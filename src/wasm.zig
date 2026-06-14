//! WebAssembly frontend: one exported call per game turn.
//!
//! This is the browser counterpart to serve.zig. Where the web server turns
//! an HTTP request into a `session` turn and replies with JSON, this turns a
//! JS function call into the same turn and returns the *same JSON* — so a
//! browser page can reuse the highlight-span rendering the HTTP client
//! already uses. The core library is unchanged; like every other frontend it
//! only talks to the machine through `session`, which never touches I/O.
//!
//! The WASM call boundary only carries numbers, so strings cross as
//! (pointer, length) pairs into the module's own linear memory:
//!
//!   1. JS calls `alloc(len)` to get a buffer inside wasm memory, then
//!      writes the story bytes / state blob / input line into it.
//!   2. JS calls `setStory`, then `start` / `advance`.
//!   3. Those return a pointer to a UTF-8 JSON string; its length is
//!      `resultLen()`. JS reads it back out of `memory.buffer` and frees
//!      its input buffers with `dealloc`.
//!
//! The JSON is identical to serve.zig's TurnResponse: `output` is a list of
//! {text, kind} spans, `status` is the latest status line (or null), and
//! `state` is the base64 machine-state blob to pass back to `advance` (null
//! once the game ends). On failure the JSON is `{"error": "..."}`.

const std = @import("std");
const zgigye = @import("zgigye");
const session = zgigye.session;

// Freestanding wasm has no libc malloc; this is std's page-backed wasm heap.
const gpa = std.heap.wasm_allocator;

const max_steps_per_turn = 10_000_000;

// The currently loaded story, owned here so it outlives individual turns.
var story: []u8 = &.{};

// The JSON produced by the last turn. Kept alive after the call returns so
// JS can read it, then replaced (and freed) on the next turn.
var last_result: []u8 = &.{};

/// Identical shape to serve.zig's TurnResponse, so the rendered JSON matches.
const TurnResponse = struct {
    output: []const zgigye.highlight.Span,
    status: ?Status,
    state: ?[]const u8,

    const Status = struct {
        location: []const u8,
        progress: zgigye.StatusLine.Progress,
    };
};

// --- Memory marshalling ---------------------------------------------------

/// Reserve `len` bytes inside wasm memory for JS to write into. Null on OOM.
export fn alloc(len: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, len) catch return null;
    return buf.ptr;
}

/// Release a buffer previously returned by `alloc`.
export fn dealloc(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// Length in bytes of the JSON returned by the last `start`/`advance`.
export fn resultLen() usize {
    return last_result.len;
}

// --- Game control ---------------------------------------------------------

/// Load (a copy of) the story bytes JS wrote at `ptr`. Returns false on OOM.
export fn setStory(ptr: [*]const u8, len: usize) bool {
    const copy = gpa.dupe(u8, ptr[0..len]) catch return false;
    if (story.len != 0) gpa.free(story);
    story = copy;
    return true;
}

/// Start a new game; run to the first input prompt. Returns a pointer to the
/// JSON result (length via `resultLen`).
export fn start() ?[*]const u8 {
    return runTurn(null, null);
}

/// Apply one line of input to a saved state and run to the next prompt. The
/// state blob is the base64 string from the previous turn's JSON.
export fn advance(
    state_ptr: [*]const u8,
    state_len: usize,
    input_ptr: [*]const u8,
    input_len: usize,
) ?[*]const u8 {
    return runTurn(state_ptr[0..state_len], input_ptr[0..input_len]);
}

// --- Turn machinery -------------------------------------------------------

fn runTurn(state_b64: ?[]const u8, input: ?[]const u8) ?[*]const u8 {
    // Drop the previous turn's JSON before producing this one.
    if (last_result.len != 0) {
        gpa.free(last_result);
        last_result = &.{};
    }
    if (story.len == 0) return errorJson(error.NoStoryLoaded);

    // Everything a turn allocates is short-lived; an arena keeps it tidy and
    // is freed wholesale below. The JSON we hand back is built on gpa so it
    // survives the arena.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const turn = if (state_b64) |s| blk: {
        const decoder = std.base64.standard.Decoder;
        const len = decoder.calcSizeForSlice(s) catch return errorJson(error.InvalidState);
        const state = arena.alloc(u8, len) catch return errorJson(error.OutOfMemory);
        decoder.decode(state, s) catch return errorJson(error.InvalidState);
        break :blk session.advance(arena, story, state, input.?, max_steps_per_turn) catch |err|
            return errorJson(err);
    } else session.start(arena, story, max_steps_per_turn) catch |err|
        return errorJson(err);
    // `turn` is arena-allocated; arena.deinit cleans it up (no turn.deinit).

    const json = buildJson(arena, turn) catch |err| return errorJson(err);
    last_result = json;
    return json.ptr;
}

fn buildJson(arena: std.mem.Allocator, turn: session.Turn) ![]u8 {
    const state_b64: ?[]const u8 = if (turn.state) |blob| blk: {
        const encoder = std.base64.standard.Encoder;
        const buf = try arena.alloc(u8, encoder.calcSize(blob.len));
        break :blk encoder.encode(buf, blob);
    } else null;

    const payload: TurnResponse = .{
        .output = turn.spans,
        .status = if (turn.status) |s| .{ .location = s.location, .progress = s.progress } else null,
        .state = state_b64,
    };

    // Built on gpa so it outlives the arena; json.fmt copies span texts in.
    var json: std.Io.Writer.Allocating = .init(gpa);
    errdefer json.deinit();
    try json.writer.print("{f}", .{std.json.fmt(payload, .{})});
    return json.toOwnedSlice();
}

fn errorJson(err: anyerror) ?[*]const u8 {
    last_result = std.fmt.allocPrint(gpa, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
        return null;
    return last_result.ptr;
}
