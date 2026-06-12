//! Instruction decoding (spec chapter 4).
//!
//! Decoding is side-effect free: variable operands are recorded as variable
//! numbers and resolved at execution time (resolving may pop the stack).

const std = @import("std");
const memory = @import("memory.zig");
const zscii = @import("zscii.zig");
const Memory = memory.Memory;

pub const Error = error{UnknownOpcode} || memory.Error || zscii.Error;

/// Opcodes are numbered by operand-count class, matching the conventional
/// decimal numbering: 2OP are 1-31, 1OP 128-143, 0OP 176-191, VAR 224-255.
/// A 2OP opcode encoded in variable form keeps its 1-31 number.
pub const Opcode = enum(u8) {
    // 2OP
    je = 1,
    jl = 2,
    jg = 3,
    dec_chk = 4,
    inc_chk = 5,
    jin = 6,
    @"test" = 7,
    @"or" = 8,
    @"and" = 9,
    test_attr = 10,
    set_attr = 11,
    clear_attr = 12,
    store = 13,
    insert_obj = 14,
    loadw = 15,
    loadb = 16,
    get_prop = 17,
    get_prop_addr = 18,
    get_next_prop = 19,
    add = 20,
    sub = 21,
    mul = 22,
    div = 23,
    mod = 24,
    // 1OP
    jz = 128,
    get_sibling = 129,
    get_child = 130,
    get_parent = 131,
    get_prop_len = 132,
    inc = 133,
    dec = 134,
    print_addr = 135,
    remove_obj = 137,
    print_obj = 138,
    ret = 139,
    jump = 140,
    print_paddr = 141,
    load = 142,
    not = 143,
    // 0OP
    rtrue = 176,
    rfalse = 177,
    print = 178,
    print_ret = 179,
    nop = 180,
    save = 181,
    restore = 182,
    restart = 183,
    ret_popped = 184,
    pop = 185,
    quit = 186,
    new_line = 187,
    show_status = 188,
    verify = 189,
    // VAR
    call = 224,
    storew = 225,
    storeb = 226,
    put_prop = 227,
    sread = 228,
    print_char = 229,
    print_num = 230,
    random = 231,
    push = 232,
    pull = 233,
    split_window = 234,
    set_window = 235,
    output_stream = 243,
    input_stream = 244,
    sound_effect = 245,
    _,

    /// Does this opcode store a result into a variable? (v3 set)
    pub fn stores(self: Opcode) bool {
        return switch (self) {
            .@"or", .@"and", .loadw, .loadb => true,
            .get_prop, .get_prop_addr, .get_next_prop => true,
            .add, .sub, .mul, .div, .mod => true,
            .get_sibling, .get_child, .get_parent, .get_prop_len => true,
            .load, .not, .call, .random => true,
            else => false,
        };
    }

    /// Does this opcode end with branch data? (v3 set)
    pub fn branches(self: Opcode) bool {
        return switch (self) {
            .je, .jl, .jg, .dec_chk, .inc_chk, .jin, .@"test", .test_attr => true,
            .jz, .get_sibling, .get_child => true,
            .save, .restore, .verify => true,
            else => false,
        };
    }

    /// Is the opcode followed by an inline z-string?
    pub fn hasText(self: Opcode) bool {
        return self == .print or self == .print_ret;
    }
};

pub const OperandType = enum(u2) {
    large = 0b00,
    small = 0b01,
    variable = 0b10,
    omitted = 0b11,
};

pub const Branch = struct {
    /// Branch when the condition matches this value.
    on_true: bool,
    target: Target,

    pub const Target = union(enum) {
        return_false,
        return_true,
        addr: u32,
    };
};

pub const Operand = struct {
    type: OperandType,
    /// A raw value for constants, or a variable number to resolve.
    value: u16,
};

pub const Instruction = struct {
    addr: u32,
    opcode: Opcode,
    operand_buf: [8]Operand = undefined,
    operand_count: u8 = 0,
    store: ?u8 = null,
    branch: ?Branch = null,
    /// Address of the inline z-string for print/print_ret.
    text_addr: ?u32 = null,
    /// Address of the next instruction in sequence.
    next: u32,

    pub fn operands(self: *const Instruction) []const Operand {
        return self.operand_buf[0..self.operand_count];
    }

    pub fn decode(mem: *const Memory, addr: u32) Error!Instruction {
        var cur = mem.cursor(addr);
        const first = try cur.byte();

        var opcode_num: u8 = undefined;
        var types_buf: [8]OperandType = @splat(.omitted);

        switch (form(first)) {
            .long => {
                // Bits 6 and 5 select small constant (0) or variable (1).
                opcode_num = first & 0x1F;
                types_buf[0] = if (first & 0x40 != 0) .variable else .small;
                types_buf[1] = if (first & 0x20 != 0) .variable else .small;
            },
            .short => {
                const op_type: OperandType = @enumFromInt((first >> 4) & 0x3);
                if (op_type == .omitted) {
                    opcode_num = (first & 0x0F) + 176; // 0OP
                } else {
                    opcode_num = (first & 0x0F) + 128; // 1OP
                    types_buf[0] = op_type;
                }
            },
            .variable => {
                // Bit 5 distinguishes a VAR opcode from a 2OP in var form.
                opcode_num = if (first & 0x20 != 0) first else first & 0x1F;
                const type_byte = try cur.byte();
                for (0..4) |i| {
                    types_buf[i] = @enumFromInt((type_byte >> @intCast(6 - 2 * i)) & 0x3);
                }
            },
        }

        const opcode: Opcode = @enumFromInt(opcode_num);
        if (!isKnown(opcode)) return Error.UnknownOpcode;

        var instr = Instruction{ .addr = addr, .opcode = opcode, .next = undefined };

        for (types_buf) |op_type| {
            if (op_type == .omitted) break;
            const value: u16 = switch (op_type) {
                .large => try cur.word(),
                .small, .variable => try cur.byte(),
                .omitted => unreachable,
            };
            instr.operand_buf[instr.operand_count] = .{ .type = op_type, .value = value };
            instr.operand_count += 1;
        }

        if (opcode.stores()) instr.store = try cur.byte();
        if (opcode.branches()) instr.branch = try decodeBranch(&cur);

        if (opcode.hasText()) {
            instr.text_addr = cur.pos;
            cur.pos += try zscii.stringLength(mem, cur.pos);
        }

        instr.next = cur.pos;
        return instr;
    }

    const Form = enum { long, short, variable };

    fn form(first: u8) Form {
        return switch (first >> 6) {
            0b11 => .variable,
            0b10 => .short,
            else => .long,
        };
    }

    fn decodeBranch(cur: *memory.Cursor) Error!Branch {
        const b = try cur.byte();
        const on_true = b & 0x80 != 0;
        var offset: i16 = undefined;
        if (b & 0x40 != 0) {
            offset = b & 0x3F; // single byte: unsigned 0-63
        } else {
            // Two bytes: 14-bit signed offset.
            const raw = @as(u16, b & 0x3F) << 8 | try cur.byte();
            offset = @intCast(if (raw >= 0x2000) @as(i32, raw) - 0x4000 else raw);
        }
        const target: Branch.Target = switch (offset) {
            0 => .return_false,
            1 => .return_true,
            else => .{ .addr = @intCast(@as(i64, cur.pos) + offset - 2) },
        };
        return .{ .on_true = on_true, .target = target };
    }

    fn isKnown(opcode: Opcode) bool {
        // A non-exhaustive enum accepts any value; check against named tags.
        inline for (@typeInfo(Opcode).@"enum".fields) |field| {
            if (@intFromEnum(opcode) == field.value) return true;
        }
        return false;
    }
};

fn decodeBytes(bytes: []const u8) Error!Instruction {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..bytes.len], bytes);
    const mem = Memory{ .bytes = buf[0..bytes.len], .static_start = 0 };
    return Instruction.decode(&mem, 0);
}

test "decode long form 2OP with branch" {
    // je local1, small 4 -> branch on true, single-byte offset 11
    const instr = try decodeBytes(&.{ 0x41, 0x01, 0x04, 0xCB });
    try std.testing.expectEqual(Opcode.je, instr.opcode);
    try std.testing.expectEqual(@as(usize, 2), instr.operands().len);
    try std.testing.expectEqual(OperandType.variable, instr.operands()[0].type);
    try std.testing.expectEqual(OperandType.small, instr.operands()[1].type);
    const branch = instr.branch.?;
    try std.testing.expect(branch.on_true);
    // Branch byte ends at 4; target = 4 + 11 - 2 = 13.
    try std.testing.expectEqual(Branch.Target{ .addr = 13 }, branch.target);
    try std.testing.expectEqual(@as(u32, 4), instr.next);
}

test "decode short form 1OP and 0OP" {
    // jump with large constant
    const jump = try decodeBytes(&.{ 0x8C, 0xFF, 0xFE });
    try std.testing.expectEqual(Opcode.jump, jump.opcode);
    try std.testing.expectEqual(@as(u16, 0xFFFE), jump.operands()[0].value);

    // rtrue
    const rtrue = try decodeBytes(&.{0xB0});
    try std.testing.expectEqual(Opcode.rtrue, rtrue.opcode);
    try std.testing.expectEqual(@as(usize, 0), rtrue.operands().len);
}

test "decode variable form call with store" {
    // call 0x1234, 5 -> store to stack; type byte: large, small, omitted x2
    const instr = try decodeBytes(&.{ 0xE0, 0x1F, 0x12, 0x34, 0x05, 0x00 });
    try std.testing.expectEqual(Opcode.call, instr.opcode);
    try std.testing.expectEqual(@as(usize, 2), instr.operands().len);
    try std.testing.expectEqual(@as(u16, 0x1234), instr.operands()[0].value);
    try std.testing.expectEqual(@as(?u8, 0), instr.store);
}

test "decode 2OP in variable form" {
    // je with three small operands (var form of opcode 1), branch offset 5
    const instr = try decodeBytes(&.{ 0xC1, 0x57, 0x01, 0x02, 0x03, 0xC5 });
    try std.testing.expectEqual(Opcode.je, instr.opcode);
    try std.testing.expectEqual(@as(usize, 3), instr.operands().len);
}

test "decode two-byte branch with negative offset" {
    // jz small-constant 0 -> branch on false, 14-bit offset -1
    const enc: u16 = @as(u14, @bitCast(@as(i14, -1)));
    const instr = try decodeBytes(&.{ 0x90, 0x00, @intCast(enc >> 8), @intCast(enc & 0xFF) });
    const branch = instr.branch.?;
    try std.testing.expect(!branch.on_true);
    // Branch data ends at 4; target = 4 + (-1) - 2 = 1.
    try std.testing.expectEqual(Branch.Target{ .addr = 1 }, branch.target);
}

test "unknown opcode is rejected" {
    // 0OP number 190 (extended marker, not valid in v3)
    try std.testing.expectError(Error.UnknownOpcode, decodeBytes(&.{0xBE}));
}
