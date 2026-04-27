const std = @import("std");

pub const BuildZigZon = @import("BuildZigZon.zig");
pub const Dep = @import("Dep.zig");
pub const Deps = @import("Deps.zig");

pub fn streamer(in: *std.Io.Reader, out: *std.Io.Writer) !void {
    _ = try in.streamRemaining(out);
    try out.flush();
}

pub const Style = enum {
    git,
    http,
    file,
    other,

    const map: std.StaticStringMap(Style) = .initComptime(&.{
        .{ "git+https", .git },
        .{ "git+http", .git },
        .{ "https", .http },
        .{ "http", .http },
        .{ "file", .file },
    });

    pub fn init(scheme: []const u8) Style {
        return map.get(scheme) orelse .other;
    }
};

test {
    std.testing.refAllDecls(@This());
}
