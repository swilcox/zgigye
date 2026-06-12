//! Whole-machine tests against real story files.
//!
//! czech.z3 is a z-machine conformance suite that runs without input and
//! reports a pass/fail summary; minizork exercises the parser and sread.

const std = @import("std");
const Machine = @import("machine.zig").Machine;
const TextUi = @import("text_ui.zig").TextUi;

const czech_story = @embedFile("testdata/czech.z3");
const minizork_story = @embedFile("testdata/minizork.z3");

/// Run a story with scripted input, returning everything it printed.
fn runStory(gpa: std.mem.Allocator, story: []const u8, input: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(gpa);
    errdefer out.deinit();
    var in = std.Io.Reader.fixed(input);

    var text_ui = TextUi{ .out = &out.writer, .in = &in };
    const machine = try Machine.create(gpa, story, text_ui.ui());
    defer machine.destroy();
    machine.steps_remaining = 10_000_000;

    machine.run() catch |err| {
        std.debug.print("machine error {t} at pc 0x{x}\npartial output:\n{s}\n", .{
            err, machine.pc, out.written(),
        });
        return err;
    };
    return out.toOwnedSlice();
}

test "czech conformance suite passes" {
    const output = try runStory(std.testing.allocator, czech_story, "");
    defer std.testing.allocator.free(output);

    const passed = std.mem.indexOf(u8, output, "Passed: 349, Failed: 0") != null and
        std.mem.indexOf(u8, output, "Didn't crash: hooray!") != null;
    if (!passed) {
        std.debug.print("--- czech.z3 output ---\n{s}\n", .{output});
        return error.CzechSuiteFailed;
    }
}

test "minizork accepts commands and quits" {
    const output = try runStory(
        std.testing.allocator,
        minizork_story,
        "open mailbox\nread leaflet\nquit\ny\n",
    );
    defer std.testing.allocator.free(output);

    const checks = [_][]const u8{
        "MINI-ZORK I", // banner
        "West of House", // initial room description
        "Opening the small mailbox reveals a leaflet.",
        "WELCOME TO ZORK", // leaflet text
        "Your score is 0 (of 350 points), in 2 moves", // quit confirms turns counted
    };
    for (checks) |expected| {
        if (std.mem.indexOf(u8, output, expected) == null) {
            std.debug.print("--- minizork output ---\n{s}\n", .{output});
            std.debug.print("missing: {s}\n", .{expected});
            return error.UnexpectedOutput;
        }
    }
}
