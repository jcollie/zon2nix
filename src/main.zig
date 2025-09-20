const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const zon2nix = @import("zon2nix");

pub const ZigVersion = enum {
    @"14",
    @"15",
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

fn getParam(name: []const u8, arg: []const u8, it: *std.process.ArgIterator) !?[]const u8 {
    if (!std.mem.startsWith(u8, arg, name)) return null;
    const rest = arg[name.len..];
    if (std.mem.startsWith(u8, rest, "=")) return rest[1..];
    return it.next() orelse return error.MissingPath;
}

pub fn main() !void {
    const alloc, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    zon2nix.zig.init(alloc);
    defer zon2nix.zig.deinit(alloc);

    // stack of paths to build.zig.zon files that we need to visit
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| {
            alloc.free(path);
        }
        paths.deinit(alloc);
    }

    var zig_version: ZigVersion = .@"14";

    var txt_out: ?[]const u8 = null;
    defer if (txt_out) |f| alloc.free(f);

    var nix_out: ?[]const u8 = null;
    defer if (nix_out) |f| alloc.free(f);

    var json_out: ?[]const u8 = null;
    defer if (json_out) |f| alloc.free(f);

    var flatpak_out: ?[]const u8 = null;
    defer if (flatpak_out) |f| alloc.free(f);

    {
        var it = try std.process.ArgIterator.initWithAllocator(alloc);
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

            if (std.mem.eql(u8, arg, "--14")) {
                zig_version = .@"14";
                continue;
            }

            if (std.mem.eql(u8, arg, "--15")) {
                zig_version = .@"15";
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

            try paths.append(alloc, try alloc.dupe(u8, arg));
        }
    }

    // if the user didn't supply any paths on the command line, look for
    // build.zig.zon in the current directory
    if (paths.items.len == 0) {
        log.warn("no paths specified on the command line, looking for build.zig.zon in the current directory", .{});
        try paths.append(alloc, try alloc.dupe(u8, "build.zig.zon"));
    }

    // keep track of paths that we've already processed
    var paths_seen: std.StringArrayHashMapUnmanaged(bool) = .empty;
    defer {
        var it = paths_seen.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }
        paths_seen.deinit(alloc);
    }

    // keep track of URLs that we've already visited
    var urls_seen: std.StringArrayHashMapUnmanaged(bool) = .empty;
    defer {
        var it = urls_seen.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }
        urls_seen.deinit(alloc);
    }

    // map zig hash -> URL
    var urls: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer {
        var it = urls.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        urls.deinit(alloc);
    }

    // map zig hash -> dependency name
    var names: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer {
        var it = names.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        names.deinit(alloc);
    }

    // map zig hash -> nix hash
    var nix_hashes: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer {
        var it = nix_hashes.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        nix_hashes.deinit(alloc);
    }

    // map zig hash -> sha256 hash
    var sha256_hashes: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer {
        var it = sha256_hashes.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        sha256_hashes.deinit(alloc);
    }

    // loop through all the paths
    while (paths.pop()) |path| {
        defer alloc.free(path);

        // if we've already processed a path don't do it again
        if (paths_seen.contains(path)) continue;
        try paths_seen.put(alloc, try alloc.dupe(u8, path), true);

        log.debug("reading {s}", .{path});
        var file = std.fs.cwd().openFile(
            path,
            .{ .mode = .read_only },
        ) catch |err| switch (err) {
            error.FileNotFound => {
                log.debug("{s} not found", .{path});
                continue;
            },
            else => |e| return e,
        };
        defer file.close();

        var buffer: [1024]u8 = undefined;
        var reader = file.reader(&buffer);

        var build_zig_zon: zon2nix.BuildZigZon = try .init(alloc, &reader.interface);
        defer build_zig_zon.deinit();

        var it = build_zig_zon.dependencies.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const dep = entry.value_ptr;

            if (dep.url) |url| {
                if (urls_seen.contains(url)) continue;
                try urls_seen.put(alloc, try alloc.dupe(u8, url), true);

                const uri = try std.Uri.parse(url);
                if (std.mem.eql(u8, uri.scheme, "file")) {
                    log.err("file:// urls are not supported: {s} {s}", .{ name, url });
                    continue;
                }

                const zig_hash = dep.hash orelse {
                    log.err("hash is missing from {s} in {s}", .{ name, path });
                    continue;
                };

                if (urls.get(zig_hash)) |old_url| {
                    if (!std.mem.eql(u8, old_url, url)) {
                        log.warn("zig hash {s} downloaded from multiple urls:", .{zig_hash});
                        log.warn("  1st url: {s}", .{old_url});
                        log.warn("  2nd url: {s}", .{url});
                    }
                } else {
                    try urls.put(alloc, try alloc.dupe(u8, zig_hash), try alloc.dupe(u8, url));
                }
                if (names.get(zig_hash)) |old_name| {
                    if (!std.mem.eql(u8, old_name, name)) {
                        log.warn("zig hash {s} referenced by multiple names:", .{zig_hash});
                        log.warn("  1st name: {s}", .{old_name});
                        log.warn("  2nd name: {s}", .{name});
                    }
                } else {
                    try names.put(alloc, try alloc.dupe(u8, zig_hash), try alloc.dupe(u8, name));
                }

                {
                    const cache_path = try zon2nix.zig.fetch(alloc, url, zig_hash, .{ .zig = options.zig });
                    defer alloc.free(cache_path);

                    {
                        const new_path = try std.fs.path.join(
                            alloc,
                            &.{
                                cache_path,
                                "build.zig.zon",
                            },
                        );
                        errdefer alloc.free(new_path);

                        log.debug("adding to paths: {s}", .{new_path});
                        try paths.append(
                            alloc,
                            new_path,
                        );
                    }
                }

                // if we're not outputting a nix derivation or json, skip fetching the hash
                if (nix_out != null or json_out != null or flatpak_out != null) {
                    const nix_hash, const sha256_hash = try zon2nix.nix.fetch(
                        alloc,
                        url,
                        .{ .nix_prefetch_git = options.nix_prefetch_git },
                    );
                    defer {
                        alloc.free(nix_hash);
                        alloc.free(sha256_hash);
                    }
                    log.debug("   nix hash for {s} is {s}", .{ zig_hash, nix_hash });
                    log.debug("sha256 hash for {s} is {s}", .{ zig_hash, sha256_hash });
                    if (nix_hashes.get(zig_hash)) |old_nix_hash| {
                        if (!std.mem.eql(u8, old_nix_hash, nix_hash)) {
                            log.err("zig hash {s} resulted in different nix hashes:", .{zig_hash});
                            log.err("  1st nix hash: {s}", .{old_nix_hash});
                            log.err("  2nd nix hash: {s}", .{nix_hash});
                            return error.NixHashMismatch;
                        }
                    } else {
                        try nix_hashes.put(
                            alloc,
                            try alloc.dupe(u8, zig_hash),
                            try alloc.dupe(u8, nix_hash),
                        );
                    }
                    if (sha256_hashes.get(zig_hash)) |old_sha256_hash| {
                        if (!std.mem.eql(u8, old_sha256_hash, sha256_hash)) {
                            log.err("zig hash {s} resulted in different sha256 hashes:", .{zig_hash});
                            log.err("  1st nix hash: {s}", .{old_sha256_hash});
                            log.err("  2nd nix hash: {s}", .{sha256_hash});
                            return error.Sha256HashMismatch;
                        }
                    } else {
                        try sha256_hashes.put(
                            alloc,
                            try alloc.dupe(u8, zig_hash),
                            try alloc.dupe(u8, sha256_hash),
                        );
                    }
                }
            }

            if (dep.path) |dep_path| {
                const dir = try std.fs.cwd().openDir(
                    std.fs.path.dirname(path) orelse ".",
                    .{},
                );
                const full_path = try dir.realpathAlloc(alloc, dep_path);
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

    var list: std.ArrayList([]const u8) = .empty;
    // don't deallocate the actual entries as they will be
    // deallocated with the hash maps
    defer list.deinit(alloc);

    var it = urls.iterator();
    while (it.next()) |entry| {
        try list.append(alloc, entry.key_ptr.*);
    }

    if (txt_out) |path| {
        // output a list of URLs
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var buffer: [64]u8 = undefined;
        var writer = file.writer(&buffer);

        std.mem.sort([]const u8, list.items, &urls, sortByMap);

        for (list.items) |zig_hash| {
            const url = urls.get(zig_hash) orelse unreachable;
            try writer.interface.print("{s}\n", .{url});
        }

        try writer.interface.flush();
    }

    if (nix_out) |path| {
        // output a Nix derivation

        const StreamToFile = struct {
            fn streamer(in: *std.Io.Reader, out: *std.Io.Writer) !void {
                _ = try in.streamRemaining(out);
                try out.flush();
            }
        };

        std.mem.sort([]const u8, list.items, &names, sortByMap);

        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var file_buffer: [64]u8 = undefined;
        var file_writer = file.writer(&file_buffer);

        var nixfmt: std.process.Child = .init(&.{options.nixfmt}, alloc);
        nixfmt.stdin_behavior = .Pipe;
        nixfmt.stdout_behavior = .Pipe;

        try nixfmt.spawn();
        errdefer _ = nixfmt.kill() catch {};

        const stdin = nixfmt.stdin orelse return error.ExecFailed;
        var stdin_buf: [1024]u8 = undefined;
        var stdin_writer = stdin.writer(&stdin_buf);

        const stdout = nixfmt.stdout orelse return error.ExecFailed;
        var stdout_buf: [1024]u8 = undefined;
        var stdout_reader = stdout.reader(&stdout_buf);

        const stream_to_file = try std.Thread.spawn(
            .{},
            StreamToFile.streamer,
            .{ &stdout_reader.interface, &file_writer.interface },
        );

        try stdin_writer.interface.writeAll(switch (zig_version) {
            .@"14" => @embedFile("header_0_14.nix"),
            .@"15" => @embedFile("header_0_15.nix"),
        });

        for (list.items) |zig_hash| {
            const name = names.get(zig_hash) orelse return error.MissingName;
            const url = urls.get(zig_hash) orelse return error.MissingUrl;
            const nix_hash = nix_hashes.get(zig_hash) orelse return error.MissingNixHash;

            try stdin_writer.interface.print(
                \\  {{
                \\    name = "{[zig_hash]s}";
                \\    path = fetchZigArtifact {{
                \\      name = "{[name]s}";
                \\      url = "{[url]s}";
                \\      hash = "{[nix_hash]s}";
                \\    }};
                \\  }}
                \\
            , .{
                .zig_hash = zig_hash,
                .name = name,
                .url = url,
                .nix_hash = nix_hash,
            });
        }

        try stdin_writer.interface.writeAll("]\n");
        try stdin_writer.interface.flush();
        stdin.close();

        stream_to_file.join();
    }

    if (json_out) |path| {
        // output a json object
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var buffer: [64]u8 = undefined;
        var writer = file.writer(&buffer);

        std.mem.sort([]const u8, list.items, &names, sortByMap);

        try writer.interface.writeAll("{\n");

        for (list.items, 0..) |zig_hash, index| {
            const name = names.get(zig_hash) orelse return error.MissingName;
            const url = urls.get(zig_hash) orelse return error.MissingUrl;
            const nix_hash = nix_hashes.get(zig_hash) orelse return error.MissingNixHash;

            try writer.interface.print(
                \\  "{[zig_hash]s}": {{
                \\    "name": "{[name]s}",
                \\    "url": "{[url]s}",
                \\    "hash": "{[nix_hash]s}"
                \\  }}{[comma]s}
                \\
            , .{
                .zig_hash = zig_hash,
                .name = name,
                .url = url,
                .nix_hash = nix_hash,
                .comma = if (index < list.items.len - 1) "," else "",
            });
        }

        try writer.interface.writeAll("}\n");
        try writer.interface.flush();
    }

    if (flatpak_out) |path| {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var buffer: [64]u8 = undefined;
        var writer = file.writer(&buffer);

        std.mem.sort([]const u8, list.items, &names, sortByMap);
        try writer.interface.writeAll("[\n");

        for (list.items, 0..) |zig_hash, index| {
            const url = urls.get(zig_hash) orelse return error.MissingUrl;
            const sha256_hash = sha256_hashes.get(zig_hash) orelse return error.MissingSha256Hash;

            if (!std.mem.startsWith(u8, url, "git+")) {
                try writer.interface.print(
                    \\  {{
                    \\    "type": "archive",
                    \\    "url": "{[url]s}",
                    \\    "dest": "vendor/p/{[zig_hash]s}",
                    \\    "sha256": "{[sha256_hash]s}"
                    \\  }}{[comma]s}
                    \\
                , .{
                    .zig_hash = zig_hash,
                    .url = url,
                    .sha256_hash = sha256_hash,
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
                    .zig_hash = zig_hash,
                    .url = new_url,
                    .commit = commit,
                    .comma = if (index < list.items.len - 1) "," else "",
                });
            }
        }

        try writer.interface.writeAll("]\n");
        try writer.interface.flush();
    }
}

fn sortByKey(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn sortByMap(map: *const std.StringArrayHashMapUnmanaged([]const u8), lhs: []const u8, rhs: []const u8) bool {
    const a = map.get(lhs) orelse unreachable;
    const b = map.get(rhs) orelse unreachable;
    return std.mem.lessThan(u8, a, b);
}
