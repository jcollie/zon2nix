const std = @import("std");

const log = std.log.scoped(.zig);

var global_cache_dir: ?[]const u8 = null;

pub const Options = struct {
    zig: []const u8 = "zig",
};

pub fn init(_: std.mem.Allocator) void {}

pub fn deinit(alloc: std.mem.Allocator) void {
    if (global_cache_dir) |dir| alloc.free(dir);
}

pub fn getGlobalCacheDir(alloc: std.mem.Allocator, options: Options) ![]const u8 {
    if (global_cache_dir) |cache_dir| return cache_dir;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(alloc);

    get_zig_env: {
        var stderr: std.ArrayList(u8) = .empty;
        defer stderr.deinit(alloc);

        var zig_env = std.process.Child.init(&.{ options.zig, "env" }, alloc);
        zig_env.stdout_behavior = .Pipe;
        zig_env.stderr_behavior = .Pipe;
        try zig_env.spawn();
        try zig_env.collectOutput(alloc, &stdout, &stderr, std.math.maxInt(u16));

        const term = zig_env.wait() catch |err| {
            return err;
        };

        switch (term) {
            .Exited => |status| {
                if (status == 0) break :get_zig_env;
                return error.GettingZigEnv;
            },
            else => {
                return error.GettingZigEnv;
            },
        }
    }

    const Env = struct {
        global_cache_dir: ?[]const u8,
    };

    const cache_dir = if (std.mem.startsWith(u8, stdout.items, ".{")) zon: {
        try stdout.append(alloc, '\x00');
        const parsed = try std.zon.parse.fromSlice(
            Env,
            alloc,
            stdout.items[0 .. stdout.items.len - 1 :0],
            null,
            .{ .ignore_unknown_fields = true },
        );
        defer std.zon.parse.free(alloc, parsed);
        const cache_dir = try alloc.dupe(u8, parsed.global_cache_dir orelse return error.GettingZigEnv);
        break :zon cache_dir;
    } else json: {
        const parsed = try std.json.parseFromSlice(
            Env,
            alloc,
            stdout.items,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        const cache_dir = try alloc.dupe(
            u8,
            parsed.value.global_cache_dir orelse return error.GettingZigEnv,
        );
        break :json cache_dir;
    };

    global_cache_dir = cache_dir;

    log.debug("global cache dir: {s}", .{cache_dir});

    return cache_dir;
}

pub fn fetch(alloc: std.mem.Allocator, url: []const u8, expected_hash: []const u8, options: Options) ![]const u8 {
    const cache_dir = try getGlobalCacheDir(alloc, options);
    const cache_path = try std.fs.path.join(alloc, &.{ cache_dir, "p", expected_hash });
    errdefer alloc.free(cache_path);

    // if the cache dir already exists don't download it again
    check: {
        std.fs.accessAbsolute(cache_path, .{}) catch {
            break :check;
        };
        return cache_path;
    }

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(alloc);

    zig_fetch: {
        log.info("zig fetch {s}", .{url});
        var stderr: std.ArrayList(u8) = .empty;
        defer stderr.deinit(alloc);

        var zig_fetch = std.process.Child.init(
            &.{ options.zig, "fetch", url },
            alloc,
        );
        zig_fetch.stdout_behavior = .Pipe;
        zig_fetch.stderr_behavior = .Pipe;
        try zig_fetch.spawn();
        try zig_fetch.collectOutput(
            alloc,
            &stdout,
            &stderr,
            std.math.maxInt(u16),
        );

        const term = zig_fetch.wait() catch |err| {
            return err;
        };
        switch (term) {
            .Exited => |status| {
                if (status == 0) break :zig_fetch;
                return error.GettingZigDep;
            },
            else => {
                return error.GettingZigDep;
            },
        }
    }

    const found_hash = std.mem.trim(u8, stdout.items, &std.ascii.whitespace);

    if (!std.mem.eql(u8, expected_hash, found_hash)) {
        log.err("expected: {s}", .{expected_hash});
        log.err("actual:   {s}", .{found_hash});
        return error.HashMismatch;
    }

    // insurance
    try std.fs.accessAbsolute(cache_path, .{});

    return cache_path;
}
