//! The operating system and the terminal: files, processes, the clock, raw
//! mode, and input turned into the events the widgets understand.
//!
//! This is the only place that knows whether it runs on Unix or Windows.
//! Files here may import `ui` for the event types they produce, and each
//! other; the module boundary in `build.zig` keeps the text model and the
//! application out.

pub const os = @import("os.zig");
pub const heap = @import("heap.zig");
pub const term = @import("term.zig");
pub const ansi = @import("ansi.zig");
pub const win_input = @import("win_input.zig");

test {
    _ = os;
    _ = heap;
    _ = term;
    _ = ansi;
    _ = win_input;
}
