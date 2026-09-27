// SPDX-FileCopyrightText: 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
//
// SPDX-License-Identifier: MIT

//! Decoding of Nix's base-32 hash encoding, the form `nix-prefetch-url`
//! prints a hash in, so that it can be turned back into raw bytes and from
//! there into the hex and SRI forms the generated expression uses.
//!
//! It is not RFC 4648 base32 and nothing in the standard library reads it.
//! The alphabet is its own, and the bit order is the reverse of what the
//! string suggests: the hash is read as one little-endian stream of bits, cut
//! into five-bit digits starting from the least significant, and those digits
//! are written out most significant first. So the *last* character of the
//! string holds the lowest five bits of the first byte, and the first
//! character holds whatever is left over at the top of the last byte.

const std = @import("std");

/// The 32 digits, in order of value. It is `0-9a-z` with `e`, `o`, `u` and
/// `t` left out, so that a hash can never spell anything unfortunate.
const alphabet = "0123456789abcdfghijklmnpqrsvwxyz";

/// Maps every byte to the digit it stands for, or null if it is not one of
/// the alphabet, so that decoding is a table lookup rather than a search.
/// Built at compile time from `alphabet`, so the two cannot disagree.
const reverse: [256]?u5 = reverse: {
    std.debug.assert(alphabet.len == 32);
    var rv: [256]?u5 = @splat(null);
    for (alphabet, 0..) |ch, i| {
        rv[ch] = i;
    }
    const rc = rv;
    break :reverse rc;
};

/// Walks an encoded string from its last character to its first, which is
/// from its least significant digit to its most -- the order in which the
/// digits' bits land in the output.
const Reverse = struct {
    str: []const u8,
    /// The position in `str` of the character last returned; `str.len`
    /// before the first call to `next`, and zero once all have been.
    index: usize,

    pub fn init(str: []const u8) Reverse {
        return .{
            .str = str,
            .index = str.len,
        };
    }

    pub const Next = struct {
        /// The value of the character.
        digit: u5,
        /// Its place value, counted from the end of the string: zero for the
        /// last character, one for the one before it, and so on. The digit's
        /// bits start at bit `index * 5` of the output.
        index: usize,
    };

    /// Returns the next digit, or null once the start of the string has been
    /// passed. A character outside the alphabet is `error.InvalidCharacter`.
    pub fn next(self: *Reverse) !?Next {
        if (self.index == 0) return null;
        self.index -= 1;
        return .{
            .digit = reverse[self.str[self.index]] orelse return error.InvalidCharacter,
            .index = self.str.len - self.index - 1,
        };
    }
};

/// How many characters `encode` makes of `len` bytes: one for every five
/// bits, rounded up. 20 bytes make 32 characters and 32 bytes make 52.
pub fn encodedLen(len: usize) usize {
    return std.math.divCeil(usize, len * 8, 5) catch unreachable;
}

/// Encodes `input` into `output` and returns the part of `output` that holds
/// the result, `encodedLen(input.len)` characters long; `output` must have
/// room for at least that. This is the form `nix-hash --type sha256 --base32`
/// and `nix-prefetch-url` print, and what `decode` reads back.
///
/// When `input.len * 8` is not a multiple of five, the first character has
/// bits left over at its top, and they are always written as zero -- which
/// is what `decode` insists on.
pub fn encode(output: []u8, input: []const u8) []const u8 {
    const len = encodedLen(input.len);
    std.debug.assert(output.len >= len);

    for (output[0..len], 0..) |*ch, k| {
        // The characters are written most significant first, so the one at
        // `k` is the digit whose bits start at bit `b` of the input, taken
        // as one little-endian stream: bit `j` of byte `i` onwards.
        const b = (len - k - 1) * 5;
        const i = @divFloor(b, 8);
        const j = @mod(b, 8);

        // The part of the digit in byte `i`, and whatever it takes from the
        // low bits of the next byte when `j` is above 3 -- unless there is no
        // next byte, which is where the zero padding comes from. `shl`, where
        // a plain `<<` would not, allows the shift of 8 that `j` of 0 asks
        // for, and gives nothing, which is right: all five bits are in byte
        // `i` then.
        const low = input[i] >> @intCast(j);
        const high = if (i + 1 < input.len) std.math.shl(u8, input[i + 1], 8 - j) else 0;
        ch.* = alphabet[@as(u5, @truncate(low | high))];
    }
    return output[0..len];
}

/// Decodes `input` into `output` and returns the part of `output` that holds
/// the result.
///
/// The result is `input.len * 5 / 8` bytes long, rounded down, and `output`
/// must have room for at least that: 32 characters make a 20-byte SHA-1, 52 a
/// 32-byte SHA-256. The length follows from the input alone, so a hash with
/// zero bytes at the end still comes back at full length.
///
/// When `input.len * 5` is not a multiple of eight, the digits hold more bits
/// than the hash has, and the spare ones -- at the top of the first character
/// -- must be zero. A set one is `error.InvalidPadding` rather than being
/// dropped, the same as Nix itself, since a string that says more than a
/// hash can hold is not a hash of that length. A character outside the
/// alphabet is `error.InvalidCharacter`.
pub fn decode(output: []u8, input: []const u8) error{ InvalidCharacter, InvalidPadding }![]const u8 {
    const len = @divTrunc(input.len * 5, 8);
    std.debug.assert(output.len >= len);

    // Every digit is OR-ed into place, so the buffer has to start clear.
    @memset(output[0..len], 0);

    var it: Reverse = .init(input);

    while (try it.next()) |n| {
        // The digit occupies bits `b` to `b + 4` of the output, taken as one
        // little-endian stream: bit `j` of byte `i` onwards.
        const b = n.index * 5;
        const i = @divFloor(b, 8);
        const j = @mod(b, 8);

        // As much of the digit as fits in byte `i`. `shl` drops the bits
        // shifted past the top of the byte rather than overflowing, which is
        // what is wanted: they are the ones picked up below.
        const low = std.math.shl(u8, n.digit, j);
        if (i < len) {
            output[i] |= low;
        } else if (low != 0) {
            return error.InvalidPadding;
        }

        // Whatever did not fit, when `j` is above 3, carries into the low
        // bits of the next byte -- unless there is no next byte, in which
        // case it has to be nothing.
        const high = std.math.shr(u8, n.digit, 8 - @as(u4, @intCast(j)));
        if (i + 1 < len) {
            output[i + 1] |= high;
        } else if (high != 0) {
            return error.InvalidPadding;
        }
    }
    return output[0..len];
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
    {
        // The same SHA-256 as above with its first character one higher,
        // which sets the lowest of the four bits past the end of the hash.
        var buf: [32]u8 = undefined;
        try std.testing.expectError(
            error.InvalidPadding,
            decode(&buf, "2b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s"),
        );
    }
    {
        // `e` is one of the letters the alphabet leaves out.
        var buf: [32]u8 = undefined;
        try std.testing.expectError(
            error.InvalidCharacter,
            decode(&buf, "eb8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s"),
        );
    }
    {
        // An output exactly the size of the hash is enough.
        var buf: [32]u8 = undefined;
        const out = try decode(&buf, "1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s");
        try std.testing.expectEqual(32, out.len);
    }
    {
        var buf: [0]u8 = undefined;
        try std.testing.expectEqual(0, (try decode(&buf, "")).len);
    }
}

test encode {
    {
        // A SHA-1: 20 bytes, 160 bits, which is exactly 32 digits.
        var raw: [20]u8 = undefined;
        _ = try std.fmt.hexToBytes(&raw, "800d59cfcd3c05e900cb4e214be48f6b886a08df");
        var buf: [32]u8 = undefined;
        try std.testing.expectEqualStrings("vw46m23bizj4n8afrc0fj19wrp7mj3c0", encode(&buf, &raw));
    }
    {
        // A SHA-256: 256 bits in 52 digits, with four bits of padding.
        var raw: [32]u8 = undefined;
        try std.base64.standard.Decoder.decode(&raw, "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=");
        var buf: [52]u8 = undefined;
        try std.testing.expectEqualStrings("1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s", encode(&buf, &raw));
    }
    {
        var buf: [0]u8 = undefined;
        try std.testing.expectEqualStrings("", encode(&buf, ""));
    }
}

test "encode and decode are inverses" {
    var prng: std.Random.DefaultPrng = .init(0x6e69783332);
    const random = prng.random();

    // Every length up to a SHA-512 and a little past, which covers every
    // amount of padding the first character can carry.
    for (0..70) |len| {
        var raw: [70]u8 = undefined;
        random.bytes(raw[0..len]);

        var text: [encodedLen(70)]u8 = undefined;
        const encoded = encode(&text, raw[0..len]);
        try std.testing.expectEqual(encodedLen(len), encoded.len);

        var back: [70]u8 = undefined;
        try std.testing.expectEqualSlices(u8, raw[0..len], try decode(&back, encoded));
    }
}
