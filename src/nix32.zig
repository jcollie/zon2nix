const std = @import("std");

const alphabet = "0123456789abcdfghijklmnpqrsvwxyz";
const reverse: [256]?u5 = reverse: {
    std.debug.assert(alphabet.len == 32);
    var rv: [256]?u5 = @splat(null);
    for (alphabet, 0..) |ch, i| {
        rv[ch] = i;
    }
    const rc = rv;
    break :reverse rc;
};

const Reverse = struct {
    str: []const u8,
    index: usize,

    pub fn init(str: []const u8) Reverse {
        return .{
            .str = str,
            .index = str.len,
        };
    }

    pub const Next = struct {
        digit: u5,
        index: usize,
    };

    pub fn next(self: *Reverse) !?Next {
        if (self.index == 0) return null;
        self.index -= 1;
        return .{
            .digit = reverse[self.str[self.index]] orelse return error.InvalidCharacter,
            .index = self.str.len - self.index - 1,
        };
    }
};

pub fn decode(output: []u8, input: []const u8) ![]const u8 {
    std.debug.assert(output.len >= @divTrunc(input.len * 5, 8));

    @memset(output, 0);

    var it: Reverse = .init(input);
    var used: usize = 0;

    while (try it.next()) |n| {
        const b = n.index * 5;
        const i = @divFloor(b, 8);
        const j = @mod(b, 8);

        const low = std.math.shl(u8, n.digit, j);
        output[i] |= low;
        used = @max(used, i);

        const high = std.math.shr(u8, n.digit, 8 - @as(u4, @intCast(j)));
        if (high != 0) {
            output[i + 1] |= high;
            used = @max(used, i + 1);
        }
    }
    return output[0 .. used + 1];
}

test decode {
    const alloc = std.testing.allocator;
    {
        const in = "vw46m23bizj4n8afrc0fj19wrp7mj3c0";
        var buf: [128]u8 = undefined;
        const actual = out: {
            const out = try decode(&buf, in);
            break :out try std.fmt.allocPrint(alloc, "{x}", .{out});
        };
        defer alloc.free(actual);
        try std.testing.expectEqualStrings("800d59cfcd3c05e900cb4e214be48f6b886a08df", actual);
    }
    {
        const in = "1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s";
        var buf: [128]u8 = undefined;
        const actual = out: {
            const out = try decode(&buf, in);
            break :out try std.fmt.allocPrint(alloc, "sha256-{b64}", .{out});
        };
        defer alloc.free(actual);
        try std.testing.expectEqualStrings("sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=", actual);
    }
    {
        const in = "0vbg7rhyvg7yxn3sbcx7xih0x5kp2vmdp1ckwkma08ankddmg527";
        var buf: [128]u8 = undefined;
        const actual = out: {
            const out = try decode(&buf, in);
            break :out try std.fmt.allocPrint(alloc, "sha256-{b64}", .{out});
        };
        defer alloc.free(actual);
        try std.testing.expectEqualStrings("sha256-R5RXW5tWIaDq5JOF2+oWd5YOYOyns6WH7f687WE+b20=", actual);
    }
}
