const TmpDir = @This();

const std = @import("std");

path: []const u8,
sub_path: []const u8,
dir: std.Io.Dir,
tmp: std.Io.Dir,

const random_basename_bytes = 16;
const b64_encoder = std.base64.url_safe_no_pad.Encoder;
pub const random_basename_len = b64_encoder.calcSize(random_basename_bytes);

pub fn init(self: *TmpDir, io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map) !void {
    const tmpdir = tmpdir: {
        if (env_map.get("TMPDIR")) |tmpdir| break :tmpdir tmpdir;
        if (env_map.get("TMP")) |tmpdir| break :tmpdir tmpdir;
        if (env_map.get("TEMP")) |tmpdir| break :tmpdir tmpdir;
        if (env_map.get("TEMPDIR")) |tmpdir| break :tmpdir tmpdir;
        break :tmpdir "/tmp";
    };

    var random_bytes: [random_basename_bytes]u8 = undefined;
    io.random(&random_bytes);
    var sub_path_buffer: [random_basename_len]u8 = undefined;
    _ = b64_encoder.encode(&sub_path_buffer, &random_bytes);

    self.sub_path = try std.fmt.allocPrint(alloc, "tmp.{s}", .{&sub_path_buffer});
    errdefer alloc.free(self.sub_path);

    self.path = try std.fs.path.join(alloc, &.{ tmpdir, self.sub_path });
    errdefer alloc.free(self.path);

    self.tmp = try std.Io.Dir.openDirAbsolute(io, tmpdir, .{});
    errdefer self.tmp.close(io);

    self.dir = try self.tmp.createDirPathOpen(io, self.sub_path, .{});
}

pub fn deinit(self: *TmpDir, io: std.Io, alloc: std.mem.Allocator) void {
    self.dir.close(io);
    // self.tmp.deleteTree(io, self.sub_path) catch {};
    self.tmp.close(io);
    alloc.free(self.sub_path);
    alloc.free(self.path);
    self.* = undefined;
}

pub const SubDir = struct {
    dir: std.Io.Dir,
    name: []const u8,
    path: []const u8,

    pub fn deinit(self: *const SubDir, io: std.Io, alloc: std.mem.Allocator) void {
        self.dir.close(io);
        alloc.free(self.name);
        alloc.free(self.path);
    }
};

pub fn randomSubdir(self: *TmpDir, io: std.Io, alloc: std.mem.Allocator) !SubDir {
    var random_data: [random_basename_bytes]u8 = undefined;
    io.random(&random_data);
    var filename_buffer: [random_basename_len]u8 = undefined;
    const random_filename = b64_encoder.encode(&filename_buffer, &random_data);
    var dir = try self.dir.createDirPathOpen(io, random_filename, .{});
    errdefer dir.close(io);
    const name = try alloc.dupe(u8, random_filename);
    errdefer alloc.free(name);
    const path = try std.fs.path.join(alloc, &.{ self.path, name });
    errdefer alloc.free(name);
    return .{
        .dir = dir,
        .name = name,
        .path = path,
    };
}

pub fn createFile(self: *TmpDir, io: std.Io, sub_path: []const u8, flags: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
    return try self.dir.createFile(io, sub_path, flags);
}
