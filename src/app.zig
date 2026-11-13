//! The editor itself: open documents, panes, panels, and what every command
//! does. Events come in through `handle`, a frame goes out through `draw`,
//! and nothing in between knows about a terminal. That is what lets the
//! tests drive a whole editor in memory: events in, a grid of cells out.
//!
//! The parts live next to this file under `app/`:
//!   doc.zig      a document and its file
//!   prompt.zig   the one-line prompt (find, replace, go to, save as)
//!   pickers.zig  file picker, theme picker, command palette
//!   mouse.zig    the mouse
//!   draw.zig     the frame
//!   session.zig  what is remembered between runs
//!   files.zig    formatter, reloading changed files, the clipboard

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const os = @import("platform").os;
const commands = @import("commands.zig");
const config_mod = @import("config.zig");
const event = @import("ui").event;
const layout = @import("ui").layout;
const screen = @import("ui").screen;
const TabBar = @import("ui").tabbar.TabBar;

pub const doc_mod = @import("app/doc.zig");
pub const prompt = @import("app/prompt.zig");
pub const pickers = @import("app/pickers.zig");
pub const mouse = @import("app/mouse.zig");
pub const drawing = @import("app/draw.zig");
pub const session = @import("app/session.zig");
pub const files = @import("app/files.zig");
pub const FileTree = @import("app/tree.zig").Tree;

pub const Doc = doc_mod.Doc;
pub const Command = commands.Command;
pub const Config = config_mod.Config;
const View = core.View;
const Selection = core.Selection;

pub const version = "0.1.0";

/// One pane: a view of a document. Two panes may show the same document;
/// each has its own cursors and scroll.
pub const Pane = struct {
    doc: *Doc,
    view: *View,
    /// Scroll to the cursor at the next draw. Set by anything that moves the
    /// cursor, not by scrolling, so the wheel can look elsewhere.
    reveal: bool = true,
};

pub const Options = struct {
    config: Config = .{},
    /// Where the executable lives: themes and syntax files are looked up
    /// there after the working directory.
    exe_dir: ?[]const u8 = null,
    /// Where the session and scratch files go. Null turns persistence off.
    state_dir: ?[]const u8 = null,
};

pub const App = struct {
    allocator: Allocator,
    config: Config,
    exe_dir: ?[]const u8,
    state_dir: ?[]const u8,
    registry: core.syntax.Registry,

    /// Open documents, in tab order.
    docs: std.ArrayList(*Doc) = .empty,
    next_doc_id: u32 = 1,
    layout: layout.Tree = .empty,
    /// Indexed by the layout's pane id.
    panes: [layout.max_nodes]?Pane = [_]?Pane{null} ** layout.max_nodes,
    /// Where the panes were last drawn.
    pane_area: screen.Rect = .{},

    tabbar: TabBar,
    tree: ?FileTree = null,
    tree_focus: bool = false,
    prompt: ?prompt.Prompt = null,
    picker: ?pickers.State = null,
    help: bool = false,
    mouse: mouse.State = .{},

    search: ?core.search.Search = null,
    search_regex: bool = false,
    clipboard: std.ArrayList(u8) = .empty,
    /// Bytes for the terminal that are not part of a frame: the window
    /// title, the clipboard. The run loop writes and clears it.
    term_out: std.ArrayList(u8) = .empty,
    title: std.ArrayList(u8) = .empty,

    message_buf: [200]u8 = undefined,
    message_len: usize = 0,
    /// Spaces; `indent()` is the slice one Tab inserts.
    indent_buf: [16]u8 = [_]u8{' '} ** 16,

    /// Time of the event being handled. The run loop sets it; the app has
    /// no clock of its own.
    now_ms: u64 = 0,
    /// Size of the screen at the last draw.
    cols: usize = 80,
    rows: usize = 24,
    quit: bool = false,
    /// Something changed that the session file should record.
    session_dirty: bool = false,

    pub fn init(allocator: Allocator, options: Options) App {
        return .{
            .allocator = allocator,
            .config = options.config,
            .exe_dir = options.exe_dir,
            .state_dir = options.state_dir,
            .registry = core.syntax.Registry.init(allocator),
            .tabbar = TabBar.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        if (self.picker) |*p| p.deinit();
        if (self.prompt) |*p| p.deinit();
        if (self.tree) |*t| t.deinit();
        if (self.search) |*s| s.deinit();
        for (&self.panes) |*slot| {
            if (slot.*) |p| p.view.destroy();
            slot.* = null;
        }
        for (self.docs.items) |d| d.destroy();
        self.docs.deinit(self.allocator);
        self.tabbar.deinit();
        self.clipboard.deinit(self.allocator);
        self.term_out.deinit(self.allocator);
        self.title.deinit(self.allocator);
        self.registry.deinit();
    }

    // --- status message --------------------------------------------------

    pub fn setMessage(self: *App, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.message_buf, fmt, args) catch blk: {
            // Too long: keep what fits.
            break :blk self.message_buf[0..];
        };
        self.message_len = text.len;
    }

    pub fn message(self: *const App) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    fn reportError(self: *App, what: []const u8, err: anyerror) void {
        self.setMessage("{s}: {s}", .{ what, describe(err) });
    }

    // --- documents and panes ---------------------------------------------

    pub fn indent(self: *const App) []const u8 {
        return self.indent_buf[0..std.math.clamp(self.config.tab_width, 1, self.indent_buf.len)];
    }

    /// The focused pane. There is always one while the app is running.
    pub fn pane(self: *App) *Pane {
        return &self.panes[self.layout.focused().?].?;
    }

    pub fn view(self: *App) *View {
        return self.pane().view;
    }

    pub fn doc(self: *App) *Doc {
        return self.pane().doc;
    }

    pub fn docIndex(self: *const App, d: *const Doc) ?usize {
        return std.mem.indexOfScalar(*Doc, self.docs.items, @constCast(d));
    }

    pub fn activeIndex(self: *App) usize {
        return self.docIndex(self.doc()).?;
    }

    pub fn findByPath(self: *const App, path: []const u8) ?usize {
        for (self.docs.items, 0..) |d, i| {
            if (d.path) |p| {
                if (doc_mod.pathsEqual(p, path)) return i;
            }
        }
        return null;
    }

    fn paneShowing(self: *const App, d: *const Doc) ?u8 {
        for (self.layout.leaves[0..self.layout.leaf_count]) |id| {
            if (self.panes[id].?.doc == d) return id;
        }
        return null;
    }

    fn newView(self: *App, d: *Doc, state: doc_mod.ViewState) !*View {
        const v = try View.create(self.allocator, &d.document);
        v.tab_width = self.config.tab_width;
        v.indent_unit = self.indent();
        v.setSelection(.{ .anchor = @min(state.anchor, d.document.len()), .head = @min(state.head, d.document.len()) });
        v.scroll_row = state.scroll_row;
        v.scroll_col = state.scroll_col;
        return v;
    }

    pub fn stateOf(v: *const View) doc_mod.ViewState {
        const sel = v.primarySelection();
        return .{ .anchor = sel.anchor, .head = sel.head, .scroll_row = v.scroll_row, .scroll_col = v.scroll_col };
    }

    /// Show `d` in pane `id`, which may be empty or showing something else.
    fn showDoc(self: *App, id: u8, d: *Doc) !void {
        if (self.panes[id]) |p| {
            if (p.doc == d) return;
        }
        const v = try self.newView(d, d.last);
        if (self.panes[id]) |p| {
            p.doc.last = stateOf(p.view);
            p.view.destroy();
        }
        self.panes[id] = .{ .doc = d, .view = v };
        self.session_dirty = true;
    }

    fn setLanguage(self: *App, d: *Doc) void {
        d.highlighter.setLang(if (self.config.syntax) self.registry.find(d.path) else null);
    }

    /// Add a document as a new tab and show it in the focused pane.
    pub fn addDoc(self: *App, path: ?[]const u8, data: []const u8) !*Doc {
        try self.docs.ensureUnusedCapacity(self.allocator, 1);
        const d = try Doc.create(self.allocator, self.next_doc_id, path, data);
        errdefer d.destroy();
        self.setLanguage(d);
        const id = self.layout.focused() orelse self.layout.open().?;
        errdefer if (self.panes[id] == null) self.layout.remove(id);
        try self.showDoc(id, d);
        self.next_doc_id += 1;
        self.docs.appendAssumeCapacity(d);
        return d;
    }

    /// Open a file in a tab, or switch to its tab when it is already open.
    /// A path that does not exist yet opens empty: saving creates it.
    pub fn openPath(self: *App, path: []const u8) !void {
        if (self.findByPath(path)) |i| return self.focusDoc(i);
        const data: ?[]u8 = os.readFileAlloc(self.allocator, path, doc_mod.max_file) catch |err| switch (err) {
            error.FileNotFound => null,
            // Anything else must not open an empty buffer under that path:
            // saving it would destroy the real file.
            else => return err,
        };
        defer if (data) |bytes| self.allocator.free(bytes);
        // A fresh start (one empty, unnamed, untouched tab) is replaced
        // rather than left behind as a stray tab.
        const lone = self.docs.items.len == 1 and self.isScratch(self.docs.items[0]);
        _ = try self.addDoc(path, data orelse "");
        if (lone) self.removeDoc(0);
    }

    fn isScratch(self: *const App, d: *const Doc) bool {
        _ = self;
        return d.path == null and !d.isDirty() and d.document.len() == 0 and
            d.document.history.undo_stack.items.len == 0;
    }

    /// Bring tab `index` to the front: focus the pane already showing it,
    /// or show it in the focused pane.
    pub fn focusDoc(self: *App, index: usize) !void {
        if (index >= self.docs.items.len) return;
        const d = self.docs.items[index];
        if (self.paneShowing(d)) |id| {
            self.focusPane(id);
        } else {
            try self.showDoc(self.layout.focused().?, d);
        }
        self.pane().reveal = true;
    }

    pub fn focusPane(self: *App, id: u8) void {
        self.layout.setFocus(id);
        self.tree_focus = false;
        self.session_dirty = true;
    }

    fn cycleTab(self: *App, delta: isize) !void {
        const n: isize = @intCast(self.docs.items.len);
        if (n <= 1) return;
        const i: isize = @intCast(self.activeIndex());
        try self.focusDoc(@intCast(@mod(i + delta, n)));
    }

    pub fn moveTab(self: *App, from: usize, to: usize) void {
        const n = self.docs.items.len;
        if (from >= n or to >= n or from == to) return;
        const d = self.docs.orderedRemove(from);
        self.docs.insertAssumeCapacity(to, d);
        self.session_dirty = true;
    }

    /// Close tab `index` without asking. Every pane showing it closes too,
    /// except the last pane, which moves to a neighbouring tab. Closing the
    /// last tab quits.
    pub fn removeDoc(self: *App, index: usize) void {
        const d = self.docs.items[index];
        if (self.docs.items.len == 1) {
            self.quit = true;
            return;
        }
        _ = self.docs.orderedRemove(index);
        const neighbour = self.docs.items[@min(index, self.docs.items.len - 1)];
        var i: usize = 0;
        while (i < self.layout.leaf_count) {
            const id = self.layout.leaves[i];
            const p = self.panes[id].?;
            if (p.doc != d) {
                i += 1;
                continue;
            }
            if (self.layout.count() > 1) {
                p.view.destroy();
                self.panes[id] = null;
                self.layout.remove(id); // `leaves` shifts down: same index again
                continue;
            }
            // The last pane: show a document that still exists. If even that
            // fails for lack of memory the tab stays open.
            const v = self.newView(neighbour, neighbour.last) catch {
                self.docs.insertAssumeCapacity(index, d);
                return;
            };
            p.view.destroy();
            self.panes[id] = .{ .doc = neighbour, .view = v };
            i += 1;
        }
        session.dropBuffer(self, d);
        d.destroy();
        self.session_dirty = true;
    }

    /// Close a tab, asking first when it has unsaved changes.
    pub fn requestCloseTab(self: *App, index: usize) !void {
        if (index >= self.docs.items.len) return;
        if (self.docs.items[index].isDirty()) {
            try self.focusDoc(index);
            return prompt.open(self, .confirm_close);
        }
        self.removeDoc(index);
    }

    /// Quit. With a session, nothing is lost by leaving: unsaved text comes
    /// back with the tabs on the next start, so there is nothing to ask.
    /// Without one, unsaved changes get a question first.
    fn requestQuit(self: *App) !void {
        if (self.state_dir == null) for (self.docs.items) |d| {
            if (d.isDirty()) return prompt.open(self, .confirm_quit);
        };
        self.quit = true;
    }

    pub fn splitPane(self: *App, target: u8, dir: layout.Dir, first: bool, d: *Doc) !void {
        const source = self.panes[target].?;
        // The new view starts where the old one is looking when it shows the
        // same document.
        const state = if (source.doc == d) stateOf(source.view) else d.last;
        const v = try self.newView(d, state);
        const id = self.layout.split(target, dir, first) orelse {
            v.destroy();
            self.setMessage("no room for another pane", .{});
            return;
        };
        self.panes[id] = .{ .doc = d, .view = v };
        self.tree_focus = false;
        self.session_dirty = true;
    }

    fn closePane(self: *App) void {
        if (self.layout.count() <= 1) return; // the last pane always stays
        const id = self.layout.focused().?;
        const p = self.panes[id].?;
        p.doc.last = stateOf(p.view);
        p.view.destroy();
        self.panes[id] = null;
        self.layout.remove(id);
        self.session_dirty = true;
    }

    fn toggleTree(self: *App) !void {
        if (self.tree) |*t| {
            if (self.tree_focus) {
                t.deinit();
                self.tree = null;
                self.tree_focus = false;
            } else {
                self.tree_focus = true;
            }
            return;
        }
        self.tree = try FileTree.init(self.allocator, ".");
        self.tree_focus = true;
    }

    // --- events ------------------------------------------------------------

    /// Handle one event. Errors (out of memory, a failed save) become a
    /// status message: an editor that exits on an error loses work.
    pub fn handle(self: *App, ev: event.Event) void {
        self.dispatch(ev) catch |err| self.setMessage("{s}", .{describe(err)});
    }

    fn dispatch(self: *App, ev: event.Event) !void {
        switch (ev) {
            .key => |key| {
                self.message_len = 0;
                try self.handleKey(key);
            },
            .mouse => |m| try mouse.handle(self, m),
            .paste => |text| try self.handlePaste(text),
            .focus, .resize => {},
        }
    }

    fn handleKey(self: *App, key: event.Key) !void {
        if (self.picker != null) return pickers.handleKey(self, key);
        if (self.prompt != null) return prompt.handleKey(self, key);
        if (self.tree_focus and self.tree != null) {
            if (try self.handleTreeKey(key)) return;
        }
        if (self.config.keys.resolve(key)) |r| return self.run(r.command, r.extend);
        if (key.isText()) {
            var enc: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(key.cp, &enc) catch return;
            const v = self.view();
            v.now_ms = self.now_ms;
            try v.insert(enc[0..len]);
            self.pane().reveal = true;
            self.session_dirty = true;
        }
    }

    fn handlePaste(self: *App, raw: []const u8) !void {
        if (self.picker) |*p| {
            try p.picker.filter.insert(raw);
            return p.picker.refilter();
        }
        if (self.prompt) |*p| {
            try p.input.insert(raw);
            return prompt.changed(self);
        }
        const copy = try self.allocator.dupe(u8, raw);
        defer self.allocator.free(copy);
        const text = normalizePasted(copy);
        const v = self.view();
        v.now_ms = self.now_ms;
        try v.paste(text);
        self.pane().reveal = true;
        self.session_dirty = true;
    }

    /// Keys while the file tree has the focus. False hands the key on to
    /// the normal bindings (Ctrl+S, Ctrl+Q and the rest still work).
    fn handleTreeKey(self: *App, key: event.Key) !bool {
        const t = &self.tree.?;
        if (key.mods.none()) {
            switch (key.special) {
                .up => t.move(-1),
                .down => t.move(1),
                .right => if (t.selectedEntry()) |e| {
                    if (e.is_dir and !e.is_parent and !t.isExpanded(e.path)) try t.toggleDir(e.path);
                },
                .left => if (t.selectedEntry()) |e| {
                    if (e.is_dir and !e.is_parent and t.isExpanded(e.path)) try t.toggleDir(e.path);
                },
                .enter => try self.openTreeSelection(),
                .tab, .esc => self.tree_focus = false,
                .none => switch (key.cp) {
                    'k' => t.move(-1),
                    'j' => t.move(1),
                    else => return key.isText(), // typing does not leak into the document
                },
                else => return false,
            }
            return true;
        }
        return false;
    }

    /// Enter (or a second click) on a tree row: go up, expand, or open.
    pub fn openTreeSelection(self: *App) !void {
        const t = &self.tree.?;
        const entry = t.selectedEntry() orelse return;
        if (entry.is_parent) return t.goUp();
        if (entry.is_dir) return t.toggleDir(entry.path);
        var path_buf: [1024]u8 = undefined;
        const path = t.selectedPath(&path_buf) orelse return;
        self.openPath(path) catch |err| return self.reportError("Cannot open", err);
        self.tree_focus = false;
    }

    // --- commands ----------------------------------------------------------

    /// Rows a page motion moves: the focused pane's height.
    fn pageRows(self: *App) usize {
        const r = self.layout.rectOf(self.layout.focused().?) orelse return 1;
        return @max(r.h, 1);
    }

    pub fn run(self: *App, command: Command, extend: bool) !void {
        const p = self.pane();
        const v = p.view;
        v.now_ms = self.now_ms;
        p.reveal = true;
        self.session_dirty = true;
        switch (command) {
            .save => try self.save(),
            .save_as => try prompt.open(self, .save_as),
            .open => try pickers.open(self, .files),
            .new_tab => _ = try self.addDoc(null, ""),
            .close_tab => try self.requestCloseTab(self.activeIndex()),
            .next_tab => try self.cycleTab(1),
            .prev_tab => try self.cycleTab(-1),
            .quit => try self.requestQuit(),

            .undo => if (!try v.undo()) self.setMessage("nothing to undo", .{}),
            .redo => if (!try v.redo()) self.setMessage("nothing to redo", .{}),
            .copy => {
                const text = try v.copyText(self.allocator);
                defer self.allocator.free(text);
                try files.setClipboard(self, text);
            },
            .cut => {
                const text = try v.cutText(self.allocator);
                defer self.allocator.free(text);
                try files.setClipboard(self, text);
            },
            .paste => try v.paste(self.clipboard.items),
            .duplicate_line => try v.duplicateLines(),
            .delete_line => try v.deleteLines(),
            .move_line_up => try v.moveLines(-1),
            .move_line_down => try v.moveLines(1),
            .toggle_comment => {
                const lang = p.doc.highlighter.lang orelse self.registry.find(p.doc.path);
                const token = if (lang) |l| (if (l.sl_comment_starts.len > 0) l.sl_comment_starts[0] else "") else "";
                if (token.len == 0) return self.setMessage("no line comment for this file type", .{});
                try v.toggleComment(token);
            },
            .indent => try v.indent(),
            .dedent => try v.dedent(),
            .insert_newline => try v.newline(),
            .insert_tab => try v.tab(),
            .backspace => try v.backspace(),
            .delete_forward => try v.deleteForward(),
            .delete_word_back => try v.deleteWordBack(),
            .delete_word_forward => try v.deleteWordForward(),
            .format => try files.format(self, false),
            .filter => try prompt.open(self, .filter),

            .select_all => v.selectAll(),
            .clear_selection => {
                // Esc closes one thing at a time: the help panel, then the
                // extra cursors and the selection.
                if (self.help) {
                    self.help = false;
                } else {
                    v.collapse();
                }
            },
            .add_cursor_above => _ = try v.addCaretVertical(-1),
            .add_cursor_below => _ = try v.addCaretVertical(1),

            .move_up => v.move(.up, extend, 1),
            .move_down => v.move(.down, extend, 1),
            .move_left => v.move(.left, extend, 1),
            .move_right => v.move(.right, extend, 1),
            .move_word_left => v.move(.word_left, extend, 1),
            .move_word_right => v.move(.word_right, extend, 1),
            .move_home => v.move(.line_start, extend, 1),
            .move_end => v.move(.line_end, extend, 1),
            .page_up => v.move(.page_up, extend, self.pageRows()),
            .page_down => v.move(.page_down, extend, self.pageRows()),
            .move_doc_start => v.move(.doc_start, extend, 1),
            .move_doc_end => v.move(.doc_end, extend, 1),
            .move_bracket => v.move(.bracket, extend, 1),

            .find => try prompt.open(self, .find),
            .find_next => self.findNext(1),
            .find_prev => self.findNext(-1),
            .replace => try prompt.open(self, .replace_find),
            .goto => try prompt.open(self, .goto),

            .command_palette => try pickers.open(self, .commands),
            .theme_picker => try pickers.open(self, .themes),
            .toggle_tree => try self.toggleTree(),
            .toggle_wrap => {
                self.config.soft_wrap = !self.config.soft_wrap;
                // Every pane re-folds at the next draw; keep each cursor in view.
                for (&self.panes) |*slot| {
                    if (slot.*) |*open| open.reveal = true;
                }
                self.setMessage("word wrap {s}", .{if (self.config.soft_wrap) "on" else "off"});
            },
            .help => self.help = !self.help,
            .split_columns => try self.splitPane(self.layout.focused().?, .columns, false, p.doc),
            .split_rows => try self.splitPane(self.layout.focused().?, .rows, false, p.doc),
            .close_pane => self.closePane(),
            .next_pane => self.layout.cycleFocus(1),
            .prev_pane => self.layout.cycleFocus(-1),
        }
    }

    pub fn save(self: *App) !void {
        const d = self.doc();
        if (d.path == null) return prompt.open(self, .save_as);
        if (self.config.format_on_save) files.format(self, true) catch {};
        d.save() catch |err| return self.reportError("Save failed", err);
        self.setMessage("Saved", .{});
    }

    /// Save the focused document under a new name. On failure the old path
    /// and the dirty flag are kept.
    pub fn saveAs(self: *App, path: []const u8) !void {
        const d = self.doc();
        const old: ?[]u8 = if (d.path) |p| try self.allocator.dupe(u8, p) else null;
        defer if (old) |p| self.allocator.free(p);
        try d.setPath(path);
        d.save() catch |err| {
            if (old) |p| {
                d.setPath(p) catch {};
            } else {
                self.allocator.free(d.path.?);
                d.path = null;
            }
            return self.reportError("Save failed", err);
        };
        self.setLanguage(d);
        self.setMessage("Saved", .{});
    }

    // --- search ------------------------------------------------------------

    /// Compile `needle` as the current search. An empty needle clears it.
    /// A bad regular expression is reported and leaves no search.
    pub fn setSearch(self: *App, needle: []const u8) !void {
        if (self.search) |*s| s.deinit();
        self.search = null;
        if (needle.len == 0) return;
        var diag: core.search.Diagnostic = .{};
        self.search = core.search.Search.init(self.allocator, needle, .{ .regex = self.search_regex }, &diag) catch |err| switch (err) {
            error.Syntax => return self.setMessage("regex: {s} (at {d})", .{ diag.message, diag.offset + 1 }),
            else => return err,
        };
    }

    /// Select the first match at or after `from` (wrapping to the start).
    /// Returns false when there is none.
    pub fn selectMatchFrom(self: *App, from: usize) bool {
        const s = if (self.search) |*s| s else return false;
        const buf = &self.doc().document.buffer;
        const m = s.next(buf, from) orelse s.next(buf, 0) orelse return false;
        self.view().setSelection(.{ .anchor = m.start, .head = m.end });
        self.pane().reveal = true;
        return true;
    }

    fn findNext(self: *App, direction: i2) void {
        const s = if (self.search) |*s| s else return self.setMessage("nothing to search for", .{});
        const buf = &self.doc().document.buffer;
        const sel = self.view().primarySelection();
        var found: ?core.search.Match = null;
        if (direction > 0) {
            found = s.next(buf, sel.end()) orelse s.next(buf, 0);
            // An empty match under a bare cursor (`^`, `$`) would be found
            // again and again: step past it.
            if (found) |m| {
                if (m.start == m.end and sel.isEmpty() and m.start == sel.head) {
                    found = s.next(buf, core.search.Search.after(buf, m)) orelse s.next(buf, 0);
                }
            }
        } else {
            found = s.prev(buf, sel.start()) orelse s.prev(buf, buf.len() + 1);
        }
        const m = found orelse return self.setMessage("not found", .{});
        self.view().setSelection(.{ .anchor = m.start, .head = m.end });
    }

    // --- housekeeping ------------------------------------------------------

    /// Called when nothing has happened for a while: follow changes made on
    /// disk. Returns true when the screen needs repainting.
    pub fn tick(self: *App) bool {
        return files.refreshFromDisk(self);
    }

    pub fn draw(self: *App, s: *screen.Screen) void {
        drawing.draw(self, s);
    }
};

/// Pasted text: CRLF and lone CR both mean a line break.
fn normalizePasted(data: []u8) []u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        var b = data[i];
        if (b == '\r') {
            if (i + 1 < data.len and data[i + 1] == '\n') continue;
            b = '\n';
        }
        data[out] = b;
        out += 1;
    }
    return data[0..out];
}

/// An error as a person would say it.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory",
        error.FileNotFound => "file not found",
        error.AccessDenied => "permission denied",
        error.IsDir => "that is a directory",
        error.FileTooBig => "file too large",
        error.NoPath => "the file has no name yet",
        error.Unsupported => "not available in this build",
        error.NotATerminal => "not a terminal (run it in a terminal window, not through a pipe)",
        else => @errorName(err),
    };
}

test {
    _ = @import("app/test.zig");
}
