pub const Deps = @This();

const std = @import("std");

const log = std.log.scoped(.deps);

const Dep = @import("Dep.zig");
const TmpDir = @import("TmpDir.zig");
const Zig = @import("Zig.zig");

zig: Zig,
tmpdir: TmpDir,
deps: std.StringArrayHashMapUnmanaged(Dep),

pub fn init(self: *Deps, io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map) !void {
    try self.tmpdir.init(io, alloc, env_map);
    self.deps = .empty;
    try self.zig.init(io, alloc, &self.tmpdir, .{});
}

pub fn deinit(self: *Deps, io: std.Io, alloc: std.mem.Allocator) void {
    self.zig.deinit(alloc);

    var d_it = self.deps.iterator();
    while (d_it.next()) |d| {
        alloc.free(d.key_ptr.*);
        d.value_ptr.deinit(alloc);
    }
    self.deps.deinit(alloc);
    self.tmpdir.deinit(io, alloc);
}

pub fn get(
    self: *Deps,
    io: std.Io,
    alloc: std.mem.Allocator,
    name: []const u8,
    url: []const u8,
    zig_hash: []const u8,
) !*Dep {
    const gop = try self.deps.getOrPut(alloc, zig_hash);

    if (!gop.found_existing) {
        const h = try alloc.dupe(u8, zig_hash);
        errdefer alloc.free(h);

        errdefer _ = self.deps.swapRemove(zig_hash);
        gop.key_ptr.* = h;

        try gop.value_ptr.init(io, alloc, &self.tmpdir, name, url, zig_hash);
        errdefer gop.value_ptr.deinit(alloc);
    } else {
        const v = gop.value_ptr;
        try v.addName(alloc, name);
        try v.addUrl(alloc, url);
    }

    return gop.value_ptr;
}

pub fn iterator(self: *Deps) Iterator {
    return .{
        .iterator = self.deps.iterator(),
    };
}

pub const Iterator = struct {
    iterator: std.StringArrayHashMapUnmanaged(Dep).Iterator,

    pub fn next(self: *Iterator) ?*Dep {
        const entry = self.iterator.next() orelse return null;
        return entry.value_ptr;
    }
};
