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
            const writer = buf.writer(arena.allocator());
            try uri.writeToStream(.{
                .scheme = true,
                .authority = true,
                .path = true,
            }, writer);
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

    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    defer stdout.deinit(alloc);

    nix_prefetch_git: {
        var stderr: std.ArrayListUnmanaged(u8) = .empty;
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

    var header_buf: [16384]u8 = undefined;
    const uri = try std.Uri.parse(url);
    var req = try client.open(.GET, uri, .{ .server_header_buffer = &header_buf });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) return error.BadHttpStatus;

    var rdr = req.reader();
    var body_buf: [std.math.maxInt(u20)]u8 = undefined;
    while (true) {
        const len = try rdr.read(&body_buf);
        if (len == 0) break;
        const data = body_buf[0..len];
        hash.update(data);
    }

    var final: [Hash.digest_length]u8 = undefined;
    hash.final(&final);
    const encoder = std.base64.standard.Encoder;
    var buffer: [encoder.calcSize(final.len)]u8 = undefined;
    const encoded = encoder.encode(&buffer, &final);

    return try std.fmt.allocPrint(alloc, "sha256-{s}", .{encoded});
}
