//! Dictionary lookup and input tokenisation (spec chapter 13).

const std = @import("std");
const memory = @import("memory.zig");
const zscii = @import("zscii.zig");
const Memory = memory.Memory;

pub const Error = memory.Error;

pub const Dictionary = struct {
    mem: *const Memory,
    /// Word separator characters (a slice into story memory).
    separators: []const u8,
    entry_length: u8,
    entry_count: u16,
    entries_addr: u32,

    pub fn init(mem: *const Memory, addr: u16) Error!Dictionary {
        var cur = mem.cursor(addr);
        const separator_count = try cur.byte();
        const separators_addr = cur.pos;
        cur.pos += separator_count;
        const entry_length = try cur.byte();
        const entry_count = try cur.word();
        return .{
            .mem = mem,
            .separators = mem.bytes[separators_addr .. separators_addr + separator_count],
            .entry_length = entry_length,
            .entry_count = entry_count,
            .entries_addr = cur.pos,
        };
    }

    pub fn isSeparator(self: *const Dictionary, c: u8) bool {
        return std.mem.indexOfScalar(u8, self.separators, c) != null;
    }

    /// Byte address of the dictionary entry matching `word`, or 0.
    pub fn lookup(self: *const Dictionary, word: []const u8) Error!u16 {
        const encoded = zscii.encodeWord(word);
        for (0..self.entry_count) |i| {
            const addr: u32 = @intCast(self.entries_addr + i * self.entry_length);
            if (try self.mem.readWord(addr) == encoded[0] and
                try self.mem.readWord(addr + 2) == encoded[1])
            {
                return @intCast(addr);
            }
        }
        return 0;
    }
};

/// One word of player input: where it sits in the text buffer and its
/// dictionary address (0 if unrecognised).
pub const Token = struct {
    dict_addr: u16,
    /// Offset of the word within the text buffer.
    position: u8,
    length: u8,
};

/// Split `text` (the contents of the text buffer, starting at buffer
/// offset `start`) into words. Separators count as words themselves;
/// spaces only divide. Calls `emit` for each token found.
pub fn forEachToken(
    dict: *const Dictionary,
    text: []const u8,
    start: u8,
    context: anytype,
    comptime emit: fn (@TypeOf(context), Token) anyerror!void,
) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == ' ') {
            i += 1;
        } else if (dict.isSeparator(text[i])) {
            try emit(context, try makeToken(dict, text[i .. i + 1], start + i));
            i += 1;
        } else {
            const word_start = i;
            while (i < text.len and text[i] != ' ' and !dict.isSeparator(text[i])) i += 1;
            try emit(context, try makeToken(dict, text[word_start..i], start + word_start));
        }
    }
}

fn makeToken(dict: *const Dictionary, word: []const u8, position: usize) !Token {
    return .{
        .dict_addr = try dict.lookup(word),
        .position = @intCast(position),
        .length = @intCast(word.len),
    };
}

// --- Tests ---

fn buildTestDictionary(buf: []u8) !Dictionary {
    @memset(buf, 0);
    // 1 separator (','), entry length 7, 2 entries: "look", "take"
    buf[0] = 1;
    buf[1] = ',';
    buf[2] = 7;
    buf[3] = 0;
    buf[4] = 2;
    var addr: usize = 5;
    for ([_][]const u8{ "look", "take" }) |w| {
        const enc = zscii.encodeWord(w);
        std.mem.writeInt(u16, buf[addr..][0..2], enc[0], .big);
        std.mem.writeInt(u16, buf[addr + 2 ..][0..2], enc[1], .big);
        addr += 7;
    }
    return .{
        .mem = undefined,
        .separators = buf[1..2],
        .entry_length = 7,
        .entry_count = 2,
        .entries_addr = 5,
    };
}

var test_buf: [64]u8 = undefined;
var test_mem: Memory = undefined;

test "lookup finds entries and misses unknown words" {
    var dict = try buildTestDictionary(&test_buf);
    test_mem = .{ .bytes = &test_buf, .static_start = 0 };
    dict.mem = &test_mem;

    try std.testing.expectEqual(@as(u16, 5), try dict.lookup("look"));
    try std.testing.expectEqual(@as(u16, 12), try dict.lookup("take"));
    try std.testing.expectEqual(@as(u16, 0), try dict.lookup("xyzzy"));
}

test "tokenise splits on spaces and separators" {
    var dict = try buildTestDictionary(&test_buf);
    test_mem = .{ .bytes = &test_buf, .static_start = 0 };
    dict.mem = &test_mem;

    const Collect = struct {
        tokens: [8]Token = undefined,
        count: usize = 0,
        fn emit(self: *@This(), token: Token) !void {
            self.tokens[self.count] = token;
            self.count += 1;
        }
    };
    var c = Collect{};
    try forEachToken(&dict, "look up,take", 1, &c, Collect.emit);

    try std.testing.expectEqual(@as(usize, 4), c.count);
    // "look" at buffer offset 1, found in dictionary
    try std.testing.expectEqual(@as(u16, 5), c.tokens[0].dict_addr);
    try std.testing.expectEqual(@as(u8, 1), c.tokens[0].position);
    try std.testing.expectEqual(@as(u8, 4), c.tokens[0].length);
    // "up" unknown, offset 6
    try std.testing.expectEqual(@as(u16, 0), c.tokens[1].dict_addr);
    try std.testing.expectEqual(@as(u8, 6), c.tokens[1].position);
    // "," is its own token at offset 8
    try std.testing.expectEqual(@as(u8, 8), c.tokens[2].position);
    try std.testing.expectEqual(@as(u8, 1), c.tokens[2].length);
    // "take" at offset 9
    try std.testing.expectEqual(@as(u16, 12), c.tokens[3].dict_addr);
    try std.testing.expectEqual(@as(u8, 9), c.tokens[3].position);
}
