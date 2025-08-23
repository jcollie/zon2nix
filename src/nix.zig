const std = @import("std");

const TmpDir = @import("TmpDir.zig");

const log = std.log.scoped(.nix);

pub const Options = struct {
    nix_prefetch_git: []const u8 = "nix-prefetch-git",
};

pub fn fetch(alloc: std.mem.Allocator, url: []const u8, options: Options) ![]const u8 {
    const u = try std.Uri.parse(url);

    if (std.mem.eql(u8, u.scheme, "git+http")) return try fetchGit(alloc, url, options);
    if (std.mem.eql(u8, u.scheme, "git+https")) return try fetchGit(alloc, url, options);

    if (std.mem.eql(u8, u.scheme, "http")) return try fetchPlain(alloc, url, options);
    if (std.mem.eql(u8, u.scheme, "https")) return try fetchPlain(alloc, url, options);

    return error.UnsupportedScheme;
}

fn fetchGit(alloc: std.mem.Allocator, url: []const u8, options: Options) ![]const u8 {
    log.debug("nix fetch git: {s}", .{url});

    var uri = try std.Uri.parse(url);
    uri.scheme = uri.scheme[4..];

    const git_url, const git_rev = blk: {
        if (uri.fragment) |component| {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const fragment = try component.toRawMaybeAlloc(arena.allocator());
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            var buffer: [64]u8 = undefined;
            var writer = buf.writer(arena.allocator()).adaptToNewApi(&buffer);
            try uri.writeToStream(
                &writer.new_interface,
                .{
                    .scheme = true,
                    .authority = true,
                    .path = true,
                },
            );
            try writer.new_interface.flush();
            break :blk .{ try alloc.dupe(u8, buf.items), try alloc.dupe(u8, fragment) };
        }
        break :blk .{ try alloc.dupe(u8, url), try alloc.dupe(u8, "HEAD") };
    };
    defer alloc.free(git_rev);
    defer alloc.free(git_url);

    var tmpdir: TmpDir = undefined;
    try tmpdir.init(alloc);
    defer tmpdir.cleanup(alloc);

    const path = try std.fs.path.join(alloc, &.{ tmpdir.path, "artifact.git" });
    defer alloc.free(path);

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(alloc);

    nix_prefetch_git: {
        var envmap = try std.process.getEnvMap(alloc);
        defer envmap.deinit();

        try envmap.put("TMPDIR", tmpdir.path);
        try envmap.put("TMP", tmpdir.path);
        try envmap.put("TEMP", tmpdir.path);
        try envmap.put("TEMPDIR", tmpdir.path);

        var stderr: std.ArrayList(u8) = .empty;
        defer stderr.deinit(alloc);

        var nix_prefetch_git = std.process.Child.init(
            &.{
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
            alloc,
        );
        nix_prefetch_git.env_map = &envmap;
        nix_prefetch_git.stdout_behavior = .Pipe;
        nix_prefetch_git.stderr_behavior = .Pipe;
        try nix_prefetch_git.spawn();
        try nix_prefetch_git.collectOutput(
            alloc,
            &stdout,
            &stderr,
            std.math.maxInt(u16),
        );

        const term = nix_prefetch_git.wait() catch |err| {
            return err;
        };

        if (stderr.items.len > 0) log.err("{s}", .{stderr.items});

        switch (term) {
            .Exited => |status| {
                if (status == 0) break :nix_prefetch_git;
                return error.NixHashFile;
            },
            else => {
                return error.NixHashFile;
            },
        }
    }

    const Hash = struct {
        hash: ?[]const u8,
    };
    const parsed = try std.json.parseFromSlice(
        Hash,
        alloc,
        stdout.items,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    if (parsed.value.hash) |hash| {
        return try alloc.dupe(u8, hash);
    }
    return error.HashNotFound;
}

fn fetchPlain(alloc: std.mem.Allocator, url: []const u8, _: Options) ![]const u8 {
    log.debug("nix fetch plain: {s}", .{url});

    const Hash = std.crypto.hash.sha2.Sha256;
    var hash = Hash.init(.{});

    var client = std.http.Client{ .allocator = alloc };
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

    return try std.fmt.allocPrint(alloc, "sha256-{b64}", .{final});
}
