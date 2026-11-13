//! The web platform: the same interface as `platform.zig`, implemented over an
//! in-memory filesystem and host calls instead of an operating system. The
//! module is selected for the wasm build in `build.zig`; the app, widgets and
//! text model do not know the difference.
//!
//! `web/vfs.zig` is plain Zig with no host calls, so its tests run natively
//! (`zig build test-web`). `web/os.zig` needs the host; the wasm build checks
//! it compiles and `web/test` drives it through the real module.

pub const os = @import("web/os.zig");
pub const heap = @import("web/heap.zig");
pub const ansi = @import("ansi.zig");
