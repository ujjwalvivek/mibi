//! Text measurement: how bytes become cells on a line, where a cursor may
//! stand, and what counts as a word.
//!
//! Everything here works on one line of UTF-8 without its newline. Columns
//! come in two kinds and the names say which: a *byte column* is an offset
//! into the line, a *cell column* is a position on screen (tabs expand, CJK
//! and emoji take two cells, combining marks none).

const std = @import("std");
const utf8 = @import("utf8.zig");
const width = @import("width.zig");

/// Cells a codepoint occupies when it starts at cell column `cell`.
pub fn cellsFor(cp: u21, cell: usize, tab_width: usize) usize {
    if (cp == '\t') return tab_width - (cell % tab_width);
    return width.cellWidth(cp);
}

/// Cell column of byte column `byte_col`.
pub fn cellOfByte(line: []const u8, byte_col: usize, tab_width: usize) usize {
    var cell: usize = 0;
    var i: usize = 0;
    const end = @min(byte_col, line.len);
    while (i < end) {
        const cp = utf8.nextCp(line, &i);
        cell += cellsFor(cp, cell, tab_width);
    }
    return cell;
}

/// Byte column of the cursor position nearest to cell column `cell`: the
/// character whose cells contain it, or the end of the line. Never lands
/// between a character and its combining marks.
pub fn byteOfCell(line: []const u8, cell: usize, tab_width: usize) usize {
    var at: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const start = i;
        const cp = utf8.nextCp(line, &i);
        const w = cellsFor(cp, at, tab_width);
        if (w > 0 and at + w > cell) return start;
        at += w;
    }
    return line.len;
}

/// One visual row of a line: bytes `start..end`, the first of which stands
/// at cell column `cell` of the unwrapped line.
pub const Segment = struct { start: usize, end: usize, cell: usize };

/// Splits a line into the visual rows it takes at `width` cells. A row ends
/// after the last blank that fits, so words stay whole; a word longer than a
/// row is cut where the row ends. A character is never split, and every line,
/// even an empty one, has at least one segment. `width` 0 means no wrapping:
/// one segment, the whole line.
pub const Wrap = struct {
    line: []const u8,
    tab_width: usize,
    width: usize,
    pos: usize = 0,
    cell: usize = 0,
    done: bool = false,

    pub fn next(self: *Wrap) ?Segment {
        if (self.done) return null;
        const start = self.pos;
        const start_cell = self.cell;
        if (self.width > 0) {
            var i = start;
            var cell = start_cell;
            var after_blank: ?Segment = null; // only `end` and `cell` are used
            while (i < self.line.len) {
                const at = i;
                const cp = utf8.nextCp(self.line, &i);
                const w = cellsFor(cp, cell, self.tab_width);
                // `at > start`: a character wider than the row still gets one.
                if (cell + w - start_cell > self.width and at > start) {
                    const cut = after_blank orelse Segment{ .start = start, .end = at, .cell = cell };
                    self.pos = cut.end;
                    self.cell = cut.cell;
                    return .{ .start = start, .end = cut.end, .cell = start_cell };
                }
                cell += w;
                if (cp == ' ' or cp == '\t') after_blank = .{ .start = start, .end = i, .cell = cell };
            }
        }
        self.done = true;
        return .{ .start = start, .end = self.line.len, .cell = start_cell };
    }
};

/// How many visual rows `line` takes at `cols` cells.
pub fn wrapCount(line: []const u8, tab_width: usize, cols: usize) usize {
    if (cols == 0) return 1;
    var it = Wrap{ .line = line, .tab_width = tab_width, .width = cols };
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

/// The visual row holding byte column `col`, and its index. A column on the
/// seam between two rows belongs to the second: that is where the cursor is
/// drawn.
pub fn wrapAt(line: []const u8, tab_width: usize, cols: usize, col: usize) struct { index: usize, seg: Segment } {
    var it = Wrap{ .line = line, .tab_width = tab_width, .width = cols };
    var index: usize = 0;
    var seg = it.next().?;
    while (col >= seg.end) {
        seg = it.next() orelse break;
        index += 1;
    }
    return .{ .index = index, .seg = seg };
}

/// Visual row number `index` of the line, or the last one if there are fewer.
pub fn wrapSegment(line: []const u8, tab_width: usize, cols: usize, index: usize) Segment {
    var it = Wrap{ .line = line, .tab_width = tab_width, .width = cols };
    var seg = it.next().?;
    var i: usize = 0;
    while (i < index) : (i += 1) seg = it.next() orelse break;
    return seg;
}

/// The byte column in `seg` nearest to `x` cells from its left edge. Unless
/// the segment is the line's last, the answer stays inside it: its end is
/// the next row's first column.
pub fn byteOfSegmentCell(line: []const u8, seg: Segment, x: usize, tab_width: usize) usize {
    var at = seg.cell;
    var i = seg.start;
    while (i < seg.end) {
        const start = i;
        const cp = utf8.nextCp(line, &i);
        const w = cellsFor(cp, at, tab_width);
        if (w > 0 and at + w > seg.cell + x) return start;
        at += w;
    }
    if (seg.end < line.len and seg.end > seg.start) return @max(prevBoundary(line, seg.end), seg.start);
    return seg.end;
}

/// Total cells the line occupies.
pub fn cellWidth(line: []const u8, tab_width: usize) usize {
    return cellOfByte(line, line.len, tab_width);
}

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// The cursor position after `col`: past one character and any zero-width
/// codepoints attached to it (combining marks, variation selectors), so the
/// cursor never stops inside what is drawn as one glyph.
pub fn nextBoundary(line: []const u8, col: usize) usize {
    if (col >= line.len) return line.len;
    var i = col;
    _ = utf8.nextCp(line, &i);
    while (i < line.len) {
        var j = i;
        const cp = utf8.nextCp(line, &j);
        if (cp == '\t' or width.cellWidth(cp) != 0) break;
        i = j;
    }
    return i;
}

/// The cursor position before `col`; the mirror of `nextBoundary`.
pub fn prevBoundary(line: []const u8, col: usize) usize {
    var i = @min(col, line.len);
    while (i > 0) {
        i -= 1;
        while (i > 0 and isContinuation(line[i])) i -= 1;
        const cp = utf8.cpAt(line, i);
        if (cp == '\t' or width.cellWidth(cp) != 0) break;
    }
    return i;
}

pub const Class = enum { space, word, punct };

/// Word characters are letters, digits, `_` and everything outside ASCII.
pub fn classOf(b: u8) Class {
    return switch (b) {
        ' ', '\t' => .space,
        'a'...'z', 'A'...'Z', '0'...'9', '_', 0x80...0xFF => .word,
        else => .punct,
    };
}

/// Where Ctrl+Right goes from `col`: past any blanks, then to the end of the
/// run of word or punctuation characters that follows.
pub fn nextWordEnd(line: []const u8, col: usize) usize {
    var i = @min(col, line.len);
    while (i < line.len and classOf(line[i]) == .space) i += 1;
    if (i == line.len) return i;
    const class = classOf(line[i]);
    while (i < line.len and classOf(line[i]) == class) i += 1;
    return i;
}

/// Where Ctrl+Left goes from `col`: back over any blanks, then to the start
/// of the run before them.
pub fn prevWordStart(line: []const u8, col: usize) usize {
    var i = @min(col, line.len);
    while (i > 0 and classOf(line[i - 1]) == .space) i -= 1;
    if (i == 0) return 0;
    const class = classOf(line[i - 1]);
    while (i > 0 and classOf(line[i - 1]) == class) i -= 1;
    return i;
}

/// The run of same-class characters around `col` (what a double click
/// selects). At the end of a line it is the run before.
pub fn wordAround(line: []const u8, col: usize) struct { start: usize, end: usize } {
    if (line.len == 0) return .{ .start = 0, .end = 0 };
    const at = if (col >= line.len) line.len - 1 else col;
    const class = classOf(line[at]);
    var start = at;
    while (start > 0 and classOf(line[start - 1]) == class) start -= 1;
    var end = at;
    while (end < line.len and classOf(line[end]) == class) end += 1;
    return .{ .start = start, .end = end };
}

/// Byte column of the first character that is not a blank: where the text of
/// an indented line begins.
pub fn indentEnd(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and classOf(line[i]) == .space) i += 1;
    return i;
}

// --- line endings --------------------------------------------------------

pub const LineEnding = enum {
    lf,
    crlf,

    pub fn bytes(self: LineEnding) []const u8 {
        return switch (self) {
            .lf => "\n",
            .crlf => "\r\n",
        };
    }
};

/// The line ending a file uses: CRLF when most of its line breaks are, LF
/// otherwise (and for a file with no line breaks).
pub fn detectLineEnding(data: []const u8) LineEnding {
    var crlf: usize = 0;
    var lf: usize = 0;
    for (data, 0..) |c, i| {
        if (c != '\n') continue;
        if (i > 0 and data[i - 1] == '\r') crlf += 1 else lf += 1;
    }
    return if (crlf > lf) .crlf else .lf;
}

/// Rewrite CRLF as LF in place and return the shortened slice. In memory a
/// document always uses `\n`; the original style is put back when saving. A
/// `\r` that is not part of a CRLF is text and is kept.
pub fn normalizeLineEndings(data: []u8) []u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n') continue;
        data[out] = data[i];
        out += 1;
    }
    return data[0..out];
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "cells: ascii, tabs, wide and combining" {
    try testing.expectEqual(@as(usize, 3), cellOfByte("abc", 3, 4));
    try testing.expectEqual(@as(usize, 4), cellOfByte("\tx", 1, 4));
    try testing.expectEqual(@as(usize, 4), cellOfByte("ab\tx", 3, 4)); // tab stops, not a fixed width
    try testing.expectEqual(@as(usize, 8), cellOfByte("abcd\tx", 5, 4));
    try testing.expectEqual(@as(usize, 2), cellOfByte("日本", 3, 4));
    try testing.expectEqual(@as(usize, 4), cellWidth("日本", 4));
    try testing.expectEqual(@as(usize, 1), cellWidth("e\u{301}", 4)); // e + combining acute
    try testing.expectEqual(@as(usize, 99), cellOfByte("x", 0, 4) + 99); // clamp sanity
    try testing.expectEqual(@as(usize, 1), cellOfByte("x", 50, 4)); // past the end
}

test "byteOfCell is the inverse on character starts" {
    const line = "a\t日e\u{301}z";
    var col: usize = 0;
    while (col < line.len) : (col = nextBoundary(line, col)) {
        try testing.expectEqual(col, byteOfCell(line, cellOfByte(line, col, 4), 4));
    }
    // The second cell of a wide character and the inside of a tab belong to
    // that character.
    try testing.expectEqual(@as(usize, 2), byteOfCell(line, 5, 4));
    try testing.expectEqual(@as(usize, 1), byteOfCell(line, 2, 4));
    try testing.expectEqual(line.len, byteOfCell(line, 500, 4));
}

test "boundaries keep combining marks with their base" {
    const line = "ae\u{301}\u{302}日x";
    try testing.expectEqual(@as(usize, 1), nextBoundary(line, 0));
    try testing.expectEqual(@as(usize, 6), nextBoundary(line, 1)); // e + two marks
    try testing.expectEqual(@as(usize, 9), nextBoundary(line, 6));
    try testing.expectEqual(line.len, nextBoundary(line, line.len));
    try testing.expectEqual(@as(usize, 9), prevBoundary(line, 10));
    try testing.expectEqual(@as(usize, 6), prevBoundary(line, 9));
    try testing.expectEqual(@as(usize, 1), prevBoundary(line, 6));
    try testing.expectEqual(@as(usize, 0), prevBoundary(line, 1));
    try testing.expectEqual(@as(usize, 0), prevBoundary(line, 0));
    // A line that starts with a stray mark still terminates.
    try testing.expectEqual(@as(usize, 0), prevBoundary("\u{301}a", 2));
}

test "word motion" {
    const line = "foo.bar  baz_1 ->x";
    try testing.expectEqual(@as(usize, 3), nextWordEnd(line, 0));
    try testing.expectEqual(@as(usize, 4), nextWordEnd(line, 3)); // the dot is its own run
    try testing.expectEqual(@as(usize, 7), nextWordEnd(line, 4));
    try testing.expectEqual(@as(usize, 14), nextWordEnd(line, 7)); // skips the blanks
    try testing.expectEqual(@as(usize, 17), nextWordEnd(line, 14));
    try testing.expectEqual(line.len, nextWordEnd(line, line.len));
    try testing.expectEqual(@as(usize, 9), prevWordStart(line, 14));
    try testing.expectEqual(@as(usize, 4), prevWordStart(line, 9));
    try testing.expectEqual(@as(usize, 3), prevWordStart(line, 4));
    try testing.expectEqual(@as(usize, 0), prevWordStart(line, 3));
    try testing.expectEqual(@as(usize, 0), prevWordStart("   ", 3));
}

test "wordAround and indentEnd" {
    const w = wordAround("say hello!", 6);
    try testing.expectEqual(@as(usize, 4), w.start);
    try testing.expectEqual(@as(usize, 9), w.end);
    const last = wordAround("say hello", 9); // at the end of the line
    try testing.expectEqual(@as(usize, 4), last.start);
    const none = wordAround("", 0);
    try testing.expectEqual(@as(usize, 0), none.end);
    try testing.expectEqual(@as(usize, 3), indentEnd(" \t x"));
    try testing.expectEqual(@as(usize, 2), indentEnd("  "));
}

test "line endings are detected and normalised" {
    try testing.expectEqual(LineEnding.lf, detectLineEnding("no breaks"));
    try testing.expectEqual(LineEnding.lf, detectLineEnding("a\nb\n"));
    try testing.expectEqual(LineEnding.crlf, detectLineEnding("a\r\nb\r\n"));
    try testing.expectEqual(LineEnding.crlf, detectLineEnding("a\r\nb\r\nc\n"));

    var data = "a\r\nb\rc\r\n\r\n".*;
    try testing.expectEqualStrings("a\nb\rc\n\n", normalizeLineEndings(&data));
}

fn expectWrap(line: []const u8, cols: usize, want: []const []const u8) !void {
    var it = Wrap{ .line = line, .tab_width = 4, .width = cols };
    var n: usize = 0;
    var at: usize = 0;
    while (it.next()) |seg| : (n += 1) {
        try std.testing.expect(n < want.len);
        try std.testing.expectEqualStrings(want[n], line[seg.start..seg.end]);
        try std.testing.expectEqual(at, seg.start); // no gaps, no overlap
        try std.testing.expectEqual(cellOfByte(line, seg.start, 4), seg.cell);
        at = seg.end;
    }
    try std.testing.expectEqual(want.len, n);
    try std.testing.expectEqual(line.len, at);
    try std.testing.expectEqual(want.len, wrapCount(line, 4, cols));
}

test "wrap breaks after blanks, cuts long words, and never splits a character" {
    try expectWrap("", 10, &.{""});
    try expectWrap("short", 10, &.{"short"});
    try expectWrap("exactly ten", 0, &.{"exactly ten"}); // off
    try expectWrap("one two three four", 8, &.{ "one two ", "three ", "four" });
    try expectWrap("abcdefghijkl", 5, &.{ "abcde", "fghij", "kl" });
    try expectWrap("ab cdefghijkl", 5, &.{ "ab ", "cdefg", "hijkl" });
    // Wide characters take two cells and are not cut in half.
    try expectWrap("\u{65e5}\u{672c}\u{8a9e}\u{3067}\u{3059}", 5, &.{ "\u{65e5}\u{672c}", "\u{8a9e}\u{3067}", "\u{3059}" });
    // A combining mark stays with its letter, whatever the width.
    try expectWrap("ae\u{301}io", 2, &.{ "ae\u{301}", "io" });
    // Narrower than a character: one per row, and it still ends.
    try expectWrap("\u{65e5}\u{672c}", 1, &.{ "\u{65e5}", "\u{672c}" });
    try expectWrap("a\tb", 4, &.{ "a\t", "b" });
}

test "wrapAt puts a seam position on the lower row; byteOfSegmentCell stays on its row" {
    const line = "one two three four";
    try std.testing.expectEqual(@as(usize, 0), wrapAt(line, 4, 8, 7).index);
    try std.testing.expectEqual(@as(usize, 1), wrapAt(line, 4, 8, 8).index); // the seam
    try std.testing.expectEqual(@as(usize, 2), wrapAt(line, 4, 8, line.len).index);
    try std.testing.expectEqual(@as(usize, 0), wrapAt(line, 4, 0, line.len).index);

    const first = wrapSegment(line, 4, 8, 0);
    try std.testing.expectEqual(@as(usize, 3), byteOfSegmentCell(line, first, 3, 4));
    try std.testing.expectEqual(@as(usize, 7), byteOfSegmentCell(line, first, 99, 4)); // not 8: that is row two
    const last = wrapSegment(line, 4, 8, 99);
    try std.testing.expectEqualStrings("four", line[last.start..last.end]);
    try std.testing.expectEqual(line.len, byteOfSegmentCell(line, last, 99, 4));
}
