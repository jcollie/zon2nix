const BuildZigZon = @This();

const std = @import("std");

arena: std.heap.ArenaAllocator,
name: ?[]const u8 = null,
version: ?[]const u8 = null,
fingerprint: ?u64 = null,
paths: std.ArrayListUnmanaged([]const u8) = .empty,
dependencies: std.StringArrayHashMapUnmanaged(Dependency) = .empty,

pub const Dependency = struct {
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
    lazy: bool = false,
};

pub fn init(self: *BuildZigZon, allocator: std.mem.Allocator, reader: std.io.AnyReader) !void {
    self.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };

    const content = content: {
        const content = try reader.readAllAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(content);
        break :content try allocator.dupeZ(u8, content);
    };
    defer allocator.free(content);

    var ast = try std.zig.Ast.parse(allocator, content, .zon);
    defer ast.deinit(allocator);

    const zoir = try std.zig.ZonGen.generate(allocator, ast, .{ .parse_str_lits = true });
    defer zoir.deinit(allocator);

    const root = std.zig.Zoir.Node.Index.root.get(zoir);
    const root_struct = if (root == .struct_literal) root.struct_literal else return error.Parse;

    const alloc = self.arena.allocator();

    for (root_struct.names, 0..root_struct.vals.len) |name_node, index| {
        const value = root_struct.vals.at(@intCast(index));
        const name = name_node.get(zoir);

        if (std.mem.eql(u8, name, "name")) {
            switch (value.get(zoir)) {
                .string_literal => |v| {
                    self.name = try alloc.dupe(u8, v);
                },
                .enum_literal => |v| {
                    self.name = try alloc.dupe(u8, v.get(zoir));
                },
                else => return error.Parse,
            }
        }
        if (std.mem.eql(u8, name, "version")) {
            self.version = try alloc.dupe(u8, value.get(zoir).string_literal);
        }
        if (std.mem.eql(u8, name, "fingerprint")) {
            switch (value.get(zoir)) {
                .int_literal => |v| {
                    switch (v) {
                        .small => |i| self.fingerprint = @intCast(i),
                        .big => |i| self.fingerprint = try i.toInt(u64),
                    }
                },
                else => return error.Parse,
            }
        }
        if (std.mem.eql(u8, name, "dependencies")) dep: {
            switch (value.get(zoir)) {
                .struct_literal => |sl| {
                    for (sl.names, 0..sl.vals.len) |dep_name, dep_index| {
                        const node = sl.vals.at(@intCast(dep_index));
                        const dep_body = try std.zon.parse.fromZoirNode(BuildZigZon.Dependency, alloc, ast, zoir, node, null, .{});
                        try self.dependencies.put(alloc, try alloc.dupe(u8, dep_name.get(zoir)), dep_body);
                    }
                },
                .empty_literal => {
                    break :dep;
                },
                else => return error.Parse,
            }
        }
    }
}

pub fn deinit(self: *BuildZigZon) void {
    self.arena.deinit();
    self.* = undefined;
}

// test {
//     const allocator = std.testing.allocator;
//     var json = std.ArrayList(u8).init(allocator);
//     defer json.deinit();
//     var file = try std.fs.cwd().openFile("build.zig.zon", .{ .mode = .read_only });
//     defer file.close();
//     try parse(allocator, file.reader().any(), json.writer(), {}, .{});
//     try std.testing.expectEqualStrings(
//         \\{"name":"zon2json","version":"0.0.0","dependencies":{},"paths":["src","build.zig","build.zig.zon","LICENSE"]}
//     , json.items);
// }
