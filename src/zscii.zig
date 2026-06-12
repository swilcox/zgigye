//! ZSCII text: decoding z-strings and encoding dictionary words.
//!
//! Z-characters are 5 bits, packed three to a 16-bit word; the top bit of
//! a word marks the end of the string. This module implements the version-3
//! alphabets and rules (spec chapter 3).

const std = @import("std");
const Memory = @import("memory.zig").Memory;

pub const alphabet_0 = "abcdefghijklmnopqrstuvwxyz";
pub const alphabet_1 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
/// Positions 0 and 1 (z-characters 6 and 7) are the 10-bit escape and
/// newline; the placeholders here are never printed directly.
pub const alphabet_2 = " \n0123456789.,!?_#'\"/\\-:()";

const alphabets = [3][]const u8{ alphabet_0, alphabet_1, alphabet_2 };

/// Default mapping for ZSCII codes 155-223 (spec table 1).
const default_unicode = [_]u21{
    0xE4, 0xF6, 0xFC, 0xC4, 0xD6, 0xDC, 0xDF, 0xBB, 0xAB, 0xEB, // 155
    0xEF, 0xFF, 0xCB, 0xCF, 0xE1, 0xE9, 0xED, 0xF3, 0xFA, 0xFD, // 165
    0xC1, 0xC9, 0xCD, 0xD3, 0xDA, 0xDD, 0xE0, 0xE8, 0xEC, 0xF2, // 175
    0xF9, 0xC0, 0xC8, 0xCC, 0xD2, 0xD9, 0xE2, 0xEA, 0xEE, 0xF4, // 185
    0xFB, 0xC2, 0xCA, 0xCE, 0xD4, 0xDB, 0xE5, 0xC5, 0xF8, 0xD8, // 195
    0xE3, 0xF1, 0xF5, 0xC3, 0xD1, 0xD5, 0xE6, 0xC6, 0xE7, 0xC7, // 205
    0xFE, 0xF0, 0xDE, 0xD0, 0xA3, 0x153, 0x152, 0xA1, 0xBF, // 215..223
};

pub const Error = error{
    NestedAbbreviation,
    WriteFailed,
} || @import("memory.zig").Error;

/// Decode the z-string at `addr`, writing UTF-8 text to `out`.
pub fn decode(mem: *const Memory, abbreviations: u16, addr: u32, out: *std.Io.Writer) Error!void {
    try decodeInner(mem, abbreviations, addr, out, true);
}

/// Number of bytes occupied by the z-string at `addr`.
pub fn stringLength(mem: *const Memory, addr: u32) Error!u32 {
    var pos = addr;
    while (try mem.readWord(pos) & 0x8000 == 0) pos += 2;
    return pos + 2 - addr;
}

fn decodeInner(
    mem: *const Memory,
    abbreviations: u16,
    addr: u32,
    out: *std.Io.Writer,
    allow_abbrev: bool,
) Error!void {
    const Mode = enum { normal, abbrev, ten_high, ten_low };
    var mode: Mode = .normal;
    var shift: u2 = 0; // alphabet applied to the next literal character
    var abbrev_bank: u16 = 0;
    var ten_acc: u16 = 0;

    var pos = addr;
    while (true) {
        const word = try mem.readWord(pos);
        pos += 2;
        const zchars = [3]u5{
            @truncate(word >> 10),
            @truncate(word >> 5),
            @truncate(word),
        };
        for (zchars) |z| {
            switch (mode) {
                .abbrev => {
                    if (!allow_abbrev) return Error.NestedAbbreviation;
                    const entry = abbreviations + 2 * (32 * (abbrev_bank - 1) + z);
                    const string_addr = @as(u32, try mem.readWord(@intCast(entry))) * 2;
                    try decodeInner(mem, abbreviations, string_addr, out, false);
                    mode = .normal;
                },
                .ten_high => {
                    ten_acc = @as(u16, z) << 5;
                    mode = .ten_low;
                },
                .ten_low => {
                    try writeZscii(ten_acc | z, out);
                    mode = .normal;
                },
                .normal => {
                    const alphabet = shift;
                    shift = 0;
                    switch (z) {
                        0 => try writeAll(out, " "),
                        1, 2, 3 => {
                            mode = .abbrev;
                            abbrev_bank = z;
                        },
                        4 => shift = 1,
                        5 => shift = 2,
                        else => if (alphabet == 2 and z == 6) {
                            mode = .ten_high;
                        } else if (alphabet == 2 and z == 7) {
                            try writeAll(out, "\n");
                        } else {
                            try writeAll(out, alphabets[alphabet][z - 6 .. z - 5]);
                        },
                    }
                },
            }
        }
        if (word & 0x8000 != 0) return;
    }
}

/// Write a single ZSCII output code as UTF-8.
pub fn writeZscii(code: u16, out: *std.Io.Writer) Error!void {
    switch (code) {
        0 => {}, // "no effect" (spec 3.8.2.1)
        13 => try writeAll(out, "\n"),
        32...126 => try writeAll(out, &.{@intCast(code)}),
        155...223 => {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(default_unicode[code - 155], &buf) catch unreachable;
            try writeAll(out, buf[0..len]);
        },
        224...251 => try writeAll(out, "?"), // extra chars without a table
        else => {}, // undefined codes print nothing
    }
}

fn writeAll(out: *std.Io.Writer, bytes: []const u8) Error!void {
    out.writeAll(bytes) catch return Error.WriteFailed;
}

/// A version-3 encoded dictionary word: 6 z-characters in 2 words.
pub const EncodedWord = [2]u16;

/// Encode (lowercased) input text as a dictionary key (spec 3.7).
/// Characters outside the alphabets use the 10-bit ZSCII escape.
pub fn encodeWord(text: []const u8) EncodedWord {
    var zchars: [6]u5 = @splat(5); // pad with shift-5 (spec 3.7)
    var n: usize = 0;
    for (text) |c| {
        if (n >= zchars.len) break;
        if (std.mem.indexOfScalar(u8, alphabet_0, c)) |i| {
            zchars[n] = @intCast(i + 6);
            n += 1;
        } else if (std.mem.indexOfScalarPos(u8, alphabet_2, 2, c)) |i| {
            push2(&zchars, &n, 5, @intCast(i + 6));
        } else {
            // 10-bit escape: 5, 6, then the ZSCII code in two 5-bit halves.
            push2(&zchars, &n, 5, 6);
            push2(&zchars, &n, @truncate(c >> 5), @truncate(c & 0x1F));
        }
    }
    return .{
        @as(u16, zchars[0]) << 10 | @as(u16, zchars[1]) << 5 | zchars[2],
        0x8000 | @as(u16, zchars[3]) << 10 | @as(u16, zchars[4]) << 5 | zchars[5],
    };
}

fn push2(zchars: *[6]u5, n: *usize, a: u5, b: u5) void {
    if (n.* < zchars.len) {
        zchars.*[n.*] = a;
        n.* += 1;
    }
    if (n.* < zchars.len) {
        zchars.*[n.*] = b;
        n.* += 1;
    }
}

fn decodeToString(buf: []u8, words: []const u16) ![]u8 {
    var bytes: [32]u8 = undefined;
    for (words, 0..) |w, i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], w, .big);
    const mem = Memory{ .bytes = bytes[0 .. words.len * 2], .static_start = 0 };
    var writer = std.Io.Writer.fixed(buf);
    try decode(&mem, 0, 0, &writer);
    return writer.buffered();
}

test "encode/decode round-trips simple words" {
    var buf: [32]u8 = undefined;
    const encoded = encodeWord("hello");
    try std.testing.expectEqualStrings("hello", try decodeToString(&buf, &encoded));
}

test "encode uses A2 for digits and punctuation" {
    var buf: [32]u8 = undefined;
    const encoded = encodeWord("x1.");
    try std.testing.expectEqualStrings("x1.", try decodeToString(&buf, &encoded));
}

test "encode truncates to six z-characters" {
    var buf: [32]u8 = undefined;
    const encoded = encodeWord("northeast");
    try std.testing.expectEqualStrings("northe", try decodeToString(&buf, &encoded));
}

test "decode handles shifts, spaces, and 10-bit escapes" {
    var buf: [32]u8 = undefined;
    // "Hi 5" = shift(4),h(13), i(14),space(0),shift(5) | digit5(13),pad,pad
    const words = [2]u16{
        4 << 10 | 13 << 5 | 14,
        0x8000 | 0 << 10 | 5 << 5 | 13,
    };
    try std.testing.expectEqualStrings("Hi 5", try decodeToString(&buf, &words));

    // 10-bit escape for '@' (64): 5,6,2 | 0,pad,pad
    const escape = [2]u16{
        5 << 10 | 6 << 5 | 2,
        0x8000 | 0 << 10 | 5 << 5 | 5,
    };
    try std.testing.expectEqualStrings("@", try decodeToString(&buf, &escape));
}

test "stringLength counts to the terminator word" {
    var bytes = [_]u8{ 0x00, 0x01, 0x80, 0x02 };
    const mem = Memory{ .bytes = &bytes, .static_start = 0 };
    try std.testing.expectEqual(@as(u32, 4), try stringLength(&mem, 0));
}
