const std = @import("std");

const log = std.log.scoped(.zig);

var version_string: []const u8 = undefined;
var version: std.SemanticVersion = undefined;
var global_cache_dir: []const u8 = undefined;
var root_pkg_dir: []const u8 = undefined;

pub const Options = struct {};

pub fn init(io: std.Io, alloc: std.mem.Allocator, _: Options) !void {
    const stdout = stdout: {
        const zig_env = std.process.run(alloc, io, .{
            .argv = &.{
                "zig",
                "env",
            },
        }) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    log.err("unable to execute zig, is it in your PATH?", .{});
                    return error.GettingZigEnv;
                },
                else => |e| return e,
            }
        };
        defer {
            alloc.free(zig_env.stdout);
            alloc.free(zig_env.stderr);
        }

        switch (zig_env.term) {
            .exited => |status| {
                if (status == 0) break :stdout try alloc.dupeZ(u8, zig_env.stdout);
                return error.GettingZigEnv;
            },
            else => {
                return error.GettingZigEnv;
            },
        }
    };
    defer alloc.free(stdout);

    const Env = struct {
        version: ?[]const u8,
        global_cache_dir: ?[]const u8,
    };

    if (std.mem.startsWith(u8, stdout, ".{")) {
        const parsed = try std.zon.parse.fromSliceAlloc(
            Env,
            alloc,
            stdout,
            null,
            .{ .ignore_unknown_fields = true },
        );
        defer std.zon.parse.free(alloc, parsed);
        version_string = try alloc.dupe(u8, parsed.version orelse return error.GettingZigEnv);
        version = try .parse(version_string);
        global_cache_dir = try alloc.dupe(u8, parsed.global_cache_dir orelse return error.GettingZigEnv);
    } else {
        const parsed = try std.json.parseFromSlice(
            Env,
            alloc,
            stdout,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        version_string = try alloc.dupe(u8, parsed.value.version orelse return error.GettingZigEnv);
        version = try .parse(version_string);
        global_cache_dir = try alloc.dupe(u8, parsed.value.global_cache_dir orelse return error.GettingZigEnv);
    }
    errdefer alloc.free(version_string);
    errdefer alloc.free(global_cache_dir);

    const cwd: std.Io.Dir = .cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try cwd.realPathFile(io, ".", &buf);
    root_pkg_dir = try std.fs.path.join(alloc, &.{ buf[0..len], "zig-pkg" });
}

pub fn deinit(alloc: std.mem.Allocator) void {
    alloc.free(version_string);
    alloc.free(global_cache_dir);
    alloc.free(root_pkg_dir);
}

pub fn fetch(io: std.Io, alloc: std.mem.Allocator, url: []const u8, expected_hash: []const u8, _: Options) ![]const u8 {
    const cache_path = cache_path: {
        const sixteen = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0, .pre = "dev" };
        if (version.order(sixteen) == .lt) {
            break :cache_path try std.fs.path.join(alloc, &.{ global_cache_dir, "p", expected_hash });
        } else {
            break :cache_path try std.fs.path.join(alloc, &.{ root_pkg_dir, expected_hash });
        }
    };
    errdefer alloc.free(cache_path);

    // if the cache dir already exists don't download it again
    check: {
        std.Io.Dir.accessAbsolute(io, cache_path, .{}) catch break :check;
        return cache_path;
    }

    const stdout = zig_fetch: {
        var stdout: std.Io.Writer.Allocating = .init(alloc);
        defer stdout.deinit();

        log.info("zig fetch {s}", .{url});

        var zig_fetch = try std.process.spawn(
            io,
            .{
                .argv = &.{ "zig", "fetch", url },
                .stderr = .ignore,
                .stdout = .pipe,
                .stdin = .ignore,
            },
        );
        errdefer zig_fetch.kill(io);

        if (zig_fetch.stdout) |stdout_file| {
            var buffer: [1024]u8 = undefined;
            var stdout_reader = stdout_file.reader(io, &buffer);
            const reader = &stdout_reader.interface;
            _ = try reader.streamRemaining(&stdout.writer);
        }

        const term = zig_fetch.wait(io) catch |err| {
            return err;
        };
        switch (term) {
            .exited => |status| {
                if (status == 0) break :zig_fetch try stdout.toOwnedSlice();
                return error.GettingZigDep;
            },
            else => {
                return error.GettingZigDep;
            },
        }
    };
    defer alloc.free(stdout);

    const found_hash = std.mem.trim(u8, stdout, &std.ascii.whitespace);

    if (!std.mem.eql(u8, expected_hash, found_hash)) {
        log.err("expected: {s}", .{expected_hash});
        log.err("actual:   {s}", .{found_hash});
        return error.HashMismatch;
    }

    // insurance
    log.warn("cache_path: {s}", .{cache_path});
    try std.Io.Dir.accessAbsolute(io, cache_path, .{});

    return cache_path;
}
