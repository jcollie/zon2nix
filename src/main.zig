const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const zon2nix = @import("zon2nix");

pub const ZigVersion = enum {
    @"15",
    @"16",
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

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;

    const cwd: std.Io.Dir = .cwd();

    // stack of paths to build.zig.zon files that we need to visit
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| {
            alloc.free(path);
        }
        paths.deinit(alloc);
    }

    var zig_version: ZigVersion = .@"15";

    var txt_out: ?[]const u8 = null;
    defer if (txt_out) |f| alloc.free(f);

    var nix_out: ?[]const u8 = null;
    defer if (nix_out) |f| alloc.free(f);

    var json_out: ?[]const u8 = null;
    defer if (json_out) |f| alloc.free(f);

    var flatpak_out: ?[]const u8 = null;
    defer if (flatpak_out) |f| alloc.free(f);

    {
        var it = try init.minimal.args.iterateAllocator(alloc);
        defer it.deinit();

        // skip program name
        _ = it.next();

        while (it.next()) |arg| {
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

            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const len = try cwd.realPathFile(io, arg, &buf);
            try paths.append(alloc, try alloc.dupe(u8, buf[0..len]));
        }
    }

    // if the user didn't supply any paths on the command line, look for
    // build.zig.zon in the current directory
    if (paths.items.len == 0) {
        log.warn("no paths specified on the command line, looking for build.zig.zon in the current directory", .{});
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try cwd.realPathFile(io, "build.zig.zon", &buf);
        try paths.append(alloc, try alloc.dupe(u8, buf[0..len]));
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

    // loop through all the paths
    while (paths.pop()) |path| {
        defer alloc.free(path);

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

        var build_zig_zon: zon2nix.BuildZigZon = try .init(alloc, &reader.interface);
        defer build_zig_zon.deinit();

        var it = build_zig_zon.dependencies.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const zon_dep = entry.value_ptr;

            if (zon_dep.url) |url| {
                const zig_hash = zon_dep.hash orelse {
                    log.err("hash is missing from {s} in {s}", .{ name, path });
                    continue;
                };

                const dep = try deps.get(io, alloc, name, url, zig_hash);
                build_zig_zon: {
                    const new_path = try dep.getBuildZigZon(io, alloc, &deps.zig, &deps.tmpdir) orelse break :build_zig_zon;
                    errdefer alloc.free(new_path);

                    log.debug("adding to paths: {s}", .{new_path});
                    try paths.append(
                        alloc,
                        new_path,
                    );
                }

                // if we're not outputting a nix derivation or json, skip fetching the hash
                if (nix_out != null or json_out != null or flatpak_out != null) {
                    try dep.getNixHashes(
                        io,
                        alloc,
                        init.environ_map,
                        &deps.tmpdir,
                        .{
                            .nix_prefetch_git = options.nix_prefetch_git,
                            .nix_prefetch_url = options.nix_prefetch_url,
                        },
                    );
                }
            }

            if (zon_dep.path) |dep_path| {
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
                        "build.zig.zon",
                    },
                );
                log.debug("adding to paths: {s}", .{new_path});
                try paths.append(
                    alloc,
                    new_path,
                );
            }
        }
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
                .argv = &.{options.nixfmt},
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

        try stdin_writer.interface.writeAll(switch (zig_version) {
            .@"15" => @embedFile("header_0_15.nix"),
            .@"16" => @embedFile("header_0_16.nix"),
        });

        for (list.items) |dep| {
            const nix = dep.nix orelse return error.MissingNixHash;

            try stdin_writer.interface.print(
                \\  {{
                \\    name = "{[zig_hash]s}";
                \\    path = fetchZigArtifact {{
                \\      name = "{[name]s}";
                \\      url = "{[url]s}";
                \\      hash = "{[nix_hash]s}";
                \\      unpack = {[unpack]};
                \\    }};
                \\  }}
                \\
            , .{
                .zig_hash = dep.zig_hash,
                .name = dep.getName(),
                .url = dep.getUrl(),
                .nix_hash = nix.b64,
                .unpack = nix.unpack,
            });
        }

        try stdin_writer.interface.writeAll("]\n");
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
            const nix = dep.nix orelse return error.MissingNixHash;

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
                .nix_hash = nix.b64,
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
                const uri = try std.Uri.parse(url[4..]);
                const commit = commit: {
                    if (uri.fragment) |fragment| {
                        var buf: std.Io.Writer.Allocating = .init(alloc);
                        defer buf.deinit();
                        try fragment.formatFragment(&buf.writer);
                        break :commit try buf.toOwnedSlice();
                    }
                    log.warn("can't find commit in url {s}", .{url});
                    continue;
                };
                defer alloc.free(commit);
                const new_url = new_url: {
                    var buf: std.Io.Writer.Allocating = .init(alloc);
                    defer buf.deinit();
                    try uri.writeToStream(&buf.writer, .{
                        .scheme = true,
                        .authority = true,
                        .path = true,
                    });
                    break :new_url try buf.toOwnedSlice();
                };
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
