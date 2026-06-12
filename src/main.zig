//! Command-line z-machine interpreter.
//!
//! By default runs the full-screen TUI when attached to a terminal, and
//! plain text otherwise (or with --plain), so piped input keeps working.

const std = @import("std");
const Io = std.Io;
const zgigye = @import("zgigye");
const TuiUi = @import("tui_ui.zig").TuiUi;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var story_path: ?[]const u8 = null;
    var plain = false;
    const args = try init.minimal.args.toSlice(arena);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--plain")) {
            plain = true;
        } else if (story_path == null) {
            story_path = arg;
        } else {
            story_path = null;
            break;
        }
    }
    const path = story_path orelse {
        std.debug.print("usage: {s} [--plain] <story-file.z3>\n", .{args[0]});
        std.process.exit(1);
    };

    const story = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
        std.debug.print("error: cannot read '{s}': {t}\n", .{ path, err });
        std.process.exit(1);
    };

    const is_terminal = (Io.File.stdin().isTty(io) catch false) and
        (Io.File.stdout().isTty(io) catch false);
    if (plain or !is_terminal) {
        try runPlain(arena, io, story);
    } else {
        try runTui(init, story, std.fs.path.basename(path));
    }
}

fn runPlain(arena: std.mem.Allocator, io: Io, story: []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);

    var text_ui = zgigye.TextUi{
        .out = &stdout_writer.interface,
        .in = &stdin_reader.interface,
    };

    const machine = try zgigye.Machine.create(arena, story, text_ui.ui());
    defer machine.destroy();

    machine.run() catch |err| switch (err) {
        // Stdin closed (e.g. piped input ran out): exit quietly.
        error.EndOfStream => {},
        else => return err,
    };

    try stdout_writer.interface.flush();
}

fn runTui(init: std.process.Init, story: []const u8, title: []const u8) !void {
    const tui = try TuiUi.create(init.gpa, init.io, init.environ_map, title);
    defer tui.destroy();

    const machine = try zgigye.Machine.create(init.arena.allocator(), story, tui.ui());
    defer machine.destroy();

    machine.run() catch |err| switch (err) {
        error.Interrupted => return, // Ctrl+C: restore the screen and leave
        else => return err,
    };

    try tui.waitForExit();
}

test {
    _ = @import("tui_ui.zig");
}
