//! mibi's text model: everything that can be said about a document without a
//! terminal or an operating system. Nothing under `src/core/` may import from
//! outside it; `zig build test-core` compiles this module on its own, so an
//! import in the wrong direction is a compile error.

pub const buffer = @import("buffer.zig");
pub const Buffer = buffer.Buffer;

test {
    _ = buffer;
}
