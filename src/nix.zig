const std = @import("std");

const TmpDir = @import("TmpDir.zig");

const log = std.log.scoped(.nix);

pub const Options = struct {
    nix_prefetch_git: []const u8 = "nix-prefetch-git",
};

const Hashes = std.meta.Tuple(&.{ []const u8, []const u8 });

pub fn fetch(io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map, url: []const u8, options: Options) !Hashes {
    const u = try std.Uri.parse(url);

    if (std.mem.eql(u8, u.scheme, "git+http")) return try fetchGit(io, alloc, env_map, url, options);
    if (std.mem.eql(u8, u.scheme, "git+https")) return try fetchGit(io, alloc, env_map, url, options);

    if (std.mem.eql(u8, u.scheme, "http")) return try fetchPlain(io, alloc, url, options);
    if (std.mem.eql(u8, u.scheme, "https")) return try fetchPlain(io, alloc, url, options);

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
            try alloc.dupe(u8, hash),
            try alloc.dupe(u8, &hex),
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

fn fetchPlain(io: std.Io, alloc: std.mem.Allocator, url: []const u8, _: Options) !Hashes {
    log.debug("nix fetch plain: {s}", .{url});

    const Hash = std.crypto.hash.sha2.Sha256;
    var hash: Hash = .init(.{});

    var client = std.http.Client{
        .io = io,
        .allocator = alloc,
    };
    defer client.deinit();

    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();

    const status = status: {
        const uri = try std.Uri.parse(url);
        const result = try client.fetch(.{
            .method = .GET,
            .location = .{ .uri = uri },
            .response_writer = &writer.writer,
        });
        break :status result.status;
    };

    if (status != .ok) return error.BadHttpStatus;

    try writer.writer.flush();

    hash.update(writer.written());

    var final: [Hash.digest_length]u8 = undefined;
    hash.final(&final);
    const hex = std.fmt.bytesToHex(final, .lower);

    return .{
        try std.fmt.allocPrint(alloc, "sha256-{b64}", .{final}),
        try alloc.dupe(u8, &hex),
    };
}
