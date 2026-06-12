//! Byte-addressed story memory with big-endian word access.
//!
//! The z-machine divides memory into dynamic (writable by the game),
//! static, and high memory. Reads may touch anything; writes are only
//! legal below the static memory mark.

const std = @import("std");

pub const Error = error{
    AddressOutOfRange,
    WriteToStaticMemory,
};

pub const Memory = struct {
    bytes: []u8,
    /// Byte address where static memory begins; writes below this only.
    static_start: u32,

    pub fn readByte(self: *const Memory, addr: u32) Error!u8 {
        if (addr >= self.bytes.len) return Error.AddressOutOfRange;
        return self.bytes[addr];
    }

    pub fn readWord(self: *const Memory, addr: u32) Error!u16 {
        if (addr + 1 >= self.bytes.len) return Error.AddressOutOfRange;
        return std.mem.readInt(u16, self.bytes[addr..][0..2], .big);
    }

    pub fn writeByte(self: *Memory, addr: u32, value: u8) Error!void {
        if (addr >= self.static_start) return Error.WriteToStaticMemory;
        self.bytes[addr] = value;
    }

    pub fn writeWord(self: *Memory, addr: u32, value: u16) Error!void {
        if (addr + 1 >= self.static_start) return Error.WriteToStaticMemory;
        std.mem.writeInt(u16, self.bytes[addr..][0..2], value, .big);
    }

    pub fn cursor(self: *const Memory, addr: u32) Cursor {
        return .{ .mem = self, .pos = addr };
    }
};

/// Sequential reader over memory, used by the instruction decoder and
/// routine-header parsing.
pub const Cursor = struct {
    mem: *const Memory,
    pos: u32,

    pub fn byte(self: *Cursor) Error!u8 {
        const value = try self.mem.readByte(self.pos);
        self.pos += 1;
        return value;
    }

    pub fn word(self: *Cursor) Error!u16 {
        const value = try self.mem.readWord(self.pos);
        self.pos += 2;
        return value;
    }
};

test "big-endian word access" {
    var bytes = [_]u8{ 0x12, 0x34, 0x00, 0x00 };
    var mem = Memory{ .bytes = &bytes, .static_start = 4 };
    try std.testing.expectEqual(@as(u16, 0x1234), try mem.readWord(0));
    try mem.writeWord(2, 0xBEEF);
    try std.testing.expectEqual(@as(u8, 0xBE), try mem.readByte(2));
    try std.testing.expectEqual(@as(u8, 0xEF), try mem.readByte(3));
}

test "writes to static memory are rejected" {
    var bytes = [_]u8{ 0, 0, 0, 0 };
    var mem = Memory{ .bytes = &bytes, .static_start = 2 };
    try mem.writeByte(1, 7);
    try std.testing.expectError(Error.WriteToStaticMemory, mem.writeByte(2, 7));
    try std.testing.expectError(Error.WriteToStaticMemory, mem.writeWord(1, 7));
}

test "cursor reads sequentially" {
    var bytes = [_]u8{ 0x01, 0x02, 0x03 };
    var mem = Memory{ .bytes = &bytes, .static_start = 0 };
    var cur = mem.cursor(0);
    try std.testing.expectEqual(@as(u8, 0x01), try cur.byte());
    try std.testing.expectEqual(@as(u16, 0x0203), try cur.word());
    try std.testing.expectEqual(@as(u32, 3), cur.pos);
}
