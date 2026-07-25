//! The interface between the z-machine core and the outside world.
//!
//! The machine talks only to `Ui`; concrete frontends (plain text today,
//! rich text or web later) implement the vtable. Status information is
//! passed structured, not preformatted, so each frontend can render it
//! however it likes.

const std = @import("std");

pub const StatusLine = struct {
    /// Short name of the object the game considers the current location.
    location: []const u8,
    progress: Progress,

    pub const Progress = union(enum) {
        score: struct { score: i16, turns: u16 },
        time: struct { hours: u16, minutes: u16 },
    };
};

pub const Ui = struct {
    /// Everything a frontend is allowed to fail with.
    ///
    /// The set is explicit rather than `anyerror` because one of its members is
    /// load-bearing: `InputPending` is how a frontend that cannot block drives
    /// the suspend/resume protocol, and with an erased error set nothing
    /// declared that it was part of the interface at all. Naming the set also
    /// bounds what the machine's callers have to handle — `Machine.run` can
    /// fail with these on top of its own errors, and no others.
    ///
    /// A frontend whose underlying library fails in some other way maps it onto
    /// the closest member (see `tui_ui.zig`); the machine has no use for the
    /// distinction, since every one of these ends the turn.
    pub const Error = error{
        /// No input is available and this frontend will not wait for it. The
        /// machine rewinds to the read instruction and unwinds out of `run`, so
        /// the caller can resume — or snapshot via `Machine.saveState` — once
        /// input arrives. Returned only from `readLine`.
        InputPending,
        /// Input ended: piped input ran out, or the terminal went away.
        EndOfStream,
        /// The player asked to stop (Ctrl+C in the TUI).
        Interrupted,
        /// Output could not be written.
        WriteFailed,
        /// Input could not be read.
        ReadFailed,
        OutOfMemory,
    };

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Write game output. Text is UTF-8; newlines are '\n'.
        print: *const fn (ptr: *anyopaque, text: []const u8) Error!void,
        /// Write an object's short name, emitted by the print_obj opcode.
        /// `location` is true when the object is the game's current location
        /// (global 0). Rich frontends highlight it; plain frontends print it
        /// like any other text.
        printObject: *const fn (ptr: *anyopaque, text: []const u8, location: bool) Error!void,
        /// Read one line of player input into `buf`; returns the line
        /// without its newline. Implementations should flush any pending
        /// output first. A frontend that cannot block returns
        /// `error.InputPending`; see that error's documentation.
        readLine: *const fn (ptr: *anyopaque, buf: []u8) Error![]const u8,
        /// Update the status line (shown for v3 games before input).
        showStatus: *const fn (ptr: *anyopaque, status: StatusLine) Error!void,
    };

    pub fn print(self: Ui, text: []const u8) Error!void {
        return self.vtable.print(self.ptr, text);
    }

    pub fn printObject(self: Ui, text: []const u8, location: bool) Error!void {
        return self.vtable.printObject(self.ptr, text, location);
    }

    pub fn readLine(self: Ui, buf: []u8) Error![]const u8 {
        return self.vtable.readLine(self.ptr, buf);
    }

    pub fn showStatus(self: Ui, status: StatusLine) Error!void {
        return self.vtable.showStatus(self.ptr, status);
    }
};

// --- Tests ---

const testing = std.testing;
const Machine = @import("machine.zig").Machine;
const test_machine = @import("test_machine.zig");
const Asm = test_machine.Asm;

/// A frontend that has no input and will not wait for one — the whole of
/// what a non-blocking frontend has to do (see session.zig for the real
/// one).
const PendingUi = struct {
    reads: usize = 0,

    fn ui(self: *PendingUi) Ui {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Ui.VTable{
        .print = print,
        .printObject = printObject,
        .readLine = readLine,
        .showStatus = showStatus,
    };

    fn print(_: *anyopaque, _: []const u8) Ui.Error!void {}
    fn printObject(_: *anyopaque, _: []const u8, _: bool) Ui.Error!void {}
    fn showStatus(_: *anyopaque, _: StatusLine) Ui.Error!void {}

    fn readLine(ptr: *anyopaque, _: []u8) Ui.Error![]const u8 {
        const self: *PendingUi = @ptrCast(@alignCast(ptr));
        self.reads += 1;
        return error.InputPending;
    }
};

test "a frontend returning InputPending suspends at the read instruction" {
    // The contract `Ui.Error.InputPending` names: the machine must rewind
    // to the sread it was executing, so resuming re-executes the read
    // rather than continuing past it with no input. Everything the web
    // frontends do rests on this, and it was previously expressible only
    // as an untyped `anyerror`.
    const gpa = testing.allocator;
    var frontend: PendingUi = .{};

    const story = test_machine.syntheticStory();
    const machine = try Machine.create(gpa, &story, frontend.ui());
    defer machine.destroy();

    // Buffers for sread to fill, in dynamic memory past the code region:
    // byte 0 of each is its capacity.
    const text_addr: u16 = 0x380;
    const parse_addr: u16 = 0x3C0;
    try machine.memory.writeByte(text_addr, 20);
    try machine.memory.writeByte(parse_addr, 4);

    var code: Asm = .{};
    _ = code.varOp(.sread, &.{ .{ .large = text_addr }, .{ .large = parse_addr } });
    for (code.code(), 0..) |byte, i| {
        try machine.memory.writeByte(test_machine.code_addr + @as(u32, @intCast(i)), byte);
    }
    machine.pc = test_machine.code_addr;

    machine.steps_remaining = 100;
    try testing.expectError(error.InputPending, machine.run());

    // Rewound, not advanced: the pc is back at the sread itself.
    try testing.expectEqual(@as(u32, test_machine.code_addr), machine.pc);
    try testing.expectEqual(@as(usize, 1), frontend.reads);

    // So running again re-executes the same instruction, asking once more.
    try testing.expectError(error.InputPending, machine.run());
    try testing.expectEqual(@as(u32, test_machine.code_addr), machine.pc);
    try testing.expectEqual(@as(usize, 2), frontend.reads);
}
