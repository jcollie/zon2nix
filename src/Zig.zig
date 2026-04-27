const Zig = @This();

const std = @import("std");

const log = std.log.scoped(.zig);

const TmpDir = @import("TmpDir.zig");

version_string: []const u8,
version: std.SemanticVersion,
global_cache_dir: []const u8,
root_pkg_dir: []const u8,

pub const Options = struct {
    zig: []const u8 = "zig",
};

pub fn init(self: *Zig, io: std.Io, alloc: std.mem.Allocator, tmpdir: *TmpDir, options: Options) !void {
    {
        // workaround https://codeberg.org/ziglang/zig/issues/31866
        // https://github.com/Cloudef/zig2nix/issues/54
        const build_zig = try tmpdir.createFile(io, "build.zig", .{});
        defer build_zig.close(io);
    }

    const stdout = stdout: {
        const zig_env = std.process.run(alloc, io, .{
            .argv = &.{
                options.zig,
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

    const format: enum { zon, json } = if (std.mem.startsWith(u8, stdout, ".{")) .zon else .json;

    const version_string = switch (format) {
        .zon => zon: {
            const parsed = try std.zon.parse.fromSliceAlloc(
                Env,
                alloc,
                stdout,
                null,
                .{ .ignore_unknown_fields = true },
            );
            defer std.zon.parse.free(alloc, parsed);
            break :zon try alloc.dupe(u8, parsed.version orelse return error.GettingZigEnv);
        },
        .json => json: {
            const parsed = try std.json.parseFromSlice(
                Env,
                alloc,
                stdout,
                .{ .ignore_unknown_fields = true },
            );
            defer parsed.deinit();

            break :json try alloc.dupe(u8, parsed.value.version orelse return error.GettingZigEnv);
        },
    };
    errdefer alloc.free(version_string);
    const version: std.SemanticVersion = try .parse(version_string);

    const global_cache_dir = try alloc.dupe(u8, tmpdir.path);
    errdefer alloc.free(global_cache_dir);
    log.debug("global_cache_dir: {s}", .{global_cache_dir});

    const root_pkg_dir = try std.fs.path.join(alloc, &.{ tmpdir.path, "zig-pkg" });
    errdefer alloc.free(root_pkg_dir);

    log.debug("root_pkg_dir: {s}", .{root_pkg_dir});

    self.* = .{
        .version_string = version_string,
        .version = version,
        .global_cache_dir = global_cache_dir,
        .root_pkg_dir = root_pkg_dir,
    };
}

pub fn deinit(self: *Zig, alloc: std.mem.Allocator) void {
    alloc.free(self.version_string);
    alloc.free(self.global_cache_dir);
    alloc.free(self.root_pkg_dir);
}

const sixteen = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0, .pre = "dev" };

pub fn isSixteen(self: *Zig) bool {
    return self.version.order(sixteen) != .lt;
}

const Paths = std.meta.Tuple(&.{ []const u8, []const u8 });

pub fn fetch(
    self: *Zig,
    io: std.Io,
    alloc: std.mem.Allocator,
    tmpdir: std.Io.Dir,
    url: []const u8,
    expected_hash: []const u8,
    options: Options,
) !Paths {
    const local_path, const global_path = paths: {
        if (self.isSixteen()) {
            const global_filename = try std.fmt.allocPrint(alloc, "{s}.tar.gz", .{expected_hash});
            defer alloc.free(global_filename);
            break :paths .{
                try std.fs.path.join(alloc, &.{ self.root_pkg_dir, expected_hash }),
                try std.fs.path.join(alloc, &.{ self.global_cache_dir, "p", global_filename }),
            };
        } else {
            break :paths .{
                try std.fs.path.join(alloc, &.{ self.global_cache_dir, "p", expected_hash }),
                try std.fs.path.join(alloc, &.{ self.global_cache_dir, "p", expected_hash }),
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
                .argv = &.{
                    options.zig,
                    "fetch",
                    "--global-cache-dir",
                    self.global_cache_dir,
                    url,
                },
                .cwd = .{
                    .dir = tmpdir,
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
