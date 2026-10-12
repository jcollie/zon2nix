// SPDX-FileCopyrightText: 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
//
// SPDX-License-Identifier: MIT

//! Reports what zon2nix is doing to the terminal, with the Program Status
//! Protocol, OSC 7501: working while it fetches, with a percentage, then done
//! or failed. A terminal that knows the protocol can show it in a tab, a
//! progress bar or a notification; one that does not ignores the sequence.
//!
//! ```
//! ESC ] 7501 ; state=working:app=zon2nix:progress=40:msg=<base64> ESC \
//! ```
//!
//! Each report replaces the whole of the previous one, so every report
//! carries everything. There is only ever the one record -- no `id` -- since
//! zon2nix reports on itself and nothing else.

const ProgramStatus = @This();

const std = @import("std");

/// The `app` every report carries: a stable name for a terminal to match on,
/// rather than a label for people, which is `title`.
pub const app = "zon2nix";

/// The limits on `title` and `msg`, in bytes of text before encoding.
pub const max_title_bytes = 192;
pub const max_msg_bytes = 2048;

pub const State = enum {
    /// Running. May carry a progress percentage.
    working,
    /// Finished. Unlike `working`, this outlives the process, which is the
    /// point: a long fetch in another tab is found finished afterwards.
    done,
    /// Failed. Outlives the process, as `done` does.
    @"error",
};

pub const Report = struct {
    state: State,
    /// From 0 to 100, and only sent while working. Null is indeterminate.
    progress: ?u8 = null,
    /// A short label, such as the name of the project.
    title: ?[]const u8 = null,
    /// One line saying what is going on.
    msg: ?[]const u8 = null,
};

io: std.Io,
/// Off when stderr is not a terminal, or when `--no-status` says so; then
/// `send` does nothing. A sequence written into a log file or a pipe is only
/// noise for whoever reads it.
enabled: bool,
/// Given to every report, so that a record names the project it is about.
title: ?[]const u8 = null,

/// On if stderr is a terminal that takes escape sequences.
pub fn init(io: std.Io, want: bool) ProgramStatus {
    const enabled = want and (std.Io.File.stderr().supportsAnsiEscapeCodes(io) catch false);
    return .{ .io = io, .enabled = enabled };
}

/// Writes `report` to stderr. Stderr is locked for it, so that it does not
/// land in the middle of a log line from another thread; and a report that
/// cannot be written is dropped, since it is only ever a courtesy.
pub fn send(self: *const ProgramStatus, report: Report) void {
    if (!self.enabled) return;
    var r = report;
    if (r.title == null) r.title = self.title;
    var buffer: [256]u8 = undefined;
    const stderr = self.io.lockStderr(&buffer, null) catch return;
    defer self.io.unlockStderr();
    const w = &stderr.file_writer.interface;
    write(w, r) catch return;
    w.flush() catch return;
}

/// Writes `report` as one OSC 7501 sequence.
pub fn write(w: *std.Io.Writer, report: Report) std.Io.Writer.Error!void {
    try w.print("\x1b]7501;state={t}:app=" ++ app, .{report.state});
    if (report.state == .working) {
        if (report.progress) |progress| try w.print(":progress={d}", .{@min(progress, 100)});
    }
    if (report.title) |title| try writeText(w, "title", title, max_title_bytes);
    if (report.msg) |msg| try writeText(w, "msg", msg, max_msg_bytes);
    try w.writeAll("\x1b\\");
}

/// Writes `:key=` and `text` in base64, made safe and short enough first.
fn writeText(w: *std.Io.Writer, comptime key: []const u8, text: []const u8, comptime max: usize) std.Io.Writer.Error!void {
    var buf: [max]u8 = undefined;
    const clean = sanitize(&buf, text);
    if (clean.len == 0) return;
    try w.writeAll(":" ++ key ++ "=");
    try std.base64.standard.Encoder.encodeWriter(w, clean);
}

/// Copies as much of `text` into `buf` as fits whole, with each control
/// character and each byte that is not UTF-8 made a `?`. A terminal throws
/// out a report whose text has either, and the text here comes out of
/// manifests -- a URL, a path -- which nothing promises are clean.
fn sanitize(buf: []u8, text: []const u8) []const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const length: ?u3 = std.unicode.utf8ByteSequenceLength(text[i]) catch null;
        const n: usize = length orelse 1;
        const cp: ?u21 = if (length != null and i + n <= text.len)
            std.unicode.utf8Decode(text[i..][0..n]) catch null
        else
            null;
        const ok = if (cp) |c| !(c < 0x20 or (c >= 0x7f and c < 0xa0)) else false;
        const bytes: []const u8 = if (ok) text[i..][0..n] else "?";
        if (len + bytes.len > buf.len) break;
        @memcpy(buf[len..][0..bytes.len], bytes);
        len += bytes.len;
        i += if (cp != null) n else 1;
    }
    return buf[0..len];
}

test write {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .{ .state = .working, .progress = 40, .msg = "fetching" });
    try std.testing.expectEqualStrings(
        "\x1b]7501;state=working:app=zon2nix:progress=40:msg=ZmV0Y2hpbmc=\x1b\\",
        w.buffered(),
    );
}

test "progress is sent only while working" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .{ .state = .done, .progress = 100, .title = "ghostty" });
    try std.testing.expectEqualStrings(
        "\x1b]7501;state=done:app=zon2nix:title=Z2hvc3R0eQ==\x1b\\",
        w.buffered(),
    );
}

test "error is spelled as the protocol spells it" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .{ .state = .@"error" });
    try std.testing.expectEqualStrings("\x1b]7501;state=error:app=zon2nix\x1b\\", w.buffered());
}

test sanitize {
    var buf: [16]u8 = undefined;
    // A newline, a C1 control in UTF-8, and a byte that is not UTF-8.
    try std.testing.expectEqualStrings("a?b?c?d", sanitize(&buf, "a\nb\xc2\x85c\xffd"));
    // Multi-byte text that is fine is kept as it is.
    try std.testing.expectEqualStrings("caf\u{e9}", sanitize(&buf, "caf\u{e9}"));
    // Cut short of a character that would not fit whole.
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaa", sanitize(&buf, "aaaaaaaaaaaaaaa\u{e9}"));
    // A sequence cut off by the end of the text.
    try std.testing.expectEqualStrings("a?", sanitize(&buf, "a\xc3"));
}
