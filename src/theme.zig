//! Colour themes for the full-screen TUI.
//!
//! A theme is just a `vaxis.Style` per styled element, so a theme can set
//! any combination of foreground/background colour and attributes (bold,
//! italic, underline, ...). This lives with the exe, not the core library:
//! like `tui_ui.zig` it depends on vaxis, and the z-machine never sees it.

const std = @import("std");
const vaxis = @import("vaxis");

pub const Theme = struct {
    /// The transcript area: its background fills the screen and its
    /// foreground colours the ordinary (unhighlighted) game text. Leave it
    /// `.{}` to keep the terminal's own colours.
    body: vaxis.Style,
    /// The top title bar (story name and live status).
    title: vaxis.Style,
    /// The footer key-hint bar.
    footer: vaxis.Style,
    /// The input prompt ("> ").
    prompt: vaxis.Style,
    /// The current location's name where the game prints it (print_obj on
    /// the object in global 0).
    location: vaxis.Style,
    /// Any other object name the game prints (print_obj).
    keyword: vaxis.Style,
};

/// The default theme: bold yellow location names, cyan italic object names,
/// over the terminal's own background.
pub const default: Theme = .{
    .body = .{},
    .title = .{ .bg = .{ .index = 4 }, .fg = .{ .index = 15 }, .bold = true },
    .footer = .{ .reverse = true, .dim = true },
    .prompt = .{ .fg = .{ .index = 6 }, .bold = true },
    .location = .{ .fg = .{ .index = 3 }, .bold = true },
    .keyword = .{ .fg = .{ .index = 6 }, .italic = true },
};

/// A colourless theme that leans on attributes alone — useful where colour
/// is unwanted or unreliable (it is the styling the TUI shipped with).
pub const mono: Theme = .{
    .body = .{},
    .title = .{ .reverse = true, .bold = true },
    .footer = .{ .reverse = true, .dim = true },
    .prompt = .{ .bold = true },
    .location = .{ .bold = true },
    .keyword = .{ .italic = true },
};

/// The Commodore 64 startup screen: light blue text on a dark blue screen
/// with a light blue border, using the colodore/Pepto palette RGB values.
/// Elements drawn over the screen carry the blue background so highlights
/// blend in rather than punching through to the terminal default.
pub const c64: Theme = blk: {
    const blue: vaxis.Color = .{ .rgb = .{ 0x40, 0x31, 0x8D } }; // background (colour 6)
    const light_blue: vaxis.Color = .{ .rgb = .{ 0x78, 0x69, 0xC4 } }; // text/border (colour 14)
    const cyan: vaxis.Color = .{ .rgb = .{ 0x67, 0xB6, 0xBD } }; // colour 3
    const yellow: vaxis.Color = .{ .rgb = .{ 0xBF, 0xCE, 0x72 } }; // colour 7
    break :blk .{
        .body = .{ .fg = light_blue, .bg = blue },
        .title = .{ .fg = blue, .bg = light_blue, .bold = true },
        .footer = .{ .fg = blue, .bg = light_blue },
        .prompt = .{ .fg = light_blue, .bg = blue, .bold = true },
        .location = .{ .fg = yellow, .bg = blue, .bold = true },
        .keyword = .{ .fg = cyan, .bg = blue, .italic = true },
    };
};

/// Comma-separated list of the built-in theme names, for help text.
pub const names = "default, mono, c64";

/// Look up a built-in theme by name, or null if there is no such theme.
pub fn byName(name: []const u8) ?Theme {
    if (std.mem.eql(u8, name, "default")) return default;
    if (std.mem.eql(u8, name, "mono")) return mono;
    if (std.mem.eql(u8, name, "c64")) return c64;
    return null;
}

test "byName resolves built-ins and rejects the unknown" {
    try std.testing.expect(byName("default").?.location.bold);
    try std.testing.expect(byName("default").?.keyword.italic);
    // The C64 theme paints a blue screen; default leaves it to the terminal.
    try std.testing.expect(vaxis.Color.eql(byName("c64").?.body.bg, .{ .rgb = .{ 0x40, 0x31, 0x8D } }));
    try std.testing.expect(vaxis.Color.eql(byName("default").?.body.bg, .default));
    try std.testing.expectEqual(@as(?Theme, null), byName("nope"));
}
