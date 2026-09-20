// SPDX-FileCopyrightText: 2025 Jeffrey C. Ollie <jeff@ocjtech.us>
//
// SPDX-License-Identifier: MIT

const BuildZigZon = @This();

const std = @import("std");

const log = std.log.scoped(.zon2nix);

arena: std.heap.ArenaAllocator,
name: ?[]const u8 = null,
version: ?[]const u8 = null,
fingerprint: ?u64 = null,
paths: std.ArrayList([]const u8) = .empty,
dependencies: std.StringArrayHashMapUnmanaged(Dependency) = .empty,

pub const Dependency = struct {
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
    lazy: bool = false,
};

/// Read and parse one `build.zig.zon`.
///
/// `path` is only ever used to say where a syntax error is -- it is not
/// opened, and passing `null` parses without reporting anything, which is
/// what the tests below want and what a caller doing a speculative parse
/// would.
pub fn init(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    path: ?[]const u8,
) !BuildZigZon {
    var self: BuildZigZon = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };

    const content = content: {
        const content = try reader.allocRemaining(allocator, .unlimited);
        defer allocator.free(content);
        break :content try allocator.dupeZ(u8, content);
    };
    defer allocator.free(content);

    var ast = try std.zig.Ast.parse(allocator, content, .zon);
    defer ast.deinit(allocator);

    // Neither `Ast.parse` nor `ZonGen.generate` returns an error for a
    // malformed file: the first collects them in `ast.errors` and the second
    // in `zoir.compile_errors`, and both then hand back a structure with no
    // nodes in it. Asking such a `Zoir` for its root indexes an empty list,
    // which is a panic rather than a diagnostic -- so the errors have to be
    // looked at here, before the root is touched.
    if (ast.errors.len > 0) {
        if (path) |p| reportAstErrors(ast, p);
        return error.Parse;
    }

    const zoir = try std.zig.ZonGen.generate(allocator, ast, .{ .parse_str_lits = true });
    defer zoir.deinit(allocator);

    if (zoir.hasCompileErrors()) {
        if (path) |p| reportZoirErrors(zoir, ast, p);
        return error.Parse;
    }

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
                        const dep_body = try std.zon.parse.fromZoirNodeAlloc(
                            BuildZigZon.Dependency,
                            alloc,
                            ast,
                            zoir,
                            node,
                            null,
                            .{},
                        );
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

    return self;
}

pub fn deinit(self: *BuildZigZon) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Print the syntax errors `Ast.parse` collected, in the shape the Zig
/// compiler prints them, so that an editor's error parser recognises them.
fn reportAstErrors(ast: std.zig.Ast, path: []const u8) void {
    var buf: [1024]u8 = undefined;
    for (ast.errors) |err| {
        // `errorOffset` is a *byte* offset within the token, not a number of
        // tokens, so it belongs on the column rather than on the token index.
        // Adding it to the index walks off the end of the token list on any
        // error flagged against the previous token.
        const loc = ast.tokenLocation(0, err.token);
        const column = loc.column + ast.errorOffset(err) + 1;

        var writer: std.Io.Writer = .fixed(&buf);
        ast.renderError(err, &writer) catch continue;
        const message = writer.buffered();

        if (err.is_note) {
            log.err("{s}:{d}:{d}: note: {s}", .{ path, loc.line + 1, column, message });
        } else {
            log.err("{s}:{d}:{d}: {s}", .{ path, loc.line + 1, column, message });
        }
    }
}

/// Print the errors `ZonGen` collected -- a file that parses as Zig but is not
/// valid ZON, such as one containing an expression.
fn reportZoirErrors(zoir: std.zig.Zoir, ast: std.zig.Ast, path: []const u8) void {
    for (zoir.compile_errors) |err| {
        const msg = err.msg.get(zoir);
        if (err.token.unwrap()) |token| {
            const loc = ast.tokenLocation(0, token);
            log.err("{s}:{d}:{d}: {s}", .{ path, loc.line + 1, loc.column + 1, msg });
        } else {
            log.err("{s}: {s}", .{ path, msg });
        }
        for (err.getNotes(zoir)) |note| {
            log.err("  note: {s}", .{note.msg.get(zoir)});
        }
    }
}

/// Parse `source` the way `init` does, for the tests below.
fn parseForTest(allocator: std.mem.Allocator, source: []const u8) !BuildZigZon {
    var reader: std.Io.Reader = .fixed(source);
    // `null`: the malformed cases below are deliberate, and the test runner
    // counts an error-level log as a failed test.
    return init(allocator, &reader, null);
}

test "a well formed manifest parses" {
    const allocator = std.testing.allocator;
    var manifest = try parseForTest(allocator,
        \\.{
        \\    .name = .thing,
        \\    .version = "1.2.3",
        \\    .dependencies = .{
        \\        .dep = .{
        \\            .url = "https://example.invalid/dep.tar.gz",
        \\            .hash = "dep-1.0.0-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        \\            .lazy = true,
        \\        },
        \\    },
        \\    .paths = .{"build.zig"},
        \\}
    );
    defer manifest.deinit();

    try std.testing.expectEqualStrings("thing", manifest.name.?);
    try std.testing.expectEqualStrings("1.2.3", manifest.version.?);
    try std.testing.expectEqual(@as(usize, 1), manifest.dependencies.count());

    // A lazy dependency is still reported. Nothing here can know which
    // targets a build will ask for, so leaving one out would produce a
    // package set that works until somebody cross-compiles.
    const dep = manifest.dependencies.get("dep").?;
    try std.testing.expect(dep.lazy);
    try std.testing.expectEqualStrings("https://example.invalid/dep.tar.gz", dep.url.?);
}

test "a malformed manifest is an error rather than a panic" {
    const allocator = std.testing.allocator;

    // Each of these used to panic in `Zoir.Node.Index.root.get`, because
    // neither `Ast.parse` nor `ZonGen.generate` reports a malformed file by
    // returning an error -- they hand back a structure with no nodes, and
    // asking that for its root indexes an empty list.
    //
    // The empty case is not hypothetical. `--txt FILE` names an *output*, so
    // pointing it at a manifest truncates it, and every run afterwards met
    // this.
    const bad = [_][]const u8{
        // Empty.
        "",
        // Not ZON at all -- what is left after `--txt` has written over a
        // manifest.
        "https://example.invalid/dep.tar.gz\n",
        // Truncated.
        ".{\n    .name = .thing,\n",
        // Valid Zig, but an expression, which ZON does not allow. This one
        // reaches the second check rather than the first.
        ".{ .version = 1 + 2 }\n",
        // A bare value rather than a struct.
        "42\n",
    };

    for (bad) |source| {
        try std.testing.expectError(error.Parse, parseForTest(allocator, source));
    }
}
