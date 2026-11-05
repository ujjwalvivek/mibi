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
const config_mod = @import("config.zig");
const keys = @import("keys.zig");

pub const version = "0.0.1";

const MAX_FILE = 64 * 1024 * 1024;

const HelpRow = struct {
    actions: []const keys.Action,
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
    .{ .actions = &.{ .insert_newline, .insert_tab }, .desc = "new line / indent" },
    .{ .actions = &.{ .backspace, .delete_forward }, .desc = "delete" },
    .{ .actions = &.{.save}, .desc = "save" },
    .{ .actions = &.{.open}, .desc = "open file picker" },
    .{ .actions = &.{.theme_picker}, .desc = "theme picker (live preview)" },
    .{ .actions = &.{ .new_tab, .close_tab }, .desc = "new / close tab" },
    .{ .actions = &.{ .next_tab, .prev_tab }, .desc = "next / previous tab" },
    .{ .actions = &.{.help}, .desc = "toggle this help" },
    .{ .actions = &.{.quit}, .desc = "quit (asks if unsaved)" },
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
const UiRequest = enum { open_picker, theme_picker };

const Session = struct {
    allocator: std.mem.Allocator,
    docs: std.ArrayList(*Editor),
    active: usize,
    config: config_mod.Config = .{},
    /// Set by an action that needs the UI layer to open a picker.
    ui_request: ?UiRequest = null,

    fn init(allocator: std.mem.Allocator) Session {
        return .{ .allocator = allocator, .docs = std.ArrayList(*Editor).empty, .active = 0 };
    }

    fn deinit(self: *Session) void {
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
        try self.docs.append(self.allocator, ed);
        self.active = self.docs.items.len - 1;
    }

    /// Close the active tab; the caller quits when the last one goes.
    fn closeActive(self: *Session) void {
        if (self.docs.items.len == 0) return;
        const ed = self.docs.items[self.active];
        ed.deinit();
        self.allocator.destroy(ed);
        _ = self.docs.orderedRemove(self.active);
        if (self.active >= self.docs.items.len and self.docs.items.len > 0) {
            self.active = self.docs.items.len - 1;
        }
    }

    fn cycle(self: *Session, delta: isize) void {
        const n = self.docs.items.len;
        if (n <= 1) return;
        const i: isize = @as(isize, @intCast(self.active)) + delta;
        self.active = @intCast(@mod(i, @as(isize, @intCast(n))));
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
                if (std.mem.eql(u8, p, path)) return i;
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

    var session = Session.init(allocator);
    defer session.deinit();
    session.config = config;
    try session.add(path, initial, registry.find(path));
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

    var input: [256]u8 = undefined;
    var msg_buf: [96]u8 = undefined;
    var msg: []const u8 = "";
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

    while (running) {
        const now = term.size();
        if (now.cols != screen.cols or now.rows != screen.rows) {
            try screen.resize(now.cols, now.rows);
            @memset(screen.front, render.Cell{ .ch = 0, .attr = .{ .bold = true, .underline = true, .reverse = true } });
            try term.write("\x1b[2J");
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

        draw(&screen, &session, msg, prompt, help);
        if (picker_state) |*pk| drawPicker(&screen, pk, picker_mode, session.config.theme);
        try screen.render();

        const n = try term.readInput(&input);
        if (n == 0) {
            // A console resize wakes the read with no bytes: repaint at the new
            // size instead of counting it as end-of-input.
            if (term.takeResize()) {
                zero_reads = 0;
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
        const view_rows = viewRows(screen.rows);
        // Consume whole tokens. A prompt can close in the middle of a chunk
        // (Enter), after which the remaining bytes are ordinary editing input.
        var off: usize = 0;
        while (off < pending_len and running) {
            const chunk = pending[off..pending_len];
            const used = if (picker_state != null)
                try handlePickerInput(&session, &picker_state, picker_mode, &theme_before, exe_dir, &registry, chunk, &running, &msg_buf, &msg)
            else if (prompt != null)
                try handlePromptInput(&session, &registry, &prompt, chunk, &running, &msg_buf, &msg)
            else
                try processInput(&session, chunk, view_rows, &running, &prompt, &help, &msg_buf, &msg);
            if (used == 0) break; // incomplete escape sequence: wait for more
            off += used;
            // An action can ask for a picker (Ctrl+O, F2): open it right away so
            // the first press is enough.
            if (session.ui_request) |req| {
                session.ui_request = null;
                const mode: picker.Mode = if (req == .theme_picker) .theme else .open_file;
                openPicker(&session, &picker_state, mode, &theme_before, exe_dir);
                picker_mode = mode;
            }
        }
        const rem = pending_len - off;
        if (rem > 0) std.mem.copyForwards(u8, pending[0..rem], pending[off..pending_len]);
        pending_len = rem;
    }
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
        const b = buf[i];
        if (b == 0x1b) {
            if (i + 1 >= buf.len) return i; // incomplete: wait for more
            const k = buf[i + 1];
            if (k == '[') {
                var j = i + 2;
                while (j < buf.len) : (j += 1) {
                    if (buf[j] >= 0x40 and buf[j] <= 0x7E) break;
                }
                if (j >= buf.len) return i; // incomplete
                applyCsi(session, buf[i + 2 .. j], buf[j], view_rows, running, prompt, msg_buf, msg, help, true) catch |e| setMsg(msg_buf, msg, @errorName(e));
                i = j + 1;
            } else if (k == 'O') {
                if (i + 2 >= buf.len) return i;
                switch (buf[i + 2]) {
                    'A', 'B', 'C', 'D', 'H', 'F', 'R', 'P', 'Q' => |f| applyCsi(session, "", f, view_rows, running, prompt, msg_buf, msg, help, true) catch |e| setMsg(msg_buf, msg, @errorName(e)),
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
            else => return null,
        },
        else => return null,
    };
    var n: usize = 0;
    if (ctrl) {
        @memcpy(buf[n..][0..5], "ctrl+");
        n += 5;
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
        ed.clearSelection();
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
                session.active = idx;
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
    const ctrl = (bits & 4) != 0;
    switch (final) {
        'Q' => session.ui_request = .theme_picker,
        'A' => ed.moveUp(shift),
        'B' => ed.moveDown(shift),
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

    const ed = session.current();
    const theme = session.config.theme;
    const view_rows = h - 2; // row 0 is the tab bar, row h-1 the status line
    const total = ed.lineCount();
    const gutter: usize = if (session.config.line_numbers) digits(total) + 1 else 0;
    const text_cols: usize = if (w > gutter + 1) w - gutter - 1 else 0;
    ed.scrollToCursor(view_rows, text_cols);

    const gutter_fg = theme.gutter;
    const text_fg = theme.text;
    const sel_bg = theme.selection;
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

    drawTabBar(s, session, w, text_fg, gutter_fg);

    const sel = session.current().selectionRange();
    const rc = session.current().rowCol();
    const cur_dcol = session.current().cursorDisplayCol();

    // Syntax state at the top of the viewport, carried down the visible rows.
    var syn_state = ed.syntaxStateAt(ed.scroll_row);
    var spans: [syntax.MAX_SPANS]syntax.Span = undefined;

    var row: usize = 0;
    while (row < view_rows) : (row += 1) {
        const y: u16 = @intCast(row + 1);
        const lr = ed.scroll_row + row;
        if (lr >= total) break;
        const line = ed.line(lr);
        const line_start = ed.rowStart(lr);
        const line_end = line_start + line.len;
        const nspans = ed.highlightLine(lr, &syn_state, &spans);

        // Gutter.
        if (gutter > 0) {
            var num_buf: [24]u8 = undefined;
            const num = std.fmt.bufPrint(&num_buf, "{d}", .{lr + 1}) catch "";
            const gx = gutter - 1;
            var k: usize = 0;
            while (k + num.len < gx) : (k += 1) s.put(@intCast(k), y, .{ .ch = ' ', .bg = theme.background });
            s.putStr(@intCast(gx - num.len), y, num, .{ .fg = gutter_fg, .bg = theme.background });
        }

        // Text (wide characters take two cells; the second is marked cont).
        var dcol: usize = 0;
        var sx: usize = gutter;
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
                        var cell = render.Cell{ .ch = ' ', .fg = fg, .bg = theme.background };
                        if (selected) cell.bg = sel_bg;
                        s.put(@intCast(sx), y, cell);
                        sx += 1;
                        if (sx >= w) break;
                    }
                }
                continue;
            }
            const cw = width.cellWidth(cp);
            if (cw == 0) continue; // combining mark: attaches to the previous cell
            if (dcol >= ed.scroll_col) {
                if (sx + cw > w) break;
                var cell = render.Cell{ .ch = cp, .fg = fg, .bg = theme.background };
                if (selected) cell.bg = sel_bg;
                s.put(@intCast(sx), y, cell);
                if (cw == 2) {
                    var cont = render.Cell{ .ch = ' ', .fg = fg, .bg = theme.background, .cont = true };
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
                const cell_x = gutter + (dcol - ed.scroll_col);
                if (cell_x < w) s.put(@intCast(cell_x), y, .{ .ch = ' ', .bg = sel_bg });
            }
        }

        // Block cursor (drawn last so it wins over selection).
        if (lr == rc.row and cur_dcol >= ed.scroll_col) {
            const cx = gutter + (cur_dcol - ed.scroll_col);
            if (cx < w) {
                var under: u21 = ' ';
                if (rc.col < line.len) under = utf8.cpAt(line, rc.col);
                if (under < 0x20) under = ' ';
                var uw: usize = width.cellWidth(under);
                if (uw == 0) {
                    under = ' ';
                    uw = 1;
                }
                if (cx + uw <= w) {
                    s.put(@intCast(cx), y, .{ .ch = under, .fg = text_fg, .attr = .{ .reverse = true } });
                    if (uw == 2) {
                        s.put(@intCast(cx + 1), y, .{ .ch = ' ', .fg = text_fg, .attr = .{ .reverse = true }, .cont = true });
                    }
                }
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
        drawStatus(s, ed, msg, w, h, rc, total, bar_bg, accent, hint_fg);
    }

    // The help panel covers the bottom rows, so a prompt (which lives on the
    // last row) takes precedence over it while it is open.
    if (help and prompt == null) drawHelp(s, session, w, h, theme);
}

/// One row of tabs: ` name [+] ` per document, the active one highlighted.
fn drawTabBar(s: *render.Screen, session: *Session, w: usize, text_fg: render.Color, dim_fg: render.Color) void {
    const bar_bg = session.config.theme.tab_bg;
    const active_bg = session.config.theme.tab_active_bg;
    var x: usize = 0;
    while (x < w) : (x += 1) s.put(@intCast(x), 0, .{ .bg = bar_bg });

    var tx: usize = 0;
    for (session.docs.items, 0..) |ed, i| {
        const name = ed.path orelse "[No Name]";
        var buf: [160]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, " {s}{s} ", .{ name, if (ed.dirty) " [+]" else "" }) catch continue;
        if (tx + label.len > w) break;
        const active = i == session.active;
        s.putStr(@intCast(tx), 0, label, .{
            .bg = if (active) active_bg else bar_bg,
            .fg = if (active) text_fg else dim_fg,
            .attr = .{ .bold = active },
        });
        tx += label.len;
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
                        session.active = i;
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
        const keys_text = joinActionKeys(session, help_rows[i].actions, &keys_buf);
        const pad = if (keys_text.len < pad_text.len) pad_text[0 .. pad_text.len - keys_text.len] else " ";
        var line_buf: [192]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "  {s}{s}{s}", .{ keys_text, pad, help_rows[i].desc }) catch help_rows[i].desc;
        s.putStr(0, @intCast(top + 1 + i), line, .{ .bg = bg, .fg = fg });
    }
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
    try std.testing.expect(std.mem.indexOf(u8, bar, "[No Name]  [No Name]") != null);

    try d.send("\x1b[5;5~"); // Ctrl+PgUp back to the first document
    draw(&s, &d.session, "", null, false);
    // The first document row starts one line below the tab bar.
    const text_row = rowText(&s, 1, &buf);
    try std.testing.expect(std.mem.indexOf(u8, text_row, "1 one") != null);
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
