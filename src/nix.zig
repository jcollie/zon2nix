const std = @import("std");

const TmpDir = @import("TmpDir.zig");
const zig = @import("zig.zig");
const nix32 = @import("nix32.zig");

const log = std.log.scoped(.nix);

pub const Options = struct {
    nix_prefetch_git: []const u8 = "nix-prefetch-git",
    nix_prefetch_url: []const u8 = "nix-prefetch-url",
};

const Hashes = struct {
    b64: []const u8,
    hex: []const u8,
    unpack: bool,
};

pub fn fetch(
    io: std.Io,
    alloc: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    url: []const u8,
    expected_hash: []const u8,
    options: Options,
) !Hashes {
    const u = try std.Uri.parse(url);

    if (std.mem.eql(u8, u.scheme, "git+http")) return try fetchGit(io, alloc, env_map, url, options);
    if (std.mem.eql(u8, u.scheme, "git+https")) return try fetchGit(io, alloc, env_map, url, options);

    if (std.mem.eql(u8, u.scheme, "http")) return try fetchPlain(io, alloc, env_map, url, expected_hash, options);
    if (std.mem.eql(u8, u.scheme, "https")) return try fetchPlain(io, alloc, env_map, url, expected_hash, options);

    return error.UnsupportedScheme;
}

fn fetchGit(io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map, url: []const u8, options: Options) !Hashes {
    log.debug("nix fetch git: {s}", .{url});

    const stdout = stdout: {
        var uri = try std.Uri.parse(url);
        uri.scheme = uri.scheme[4..];

        const git_url, const git_rev = blk: {
            if (uri.fragment) |component| {
                var arena: std.heap.ArenaAllocator = .init(alloc);
                defer arena.deinit();
                const fragment = try component.toRawMaybeAlloc(arena.allocator());
                var writer: std.Io.Writer.Allocating = .init(arena.allocator());
                try uri.writeToStream(
                    &writer.writer,
                    .{
                        .scheme = true,
                        .authority = true,
                        .path = true,
                    },
                );
                try writer.writer.flush();
                break :blk .{ try alloc.dupe(u8, writer.written()), try alloc.dupe(u8, fragment) };
            }
            break :blk .{ try alloc.dupe(u8, url), try alloc.dupe(u8, "HEAD") };
        };
        defer alloc.free(git_rev);
        defer alloc.free(git_url);

        var tmpdir: TmpDir = undefined;
        try tmpdir.init(io, alloc, env_map);
        defer tmpdir.cleanup(io, alloc);

        const path = try std.fs.path.join(alloc, &.{ tmpdir.path, "artifact.git" });
        defer alloc.free(path);

        var envmap = try env_map.clone(alloc);
        defer envmap.deinit();

        try envmap.put("TMPDIR", tmpdir.path);
        try envmap.put("TMP", tmpdir.path);
        try envmap.put("TEMP", tmpdir.path);
        try envmap.put("TEMPDIR", tmpdir.path);

        var nix_prefetch_git = std.process.spawn(
            io,
            .{
                .argv = &.{
                    options.nix_prefetch_git,
                    "--out",
                    path,
                    "--url",
                    git_url,
                    "--rev",
                    git_rev,
                    "--no-deepClone",
                    "--quiet",
                },
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .pipe,
                .environ_map = &envmap,
            },
        ) catch |err| switch (err) {
            error.FileNotFound => {
                log.err("unable to execute nix-prefetch-git, is it in your PATH?", .{});
                return error.FileNotFound;
            },
            else => |e| return e,
        };
        errdefer nix_prefetch_git.kill(io);

        var stdout_task = try io.concurrent(collect, .{ io, alloc, nix_prefetch_git.stdout });
        defer _ = stdout_task.cancel(io) catch {};

        var stderr_task = try io.concurrent(collect, .{ io, alloc, nix_prefetch_git.stderr });
        defer _ = stderr_task.cancel(io) catch {};

        const term = try nix_prefetch_git.wait(io);

        const stdout = try stdout_task.await(io);
        errdefer alloc.free(stdout);

        const stderr = try stderr_task.await(io);
        defer alloc.free(stderr);

        switch (term) {
            .exited => |status| {
                if (status == 0) break :stdout stdout;
                var it = std.mem.splitScalar(u8, stderr, '\n');
                while (it.next()) |line| {
                    log.err("nix-prefetch-git errors: {s}", .{line});
                }
                return error.NixHashFile;
            },
            else => {
                return error.NixHashFile;
            },
        }
    };
    defer alloc.free(stdout);

    const Output = struct {
        hash: ?[]const u8,
    };
    const parsed = try std.json.parseFromSlice(
        Output,
        alloc,
        stdout,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    if (parsed.value.hash) |hash| {
        const h = std.mem.cutPrefix(u8, hash, "sha256-") orelse return error.UnsupportedNixHash;
        const decoder = std.base64.standard.Decoder;
        const Hash = std.crypto.hash.sha2.Sha256;
        if (try decoder.calcSizeForSlice(h) != Hash.digest_length) return error.HashLengthMismatch;
        var final: [Hash.digest_length]u8 = undefined;
        try decoder.decode(&final, h);
        const hex = std.fmt.bytesToHex(final, .lower);

        return .{
            .b64 = try alloc.dupe(u8, hash),
            .hex = try alloc.dupe(u8, &hex),
            .unpack = true,
        };
    }
    return error.HashNotFound;
}

fn collect(io: std.Io, alloc: std.mem.Allocator, file_: ?std.Io.File) ![]const u8 {
    const file = file_ orelse return try alloc.dupe(u8, "");

    var writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer writer.deinit();

    var buf: [1024]u8 = undefined;
    var reader = file.reader(io, &buf);

    _ = try reader.interface.streamRemaining(&writer.writer);

    return try writer.toOwnedSlice();
}

fn fetchPlain(io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map, url: []const u8, expected_hash: []const u8, options: Options) !Hashes {
    log.debug("nix fetch plain: {s}", .{url});

    const unpack = !std.mem.startsWith(u8, expected_hash, "N-V-");

    const stdout = stdout: {
        var tmpdir: TmpDir = undefined;
        try tmpdir.init(io, alloc, env_map);
        defer tmpdir.cleanup(io, alloc);

        var envmap = try env_map.clone(alloc);
        defer envmap.deinit();

        try envmap.put("TMPDIR", tmpdir.path);
        try envmap.put("TMP", tmpdir.path);
        try envmap.put("TEMP", tmpdir.path);
        try envmap.put("TEMPDIR", tmpdir.path);

        var nix_prefetch_url = std.process.spawn(
            io,
            .{
                .argv = if (unpack)
                    &.{
                        options.nix_prefetch_url,
                        "--type",
                        "sha256",
                        "--unpack",
                        url,
                    }
                else
                    &.{
                        options.nix_prefetch_url,
                        "--type",
                        "sha256",
                        url,
                    },
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .pipe,
                .environ_map = &envmap,
            },
        ) catch |err| switch (err) {
            error.FileNotFound => {
                log.err("unable to execute nix-prefetch-url, is it in your PATH?", .{});
                return error.FileNotFound;
            },
            else => |e| return e,
        };
        errdefer nix_prefetch_url.kill(io);

        var stdout_task = try io.concurrent(collect, .{ io, alloc, nix_prefetch_url.stdout });
        defer _ = stdout_task.cancel(io) catch {};

        var stderr_task = try io.concurrent(collect, .{ io, alloc, nix_prefetch_url.stderr });
        defer _ = stderr_task.cancel(io) catch {};

        const term = try nix_prefetch_url.wait(io);

        const stdout = try stdout_task.await(io);
        errdefer alloc.free(stdout);

        const stderr = try stderr_task.await(io);
        defer alloc.free(stderr);

        switch (term) {
            .exited => |status| {
                if (status == 0) break :stdout stdout;
                var it = std.mem.splitScalar(u8, stderr, '\n');
                while (it.next()) |line| {
                    log.err("nix-prefetch-url errors: {s}", .{line});
                }
                return error.NixHashFile;
            },
            else => {
                return error.NixHashFile;
            },
        }
    };
    defer alloc.free(stdout);

    const encoded = std.mem.trim(u8, stdout, &std.ascii.whitespace);

    var hex_buf: [128]u8 = undefined;
    const raw = try nix32.decode(&hex_buf, encoded);

    const hex = try std.fmt.allocPrint(alloc, "{x}", .{raw});
    errdefer alloc.free(hex);

    const hash = try std.fmt.allocPrint(alloc, "sha256-{b64}", .{raw});
    errdefer alloc.free(hash);

    return .{
        .b64 = hash,
        .hex = hex,
        .unpack = unpack,
    };
}

test {
    _ = nix32;
    std.testing.refAllDecls(@This());
}
