const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const zon2nix = @import("zon2nix");

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
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
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
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |path| {
            alloc.free(path);
        }
        paths.deinit(alloc);
    }

    var txt_out: ?[]const u8 = null;
    defer if (txt_out) |f| alloc.free(f);

    var nix_out: ?[]const u8 = null;
    defer if (nix_out) |f| alloc.free(f);

    var json_out: ?[]const u8 = null;
    defer if (json_out) |f| alloc.free(f);

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
            if (std.mem.eql(u8, arg, "--txt")) {
                txt_out = try alloc.dupe(u8, it.next() orelse return error.MissingPath);
                continue;
            }
            if (std.mem.eql(u8, arg[0..6], "--txt=")) {
                if (arg.len == 6) return error.MissingPath;
                txt_out = try alloc.dupe(u8, arg[6..]);
                continue;
            }
            if (std.mem.eql(u8, arg, "--nix")) {
                nix_out = try alloc.dupe(u8, it.next() orelse return error.MissingPath);
                continue;
            }
            if (std.mem.eql(u8, arg[0..6], "--nix=")) {
                if (arg.len == 6) return error.MissingPath;
                nix_out = try alloc.dupe(u8, arg[6..]);
                continue;
            }
            if (std.mem.eql(u8, arg, "--json")) {
                json_out = try alloc.dupe(u8, it.next() orelse return error.MissingPath);
                continue;
            }
            if (std.mem.eql(u8, arg[0..7], "--json=")) {
                if (arg.len == 7) return error.MissingPath;
                json_out = try alloc.dupe(u8, arg[7..]);
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

        var build_zig_zon: zon2nix.BuildZigZon = undefined;
        try build_zig_zon.init(alloc, file.reader().any());
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

                const cache_path = try zon2nix.zig.fetch(alloc, url, zig_hash, .{ .zig = options.zig });
                defer alloc.free(cache_path);

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

                // if we're not outputting a nix derivation or json, skip fetching the hash
                if (nix_out != null or json_out != null) {
                    const nix_hash = try zon2nix.nix.fetch(alloc, url, .{ .nix_prefetch_git = options.nix_prefetch_git });
                    defer alloc.free(nix_hash);
                    log.debug("nix hash for {s} is {s}", .{ zig_hash, nix_hash });
                    if (nix_hashes.get(zig_hash)) |old_nix_hash| {
                        if (!std.mem.eql(u8, old_nix_hash, nix_hash)) {
                            log.err("zig hash {s} resulted in different nix hashes:", .{zig_hash});
                            log.err("  1st nix hash: {s}", .{old_nix_hash});
                            log.err("  2nd nix hash: {s}", .{nix_hash});
                            return error.NixHashMismatch;
                        }
                    } else {
                        try nix_hashes.put(alloc, try alloc.dupe(u8, zig_hash), try alloc.dupe(u8, nix_hash));
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

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
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
        const writer = file.writer();

        std.mem.sort([]const u8, list.items, &urls, sortByMap);

        for (list.items) |zig_hash| {
            const url = urls.get(zig_hash) orelse unreachable;
            try writer.print("{s}\n", .{url});
        }
    }

    if (nix_out) |path| {
        // output a Nix derivation
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        const writer = file.writer();

        std.mem.sort([]const u8, list.items, &names, sortByMap);

        try writer.writeAll(@embedFile("header.nix"));

        for (list.items) |zig_hash| {
            const name = names.get(zig_hash) orelse return error.MissingName;
            const url = urls.get(zig_hash) orelse return error.MissingUrl;
            const nix_hash = nix_hashes.get(zig_hash) orelse return error.MissingNixHash;

            try writer.print(
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

        try writer.writeAll("]\n");
    }

    if (json_out) |path| {
        // output a json object
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        const writer = file.writer();

        std.mem.sort([]const u8, list.items, &names, sortByMap);

        try writer.writeAll("{\n");

        for (list.items, 0..) |zig_hash, index| {
            const name = names.get(zig_hash) orelse return error.MissingName;
            const url = urls.get(zig_hash) orelse return error.MissingUrl;
            const nix_hash = nix_hashes.get(zig_hash) orelse return error.MissingNixHash;

            try writer.print(
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

        try writer.writeAll("}\n");
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
