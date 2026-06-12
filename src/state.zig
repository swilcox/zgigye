//! Out-of-band machine state snapshots.
//!
//! `save` captures everything mutable in a `Machine` — dynamic memory,
//! call frames, evaluation stack, PC, and RNG — as a compact byte blob;
//! `load` applies one to a fresh machine created from the same story.
//! The caller owns persistence: a web frontend can suspend at an input
//! prompt (see session.zig), stash the blob wherever it likes, and resume
//! in a different process. This is a private format, not Quetzal.
//!
//! Layout (integers little-endian):
//!
//!   magic "ZGS1"
//!   release u16, serial [6]u8, checksum u16    -- story identity
//!   pc u32
//!   rng [4]u64
//!   stack: len u32, len * u16
//!   frames: count u32, then per frame:
//!     resume_pc u32, has_store u8, store u8,
//!     locals_count u8, arg_count u8, stack_base u32,
//!     locals_count * u16
//!   dynamic memory: dyn_len u32, comp_len u32, comp bytes
//!
//! The comp bytes encode (memory XOR original) over the dynamic region,
//! Quetzal-CMem style: a nonzero byte stands for itself; 0x00 is followed
//! by a count byte n meaning n+1 zeros. The trailing zero run is omitted,
//! so a machine whose dynamic memory still matches the story compresses
//! to nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const machine_mod = @import("machine.zig");
const Machine = machine_mod.Machine;
const Frame = machine_mod.Frame;

const magic = "ZGS1";

pub const Error = error{InvalidState} || Allocator.Error;

pub fn save(m: *const Machine, gpa: Allocator) Allocator.Error![]u8 {
    var comp: std.Io.Writer.Allocating = .init(gpa);
    defer comp.deinit();
    const dyn_len = m.memory.static_start;
    compress(m.memory.bytes[0..dyn_len], m.original[0..dyn_len], &comp.writer) catch
        return error.OutOfMemory;

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    writeBlob(m, comp.written(), &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeBlob(m: *const Machine, comp: []const u8, w: *std.Io.Writer) !void {
    try w.writeAll(magic);
    try putInt(w, u16, m.header.release);
    try w.writeAll(&m.header.serial);
    try putInt(w, u16, m.header.checksum);
    try putInt(w, u32, m.pc);
    for (m.rng.s) |word| try putInt(w, u64, word);

    try putInt(w, u32, @intCast(m.stack.items.len));
    for (m.stack.items) |value| try putInt(w, u16, value);

    try putInt(w, u32, @intCast(m.frames.items.len));
    for (m.frames.items) |frame| {
        try putInt(w, u32, frame.resume_pc);
        try w.writeByte(@intFromBool(frame.store != null));
        try w.writeByte(frame.store orelse 0);
        try w.writeByte(frame.locals_count);
        try w.writeByte(frame.arg_count);
        try putInt(w, u32, @intCast(frame.stack_base));
        for (frame.locals[0..frame.locals_count]) |local| try putInt(w, u16, local);
    }

    try putInt(w, u32, m.memory.static_start);
    try putInt(w, u32, @intCast(comp.len));
    try w.writeAll(comp);
}

/// The blob is untrusted input: every length and index is validated before
/// anything is allocated or applied, and the machine is only modified once
/// the whole blob has parsed cleanly.
pub fn load(m: *Machine, data: []const u8) Error!void {
    var c = Cursor{ .data = data };

    if (!std.mem.eql(u8, try c.take(magic.len), magic)) return error.InvalidState;
    if (try c.int(u16) != m.header.release) return error.InvalidState;
    if (!std.mem.eql(u8, try c.take(6), &m.header.serial)) return error.InvalidState;
    if (try c.int(u16) != m.header.checksum) return error.InvalidState;

    const pc = try c.int(u32);
    if (pc >= m.memory.bytes.len) return error.InvalidState;
    var rng_state: [4]u64 = undefined;
    for (&rng_state) |*word| word.* = try c.int(u64);

    const stack_len = try c.int(u32);
    if (@as(u64, stack_len) * 2 > c.remaining()) return error.InvalidState;
    var stack: std.ArrayList(u16) = .empty;
    errdefer stack.deinit(m.gpa);
    try stack.ensureTotalCapacityPrecise(m.gpa, stack_len);
    for (0..stack_len) |_| stack.appendAssumeCapacity(try c.int(u16));

    const frame_count = try c.int(u32);
    const min_frame_size = 12; // a frame with no locals
    if (frame_count == 0) return error.InvalidState;
    if (@as(u64, frame_count) * min_frame_size > c.remaining()) return error.InvalidState;
    var frames: std.ArrayList(Frame) = .empty;
    errdefer frames.deinit(m.gpa);
    try frames.ensureTotalCapacityPrecise(m.gpa, frame_count);
    var prev_base: u32 = 0;
    for (0..frame_count) |_| {
        var frame = Frame{};
        frame.resume_pc = try c.int(u32);
        if (frame.resume_pc >= m.memory.bytes.len) return error.InvalidState;
        const has_store = try c.int(u8);
        const store = try c.int(u8);
        if (has_store > 1) return error.InvalidState;
        frame.store = if (has_store == 1) store else null;
        frame.locals_count = try c.int(u8);
        if (frame.locals_count > machine_mod.max_locals) return error.InvalidState;
        frame.arg_count = try c.int(u8);
        const stack_base = try c.int(u32);
        if (stack_base > stack.items.len or stack_base < prev_base) return error.InvalidState;
        frame.stack_base = stack_base;
        prev_base = stack_base;
        for (frame.locals[0..frame.locals_count]) |*local| local.* = try c.int(u16);
        frames.appendAssumeCapacity(frame);
    }

    const dyn_len = try c.int(u32);
    if (dyn_len != m.memory.static_start) return error.InvalidState;
    const comp_len = try c.int(u32);
    const comp = try c.take(comp_len);

    const dyn = try m.gpa.alloc(u8, dyn_len);
    defer m.gpa.free(dyn);
    try decompress(comp, m.original[0..dyn_len], dyn);

    // Everything parsed; commit.
    m.stack.deinit(m.gpa);
    m.stack = stack;
    m.frames.deinit(m.gpa);
    m.frames = frames;
    @memcpy(m.memory.bytes[0..dyn_len], dyn);
    m.rng.s = rng_state;
    m.pc = pc;
    m.running = true;
}

fn putInt(w: *std.Io.Writer, comptime T: type, value: T) !void {
    std.mem.writeInt(T, try w.writableArray(@sizeOf(T)), value, .little);
}

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn remaining(self: *const Cursor) usize {
        return self.data.len - self.pos;
    }

    fn take(self: *Cursor, len: usize) error{InvalidState}![]const u8 {
        if (self.remaining() < len) return error.InvalidState;
        defer self.pos += len;
        return self.data[self.pos..][0..len];
    }

    fn int(self: *Cursor, comptime T: type) error{InvalidState}!T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }
};

// --- XOR + zero-RLE codec over the dynamic memory region ---

fn compress(memory: []const u8, original: []const u8, w: *std.Io.Writer) !void {
    var zeros: usize = 0;
    for (memory, original) |b, o| {
        const diff = b ^ o;
        if (diff == 0) {
            zeros += 1;
            continue;
        }
        while (zeros > 0) {
            const run = @min(zeros, 256);
            try w.writeByte(0);
            try w.writeByte(@intCast(run - 1));
            zeros -= run;
        }
        try w.writeByte(diff);
    }
    // Trailing zeros are omitted; decompress pads from the original.
}

fn decompress(comp: []const u8, original: []const u8, out: []u8) error{InvalidState}!void {
    var i: usize = 0;
    var pos: usize = 0;
    while (i < comp.len) {
        const b = comp[i];
        i += 1;
        if (b == 0) {
            if (i >= comp.len) return error.InvalidState;
            const run = @as(usize, comp[i]) + 1;
            i += 1;
            if (run > out.len - pos) return error.InvalidState;
            @memcpy(out[pos..][0..run], original[pos..][0..run]);
            pos += run;
        } else {
            if (pos >= out.len) return error.InvalidState;
            out[pos] = original[pos] ^ b;
            pos += 1;
        }
    }
    @memcpy(out[pos..], original[pos..out.len]);
}

// --- Tests ---

const testing = std.testing;

fn expectRoundTrip(memory: []const u8, original: []const u8) !void {
    var comp: std.Io.Writer.Allocating = .init(testing.allocator);
    defer comp.deinit();
    try compress(memory, original, &comp.writer);

    const out = try testing.allocator.alloc(u8, memory.len);
    defer testing.allocator.free(out);
    try decompress(comp.written(), original, out);
    try testing.expectEqualSlices(u8, memory, out);
}

test "codec round-trips" {
    // Unchanged memory compresses to nothing.
    const original = [_]u8{ 1, 2, 3, 4, 5 };
    try expectRoundTrip(&original, &original);

    // Sparse changes, including the first and last byte.
    try expectRoundTrip(&.{ 9, 2, 3, 4, 7 }, &original);

    // Every byte changed.
    try expectRoundTrip(&.{ 2, 3, 4, 5, 6 }, &original);

    // Zero-runs longer than one chunk (256), and a change after them.
    var big_orig: [1000]u8 = @splat(0xaa);
    var big_mem = big_orig;
    big_mem[999] = 0x55;
    try expectRoundTrip(&big_mem, &big_orig);

    // Empty region.
    try expectRoundTrip(&.{}, &.{});
}

test "codec compresses unchanged memory to zero bytes" {
    const original = [_]u8{ 1, 2, 3, 4, 5 };
    var comp: std.Io.Writer.Allocating = .init(testing.allocator);
    defer comp.deinit();
    try compress(&original, &original, &comp.writer);
    try testing.expectEqual(@as(usize, 0), comp.written().len);
}

test "codec rejects overlong runs and trailing run markers" {
    var out: [4]u8 = undefined;
    const original = [_]u8{ 0, 0, 0, 0 };
    // Run of 6 zeros into a 4-byte region.
    try testing.expectError(error.InvalidState, decompress(&.{ 0, 5 }, &original, &out));
    // 0x00 marker with no count byte.
    try testing.expectError(error.InvalidState, decompress(&.{ 7, 0 }, &original, &out));
    // More literal bytes than the region holds.
    try testing.expectError(error.InvalidState, decompress(&.{ 1, 2, 3, 4, 5 }, &original, &out));
}
