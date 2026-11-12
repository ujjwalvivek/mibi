//! A view: one way of looking at a document. It owns the selections and the
//! scroll position, and it is where editing commands live.
//!
//! Every command works on the whole selection list. There is no "main cursor
//! plus extras": one cursor is a list of length one. A command turns the
//! selections into a list of edits, the document applies them as one undo
//! step, and the selections are carried through the edits to where they
//! belong afterwards.
//!
//! Several views can show one document (split panes). A view registers as an
//! observer, so its selections move when another view edits the text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const document = @import("document.zig");
const selection = @import("selection.zig");
const text = @import("text.zig");
const Document = document.Document;
const Edit = document.Edit;
const Bias = document.Bias;
const Kind = document.Kind;
const Selection = selection.Selection;

pub const Motion = enum {
    left,
    right,
    up,
    down,
    word_left,
    word_right,
    /// Home: the first non-blank character, or column 0 if already there.
    line_start,
    line_end,
    page_up,
    page_down,
    doc_start,
    doc_end,
};

pub const View = struct {
    allocator: Allocator,
    doc: *Document,
    /// Never empty; kept sorted and non-overlapping by `normalize`.
    selections: std.ArrayList(Selection),
    /// Index of the selection the view keeps on screen.
    primary: usize = 0,
    scroll_row: usize = 0,
    scroll_col: usize = 0,
    tab_width: usize = 4,
    /// What Tab inserts and what one level of indentation is.
    indent_unit: []const u8 = "    ",
    /// The time of the event being handled, for grouping runs of typing. Set
    /// by the caller before a command; the core has no clock.
    now_ms: u64 = 0,
    /// Scratch for reading lines that span pieces.
    scratch: std.ArrayList(u8) = .empty,

    /// Views are heap-allocated: the document keeps a pointer to each one.
    pub fn create(allocator: Allocator, doc: *Document) !*View {
        const self = try allocator.create(View);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .doc = doc, .selections = .empty };
        errdefer self.selections.deinit(allocator);
        try self.selections.append(allocator, Selection.caret(0));
        try doc.observe(.{ .ptr = self, .onChange = onChange });
        return self;
    }

    pub fn destroy(self: *View) void {
        self.doc.unobserve(self);
        self.selections.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// The document changed under this view: move the selections with the
    /// text. The view that made the edit is told too, and then overwrites
    /// the result with the selections it wants.
    fn onChange(ptr: *anyopaque, tx: *const document.Transaction, direction: document.Direction) void {
        const self: *View = @ptrCast(@alignCast(ptr));
        for (self.selections.items) |*s| {
            switch (direction) {
                .applied => {
                    s.anchor = tx.map(s.anchor, .before);
                    s.head = tx.map(s.head, .before);
                },
                .reverted => {
                    s.anchor = tx.unmap(s.anchor, .before);
                    s.head = tx.unmap(s.head, .before);
                },
            }
            s.goal = null;
        }
        self.normalize();
    }

    // --- reading ---------------------------------------------------------

    pub fn primarySelection(self: *const View) Selection {
        return self.selections.items[self.primary];
    }

    pub fn hasMultiple(self: *const View) bool {
        return self.selections.items.len > 1;
    }

    fn normalize(self: *View) void {
        const merged = selection.normalize(self.selections.items, &self.primary);
        self.selections.shrinkRetainingCapacity(merged.len);
    }

    /// Line `row` without its newline. Valid until the next call.
    fn lineText(self: *View, row: usize) []const u8 {
        // Reading into scratch only allocates when a line spans pieces. If
        // that allocation fails the line reads as empty: a wrong cursor
        // column is recoverable, a crash while moving the cursor is not.
        return self.doc.buffer.line(row, &self.scratch) catch "";
    }

    const Place = struct { row: usize, col: usize, line_start: usize };

    fn place(self: *const View, pos: usize) Place {
        const row = self.doc.buffer.lineOf(pos);
        const start = self.doc.buffer.lineStart(row);
        return .{ .row = row, .col = pos - start, .line_start = start };
    }

    fn lastRow(self: *const View) usize {
        return self.doc.buffer.lineCount() - 1;
    }

    /// Cell column of a document offset.
    pub fn cellOf(self: *View, pos: usize) usize {
        const p = self.place(pos);
        return text.cellOfByte(self.lineText(p.row), p.col, self.tab_width);
    }

    /// The document offset under a screen position (row in the document,
    /// cell column on that row): where a click puts the cursor.
    pub fn offsetAt(self: *View, row: usize, cell: usize) usize {
        const r = @min(row, self.lastRow());
        return self.doc.buffer.lineStart(r) + text.byteOfCell(self.lineText(r), cell, self.tab_width);
    }

    // --- selections ------------------------------------------------------

    /// One caret at `pos`, dropping every other selection.
    pub fn setCaret(self: *View, pos: usize) void {
        self.setSelection(Selection.caret(@min(pos, self.doc.len())));
    }

    pub fn setSelection(self: *View, sel: Selection) void {
        self.selections.clearRetainingCapacity();
        self.selections.appendAssumeCapacity(sel); // capacity >= 1 always
        self.primary = 0;
        self.doc.breakUndoGroup();
    }

    /// Replace the whole selection list (restoring a session, undo).
    pub fn setSelections(self: *View, items: []const Selection, primary: usize) !void {
        if (items.len == 0) return;
        try self.selections.ensureTotalCapacity(self.allocator, items.len);
        self.selections.clearRetainingCapacity();
        const max = self.doc.len();
        for (items) |s| {
            self.selections.appendAssumeCapacity(.{ .anchor = @min(s.anchor, max), .head = @min(s.head, max), .goal = s.goal });
        }
        self.primary = @min(primary, items.len - 1);
        self.normalize();
    }

    /// Move the head of the primary selection to `pos`, keeping its anchor:
    /// shift+click and mouse drag.
    pub fn extendTo(self: *View, pos: usize) void {
        const s = &self.selections.items[self.primary];
        s.head = @min(pos, self.doc.len());
        s.goal = null;
        self.doc.breakUndoGroup();
        self.normalize();
    }

    /// Add a caret at `pos` (ctrl+click). It becomes the primary.
    pub fn addCaret(self: *View, pos: usize) !void {
        try self.selections.append(self.allocator, Selection.caret(@min(pos, self.doc.len())));
        self.primary = self.selections.items.len - 1;
        self.doc.breakUndoGroup();
        self.normalize();
    }

    /// Add a caret on the line above (`delta` -1) or below (+1) the outermost
    /// selection, at the same cell column. Returns false at the edge of the
    /// document.
    pub fn addCaretVertical(self: *View, delta: i2) !bool {
        const items = self.selections.items;
        const from = if (delta < 0) items[0] else items[items.len - 1];
        const p = self.place(from.head);
        if (delta < 0 and p.row == 0) return false;
        if (delta > 0 and p.row == self.lastRow()) return false;
        const cell = from.goal orelse text.cellOfByte(self.lineText(p.row), p.col, self.tab_width);
        const row = if (delta < 0) p.row - 1 else p.row + 1;
        var caret = Selection.caret(self.offsetAt(row, cell));
        caret.goal = cell;
        try self.selections.append(self.allocator, caret);
        self.primary = self.selections.items.len - 1;
        self.doc.breakUndoGroup();
        self.normalize();
        return true;
    }

    /// Esc: back to one selection, the primary, with nothing selected.
    pub fn collapse(self: *View) void {
        self.setCaret(self.primarySelection().head);
    }

    pub fn selectAll(self: *View) void {
        self.setSelection(.{ .anchor = 0, .head = self.doc.len() });
    }

    /// Select the word around `pos` (double click).
    pub fn selectWordAt(self: *View, pos: usize) void {
        const p = self.place(@min(pos, self.doc.len()));
        const w = text.wordAround(self.lineText(p.row), p.col);
        self.setSelection(.{ .anchor = p.line_start + w.start, .head = p.line_start + w.end });
    }

    /// Select the whole line at `pos`, with its newline (triple click).
    pub fn selectLineAt(self: *View, pos: usize) void {
        const p = self.place(@min(pos, self.doc.len()));
        self.setSelection(.{ .anchor = p.line_start, .head = self.doc.buffer.lineStart(p.row + 1) });
    }

    // --- movement --------------------------------------------------------

    /// Move every selection. With `extend` the anchor stays (shift+arrow);
    /// without it the selection collapses. `page` is the number of rows a
    /// page motion covers.
    pub fn move(self: *View, motion: Motion, extend: bool, page: usize) void {
        for (self.selections.items) |*s| {
            const vertical = switch (motion) {
                .up, .down, .page_up, .page_down => true,
                else => false,
            };
            // Leaving a selection without extending it lands on the edge in
            // the direction of travel, not one step beyond it.
            if (!extend and !s.isEmpty() and (motion == .left or motion == .right)) {
                s.* = Selection.caret(if (motion == .left) s.start() else s.end());
                continue;
            }
            const from = if (extend or s.isEmpty())
                s.head
            else switch (motion) {
                .up, .page_up => s.start(),
                .down, .page_down => s.end(),
                else => s.head,
            };
            var goal: ?usize = if (vertical) s.goal else null;
            const head = self.target(from, motion, page, &goal);
            s.head = head;
            if (!extend) s.anchor = head;
            s.goal = goal;
        }
        self.doc.breakUndoGroup();
        self.normalize();
    }

    fn target(self: *View, from: usize, motion: Motion, page: usize, goal: *?usize) usize {
        const buf = &self.doc.buffer;
        const p = self.place(from);
        switch (motion) {
            .left => {
                if (p.col == 0) return from -| 1; // onto the previous line's end
                return p.line_start + text.prevBoundary(self.lineText(p.row), p.col);
            },
            .right => {
                const line = self.lineText(p.row);
                if (p.col >= line.len) return @min(from + 1, buf.len());
                return p.line_start + text.nextBoundary(line, p.col);
            },
            .word_left => {
                if (p.col == 0) return from -| 1;
                return p.line_start + text.prevWordStart(self.lineText(p.row), p.col);
            },
            .word_right => {
                const line = self.lineText(p.row);
                if (p.col >= line.len) return @min(from + 1, buf.len());
                return p.line_start + text.nextWordEnd(line, p.col);
            },
            .line_start => {
                const text_start = text.indentEnd(self.lineText(p.row));
                return p.line_start + if (p.col == text_start) 0 else text_start;
            },
            .line_end => return buf.lineEnd(p.row),
            .doc_start => return 0,
            .doc_end => return buf.len(),
            .up, .down, .page_up, .page_down => {
                const cell = goal.* orelse text.cellOfByte(self.lineText(p.row), p.col, self.tab_width);
                goal.* = cell;
                const step = if (motion == .up or motion == .down) 1 else @max(page, 1);
                if (motion == .up or motion == .page_up) {
                    // Up from the first line goes to the start of the text,
                    // down from the last to its end, as editors do.
                    if (p.row == 0) return 0;
                    return self.offsetAt(p.row -| step, cell);
                }
                if (p.row == self.lastRow()) return buf.len();
                return self.offsetAt(@min(p.row + step, self.lastRow()), cell);
            },
        }
    }

    /// Adjust the scroll position so the primary cursor is inside a window
    /// of `rows` by `cols` cells.
    pub fn scrollToCursor(self: *View, rows: usize, cols: usize) void {
        const head = self.primarySelection().head;
        const row = self.doc.buffer.lineOf(head);
        const cell = self.cellOf(head);
        if (row < self.scroll_row) self.scroll_row = row;
        if (rows > 0 and row >= self.scroll_row + rows) self.scroll_row = row + 1 - rows;
        if (cell < self.scroll_col) self.scroll_col = cell;
        if (cols > 0 and cell >= self.scroll_col + cols) self.scroll_col = cell + 1 - cols;
    }

    // --- applying edits --------------------------------------------------

    const After = enum {
        /// Each selection keeps its range, moved with the text.
        keep,
        /// Each selection becomes a caret after the text that replaced it.
        caret_at_end,
    };

    /// Apply `edits` (sorted, non-overlapping) as one undo step and move the
    /// selections through them. `bias` says which way a selection end that
    /// sits exactly on an insertion point goes.
    fn apply(self: *View, edits: []const Edit, kind: Kind, after: After, bias: Bias) !void {
        if (edits.len == 0) return;
        const next = try self.allocator.alloc(Selection, self.selections.items.len);
        defer self.allocator.free(next);
        for (self.selections.items, next) |s, *n| {
            n.* = switch (after) {
                .keep => .{
                    .anchor = document.mapThroughEdits(edits, s.anchor, bias),
                    .head = document.mapThroughEdits(edits, s.head, bias),
                },
                .caret_at_end => Selection.caret(document.mapThroughEdits(edits, s.end(), .after)),
            };
        }
        const changed = try self.doc.edit(edits, .{
            .kind = kind,
            .time_ms = self.now_ms,
            .before = self.selections.items,
            .after = next,
        });
        if (!changed) return;
        // The observer has already moved the selections; this is the exact
        // answer for the view that made the edit.
        self.selections.clearRetainingCapacity();
        self.selections.appendSliceAssumeCapacity(next);
        self.normalize();
    }

    fn allEmpty(self: *const View) bool {
        for (self.selections.items) |s| {
            if (!s.isEmpty()) return false;
        }
        return true;
    }

    // --- typing ----------------------------------------------------------

    /// Type `bytes` at every cursor, replacing what is selected.
    pub fn insert(self: *View, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const edits = try self.allocator.alloc(Edit, self.selections.items.len);
        defer self.allocator.free(edits);
        for (self.selections.items, edits) |s, *e| e.* = .{ .start = s.start(), .end = s.end(), .text = bytes };
        // Plain typing groups into one undo step; replacing a selection or
        // inserting a line break is a step of its own.
        const plain = self.allEmpty() and std.mem.indexOfScalar(u8, bytes, '\n') == null;
        try self.apply(edits, if (plain) .typing else .other, .caret_at_end, .after);
    }

    /// Paste. With several cursors and exactly one line of text per cursor,
    /// each cursor gets its own line; otherwise every cursor gets all of it.
    pub fn paste(self: *View, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const count = self.selections.items.len;
        const edits = try self.allocator.alloc(Edit, count);
        defer self.allocator.free(edits);

        const body = if (bytes[bytes.len - 1] == '\n') bytes[0 .. bytes.len - 1] else bytes;
        const per_cursor = count > 1 and std.mem.count(u8, body, "\n") + 1 == count;
        var lines = std.mem.splitScalar(u8, body, '\n');
        for (self.selections.items, edits) |s, *e| {
            e.* = .{ .start = s.start(), .end = s.end(), .text = if (per_cursor) lines.next().? else bytes };
        }
        try self.apply(edits, .other, .caret_at_end, .after);
    }

    /// Enter: a line break that carries the indentation of the current line.
    pub fn newline(self: *View) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const edits = try a.alloc(Edit, self.selections.items.len);
        for (self.selections.items, edits) |s, *e| {
            const p = self.place(s.start());
            const line = self.lineText(p.row);
            // Only the indentation before the cursor: Enter in the middle of
            // the leading blanks must not add to them.
            const leading = line[0..@min(text.indentEnd(line), p.col)];
            const with_break = try a.alloc(u8, 1 + leading.len);
            with_break[0] = '\n';
            @memcpy(with_break[1..], leading);
            e.* = .{ .start = s.start(), .end = s.end(), .text = with_break };
        }
        try self.apply(edits, .other, .caret_at_end, .after);
    }

    /// Tab: indent the selected lines, or insert one indent unit at a caret.
    pub fn tab(self: *View) !void {
        if (self.allEmpty()) return self.insert(self.indent_unit);
        return self.indent();
    }

    // --- deleting --------------------------------------------------------

    const Reach = enum { char, word };

    /// Backspace: delete the selection, or the character before the cursor.
    /// Inside leading spaces it steps back one indent level.
    pub fn backspace(self: *View) !void {
        try self.erase(.back, .char);
    }

    /// Delete: delete the selection, or the character after the cursor.
    pub fn deleteForward(self: *View) !void {
        try self.erase(.forward, .char);
    }

    pub fn deleteWordBack(self: *View) !void {
        try self.erase(.back, .word);
    }

    pub fn deleteWordForward(self: *View) !void {
        try self.erase(.forward, .word);
    }

    fn erase(self: *View, direction: enum { back, forward }, reach: Reach) !void {
        var edits = std.ArrayList(Edit).empty;
        defer edits.deinit(self.allocator);
        try edits.ensureTotalCapacity(self.allocator, self.selections.items.len);
        const plain = self.allEmpty() and reach == .char;

        for (self.selections.items) |s| {
            var start = s.start();
            var end = s.end();
            if (s.isEmpty()) {
                const p = self.place(s.head);
                const line = self.lineText(p.row);
                if (direction == .back) {
                    if (s.head == 0) continue;
                    start = if (p.col == 0)
                        s.head - 1 // join with the previous line
                    else
                        p.line_start + switch (reach) {
                            .char => self.backspaceTarget(line, p.col),
                            .word => text.prevWordStart(line, p.col),
                        };
                } else {
                    if (s.head >= self.doc.len()) continue;
                    end = if (p.col >= line.len)
                        s.head + 1 // join with the next line
                    else
                        p.line_start + switch (reach) {
                            .char => text.nextBoundary(line, p.col),
                            .word => text.nextWordEnd(line, p.col),
                        };
                }
            }
            // Two cursors can reach back over the same bytes (two carets in
            // one run of indentation): merge instead of deleting twice.
            if (edits.items.len > 0 and start < edits.items[edits.items.len - 1].end) {
                const last = &edits.items[edits.items.len - 1];
                last.start = @min(last.start, start);
                last.end = @max(last.end, end);
            } else {
                edits.appendAssumeCapacity(.{ .start = start, .end = end });
            }
        }
        try self.apply(edits.items, if (plain) .erasing else .other, .caret_at_end, .before);
    }

    /// Where backspace goes from `col`: one character back, or one indent
    /// level when the cursor sits in leading spaces on an indent stop.
    fn backspaceTarget(self: *const View, line: []const u8, col: usize) usize {
        const unit = self.indent_unit.len;
        if (unit > 1 and self.indent_unit[0] == ' ' and col <= text.indentEnd(line) and col % unit == 0 and col >= unit) {
            if (std.mem.allEqual(u8, line[col - unit .. col], ' ')) return col - unit;
        }
        return text.prevBoundary(line, col);
    }

    // --- line operations -------------------------------------------------

    /// A run of whole lines touched by one or more selections.
    const Block = struct { first: usize, last: usize };

    /// The lines the selections cover, as merged blocks. A selection that
    /// ends at the very start of a line does not include that line (that is
    /// what selecting whole lines with shift+down produces).
    fn blocks(self: *View, a: Allocator) ![]Block {
        var out = std.ArrayList(Block).empty;
        for (self.selections.items) |s| {
            const first = self.doc.buffer.lineOf(s.start());
            var last = self.doc.buffer.lineOf(s.end());
            if (!s.isEmpty() and last > first and self.doc.buffer.lineStart(last) == s.end()) last -= 1;
            if (out.items.len > 0 and first <= out.items[out.items.len - 1].last + 1) {
                const prev = &out.items[out.items.len - 1];
                prev.last = @max(prev.last, last);
            } else {
                try out.append(a, .{ .first = first, .last = last });
            }
        }
        return out.items;
    }

    /// Copy of the document text in `[start, end)`, owned by `a`.
    fn copyRange(self: *View, a: Allocator, start: usize, end: usize) ![]u8 {
        const out = try a.alloc(u8, end - start);
        var at: usize = 0;
        var it = self.doc.buffer.chunks(start, end);
        while (it.next()) |chunk| {
            @memcpy(out[at..][0..chunk.len], chunk);
            at += chunk.len;
        }
        return out;
    }

    /// Duplicate the selected lines below themselves; the selections stay on
    /// the copy.
    pub fn duplicateLines(self: *View) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const buf = &self.doc.buffer;
        const list = try self.blocks(a);
        const edits = try a.alloc(Edit, list.len);
        for (list, edits) |b, *e| {
            const start = buf.lineStart(b.first);
            const body = try self.copyRange(a, start, buf.lineEnd(b.last));
            const copy = try a.alloc(u8, body.len + 1);
            @memcpy(copy[0..body.len], body);
            copy[body.len] = '\n';
            // Inserting above and letting the selections ride down with the
            // text works on the last line too, which has no newline to copy.
            e.* = .{ .start = start, .end = start, .text = copy };
        }
        try self.apply(edits, .other, .keep, .after);
    }

    /// Delete the selected lines.
    pub fn deleteLines(self: *View) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const buf = &self.doc.buffer;
        const list = try self.blocks(a);
        const edits = try a.alloc(Edit, list.len);
        for (list, edits) |b, *e| {
            if (b.last < self.lastRow()) {
                e.* = .{ .start = buf.lineStart(b.first), .end = buf.lineStart(b.last + 1) };
            } else {
                // The last line has no newline of its own: take the one
                // before the block instead, if there is one.
                const start = if (b.first == 0) 0 else buf.lineEnd(b.first - 1);
                e.* = .{ .start = start, .end = buf.len() };
            }
        }
        try self.apply(edits, .other, .caret_at_end, .before);
    }

    /// Move the selected lines one line up (`delta` -1) or down (+1).
    pub fn moveLines(self: *View, delta: i2) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const buf = &self.doc.buffer;
        const list = try self.blocks(a);
        var edits = std.ArrayList(Edit).empty;
        for (list) |b| {
            if (delta < 0) {
                if (b.first == 0) continue;
                // The line above goes below the block.
                const above = try self.copyRange(a, buf.lineStart(b.first - 1), buf.lineEnd(b.first - 1));
                const moved = try a.alloc(u8, above.len + 1);
                moved[0] = '\n';
                @memcpy(moved[1..], above);
                try edits.append(a, .{ .start = buf.lineStart(b.first - 1), .end = buf.lineStart(b.first) });
                try edits.append(a, .{ .start = buf.lineEnd(b.last), .end = buf.lineEnd(b.last), .text = moved });
            } else {
                if (b.last >= self.lastRow()) continue;
                // The line below goes above the block.
                const below = try self.copyRange(a, buf.lineStart(b.last + 1), buf.lineEnd(b.last + 1));
                const moved = try a.alloc(u8, below.len + 1);
                @memcpy(moved[0..below.len], below);
                moved[below.len] = '\n';
                try edits.append(a, .{ .start = buf.lineStart(b.first), .end = buf.lineStart(b.first), .text = moved });
                try edits.append(a, .{ .start = buf.lineEnd(b.last), .end = buf.lineEnd(b.last + 1) });
            }
        }
        // Moving up, a cursor at the end of the block must stay in front of
        // the line that lands there; moving down, a cursor at the start of
        // the block must go down with it.
        try self.apply(edits.items, .other, .keep, if (delta < 0) .before else .after);
    }

    /// Indent every selected line by one unit. Empty lines are left alone.
    pub fn indent(self: *View) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const buf = &self.doc.buffer;
        var edits = std.ArrayList(Edit).empty;
        for (try self.blocks(a)) |b| {
            var row = b.first;
            while (row <= b.last) : (row += 1) {
                const start = buf.lineStart(row);
                if (buf.lineEnd(row) == start) continue;
                try edits.append(a, .{ .start = start, .end = start, .text = self.indent_unit });
            }
        }
        try self.apply(edits.items, .other, .keep, .after);
    }

    /// Remove one level of indentation from every selected line: one tab, or
    /// up to one unit of spaces.
    pub fn dedent(self: *View) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const buf = &self.doc.buffer;
        var edits = std.ArrayList(Edit).empty;
        for (try self.blocks(a)) |b| {
            var row = b.first;
            while (row <= b.last) : (row += 1) {
                const line = self.lineText(row);
                var n: usize = 0;
                if (line.len > 0 and line[0] == '\t') {
                    n = 1;
                } else {
                    const max = @max(self.indent_unit.len, 1);
                    while (n < line.len and n < max and line[n] == ' ') n += 1;
                }
                if (n == 0) continue;
                const start = buf.lineStart(row);
                try edits.append(a, .{ .start = start, .end = start + n });
            }
        }
        try self.apply(edits.items, .other, .keep, .before);
    }

    /// Comment the selected lines with `token` (for example `//`), or
    /// uncomment them when every non-blank line already is. The marker goes
    /// at the shallowest indentation of the block, so nested code stays
    /// aligned.
    pub fn toggleComment(self: *View, token: []const u8) !void {
        if (token.len == 0) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const buf = &self.doc.buffer;
        const marker = try a.alloc(u8, token.len + 1);
        @memcpy(marker[0..token.len], token);
        marker[token.len] = ' ';

        var edits = std.ArrayList(Edit).empty;
        for (try self.blocks(a)) |b| {
            var commented = true;
            var any = false;
            var depth: usize = std.math.maxInt(usize);
            var row = b.first;
            while (row <= b.last) : (row += 1) {
                const line = self.lineText(row);
                const at = text.indentEnd(line);
                if (at == line.len) continue; // blank
                any = true;
                depth = @min(depth, at);
                if (!std.mem.startsWith(u8, line[at..], token)) commented = false;
            }
            if (!any) continue;

            row = b.first;
            while (row <= b.last) : (row += 1) {
                const line = self.lineText(row);
                const at = text.indentEnd(line);
                if (at == line.len) continue;
                const start = buf.lineStart(row);
                if (commented) {
                    var n = token.len;
                    if (at + n < line.len and line[at + n] == ' ') n += 1;
                    try edits.append(a, .{ .start = start + at, .end = start + at + n });
                } else {
                    try edits.append(a, .{ .start = start + depth, .end = start + depth, .text = marker });
                }
            }
        }
        try self.apply(edits.items, .other, .keep, .after);
    }

    // --- clipboard -------------------------------------------------------

    /// The text Ctrl+C takes: the selections, one per line when there are
    /// several, or the whole current line(s) when nothing is selected.
    /// Owned by the caller.
    pub fn copyText(self: *View, allocator: Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        const buf = &self.doc.buffer;
        if (self.allEmpty()) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            for (try self.blocks(arena.allocator())) |b| {
                var it = buf.chunks(buf.lineStart(b.first), buf.lineEnd(b.last));
                while (it.next()) |chunk| try out.appendSlice(allocator, chunk);
                try out.append(allocator, '\n');
            }
        } else {
            var first = true;
            for (self.selections.items) |s| {
                if (s.isEmpty()) continue;
                if (!first) try out.append(allocator, '\n');
                first = false;
                var it = buf.chunks(s.start(), s.end());
                while (it.next()) |chunk| try out.appendSlice(allocator, chunk);
            }
        }
        return out.toOwnedSlice(allocator);
    }

    /// Ctrl+X: what `copyText` returns, removed from the document.
    pub fn cutText(self: *View, allocator: Allocator) ![]u8 {
        const taken = try self.copyText(allocator);
        errdefer allocator.free(taken);
        if (self.allEmpty()) {
            try self.deleteLines();
        } else {
            try self.erase(.back, .char); // every non-empty selection
        }
        return taken;
    }

    // --- history ---------------------------------------------------------

    /// Undo one step and put the cursors back where they were before it.
    /// Returns false when there was nothing to undo.
    pub fn undo(self: *View) !bool {
        const tx = try self.doc.undo() orelse return false;
        if (tx.before.items.len > 0) try self.setSelections(tx.before.items, 0);
        return true;
    }

    pub fn redo(self: *View) !bool {
        const tx = try self.doc.redo() orelse return false;
        if (tx.after.items.len > 0) try self.setSelections(tx.after.items, 0);
        return true;
    }
};

// --- tests ---------------------------------------------------------------
//
// Tests write a document with its selections in one string: `|` is a caret,
// `[...>` a selection with the head at the end, `<...]` one with the head at
// the start. `expectState` renders the view the same way.

const testing = std.testing;

const Fixture = struct {
    doc: *Document,
    view: *View,

    fn init(marked: []const u8) !Fixture {
        const a = testing.allocator;
        var plain = std.ArrayList(u8).empty;
        defer plain.deinit(a);
        var sels = std.ArrayList(Selection).empty;
        defer sels.deinit(a);
        var open: usize = 0;
        for (marked) |c| {
            const pos = plain.items.len;
            switch (c) {
                '|' => try sels.append(a, Selection.caret(pos)),
                '[', '<' => open = pos,
                '>' => try sels.append(a, .{ .anchor = open, .head = pos }),
                ']' => try sels.append(a, .{ .anchor = pos, .head = open }),
                else => try plain.append(a, c),
            }
        }

        const doc = try a.create(Document);
        errdefer a.destroy(doc);
        doc.* = try Document.init(a, plain.items);
        errdefer doc.deinit();
        const view = try View.create(a, doc);
        errdefer view.destroy();
        if (sels.items.len > 0) try view.setSelections(sels.items, 0);
        return .{ .doc = doc, .view = view };
    }

    fn deinit(self: *Fixture) void {
        self.view.destroy();
        self.doc.deinit();
        testing.allocator.destroy(self.doc);
    }

    fn expect(self: *Fixture, want: []const u8) !void {
        try expectState(self.view, want);
    }
};

fn expectState(view: *View, want: []const u8) !void {
    const a = testing.allocator;
    const plain = try view.doc.buffer.toOwned(a);
    defer a.free(plain);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    var at: usize = 0;
    for (view.selections.items) |s| {
        try out.appendSlice(a, plain[at..s.start()]);
        if (s.isEmpty()) {
            try out.append(a, '|');
        } else {
            try out.append(a, if (s.head < s.anchor) '<' else '[');
            try out.appendSlice(a, plain[s.start()..s.end()]);
            try out.append(a, if (s.head < s.anchor) ']' else '>');
        }
        at = s.end();
    }
    try out.appendSlice(a, plain[at..]);
    try testing.expectEqualStrings(want, out.items);
}

test "typing at one cursor and at several" {
    var f = try Fixture.init("|one\n|two\n|three");
    defer f.deinit();
    try f.view.insert("- ");
    try f.expect("- |one\n- |two\n- |three");
    try f.view.insert("x");
    try f.expect("- x|one\n- x|two\n- x|three");

    // One undo step for the run, and the cursors come back.
    try testing.expect(try f.view.undo());
    try f.expect("|one\n|two\n|three");
    try testing.expect(try f.view.redo());
    try f.expect("- x|one\n- x|two\n- x|three");
}

test "typing replaces a selection" {
    var f = try Fixture.init("say [hello> and <bye]");
    defer f.deinit();
    try f.view.insert("X");
    try f.expect("say X| and X|");
    _ = try f.view.undo();
    try f.expect("say [hello> and <bye]");
}

test "left and right, across lines and out of selections" {
    var f = try Fixture.init("ab\n|cd");
    defer f.deinit();
    f.view.move(.left, false, 0);
    try f.expect("ab|\ncd");
    f.view.move(.right, false, 0);
    f.view.move(.right, false, 0);
    try f.expect("ab\nc|d");
    f.view.move(.left, true, 0);
    f.view.move(.left, true, 0);
    try f.expect("ab<\nc]d");
    f.view.move(.right, false, 0); // collapses to the right edge
    try f.expect("ab\nc|d");
    f.view.move(.doc_end, false, 0);
    f.view.move(.right, false, 0); // nothing past the end
    try f.expect("ab\ncd|");
    f.view.move(.doc_start, false, 0);
    f.view.move(.left, false, 0);
    try f.expect("|ab\ncd");
}

test "vertical movement remembers the column through short lines" {
    var f = try Fixture.init("long line|\nx\nanother long one");
    defer f.deinit();
    f.view.move(.down, false, 0);
    try f.expect("long line\nx|\nanother long one");
    f.view.move(.down, false, 0);
    try f.expect("long line\nx\nanother l|ong one");
    f.view.move(.down, false, 0); // last line: to the end of the text
    try f.expect("long line\nx\nanother long one|");
    f.view.move(.up, false, 0);
    f.view.move(.up, false, 0);
    try f.expect("long line|\nx\nanother long one");
    f.view.move(.up, false, 0); // first line: to the start
    try f.expect("|long line\nx\nanother long one");
}

test "vertical movement goes by cells, not bytes" {
    var f = try Fixture.init("日本語|\nabcdefgh\n\tz");
    defer f.deinit();
    f.view.move(.down, false, 0);
    try f.expect("日本語\nabcdef|gh\n\tz"); // three wide characters are six cells
    f.view.move(.down, false, 0);
    try f.expect("日本語\nabcdefgh\n\tz|"); // tab is four cells, z the fifth
}

test "page motion clamps to the document" {
    var f = try Fixture.init("a\nb|\nc\nd\ne");
    defer f.deinit();
    f.view.move(.page_down, false, 2);
    try f.expect("a\nb\nc\nd|\ne");
    f.view.move(.page_down, false, 10);
    try f.expect("a\nb\nc\nd\ne|");
    f.view.move(.page_up, true, 3);
    try f.expect("a\nb<\nc\nd\ne]");
}

test "home toggles between the indentation and column zero" {
    var f = try Fixture.init("    indented| line");
    defer f.deinit();
    f.view.move(.line_start, false, 0);
    try f.expect("    |indented line");
    f.view.move(.line_start, false, 0);
    try f.expect("|    indented line");
    f.view.move(.line_start, false, 0);
    try f.expect("    |indented line");
    f.view.move(.line_end, true, 0);
    try f.expect("    [indented line>");
}

test "word motion crosses lines" {
    var f = try Fixture.init("foo bar|\nbaz");
    defer f.deinit();
    f.view.move(.word_right, false, 0);
    try f.expect("foo bar\n|baz");
    f.view.move(.word_right, false, 0);
    try f.expect("foo bar\nbaz|");
    f.view.move(.word_left, false, 0);
    f.view.move(.word_left, false, 0);
    try f.expect("foo bar|\nbaz");
    f.view.move(.word_left, true, 0);
    try f.expect("foo <bar]\nbaz");
}

test "cursors that meet become one" {
    var f = try Fixture.init("a|b|c");
    defer f.deinit();
    f.view.move(.line_start, false, 0);
    try f.expect("|abc");
    try testing.expect(!f.view.hasMultiple());
}

test "backspace: characters, line joins, indentation and selections" {
    var f = try Fixture.init("ab|\n|cd");
    defer f.deinit();
    try f.view.backspace();
    try f.expect("a|cd"); // the two carets met and became one
    _ = try f.view.undo();
    try f.expect("ab|\n|cd");

    var g = try Fixture.init("        |deep\n   |odd\nx[yz>");
    defer g.deinit();
    try g.view.backspace();
    try g.expect("    |deep\n  |odd\nx|"); // one indent level; one space; the selection
    try g.view.backspace();
    try g.expect("|deep\n |odd\n|");
}

test "backspace with two carets in one run of indentation deletes it once" {
    var f = try Fixture.init("  |  |x");
    defer f.deinit();
    try f.view.backspace();
    try f.expect("|x");
}

test "backspace removes a character with its combining marks" {
    var f = try Fixture.init("ae\u{301}|");
    defer f.deinit();
    try f.view.backspace();
    try f.expect("a|");
}

test "delete forward and by word" {
    var f = try Fixture.init("|one two\n|three");
    defer f.deinit();
    try f.view.deleteForward();
    try f.expect("|ne two\n|hree");
    try f.view.deleteWordForward();
    try f.expect("| two\n|");
    try f.view.deleteForward();
    try f.view.deleteForward();
    try f.expect("|wo\n|");

    var g = try Fixture.init("alpha beta| gamma|");
    defer g.deinit();
    try g.view.deleteWordBack();
    try g.expect("alpha | |");
    // At the end of a line Delete joins the next one.
    var h = try Fixture.init("a|\nb");
    defer h.deinit();
    try h.view.deleteForward();
    try h.expect("a|b");
}

test "a run of backspaces is one undo step" {
    var f = try Fixture.init("hello|");
    defer f.deinit();
    f.view.now_ms = 0;
    try f.view.backspace();
    f.view.now_ms = 100;
    try f.view.backspace();
    try f.expect("hel|");
    _ = try f.view.undo();
    try f.expect("hello|");
}

test "newline keeps the indentation" {
    var f = try Fixture.init("    if x:|\n  |  y");
    defer f.deinit();
    try f.view.newline();
    try f.expect("    if x:\n    |\n  \n  |  y");
}

test "tab inserts at a caret and indents a selection" {
    var f = try Fixture.init("a|b");
    defer f.deinit();
    try f.view.tab();
    try f.expect("a    |b");

    var g = try Fixture.init("[one\n\ntwo>\nthree");
    defer g.deinit();
    try g.view.tab();
    try g.expect("    [one\n\n    two>\nthree"); // the empty line stays empty
    try g.view.dedent();
    try g.expect("[one\n\ntwo>\nthree");
    try g.view.dedent(); // nothing left to remove
    try g.expect("[one\n\ntwo>\nthree");
}

test "dedent takes a tab or up to one unit of spaces" {
    var f = try Fixture.init("[\ta\n  b\n      c>");
    defer f.deinit();
    try f.view.dedent();
    try f.expect("[a\nb\n  c>");
}

test "duplicate lines keeps the selection on the copy" {
    var f = try Fixture.init("one\nt|wo\nthree");
    defer f.deinit();
    try f.view.duplicateLines();
    try f.expect("one\ntwo\nt|wo\nthree");

    var g = try Fixture.init("a\n[b\nc>"); // through the last line, which has no newline
    defer g.deinit();
    try g.view.duplicateLines();
    try g.expect("a\nb\nc\n[b\nc>");
    _ = try g.view.undo();
    try g.expect("a\n[b\nc>");
}

test "two cursors on one line duplicate it once" {
    var f = try Fixture.init("a|b|c\nz");
    defer f.deinit();
    try f.view.duplicateLines();
    try f.expect("abc\na|b|c\nz");
}

test "delete lines, including the last one" {
    var f = try Fixture.init("one\nt|wo\nthree");
    defer f.deinit();
    try f.view.deleteLines();
    try f.expect("one\n|three");
    try f.view.deleteLines();
    try f.expect("one|");
    try f.view.deleteLines();
    try f.expect("|");
}

test "move lines up and down" {
    var f = try Fixture.init("one\nt|wo\nthree");
    defer f.deinit();
    try f.view.moveLines(-1);
    try f.expect("t|wo\none\nthree");
    try f.view.moveLines(-1); // already at the top
    try f.expect("t|wo\none\nthree");
    try f.view.moveLines(1);
    try f.view.moveLines(1);
    try f.expect("one\nthree\nt|wo");
    try f.view.moveLines(1); // already at the bottom
    try f.expect("one\nthree\nt|wo");
}

test "move a block and two separate blocks" {
    var f = try Fixture.init("a\n[b\nc>\nd");
    defer f.deinit();
    try f.view.moveLines(1);
    try f.expect("a\nd\n[b\nc>");
    try f.view.moveLines(-1);
    try f.view.moveLines(-1);
    try f.expect("[b\nc>\na\nd");

    var g = try Fixture.init("0\n|1\n2\n|3\n4");
    defer g.deinit();
    try g.view.moveLines(-1);
    try g.expect("|1\n0\n|3\n2\n4");
    try g.view.moveLines(1);
    try g.expect("0\n|1\n2\n|3\n4");
}

test "a selection ending at a line start does not take that line" {
    var f = try Fixture.init("[one\n>two");
    defer f.deinit();
    try f.view.duplicateLines();
    try f.expect("one\n[one\n>two");
}

test "toggle comment" {
    var f = try Fixture.init("[fn main() {\n    body();\n\n}>");
    defer f.deinit();
    try f.view.toggleComment("//");
    try f.expect("// [fn main() {\n//     body();\n\n// }>");
    try f.view.toggleComment("//");
    try f.expect("[fn main() {\n    body();\n\n}>");

    // The marker goes at the block's shallowest indentation.
    var g = try Fixture.init("    [a\n        b>");
    defer g.deinit();
    try g.view.toggleComment("#");
    try g.expect("    # [a\n    #     b>");
    // Uncommenting accepts a marker with no space after it.
    var h = try Fixture.init("#x|");
    defer h.deinit();
    try h.view.toggleComment("#");
    try h.expect("x|");
}

test "copy, cut and paste" {
    const a = testing.allocator;
    var f = try Fixture.init("[one> two [three>");
    defer f.deinit();
    const copied = try f.view.copyText(a);
    defer a.free(copied);
    try testing.expectEqualStrings("one\nthree", copied);

    // One line per cursor goes back one line per cursor.
    f.view.move(.right, false, 0);
    try f.expect("one| two three|");
    try f.view.paste(copied);
    try f.expect("oneone| two threethree|");
    // Anything else goes to every cursor whole.
    try f.view.paste("!");
    try f.expect("oneone!| two threethree!|");

    const cut = try f.view.cutText(a); // nothing selected: the line
    defer a.free(cut);
    try testing.expectEqualStrings("oneone! two threethree!\n", cut);
    try f.expect("|");
}

test "cut takes the selections" {
    const a = testing.allocator;
    var f = try Fixture.init("a[bc>d\n[ef>");
    defer f.deinit();
    const cut = try f.view.cutText(a);
    defer a.free(cut);
    try testing.expectEqualStrings("bc\nef", cut);
    try f.expect("a|d\n|");
}

test "select word, line and all" {
    var f = try Fixture.init("say hello there\nnext");
    defer f.deinit();
    f.view.selectWordAt(6);
    try f.expect("say [hello> there\nnext");
    f.view.selectLineAt(6);
    try f.expect("[say hello there\n>next");
    f.view.selectAll();
    try f.expect("[say hello there\nnext>");
    f.view.collapse();
    try f.expect("say hello there\nnext|");
}

test "add carets above and below, and by position" {
    var f = try Fixture.init("abcdef\nab\nabcdef|");
    defer f.deinit();
    try testing.expect(try f.view.addCaretVertical(-1));
    try testing.expect(try f.view.addCaretVertical(-1));
    try f.expect("abcdef|\nab|\nabcdef|"); // the short line clamps, the column is kept
    try testing.expect(!try f.view.addCaretVertical(-1));
    try f.view.addCaret(1);
    try f.expect("a|bcdef|\nab|\nabcdef|");
    f.view.extendTo(3);
    try f.expect("a[bc>def|\nab|\nabcdef|");
}

test "offsetAt maps a click to a cursor position" {
    var f = try Fixture.init("a\t日本\nxyz");
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.view.offsetAt(0, 0));
    try testing.expectEqual(@as(usize, 1), f.view.offsetAt(0, 2)); // inside the tab
    try testing.expectEqual(@as(usize, 2), f.view.offsetAt(0, 5)); // second cell of 日
    try testing.expectEqual(@as(usize, 8), f.view.offsetAt(0, 99));
    try testing.expectEqual(@as(usize, 11), f.view.offsetAt(7, 2)); // past the last row
}

test "scrollToCursor keeps the cursor in the window" {
    var f = try Fixture.init("0\n1\n2\n3\n4\n5\n6\n7\n8\nlong line here|");
    defer f.deinit();
    f.view.scrollToCursor(4, 10);
    try testing.expectEqual(@as(usize, 6), f.view.scroll_row);
    try testing.expectEqual(@as(usize, 5), f.view.scroll_col);
    f.view.move(.doc_start, false, 0);
    f.view.scrollToCursor(4, 10);
    try testing.expectEqual(@as(usize, 0), f.view.scroll_row);
    try testing.expectEqual(@as(usize, 0), f.view.scroll_col);
}

test "a second view follows edits made in the first" {
    var f = try Fixture.init("one\ntwo|\nthree");
    defer f.deinit();
    const other = try View.create(testing.allocator, f.doc);
    defer other.destroy();
    other.setCaret(10); // in "three"

    f.view.move(.doc_start, false, 0);
    try f.view.insert("## ");
    try expectState(other, "## one\ntwo\nth|ree");
    try f.view.deleteLines();
    try expectState(other, "two\nth|ree");
    _ = try f.view.undo();
    _ = try f.view.undo();
    try expectState(other, "one\ntwo\nth|ree");

    // Text the other view's cursor was in disappears: it lands on the edge.
    f.view.selectAll();
    try f.view.insert("x");
    try expectState(other, "|x");
}

test "allocation failure in a command leaves text and selections intact" {
    const Check = struct {
        fn run(allocator: Allocator) !void {
            var doc = try Document.init(allocator, "  one\n  two\nthree");
            defer doc.deinit();
            const view = try View.create(allocator, &doc);
            defer view.destroy();
            try view.setSelections(&.{ Selection.caret(3), .{ .anchor = 8, .head = 14 } }, 0);

            inline for (.{ "insert", "newline", "duplicate", "move", "comment", "dedent" }) |name| {
                const text_before = try doc.buffer.toOwned(allocator);
                defer allocator.free(text_before);
                const sels_before = try allocator.dupe(Selection, view.selections.items);
                defer allocator.free(sels_before);
                const revision = doc.revision;

                const result = if (comptime std.mem.eql(u8, name, "insert"))
                    view.insert("xy")
                else if (comptime std.mem.eql(u8, name, "newline"))
                    view.newline()
                else if (comptime std.mem.eql(u8, name, "duplicate"))
                    view.duplicateLines()
                else if (comptime std.mem.eql(u8, name, "move"))
                    view.moveLines(1)
                else if (comptime std.mem.eql(u8, name, "comment"))
                    view.toggleComment("//")
                else
                    view.dedent();
                result catch |e| {
                    // A failed command did nothing at all.
                    try testing.expectEqual(revision, doc.revision);
                    try testing.expectEqualSlices(Selection, sels_before, view.selections.items);
                    var at: usize = 0;
                    var it = doc.buffer.chunks(0, doc.len());
                    while (it.next()) |chunk| {
                        try testing.expectEqualStrings(text_before[at..][0..chunk.len], chunk);
                        at += chunk.len;
                    }
                    try testing.expectEqual(text_before.len, at);
                    return e;
                };
                // Put the document back for the next command.
                _ = try view.undo();
            }
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{});
}
