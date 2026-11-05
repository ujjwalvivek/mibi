//! Editor state: cursor, selection, movement, editing operations, undo/redo,
//! a clipboard register, and file I/O. The renderer reads `line`/`rowCol`/
//! `selectionRange`; main.zig turns keys into calls on this.

const std = @import("std");
const Allocator = std.mem.Allocator;
const os = @import("os.zig");
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;

const MAX_UNDO = 512;

pub const Range = struct { start: usize, end: usize };

pub const Editor = struct {
    allocator: Allocator,
    buf: Buffer,
    cursor: usize = 0,
    scroll_row: usize = 0,
    scroll_col: usize = 0,
    path: ?[]u8 = null,
    dirty: bool = false,
    /// Selection anchor; when set and != cursor, a range is selected.
    sel_anchor: ?usize = null,
    /// Column to keep when moving vertically through short lines.
    pref_col: ?usize = null,
    /// True while a run of plain typing is being grouped into one undo step.
    grouping: bool = false,
    register: std.ArrayList(u8),
    undo_stack: std.ArrayList(buffer.Snapshot),
    redo_stack: std.ArrayList(buffer.Snapshot),

    pub fn init(allocator: Allocator, path: ?[]const u8, data: []const u8) !Editor {
        return .{
            .allocator = allocator,
            .buf = try Buffer.init(allocator, data),
            .path = if (path) |p| try allocator.dupe(u8, p) else null,
            .register = std.ArrayList(u8).empty,
            .undo_stack = std.ArrayList(buffer.Snapshot).empty,
            .redo_stack = std.ArrayList(buffer.Snapshot).empty,
        };
    }

    pub fn deinit(self: *Editor) void {
        if (self.path) |p| self.allocator.free(p);
        self.register.deinit(self.allocator);
        for (self.undo_stack.items) |s| self.buf.freeSnapshot(s);
        for (self.redo_stack.items) |s| self.buf.freeSnapshot(s);
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
        self.buf.deinit();
    }

    pub fn text(self: *Editor) []const u8 {
        return self.buf.flat();
    }

    pub fn registerText(self: *Editor) []const u8 {
        return self.register.items;
    }

    pub fn lineCount(self: *Editor) usize {
        const f = self.buf.flat();
        var n: usize = 1;
        for (f) |c| {
            if (c == '\n') n += 1;
        }
        return n;
    }

    pub fn rowStart(self: *Editor, row: usize) usize {
        const f = self.buf.flat();
        var r: usize = 0;
        var i: usize = 0;
        while (r < row and i < f.len) : (i += 1) {
            if (f[i] == '\n') r += 1;
        }
        return i;
    }

    pub fn line(self: *Editor, row: usize) []const u8 {
        const f = self.buf.flat();
        const start = self.rowStart(row);
        var end = start;
        while (end < f.len and f[end] != '\n') end += 1;
        return f[start..end];
    }

    pub fn rowCol(self: *Editor) struct { row: usize, col: usize } {
        const f = self.buf.flat();
        var row: usize = 0;
        var ls: usize = 0;
        var i: usize = 0;
        while (i < self.cursor) : (i += 1) {
            if (f[i] == '\n') {
                row += 1;
                ls = i + 1;
            }
        }
        return .{ .row = row, .col = self.cursor - ls };
    }

    fn offsetOfRowCol(self: *Editor, row: usize, col: usize) usize {
        const f = self.buf.flat();
        const start = self.rowStart(row);
        var end = start;
        while (end < f.len and f[end] != '\n') end += 1;
        return start + @min(col, end - start);
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
        self.prepMove(extend);
        const rc = self.rowCol();
        self.cursor = self.offsetOfRowCol(rc.row, 0);
    }

    pub fn moveEnd(self: *Editor, extend: bool) void {
        self.prepMove(extend);
        const rc = self.rowCol();
        const ln = self.line(rc.row);
        self.cursor = self.offsetOfRowCol(rc.row, ln.len);
    }

    fn isWordChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
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
        self.moveVertical(-1, extend);
    }

    pub fn moveDown(self: *Editor, extend: bool) void {
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
        const snap = try self.buf.snapshot();
        try self.undo_stack.append(self.allocator, snap);
        if (self.undo_stack.items.len > MAX_UNDO) {
            const old = self.undo_stack.orderedRemove(0);
            self.buf.freeSnapshot(old);
        }
        for (self.redo_stack.items) |s| self.buf.freeSnapshot(s);
        self.redo_stack.clearRetainingCapacity();
        self.grouping = is_type;
    }

    pub fn insertText(self: *Editor, bytes: []const u8) !void {
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
    }

    pub fn backspace(self: *Editor) !void {
        if (self.selectionRange()) |_| return self.deleteSelection();
        if (self.cursor == 0) return;
        const start = self.prevCodepointStart(self.cursor);
        try self.beginEdit(false);
        try self.buf.delete(start, self.cursor - start);
        self.cursor = start;
        self.dirty = true;
        self.pref_col = null;
    }

    pub fn deleteForward(self: *Editor) !void {
        if (self.selectionRange()) |_| return self.deleteSelection();
        if (self.cursor >= self.buf.len()) return;
        const end = self.nextCodepointEnd(self.cursor);
        try self.beginEdit(false);
        try self.buf.delete(self.cursor, end - self.cursor);
        self.dirty = true;
        self.pref_col = null;
    }

    pub fn deleteSelection(self: *Editor) !void {
        const r = self.selectionRange() orelse return;
        try self.beginEdit(false);
        try self.buf.delete(r.start, r.end - r.start);
        self.cursor = r.start;
        self.sel_anchor = null;
        self.dirty = true;
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
        }
    }

    pub fn paste(self: *Editor) !void {
        if (self.register.items.len == 0) return;
        try self.insertText(self.register.items);
    }

    // --- undo/redo -------------------------------------------------------

    pub fn undo(self: *Editor) !void {
        if (self.undo_stack.items.len == 0) return;
        const snap = self.undo_stack.pop().?;
        try self.redo_stack.append(self.allocator, try self.buf.snapshot());
        try self.buf.restore(snap);
        self.buf.freeSnapshot(snap);
        self.grouping = false;
        self.pref_col = null;
        self.sel_anchor = null;
        self.clampCursor();
        self.dirty = true;
    }

    pub fn redo(self: *Editor) !void {
        if (self.redo_stack.items.len == 0) return;
        const snap = self.redo_stack.pop().?;
        try self.undo_stack.append(self.allocator, try self.buf.snapshot());
        try self.buf.restore(snap);
        self.buf.freeSnapshot(snap);
        self.grouping = false;
        self.pref_col = null;
        self.sel_anchor = null;
        self.clampCursor();
        self.dirty = true;
    }

    // --- files -----------------------------------------------------------

    pub fn setPath(self: *Editor, path: []const u8) !void {
        if (self.path) |p| self.allocator.free(p);
        self.path = try self.allocator.dupe(u8, path);
    }

    pub fn save(self: *Editor) !void {
        const p = self.path orelse return error.NoFileName;
        try os.writeFile(p, self.buf.flat());
        self.dirty = false;
    }

    /// Replace the whole document (e.g. after opening another file).
    pub fn replaceContents(self: *Editor, data: []const u8) !void {
        for (self.undo_stack.items) |s| self.buf.freeSnapshot(s);
        self.undo_stack.clearRetainingCapacity();
        for (self.redo_stack.items) |s| self.buf.freeSnapshot(s);
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
    }

    pub fn scrollToCursor(self: *Editor, rows: usize, cols: usize) void {
        const rc = self.rowCol();
        if (rc.row < self.scroll_row) self.scroll_row = rc.row;
        if (rc.row >= self.scroll_row + rows) self.scroll_row = rc.row - rows + 1;
        if (rc.col < self.scroll_col) self.scroll_col = rc.col;
        if (rc.col >= self.scroll_col + cols) self.scroll_col = rc.col - cols + 1;
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
