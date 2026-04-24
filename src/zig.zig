const std = @import("std");

const log = std.log.scoped(.zig);

const TmpDir = @import("TmpDir.zig");

var version_string: []const u8 = undefined;
var version: std.SemanticVersion = undefined;
var tmpdir: TmpDir = undefined;
var global_cache_dir: []const u8 = undefined;
var root_pkg_dir: []const u8 = undefined;

pub const Options = struct {};

pub fn init(io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map, _: Options) !void {
    try tmpdir.init(io, alloc, env_map);
    errdefer tmpdir.cleanup(io, alloc);

    {
        // workaround https://codeberg.org/ziglang/zig/issues/31866
        // https://github.com/Cloudef/zig2nix/issues/54
        const build_zig = try tmpdir.dir.createFile(io, "build.zig", .{});
        defer build_zig.close(io);
    }

    {
        // workaround https://codeberg.org/ziglang/zig/issues/31964
        try tmpdir.dir.createDir(io, "tmp", .default_dir);
    }

    const stdout = stdout: {
        const zig_env = std.process.run(alloc, io, .{
            .argv = &.{
                "zig",
                "env",
            },
            .cwd = .{
                .dir = tmpdir.dir,
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
    }
    errdefer alloc.free(version_string);

    global_cache_dir = try alloc.dupe(u8, tmpdir.path);
    errdefer alloc.free(global_cache_dir);
    log.debug("global_cache_dir: {s}", .{global_cache_dir});

    root_pkg_dir = try std.fs.path.join(alloc, &.{ tmpdir.path, "zig-pkg" });
    log.debug("root_pkg_dir: {s}", .{root_pkg_dir});
}

pub fn deinit(io: std.Io, alloc: std.mem.Allocator) void {
    alloc.free(version_string);
    alloc.free(global_cache_dir);
    alloc.free(root_pkg_dir);
    tmpdir.cleanup(io, alloc);
}

const sixteen = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0, .pre = "dev" };

pub fn isSixteen() bool {
    return version.order(sixteen) != .lt;
}

const Paths = std.meta.Tuple(&.{ []const u8, []const u8 });
pub fn fetch(io: std.Io, alloc: std.mem.Allocator, url: []const u8, expected_hash: []const u8, _: Options) !Paths {
    const local_path, const global_path = paths: {
        if (isSixteen()) {
            const global_filename = try std.fmt.allocPrint(alloc, "{s}.tar.gz", .{expected_hash});
            defer alloc.free(global_filename);
            break :paths .{
                try std.fs.path.join(alloc, &.{ root_pkg_dir, expected_hash }),
                try std.fs.path.join(alloc, &.{ global_cache_dir, "p", global_filename }),
            };
        } else {
            break :paths .{
                try std.fs.path.join(alloc, &.{ global_cache_dir, "p", expected_hash }),
                try std.fs.path.join(alloc, &.{ global_cache_dir, "p", expected_hash }),
            };
        }
    };
    errdefer alloc.free(local_path);
    errdefer alloc.free(global_path);
    log.debug("local_path: {s}", .{local_path});
    log.debug("global_path: {s}", .{global_path});

    // if the cache dir already exists don't download it again
    check: {
        std.Io.Dir.accessAbsolute(io, local_path, .{}) catch break :check;
        std.Io.Dir.accessAbsolute(io, global_path, .{}) catch break :check;
        return .{ local_path, global_path };
    }

    const stdout = zig_fetch: {
        var stdout: std.Io.Writer.Allocating = .init(alloc);
        defer stdout.deinit();

        log.info("zig fetch {s}", .{url});

        const zig_fetch = try std.process.run(
            alloc,
            io,
            .{
                .argv = &.{ "zig", "fetch", "--global-cache-dir", global_cache_dir, url },
                .cwd = .{
                    .dir = tmpdir.dir,
                },
            },
        );
        defer {
            alloc.free(zig_fetch.stdout);
            alloc.free(zig_fetch.stderr);
        }

        switch (zig_fetch.term) {
            .exited => |status| {
                if (status == 0) break :zig_fetch try alloc.dupe(u8, zig_fetch.stdout);
                var it = std.mem.splitScalar(u8, zig_fetch.stderr, '\n');
                while (it.next()) |line| {
                    log.err("fetching zig dep: {s}", .{line});
                }
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
    try std.Io.Dir.accessAbsolute(io, local_path, .{});
    try std.Io.Dir.accessAbsolute(io, global_path, .{});

    return .{ local_path, global_path };
}
