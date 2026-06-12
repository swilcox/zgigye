//! Semantic highlighting of game output.
//!
//! `Vocabulary` pulls the object short names out of a story file, and
//! `annotate` splits a chunk of output into spans marking occurrences of
//! those names and of the current location. This is pure string work:
//! frontends decide what a span looks like (bold/italic in the TUI, CSS
//! classes on the web), and plain frontends simply never call it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Header = @import("header.zig").Header;
const Memory = @import("memory.zig").Memory;
const ObjectTable = @import("objects.zig").ObjectTable;
const zscii = @import("zscii.zig");

pub const Kind = enum { plain, location, keyword };

/// One run of output text. Concatenating a result's span texts in order
/// reproduces the annotated input exactly.
pub const Span = struct {
    text: []const u8,
    kind: Kind,
};

/// The object short names of a story, deduplicated case-insensitively
/// and sorted longest-first so that at any position the longest name
/// wins ("small mailbox" before "mailbox").
pub const Vocabulary = struct {
    names: [][]u8,

    pub fn fromStory(gpa: Allocator, story: []const u8) !Vocabulary {
        const header = try Header.parse(story);
        // Memory wants mutable bytes; work on a throwaway copy.
        const bytes = try gpa.dupe(u8, story);
        defer gpa.free(bytes);
        var mem = Memory{ .bytes = bytes, .static_start = header.static_memory };
        const objects = ObjectTable{ .mem = &mem, .base = header.object_table };

        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |name| gpa.free(name);
            names.deinit(gpa);
        }
        var scratch: std.Io.Writer.Allocating = .init(gpa);
        defer scratch.deinit();

        const object_count = try objects.count();
        for (1..@as(u32, object_count) + 1) |obj| {
            const addr = (try objects.nameAddr(@intCast(obj))) orelse continue;
            scratch.clearRetainingCapacity();
            zscii.decode(&mem, header.abbreviations, addr, &scratch.writer) catch continue;
            const name = scratch.written();
            if (name.len < 2) continue; // single letters would riddle the prose
            if (isParserPseudoObject(name)) continue;
            if (contains(names.items, name)) continue;
            try names.append(gpa, try gpa.dupe(u8, name));
        }

        std.mem.sort([]u8, names.items, {}, longerFirst);
        return .{ .names = try names.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: *Vocabulary, gpa: Allocator) void {
        for (self.names) |name| gpa.free(name);
        gpa.free(self.names);
        self.* = undefined;
    }

    /// Games define objects for parser bookkeeping — the player ("you"),
    /// pronoun referents ("it"), numeric input ("number"), local scenery
    /// stand-ins ("pseudo"). Highlighting those would italicize ordinary
    /// prose all over, so they are dropped.
    fn isParserPseudoObject(name: []const u8) bool {
        const pseudo = [_][]const u8{
            "you", "it", "me", "all", "them", "him", "her", "pseudo", "number",
        };
        for (pseudo) |p| {
            if (std.ascii.eqlIgnoreCase(name, p)) return true;
        }
        return false;
    }

    fn contains(names: []const []u8, candidate: []const u8) bool {
        for (names) |name| {
            if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
        }
        return false;
    }

    fn longerFirst(_: void, a: []u8, b: []u8) bool {
        return a.len > b.len;
    }
};

/// Split `text` into spans. At each word start the current `location` is
/// tried first (so a room name is marked .location even though rooms are
/// objects too), then `names` in order — pass them longest-first.
/// Matching is case-insensitive and both ends of a match must fall on
/// word boundaries ("mailbox" does not match inside "mailboxes").
/// Callers express their toggles by passing `location = null` and/or
/// `names = &.{}`. The caller frees the returned slice; span texts are
/// slices into `text`.
pub fn annotate(
    gpa: Allocator,
    names: []const []const u8,
    location: ?[]const u8,
    text: []const u8,
) Allocator.Error![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);

    var plain_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (isWordStart(text, i)) {
            if (matchAt(text, i, location, names)) |match| {
                if (i > plain_start) {
                    try spans.append(gpa, .{ .text = text[plain_start..i], .kind = .plain });
                }
                try spans.append(gpa, .{ .text = text[i..][0..match.len], .kind = match.kind });
                i += match.len;
                plain_start = i;
                continue;
            }
        }
        i += 1;
    }
    if (text.len > plain_start) {
        try spans.append(gpa, .{ .text = text[plain_start..], .kind = .plain });
    }
    return spans.toOwnedSlice(gpa);
}

const Match = struct { len: usize, kind: Kind };

fn matchAt(text: []const u8, i: usize, location: ?[]const u8, names: []const []const u8) ?Match {
    if (location) |loc| {
        if (phraseAt(text, i, loc)) return .{ .len = loc.len, .kind = .location };
    }
    for (names) |name| {
        if (phraseAt(text, i, name)) return .{ .len = name.len, .kind = .keyword };
    }
    return null;
}

fn phraseAt(text: []const u8, i: usize, phrase: []const u8) bool {
    if (phrase.len == 0 or phrase.len > text.len - i) return false;
    if (!std.ascii.eqlIgnoreCase(text[i..][0..phrase.len], phrase)) return false;
    const end = i + phrase.len;
    return end == text.len or !isWordChar(text[end]);
}

fn isWordStart(text: []const u8, i: usize) bool {
    return isWordChar(text[i]) and (i == 0 or !isWordChar(text[i - 1]));
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
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

test "annotate marks names and the location" {
    const names = [_][]const u8{ "small mailbox", "mailbox", "leaflet" };
    const spans = try annotate(
        testing.allocator,
        &names,
        "West of House",
        "West of House\nThere is a small mailbox here.",
    );
    defer testing.allocator.free(spans);
    try expectSpans(&.{
        .{ .text = "West of House", .kind = .location },
        .{ .text = "\nThere is a ", .kind = .plain },
        .{ .text = "small mailbox", .kind = .keyword },
        .{ .text = " here.", .kind = .plain },
    }, spans);
}

test "annotate is case-insensitive and longest-first" {
    const names = [_][]const u8{ "small mailbox", "mailbox" };
    const spans = try annotate(testing.allocator, &names, null, "Open the SMALL MAILBOX?");
    defer testing.allocator.free(spans);
    try expectSpans(&.{
        .{ .text = "Open the ", .kind = .plain },
        .{ .text = "SMALL MAILBOX", .kind = .keyword },
        .{ .text = "?", .kind = .plain },
    }, spans);
}

test "annotate respects word boundaries" {
    const names = [_][]const u8{"mailbox"};
    const spans = try annotate(testing.allocator, &names, null, "Two mailboxes, no thanks.");
    defer testing.allocator.free(spans);
    try expectSpans(&.{
        .{ .text = "Two mailboxes, no thanks.", .kind = .plain },
    }, spans);
}

test "annotate prefers location over keyword" {
    // Rooms are objects, so the room name is usually also in the vocabulary.
    const names = [_][]const u8{"West of House"};
    const spans = try annotate(testing.allocator, &names, "West of House", "West of House");
    defer testing.allocator.free(spans);
    try expectSpans(&.{
        .{ .text = "West of House", .kind = .location },
    }, spans);
}

test "annotate with nothing to match returns one plain span" {
    const spans = try annotate(testing.allocator, &.{}, null, "Nothing happens.");
    defer testing.allocator.free(spans);
    try expectSpans(&.{
        .{ .text = "Nothing happens.", .kind = .plain },
    }, spans);

    const empty = try annotate(testing.allocator, &.{}, null, "");
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}
