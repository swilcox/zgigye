//! Debug commands that run outside the z-machine (spec-external).
//!
//! A line of player input beginning with `$` is intercepted before it
//! reaches the parser (see `Machine.readInput`) and handled here: it
//! inspects machine state — call frames, the dictionary, the object tree —
//! and writes a report. Nothing here mutates the machine, so a debug
//! command never perturbs a playthrough; it just peeks. Like the rest of
//! the core, this module touches no files or terminals: output goes to a
//! `std.Io.Writer` the caller then hands to the `Ui`.

const std = @import("std");
const Machine = @import("machine.zig").Machine;
const zscii = @import("zscii.zig");
const dictionary = @import("dictionary.zig");

/// Object short names can be long (the v3 cap is generous), but the ones
/// we compare against are room/item names; this is plenty and lets the
/// resolver work without an allocator.
const name_buf_len = 256;

pub const help_text =
    \\Debug commands (run outside the game):
    \\  $help            list these commands
    \\  $dump            program counter, call frames, evaluation stack
    \\  $dict            the story's dictionary
    \\  $tree            the whole object tree
    \\  $room            sub-tree of the current location
    \\  $you             sub-tree of the player object
    \\  $object num|name an object's sub-tree
    \\  $attrs num|name  an object's set attribute flags
    \\  $props num|name  an object's properties
    \\  $find name       object numbers whose name matches
    \\  $header          story header fields
    \\
;

/// Handle `line` if it is a debug command. Returns true when it was one
/// (a report has been written to `w`), false when `line` is ordinary game
/// input the caller should pass on to the parser. Command-level errors
/// (a bad object number, say) are reported in `w`, not returned; only
/// writer failures and out-of-memory propagate.
pub fn dispatch(m: *Machine, w: *std.Io.Writer, line: []const u8) !bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '$') return false;

    var it = std.mem.tokenizeScalar(u8, trimmed[1..], ' ');
    const cmd = it.next() orelse "help";
    const arg = std.mem.trim(u8, it.rest(), " \t\r\n");

    run(m, w, cmd, arg) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return err,
        else => try w.print("(error: {t})\n", .{err}),
    };
    return true;
}

fn run(m: *Machine, w: *std.Io.Writer, cmd: []const u8, arg: []const u8) !void {
    if (eql(cmd, "help")) {
        try w.writeAll(help_text);
    } else if (eql(cmd, "dump")) {
        try dump(m, w);
    } else if (eql(cmd, "dict")) {
        try dict(m, w);
    } else if (eql(cmd, "tree")) {
        try tree(m, w);
    } else if (eql(cmd, "room")) {
        try subtreeOf(m, w, try m.readGlobal(0), "current location");
    } else if (eql(cmd, "you")) {
        const player = try findPlayer(m) orelse {
            try w.writeAll("Could not identify the player object.\n");
            return;
        };
        try subtreeOf(m, w, player, "player");
    } else if (eql(cmd, "object")) {
        if (try resolveOrReport(m, w, arg)) |obj| try subtreeOf(m, w, obj, null);
    } else if (eql(cmd, "attrs")) {
        if (try resolveOrReport(m, w, arg)) |obj| try attrs(m, w, obj);
    } else if (eql(cmd, "props")) {
        if (try resolveOrReport(m, w, arg)) |obj| try props(m, w, obj);
    } else if (eql(cmd, "find")) {
        try find(m, w, arg);
    } else if (eql(cmd, "header")) {
        try header(m, w);
    } else {
        try w.print("Unknown debug command '${s}'. Type $help.\n", .{cmd});
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// --- $dump ---

fn dump(m: *Machine, w: *std.Io.Writer) !void {
    try w.print("PC: 0x{x:0>5}\n", .{m.pc});

    const frames = m.frames.items;
    try w.print("Call frames: {d} (innermost last)\n", .{frames.len});
    for (frames, 0..) |frame, i| {
        // Each frame owns the slice of the shared evaluation stack from
        // its base up to the next frame's base (the top frame, to the top).
        const top = if (i + 1 < frames.len) frames[i + 1].stack_base else m.stack.items.len;
        const pushed = m.stack.items[frame.stack_base..top];

        if (i == 0) {
            try w.writeAll("  [0] main");
        } else {
            try w.print("  [{d}] return->0x{x:0>5} store=", .{ i, frame.resume_pc });
            try writeVariable(w, frame.store);
            try w.print(" args={d}", .{frame.arg_count});
        }
        try w.print(" locals={d}", .{frame.locals_count});
        if (frame.locals_count > 0) {
            try w.writeAll(" [");
            for (frame.locals[0..frame.locals_count], 0..) |local, n| {
                if (n > 0) try w.writeAll(", ");
                try w.print("0x{x:0>4}", .{local});
            }
            try w.writeByte(']');
        }
        try w.print(" stack={d}", .{pushed.len});
        if (pushed.len > 0) {
            try w.writeAll(" [");
            for (pushed, 0..) |value, n| {
                if (n > 0) try w.writeAll(", ");
                try w.print("0x{x:0>4}", .{value});
            }
            try w.writeByte(']');
        }
        try w.writeByte('\n');
    }
}

/// A variable reference as the z-machine names them: the stack (0), a
/// local (1-15), or a global (16-255). `null` is a discarded result.
fn writeVariable(w: *std.Io.Writer, variable: ?u8) !void {
    const v = variable orelse return w.writeAll("(discard)");
    switch (v) {
        0 => try w.writeAll("sp"),
        1...Machine_max_locals => try w.print("L{x:0>2}", .{v - 1}),
        else => try w.print("G{x:0>2}", .{v - 16}),
    }
}

const Machine_max_locals = @import("machine.zig").max_locals;

// --- $dict ---

fn dict(m: *Machine, w: *std.Io.Writer) !void {
    const d = m.dict;
    try w.print("Dictionary at 0x{x:0>4}: {d} entries, entry length {d}\n", .{
        d.entries_addr, d.entry_count, d.entry_length,
    });
    if (d.separators.len > 0) {
        try w.writeAll("Separators:");
        for (d.separators) |c| try w.print(" '{c}'", .{c});
        try w.writeByte('\n');
    }
    for (0..d.entry_count) |i| {
        const addr: u32 = @intCast(d.entries_addr + i * d.entry_length);
        try w.print("  [{d:>3}] 0x{x:0>4}  ", .{ i, addr });
        // The encoded word sits in the first 4 bytes (two words, the end
        // bit set on the second), so decoding from the entry start yields
        // the word text.
        try zscii.decode(&m.memory, m.header.abbreviations, addr, w);
        try w.writeByte('\n');
    }
}

// --- Object tree ($tree, $room, $you, $object) ---

fn tree(m: *Machine, w: *std.Io.Writer) !void {
    const count = try m.objects.count();
    try w.print("Object tree ({d} objects):\n", .{count});
    var obj: u16 = 1;
    while (obj <= count) : (obj += 1) {
        // Roots only; their descendants are printed recursively.
        if (try m.objects.parent(obj) == 0) try printSubtree(m, w, obj, 0);
    }
}

fn subtreeOf(m: *Machine, w: *std.Io.Writer, obj: u16, label: ?[]const u8) !void {
    if (obj == 0) {
        try w.print("{s} is nothing (object 0).\n", .{label orelse "Object"});
        return;
    }
    if (label) |l| try w.print("Sub-tree of {s}:\n", .{l});
    try printSubtree(m, w, obj, 0);
}

fn printSubtree(m: *Machine, w: *std.Io.Writer, obj: u16, depth: usize) !void {
    for (0..depth) |_| try w.writeAll("  ");
    try w.print("[{d}] ", .{obj});
    try printName(m, w, obj);
    try w.writeByte('\n');

    var c = try m.objects.child(obj);
    while (c != 0) : (c = try m.objects.sibling(c)) {
        try printSubtree(m, w, c, depth + 1);
    }
}

fn printName(m: *Machine, w: *std.Io.Writer, obj: u16) !void {
    if (try m.objects.nameAddr(obj)) |addr| {
        try zscii.decode(&m.memory, m.header.abbreviations, addr, w);
    } else {
        try w.writeAll("(no name)");
    }
}

/// A `Object N "name" suffix:` heading shared by the per-object reports.
fn objectHeading(m: *Machine, w: *std.Io.Writer, obj: u16, suffix: []const u8) !void {
    try w.print("Object {d} ", .{obj});
    try printName(m, w, obj);
    try w.print(" {s}:\n", .{suffix});
}

// --- $attrs and $props ---

fn attrs(m: *Machine, w: *std.Io.Writer, obj: u16) !void {
    try objectHeading(m, w, obj, "attributes");
    try w.writeAll("  set:");
    var any = false;
    var a: u16 = 0;
    while (a < attr_count) : (a += 1) {
        if (try m.objects.testAttr(obj, a)) {
            try w.print(" {d}", .{a});
            any = true;
        }
    }
    if (!any) try w.writeAll(" (none)");
    try w.writeByte('\n');
}

/// Objects carry 32 attribute flags (four bytes, spec 12.3.1).
const attr_count = 32;

fn props(m: *Machine, w: *std.Io.Writer, obj: u16) !void {
    try objectHeading(m, w, obj, "properties");
    var prop = try m.objects.firstProperty(obj);
    if (prop == null) try w.writeAll("  (none)\n");
    while (prop) |p| : (prop = try m.objects.nextProperty(p)) {
        try w.print("  [{d}] size {d}:", .{ p.number, p.size });
        for (0..p.size) |i| {
            try w.print(" 0x{x:0>2}", .{try m.memory.readByte(p.data_addr + @as(u32, @intCast(i)))});
        }
        try w.writeByte('\n');
    }
}

// --- $header ---

fn header(m: *Machine, w: *std.Io.Writer) !void {
    const h = m.header;
    try w.writeAll("Header:\n");
    try w.print("  version:       {d}\n", .{h.version});
    try w.print("  release:       {d}\n", .{h.release});
    try w.print("  serial:        {s}\n", .{&h.serial});
    try w.print("  high memory:   0x{x:0>4}\n", .{h.high_memory});
    try w.print("  initial pc:    0x{x:0>4}\n", .{h.initial_pc});
    try w.print("  dictionary:    0x{x:0>4}\n", .{h.dictionary});
    try w.print("  object table:  0x{x:0>4}\n", .{h.object_table});
    try w.print("  globals:       0x{x:0>4}\n", .{h.globals});
    try w.print("  static memory: 0x{x:0>4}\n", .{h.static_memory});
    try w.print("  abbreviations: 0x{x:0>4}\n", .{h.abbreviations});
    try w.print("  file length:   {d} bytes\n", .{h.file_length});
    try w.print("  checksum:      0x{x:0>4} stored, 0x{x:0>4} computed\n", .{ h.checksum, m.checksum() });
    try w.print("  status line:   {s}\n", .{@tagName(h.status_line_type)});
}

// --- $find and name resolution ---

fn find(m: *Machine, w: *std.Io.Writer, arg: []const u8) !void {
    if (arg.len == 0) {
        try w.writeAll("Usage: $find name\n");
        return;
    }
    const count = try m.objects.count();
    var hits: u16 = 0;
    var obj: u16 = 1;
    while (obj <= count) : (obj += 1) {
        var buf: [name_buf_len]u8 = undefined;
        const name = (try objectName(m, obj, &buf)) orelse continue;
        if (std.ascii.indexOfIgnoreCase(name, arg) != null) {
            try w.print("  [{d}] {s}\n", .{ obj, name });
            hits += 1;
        }
    }
    if (hits == 0) try w.print("No object name contains '{s}'.\n", .{arg});
}

/// `resolve`, but write a "no match" line when nothing is found so each
/// per-object command needn't repeat it.
fn resolveOrReport(m: *Machine, w: *std.Io.Writer, arg: []const u8) !?u16 {
    return (try resolve(m, arg)) orelse {
        try w.print("No object matches '{s}'.\n", .{arg});
        return null;
    };
}

/// Resolve `arg` to an object number: a decimal number is taken literally,
/// otherwise the first object whose name equals `arg` (case-insensitive),
/// failing that the first whose name contains it.
fn resolve(m: *Machine, arg: []const u8) !?u16 {
    if (arg.len == 0) return null;
    if (std.fmt.parseInt(u16, arg, 10)) |n| {
        return n;
    } else |_| {}

    const count = try m.objects.count();
    var substring_match: ?u16 = null;
    var obj: u16 = 1;
    while (obj <= count) : (obj += 1) {
        var buf: [name_buf_len]u8 = undefined;
        const name = (try objectName(m, obj, &buf)) orelse continue;
        if (eql(name, arg)) return obj;
        if (substring_match == null and std.ascii.indexOfIgnoreCase(name, arg) != null) {
            substring_match = obj;
        }
    }
    return substring_match;
}

/// Games define a player object; its short name is one of a handful of
/// conventional words ("you", "cretin" in Zork, ...). Find the first
/// object so named.
fn findPlayer(m: *Machine) !?u16 {
    const aliases = [_][]const u8{ "you", "yourself", "cretin", "adventurer", "me" };
    const count = try m.objects.count();
    var obj: u16 = 1;
    while (obj <= count) : (obj += 1) {
        var buf: [name_buf_len]u8 = undefined;
        const name = (try objectName(m, obj, &buf)) orelse continue;
        for (aliases) |alias| {
            if (eql(name, alias)) return obj;
        }
    }
    return null;
}

/// Decode an object's short name into `buf`, or null if it has none or is
/// too long to fit (the latter never happens for real room/item names).
fn objectName(m: *Machine, obj: u16, buf: []u8) !?[]const u8 {
    const addr = (try m.objects.nameAddr(obj)) orelse return null;
    var fixed = std.Io.Writer.fixed(buf);
    zscii.decode(&m.memory, m.header.abbreviations, addr, &fixed) catch return null;
    return fixed.buffered();
}

// --- Tests ---

const TextUi = @import("text_ui.zig").TextUi;
const minizork_story = @embedFile("testdata/minizork.z3");

/// Build a machine and run it to the first input prompt, so the object
/// tree and the location global (0) are populated. Returns the machine and
/// an output writer the caller must clean up.
fn machineAtPrompt(gpa: std.mem.Allocator, sink: *std.Io.Writer.Allocating) !*Machine {
    var in = std.Io.Reader.fixed("");
    var ui = TextUi{ .out = &sink.writer, .in = &in };
    const m = try Machine.create(gpa, minizork_story, ui.ui());
    m.steps_remaining = 10_000_000;
    // Runs until it asks for input; the empty reader then ends the stream.
    m.run() catch |err| switch (err) {
        error.EndOfStream => {},
        else => {
            m.destroy();
            return err;
        },
    };
    return m;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("--- output ---\n{s}\n--- missing: {s}\n", .{ haystack, needle });
        return error.MissingSubstring;
    }
}

test "dispatch ignores ordinary input and recognises debug commands" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    const m = try machineAtPrompt(gpa, &sink);
    defer m.destroy();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expect(!try dispatch(m, &out.writer, "open mailbox"));
    try std.testing.expect(!try dispatch(m, &out.writer, ""));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);

    try std.testing.expect(try dispatch(m, &out.writer, "$help"));
    try expectContains(out.written(), "$dump");
}

test "dump reports the pc and the main frame" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    const m = try machineAtPrompt(gpa, &sink);
    defer m.destroy();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try dispatch(m, &out.writer, "$dump");
    try expectContains(out.written(), "PC: 0x");
    try expectContains(out.written(), "[0] main");
}

test "dict lists known words" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    const m = try machineAtPrompt(gpa, &sink);
    defer m.destroy();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try dispatch(m, &out.writer, "$dict");
    // v3 dictionary words are truncated to six z-characters, so the entry
    // for "mailbox" reads "mailbo".
    try expectContains(out.written(), "mailbo");
    try expectContains(out.written(), "window");
}

test "tree and room show the object hierarchy" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    const m = try machineAtPrompt(gpa, &sink);
    defer m.destroy();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try dispatch(m, &out.writer, "$tree");
    try expectContains(out.written(), "Object tree (");
    try expectContains(out.written(), "mailbox");

    out.clearRetainingCapacity();
    _ = try dispatch(m, &out.writer, "$room");
    try expectContains(out.written(), "West of House");
}

test "find and object resolve names and numbers" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    const m = try machineAtPrompt(gpa, &sink);
    defer m.destroy();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try dispatch(m, &out.writer, "$find mailbox");
    try expectContains(out.written(), "mailbox");

    // $object by name should agree with $object by the number $find printed.
    out.clearRetainingCapacity();
    _ = try dispatch(m, &out.writer, "$object mailbox");
    try expectContains(out.written(), "mailbox");

    // A number past the table resolves but fails to read; reported, not fatal.
    out.clearRetainingCapacity();
    _ = try dispatch(m, &out.writer, "$object 60000");
    try expectContains(out.written(), "error:");
}

test "attrs and props inspect an object" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    const m = try machineAtPrompt(gpa, &sink);
    defer m.destroy();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try dispatch(m, &out.writer, "$attrs small mailbox");
    try expectContains(out.written(), "attributes");
    try expectContains(out.written(), "set:");

    out.clearRetainingCapacity();
    _ = try dispatch(m, &out.writer, "$props small mailbox");
    try expectContains(out.written(), "properties");
    try expectContains(out.written(), "size ");

    out.clearRetainingCapacity();
    _ = try dispatch(m, &out.writer, "$attrs nonsuch");
    try expectContains(out.written(), "No object matches");
}

test "header reports story metadata" {
    const gpa = std.testing.allocator;
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    const m = try machineAtPrompt(gpa, &sink);
    defer m.destroy();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try dispatch(m, &out.writer, "$header");
    try expectContains(out.written(), "version:       3");
    try expectContains(out.written(), "871124"); // serial, shown in the banner too
}
