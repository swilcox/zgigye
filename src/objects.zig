//! The version-3 object table (spec chapter 12).
//!
//! Layout: 31 words of property defaults, then 9-byte object entries.
//! Each entry is 4 attribute bytes, parent/sibling/child bytes, and a
//! word pointing at the object's property table.

const std = @import("std");
const memory = @import("memory.zig");
const Memory = memory.Memory;

pub const Error = error{
    InvalidObject,
    InvalidAttribute,
    MissingProperty,
} || memory.Error;

const object_size = 9;
const attr_bytes = 4;
const default_count = 31;

const parent_offset = attr_bytes; // +4
const sibling_offset = attr_bytes + 1; // +5
const child_offset = attr_bytes + 2; // +6
const properties_offset = attr_bytes + 3; // +7

pub const Property = struct {
    number: u8,
    size: u8,
    /// Address of the property's data bytes.
    data_addr: u32,
};

pub const ObjectTable = struct {
    mem: *Memory,
    /// Address of the property defaults table (from the header).
    base: u16,

    fn objectAddr(self: ObjectTable, obj: u16) Error!u32 {
        if (obj == 0) return Error.InvalidObject;
        return self.base + default_count * 2 + (@as(u32, obj) - 1) * object_size;
    }

    // --- Tree relations ---
    // Games sometimes ask about "nothing" (object 0); its relations are 0.

    pub fn parent(self: ObjectTable, obj: u16) Error!u16 {
        if (obj == 0) return 0;
        return try self.mem.readByte(try self.objectAddr(obj) + parent_offset);
    }

    pub fn sibling(self: ObjectTable, obj: u16) Error!u16 {
        if (obj == 0) return 0;
        return try self.mem.readByte(try self.objectAddr(obj) + sibling_offset);
    }

    pub fn child(self: ObjectTable, obj: u16) Error!u16 {
        if (obj == 0) return 0;
        return try self.mem.readByte(try self.objectAddr(obj) + child_offset);
    }

    pub fn setParent(self: ObjectTable, obj: u16, value: u16) Error!void {
        try self.mem.writeByte(try self.objectAddr(obj) + parent_offset, @intCast(value));
    }

    pub fn setSibling(self: ObjectTable, obj: u16, value: u16) Error!void {
        try self.mem.writeByte(try self.objectAddr(obj) + sibling_offset, @intCast(value));
    }

    pub fn setChild(self: ObjectTable, obj: u16, value: u16) Error!void {
        try self.mem.writeByte(try self.objectAddr(obj) + child_offset, @intCast(value));
    }

    /// Detach an object from its parent, splicing the sibling chain.
    pub fn remove(self: ObjectTable, obj: u16) Error!void {
        const old_parent = try self.parent(obj);
        if (old_parent == 0) return;

        const younger = try self.sibling(obj);
        if (try self.child(old_parent) == obj) {
            try self.setChild(old_parent, younger);
        } else {
            // Find the sibling that points at obj.
            var prev = try self.child(old_parent);
            while (try self.sibling(prev) != obj) prev = try self.sibling(prev);
            try self.setSibling(prev, younger);
        }
        try self.setParent(obj, 0);
        try self.setSibling(obj, 0);
    }

    /// Move an object to be the first child of a destination.
    pub fn insertInto(self: ObjectTable, obj: u16, destination: u16) Error!void {
        if (try self.child(destination) == obj) return;
        try self.remove(obj);
        try self.setSibling(obj, try self.child(destination));
        try self.setChild(destination, obj);
        try self.setParent(obj, destination);
    }

    // --- Attributes (32 flags per object) ---

    fn attrLocation(self: ObjectTable, obj: u16, attr: u16) Error!struct { addr: u32, mask: u8 } {
        if (attr >= attr_bytes * 8) return Error.InvalidAttribute;
        return .{
            .addr = try self.objectAddr(obj) + attr / 8,
            .mask = @as(u8, 0x80) >> @intCast(attr % 8),
        };
    }

    pub fn testAttr(self: ObjectTable, obj: u16, attr: u16) Error!bool {
        const loc = try self.attrLocation(obj, attr);
        return try self.mem.readByte(loc.addr) & loc.mask != 0;
    }

    pub fn setAttr(self: ObjectTable, obj: u16, attr: u16) Error!void {
        const loc = try self.attrLocation(obj, attr);
        try self.mem.writeByte(loc.addr, try self.mem.readByte(loc.addr) | loc.mask);
    }

    pub fn clearAttr(self: ObjectTable, obj: u16, attr: u16) Error!void {
        const loc = try self.attrLocation(obj, attr);
        try self.mem.writeByte(loc.addr, try self.mem.readByte(loc.addr) & ~loc.mask);
    }

    /// Number of objects. The table has no explicit count; by convention
    /// the entries run up to the lowest property table address (capped at
    /// 255, the v3 limit).
    pub fn count(self: ObjectTable) Error!u16 {
        const first = self.base + default_count * 2;
        var lowest_props: u32 = std.math.maxInt(u32);
        var n: u16 = 0;
        while (n < 255) {
            const addr = first + @as(u32, n) * object_size;
            if (addr + object_size > lowest_props) break;
            const props = try self.mem.readWord(addr + properties_offset);
            if (props != 0 and props < lowest_props) lowest_props = props;
            n += 1;
        }
        return n;
    }

    // --- Properties ---

    pub fn propertiesAddr(self: ObjectTable, obj: u16) Error!u32 {
        return try self.mem.readWord(try self.objectAddr(obj) + properties_offset);
    }

    /// Address of the object's short-name z-string, or null if unnamed.
    pub fn nameAddr(self: ObjectTable, obj: u16) Error!?u32 {
        if (obj == 0) return null;
        const addr = try self.propertiesAddr(obj);
        const words = try self.mem.readByte(addr);
        return if (words == 0) null else addr + 1;
    }

    pub fn defaultProperty(self: ObjectTable, number: u16) Error!u16 {
        if (number == 0 or number > default_count) return Error.MissingProperty;
        return self.mem.readWord(self.base + (@as(u32, number) - 1) * 2);
    }

    fn propertyAt(self: ObjectTable, addr: u32) Error!?Property {
        // Size byte: 32 * (size - 1) + number; zero terminates the list.
        const size_byte = try self.mem.readByte(addr);
        if (size_byte == 0) return null;
        return .{
            .number = size_byte & 0x1F,
            .size = size_byte / 32 + 1,
            .data_addr = addr + 1,
        };
    }

    pub fn firstProperty(self: ObjectTable, obj: u16) Error!?Property {
        const addr = try self.propertiesAddr(obj);
        const name_words = try self.mem.readByte(addr);
        return self.propertyAt(addr + 1 + @as(u32, name_words) * 2);
    }

    pub fn nextProperty(self: ObjectTable, prop: Property) Error!?Property {
        return self.propertyAt(prop.data_addr + prop.size);
    }

    /// Properties are stored in descending number order.
    pub fn findProperty(self: ObjectTable, obj: u16, number: u16) Error!?Property {
        var prop = try self.firstProperty(obj);
        while (prop) |p| : (prop = try self.nextProperty(p)) {
            if (p.number == number) return p;
            if (p.number < number) return null;
        }
        return null;
    }

    /// Recover a property's size from its data address (for get_prop_len).
    pub fn propertyLengthAt(self: ObjectTable, data_addr: u32) Error!u8 {
        if (data_addr == 0) return 0;
        return try self.mem.readByte(data_addr - 1) / 32 + 1;
    }
};

// --- Tests ---
//
// A tiny hand-built object table: defaults, then 3 objects.
//   1 "one"  parent=0 sibling=0 child=2
//   2 "two"  parent=1 sibling=3 child=0
//   3 (none) parent=1 sibling=0 child=0

fn buildTestTable(buf: []u8) ObjectTable {
    @memset(buf, 0);
    const base: u16 = 0;
    const objects = default_count * 2;
    buf[1] = 0x11; // default for property 1 = 0x0011

    const props_1: u16 = @intCast(objects + 3 * object_size);
    const entries = [3]struct { p: u8, s: u8, c: u8 }{
        .{ .p = 0, .s = 0, .c = 2 },
        .{ .p = 1, .s = 3, .c = 0 },
        .{ .p = 1, .s = 0, .c = 0 },
    };
    for (entries, 0..) |e, i| {
        const addr = objects + i * object_size;
        buf[addr + parent_offset] = e.p;
        buf[addr + sibling_offset] = e.s;
        buf[addr + child_offset] = e.c;
        const ptable: u16 = @intCast(props_1 + i * 16);
        buf[addr + properties_offset] = @intCast(ptable >> 8);
        buf[addr + properties_offset + 1] = @intCast(ptable & 0xFF);
    }
    // Object 1 property table: name "go" (1 word), prop 2 (2 bytes), prop 1 (1 byte).
    var p = props_1;
    buf[p] = 1; // name length in words
    const name = @import("zscii.zig").encodeWord("go");
    buf[p + 1] = @intCast(name[0] >> 8);
    buf[p + 2] = @intCast(name[0] & 0xFF);
    p += 3;
    buf[p] = 32 * (2 - 1) + 2; // prop 2, size 2
    buf[p + 1] = 0xAB;
    buf[p + 2] = 0xCD;
    p += 3;
    buf[p] = 32 * (1 - 1) + 1; // prop 1, size 1
    buf[p + 1] = 0x42;
    return .{ .mem = undefined, .base = base };
}

var test_buf: [512]u8 = undefined;
var test_mem: Memory = undefined;

fn testTable() ObjectTable {
    var table = buildTestTable(&test_buf);
    test_mem = .{ .bytes = &test_buf, .static_start = @intCast(test_buf.len) };
    table.mem = &test_mem;
    return table;
}

test "tree relations and remove/insert" {
    const t = testTable();
    try std.testing.expectEqual(@as(u16, 2), try t.child(1));
    try std.testing.expectEqual(@as(u16, 3), try t.sibling(2));

    // Remove the middle child: 3 becomes first child of 1.
    try t.remove(2);
    try std.testing.expectEqual(@as(u16, 3), try t.child(1));
    try std.testing.expectEqual(@as(u16, 0), try t.parent(2));

    // Insert it back at the front.
    try t.insertInto(2, 1);
    try std.testing.expectEqual(@as(u16, 2), try t.child(1));
    try std.testing.expectEqual(@as(u16, 3), try t.sibling(2));
}

test "count infers the table size from the first property table" {
    const t = testTable();
    try std.testing.expectEqual(@as(u16, 3), try t.count());
}

test "attributes set, test, clear" {
    const t = testTable();
    try std.testing.expect(!try t.testAttr(1, 17));
    try t.setAttr(1, 17);
    try std.testing.expect(try t.testAttr(1, 17));
    try std.testing.expect(!try t.testAttr(1, 16)); // neighbors untouched
    try t.clearAttr(1, 17);
    try std.testing.expect(!try t.testAttr(1, 17));
    try std.testing.expectError(Error.InvalidAttribute, t.testAttr(1, 32));
}

test "property lookup and defaults" {
    const t = testTable();
    const p2 = (try t.findProperty(1, 2)).?;
    try std.testing.expectEqual(@as(u8, 2), p2.size);
    try std.testing.expectEqual(@as(u16, 0xABCD), try t.mem.readWord(p2.data_addr));

    const p1 = (try t.findProperty(1, 1)).?;
    try std.testing.expectEqual(@as(u8, 1), p1.size);
    try std.testing.expectEqual(@as(u8, 0x42), try t.mem.readByte(p1.data_addr));

    try std.testing.expectEqual(@as(?Property, null), try t.findProperty(1, 5));
    try std.testing.expectEqual(@as(u16, 0x11), try t.defaultProperty(1));
    try std.testing.expectEqual(@as(u8, 2), try t.propertyLengthAt(p2.data_addr));
}
