//! The story file header (the first 64 bytes of memory).
//!
//! Fields here are the static values read once at load time. Anything the
//! game can change at runtime (flags) is read from memory when needed.

const std = @import("std");

pub const StatusLineType = enum { score, time };

pub const Error = error{
    StoryTooSmall,
    UnsupportedVersion,
};

pub const Header = struct {
    version: u8,
    release: u16,
    high_memory: u16,
    initial_pc: u16,
    dictionary: u16,
    /// Address of the property defaults table; objects follow it.
    object_table: u16,
    globals: u16,
    static_memory: u16,
    serial: [6]u8,
    abbreviations: u16,
    /// Unpacked length in bytes (the header stores it divided by 2 in v3).
    file_length: u32,
    checksum: u16,
    status_line_type: StatusLineType,

    pub fn parse(bytes: []const u8) Error!Header {
        if (bytes.len < 64) return Error.StoryTooSmall;
        const version = bytes[0];
        if (version != 3) return Error.UnsupportedVersion;
        const flags1 = bytes[0x01];
        return .{
            .version = version,
            .release = word(bytes, 0x02),
            .high_memory = word(bytes, 0x04),
            .initial_pc = word(bytes, 0x06),
            .dictionary = word(bytes, 0x08),
            .object_table = word(bytes, 0x0A),
            .globals = word(bytes, 0x0C),
            .static_memory = word(bytes, 0x0E),
            .serial = bytes[0x12..0x18].*,
            .abbreviations = word(bytes, 0x18),
            .file_length = @as(u32, word(bytes, 0x1A)) * 2,
            .checksum = word(bytes, 0x1C),
            .status_line_type = if (flags1 & 0x02 != 0) .time else .score,
        };
    }

    fn word(bytes: []const u8, addr: usize) u16 {
        return std.mem.readInt(u16, bytes[addr..][0..2], .big);
    }
};

test "parse rejects non-v3 stories" {
    var bytes = [_]u8{0} ** 64;
    bytes[0] = 5;
    try std.testing.expectError(Error.UnsupportedVersion, Header.parse(&bytes));
    try std.testing.expectError(Error.StoryTooSmall, Header.parse(bytes[0..10]));
}

test "parse reads v3 fields" {
    var bytes = [_]u8{0} ** 64;
    bytes[0] = 3;
    bytes[0x06] = 0x12;
    bytes[0x07] = 0x34;
    bytes[0x1A] = 0x00;
    bytes[0x1B] = 0x10;
    const h = try Header.parse(&bytes);
    try std.testing.expectEqual(@as(u16, 0x1234), h.initial_pc);
    try std.testing.expectEqual(@as(u32, 0x20), h.file_length);
    try std.testing.expectEqual(StatusLineType.score, h.status_line_type);
}
