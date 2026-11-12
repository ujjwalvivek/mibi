//! Draws one view of a document into a rectangle: line numbers, text with
//! syntax colours, selections and cursors. Also the inverse, for the mouse:
//! which document offset is under a cell.
//!
//! Nothing is stored here. The pane's state is the core `View` (selections,
//! scroll); this file is a function of it.

const std = @import("std");
const core = @import("core");
const screen = @import("screen.zig");
const Theme = @import("theme.zig").Theme;
const View = core.View;
const syntax = core.syntax;
const utf8 = core.utf8;
const text = core.text;

pub const Options = struct {
    theme: *const Theme,
    line_numbers: bool = true,
    /// The pane with the keyboard focus draws its cursors and tints the
    /// cursor's line; the others show text and selections only.
    focused: bool = true,
    /// Null when syntax colouring is off or the file type is unknown.
    highlighter: ?*core.highlight.Highlighter = null,
};

fn digits(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

/// Cells taken by the line numbers and the blank after them.
pub fn gutterWidth(view: *const View, line_numbers: bool) usize {
    return if (line_numbers) digits(view.doc.buffer.lineCount()) + 1 else 0;
}

/// Cells of text that fit in a pane `width` cells wide. One cell is kept
/// free at the right so the cursor can stand after the last character.
pub fn textCols(view: *const View, width: usize, line_numbers: bool) usize {
    return width -| (gutterWidth(view, line_numbers) + 1);
}

/// The document offset under screen cell `(x, y)` of a pane drawn at `r`.
/// Cells outside the text (the gutter, below the last line) give the nearest
/// position.
pub fn offsetAt(view: *View, r: screen.Rect, line_numbers: bool, x: usize, y: usize) usize {
    const gutter = gutterWidth(view, line_numbers);
    const row = view.scroll_row + (@max(y, r.y) - r.y);
    const cell = view.scroll_col + (@max(x, r.x + gutter) - r.x - gutter);
    return view.offsetAt(row, cell);
}

fn colorOf(class: syntax.Class, theme: *const Theme) screen.Color {
    return switch (class) {
        .normal => theme.text,
        .comment, .ml_comment => theme.comment,
        .keyword1 => theme.keyword1,
        .keyword2 => theme.keyword2,
        .string, .ml_string => theme.string,
        .number => theme.number,
    };
}

pub fn draw(s: *screen.Screen, r: screen.Rect, view: *View, opts: Options) void {
    if (r.w == 0 or r.h == 0) return;
    const theme = opts.theme;
    const buf = &view.doc.buffer;
    const total = buf.lineCount();
    const gutter = gutterWidth(view, opts.line_numbers);
    const right = r.right();
    const text_x = r.x + gutter;
    const sels = view.selections.items;
    const head_row = buf.lineOf(view.primarySelection().head);
    const line_bg = theme.lineHighlight();

    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(view.allocator);
    var spans: [syntax.MAX_SPANS]syntax.Span = undefined;
    // Selections are sorted, so one index walks them as the rows go down.
    var sel_i: usize = 0;

    var vrow: usize = 0;
    while (vrow < r.h) : (vrow += 1) {
        const row = view.scroll_row + vrow;
        if (row >= total) break;
        const y = r.y + vrow;
        // An unreadable line (out of memory joining its pieces) is drawn
        // empty rather than not drawing the frame.
        const line = buf.line(row, &scratch) catch "";
        const line_start = buf.lineStart(row);
        const line_end = line_start + line.len;

        const tinted = opts.focused and row == head_row and !line_bg.isDefault();
        const row_bg = if (tinted) line_bg else theme.background;
        if (tinted) s.fill(.{ .x = r.x, .y = y, .w = r.w, .h = 1 }, .{ .bg = row_bg });

        if (gutter > 0) {
            var num_buf: [24]u8 = undefined;
            const num = std.fmt.bufPrint(&num_buf, "{d}", .{row + 1}) catch "";
            const fg = if (opts.focused and row == head_row) theme.text else theme.gutter;
            _ = s.text(r.x + (gutter - 1 - num.len), y, right, num, .{ .fg = fg, .bg = row_bg });
        }

        const nspans = if (opts.highlighter) |h| h.spans(row, line, &spans) else 0;
        while (sel_i < sels.len and sels[sel_i].end() < line_start) sel_i += 1;

        var cell: usize = 0; // cell column in the line, before scrolling
        var i: usize = 0;
        var span_i: usize = 0;
        var si = sel_i;
        while (i < line.len) {
            const at = i;
            const cp = utf8.nextCp(line, &i);
            const w = text.cellsFor(cp, cell, view.tab_width);
            if (w == 0) continue; // combining mark: drawn with the cell before
            const pos = line_start + at;
            while (si < sels.len and sels[si].end() <= pos) si += 1;
            const selected = si < sels.len and !sels[si].isEmpty() and sels[si].start() <= pos;
            while (span_i < nspans and spans[span_i].end <= at) span_i += 1;
            const class: syntax.Class = if (span_i < nspans and at >= spans[span_i].start) spans[span_i].class else .normal;
            const style = screen.Cell{
                .ch = if (cp == '\t' or cp < 0x20 or cp == 0x7f) ' ' else cp,
                .fg = colorOf(class, theme),
                .bg = if (selected) theme.selection else row_bg,
            };
            if (cell + w > view.scroll_col) {
                const x = text_x + (cell -| view.scroll_col);
                if (x >= right) break;
                if (cp == '\t' or cell < view.scroll_col) {
                    // A tab, or a wide character cut by the left edge: blanks.
                    var k = @max(cell, view.scroll_col);
                    while (k < cell + w) : (k += 1) {
                        const tx = text_x + (k - view.scroll_col);
                        if (tx < right) s.put(tx, y, .{ .fg = style.fg, .bg = style.bg });
                    }
                } else if (x + w <= right) {
                    s.put(x, y, style);
                    if (w == 2) s.put(x + 1, y, .{ .fg = style.fg, .bg = style.bg, .cont = true });
                }
            }
            cell += w;
        }

        // A selection that runs past the end of the line shows one selected
        // cell where the newline is.
        while (si < sels.len and sels[si].end() <= line_end) si += 1;
        if (si < sels.len and !sels[si].isEmpty() and sels[si].start() <= line_end and cell >= view.scroll_col) {
            const x = text_x + (cell - view.scroll_col);
            if (x < right) s.put(x, y, .{ .bg = theme.selection });
        }
    }

    if (!opts.focused) return;
    // Cursors last, so they win over the selection colour.
    for (sels) |sel| {
        const row = buf.lineOf(sel.head);
        if (row < view.scroll_row or row >= view.scroll_row + r.h) continue;
        const cell = view.cellOf(sel.head);
        if (cell < view.scroll_col) continue;
        const x = text_x + (cell - view.scroll_col);
        if (x >= right) continue;
        const y = r.y + (row - view.scroll_row);
        var under = s.at(x, y);
        if (under.cont) under = .{};
        s.put(x, y, .{ .ch = under.ch, .fg = theme.text, .attr = .{ .reverse = true } });
        if (x + 1 < right and s.at(x + 1, y).cont) {
            s.put(x + 1, y, .{ .fg = theme.text, .attr = .{ .reverse = true }, .cont = true });
        }
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    doc: *core.Document,
    view: *View,
    s: screen.Screen,
    theme: Theme = .{},
    buf: [256]u8 = undefined,

    fn init(content: []const u8, cols: usize, rows: usize) !Fixture {
        const doc = try testing.allocator.create(core.Document);
        errdefer testing.allocator.destroy(doc);
        doc.* = try core.Document.init(testing.allocator, content);
        errdefer doc.deinit();
        const view = try View.create(testing.allocator, doc);
        errdefer view.destroy();
        return .{ .doc = doc, .view = view, .s = try screen.Screen.init(testing.allocator, cols, rows) };
    }

    fn deinit(self: *Fixture) void {
        self.s.deinit();
        self.view.destroy();
        self.doc.deinit();
        testing.allocator.destroy(self.doc);
    }

    fn render(self: *Fixture, opts: struct { line_numbers: bool = true, focused: bool = true }) void {
        self.s.clear();
        draw(&self.s, self.s.area(), self.view, .{ .theme = &self.theme, .line_numbers = opts.line_numbers, .focused = opts.focused });
    }

    fn row(self: *Fixture, y: usize) []const u8 {
        return self.s.rowText(y, &self.buf);
    }
};

test "text, gutter and cursor" {
    var f = try Fixture.init("one\ntwo\nthree", 20, 5);
    defer f.deinit();
    f.render(.{});
    try testing.expectEqualStrings("1 one", f.row(0));
    try testing.expectEqualStrings("2 two", f.row(1));
    try testing.expectEqualStrings("3 three", f.row(2));
    try testing.expectEqualStrings("", f.row(3));
    try testing.expect(f.s.at(2, 0).attr.reverse); // cursor on 'o'
    try testing.expectEqual(@as(u21, 'o'), f.s.at(2, 0).ch);
    try testing.expect(!f.s.at(3, 0).attr.reverse);

    f.render(.{ .line_numbers = false });
    try testing.expectEqualStrings("one", f.row(0));

    // An unfocused pane has no cursor.
    f.render(.{ .focused = false });
    try testing.expect(!f.s.at(2, 0).attr.reverse);
}

test "the gutter grows with the line count" {
    var f = try Fixture.init("a\n" ** 11, 20, 3);
    defer f.deinit();
    f.render(.{});
    try testing.expectEqualStrings(" 1 a", f.row(0));
    try testing.expectEqual(@as(usize, 3), gutterWidth(f.view, true));
    try testing.expectEqual(@as(usize, 16), textCols(f.view, 20, true));
}

test "a selection is painted, including the newline it crosses" {
    var f = try Fixture.init("abc\ndef", 20, 3);
    defer f.deinit();
    f.view.setSelection(.{ .anchor = 1, .head = 5 }); // "bc\nd"
    f.render(.{ .line_numbers = false });
    const sel = f.theme.selection;
    try testing.expect(!f.s.at(0, 0).bg.eql(sel));
    try testing.expect(f.s.at(1, 0).bg.eql(sel));
    try testing.expect(f.s.at(2, 0).bg.eql(sel));
    try testing.expect(f.s.at(3, 0).bg.eql(sel)); // the newline
    try testing.expect(f.s.at(0, 1).bg.eql(sel));
    // The head (offset 5, on 'e') is the cursor, drawn over the selection.
    try testing.expect(f.s.at(1, 1).attr.reverse);
    try testing.expect(!f.s.at(2, 1).bg.eql(sel));
}

test "every cursor is drawn" {
    var f = try Fixture.init("ab\ncd\nef", 20, 3);
    defer f.deinit();
    try f.view.setSelections(&.{ core.Selection.caret(1), core.Selection.caret(4), core.Selection.caret(8) }, 0);
    f.render(.{ .line_numbers = false });
    try testing.expect(f.s.at(1, 0).attr.reverse);
    try testing.expect(f.s.at(1, 1).attr.reverse);
    try testing.expect(f.s.at(2, 2).attr.reverse); // after the last character
    try testing.expect(!f.s.at(0, 0).attr.reverse);
}

test "tabs expand and wide characters take two cells" {
    var f = try Fixture.init("\tx\n\xe4\xb8\xady", 20, 2);
    defer f.deinit();
    f.view.setCaret(f.doc.len());
    f.render(.{ .line_numbers = false });
    try testing.expectEqualStrings("    x", f.row(0));
    try testing.expectEqual(@as(u21, 0x4e2d), f.s.at(0, 1).ch);
    try testing.expect(f.s.at(1, 1).cont);
    try testing.expectEqual(@as(u21, 'y'), f.s.at(2, 1).ch);
    try testing.expect(f.s.at(3, 1).attr.reverse);
}

test "horizontal scroll cuts the left edge cleanly" {
    var f = try Fixture.init("\tab\xe4\xb8\xadcd", 20, 1);
    defer f.deinit();
    f.view.scroll_col = 2; // inside the tab
    f.render(.{ .line_numbers = false, .focused = false });
    try testing.expectEqualStrings("  ab\xe4\xb8\xadcd", f.row(0));
    f.view.scroll_col = 7; // inside the wide character
    f.render(.{ .line_numbers = false, .focused = false });
    try testing.expectEqualStrings(" cd", f.row(0));
}

test "a long line stops at the right edge without splitting a wide character" {
    var f = try Fixture.init("abc\xe4\xb8\xad", 4, 1);
    defer f.deinit();
    f.render(.{ .line_numbers = false, .focused = false });
    try testing.expectEqualStrings("abc", f.row(0));
}

test "a click maps back to a document offset" {
    var f = try Fixture.init("one\n\ttwo\nthree", 20, 5);
    defer f.deinit();
    const r = f.s.area();
    try testing.expectEqual(@as(usize, 0), offsetAt(f.view, r, true, 2, 0));
    try testing.expectEqual(@as(usize, 2), offsetAt(f.view, r, true, 4, 0));
    try testing.expectEqual(@as(usize, 3), offsetAt(f.view, r, true, 15, 0)); // past the end
    try testing.expectEqual(@as(usize, 0), offsetAt(f.view, r, true, 0, 0)); // in the gutter
    try testing.expectEqual(@as(usize, 4), offsetAt(f.view, r, true, 3, 1)); // inside the tab
    try testing.expectEqual(@as(usize, 5), offsetAt(f.view, r, true, 6, 1)); // 't'
    try testing.expectEqual(@as(usize, 9), offsetAt(f.view, r, true, 2, 4)); // below the text: last line
}

test "syntax colours and the cursor-line tint" {
    var reg = syntax.Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.parse("name=C\nextensions=c\nsingleline_comment_start=//\nkeywords_1=int\n");
    var f = try Fixture.init("int x; // note\nint y;", 30, 2);
    defer f.deinit();
    f.theme.background = .{ .rgb = .{ .r = 0x10, .g = 0x10, .b = 0x10 } };
    const hl = try core.highlight.Highlighter.create(testing.allocator, f.doc);
    defer hl.destroy();
    hl.setLang(reg.find("a.c"));
    f.view.setCaret(f.doc.len());
    f.s.clear();
    draw(&f.s, f.s.area(), f.view, .{ .theme = &f.theme, .line_numbers = false, .highlighter = hl });
    try testing.expect(f.s.at(0, 0).fg.eql(f.theme.keyword1));
    try testing.expect(f.s.at(4, 0).fg.eql(f.theme.text));
    try testing.expect(f.s.at(8, 0).fg.eql(f.theme.comment));
    // Row 1 holds the cursor: tinted across the whole pane; row 0 is not.
    try testing.expect(f.s.at(20, 1).bg.eql(f.theme.lineHighlight()));
    try testing.expect(f.s.at(20, 0).bg.isDefault());
}
