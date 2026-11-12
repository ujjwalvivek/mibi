//! Syntax state for one document, remembered between frames.
//!
//! The lexer is line-oriented: to colour row N it needs the state the lexer
//! was in at the end of row N-1 (inside a block comment, inside a multi-line
//! string). This keeps that state for every row it has been asked about and
//! throws away only what an edit can have changed: everything below the first
//! edited row. Drawing a screenful after a keystroke then lexes the visible
//! rows, not the file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const syntax = @import("syntax.zig");
const document = @import("document.zig");
const Document = document.Document;

pub const Highlighter = struct {
    allocator: Allocator,
    doc: *Document,
    lang: ?*const syntax.Lang = null,
    /// `states.items[r]` is the lexer state at the start of row `r`. Rows
    /// past the end have not been computed yet.
    states: std.ArrayList(syntax.State) = .empty,
    scratch: std.ArrayList(u8) = .empty,

    /// Heap-allocated because the document keeps a pointer to it.
    pub fn create(allocator: Allocator, doc: *Document) !*Highlighter {
        const self = try allocator.create(Highlighter);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .doc = doc };
        try doc.observe(.{ .ptr = self, .onChange = onChange });
        return self;
    }

    pub fn destroy(self: *Highlighter) void {
        self.doc.unobserve(self);
        self.states.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn setLang(self: *Highlighter, lang: ?*const syntax.Lang) void {
        if (self.lang == lang) return;
        self.lang = lang;
        self.states.clearRetainingCapacity();
    }

    fn onChange(ptr: *anyopaque, tx: *const document.Transaction, direction: document.Direction) void {
        _ = direction;
        const self: *Highlighter = @ptrCast(@alignCast(ptr));
        // Text before the first change is the same before and after, in
        // either direction, so the state at the start of its row still holds.
        var first: usize = std.math.maxInt(usize);
        for (tx.changes.items) |c| first = @min(first, c.pos);
        if (first == std.math.maxInt(usize)) return;
        const row = self.doc.buffer.lineOf(@min(first, self.doc.buffer.len()));
        if (self.states.items.len > row + 1) self.states.shrinkRetainingCapacity(row + 1);
    }

    /// The lexer state at the start of `row`.
    pub fn stateAt(self: *Highlighter, row: usize) syntax.State {
        const lang = self.lang orelse return .{};
        if (row < self.states.items.len) return self.states.items[row];
        // Out of memory degrades to not caching: the answer is still right.
        self.states.ensureTotalCapacity(self.allocator, row + 1) catch {};
        var state: syntax.State = .{};
        var r: usize = 0;
        if (self.states.items.len > 0) {
            r = self.states.items.len - 1;
            state = self.states.items[r];
        } else if (self.states.capacity > 0) {
            self.states.appendAssumeCapacity(state);
        }
        while (r < row) : (r += 1) {
            const line = self.doc.buffer.line(r, &self.scratch) catch return .{};
            syntax.advance(lang, line, &state);
            if (self.states.items.len == r + 1 and self.states.capacity > r + 1) {
                self.states.appendAssumeCapacity(state);
            }
        }
        return state;
    }

    /// Colour `line`, which must be the text of `row`. Returns the number of
    /// spans written.
    pub fn spans(self: *Highlighter, row: usize, line: []const u8, out: []syntax.Span) usize {
        const lang = self.lang orelse return 0;
        var state = self.stateAt(row);
        return syntax.highlight(lang, line, &state, out);
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    reg: syntax.Registry,
    doc: *Document,
    hl: *Highlighter,

    fn init(text: []const u8) !Fixture {
        var reg = syntax.Registry.init(testing.allocator);
        errdefer reg.deinit();
        try reg.parse(
            \\name=C
            \\extensions=c
            \\singleline_comment_start=//
            \\multiline_comment_delims=/*, */
            \\keywords_1=int
            \\
        );
        const doc = try testing.allocator.create(Document);
        errdefer testing.allocator.destroy(doc);
        doc.* = try Document.init(testing.allocator, text);
        errdefer doc.deinit();
        const hl = try Highlighter.create(testing.allocator, doc);
        hl.setLang(reg.find("x.c"));
        return .{ .reg = reg, .doc = doc, .hl = hl };
    }

    fn deinit(self: *Fixture) void {
        self.hl.destroy();
        self.doc.deinit();
        testing.allocator.destroy(self.doc);
        self.reg.deinit();
    }

    /// The same answer computed from scratch, to compare the cache against.
    fn reference(self: *Fixture, row: usize) !syntax.State {
        var state: syntax.State = .{};
        var scratch = std.ArrayList(u8).empty;
        defer scratch.deinit(testing.allocator);
        var r: usize = 0;
        while (r < row) : (r += 1) {
            syntax.advance(self.hl.lang.?, try self.doc.buffer.line(r, &scratch), &state);
        }
        return state;
    }

    fn expectMatchesReference(self: *Fixture) !void {
        var row: usize = 0;
        while (row < self.doc.buffer.lineCount()) : (row += 1) {
            try testing.expectEqual(try self.reference(row), self.hl.stateAt(row));
        }
    }
};

test "state carries across lines and is cached" {
    var f = try Fixture.init("int a;\n/* open\nstill\nclose */\nint b;\n");
    defer f.deinit();
    try testing.expect(!f.hl.stateAt(1).in_ml_comment);
    try testing.expect(f.hl.stateAt(2).in_ml_comment);
    try testing.expect(f.hl.stateAt(3).in_ml_comment);
    try testing.expect(!f.hl.stateAt(4).in_ml_comment);
    try testing.expectEqual(@as(usize, 5), f.hl.states.items.len);
    try f.expectMatchesReference();
}

test "an edit invalidates the rows below it and nothing above" {
    var f = try Fixture.init("int a;\nint b;\nint c;\nint d;\n");
    defer f.deinit();
    _ = f.hl.stateAt(4);
    try testing.expectEqual(@as(usize, 5), f.hl.states.items.len);

    // Open a comment on row 1: rows 2.. are now inside it.
    const at = f.doc.buffer.lineStart(1);
    _ = try f.doc.edit(&.{.{ .start = at, .end = at, .text = "/* " }}, .{});
    try testing.expectEqual(@as(usize, 2), f.hl.states.items.len);
    try testing.expect(f.hl.stateAt(3).in_ml_comment);
    try f.expectMatchesReference();

    // Undo closes it again.
    _ = try f.doc.undo();
    try testing.expect(!f.hl.stateAt(3).in_ml_comment);
    try f.expectMatchesReference();
}

test "edits at several cursors invalidate from the first" {
    var f = try Fixture.init("a\nb\nc\nd\ne\n");
    defer f.deinit();
    _ = f.hl.stateAt(5);
    const r1 = f.doc.buffer.lineStart(1);
    const r3 = f.doc.buffer.lineStart(3);
    _ = try f.doc.edit(&.{
        .{ .start = r1, .end = r1, .text = "/*" },
        .{ .start = r3, .end = r3, .text = "*/" },
    }, .{});
    try testing.expectEqual(@as(usize, 2), f.hl.states.items.len);
    try testing.expect(f.hl.stateAt(2).in_ml_comment);
    try testing.expect(f.hl.stateAt(3).in_ml_comment);
    try testing.expect(!f.hl.stateAt(4).in_ml_comment);
    try f.expectMatchesReference();
}

test "no language means no state and no spans" {
    var f = try Fixture.init("/* x\ny\n");
    defer f.deinit();
    f.hl.setLang(null);
    var out: [8]syntax.Span = undefined;
    try testing.expectEqual(syntax.State{}, f.hl.stateAt(1));
    try testing.expectEqual(@as(usize, 0), f.hl.spans(1, "y", &out));
}

test "spans use the cached state" {
    var f = try Fixture.init("/* x\nint y\n*/ int z\n");
    defer f.deinit();
    var out: [8]syntax.Span = undefined;
    var n = f.hl.spans(1, "int y", &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(syntax.Class.ml_comment, out[0].class);
    n = f.hl.spans(2, "*/ int z", &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(syntax.Class.keyword1, out[1].class);
}
