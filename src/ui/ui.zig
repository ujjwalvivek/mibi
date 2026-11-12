//! The widgets: everything mibi draws and every key or click it understands,
//! with no terminal and no operating system underneath. A widget is handed
//! events and a `Screen` of cells, so each one is tested by pressing keys
//! and reading cells back.
//!
//! Files here may import the text model (`core`) and each other, nothing
//! else. This is a module of its own in `build.zig`, so an import that
//! reaches for the platform or the application does not compile.

pub const event = @import("event.zig");
pub const screen = @import("screen.zig");
pub const theme = @import("theme.zig");
pub const layout = @import("layout.zig");
pub const line_edit = @import("line_edit.zig");
pub const picker = @import("picker.zig");
pub const tabbar = @import("tabbar.zig");
pub const editor_pane = @import("editor_pane.zig");

test {
    _ = event;
    _ = screen;
    _ = theme;
    _ = layout;
    _ = line_edit;
    _ = picker;
    _ = tabbar;
    _ = editor_pane;
}
