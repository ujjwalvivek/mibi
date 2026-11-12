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
