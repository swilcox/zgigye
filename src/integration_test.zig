//! Whole-machine tests against real story files.
//!
//! czech.z3 is a z-machine conformance suite that runs without input and
//! reports a pass/fail summary; minizork exercises the parser and sread.

const std = @import("std");
const Machine = @import("machine.zig").Machine;
const TextUi = @import("text_ui.zig").TextUi;
const session = @import("session.zig");
const highlight = @import("highlight.zig");

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

test "vocabulary extraction and annotation on a real story" {
    const gpa = std.testing.allocator;
    var vocab = try highlight.Vocabulary.fromStory(gpa, minizork_story);
    defer vocab.deinit(gpa);

    for ([_][]const u8{ "small mailbox", "leaflet", "West of House" }) |expected| {
        var found = false;
        for (vocab.names) |name| {
            if (std.mem.eql(u8, name, expected)) found = true;
        }
        if (!found) {
            std.debug.print("vocabulary missing: {s}\n", .{expected});
            return error.MissingName;
        }
    }

    const spans = try highlight.annotate(
        gpa,
        vocab.names,
        "West of House",
        "West of House\nThere is a small mailbox here.",
    );
    defer gpa.free(spans);
    try std.testing.expectEqual(@as(usize, 4), spans.len);
    try std.testing.expectEqual(highlight.Kind.location, spans[0].kind);
    try std.testing.expectEqualStrings("small mailbox", spans[2].text);
    try std.testing.expectEqual(highlight.Kind.keyword, spans[2].kind);
}

test "session suspend/resume is invisible to the game" {
    const gpa = std.testing.allocator;
    const max_steps = 10_000_000;

    // The same playthrough, straight through one machine...
    const direct = try runStory(gpa, minizork_story, "open mailbox\nread leaflet\nquit\ny\n");
    defer gpa.free(direct);

    // ...and as one suspended session per command, each turn restored
    // into a brand-new machine from the previous turn's state blob.
    var combined: std.Io.Writer.Allocating = .init(gpa);
    defer combined.deinit();

    var turn = try session.start(gpa, minizork_story, max_steps);
    defer turn.deinit(gpa);
    try combined.writer.writeAll(turn.output);

    const commands = [_][]const u8{ "open mailbox", "read leaflet", "quit", "y" };
    for (commands) |command| {
        const blob = turn.state orelse return error.GameEndedEarly;
        const next = try session.advance(gpa, minizork_story, blob, command, max_steps);
        turn.deinit(gpa);
        turn = next;
        try combined.writer.writeAll(turn.output);
    }

    try std.testing.expectEqualStrings(direct, combined.written());
    try std.testing.expectEqual(null, turn.state); // the game quit
    const status = turn.status orelse return error.MissingStatus;
    try std.testing.expectEqualStrings("West of House", status.location);
}

test "state snapshot restores into a fresh machine and resumes identically" {
    const gpa = std.testing.allocator;

    // Run czech (needs no input) partway, snapshot, and load the snapshot
    // into a second machine.
    var out_a: std.Io.Writer.Allocating = .init(gpa);
    defer out_a.deinit();
    var in_a = std.Io.Reader.fixed("");
    var ui_a = TextUi{ .out = &out_a.writer, .in = &in_a };
    const a = try Machine.create(gpa, czech_story, ui_a.ui());
    defer a.destroy();
    a.steps_remaining = 1000;
    try std.testing.expectError(error.StepLimitExceeded, a.run());

    const blob = try a.saveState(gpa);
    defer gpa.free(blob);

    var out_b: std.Io.Writer.Allocating = .init(gpa);
    defer out_b.deinit();
    var in_b = std.Io.Reader.fixed("");
    var ui_b = TextUi{ .out = &out_b.writer, .in = &in_b };
    const b = try Machine.create(gpa, czech_story, ui_b.ui());
    defer b.destroy();
    try b.loadState(blob);

    try std.testing.expectEqual(a.pc, b.pc);
    try std.testing.expectEqual(a.rng.s, b.rng.s);
    try std.testing.expectEqualSlices(u16, a.stack.items, b.stack.items);
    try std.testing.expectEqualSlices(u8, a.memory.bytes, b.memory.bytes);
    try std.testing.expectEqual(a.frames.items.len, b.frames.items.len);
    for (a.frames.items, b.frames.items) |fa, fb| {
        try std.testing.expectEqual(fa, fb);
    }

    // Both machines must now produce byte-identical output.
    const resume_at = out_a.written().len;
    a.steps_remaining = 2000;
    b.steps_remaining = 2000;
    try std.testing.expectError(error.StepLimitExceeded, a.run());
    try std.testing.expectError(error.StepLimitExceeded, b.run());
    try std.testing.expectEqualStrings(out_a.written()[resume_at..], out_b.written());
}

test "loadState rejects malformed blobs" {
    const gpa = std.testing.allocator;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var in = std.Io.Reader.fixed("");
    var ui = TextUi{ .out = &out.writer, .in = &in };
    const m = try Machine.create(gpa, czech_story, ui.ui());
    defer m.destroy();

    const blob = try m.saveState(gpa);
    defer gpa.free(blob);
    try m.loadState(blob); // the genuine blob loads fine

    // Every strict prefix is missing data somewhere.
    for (0..blob.len) |len| {
        try std.testing.expectError(error.InvalidState, m.loadState(blob[0..len]));
    }

    // Corrupting identity or validated fields is caught. Fixed offsets,
    // per the layout in state.zig: magic 0, release 4, serial 6,
    // checksum 12, pc 14 (le: byte 17 is the high byte), rng 18..50,
    // stack len 50 (empty), frame count 54 (=1), then the lone frame:
    // resume_pc 58, has_store 62, store 63, locals_count 64,
    // arg_count 65, stack_base 66.
    const corruptions = [_]struct { offset: usize, xor: u8 = 0, set: u8 = 0 }{
        .{ .offset = 0, .xor = 0xff }, // magic
        .{ .offset = 4, .xor = 0xff }, // release
        .{ .offset = 6, .xor = 0xff }, // serial
        .{ .offset = 12, .xor = 0xff }, // checksum
        .{ .offset = 17, .xor = 0xff }, // pc out of range
        .{ .offset = 62, .set = 2 }, // has_store flag not 0/1
        .{ .offset = 64, .set = 16 }, // locals_count > max_locals
        .{ .offset = 66, .set = 1 }, // stack_base beyond empty stack
    };
    for (corruptions) |corruption| {
        const copy = try gpa.dupe(u8, blob);
        defer gpa.free(copy);
        copy[corruption.offset] = (copy[corruption.offset] ^ corruption.xor) | corruption.set;
        try std.testing.expectError(error.InvalidState, m.loadState(copy));
    }

    // A blob from one story must not load into another.
    var out2: std.Io.Writer.Allocating = .init(gpa);
    defer out2.deinit();
    var in2 = std.Io.Reader.fixed("");
    var ui2 = TextUi{ .out = &out2.writer, .in = &in2 };
    const other = try Machine.create(gpa, minizork_story, ui2.ui());
    defer other.destroy();
    try std.testing.expectError(error.InvalidState, other.loadState(blob));
}
