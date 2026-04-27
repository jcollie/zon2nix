pub const Dep = @This();

const std = @import("std");

const log = std.log.scoped(.deps);

const TmpDir = @import("TmpDir.zig");
const Zig = @import("Zig.zig");
const nixpkg = @import("nix.zig");
const Style = @import("root.zig").Style;

zig_hash: []const u8,
names: std.StringArrayHashMapUnmanaged(bool),
urls: std.StringArrayHashMapUnmanaged(bool),
local: ?struct {
    path: []const u8,
    sha256: []const u8,
},
zig: ?struct {
    local_path: []const u8,
    global_path: []const u8,
},
nix: ?struct {
    b64: []const u8,
    hex: []const u8,
    unpack: bool,
},

const Hasher = std.crypto.hash.sha2.Sha256;

pub fn init(
    self: *Dep,
    io: std.Io,
    alloc: std.mem.Allocator,
    tmpdir: *TmpDir,
    name: []const u8,
    url: []const u8,
    zig_hash: []const u8,
) !void {
    self.* = .{
        .zig_hash = try alloc.dupe(u8, zig_hash),
        .local = null,
        .zig = null,
        .nix = null,
        .names = .empty,
        .urls = .empty,
    };
    errdefer self.deinit(alloc);

    {
        const owned = try alloc.dupe(u8, name);
        errdefer alloc.free(owned);
        try self.names.putNoClobber(alloc, owned, true);
    }
    {
        const owned = try alloc.dupe(u8, url);
        errdefer alloc.free(owned);
        try self.urls.putNoClobber(alloc, owned, true);
    }

    try self.download(io, alloc, tmpdir, url);
}

pub fn deinit(self: *Dep, alloc: std.mem.Allocator) void {
    alloc.free(self.zig_hash);
    if (self.local) |local| {
        alloc.free(local.path);
        alloc.free(local.sha256);
    }
    if (self.zig) |zig| {
        alloc.free(zig.local_path);
        alloc.free(zig.global_path);
    }
    if (self.nix) |nix| {
        alloc.free(nix.hex);
        alloc.free(nix.b64);
    }
    self.deinitNames(alloc);
    self.deinitUrls(alloc);
}

fn deinitNames(self: *Dep, alloc: std.mem.Allocator) void {
    var n_it = self.names.iterator();
    while (n_it.next()) |n| {
        alloc.free(n.key_ptr.*);
    }
    self.names.deinit(alloc);
}

fn deinitUrls(self: *Dep, alloc: std.mem.Allocator) void {
    var u_it = self.urls.iterator();
    while (u_it.next()) |u| {
        alloc.free(u.key_ptr.*);
    }
    self.urls.deinit(alloc);
}

pub fn addName(self: *Dep, alloc: std.mem.Allocator, name: []const u8) !void {
    if (self.names.contains(name)) return;
    {
        const owned = try alloc.dupe(u8, name);
        errdefer alloc.free(owned);
        try self.names.putNoClobber(alloc, owned, true);
    }
    log.warn("{s} referenced by multiple names:", .{self.zig_hash});
    var it = self.names.iterator();
    while (it.next()) |entry| {
        log.warn("  {s}", .{entry.key_ptr.*});
    }
}

pub fn getName(self: *Dep) []const u8 {
    if (self.names.entries.len == 0) unreachable;
    return self.names.entries.get(0).key;
}

pub fn addUrl(self: *Dep, alloc: std.mem.Allocator, url: []const u8) !void {
    if (self.urls.contains(url)) return;
    {
        const owned = try alloc.dupe(u8, url);
        errdefer alloc.free(owned);
        try self.urls.put(alloc, owned, true);
    }
    log.warn("{s} downloaded via multiple URLs:", .{self.zig_hash});
    var it = self.urls.iterator();
    while (it.next()) |entry| {
        log.warn("  {s}", .{entry.key_ptr.*});
    }
}

pub fn getUrl(self: *Dep) []const u8 {
    if (self.urls.entries.len == 0) unreachable;
    return self.urls.entries.get(0).key;
}

pub fn download(
    self: *Dep,
    io: std.Io,
    alloc: std.mem.Allocator,
    tmpdir: *TmpDir,
    url: []const u8,
) !void {
    log.debug("downloading {s}", .{url});

    const uri = try std.Uri.parse(url);

    const style: Style = .init(uri.scheme);

    switch (style) {
        .http => {
            const subdir = try tmpdir.randomSubdir(io, alloc);
            defer subdir.deinit(io, alloc);

            const filename = std.fs.path.basename(url);
            const path = try std.fs.path.join(alloc, &.{ tmpdir.path, subdir.name, filename });
            errdefer alloc.free(path);

            var f = try subdir.dir.createFileAtomic(io, filename, .{});
            defer f.deinit(io);

            var file_writer_buffer: [1024]u8 = undefined;
            var file_writer = f.file.writer(io, &file_writer_buffer);

            var hasher_buffer: [1024]u8 = undefined;
            var hasher_writer: std.Io.Writer.Hashed(Hasher) = .initHasher(&file_writer.interface, .init(.{}), &hasher_buffer);
            const writer = &hasher_writer.writer;

            var client = std.http.Client{
                .io = io,
                .allocator = alloc,
            };
            defer client.deinit();

            const status = status: {
                const result = try client.fetch(.{
                    .method = .GET,
                    .location = .{ .uri = uri },
                    .response_writer = writer,
                });
                break :status result.status;
            };
            if (status != .ok) return error.BadHttpStatus;

            try hasher_writer.writer.flush();
            try file_writer.interface.flush();
            try f.link(io);

            const sha256 = try std.fmt.allocPrint(alloc, "{x}", .{hasher_writer.hasher.finalResult()});
            errdefer alloc.free(sha256);

            self.local = .{
                .path = path,
                .sha256 = sha256,
            };
            log.debug("downloaded and hashed {s}", .{url});
        },
        .file => {
            const path = path: {
                var w: std.Io.Writer.Allocating = .init(alloc);
                defer w.deinit();
                try uri.path.formatPath(&w.writer);
                try w.writer.flush();

                break :path try w.toOwnedSlice();
            };
            errdefer alloc.free(path);

            var file = try tmpdir.dir.openFile(io, path, .{});
            var file_read_buffer: [1024]u8 = undefined;
            var file_reader = file.reader(io, &file_read_buffer);

            var hasher_buffer: [1024]u8 = undefined;
            var hasher: std.Io.Writer.Hashing(Hasher) = .initHasher(.init(.{}), &hasher_buffer);

            _ = try file_reader.interface.streamRemaining(&hasher.writer);
            try hasher.writer.flush();

            const sha256 = try std.fmt.allocPrint(alloc, "{x}", .{hasher.hasher.finalResult()});
            errdefer alloc.free(sha256);

            self.local = .{
                .path = path,
                .sha256 = sha256,
            };

            log.debug("hashed local file {s}", .{url});
        },
        .git, .other => {
            log.debug("download skipped for {s}", .{url});
        },
    }
}

pub fn getBuildZigZon(
    self: *Dep,
    io: std.Io,
    alloc: std.mem.Allocator,
    zigcli: *Zig,
    tmpdir: *TmpDir,
) !?[]const u8 {
    const local_path = local_path: {
        if (self.zig) |z| {
            break :local_path z.local_path;
        }

        const path_or_url = path_or_url: {
            if (self.local) |local| break :path_or_url local.path;
            if (self.urls.entries.len == 0) return error.NoUrl;
            break :path_or_url self.urls.entries.get(0).key;
        };

        const local_path, const global_path = try zigcli.fetch(
            io,
            alloc,
            tmpdir.dir,
            path_or_url,
            self.zig_hash,
            .{},
        );
        errdefer alloc.free(local_path);
        errdefer alloc.free(global_path);
        self.zig = .{
            .local_path = local_path,
            .global_path = global_path,
        };
        break :local_path local_path;
    };

    const path = try std.fs.path.join(alloc, &.{ local_path, "build.zig.zon" });
    std.Io.Dir.accessAbsolute(io, path, .{}) catch {
        alloc.free(path);
        return null;
    };
    return path;
}

pub fn getNixHashes(
    self: *Dep,
    io: std.Io,
    alloc: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    tmpdir: *TmpDir,
    options: nixpkg.Options,
) !void {
    if (self.nix) |_| return;

    const path = if (self.local) |local| local.path else null;

    const url = url: {
        if (self.urls.entries.len == 0) return error.NoUrl;
        break :url self.urls.entries.get(0).key;
    };
    const hashes = try nixpkg.fetch(
        io,
        alloc,
        tmpdir,
        env_map,
        path,
        url,
        self.zig_hash,
        .{
            .nix_prefetch_git = options.nix_prefetch_git,
            .nix_prefetch_url = options.nix_prefetch_url,
        },
    );
    self.nix = .{
        .b64 = hashes.b64,
        .hex = hashes.hex,
        .unpack = hashes.unpack,
    };
}
