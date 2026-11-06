//! Editor state: cursor, selection, movement, editing operations, undo/redo,
//! a clipboard register, and file I/O. The renderer reads `line`/`rowCol`/
//! `selectionRange`; main.zig turns keys into calls on this.

const std = @import("std");
const Allocator = std.mem.Allocator;
const os = @import("os.zig");
const buffer = @import("buffer.zig");
const regex = @import("regex.zig");
const Buffer = buffer.Buffer;
const utf8 = @import("text.zig");
const width = @import("width.zig");
const syntax = @import("syntax.zig");

const MAX_UNDO = 512;

pub const Range = struct { start: usize, end: usize };
pub const RowCol = struct { row: usize, col: usize };

/// One undo/redo step: the buffer state to restore plus the cursor position
/// that belongs with it. For an edit that consumed a selection, the recorded
/// cursor is the *end* of the selection, so undoing the edit leaves the cursor
/// after the reinserted text instead of at its start.
const EditStep = struct { snap: buffer.Snapshot, cursor: usize };

/// Append `repl` to `out`, expanding `$0`..`$9` with the captured text.
fn appendExpanded(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    repl: []const u8,
    text: []const u8,
    caps: *const [regex.MAX_SLOTS]?usize,
) !void {
    var i: usize = 0;
    while (i < repl.len) {
        const c = repl[i];
        if (c == '$' and i + 1 < repl.len) {
            const d = repl[i + 1];
            if (d >= '0' and d <= '9') {
                const slot: usize = @as(usize, d - '0') * 2;
                if (slot + 1 < caps.len) {
                    if (caps[slot]) |start| {
                        if (caps[slot + 1]) |end| {
                            if (start <= end and end <= text.len) {
                                try out.appendSlice(allocator, text[start..end]);
                                i += 2;
                                continue;
                            }
                        }
                    }
                }
                i += 2;
                continue;
            }
            if (d == '$') {
                try out.append(allocator, '$');
                i += 2;
                continue;
            }
        }
        try out.append(allocator, c);
        i += 1;
    }
}

pub const Editor = struct {
    allocator: Allocator,
    buf: Buffer,
    /// Stable document id, assigned by the session. Panes and the session file
    /// refer to documents by this id, so reordering tabs cannot confuse them.
    id: u32 = 0,
    cursor: usize = 0,
    /// Extra cursors, for editing several places at once. The primary is
    /// `cursor`; these are the others. Empty for a normal edit.
    cursors: std.ArrayList(usize),
    /// Cells a tab advances to; set from the config.
    tab_width: usize = 4,
    scroll_row: usize = 0,
    scroll_col: usize = 0,
    path: ?[]u8 = null,
    dirty: bool = false,
    /// The file changed on disk while this buffer had unsaved edits, so the
    /// buffer and the disk disagree. Never silently overwritten: the tab shows
    /// `[!]` and saving asks first.
    conflict: bool = false,
    /// F9 was pressed once and warned; the next press goes ahead.
    reload_armed: bool = false,
    /// Size+mtime stamp of the file when it was read or written, so an idle
    /// tick can notice that it changed on disk.
    stamp: u64 = 0,
    /// Selection anchor; when set and != cursor, a range is selected.
    sel_anchor: ?usize = null,
    /// Column to keep when moving vertically through short lines.
    pref_col: ?usize = null,
    /// True while a run of plain typing is being grouped into one undo step.
    grouping: bool = false,
    register: std.ArrayList(u8),
    search: ?[]u8 = null,
    /// Treat the search term as a regular expression.
    search_regex: bool = false,
    regex_prog: ?regex.Program = null,
    /// Language for the current file (from its extension), if any.
    lang: ?*const syntax.Lang = null,
    /// Cached syntax state at the start of each line, grown lazily. Entries
    /// from an edited row down are dropped so block comments re-lex.
    syntax_states: std.ArrayList(syntax.State),
    undo_stack: std.ArrayList(EditStep),
    redo_stack: std.ArrayList(EditStep),

    pub fn init(allocator: Allocator, path: ?[]const u8, data: []const u8) !Editor {
        return .{
            .allocator = allocator,
            .cursors = std.ArrayList(usize).empty,
            .buf = try Buffer.init(allocator, data),
            .stamp = if (path) |p| os.fileStamp(p) else 0,
            .path = if (path) |p| try allocator.dupe(u8, p) else null,
            .register = std.ArrayList(u8).empty,
            .lang = null,
            .syntax_states = std.ArrayList(syntax.State).empty,
            .undo_stack = std.ArrayList(EditStep).empty,
            .redo_stack = std.ArrayList(EditStep).empty,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.cursors.deinit(self.allocator);
        if (self.regex_prog) |*p| p.deinit();
        if (self.path) |p| self.allocator.free(p);
        if (self.search) |s| self.allocator.free(s);
        self.register.deinit(self.allocator);
        self.syntax_states.deinit(self.allocator);
        for (self.undo_stack.items) |s| self.buf.freeSnapshot(s.snap);
        for (self.redo_stack.items) |s| self.buf.freeSnapshot(s.snap);
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
        self.buf.deinit();
    }

    /// Forget cached syntax states from `row` down: an edit there can change
    /// the block-comment state of every line that follows.
    pub fn invalidateSyntax(self: *Editor, row: usize) void {
        const keep = @min(self.syntax_states.items.len, row -| 1);
        self.syntax_states.shrinkRetainingCapacity(keep);
    }

    fn clearSyntax(self: *Editor) void {
        self.syntax_states.clearRetainingCapacity();
    }

    /// Syntax state at the start of `row`, lexing forward from the cache.
    pub fn syntaxStateAt(self: *Editor, row: usize) syntax.State {
        const starts = self.buf.lineStarts();
        if (starts.len == 0) return .{};
        const target = @min(row, starts.len - 1);
        while (self.syntax_states.items.len <= target) {
            const i = self.syntax_states.items.len;
            const st: syntax.State = if (i == 0) .{} else self.syntax_states.items[i - 1];
            self.syntax_states.append(self.allocator, st) catch return st;
            if (i > 0) {
                if (self.lang) |lang| syntax.advance(lang, self.line(i - 1), &self.syntax_states.items[i]);
            }
        }
        return self.syntax_states.items[target];
    }

    /// Highlight one line, advancing `state` to the next line. Returns the span
    /// count (0 when the document has no language).
    pub fn highlightLine(self: *Editor, row: usize, state: *syntax.State, spans: []syntax.Span) usize {
        const lang = self.lang orelse return 0;
        return syntax.highlight(lang, self.line(row), state, spans);
    }

    pub fn text(self: *Editor) []const u8 {
        return self.buf.flat();
    }

    pub fn registerText(self: *Editor) []const u8 {
        return self.register.items;
    }

    pub fn lineCount(self: *Editor) usize {
        // The buffer always has at least one line; guard the degenerate
        // out-of-memory case where the index could not be built.
        return @max(1, self.buf.lineStarts().len);
    }

    pub fn rowStart(self: *Editor, row: usize) usize {
        const starts = self.buf.lineStarts();
        if (starts.len == 0) return 0;
        return starts[@min(row, starts.len - 1)];
    }

    pub fn line(self: *Editor, row: usize) []const u8 {
        const starts = self.buf.lineStarts();
        const f = self.buf.flat();
        if (starts.len == 0) return f;
        const i = @min(row, starts.len - 1);
        const start = starts[i];
        const end = if (i + 1 < starts.len) starts[i + 1] - 1 else f.len;
        return f[start..@min(end, f.len)];
    }

    pub fn rowCol(self: *Editor) RowCol {
        return self.rowColAt(self.cursor);
    }

    pub fn rowColAt(self: *Editor, pos: usize) RowCol {
        const starts = self.buf.lineStarts();
        if (starts.len == 0) return .{ .row = 0, .col = pos };
        // Largest row whose start is <= pos (binary search; starts[0] == 0).
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] <= pos) lo = mid else hi = mid;
        }
        return .{ .row = lo, .col = pos - starts[lo] };
    }

    fn offsetOfRowCol(self: *Editor, row: usize, col: usize) usize {
        const start = self.rowStart(row);
        return start + @min(col, self.line(row).len);
    }

    fn clampCursor(self: *Editor) void {
        if (self.cursor > self.buf.len()) self.cursor = self.buf.len();
    }

    fn prevCodepointStart(self: *Editor, pos: usize) usize {
        const f = self.buf.flat();
        if (pos == 0) return 0;
        var i = pos - 1;
        while (i > 0 and (f[i] & 0xC0) == 0x80) i -= 1;
        return i;
    }

    fn nextCodepointEnd(self: *Editor, pos: usize) usize {
        const f = self.buf.flat();
        if (pos >= f.len) return f.len;
        var i = pos + 1;
        while (i < f.len and (f[i] & 0xC0) == 0x80) i += 1;
        return i;
    }

    // --- selection -------------------------------------------------------

    /// The selected range, always ordered so `start <= end` (and therefore
    /// `start` is the smaller offset). `sel_anchor` may be either side of the
    /// cursor — drag-select sets it after the cursor when dragging backwards —
    /// so callers may rely on the order and never need to compare the two
    /// themselves. Returns null when there is no selection.
    pub fn selectionRange(self: *Editor) ?Range {
        const a = self.sel_anchor orelse return null;
        if (a == self.cursor) return null;
        return if (a < self.cursor) .{ .start = a, .end = self.cursor } else .{ .start = self.cursor, .end = a };
    }

    pub fn hasSelection(self: *Editor) bool {
        return self.selectionRange() != null;
    }

    pub fn clearSelection(self: *Editor) void {
        self.sel_anchor = null;
    }

    pub fn selectAll(self: *Editor) void {
        self.sel_anchor = 0;
        self.cursor = self.buf.len();
    }

    /// Prepare for a movement. If not extending, drop the selection; if
    /// extending, start one. Left/Right handle a selection themselves so they
    /// collapse to the near edge instead of stepping past it.
    fn prepMove(self: *Editor, extend: bool) void {
        if (!extend) {
            self.sel_anchor = null;
        } else if (self.sel_anchor == null) {
            self.sel_anchor = self.cursor;
        }
        self.grouping = false;
        self.pref_col = null;
    }

    // --- movement --------------------------------------------------------

    pub fn moveLeft(self: *Editor, extend: bool) void {
        if (self.cursors.items.len == 0) return self.moveLeftOne(extend);
        self.moveEach(moveLeftOne, extend);
    }

    fn moveLeftOne(self: *Editor, extend: bool) void {
        if (!extend) {
            if (self.selectionRange()) |r| {
                self.sel_anchor = null;
                self.cursor = r.start;
                self.grouping = false;
                self.pref_col = null;
                return;
            }
        }
        self.prepMove(extend);
        self.cursor = self.prevCodepointStart(self.cursor);
    }

    pub fn moveRight(self: *Editor, extend: bool) void {
        if (self.cursors.items.len == 0) return self.moveRightOne(extend);
        self.moveEach(moveRightOne, extend);
    }

    fn moveRightOne(self: *Editor, extend: bool) void {
        if (!extend) {
            if (self.selectionRange()) |r| {
                self.sel_anchor = null;
                self.cursor = r.end;
                self.grouping = false;
                self.pref_col = null;
                return;
            }
        }
        self.prepMove(extend);
        self.cursor = self.nextCodepointEnd(self.cursor);
    }

    pub fn moveHome(self: *Editor, extend: bool) void {
        if (self.cursors.items.len == 0) return self.moveHomeOne(extend);
        self.moveEach(moveHomeOne, extend);
    }

    fn moveHomeOne(self: *Editor, extend: bool) void {
        self.prepMove(extend);
        const rc = self.rowCol();
        self.cursor = self.offsetOfRowCol(rc.row, 0);
    }

    pub fn moveEnd(self: *Editor, extend: bool) void {
        if (self.cursors.items.len == 0) return self.moveEndOne(extend);
        self.moveEach(moveEndOne, extend);
    }

    fn moveEndOne(self: *Editor, extend: bool) void {
        self.prepMove(extend);
        const rc = self.rowCol();
        const ln = self.line(rc.row);
        self.cursor = self.offsetOfRowCol(rc.row, ln.len);
    }

    fn isWordChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    /// Whitespace separates words and is never selected on its own.
    fn isSpaceChar(c: u8) bool {
        return std.ascii.isWhitespace(c);
    }

    /// Double click: select the run under the pointer. Word characters
    /// (`[A-Za-z0-9_]`) select their run, punctuation selects its own run, and a
    /// click in the gap right after a word still selects that word, because
    /// that is where the pointer usually lands. Whitespace that is not such a
    /// gap selects nothing: the run of spaces is never worth a selection. A
    /// click past the end of the buffer (the gutter right of the last line)
    /// counts as a click on the last character, and an empty buffer is a no-op.
    pub fn selectWordAt(self: *Editor, at: usize) void {
        const f = self.buf.flat();
        if (f.len == 0) {
            // Nothing to select, and nothing stale to keep either.
            self.sel_anchor = null;
            return;
        }
        // Clamp: `at` may point past the end (or at a huge value) when the
        // pointer is over the gutter.
        const i = @min(at, f.len - 1);
        var start: usize = undefined;
        var end: usize = undefined;
        if (isWordChar(f[i])) {
            start = i;
            while (start > 0 and isWordChar(f[start - 1])) start -= 1;
            end = i;
            while (end < f.len and isWordChar(f[end])) end += 1;
        } else if (!isSpaceChar(f[i])) {
            // Punctuation: select the whole run, so "->" or "!!!" comes as one
            // word and a click anywhere in it selects all of it.
            start = i;
            while (start > 0 and !isWordChar(f[start - 1]) and !isSpaceChar(f[start - 1])) start -= 1;
            end = i;
            while (end < f.len and !isWordChar(f[end]) and !isSpaceChar(f[end])) end += 1;
        } else if (i > 0 and isWordChar(f[i - 1])) {
            // The gap right after a word: the word before the pointer wins.
            start = i - 1;
            while (start > 0 and isWordChar(f[start - 1])) start -= 1;
            end = i;
        } else {
            // Whitespace that is not a word gap: no selection (and drop any
            // stale one instead of leaving the previous word highlighted).
            self.sel_anchor = null;
            return;
        }
        self.sel_anchor = start;
        self.cursor = end;
        self.pref_col = null;
        self.clearCursors();
    }

    /// Triple click: select the whole line at `at`, without its newline, so
    /// typing over it keeps the line break. The whole line is selected wherever
    /// the click lands (middle of the line, on the newline, or past the end of
    /// the text in the trailing gutter). An empty line has nothing to select:
    /// it drops any old selection and parks the cursor on that line instead.
    pub fn selectLineAt(self: *Editor, at: usize) void {
        const f = self.buf.flat();
        if (f.len == 0) {
            self.sel_anchor = null;
            self.cursor = 0;
            self.pref_col = null;
            self.clearCursors();
            return;
        }
        // `at` may be past the end (a click in the gutter): rowColAt clamps it
        // to the last line, which is the line the pointer is over.
        const row = self.rowColAt(@min(at, f.len)).row;
        const start = self.rowStart(row);
        const ln = self.line(row);
        // A CRLF line ends with "\r\n": the CR is part of the line break, not
        // of the text, so it must not be selected.
        const len = if (ln.len > 0 and ln[ln.len - 1] == '\r') ln.len - 1 else ln.len;
        if (len == 0) {
            // Empty line: no selection, and no stale one from a previous click.
            self.sel_anchor = null;
            self.cursor = start;
            self.pref_col = null;
            self.clearCursors();
            return;
        }
        self.sel_anchor = start;
        self.cursor = start + len;
        self.pref_col = null;
        self.clearCursors();
    }

    pub fn moveWordLeft(self: *Editor, extend: bool) void {
        self.prepMove(extend);
        const f = self.buf.flat();
        var i = self.cursor;
        while (i > 0 and !isWordChar(f[i - 1])) i -= 1;
        while (i > 0 and isWordChar(f[i - 1])) i -= 1;
        self.cursor = i;
    }

    pub fn moveWordRight(self: *Editor, extend: bool) void {
        self.prepMove(extend);
        const f = self.buf.flat();
        var i = self.cursor;
        while (i < f.len and isWordChar(f[i])) i += 1;
        while (i < f.len and !isWordChar(f[i])) i += 1;
        self.cursor = i;
    }

    fn moveVertical(self: *Editor, delta: i32, extend: bool) void {
        self.prepMove(extend);
        const rc = self.rowCol();
        const want = self.pref_col orelse rc.col;
        self.pref_col = want;
        const total = self.lineCount();
        var target = rc.row;
        if (delta < 0) {
            if (target == 0) return;
            target -= 1;
        } else {
            if (target + 1 >= total) return;
            target += 1;
        }
        self.cursor = self.offsetOfRowCol(target, want);
    }

    pub fn moveUp(self: *Editor, extend: bool) void {
        if (self.cursors.items.len == 0) return self.moveUpOne(extend);
        self.moveEach(moveUpOne, extend);
    }

    fn moveUpOne(self: *Editor, extend: bool) void {
        self.moveVertical(-1, extend);
    }

    pub fn moveDown(self: *Editor, extend: bool) void {
        if (self.cursors.items.len == 0) return self.moveDownOne(extend);
        self.moveEach(moveDownOne, extend);
    }

    fn moveDownOne(self: *Editor, extend: bool) void {
        self.moveVertical(1, extend);
    }

    pub fn movePage(self: *Editor, delta: i32, page: usize, extend: bool) void {
        var n = page;
        while (n > 0) : (n -= 1) {
            if (delta < 0) self.moveVertical(-1, extend) else self.moveVertical(1, extend);
        }
    }

    // --- editing ---------------------------------------------------------

    fn beginEdit(self: *Editor, is_type: bool) !void {
        if (is_type and self.grouping) return;
        // Where the cursor belongs once this step is undone. An edit that eats a
        // selection must bring the cursor back after the restored text, so
        // record the far edge of the selection: the cursor itself can sit at
        // the near edge when the selection was made backwards (dragging left),
        // and undo would then drop it before the reinserted text.
        const restore = if (self.selectionRange()) |r| r.end else self.cursor;
        const snap = try self.buf.snapshot();
        self.undo_stack.append(self.allocator, .{ .snap = snap, .cursor = restore }) catch |e| {
            self.buf.freeSnapshot(snap);
            return e;
        };
        if (self.undo_stack.items.len > MAX_UNDO) {
            const old = self.undo_stack.orderedRemove(0);
            self.buf.freeSnapshot(old.snap);
        }
        for (self.redo_stack.items) |s| self.buf.freeSnapshot(s.snap);
        self.redo_stack.clearRetainingCapacity();
        self.grouping = is_type;
    }

    // --- multiple cursors -------------------------------------------------
    pub const MAX_CURSORS = 32;

    /// Every cursor position, primary included, sorted ascending.
    fn allCursors(self: *Editor, out: *[MAX_CURSORS]usize) usize {
        out[0] = self.cursor;
        var n: usize = 1;
        for (self.cursors.items) |c| {
            if (n >= out.len) break;
            out[n] = c;
            n += 1;
        }
        // Insertion sort: std.mem.sort would instantiate pdqsort again.
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const v = out[i];
            var j = i;
            while (j > 0 and out[j - 1] > v) : (j -= 1) out[j] = out[j - 1];
            out[j] = v;
        }
        return n;
    }

    pub fn hasCursors(self: *Editor) bool {
        return self.cursors.items.len > 0;
    }

    pub fn clearCursors(self: *Editor) void {
        self.cursors.clearRetainingCapacity();
    }

    /// Add a cursor on the line below (or above) the last one, at the same
    /// column. Returns false when there is no such line.
    pub fn addCursor(self: *Editor, delta: i32) bool {
        if (self.cursors.items.len >= MAX_CURSORS - 1) return false;
        // Work from the lowest cursor so each new one is below the previous.
        var last = self.cursor;
        for (self.cursors.items) |c| {
            if (delta > 0) {
                if (c > last) last = c;
            } else {
                if (c < last) last = c;
            }
        }
        const rc = self.rowColAt(last);
        const total = self.lineCount();
        if (delta > 0 and rc.row + 1 >= total) return false;
        if (delta < 0 and rc.row == 0) return false;
        const target_row = if (delta > 0) rc.row + 1 else rc.row - 1;
        const pos = self.offsetOfRowCol(target_row, rc.col);
        // A cursor already there is not worth a second one.
        if (pos == self.cursor) return false;
        for (self.cursors.items) |c| {
            if (c == pos) return false;
        }
        self.cursors.append(self.allocator, pos) catch return false;
        return true;
    }

    /// Apply a single-cursor movement to every cursor.
    fn moveEach(self: *Editor, comptime one: fn (*Editor, bool) void, extend: bool) void {
        var positions: [MAX_CURSORS]usize = undefined;
        const n = self.allCursors(&positions);
        var results: [MAX_CURSORS]usize = undefined;
        const primary = self.cursor;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.cursor = positions[i];
            one(self, extend);
            results[i] = self.cursor;
        }
        self.cursor = primary;
        self.cursors.clearRetainingCapacity();
        i = 0;
        while (i < n) : (i += 1) {
            if (positions[i] == primary) {
                self.cursor = results[i];
            } else {
                self.cursors.append(self.allocator, results[i]) catch {};
            }
        }
    }

    pub fn insertText(self: *Editor, bytes: []const u8) !void {
        if (self.cursors.items.len == 0) return self.insertTextOne(bytes);
        var positions: [MAX_CURSORS]usize = undefined;
        const n = self.allCursors(&positions);
        const primary = self.cursor;
        self.sel_anchor = null; // a multi-cursor edit is not a selection edit
        try self.beginEdit(bytes.len == 1 and bytes[0] >= 0x20);
        // Insert from the highest cursor down so earlier offsets stay valid.
        var i = n;
        while (i > 0) {
            i -= 1;
            try self.buf.insert(positions[i], bytes);
        }
        // Each cursor moves past its own insert plus every insert below it.
        self.cursors.clearRetainingCapacity();
        i = 0;
        while (i < n) : (i += 1) {
            const moved = positions[i] + (i + 1) * bytes.len;
            if (positions[i] == primary) {
                self.cursor = moved;
            } else {
                self.cursors.append(self.allocator, moved) catch {};
            }
        }
        self.dirty = true;
        self.pref_col = null;
        self.invalidateSyntax(self.rowColAt(positions[0]).row);
    }

    fn insertTextOne(self: *Editor, bytes: []const u8) !void {
        const is_type = bytes.len == 1 and bytes[0] >= 0x20;
        if (self.selectionRange()) |r| {
            try self.beginEdit(false);
            try self.buf.delete(r.start, r.end - r.start);
            self.cursor = r.start;
            self.sel_anchor = null;
        } else {
            try self.beginEdit(is_type);
        }
        try self.buf.insert(self.cursor, bytes);
        self.cursor += bytes.len;
        self.dirty = true;
        self.pref_col = null;
        self.invalidateSyntax(self.rowCol().row);
    }

    pub fn backspace(self: *Editor) !void {
        if (self.cursors.items.len == 0) return self.backspaceOne();
        var positions: [MAX_CURSORS]usize = undefined;
        const n = self.allCursors(&positions);
        const primary = self.cursor;
        self.sel_anchor = null;
        var starts: [MAX_CURSORS]usize = undefined;
        var lens: [MAX_CURSORS]usize = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = positions[i];
            if (p == 0) {
                starts[i] = 0;
                lens[i] = 0;
                continue;
            }
            const st = self.prevCodepointStart(p);
            starts[i] = st;
            lens[i] = p - st;
        }
        try self.beginEdit(false);
        i = n;
        while (i > 0) {
            i -= 1;
            if (lens[i] > 0) try self.buf.delete(starts[i], lens[i]);
        }
        self.cursors.clearRetainingCapacity();
        var below: usize = 0;
        i = 0;
        while (i < n) : (i += 1) {
            const np = starts[i] - below;
            below += lens[i];
            if (positions[i] == primary) {
                self.cursor = np;
            } else {
                self.cursors.append(self.allocator, np) catch {};
            }
        }
        self.dirty = true;
        self.pref_col = null;
        self.invalidateSyntax(0);
    }

    fn backspaceOne(self: *Editor) !void {
        if (self.selectionRange()) |_| return self.deleteSelection();
        if (self.cursor == 0) return;
        const start = self.prevCodepointStart(self.cursor);
        try self.beginEdit(false);
        try self.buf.delete(start, self.cursor - start);
        self.cursor = start;
        self.dirty = true;
        self.pref_col = null;
        self.invalidateSyntax(self.rowCol().row);
    }

    pub fn deleteForward(self: *Editor) !void {
        if (self.cursors.items.len == 0) return self.deleteForwardOne();
        var positions: [MAX_CURSORS]usize = undefined;
        const n = self.allCursors(&positions);
        const primary = self.cursor;
        const len = self.buf.len();
        self.sel_anchor = null;
        var ends: [MAX_CURSORS]usize = undefined;
        var lens: [MAX_CURSORS]usize = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = positions[i];
            if (p >= len) {
                ends[i] = p;
                lens[i] = 0;
                continue;
            }
            const e = self.nextCodepointEnd(p);
            ends[i] = e;
            lens[i] = e - p;
        }
        try self.beginEdit(false);
        i = n;
        while (i > 0) {
            i -= 1;
            if (lens[i] > 0) try self.buf.delete(positions[i], lens[i]);
        }
        self.cursors.clearRetainingCapacity();
        var below: usize = 0;
        i = 0;
        while (i < n) : (i += 1) {
            const np = positions[i] - below;
            below += lens[i];
            if (positions[i] == primary) {
                self.cursor = np;
            } else {
                self.cursors.append(self.allocator, np) catch {};
            }
        }
        self.dirty = true;
        self.pref_col = null;
        self.invalidateSyntax(0);
    }

    fn deleteForwardOne(self: *Editor) !void {
        if (self.selectionRange()) |_| return self.deleteSelection();
        if (self.cursor >= self.buf.len()) return;
        const end = self.nextCodepointEnd(self.cursor);
        try self.beginEdit(false);
        try self.buf.delete(self.cursor, end - self.cursor);
        self.dirty = true;
        self.pref_col = null;
        self.invalidateSyntax(self.rowCol().row);
    }

    /// Re-read the file when it changed on disk underneath us. Only clean
    /// buffers are reloaded: unsaved edits are never thrown away.
    pub fn reloadIfChanged(self: *Editor) bool {
        const path = self.path orelse return false;
        const now = os.fileStamp(path);
        if (now == 0 or now == self.stamp) return false;
        if (self.dirty) {
            // The file moved on under unsaved edits. Do not touch the buffer
            // (that would throw the edits away), but say so: the tab marks the
            // conflict and the status line offers a reload.
            self.conflict = true;
            return false;
        }
        const data = os.readFileAlloc(self.allocator, path, 16 * 1024 * 1024) catch return false;
        defer self.allocator.free(data);
        self.stamp = now;
        if (std.mem.eql(u8, data, self.text())) return false;
        self.buf.deinit();
        self.buf = buffer.Buffer.init(self.allocator, data) catch return false;
        if (self.cursor > self.buf.len()) self.cursor = self.buf.len();
        self.sel_anchor = null;
        self.clearCursors();
        self.invalidateSyntax(0);
        return true;
    }

    /// Reload the file from disk, discarding the buffer: the explicit "I want
    /// what is on disk" action behind F9 and the conflict prompt.
    pub fn reloadFromDisk(self: *Editor) !bool {
        const path = self.path orelse return false;
        const data = try os.readFileAlloc(self.allocator, path, 16 * 1024 * 1024);
        defer self.allocator.free(data);
        if (std.mem.eql(u8, data, self.text())) {
            self.stamp = os.fileStamp(path);
            self.conflict = false;
            self.dirty = false;
            return false;
        }
        self.buf.deinit();
        self.buf = try buffer.Buffer.init(self.allocator, data);
        self.stamp = os.fileStamp(path);
        self.cursor = 0;
        self.sel_anchor = null;
        self.clearCursors();
        self.dirty = false;
        self.conflict = false;
        self.invalidateSyntax(0);
        return true;
    }

    /// Replace the whole buffer as one undo step (used by the formatter),
    /// keeping the cursor inside the new text.
    pub fn replaceText(self: *Editor, bytes: []const u8) !void {
        try self.beginEdit(false);
        try self.buf.delete(0, self.buf.len());
        try self.buf.insert(0, bytes);
        if (self.cursor > self.buf.len()) self.cursor = self.buf.len();
        self.sel_anchor = null;
        self.clearCursors();
        self.dirty = true;
        self.pref_col = null;
        self.invalidateSyntax(0);
    }

    pub fn deleteSelection(self: *Editor) !void {
        const r = self.selectionRange() orelse return;
        try self.beginEdit(false);
        try self.buf.delete(r.start, r.end - r.start);
        self.cursor = r.start;
        self.sel_anchor = null;
        self.dirty = true;
        self.invalidateSyntax(self.rowCol().row);
    }

    pub fn duplicateLine(self: *Editor) !void {
        const rc = self.rowCol();
        const start = self.rowStart(rc.row);
        // Copy the line out first: insert() rebuilds the flat buffer, so a
        // slice returned by line() would dangle.
        const dup = try self.allocator.dupe(u8, self.line(rc.row));
        defer self.allocator.free(dup);
        try self.beginEdit(false);
        const insert_at = start + dup.len;
        try self.buf.insert(insert_at, "\n");
        try self.buf.insert(insert_at + 1, dup);
        self.cursor = insert_at + 1;
        self.dirty = true;
        self.invalidateSyntax(self.rowCol().row);
    }

    // --- clipboard -------------------------------------------------------

    /// Copy the selection, or the current line, into the register.
    pub fn copy(self: *Editor) !void {
        self.register.clearRetainingCapacity();
        if (self.selectionRange()) |r| {
            const f = self.buf.flat();
            try self.register.appendSlice(self.allocator, f[r.start..r.end]);
        } else {
            const rc = self.rowCol();
            const ln = self.line(rc.row);
            try self.register.appendSlice(self.allocator, ln);
            try self.register.append(self.allocator, '\n');
        }
    }

    pub fn cut(self: *Editor) !void {
        try self.copy();
        if (self.selectionRange()) |_| {
            try self.deleteSelection();
        } else {
            const rc = self.rowCol();
            const start = self.rowStart(rc.row);
            const ln = self.line(rc.row);
            const has_nl = start + ln.len < self.buf.len();
            const end = start + ln.len + @as(usize, if (has_nl) 1 else 0);
            try self.beginEdit(false);
            try self.buf.delete(start, end - start);
            self.cursor = start;
            self.dirty = true;
            self.invalidateSyntax(self.rowCol().row);
        }
    }

    pub fn paste(self: *Editor) !void {
        if (self.register.items.len == 0) return;
        try self.insertText(self.register.items);
    }

    // --- undo/redo -------------------------------------------------------

    pub fn undo(self: *Editor) !void {
        if (self.undo_stack.items.len == 0) return;
        const step = self.undo_stack.pop().?;
        const snap = try self.buf.snapshot();
        self.redo_stack.append(self.allocator, .{ .snap = snap, .cursor = self.cursor }) catch |e| {
            self.buf.freeSnapshot(snap);
            return e;
        };
        self.buf.restore(step.snap) catch |e| {
            self.buf.freeSnapshot(step.snap);
            return e;
        };
        self.buf.freeSnapshot(step.snap);
        self.cursor = step.cursor;
        self.grouping = false;
        self.pref_col = null;
        self.sel_anchor = null;
        self.clampCursor();
        self.dirty = true;
        self.clearSyntax();
    }

    pub fn redo(self: *Editor) !void {
        if (self.redo_stack.items.len == 0) return;
        const step = self.redo_stack.pop().?;
        const snap = try self.buf.snapshot();
        self.undo_stack.append(self.allocator, .{ .snap = snap, .cursor = self.cursor }) catch |e| {
            self.buf.freeSnapshot(snap);
            return e;
        };
        self.buf.restore(step.snap) catch |e| {
            self.buf.freeSnapshot(step.snap);
            return e;
        };
        self.buf.freeSnapshot(step.snap);
        self.cursor = step.cursor;
        self.grouping = false;
        self.pref_col = null;
        self.sel_anchor = null;
        self.clampCursor();
        self.dirty = true;
        self.clearSyntax();
    }

    // --- search / replace / goto ----------------------------------------

    pub fn setSearch(self: *Editor, needle: []const u8) !void {
        if (self.search) |s| self.allocator.free(s);
        self.search = if (needle.len == 0) null else try self.allocator.dupe(u8, needle);
        if (self.regex_prog) |*p| p.deinit();
        self.regex_prog = null;
        if (self.search_regex and needle.len > 0) {
            self.regex_prog = regex.compile(self.allocator, needle) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                return error.InvalidRegex;
            };
        }
    }

    /// The next match at or after `from`, as a byte range.
    pub fn findRangeFrom(self: *Editor, from: usize) ?regex.Match {
        const f = self.buf.flat();
        if (from > f.len) return null;
        if (self.regex_prog) |*prog| return regex.find(prog, f, from);
        const needle = self.search orelse return null;
        if (needle.len == 0) return null;
        const p = std.mem.indexOfPos(u8, f, from, needle) orelse return null;
        return .{ .start = p, .end = p + needle.len };
    }

    pub fn findFrom(self: *Editor, from: usize) ?usize {
        const m = self.findRangeFrom(from) orelse return null;
        return m.start;
    }

    /// Move to the next match (wrapping). No-op without a search term.
    pub fn findNext(self: *Editor) void {
        if (self.search == null and self.regex_prog == null) return;
        const f = self.buf.flat();
        const start = @min(self.cursor + 1, f.len);
        if (self.findRangeFrom(start)) |m| {
            self.cursor = m.start;
        } else if (self.findRangeFrom(0)) |m| {
            self.cursor = m.start;
        }
        self.sel_anchor = null;
        self.pref_col = null;
    }

    /// Move to the previous match (wrapping). No-op without a search term.
    pub fn findPrev(self: *Editor) void {
        if (self.search == null and self.regex_prog == null) return;
        // Scan forward for the last match that starts before the cursor.
        var best: ?regex.Match = null;
        var from: usize = 0;
        while (self.findRangeFrom(from)) |m| {
            if (m.start >= self.cursor) break;
            best = m;
            from = m.end;
            if (m.end == m.start) from += 1; // zero-width match: advance
        }
        const m = best orelse {
            // Wrap: the last match in the document.
            var last: ?regex.Match = null;
            var f: usize = 0;
            while (self.findRangeFrom(f)) |mm| {
                last = mm;
                f = mm.end;
                if (mm.end == mm.start) f += 1;
            }
            const lm = last orelse return;
            self.cursor = lm.start;
            self.sel_anchor = null;
            self.pref_col = null;
            return;
        };
        self.cursor = m.start;
        self.sel_anchor = null;
        self.pref_col = null;
    }

    pub fn gotoLineCol(self: *Editor, row: usize, col: usize) void {
        const total = self.lineCount();
        const r = if (row >= total) total - 1 else row;
        self.cursor = self.offsetOfRowCol(r, col);
        self.sel_anchor = null;
        self.pref_col = null;
        self.grouping = false;
    }

    /// Replace every occurrence of `needle` with `repl`; returns the count.
    pub fn replaceAll(self: *Editor, needle: []const u8, repl: []const u8) !usize {
        if (needle.len == 0) return 0;
        if (self.regex_prog) |*prog| return self.replaceAllRegex(prog, repl);
        var positions = std.ArrayList(regex.Match).empty;
        defer positions.deinit(self.allocator);
        {
            const f = self.buf.flat();
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, f, i, needle)) |p| {
                try positions.append(self.allocator, .{ .start = p, .end = p + needle.len });
                i = p + needle.len;
            }
        }
        if (positions.items.len == 0) return 0;
        try self.beginEdit(false);
        // Replace from the end so earlier offsets stay valid.
        var k = positions.items.len;
        while (k > 0) {
            k -= 1;
            const p = positions.items[k].start;
            const len = positions.items[k].end - positions.items[k].start;
            try self.buf.delete(p, len);
            try self.buf.insert(p, repl);
        }
        self.dirty = true;
        self.clearSyntax();
        self.cursor = positions.items[0].start;
        self.sel_anchor = null;
        return positions.items.len;
    }

    /// Regex replace: rebuilds the whole buffer so replacements can grow or
    /// shrink and `$1`..`$9` / `$0` expand to the captured text.
    fn replaceAllRegex(self: *Editor, prog: *const regex.Program, repl: []const u8) !usize {
        const f = self.buf.flat();
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.allocator);
        var caps: [regex.MAX_SLOTS]?usize = .{null} ** regex.MAX_SLOTS;
        var last: usize = 0;
        var count: usize = 0;
        var i: usize = 0;
        while (regex.findCaptures(prog, f, i, &caps)) |m| {
            try out.appendSlice(self.allocator, f[last..m.start]);
            try appendExpanded(self.allocator, &out, repl, f, &caps);
            last = m.end;
            count += 1;
            i = if (m.end > m.start) m.end else m.end + 1;
            if (i > f.len) break;
        }
        if (count == 0) return 0;
        try out.appendSlice(self.allocator, f[last..]);
        try self.beginEdit(false);
        try self.buf.delete(0, f.len);
        try self.buf.insert(0, out.items);
        self.dirty = true;
        self.clearSyntax();
        self.cursor = 0;
        self.sel_anchor = null;
        return count;
    }

    // --- files -----------------------------------------------------------

    pub fn setPath(self: *Editor, path: []const u8) !void {
        if (self.path) |p| self.allocator.free(p);
        self.path = try self.allocator.dupe(u8, path);
    }

    /// Point the document at a language definition (or none) and drop the
    /// cached states, since the lexer rules changed.
    pub fn setLanguage(self: *Editor, lang: ?*const syntax.Lang) void {
        self.lang = lang;
        self.clearSyntax();
    }

    pub fn save(self: *Editor) !void {
        defer {
            if (self.path) |p| self.stamp = os.fileStamp(p);
        }
        const p = self.path orelse return error.NoFileName;
        try os.writeFile(p, self.buf.flat());
        self.dirty = false;
    }

    /// Write to `path` and adopt it as the buffer's name. The path is only
    /// changed once the write has succeeded, so a failed Save-As leaves the
    /// buffer pointing at its old (valid) file.
    pub fn saveAs(self: *Editor, path: []const u8) !void {
        try os.writeFile(path, self.buf.flat());
        try self.setPath(path);
        self.dirty = false;
    }

    /// Replace the whole document (e.g. after opening another file).
    pub fn replaceContents(self: *Editor, data: []const u8) !void {
        for (self.undo_stack.items) |s| self.buf.freeSnapshot(s.snap);
        self.undo_stack.clearRetainingCapacity();
        for (self.redo_stack.items) |s| self.buf.freeSnapshot(s.snap);
        self.redo_stack.clearRetainingCapacity();
        self.buf.deinit();
        self.buf = try Buffer.init(self.allocator, data);
        self.cursor = 0;
        self.scroll_row = 0;
        self.scroll_col = 0;
        self.sel_anchor = null;
        self.pref_col = null;
        self.grouping = false;
        self.dirty = false;
        self.clearSyntax();
    }

    pub fn scrollToCursor(self: *Editor, rows: usize, cols: usize) void {
        const rc = self.rowCol();
        const dcol = self.cursorDisplayCol();
        if (rc.row < self.scroll_row) self.scroll_row = rc.row;
        if (rc.row >= self.scroll_row + rows) self.scroll_row = rc.row - rows + 1;
        if (dcol < self.scroll_col) self.scroll_col = dcol;
        if (dcol >= self.scroll_col + cols) self.scroll_col = dcol - cols + 1;
    }

    /// Display column of the cursor, accounting for tabs, wide (2-cell) and
    /// zero-width codepoints.
    pub fn cursorDisplayCol(self: *Editor) usize {
        return self.displayColAt(self.cursor);
    }

    /// Display column of an arbitrary offset (tabs expand, CR counts as zero).
    pub fn displayColAt(self: *Editor, pos: usize) usize {
        const rc = self.rowColAt(pos);
        const ln = self.line(rc.row);
        var dcol: usize = 0;
        var i: usize = 0;
        while (i < rc.col and i < ln.len) {
            const cp = utf8.nextCp(ln, &i);
            if (cp == '\t') {
                dcol = (dcol / self.tab_width + 1) * self.tab_width;
            } else if (cp == '\r') {
                // A CR is never drawn (CRLF files), so it occupies no cell;
                // counting it would put the cursor one column past the text.
            } else {
                dcol += width.cellWidth(cp);
            }
        }
        return dcol;
    }
};

test "editing, movement and undo" {
    var e = try Editor.init(std.testing.allocator, null, "hello\nworld");
    defer e.deinit();

    try e.insertText("!");
    try std.testing.expectEqualStrings("!hello\nworld", e.text());

    e.moveLeft(false); // back before the '!'
    try e.deleteForward();
    try std.testing.expectEqualStrings("hello\nworld", e.text());

    e.cursor = e.buf.len();
    try e.backspace();
    try std.testing.expectEqualStrings("hello\nworl", e.text());

    try e.undo();
    try std.testing.expectEqualStrings("hello\nworld", e.text());
    try e.redo();
    try std.testing.expectEqualStrings("hello\nworl", e.text());

    e.cursor = 0;
    e.moveDown(false);
    const rc = e.rowCol();
    try std.testing.expectEqual(@as(usize, 1), rc.row);
}

test "newline, vertical movement and home/end" {
    var e = try Editor.init(std.testing.allocator, null, "ab\ncd");
    defer e.deinit();

    e.cursor = 1;
    try e.insertText("\n");
    try std.testing.expectEqualStrings("a\nb\ncd", e.text());

    var rc = e.rowCol();
    try std.testing.expectEqual(@as(usize, 1), rc.row);
    try std.testing.expectEqual(@as(usize, 0), rc.col);

    e.moveUp(false);
    rc = e.rowCol();
    try std.testing.expectEqual(@as(usize, 0), rc.row);

    e.moveDown(false);
    e.moveEnd(false);
    rc = e.rowCol();
    try std.testing.expectEqual(@as(usize, 1), rc.row);
    try std.testing.expectEqual(@as(usize, 1), rc.col);

    e.moveHome(false);
    rc = e.rowCol();
    try std.testing.expectEqual(@as(usize, 0), rc.col);
}

test "selection, copy and paste" {
    var e = try Editor.init(std.testing.allocator, null, "hello world");
    defer e.deinit();

    e.cursor = 0;
    e.moveRight(true);
    e.moveRight(true);
    e.moveRight(true);
    e.moveRight(true);
    e.moveRight(true); // select "hello"
    const r = e.selectionRange().?;
    try std.testing.expectEqual(@as(usize, 0), r.start);
    try std.testing.expectEqual(@as(usize, 5), r.end);

    try e.copy();
    try std.testing.expectEqualStrings("hello", e.registerText());

    e.clearSelection();
    e.cursor = e.buf.len();
    try e.paste();
    try std.testing.expectEqualStrings("hello worldhello", e.text());
}

test "cut and delete selection" {
    var e = try Editor.init(std.testing.allocator, null, "abcdef");
    defer e.deinit();

    e.sel_anchor = 1;
    e.cursor = 4;
    try e.cut();
    try std.testing.expectEqualStrings("aef", e.text());
    try std.testing.expectEqualStrings("bcd", e.registerText());
}

/// Every row must match a naive split of the text, and the offsets must line
/// up with the cached line index.
fn expectLinesMatch(e: *Editor) !void {
    const f = e.text();
    var it = std.mem.splitScalar(u8, f, '\n');
    var row: usize = 0;
    var offset: usize = 0;
    while (it.next()) |expected| : (row += 1) {
        try std.testing.expect(row < e.lineCount());
        try std.testing.expectEqualStrings(expected, e.line(row));
        try std.testing.expectEqual(offset, e.rowStart(row));
        offset += expected.len + 1;
    }
    try std.testing.expectEqual(row, e.lineCount());
}

test "line access agrees with a naive scan after edits" {
    var e = try Editor.init(std.testing.allocator, null, "alpha\nbeta\ngamma\ndelta");
    defer e.deinit();
    try expectLinesMatch(&e);

    e.cursor = 2;
    try e.insertText("\nnew"); // split a line
    try expectLinesMatch(&e);
    try e.insertText("\n\n\n"); // blank lines
    try expectLinesMatch(&e);

    e.cursor = 0;
    try e.backspace(); // no-op at the start
    try expectLinesMatch(&e);
    e.cursor = e.buf.len();
    try e.backspace();
    try expectLinesMatch(&e);

    try e.duplicateLine();
    try expectLinesMatch(&e);

    e.cursor = 0;
    e.moveDown(false);
    try e.cut(); // cut a whole line
    try expectLinesMatch(&e);
    try e.paste();
    try expectLinesMatch(&e);

    _ = try e.replaceAll("a", "AAA");
    try expectLinesMatch(&e);
    try e.undo();
    try expectLinesMatch(&e);
    try e.redo();
    try expectLinesMatch(&e);

    try e.insertText("\n"); // trailing newline: one more empty row
    try expectLinesMatch(&e);
}

test "findPrev wraps to the last match" {
    var e = try Editor.init(std.testing.allocator, null, "one two one two one");
    defer e.deinit();
    try e.setSearch("two");

    e.cursor = 4; // first match: nothing before it, so wrap to the last one
    e.findPrev();
    try std.testing.expectEqual(@as(usize, 12), e.cursor);

    e.findPrev();
    try std.testing.expectEqual(@as(usize, 4), e.cursor);

    e.cursor = 0;
    e.findPrev(); // at the very start, wraps to the end
    try std.testing.expectEqual(@as(usize, 12), e.cursor);
}

test "crlf does not offset the cursor" {
    var e = try Editor.init(std.testing.allocator, null, "ab\r\ncd");
    defer e.deinit();

    e.cursor = 2; // after "ab", before the CR
    try std.testing.expectEqual(@as(usize, 2), e.cursorDisplayCol());
    e.cursor = 3; // after the CR, still end of the visible line
    try std.testing.expectEqual(@as(usize, 2), e.cursorDisplayCol());
    e.cursor = 4; // start of the next line
    try std.testing.expectEqual(@as(usize, 0), e.cursorDisplayCol());
}

test "undo everything then redo everything restores both states" {
    var e = try Editor.init(std.testing.allocator, null, "start\nhere");
    defer e.deinit();
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rand = prng.random();

    var step: usize = 0;
    while (step < 60) : (step += 1) {
        switch (rand.uintLessThan(u8, 8)) {
            0 => try e.insertText("x"),
            1 => try e.insertText("\n"),
            2 => try e.backspace(),
            3 => try e.deleteForward(),
            4 => e.moveRight(false),
            5 => e.moveDown(false),
            6 => try e.duplicateLine(),
            7 => try e.paste(),
            else => unreachable,
        }
    }
    try expectLinesMatch(&e);
    const before = try std.testing.allocator.dupe(u8, e.text());
    defer std.testing.allocator.free(before);

    var n: usize = 0;
    while (e.undo_stack.items.len > 0 and n < 1000) : (n += 1) {
        try e.undo();
        try expectLinesMatch(&e);
    }
    try std.testing.expectEqualStrings("start\nhere", e.text());

    n = 0;
    while (e.redo_stack.items.len > 0 and n < 1000) : (n += 1) {
        try e.redo();
        try expectLinesMatch(&e);
    }
    try std.testing.expectEqualStrings(before, e.text());
}

test "regex replace expands capture groups" {
    var ed = try Editor.init(std.testing.allocator, null, "foo=1 bar=2");
    defer ed.deinit();
    ed.search_regex = true;
    try ed.setSearch("(\\w+)=(\\d+)");
    const n = try ed.replaceAll("(\\w+)=(\\d+)", "$2:$1");
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("1:foo 2:bar", ed.text());
}

test "double click selects the word under the pointer" {
    var e = try Editor.init(std.testing.allocator, null, "alpha beta gamma\nsecond");
    defer e.deinit();

    e.selectWordAt(6);
    try std.testing.expectEqual(@as(?usize, 6), e.sel_anchor);
    try std.testing.expectEqual(@as(usize, 10), e.cursor);
    // Typing replaces the whole selection.
    try e.insertText("X");
    try std.testing.expectEqualStrings("alpha X gamma\nsecond", e.text());
}

test "double click on the gap after a word still selects it" {
    var e = try Editor.init(std.testing.allocator, null, "alpha beta gamma");
    defer e.deinit();

    e.selectWordAt(10); // the space right after "beta"
    try std.testing.expectEqual(@as(?usize, 6), e.sel_anchor);
    try std.testing.expectEqual(@as(usize, 10), e.cursor);
}

test "triple click selects the whole line but not its newline" {
    var e = try Editor.init(std.testing.allocator, null, "alpha beta gamma\nsecond");
    defer e.deinit();

    e.selectLineAt(6);
    try std.testing.expectEqual(@as(?usize, 0), e.sel_anchor);
    try std.testing.expectEqual(@as(usize, 16), e.cursor);
    try e.insertText("Y");
    try std.testing.expectEqualStrings("Y\nsecond", e.text());
}

// --- undo puts the cursor back after the restored text ----------------------

test "undo after deleting a word selection leaves the cursor after the word" {
    var e = try Editor.init(std.testing.allocator, null, "alpha beta gamma");
    defer e.deinit();

    e.selectWordAt(6); // "beta"
    try e.deleteSelection();
    try std.testing.expectEqualStrings("alpha  gamma", e.text());
    try std.testing.expectEqual(@as(usize, 6), e.cursor);

    try e.undo();
    try std.testing.expectEqualStrings("alpha beta gamma", e.text());
    // End of the restored "beta", not its start.
    try std.testing.expectEqual(@as(usize, 10), e.cursor);
    try std.testing.expectEqual(@as(usize, 10), e.rowColAt(e.cursor).col);
}

test "undo after typing over a selection leaves the cursor after the text" {
    var e = try Editor.init(std.testing.allocator, null, "alpha beta gamma");
    defer e.deinit();

    e.selectWordAt(6); // "beta"
    try e.insertText("X");
    try std.testing.expectEqualStrings("alpha X gamma", e.text());

    try e.undo();
    try std.testing.expectEqualStrings("alpha beta gamma", e.text());
    try std.testing.expectEqual(@as(usize, 10), e.cursor);
}

test "undo after deleting a backwards selection leaves the cursor at the end" {
    var e = try Editor.init(std.testing.allocator, null, "alpha beta gamma");
    defer e.deinit();

    // Drag-select right to left: the anchor is after the cursor.
    e.sel_anchor = 10;
    e.cursor = 6;
    try e.deleteSelection();
    try std.testing.expectEqualStrings("alpha  gamma", e.text());
    try std.testing.expectEqual(@as(usize, 6), e.cursor);

    try e.undo();
    try std.testing.expectEqualStrings("alpha beta gamma", e.text());
    try std.testing.expectEqual(@as(usize, 10), e.cursor);
}

test "undo of a backspace leaves the cursor after the restored character" {
    var e = try Editor.init(std.testing.allocator, null, "abc");
    defer e.deinit();

    e.cursor = 3;
    try e.backspace();
    try std.testing.expectEqualStrings("ab", e.text());
    try e.undo();
    try std.testing.expectEqualStrings("abc", e.text());
    try std.testing.expectEqual(@as(usize, 3), e.cursor);
}

test "redo puts the cursor back where the edit left it" {
    var e = try Editor.init(std.testing.allocator, null, "alpha beta");
    defer e.deinit();

    e.selectWordAt(6); // "beta"
    try e.deleteSelection();
    try std.testing.expectEqual(@as(usize, 6), e.cursor);

    try e.undo();
    try std.testing.expectEqual(@as(usize, 10), e.cursor);
    try e.redo();
    try std.testing.expectEqualStrings("alpha ", e.text());
    try std.testing.expectEqual(@as(usize, 6), e.cursor);
}

test "typing runs stay one undo step and undo returns to the run start" {
    var e = try Editor.init(std.testing.allocator, null, "ab");
    defer e.deinit();

    e.cursor = 2;
    try e.insertText("c");
    try e.insertText("d");
    try e.insertText("e");
    // A run of plain typing is still grouped into a single step.
    try std.testing.expectEqual(@as(usize, 1), e.undo_stack.items.len);
    try std.testing.expectEqualStrings("abcde", e.text());

    try e.undo();
    try std.testing.expectEqualStrings("ab", e.text());
    try std.testing.expectEqual(@as(usize, 2), e.cursor);
    try std.testing.expectEqual(@as(usize, 0), e.undo_stack.items.len);
}

// --- line selection ---------------------------------------------------------

test "triple click in the middle of a line selects the whole line" {
    var e = try Editor.init(std.testing.allocator, null, "alpha beta\ngamma");
    defer e.deinit();

    e.selectLineAt(3); // middle of "alpha beta"
    const r = e.selectionRange().?;
    try std.testing.expectEqual(@as(usize, 0), r.start);
    try std.testing.expectEqual(@as(usize, 10), r.end);
    try std.testing.expectEqualStrings("alpha beta", e.text()[r.start..r.end]);

    // Typing replaces the line content but keeps the line break.
    try e.insertText("Z");
    try std.testing.expectEqualStrings("Z\ngamma", e.text());
}

test "triple click at the end of a line selects that line, not the next" {
    var e = try Editor.init(std.testing.allocator, null, "ab\nlongerline\ncd");
    defer e.deinit();

    // Exactly on the newline: still the first line, without the newline.
    e.selectLineAt(2);
    const r = e.selectionRange().?;
    try std.testing.expectEqual(@as(usize, 0), r.start);
    try std.testing.expectEqual(@as(usize, 2), r.end);

    // Past the end of the text (trailing gutter): the last line.
    e.selectLineAt(e.buf.len() + 40);
    const r2 = e.selectionRange().?;
    try std.testing.expectEqual(@as(usize, 14), r2.start);
    try std.testing.expectEqual(@as(usize, 16), r2.end);
}

test "triple click on an empty line selects nothing" {
    var e = try Editor.init(std.testing.allocator, null, "a\n\nb");
    defer e.deinit();

    e.selectLineAt(0); // select "a" first
    try std.testing.expect(e.hasSelection());

    e.selectLineAt(2); // the empty line: no selection, not a stale one
    try std.testing.expectEqual(@as(?usize, null), e.sel_anchor);
    try std.testing.expect(!e.hasSelection());
    try std.testing.expectEqual(@as(usize, 2), e.cursor);

    // Typing on the empty line inserts instead of eating the previous line.
    try e.insertText("x");
    try std.testing.expectEqualStrings("a\nx\nb", e.text());
}

test "triple click on the last line without a trailing newline" {
    var e = try Editor.init(std.testing.allocator, null, "one\ntwo");
    defer e.deinit();

    e.selectLineAt(6);
    const r = e.selectionRange().?;
    try std.testing.expectEqual(@as(usize, 4), r.start);
    try std.testing.expectEqual(@as(usize, 7), r.end);
    try std.testing.expectEqualStrings("two", e.text()[r.start..r.end]);

    try e.insertText("Z");
    try std.testing.expectEqualStrings("one\nZ", e.text());
}

test "triple click on a crlf line excludes the line break" {
    var e = try Editor.init(std.testing.allocator, null, "ab\r\ncd");
    defer e.deinit();

    e.selectLineAt(1); // middle of "ab\r"
    const r = e.selectionRange().?;
    try std.testing.expectEqual(@as(usize, 0), r.start);
    try std.testing.expectEqual(@as(usize, 2), r.end);
}

test "triple click on an empty buffer is safe" {
    var e = try Editor.init(std.testing.allocator, null, "");
    defer e.deinit();

    e.selectLineAt(0);
    try std.testing.expectEqual(@as(?usize, null), e.sel_anchor);
    try std.testing.expectEqual(@as(usize, 0), e.cursor);
    e.selectLineAt(9999);
    try std.testing.expect(!e.hasSelection());
}

// --- word selection ---------------------------------------------------------

test "double click selects a run of word characters" {
    var e = try Editor.init(std.testing.allocator, null, "foo_bar123 baz");
    defer e.deinit();

    // Digits and underscores belong to the word, like letters.
    e.selectWordAt(1);
    try std.testing.expectEqual(@as(?usize, 0), e.sel_anchor);
    try std.testing.expectEqual(@as(usize, 10), e.cursor);
    try std.testing.expectEqualStrings("foo_bar123", e.text()[0..10]);

    e.selectWordAt(12); // "baz"
    try std.testing.expectEqual(@as(?usize, 11), e.sel_anchor);
    try std.testing.expectEqual(@as(usize, 14), e.cursor);
}

test "double click on punctuation selects its run" {
    var e = try Editor.init(std.testing.allocator, null, "foo->bar!! baz");
    defer e.deinit();

    e.selectWordAt(4); // the '>' in "->"
    try std.testing.expectEqual(@as(?usize, 3), e.sel_anchor);
    try std.testing.expectEqual(@as(usize, 5), e.cursor);
    try std.testing.expectEqualStrings("->", e.text()[3..5]);

    e.selectWordAt(9); // a '!' in the "!!" run
    try std.testing.expectEqual(@as(?usize, 8), e.sel_anchor);
    try std.testing.expectEqual(@as(usize, 10), e.cursor);
}

test "double click in the gap after a word selects the word" {
    var e = try Editor.init(std.testing.allocator, null, "alpha beta");
    defer e.deinit();

    e.selectWordAt(5); // the space between the words
    try std.testing.expectEqual(@as(?usize, 0), e.sel_anchor);
    try std.testing.expectEqual(@as(usize, 5), e.cursor);

    e.selectWordAt(10); // past the end of the buffer: still "beta"
    try std.testing.expectEqual(@as(?usize, 6), e.sel_anchor);
    try std.testing.expectEqual(@as(usize, 10), e.cursor);
}

test "double click past the end after a trailing newline selects the word" {
    var e = try Editor.init(std.testing.allocator, null, "word\n");
    defer e.deinit();

    e.selectWordAt(9999);
    try std.testing.expectEqual(@as(?usize, 0), e.sel_anchor);
    try std.testing.expectEqual(@as(usize, 4), e.cursor);
}

test "double click on whitespace selects nothing" {
    var e = try Editor.init(std.testing.allocator, null, "alpha  beta\n  x");
    defer e.deinit();

    e.selectWordAt(0); // a real selection first
    try std.testing.expect(e.hasSelection());

    e.selectWordAt(6); // the second space of the run: no word before the gap
    try std.testing.expectEqual(@as(?usize, null), e.sel_anchor);
    try std.testing.expect(!e.hasSelection());

    e.selectWordAt(12); // indentation at the start of the second line
    try std.testing.expect(!e.hasSelection());
}

test "double click on trailing spaces past the end selects nothing" {
    var e = try Editor.init(std.testing.allocator, null, "abc   ");
    defer e.deinit();

    e.selectWordAt(9999);
    try std.testing.expectEqual(@as(?usize, null), e.sel_anchor);
    try std.testing.expect(!e.hasSelection());
}

test "double click clamps on an empty buffer" {
    var e = try Editor.init(std.testing.allocator, null, "");
    defer e.deinit();

    e.selectWordAt(0);
    try std.testing.expectEqual(@as(?usize, null), e.sel_anchor);
    e.selectWordAt(9999);
    try std.testing.expectEqual(@as(?usize, null), e.sel_anchor);
    try std.testing.expectEqual(@as(usize, 0), e.cursor);
}

// --- the renderer/drag-select contract --------------------------------------

test "selectionRange is ordered whichever side the anchor is on" {
    var e = try Editor.init(std.testing.allocator, null, "hello world");
    defer e.deinit();

    // Forward selection (anchor before the cursor).
    e.sel_anchor = 2;
    e.cursor = 7;
    var r = e.selectionRange().?;
    try std.testing.expectEqual(@as(usize, 2), r.start);
    try std.testing.expectEqual(@as(usize, 7), r.end);

    // Backwards drag: main.zig sets the anchor after the cursor.
    e.sel_anchor = 7;
    e.cursor = 2;
    r = e.selectionRange().?;
    try std.testing.expectEqual(@as(usize, 2), r.start);
    try std.testing.expectEqual(@as(usize, 7), r.end);

    // A zero-width range is not a selection.
    e.sel_anchor = 3;
    e.cursor = 3;
    try std.testing.expect(e.selectionRange() == null);
}
