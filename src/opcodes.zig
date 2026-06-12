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
        .jump => m.pc = offsetPc(m.pc, args[0]),

        // --- Variables ---
        .load => try store(m, instr, try m.readVariableIndirect(@intCast(args[0]))),
        .store => try m.writeVariableIndirect(@intCast(args[0]), args[1]),
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
        .pull => try m.writeVariableIndirect(@intCast(args[0]), try m.pop()),
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

fn offsetPc(pc: u32, offset: u16) u32 {
    return @intCast(@as(i64, pc) + signed(offset) - 2);
}

/// inc/dec/inc_chk/dec_chk: signed adjustment of a variable, indirect access.
fn addToVariable(m: *Machine, variable: u16, delta: i16) !i16 {
    const value = signed(try m.readVariableIndirect(@intCast(variable))) +% delta;
    try m.writeVariableIndirect(@intCast(variable), unsigned(value));
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
