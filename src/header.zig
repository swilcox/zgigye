//! The story file header (the first 64 bytes of memory).
//!
//! Fields here are the static values read once at load time. Anything the
//! game can change at runtime (flags) is read from memory when needed.
//!
//! A story file is untrusted input: it may be hand-edited, truncated, or
//! hostile. Every address the header hands out is therefore checked against
//! the file's actual length here, once, so the rest of the interpreter can
//! treat those addresses as being inside memory. In particular the static
//! memory mark bounds every write the game makes (see memory.zig), so a
//! story claiming a mark past the end of the file would otherwise turn the
//! write guard into an out-of-bounds write.

const std = @import("std");

pub const StatusLineType = enum { score, time };

pub const Error = error{
    StoryTooSmall,
    UnsupportedVersion,
    MalformedHeader,
};

/// Sizes of the tables the header points at, in bytes. Each must fit
/// inside the story file for the addresses in the header to be usable.
const globals_size = 240 * 2;
/// 31 property defaults; the object entries follow immediately.
const property_defaults_size = 31 * 2;
/// Three banks of 32 entries, each a word (spec 3.3).
const abbreviations_size = 3 * 32 * 2;

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
        const header: Header = .{
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
        try header.validate(bytes.len);
        return header;
    }

    /// Reject a header whose addresses do not fit in a story of `file_len`
    /// bytes. Only the tables the interpreter actually indexes are checked,
    /// and only for the space it can actually reach: the object and
    /// dictionary tables are variable-length and self-describing, so their
    /// entries stay bounded by the ordinary memory checks.
    fn validate(self: Header, file_len: usize) Error!void {
        // Dynamic memory runs from 0 to the static mark, and every write the
        // game makes is bounded by it, so it must lie inside the file. It
        // must also clear the header itself, which is dynamic memory.
        if (self.static_memory < 64 or self.static_memory > file_len) return Error.MalformedHeader;

        if (!fits(self.globals, globals_size, file_len)) return Error.MalformedHeader;
        if (!fits(self.object_table, property_defaults_size, file_len)) return Error.MalformedHeader;
        if (!fits(self.dictionary, 4, file_len)) return Error.MalformedHeader; // counts, then entries
        // Zero means "no abbreviations"; games without any leave it unset.
        if (self.abbreviations != 0 and !fits(self.abbreviations, abbreviations_size, file_len))
            return Error.MalformedHeader;

        // Execution starts here, so at least one opcode byte must exist.
        if (self.initial_pc >= file_len) return Error.MalformedHeader;
    }

    /// Does a table of `size` bytes at `addr` fit within `file_len`?
    fn fits(addr: u16, size: u32, file_len: usize) bool {
        return @as(u64, addr) + size <= file_len;
    }

    fn word(bytes: []const u8, addr: usize) u16 {
        return std.mem.readInt(u16, bytes[addr..][0..2], .big);
    }
};

// --- Tests ---

const story_len = 2048;

/// A minimal but internally consistent v3 header, laid out in a story of
/// `story_len` bytes. Tests corrupt one field at a time from this baseline.
fn validStory() [story_len]u8 {
    var bytes: [story_len]u8 = @splat(0);
    bytes[0] = 3;
    setWord(&bytes, 0x06, 0x0400); // initial_pc
    setWord(&bytes, 0x08, 0x0300); // dictionary
    setWord(&bytes, 0x0A, 0x0100); // object_table
    setWord(&bytes, 0x0C, 0x0180); // globals (needs 480 bytes: ends at 0x360)
    setWord(&bytes, 0x0E, 0x0500); // static_memory
    setWord(&bytes, 0x18, 0x0040); // abbreviations (needs 192 bytes)
    setWord(&bytes, 0x1A, 0x0400); // file_length / 2
    return bytes;
}

fn setWord(bytes: []u8, addr: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[addr..][0..2], value, .big);
}

test "parse rejects non-v3 stories" {
    var bytes = validStory();
    bytes[0] = 5;
    try std.testing.expectError(Error.UnsupportedVersion, Header.parse(&bytes));
    try std.testing.expectError(Error.StoryTooSmall, Header.parse(bytes[0..10]));
}

test "parse reads v3 fields" {
    var bytes = validStory();
    const h = try Header.parse(&bytes);
    try std.testing.expectEqual(@as(u16, 0x0400), h.initial_pc);
    try std.testing.expectEqual(@as(u16, 0x0500), h.static_memory);
    try std.testing.expectEqual(@as(u32, 0x0800), h.file_length);
    try std.testing.expectEqual(StatusLineType.score, h.status_line_type);
}

test "parse rejects addresses that do not fit the story" {
    // Each case moves one header field past the end of the file (or, for
    // the static mark, below the header) and must be rejected. A story that
    // got past this check would make the memory write guard unsound.
    const cases = [_]struct { name: []const u8, addr: usize, value: u16 }{
        .{ .name = "static memory past the end", .addr = 0x0E, .value = 0xFFFF },
        .{ .name = "static memory inside the header", .addr = 0x0E, .value = 0x20 },
        .{ .name = "globals table overruns", .addr = 0x0C, .value = story_len - 100 },
        .{ .name = "object table overruns", .addr = 0x0A, .value = story_len - 10 },
        .{ .name = "dictionary past the end", .addr = 0x08, .value = 0xFFFF },
        .{ .name = "abbreviations overrun", .addr = 0x18, .value = story_len - 10 },
        .{ .name = "initial pc past the end", .addr = 0x06, .value = 0xFFFF },
    };
    for (cases) |case| {
        var bytes = validStory();
        setWord(&bytes, case.addr, case.value);
        std.testing.expectError(Error.MalformedHeader, Header.parse(&bytes)) catch |err| {
            std.debug.print("case '{s}' was not rejected\n", .{case.name});
            return err;
        };
    }
}

test "an unset abbreviations table is allowed" {
    // Zero means "no abbreviations", not "a table at address 0".
    var bytes = validStory();
    setWord(&bytes, 0x18, 0);
    const h = try Header.parse(&bytes);
    try std.testing.expectEqual(@as(u16, 0), h.abbreviations);
}
