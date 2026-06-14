//! The span model for object-name highlighting.
//!
//! Highlighting is decided at print time: when the game runs the print_obj
//! opcode, the core marks that text as an object name (the current location
//! is one kind, every other object another). Frontends collect those marks
//! over a turn's output and decide what a span looks like — bold/italic in
//! the TUI, CSS classes on the web; plain frontends ignore them entirely.
//! This module just carries the span types and assembles a flat span list
//! from a turn's text and the marks recorded over it.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { plain, location, keyword };

/// One run of output text. Concatenating a result's span texts in order
/// reproduces the original text exactly.
pub const Span = struct {
    text: []const u8,
    kind: Kind,
};

/// An object name recorded at print time, as offsets into the turn's output
/// text. `kind` is `location` or `keyword`, never `plain`.
pub const Mark = struct {
    start: usize,
    len: usize,
    kind: Kind,
};

/// Build a flat span list over `text` from object-name `marks` (ordered by
/// start and non-overlapping, as the core records them), filling the gaps
/// between marks with plain spans. Span texts are slices into `text`; the
/// caller frees the returned slice.
pub fn spansFromMarks(gpa: Allocator, text: []const u8, marks: []const Mark) Allocator.Error![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);

    var pos: usize = 0;
    for (marks) |mark| {
        if (mark.start > pos) {
            try spans.append(gpa, .{ .text = text[pos..mark.start], .kind = .plain });
        }
        const end = mark.start + mark.len;
        try spans.append(gpa, .{ .text = text[mark.start..end], .kind = mark.kind });
        pos = end;
    }
    if (pos < text.len) {
        try spans.append(gpa, .{ .text = text[pos..], .kind = .plain });
    }
    return spans.toOwnedSlice(gpa);
}

// --- Tests ---

const testing = std.testing;

fn expectSpans(expected: []const Span, actual: []const Span) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqualStrings(e.text, a.text);
        try testing.expectEqual(e.kind, a.kind);
    }
}

test "spansFromMarks interleaves plain text and marks" {
    const text = "West of House\nThere is a small mailbox here.";
    const marks = [_]Mark{
        .{ .start = 0, .len = 13, .kind = .location }, // "West of House"
        .{ .start = 25, .len = 13, .kind = .keyword }, // "small mailbox"
    };
    const spans = try spansFromMarks(testing.allocator, text, &marks);
    defer testing.allocator.free(spans);
    try expectSpans(&.{
        .{ .text = "West of House", .kind = .location },
        .{ .text = "\nThere is a ", .kind = .plain },
        .{ .text = "small mailbox", .kind = .keyword },
        .{ .text = " here.", .kind = .plain },
    }, spans);
}

test "spansFromMarks with no marks is a single plain span" {
    const spans = try spansFromMarks(testing.allocator, "Nothing happens.", &.{});
    defer testing.allocator.free(spans);
    try expectSpans(&.{.{ .text = "Nothing happens.", .kind = .plain }}, spans);

    const empty = try spansFromMarks(testing.allocator, "", &.{});
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "spansFromMarks handles a mark flush against each end" {
    const marks = [_]Mark{.{ .start = 0, .len = 3, .kind = .keyword }};
    const spans = try spansFromMarks(testing.allocator, "cat", &marks);
    defer testing.allocator.free(spans);
    try expectSpans(&.{.{ .text = "cat", .kind = .keyword }}, spans);
}
