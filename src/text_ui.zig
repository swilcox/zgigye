//! A plain-text frontend over any `std.Io` reader/writer pair.
//!
//! Used with stdin/stdout for interactive play, or with fixed/allocating
//! streams for scripted runs and tests. The status line is not drawn;
//! richer frontends can render it via `showStatus`.

const std = @import("std");
const Ui = @import("ui.zig").Ui;
const StatusLine = @import("ui.zig").StatusLine;

pub const TextUi = struct {
    out: *std.Io.Writer,
    in: *std.Io.Reader,

    pub fn ui(self: *TextUi) Ui {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Ui.VTable{
        .print = print,
        .readLine = readLine,
        .showStatus = showStatus,
    };

    fn print(ptr: *anyopaque, text: []const u8) anyerror!void {
        const self: *TextUi = @ptrCast(@alignCast(ptr));
        try self.out.writeAll(text);
    }

    fn readLine(ptr: *anyopaque, buf: []u8) anyerror![]const u8 {
        const self: *TextUi = @ptrCast(@alignCast(ptr));
        try self.out.flush();
        const line = try self.in.takeDelimiter('\n') orelse return error.EndOfStream;
        const len = @min(line.len, buf.len);
        @memcpy(buf[0..len], line[0..len]);
        return buf[0..len];
    }

    fn showStatus(ptr: *anyopaque, status: StatusLine) anyerror!void {
        _ = ptr;
        _ = status;
    }
};

test "TextUi reads lines and echoes output" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var in = std.Io.Reader.fixed("go north\nquit\n");

    var text_ui = TextUi{ .out = &out.writer, .in = &in };
    const u = text_ui.ui();

    try u.print("Hello.\n");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("go north", try u.readLine(&buf));
    try std.testing.expectEqualStrings("quit", try u.readLine(&buf));
    try std.testing.expectEqualStrings("Hello.\n", out.written());
}
