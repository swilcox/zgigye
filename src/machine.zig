//! The z-machine core: memory, call frames, the evaluation stack, and the
//! fetch/decode/execute loop. All input/output goes through the `Ui`
//! interface; the core never touches files or terminals directly.

const std = @import("std");
const Allocator = std.mem.Allocator;

const memory_mod = @import("memory.zig");
const Memory = memory_mod.Memory;
const Header = @import("header.zig").Header;
const ObjectTable = @import("objects.zig").ObjectTable;
const Dictionary = @import("dictionary.zig").Dictionary;
const dictionary = @import("dictionary.zig");
const zscii = @import("zscii.zig");
const instruction = @import("instruction.zig");
const Instruction = instruction.Instruction;
const opcodes = @import("opcodes.zig");
const ui_mod = @import("ui.zig");
const Ui = ui_mod.Ui;
const state = @import("state.zig");
const debug = @import("debug.zig");

pub const Error = error{
    StackUnderflow,
    NoSuchLocal,
    NoSuchGlobal,
    InvalidRoutine,
    ReturnFromMainRoutine,
    DivisionByZero,
    MissingProperty,
    StepLimitExceeded,
    OutOfMemory,
};

pub const max_locals = 15;

/// One routine activation. Locals live in the frame; pushed values live on
/// the machine's shared evaluation stack above `stack_base`.
pub const Frame = struct {
    /// Where execution continues after this routine returns.
    resume_pc: u32 = 0,
    /// Variable that receives the routine's return value.
    store: ?u8 = null,
    locals: [max_locals]u16 = @splat(0),
    locals_count: u8 = 0,
    arg_count: u8 = 0,
    stack_base: usize = 0,
};

pub const Machine = struct {
    gpa: Allocator,
    ui: Ui,
    memory: Memory,
    /// Pristine copy of the story file, for restart and verify.
    original: []const u8,
    header: Header,
    objects: ObjectTable,
    dict: Dictionary,

    pc: u32,
    frames: std.ArrayList(Frame),
    stack: std.ArrayList(u16),
    rng: std.Random.DefaultPrng,
    running: bool = false,
    /// Optional bound on instructions executed; a backstop against
    /// runaway loops in scripted or test runs.
    steps_remaining: ?u64 = null,
    /// Scratch buffer for decoding strings before handing them to the UI.
    scratch: std.Io.Writer.Allocating,

    /// The machine is heap-allocated because parts of it (object table,
    /// dictionary) point back into it.
    pub fn create(gpa: Allocator, story: []const u8, ui: Ui) !*Machine {
        const header = try Header.parse(story);

        const self = try gpa.create(Machine);
        errdefer gpa.destroy(self);

        const bytes = try gpa.dupe(u8, story);
        errdefer gpa.free(bytes);
        const original = try gpa.dupe(u8, story);
        errdefer gpa.free(original);

        self.* = .{
            .gpa = gpa,
            .ui = ui,
            .memory = .{ .bytes = bytes, .static_start = header.static_memory },
            .original = original,
            .header = header,
            .objects = .{ .mem = &self.memory, .base = header.object_table },
            .dict = undefined,
            .pc = header.initial_pc,
            .frames = .empty,
            .stack = .empty,
            .rng = std.Random.DefaultPrng.init(0),
            .scratch = .init(gpa),
        };
        self.dict = try Dictionary.init(&self.memory, header.dictionary);
        try self.frames.append(gpa, .{});
        return self;
    }

    pub fn destroy(self: *Machine) void {
        const gpa = self.gpa;
        self.frames.deinit(gpa);
        self.stack.deinit(gpa);
        self.scratch.deinit();
        gpa.free(self.memory.bytes);
        gpa.free(self.original);
        gpa.destroy(self);
    }

    // --- Execution ---

    pub fn run(self: *Machine) !void {
        self.running = true;
        while (self.running) try self.step();
    }

    pub fn step(self: *Machine) !void {
        if (self.steps_remaining) |*remaining| {
            if (remaining.* == 0) return Error.StepLimitExceeded;
            remaining.* -= 1;
        }
        const instr = try Instruction.decode(&self.memory, self.pc);
        // Default to the next instruction; control-flow opcodes overwrite.
        self.pc = instr.next;
        try opcodes.execute(self, &instr);
    }

    // --- Routines and branching ---

    pub fn callRoutine(self: *Machine, packed_addr: u16, args: []const u16, store: ?u8) !void {
        // Calling packed address 0 does nothing and returns false (spec 6.4.3).
        if (packed_addr == 0) {
            if (store) |v| try self.writeVariable(v, 0);
            return;
        }
        const addr = @as(u32, packed_addr) * 2;
        var cur = self.memory.cursor(addr);
        const locals_count = try cur.byte();
        if (locals_count > max_locals) return Error.InvalidRoutine;

        var frame = Frame{
            .resume_pc = self.pc,
            .store = store,
            .locals_count = locals_count,
            .arg_count = @intCast(args.len),
            .stack_base = self.stack.items.len,
        };
        // Locals start with default values from the routine header (v3);
        // arguments overwrite the first few.
        for (frame.locals[0..locals_count]) |*local| local.* = try cur.word();
        for (args[0..@min(args.len, locals_count)], 0..) |arg, i| frame.locals[i] = arg;

        try self.frames.append(self.gpa, frame);
        self.pc = cur.pos;
    }

    pub fn returnFromRoutine(self: *Machine, value: u16) !void {
        if (self.frames.items.len == 1) return Error.ReturnFromMainRoutine;
        const frame = self.frames.pop().?;
        self.stack.shrinkRetainingCapacity(frame.stack_base);
        self.pc = frame.resume_pc;
        if (frame.store) |v| try self.writeVariable(v, value);
    }

    pub fn takeBranch(self: *Machine, branch: instruction.Branch, condition: bool) !void {
        if (condition != branch.on_true) return;
        switch (branch.target) {
            .return_false => try self.returnFromRoutine(0),
            .return_true => try self.returnFromRoutine(1),
            .addr => |addr| self.pc = addr,
        }
    }

    // --- Variables (0 = stack, 1-15 = locals, 16-255 = globals) ---

    pub fn readVariable(self: *Machine, variable: u8) !u16 {
        return switch (variable) {
            0 => self.pop(),
            1...max_locals => self.readLocal(variable - 1),
            else => self.readGlobal(variable - 16),
        };
    }

    pub fn writeVariable(self: *Machine, variable: u8, value: u16) !void {
        switch (variable) {
            0 => try self.push(value),
            1...max_locals => try self.writeLocal(variable - 1, value),
            else => try self.writeGlobal(variable - 16, value),
        }
    }

    /// Indirect variable access (load, store, inc, dec, pull): reading or
    /// writing the stack works in place instead of popping/pushing (spec 6.3.4).
    pub fn readVariableIndirect(self: *Machine, variable: u8) !u16 {
        return if (variable == 0) self.peek() else self.readVariable(variable);
    }

    pub fn writeVariableIndirect(self: *Machine, variable: u8, value: u16) !void {
        if (variable == 0) {
            _ = try self.pop();
            try self.push(value);
        } else {
            try self.writeVariable(variable, value);
        }
    }

    fn currentFrame(self: *Machine) *Frame {
        return &self.frames.items[self.frames.items.len - 1];
    }

    fn readLocal(self: *Machine, index: u8) !u16 {
        const frame = self.currentFrame();
        if (index >= frame.locals_count) return Error.NoSuchLocal;
        return frame.locals[index];
    }

    fn writeLocal(self: *Machine, index: u8, value: u16) !void {
        const frame = self.currentFrame();
        if (index >= frame.locals_count) return Error.NoSuchLocal;
        frame.locals[index] = value;
    }

    pub fn readGlobal(self: *Machine, index: u8) !u16 {
        if (index >= 240) return Error.NoSuchGlobal;
        return self.memory.readWord(self.header.globals + @as(u32, index) * 2);
    }

    pub fn writeGlobal(self: *Machine, index: u8, value: u16) !void {
        if (index >= 240) return Error.NoSuchGlobal;
        try self.memory.writeWord(self.header.globals + @as(u32, index) * 2, value);
    }

    pub fn push(self: *Machine, value: u16) !void {
        try self.stack.append(self.gpa, value);
    }

    pub fn pop(self: *Machine) !u16 {
        if (self.stack.items.len <= self.currentFrame().stack_base) return Error.StackUnderflow;
        return self.stack.pop().?;
    }

    pub fn peek(self: *Machine) !u16 {
        if (self.stack.items.len <= self.currentFrame().stack_base) return Error.StackUnderflow;
        return self.stack.items[self.stack.items.len - 1];
    }

    // --- Output ---

    pub fn printZString(self: *Machine, addr: u32) !void {
        self.scratch.clearRetainingCapacity();
        try zscii.decode(&self.memory, self.header.abbreviations, addr, &self.scratch.writer);
        try self.ui.print(self.scratch.written());
    }

    pub fn printZsciiChar(self: *Machine, code: u16) !void {
        self.scratch.clearRetainingCapacity();
        try zscii.writeZscii(code, &self.scratch.writer);
        try self.ui.print(self.scratch.written());
    }

    pub fn printFormat(self: *Machine, comptime fmt: []const u8, args: anytype) !void {
        self.scratch.clearRetainingCapacity();
        self.scratch.writer.print(fmt, args) catch return error.WriteFailed;
        try self.ui.print(self.scratch.written());
    }

    /// Print an object's short name (the print_obj opcode). It travels
    /// through the object-name channel, tagged with whether the object is
    /// the current location (global 0), so frontends can highlight it.
    pub fn printObjectName(self: *Machine, obj: u16) !void {
        const addr = (try self.objects.nameAddr(obj)) orelse return;
        self.scratch.clearRetainingCapacity();
        try zscii.decode(&self.memory, self.header.abbreviations, addr, &self.scratch.writer);
        try self.ui.printObject(self.scratch.written(), obj == try self.readGlobal(0));
    }

    pub fn updateStatus(self: *Machine) !void {
        // Global 0 is the current location; globals 1 and 2 are
        // score/turns or hours/minutes (spec 8.2).
        self.scratch.clearRetainingCapacity();
        const location_obj = try self.readGlobal(0);
        if (try self.objects.nameAddr(location_obj)) |addr| {
            try zscii.decode(&self.memory, self.header.abbreviations, addr, &self.scratch.writer);
        }
        const g1 = try self.readGlobal(1);
        const g2 = try self.readGlobal(2);
        try self.ui.showStatus(.{
            .location = self.scratch.written(),
            .progress = switch (self.header.status_line_type) {
                .score => .{ .score = .{ .score = @bitCast(g1), .turns = g2 } },
                .time => .{ .time = .{ .hours = g1, .minutes = g2 } },
            },
        });
    }

    // --- Input ---

    /// The sread opcode: show status, read a line, write it to the text
    /// buffer, and tokenise into the parse buffer (spec 15, "read").
    pub fn readInput(self: *Machine, text_addr: u16, parse_addr: u16) !void {
        try self.updateStatus();

        const max_len = try self.memory.readByte(text_addr);
        var buf: [256]u8 = undefined;
        const line = while (true) {
            const raw = try self.ui.readLine(&buf);
            // A line beginning with '$' is a debug command: handle it
            // outside the machine, print the report, and read again for a
            // real line. Debug commands never mutate the machine.
            self.scratch.clearRetainingCapacity();
            if (try debug.dispatch(self, &self.scratch.writer, raw)) {
                try self.ui.print(self.scratch.written());
                continue;
            }
            break raw[0..@min(raw.len, max_len)];
        };

        // v3 text buffer: typed characters from byte 1, zero-terminated.
        for (line, 0..) |c, i| {
            try self.memory.writeByte(@intCast(text_addr + 1 + i), std.ascii.toLower(c));
        }
        try self.memory.writeByte(@intCast(text_addr + 1 + line.len), 0);

        const text = self.memory.bytes[text_addr + 1 ..][0..line.len];
        try self.tokenise(text, parse_addr);
    }

    fn tokenise(self: *Machine, text: []const u8, parse_addr: u16) !void {
        const Sink = struct {
            machine: *Machine,
            parse_addr: u16,
            max_tokens: u8,
            count: u8 = 0,

            fn emit(sink: *@This(), token: dictionary.Token) !void {
                if (sink.count >= sink.max_tokens) return;
                // Each entry: dictionary address, length, buffer position.
                const addr = @as(u32, sink.parse_addr) + 2 + @as(u32, sink.count) * 4;
                try sink.machine.memory.writeWord(addr, token.dict_addr);
                try sink.machine.memory.writeByte(addr + 2, token.length);
                try sink.machine.memory.writeByte(addr + 3, token.position);
                sink.count += 1;
            }
        };

        var sink = Sink{
            .machine = self,
            .parse_addr = parse_addr,
            .max_tokens = try self.memory.readByte(parse_addr),
        };
        try dictionary.forEachToken(&self.dict, text, 1, &sink, Sink.emit);
        try self.memory.writeByte(parse_addr + 1, sink.count);
    }

    // --- Whole-machine operations ---

    pub fn restart(self: *Machine) !void {
        // Reset dynamic memory to the original story, preserving the two
        // "printer transcript" / "fixed pitch" bits of Flags 2 (spec 6.1.3).
        const flags2 = try self.memory.readWord(0x10);
        const static = self.header.static_memory;
        @memcpy(self.memory.bytes[0..static], self.original[0..static]);
        const fresh = try self.memory.readWord(0x10);
        try self.memory.writeWord(0x10, (fresh & ~@as(u16, 0x3)) | (flags2 & 0x3));

        self.frames.shrinkRetainingCapacity(1);
        self.frames.items[0] = .{};
        self.stack.clearRetainingCapacity();
        self.pc = self.header.initial_pc;
    }

    /// Sum of all bytes after the header, for the verify opcode.
    pub fn checksum(self: *Machine) u16 {
        const end = @min(self.header.file_length, self.original.len);
        var sum: u16 = 0;
        for (self.original[0x40..end]) |b| sum +%= b;
        return sum;
    }

    pub fn quit(self: *Machine) void {
        self.running = false;
    }

    /// Snapshot all mutable state (dynamic memory, stacks, PC, RNG) as a
    /// byte blob the caller persists however it likes; see state.zig.
    pub fn saveState(self: *const Machine, gpa: Allocator) ![]u8 {
        return state.save(self, gpa);
    }

    /// Replace this machine's state with a snapshot taken from the same
    /// story file. The blob is untrusted: a malformed one yields
    /// `error.InvalidState` and leaves the machine unchanged.
    pub fn loadState(self: *Machine, data: []const u8) !void {
        return state.load(self, data);
    }
};
