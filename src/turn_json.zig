//! The JSON wire format for a turn, shared by every frontend that reports
//! one to a browser.
//!
//! `serve.zig` and `wasm.zig` deliver turns by completely different routes
//! — an HTTP response, and a pointer into a WebAssembly module's linear
//! memory — but the page rendering them is the same page, so the bytes in
//! between have to be identical. Keeping the shape here is what makes that
//! true by construction rather than by two definitions being kept in step
//! by hand.
//!
//! A turn is:
//!
//!   {"output": [{"text": "...", "kind": "plain"|"location"|"keyword"}, ...],
//!    "status": {"location": "...", "progress": {...}} | null,
//!    "state":  "<base64>" | null}
//!
//! Concatenating the `output` texts reproduces the turn's raw text; `kind`
//! marks the object names the game printed (see highlight.zig). `state` is
//! the blob to hand back to `session.advance`, and is null once the game
//! has ended. A failure is reported as {"error": "..."} instead.

const std = @import("std");
const Allocator = std.mem.Allocator;

const session = @import("session.zig");
const highlight = @import("highlight.zig");
const StatusLine = @import("ui.zig").StatusLine;

/// The serialised form. Field names and types are the wire format; the
/// `Span` and `Progress` types render as objects via std.json.
pub const Response = struct {
    output: []const highlight.Span,
    status: ?Status,
    state: ?[]const u8,

    pub const Status = struct {
        location: []const u8,
        progress: StatusLine.Progress,
    };
};

/// Render `turn` as JSON into `w`. The state blob is base64-encoded, so the
/// text is safe to embed in JSON and to hand back through a URL or form.
pub fn writeTurn(gpa: Allocator, turn: session.Turn, w: *std.Io.Writer) !void {
    const state_b64: ?[]const u8 = if (turn.state) |blob| blk: {
        const encoder = std.base64.standard.Encoder;
        const buf = try gpa.alloc(u8, encoder.calcSize(blob.len));
        break :blk encoder.encode(buf, blob);
    } else null;
    defer if (state_b64) |s| gpa.free(s);

    const payload: Response = .{
        .output = turn.spans,
        .status = if (turn.status) |s| .{ .location = s.location, .progress = s.progress } else null,
        .state = state_b64,
    };
    try w.print("{f}", .{std.json.fmt(payload, .{})});
}

/// Render `turn` as a JSON string owned by the caller.
pub fn allocTurn(gpa: Allocator, turn: session.Turn) ![]u8 {
    var json: std.Io.Writer.Allocating = .init(gpa);
    errdefer json.deinit();
    try writeTurn(gpa, turn, &json.writer);
    return json.toOwnedSlice();
}

/// Render a failure in the shape the page expects. The name is the error
/// tag, which is stable enough to show and specific enough to act on.
pub fn allocError(gpa: Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
}

/// Decode a base64 state blob from a client. Untrusted: the bytes it yields
/// still go through `Machine.loadState`, which validates them.
pub fn decodeState(gpa: Allocator, base64: []const u8) error{ InvalidState, OutOfMemory }![]u8 {
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(base64) catch return error.InvalidState;
    const state = try gpa.alloc(u8, len);
    errdefer gpa.free(state);
    decoder.decode(state, base64) catch return error.InvalidState;
    return state;
}

// --- Tests ---

const testing = std.testing;
const zork1_story = @embedFile("testdata/zork1.z3");
const max_steps = 10_000_000;

test "a turn renders as the documented shape" {
    const gpa = testing.allocator;
    var turn = try session.start(gpa, zork1_story, max_steps);
    defer turn.deinit(gpa);

    const json = try allocTurn(gpa, turn);
    defer gpa.free(json);

    // Parse it back rather than matching text, so the test pins the shape
    // and not the formatter's spacing.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const output = root.get("output").?.array;
    try testing.expect(output.items.len > 0);
    // Every span carries text and one of the three kinds, and concatenating
    // them reproduces the turn exactly — the property the page relies on.
    var joined: std.Io.Writer.Allocating = .init(gpa);
    defer joined.deinit();
    for (output.items) |span| {
        const kind = span.object.get("kind").?.string;
        try testing.expect(
            std.mem.eql(u8, kind, "plain") or
                std.mem.eql(u8, kind, "location") or
                std.mem.eql(u8, kind, "keyword"),
        );
        try joined.writer.writeAll(span.object.get("text").?.string);
    }
    try testing.expectEqualStrings(turn.output, joined.written());

    // The status line is structured, not preformatted.
    const status = root.get("status").?.object;
    try testing.expectEqualStrings("West of House", status.get("location").?.string);
    const score = status.get("progress").?.object.get("score").?.object;
    try testing.expectEqual(@as(i64, 0), score.get("score").?.integer);

    // The state round-trips back to the bytes the session produced.
    const decoded = try decodeState(gpa, root.get("state").?.string);
    defer gpa.free(decoded);
    try testing.expectEqualSlices(u8, turn.state.?, decoded);
}

test "a finished game reports a null state" {
    const gpa = testing.allocator;
    var turn = try session.start(gpa, zork1_story, max_steps);
    defer turn.deinit(gpa);

    for ([_][]const u8{ "quit", "y" }) |command| {
        const blob = turn.state orelse break;
        const next = try session.advance(gpa, zork1_story, blob, command, max_steps);
        turn.deinit(gpa);
        turn = next;
    }
    try testing.expectEqual(@as(?[]u8, null), turn.state);

    const json = try allocTurn(gpa, turn);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(std.json.Value.null, parsed.value.object.get("state").?);
}

test "errors render as an error object" {
    const gpa = testing.allocator;
    const json = try allocError(gpa, error.InvalidState);
    defer gpa.free(json);
    try testing.expectEqualStrings("{\"error\":\"InvalidState\"}", json);
}

test "state decoding rejects text that is not base64" {
    try testing.expectError(error.InvalidState, decodeState(testing.allocator, "not base64!!"));
}
