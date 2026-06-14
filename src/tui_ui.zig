//! A full-screen terminal frontend built on libvaxis.
//!
//! Layout: a title bar showing the story name and live status (location,
//! score/turns or time), a scrolling transcript window, an input line, and
//! a footer with key hints. PgUp/PgDn scroll the transcript.
//!
//! This file is part of the executable, not the core library: the z-machine
//! itself only ever sees the `Ui` interface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const zgigye = @import("zgigye");
const Ui = zgigye.Ui;
const StatusLine = zgigye.StatusLine;
const theme_mod = @import("theme.zig");
pub const Theme = theme_mod.Theme;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

/// One word-wrapped display row: a slice of the transcript plus where it
/// starts, so highlight marks (kept in transcript offsets) can be overlaid.
const Row = struct {
    text: []const u8,
    off: usize,
};

/// A styled region of the transcript, in transcript byte offsets.
const Mark = struct {
    start: usize,
    end: usize,
    kind: zgigye.highlight.Kind,
};

pub const TuiUi = struct {
    gpa: Allocator,
    tty: vaxis.Tty,
    tty_buffer: [4096]u8,
    vx: vaxis.Vaxis,
    loop: vaxis.Loop(Event),
    input: vaxis.widgets.TextInput,

    /// Story name shown in the title bar.
    title: []const u8,
    options: Options,
    /// Everything the game has printed, with '\n' separators.
    transcript: std.ArrayList(u8),
    /// Transcript word-wrapped to the current width (slices into transcript).
    rows: std.ArrayList(Row),
    /// Highlighted regions, ordered by start offset.
    marks: std.ArrayList(Mark),
    /// How many rows the user has scrolled up from the bottom.
    scroll: usize = 0,
    /// The game's own trailing ">" prompt was hidden for this read; it is
    /// restored in front of the echoed command.
    prompt_stripped: bool = false,
    status_text: [128]u8 = undefined,
    status_len: usize = 0,

    pub const Options = struct {
        /// Embolden the current location's name where the game prints it.
        highlight_location: bool = true,
        /// Italicize other object names where the game prints them.
        highlight_keywords: bool = true,
        /// Colours and attributes for each styled element.
        theme: Theme = theme_mod.default,
    };

    /// Heap-allocated because the event loop holds pointers into the struct.
    pub fn create(
        gpa: Allocator,
        io: std.Io,
        environ_map: *std.process.Environ.Map,
        title: []const u8,
        options: Options,
    ) !*TuiUi {
        const self = try gpa.create(TuiUi);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .tty = undefined,
            .tty_buffer = undefined,
            .vx = undefined,
            .loop = undefined,
            .input = vaxis.widgets.TextInput.init(gpa),
            .title = title,
            .options = options,
            .transcript = .empty,
            .rows = .empty,
            .marks = .empty,
        };
        self.tty = try vaxis.Tty.init(io, &self.tty_buffer);
        self.vx = try vaxis.init(io, gpa, environ_map, .{});
        self.loop = .init(io, &self.tty, &self.vx);

        try self.loop.start();
        errdefer self.loop.stop();
        try self.vx.enterAltScreen(self.tty.writer());
        try self.tty.writer().flush();
        try self.vx.queryTerminal(self.tty.writer(), .fromSeconds(1));
        return self;
    }

    pub fn destroy(self: *TuiUi) void {
        const gpa = self.gpa;
        self.loop.stop();
        self.vx.deinit(gpa, self.tty.writer());
        self.tty.deinit();
        self.input.deinit();
        self.marks.deinit(gpa);
        self.rows.deinit(gpa);
        self.transcript.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn ui(self: *TuiUi) Ui {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Keep the final screen up until a key is pressed; without this the
    /// game's parting words would vanish with the alternate screen.
    pub fn waitForExit(self: *TuiUi) !void {
        try self.appendTranscript("\n[ Press any key to exit. ]");
        try self.render();
        while (true) {
            switch (try self.loop.nextEvent()) {
                .key_press => |key| {
                    if (key.matches(vaxis.Key.page_up, .{})) {
                        self.scroll += self.pageSize();
                    } else if (key.matches(vaxis.Key.page_down, .{})) {
                        self.scroll -|= self.pageSize();
                    } else return;
                },
                .winsize => |ws| try self.resize(ws),
            }
            try self.render();
        }
    }

    // --- Ui interface ---

    const vtable = Ui.VTable{
        .print = print,
        .printObject = printObject,
        .readLine = readLine,
        .showStatus = showStatus,
    };

    fn print(ptr: *anyopaque, text: []const u8) anyerror!void {
        const self: *TuiUi = @ptrCast(@alignCast(ptr));
        try self.appendTranscript(text);
    }

    /// An object name (from print_obj): append it and record a highlight
    /// mark over those bytes, unless that kind is disabled. Plain output
    /// (`print`) never marks, so echoed commands and prose stay plain.
    fn printObject(ptr: *anyopaque, text: []const u8, location: bool) anyerror!void {
        const self: *TuiUi = @ptrCast(@alignCast(ptr));
        const start = self.transcript.items.len;
        try self.appendTranscript(text);
        const enabled = if (location) self.options.highlight_location else self.options.highlight_keywords;
        if (enabled) try self.marks.append(self.gpa, .{
            .start = start,
            .end = self.transcript.items.len,
            .kind = if (location) .location else .keyword,
        });
    }

    fn readLine(ptr: *anyopaque, buf: []u8) anyerror![]const u8 {
        const self: *TuiUi = @ptrCast(@alignCast(ptr));
        self.stripPrompt();
        try self.render();
        while (true) {
            switch (try self.loop.nextEvent()) {
                .key_press => |key| {
                    if (key.matches('c', .{ .ctrl = true })) return error.Interrupted;
                    if (key.matches(vaxis.Key.enter, .{})) return self.acceptInput(buf);
                    if (key.matches(vaxis.Key.page_up, .{})) {
                        self.scroll += self.pageSize();
                    } else if (key.matches(vaxis.Key.page_down, .{})) {
                        self.scroll -|= self.pageSize();
                    } else {
                        try self.input.update(.{ .key_press = key });
                    }
                },
                .winsize => |ws| try self.resize(ws),
            }
            try self.render();
        }
    }

    fn showStatus(ptr: *anyopaque, status: StatusLine) anyerror!void {
        const self: *TuiUi = @ptrCast(@alignCast(ptr));
        var writer = std.Io.Writer.fixed(&self.status_text);
        switch (status.progress) {
            .score => |s| writer.print("{s}  |  Score: {d}  Moves: {d}", .{
                status.location, s.score, s.turns,
            }) catch {},
            .time => |t| {
                const hours12 = if (t.hours % 12 == 0) 12 else t.hours % 12;
                const half: []const u8 = if (t.hours >= 12) "PM" else "AM";
                writer.print("{s}  |  {d}:{d:0>2} {s}", .{
                    status.location, hours12, t.minutes, half,
                }) catch {};
            },
        }
        self.status_len = writer.buffered().len;
    }

    // --- Internals ---

    fn appendTranscript(self: *TuiUi, text: []const u8) !void {
        try self.transcript.appendSlice(self.gpa, text);
        self.scroll = 0; // new output snaps the view back to the bottom
    }

    /// The game usually prints its own "> " just before reading; hide it
    /// while our input line is showing so there is only one prompt.
    fn stripPrompt(self: *TuiUi) void {
        const text = self.transcript.items;
        var end = text.len;
        while (end > 0 and text[end - 1] == ' ') end -= 1;
        if (end > 0 and text[end - 1] == '>') {
            self.transcript.shrinkRetainingCapacity(end - 1);
            self.prompt_stripped = true;
        }
    }

    /// Enter was pressed: echo the line into the transcript and hand it
    /// to the machine.
    fn acceptInput(self: *TuiUi, buf: []u8) ![]const u8 {
        const line = try self.input.toOwnedSlice();
        defer self.gpa.free(line);
        self.input.reset();

        if (self.prompt_stripped) {
            self.prompt_stripped = false;
            try self.appendTranscript("> ");
        }
        try self.appendTranscript(line);
        try self.appendTranscript("\n");
        try self.render();

        const len = @min(line.len, buf.len);
        @memcpy(buf[0..len], line[0..len]);
        return buf[0..len];
    }

    fn resize(self: *TuiUi, ws: vaxis.Winsize) !void {
        try self.vx.resize(self.gpa, self.tty.writer(), ws);
    }

    fn pageSize(self: *TuiUi) usize {
        return @max(1, self.outputHeight() / 2);
    }

    fn outputHeight(self: *TuiUi) usize {
        const h = self.vx.window().height;
        // Three rows of chrome: title, input line, footer.
        return if (h > 3) h - 3 else 0;
    }

    fn render(self: *TuiUi) !void {
        const win = self.vx.window();
        win.clear();
        const width = win.width;
        const height = win.height;
        if (width < 4 or height < 4) return;

        const theme = self.options.theme;
        // Paint the whole screen with the body style; the bars below repaint
        // their own rows, and the transcript text inherits the body colour.
        win.fill(.{ .style = theme.body });

        // Title bar: story name left, status right.
        const title_bar = win.child(.{ .height = 1 });
        title_bar.fill(.{ .style = theme.title });
        _ = title_bar.printSegment(
            .{ .text = self.title, .style = theme.title },
            .{ .col_offset = 1, .wrap = .none },
        );
        const status = self.status_text[0..self.status_len];
        if (status.len > 0 and width > status.len + 2) {
            _ = title_bar.printSegment(
                .{ .text = status, .style = theme.title },
                .{ .col_offset = @intCast(width - status.len - 1), .wrap = .none },
            );
        }

        // Transcript: word-wrapped, bottom-aligned, scrolled by `scroll`.
        const out_win = win.child(.{ .y_off = 1, .x_off = 1, .width = width - 2, .height = @intCast(self.outputHeight()) });
        try self.rebuildRows(out_win.width);
        const visible: usize = out_win.height;
        const max_scroll = self.rows.items.len -| visible;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
        const first = self.rows.items.len -| visible -| self.scroll;
        for (self.rows.items[first..@min(first + visible, self.rows.items.len)], 0..) |row, i| {
            self.printRow(out_win, row, @intCast(i));
        }

        // Input line: prompt plus the text-input widget.
        const input_bar = win.child(.{ .y_off = height - 2, .height = 1 });
        _ = input_bar.printSegment(.{ .text = "> ", .style = theme.prompt }, .{ .wrap = .none });
        self.input.draw(input_bar.child(.{ .x_off = 2 }));

        // Footer: key hints.
        const footer = win.child(.{ .y_off = height - 1, .height = 1 });
        footer.fill(.{ .style = theme.footer });
        const hints = if (self.scroll > 0) "[ scrolled - PgDn for latest ]" else "PgUp/PgDn scroll  |  Ctrl+C quit";
        _ = footer.printSegment(.{ .text = hints, .style = theme.footer }, .{ .col_offset = 1, .wrap = .none });

        try self.vx.render(self.tty.writer());
        try self.tty.writer().flush();
    }

    /// Draw one transcript row, splitting it into styled segments where
    /// highlight marks overlap it. Marks live in transcript offsets, so a
    /// phrase wrapped across two rows is styled in both.
    fn printRow(self: *TuiUi, win: vaxis.Window, row: Row, row_index: u16) void {
        var segments: [max_row_segments]vaxis.Segment = undefined;
        var count: usize = 0;
        const row_end = row.off + row.text.len;

        const body = self.options.theme.body;
        var pos = row.off;
        for (self.marks.items) |mark| {
            if (mark.end <= pos) continue;
            if (mark.start >= row_end or count + 2 >= segments.len) break;
            const start = @max(mark.start, pos);
            if (start > pos) {
                segments[count] = .{ .text = self.sliceTranscript(pos, start), .style = body };
                count += 1;
            }
            const end = @min(mark.end, row_end);
            segments[count] = .{
                .text = self.sliceTranscript(start, end),
                .style = switch (mark.kind) {
                    .location => self.options.theme.location,
                    .keyword => self.options.theme.keyword,
                    .plain => body,
                },
            };
            count += 1;
            pos = end;
        }
        if (pos < row_end) {
            segments[count] = .{ .text = self.sliceTranscript(pos, row_end), .style = body };
            count += 1;
        }
        _ = win.print(segments[0..count], .{ .row_offset = row_index, .wrap = .none });
    }

    const max_row_segments = 32;

    fn sliceTranscript(self: *TuiUi, start: usize, end: usize) []const u8 {
        return self.transcript.items[start..end];
    }

    /// Re-wrap the transcript for the given width. Rows are slices into
    /// the transcript buffer, so this allocates only list storage.
    fn rebuildRows(self: *TuiUi, width: u16) !void {
        self.rows.clearRetainingCapacity();
        var lines = std.mem.splitScalar(u8, self.transcript.items, '\n');
        var line_off: usize = 0;
        while (lines.next()) |line| {
            try wrapLine(self.gpa, &self.rows, line, line_off, width);
            line_off += line.len + 1; // the '\n'
        }
    }
};

/// Word-wrap one line to `width` columns (counting codepoints), splitting
/// at spaces where possible and mid-word only when a word is too long.
/// `line_off` is the line's offset within the transcript, recorded per
/// row so highlight marks can be mapped back onto wrapped rows.
fn wrapLine(
    gpa: Allocator,
    rows: *std.ArrayList(Row),
    line: []const u8,
    line_off: usize,
    width: usize,
) !void {
    if (width == 0) return;
    var start: usize = 0;
    while (true) {
        // Walk forward up to `width` columns, remembering the last space.
        var i = start;
        var col: usize = 0;
        var last_space: ?usize = null;
        while (i < line.len and col < width) {
            if (line[i] == ' ') last_space = i;
            i += std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            col += 1;
        }
        if (i >= line.len) {
            try rows.append(gpa, .{ .text = line[start..], .off = line_off + start });
            return;
        }
        if (last_space) |space| {
            try rows.append(gpa, .{ .text = line[start..space], .off = line_off + start });
            start = space + 1;
        } else {
            try rows.append(gpa, .{ .text = line[start..i], .off = line_off + start });
            start = i;
        }
    }
}

test "wrapLine wraps at word boundaries" {
    const gpa = std.testing.allocator;
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);

    try wrapLine(gpa, &rows, "the quick brown fox jumps", 100, 10);
    try std.testing.expectEqual(@as(usize, 3), rows.items.len);
    try std.testing.expectEqualStrings("the quick", rows.items[0].text);
    try std.testing.expectEqualStrings("brown fox", rows.items[1].text);
    try std.testing.expectEqualStrings("jumps", rows.items[2].text);
    // Row offsets are transcript-absolute: line offset plus position.
    try std.testing.expectEqual(@as(usize, 100), rows.items[0].off);
    try std.testing.expectEqual(@as(usize, 110), rows.items[1].off);
    try std.testing.expectEqual(@as(usize, 120), rows.items[2].off);
}

test "wrapLine hard-breaks overlong words and keeps empty lines" {
    const gpa = std.testing.allocator;
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);

    try wrapLine(gpa, &rows, "", 0, 5);
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqualStrings("", rows.items[0].text);

    rows.clearRetainingCapacity();
    try wrapLine(gpa, &rows, "abcdefghij", 0, 4);
    try std.testing.expectEqual(@as(usize, 3), rows.items.len);
    try std.testing.expectEqualStrings("abcd", rows.items[0].text);
    try std.testing.expectEqual(@as(usize, 4), rows.items[1].off);
}
