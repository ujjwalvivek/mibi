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

pub const version = "0.0.1";

const MAX_FILE = 64 * 1024 * 1024;
const TAB_STOP = 4;

const help_lines = [_][]const u8{
    "mibi controls",
    "",
    "  arrows / Ctrl+arrows   move / by word",
    "  Home / End             line start / end",
    "  PgUp / PgDn            move a page",
    "  Shift + movement       select",
    "  Ctrl+A                 select all",
    "  Esc                    clear selection",
    "  Ctrl+C / Ctrl+X        copy / cut",
    "  Ctrl+V                 paste",
    "  Ctrl+D                 duplicate line",
    "  Ctrl+Z / Ctrl+Y        undo / redo",
    "  Enter / Tab            new line / indent",
    "  Backspace / Delete     delete",
    "  Ctrl+S                 save (Save as if unnamed)",
    "  Ctrl+O                 open (Tab completes path)",
    "  Ctrl+?  / F1           toggle this help",
    "  Ctrl+Q                 quit",
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

const PromptKind = enum { save_as, open };

const Prompt = struct {
    kind: PromptKind,
    buf: [512]u8 = undefined,
    len: usize = 0,
};

fn run(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;

    var arg_it = try init.args.iterateAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.next();
    const path: ?[]const u8 = arg_it.next();

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

    var initial: []const u8 = "";
    var initial_owned: ?[]u8 = null;
    if (path) |p| {
        initial_owned = os.readFileAlloc(allocator, p, MAX_FILE) catch null;
        if (initial_owned) |d| initial = d;
    }
    var ed = try Editor.init(allocator, path, initial);
    defer ed.deinit();
    if (initial_owned) |d| allocator.free(d);

    try term.enterRaw();
    defer term.restore();
    try term.enterAltScreen();
    defer term.leaveAltScreen() catch {};

    const first = term.size();
    var screen = try render.Screen.init(allocator, first.cols, first.rows);
    defer screen.deinit();

    var input: [256]u8 = undefined;
    var msg_buf: [96]u8 = undefined;
    var msg: []const u8 = "";
    var prompt: ?Prompt = null;
    var running = true;
    var help = false;
    var zero_reads: usize = 0;
    var last_scroll_row: usize = std.math.maxInt(usize);
    var last_scroll_col: usize = std.math.maxInt(usize);
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
        // screen so no stale cells can survive the jump.
        {
            const total = ed.lineCount();
            const gutter = digits(total) + 1;
            const w: usize = screen.cols;
            const text_cols: usize = if (w > gutter + 1) w - gutter - 1 else 0;
            ed.scrollToCursor(@as(usize, screen.rows) - 1, text_cols);
            if (ed.scroll_row != last_scroll_row or ed.scroll_col != last_scroll_col) {
                last_scroll_row = ed.scroll_row;
                last_scroll_col = ed.scroll_col;
                @memset(screen.front, render.Cell{ .ch = 0, .attr = .{ .bold = true, .underline = true, .reverse = true } });
            }
        }

        draw(&screen, &ed, msg, prompt, help);
        try screen.render();

        const n = try term.readInput(&input);
        if (n == 0) {
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
        if (prompt != null) {
            try handlePromptInput(&ed, &prompt, pending[0..pending_len], &msg_buf, &msg);
            pending_len = 0;
        } else {
            const view_rows: usize = @as(usize, screen.rows) - 1;
            const consumed = try processInput(&ed, pending[0..pending_len], view_rows, &running, &prompt, &help, &msg_buf, &msg);
            const rem = pending_len - consumed;
            if (rem > 0) std.mem.copyForwards(u8, pending[0..rem], pending[consumed..pending_len]);
            pending_len = rem;
        }
    }
}

fn setMsg(buf: []u8, out: *[]const u8, text: []const u8) void {
    const n = @min(buf.len, text.len);
    @memcpy(buf[0..n], text[0..n]);
    out.* = buf[0..n];
}

/// Process as much of `buf` as forms complete tokens, returning how many bytes
/// were consumed. An escape sequence split across reads is left for next time,
/// so its bytes are never mistaken for typed text.
fn processInput(
    ed: *Editor,
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
        const b = buf[i];
        if (b == 0x1f) { // Ctrl+? / Ctrl+/ : toggle help
            help.* = !help.*;
            i += 1;
        } else if (b == 0x1b) {
            if (i + 1 >= buf.len) return i; // incomplete: wait for more
            const k = buf[i + 1];
            if (k == '[') {
                var j = i + 2;
                while (j < buf.len) : (j += 1) {
                    if (buf[j] >= 0x40 and buf[j] <= 0x7E) break;
                }
                if (j >= buf.len) return i; // incomplete
                if (buf[j] == '~' and std.mem.eql(u8, buf[i + 2 .. j], "11")) {
                    help.* = !help.*; // F1
                } else {
                    applyCsi(ed, buf[i + 2 .. j], buf[j], view_rows) catch |e| setMsg(msg_buf, msg, @errorName(e));
                }
                i = j + 1;
            } else if (k == 'O') {
                if (i + 2 >= buf.len) return i;
                switch (buf[i + 2]) {
                    'A' => ed.moveUp(false),
                    'B' => ed.moveDown(false),
                    'C' => ed.moveRight(false),
                    'D' => ed.moveLeft(false),
                    'H' => ed.moveHome(false),
                    'F' => ed.moveEnd(false),
                    'P' => help.* = !help.*, // F1
                    else => {},
                }
                i += 3;
            } else {
                ed.clearSelection(); // lone Esc
                i += 1;
            }
        } else {
            applyByte(ed, b, running, prompt, msg_buf, msg) catch |e| setMsg(msg_buf, msg, @errorName(e));
            i += 1;
        }
    }
    return i;
}

fn applyByte(ed: *Editor, b: u8, running: *bool, prompt: *?Prompt, msg_buf: []u8, msg: *[]const u8) !void {
    if (b == 0x13) { // Ctrl+S: save, or ask for a name
        if (ed.path == null) {
            prompt.* = .{ .kind = .save_as };
        } else ed.save() catch {
            setMsg(msg_buf, msg, "Save failed");
        };
    } else if (b == 0x0f) { // Ctrl+O
        prompt.* = .{ .kind = .open };
    } else if (b == 0x11) { // Ctrl+Q
        running.* = false;
    } else if (b == 0x01) { // Ctrl+A
        ed.selectAll();
    } else if (b == 0x03) { // Ctrl+C
        try ed.copy();
        setMsg(msg_buf, msg, "Copied");
        try sendOsc52(ed.registerText());
    } else if (b == 0x18) { // Ctrl+X
        try ed.cut();
        setMsg(msg_buf, msg, "Cut");
        try sendOsc52(ed.registerText());
    } else if (b == 0x16) { // Ctrl+V
        try ed.paste();
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
    } else if (b >= 0x20) {
        const one = [1]u8{b};
        try ed.insertText(&one);
    }
}

fn handlePromptInput(
    ed: *Editor,
    slot: *?Prompt,
    buf: []const u8,
    msg_buf: []u8,
    msg: *[]const u8,
) !void {
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const b = buf[i];
        const p = &slot.*.?;
        if (b == 0x1b) { // Esc cancels
            slot.* = null;
            return;
        }
        if (b == 0x0d or b == 0x0a) {
            try executePrompt(ed, p, msg_buf, msg);
            slot.* = null;
            return;
        }
        if (b == 0x7f or b == 0x08) {
            if (p.len > 0) p.len -= 1;
            continue;
        }
        if (b == 0x09) { // Tab completes the path
            try completePath(ed.allocator, p);
            continue;
        }
        if (b >= 0x20 and p.len < p.buf.len) {
            p.buf[p.len] = b;
            p.len += 1;
        }
    }
}

fn executePrompt(ed: *Editor, p: *Prompt, msg_buf: []u8, msg: *[]const u8) !void {
    const text = p.buf[0..p.len];
    if (text.len == 0) return;
    switch (p.kind) {
        .save_as => {
            ed.setPath(text) catch {
                setMsg(msg_buf, msg, "Bad path");
                return;
            };
            ed.save() catch {
                setMsg(msg_buf, msg, "Save failed");
                return;
            };
            setMsg(msg_buf, msg, "Saved");
        },
        .open => {
            const allocator = std.heap.page_allocator;
            const data = os.readFileAlloc(allocator, text, MAX_FILE) catch {
                setMsg(msg_buf, msg, "Cannot open file");
                return;
            };
            defer allocator.free(data);
            try ed.replaceContents(data);
            try ed.setPath(text);
            setMsg(msg_buf, msg, "Opened");
        },
    }
}

/// Apply a CSI sequence given its parameter bytes and final byte.
fn applyCsi(ed: *Editor, params_bytes: []const u8, final: u8, view_rows: usize) !void {
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
        'A' => ed.moveUp(shift),
        'B' => ed.moveDown(shift),
        'C' => if (ctrl) ed.moveWordRight(shift) else ed.moveRight(shift),
        'D' => if (ctrl) ed.moveWordLeft(shift) else ed.moveLeft(shift),
        'H' => ed.moveHome(shift),
        'F' => ed.moveEnd(shift),
        '~' => switch (p0) {
            1, 7 => ed.moveHome(shift),
            4, 8 => ed.moveEnd(shift),
            3 => try ed.deleteForward(),
            5 => ed.movePage(-1, view_rows, shift),
            6 => ed.movePage(1, view_rows, shift),
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

/// Decode the next UTF-8 codepoint at `s[i.*]`, advancing `i.*`.
fn nextCp(s: []const u8, i: *usize) u21 {
    const b = s[i.*];
    const len = std.unicode.utf8ByteSequenceLength(b) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + len > s.len) {
        i.* += 1;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(s[i.* .. i.* + len]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    i.* += len;
    return cp;
}

fn cpAt(line: []const u8, byte_off: usize) u21 {
    if (byte_off >= line.len) return ' ';
    var i = byte_off;
    return nextCp(line, &i);
}

fn displayCol(line: []const u8, byte_col: usize) usize {
    var dcol: usize = 0;
    var i: usize = 0;
    while (i < byte_col and i < line.len) {
        const cp = nextCp(line, &i);
        if (cp == '\t') {
            dcol = (dcol / TAB_STOP + 1) * TAB_STOP;
        } else {
            dcol += 1;
        }
    }
    return dcol;
}

fn draw(s: *render.Screen, ed: *Editor, msg: []const u8, prompt: ?Prompt, help: bool) void {
    s.clear();
    const w: usize = s.cols;
    const h: usize = s.rows;
    if (h < 2 or w < 4) return;

    const view_rows = h - 1;
    const total = ed.lineCount();
    const gutter: usize = digits(total) + 1;
    const text_cols: usize = if (w > gutter + 1) w - gutter - 1 else 0;
    ed.scrollToCursor(view_rows, text_cols);

    const gutter_fg = render.Color{ .rgb = .{ .r = 0x5c, .g = 0x63, .b = 0x70 } };
    const text_fg = render.Color{ .rgb = .{ .r = 0xd8, .g = 0xde, .b = 0xe9 } };
    const sel_bg = render.Color{ .rgb = .{ .r = 0x33, .g = 0x45, .b = 0x66 } };
    const bar_bg = render.Color{ .rgb = .{ .r = 0x28, .g = 0x28, .b = 0x38 } };
    const accent = render.Color{ .rgb = .{ .r = 0x8b, .g = 0xd4, .b = 0x50 } };
    const hint_bg = render.Color{ .rgb = .{ .r = 0x1e, .g = 0x1e, .b = 0x2a } };
    const hint_fg = render.Color{ .rgb = .{ .r = 0x88, .g = 0x92, .b = 0xa4 } };

    const sel = ed.selectionRange();
    const rc = ed.rowCol();
    const cursor_line = ed.line(rc.row);
    const cur_dcol = displayCol(cursor_line, rc.col);

    var row: usize = 0;
    while (row < view_rows) : (row += 1) {
        const lr = ed.scroll_row + row;
        if (lr >= total) break;
        const line = ed.line(lr);
        const line_start = ed.rowStart(lr);
        const line_end = line_start + line.len;

        // Gutter.
        var num_buf: [24]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{lr + 1}) catch "";
        const gx = gutter - 1;
        var k: usize = 0;
        while (k + num.len < gx) : (k += 1) s.put(@intCast(k), @intCast(row), .{ .ch = ' ' });
        s.putStr(@intCast(gx - num.len), @intCast(row), num, .{ .fg = gutter_fg });

        // Text.
        var dcol: usize = 0;
        var sx: usize = gutter;
        var bi: usize = 0;
        while (bi < line.len) {
            const cp_start = bi;
            const cp = nextCp(line, &bi);
            const selected = if (sel) |sr| (cp_start >= sr.start and cp_start < sr.end) else false;
            if (cp == '\r') {
                dcol += 1;
                continue;
            }
            if (cp == '\t') {
                const next = (dcol / TAB_STOP + 1) * TAB_STOP;
                while (dcol < next) : (dcol += 1) {
                    if (dcol >= ed.scroll_col) {
                        var cell = render.Cell{ .ch = ' ' };
                        if (selected) cell.bg = sel_bg;
                        s.put(@intCast(sx), @intCast(row), cell);
                        sx += 1;
                        if (sx >= w) break;
                    }
                }
                continue;
            }
            if (dcol >= ed.scroll_col) {
                var cell = render.Cell{ .ch = cp, .fg = text_fg };
                if (selected) cell.bg = sel_bg;
                s.put(@intCast(sx), @intCast(row), cell);
                sx += 1;
                if (sx >= w) break;
            }
            dcol += 1;
        }

        // Selection covering the newline (or end of file).
        if (sel) |sr| {
            if (line_end >= sr.start and line_end < sr.end and dcol >= ed.scroll_col) {
                const cell_x = gutter + (dcol - ed.scroll_col);
                if (cell_x < w) s.put(@intCast(cell_x), @intCast(row), .{ .ch = ' ', .bg = sel_bg });
            }
        }

        // Block cursor (drawn last so it wins over selection).
        if (lr == rc.row and cur_dcol >= ed.scroll_col) {
            const cx = gutter + (cur_dcol - ed.scroll_col);
            if (cx < w) {
                var under: u21 = ' ';
                if (rc.col < line.len) under = cpAt(line, rc.col);
                if (under < 0x20) under = ' ';
                s.put(@intCast(cx), @intCast(row), .{ .ch = under, .fg = text_fg, .attr = .{ .reverse = true } });
            }
        }
    }

    if (prompt) |p| {
        // One line of the directory being typed, like `ls`.
        if (h >= 3) {
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
        drawStatus(s, ed, msg, w, h, rc, total, bar_bg, accent);
    }

    if (help) drawHelp(s, w, h);
}

/// Bottom panel listing the controls (temporary; will become a real panel).
fn drawHelp(s: *render.Screen, w: usize, h: usize) void {
    if (h < 2) return;
    const panel_h = @min(h - 1, help_lines.len + 1);
    const top = h - panel_h;
    const bg = render.Color{ .rgb = .{ .r = 0x1a, .g = 0x1a, .b = 0x24 } };
    const fg = render.Color{ .rgb = .{ .r = 0xd8, .g = 0xde, .b = 0xe9 } };
    const title_fg = render.Color{ .rgb = .{ .r = 0x8b, .g = 0xd4, .b = 0x50 } };

    var y: usize = top;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) s.put(@intCast(x), @intCast(y), .{ .bg = bg });
    }
    var i: usize = 0;
    while (i < help_lines.len and top + i < h) : (i += 1) {
        const col = if (i == 0) title_fg else fg;
        s.putStr(0, @intCast(top + i), help_lines[i], .{ .bg = bg, .fg = col });
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
    };
    s.putStr(0, y, label, .{ .bg = bar_bg, .fg = accent });
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
) void {
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
    s.putStr(0, @intCast(h - 1), status, .{ .bg = bar_bg, .fg = accent });
}

test "an escape sequence split across reads is not typed as text" {    var ed = try Editor.init(std.testing.allocator, null, "one two three");
    defer ed.deinit();
    var running = true;
    var prompt: ?Prompt = null;
    var help = false;
    var mb: [64]u8 = undefined;
    var msg: []const u8 = "";

    // Ctrl+Right arrives as "\x1b[1;5" then "C".
    const first = "\x1b[1;5";
    const consumed1 = try processInput(&ed, first, 10, &running, &prompt, &help, &mb, &msg);
    try std.testing.expectEqual(@as(usize, 0), consumed1); // held back, not consumed
    try std.testing.expectEqualStrings("one two three", ed.text());

    var combined: [32]u8 = undefined;
    @memcpy(combined[0..first.len], first);
    combined[first.len] = 'C';
    const total = first.len + 1;
    const consumed2 = try processInput(&ed, combined[0..total], 10, &running, &prompt, &help, &mb, &msg);
    try std.testing.expectEqual(total, consumed2);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor); // after "one "
    try std.testing.expectEqualStrings("one two three", ed.text());
}

test "page down and page up move by a page" {
    var ed = try Editor.init(std.testing.allocator, null, "0\n1\n2\n3\n4\n5\n6\n7\n8\n9");
    defer ed.deinit();
    var running = true;
    var prompt: ?Prompt = null;
    var help = false;
    var mb: [64]u8 = undefined;
    var msg: []const u8 = "";

    const consumed = try processInput(&ed, "\x1b[6~", 3, &running, &prompt, &help, &mb, &msg);
    try std.testing.expectEqual(@as(usize, 4), consumed);
    try std.testing.expectEqual(@as(usize, 3), ed.rowCol().row);

    _ = try processInput(&ed, "\x1b[5~", 3, &running, &prompt, &help, &mb, &msg);
    try std.testing.expectEqual(@as(usize, 0), ed.rowCol().row);
}

test "ctrl+a selects all and ctrl+x cuts the selection" {
    var ed = try Editor.init(std.testing.allocator, null, "hello world");
    defer ed.deinit();
    var running = true;
    var prompt: ?Prompt = null;
    var help = false;
    var mb: [64]u8 = undefined;
    var msg: []const u8 = "";

    _ = try processInput(&ed, "\x01", 10, &running, &prompt, &help, &mb, &msg); // Ctrl+A
    const r = ed.selectionRange();
    try std.testing.expect(r != null);
    try std.testing.expectEqual(@as(usize, 0), r.?.start);
    try std.testing.expectEqual(@as(usize, 11), r.?.end);

    _ = try processInput(&ed, "\x18", 10, &running, &prompt, &help, &mb, &msg); // Ctrl+X
    try std.testing.expectEqualStrings("", ed.text());
    try std.testing.expectEqualStrings("hello world", ed.registerText());
}

// --- integration drive: feed real key bytes through the real handlers ------

const Drive = struct {
    ed: Editor,
    running: bool = true,
    prompt: ?Prompt = null,
    help: bool = false,
    mb: [256]u8 = undefined,
    msg: []const u8 = "",

    fn start(text: []const u8) !Drive {
        return .{ .ed = try Editor.init(std.testing.allocator, null, text) };
    }
    fn stop(self: *Drive) void {
        self.ed.deinit();
    }
    /// Feed bytes exactly as the run loop would (prompt mode uses its handler).
    fn send(self: *Drive, bytes: []const u8) !void {
        if (self.prompt != null) {
            try handlePromptInput(&self.ed, &self.prompt, bytes, &self.mb, &self.msg);
        } else {
            _ = try processInput(&self.ed, bytes, 10, &self.running, &self.prompt, &self.help, &self.mb, &self.msg);
        }
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
    try std.testing.expectEqualStrings("abc", d.ed.text());
    try d.send("\r");
    try std.testing.expectEqualStrings("abc\n", d.ed.text());
    try d.send("\t");
    try std.testing.expectEqualStrings("abc\n    ", d.ed.text());
    try d.send("\x7f");
    try std.testing.expectEqualStrings("abc\n   ", d.ed.text());
    try d.send("\x1b[3~"); // delete at end: no-op
    try std.testing.expectEqualStrings("abc\n   ", d.ed.text());
}

test "movement: arrows, home, end, word, page" {
    var d = try Drive.start("one two three\nfour\nfive");
    defer d.stop();
    try d.send("\x1b[C\x1b[C");
    try std.testing.expectEqual(@as(usize, 2), d.ed.cursor);
    try d.send("\x1b[1;5C"); // Ctrl+Right -> after "one "
    try std.testing.expectEqual(@as(usize, 4), d.ed.cursor);
    try d.send("\x1b[F"); // End
    try std.testing.expectEqual(@as(usize, 13), d.ed.cursor);
    try d.send("\x1b[H"); // Home
    try std.testing.expectEqual(@as(usize, 0), d.ed.cursor);
    try d.send("\x1b[6~"); // PageDown -> last line
    try std.testing.expectEqual(@as(usize, 2), d.ed.rowCol().row);
    try d.send("\x1b[5~"); // PageUp -> first line
    try std.testing.expectEqual(@as(usize, 0), d.ed.rowCol().row);
}

test "selection: extend, collapse, clear" {
    var d = try Drive.start("hello");
    defer d.stop();
    try d.send("\x1b[1;2C\x1b[1;2C"); // Shift+Right x2 -> 0..2
    try std.testing.expectEqual(@as(usize, 2), d.ed.selectionRange().?.end);
    try d.send("\x1b[C"); // plain Right collapses to the end (2)
    try std.testing.expect(d.ed.selectionRange() == null);
    try std.testing.expectEqual(@as(usize, 2), d.ed.cursor);
    try d.send("\x1b[1;2C\x1b[1;2C"); // Shift+Right x2 -> 2..4
    try d.send("\x1b[D"); // plain Left collapses to the start (2)
    try std.testing.expectEqual(@as(usize, 2), d.ed.cursor);
    try d.send("\x1b[1;2C"); // Shift+Right -> 2..3
    try d.send("\x1b\x1b"); // Esc (a lone Esc is only disambiguated by the next byte)
    try std.testing.expect(d.ed.selectionRange() == null);
}

test "copy, cut, paste" {
    var d = try Drive.start("hello world");
    defer d.stop();
    try d.send("\x01"); // Ctrl+A
    try d.send("\x03"); // Ctrl+C
    try std.testing.expectEqualStrings("hello world", d.ed.registerText());
    try d.send("\x18"); // Ctrl+X
    try std.testing.expectEqualStrings("", d.ed.text());
    try d.send("\x16"); // Ctrl+V
    try std.testing.expectEqualStrings("hello world", d.ed.text());
}

test "undo, redo, and redo cleared by a new edit" {
    var d = try Drive.start("");
    defer d.stop();
    try d.send("abc def");
    try d.send("\x1a"); // Ctrl+Z
    try std.testing.expectEqualStrings("", d.ed.text());
    try d.send("\x19"); // Ctrl+Y
    try std.testing.expectEqualStrings("abc def", d.ed.text());
    try d.send("\x1a"); // Ctrl+Z
    try d.send("X"); // new edit clears redo
    try d.send("\x19"); // Ctrl+Y: no-op
    try std.testing.expectEqualStrings("X", d.ed.text());
}

test "duplicate line" {
    var d = try Drive.start("alpha\nbeta");
    defer d.stop();
    try d.send("\x04"); // Ctrl+D
    try std.testing.expectEqualStrings("alpha\nalpha\nbeta", d.ed.text());
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
        draw(&s, &d.ed, "", null, false);
    }
    i = 0;
    while (i < 120) : (i += 1) {
        try d.send("\x1a"); // undo past the beginning
        draw(&s, &d.ed, "", null, false);
    }
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma", d.ed.text());
    i = 0;
    while (i < 120) : (i += 1) {
        try d.send("\x19"); // redo past the end
        draw(&s, &d.ed, "", null, false);
    }
    // A fresh edit after all that must not corrupt the buffer.
    try d.send("Z");
    draw(&s, &d.ed, "", null, false);
    try d.send("\x1a");
    draw(&s, &d.ed, "", null, false);
}

test "save-as and open prompts" {
    var d = try Drive.start("");
    defer d.stop();

    try d.send("\x13"); // Ctrl+S on an unnamed buffer -> Save as prompt
    try std.testing.expect(d.prompt != null);
    try std.testing.expectEqual(PromptKind.save_as, d.prompt.?.kind);
    try d.send("\x1b"); // Esc cancels
    try std.testing.expect(d.prompt == null);

    try d.send("\x0f"); // Ctrl+O -> Open prompt
    try std.testing.expect(d.prompt != null);
    try std.testing.expectEqual(PromptKind.open, d.prompt.?.kind);
    try d.send("ab");
    try std.testing.expectEqualStrings("ab", d.prompt.?.buf[0..d.prompt.?.len]);
    try d.send("\x7f"); // Backspace edits the path
    try std.testing.expectEqualStrings("a", d.prompt.?.buf[0..d.prompt.?.len]);
    try d.send("\x1b");
    try std.testing.expect(d.prompt == null);
}

test "render shows text, gutter and selection" {
    var ed = try Editor.init(std.testing.allocator, null, "hello\nworld");
    defer ed.deinit();
    var s = try render.Screen.init(std.testing.allocator, 20, 5);
    defer s.deinit();

    draw(&s, &ed, "", null, false);
    var buf: [64]u8 = undefined;
    const r0 = rowText(&s, 0, &buf);
    try std.testing.expect(std.mem.indexOf(u8, r0, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, r0, "1") != null); // gutter

    ed.selectAll();
    draw(&s, &ed, "", null, false);
    // First text cell (gutter is 2 wide for 2 lines) carries the selection bg.
    const sel_bg = switch (s.back[0 * s.cols + 2].bg) {
        .default => false,
        else => true,
    };
    try std.testing.expect(sel_bg);
}

test "promptDir extracts the directory part of a path" {    try std.testing.expectEqualStrings(".", promptDir("foo"));
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
    try os.writeFile("mibi-test.tmp", "hello world");
    const data = try os.readFileAlloc(allocator, "mibi-test.tmp", 1024);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("hello world", data);
}
