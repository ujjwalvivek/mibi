//! The web platform: the same interface as `platform.zig`, implemented over a
//! virtual filesystem and host calls instead of an operating system. The
//! module is selected for the wasm build in `build.zig`; the app, widgets and
//! text model do not know the difference.

pub const os = @import("web/os.zig");
pub const heap = @import("web/heap.zig");
pub const ansi = @import("ansi.zig");
