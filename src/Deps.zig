// SPDX-FileCopyrightText: 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
//
// SPDX-License-Identifier: MIT

pub const Deps = @This();

const std = @import("std");

const log = std.log.scoped(.deps);

const Dep = @import("Dep.zig");
const TmpDir = @import("TmpDir.zig");
const Zig = @import("Zig.zig");

zig: Zig,
tmpdir: TmpDir,
/// Keyed by Zig package hash. The packages are held by pointer rather than by
/// value because those pointers are kept -- by the round waiting to be
/// fetched, and by each manifest to say which package it came out of -- while
/// more packages are still being added, and the values of an array hash map
/// move when it grows.
deps: std.StringArrayHashMapUnmanaged(*Dep),

pub fn init(self: *Deps, io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map) !void {
    try self.tmpdir.init(io, alloc, env_map);
    // create dir structure
    try self.tmpdir.dir.createDir(io, "cache", .default_dir);
    try self.tmpdir.dir.createDir(io, "src", .default_dir);
    try self.tmpdir.dir.createDir(io, "tmp", .default_dir);
    const f = try self.tmpdir.dir.createFile(io, "src/build.zig", .{});
    defer f.close(io);

    self.deps = .empty;
    try self.zig.init(io, alloc, &self.tmpdir, .{});
}

pub fn deinit(self: *Deps, io: std.Io, alloc: std.mem.Allocator) void {
    self.zig.deinit(alloc);

    var d_it = self.deps.iterator();
    while (d_it.next()) |d| {
        alloc.free(d.key_ptr.*);
        d.value_ptr.*.deinit(alloc);
        alloc.destroy(d.value_ptr.*);
    }
    self.deps.deinit(alloc);
    self.tmpdir.deinit(io, alloc);
}

pub const Entry = struct {
    dep: *Dep,
    /// True the first time a package hash is seen, which is when the caller
    /// has to arrange for it to be fetched.
    is_new: bool,
};

/// Look a package up by hash, creating the entry if this is the first time it
/// has been named. Does no I/O: the fetching is `Dep.fetch`, so that a whole
/// round of them can be run at once.
pub fn get(
    self: *Deps,
    alloc: std.mem.Allocator,
    name: []const u8,
    url: []const u8,
    zig_hash: []const u8,
) !Entry {
    const gop = try self.deps.getOrPut(alloc, zig_hash);

    if (!gop.found_existing) {
        const h = try alloc.dupe(u8, zig_hash);
        errdefer alloc.free(h);

        errdefer _ = self.deps.swapRemove(zig_hash);
        gop.key_ptr.* = h;

        const dep = try alloc.create(Dep);
        errdefer alloc.destroy(dep);

        try dep.init(alloc, name, url, zig_hash);
        errdefer dep.deinit(alloc);

        gop.value_ptr.* = dep;
    } else {
        const v = gop.value_ptr.*;
        try v.addName(alloc, name);
        try v.addUrl(alloc, url);
    }

    return .{ .dep = gop.value_ptr.*, .is_new = !gop.found_existing };
}

pub fn iterator(self: *Deps) Iterator {
    return .{
        .iterator = self.deps.iterator(),
    };
}

pub const Iterator = struct {
    iterator: std.StringArrayHashMapUnmanaged(*Dep).Iterator,

    pub fn next(self: *Iterator) ?*Dep {
        const entry = self.iterator.next() orelse return null;
        return entry.value_ptr.*;
    }
};
