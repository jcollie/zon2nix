// SPDX-FileCopyrightText: 2025 Jeffrey C. Ollie <jeff@ocjtech.us>
//
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const zon2nix = @import("zon2nix");

pub const ZigVersion = enum {
    @"15",
    @"16",
};

/// A `build.zig.zon` still to be visited, and the fetched package it came out
/// of. `owner` is null for the manifests named on the command line, which are
/// the project's own, and is carried across a `.path` dependency so that a
/// nested one is still attributed to the package that was fetched.
const Manifest = struct {
    path: []const u8,
    owner: ?*zon2nix.Dep,
};

const usage =
    \\Usage: zon2nix [options] [path ...]
    \\
    \\Reads each build.zig.zon named, follows every dependency it declares,
    \\fetches them to compute the hashes Nix needs, and writes the results.
    \\With no paths, reads build.zig.zon in the current directory.
    \\
    \\Output (each names the file to write; any may be combined):
    \\  --nix=FILE       a Nix expression that fetches every dependency
    \\  --json=FILE      a JSON object of each package's name, URL and hash
    \\  --txt=FILE       the dependency URLs, one per line (computes no hashes)
    \\  --flatpak=FILE   a flatpak-builder sources array
    \\
    \\Zig version of the Nix expression:
    \\  --16             use zig_0_16 (the default)
    \\  --15             use zig_0_15
    \\
    \\Fetching:
    \\  --jobs=N         fetch N packages at once (default 8)
    \\  --exclude=NAME   leave out the dependency named NAME, or whose package
    \\                   hash is NAME, and everything beneath it (repeatable)
    \\
    \\Logging:
    \\  --quiet          say less (repeatable)
    \\  --verbose        say more (repeatable)
    \\  --debug          say everything
    \\
    \\  -h, --help       show this and exit
    \\
    \\An option taking a value accepts it as --opt=VALUE or --opt VALUE.
    \\
;

/// The only file name zon2nix ever reads a manifest from.
const manifest_name = "build.zig.zon";

/// How many packages to fetch at once, when `--jobs` does not say.
///
/// The work is a download and a couple of subprocesses per package, so the
/// useful number is set by how long each one waits rather than by how many
/// cores there are; eight keeps the pipe full without opening an unreasonable
/// number of connections to whoever is serving the packages.
const default_jobs: usize = 8;

/// Fetches packages on a pool of workers while the main thread reads the
/// manifests they turn up.
///
/// Only the main thread touches the dependency table and reads manifests, so
/// neither needs a lock. It hands each package it finds to `todo` as soon as
/// it finds it, and a worker does the whole of that one package and hands it
/// back through `done`, which is where the main thread learns there is a new
/// manifest to read. So a package's dependencies start as soon as it is
/// finished, rather than when everything else found alongside it is.
///
/// A worker reaches nothing shared but the allocator, the temporary
/// directory and the environment, all threadsafe or read-only, and reads
/// nothing of its package that the main thread may be changing: the URL it
/// fetches is fixed before the package is handed over.
const Fetcher = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    deps: *zon2nix.Deps,
    env_map: *std.process.Environ.Map,
    want_nix_hashes: bool,
    want_json_hashes: bool,
    nix_prefetch_git: []const u8,
    nix_prefetch_url: []const u8,

    /// Waiting for a worker.
    todo: std.Io.Queue(*zon2nix.Dep),
    /// Finished with, successfully or not, and waiting for the main thread.
    done: std.Io.Queue(*zon2nix.Dep),
    todo_buffer: []*zon2nix.Dep,
    done_buffer: []*zon2nix.Dep,
    /// Found, but not yet handed over because `todo` was full. The main
    /// thread never waits to put into `todo` -- only to take from `done` --
    /// which is what keeps it and the workers from waiting on each other.
    backlog: std.ArrayList(*zon2nix.Dep),
    /// Handed to a worker and not yet back. Never more than there are
    /// workers, so nothing waits in `todo` long enough to go stale.
    outstanding: usize,
    /// No worker could be started, so the main thread fetches each package
    /// itself as it is submitted, and this holds what it has finished.
    finished: ?std.ArrayList(*zon2nix.Dep),
    group: std.Io.Group,
    /// How many workers were started, which may be fewer than asked for.
    workers: usize,

    fn init(self: *Fetcher, jobs: usize) !void {
        self.todo_buffer = try self.alloc.alloc(*zon2nix.Dep, jobs);
        errdefer self.alloc.free(self.todo_buffer);
        // Each worker holds at most one package, so there is always room for
        // it to hand that one back.
        self.done_buffer = try self.alloc.alloc(*zon2nix.Dep, jobs);
        errdefer self.alloc.free(self.done_buffer);

        self.todo = .init(self.todo_buffer);
        self.done = .init(self.done_buffer);
        self.backlog = .empty;
        self.outstanding = 0;
        self.finished = null;
        self.group = .init;

        self.workers = 0;
        while (self.workers < jobs) : (self.workers += 1) {
            self.group.concurrent(self.io, work, .{self}) catch |err| switch (err) {
                error.ConcurrencyUnavailable => break,
            };
        }

        // An Io that will not spawn anything is not an error: the main
        // thread does it all itself, one package at a time.
        if (self.workers == 0) self.finished = .empty;
    }

    fn deinit(self: *Fetcher) void {
        // Closing `todo` sends the idle workers home, and closing `done`
        // those that were about to hand something back after an error has
        // stopped anyone listening.
        self.todo.close(self.io);
        self.done.close(self.io);
        self.group.await(self.io) catch {};
        self.backlog.deinit(self.alloc);
        if (self.finished) |*finished| finished.deinit(self.alloc);
        self.alloc.free(self.todo_buffer);
        self.alloc.free(self.done_buffer);
    }

    fn fetchOne(self: *Fetcher, dep: *zon2nix.Dep) void {
        log.debug("fetching {s}", .{dep.fetched_url.?});
        dep.fetch(
            self.io,
            self.alloc,
            &self.deps.tmpdir,
            &self.deps.zig,
            &self.deps.http,
            self.env_map,
            self.want_nix_hashes,
            self.want_json_hashes,
            .{
                .nix_prefetch_git = self.nix_prefetch_git,
                .nix_prefetch_url = self.nix_prefetch_url,
            },
        ) catch |err| {
            // Left on the package and reported by the main thread.
            dep.fetch_error = err;
        };
    }

    fn work(self: *Fetcher) std.Io.Cancelable!void {
        while (true) {
            const dep = self.todo.getOne(self.io) catch |err| switch (err) {
                error.Closed => return,
                error.Canceled => |e| return e,
            };
            self.fetchOne(dep);
            self.done.putOne(self.io, dep) catch |err| switch (err) {
                error.Closed => return,
                error.Canceled => |e| return e,
            };
        }
    }

    /// Arranges for `dep` to be fetched. Which of its URLs is settled when it
    /// is handed to a worker rather than now, since a better one may turn up
    /// while it waits.
    fn submit(self: *Fetcher, dep: *zon2nix.Dep) !void {
        std.debug.assert(!dep.in_flight);
        dep.in_flight = true;
        try self.backlog.append(self.alloc, dep);
    }

    /// Settles the URLs of everything in the backlog, just before it is
    /// handed over. From then on it is the worker's to read.
    fn settleUrls(self: *Fetcher) void {
        for (self.backlog.items) |dep| dep.fetched_url = dep.getUrl();
    }

    /// Fetches `dep` again if it was fetched from a URL other than the one
    /// it will be written out with -- which happens when a better one turns
    /// up after it was started. The Nix hash belongs to the URL fetched, so
    /// the two have to agree. A package still with a worker is left alone;
    /// it is looked at again when it comes back.
    fn refetchIfStale(self: *Fetcher, dep: *zon2nix.Dep) !bool {
        if (!self.want_nix_hashes or dep.in_flight) return false;
        const url = dep.getUrl();
        if (std.mem.eql(u8, url, dep.fetched_url.?)) return false;
        log.info("fetching {s} again from {s}, the URL it is written out with", .{ dep.zig_hash, url });
        dep.forgetFetch(self.alloc);
        try self.submit(dep);
        return true;
    }

    /// The next package a worker has finished with, waiting for one if need
    /// be, or null once nothing is left to fetch.
    fn next(self: *Fetcher) !?*zon2nix.Dep {
        self.settleUrls();

        if (self.finished) |*finished| {
            for (self.backlog.items) |dep| {
                self.fetchOne(dep);
                try finished.append(self.alloc, dep);
            }
            self.backlog.clearRetainingCapacity();
            const dep = finished.pop() orelse return null;
            dep.in_flight = false;
            return dep;
        }

        // Hand over only as many as there are idle workers to take them at
        // once, and without waiting. Anything left behind stays in the
        // backlog, where its URL can still change.
        const idle = self.workers - self.outstanding;
        const offer = self.backlog.items[0..@min(idle, self.backlog.items.len)];
        const handed = try self.todo.put(self.io, offer, 0);
        self.outstanding += handed;
        const rest = self.backlog.items[handed..];
        std.mem.copyForwards(*zon2nix.Dep, self.backlog.items[0..rest.len], rest);
        self.backlog.shrinkRetainingCapacity(rest.len);

        if (self.outstanding == 0) {
            // With nothing in flight, `todo` was empty and took everything.
            std.debug.assert(self.backlog.items.len == 0);
            return null;
        }
        const dep = try self.done.getOne(self.io);
        self.outstanding -= 1;
        dep.in_flight = false;
        return dep;
    }
};

pub const std_options: std.Options = .{
    .logFn = myLogFn,
};

const log = std.log.scoped(.zon2nix);

var verbose: u3 = 2;
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    switch (level) {
        .debug => if (verbose < 4) return,
        .info => if (verbose < 3) return,
        .warn => if (verbose < 2) return,
        .err => if (verbose < 1) return,
    }

    const prefix = @tagName(level) ++ "(" ++ @tagName(scope) ++ "): ";

    // Print the message to stderr, silently ignoring any errors
    std.debug.print(prefix ++ format ++ "\n", args);
}

fn getParam(name: []const u8, arg: []const u8, it: *std.process.Args.Iterator) !?[]const u8 {
    const rest = std.mem.cutPrefix(u8, arg, name) orelse return null;
    return std.mem.cutPrefix(u8, rest, "=") orelse return it.next() orelse return error.MissingPath;
}

/// Whether writing to `out_path` would destroy a manifest, and which one.
///
/// Two ways it can. It may resolve to one of the manifests about to be read,
/// which is what happens when an output flag swallows the positional argument
/// meant as the input. Or it may simply be called `build.zig.zon`, which no
/// output ever wants to be and which also covers the manifests reached later
/// through a `.path` dependency -- those are not known yet at the point this
/// is called, and are all named that.
///
/// The returned reason is owned by the caller.
fn wouldOverwriteManifest(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    out_path: []const u8,
    inputs: []const Manifest,
) !?[]const u8 {
    if (std.mem.eql(u8, std.fs.path.basename(out_path), manifest_name)) {
        return try std.fmt.allocPrint(alloc, "'{s}', which is a manifest", .{out_path});
    }

    // The inputs are already absolute, so the output has to be made absolute
    // too before they can be compared. The file itself need not exist yet --
    // it is about to be written -- so it is the *directory* that gets
    // resolved, which does have to exist for the write to land anywhere.
    //
    // Note that `Dir.cwd()`'s handle is `AT_FDCWD` rather than a real
    // descriptor, so asking it for its own path does not work; naming a path
    // relative to it does.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_name = std.fs.path.dirname(out_path) orelse ".";
    const dir_len = cwd.realPathFile(io, dir_name, &buf) catch {
        // No such directory: the write will fail on its own, and with a
        // better message than anything that could be invented here.
        return null;
    };
    const resolved = try std.fs.path.join(alloc, &.{
        buf[0..dir_len],
        std.fs.path.basename(out_path),
    });
    defer alloc.free(resolved);

    for (inputs) |manifest| {
        if (std.mem.eql(u8, manifest.path, resolved)) {
            return try std.fmt.allocPrint(alloc, "'{s}', which it is also reading", .{out_path});
        }
    }
    return null;
}

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;

    const cwd: std.Io.Dir = .cwd();

    // stack of paths to build.zig.zon files that we need to visit
    var paths: std.ArrayList(Manifest) = .empty;
    defer {
        for (paths.items) |manifest| {
            alloc.free(manifest.path);
        }
        paths.deinit(alloc);
    }

    var zig_version: ZigVersion = .@"16";

    var txt_out: ?[]const u8 = null;
    defer if (txt_out) |f| alloc.free(f);

    var nix_out: ?[]const u8 = null;
    defer if (nix_out) |f| alloc.free(f);

    var json_out: ?[]const u8 = null;
    defer if (json_out) |f| alloc.free(f);

    var flatpak_out: ?[]const u8 = null;
    defer if (flatpak_out) |f| alloc.free(f);

    var jobs: usize = default_jobs;

    var excludes: Excludes = .{};
    defer excludes.deinit(alloc);

    {
        var it = try init.minimal.args.iterateAllocator(alloc);
        defer it.deinit();

        // skip program name
        _ = it.next();

        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                var buffer: [1024]u8 = undefined;
                var stdout: std.Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
                stdout.interface.writeAll(usage) catch {};
                stdout.interface.flush() catch {};
                return 0;
            }

            if (std.mem.eql(u8, arg, "--verbose")) {
                verbose = (verbose + 1) % 5;
                continue;
            }

            if (std.mem.eql(u8, arg, "--quiet")) {
                verbose -|= 1;
                continue;
            }

            if (std.mem.eql(u8, arg, "--debug")) {
                verbose = 4;
                continue;
            }

            if (std.mem.eql(u8, arg, "--15")) {
                zig_version = .@"15";
                continue;
            }

            if (std.mem.eql(u8, arg, "--16")) {
                zig_version = .@"16";
                continue;
            }

            if (try getParam("--txt", arg, &it)) |param| {
                txt_out = try alloc.dupe(u8, param);
                continue;
            }

            if (try getParam("--nix", arg, &it)) |param| {
                nix_out = try alloc.dupe(u8, param);
                continue;
            }

            if (try getParam("--json", arg, &it)) |param| {
                json_out = try alloc.dupe(u8, param);
                continue;
            }

            if (try getParam("--flatpak", arg, &it)) |param| {
                flatpak_out = try alloc.dupe(u8, param);
                continue;
            }

            if (try getParam("--exclude", arg, &it)) |param| {
                try excludes.add(alloc, param);
                continue;
            }

            if (try getParam("--jobs", arg, &it)) |param| {
                jobs = std.fmt.parseUnsigned(usize, param, 10) catch {
                    log.err("--jobs wants a number, got '{s}'", .{param});
                    return 1;
                };
                if (jobs == 0) {
                    log.err("--jobs must be at least 1", .{});
                    return 1;
                }
                continue;
            }

            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const len = try cwd.realPathFile(io, arg, &buf);
            try paths.append(alloc, .{ .path = try alloc.dupe(u8, buf[0..len]), .owner = null });
        }
    }

    // if the user didn't supply any paths on the command line, look for
    // build.zig.zon in the current directory
    if (paths.items.len == 0) {
        log.warn("no paths specified on the command line, looking for build.zig.zon in the current directory", .{});
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try cwd.realPathFile(io, manifest_name, &buf);
        try paths.append(alloc, .{ .path = try alloc.dupe(u8, buf[0..len]), .owner = null });
    }

    // Refuse to write an output over a manifest, before any work is done.
    //
    // `--txt`, `--nix`, `--json` and `--flatpak` all name an *output*, and in
    // the `--txt FILE` form that is easy to read as an input -- `zon2nix --txt
    // build.zig.zon` is a plausible-looking way to ask for a listing and is in
    // fact a request to overwrite the manifest with one. It is worth noticing
    // that this leaves nothing to recover from: the manifest holds the URLs
    // and hashes, and the file that replaces it holds the URLs.
    {
        const outputs = [_]struct { flag: []const u8, path: ?[]const u8 }{
            .{ .flag = "--txt", .path = txt_out },
            .{ .flag = "--nix", .path = nix_out },
            .{ .flag = "--json", .path = json_out },
            .{ .flag = "--flatpak", .path = flatpak_out },
        };
        for (outputs) |output| {
            const out_path = output.path orelse continue;
            if (try wouldOverwriteManifest(alloc, io, cwd, out_path, paths.items)) |reason| {
                defer alloc.free(reason);
                log.err("{s} would write over {s}", .{ output.flag, reason });
                log.err("these flags name the file to write, not the manifest to read", .{});
                return 1;
            }
        }
    }

    var deps: zon2nix.Deps = undefined;
    try deps.init(io, alloc, init.environ_map);
    defer deps.deinit(io, alloc);

    // keep track of paths that we've already processed
    var paths_seen: std.StringArrayHashMapUnmanaged(bool) = .empty;
    defer {
        var it = paths_seen.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }
        paths_seen.deinit(alloc);
    }

    // if we're not outputting a nix derivation or json, skip fetching the hash
    const want_nix_hashes = nix_out != null or json_out != null or flatpak_out != null;

    var fetcher: Fetcher = .{
        .io = io,
        .alloc = alloc,
        .deps = &deps,
        .env_map = init.environ_map,
        .want_nix_hashes = want_nix_hashes,
        .want_json_hashes = json_out != null,
        .nix_prefetch_git = options.nix_prefetch_git,
        .nix_prefetch_url = options.nix_prefetch_url,
        .todo = undefined,
        .done = undefined,
        .todo_buffer = undefined,
        .done_buffer = undefined,
        .backlog = undefined,
        .outstanding = undefined,
        .finished = undefined,
        .group = undefined,
        .workers = undefined,
    };
    try fetcher.init(jobs);
    defer fetcher.deinit();

    // Once anything has failed nothing new is started: the run is going to
    // fail, and what is already in flight is only waited for so that it can
    // be reported and cleaned up.
    var failed = false;

    while (true) {
        // Read every manifest that is ready. A `.path` dependency is already
        // on disk, so it is read straight away rather than waiting its turn,
        // and stays attributed to the package it came out of.
        while (paths.pop()) |manifest| {
            defer alloc.free(manifest.path);
            const path = manifest.path;

            // if we've already processed a path don't do it again
            if (paths_seen.contains(path)) continue;
            try paths_seen.put(alloc, try alloc.dupe(u8, path), true);

            log.debug("reading {s}", .{path});
            var file = cwd.openFile(
                io,
                path,
                .{ .mode = .read_only },
            ) catch |err| switch (err) {
                error.FileNotFound => {
                    log.debug("{s} not found", .{path});
                    continue;
                },
                else => |e| return e,
            };
            defer file.close(io);

            var buffer: [1024]u8 = undefined;
            var reader = file.reader(io, &buffer);

            var build_zig_zon: zon2nix.BuildZigZon = try .init(alloc, &reader.interface, path);
            defer build_zig_zon.deinit();

            var it = build_zig_zon.dependencies.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                const zon_dep = entry.value_ptr;

                if (excludes.matches(name, zon_dep.hash)) {
                    log.info("excluding {s}, named in {s}", .{ name, path });
                    continue;
                }

                if (zon_dep.url) |url| {
                    const zig_hash = zon_dep.hash orelse {
                        log.err("hash is missing from {s} in {s}", .{ name, path });
                        continue;
                    };

                    const found = try deps.get(alloc, name, url, zig_hash);
                    if (failed) continue;
                    if (found.is_new) {
                        try fetcher.submit(found.dep);
                    } else {
                        // This may have been a better URL for a package
                        // already fetched.
                        _ = try fetcher.refetchIfStale(found.dep);
                    }
                }

                if (zon_dep.path) |dep_path| {
                    // Zig 0.16.0 hangs in `--system` mode on a fetched package
                    // with a `.path` dependency, so the package that brought
                    // this manifest in has to be named in the generated
                    // expression.
                    if (manifest.owner) |owner| owner.has_path_dependency = true;

                    const dir = try cwd.openDir(
                        io,
                        std.fs.path.dirname(path) orelse ".",
                        .{},
                    );
                    const full_path = try dir.realPathFileAlloc(io, dep_path, alloc);
                    defer alloc.free(full_path);

                    const new_path = try std.fs.path.join(
                        alloc,
                        &.{
                            full_path,
                            manifest_name,
                        },
                    );
                    errdefer alloc.free(new_path);

                    log.debug("adding to paths: {s}", .{new_path});
                    try paths.append(
                        alloc,
                        .{ .path = new_path, .owner = manifest.owner },
                    );
                }
            }
        }

        const dep = try fetcher.next() orelse break;
        if (dep.fetch_error) |err| {
            log.err("fetching {s}: {t}", .{ dep.fetched_url.?, err });
            failed = true;
            continue;
        }
        if (failed) continue;
        // A better URL may have turned up while it was being fetched.
        if (try fetcher.refetchIfStale(dep)) continue;
        if (dep.manifest_queued) continue;
        const manifest_path = dep.manifest_path orelse continue;
        dep.manifest_queued = true;
        log.debug("adding to paths: {s}", .{manifest_path});
        try paths.append(
            alloc,
            .{ .path = try alloc.dupe(u8, manifest_path), .owner = dep },
        );
    }
    if (failed) return 1;

    // An exclusion that never matched is most likely a misspelling, and would
    // otherwise leave the package it meant to exclude silently included.
    for (excludes.items.items) |exclude| {
        if (!exclude.matched) log.warn("--exclude {s} matched no dependency", .{exclude.pattern});
    }

    // Every package now agrees with the URL it will be written out with:
    // the last manifest has been read, so no better one can turn up, and any
    // package that came back stale was sent out again before the loop could
    // end.
    if (want_nix_hashes) {
        var it = deps.iterator();
        while (it.next()) |dep| std.debug.assert(std.mem.eql(u8, dep.getUrl(), dep.fetched_url.?));
    }

    var list: std.ArrayList(*zon2nix.Dep) = .empty;
    // don't deallocate the actual entries as they will be
    // deallocated with the hash maps
    defer list.deinit(alloc);

    var it = deps.iterator();
    while (it.next()) |entry| {
        try list.append(alloc, entry);
    }

    if (txt_out) |path| {
        std.mem.sort(*zon2nix.Dep, list.items, {}, sortByUrl);

        // output a list of URLs
        var file = try cwd.createFileAtomic(io, path, .{ .replace = true });
        defer file.deinit(io);

        var buffer: [64]u8 = undefined;
        var writer = file.file.writer(io, &buffer);

        for (list.items) |dep| {
            try writer.interface.print("{s}\n", .{dep.getUrl()});
        }

        try writer.interface.flush();
        try file.replace(io);
    }

    if (nix_out) |path| {
        std.mem.sort(*zon2nix.Dep, list.items, {}, sortByName);

        var file = try cwd.createFileAtomic(io, path, .{ .replace = true });
        defer file.deinit(io);

        var file_buffer: [64]u8 = undefined;
        var file_writer = file.file.writer(io, &file_buffer);

        var nixfmt = std.process.spawn(
            io,
            .{
                .argv = &.{ options.nixfmt, "-" },
                .stdin = .pipe,
                .stdout = .pipe,
            },
        ) catch |err| switch (err) {
            error.FileNotFound => {
                log.err("unable to execute nixfmt, is it in your PATH?", .{});
                return 1;
            },
            else => |e| return e,
        };
        errdefer nixfmt.kill(io);

        const stdin = nixfmt.stdin orelse return error.ExecFailed;
        var stdin_buf: [1024]u8 = undefined;
        var stdin_writer = stdin.writer(io, &stdin_buf);

        const stdout = nixfmt.stdout orelse return error.ExecFailed;
        var stdout_buf: [1024]u8 = undefined;
        var stdout_reader = stdout.reader(io, &stdout_buf);

        var stream_to_file = try io.concurrent(
            zon2nix.streamer,
            .{ &stdout_reader.interface, &file_writer.interface },
        );
        defer stream_to_file.cancel(io) catch {};

        const template = switch (zig_version) {
            .@"15" => @embedFile("header_0_15.nix"),
            .@"16" => @embedFile("header_0_16.nix"),
        };
        const head, const rest = splitTemplate(template, packages_marker);
        const middle, const tail = splitTemplate(rest, path_dependencies_marker);

        const w = &stdin_writer.interface;
        try w.writeAll(head);
        for (list.items) |dep| try writeNixPackage(alloc, w, dep);
        try w.writeAll(middle);
        // Packages that declare `.path` dependencies of their own, which
        // `zig build --system` cannot build on Zig 0.16.0 without forking
        // them.
        for (list.items) |dep| {
            if (!dep.has_path_dependency) continue;
            try writeNixString(w, dep.zig_hash);
            try w.writeByte('\n');
        }
        try w.writeAll(tail);

        try stdin_writer.interface.flush();
        stdin.close(io);
        nixfmt.stdin = null;

        try stream_to_file.await(io);

        _ = try nixfmt.wait(io);

        try file.replace(io);
    }

    if (json_out) |path| {
        // output a json object
        var file = try cwd.createFileAtomic(io, path, .{ .replace = true });
        defer file.deinit(io);

        var buffer: [64]u8 = undefined;
        var writer = file.file.writer(io, &buffer);

        std.mem.sort(*zon2nix.Dep, list.items, {}, sortByName);

        try writer.interface.writeAll("{\n");

        for (list.items, 0..) |dep, index| {
            const json_hash = try jsonHash(alloc, dep);
            defer alloc.free(json_hash);

            try writer.interface.print(
                \\  "{[zig_hash]s}": {{
                \\    "name": "{[name]s}",
                \\    "url": "{[url]s}",
                \\    "hash": "{[nix_hash]s}"
                \\  }}{[comma]s}
                \\
            , .{
                .zig_hash = dep.zig_hash,
                .name = dep.getName(),
                .url = dep.getUrl(),
                .nix_hash = json_hash,
                .comma = if (index < list.items.len - 1) "," else "",
            });
        }

        try writer.interface.writeAll("}\n");
        try writer.interface.flush();

        try file.replace(io);
    }

    if (flatpak_out) |path| {
        std.mem.sort(*zon2nix.Dep, list.items, {}, sortByName);

        var file = try cwd.createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        var buffer: [64]u8 = undefined;
        var writer = file.writer(io, &buffer);

        try writer.interface.writeAll("[\n");

        for (list.items, 0..) |dep, index| {
            const url = dep.getUrl();

            if (!std.mem.startsWith(u8, url, "git+")) {
                const local = dep.local orelse return error.MissingSHA256;

                try writer.interface.print(
                    \\  {{
                    \\    "type": "archive",
                    \\    "url": "{[url]s}",
                    \\    "dest": "vendor/p/{[zig_hash]s}",
                    \\    "sha256": "{[sha256_hash]s}"
                    \\  }}{[comma]s}
                    \\
                , .{
                    .zig_hash = dep.zig_hash,
                    .url = url,
                    .sha256_hash = local.sha256,
                    .comma = if (index < list.items.len - 1) "," else "",
                });
            } else {
                // The commit the URL resolved to, since the URL may name a
                // branch or a tag and Flatpak wants a commit.
                const commit = (dep.nix orelse return error.MissingNixHash).rev orelse return error.MissingGitRev;
                const new_url = try zon2nix.nix.gitRepositoryUrl(alloc, url);
                defer alloc.free(new_url);
                try writer.interface.print(
                    \\  {{
                    \\    "type": "git",
                    \\    "url": "{[url]s}",
                    \\    "commit": "{[commit]s}",
                    \\    "dest": "vendor/p/{[zig_hash]s}"
                    \\  }}{[comma]s}
                    \\
                , .{
                    .zig_hash = dep.zig_hash,
                    .url = new_url,
                    .commit = commit,
                    .comma = if (index < list.items.len - 1) "," else "",
                });
            }
        }

        try writer.interface.writeAll("]\n");
        try writer.interface.flush();
    }

    return 0;
}

// fn sortByKey(_: void, lhs: []const u8, rhs: []const u8) bool {
//     return std.mem.lessThan(u8, lhs, rhs);
// }

/// The packages named by `--exclude`, which are neither fetched nor looked
/// inside, so that nothing beneath them is either.
const Excludes = struct {
    items: std.ArrayList(struct { pattern: []const u8, matched: bool }) = .empty,

    fn add(self: *Excludes, alloc: std.mem.Allocator, pattern: []const u8) !void {
        const owned = try alloc.dupe(u8, pattern);
        errdefer alloc.free(owned);
        try self.items.append(alloc, .{ .pattern = owned, .matched = false });
    }

    fn deinit(self: *Excludes, alloc: std.mem.Allocator) void {
        for (self.items.items) |exclude| alloc.free(exclude.pattern);
        self.items.deinit(alloc);
    }

    /// Whether a dependency is excluded: by the name the manifest gives it,
    /// or by its package hash.
    fn matches(self: *Excludes, name: []const u8, hash: ?[]const u8) bool {
        var found = false;
        for (self.items.items) |*exclude| {
            if (std.mem.eql(u8, exclude.pattern, name) or
                (hash != null and std.mem.eql(u8, exclude.pattern, hash.?)))
            {
                exclude.matched = true;
                found = true;
            }
        }
        return found;
    }
};

test "Excludes.matches" {
    const alloc = std.testing.allocator;
    var excludes: Excludes = .{};
    defer excludes.deinit(alloc);
    try excludes.add(alloc, "tree_sitter");
    try excludes.add(alloc, "N-V-__8AAFdWDwA0ktbNUi9pFBHCRN4weXIgIfCrVjfGxqgA");
    try excludes.add(alloc, "never_used");

    try std.testing.expect(excludes.matches("tree_sitter", "tree_sitter-0.25.0-AAAA"));
    try std.testing.expect(!excludes.matches("tree_sitter_json", null));
    try std.testing.expect(excludes.matches("wayland_protocols", "N-V-__8AAFdWDwA0ktbNUi9pFBHCRN4weXIgIfCrVjfGxqgA"));
    try std.testing.expect(!excludes.matches("local", null));

    try std.testing.expect(excludes.items.items[0].matched);
    try std.testing.expect(excludes.items.items[1].matched);
    try std.testing.expect(!excludes.items.items[2].matched);
}

/// The hash a package is given in the JSON output, owned by the caller.
///
/// Tools outside zon2nix build distribution packages from the JSON, so its
/// hashes keep the meaning they had before the Nix expression chose a fetcher
/// per archive: for a naked `N-V-` package, the SHA-256 of the archive file;
/// for anything else, the Nix hash of the unpacked package or of an ordinary
/// git checkout. The Nix expression may use `fetchzip` for a naked package,
/// and then hashes it unpacked, and checks a git repository out without its
/// `.gitattributes`, which is why the two can differ.
fn jsonHash(alloc: std.mem.Allocator, dep: *zon2nix.Dep) ![]const u8 {
    const nix = dep.nix orelse return error.MissingNixHash;
    if (dep.json_hash) |hash| return alloc.dupe(u8, hash);
    if (std.mem.startsWith(u8, dep.zig_hash, "N-V-")) {
        if (dep.local) |local| {
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            _ = try std.fmt.hexToBytes(&digest, local.sha256);
            return std.fmt.allocPrint(alloc, "sha256-{b64}", .{&digest});
        }
    }
    return alloc.dupe(u8, nix.hash);
}

/// Where the packages go in a Nix header, and where the packages that need
/// forking go. Each is a comment line on its own, so that the header is valid
/// Nix as it stands, and is replaced whole.
const packages_marker = "    # @packages@\n";
const path_dependencies_marker = "    # @pathDependencyPackages@\n";

fn splitTemplate(template: []const u8, comptime marker: []const u8) struct { []const u8, []const u8 } {
    const at = std.mem.find(u8, template, marker) orelse @panic("Nix header is missing " ++ marker);
    return .{ template[0..at], template[at + marker.len ..] };
}

/// Writes one package's entry: its hash, and the call that fetches it.
fn writeNixPackage(alloc: std.mem.Allocator, w: *std.Io.Writer, dep: *zon2nix.Dep) !void {
    const nix = dep.nix orelse return error.MissingNixHash;
    const url = dep.getUrl();

    try writeNixString(w, dep.zig_hash);
    try w.print(" = {s} {{\n", .{switch (nix.fetcher) {
        .fetchzip => "fetchzip",
        .fetchurl => "fetchurl",
        // `fetchgit`, checking out the files as committed; see the header.
        .fetchgit => "fetchZigGit",
    }});
    switch (nix.fetcher) {
        .fetchzip => {
            try writeNixAttr(w, "name", dep.getName());
            try writeNixAttr(w, "url", url);
            try writeNixAttr(w, "hash", nix.hash);
            if (std.ascii.endsWithIgnoreCase(url, ".tar.zst") or std.ascii.endsWithIgnoreCase(url, ".tzst")) {
                try w.writeAll("nativeBuildInputs = [ zstd ];\n");
            }
        },
        .fetchurl => {
            // No name: Nix names the file after the URL, and `zig fetch`
            // decides how to unpack it by that name.
            try writeNixAttr(w, "url", url);
            try writeNixAttr(w, "hash", nix.hash);
        },
        .fetchgit => {
            const git_url = try zon2nix.nix.gitRepositoryUrl(alloc, url);
            defer alloc.free(git_url);
            try writeNixAttr(w, "name", dep.getName());
            try writeNixAttr(w, "url", git_url);
            try writeNixAttr(w, "rev", nix.rev orelse return error.MissingGitRev);
            try writeNixAttr(w, "hash", nix.hash);
        },
    }
    try w.writeAll("};\n");
}

fn writeNixAttr(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try w.print("{s} = ", .{name});
    try writeNixString(w, value);
    try w.writeAll(";\n");
}

/// Writes `value` as a Nix string. The URLs and names come from manifests,
/// so a `"` or `${` in one must not end the string or start an
/// interpolation.
fn writeNixString(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '$' => try w.writeAll(if (i + 1 < value.len and value[i + 1] == '{') "\\$" else "$"),
            else => |c| try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

test writeNixString {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeNixString(&w, "a\"b\\c${d}$e\n");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\${d}$e\\n\"", w.buffered());
}

fn sortByZigHash(_: void, lhs: *zon2nix.Dep, rhs: *zon2nix.Dep) bool {
    const a = lhs.zig_hash;
    const b = rhs.zig_hash;
    return std.mem.lessThan(u8, a, b);
}

fn sortByName(_: void, lhs: *zon2nix.Dep, rhs: *zon2nix.Dep) bool {
    if (std.mem.eql(u8, lhs.getName(), rhs.getName())) {
        return std.mem.lessThan(u8, lhs.getUrl(), rhs.getUrl());
    }
    return std.mem.lessThan(u8, lhs.getName(), rhs.getName());
}

fn sortByUrl(_: void, lhs: *zon2nix.Dep, rhs: *zon2nix.Dep) bool {
    const a = lhs.getUrl();
    const b = rhs.getUrl();
    return std.mem.lessThan(u8, a, b);
}

test "an output named like a manifest is refused wherever it is" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_][]const u8{
        manifest_name,
        "./" ++ manifest_name,
        "sub/" ++ manifest_name,
        "/tmp/" ++ manifest_name,
    }) |out_path| {
        const reason = try wouldOverwriteManifest(alloc, io, tmp.dir, out_path, &.{});
        defer if (reason) |r| alloc.free(r);
        try std.testing.expect(reason != null);
        try std.testing.expect(std.mem.endsWith(u8, reason.?, "which is a manifest"));
    }
}

test "an output that resolves onto an input is refused" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "listed.zon", .data = ".{}\n" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const absolute = buf[0..try tmp.dir.realPathFile(io, "listed.zon", &buf)];
    const inputs = [_]Manifest{.{ .path = absolute, .owner = null }};

    // Named relatively, where the input was recorded absolutely: the two have
    // to be recognised as the same file, which is the whole job of resolving
    // the output's directory.
    {
        const reason = try wouldOverwriteManifest(alloc, io, tmp.dir, "listed.zon", &inputs);
        defer if (reason) |r| alloc.free(r);
        try std.testing.expect(reason != null);
        try std.testing.expect(std.mem.endsWith(u8, reason.?, "which it is also reading"));
    }

    // And by the same name with a detour through the directory.
    {
        const reason = try wouldOverwriteManifest(alloc, io, tmp.dir, "./listed.zon", &inputs);
        defer if (reason) |r| alloc.free(r);
        try std.testing.expect(reason != null);
    }
}

test "an ordinary output is allowed" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "listed.zon", .data = ".{}\n" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const absolute = buf[0..try tmp.dir.realPathFile(io, "listed.zon", &buf)];
    const inputs = [_]Manifest{.{ .path = absolute, .owner = null }};

    for ([_][]const u8{ "build.zig.zon.nix", "deps.txt", "./out.json" }) |out_path| {
        const reason = try wouldOverwriteManifest(alloc, io, tmp.dir, out_path, &inputs);
        defer if (reason) |r| alloc.free(r);
        try std.testing.expectEqual(@as(?[]const u8, null), reason);
    }

    // A directory that does not exist is not this check's business: the write
    // will say so, and better.
    const missing = try wouldOverwriteManifest(alloc, io, tmp.dir, "nope/out.nix", &inputs);
    defer if (missing) |r| alloc.free(r);
    try std.testing.expectEqual(@as(?[]const u8, null), missing);
}
