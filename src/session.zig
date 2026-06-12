//! A suspend/resume driver for frontends that cannot block on input,
//! such as a web server handling one request per game turn.
//!
//! Each call creates a machine, runs it until it asks for input or the
//! game ends, and returns a `Turn`: everything printed, the latest status
//! line, and a state blob (see state.zig). The caller persists the blob
//! however it likes — a session store, a cookie, a database row — and
//! hands it back with the player's next command. The core stays free of
//! any I/O; this module needs only an allocator.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Machine = @import("machine.zig").Machine;
const ui_mod = @import("ui.zig");
const Ui = ui_mod.Ui;
const StatusLine = ui_mod.StatusLine;

/// Everything that happened between two input prompts. Owned by the
/// caller; free with `deinit`.
pub const Turn = struct {
    /// All game output since the previous prompt.
    output: []u8,
    /// The most recent status line, if the game showed one.
    status: ?Status,
    /// Machine state to pass to `advance`; null when the game has ended.
    state: ?[]u8,

    pub const Status = struct {
        location: []u8,
        progress: StatusLine.Progress,
    };

    pub fn deinit(self: *Turn, gpa: Allocator) void {
        gpa.free(self.output);
        if (self.status) |s| gpa.free(s.location);
        if (self.state) |s| gpa.free(s);
        self.* = undefined;
    }
};

/// Start a new game: run from the top until the first input prompt.
/// `max_steps` bounds the instructions executed in this turn, so a story
/// stuck in a loop returns `error.StepLimitExceeded` instead of hanging
/// the host.
pub fn start(gpa: Allocator, story: []const u8, max_steps: u64) !Turn {
    return runTurn(gpa, story, null, null, max_steps);
}

/// Resume a suspended game (`resume` is a Zig keyword): apply one line of
/// player input to the given state and run to the next prompt.
pub fn advance(
    gpa: Allocator,
    story: []const u8,
    state: []const u8,
    input: []const u8,
    max_steps: u64,
) !Turn {
    return runTurn(gpa, story, state, input, max_steps);
}

fn runTurn(
    gpa: Allocator,
    story: []const u8,
    state: ?[]const u8,
    input: ?[]const u8,
    max_steps: u64,
) !Turn {
    var channel = ChannelUi{ .gpa = gpa, .out = .init(gpa), .input = input };
    defer channel.out.deinit();
    errdefer if (channel.status) |s| gpa.free(s.location);

    const machine = try Machine.create(gpa, story, channel.ui());
    defer machine.destroy();
    if (state) |blob| try machine.loadState(blob);
    machine.steps_remaining = max_steps;

    var awaiting_input = false;
    machine.run() catch |err| switch (err) {
        error.InputPending => awaiting_input = true,
        else => return err,
    };

    const new_state = if (awaiting_input) try machine.saveState(gpa) else null;
    errdefer if (new_state) |s| gpa.free(s);
    return .{
        .output = try channel.out.toOwnedSlice(),
        .status = channel.status,
        .state = new_state,
    };
}

/// Collects output in memory and hands out at most one line of input;
/// the second read request suspends the machine via `error.InputPending`.
const ChannelUi = struct {
    gpa: Allocator,
    out: std.Io.Writer.Allocating,
    input: ?[]const u8,
    status: ?Turn.Status = null,

    fn ui(self: *ChannelUi) Ui {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Ui.VTable{
        .print = print,
        .readLine = readLine,
        .showStatus = showStatus,
    };

    fn print(ptr: *anyopaque, text: []const u8) anyerror!void {
        const self: *ChannelUi = @ptrCast(@alignCast(ptr));
        try self.out.writer.writeAll(text);
    }

    fn readLine(ptr: *anyopaque, buf: []u8) anyerror![]const u8 {
        const self: *ChannelUi = @ptrCast(@alignCast(ptr));
        const line = self.input orelse return error.InputPending;
        self.input = null;
        const len = @min(line.len, buf.len);
        @memcpy(buf[0..len], line[0..len]);
        return buf[0..len];
    }

    fn showStatus(ptr: *anyopaque, status: StatusLine) anyerror!void {
        const self: *ChannelUi = @ptrCast(@alignCast(ptr));
        // status.location aliases the machine's scratch buffer, which is
        // overwritten by the next string decode; keep our own copy.
        const location = try self.gpa.dupe(u8, status.location);
        if (self.status) |s| self.gpa.free(s.location);
        self.status = .{ .location = location, .progress = status.progress };
    }
};
