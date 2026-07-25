//! Opcode execution (the v3 instruction set, spec chapters 14-15).
//!
//! `Machine.step` has already advanced the program counter to the next
//! instruction, so handlers only touch it for control flow.

const std = @import("std");
const machine_mod = @import("machine.zig");
const Machine = machine_mod.Machine;
const Error = machine_mod.Error;
const instruction = @import("instruction.zig");
const Instruction = instruction.Instruction;
const memory = @import("memory.zig");

pub fn execute(m: *Machine, instr: *const Instruction) !void {
    // Resolve operands in order; variable operands may pop the stack.
    var args_buf: [8]u16 = undefined;
    for (instr.operands(), 0..) |operand, i| {
        args_buf[i] = switch (operand.type) {
            .variable => try m.readVariable(@intCast(operand.value)),
            else => operand.value,
        };
    }
    const args = args_buf[0..instr.operand_count];

    switch (instr.opcode) {
        // --- Arithmetic (signed, wrapping) ---
        .add => try store(m, instr, unsigned(signed(args[0]) +% signed(args[1]))),
        .sub => try store(m, instr, unsigned(signed(args[0]) -% signed(args[1]))),
        .mul => try store(m, instr, unsigned(signed(args[0]) *% signed(args[1]))),
        .div => try store(m, instr, unsigned(try divide(args[0], args[1]))),
        .mod => try store(m, instr, unsigned(try remainder(args[0], args[1]))),
        .@"and" => try store(m, instr, args[0] & args[1]),
        .@"or" => try store(m, instr, args[0] | args[1]),
        .not => try store(m, instr, ~args[0]),

        // --- Branches and comparisons ---
        .je => try m.takeBranch(instr.branch.?, equalsAny(args[0], args[1..])),
        .jl => try m.takeBranch(instr.branch.?, signed(args[0]) < signed(args[1])),
        .jg => try m.takeBranch(instr.branch.?, signed(args[0]) > signed(args[1])),
        .jz => try m.takeBranch(instr.branch.?, args[0] == 0),
        .jin => try m.takeBranch(instr.branch.?, try m.objects.parent(args[0]) == args[1]),
        .@"test" => try m.takeBranch(instr.branch.?, args[0] & args[1] == args[1]),
        .jump => m.pc = try offsetPc(m, args[0]),

        // --- Variables ---
        .load => try store(m, instr, try m.readVariableIndirect(try variableNumber(args[0]))),
        .store => try m.writeVariableIndirect(try variableNumber(args[0]), args[1]),
        .inc => _ = try addToVariable(m, args[0], 1),
        .dec => _ = try addToVariable(m, args[0], -1),
        .inc_chk => {
            const value = try addToVariable(m, args[0], 1);
            try m.takeBranch(instr.branch.?, value > signed(args[1]));
        },
        .dec_chk => {
            const value = try addToVariable(m, args[0], -1);
            try m.takeBranch(instr.branch.?, value < signed(args[1]));
        },
        .push => try m.push(args[0]),
        .pull => try m.writeVariableIndirect(try variableNumber(args[0]), try m.pop()),
        .pop => _ = try m.pop(),

        // --- Memory ---
        .loadw => try store(m, instr, try m.memory.readWord(arrayAddr(args[0], args[1], 2))),
        .loadb => try store(m, instr, try m.memory.readByte(arrayAddr(args[0], args[1], 1))),
        .storew => try m.memory.writeWord(arrayAddr(args[0], args[1], 2), args[2]),
        .storeb => try m.memory.writeByte(arrayAddr(args[0], args[1], 1), @truncate(args[2])),

        // --- Routines ---
        .call => try m.callRoutine(args[0], args[1..], instr.store),
        .ret => try m.returnFromRoutine(args[0]),
        .rtrue => try m.returnFromRoutine(1),
        .rfalse => try m.returnFromRoutine(0),
        .ret_popped => try m.returnFromRoutine(try m.pop()),

        // --- Objects ---
        .get_parent => try store(m, instr, try m.objects.parent(args[0])),
        .get_sibling => {
            const sibling = try m.objects.sibling(args[0]);
            try store(m, instr, sibling);
            try m.takeBranch(instr.branch.?, sibling != 0);
        },
        .get_child => {
            const child = try m.objects.child(args[0]);
            try store(m, instr, child);
            try m.takeBranch(instr.branch.?, child != 0);
        },
        .insert_obj => try m.objects.insertInto(args[0], args[1]),
        .remove_obj => try m.objects.remove(args[0]),
        .test_attr => try m.takeBranch(instr.branch.?, try m.objects.testAttr(args[0], args[1])),
        .set_attr => try m.objects.setAttr(args[0], args[1]),
        .clear_attr => try m.objects.clearAttr(args[0], args[1]),

        // --- Properties ---
        .get_prop => try store(m, instr, try getProp(m, args[0], args[1])),
        .get_prop_addr => {
            const prop = try m.objects.findProperty(args[0], args[1]);
            try store(m, instr, if (prop) |p| @intCast(p.data_addr) else 0);
        },
        .get_prop_len => try store(m, instr, try m.objects.propertyLengthAt(args[0])),
        .get_next_prop => try store(m, instr, try getNextProp(m, args[0], args[1])),
        .put_prop => {
            const prop = try m.objects.findProperty(args[0], args[1]) orelse
                return Error.MissingProperty;
            switch (prop.size) {
                1 => try m.memory.writeByte(prop.data_addr, @truncate(args[2])),
                else => try m.memory.writeWord(prop.data_addr, args[2]),
            }
        },

        // --- Printing ---
        .print => try m.printZString(instr.text_addr.?),
        .print_ret => {
            try m.printZString(instr.text_addr.?);
            try m.ui.print("\n");
            try m.returnFromRoutine(1);
        },
        .print_addr => try m.printZString(args[0]),
        .print_paddr => try m.printZString(@as(u32, args[0]) * 2),
        .print_obj => try m.printObjectName(args[0]),
        .print_char => try m.printZsciiChar(args[0]),
        .print_num => try m.printFormat("{d}", .{signed(args[0])}),
        .new_line => try m.ui.print("\n"),

        // --- Input ---
        .sread => m.readInput(args[0], args[1]) catch |err| {
            // A non-blocking UI has no input queued yet: rewind so sread
            // re-executes when the machine is resumed (readInput has no
            // side effects before it asks the UI for a line).
            if (err == error.InputPending) m.pc = instr.addr;
            return err;
        },

        // --- Miscellaneous ---
        .random => try store(m, instr, random(m, args[0])),
        .verify => try m.takeBranch(instr.branch.?, m.checksum() == m.header.checksum),
        .show_status => try m.updateStatus(),
        .restart => try m.restart(),
        .quit => m.quit(),
        .nop => {},

        // Saving is not implemented yet; branch on failure (TODO: Quetzal).
        .save => try m.takeBranch(instr.branch.?, false),
        .restore => try m.takeBranch(instr.branch.?, false),

        // Screen and stream control beyond plain text is not supported.
        .split_window, .set_window, .output_stream, .input_stream, .sound_effect => {},

        // The decoder rejects unknown opcodes before we get here.
        _ => unreachable,
    }
}

fn signed(value: u16) i16 {
    return @bitCast(value);
}

fn unsigned(value: i16) u16 {
    return @bitCast(value);
}

fn store(m: *Machine, instr: *const Instruction, value: u16) !void {
    try m.writeVariable(instr.store.?, value);
}

fn equalsAny(value: u16, candidates: []const u16) bool {
    for (candidates) |c| {
        if (value == c) return true;
    }
    return false;
}

fn divide(a: u16, b: u16) Error!i16 {
    if (b == 0) return Error.DivisionByZero;
    return @divTrunc(signed(a), signed(b));
}

fn remainder(a: u16, b: u16) Error!i16 {
    if (b == 0) return Error.DivisionByZero;
    // @rem truncates toward zero: the sign follows the dividend, as required.
    return @rem(signed(a), signed(b));
}

/// Array addresses wrap within 16 bits; the index is signed.
fn arrayAddr(base: u16, index: u16, element_size: u16) u16 {
    return base +% index *% element_size;
}

/// jump: a signed displacement from the instruction after this one. It can
/// point before address 0 or past the end of the story, so the result is
/// range-checked rather than cast.
fn offsetPc(m: *Machine, offset: u16) !u32 {
    const target = @as(i64, m.pc) + signed(offset) - 2;
    if (target < 0 or target >= m.memory.bytes.len) return memory.Error.AddressOutOfRange;
    return @intCast(target);
}

/// Operands that name a variable (load, store, inc, dec, pull) carry a
/// variable number, which is a byte: 0 is the stack, 1-15 are locals and
/// 16-255 globals (spec 4.2.2). Nothing stops a story encoding one as a
/// large constant, but a wider value names no variable that exists.
fn variableNumber(value: u16) Error!u8 {
    if (value > std.math.maxInt(u8)) return Error.NoSuchVariable;
    return @intCast(value);
}

/// inc/dec/inc_chk/dec_chk: signed adjustment of a variable, indirect access.
fn addToVariable(m: *Machine, variable: u16, delta: i16) !i16 {
    const number = try variableNumber(variable);
    const value = signed(try m.readVariableIndirect(number)) +% delta;
    try m.writeVariableIndirect(number, unsigned(value));
    return value;
}

fn getProp(m: *Machine, obj: u16, number: u16) !u16 {
    const prop = try m.objects.findProperty(obj, number) orelse
        return m.objects.defaultProperty(number);
    return switch (prop.size) {
        1 => try m.memory.readByte(prop.data_addr),
        else => try m.memory.readWord(prop.data_addr),
    };
}

fn getNextProp(m: *Machine, obj: u16, number: u16) !u16 {
    if (number == 0) {
        const first = try m.objects.firstProperty(obj) orelse return 0;
        return first.number;
    }
    const prop = try m.objects.findProperty(obj, number) orelse return Error.MissingProperty;
    const next = try m.objects.nextProperty(prop) orelse return 0;
    return next.number;
}

/// random n: positive yields a result in 1..n; zero or negative reseeds
/// (predictably for negative n, unpredictably for zero) and returns 0.
fn random(m: *Machine, range: u16) u16 {
    const r = signed(range);
    if (r < 0) {
        m.rng = std.Random.DefaultPrng.init(@abs(r));
        return 0;
    }
    if (r == 0) {
        // "Random" reseed: any unpredictable value will do; the current
        // generator state is as good as a clock without needing one.
        m.rng = std.Random.DefaultPrng.init(m.rng.random().int(u64));
        return 0;
    }
    return m.rng.random().intRangeAtMost(u16, 1, range);
}

// --- Tests ---
//
// The czech conformance suite (see integration_test.zig) is the broad check
// on the instruction set, but it reports only a pass count: a regression
// there says nothing about which opcode broke. These pin the semantics that
// are easy to get subtly wrong — signedness, the indirect-stack rule,
// address wraparound — one opcode at a time, plus the malformed encodings a
// conforming story never produces and czech therefore cannot reach.

const testing = std.testing;
const test_machine = @import("test_machine.zig");
const TestMachine = test_machine.TestMachine;
const Asm = test_machine.Asm;

/// Variable 16 is global 0; the tests store results there and read them back.
const result_var: u8 = 16;

fn expectResult(tm: *TestMachine, expected: u16, code: []const u8) !void {
    try tm.step(code);
    try testing.expectEqual(expected, try tm.machine.readGlobal(0));
}

/// A signed value as a large-constant operand.
fn signedOperand(value: i16) test_machine.Operand {
    return .{ .large = @bitCast(value) };
}

test "division and remainder truncate toward zero" {
    // @divTrunc and @rem, not floor division: the quotient rounds toward
    // zero and the remainder takes the sign of the dividend (spec 15).
    const tm = try TestMachine.create(testing.allocator, "");
    defer tm.destroy();

    const cases = [_]struct { a: i16, b: i16, div: i16, mod: i16 }{
        .{ .a = -11, .b = 2, .div = -5, .mod = -1 },
        .{ .a = 11, .b = -2, .div = -5, .mod = 1 },
        .{ .a = -11, .b = -2, .div = 5, .mod = -1 },
        .{ .a = 11, .b = 2, .div = 5, .mod = 1 },
    };
    for (cases) |case| {
        var d: Asm = .{};
        _ = d.varOp(.div, &.{ signedOperand(case.a), signedOperand(case.b) }).store(result_var);
        try expectResult(tm, @bitCast(case.div), d.code());

        var m: Asm = .{};
        _ = m.varOp(.mod, &.{ signedOperand(case.a), signedOperand(case.b) }).store(result_var);
        try expectResult(tm, @bitCast(case.mod), m.code());
    }
}

test "division by zero is an error, not a trap" {
    const tm = try TestMachine.create(testing.allocator, "");
    defer tm.destroy();

    var d: Asm = .{};
    _ = d.varOp(.div, &.{ .{ .small = 1 }, .{ .small = 0 } }).store(result_var);
    try testing.expectError(Error.DivisionByZero, tm.step(d.code()));

    var m: Asm = .{};
    _ = m.varOp(.mod, &.{ .{ .small = 1 }, .{ .small = 0 } }).store(result_var);
    try testing.expectError(Error.DivisionByZero, tm.step(m.code()));
}

test "je compares against every operand it is given" {
    // je is the one 2OP that takes a variable number of operands: in
    // variable form it accepts two to four, and branches if the first
    // equals any of the rest (spec 15).
    const tm = try TestMachine.create(testing.allocator, "");
    defer tm.destroy();

    // Four operands, the match in last place.
    var hit: Asm = .{};
    _ = hit.varOp(.je, &.{
        .{ .small = 7 },
        .{ .small = 1 },
        .{ .small = 2 },
        .{ .small = 7 },
    }).branch(true, 10);
    try tm.step(hit.code());
    // Six bytes of instruction and two of branch data end at 0x308, and a
    // taken branch lands at that address plus the offset, less two.
    try testing.expectEqual(@as(u32, test_machine.code_addr + 8 + 10 - 2), tm.machine.pc);

    // Three operands, no match: execution falls through to the next
    // instruction instead.
    var miss: Asm = .{};
    _ = miss.varOp(.je, &.{
        .{ .small = 7 },
        .{ .small = 1 },
        .{ .small = 2 },
    }).branch(true, 10);
    try tm.step(miss.code());
    try testing.expectEqual(@as(u32, test_machine.code_addr + 7), tm.machine.pc);
}

test "inc_chk and dec_chk compare as signed" {
    const tm = try TestMachine.create(testing.allocator, "");
    defer tm.destroy();

    // 0x7FFF + 1 wraps to 0x8000, which is -32768 signed but 32768
    // unsigned. Signed, it is not greater than 0, so the branch is not
    // taken; an unsigned comparison would take it.
    try tm.machine.writeGlobal(0, 0x7FFF);
    var inc: Asm = .{};
    _ = inc.varOp(.inc_chk, &.{ .{ .small = result_var }, .{ .small = 0 } }).branch(true, 10);
    try tm.step(inc.code());
    try testing.expectEqual(@as(u32, test_machine.code_addr + 6), tm.machine.pc); // fell through
    try testing.expectEqual(@as(u16, 0x8000), try tm.machine.readGlobal(0));

    // 0 - 1 wraps to 0xFFFF, which is -1 signed and so less than 0; an
    // unsigned comparison would not branch.
    try tm.machine.writeGlobal(0, 0);
    var dec: Asm = .{};
    _ = dec.varOp(.dec_chk, &.{ .{ .small = result_var }, .{ .small = 0 } }).branch(true, 10);
    try tm.step(dec.code());
    try testing.expectEqual(@as(u32, test_machine.code_addr + 6 + 10 - 2), tm.machine.pc);
    try testing.expectEqual(@as(u16, 0xFFFF), try tm.machine.readGlobal(0));
}

test "indirect variable access works on the stack in place" {
    // Reading or writing variable 0 by number, rather than as an operand,
    // peeks and replaces instead of popping and pushing (spec 6.3.4).
    const tm = try TestMachine.create(testing.allocator, "");
    defer tm.destroy();

    try tm.machine.push(42);
    const depth = tm.machine.stack.items.len;

    // load 0 -> reads the top without consuming it.
    var load: Asm = .{};
    _ = load.oneOp(.load, .{ .small = 0 }).store(result_var);
    try expectResult(tm, 42, load.code());
    try testing.expectEqual(depth, tm.machine.stack.items.len);
    try testing.expectEqual(@as(u16, 42), try tm.machine.peek());

    // store 0, 99 -> replaces the top rather than pushing onto it.
    var store_top: Asm = .{};
    _ = store_top.varOp(.store, &.{ .{ .small = 0 }, .{ .small = 99 } });
    try tm.step(store_top.code());
    try testing.expectEqual(depth, tm.machine.stack.items.len);
    try testing.expectEqual(@as(u16, 99), try tm.machine.peek());
}

test "get_prop_len of address zero is zero" {
    // Spec 12.4.1: get_prop_len 0 must return 0, and in particular must not
    // read the byte before address 0 looking for a size.
    const tm = try TestMachine.create(testing.allocator, "");
    defer tm.destroy();

    var a: Asm = .{};
    _ = a.oneOp(.get_prop_len, .{ .small = 0 }).store(result_var);
    try expectResult(tm, 0, a.code());
}

test "array addresses wrap within sixteen bits" {
    // loadw/storew compute base + index * size with wrapping arithmetic,
    // so an address past 0xFFFF comes back round to the bottom of memory.
    const tm = try TestMachine.create(testing.allocator, "");
    defer tm.destroy();

    // 0xFFFF + 1 * 1 wraps to 0, where the version byte lives.
    var load: Asm = .{};
    _ = load.varOp(.loadb, &.{ .{ .large = 0xFFFF }, .{ .small = 1 } }).store(result_var);
    try expectResult(tm, 3, load.code());

    // 0xFFFE + 1 * 2 wraps to 0 as well.
    var store_wrapped: Asm = .{};
    _ = store_wrapped.varOp(.storew, &.{
        .{ .large = 0xFFFE },
        .{ .small = 1 },
        .{ .large = 0xBEEF },
    });
    try tm.step(store_wrapped.code());
    try testing.expectEqual(@as(u16, 0xBEEF), try tm.machine.memory.readWord(0));
}

test "random is reproducible from a seed and reseeds on a negative range" {
    // A negative range reseeds predictably with its absolute value and
    // returns 0 (spec 15), which is what makes scripted runs repeatable.
    const tm = try TestMachine.create(testing.allocator, "");
    defer tm.destroy();

    var seed: Asm = .{};
    _ = seed.varOp(.random, &.{signedOperand(-5)}).store(result_var);
    var draw: Asm = .{};
    _ = draw.varOp(.random, &.{.{ .large = 1000 }}).store(result_var);

    try expectResult(tm, 0, seed.code()); // reseeding yields 0
    try tm.step(draw.code());
    const first = try tm.machine.readGlobal(0);

    try tm.step(seed.code());
    try tm.step(draw.code());
    try testing.expectEqual(first, try tm.machine.readGlobal(0));

    // And the result is in range.
    try testing.expect(first >= 1 and first <= 1000);
}

test "print_num prints signed values" {
    const tm = try TestMachine.create(testing.allocator, "");
    defer tm.destroy();

    var a: Asm = .{};
    _ = a.varOp(.print_num, &.{signedOperand(-1)});
    try tm.step(a.code());
    try testing.expectEqualStrings("-1", tm.written());
}

test "calling packed address zero returns false without a frame" {
    // Spec 6.4.3: call 0 does nothing, stores false, and must not push a
    // call frame — a routine that never ran cannot be returned from.
    const tm = try TestMachine.create(testing.allocator, "");
    defer tm.destroy();

    try tm.machine.writeGlobal(0, 0xFFFF);
    const frames = tm.machine.frames.items.len;

    var a: Asm = .{};
    _ = a.varOp(.call, &.{.{ .small = 0 }}).store(result_var);
    try expectResult(tm, 0, a.code());
    try testing.expectEqual(frames, tm.machine.frames.items.len);
}

test "bitwise operations" {
    const tm = try TestMachine.create(testing.allocator, "");
    defer tm.destroy();

    var and_op: Asm = .{};
    _ = and_op.varOp(.@"and", &.{ .{ .large = 0xFF00 }, .{ .large = 0x0F0F } }).store(result_var);
    try expectResult(tm, 0x0F00, and_op.code());

    var or_op: Asm = .{};
    _ = or_op.varOp(.@"or", &.{ .{ .large = 0xFF00 }, .{ .large = 0x0F0F } }).store(result_var);
    try expectResult(tm, 0xFF0F, or_op.code());

    var not_op: Asm = .{};
    _ = not_op.oneOp(.not, .{ .large = 0xFF00 }).store(result_var);
    try expectResult(tm, 0x00FF, not_op.code());
}

// --- Malformed encodings ---

test "a variable number wider than a byte is rejected" {
    // Variable numbers are bytes, but the operand carrying one can be a
    // large constant, so a story can name variable 0x1234. Was: the cast to
    // u8 panicked.
    const tm = try TestMachine.create(testing.allocator, "");
    defer tm.destroy();

    var a: Asm = .{};
    _ = a.oneOp(.dec, .{ .large = 0x1234 });
    try testing.expectError(Error.NoSuchVariable, tm.step(a.code()));
}

test "a jump landing outside memory is rejected" {
    // jump takes a signed displacement, so it can address before 0 or past
    // the end of the story. Was: the cast to u32 panicked.
    const tm = try TestMachine.create(testing.allocator, "");
    defer tm.destroy();

    var backwards: Asm = .{};
    _ = backwards.oneOp(.jump, signedOperand(-32768));
    try testing.expectError(error.AddressOutOfRange, tm.step(backwards.code()));

    var forwards: Asm = .{};
    _ = forwards.oneOp(.jump, .{ .large = 0x7FFF });
    try testing.expectError(error.AddressOutOfRange, tm.step(forwards.code()));
}
