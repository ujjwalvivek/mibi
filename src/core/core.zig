//! mibi's text model: everything that can be said about a document without a
//! terminal or an operating system. Nothing under `src/core/` may import from
//! outside it; `zig build test-core` compiles this module on its own, so an
//! import in the wrong direction is a compile error.

pub const buffer = @import("buffer.zig");
pub const utf8 = @import("utf8.zig");
pub const width = @import("width.zig");
pub const text = @import("text.zig");
pub const selection = @import("selection.zig");
pub const history = @import("history.zig");
pub const document = @import("document.zig");
pub const view = @import("view.zig");
pub const regex = @import("regex.zig");
pub const search = @import("search.zig");
pub const ini = @import("ini.zig");
pub const syntax = @import("syntax.zig");
pub const highlight = @import("highlight.zig");

pub const Buffer = buffer.Buffer;
pub const Selection = selection.Selection;
pub const Document = document.Document;
pub const Edit = document.Edit;
pub const View = view.View;

test {
    _ = buffer;
    _ = text;
    _ = selection;
    _ = history;
    _ = document;
    _ = view;
    _ = regex;
    _ = search;
    _ = ini;
    _ = syntax;
    _ = highlight;
}
