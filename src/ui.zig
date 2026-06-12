//! The interface between the z-machine core and the outside world.
//!
//! The machine talks only to `Ui`; concrete frontends (plain text today,
//! rich text or web later) implement the vtable. Status information is
//! passed structured, not preformatted, so each frontend can render it
//! however it likes.

const std = @import("std");

pub const StatusLine = struct {
    /// Short name of the object the game considers the current location.
    location: []const u8,
    progress: Progress,

    pub const Progress = union(enum) {
        score: struct { score: i16, turns: u16 },
        time: struct { hours: u16, minutes: u16 },
    };
};

pub const Ui = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Write game output. Text is UTF-8; newlines are '\n'.
        print: *const fn (ptr: *anyopaque, text: []const u8) anyerror!void,
        /// Read one line of player input into `buf`; returns the line
        /// without its newline. Implementations should flush any pending
        /// output first.
        readLine: *const fn (ptr: *anyopaque, buf: []u8) anyerror![]const u8,
        /// Update the status line (shown for v3 games before input).
        showStatus: *const fn (ptr: *anyopaque, status: StatusLine) anyerror!void,
    };

    pub fn print(self: Ui, text: []const u8) anyerror!void {
        return self.vtable.print(self.ptr, text);
    }

    pub fn readLine(self: Ui, buf: []u8) anyerror![]const u8 {
        return self.vtable.readLine(self.ptr, buf);
    }

    pub fn showStatus(self: Ui, status: StatusLine) anyerror!void {
        return self.vtable.showStatus(self.ptr, status);
    }
};
