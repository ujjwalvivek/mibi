//! mibi - a tiny, modern terminal text editor.
//!
//! Phase 2: piece-table buffer, cursor, selection, clipboard (+OSC 52),
//! undo/redo, file open/save with a prompt, rendered through the diff renderer.
//!
//! Size rules (measured; see experiments/README.md):
//!   - `pub fn main() void` + `run() catch` at the boundary. A `main` that can
//!     return an error costs ~484 KB. `try` inside helpers is free.
//!   - No `std.Io.Threaded`; I/O goes through src/os.zig.

const std = @import("std");
const builtin = @import("builtin");
const os = @import("os.zig");
const term = @import("term.zig");
const render = @import("render.zig");
const editor_mod = @import("editor.zig");
const Editor = editor_mod.Editor;
const utf8 = @import("text.zig");
const width = @import("width.zig");
const syntax = @import("syntax.zig");
const picker = @import("picker.zig");
const tree_mod = @import("tree.zig");
const panes_mod = @import("panes.zig");
const regex = @import("regex.zig");
const config_mod = @import("config.zig");
const keys = @import("keys.zig");

pub const version = "0.0.2";

const MAX_FILE = 64 * 1024 * 1024;

const HelpRow = struct {
    actions: []const keys.Action = &.{},
    literal: ?[]const u8 = null,
    desc: []const u8,
};

/// The help panel is built from actions, so rebound keys show up here too.
const help_rows = [_]HelpRow{
    .{ .actions = &.{ .move_word_left, .move_word_right }, .desc = "move by word (arrows move)" },
    .{ .actions = &.{ .move_home, .move_end }, .desc = "line start / end" },
    .{ .actions = &.{ .page_up, .page_down }, .desc = "move a page" },
    .{ .actions = &.{ .select_all, .clear_selection }, .desc = "select all / clear" },
    .{ .actions = &.{ .copy, .cut }, .desc = "copy / cut" },
    .{ .actions = &.{.paste}, .desc = "paste" },
    .{ .actions = &.{.duplicate_line}, .desc = "duplicate line" },
    .{ .actions = &.{ .undo, .redo }, .desc = "undo / redo" },
    .{ .actions = &.{ .find, .find_next, .find_prev }, .desc = "find / next / previous" },
    .{ .actions = &.{.replace}, .desc = "replace" },
    .{ .actions = &.{.goto}, .desc = "go to line[:col]" },
    .{ .actions = &.{.save}, .desc = "save" },
    .{ .actions = &.{.open}, .desc = "open file picker" },
    .{ .actions = &.{.theme_picker}, .desc = "theme picker (live preview)" },
    .{ .actions = &.{.command_palette}, .desc = "command palette" },
    .{ .actions = &.{ .new_tab, .close_tab }, .desc = "new / close tab" },
    .{ .actions = &.{ .next_tab, .prev_tab }, .desc = "next / previous tab" },
    .{ .actions = &.{ .split_columns, .close_pane, .next_pane }, .desc = "split / unsplit / next" },
    .{ .literal = "ctrl+alt+up/down", .desc = "add a cursor above / below" },
    .{ .actions = &.{.format}, .desc = "format with the configured tool" },
    .{ .actions = &.{.help}, .desc = "toggle this help" },
    .{ .actions = &.{.quit}, .desc = "quit (asks if unsaved)" },
    .{ .literal = "click / wheel", .desc = "cursor, tabs, pickers / scroll" },
    .{ .literal = "ctrl+b", .desc = "file tree (j/k, Enter, click)" },
};

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
};

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, _: ?usize) noreturn {
    term.restore();
    os.writeAll(os.STDERR, "mibi: ") catch {};
    os.writeAll(os.STDERR, msg) catch {};
    os.writeAll(os.STDERR, "\n") catch {};
    os.exit(1);
}

pub fn main(init: std.process.Init.Minimal) void {
    run(init) catch |err| fatal(err);
}

fn fatal(err: anyerror) noreturn {
    term.restore();
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "mibi: {s}\n", .{@errorName(err)}) catch "mibi: fatal error\n";
    os.writeAll(os.STDERR, msg) catch {};
    os.exit(1);
}

const PromptKind = enum { save_as, open, find, replace_find, replace_with, goto, confirm_quit, confirm_close };

const Prompt = struct {
    kind: PromptKind,
    buf: [512]u8 = undefined,
    len: usize = 0,
    /// Cursor position when the prompt opened (find searches from here).
    origin: usize = 0,
    /// The find text remembered between the replace prompts.
    find_buf: [256]u8 = undefined,
    find_len: usize = 0,
};

/// All open documents in tab order, with one active. Editors are heap
/// allocated so the list can grow without invalidating live pointers.
const UiRequest = enum { open_picker, theme_picker, command_palette };

/// The live session, so the console close handler (which runs on its own
/// thread) can save it when the window is closed with the X button.
var g_session: ?*Session = null;
var g_exe_dir: ?[]const u8 = null;

fn saveSessionOnClose() void {
    if (g_session) |s| saveSession(s, g_exe_dir);
}

const MAX_TABS = 32;

/// Cells the pointer must travel over a tab before a click turns into a drag.
const DRAG_THRESHOLD = 3;

/// Where a dragged tab would land when dropped on a pane: the half of the
/// pane it is over, which becomes a split in that direction.
const DropSide = enum { left, right, top, bottom };
const DropZone = struct { node: u8, side: DropSide };

const Session = struct {
    allocator: std.mem.Allocator,
    docs: std.ArrayList(*Editor),
    active: usize,
    config: config_mod.Config = .{},
    /// Set by an action that needs the UI layer to open a picker.
    ui_request: ?UiRequest = null,
    /// Set when the last tab is closed from the mouse: the run loop quits.
    quit_requested: bool = false,
    /// Set by the command palette: the run loop executes it like a key press.
    ui_action: ?keys.Action = null,
    /// Screen columns of each tab, filled in by drawTabBar so clicks can hit
    /// the same regions the user sees.
    tab_spans: [MAX_TABS][2]u16 = undefined,
    tab_close_x: [MAX_TABS]u16 = undefined,
    tab_count: usize = 0,
    new_tab_x: u16 = 0xFFFF,
    /// Syntax registry, so UI paths (the tree) can pick a language.
    registry: ?*syntax.Registry = null,
    /// Tab being dragged, where it would land, and the pointer column.
    drag_tab: ?usize = null,
    drag_to: usize = 0,
    drag_x: u16 = 0,
    /// Tab pressed on but not yet dragged: a click switches, a drag reorders.
    press_tab: ?usize = null,
    press_x: u16 = 0,
    press_y: u16 = 0,
    /// Where a tab being dragged would land if dropped on a pane.
    drop_zone: ?DropZone = null,
    /// Tab under the pointer (shows its path in the status line).
    hover_tab: ?usize = null,
    /// Pointer is over a tab's close button, the "+", or an end arrow.
    hover_close: ?usize = null,
    hover_plus: bool = false,
    hover_prev: bool = false,
    hover_next: bool = false,
    /// Tab strip scroll, in cells, snapped to a tab start. `tab_scroll_max` is
    /// the furthest scroll the current width allows; the strip layout is cached
    /// so the wheel and the end arrows can move by whole tabs.
    tab_scroll: usize = 0,
    tab_scroll_max: usize = 0,
    tab_starts: [MAX_TABS]usize = undefined,
    tab_widths: [MAX_TABS]usize = undefined,
    /// End arrows (0xFFFF when the strip fits and no arrows are drawn).
    tab_prev_x: u16 = 0xFFFF,
    tab_next_x: u16 = 0xFFFF,
    /// Active tab at the last draw, so a change scrolls it back into view.
    drawn_active: usize = MAX_TABS,
    /// File tree sidebar; null when closed.
    tree: ?tree_mod.Tree = null,
    tree_focus: bool = false,
    /// Split layout: each pane shows one document, by its stable id. `active`
    /// always names the focused pane's document.
    panes: panes_mod.Tree = panes_mod.Tree.empty(),
    /// The rectangle the panes were last laid out in, so a structural change
    /// (closing or splitting a pane from the mouse) can recompute the layout.
    pane_area: panes_mod.Rect = .{},
    next_doc_id: u32 = 1,

    fn init(allocator: std.mem.Allocator) Session {
        return .{ .allocator = allocator, .docs = std.ArrayList(*Editor).empty, .active = 0 };
    }

    fn deinit(self: *Session) void {
        if (self.tree) |*t| t.deinit();
        for (self.docs.items) |ed| {
            ed.deinit();
            self.allocator.destroy(ed);
        }
        self.docs.deinit(self.allocator);
    }

    fn count(self: *Session) usize {
        return self.docs.items.len;
    }

    fn current(self: *Session) *Editor {
        return self.docs.items[self.active];
    }

    fn add(self: *Session, path: ?[]const u8, data: []const u8, lang: ?*const syntax.Lang) !void {
        const ed = try self.allocator.create(Editor);
        errdefer self.allocator.destroy(ed);
        ed.* = try Editor.init(self.allocator, path, data);
        ed.tab_width = self.config.tab_width;
        ed.lang = if (self.config.syntax) lang else null;
        errdefer ed.deinit();
        ed.id = self.next_doc_id;
        self.next_doc_id += 1;
        try self.docs.append(self.allocator, ed);
        self.active = self.docs.items.len - 1;
        // A new document always lands in the focused pane.
        self.panes.setFocusedDoc(ed.id);
    }

    /// Index of the document with this id, if it is still open.
    fn docIndex(self: *Session, id: u32) ?usize {
        for (self.docs.items, 0..) |ed, i| {
            if (ed.id == id) return i;
        }
        return null;
    }

    /// Make document `i` the active one. If a pane already shows it, that pane
    /// takes the focus; otherwise the focused pane switches to it.
    fn focusDoc(self: *Session, i: usize) void {
        if (i >= self.docs.items.len) return;
        const id = self.docs.items[i].id;
        if (self.panes.paneWithDoc(id)) |node| {
            self.focusPane(node);
            return;
        }
        // The focused pane switches to it, keeping the document's own cursor.
        self.saveView();
        self.panes.setFocusedDoc(id);
        self.active = i;
        self.saveView();
    }

    /// Keep `active` pointing at the focused pane's document.
    fn syncActive(self: *Session) void {
        const id = self.panes.focusedDoc() orelse return;
        if (self.docIndex(id)) |i| self.active = i;
    }

    /// Every pane must show a live document: drop panes whose document was
    /// closed, and give the tree a document again if it lost its last pane.
    fn ensurePaneDocs(self: *Session) void {
        if (self.docs.items.len == 0) return;
        var guard: usize = 0;
        while (guard <= panes_mod.MAX_PANES) : (guard += 1) {
            var dead: ?u8 = null;
            for (self.panes.leaves[0..self.panes.leaf_count]) |node| {
                if (self.docIndex(self.panes.nodes[node].doc) == null) {
                    dead = node;
                    break;
                }
            }
            const node = dead orelse break;
            self.panes.focus = node;
            self.panes.removeFocused();
            if (self.panes.live == 0) break;
        }
        if (self.panes.live == 0) {
            const i = @min(self.active, self.docs.items.len - 1);
            self.panes = panes_mod.Tree.init(self.docs.items[i].id);
        }
        self.syncActive();
    }

    /// An open, empty, unsaved buffer that no pane is showing: splitting can
    /// reuse it instead of piling up `[No Name]` tabs.
    fn findScratch(self: *Session) ?usize {
        for (self.docs.items, 0..) |ed, i| {
            if (ed.path == null and !ed.dirty and ed.text().len == 0 and
                self.panes.paneWithDoc(ed.id) == null) return i;
        }
        return null;
    }

    /// Split the focused pane. The new pane shows the next tab that no other
    /// pane is showing, reusing an empty scratch tab, and only adds a new
    /// buffer when there is nothing at all left to show.
    fn splitFocused(self: *Session, dir: panes_mod.Dir) !void {
        // A split is a second view of what you are looking at, like every
        // other editor: the same document in both halves, each with its own
        // cursor and scroll. Nothing is created, so no blank buffer appears.
        if (self.panes.live == 0 or self.docs.items.len == 0) return;
        if (self.panes.leaf_count >= panes_mod.MAX_PANES) return;
        self.saveView();
        const doc = self.panes.nodes[self.panes.focus].doc;
        if (!self.panes.split(dir, doc)) return;
        self.loadView(self.panes.focus);
    }

    /// Close the tab at `index`; a dirty tab becomes active and asks first.
    fn closeTabAt(self: *Session, index: usize, prompt: *?Prompt) void {
        if (index >= self.docs.items.len) return;
        self.focusDoc(index);
        if (self.docs.items[index].dirty) {
            prompt.* = .{ .kind = .confirm_close };
            return;
        }
        self.closeActive();
        // Closing the last tab quits, exactly like Ctrl+W.
        if (self.docs.items.len == 0) self.quit_requested = true;
    }

    /// Move the tab at `from` to `to`, keeping the same tab active.
    fn moveTab(self: *Session, from: usize, to: usize) void {
        const n = self.docs.items.len;
        if (from >= n or to >= n or from == to) return;
        const doc = self.docs.orderedRemove(from);
        self.docs.insert(self.allocator, to, doc) catch {
            self.docs.append(self.allocator, doc) catch return;
        };
        self.active = to;
    }

    /// Close the active tab; the caller quits when the last one goes.
    fn closeActive(self: *Session) void {
        if (self.docs.items.len == 0) return;
        const ed = self.docs.items[self.active];
        const id = ed.id;
        ed.deinit();
        self.allocator.destroy(ed);
        _ = self.docs.orderedRemove(self.active);
        // Every pane showing it goes; each sibling takes its parent's place.
        var guard: usize = 0;
        while (guard < panes_mod.MAX_PANES) : (guard += 1) {
            const node = self.panes.paneWithDoc(id) orelse break;
            if (self.panes.live <= 1) break; // the last pane always stays
            self.panes.focus = node;
            self.panes.removeFocused();
        }
        if (self.docs.items.len == 0) {
            self.panes = panes_mod.Tree.empty();
            return;
        }
        if (self.active >= self.docs.items.len) self.active = self.docs.items.len - 1;
        self.ensurePaneDocs();
    }

    fn cycle(self: *Session, delta: isize) void {
        const n = self.docs.items.len;
        if (n <= 1) return;
        const i: isize = @as(isize, @intCast(self.active)) + delta;
        self.focusDoc(@intCast(@mod(i, @as(isize, @intCast(n)))));
    }

    /// Close the focused pane. Its document stays open as a tab, so a split
    /// can be undone without closing (or reopening) the file.
    fn closePane(self: *Session) void {
        if (self.panes.live <= 1) return; // the last pane always stays
        self.panes.removeFocused();
        self.ensurePaneDocs();
    }

    /// Drop a dragged tab onto a pane edge: that document moves into a new
    /// pane split off the target.
    fn dropTabIntoPane(self: *Session, tab: usize, dz: DropZone) void {
        if (tab >= self.docs.items.len) return;
        if (self.panes.live == 0) return;
        const doc = self.docs.items[tab].id;
        const dir: panes_mod.Dir = if (dz.side == .left or dz.side == .right) .columns else .rows;
        const first = dz.side == .left or dz.side == .top;
        // Dropping on a pane edge always makes a new view there, even of the
        // document that pane already shows.
        if (self.panes.leaf_count >= panes_mod.MAX_PANES) return;
        self.saveView();
        if (!self.panes.splitAt(dz.node, dir, doc, first)) return;
        self.loadView(self.panes.focus);
    }

    /// Store the live cursor and scroll in the focused pane, so another pane
    /// can be given the editor without losing where this one was looking.
    fn saveView(self: *Session) void {
        if (self.panes.live == 0 or self.docs.items.len == 0) return;
        const ed = self.docs.items[self.active];
        const n = &self.panes.nodes[self.panes.focus];
        n.view_cursor = ed.cursor;
        n.view_row = ed.scroll_row;
        n.view_col = ed.scroll_col;
    }

    /// Give the editor the view stored in `node`.
    fn loadView(self: *Session, node: u8) void {
        const n = self.panes.nodes[node];
        const idx = self.docIndex(n.doc) orelse return;
        const ed = self.docs.items[idx];
        ed.cursor = @min(n.view_cursor, ed.text().len);
        ed.scroll_row = n.view_row;
        ed.scroll_col = n.view_col;
        self.active = idx;
    }

    /// Focus a pane, carrying the editor's view state with it.
    fn focusPane(self: *Session, node: u8) void {
        if (self.panes.live == 0) return;
        if (node == self.panes.focus) {
            self.syncActive();
            return;
        }
        self.saveView();
        self.panes.focus = node;
        self.loadView(node);
    }

    /// Move the focus to the next pane and follow it with the active document.
    fn cyclePane(self: *Session, delta: isize) void {
        if (self.panes.leaf_count <= 1) return;
        self.saveView();
        self.panes.cycleFocus(delta);
        self.loadView(self.panes.focus);
    }

    /// Scroll the tab strip by one tab. Manual scrolling pins the strip, so the
    /// next draw does not jump back to the active tab.
    fn scrollTabs(self: *Session, dir: i8) void {
        if (self.tab_scroll_max == 0) return;
        var target = self.tab_scroll;
        if (dir > 0) {
            var i: usize = 0;
            while (i < self.tab_count) : (i += 1) {
                if (self.tab_starts[i] > self.tab_scroll) {
                    target = self.tab_starts[i];
                    break;
                }
            }
        } else {
            var i: usize = self.tab_count;
            while (i > 0) {
                i -= 1;
                if (self.tab_starts[i] < self.tab_scroll) {
                    target = self.tab_starts[i];
                    break;
                }
            }
        }
        if (target > self.tab_scroll_max) target = self.tab_scroll_max;
        self.tab_scroll = target;
        self.drawn_active = self.active;
    }

    fn anyDirty(self: *Session) bool {
        for (self.docs.items) |ed| {
            if (ed.dirty) return true;
        }
        return false;
    }

    fn findByPath(self: *Session, path: []const u8) ?usize {
        for (self.docs.items, 0..) |ed, i| {
            if (ed.path) |p| {
                if (pathsEqual(p, path)) return i;
            }
        }
        return null;
    }
};

fn run(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;

    var arg_it = try init.args.iterateAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.next();
    var in_terminal = false;
    var path: ?[]const u8 = null;
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--in-terminal")) {
            in_terminal = true; // set by the hand-off below; do not recurse
        } else if (path == null) {
            path = arg;
        }
    }

    // `mibi --version` must work without a terminal.
    if (path) |p| {
        if (std.mem.eql(u8, p, "--version") or std.mem.eql(u8, p, "-v")) {
            var buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "mibi {s}\n", .{version});
            try os.writeAll(os.STDOUT, s);
            return;
        }
    }

    if (!term.isTty()) return error.NotATerminal;

    const exe_dir = os.exeDirAlloc(allocator) catch null;
    defer if (exe_dir) |d| allocator.free(d);
    const config = config_mod.load(allocator, exe_dir);

    // Double-clicking a console app gets a console window of its own, which is
    // not what a TUI wants. When that happens, hide the flash and explain that
    // mibi runs inside a terminal. `--in-terminal` skips the check.
    if (os.is_windows and !in_terminal and !os.inWindowsTerminal() and os.consoleProcessCount() <= 1) {
        os.hideConsoleWindow();
        os.messageBox(
            "mibi is a terminal text editor.\n\n" ++
                "Open it from a terminal window instead of double-clicking:\n\n" ++
                "    mibi <file>     in Windows Terminal (or any terminal)\n" ++
                "    mibi.cmd        in assets\\windows-terminal\\\n\n" ++
                "The README covers the Windows Terminal profile, colours and keys.",
            "mibi",
        );
        return;
    }

    var initial: []const u8 = "";
    var initial_owned: ?[]u8 = null;
    if (path) |p| {
        initial_owned = os.readFileAlloc(allocator, p, MAX_FILE) catch |err| switch (err) {
            // A missing file is how `mibi newfile` starts: open empty and let
            // Ctrl+S create it. Anything else (permissions, size, I/O) must be
            // reported: opening an empty buffer with the path attached would
            // let a later save silently destroy the real file.
            error.FileNotFound => null,
            else => return err,
        };
        if (initial_owned) |d| initial = d;
    }
    // Syntax definitions live in `syntax.d`, next to the binary or in the
    // working directory (kibi's model: data files, not code).
    var registry = syntax.Registry.init(allocator);
    defer registry.deinit();
    if (exe_dir) |dir| {
        var dir_buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&dir_buf, "{s}/syntax.d", .{dir})) |sub_dir| {
            _ = registry.loadDir(sub_dir);
        } else |_| {}
    }
    if (registry.langs.items.len == 0) _ = registry.loadDir("syntax.d");

    // Session state goes to the user's data directory, not the project folder.
    g_session_dir = blk: {
        const dir = sessionDirAlloc(allocator) catch break :blk null;
        os.makeDirAll(dir) catch {};
        break :blk dir;
    };

    var session = Session.init(allocator);
    defer session.deinit();
    session.registry = &registry;
    session.config = config;
    // Always bring back the previous session (tabs, cursors and the text of
    // anything that was not saved); a file named on the command line is added
    // to it as a tab instead of replacing it.
    const restored = loadSession(allocator, exe_dir, &registry, &session);
    if (path) |p| {
        var already = false;
        for (session.docs.items, 0..) |doc, i| {
            if (doc.path) |doc_path| {
                if (pathsEqual(doc_path, p)) {
                    session.focusDoc(i);
                    already = true;
                    break;
                }
            }
        }
        if (!already) try session.add(p, initial, registry.find(p));
    } else if (!restored) {
        try session.add(null, "", null);
    }
    if (initial_owned) |d| allocator.free(d);

    try term.enterRaw();
    defer term.restore();
    try term.enterAltScreen();
    defer term.leaveAltScreen() catch {};

    const first = term.size();
    var screen = try render.Screen.init(allocator, first.cols, first.rows);
    defer screen.deinit();
    // Paint every cell on the first frame: the diff renderer assumes the
    // terminal starts blank, but a host that keeps old content around (or an
    // alternate screen that was not cleared) would otherwise leak it through.
    @memset(screen.front, render.Cell{ .ch = 0, .attr = .{ .bold = true, .underline = true, .reverse = true } });

    defer saveSession(&session, exe_dir);
    // The X button terminates the process without unwinding, so save from the
    // console control handler as well as from the normal exit path.
    g_session = &session;
    g_exe_dir = exe_dir;
    term.installCloseHandler(saveSessionOnClose);
    var last_save_ms = os.ticksMs();
    var unsaved = false;
    var input: [256]u8 = undefined;
    var msg_buf: [96]u8 = undefined;
    var msg: []const u8 = "";
    var theme_warn_buf: [128]u8 = undefined;
    if (session.config.theme_missing) {
        msg = std.fmt.bufPrint(&theme_warn_buf, "theme '{s}' not found", .{session.config.themeName()}) catch "theme not found";
    }
    var prompt: ?Prompt = null;
    var running = true;
    var help = false;
    // Fuzzy picker: file open (Ctrl+O) and theme switch (F2, live preview).
    var picker_state: ?picker.Picker = null;
    var picker_mode: picker.Mode = .open_file;
    var theme_before: config_mod.Theme = .{};
    defer closePicker(&picker_state);
    var zero_reads: usize = 0;
    var last_scroll_row: usize = std.math.maxInt(usize);
    var last_scroll_col: usize = std.math.maxInt(usize);
    var last_title: [192]u8 = undefined;
    var last_title_len: usize = 0;
    // Bytes held back when an escape sequence is split across reads.
    var pending: [1024]u8 = undefined;
    var pending_len: usize = 0;

    var needs_redraw = true;
    while (running) {
        const now = term.size();
        if (now.cols != screen.cols or now.rows != screen.rows) {
            try screen.resize(now.cols, now.rows);
            @memset(screen.front, render.Cell{ .ch = 0, .attr = .{ .bold = true, .underline = true, .reverse = true } });
            try term.write("\x1b[2J");
            needs_redraw = true;
        }

        // Keep the view on the cursor; when the view scrolls, repaint the whole
        // screen so no stale cells can survive the jump. Rows 0 and h-1 are the
        // tab bar and the status/prompt line.
        {
            const ed = session.current();
            const total = ed.lineCount();
            const gutter = digits(total) + 1;
            const w: usize = screen.cols;
            const text_cols: usize = if (w > gutter + 1) w - gutter - 1 else 0;
            ed.scrollToCursor(viewRows(screen.rows), text_cols);
            if (ed.scroll_row != last_scroll_row or ed.scroll_col != last_scroll_col) {
                last_scroll_row = ed.scroll_row;
                last_scroll_col = ed.scroll_col;
                @memset(screen.front, render.Cell{ .ch = 0, .attr = .{ .bold = true, .underline = true, .reverse = true } });
            }
        }

        // Keep the terminal/tab title in step with the active document, so the
        // host's chrome shows "mibi - notes.txt" instead of the executable path.
        {
            const ed = session.current();
            const name = ed.path orelse "[No Name]";
            var title_buf: [160]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, "mibi - {s}{s}", .{
                name,
                if (ed.dirty) " [+]" else "",
            }) catch "mibi";
            if (!std.mem.eql(u8, title, last_title[0..last_title_len])) {
                const n = @min(title.len, last_title.len);
                @memcpy(last_title[0..n], title[0..n]);
                last_title_len = n;
                term.setTitle(title) catch {};
            }
        }

        if (needs_redraw) {
            draw(&screen, &session, msg, prompt, help);
            if (picker_state) |*pk| drawPicker(&screen, pk, picker_mode, session.config.theme);
            try screen.render();
            needs_redraw = false;
        }

        const n = try term.readInput(&input);
        if (n == 0) {
            // Focus changes are not input, but a terminal that was in the
            // background may have painted nothing at all, so the picture it
            // shows is stale. Repaint every cell instead of a per-row diff.
            if (term.takeFocusChange()) {
                zero_reads = 0;
                dirtyAll(&screen);
                needs_redraw = true;
                continue;
            }
            // A console resize wakes the read with no bytes: repaint at the new
            // size instead of counting it as end-of-input.
            if (term.takeResize()) {
                zero_reads = 0;
                continue;
            }
            // An idle tick: refresh anything that changed on disk, then wait
            // again. This is what makes the tree and open files keep up.
            if (term.takeIdle()) {
                zero_reads = 0;
                if (refreshFromDisk(&session, &msg_buf, &msg)) {
                    dirtyAll(&screen);
                    needs_redraw = true;
                }
                continue;
            }
            zero_reads += 1;
            if (zero_reads >= 3) break;
            continue;
        }
        zero_reads = 0;

        // Append to anything held back from a split escape sequence.
        if (pending_len + n > pending.len) pending_len = 0;
        @memcpy(pending[pending_len .. pending_len + n], input[0..n]);
        pending_len += n;

        msg = "";
        needs_redraw = true;
        const view_rows = viewRows(screen.rows);
        // Consume whole tokens. A prompt can close in the middle of a chunk
        // (Enter), after which the remaining bytes are ordinary editing input.
        var off: usize = 0;
        while (off < pending_len and running) {
            if (session.quit_requested) break;
            const chunk = pending[off..pending_len];
            if (session.tree_focus and session.tree != null and prompt == null and picker_state == null) {
                if (handleTreeInput(&session, chunk, &msg_buf, &msg)) |consumed| {
                    off += consumed;
                    continue;
                }
            }
            const used = if (picker_state != null)
                try handlePickerInput(&session, &picker_state, picker_mode, &theme_before, exe_dir, &registry, chunk, &running, &msg_buf, &msg)
            else if (prompt != null)
                try handlePromptInput(&session, &registry, &prompt, chunk, &running, &msg_buf, &msg)
            else
                try processInput(&session, chunk, view_rows, &running, &prompt, &help, &msg_buf, &msg);
            if (used == 0) break; // incomplete escape sequence: wait for more
            off += used;
            // The command palette asks for an action to run.
            if (session.ui_action) |action| {
                session.ui_action = null;
                switch (defaultKeyFor(action, false)) {
                    .byte => |b| applyByte(&session, b, &running, &prompt, &msg_buf, &msg, &help, view_rows, false) catch |e| setMsg(&msg_buf, &msg, @errorName(e)),
                    .csi => |c| applyCsi(&session, c.params, c.final, view_rows, &running, &prompt, &msg_buf, &msg, &help, false) catch |e| setMsg(&msg_buf, &msg, @errorName(e)),
                }
            }
            // An action can ask for a picker (Ctrl+O, F2): open it right away so
            // the first press is enough.
            if (session.ui_request) |req| {
                session.ui_request = null;
                const mode: picker.Mode = switch (req) {
                    .theme_picker => .theme,
                    .command_palette => .commands,
                    .open_picker => .open_file,
                };
                openPicker(&session, &picker_state, mode, &theme_before, exe_dir);
                picker_mode = mode;
            }
        }
        if (off > 0) unsaved = true;
        // Autosave: a crash, a kill, or a console that never delivers the
        // close event loses at most a couple of seconds.
        const now_ms = os.ticksMs();
        if (unsaved and now_ms - last_save_ms >= 2000) {
            saveSession(&session, exe_dir);
            last_save_ms = now_ms;
            unsaved = false;
        }
        // The tab bar's close button quits when it closes the last tab.
        if (session.quit_requested) {
            session.quit_requested = false;
            running = false;
        }
        const rem = pending_len - off;
        if (rem > 0) std.mem.copyForwards(u8, pending[0..rem], pending[off..pending_len]);
        pending_len = rem;
    }
}

// ---------------------------------------------------------------------------
// Session persistence: the tabs, their cursors, and the text of unsaved
// buffers, so a restart (or a crash) does not lose work.
// ---------------------------------------------------------------------------
const SESSION_FILE = "mibi-session";

/// Where session state lives. It is deliberately *not* the project folder:
/// a per-project hash under the user's data directory keeps working
/// directories clean, and `MIBI_STATE_DIR` overrides it (used by the tests).
var g_session_dir: ?[]u8 = null;

fn sessionDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    if (os.getEnvAlloc(allocator, "MIBI_STATE_DIR")) |v| {
        if (v.len > 0) return v;
        allocator.free(v);
    } else |_| {}
    const data = try os.dataDirAlloc(allocator);
    defer allocator.free(data);
    const cwd = try os.cwdAlloc(allocator);
    defer allocator.free(cwd);
    // FNV-1a over the working directory: one session per project.
    var h: u64 = 0xcbf29ce484222325;
    for (cwd) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return std.fmt.allocPrint(allocator, "{s}/sessions/{x}", .{ data, h });
}

fn sessionPath(buf: []u8) []const u8 {
    if (g_session_dir) |d| {
        if (std.fmt.bufPrint(buf, "{s}/" ++ SESSION_FILE, .{d})) |p| return p else |_| {}
    }
    return SESSION_FILE;
}

fn bufferPath(index: usize, buf: []u8) []const u8 {
    if (g_session_dir) |d| {
        if (std.fmt.bufPrint(buf, "{s}/" ++ SESSION_FILE ++ "-buf-{d}.txt", .{ d, index })) |p| return p else |_| {}
    }
    return std.fmt.bufPrint(buf, SESSION_FILE ++ "-buf-{d}.txt", .{index}) catch SESSION_FILE;
}

fn saveSession(session: *Session, exe_dir: ?[]const u8) void {
    _ = exe_dir;
    const allocator = std.heap.page_allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var path_buf: [1024]u8 = undefined;
    var line_buf: [1024]u8 = undefined;

    const header = std.fmt.bufPrint(&line_buf, "v1\nactive {d}\ncount {d}\ntree {d}\n", .{
        session.active,
        session.count(),
        @intFromBool(session.tree != null),
    }) catch return;
    out.appendSlice(allocator, header) catch return;
    if (session.tree) |*t| {
        const root_line = std.fmt.bufPrint(&line_buf, "tree_root {s}\n", .{t.rootPath()}) catch "";
        out.appendSlice(allocator, root_line) catch {};
        // Which folders were open and which entry was selected.
        var sel_buf: [1024]u8 = undefined;
        if (t.selectedPath(&sel_buf)) |sel| {
            const sel_line = std.fmt.bufPrint(&line_buf, "tree_sel {s}\n", .{sel}) catch "";
            out.appendSlice(allocator, sel_line) catch {};
        }
        for (t.expanded.items) |dir| {
            const dir_line = std.fmt.bufPrint(&line_buf, "tree_exp {s}\n", .{dir}) catch continue;
            out.appendSlice(allocator, dir_line) catch {};
        }
    }
    // Split layout, preorder: `p <tab>` for a leaf, `s <dir> <ratio>` for a
    // split. Tab indices are remapped back to document ids on load.
    {
        var enc = std.ArrayList(panes_mod.Encoded).empty;
        defer enc.deinit(allocator);
        panes_mod.encode(&session.panes, &enc, allocator) catch {};
        for (enc.items) |*e| {
            const line = switch (e.*) {
                .leaf => |l| blk: {
                    const idx: u32 = if (session.docIndex(l.doc)) |i| @intCast(i) else 0;
                    break :blk std.fmt.bufPrint(&line_buf, "p {d} {d} {d} {d}\n", .{ idx, l.cursor, l.row, l.col }) catch continue;
                },
                .split => |sp| std.fmt.bufPrint(&line_buf, "s {d} {d}\n", .{ @intFromEnum(sp.dir), sp.ratio }) catch continue,
            };
            out.appendSlice(allocator, line) catch {};
        }
    }
    for (session.docs.items, 0..) |ed, i| {
        var buf_path: [1024]u8 = undefined;
        const bp = bufferPath(i, &buf_path);
        const has_buffer = ed.dirty or ed.path == null;
        if (has_buffer) os.writeFile(bp, ed.text()) catch {};
        const row = ed.rowCol();
        const line = std.fmt.bufPrint(&line_buf, "tab {s}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
            ed.path orelse "",
            ed.cursor,
            @intFromBool(ed.dirty),
            @intFromBool(has_buffer),
            row.row,
            row.col,
        }) catch continue;
        out.appendSlice(allocator, line) catch return;
    }
    const path = sessionPath(&path_buf);
    os.writeFile(path, out.items) catch {};
}

fn loadSession(allocator: std.mem.Allocator, exe_dir: ?[]const u8, registry: *syntax.Registry, session: *Session) bool {
    _ = exe_dir;
    var path_buf: [1024]u8 = undefined;
    const path = sessionPath(&path_buf);
    const data = os.readFileAlloc(allocator, path, 16 * 1024 * 1024) catch blk: {
        // An older mibi kept its session in the working directory.
        if (g_session_dir != null) {
            if (os.readFileAlloc(allocator, SESSION_FILE, 16 * 1024 * 1024)) |old| {
                os.deleteFile(SESSION_FILE) catch {};
                break :blk old;
            } else |_| {}
        }
        return false;
    };
    defer allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    const magic = lines.next() orelse return false;
    if (!std.mem.eql(u8, std.mem.trim(u8, magic, " \r"), "v1")) return false;
    var active: usize = 0;
    var loaded: usize = 0;
    var tree_open = false;
    var tree_root: [1024]u8 = undefined;
    var tree_root_len: usize = 0;
    var tree_sel: [1024]u8 = undefined;
    var tree_sel_len: usize = 0;
    var tree_expanded = std.ArrayList([]u8).empty;
    defer {
        for (tree_expanded.items) |p| allocator.free(p);
        tree_expanded.deinit(allocator);
    }
    var pane_enc = std.ArrayList(panes_mod.Encoded).empty;
    defer pane_enc.deinit(allocator);
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (std.mem.startsWith(u8, line, "active ")) {
            active = std.fmt.parseInt(usize, line["active ".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, line, "count ")) {
            // informational only
        } else if (std.mem.startsWith(u8, line, "tree_root ")) {
            // Before "tree ": every tree_root line also starts with "tree ".
            const root = line["tree_root ".len..];
            const n = @min(root.len, tree_root.len);
            @memcpy(tree_root[0..n], root[0..n]);
            tree_root_len = n;
        } else if (std.mem.startsWith(u8, line, "tree_sel ")) {
            const sel = line["tree_sel ".len..];
            const n = @min(sel.len, tree_sel.len);
            @memcpy(tree_sel[0..n], sel[0..n]);
            tree_sel_len = n;
        } else if (std.mem.startsWith(u8, line, "tree_exp ")) {
            const dir = line["tree_exp ".len..];
            if (dir.len > 0) {
                const copy = allocator.dupe(u8, dir) catch null;
                if (copy) |c| tree_expanded.append(allocator, c) catch allocator.free(c);
            }
        } else if (std.mem.startsWith(u8, line, "tree ")) {
            tree_open = std.mem.eql(u8, line["tree ".len..], "1");
        } else if (std.mem.startsWith(u8, line, "p ")) {
            var f = std.mem.splitScalar(u8, line["p ".len..], ' ');
            const idx = std.fmt.parseInt(u32, f.next() orelse "0", 10) catch 0;
            const cursor = std.fmt.parseInt(usize, f.next() orelse "0", 10) catch 0;
            const row = std.fmt.parseInt(usize, f.next() orelse "0", 10) catch 0;
            const col = std.fmt.parseInt(usize, f.next() orelse "0", 10) catch 0;
            pane_enc.append(allocator, .{ .leaf = .{ .doc = idx, .cursor = cursor, .row = row, .col = col } }) catch {};
        } else if (std.mem.startsWith(u8, line, "s ")) {
            var fields = std.mem.splitScalar(u8, line["s ".len..], ' ');
            const dir = std.fmt.parseInt(u8, fields.next() orelse "0", 10) catch 0;
            const ratio = std.fmt.parseInt(u8, fields.next() orelse "50", 10) catch 50;
            pane_enc.append(allocator, .{ .split = .{
                .dir = if (dir == 1) .rows else .columns,
                .ratio = @min(@max(ratio, 10), 90),
            } }) catch {};
        } else if (std.mem.startsWith(u8, line, "tab ")) {
            var fields = std.mem.splitScalar(u8, line["tab ".len..], '\t');
            const tab_path = fields.next() orelse continue;
            const cursor = std.fmt.parseInt(usize, fields.next() orelse "0", 10) catch 0;
            const dirty = std.fmt.parseInt(u8, fields.next() orelse "0", 10) catch 0;
            const has_buffer = std.fmt.parseInt(u8, fields.next() orelse "0", 10) catch 0;
            _ = std.fmt.parseInt(usize, fields.next() orelse "0", 10) catch 0;
            _ = std.fmt.parseInt(usize, fields.next() orelse "0", 10) catch 0;

            var buf_path: [1024]u8 = undefined;
            const bp = bufferPath(loaded, &buf_path);
            var text: []u8 = &[_]u8{};
            var owned = false;
            if (has_buffer != 0) {
                if (os.readFileAlloc(allocator, bp, MAX_FILE)) |t| {
                    text = t;
                    owned = true;
                } else |_| {}
            }
            if (!owned) {
                if (tab_path.len > 0) {
                    if (os.readFileAlloc(allocator, tab_path, MAX_FILE)) |t| {
                        text = t;
                        owned = true;
                    } else |_| {}
                }
            }
            defer if (owned) allocator.free(text);
            const lang = if (tab_path.len > 0) registry.find(tab_path) else null;
            session.add(if (tab_path.len > 0) tab_path else null, text, lang) catch continue;
            const ed = session.current();
            ed.cursor = @min(cursor, ed.text().len);
            ed.dirty = dirty != 0;
            loaded += 1;
        }
    }
    if (loaded == 0) return false;
    session.active = @min(active, session.count() - 1);
    // Rebuild the split layout. Saved leaves carry tab indices; map them back
    // to document ids now that the tabs exist.
    if (pane_enc.items.len > 0) {
        for (pane_enc.items) |*e| {
            switch (e.*) {
                .leaf => |l| {
                    const i = @min(l.doc, @as(u32, @intCast(session.count() - 1)));
                    e.* = .{ .leaf = .{ .doc = session.docs.items[i].id, .cursor = l.cursor, .row = l.row, .col = l.col } };
                },
                .split => {},
            }
        }
        if (panes_mod.decode(pane_enc.items)) |t| {
            session.panes = t;
            const want = session.docs.items[session.active].id;
            if (session.panes.paneWithDoc(want)) |node| {
                session.panes.focus = node;
            } else if (session.panes.leaf_count > 0) {
                session.panes.focus = session.panes.leaves[0];
            }
        }
    }
    if (tree_open) {
        const root = if (tree_root_len > 0) tree_root[0..tree_root_len] else ".";
        if (tree_mod.Tree.init(allocator, root)) |t| {
            session.tree = t;
            // Re-open the folders that were open, then reload once.
            for (tree_expanded.items) |dir| session.tree.?.expand(dir) catch {};
            session.tree.?.reload() catch {};
            if (tree_sel_len > 0) session.tree.?.selectPath(tree_sel[0..tree_sel_len]);
            session.tree_focus = false;
        } else |_| {}
    }
    return true;
}

fn setMsg(buf: []u8, out: *[]const u8, text: []const u8) void {
    const n = @min(buf.len, text.len);
    @memcpy(buf[0..n], text[0..n]);
    out.* = buf[0..n];
}

/// `prefix: ErrorName` in the status line, e.g. "Save failed: AccessDenied".
fn setErrMsg(buf: []u8, out: *[]const u8, prefix: []const u8, err: anyerror) void {
    var tmp: [96]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{s}: {s}", .{ prefix, @errorName(err) }) catch prefix;
    setMsg(buf, out, s);
}

/// Process as much of `buf` as forms complete tokens, returning how many bytes
/// were consumed. An escape sequence split across reads is left for next time,
/// so its bytes are never mistaken for typed text.
fn processInput(
    session: *Session,
    buf: []const u8,
    view_rows: usize,
    running: *bool,
    prompt: *?Prompt,
    help: *bool,
    msg_buf: []u8,
    msg: *[]const u8,
) !usize {
    var i: usize = 0;
    while (i < buf.len) {
        if (!running.*) break;
        // The last tab can close inside this chunk (its close button): stop
        // before another token asks for the now-missing document.
        if (session.docs.items.len == 0) break;
        const b = buf[i];
        if (b == 0x1b) {
            if (i + 1 >= buf.len) {
                // A trailing Esc closes the help panel right away. Other
                // actions still wait for the next byte, so an escape sequence
                // split across reads is never mistaken for Esc.
                if (help.*) {
                    help.* = false;
                    return i + 1;
                }
                return i; // incomplete: wait for more
            }
            const k = buf[i + 1];
            if (k == '[') {
                var j = i + 2;
                while (j < buf.len) : (j += 1) {
                    if (buf[j] >= 0x40 and buf[j] <= 0x7E) break;
                }
                if (j >= buf.len) return i; // incomplete
                if (buf[i + 2] == '<') {
                    // SGR mouse: ESC [ < button ; x ; y M
                    handleMouse(session, buf[i + 2 .. j], buf[j], help, prompt, msg_buf, msg);
                } else {
                    applyCsi(session, buf[i + 2 .. j], buf[j], view_rows, running, prompt, msg_buf, msg, help, true) catch |e| setMsg(msg_buf, msg, @errorName(e));
                }
                i = j + 1;
            } else if (k == 'O') {
                if (i + 2 >= buf.len) return i;
                switch (buf[i + 2]) {
                    'A', 'B', 'C', 'D', 'H', 'F', 'R', 'P', 'Q' => |f| applyCsi(session, "", f, view_rows, running, prompt, msg_buf, msg, help, true) catch |e| setMsg(msg_buf, msg, @errorName(e)),
                    // F4 in its SS3 form (ESC O S), which is what terminals send.
                    'S' => applyCsi(session, "14", '~', view_rows, running, prompt, msg_buf, msg, help, true) catch |e| setMsg(msg_buf, msg, @errorName(e)),
                    else => {},
                }
                i += 3;
            } else {
                applyByte(session, 0x1b, running, prompt, msg_buf, msg, help, view_rows, true) catch |e| setMsg(msg_buf, msg, @errorName(e)); // lone Esc
                i += 1;
            }
        } else {
            applyByte(session, b, running, prompt, msg_buf, msg, help, view_rows, true) catch |e| setMsg(msg_buf, msg, @errorName(e));
            i += 1;
        }
    }
    return i;
}

/// Parse the `<button;x;y` part of an SGR mouse sequence.
fn parseMouse(params: []const u8) [3]u16 {
    var nums: [3]u16 = .{ 0, 0, 0 };
    var count: usize = 0;
    for (params) |c| {
        if (c == '<') continue;
        if (c == ';') {
            if (count < nums.len - 1) count += 1;
            continue;
        }
        if (c < '0' or c > '9') break;
        nums[count] = nums[count] * 10 + (c - '0');
    }
    return nums;
}

/// Mouse in the editor: click the tab bar to switch tabs, click the status-bar
/// hint to toggle help, click text to place the cursor. The wheel moves one
/// line per notch.
fn handleMouse(session: *Session, params: []const u8, final: u8, help: *bool, prompt: *?Prompt, msg_buf: []u8, msg: *[]const u8) void {
    // Closing the last tab empties the session; the run loop quits right after,
    // so any further event in the same chunk must not touch the editor.
    if (session.docs.items.len == 0) return;
    // The mouse needs the pane geometry. The draw before input normally leaves
    // it cached, but a click can arrive before the first frame.
    if (session.panes.rect_count == 0) {
        const sz = term.size();
        const side = sidebarWidth(session);
        session.pane_area = .{
            .x = side,
            .y = 1,
            .w = if (sz.cols > side) @as(usize, sz.cols) - side else 0,
            .h = viewRows(sz.rows),
        };
        session.panes.layout(session.pane_area);
    }
    const nums = parseMouse(params);
    const button = nums[0];
    const x = nums[1];
    const y = nums[2];
    const ed = session.current();

    // A press always starts fresh: a release that never arrived must not leave
    // a drag chip or a drop hint behind.
    if (button == 0 and final == 'M') {
        session.drag_tab = null;
        session.drop_zone = null;
    }
    // Tab bar: the "x" closes a tab, "+" opens one, the arrows scroll the
    // strip, the label switches (and starts a drag).
    if (button == 0 and final == 'M' and y == 1) {
        const col = if (x > 0) @as(u16, x) - 1 else 0;
        if (col == session.tab_prev_x) {
            session.scrollTabs(-1);
            return;
        }
        if (col == session.tab_next_x) {
            session.scrollTabs(1);
            return;
        }
        var i: usize = 0;
        while (i < session.tab_count) : (i += 1) {
            if (col == session.tab_close_x[i]) {
                session.closeTabAt(i, prompt);
                return;
            }
        }
        if (col == session.new_tab_x) {
            session.add(null, "", null) catch {};
            return;
        }
        i = 0;
        while (i < session.tab_count) : (i += 1) {
            const span = session.tab_spans[i];
            if (x >= span[0] and x < span[1]) {
                session.focusDoc(i); // a plain click switches
                // A press only becomes a drag once the pointer really moves,
                // so clicking a tab never flashes the drag chip.
                session.press_tab = i;
                session.press_x = x;
                session.press_y = y;
                session.drag_to = i;
                return;
            }
        }
    }
    if (session.press_tab) |from| {
        if (button == 32) { // motion while held
            if (session.drag_tab == null) {
                const dx = if (x > session.press_x) x - session.press_x else session.press_x - x;
                const dy = if (y > session.press_y) y - session.press_y else session.press_y - y;
                // Either axis counts: dragging straight down from the tab bar
                // into a pane is a drag too, not just a sideways one.
                if (@max(dx, dy) < DRAG_THRESHOLD) return; // still a click
                session.drag_tab = from;
            }
            session.drag_x = x;
            var to = from;
            var i: usize = 0;
            while (i < session.tab_count) : (i += 1) {
                const span = session.tab_spans[i];
                if (x >= span[0] and x < span[1]) {
                    to = i;
                    break;
                }
            }
            session.drag_to = to;
            // Over the text area a drop means "split this pane here".
            session.drop_zone = dropZoneAt(session, x, y);
            return;
        }
        if (final == 'm') { // release
            if (session.drag_tab) |f| {
                if (session.drop_zone) |dz| {
                    session.dropTabIntoPane(f, dz);
                } else {
                    session.moveTab(f, session.drag_to);
                }
            }
            session.drag_tab = null;
            session.press_tab = null;
            session.hover_tab = null;
            session.drop_zone = null;
            return;
        }
    }
    const size = term.size();
    if (button == 64 or button == 65) { // wheel up / down
        // Over the tab bar the wheel scrolls the strip instead of the text.
        if (y == 1) {
            session.scrollTabs(if (button == 64) -1 else 1);
            return;
        }
        // Over a pane the wheel scrolls that pane, not the focused one.
        var target = ed;
        if (paneUnder(session, x, y)) |node| {
            if (session.docIndex(session.panes.nodes[node].doc)) |i| target = session.docs.items[i];
        }
        target.movePage(if (button == 64) -1 else 1, 1, false);
        return;
    }
    // Hovering the tab bar shows that tab's name in the status line, and
    // lights up the button under the pointer.
    if (button == 35 or button == 32) {
        session.hover_tab = null;
        session.hover_close = null;
        session.hover_plus = false;
        session.hover_prev = false;
        session.hover_next = false;
        if (y == 1) {
            const col = if (x > 0) @as(u16, x) - 1 else 0;
            if (col == session.tab_prev_x) session.hover_prev = true;
            if (col == session.tab_next_x) session.hover_next = true;
            if (col == session.new_tab_x) session.hover_plus = true;
            var hi: usize = 0;
            while (hi < session.tab_count) : (hi += 1) {
                if (col == session.tab_close_x[hi]) {
                    session.hover_close = hi;
                    break;
                }
            }
            hi = 0;
            while (hi < session.tab_count) : (hi += 1) {
                const span = session.tab_spans[hi];
                if (x >= span[0] and x < span[1]) {
                    session.hover_tab = hi;
                    break;
                }
            }
        }
        if (button == 35) return;
    }

    if (button != 0) return; // primary button only
    // A click is a press. The matching release arrives as its own event and
    // must not act again, or one click toggles a folder twice.
    if (final != 'M') return;

    // File tree: click a row to select it, click again to open or expand.
    if (session.tree) |*t| {
        if (x <= TREE_WIDTH and y >= 2 and y + 1 <= size.rows) {
            const rows = @as(usize, size.rows) - 2;
            t.ensureVisible(rows);
            const idx = t.scroll + (y - 2);
            if (idx < t.count()) {
                const was = idx == t.selected;
                t.selected = idx;
                session.tree_focus = true;
                if (was) openTreeSelection(session, msg_buf, msg);
            }
            return;
        }
    }

    // Tab bar: switch to the tab under the pointer.
    if (y == 1) {
        var i: usize = 0;
        while (i < session.tab_count) : (i += 1) {
            const span = session.tab_spans[i];
            if (x >= span[0] and x < span[1]) {
                session.focusDoc(i);
                return;
            }
        }
        return;
    }

    // Status line: the right-hand help hint toggles the panel.
    if (y == size.rows and size.cols > 10 and x + 10 > size.cols) {
        help.* = !help.*;
        return;
    }

    // Text: focus the pane under the pointer and place the cursor in it.
    if (y < 2 or y >= size.rows) return;
    const sx = if (x > 0) @as(usize, x) - 1 else 0;
    const sy = @as(usize, y) - 1;
    const node = paneUnder(session, x, y) orelse return;
    session.focusPane(node);
    const rect = session.panes.rectOf(node) orelse return;
    const target = session.current();
    const gutter: usize = if (session.config.line_numbers) digits(target.lineCount()) + 1 else 0;
    const row = target.scroll_row + (sy - rect.y);
    const col = if (sx >= rect.x + gutter) sx - rect.x - gutter + target.scroll_col else 0;
    target.gotoLineCol(row, col);
}

/// Housekeeping on an idle tick: the file tree follows the disk, and clean
/// buffers reload when their file changes underneath us.
/// Mark every cell as needing a repaint, so the next frame paints all of it.
/// The sentinel is a cell no real frame produces (reverse + bold + underline on
/// a NUL), so it never compares equal to what `draw` puts in the back buffer.
fn dirtyAll(s: *render.Screen) void {
    @memset(s.front, render.Cell{ .ch = 0, .attr = .{ .bold = true, .underline = true, .reverse = true } });
}

fn refreshFromDisk(session: *Session, msg_buf: []u8, msg: *[]const u8) bool {
    var changed = false;
    if (session.tree) |*t| {
        if (t.refreshIfChanged()) changed = true;
    }
    for (session.docs.items) |ed| {
        if (ed.reloadIfChanged()) {
            changed = true;
            // Say so in the status line: a reload that happened while the
            // window was in the background is then visible the moment the
            // user looks back at it.
            var line: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "reloaded {s} from disk", .{baseName(ed.path orelse "")}) catch "reloaded from disk";
            setMsg(msg_buf, msg, text);
        }
    }
    return changed;
}

/// Split a configured command into argv, replacing `{file}` with the path so
/// tools can pick a parser. Arguments are stored in `buf`.
fn buildArgv(cmd: []const u8, file: []const u8, out: *[16][]const u8, buf: []u8) usize {
    var n: usize = 0;
    var b: usize = 0;
    var i: usize = 0;
    while (i < cmd.len and n < out.len) {
        while (i < cmd.len and (cmd[i] == ' ' or cmd[i] == '\t')) i += 1;
        if (i >= cmd.len) break;
        const start = b;
        while (i < cmd.len and cmd[i] != ' ' and cmd[i] != '\t') {
            if (cmd[i] == '{' and i + 6 <= cmd.len and std.mem.eql(u8, cmd[i .. i + 6], "{file}")) {
                for (file) |c| {
                    if (b < buf.len) {
                        buf[b] = c;
                        b += 1;
                    }
                }
                i += 6;
            } else {
                if (b < buf.len) {
                    buf[b] = cmd[i];
                    b += 1;
                }
                i += 1;
            }
        }
        out[n] = buf[start..b];
        n += 1;
    }
    return n;
}

/// Run the formatter configured for this file and replace the buffer with what
/// it prints. Every failure is reported in the status line rather than being
/// silent.
fn formatBuffer(session: *Session, msg_buf: []u8, msg: *[]const u8) void {
    const ed = session.current();
    const path = ed.path orelse {
        setMsg(msg_buf, msg, "Save the file first: no formatter for an untitled buffer");
        return;
    };
    const cmd = session.config.formatCommandFor(path) orelse {
        setMsg(msg_buf, msg, "No formatter configured for this file type");
        return;
    };
    var argv_buf: [16][]const u8 = undefined;
    var text_buf: [1024]u8 = undefined;
    const argc = buildArgv(cmd, path, &argv_buf, &text_buf);
    if (argc == 0) {
        setMsg(msg_buf, msg, "Formatter command is empty");
        return;
    }
    var out = std.ArrayList(u8).empty;
    defer out.deinit(session.allocator);
    const state_dir = g_session_dir orelse ".";
    const res = os.runCommand(session.allocator, state_dir, argv_buf[0..argc], ed.text(), &out, 10_000) catch |e| {
        var why: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&why, "Could not start the formatter ({s})", .{@errorName(e)}) catch "Could not start the formatter";
        setMsg(msg_buf, msg, line);
        return;
    };
    if (res.timed_out) {
        setMsg(msg_buf, msg, "Formatter timed out");
        return;
    }
    if (res.exit_code != 0) {
        setMsg(msg_buf, msg, "Formatter failed");
        return;
    }
    if (out.items.len == 0) {
        setMsg(msg_buf, msg, "Formatter produced no output");
        return;
    }
    if (std.mem.eql(u8, out.items, ed.text())) {
        setMsg(msg_buf, msg, "Already formatted");
        return;
    }
    ed.replaceText(out.items) catch {
        setMsg(msg_buf, msg, "Could not apply the formatted text");
        return;
    };
    setMsg(msg_buf, msg, "Formatted");
}

/// The pane under a 1-based screen cell, if any.
fn paneUnder(session: *Session, x: u16, y: u16) ?u8 {
    if (x == 0 or y < 2) return null;
    return session.panes.paneAt(@as(usize, x) - 1, @as(usize, y) - 1);
}

/// Which half of which pane the pointer is over: the left and right thirds
/// split side by side, the middle falls back to top or bottom.
fn dropZoneAt(session: *Session, x: u16, y: u16) ?DropZone {
    const node = paneUnder(session, x, y) orelse return null;
    const r = session.panes.rectOf(node) orelse return null;
    if (r.w < 2 or r.h < 2) return null;
    const rx = (@as(usize, x) - 1) - r.x;
    const ry = (@as(usize, y) - 1) - r.y;
    const side: DropSide = if (rx * 3 < r.w)
        .left
    else if (rx * 3 >= r.w * 2)
        .right
    else if (ry * 2 < r.h)
        .top
    else
        .bottom;
    return .{ .node = node, .side = side };
}

/// Outline the half of the pane where a dragged tab would land.
fn drawDropHint(s: *render.Screen, session: *Session, dz: DropZone, theme: config_mod.Theme) void {
    const r = session.panes.rectOf(dz.node) orelse return;
    const rect: panes_mod.Rect = switch (dz.side) {
        .left => .{ .x = r.x, .y = r.y, .w = (r.w + 1) / 2, .h = r.h },
        .right => .{ .x = r.x + r.w / 2, .y = r.y, .w = r.w - r.w / 2, .h = r.h },
        .top => .{ .x = r.x, .y = r.y, .w = r.w, .h = (r.h + 1) / 2 },
        .bottom => .{ .x = r.x, .y = r.y + r.h / 2, .w = r.w, .h = r.h - r.h / 2 },
    };
    if (rect.w == 0 or rect.h == 0) return;
    // Invert the area: the text keeps its own colour, only the background
    // becomes the highlight colour, so the drop target reads at a glance.
    const bg = theme.selection;
    var y = rect.y;
    while (y < rect.y + rect.h) : (y += 1) {
        var x = rect.x;
        while (x < rect.x + rect.w) : (x += 1) {
            if (x >= s.cols or y >= s.rows) break;
            const cur = s.back[y * s.cols + x];
            s.put(@intCast(x), @intCast(y), .{
                .ch = cur.ch,
                .fg = cur.fg,
                .bg = bg,
                .cont = cur.cont,
                .attr = cur.attr,
            });
        }
    }
}

/// Rows available for document text: everything but the tab bar and status line.
fn viewRows(rows: u16) usize {
    return if (rows > 2) @as(usize, rows) - 2 else 0;
}

/// The default key for an action: byte for editing commands, CSI for
/// movements. The key map translates user bindings into these.
const DefaultKey = union(enum) {
    byte: u8,
    csi: struct { params: []const u8, final: u8 },
};

fn moveCsi(final: u8, shift: bool) DefaultKey {
    return .{ .csi = .{ .params = if (shift) "1;2" else "", .final = final } };
}

fn defaultKeyFor(action: keys.Action, shift: bool) DefaultKey {
    return switch (action) {
        .save => .{ .byte = 0x13 },
        .open => .{ .byte = 0x0f },
        .quit => .{ .byte = 0x11 },
        .new_tab => .{ .byte = 0x14 },
        .close_tab => .{ .byte = 0x17 },
        .select_all => .{ .byte = 0x01 },
        .copy => .{ .byte = 0x03 },
        .cut => .{ .byte = 0x18 },
        .paste => .{ .byte = 0x16 },
        .find => .{ .byte = 0x06 },
        .replace => .{ .byte = 0x12 },
        .goto => .{ .byte = 0x07 },
        .duplicate_line => .{ .byte = 0x04 },
        .undo => .{ .byte = 0x1a },
        .redo => .{ .byte = 0x19 },
        .insert_newline => .{ .byte = 0x0d },
        .insert_tab => .{ .byte = 0x09 },
        .backspace => .{ .byte = 0x7f },
        .help => .{ .byte = 0x1f },
        .theme_picker => .{ .csi = .{ .params = "", .final = 'Q' } },
        .command_palette => .{ .byte = 0x10 },
        .clear_selection => .{ .byte = 0x1b },
        .move_up => moveCsi('A', shift),
        .move_down => moveCsi('B', shift),
        .move_left => moveCsi('D', shift),
        .move_right => moveCsi('C', shift),
        .move_word_left => .{ .csi = .{ .params = if (shift) "1;6" else "1;5", .final = 'D' } },
        .move_word_right => .{ .csi = .{ .params = if (shift) "1;6" else "1;5", .final = 'C' } },
        .move_home => moveCsi('H', shift),
        .move_end => moveCsi('F', shift),
        .page_up => .{ .csi = .{ .params = if (shift) "5;2" else "5", .final = '~' } },
        .page_down => .{ .csi = .{ .params = if (shift) "6;2" else "6", .final = '~' } },
        .delete_forward => .{ .csi = .{ .params = "3", .final = '~' } },
        .find_next => moveCsi('R', false),
        .find_prev => moveCsi('R', true),
        .next_tab => .{ .csi = .{ .params = "6;5", .final = '~' } },
        .prev_tab => .{ .csi = .{ .params = "5;5", .final = '~' } },
        .split_columns => .{ .csi = .{ .params = "15", .final = '~' } }, // F5
        .close_pane => .{ .csi = .{ .params = if (shift) "18;2" else "15;2", .final = '~' } }, // Shift+F5 / Shift+F7
        .format => .{ .csi = .{ .params = "14", .final = '~' } }, // F4
        .add_cursor_below => .{ .csi = .{ .params = "1;7", .final = 'B' } }, // Ctrl+Alt+Down
        .add_cursor_above => .{ .csi = .{ .params = "1;7", .final = 'A' } }, // Ctrl+Alt+Up
        .split_rows => .{ .csi = .{ .params = "18", .final = '~' } }, // F7
        .next_pane => .{ .csi = .{ .params = "17", .final = '~' } }, // F6
        .prev_pane => .{ .csi = .{ .params = if (shift) "17;2" else "17;5", .final = '~' } },
    };
}

const ctrl_names = [_][]const u8{
    "ctrl+a", "ctrl+b", "ctrl+c", "ctrl+d", "ctrl+e", "ctrl+f", "ctrl+g",
    "ctrl+h", "ctrl+i", "ctrl+j", "ctrl+k", "ctrl+l", "ctrl+m", "ctrl+n",
    "ctrl+o", "ctrl+p", "ctrl+q", "ctrl+r", "ctrl+s", "ctrl+t", "ctrl+u",
    "ctrl+v", "ctrl+w", "ctrl+x", "ctrl+y", "ctrl+z",
};

/// Canonical name of a single-byte key, or null for text input.
fn keyNameByte(b: u8) ?[]const u8 {
    return switch (b) {
        0x01...0x07 => ctrl_names[b - 1],
        0x08 => "backspace",
        0x09 => "tab",
        0x0a, 0x0d => "enter",
        0x0b, 0x0c => ctrl_names[b - 1],
        0x0e...0x1a => ctrl_names[b - 1],
        0x1b => "esc",
        0x1f => "ctrl+?",
        0x7f => "backspace",
        else => null,
    };
}

/// Canonical name of a CSI sequence (e.g. "shift+up"), or null.
fn csiKeyName(buf: []u8, params_bytes: []const u8, final: u8) ?[]const u8 {
    var params: [4]u16 = .{ 0, 0, 0, 0 };
    var np: usize = 0;
    for (params_bytes) |c| {
        if (c >= '0' and c <= '9') {
            params[np] = params[np] * 10 + (c - '0');
        } else if (c == ';') {
            if (np < params.len - 1) np += 1;
        }
    }
    const p0 = params[0];
    const m: u16 = if (np >= 1 and params[1] != 0) params[1] else 1;
    const bits = m - 1;
    const shift = (bits & 1) != 0;
    const ctrl = (bits & 4) != 0;
    const base: []const u8 = switch (final) {
        'A' => "up",
        'B' => "down",
        'C' => "right",
        'D' => "left",
        'H' => "home",
        'F' => "end",
        'R' => "f3",
        'P' => "f1",
        'Q' => "f2",
        '~' => switch (p0) {
            1, 7 => "home",
            4, 8 => "end",
            3 => "delete",
            2 => "insert",
            5 => "pgup",
            6 => "pgdn",
            11 => "f1",
            12 => "f2",
            14 => "f4",
            15 => "f5",
            17 => "f6",
            18 => "f7",
            else => return null,
        },
        else => return null,
    };
    const alt = (bits & 2) != 0;
    var n: usize = 0;
    if (ctrl) {
        @memcpy(buf[n..][0..5], "ctrl+");
        n += 5;
    }
    if (alt) {
        @memcpy(buf[n..][0..4], "alt+");
        n += 4;
    }
    if (shift) {
        @memcpy(buf[n..][0..6], "shift+");
        n += 6;
    }
    for (base) |c| {
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

fn applyByte(
    session: *Session,
    b: u8,
    running: *bool,
    prompt: *?Prompt,
    msg_buf: []u8,
    msg: *[]const u8,
    help: *bool,
    view_rows: usize,
    remap: bool,
) anyerror!void {
    if (remap) {
        if (keyNameByte(b)) |name| {
            if (session.config.keys.lookup(name)) |action| {
                const shift = std.mem.indexOf(u8, name, "shift+") != null;
                switch (defaultKeyFor(action, shift)) {
                    .byte => |target| if (target != b) return applyByte(session, target, running, prompt, msg_buf, msg, help, view_rows, false),
                    .csi => |c| return applyCsi(session, c.params, c.final, view_rows, running, prompt, msg_buf, msg, help, false),
                }
                return;
            }
        }
    }
    const ed = session.current();
    if (b == 0x13) { // Ctrl+S: save, or ask for a name
        if (session.config.format_on_save and ed.path != null) formatBuffer(session, msg_buf, msg);
        if (ed.path == null) {
            prompt.* = .{ .kind = .save_as };
        } else ed.save() catch |e| {
            setErrMsg(msg_buf, msg, "Save failed", e);
        };
    } else if (b == 0x14) { // Ctrl+T: new empty tab
        try session.add(null, "", null);
        setMsg(msg_buf, msg, "New tab");
    } else if (b == 0x17) { // Ctrl+W: close the tab; closing the last one quits
        if (ed.dirty) {
            prompt.* = .{ .kind = .confirm_close };
        } else {
            session.closeActive();
            if (session.count() == 0) running.* = false;
        }
    } else if (b == 0x1c) { // Ctrl+\: split the pane side by side
        try session.splitFocused(.columns);
        setMsg(msg_buf, msg, "Split");
    } else if (b == 0x02) { // Ctrl+B: file tree
        if (session.tree != null) {
            session.tree_focus = false;
            session.tree.?.deinit();
            session.tree = null;
        } else {
            const dir = if (session.current().path) |p| promptDir(p) else ".";
            session.tree = tree_mod.Tree.init(session.allocator, dir) catch null;
            session.tree_focus = session.tree != null;
        }
    } else if (b == 0x10) { // Ctrl+P: command palette
        session.ui_request = .command_palette;
    } else if (b == 0x0f) { // Ctrl+O: open the file picker
        session.ui_request = .open_picker;
    } else if (b == 0x11) { // Ctrl+Q: confirm first if any tab is dirty
        if (session.anyDirty()) {
            prompt.* = .{ .kind = .confirm_quit };
        } else running.* = false;
    } else if (b == 0x01) { // Ctrl+A
        ed.selectAll();
    } else if (b == 0x03) { // Ctrl+C
        try ed.copy();
        setMsg(msg_buf, msg, "Copied");
        try sendOsc52(session.current().registerText());
    } else if (b == 0x18) { // Ctrl+X
        try ed.cut();
        setMsg(msg_buf, msg, "Cut");
        try sendOsc52(session.current().registerText());
    } else if (b == 0x16) { // Ctrl+V
        try ed.paste();
    } else if (b == 0x06) { // Ctrl+F: find
        prompt.* = .{ .kind = .find, .origin = session.current().cursor };
    } else if (b == 0x12) { // Ctrl+R: replace
        prompt.* = .{ .kind = .replace_find, .origin = session.current().cursor };
    } else if (b == 0x07) { // Ctrl+G: go to line
        prompt.* = .{ .kind = .goto };
    } else if (b == 0x04) { // Ctrl+D
        try ed.duplicateLine();
    } else if (b == 0x1a) { // Ctrl+Z
        try ed.undo();
    } else if (b == 0x19) { // Ctrl+Y
        try ed.redo();
    } else if (b == 0x0d or b == 0x0a) {
        try ed.insertText("\n");
    } else if (b == 0x09) {
        try ed.insertText("    ");
    } else if (b == 0x7f or b == 0x08) {
        try ed.backspace();
    } else if (b == 0x1f) {
        help.* = !help.*;
    } else if (b == 0x1b) {
        // Esc closes the help panel, then drops extra cursors, then clears the
        // selection.
        if (help.*) {
            help.* = false;
        } else if (ed.hasCursors()) {
            ed.clearCursors();
        } else {
            ed.clearSelection();
        }
    } else if (b >= 0x20) {
        const one = [1]u8{b};
        try ed.insertText(&one);
    }
}

/// Consume an escape sequence starting at `buf[i]` (which holds ESC). Returns
/// the index just past it, or null when the sequence is truncated and the rest
/// has not arrived yet.
fn skipEscape(buf: []const u8, i: usize) ?usize {
    if (buf[i + 1] == '[') {
        var j = i + 2;
        while (j < buf.len and !(buf[j] >= 0x40 and buf[j] <= 0x7E)) j += 1;
        if (j >= buf.len) return null; // no final byte yet
        return j + 1;
    }
    // ESC O x (SS3)
    if (i + 2 >= buf.len) return null;
    return i + 3;
}

fn handlePromptInput(
    session: *Session,
    registry: *syntax.Registry,
    slot: *?Prompt,
    buf: []const u8,
    running: *bool,
    msg_buf: []u8,
    msg: *[]const u8,
) !usize {
    var i: usize = 0;
    while (i < buf.len) {
        const b = buf[i];
        const p = &slot.*.?;
        if (b == 0x1b) {
            // Arrow/function keys arrive as escape sequences; they are not
            // prompt input. Consume them instead of reading ESC as "cancel"
            // (which used to close the Open prompt on any arrow key).
            if (i + 1 < buf.len and (buf[i + 1] == '[' or buf[i + 1] == 'O')) {
                const next = skipEscape(buf, i) orelse return i; // hold the partial sequence
                i = next;
                continue;
            }
            if (p.kind == .find or p.kind == .replace_find) session.current().cursor = p.origin;
            slot.* = null;
            return i + 1;
        }
        if (b == 0x0d or b == 0x0a) {
            // Enter on a yes/no question means the default answer: no.
            if (p.kind == .confirm_quit or p.kind == .confirm_close) {
                slot.* = null;
                return i + 1;
            }
            const close = try executePrompt(session, registry, p, msg_buf, msg);
            if (close) {
                slot.* = null;
                return i + 1;
            }
            i += 1;
            continue; // replace: now asking for the replacement
        }
        if (b == 0x12 and (p.kind == .find or p.kind == .replace_find or p.kind == .replace_with)) {
            // Ctrl+R inside a search prompt toggles regular expressions.
            const ed = session.current();
            ed.search_regex = !ed.search_regex;
            if (p.len > 0) ed.setSearch(p.buf[0..p.len]) catch {};
            setMsg(msg_buf, msg, if (ed.search_regex) "regex on" else "regex off");
            i += 1;
            continue;
        }
        if (b == 0x7f or b == 0x08) {
            if (p.len > 0) p.len -= 1;
        } else if (b == 0x09) {
            if (p.kind == .save_as or p.kind == .open) try completePath(session.current().allocator, p);
        } else if (b >= 0x20 and p.len < p.buf.len) {
            switch (p.kind) {
                .confirm_quit => {
                    if (b == 'y' or b == 'Y') running.* = false;
                    slot.* = null;
                    return i + 1;
                },
                .confirm_close => {
                    if (b == 'y' or b == 'Y') {
                        session.closeActive();
                        if (session.count() == 0) running.* = false;
                    }
                    slot.* = null;
                    return i + 1;
                },
                else => {
                    p.buf[p.len] = b;
                    p.len += 1;
                },
            }
        }
        if (p.kind == .find or p.kind == .replace_find) try liveSearch(session.current(), p);
        i += 1;
    }
    return i;
}

/// As the find text changes, jump to the first match from where we started.
fn liveSearch(ed: *Editor, p: *Prompt) !void {
    const needle = p.buf[0..p.len];
    try ed.setSearch(needle);
    if (needle.len == 0) {
        ed.cursor = p.origin;
        return;
    }
    if (ed.findFrom(p.origin)) |pos| ed.cursor = pos;
}

/// Run the prompt's action. Returns whether the prompt should close.
fn executePrompt(
    session: *Session,
    registry: *syntax.Registry,
    p: *Prompt,
    msg_buf: []u8,
    msg: *[]const u8,
) !bool {
    const text = p.buf[0..p.len];
    const ed = session.current();
    switch (p.kind) {
        .save_as => {
            if (text.len == 0) return true;
            ed.saveAs(text) catch |e| {
                setErrMsg(msg_buf, msg, "Save failed", e);
                return true;
            };
            ed.setLanguage(registry.find(text));
            setMsg(msg_buf, msg, "Saved");
            return true;
        },
        .open => {
            if (text.len == 0) return true;
            const allocator = std.heap.page_allocator;
            const data = os.readFileAlloc(allocator, text, MAX_FILE) catch |e| {
                setErrMsg(msg_buf, msg, "Cannot open", e);
                return true;
            };
            defer allocator.free(data);
            // Already open: switch to that tab rather than opening it twice.
            if (session.findByPath(text)) |idx| {
                session.focusDoc(idx);
                setMsg(msg_buf, msg, "Switched");
                return true;
            }
            // A fresh `mibi` (one empty, unnamed, clean tab) opens in place.
            if (session.count() == 1 and ed.path == null and !ed.dirty and session.current().text().len == 0) {
                try ed.replaceContents(data);
                try ed.setPath(text);
                ed.setLanguage(registry.find(text));
                setMsg(msg_buf, msg, "Opened");
                return true;
            }
            try session.add(text, data, registry.find(text));
            setMsg(msg_buf, msg, "Opened");
            return true;
        },
        // Yes/no prompts are answered in handlePromptInput, never here.
        .confirm_quit, .confirm_close => return true,
        .find => {
            try ed.setSearch(text);
            return true;
        },
        .replace_find => {
            const n = @min(p.find_buf.len, text.len);
            @memcpy(p.find_buf[0..n], text[0..n]);
            p.find_len = n;
            p.len = 0;
            p.kind = .replace_with;
            return false; // keep the prompt open for the replacement
        },
        .replace_with => {
            const n = try ed.replaceAll(p.find_buf[0..p.find_len], text);
            var tmp: [32]u8 = undefined;
            const m = std.fmt.bufPrint(&tmp, "{d} replaced", .{n}) catch "replaced";
            setMsg(msg_buf, msg, m);
            return true;
        },
        .goto => {
            var line: usize = 0;
            var col: usize = 0;
            var idx: usize = 0;
            while (idx < text.len and text[idx] >= '0' and text[idx] <= '9') : (idx += 1) {
                line = line * 10 + (text[idx] - '0');
            }
            if (idx < text.len and text[idx] == ':') {
                idx += 1;
                while (idx < text.len and text[idx] >= '0' and text[idx] <= '9') : (idx += 1) {
                    col = col * 10 + (text[idx] - '0');
                }
            }
            if (line > 0) ed.gotoLineCol(line - 1, if (col > 0) col - 1 else 0);
            return true;
        },
    }
}

/// Apply a CSI sequence given its parameter bytes and final byte.
fn applyCsi(
    session: *Session,
    params_bytes: []const u8,
    final: u8,
    view_rows: usize,
    running: *bool,
    prompt: *?Prompt,
    msg_buf: []u8,
    msg: *[]const u8,
    help: *bool,
    remap: bool,
) anyerror!void {
    if (remap) {
        var name_buf: [32]u8 = undefined;
        if (csiKeyName(&name_buf, params_bytes, final)) |name| {
            if (session.config.keys.lookup(name)) |action| {
                const shift = std.mem.indexOf(u8, name, "shift+") != null;
                switch (defaultKeyFor(action, shift)) {
                    .byte => |target| return applyByte(session, target, running, prompt, msg_buf, msg, help, view_rows, false),
                    .csi => |c| return applyCsi(session, c.params, c.final, view_rows, running, prompt, msg_buf, msg, help, false),
                }
            }
        }
    }
    const ed = session.current();
    var params: [4]u16 = .{ 0, 0, 0, 0 };
    var np: usize = 0;
    for (params_bytes) |c| {
        if (c >= '0' and c <= '9') {
            params[np] = params[np] * 10 + (c - '0');
        } else if (c == ';') {
            if (np < params.len - 1) np += 1;
        }
    }
    const p0 = params[0];
    const m: u16 = if (np >= 1 and params[1] != 0) params[1] else 1;
    const bits = m - 1;
    const shift = (bits & 1) != 0;
    const alt = (bits & 2) != 0;
    const ctrl = (bits & 4) != 0;
    switch (final) {
        'Q' => session.ui_request = .theme_picker,
        'A' => if (ctrl and alt) {
            _ = ed.addCursor(-1);
        } else ed.moveUp(shift),
        'B' => if (ctrl and alt) {
            _ = ed.addCursor(1);
        } else ed.moveDown(shift),
        'C' => if (ctrl) ed.moveWordRight(shift) else ed.moveRight(shift),
        'D' => if (ctrl) ed.moveWordLeft(shift) else ed.moveLeft(shift),
        'H' => ed.moveHome(shift),
        'F' => ed.moveEnd(shift),
        'R' => if (shift) ed.findPrev() else ed.findNext(),
        'P' => help.* = !help.*, // F1
        '~' => switch (p0) {
            1, 7 => ed.moveHome(shift),
            4, 8 => ed.moveEnd(shift),
            3 => try ed.deleteForward(),
            11 => help.* = !help.*, // F1
            5 => if (ctrl) session.cycle(-1) else ed.movePage(-1, view_rows, shift),
            6 => if (ctrl) session.cycle(1) else ed.movePage(1, view_rows, shift),
            14 => formatBuffer(session, msg_buf, msg), // F4: format
            15 => if (shift) session.closePane() else try session.splitFocused(.columns), // F5 / Shift+F5
            17 => session.cyclePane(if (shift) -1 else 1), // F6 / Shift+F6
            18 => if (shift) session.closePane() else try session.splitFocused(.rows), // F7 / Shift+F7
            else => {},
        },
        else => {},
    }
}

// --- OSC 52 clipboard ----------------------------------------------------

const b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const out_len = ((data.len + 2) / 3) * 4;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    var i: usize = 0;
    var o: usize = 0;
    while (i + 3 <= data.len) : (i += 3) {
        const n = (@as(u32, data[i]) << 16) | (@as(u32, data[i + 1]) << 8) | data[i + 2];
        out[o] = b64_chars[(n >> 18) & 63];
        out[o + 1] = b64_chars[(n >> 12) & 63];
        out[o + 2] = b64_chars[(n >> 6) & 63];
        out[o + 3] = b64_chars[n & 63];
        o += 4;
    }
    const rem = data.len - i;
    if (rem == 1) {
        const n = @as(u32, data[i]) << 16;
        out[o] = b64_chars[(n >> 18) & 63];
        out[o + 1] = b64_chars[(n >> 12) & 63];
        out[o + 2] = '=';
        out[o + 3] = '=';
    } else if (rem == 2) {
        const n = (@as(u32, data[i]) << 16) | (@as(u32, data[i + 1]) << 8);
        out[o] = b64_chars[(n >> 18) & 63];
        out[o + 1] = b64_chars[(n >> 12) & 63];
        out[o + 2] = b64_chars[(n >> 6) & 63];
        out[o + 3] = '=';
    }
    return out;
}

/// Put `text` on the system clipboard via OSC 52 (best effort; capped size).
fn sendOsc52(text: []const u8) !void {
    if (text.len == 0) return;
    if (!term.isTty()) return; // don't spew OSC into pipes or tests
    const allocator = std.heap.page_allocator;
    const slice = text[0..@min(text.len, 96 * 1024)];
    const b64 = try base64Encode(allocator, slice);
    defer allocator.free(b64);
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, "\x1b]52;c;");
    try list.appendSlice(allocator, b64);
    try list.append(allocator, 0x07);
    try term.write(list.items);
}

// --- rendering -----------------------------------------------------------

fn digits(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

/// Colour for a syntax class; plain text keeps the editor's normal colour.
fn syntaxColor(class: syntax.Class, theme: config_mod.Theme) render.Color {
    return switch (class) {
        .normal => theme.text,
        .comment, .ml_comment => theme.comment,
        .keyword1 => theme.keyword1,
        .keyword2 => theme.keyword2,
        .string, .ml_string => theme.string,
        .number => theme.number,
    };
}

fn draw(s: *render.Screen, session: *Session, msg: []const u8, prompt: ?Prompt, help: bool) void {
    s.clear();
    const w: usize = s.cols;
    const h: usize = s.rows;
    if (h < 3 or w < 4) return;

    const theme = session.config.theme;
    const text_fg = theme.text;
    const bar_bg = theme.bar_bg;
    const accent = theme.accent;
    const hint_bg = theme.hint_bg;
    const hint_fg = theme.hint_fg;

    if (theme.background != .default) {
        var by: usize = 0;
        while (by < h) : (by += 1) {
            var bx: usize = 0;
            while (bx < w) : (bx += 1) s.put(@intCast(bx), @intCast(by), .{ .bg = theme.background });
        }
    }

    drawTabBar(s, session, w, text_fg, theme.gutter);
    const side = sidebarWidth(session);
    if (session.tree) |*t| drawTree(s, t, session.tree_focus, h, theme, session.config.icons_unicode);

    // The text area, split into panes. Row 0 is the tab bar, row h-1 the
    // status line; the sidebar takes the left columns.
    const area = panes_mod.Rect{
        .x = side,
        .y = 1,
        .w = if (w > side) w - side else 0,
        .h = h - 2,
    };
    session.pane_area = area;
    session.panes.layout(area);
    // Drawing another pane borrows the editor and moves its cursor, so the
    // focused pane's own state is captured and put back afterwards.
    const live_ed = session.current();
    const live_view = .{ .cursor = live_ed.cursor, .row = live_ed.scroll_row, .col = live_ed.scroll_col };
    var focused_view: ?struct { cursor: usize, row: usize, col: usize } = null;
    var pi: usize = 0;
    while (pi < session.panes.rect_count) : (pi += 1) {
        const pr = session.panes.rects[pi];
        const idx = session.docIndex(session.panes.nodes[pr.node].doc) orelse continue;
        const ed = session.docs.items[idx];
        const focused = pr.node == session.panes.focus;
        if (focused) {
            // Another pane may have borrowed the editor: put the live view
            // back before drawing the pane that owns it.
            ed.cursor = live_view.cursor;
            ed.scroll_row = live_view.row;
            ed.scroll_col = live_view.col;
        }
        drawPane(s, session, ed, pr.rect, pr.node, focused);
        if (focused) {
            focused_view = .{ .cursor = ed.cursor, .row = ed.scroll_row, .col = ed.scroll_col };
        }
    }
    if (focused_view) |v| {
        const ed = session.current();
        ed.cursor = v.cursor;
        ed.scroll_row = v.row;
        ed.scroll_col = v.col;
    }
    if (session.drag_tab == null) session.drop_zone = null;
    if (session.drop_zone) |dz| drawDropHint(s, session, dz, theme);
    // Separators; the ones beside the focused pane glow in the accent colour.
    const focus_rect = session.panes.rectOf(session.panes.focus);
    pi = 0;
    while (pi < session.panes.sep_count) : (pi += 1) {
        const sp = session.panes.seps[pi];
        var hot = false;
        if (focus_rect) |fr| {
            hot = if (sp.dir == .columns)
                (fr.x == sp.x + 1 or fr.x + fr.w == sp.x)
            else
                (fr.y == sp.y + 1 or fr.y + fr.h == sp.y);
        }
        const fg = if (hot) accent else theme.gutter;
        if (sp.dir == .columns) {
            var k: usize = 0;
            while (k < sp.len) : (k += 1) {
                s.put(@intCast(sp.x), @intCast(sp.y + k), .{ .ch = '\u{2502}', .fg = fg, .bg = theme.background });
            }
        } else {
            var k: usize = 0;
            while (k < sp.len) : (k += 1) {
                s.put(@intCast(sp.x + k), @intCast(sp.y), .{ .ch = '\u{2500}', .fg = fg, .bg = theme.background });
            }
        }
    }

    if (prompt) |p| {
        // One line of the directory being typed, like `ls` (paths only).
        if ((p.kind == .save_as or p.kind == .open) and h >= 3) {
            var line = std.ArrayList(u8).empty;
            defer line.deinit(s.allocator);
            const dir = promptDir(p.buf[0..p.len]);
            os.listDirLine(s.allocator, dir, &line) catch {};
            const y: u16 = @intCast(h - 2);
            var hx: usize = 0;
            while (hx < w) : (hx += 1) s.put(@intCast(hx), y, .{ .bg = hint_bg });
            const show = line.items[0..@min(line.items.len, w)];
            s.putStr(0, y, show, .{ .bg = hint_bg, .fg = hint_fg });
        }
        drawPrompt(s, p, w, h, bar_bg, accent, text_fg);
    } else {
        var status_msg = msg;
        if (session.hover_tab) |hi| {
            if (hi < session.docs.items.len) {
                // The name only: long paths look bad in the status line.
                if (session.docs.items[hi].path) |hp| status_msg = baseName(hp);
            }
        }
        // The status line always describes the focused pane's document.
        const active = session.current();
        drawStatus(s, active, status_msg, w, h, active.rowCol(), active.lineCount(), bar_bg, accent, hint_fg);
    }

    // The help panel covers the bottom rows, so a prompt (which lives on the
    // last row) takes precedence over it while it is open.
    if (help and prompt == null) drawHelp(s, session, w, h, theme);
}

/// Draw one pane's document inside `r`. Only the focused pane draws the block
/// cursor and the current-line tint, so the focus is visible even when the
/// panes are narrow.
fn drawPane(s: *render.Screen, session: *Session, ed: *Editor, r: panes_mod.Rect, node: u8, focused: bool) void {
    if (r.w == 0 or r.h == 0) return;
    const theme = session.config.theme;
    // A pane that is not focused draws its own stored view of the document.
    if (!focused) {
        const n = session.panes.nodes[node];
        ed.cursor = @min(n.view_cursor, ed.text().len);
        ed.scroll_row = n.view_row;
        ed.scroll_col = n.view_col;
    }
    const total = ed.lineCount();
    const gutter: usize = if (session.config.line_numbers) digits(total) + 1 else 0;
    const text_cols: usize = if (r.w > gutter + 1) r.w - gutter - 1 else 0;
    ed.scrollToCursor(r.h, text_cols);

    const right = r.x + r.w;
    const gutter_fg = theme.gutter;
    const text_fg = theme.text;
    const sel_bg = theme.selection;
    const sel = ed.selectionRange();
    const rc = ed.rowCol();
    const line_bg = theme.lineHighlight();
    const cur_dcol = ed.cursorDisplayCol();

    // Syntax state at the top of the viewport, carried down the visible rows.
    var syn_state = ed.syntaxStateAt(ed.scroll_row);
    var spans: [syntax.MAX_SPANS]syntax.Span = undefined;

    var row: usize = 0;
    while (row < r.h) : (row += 1) {
        const y: u16 = @intCast(r.y + row);
        const lr = ed.scroll_row + row;
        if (lr >= total) break;
        const line = ed.line(lr);
        const line_start = ed.rowStart(lr);
        const line_end = line_start + line.len;
        const nspans = ed.highlightLine(lr, &syn_state, &spans);
        const cursor_line = focused and lr == rc.row and std.meta.activeTag(line_bg) != .default;
        const row_bg = if (cursor_line) line_bg else theme.background;
        if (cursor_line) {
            var cx: usize = r.x; // the pane's own columns only
            while (cx < right) : (cx += 1) s.put(@intCast(cx), y, .{ .ch = ' ', .bg = line_bg });
        }

        // Gutter.
        if (gutter > 0) {
            var num_buf: [24]u8 = undefined;
            const num = std.fmt.bufPrint(&num_buf, "{d}", .{lr + 1}) catch "";
            const gx = gutter - 1;
            var k: usize = 0;
            while (k + num.len < gx) : (k += 1) s.put(@intCast(r.x + k), y, .{ .ch = ' ', .bg = row_bg });
            s.putStr(@intCast(r.x + gx - num.len), y, num, .{ .fg = gutter_fg, .bg = row_bg });
        }

        // Text (wide characters take two cells; the second is marked cont).
        var dcol: usize = 0;
        var sx: usize = r.x + gutter;
        var bi: usize = 0;
        var span_i: usize = 0;
        while (bi < line.len) {
            const cp_start = bi;
            const cp = utf8.nextCp(line, &bi);
            const selected = if (sel) |sr| (cp_start >= sr.start and cp_start < sr.end) else false;
            while (span_i < nspans and spans[span_i].end <= cp_start) span_i += 1;
            const cls: syntax.Class = if (span_i < nspans and cp_start >= spans[span_i].start)
                spans[span_i].class
            else
                .normal;
            const fg = syntaxColor(cls, theme);
            if (cp == '\r') continue; // CRLF: the CR is never drawn (or counted)
            if (cp == '\t') {
                const tab = ed.tab_width;
                const next = (dcol / tab + 1) * tab;
                while (dcol < next) : (dcol += 1) {
                    if (dcol >= ed.scroll_col) {
                        var cell = render.Cell{ .ch = ' ', .fg = fg, .bg = row_bg };
                        if (selected) cell.bg = sel_bg;
                        s.put(@intCast(sx), y, cell);
                        sx += 1;
                        if (sx >= right) break;
                    }
                }
                continue;
            }
            const cw = width.cellWidth(cp);
            if (cw == 0) continue; // combining mark: attaches to the previous cell
            if (dcol >= ed.scroll_col) {
                if (sx + cw > right) break;
                var cell = render.Cell{ .ch = cp, .fg = fg, .bg = row_bg };
                if (selected) cell.bg = sel_bg;
                s.put(@intCast(sx), y, cell);
                if (cw == 2) {
                    var cont = render.Cell{ .ch = ' ', .fg = fg, .bg = row_bg, .cont = true };
                    if (selected) cont.bg = sel_bg;
                    s.put(@intCast(sx + 1), y, cont);
                }
                sx += cw;
            }
            dcol += cw;
        }

        // Selection covering the newline (or end of file).
        if (sel) |sr| {
            if (line_end >= sr.start and line_end < sr.end and dcol >= ed.scroll_col) {
                const cell_x = r.x + gutter + (dcol - ed.scroll_col);
                if (cell_x < right) s.put(@intCast(cell_x), y, .{ .ch = ' ', .bg = sel_bg });
            }
        }

        // Block cursor (drawn last so it wins over selection).
        if (focused and lr == rc.row and cur_dcol >= ed.scroll_col) {
            const cx = r.x + gutter + (cur_dcol - ed.scroll_col);
            if (cx < right) {
                var under: u21 = ' ';
                if (rc.col < line.len) under = utf8.cpAt(line, rc.col);
                if (under < 0x20) under = ' ';
                var uw: usize = width.cellWidth(under);
                if (uw == 0) {
                    under = ' ';
                    uw = 1;
                }
                if (cx + uw <= right) {
                    s.put(@intCast(cx), y, .{ .ch = under, .fg = text_fg, .attr = .{ .reverse = true } });
                    if (uw == 2) {
                        s.put(@intCast(cx + 1), y, .{ .ch = ' ', .fg = text_fg, .attr = .{ .reverse = true }, .cont = true });
                    }
                }
            }
        }
    }

    // Extra cursors, drawn as blocks like the main one.
    if (focused) {
        for (ed.cursors.items) |pos| {
            const crc = ed.rowColAt(pos);
            if (crc.row < ed.scroll_row) continue;
            const vrow = crc.row - ed.scroll_row;
            if (vrow >= r.h) continue;
            const dcol = ed.displayColAt(pos);
            if (dcol < ed.scroll_col) continue;
            const cx = r.x + gutter + (dcol - ed.scroll_col);
            if (cx >= right) continue;
            const ln = ed.line(crc.row);
            var under: u21 = ' ';
            if (crc.col < ln.len) under = utf8.cpAt(ln, crc.col);
            if (under < 0x20) under = ' ';
            var uw: usize = width.cellWidth(under);
            if (uw == 0) {
                under = ' ';
                uw = 1;
            }
            if (cx + uw > right) continue;
            const cy: u16 = @intCast(r.y + vrow);
            s.put(@intCast(cx), cy, .{ .ch = under, .fg = text_fg, .attr = .{ .reverse = true } });
            if (uw == 2) {
                s.put(@intCast(cx + 1), cy, .{ .ch = ' ', .fg = text_fg, .attr = .{ .reverse = true }, .cont = true });
            }
        }
    }
}

/// One row of tabs: ` name [+] ` per document, the active one highlighted.
const TREE_WIDTH = 28;

/// Columns the sidebar takes from the text area.
fn sidebarWidth(session: *Session) usize {
    return if (session.tree != null) TREE_WIDTH else 0;
}

fn drawTree(s: *render.Screen, t: *tree_mod.Tree, focused: bool, h: usize, theme: config_mod.Theme, icons_unicode: bool) void {
    if (h < 4) return;
    const side_w = @min(TREE_WIDTH, s.cols);
    const rows = h - 2;
    t.ensureVisible(rows);

    // The sidebar is a bar like the tab strip and the status line, so it takes
    // the bar background: darker than the editor, visibly its own surface.
    const bg = theme.bar_bg;
    const sel_bg = theme.selection;
    var y: usize = 1;
    while (y < h - 1) : (y += 1) {
        var x: usize = 0;
        while (x < side_w) : (x += 1) s.put(@intCast(x), @intCast(y), .{ .ch = ' ', .bg = bg });
    }

    var row: usize = 0;
    var idx = t.scroll;
    while (row < rows and idx < t.entries.items.len) : ({
        row += 1;
        idx += 1;
    }) {
        const e = t.entries.items[idx];
        const selected = idx == t.selected;
        const row_bg = if (selected) sel_bg else bg;
        // Whole row, so the highlight is a bar rather than a word.
        var x: usize = 0;
        while (x < side_w) : (x += 1) s.put(@intCast(x), @intCast(1 + row), .{ .ch = ' ', .bg = row_bg });

        const indent = @min(e.depth * 2, side_w - 6);
        const icon = if (e.is_parent)
            (if (icons_unicode) "\u{f062}" else "^")
        else if (e.is_dir)
            tree_mod.iconFor(e.name, true, t.isExpanded(e.path), icons_unicode)
        else
            tree_mod.iconFor(e.name, false, false, icons_unicode);
        var line_buf: [300]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}{s} {s}", .{
            " " ** 1,
            icon,
            e.name,
        }) catch e.name;
        const text_x = 1 + indent;
        s.putStr(@intCast(text_x), @intCast(1 + row), line, .{
            .bg = row_bg,
            .fg = if (selected) theme.text else if (e.is_dir) theme.keyword2 else theme.text,
            .attr = .{ .bold = selected },
        });
        _ = focused;
    }
}

/// Keys while the file tree has focus. Returns the bytes consumed, or null
/// when the chunk is not a complete tree key (so the caller waits for more).
fn handleTreeInput(session: *Session, buf: []const u8, msg_buf: []u8, msg: *[]const u8) ?usize {
    const t = &session.tree.?;
    var i: usize = 0;
    while (i < buf.len) {
        const b = buf[i];
        if (b == 0x1b) {
            if (i + 1 >= buf.len) return if (i == 0) null else i;
            const k = buf[i + 1];
            if (k == '[' and i + 2 < buf.len and buf[i + 2] == '<') return null; // mouse
            if (k == '[' or k == 'O') {
                var end: usize = undefined;
                if (k == '[') {
                    var j = i + 2;
                    while (j < buf.len) : (j += 1) {
                        if (buf[j] >= 0x40 and buf[j] <= 0x7E) break;
                    }
                    if (j >= buf.len) return if (i == 0) null else i;
                    end = j + 1;
                } else {
                    if (i + 2 >= buf.len) return if (i == 0) null else i;
                    end = i + 3;
                }
                const seq = buf[i..end];
                if (std.mem.eql(u8, seq, "\x1b[A") or std.mem.eql(u8, seq, "\x1bOA")) {
                    t.move(-1);
                } else if (std.mem.eql(u8, seq, "\x1b[B") or std.mem.eql(u8, seq, "\x1bOB")) {
                    t.move(1);
                } else if (std.mem.eql(u8, seq, "\x1b[C") or std.mem.eql(u8, seq, "\x1bOC")) {
                    if (t.selectedEntry()) |e| {
                        if (e.is_dir and !t.isExpanded(e.path)) t.toggleDir(e.path) catch {};
                    }
                } else if (std.mem.eql(u8, seq, "\x1b[D") or std.mem.eql(u8, seq, "\x1bOD")) {
                    if (t.selectedEntry()) |e| {
                        if (e.is_dir and t.isExpanded(e.path)) t.toggleDir(e.path) catch {};
                    }
                }
                i = end;
                continue;
            }
            session.tree_focus = false;
            return i + 1;
        }
        if (b == 0x0d or b == 0x0a) {
            openTreeSelection(session, msg_buf, msg);
            return i + 1;
        }
        if (b == 0x02) { // Ctrl+B closes it
            session.tree_focus = false;
            session.tree.?.deinit();
            session.tree = null;
            return i + 1;
        }
        if (b == 0x09) { // Tab: back to the editor
            session.tree_focus = false;
            return i + 1;
        }
        if (b == 'k') {
            t.move(-1);
            i += 1;
            continue;
        }
        if (b == 'j') {
            t.move(1);
            i += 1;
            continue;
        }
        // Anything else (Ctrl+Q, Ctrl+S, Ctrl+P, ...) belongs to the editor:
        // hand the whole chunk back so the normal dispatch sees it.
        return if (i == 0) null else i;
    }
    return i;
}

/// Enter in the tree: expand a directory or open a file in a new tab.
fn openTreeSelection(session: *Session, msg_buf: []u8, msg: *[]const u8) void {
    const t = &session.tree.?;
    const entry = t.selectedEntry() orelse return;
    if (entry.is_parent) {
        t.goUp() catch {};
        return;
    }
    if (entry.is_dir) {
        t.toggleDir(entry.path) catch {};
        return;
    }
    var path_buf: [1024]u8 = undefined;
    const path = t.selectedPath(&path_buf) orelse return;
    for (session.docs.items, 0..) |doc, i| {
        if (doc.path) |p| {
            if (pathsEqual(p, path)) {
                session.focusDoc(i);
                session.tree_focus = false;
                return;
            }
        }
    }
    const data = os.readFileAlloc(session.allocator, path, MAX_FILE) catch |e| {
        setErrMsg(msg_buf, msg, "Cannot open", e);
        return;
    };
    defer session.allocator.free(data);
    const lang = if (session.registry) |r| r.find(path) else null;
    session.add(path, data, lang) catch |e| {
        setErrMsg(msg_buf, msg, "Cannot open", e);
        return;
    };
    session.tree_focus = false;
}

// --- tab strip -------------------------------------------------------------
// The bar is `[<] tabs... [>] [ + ]`: the arrows only appear when the tabs do
// not fit, and `+` stays pinned to the right edge so it is always reachable.

/// A tab's text: " name " (plus " [+]" while the buffer is unsaved).
fn tabLabel(ed: *Editor, buf: []u8) []const u8 {
    const name = if (ed.path) |p| baseName(p) else "[No Name]";
    return std.fmt.bufPrint(buf, " {s}{s} ", .{ name, if (ed.dirty) " [+]" else "" }) catch name;
}

/// Cells a tab takes: the label, a pad, the close `x`, and a right pad so the
/// `x` never sits on the tab's edge.
fn tabWidth(ed: *Editor) usize {
    var buf: [200]u8 = undefined;
    return tabLabel(ed, &buf).len + 3;
}

const TabLayout = struct {
    /// True when the tabs do not fit and the strip scrolls.
    overflow: bool = false,
    /// First column of the tab area (1 when the left arrow is drawn).
    x0: usize = 0,
    /// Columns available for tabs.
    avail: usize = 0,
    /// Strip offset of the first visible tab.
    scroll: usize = 0,
    /// The " + " button, and the arrows (0xFFFF when absent).
    plus_x: u16 = 0xFFFF,
    prev_x: u16 = 0xFFFF,
    next_x: u16 = 0xFFFF,
};

/// Work out the strip geometry for a bar `w` columns wide, caching each tab's
/// offset and width on the session and clamping the scroll. Scrolling always
/// lands on a tab start, so a tab is never cut off on its left edge.
fn layoutTabs(session: *Session, w: usize) TabLayout {
    const n = @min(session.docs.items.len, MAX_TABS);
    session.tab_count = n;
    var total: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        session.tab_widths[i] = tabWidth(session.docs.items[i]);
        session.tab_starts[i] = total;
        total += session.tab_widths[i];
        if (i + 1 < n) total += 1; // one blank cell between tabs
    }

    var layout = TabLayout{};
    if (w < 8) {
        session.tab_scroll = 0;
        session.tab_scroll_max = 0;
        return layout;
    }
    layout.plus_x = @intCast(w - 3);
    var avail = w - 4; // the tab area ends one cell before " + "
    if (total > avail) {
        layout.overflow = true;
        layout.x0 = 1;
        layout.prev_x = 0;
        layout.next_x = @intCast(w - 5);
        avail -= 2; // an arrow at each end
    }
    layout.avail = avail;

    // Furthest scroll: the first tab whose remainder still fills the strip.
    var max_scroll: usize = 0;
    if (n > 0) {
        max_scroll = session.tab_starts[n - 1];
        i = 0;
        while (i < n) : (i += 1) {
            if (total - session.tab_starts[i] <= avail) {
                max_scroll = session.tab_starts[i];
                break;
            }
        }
    }
    session.tab_scroll_max = if (layout.overflow) max_scroll else 0;

    var scroll = snapScrollUp(session, @min(session.tab_scroll, session.tab_scroll_max));
    // A change of active tab scrolls it into view; a manual scroll stays put.
    if (layout.overflow and session.active != session.drawn_active and session.active < n) {
        const a = session.active;
        const a0 = session.tab_starts[a];
        const a1 = a0 + session.tab_widths[a];
        if (session.tab_widths[a] >= avail or a0 < scroll) {
            scroll = a0;
        } else if (a1 > scroll + avail) {
            scroll = snapScrollUp(session, @min(a1 - avail, session.tab_scroll_max));
        }
    }
    session.tab_scroll = scroll;
    session.drawn_active = session.active;
    layout.scroll = scroll;
    return layout;
}

/// The tab start at or after `target`; scroll targets always land on a tab.
fn snapScrollUp(session: *Session, target: usize) usize {
    const n = session.tab_count;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (session.tab_starts[i] >= target) return session.tab_starts[i];
    }
    return if (n > 0) session.tab_starts[n - 1] else 0;
}

fn drawTabBar(s: *render.Screen, session: *Session, w: usize, text_fg: render.Color, dim_fg: render.Color) void {
    const theme = session.config.theme;
    const bar_bg = theme.tab_bg;
    const active_bg = theme.tab_active_bg;
    session.tab_count = 0;
    session.new_tab_x = 0xFFFF;
    session.tab_prev_x = 0xFFFF;
    session.tab_next_x = 0xFFFF;
    var i: usize = 0;
    while (i < MAX_TABS) : (i += 1) {
        session.tab_spans[i] = .{ 0xFFFF, 0 };
        session.tab_close_x[i] = 0xFFFF;
    }
    var x: usize = 0;
    while (x < w) : (x += 1) s.put(@intCast(x), 0, .{ .bg = bar_bg });

    const layout = layoutTabs(session, w);
    const strip_end = layout.x0 + layout.avail;

    // " + " pinned to the right edge.
    if (layout.plus_x != 0xFFFF) {
        const hot = session.hover_plus;
        s.putStr(layout.plus_x, 0, " + ", .{
            .bg = if (hot) theme.accent else bar_bg,
            .fg = if (hot) bar_bg else theme.accent,
            .attr = .{ .bold = true },
        });
        session.new_tab_x = layout.plus_x + 1;
    }
    if (layout.overflow) {
        const can_prev = layout.scroll > 0;
        const can_next = layout.scroll < session.tab_scroll_max;
        const hot_prev = session.hover_prev and can_prev;
        const hot_next = session.hover_next and can_next;
        s.put(layout.prev_x, 0, .{
            .ch = '\u{2039}',
            .bg = if (hot_prev) theme.accent else bar_bg,
            .fg = if (hot_prev) bar_bg else if (can_prev) theme.accent else dim_fg,
            .attr = .{ .bold = can_prev },
        });
        s.put(layout.next_x, 0, .{
            .ch = '\u{203a}',
            .bg = if (hot_next) theme.accent else bar_bg,
            .fg = if (hot_next) bar_bg else if (can_next) theme.accent else dim_fg,
            .attr = .{ .bold = can_next },
        });
        session.tab_prev_x = layout.prev_x;
        session.tab_next_x = layout.next_x;
    }

    const n = session.tab_count;
    i = 0;
    while (i < n) : (i += 1) {
        const start = session.tab_starts[i];
        const tab_w = session.tab_widths[i];
        if (start + tab_w <= layout.scroll) continue; // scrolled off to the left
        if (start < layout.scroll) continue; // unreachable: scroll is a tab start
        const tx = layout.x0 + (start - layout.scroll);
        if (tx >= strip_end) break;
        const tab_end = @min(tx + tab_w, strip_end);
        const ed = session.docs.items[i];
        const active = i == session.active;
        const hovered = session.hover_tab == i;
        const dragging = session.drag_tab == i;
        const bg = if (dragging) theme.accent else if (active) active_bg else if (hovered) theme.selection else bar_bg;
        const fg = if (dragging) bar_bg else if (active or hovered) text_fg else dim_fg;
        // Fill the tab first so the padding cells carry its background.
        var cx = tx;
        while (cx < tab_end) : (cx += 1) s.put(@intCast(cx), 0, .{ .ch = ' ', .bg = bg });
        var buf: [200]u8 = undefined;
        const label = tabLabel(ed, &buf);
        s.putStrTo(@intCast(tx), 0, @intCast(tab_end), label, .{
            .bg = bg,
            .fg = fg,
            .attr = .{ .bold = active or dragging, .underline = hovered and !active },
        });
        const close_x = tx + label.len + 1; // one cell of padding before the x
        if (close_x + 1 < tab_end) { // the x and the cell after it both fit
            const hot = session.hover_close == i;
            s.put(@intCast(close_x), 0, .{
                .ch = 'x',
                .bg = if (hot) theme.accent else bg,
                .fg = if (hot or dragging) bar_bg else dim_fg,
                .attr = .{ .bold = hot or hovered },
            });
            session.tab_close_x[i] = @intCast(close_x);
        }
        session.tab_spans[i] = .{ @intCast(tx), @intCast(tab_end) };
    }

    // While dragging: a drop marker where the tab would land, and the tab
    // itself following the pointer.
    if (session.drag_tab) |from| {
        if (session.drag_to < n and session.tab_spans[session.drag_to][0] != 0xFFFF) {
            const marker = session.tab_spans[session.drag_to][0];
            if (marker < w) s.put(@intCast(marker), 0, .{ .ch = '\u{2502}', .bg = bar_bg, .fg = theme.accent });
        }
        const ed = session.docs.items[from];
        const name = if (ed.path) |p| baseName(p) else "[No Name]";
        var chip_buf: [300]u8 = undefined;
        const chip = std.fmt.bufPrint(&chip_buf, " {s} ", .{name}) catch name;
        const start_x: usize = if (session.drag_x > 0) @as(usize, session.drag_x) - 1 else 0;
        var cx = start_x;
        var ci: usize = 0;
        while (ci < chip.len and cx < w) : (ci += 1) {
            s.put(@intCast(cx), 0, .{
                .ch = chip[ci],
                .bg = theme.accent,
                .fg = bar_bg,
                .attr = .{ .bold = true },
            });
            cx += 1;
        }
    }
}

/// Bottom panel listing the controls (temporary; will become a real panel).
// ---------------------------------------------------------------------------
// Fuzzy picker: Ctrl+O lists the working directory, F2 lists themes (with a
// live preview while the selection moves).
// ---------------------------------------------------------------------------
fn closePicker(slot: *?picker.Picker) void {
    if (slot.*) |*p| p.deinit();
    slot.* = null;
}

fn openPicker(
    session: *Session,
    slot: *?picker.Picker,
    mode: picker.Mode,
    theme_before: *config_mod.Theme,
    exe_dir: ?[]const u8,
) void {
    closePicker(slot);
    var p = picker.Picker.init(std.heap.page_allocator);
    switch (mode) {
        .open_file => {
            p.setDir(".");
            loadDirInto(&p, ".");
        },
        .theme => {
            theme_before.* = session.config.theme;
            loadThemesInto(&p, exe_dir);
            p.selectByName(session.config.themeName());
        },
        .commands => loadCommandsInto(&p),
    }
    slot.* = p;
}

fn loadDirInto(p: *picker.Picker, dir: []const u8) void {
    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |n| p.allocator.free(n);
        names.deinit(p.allocator);
    }
    os.listDirNames(p.allocator, dir, &names) catch return;
    os.sortStrings(names.items);
    for (names.items) |name| {
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        p.add(name, os.isDirectory(path)) catch {};
    }
    p.refilter();
}

fn loadCommandsInto(p: *picker.Picker) void {
    inline for (@typeInfo(keys.Action).@"enum".fields) |field| {
        p.add(field.name, false) catch {};
    }
    p.refilter();
}

fn loadThemesInto(p: *picker.Picker, exe_dir: ?[]const u8) void {
    var exe_buf: [1024]u8 = undefined;
    var dirs: [2][]const u8 = .{ "themes", "" };
    var dir_count: usize = 1;
    if (exe_dir) |d| {
        if (std.fmt.bufPrint(&exe_buf, "{s}/themes", .{d})) |path| {
            dirs[1] = path;
            dir_count = 2;
        } else |_| {}
    }
    var seen = std.ArrayList([]u8).empty;
    defer {
        for (seen.items) |s2| p.allocator.free(s2);
        seen.deinit(p.allocator);
    }
    for (dirs[0..dir_count]) |dir| {
        var names = std.ArrayList([]u8).empty;
        defer {
            for (names.items) |n| p.allocator.free(n);
            names.deinit(p.allocator);
        }
        os.listDirNames(p.allocator, dir, &names) catch continue;
        os.sortStrings(names.items);
        for (names.items) |name| {
            if (!std.mem.endsWith(u8, name, ".ini")) continue;
            const stem = name[0 .. name.len - 4];
            var dup = false;
            for (seen.items) |s2| {
                if (std.mem.eql(u8, s2, stem)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            seen.append(p.allocator, p.allocator.dupe(u8, stem) catch continue) catch continue;
            p.add(stem, false) catch {};
        }
    }
    p.refilter();
}

/// Apply the highlighted theme immediately (live preview).
fn previewTheme(session: *Session, mode: picker.Mode, p: *picker.Picker, exe_dir: ?[]const u8) void {
    if (mode != .theme) return;
    const item = p.selectedItem() orelse return;
    if (config_mod.loadTheme(std.heap.page_allocator, exe_dir, item.text)) |theme| {
        session.config.theme = theme;
    }
}

fn acceptPicker(
    session: *Session,
    slot: *?picker.Picker,
    mode: picker.Mode,
    registry: *syntax.Registry,
    msg_buf: []u8,
    msg: *[]const u8,
) !void {
    const p = &slot.*.?;
    const item = p.selectedItem() orelse {
        closePicker(slot);
        return;
    };
    switch (mode) {
        .commands => {
            // The run loop executes the action like a key press would.
            if (keys.actionFromName(item.text)) |action| session.ui_action = action;
            closePicker(slot);
        },
        .theme => {
            // Persist the choice: the next start should come up in this theme.
            const name = item.text;
            config_mod.saveTheme(std.heap.page_allocator, &session.config, name) catch |e| {
                setErrMsg(msg_buf, msg, "Theme not saved", e);
                closePicker(slot);
                return;
            };
            var note_buf: [96]u8 = undefined;
            setMsg(msg_buf, msg, std.fmt.bufPrint(&note_buf, "theme: {s} (saved)", .{name}) catch "theme saved");
            closePicker(slot);
        },
        .open_file => {
            var path_buf: [1024]u8 = undefined;
            const dir = p.dirName();
            const path = if (std.mem.eql(u8, dir, "."))
                item.text
            else
                std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, item.text }) catch item.text;
            // Already open? Switch to its tab instead of adding a duplicate.
            for (session.docs.items, 0..) |doc, i| {
                if (doc.path) |doc_path| {
                    if (std.mem.eql(u8, doc_path, path)) {
                        session.focusDoc(i);
                        closePicker(slot);
                        return;
                    }
                }
            }
            if (item.is_dir) {
                p.clear();
                p.setDir(path);
                loadDirInto(p, path);
                return;
            }
            const data = os.readFileAlloc(std.heap.page_allocator, path, MAX_FILE) catch |e| {
                setErrMsg(msg_buf, msg, "Cannot open", e);
                return; // keep the picker open so another file can be chosen
            };
            defer std.heap.page_allocator.free(data);
            session.add(path, data, registry.find(path)) catch |e| {
                setErrMsg(msg_buf, msg, "Cannot open", e);
                return;
            };
            closePicker(slot);
        },
    }
}

fn handlePickerInput(
    session: *Session,
    slot: *?picker.Picker,
    mode: picker.Mode,
    theme_before: *config_mod.Theme,
    exe_dir: ?[]const u8,
    registry: *syntax.Registry,
    buf: []const u8,
    running: *bool,
    msg_buf: []u8,
    msg: *[]const u8,
) !usize {
    _ = running;
    const p = &slot.*.?;
    var i: usize = 0;
    while (i < buf.len) {
        const b = buf[i];
        if (b == 0x1b) {
            if (i + 1 >= buf.len) {
                // A lone Esc closes the picker right away; arrows arrive as
                // whole sequences, so waiting would just feel stuck.
                if (mode == .theme) session.config.theme = theme_before.*;
                closePicker(slot);
                return i + 1;
            }
            const k = buf[i + 1];
            if (k == '[' or k == 'O') {
                var end: usize = undefined;
                if (k == '[') {
                    var j = i + 2;
                    while (j < buf.len) : (j += 1) {
                        if (buf[j] >= 0x40 and buf[j] <= 0x7E) break;
                    }
                    if (j >= buf.len) return i;
                    end = j + 1;
                } else {
                    if (i + 2 >= buf.len) return i;
                    end = i + 3;
                }
                if (buf[i + 2] == '<') {
                    // Click in the list: select that row, accept it on a
                    // second click (items start on screen row 3).
                    const nums = parseMouse(buf[i + 2 .. end - 1]);
                    if (nums[0] == 0 and nums[2] >= 3) {
                        const idx = p.scroll + (nums[2] - 3);
                        if (idx < p.filtered.items.len) {
                            const was = idx == p.selected;
                            p.selected = idx;
                            previewTheme(session, mode, p, exe_dir);
                            if (was) {
                                try acceptPicker(session, slot, mode, registry, msg_buf, msg);
                                return end;
                            }
                        }
                    }
                    i = end;
                    continue;
                }
                const seq = buf[i..end];
                if (std.mem.eql(u8, seq, "\x1b[A") or std.mem.eql(u8, seq, "\x1bOA")) {
                    p.move(-1);
                } else if (std.mem.eql(u8, seq, "\x1b[B") or std.mem.eql(u8, seq, "\x1bOB")) {
                    p.move(1);
                }
                previewTheme(session, mode, p, exe_dir);
                i = end;
                continue;
            }
            // Escape alone (followed by an ordinary key): cancel.
            if (mode == .theme) session.config.theme = theme_before.*;
            closePicker(slot);
            return i + 1;
        }
        if (b == 0x0d or b == 0x0a) {
            try acceptPicker(session, slot, mode, registry, msg_buf, msg);
            return i + 1;
        }
        if (b == 0x7f or b == 0x08) {
            p.popFilter();
            previewTheme(session, mode, p, exe_dir);
            i += 1;
            continue;
        }
        if (b == 0x10) { // Ctrl+P
            p.move(-1);
            previewTheme(session, mode, p, exe_dir);
            i += 1;
            continue;
        }
        if (b == 0x0e) { // Ctrl+N
            p.move(1);
            previewTheme(session, mode, p, exe_dir);
            i += 1;
            continue;
        }
        if (b >= 0x20) {
            p.pushFilter(b);
            previewTheme(session, mode, p, exe_dir);
            i += 1;
            continue;
        }
        i += 1;
    }
    return i;
}

fn drawPicker(s: *render.Screen, p: *picker.Picker, mode: picker.Mode, theme: config_mod.Theme) void {
    const w: usize = s.cols;
    const h: usize = s.rows;
    if (h < 5 or w < 24) return;
    const list_rows = h - 3;
    p.ensureVisible(list_rows);

    const blank = render.Cell{ .ch = ' ', .bg = theme.background };
    var r: usize = 1;
    while (r < h) : (r += 1) {
        var c: usize = 0;
        while (c < w) : (c += 1) s.put(@intCast(c), @intCast(r), blank);
    }

    const title = switch (mode) {
        .open_file => "Open file",
        .theme => "Theme",
        .commands => "Commands",
    };
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, " {s}: {s} ({d}/{d})", .{
        title,
        p.dirName(),
        p.count(),
        p.items.items.len,
    }) catch title;
    s.putStr(1, 1, head, .{ .fg = theme.accent, .bg = theme.background, .attr = .{ .bold = true } });

    var row: usize = 2;
    var idx = p.scroll;
    while (row < h - 1 and idx < p.filtered.items.len) : ({
        row += 1;
        idx += 1;
    }) {
        const item = p.items.items[p.filtered.items[idx]];
        const selected = idx == p.selected;
        const bg = if (selected) theme.selection else theme.background;
        const fg = if (selected) theme.text else if (item.is_dir) theme.keyword2 else theme.text;
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, " {s}{s}", .{ item.text, if (item.is_dir) "/" else "" }) catch item.text;
        s.putStr(1, @intCast(row), line, .{ .fg = fg, .bg = bg, .attr = .{ .bold = selected } });
    }

    var filter_buf: [160]u8 = undefined;
    const filter = std.fmt.bufPrint(&filter_buf, " > {s}", .{p.filterText()}) catch " > ";
    s.putStr(1, s.rows - 1, filter, .{ .fg = theme.text, .bg = theme.bar_bg });
    if (w > filter.len + 20) {
        s.putStr(@intCast(w - 20), s.rows - 1, "Enter select  Esc cancel", .{ .fg = theme.hint_fg, .bg = theme.bar_bg });
    }
}

/// The key bound to `action` (the user's choice) or its built-in key.
fn actionKeyName(session: *Session, action: keys.Action, buf: []u8) []const u8 {
    if (session.config.keys.keyFor(action)) |bound| return bound;
    const dk = defaultKeyFor(action, false);
    return switch (dk) {
        .byte => |b| keyNameByte(b) orelse "?",
        .csi => |c| csiKeyName(buf, c.params, c.final) orelse "?",
    };
}

fn joinActionKeys(session: *Session, actions: []const keys.Action, buf: []u8) []const u8 {
    var n: usize = 0;
    for (actions, 0..) |action, idx| {
        if (idx > 0) {
            if (n + 3 > buf.len) break;
            @memcpy(buf[n..][0..3], " / ");
            n += 3;
        }
        var tmp: [64]u8 = undefined;
        const name = actionKeyName(session, action, &tmp);
        if (n + name.len > buf.len) break;
        @memcpy(buf[n..][0..name.len], name);
        n += name.len;
    }
    return buf[0..n];
}

fn drawHelp(s: *render.Screen, session: *Session, w: usize, h: usize, theme: config_mod.Theme) void {
    if (h < 2) return;
    const panel_h = @min(h - 1, help_rows.len + 1);
    const top = h - panel_h;
    const bg = theme.help_bg;
    const fg = theme.text;
    const title_fg = theme.accent;

    var y: usize = top;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) s.put(@intCast(x), @intCast(y), .{ .bg = bg });
    }
    s.putStr(0, @intCast(top), " mibi controls", .{ .bg = bg, .fg = title_fg });
    const pad_text = "                        "; // 24 spaces
    var i: usize = 0;
    while (i < help_rows.len and top + 1 + i < h) : (i += 1) {
        var keys_buf: [96]u8 = undefined;
        const keys_text = if (help_rows[i].literal) |lit| lit else joinActionKeys(session, help_rows[i].actions, &keys_buf);
        const pad = if (keys_text.len < pad_text.len) pad_text[0 .. pad_text.len - keys_text.len] else " ";
        var line_buf: [192]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "  {s}{s}{s}", .{ keys_text, pad, help_rows[i].desc }) catch help_rows[i].desc;
        s.putStr(0, @intCast(top + 1 + i), line, .{ .bg = bg, .fg = fg });
    }
}

/// The last component of a path ("src/main.zig" -> "main.zig").
/// Paths compared the way a user means them: a leading "./" or ".\\" is the
/// same as none, so the tree ("./notes.txt") and a command-line argument
/// ("notes.txt") are one document, not two tabs.
fn stripDotSlash(p: []const u8) []const u8 {
    var s = p;
    while (std.mem.startsWith(u8, s, "./") or std.mem.startsWith(u8, s, ".\\")) s = s[2..];
    return s;
}

fn pathsEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, stripDotSlash(a), stripDotSlash(b));
}

fn baseName(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    var i = end;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/' or path[i - 1] == '\\') return path[i..end];
    }
    return path[0..end];
}

/// The directory part of a typed path, or "." when there is none.
fn promptDir(text: []const u8) []const u8 {
    var i = text.len;
    while (i > 0) : (i -= 1) {
        const c = text[i - 1];
        if (c == '/' or c == '\\') return text[0..i];
    }
    return ".";
}

fn commonPrefix(a: []const u8, b: []const u8) []const u8 {
    var i: usize = 0;
    while (i < a.len and i < b.len and a[i] == b[i]) : (i += 1) {}
    return a[0..i];
}

/// Tab completion: extend the last path component to the common prefix of the
/// matching directory entries.
fn completePath(allocator: std.mem.Allocator, p: *Prompt) !void {
    const text = p.buf[0..p.len];
    const dir = promptDir(text);
    const base = text[dir.len..];
    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    os.listDirNames(allocator, dir, &names) catch return;
    var prefix: ?[]const u8 = null;
    for (names.items) |n| {
        if (!std.mem.startsWith(u8, n, base)) continue;
        prefix = if (prefix) |pr| commonPrefix(pr, n) else n;
    }
    const pre = prefix orelse return;
    if (pre.len <= base.len) return;
    const total = dir.len + pre.len;
    if (total > p.buf.len) return;
    @memcpy(p.buf[dir.len..total], pre);
    p.len = total;
}

fn drawPrompt(
    s: *render.Screen,
    p: Prompt,
    w: usize,
    h: usize,
    bar_bg: render.Color,
    accent: render.Color,
    text_fg: render.Color,
) void {
    const y: u16 = @intCast(h - 1);
    var x: usize = 0;
    while (x < w) : (x += 1) s.put(@intCast(x), y, .{ .bg = bar_bg });
    const label = switch (p.kind) {
        .save_as => "Save as: ",
        .open => "Open: ",
        .find => "Find: ",
        .replace_find => "Replace: ",
        .replace_with => "With: ",
        .goto => "Go to line: ",
        .confirm_quit => "Unsaved changes - quit without saving? (y/N) ",
        .confirm_close => "Unsaved changes - close without saving? (y/N) ",
    };
    s.putStr(0, y, label, .{ .bg = bar_bg, .fg = accent });
    if (p.kind == .confirm_quit or p.kind == .confirm_close) return; // yes/no, no text field
    s.putStr(@intCast(label.len), y, p.buf[0..p.len], .{ .bg = bar_bg, .fg = text_fg });
    const cx = label.len + p.len;
    if (cx < w) s.put(@intCast(cx), y, .{ .ch = ' ', .bg = bar_bg, .attr = .{ .reverse = true } });
}

fn drawStatus(
    s: *render.Screen,
    ed: *Editor,
    msg: []const u8,
    w: usize,
    h: usize,
    rc: anytype,
    total: usize,
    bar_bg: render.Color,
    accent: render.Color,
    hint_fg: render.Color,
) void {
    const hint = "F1 help";
    var st_buf: [192]u8 = undefined;
    const name = ed.path orelse "[No Name]";
    const status = std.fmt.bufPrint(&st_buf, " mibi {s}  {s}{s}  {d}:{d}  {d}L  {d}x{d}  {s}", .{
        version,
        name,
        if (ed.dirty) " [+]" else "",
        rc.row + 1,
        rc.col + 1,
        total,
        w,
        h,
        msg,
    }) catch " mibi";
    var x: usize = 0;
    while (x < w) : (x += 1) s.put(@intCast(x), @intCast(h - 1), .{ .bg = bar_bg });
    // Keep the hint on the right edge and clip the status text before it.
    const hint_x = if (w > hint.len + 2) w - hint.len - 1 else w;
    const status_max = if (hint_x > 0) hint_x - 1 else w;
    const shown = status[0..@min(status.len, status_max)];
    s.putStr(0, @intCast(h - 1), shown, .{ .bg = bar_bg, .fg = accent });
    if (hint_x < w) s.putStr(@intCast(hint_x), @intCast(h - 1), hint, .{ .bg = bar_bg, .fg = hint_fg });
}

test "an escape sequence split across reads is not typed as text" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    try session.add(null, "one two three", null);
    var running = true;
    var prompt: ?Prompt = null;
    var help = false;
    var mb: [64]u8 = undefined;
    var msg: []const u8 = "";

    // Ctrl+Right arrives as "\x1b[1;5" then "C".
    const first = "\x1b[1;5";
    const consumed1 = try processInput(&session, first, 10, &running, &prompt, &help, &mb, &msg);
    try std.testing.expectEqual(@as(usize, 0), consumed1); // held back, not consumed
    try std.testing.expectEqualStrings("one two three", session.current().text());

    var combined: [32]u8 = undefined;
    @memcpy(combined[0..first.len], first);
    combined[first.len] = 'C';
    const total = first.len + 1;
    const consumed2 = try processInput(&session, combined[0..total], 10, &running, &prompt, &help, &mb, &msg);
    try std.testing.expectEqual(total, consumed2);
    try std.testing.expectEqual(@as(usize, 4), session.current().cursor); // after "one "
    try std.testing.expectEqualStrings("one two three", session.current().text());
}

test "page down and page up move by a page" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    try session.add(null, "0\n1\n2\n3\n4\n5\n6\n7\n8\n9", null);
    var running = true;
    var prompt: ?Prompt = null;
    var help = false;
    var mb: [64]u8 = undefined;
    var msg: []const u8 = "";

    const consumed = try processInput(&session, "\x1b[6~", 3, &running, &prompt, &help, &mb, &msg);
    try std.testing.expectEqual(@as(usize, 4), consumed);
    try std.testing.expectEqual(@as(usize, 3), session.current().rowCol().row);

    _ = try processInput(&session, "\x1b[5~", 3, &running, &prompt, &help, &mb, &msg);
    try std.testing.expectEqual(@as(usize, 0), session.current().rowCol().row);
}

test "ctrl+a selects all and ctrl+x cuts the selection" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    try session.add(null, "hello world", null);
    var running = true;
    var prompt: ?Prompt = null;
    var help = false;
    var mb: [64]u8 = undefined;
    var msg: []const u8 = "";

    _ = try processInput(&session, "\x01", 10, &running, &prompt, &help, &mb, &msg); // Ctrl+A
    const r = session.current().selectionRange();
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(usize, 0), r.?.start);
    try std.testing.expectEqual(@as(usize, 11), r.?.end);

    _ = try processInput(&session, "\x18", 10, &running, &prompt, &help, &mb, &msg); // Ctrl+X
    try std.testing.expectEqualStrings("", session.current().text());
    try std.testing.expectEqualStrings("hello world", session.current().registerText());
}

// --- integration drive: feed real key bytes through the real handlers ------

const Drive = struct {
    session: Session,
    registry: syntax.Registry,
    running: bool = true,
    prompt: ?Prompt = null,
    help: bool = false,
    mb: [256]u8 = undefined,
    msg: []const u8 = "",
    pending: [256]u8 = undefined,
    pending_len: usize = 0,

    fn start(text: []const u8) !Drive {
        var d = Drive{
            .session = Session.init(std.testing.allocator),
            .registry = syntax.Registry.init(std.testing.allocator),
        };
        try d.session.add(null, text, null);
        return d;
    }
    fn stop(self: *Drive) void {
        self.session.deinit();
        self.registry.deinit();
    }
    fn ed(self: *Drive) *Editor {
        return self.session.current();
    }
    /// Feed bytes exactly as the run loop would: whole tokens, switching
    /// between prompt and normal handling mid-chunk, keeping any incomplete
    /// escape sequence pending for the next call.
    fn send(self: *Drive, bytes: []const u8) !void {
        const n = @min(bytes.len, self.pending.len - self.pending_len);
        @memcpy(self.pending[self.pending_len..][0..n], bytes[0..n]);
        self.pending_len += n;

        var off: usize = 0;
        while (off < self.pending_len and self.running) {
            const chunk = self.pending[off..self.pending_len];
            const used: usize = if (self.prompt != null)
                try handlePromptInput(&self.session, &self.registry, &self.prompt, chunk, &self.running, &self.mb, &self.msg)
            else
                try processInput(&self.session, chunk, 10, &self.running, &self.prompt, &self.help, &self.mb, &self.msg);
            if (used == 0) break; // incomplete escape sequence
            off += used;
        }
        const rem = self.pending_len - off;
        if (rem > 0) std.mem.copyForwards(u8, self.pending[0..rem], self.pending[off..self.pending_len]);
        self.pending_len = rem;
    }
};

fn rowText(s: *render.Screen, y: u16, buf: []u8) []const u8 {
    var n: usize = 0;
    var x: u16 = 0;
    while (x < s.cols) : (x += 1) {
        const c = s.back[@as(usize, y) * s.cols + x];
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(c.ch, &tmp) catch blk: {
            tmp[0] = '?';
            break :blk 1;
        };
        if (n + len > buf.len) break;
        @memcpy(buf[n .. n + len], tmp[0..len]);
        n += len;
    }
    return buf[0..n];
}

test "typing, enter, tab, backspace, delete" {
    var d = try Drive.start("");
    defer d.stop();
    try d.send("abc");
    try std.testing.expectEqualStrings("abc", d.ed().text());
    try d.send("\r");
    try std.testing.expectEqualStrings("abc\n", d.ed().text());
    try d.send("\t");
    try std.testing.expectEqualStrings("abc\n    ", d.ed().text());
    try d.send("\x7f");
    try std.testing.expectEqualStrings("abc\n   ", d.ed().text());
    try d.send("\x1b[3~"); // delete at end: no-op
    try std.testing.expectEqualStrings("abc\n   ", d.ed().text());
}

test "movement: arrows, home, end, word, page" {
    var d = try Drive.start("one two three\nfour\nfive");
    defer d.stop();
    try d.send("\x1b[C\x1b[C");
    try std.testing.expectEqual(@as(usize, 2), d.ed().cursor);
    try d.send("\x1b[1;5C"); // Ctrl+Right -> after "one "
    try std.testing.expectEqual(@as(usize, 4), d.ed().cursor);
    try d.send("\x1b[F"); // End
    try std.testing.expectEqual(@as(usize, 13), d.ed().cursor);
    try d.send("\x1b[H"); // Home
    try std.testing.expectEqual(@as(usize, 0), d.ed().cursor);
    try d.send("\x1b[6~"); // PageDown -> last line
    try std.testing.expectEqual(@as(usize, 2), d.ed().rowCol().row);
    try d.send("\x1b[5~"); // PageUp -> first line
    try std.testing.expectEqual(@as(usize, 0), d.ed().rowCol().row);
}

test "selection: extend, collapse, clear" {
    var d = try Drive.start("hello");
    defer d.stop();
    try d.send("\x1b[1;2C\x1b[1;2C"); // Shift+Right x2 -> 0..2
    try std.testing.expectEqual(@as(usize, 2), d.ed().selectionRange().?.end);
    try d.send("\x1b[C"); // plain Right collapses to the end (2)
    try std.testing.expect(d.ed().selectionRange() == null);
    try std.testing.expectEqual(@as(usize, 2), d.ed().cursor);
    try d.send("\x1b[1;2C\x1b[1;2C"); // Shift+Right x2 -> 2..4
    try d.send("\x1b[D"); // plain Left collapses to the start (2)
    try std.testing.expectEqual(@as(usize, 2), d.ed().cursor);
    try d.send("\x1b[1;2C"); // Shift+Right -> 2..3
    try d.send("\x1b\x1b"); // Esc (a lone Esc is only disambiguated by the next byte)
    try std.testing.expect(d.ed().selectionRange() == null);
}

test "copy, cut, paste" {
    var d = try Drive.start("hello world");
    defer d.stop();
    try d.send("\x01"); // Ctrl+A
    try d.send("\x03"); // Ctrl+C
    try std.testing.expectEqualStrings("hello world", d.ed().registerText());
    try d.send("\x18"); // Ctrl+X
    try std.testing.expectEqualStrings("", d.ed().text());
    try d.send("\x16"); // Ctrl+V
    try std.testing.expectEqualStrings("hello world", d.ed().text());
}

test "undo, redo, and redo cleared by a new edit" {
    var d = try Drive.start("");
    defer d.stop();
    try d.send("abc def");
    try d.send("\x1a"); // Ctrl+Z
    try std.testing.expectEqualStrings("", d.ed().text());
    try d.send("\x19"); // Ctrl+Y
    try std.testing.expectEqualStrings("abc def", d.ed().text());
    try d.send("\x1a"); // Ctrl+Z
    try d.send("X"); // new edit clears redo
    try d.send("\x19"); // Ctrl+Y: no-op
    try std.testing.expectEqualStrings("X", d.ed().text());
}

test "duplicate line" {
    var d = try Drive.start("alpha\nbeta");
    defer d.stop();
    try d.send("\x04"); // Ctrl+D
    try std.testing.expectEqualStrings("alpha\nalpha\nbeta", d.ed().text());
}

test "stress: many edits, undos and redos stay consistent" {
    var d = try Drive.start("alpha\nbeta\ngamma");
    defer d.stop();
    var s = try render.Screen.init(std.testing.allocator, 40, 8);
    defer s.deinit();

    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try d.send("x");
        try d.send("\r");
        try d.send("\x7f"); // backspace
        draw(&s, &d.session, "", null, false);
    }
    i = 0;
    while (i < 120) : (i += 1) {
        try d.send("\x1a"); // undo past the beginning
        draw(&s, &d.session, "", null, false);
    }
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma", d.ed().text());
    i = 0;
    while (i < 120) : (i += 1) {
        try d.send("\x19"); // redo past the end
        draw(&s, &d.session, "", null, false);
    }
    // A fresh edit after all that must not corrupt the buffer.
    try d.send("Z");
    draw(&s, &d.session, "", null, false);
    try d.send("\x1a");
    draw(&s, &d.session, "", null, false);
}

/// Open `name` from `dir` through the picker, as the UI layer would.
fn openViaPicker(session: *Session, allocator: std.mem.Allocator, dir: []const u8, name: []const u8) !void {
    var slot: ?picker.Picker = picker.Picker.init(allocator);
    defer closePicker(&slot);
    const p = &slot.?;
    p.setDir(dir);
    try p.add(name, false);
    p.refilter();
    var mb: [96]u8 = undefined;
    var msg: []const u8 = "";
    var registry = syntax.Registry.init(allocator);
    defer registry.deinit();
    try acceptPicker(session, &slot, .open_file, &registry, &mb, &msg);
}

test "save-as prompt, and Ctrl+O asks for the file picker" {
    var d = try Drive.start("");
    defer d.stop();

    try d.send("\x13"); // Ctrl+S on an unnamed buffer -> Save as prompt
    try std.testing.expect(d.prompt != null);
    try std.testing.expectEqual(PromptKind.save_as, d.prompt.?.kind);
    try d.send("ab");
    try std.testing.expectEqualStrings("ab", d.prompt.?.buf[0..d.prompt.?.len]);
    try d.send("\x7f"); // Backspace edits the path
    try std.testing.expectEqualStrings("a", d.prompt.?.buf[0..d.prompt.?.len]);
    try d.send("\x1b"); // Esc cancels
    try std.testing.expect(d.prompt == null);

    // Ctrl+O is the open action: it raises a request for the UI picker.
    try d.send("\x0f");
    try std.testing.expect(d.prompt == null);
    try std.testing.expectEqual(UiRequest.open_picker, d.session.ui_request.?);
}

test "render shows text, gutter and selection" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    try session.add(null, "hello\nworld", null);
    var s = try render.Screen.init(std.testing.allocator, 20, 5);
    defer s.deinit();

    draw(&s, &session, "", null, false);
    var buf: [64]u8 = undefined;
    const r1 = rowText(&s, 1, &buf); // row 0 is the tab bar
    try std.testing.expect(std.mem.indexOf(u8, r1, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "1") != null); // gutter

    session.current().selectAll();
    draw(&s, &session, "", null, false);
    // First text cell (gutter is 2 wide for 2 lines) carries the selection bg.
    const sel_bg = switch (s.back[1 * s.cols + 2].bg) {
        .default => false,
        else => true,
    };
    try std.testing.expect(sel_bg);
}

test "promptDir extracts the directory part of a path" {
    try std.testing.expectEqualStrings(".", promptDir("foo"));
    try std.testing.expectEqualStrings("src/", promptDir("src/ma"));
    try std.testing.expectEqualStrings("a/b/", promptDir("a/b/c"));
    try std.testing.expectEqualStrings("C:\\x\\", promptDir("C:\\x\\y"));
    try std.testing.expectEqualStrings(".", promptDir(""));
}

test "ctrl+? and F1 toggle help" {
    var d = try Drive.start("x");
    defer d.stop();
    try d.send("\x1f"); // Ctrl+?
    try std.testing.expect(d.help);
    try d.send("\x1f");
    try std.testing.expect(!d.help);
    try d.send("\x1bOP"); // F1
    try std.testing.expect(d.help);
}

test "os.writeFile and readFileAlloc round-trip" {
    const allocator = std.testing.allocator;
    defer os.deleteFile("mibi-test.tmp") catch {};
    try os.writeFile("mibi-test.tmp", "hello world");
    const data = try os.readFileAlloc(allocator, "mibi-test.tmp", 1024);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("hello world", data);
}

test "unicode cell widths" {
    try std.testing.expectEqual(@as(u8, 1), width.cellWidth('a'));
    try std.testing.expectEqual(@as(u8, 1), width.cellWidth(0x00E9)); // e-acute
    try std.testing.expectEqual(@as(u8, 2), width.cellWidth(0x4E2D)); // CJK
    try std.testing.expectEqual(@as(u8, 2), width.cellWidth(0x1F600)); // emoji
    try std.testing.expectEqual(@as(u8, 0), width.cellWidth(0x0301)); // combining
}

test "wide characters occupy two cells" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    try session.add(null, "\u{4E2D}x", null);
    var s = try render.Screen.init(std.testing.allocator, 10, 3);
    defer s.deinit();
    draw(&s, &session, "", null, false);
    const base = 1 * s.cols; // row 1: first text row (row 0 is the tab bar)
    try std.testing.expectEqual(@as(u21, 0x4E2D), s.back[base + 2].ch);
    try std.testing.expect(s.back[base + 3].cont);
    try std.testing.expectEqual(@as(u21, 'x'), s.back[base + 4].ch);
}

test "find, replace and goto" {
    var d = try Drive.start("one two one two one");
    defer d.stop();

    // Ctrl+F then type "two" jumps to the first match at offset 4.
    try d.send("\x06");
    try d.send("two");
    try std.testing.expectEqual(@as(usize, 4), d.ed().cursor);
    try d.send("\r"); // accept

    try d.send("\x1bOR"); // F3 -> next
    try std.testing.expectEqual(@as(usize, 12), d.ed().cursor);
    try d.send("\x1b[1;2R"); // Shift+F3 -> previous
    try std.testing.expectEqual(@as(usize, 4), d.ed().cursor);

    // Ctrl+G, go to line 1 column 1.
    try d.send("\x07");
    try d.send("1:1");
    try d.send("\r");
    try std.testing.expectEqual(@as(usize, 0), d.ed().cursor);

    // Ctrl+R replaces every "one" with "1".
    try d.send("\x12");
    try d.send("one");
    try d.send("\r");
    try d.send("1");
    try d.send("\r");
    try std.testing.expectEqualStrings("1 two 1 two 1", d.ed().text());
}

// --- hardening regressions: prompts, file safety, unicode status bar --------

test "arrow keys in a prompt are ignored, not treated as cancel" {
    var d = try Drive.start("");
    defer d.stop();
    try d.send("\x06"); // Ctrl+F -> find prompt
    try std.testing.expect(d.prompt != null);
    try d.send("src");
    try d.send("\x1b[C"); // Right
    try std.testing.expect(d.prompt != null);
    try std.testing.expectEqualStrings("src", d.prompt.?.buf[0..d.prompt.?.len]);
    try d.send("\x1b[1;5D"); // Ctrl+Left
    try std.testing.expect(d.prompt != null);
    try d.send("\x1bOP"); // F1
    try std.testing.expect(d.prompt != null);
    try d.send("\x1b"); // a lone Esc still cancels
    try std.testing.expect(d.prompt == null);
}

test "quit asks before discarding unsaved changes" {
    var d = try Drive.start("");
    defer d.stop();
    try d.send("abc"); // dirty
    try d.send("\x11"); // Ctrl+Q
    try std.testing.expect(d.prompt != null);
    try std.testing.expectEqual(PromptKind.confirm_quit, d.prompt.?.kind);
    try std.testing.expect(d.running);

    try d.send("n"); // no: stay
    try std.testing.expect(d.prompt == null);
    try std.testing.expect(d.running);
    try std.testing.expectEqualStrings("abc", d.ed().text());

    try d.send("\x11");
    try d.send("y"); // yes: quit without saving
    try std.testing.expect(!d.running);
}

test "quit on a clean buffer does not ask" {
    var d = try Drive.start("already saved");
    defer d.stop();
    try d.send("\x11"); // Ctrl+Q
    try std.testing.expect(!d.running);
    try std.testing.expect(d.prompt == null);
}

test "a mouse click places the cursor and the wheel moves one line" {
    var d = try Drive.start("one\ntwo\nthree\nfour\nfive");
    defer d.stop();
    var help = false;
    var pr: ?Prompt = null;
    var mb: [96]u8 = undefined;
    var msg: []const u8 = "";

    // Screen row 3 is the second text line; column 4 is after the "1 " gutter.
    handleMouse(&d.session, "<0;4;3", 'M', &help, &pr, &mb, &msg);
    const rc = d.ed().rowCol();
    try std.testing.expectEqual(@as(usize, 1), rc.row);
    try std.testing.expectEqual(@as(usize, 1), rc.col);

    // One wheel notch is one line (over the text area; the tab bar scrolls).
    handleMouse(&d.session, "<65;1;3", 'M', &help, &pr, &mb, &msg);
    try std.testing.expectEqual(@as(usize, 2), d.ed().rowCol().row);
    handleMouse(&d.session, "<64;1;3", 'M', &help, &pr, &mb, &msg);
    try std.testing.expectEqual(@as(usize, 1), d.ed().rowCol().row);
}

test "the command palette lists actions and runs the chosen one" {
    var d = try Drive.start("one");
    defer d.stop();
    try d.send("\x10"); // Ctrl+P
    try std.testing.expect(d.prompt == null);
    try std.testing.expectEqual(UiRequest.command_palette, d.session.ui_request.?);

    // Accepting an entry asks the run loop to execute that action.
    var slot: ?picker.Picker = picker.Picker.init(std.testing.allocator);
    defer closePicker(&slot);
    const p = &slot.?;
    try p.add("new_tab", false);
    p.refilter();
    var mb: [96]u8 = undefined;
    var msg: []const u8 = "";
    var registry = syntax.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try acceptPicker(&d.session, &slot, .commands, &registry, &mb, &msg);
    try std.testing.expectEqual(keys.Action.new_tab, d.session.ui_action.?);
}

test "the file picker opens into a new tab without discarding the current one" {
    var d = try Drive.start("dirty");
    defer d.stop();
    try d.send("x"); // dirty
    try std.testing.expectEqualStrings("xdirty", d.ed().text());

    const path = "mibi-picker-open.tmp";
    defer os.deleteFile(path) catch {};
    try os.writeFile(path, "picked\n");
    try openViaPicker(&d.session, std.testing.allocator, ".", path);

    try std.testing.expectEqual(@as(usize, 2), d.session.count());
    try std.testing.expectEqualStrings("picked\n", d.session.current().text());
    try std.testing.expectEqualStrings(path, d.session.current().path.?);
}

test "tabs can be reordered" {
    var d = try Drive.start("one");
    defer d.stop();
    try d.send("\x14"); // Ctrl+T: second tab
    try std.testing.expectEqual(@as(usize, 2), d.session.count());
    d.session.moveTab(0, 1);
    try std.testing.expectEqual(@as(usize, 1), d.session.active);
    try std.testing.expectEqualStrings("one", d.session.current().text());
    try std.testing.expectEqualStrings("", d.session.docs.items[0].text());
}

test "ctrl+t adds a tab and ctrl+w closes it" {
    var d = try Drive.start("one");
    defer d.stop();
    try d.send("\x14"); // Ctrl+T
    try std.testing.expectEqual(@as(usize, 2), d.session.count());
    try std.testing.expectEqualStrings("", d.ed().text());
    try d.send("two");
    try std.testing.expectEqualStrings("two", d.ed().text());

    try d.send("\x17"); // Ctrl+W on a dirty tab asks first
    try std.testing.expectEqual(PromptKind.confirm_close, d.prompt.?.kind);
    try d.send("n");
    try std.testing.expectEqual(@as(usize, 2), d.session.count());

    try d.send("\x17");
    try d.send("y");
    try std.testing.expectEqual(@as(usize, 1), d.session.count());
    try std.testing.expectEqualStrings("one", d.ed().text());
}

test "ctrl+pgup and ctrl+pgdn cycle tabs" {
    var d = try Drive.start("one");
    defer d.stop();
    try d.send("\x14");
    try d.send("two");
    try std.testing.expectEqualStrings("two", d.ed().text());
    try d.send("\x1b[5;5~"); // Ctrl+PgUp
    try std.testing.expectEqualStrings("one", d.ed().text());
    try d.send("\x1b[6;5~"); // Ctrl+PgDn
    try std.testing.expectEqualStrings("two", d.ed().text());
}

test "closing the last tab quits" {
    var d = try Drive.start("only");
    defer d.stop();
    try d.send("\x17"); // Ctrl+W on a clean, last tab
    try std.testing.expect(!d.running);
    try std.testing.expectEqual(@as(usize, 0), d.session.count());
}

test "quit asks when a background tab is dirty" {
    var d = try Drive.start("one");
    defer d.stop();
    try d.send("x"); // tab 0 dirty
    try d.send("\x14"); // tab 1, clean
    try std.testing.expect(!d.ed().dirty);
    try d.send("\x11"); // Ctrl+Q
    try std.testing.expectEqual(PromptKind.confirm_quit, d.prompt.?.kind);
    try d.send("n");
    try std.testing.expect(d.running);
}

test "syntax highlighting colours keywords and comments" {
    var d = try Drive.start("const x = 1; // note");
    defer d.stop();
    _ = d.registry.loadDir("syntax.d");
    try std.testing.expect(d.registry.langs.items.len > 0);
    const lang = d.registry.find("x.zig") orelse return error.TestUnexpectedResult;
    d.session.current().setLanguage(lang);
    try std.testing.expect(d.session.current().lang != null);
    // Move the cursor off the first cell: the block cursor overpaints it.
    d.session.current().cursor = d.session.current().buf.len();

    var s = try render.Screen.init(std.testing.allocator, 40, 6);
    defer s.deinit();
    draw(&s, &d.session, "", null, false);

    const base = 1 * s.cols; // row 0 is the tab bar, row 1 the first line
    const kw = s.back[base + 2].fg; // "const"
    const plain = s.back[base + 8].fg; // "x"
    const comment = s.back[base + 15].fg; // "// note"
    try std.testing.expect(!std.meta.eql(kw, plain));
    try std.testing.expect(!std.meta.eql(comment, plain));
    try std.testing.expect(!std.meta.eql(kw, comment));
}

test "block comment state carries down the visible rows" {
    var d = try Drive.start("/* one\ntwo */\nint x;");
    defer d.stop();
    _ = d.registry.loadDir("syntax.d");
    d.session.current().setLanguage(d.registry.find("x.c"));

    var s = try render.Screen.init(std.testing.allocator, 40, 6);
    defer s.deinit();
    draw(&s, &d.session, "", null, false);

    const in_comment = s.back[2 * s.cols + 2].fg; // "two */" on row 2
    const keyword = s.back[3 * s.cols + 2].fg; // "int" on row 3
    try std.testing.expect(!std.meta.eql(in_comment, keyword));
}

test "an edit that opens a block comment re-colours the lines below" {
    var d = try Drive.start("int a;\nint b;");
    defer d.stop();
    _ = d.registry.loadDir("syntax.d");
    const ed = d.session.current();
    ed.setLanguage(d.registry.find("x.c"));

    var s = try render.Screen.init(std.testing.allocator, 40, 6);
    defer s.deinit();

    draw(&s, &d.session, "", null, false);
    const row = 2 * s.cols; // row 2 is the second line
    const before = s.back[row + 2].fg;

    ed.cursor = 0;
    try ed.insertText("/*"); // everything after this is now a comment
    draw(&s, &d.session, "", null, false);
    const after = s.back[row + 2].fg;
    try std.testing.expect(!std.meta.eql(before, after));
}

test "the config theme colours the text" {
    var d = try Drive.start("hello");
    defer d.stop();
    d.session.config.theme.text = .{ .rgb = .{ .r = 0xff, .g = 0x00, .b = 0x00 } };
    var s = try render.Screen.init(std.testing.allocator, 20, 4);
    defer s.deinit();
    draw(&s, &d.session, "", null, false);
    const cell = s.back[1 * s.cols + 2]; // row 1, first text cell (gutter is 2)
    const fg = switch (cell.fg) {
        .rgb => |c| c,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 0xff), fg.r);
}

test "line numbers can be turned off" {
    var d = try Drive.start("hello");
    defer d.stop();
    d.session.config.line_numbers = false;
    var s = try render.Screen.init(std.testing.allocator, 20, 4);
    defer s.deinit();
    draw(&s, &d.session, "", null, false);
    var buf: [32]u8 = undefined;
    const row = rowText(&s, 1, &buf);
    try std.testing.expect(std.mem.startsWith(u8, row, "hello"));
}

test "the config tab width drives the cursor column" {
    var d = try Drive.start("\tx");
    defer d.stop();
    d.session.current().cursor = 1;
    d.session.current().tab_width = 2;
    try std.testing.expectEqual(@as(usize, 2), d.session.current().cursorDisplayCol());
    d.session.current().tab_width = 8;
    try std.testing.expectEqual(@as(usize, 8), d.session.current().cursorDisplayCol());
}

test "a config binding reaches the editor" {
    var d = try Drive.start("one");
    defer d.stop();
    config_mod.apply(&d.session.config,
        \\[keys]
        \\ctrl+n = new_tab
    );
    try d.send("\x0e"); // Ctrl+N is now new_tab
    try std.testing.expectEqual(@as(usize, 2), d.session.count());
}

test "a byte key can trigger a movement action" {
    var d = try Drive.start("a\nb\nc");
    defer d.stop();
    d.session.config.keys.add("ctrl+u", .move_down);
    try d.send("\x15"); // Ctrl+U -> move_down
    try std.testing.expectEqual(@as(usize, 1), d.session.current().rowCol().row);
}

test "a function key can trigger a byte action" {
    var d = try Drive.start("x");
    defer d.stop();
    d.session.config.keys.add("f1", .save);
    try d.send("\x1bOP"); // F1 -> save (unnamed buffer asks for a name)
    try std.testing.expect(d.prompt != null);
    try std.testing.expectEqual(PromptKind.save_as, d.prompt.?.kind);
}

test "a binding overrides the default action" {
    var d = try Drive.start("one");
    defer d.stop();
    d.session.config.keys.add("ctrl+t", .save); // was new_tab
    try d.send("\x14");
    try std.testing.expectEqual(@as(usize, 1), d.session.count());
    try std.testing.expect(d.prompt != null);
    try std.testing.expectEqual(PromptKind.save_as, d.prompt.?.kind);
}

test "the tab bar shows every open document" {
    var d = try Drive.start("one");
    defer d.stop();
    try d.send("\x14"); // Ctrl+T: a second, empty document
    var s = try render.Screen.init(std.testing.allocator, 40, 6);
    defer s.deinit();

    draw(&s, &d.session, "", null, false);
    var buf: [128]u8 = undefined;
    const bar = rowText(&s, 0, &buf);
    // " name " + pad + x + pad, then one blank cell before the next tab.
    try std.testing.expect(std.mem.indexOf(u8, bar, " [No Name]  x   [No Name]  x ") != null);
    try d.send("\x1b[5;5~"); // Ctrl+PgUp back to the first document
    draw(&s, &d.session, "", null, false);
    // The first document row starts one line below the tab bar.
    const text_row = rowText(&s, 1, &buf);
    try std.testing.expect(std.mem.indexOf(u8, text_row, "1 one") != null);
}

test "a tab keeps a cell of padding after its close button" {
    var d = try Drive.start("one");
    defer d.stop();
    var s = try render.Screen.init(std.testing.allocator, 40, 6);
    defer s.deinit();
    draw(&s, &d.session, "", null, false);

    var buf: [128]u8 = undefined;
    const bar = rowText(&s, 0, &buf);
    try std.testing.expect(std.mem.indexOf(u8, bar, " [No Name]  x ") != null);
    // The x is not the tab's last cell: one cell of the tab's background
    // follows it, so it does not touch the edge.
    const close_x = d.session.tab_close_x[0];
    try std.testing.expect(close_x != 0xFFFF);
    try std.testing.expect(close_x + 1 < d.session.tab_spans[0][1]);
    try std.testing.expectEqual(@as(u16, 14), d.session.tab_spans[0][1]);
}

test "the tab strip scrolls to keep the active tab visible" {
    var d = try Drive.start("one");
    defer d.stop();
    var i: usize = 0;
    while (i < 12) : (i += 1) try d.send("\x14"); // Ctrl+T: many tabs
    var s = try render.Screen.init(std.testing.allocator, 40, 6);
    defer s.deinit();
    draw(&s, &d.session, "", null, false);

    // Too many tabs for 40 columns: the strip scrolls and shows both arrows.
    try std.testing.expect(d.session.tab_scroll_max > 0);
    try std.testing.expectEqual(@as(u16, 0), d.session.tab_prev_x);
    try std.testing.expect(d.session.tab_next_x != 0xFFFF);
    // The last tab (the active one) is visible; the first one is scrolled off.
    try std.testing.expect(d.session.tab_spans[12][0] != 0xFFFF);
    try std.testing.expect(d.session.tab_spans[0][0] == 0xFFFF);
    try std.testing.expect(d.session.tab_scroll > 0);

    // Scrolling left by hand walks back one tab at a time.
    const before = d.session.tab_scroll;
    d.session.scrollTabs(-1);
    try std.testing.expect(d.session.tab_scroll < before);
    while (d.session.tab_scroll > 0) d.session.scrollTabs(-1);
    draw(&s, &d.session, "", null, false);
    try std.testing.expectEqual(@as(usize, 0), d.session.tab_scroll);
    try std.testing.expect(d.session.tab_spans[0][0] != 0xFFFF);

    // Cycling tabs scrolls the strip back to the active one.
    try d.send("\x1b[5;5~"); // Ctrl+PgUp
    draw(&s, &d.session, "", null, false);
    try std.testing.expect(d.session.tab_spans[d.session.active][0] != 0xFFFF);
}

test "hovering a tab button highlights it" {
    var d = try Drive.start("one");
    defer d.stop();
    var s = try render.Screen.init(std.testing.allocator, 40, 6);
    defer s.deinit();
    var help = false;
    var pr: ?Prompt = null;
    var mb: [64]u8 = undefined;
    var msg: []const u8 = "";

    draw(&s, &d.session, "", null, false);
    const close_x = d.session.tab_close_x[0];
    const plus_x = d.session.new_tab_x;
    const plain_x = s.back[close_x].bg;
    const plain_plus = s.back[plus_x].bg;

    var params_buf: [32]u8 = undefined;
    var params = try std.fmt.bufPrint(&params_buf, "<35;{d};1", .{close_x + 1});
    handleMouse(&d.session, params, 'M', &help, &pr, &mb, &msg);
    try std.testing.expectEqual(@as(?usize, 0), d.session.hover_close);
    draw(&s, &d.session, "", null, false);
    try std.testing.expect(!std.meta.eql(s.back[close_x].bg, plain_x));

    params = try std.fmt.bufPrint(&params_buf, "<35;{d};1", .{plus_x + 1});
    handleMouse(&d.session, params, 'M', &help, &pr, &mb, &msg);
    try std.testing.expect(d.session.hover_plus);
    draw(&s, &d.session, "", null, false);
    try std.testing.expect(!std.meta.eql(s.back[plus_x].bg, plain_plus));
    try std.testing.expectEqual(@as(?usize, null), d.session.hover_close); // moved away

    // Leaving the bar clears the highlight.
    handleMouse(&d.session, "<35;5;5", 'M', &help, &pr, &mb, &msg);
    try std.testing.expect(!d.session.hover_plus);
    draw(&s, &d.session, "", null, false);
    try std.testing.expect(std.meta.eql(plain_plus, s.back[plus_x].bg));
}

test "a click on a tab is not a drag" {
    var d = try Drive.start("one");
    defer d.stop();
    try d.send("\x14"); // a second tab
    var s = try render.Screen.init(std.testing.allocator, 40, 6);
    defer s.deinit();
    draw(&s, &d.session, "", null, false);
    var help = false;
    var pr: ?Prompt = null;
    var mb: [64]u8 = undefined;
    var msg: []const u8 = "";

    // Press on the second tab and jiggle by one cell: still just a click.
    handleMouse(&d.session, "<0;18;1", 'M', &help, &pr, &mb, &msg);
    try std.testing.expect(d.session.press_tab != null);
    try std.testing.expect(d.session.drag_tab == null);
    handleMouse(&d.session, "<32;19;1", 'M', &help, &pr, &mb, &msg);
    try std.testing.expect(d.session.drag_tab == null);
    handleMouse(&d.session, "<0;19;1", 'm', &help, &pr, &mb, &msg);
    try std.testing.expect(d.session.drag_tab == null);
    try std.testing.expect(d.session.press_tab == null);

    // A real move promotes the press to a drag.
    handleMouse(&d.session, "<0;18;1", 'M', &help, &pr, &mb, &msg);
    handleMouse(&d.session, "<32;22;1", 'M', &help, &pr, &mb, &msg);
    try std.testing.expect(d.session.drag_tab != null);
}

test "the close button on the last tab asks to quit instead of crashing" {
    var d = try Drive.start("one");
    defer d.stop();
    var s = try render.Screen.init(std.testing.allocator, 40, 6);
    defer s.deinit();
    draw(&s, &d.session, "", null, false);
    var help = false;
    var pr: ?Prompt = null;
    var mb: [64]u8 = undefined;
    var msg: []const u8 = "";

    var params_buf: [32]u8 = undefined;
    const params = try std.fmt.bufPrint(&params_buf, "<0;{d};1", .{d.session.tab_close_x[0] + 1});
    handleMouse(&d.session, params, 'M', &help, &pr, &mb, &msg);
    try std.testing.expectEqual(@as(usize, 0), d.session.count());
    try std.testing.expect(d.session.quit_requested);

    // The release (or any other event) in the same chunk must not reach the
    // document that is now gone.
    handleMouse(&d.session, "<0;5;3", 'M', &help, &pr, &mb, &msg);
    try std.testing.expectEqual(@as(usize, 0), d.session.count());
}


test "the console close handler writes the session" {
    var d = try Drive.start("hello");
    defer d.stop();
    try d.send("X"); // unsaved edit
    g_session = &d.session;
    defer g_session = null;
    defer os.deleteFile("mibi-session") catch {};
    saveSessionOnClose();
    const data = os.readFileAlloc(std.testing.allocator, "mibi-session", 1 << 20) catch return error.SkipZigTest;
    defer std.testing.allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "tab ") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "active 0") != null);
}

test "ctrl+alt+down adds a cursor and typing edits every line" {
    var d = try Drive.start("one\ntwo\nthree");
    defer d.stop();
    try d.send("\x1b[1;7B"); // Ctrl+Alt+Down
    try std.testing.expect(d.session.current().hasCursors());
    try d.send("X");
    try std.testing.expectEqualStrings("Xone\nXtwo\nthree", d.session.current().text());
    try d.send("Y");
    try std.testing.expectEqualStrings("XYone\nXYtwo\nthree", d.session.current().text());

    // Esc drops the extra cursors; the next key is typed once.
    try d.send("\x1bq");
    try std.testing.expect(!d.session.current().hasCursors());
    try std.testing.expectEqualStrings("XYqone\nXYtwo\nthree", d.session.current().text());
}

test "backspace deletes at every cursor" {
    var d = try Drive.start("aa\nbb");
    defer d.stop();
    try d.send("\x1b[1;7B"); // cursor on the second line
    try std.testing.expect(d.session.current().hasCursors());
    try d.send("\x1b[C"); // both cursors one cell right
    try d.send("\x7f"); // and one backspace each
    try std.testing.expectEqualStrings("a\nb", d.session.current().text());
}

test "F4 runs the configured formatter and replaces the buffer" {
    const path = "mibi-format-test.txt";
    defer os.deleteFile(path) catch {};
    try os.writeFile(path, "b\na\n");
    var d = try Drive.start("");
    defer d.stop();
    try openViaPicker(&d.session, std.testing.allocator, ".", path);

    // `findstr /n` numbers the lines: a deterministic stand-in for a formatter
    // that really runs a child process and really replaces the buffer.
    const cmd = if (os.is_windows) "cmd.exe /c findstr /n ." else "cat -n";
    var rule = &d.session.config.format_rules[0];
    @memcpy(rule.ext[0..3], "txt");
    rule.ext_len = 3;
    @memcpy(rule.cmd[0..cmd.len], cmd);
    rule.cmd_len = cmd.len;
    d.session.config.format_count = 1;

    try d.send("\x1b[14~"); // F4
    const text = d.session.current().text();
    try std.testing.expect(std.mem.indexOf(u8, text, "1:b") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2:a") != null);
    try std.testing.expect(d.session.current().dirty);
    try std.testing.expect(std.mem.indexOf(u8, d.msg, "Formatted") != null);
}

test "formatting without a configured tool says so" {
    var d = try Drive.start("x");
    defer d.stop();
    try d.send("\x1b[14~"); // F4, no path and no rule
    try std.testing.expect(std.mem.indexOf(u8, d.msg, "formatter") != null);
    // Nothing was changed.
    try std.testing.expectEqualStrings("x", d.session.current().text());
}

test "esc closes the help panel" {
    var d = try Drive.start("one");
    defer d.stop();
    try d.send("\x1f"); // Ctrl+? opens help
    try std.testing.expect(d.help);
    try d.send("\x1b"); // Esc, alone in its chunk
    try std.testing.expect(!d.help);

    // With the panel closed, a lone Esc still waits for the next byte, so a
    // split arrow sequence cannot be mistaken for it.
    try d.send("\x1b");
    try std.testing.expect(!d.help);
}










test "a failed save-as keeps the old path and the dirty flag" {
    var d = try Drive.start("x");
    defer d.stop();
    try d.send("y"); // make the buffer dirty
    try d.send("\x13"); // Ctrl+S on an unnamed buffer -> Save as
    try d.send("no-such-dir/out.txt");
    try d.send("\r");
    try std.testing.expect(d.prompt == null);
    try std.testing.expect(d.ed().path == null); // unchanged
    try std.testing.expect(d.ed().dirty);
    try std.testing.expect(std.mem.indexOf(u8, d.msg, "Save failed") != null);
}

test "save writes the file, then open reads it back in a new tab" {
    const path = "mibi-save-test.tmp";
    const other = "mibi-open-test.tmp";
    defer os.deleteFile(path) catch {};
    defer os.deleteFile(other) catch {};
    try os.writeFile(other, "other file\n");

    var d = try Drive.start("");
    defer d.stop();
    try d.send("hello\nworld");
    try d.send("\x13"); // Ctrl+S -> Save as (unnamed)
    try d.send(path);
    try d.send("\r");
    try std.testing.expect(d.prompt == null);
    try std.testing.expectEqualStrings(path, d.ed().path.?);
    try std.testing.expect(!d.ed().dirty);

    const data = try os.readFileAlloc(std.testing.allocator, path, 1024);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("hello\nworld", data);

    // Change the buffer, then open another file: it gets its own tab.
    try d.send("!!!");
    try openViaPicker(&d.session, std.testing.allocator, ".", other);
    try std.testing.expectEqual(@as(usize, 2), d.session.count());
    try std.testing.expectEqualStrings("other file\n", d.ed().text());
    try std.testing.expectEqualStrings(other, d.ed().path.?);

    // Opening a file that is already open switches to its tab instead.
    try openViaPicker(&d.session, std.testing.allocator, ".", path);
    try std.testing.expectEqual(@as(usize, 2), d.session.count());
    try std.testing.expectEqualStrings("hello\nworld!!!", d.ed().text());
}

test "a split arrow key in a prompt is held, not typed" {
    var d = try Drive.start("");
    defer d.stop();
    try d.send("\x06"); // Ctrl+F -> find prompt
    try d.send("ab");
    try d.send("\x1b[1;5"); // incomplete Ctrl+Left
    try std.testing.expect(d.prompt != null);
    try std.testing.expectEqualStrings("ab", d.prompt.?.buf[0..d.prompt.?.len]);
    try d.send("D"); // completes the sequence: ignored, not typed
    try std.testing.expect(d.prompt != null);
    try std.testing.expectEqualStrings("ab", d.prompt.?.buf[0..d.prompt.?.len]);
}

test "bytes after a prompt closes in the same chunk are edited into the buffer" {
    var d = try Drive.start("");
    defer d.stop();
    try d.send("\x07"); // Ctrl+G
    try std.testing.expect(d.prompt != null);
    // Enter accepts the go-to and the trailing X is ordinary editing input.
    try d.send("2\rX");
    try std.testing.expect(d.prompt == null);
    try std.testing.expectEqualStrings("X", d.ed().text());
}

test "readFileAlloc reports a missing file distinctly" {
    const err = os.readFileAlloc(std.testing.allocator, "mibi-no-such-file.tmp", 1024);
    try std.testing.expectError(error.FileNotFound, err);
}

test "putStr decodes utf-8 and honours display width" {
    var s = try render.Screen.init(std.testing.allocator, 8, 1);
    defer s.deinit();
    s.clear();
    s.putStr(0, 0, "caf\u{00e9} \u{4e2d}", .{});
    try std.testing.expectEqual(@as(u21, 'c'), s.back[0].ch);
    try std.testing.expectEqual(@as(u21, 0x00e9), s.back[3].ch);
    try std.testing.expectEqual(@as(u21, ' '), s.back[4].ch);
    try std.testing.expectEqual(@as(u21, 0x4e2d), s.back[5].ch);
    try std.testing.expect(s.back[6].cont);
}

test "an open prompt is not hidden by the help panel" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    try session.add(null, "x", null);
    var s = try render.Screen.init(std.testing.allocator, 40, 8);
    defer s.deinit();
    const p: Prompt = .{ .kind = .find };
    draw(&s, &session, "", p, true);
    var buf: [64]u8 = undefined;
    const last = rowText(&s, 7, &buf);
    try std.testing.expect(std.mem.indexOf(u8, last, "Find: ") != null);
}

test "a non-ascii file name renders as text in the status bar" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    try session.add("caf\u{00e9}.txt", "x", null);
    var s = try render.Screen.init(std.testing.allocator, 40, 3);
    defer s.deinit();
    draw(&s, &session, "", null, false);
    var buf: [128]u8 = undefined;
    const status = rowText(&s, 2, &buf);
    try std.testing.expect(std.mem.indexOf(u8, status, "caf\u{00e9}.txt") != null);
}


test "splitting duplicates the view, not the buffer" {
    var d = try Drive.start("one\ntwo");
    defer d.stop();
    try d.send("\x1b[15~"); // F5
    // No buffer is created: the same document gets a second view.
    try std.testing.expectEqual(@as(usize, 1), d.session.count());
    try std.testing.expectEqual(@as(usize, 2), d.session.panes.live);
    const a = d.session.docIndex(d.session.panes.nodes[d.session.panes.leaves[0]].doc).?;
    const b = d.session.docIndex(d.session.panes.nodes[d.session.panes.leaves[1]].doc).?;
    try std.testing.expectEqual(a, b);

    var s = try render.Screen.init(std.testing.allocator, 40, 10);
    defer s.deinit();
    draw(&s, &d.session, "", null, false);
    try std.testing.expectEqual(@as(usize, 2), d.session.panes.rect_count);
    try std.testing.expectEqual(@as(usize, 1), d.session.panes.sep_count);
    try std.testing.expectEqual(@as(u21, 0x2502), s.back[1 * s.cols + d.session.panes.seps[0].x].ch);
    try std.testing.expectEqual(@as(usize, 0), d.session.panes.rects[0].rect.x);
    try std.testing.expectEqual(@as(usize, 20), d.session.panes.rects[1].rect.x);
}

test "each pane keeps its own cursor" {
    var d = try Drive.start("a\nb\nc\nd\ne");
    defer d.stop();
    try d.send("\x1b[15~"); // F5: two views of the same file
    var s = try render.Screen.init(std.testing.allocator, 40, 10);
    defer s.deinit();
    draw(&s, &d.session, "", null, false);
    // Move down in the focused (right) view.
    try d.send("\x1b[B");
    try d.send("\x1b[B");
    const right = d.session.current().cursor;
    try d.send("\x1b[17~"); // F6 -> the left view, which stayed at the top
    draw(&s, &d.session, "", null, false);
    try std.testing.expect(d.session.current().cursor != right);
    try d.send("\x1b[17~"); // back
    draw(&s, &d.session, "", null, false);
    try std.testing.expectEqual(right, d.session.current().cursor);
}

test "closing a pane keeps the document open" {
    var d = try Drive.start("one\ntwo");
    defer d.stop();
    try d.send("\x1b[15~"); // F5
    try std.testing.expectEqual(@as(usize, 2), d.session.panes.live);
    try d.send("\x1b[15;2~"); // Shift+F5
    try std.testing.expectEqual(@as(usize, 1), d.session.panes.live);
    try std.testing.expectEqual(@as(usize, 1), d.session.count());
    try std.testing.expectEqualStrings("one\ntwo", d.session.current().text());
    // The last pane cannot be closed: there would be nowhere to edit.
    try d.send("\x1b[15;2~");
    try std.testing.expectEqual(@as(usize, 1), d.session.panes.live);
}

test "closing the tab closes every pane showing it" {
    var d = try Drive.start("one");
    defer d.stop();
    try d.send("\x1b[15~"); // two views of the same file
    try std.testing.expectEqual(@as(usize, 2), d.session.panes.live);
    try d.send("\x17"); // Ctrl+W closes the document
    try std.testing.expectEqual(@as(usize, 0), d.session.count());
    try std.testing.expectEqual(@as(usize, 0), d.session.panes.live);
}

test "dropping a tab on a pane edge adds a view there" {
    var d = try Drive.start("one");
    defer d.stop();
    try d.send("\x1b[15~"); // two views
    var s = try render.Screen.init(std.testing.allocator, 40, 10);
    defer s.deinit();
    draw(&s, &d.session, "", null, false);
    const right = d.session.panes.rects[1].node;
    d.session.dropTabIntoPane(0, .{ .node = right, .side = .right });
    draw(&s, &d.session, "", null, false);
    try std.testing.expectEqual(@as(usize, 3), d.session.panes.live);
    try std.testing.expectEqual(@as(usize, 1), d.session.count());
}

test "dragging a tab down into the text splits the view" {
    var d = try Drive.start("one\ntwo");
    defer d.stop();
    var s = try render.Screen.init(std.testing.allocator, 40, 10);
    defer s.deinit();
    draw(&s, &d.session, "", null, false);

    var help = false;
    var pr: ?Prompt = null;
    var mb: [64]u8 = undefined;
    var msg: []const u8 = "";
    handleMouse(&d.session, "<0;3;1", 'M', &help, &pr, &mb, &msg);
    handleMouse(&d.session, "<32;3;6", 'M', &help, &pr, &mb, &msg);
    try std.testing.expect(d.session.drag_tab != null);
    try std.testing.expect(d.session.drop_zone != null);
    handleMouse(&d.session, "<0;3;6", 'm', &help, &pr, &mb, &msg);
    draw(&s, &d.session, "", null, false);
    try std.testing.expectEqual(@as(usize, 2), d.session.panes.live);
    try std.testing.expectEqual(@as(usize, 1), d.session.count());
}

test "F6 moves the focus between panes" {
    var d = try Drive.start("one");
    defer d.stop();
    try d.send("\x1b[15~");
    const right = d.session.panes.focus;
    try d.send("\x1b[17~"); // F6
    try std.testing.expect(d.session.panes.focus != right);
    try d.send("\x1b[17;2~"); // Shift+F6
    try std.testing.expectEqual(right, d.session.panes.focus);
}

test "clicking a pane focuses it and places the cursor there" {
    var d = try Drive.start("one\ntwo\nthree");
    defer d.stop();
    try d.send("\x1b[15~"); // two views
    var s = try render.Screen.init(std.testing.allocator, 40, 10);
    defer s.deinit();
    draw(&s, &d.session, "", null, false);
    const left = d.session.panes.rects[0].node;

    var help = false;
    var pr: ?Prompt = null;
    var mb: [64]u8 = undefined;
    var msg: []const u8 = "";
    // Click the third text row of the left pane (row 4, column 4 on screen).
    handleMouse(&d.session, "<0;4;4", 'M', &help, &pr, &mb, &msg);
    try std.testing.expectEqual(left, d.session.panes.focus);
    try std.testing.expectEqual(@as(usize, 2), d.session.current().rowCol().row);
}
