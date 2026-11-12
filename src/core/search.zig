//! Find and replace over a document.
//!
//! There is one engine: a plain-text search is compiled to the same Pike VM
//! as a regular expression, with its special characters escaped. That keeps
//! case folding, whole-word matching and streaming over pieces in one place.
//! The VM skips straight to the first byte of a literal, so plain searches
//! do not pay for the generality.

const std = @import("std");
const Allocator = std.mem.Allocator;
const regex = @import("regex.zig");
const text = @import("text.zig");
const document = @import("document.zig");
const Buffer = @import("buffer.zig").Buffer;
const View = @import("view.zig").View;

pub const Match = regex.Match;
pub const Diagnostic = regex.Diagnostic;

pub const Case = enum {
    sensitive,
    insensitive,
    /// Ignore case unless the needle contains an upper-case letter.
    smart,
};

pub const Options = struct {
    /// Treat the needle as a regular expression.
    regex: bool = false,
    case: Case = .smart,
    /// Only match where the text on both sides is not part of a word.
    whole_word: bool = false,
};

pub const Search = struct {
    allocator: Allocator,
    /// Heap-allocated because the matcher points at it.
    program: *regex.Program,
    matcher: regex.Matcher,
    options: Options,

    /// Compile a search. `error.Syntax` (regex mode only) fills `diagnostic`.
    pub fn init(allocator: Allocator, needle: []const u8, options: Options, diagnostic: ?*Diagnostic) !Search {
        const ignore_case = switch (options.case) {
            .sensitive => false,
            .insensitive => true,
            .smart => for (needle) |c| {
                if (std.ascii.isUpper(c)) break false;
            } else true,
        };

        var escaped = std.ArrayList(u8).empty;
        defer escaped.deinit(allocator);
        var pattern = needle;
        if (!options.regex) {
            for (needle) |c| {
                if (std.mem.indexOfScalar(u8, "\\.^$|()[]{}*+?", c) != null) try escaped.append(allocator, '\\');
                try escaped.append(allocator, c);
            }
            pattern = escaped.items;
        }

        const program = try allocator.create(regex.Program);
        errdefer allocator.destroy(program);
        program.* = try regex.compile(allocator, pattern, .{ .ignore_case = ignore_case }, diagnostic);
        errdefer program.deinit();
        return .{
            .allocator = allocator,
            .program = program,
            .matcher = try regex.Matcher.init(allocator, program),
            .options = options,
        };
    }

    pub fn deinit(self: *Search) void {
        self.matcher.deinit();
        self.program.deinit();
        self.allocator.destroy(self.program);
        self.* = undefined;
    }

    /// The first match that starts at or after `from`, or null. Does not
    /// wrap around; the caller decides whether to try again from 0.
    pub fn next(self: *Search, buf: *const Buffer, from: usize) ?Match {
        var at = from;
        while (at <= buf.len()) {
            const m = self.scan(buf, at) orelse return null;
            if (!self.options.whole_word or isWholeWord(buf, m)) return m;
            at = stepPast(buf, m.start);
        }
        return null;
    }

    /// The last match that starts before `before`, or null.
    pub fn prev(self: *Search, buf: *const Buffer, before: usize) ?Match {
        var last: ?Match = null;
        var at: usize = 0;
        while (self.next(buf, at)) |m| {
            if (m.start >= before) break;
            last = m;
            at = after(buf, m);
        }
        return last;
    }

    /// Where to resume searching after `m` so that the same match is not
    /// found again: its end, or one character on when it is empty.
    pub fn after(buf: *const Buffer, m: Match) usize {
        return if (m.end > m.start) m.end else stepPast(buf, m.end);
    }

    fn scan(self: *Search, buf: *const Buffer, from: usize) ?Match {
        self.matcher.start(from, if (from > 0) buf.byteAt(from - 1) else null);
        var it = buf.chunks(from, buf.len());
        while (it.next()) |chunk| {
            if (self.matcher.feed(chunk)) break;
        }
        return self.matcher.finish();
    }

    /// Append what `m` should be replaced with. In regex mode `$0`..`$9` in
    /// `template` stand for the captured groups and `$$` for a dollar sign;
    /// otherwise the template is taken as it is.
    pub fn expand(self: *const Search, buf: *const Buffer, m: Match, template: []const u8, allocator: Allocator, out: *std.ArrayList(u8)) !void {
        if (!self.options.regex) return out.appendSlice(allocator, template);
        var i: usize = 0;
        while (i < template.len) : (i += 1) {
            const c = template[i];
            if (c == '$' and i + 1 < template.len) {
                const d = template[i + 1];
                if (d == '$') {
                    try out.append(allocator, '$');
                    i += 1;
                    continue;
                }
                if (d >= '0' and d <= '9') {
                    const slot = @as(usize, d - '0') * 2;
                    if (m.captures[slot]) |start| {
                        if (m.captures[slot + 1]) |end| {
                            var it = buf.chunks(start, end);
                            while (it.next()) |chunk| try out.appendSlice(allocator, chunk);
                        }
                    }
                    i += 1;
                    continue;
                }
            }
            try out.append(allocator, c);
        }
    }

    /// Replace every match in the view's document, as one undo step.
    /// Returns how many were replaced.
    pub fn replaceAll(self: *Search, view: *View, template: []const u8) !usize {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const buf = &view.doc.buffer;

        var edits = std.ArrayList(document.Edit).empty;
        var at: usize = 0;
        while (self.next(buf, at)) |m| {
            var replacement = std.ArrayList(u8).empty;
            try self.expand(buf, m, template, a, &replacement);
            try edits.append(a, .{ .start = m.start, .end = m.end, .text = replacement.items });
            at = after(buf, m);
        }
        try view.applyEdits(edits.items);
        return edits.items.len;
    }
};

fn isWordByte(b: ?u8) bool {
    return if (b) |c| text.classOf(c) == .word else false;
}

/// True when neither end of the match continues a word.
fn isWholeWord(buf: *const Buffer, m: Match) bool {
    if (m.end == m.start) return false;
    const starts_word = isWordByte(buf.byteAt(m.start));
    const ends_word = isWordByte(buf.byteAt(m.end - 1));
    if (starts_word and m.start > 0 and isWordByte(buf.byteAt(m.start - 1))) return false;
    if (ends_word and isWordByte(buf.byteAt(m.end))) return false;
    return true;
}

/// The offset of the character after the one at `pos`.
fn stepPast(buf: *const Buffer, pos: usize) usize {
    var at = pos + 1;
    while (buf.byteAt(at)) |b| : (at += 1) {
        if (b & 0xC0 != 0x80) break;
    }
    return at;
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;
const Document = document.Document;

/// A buffer whose text is spread over many pieces, so every search crosses
/// piece boundaries.
fn fragmented(content: []const u8) !Buffer {
    var b = try Buffer.init(testing.allocator, "");
    errdefer b.deinit();
    // Insert back to front, three bytes at a time: no two inserts are
    // adjacent in the add store, so nothing coalesces.
    var end = content.len;
    while (end > 0) {
        const start = end -| 3;
        try b.insert(0, content[start..end]);
        end = start;
    }
    return b;
}

fn expectAll(needle: []const u8, options: Options, content: []const u8, want: []const [2]usize) !void {
    var b = try fragmented(content);
    defer b.deinit();
    var s = try Search.init(testing.allocator, needle, options, null);
    defer s.deinit();
    var at: usize = 0;
    var n: usize = 0;
    while (s.next(&b, at)) |m| : (n += 1) {
        try testing.expect(n < want.len);
        try testing.expectEqual(want[n][0], m.start);
        try testing.expectEqual(want[n][1], m.end);
        at = Search.after(&b, m);
    }
    try testing.expectEqual(want.len, n);
}

test "plain search finds every occurrence across pieces" {
    try expectAll("ab", .{}, "ab cab abab", &.{ .{ 0, 2 }, .{ 4, 6 }, .{ 7, 9 }, .{ 9, 11 } });
    try expectAll("needle", .{}, "a needle in a needlestack", &.{ .{ 2, 8 }, .{ 14, 20 } });
    try expectAll("zzz", .{}, "nothing here", &.{});
    try expectAll("a", .{}, "", &.{});
}

test "plain search takes special characters literally" {
    try expectAll("a.b", .{}, "axb a.b", &.{.{ 4, 7 }});
    try expectAll("f(x)*", .{}, "f(x)* f(x)", &.{.{ 0, 5 }});
    try expectAll("[1]", .{}, "a[1] 1", &.{.{ 1, 4 }});
    try expectAll("\\d", .{}, "5 \\d", &.{.{ 2, 4 }});
}

test "smart case" {
    try expectAll("hello", .{}, "Hello hello HELLO", &.{ .{ 0, 5 }, .{ 6, 11 }, .{ 12, 17 } });
    try expectAll("Hello", .{}, "Hello hello HELLO", &.{.{ 0, 5 }});
    try expectAll("hello", .{ .case = .sensitive }, "Hello hello", &.{.{ 6, 11 }});
    try expectAll("HELLO", .{ .case = .insensitive }, "Hello", &.{.{ 0, 5 }});
}

test "whole word" {
    try expectAll("cat", .{ .whole_word = true }, "cat concat cat_ (cat) cat", &.{ .{ 0, 3 }, .{ 17, 20 }, .{ 22, 25 } });
    // A needle that is not a word itself is only held to its word-like ends.
    try expectAll("->x", .{ .whole_word = true }, "a->x b->xy", &.{.{ 1, 4 }});
    try expectAll("é", .{ .whole_word = true }, "é né é", &.{ .{ 0, 2 }, .{ 7, 9 } });
}

test "regex search and empty matches" {
    try expectAll("\\d+", .{ .regex = true }, "a1 b22 c333", &.{ .{ 1, 2 }, .{ 4, 6 }, .{ 8, 11 } });
    try expectAll("^", .{ .regex = true }, "a\nb\n", &.{ .{ 0, 0 }, .{ 2, 2 }, .{ 4, 4 } });
    try expectAll("x*", .{ .regex = true }, "axxé", &.{ .{ 0, 0 }, .{ 1, 3 }, .{ 3, 3 }, .{ 5, 5 } });
    try expectAll("$", .{ .regex = true }, "ab", &.{.{ 2, 2 }});
}

test "a bad regex reports its error" {
    var diag = Diagnostic{};
    try testing.expectError(error.Syntax, Search.init(testing.allocator, "a(b", .{ .regex = true }, &diag));
    try testing.expectEqualStrings("missing )", diag.message);
    // The same text is a fine plain search.
    var s = try Search.init(testing.allocator, "a(b", .{}, null);
    s.deinit();
}

test "previous match" {
    var b = try fragmented("one two one two one");
    defer b.deinit();
    var s = try Search.init(testing.allocator, "one", .{}, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 8), s.prev(&b, 16).?.start);
    try testing.expectEqual(@as(usize, 0), s.prev(&b, 8).?.start);
    try testing.expect(s.prev(&b, 0) == null);
    try testing.expectEqual(@as(usize, 16), s.prev(&b, b.len()).?.start);
}

fn expectReplaced(needle: []const u8, options: Options, template: []const u8, content: []const u8, want: []const u8, count: usize) !void {
    const a = testing.allocator;
    var doc = try Document.init(a, content);
    defer doc.deinit();
    const view = try View.create(a, &doc);
    defer view.destroy();
    var s = try Search.init(a, needle, options, null);
    defer s.deinit();
    try testing.expectEqual(count, try s.replaceAll(view, template));
    const got = try doc.buffer.toOwned(a);
    defer a.free(got);
    try testing.expectEqualStrings(want, got);

    // One undo step, whatever the number of replacements.
    if (count > 0) {
        try testing.expect(try view.undo());
        const back = try doc.buffer.toOwned(a);
        defer a.free(back);
        try testing.expectEqualStrings(content, back);
        try testing.expect(!try view.undo());
    }
}

test "replace all" {
    try expectReplaced("cat", .{}, "dog", "cat concat Cat", "dog condog dog", 3);
    try expectReplaced("a", .{}, "aa", "banana", "baanaanaa", 3);
    try expectReplaced("xyz", .{}, "", "none", "none", 0);
    try expectReplaced("$1", .{}, "$2", "cost $1", "cost $2", 1); // plain mode: no expansion
}

test "replace all with captures" {
    try expectReplaced("(\\w+)@(\\w+)", .{ .regex = true }, "$2 at $1", "bob@home, amy@work", "home at bob, work at amy", 2);
    try expectReplaced("(a)|(b)", .{ .regex = true }, "[$1$2$9]", "ab", "[a][b]", 2);
    try expectReplaced("\\d+", .{ .regex = true }, "$$$0", "5 and 10", "$5 and $10", 2);
    try expectReplaced("^", .{ .regex = true }, "> ", "a\nb", "> a\n> b", 2);
    try expectReplaced("\\s+$", .{ .regex = true }, "", "a  \nb\t\nc", "a\nb\nc", 2);
}

test "replace all keeps the cursor on its text" {
    const a = testing.allocator;
    var doc = try Document.init(a, "aaa X bbb");
    defer doc.deinit();
    const view = try View.create(a, &doc);
    defer view.destroy();
    view.setCaret(4); // on the X
    var s = try Search.init(a, "a|b", .{ .regex = true }, null);
    defer s.deinit();
    _ = try s.replaceAll(view, "--");
    try testing.expectEqual(@as(?u8, 'X'), doc.buffer.byteAt(view.primarySelection().head));
}
