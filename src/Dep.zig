// SPDX-FileCopyrightText: 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
//
// SPDX-License-Identifier: MIT

pub const Dep = @This();

const std = @import("std");

const log = std.log.scoped(.deps);

const TmpDir = @import("TmpDir.zig");
const Zig = @import("Zig.zig");
const ZigPackage = @import("ZigPackage.zig");
const nixpkg = @import("nix.zig");
const Style = @import("root.zig").Style;

zig_hash: []const u8,
names: std.StringArrayHashMapUnmanaged(bool),
urls: std.StringArrayHashMapUnmanaged(bool),
local: ?struct {
    path: []const u8,
    sha256: []const u8,
},
/// Where the package was unpacked to, once it has been.
zig: ?struct {
    local_path: []const u8,
},
nix: ?struct {
    b64: []const u8,
    hex: []const u8,
    unpack: bool,
},
/// Where this package's own `build.zig.zon` ended up once it was fetched,
/// or null if it has none. Filled in by `fetch`.
manifest_path: ?[]const u8,
/// The URL this package was fetched from, one of the keys of `urls`. Set by
/// the main thread before the package is handed to a worker, so that the
/// worker never reads `urls` while the main thread may still be adding to
/// it. After the last manifest has been read it is made to agree with
/// `getUrl`, since the Nix hash belongs to the URL that was fetched.
fetched_url: ?[]const u8,
/// Whether the package is with a worker right now. Only the main thread
/// reads or writes it.
in_flight: bool,
/// Whether this package's own manifest has been queued to be read, so that
/// fetching it again from another URL does not read it twice.
manifest_queued: bool,
/// What went wrong while fetching this package, if anything. A fetch runs on
/// a worker whose return value is discarded, so the failure is recorded here
/// and reported once the round it belongs to has finished.
fetch_error: ?anyerror,
/// Whether this package's own `build.zig.zon`, or that of a package it
/// reaches by `.path`, declares a dependency by `.path`. Zig 0.16.0 cannot
/// build such a package through `zig build --system`, so the generated Nix
/// expression names them and a package that uses `--system` forks them.
has_path_dependency: bool,

const Hasher = std.crypto.hash.sha2.Sha256;

pub fn init(
    self: *Dep,
    alloc: std.mem.Allocator,
    name: []const u8,
    url: []const u8,
    zig_hash: []const u8,
) !void {
    self.* = .{
        .zig_hash = try alloc.dupe(u8, zig_hash),
        .local = null,
        .zig = null,
        .nix = null,
        .names = .empty,
        .urls = .empty,
        .manifest_path = null,
        .fetched_url = null,
        .in_flight = false,
        .manifest_queued = false,
        .fetch_error = null,
        .has_path_dependency = false,
    };
    errdefer self.deinit(alloc);

    {
        const owned = try alloc.dupe(u8, name);
        errdefer alloc.free(owned);
        try self.names.putNoClobber(alloc, owned, true);
    }
    {
        const owned = try alloc.dupe(u8, url);
        errdefer alloc.free(owned);
        try self.urls.putNoClobber(alloc, owned, true);
    }
}

/// Everything that has to happen over the network for one package, and
/// nothing that touches state shared with any other: the artifact is
/// downloaded and hashed, `zig fetch` unpacks it, and `nix-prefetch-*` is
/// asked for the hash Nix will want. Safe to run for many packages at once.
pub fn fetch(
    self: *Dep,
    io: std.Io,
    alloc: std.mem.Allocator,
    tmpdir: *TmpDir,
    zigcli: *Zig,
    http: *std.http.Client,
    env_map: *std.process.Environ.Map,
    want_nix_hashes: bool,
    options: nixpkg.Options,
) !void {
    const url = self.fetched_url.?;
    try self.download(io, alloc, tmpdir, http, url);
    self.manifest_path = try self.getBuildZigZon(io, alloc, zigcli, tmpdir);
    if (want_nix_hashes) try self.getNixHashes(io, alloc, env_map, tmpdir, options);
}

pub fn deinit(self: *Dep, alloc: std.mem.Allocator) void {
    alloc.free(self.zig_hash);
    self.forgetFetch(alloc);
    self.deinitNames(alloc);
    self.deinitUrls(alloc);
}

fn deinitNames(self: *Dep, alloc: std.mem.Allocator) void {
    var n_it = self.names.iterator();
    while (n_it.next()) |n| {
        alloc.free(n.key_ptr.*);
    }
    self.names.deinit(alloc);
}

fn deinitUrls(self: *Dep, alloc: std.mem.Allocator) void {
    var u_it = self.urls.iterator();
    while (u_it.next()) |u| {
        alloc.free(u.key_ptr.*);
    }
    self.urls.deinit(alloc);
}

pub fn addName(self: *Dep, alloc: std.mem.Allocator, name: []const u8) !void {
    if (self.names.contains(name)) return;
    {
        const owned = try alloc.dupe(u8, name);
        errdefer alloc.free(owned);
        try self.names.putNoClobber(alloc, owned, true);
    }
    log.warn("{s} referenced by multiple names:", .{self.zig_hash});
    var it = self.names.iterator();
    while (it.next()) |entry| {
        log.warn("  {s}", .{entry.key_ptr.*});
    }
}

/// The name this package is written out under: the alphabetically first of
/// the names it was reached by. Chosen by a rule rather than by which was
/// seen first, because packages are fetched as they are found, so the order
/// they are seen in is down to timing.
pub fn getName(self: *Dep) []const u8 {
    const names = self.names.keys();
    if (names.len == 0) unreachable;
    var best = names[0];
    for (names[1..]) |name| {
        if (std.mem.lessThan(u8, name, best)) best = name;
    }
    return best;
}

pub fn addUrl(self: *Dep, alloc: std.mem.Allocator, url: []const u8) !void {
    if (self.urls.contains(url)) return;
    {
        const owned = try alloc.dupe(u8, url);
        errdefer alloc.free(owned);
        try self.urls.put(alloc, owned, true);
    }
    log.warn("{s} downloaded via multiple URLs:", .{self.zig_hash});
    var it = self.urls.iterator();
    while (it.next()) |entry| {
        log.warn("  {s}", .{entry.key_ptr.*});
    }
}

/// The URL this package is written out with, chosen by a rule for the same
/// reason as `getName`: an archive over a git repository, since Nix fetches
/// one far more cheaply than it clones the other, and then the
/// alphabetically first.
pub fn getUrl(self: *Dep) []const u8 {
    const urls = self.urls.keys();
    if (urls.len == 0) unreachable;
    var best = urls[0];
    for (urls[1..]) |url| {
        if (urlLessThan(url, best)) best = url;
    }
    return best;
}

fn urlLessThan(lhs: []const u8, rhs: []const u8) bool {
    const lhs_git = std.mem.startsWith(u8, lhs, "git+");
    const rhs_git = std.mem.startsWith(u8, rhs, "git+");
    if (lhs_git != rhs_git) return rhs_git;
    return std.mem.lessThan(u8, lhs, rhs);
}

/// Forgets everything a fetch found, so that the package can be fetched
/// again from another URL. The manifest has already been read, and is not
/// read again: the package hash is the same, so its contents are too.
pub fn forgetFetch(self: *Dep, alloc: std.mem.Allocator) void {
    if (self.manifest_path) |path| alloc.free(path);
    if (self.local) |local| {
        alloc.free(local.path);
        alloc.free(local.sha256);
    }
    if (self.zig) |zig| alloc.free(zig.local_path);
    if (self.nix) |nix| {
        alloc.free(nix.hex);
        alloc.free(nix.b64);
    }
    self.manifest_path = null;
    self.local = null;
    self.zig = null;
    self.nix = null;
    self.fetch_error = null;
}

pub fn download(
    self: *Dep,
    io: std.Io,
    alloc: std.mem.Allocator,
    tmpdir: *TmpDir,
    client: *std.http.Client,
    url: []const u8,
) !void {
    log.debug("downloading {s}", .{url});

    const uri = try std.Uri.parse(url);

    const style: Style = .init(uri.scheme);

    switch (style) {
        .http => {
            const subdir = try tmpdir.randomSubdir(io, alloc);
            defer subdir.deinit(io, alloc);

            const filename = std.fs.path.basename(url);
            const path = try std.fs.path.join(alloc, &.{ tmpdir.path, subdir.name, filename });
            errdefer alloc.free(path);

            var f = try subdir.dir.createFileAtomic(io, filename, .{});
            defer f.deinit(io);

            var file_writer_buffer: [1024]u8 = undefined;
            var file_writer = f.file.writer(io, &file_writer_buffer);

            var hasher_buffer: [1024]u8 = undefined;
            var hasher_writer: std.Io.Writer.Hashed(Hasher) = .initHasher(&file_writer.interface, .init(.{}), &hasher_buffer);
            const writer = &hasher_writer.writer;

            const status = status: {
                const result = try client.fetch(.{
                    .method = .GET,
                    .location = .{ .uri = uri },
                    .response_writer = writer,
                });
                break :status result.status;
            };
            if (status != .ok) return error.BadHttpStatus;

            try hasher_writer.writer.flush();
            try file_writer.interface.flush();
            try f.link(io);

            const sha256 = try std.fmt.allocPrint(alloc, "{x}", .{hasher_writer.hasher.finalResult()});
            errdefer alloc.free(sha256);

            self.local = .{
                .path = path,
                .sha256 = sha256,
            };
            log.debug("downloaded and hashed {s}", .{url});
        },
        .file => {
            const path = path: {
                var w: std.Io.Writer.Allocating = .init(alloc);
                defer w.deinit();
                try uri.path.formatPath(&w.writer);
                try w.writer.flush();

                break :path try w.toOwnedSlice();
            };
            errdefer alloc.free(path);

            var file = try tmpdir.dir.openFile(io, path, .{});
            var file_read_buffer: [1024]u8 = undefined;
            var file_reader = file.reader(io, &file_read_buffer);

            var hasher_buffer: [1024]u8 = undefined;
            var hasher: std.Io.Writer.Hashing(Hasher) = .initHasher(.init(.{}), &hasher_buffer);

            _ = try file_reader.interface.streamRemaining(&hasher.writer);
            try hasher.writer.flush();

            const sha256 = try std.fmt.allocPrint(alloc, "{x}", .{hasher.hasher.finalResult()});
            errdefer alloc.free(sha256);

            self.local = .{
                .path = path,
                .sha256 = sha256,
            };

            log.debug("hashed local file {s}", .{url});
        },
        .git, .other => {
            log.debug("download skipped for {s}", .{url});
        },
    }
}

pub fn getBuildZigZon(
    self: *Dep,
    io: std.Io,
    alloc: std.mem.Allocator,
    zigcli: *Zig,
    tmpdir: *TmpDir,
) !?[]const u8 {
    const local_path = local_path: {
        if (self.zig) |z| {
            break :local_path z.local_path;
        }

        // An archive has already been downloaded, and is unpacked and hashed
        // here. Only a git dependency still goes through `zig fetch`.
        const local_path = if (self.local) |local|
            try self.unpack(io, alloc, tmpdir, local.path)
        else git: {
            const local_path, const global_path = try zigcli.fetch(
                io,
                alloc,
                tmpdir.dir,
                self.fetched_url.?,
                self.zig_hash,
                .{},
            );
            alloc.free(global_path);
            break :git local_path;
        };
        self.zig = .{ .local_path = local_path };
        break :local_path local_path;
    };

    const path = try std.fs.path.join(alloc, &.{ local_path, "build.zig.zon" });
    std.Io.Dir.accessAbsolute(io, path, .{}) catch {
        alloc.free(path);
        return null;
    };
    return path;
}

/// Unpacks a downloaded archive and checks it against the hash the manifest
/// named it by. Returns the package's root directory, owned by the caller.
fn unpack(
    self: *Dep,
    io: std.Io,
    alloc: std.mem.Allocator,
    tmpdir: *TmpDir,
    archive_path: []const u8,
) ![]const u8 {
    log.info("unpacking {s}", .{archive_path});

    const subdir = try tmpdir.randomSubdir(io, alloc);
    defer subdir.deinit(io, alloc);

    const unpacked = try ZigPackage.unpack(io, alloc, archive_path, subdir.dir, subdir.path);
    defer alloc.free(unpacked.hash);
    errdefer alloc.free(unpacked.root);

    if (!std.mem.eql(u8, self.zig_hash, unpacked.hash)) {
        log.err("hash mismatch for {s}", .{self.fetched_url.?});
        log.err("expected: {s}", .{self.zig_hash});
        log.err("actual:   {s}", .{unpacked.hash});
        return error.HashMismatch;
    }

    return unpacked.root;
}

pub fn getNixHashes(
    self: *Dep,
    io: std.Io,
    alloc: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    tmpdir: *TmpDir,
    options: nixpkg.Options,
) !void {
    if (self.nix) |_| return;

    const path = if (self.local) |local| local.path else null;

    const url = self.fetched_url.?;
    const hashes = try nixpkg.fetch(
        io,
        alloc,
        tmpdir,
        env_map,
        path,
        url,
        self.zig_hash,
        .{
            .nix_prefetch_git = options.nix_prefetch_git,
            .nix_prefetch_url = options.nix_prefetch_url,
        },
    );
    self.nix = .{
        .b64 = hashes.b64,
        .hex = hashes.hex,
        .unpack = hashes.unpack,
    };
}

test "the name and URL written out do not depend on the order they were found in" {
    const alloc = std.testing.allocator;

    const archive = "https://example.invalid/b.tar.gz";
    const other_archive = "https://example.invalid/a.tar.gz";
    const git = "git+https://example.invalid/a.git#0123";

    for ([_][3][]const u8{
        .{ git, archive, other_archive },
        .{ archive, other_archive, git },
        .{ other_archive, git, archive },
    }, [_][3][]const u8{
        .{ "zeta", "alpha", "mu" },
        .{ "mu", "zeta", "alpha" },
        .{ "alpha", "mu", "zeta" },
    }) |urls, names| {
        var dep: Dep = undefined;
        try dep.init(alloc, names[0], urls[0], "pkg-0.0.0-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        defer dep.deinit(alloc);

        // `addName` and `addUrl` warn about the duplicate, and the test
        // runner would count that as a failure.
        for (urls[1..]) |url| try dep.urls.put(alloc, try alloc.dupe(u8, url), true);
        for (names[1..]) |name| try dep.names.put(alloc, try alloc.dupe(u8, name), true);

        // An archive beats a git repository even when it sorts later.
        try std.testing.expectEqualStrings(other_archive, dep.getUrl());
        try std.testing.expectEqualStrings("alpha", dep.getName());
    }
}
