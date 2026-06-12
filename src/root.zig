//! zgigye: a z-machine interpreter library (version 3 stories).

const std = @import("std");

pub const Machine = @import("machine.zig").Machine;
pub const Ui = @import("ui.zig").Ui;
pub const StatusLine = @import("ui.zig").StatusLine;
pub const TextUi = @import("text_ui.zig").TextUi;
pub const Header = @import("header.zig").Header;
pub const Memory = @import("memory.zig").Memory;
pub const Instruction = @import("instruction.zig").Instruction;
pub const zscii = @import("zscii.zig");
pub const session = @import("session.zig");

test {
    _ = @import("memory.zig");
    _ = @import("header.zig");
    _ = @import("zscii.zig");
    _ = @import("instruction.zig");
    _ = @import("objects.zig");
    _ = @import("dictionary.zig");
    _ = @import("machine.zig");
    _ = @import("opcodes.zig");
    _ = @import("state.zig");
    _ = @import("session.zig");
    _ = @import("ui.zig");
    _ = @import("text_ui.zig");
    _ = @import("integration_test.zig");
}
