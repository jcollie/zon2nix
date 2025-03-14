const TmpDir = @This();

const std = @import("std");

path: []const u8,
sub_path: []const u8,
dir: std.fs.Dir,
tmp: std.fs.Dir,

pub fn init(self: *TmpDir, alloc: std.mem.Allocator) !void {
    var random_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var sub_path: [std.fs.base64_encoder.calcSize(32)]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&sub_path, &random_bytes);

    self.sub_path = try std.fmt.allocPrint(alloc, "tmp.{s}", .{&sub_path});
    errdefer alloc.free(self.sub_path);
    self.path = try std.fs.path.join(alloc, &.{ "/tmp", self.sub_path });
    errdefer alloc.free(self.path);
    self.tmp = try std.fs.openDirAbsolute("/tmp", .{});
    errdefer self.tmp.close();
    self.dir = try self.tmp.makeOpenPath(self.sub_path, .{});
}

pub fn cleanup(self: *TmpDir, alloc: std.mem.Allocator) void {
    self.dir.close();
    self.tmp.deleteTree(self.sub_path) catch {};
    self.tmp.close();
    alloc.free(self.sub_path);
    alloc.free(self.path);
    self.* = undefined;
}
