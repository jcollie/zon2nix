const TmpDir = @This();

const std = @import("std");

path: []const u8,
sub_path: []const u8,
dir: std.Io.Dir,
tmp: std.Io.Dir,

pub fn init(self: *TmpDir, io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map) !void {
    const tmpdir = tmpdir: {
        if (env_map.get("TMPDIR")) |tmpdir| break :tmpdir tmpdir;
        if (env_map.get("TMP")) |tmpdir| break :tmpdir tmpdir;
        if (env_map.get("TEMP")) |tmpdir| break :tmpdir tmpdir;
        if (env_map.get("TEMPDIR")) |tmpdir| break :tmpdir tmpdir;
        break :tmpdir "/tmp";
    };

    var random_bytes: [32]u8 = undefined;
    io.random(&random_bytes);

    var sub_path: [std.fs.base64_encoder.calcSize(32)]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&sub_path, &random_bytes);

    self.sub_path = try std.fmt.allocPrint(alloc, "tmp.{s}", .{&sub_path});
    errdefer alloc.free(self.sub_path);

    self.path = try std.fs.path.join(alloc, &.{ tmpdir, self.sub_path });
    errdefer alloc.free(self.path);

    self.tmp = try std.Io.Dir.openDirAbsolute(io, tmpdir, .{});
    errdefer self.tmp.close(io);

    self.dir = try self.tmp.createDirPathOpen(io, self.sub_path, .{});
}

pub fn cleanup(self: *TmpDir, io: std.Io, alloc: std.mem.Allocator) void {
    self.dir.close(io);
    self.tmp.deleteTree(io, self.sub_path) catch {};
    self.tmp.close(io);
    alloc.free(self.sub_path);
    alloc.free(self.path);
    self.* = undefined;
}
