//! What survives a restart: the open tabs, the pane layout, where each
//! cursor was, and the text of anything that was not saved. A crash, a
//! closed terminal window or a power cut costs at most the last couple of
//! seconds of typing.
//!
//! The state directory holds one `session` file and one `buffer-<id>.txt`
//! per document with unsaved text. The session file is lines of text:
//!
//!   mibi-session 2
//!   tree <root>                      (when the file tree is open)
//!   expand <path>                    (one per expanded directory)
//!   doc <id> <unsaved> <anchor> <head> <row> <col> <path>
//!   split <columns|rows> <ratio>     (the layout, preorder)
//!   pane <doc id> <anchor> <head> <row> <col> <focused>
//!
//! A path is the rest of its line, so it may contain spaces. Anything that
//! does not parse is skipped: a damaged session restores what it can.

const std = @import("std");
const Allocator = std.mem.Allocator;
const os = @import("platform").os;
const layout = @import("ui").layout;
const core = @import("core");
const app_mod = @import("../app.zig");
const doc_mod = @import("doc.zig");
const App = app_mod.App;
const Doc = app_mod.Doc;

const header = "mibi-session 2";

fn sessionPath(buf: []u8, dir: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/session", .{dir}) catch null;
}

fn bufferPath(buf: []u8, dir: []const u8, id: u32) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/buffer-{d}.txt", .{ dir, id }) catch null;
}

fn print(out: *std.ArrayList(u8), allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [2048]u8 = undefined;
    // A line that does not fit (a path longer than any real one) is left
    // out; the rest of the session is still worth writing.
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    try out.appendSlice(allocator, line);
}

/// A document's text has to be kept by the session when no file has it.
fn needsBuffer(d: *const Doc) bool {
    return d.isDirty() or (d.path == null and d.document.len() > 0);
}

/// Write the session. Best effort: a failure here must never get in the
/// way of editing, and the next save tries again.
pub fn save(app: *App) void {
    const dir = app.state_dir orelse return;
    write(app, dir) catch {};
    app.session_dirty = false;
}

/// Delete the buffer file of a document that is being closed.
pub fn dropBuffer(app: *App, d: *const Doc) void {
    const dir = app.state_dir orelse return;
    if (d.session_revision == null) return;
    var path_buf: [1100]u8 = undefined;
    if (bufferPath(&path_buf, dir, d.id)) |path| os.deleteFile(path) catch {};
}

fn write(app: *App, dir: []const u8) !void {
    const allocator = app.allocator;
    // A tab remembers where its last pane was looking; take that from the
    // panes that are open now, the focused one last so it wins.
    for (app.layout.leaves[0..app.layout.leaf_count]) |id| {
        const p = app.panes[id].?;
        p.doc.last = App.stateOf(p.view);
    }
    if (app.layout.focused()) |id| {
        const p = app.panes[id].?;
        p.doc.last = App.stateOf(p.view);
    }
    var path_buf: [1100]u8 = undefined;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, header ++ "\n");

    if (app.tree) |*t| {
        try print(&out, allocator, "tree {s}\n", .{t.rootPath()});
        for (t.expanded.items) |p| try print(&out, allocator, "expand {s}\n", .{p});
    }

    for (app.docs.items) |d| {
        // A path with a line break in it cannot be written in this format.
        if (d.path) |p| {
            if (std.mem.indexOfAny(u8, p, "\r\n") != null) continue;
        }
        const unsaved = needsBuffer(d);
        if (unsaved and d.session_revision != d.document.revision) {
            const text = try d.bytesForDisk(allocator);
            defer allocator.free(text);
            const path = bufferPath(&path_buf, dir, d.id) orelse continue;
            try os.writeFile(path, text);
            d.session_revision = d.document.revision;
        } else if (!unsaved and d.session_revision != null) {
            if (bufferPath(&path_buf, dir, d.id)) |path| os.deleteFile(path) catch {};
            d.session_revision = null;
        }
        try print(&out, allocator, "doc {d} {d} {d} {d} {d} {d} {s}\n", .{
            d.id,              @intFromBool(unsaved), d.last.anchor,    d.last.head,
            d.last.scroll_row, d.last.scroll_col,     d.path orelse "",
        });
    }

    var shape_buf: [layout.max_nodes]layout.Tree.Shape = undefined;
    var leaf: usize = 0;
    for (app.layout.encode(&shape_buf)) |item| switch (item) {
        .split => |sp| try print(&out, allocator, "split {s} {d}\n", .{ @tagName(sp.dir), sp.ratio }),
        .leaf => {
            const id = app.layout.leaves[leaf];
            leaf += 1;
            const p = app.panes[id].?;
            const sel = p.view.primarySelection();
            try print(&out, allocator, "pane {d} {d} {d} {d} {d} {d}\n", .{
                p.doc.id,          sel.anchor,        sel.head,
                p.view.scroll_row, p.view.scroll_col, @intFromBool(app.layout.focused() == id),
            });
        },
    };

    const path = sessionPath(&path_buf, dir) orelse return;
    try os.writeFile(path, out.items);
}

const Fields = struct {
    it: std.mem.TokenIterator(u8, .scalar),

    fn init(line: []const u8) Fields {
        return .{ .it = std.mem.tokenizeScalar(u8, line, ' ') };
    }

    fn int(self: *Fields, comptime T: type) ?T {
        return std.fmt.parseInt(T, self.it.next() orelse return null, 10) catch null;
    }

    /// Everything after the fields read so far.
    fn rest(self: *Fields) []const u8 {
        return self.it.rest();
    }
};

const PaneLine = struct {
    doc_id: u32,
    state: doc_mod.ViewState,
    focused: bool,
};

/// Restore the last session. Returns true when at least one document came
/// back; false leaves the app as it was.
pub fn load(app: *App) bool {
    const dir = app.state_dir orelse return false;
    var path_buf: [1100]u8 = undefined;
    const path = sessionPath(&path_buf, dir) orelse return false;
    const data = os.readFileAlloc(app.allocator, path, 1024 * 1024) catch return false;
    defer app.allocator.free(data);
    restore(app, dir, data) catch {};
    return app.docs.items.len > 0;
}

fn restore(app: *App, dir: []const u8, data: []const u8) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.first(), "\r"), header)) return;

    var shape: [layout.max_nodes]layout.Tree.Shape = undefined;
    var shape_len: usize = 0;
    var pane_lines: [layout.max_panes]PaneLine = undefined;
    var pane_count: usize = 0;
    var tree_root: ?[]const u8 = null;
    var shape_ok = true;

    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const word = line[0..space];
        var f = Fields.init(line[space + 1 ..]);
        if (std.mem.eql(u8, word, "doc")) {
            const id = f.int(u32) orelse continue;
            const unsaved = (f.int(u8) orelse continue) != 0;
            const state = doc_mod.ViewState{
                .anchor = f.int(usize) orelse continue,
                .head = f.int(usize) orelse continue,
                .scroll_row = f.int(usize) orelse continue,
                .scroll_col = f.int(usize) orelse continue,
            };
            const doc_path = f.rest();
            restoreDoc(app, dir, id, unsaved, state, if (doc_path.len > 0) doc_path else null) catch continue;
        } else if (std.mem.eql(u8, word, "split")) {
            const dir_name = f.it.next() orelse continue;
            const split_dir = std.meta.stringToEnum(layout.Dir, dir_name) orelse continue;
            const ratio = f.int(u8) orelse 50;
            if (shape_len < shape.len) {
                shape[shape_len] = .{ .split = .{ .dir = split_dir, .ratio = ratio } };
                shape_len += 1;
            } else shape_ok = false;
        } else if (std.mem.eql(u8, word, "pane")) {
            const pane = PaneLine{
                .doc_id = f.int(u32) orelse continue,
                .state = .{
                    .anchor = f.int(usize) orelse continue,
                    .head = f.int(usize) orelse continue,
                    .scroll_row = f.int(usize) orelse continue,
                    .scroll_col = f.int(usize) orelse continue,
                },
                .focused = (f.int(u8) orelse 0) != 0,
            };
            if (shape_len < shape.len and pane_count < pane_lines.len) {
                shape[shape_len] = .leaf;
                shape_len += 1;
                pane_lines[pane_count] = pane;
                pane_count += 1;
            } else shape_ok = false;
        } else if (std.mem.eql(u8, word, "tree")) {
            tree_root = line[space + 1 ..];
            if (app.tree == null) app.tree = app_mod.FileTree.init(app.allocator, tree_root.?) catch null;
        } else if (std.mem.eql(u8, word, "expand")) {
            if (app.tree) |*t| t.expand(line[space + 1 ..]) catch {};
        }
    }
    if (app.tree) |*t| t.reload() catch {};
    if (app.docs.items.len == 0) return;

    // The layout, if every pane's document came back; otherwise the one
    // pane `addDoc` already made, showing the last document restored.
    if (!shape_ok or pane_count == 0) return;
    for (pane_lines[0..pane_count]) |p| {
        if (findDoc(app, p.doc_id) == null) return;
    }
    var tree = layout.Tree.decode(shape[0..shape_len]) orelse return;
    try applyLayout(app, &tree, pane_lines[0..pane_count]);
}

fn findDoc(app: *App, id: u32) ?*Doc {
    for (app.docs.items) |d| {
        if (d.id == id) return d;
    }
    return null;
}

fn restoreDoc(app: *App, dir: []const u8, id: u32, unsaved: bool, state: doc_mod.ViewState, path: ?[]const u8) !void {
    if (findDoc(app, id) != null) return error.Duplicate;
    var path_buf: [1100]u8 = undefined;
    const source = if (unsaved) bufferPath(&path_buf, dir, id) orelse return error.NoBuffer else path orelse return error.NoPath;
    // A file that has been deleted since is not brought back as an empty
    // tab; text that only the session had is gone if its buffer is.
    const data = try os.readFileAlloc(app.allocator, source, doc_mod.max_file);
    defer app.allocator.free(data);

    const d = try app.addDoc(path, data);
    // Keep the old id so buffer files keep their names across runs.
    d.id = id;
    app.next_doc_id = @max(app.next_doc_id, id + 1);
    d.last = state;
    // `addDoc` showed it in the focused pane; put that view where the tab
    // was, so switching away and back keeps the place.
    const v = app.view();
    v.setSelection(.{ .anchor = @min(state.anchor, d.document.len()), .head = @min(state.head, d.document.len()) });
    v.scroll_row = state.scroll_row;
    v.scroll_col = state.scroll_col;
    app.pane().reveal = false;
    if (unsaved) {
        d.document.markUnsaved();
        d.session_revision = d.document.revision;
    }
}

fn applyLayout(app: *App, tree: *layout.Tree, pane_lines: []const PaneLine) !void {
    // Build every view first, so a failure leaves the single pane in place.
    var views: [layout.max_panes]?*core.View = [_]?*core.View{null} ** layout.max_panes;
    errdefer for (views) |v| {
        if (v) |view| view.destroy();
    };
    for (pane_lines, 0..) |p, i| {
        const d = findDoc(app, p.doc_id).?;
        const v = try core.View.create(app.allocator, &d.document);
        v.tab_width = app.config.tab_width;
        v.indent_unit = app.indent();
        const max = d.document.len();
        v.setSelection(.{ .anchor = @min(p.state.anchor, max), .head = @min(p.state.head, max) });
        v.scroll_row = p.state.scroll_row;
        v.scroll_col = p.state.scroll_col;
        views[i] = v;
    }
    for (&app.panes) |*slot| {
        if (slot.*) |old| old.view.destroy();
        slot.* = null;
    }
    app.layout = tree.*;
    for (pane_lines, 0..) |p, i| {
        const id = app.layout.leaves[i];
        // The scroll position was saved; do not jump to the cursor.
        app.panes[id] = .{ .doc = findDoc(app, p.doc_id).?, .view = views[i].?, .reveal = false };
        if (p.focused) app.layout.setFocus(id);
    }
}
