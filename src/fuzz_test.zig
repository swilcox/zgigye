//! Fuzz targets over the interpreter's two untrusted inputs.
//!
//! A z-machine's whole job is executing bytecode it did not write, and this
//! one accepts a second untrusted input besides: the state blobs that
//! suspend/resume round-trips through a browser (state.zig). Neither may
//! ever crash the host — every malformed input has to come back as an error.
//!
//! The targets below say only that: run it, and no input may panic, trip a
//! safety check, or leak. What counts as a *correct* result for a corrupt
//! story is not a question with an answer, so nothing here asserts on
//! output; the conformance suite in integration_test.zig covers behaviour.
//!
//! Coverage-guided runs come from `zig build test --fuzz`. That is broken on
//! Zig 0.16.0 by a type error in the compiler's own bundled test runner
//! (compiler/test_runner.zig:566 passes `*builtin.StackTrace` where
//! `std.debug.writeStackTrace` now wants `*const std.debug.StackTrace`); the
//! branch only compiles in fuzz mode, so plain test runs are unaffected and
//! the targets below are ready for whenever the toolchain is fixed.
//!
//! Until then the seeded driver at the bottom of this file feeds the same
//! targets thousands of pseudo-random inputs on every `zig build test` —
//! random rather than coverage-guided, but deterministic and always on —
//! and the fixed regression tests pin the specific defects already found.

const std = @import("std");
const testing = std.testing;
const Smith = std.testing.Smith;

const Header = @import("header.zig").Header;
const Machine = @import("machine.zig").Machine;
const TextUi = @import("text_ui.zig").TextUi;

const czech_story = @embedFile("testdata/czech.z3");

/// Bounded so a corrupt story that falls into a tight loop fails the run
/// instead of hanging the fuzzer.
const max_steps = 20_000;

// --- Targets ---

test "fuzz: a corrupt story file is rejected, never fatal" {
    try std.testing.fuzz({}, fuzzStory, .{});
}

fn fuzzStory(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;
    const story = try gpa.dupe(u8, czech_story);
    defer gpa.free(story);

    // Corrupt the header a byte at a time rather than replacing it: every
    // address in it points somewhere the interpreter indexes, and all of
    // them were once taken on trust, but a header drawn entirely at random
    // fails Header.parse essentially every time and the code past it would
    // never run. Mutating a real one keeps most inputs loadable.
    const header_pokes = smith.valueRangeAtMost(u8, 0, 6);
    for (0..header_pokes) |_| {
        story[smith.index(64)] = smith.value(u8);
    }
    story[0] = 3; // the version, or parse stops at its first check

    // Then scribble on the body, so corruption also reaches the object
    // tree, the dictionary, and the string decoder.
    const body_pokes = smith.valueRangeAtMost(u8, 0, 64);
    for (0..body_pokes) |_| {
        story[smith.index(story.len)] = smith.value(u8);
    }

    runBounded(gpa, story);
}

test "fuzz: a corrupt state blob is rejected, never fatal" {
    try std.testing.fuzz({}, fuzzState, .{});
}

fn fuzzState(_: void, smith: *Smith) anyerror!void {
    const gpa = testing.allocator;

    var sink: [256]u8 = undefined;
    var out: std.Io.Writer.Discarding = .init(&sink);
    var in = std.Io.Reader.fixed("");
    var ui = TextUi{ .out = &out.writer, .in = &in };
    const machine = try Machine.create(gpa, czech_story, ui.ui());
    defer machine.destroy();

    // Run a little first, so the genuine blob has frames and a non-empty
    // stack to corrupt rather than being all zeros.
    machine.steps_remaining = 500;
    machine.run() catch {};

    const genuine = try machine.saveState(gpa);
    defer gpa.free(genuine);

    const blob = try gpa.dupe(u8, genuine);
    defer gpa.free(blob);
    const mutations = smith.valueRangeAtMost(u8, 0, 32);
    for (0..mutations) |_| {
        blob[smith.index(blob.len)] = smith.value(u8);
    }
    const len = smith.valueRangeAtMost(u32, 0, @intCast(blob.len));

    const pc_before = machine.pc;
    const frames_before = machine.frames.items.len;
    const stack_before = machine.stack.items.len;

    if (machine.loadState(blob[0..len])) {
        // The blob passed validation, which says its lengths and indices are
        // consistent — not that its contents mean anything. Running it is
        // where an unsound field would actually bite.
        machine.steps_remaining = max_steps;
        machine.run() catch {};
    } else |_| {
        // state.load promises a rejected blob leaves the machine untouched;
        // it parses into fresh allocations and commits only at the end.
        try testing.expectEqual(pc_before, machine.pc);
        try testing.expectEqual(frames_before, machine.frames.items.len);
        try testing.expectEqual(stack_before, machine.stack.items.len);
    }
}

/// Load and run a story under a step limit, discarding its output. Every
/// error is an acceptable outcome here — the point is that control returns.
fn runBounded(gpa: std.mem.Allocator, story: []const u8) void {
    var sink: [256]u8 = undefined;
    var out: std.Io.Writer.Discarding = .init(&sink);
    var in = std.Io.Reader.fixed("look\nopen mailbox\nquit\ny\n");
    var ui = TextUi{ .out = &out.writer, .in = &in };

    const machine = Machine.create(gpa, story, ui.ui()) catch return;
    defer machine.destroy();
    machine.steps_remaining = max_steps;
    machine.run() catch {};
}

// --- Seeded driver ---
//
// `Smith` reads a structured byte stream: `bytes` takes its bytes verbatim,
// while every integer draw takes an 8-byte little-endian value and falls
// back to the low end of its range if that value does not fit. Undirected
// random bytes would therefore collapse almost every draw to its minimum,
// so the builders below emit each target's draws in order, at the right
// widths. They mirror the sequence of `smith.*` calls in the target above
// them; if a target's draws change, its builder changes with it.

/// How many inputs each target sees per test run — enough to cover a wide
/// spread of corruptions while keeping the suite quick. The defects fixed
/// so far were all found within a few hundred; raising this locally (and
/// changing the seeds) is the cheap way to search harder.
const seeded_iterations = 2_000;

test "seeded: corrupt story files" {
    var prng = std.Random.DefaultPrng.init(0x2317);
    const rand = prng.random();
    var buf: [8 + 6 * 16 + 8 + 64 * 16]u8 = undefined;

    for (0..seeded_iterations) |_| {
        var smith: Smith = .{ .in = buildStoryInput(rand, &buf) };
        try fuzzStory({}, &smith);
    }
}

fn buildStoryInput(rand: std.Random, buf: []u8) []u8 {
    var w = std.Io.Writer.fixed(buf);

    const header_pokes = rand.uintAtMost(u64, 6);
    w.writeInt(u64, header_pokes, .little) catch unreachable;
    for (0..header_pokes) |_| {
        w.writeInt(u64, rand.uintLessThan(u64, 64), .little) catch unreachable;
        w.writeInt(u64, rand.uintAtMost(u64, 255), .little) catch unreachable;
    }

    const body_pokes = rand.uintAtMost(u64, 64);
    w.writeInt(u64, body_pokes, .little) catch unreachable;
    for (0..body_pokes) |_| {
        w.writeInt(u64, rand.uintLessThan(u64, czech_story.len), .little) catch unreachable;
        w.writeInt(u64, rand.uintAtMost(u64, 255), .little) catch unreachable;
    }
    return w.buffered();
}

test "seeded: corrupt state blobs" {
    var prng = std.Random.DefaultPrng.init(0x5f3a);
    const rand = prng.random();
    var buf: [8 + 32 * 16 + 8]u8 = undefined;

    for (0..seeded_iterations) |_| {
        var smith: Smith = .{ .in = buildStateInput(rand, &buf) };
        try fuzzState({}, &smith);
    }
}

fn buildStateInput(rand: std.Random, buf: []u8) []u8 {
    var w = std.Io.Writer.fixed(buf);
    const mutations = rand.uintAtMost(u64, 32);
    w.writeInt(u64, mutations, .little) catch unreachable;
    for (0..mutations) |_| {
        // The blob's exact length varies with how far the machine ran; an
        // index past it simply falls back to 0, which is a valid target too.
        w.writeInt(u64, rand.uintLessThan(u64, 512), .little) catch unreachable;
        w.writeInt(u64, rand.uintAtMost(u64, 255), .little) catch unreachable;
    }
    w.writeInt(u64, rand.uintLessThan(u64, 512), .little) catch unreachable;
    return w.buffered();
}

// --- Regression tests for what fuzzing found ---
//
// These run on every `zig build test`, so the specific defects stay fixed
// whether or not anyone is fuzzing.

/// A header with one field overwritten, in a story otherwise too small to
/// contain what that field claims.
fn storyWithHeaderWord(addr: usize, value: u16) [128]u8 {
    var story: [128]u8 = @splat(0);
    story[0] = 3;
    std.mem.writeInt(u16, story[addr..][0..2], value, .big);
    return story;
}

test "a static memory mark past the end of the file is rejected" {
    // Was: Header.parse accepted it, and because Memory.writeByte only
    // guarded the mark, the game's first write past the file panicked with
    // an index-out-of-bounds instead of failing.
    var story = storyWithHeaderWord(0x0E, 0xFFFF);
    try testing.expectError(error.MalformedHeader, Header.parse(&story));

    var sink: [64]u8 = undefined;
    var out: std.Io.Writer.Discarding = .init(&sink);
    var in = std.Io.Reader.fixed("");
    var ui = TextUi{ .out = &out.writer, .in = &in };
    try testing.expectError(error.MalformedHeader, Machine.create(testing.allocator, &story, ui.ui()));
}

test "an all-zero header is rejected rather than run" {
    // The degenerate case the empty fuzz input produces: version 3 and
    // nothing else. Every table address is 0, so nothing it points at fits.
    var story: [128]u8 = @splat(0);
    story[0] = 3;
    try testing.expectError(error.MalformedHeader, Header.parse(&story));
}

test "object numbers beyond the version-3 limit are rejected" {
    // Was: any u16 was accepted, so numbers past the table read and wrote
    // whatever data followed it, silently, as long as they stayed inside
    // the file.
    const objects = @import("objects.zig");
    var bytes: [4096]u8 = @splat(0);
    var mem = @import("memory.zig").Memory{ .bytes = &bytes, .static_start = 4096 };
    const table = objects.ObjectTable{ .mem = &mem, .base = 0 };

    try testing.expectError(error.InvalidObject, table.setAttr(256, 0));
    try testing.expectError(error.InvalidObject, table.testAttr(0xFFFF, 0));
    try testing.expectError(error.InvalidObject, table.insertInto(300, 1));
}

test "removing an object from a corrupt sibling chain terminates" {
    // Was: the walk looking for the sibling that points at `obj` followed
    // the chain into object 0, whose sibling is 0 by definition, and spun
    // there forever. A hang is not a failure a test can catch after the
    // fact, so this asserts the bounded walk reports instead.
    const objects = @import("objects.zig");
    var bytes: [4096]u8 = @splat(0);
    var mem = @import("memory.zig").Memory{ .bytes = &bytes, .static_start = 4096 };
    const table = objects.ObjectTable{ .mem = &mem, .base = 0 };

    // Object 2's parent is 1, but 1's child chain (3 -> 0) never reaches it.
    try table.setParent(2, 1);
    try table.setChild(1, 3);
    try table.setSibling(3, 0);
    try testing.expectError(error.InvalidObject, table.remove(2));
}
