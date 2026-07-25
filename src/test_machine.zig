//! A machine over a synthetic story, for testing opcodes one at a time.
//!
//! The conformance suite (czech.z3, see integration_test.zig) is the broad
//! check on the instruction set, but it answers only "349 of 349 passed" —
//! a regression there says nothing about which opcode broke. These helpers
//! make the narrow tests writable: build a machine, patch one instruction
//! into it, step, and assert on the result.
//!
//! The story is synthetic rather than a real game so that the tests own
//! every byte they touch. Patching instructions into a real story means
//! landing in whatever table happens to be at that address — czech's
//! abbreviations table starts at 0x46, six bytes past the header — and the
//! layout here keeps the code region clear of everything else.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Machine = @import("machine.zig").Machine;
const TextUi = @import("text_ui.zig").TextUi;
pub const Opcode = @import("instruction.zig").Opcode;

// Story layout. Dynamic memory runs to `static_start`; the code region is
// the only part the tests write instructions into.
const story_len = 0x800;
const object_table = 0x40; // 31 property defaults (62 bytes), then entries
const globals = 0x100; // 240 words = 480 bytes, ending at 0x2E0
const code_start = 0x300; // 256 bytes, clear of everything above
const static_start = 0x400;
const dictionary = 0x400; // in static memory; empty, but well-formed

/// Address the machine's pc points at, and where `run` patches code.
pub const code_addr: u16 = code_start;

/// Exposed so tests elsewhere can build a machine over the same story
/// with a frontend of their own (see the suspend test in ui.zig).
pub fn syntheticStory() [story_len]u8 {
    var story: [story_len]u8 = @splat(0);
    story[0] = 3;
    setWord(&story, 0x06, code_start); // initial pc
    setWord(&story, 0x08, dictionary);
    setWord(&story, 0x0A, object_table);
    setWord(&story, 0x0C, globals);
    setWord(&story, 0x0E, static_start);
    setWord(&story, 0x18, 0); // no abbreviations
    setWord(&story, 0x1A, story_len / 2); // file length

    // A well-formed but empty dictionary: no separators, 7-byte entries,
    // no entries. Dictionary.init reads all three.
    story[dictionary] = 0; // separator count
    story[dictionary + 1] = 7; // entry length
    setWord(&story, dictionary + 2, 0); // entry count
    return story;
}

fn setWord(bytes: []u8, addr: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[addr..][0..2], value, .big);
}

/// A machine plus the frontend plumbing it borrows. Heap-allocated because
/// `Ui` holds a pointer to the `TextUi`, which holds pointers to the reader
/// and writer — none of which may move once the machine has them.
pub const TestMachine = struct {
    gpa: Allocator,
    out: std.Io.Writer.Allocating,
    in: std.Io.Reader,
    text_ui: TextUi,
    machine: *Machine,

    pub fn create(gpa: Allocator, input: []const u8) !*TestMachine {
        const self = try gpa.create(TestMachine);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .out = .init(gpa),
            .in = std.Io.Reader.fixed(input),
            .text_ui = undefined,
            .machine = undefined,
        };
        errdefer self.out.deinit();

        self.text_ui = .{ .out = &self.out.writer, .in = &self.in };
        const story = syntheticStory();
        self.machine = try Machine.create(gpa, &story, self.text_ui.ui());
        return self;
    }

    pub fn destroy(self: *TestMachine) void {
        self.machine.destroy();
        self.out.deinit();
        self.gpa.destroy(self);
    }

    /// Patch `code` into the code region and point the pc at it.
    pub fn load(self: *TestMachine, code: []const u8) !void {
        for (code, 0..) |byte, i| {
            try self.machine.memory.writeByte(code_addr + @as(u32, @intCast(i)), byte);
        }
        self.machine.pc = code_addr;
    }

    /// Patch one instruction and execute it.
    pub fn step(self: *TestMachine, code: []const u8) !void {
        try self.load(code);
        try self.machine.step();
    }

    /// Everything printed so far.
    pub fn written(self: *TestMachine) []const u8 {
        return self.out.written();
    }
};

// --- A small assembler ---
//
// Hand-written bytes are right for the decoder's own tests, where the
// encoding *is* the subject. Here the encoding is incidental and the
// semantics are the point, so these build it instead. Call in encoding
// order: operands, then the store byte, then branch data.

pub const Operand = union(enum) {
    small: u8,
    large: u16,
    variable: u8,
};

pub const Asm = struct {
    buf: [64]u8 = @splat(0),
    len: usize = 0,

    /// Variable form, which can express any mix of operand types. Works for
    /// VAR opcodes and for 2OP opcodes, which keep their 1-31 numbering.
    pub fn varOp(self: *Asm, opcode: Opcode, operands: []const Operand) *Asm {
        const number = @intFromEnum(opcode);
        self.byte(if (number >= 224) number else 0xC0 | number);

        // One 2-bit type per operand, high pair first, 0b11 padding the rest.
        var types: u8 = 0xFF;
        for (operands, 0..) |operand, i| {
            const type_code: u8 = switch (operand) {
                .large => 0b00,
                .small => 0b01,
                .variable => 0b10,
            };
            const shift: u3 = @intCast(6 - 2 * i);
            types = (types & ~(@as(u8, 0b11) << shift)) | (type_code << shift);
        }
        self.byte(types);
        for (operands) |op| self.emitOperand(op);
        return self;
    }

    /// Short form, one operand.
    pub fn oneOp(self: *Asm, opcode: Opcode, operand: Operand) *Asm {
        const type_code: u8 = switch (operand) {
            .large => 0b00,
            .small => 0b01,
            .variable => 0b10,
        };
        self.byte(0x80 | (type_code << 4) | (@intFromEnum(opcode) - 128));
        self.emitOperand(operand);
        return self;
    }

    /// Short form, no operands.
    pub fn zeroOp(self: *Asm, opcode: Opcode) *Asm {
        self.byte(0xB0 | (@intFromEnum(opcode) - 176));
        return self;
    }

    /// The variable a result is stored into.
    pub fn store(self: *Asm, variable: u8) *Asm {
        self.byte(variable);
        return self;
    }

    /// Branch data, always in the two-byte form: it covers the whole offset
    /// range, including 0 and 1, which mean "return false" and "return true"
    /// rather than a displacement (spec 4.7).
    pub fn branch(self: *Asm, on_true: bool, offset: i16) *Asm {
        const raw: u14 = @truncate(@as(u16, @bitCast(offset)));
        self.byte((if (on_true) @as(u8, 0x80) else 0) | @as(u8, @intCast(raw >> 8)));
        self.byte(@truncate(raw));
        return self;
    }

    pub fn code(self: *const Asm) []const u8 {
        return self.buf[0..self.len];
    }

    fn byte(self: *Asm, value: u8) void {
        self.buf[self.len] = value;
        self.len += 1;
    }

    fn emitOperand(self: *Asm, value: Operand) void {
        switch (value) {
            .small, .variable => |v| self.byte(v),
            .large => |v| {
                self.byte(@intCast(v >> 8));
                self.byte(@truncate(v));
            },
        }
    }
};

test "the synthetic story is well-formed" {
    // Everything below depends on this loading at all, so check it directly
    // rather than letting an unrelated test fail confusingly.
    const story = syntheticStory();
    const header = try @import("header.zig").Header.parse(&story);
    try std.testing.expectEqual(@as(u16, static_start), header.static_memory);
    try std.testing.expectEqual(@as(u16, code_start), header.initial_pc);

    const tm = try TestMachine.create(std.testing.allocator, "");
    defer tm.destroy();
    try std.testing.expectEqual(@as(u32, code_addr), tm.machine.pc);
    // The code region is writable, which is what `load` relies on.
    try tm.machine.memory.writeByte(code_addr, 0xB0);
}

test "the assembler encodes what the decoder reads back" {
    const Instruction = @import("instruction.zig").Instruction;
    const tm = try TestMachine.create(std.testing.allocator, "");
    defer tm.destroy();

    // add (2OP:20) in variable form: a large constant and a variable,
    // storing into global 0.
    var a: Asm = .{};
    _ = a.varOp(.add, &.{ .{ .large = 0x1234 }, .{ .variable = 16 } }).store(16);
    try tm.load(a.code());

    const instr = try Instruction.decode(&tm.machine.memory, code_addr);
    try std.testing.expectEqual(Opcode.add, instr.opcode);
    try std.testing.expectEqual(@as(usize, 2), instr.operands().len);
    try std.testing.expectEqual(@as(u16, 0x1234), instr.operands()[0].value);
    try std.testing.expectEqual(@as(u16, 16), instr.operands()[1].value);
    try std.testing.expectEqual(@as(?u8, 16), instr.store);

    // jz (1OP:128) with branch data, and a 0OP.
    var b: Asm = .{};
    _ = b.oneOp(.jz, .{ .small = 0 }).branch(true, 20);
    try tm.load(b.code());
    const jz = try Instruction.decode(&tm.machine.memory, code_addr);
    try std.testing.expectEqual(Opcode.jz, jz.opcode);
    try std.testing.expect(jz.branch.?.on_true);

    var c: Asm = .{};
    _ = c.zeroOp(.rtrue);
    try tm.load(c.code());
    try std.testing.expectEqual(Opcode.rtrue, (try Instruction.decode(&tm.machine.memory, code_addr)).opcode);
}
