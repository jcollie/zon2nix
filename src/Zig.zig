// SPDX-FileCopyrightText: 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
//
// SPDX-License-Identifier: MIT

const Zig = @This();

const std = @import("std");

const log = std.log.scoped(.zig);

const TmpDir = @import("TmpDir.zig");

version_string: []const u8,
version: std.SemanticVersion,
global_cache_dir: []const u8,
root_pkg_dir: []const u8,
/// The environment `zig` runs in: the caller's, pointed at `global_cache_dir`.
env_map: std.process.Environ.Map,

pub const Options = struct {
    zig: []const u8 = "zig",
};

pub fn init(
    self: *Zig,
    io: std.Io,
    alloc: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    tmpdir: *TmpDir,
    options: Options,
) !void {
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
                if (status == 0) break :stdout try alloc.dupeSentinel(u8, zig_env.stdout, 0);
                return error.GettingZigEnv;
            },
            else => {
                return error.GettingZigEnv;
            },
        }
    };
    defer alloc.free(stdout);

    const Env = struct {
        version: ?[]const u8 = null,
        global_cache_dir: ?[]const u8 = null,
    };

    const format: enum { zon, json } = if (std.mem.startsWith(u8, stdout, ".{")) .zon else .json;

    // Both owned.
    const version_string: []const u8, const env_cache_dir: ?[]const u8 = switch (format) {
        .zon => zon: {
            var arena: std.heap.ArenaAllocator = .init(alloc);
            defer arena.deinit();
            var diagnostics: std.zon.parse.Diagnostics = undefined;
            const parsed = try std.zon.parse.fromSlice(Env, .{
                .gpa = alloc,
                .arena = arena.allocator(),
                .source = stdout,
                .diagnostics = &diagnostics,
                .ignore_unknown_fields = true,
            });
            break :zon try dupeEnv(alloc, parsed);
        },
        .json => json: {
            const parsed = try std.json.parseFromSlice(
                Env,
                alloc,
                stdout,
                .{ .ignore_unknown_fields = true },
            );
            defer parsed.deinit();
            break :json try dupeEnv(alloc, parsed.value);
        },
    };
    errdefer alloc.free(version_string);
    defer if (env_cache_dir) |dir| alloc.free(dir);
    const version: std.SemanticVersion = try .parse(version_string);

    // A cache of its own, so that what one run fetched is not mistaken for
    // what the next one fetches -- except on Zig 0.17, where `zig fetch` runs
    // in a build runner that it compiles into the global cache the first time,
    // which takes a minute or more. In a cache of its own every run would pay
    // that again, so there zon2nix shares Zig's, and checks each package
    // against its hash itself.
    const global_cache_dir = if (layoutOf(version) == .archive_only and env_cache_dir != null)
        try alloc.dupe(u8, env_cache_dir.?)
    else
        try alloc.dupe(u8, tmpdir.path);
    errdefer alloc.free(global_cache_dir);
    log.debug("global_cache_dir: {s}", .{global_cache_dir});

    const root_pkg_dir = try std.fs.path.join(alloc, &.{ tmpdir.path, "zig-pkg" });
    errdefer alloc.free(root_pkg_dir);

    log.debug("root_pkg_dir: {s}", .{root_pkg_dir});

    var zig_env_map = try env_map.clone(alloc);
    errdefer zig_env_map.deinit();
    try zig_env_map.put("ZIG_GLOBAL_CACHE_DIR", global_cache_dir);

    self.* = .{
        .version_string = version_string,
        .version = version,
        .global_cache_dir = global_cache_dir,
        .root_pkg_dir = root_pkg_dir,
        .env_map = zig_env_map,
    };
}

fn dupeEnv(alloc: std.mem.Allocator, env: anytype) !struct { []const u8, ?[]const u8 } {
    const version = try alloc.dupe(u8, env.version orelse return error.GettingZigEnv);
    errdefer alloc.free(version);
    const cache_dir = if (env.global_cache_dir) |dir| try alloc.dupe(u8, dir) else null;
    return .{ version, cache_dir };
}

pub fn deinit(self: *Zig, alloc: std.mem.Allocator) void {
    alloc.free(self.version_string);
    alloc.free(self.global_cache_dir);
    alloc.free(self.root_pkg_dir);
    self.env_map.deinit();
}

/// Where `zig fetch` leaves the package it fetched.
pub const Layout = enum {
    /// Zig 0.15: unpacked, in the global cache's `p/<hash>`.
    global_dir,
    /// Zig 0.16: unpacked in `zig-pkg/<hash>` beside the project, and
    /// compressed in the global cache's `p/<hash>.tar.gz`.
    local_dir,
    /// Zig 0.17: only compressed, in the global cache's `p/<hash>.tar.gz`.
    /// Nothing is unpacked anywhere unless `--save` is given, which wants a
    /// project to save into.
    archive_only,
};

const sixteen = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0, .pre = "dev" };
const seventeen = std.SemanticVersion{ .major = 0, .minor = 17, .patch = 0, .pre = "dev" };

pub fn layout(self: *const Zig) Layout {
    return layoutOf(self.version);
}

fn layoutOf(version: std.SemanticVersion) Layout {
    if (version.order(seventeen) != .lt) return .archive_only;
    if (version.order(sixteen) != .lt) return .local_dir;
    return .global_dir;
}

/// What `fetch` found, both owned by the caller.
pub const Fetched = struct {
    /// The package unpacked, or null if this Zig left it only as `archive`.
    unpacked: ?[]const u8,
    /// The package in the global cache: a directory or a tarball, depending
    /// on the `Layout`.
    archive: []const u8,

    pub fn deinit(self: Fetched, alloc: std.mem.Allocator) void {
        if (self.unpacked) |path| alloc.free(path);
        alloc.free(self.archive);
    }
};

pub fn fetch(
    self: *Zig,
    io: std.Io,
    alloc: std.mem.Allocator,
    tmpdir: std.Io.Dir,
    url: []const u8,
    expected_hash: []const u8,
    options: Options,
) !Fetched {
    const fetched: Fetched = switch (self.layout()) {
        .global_dir => paths: {
            const path = try std.fs.path.join(alloc, &.{ self.global_cache_dir, "p", expected_hash });
            errdefer alloc.free(path);
            break :paths .{ .unpacked = path, .archive = try alloc.dupe(u8, path) };
        },
        .local_dir, .archive_only => |l| paths: {
            const global_filename = try std.fmt.allocPrint(alloc, "{s}.tar.gz", .{expected_hash});
            defer alloc.free(global_filename);
            const archive = try std.fs.path.join(alloc, &.{ self.global_cache_dir, "p", global_filename });
            errdefer alloc.free(archive);
            break :paths .{
                .unpacked = if (l == .local_dir)
                    try std.fs.path.join(alloc, &.{ self.root_pkg_dir, expected_hash })
                else
                    null,
                .archive = archive,
            };
        },
    };
    errdefer fetched.deinit(alloc);
    if (fetched.unpacked) |path| log.debug("unpacked: {s}", .{path});
    log.debug("archive: {s}", .{fetched.archive});

    // if the cache dir already exists don't download it again
    check: {
        if (fetched.unpacked) |path| std.Io.Dir.accessAbsolute(io, path, .{}) catch break :check;
        std.Io.Dir.accessAbsolute(io, fetched.archive, .{}) catch break :check;
        return fetched;
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
                    url,
                },
                .cwd = .{
                    .dir = tmpdir,
                },
                // Zig 0.17 has no `--global-cache-dir` for `zig fetch`, and
                // every version reads this.
                .environ_map = &self.env_map,
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
    if (fetched.unpacked) |path| try std.Io.Dir.accessAbsolute(io, path, .{});
    try std.Io.Dir.accessAbsolute(io, fetched.archive, .{});

    return fetched;
}
