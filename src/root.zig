const std = @import("std");

pub const BuildZigZon = @import("BuildZigZon.zig");
pub const zig = @import("zig.zig");
pub const nix = @import("nix.zig");

pub fn streamer(in: *std.Io.Reader, out: *std.Io.Writer) !void {
    _ = try in.streamRemaining(out);
    try out.flush();
}

test {
    std.testing.refAllDecls(@This());
}
