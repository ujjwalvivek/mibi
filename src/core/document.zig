//! A document: the text of one file and its edit history.
//!
//! This is the only place text is changed. Callers describe a change as a
//! list of edits (one per cursor) in the coordinates of the document as it is
//! now; the document applies them as one transaction, all or nothing, and
//! records it for undo. Views (cursors, scrolling) live elsewhere and follow
//! along by mapping their positions through the transaction.

const std = @import("std");
const Allocator = std.mem.Allocator;
const buffer = @import("buffer.zig");
const history = @import("history.zig");
const Buffer = buffer.Buffer;
const Piece = buffer.Piece;
const Selection = @import("selection.zig").Selection;

pub const Kind = history.Kind;
pub const Bias = history.Bias;
pub const Transaction = history.Transaction;

/// Replace `[start, end)` with `text`. An insertion has `start == end`; a
/// deletion has empty `text`.
pub const Edit = struct {
    start: usize,
    end: usize,
    text: []const u8 = "",
};

pub const EditOptions = struct {
    kind: Kind = .other,
    /// When the edit happened, for grouping runs of typing. The core has no
    /// clock; the caller passes one in.
    time_ms: u64 = 0,
    /// Selections to restore on undo and on redo.
    before: []const Selection = &.{},
    after: []const Selection = &.{},
};

/// Whether a transaction was just applied (an edit or a redo) or taken back.
pub const Direction = enum { applied, reverted };

/// Something that holds positions in a document and has to move them when
/// the text changes: another pane's cursors, a search result list.
pub const Observer = struct {
    ptr: *anyopaque,
    onChange: *const fn (ptr: *anyopaque, tx: *const Transaction, direction: Direction) void,
};

pub const Document = struct {
    allocator: Allocator,
    buffer: Buffer,
    history: history.History,
    observers: std.ArrayList(Observer) = .empty,
    /// How lines end in the file. In memory they always end in `\n`.
    line_ending: @import("text.zig").LineEnding = .lf,
    /// Incremented on every change to the text, including undo and redo.
    /// Caches (syntax state, search matches, wrapped rows) compare against it.
    revision: u64 = 0,

    pub fn init(allocator: Allocator, data: []const u8) !Document {
        return .{
            .allocator = allocator,
            .buffer = try Buffer.init(allocator, data),
            .history = history.History.init(allocator),
        };
    }

    pub fn deinit(self: *Document) void {
        self.observers.deinit(self.allocator);
        self.history.deinit();
        self.buffer.deinit();
        self.* = undefined;
    }

    pub fn observe(self: *Document, observer: Observer) !void {
        try self.observers.append(self.allocator, observer);
    }

    pub fn unobserve(self: *Document, ptr: *anyopaque) void {
        for (self.observers.items, 0..) |o, i| {
            if (o.ptr == ptr) {
                _ = self.observers.orderedRemove(i);
                return;
            }
        }
    }

    fn notify(self: *Document, tx: *const Transaction, direction: Direction) void {
        self.revision += 1;
        for (self.observers.items) |o| o.onChange(o.ptr, tx, direction);
    }

    pub fn len(self: *const Document) usize {
        return self.buffer.len();
    }

    pub fn isDirty(self: *const Document) bool {
        return self.history.isDirty();
    }

    /// The text now matches the file on disk.
    pub fn markSaved(self: *Document) void {
        self.history.markSaved();
    }

    /// The text does not match any file on disk, whatever the history says.
    pub fn markUnsaved(self: *Document) void {
        self.history.markUnsaved();
    }

    /// End the current run of typing: the next edit is its own undo step.
    /// Views call this when the cursor moves for any reason but typing.
    pub fn breakUndoGroup(self: *Document) void {
        self.history.seal();
    }

    /// Apply `edits` as one undo step. They must be sorted by position and
    /// must not overlap; offsets are in the document as it is before the
    /// call. Returns false when the edits change nothing.
    pub fn edit(self: *Document, edits: []const Edit, options: EditOptions) !bool {
        var prev_end: usize = 0;
        for (edits) |e| {
            if (e.start > e.end or e.start < prev_end or e.end > self.buffer.len()) return error.InvalidEdit;
            prev_end = e.end;
        }

        var tx = Transaction{ .kind = options.kind, .time_ms = options.time_ms };
        defer tx.deinit(self.allocator);
        var removed = std.ArrayList(Piece).empty;
        defer removed.deinit(self.allocator);

        // Last edit first: an edit never moves the text before it, so every
        // offset is still correct when its turn comes.
        var i = edits.len;
        while (i > 0) {
            i -= 1;
            const e = edits[i];
            if (e.start == e.end and e.text.len == 0) continue;
            removed.clearRetainingCapacity();
            try self.buffer.spans(e.start, e.end, self.allocator, &removed);
            if (e.text.len == 0) {
                try tx.add(self.allocator, e.start, removed.items, &.{});
            } else {
                // Storing the text does not change the document; if a later
                // step fails the bytes are simply never referenced.
                const piece = try self.buffer.store(e.text);
                try tx.add(self.allocator, e.start, removed.items, &.{piece});
            }
        }
        if (tx.changes.items.len == 0) return false;
        try tx.before.appendSlice(self.allocator, options.before);
        try tx.after.appendSlice(self.allocator, options.after);

        // Everything that can fail happens before the text changes: room in
        // the piece list, room in the history. After that the edit is three
        // steps that cannot fail, so it is all or nothing by construction.
        try self.buffer.reserve(tx.changes.items.len, tx.pieces.items.len);
        try self.history.reserve(&tx);
        tx.apply(&self.buffer) catch unreachable;
        self.notify(&tx, .applied);
        self.history.push(&tx);
        return true;
    }

    /// Undo the last step. The returned transaction (valid until the next
    /// edit, undo or redo) carries the selections to restore in `before`;
    /// other views of the document remap with `Transaction.unmap`.
    pub fn undo(self: *Document) !?*const Transaction {
        const tx = try self.history.undo(&self.buffer) orelse return null;
        self.notify(tx, .reverted);
        return tx;
    }

    /// Redo the last undone step; restore `after`, remap others with `map`.
    pub fn redo(self: *Document) !?*const Transaction {
        const tx = try self.history.redo(&self.buffer) orelse return null;
        self.notify(tx, .applied);
        return tx;
    }
};

/// Where `pos` (an offset before `edits` are applied) lands afterwards. Used
/// to work out the selections that follow an edit before making it.
pub fn mapThroughEdits(edits: []const Edit, pos: usize, bias: Bias) usize {
    var shift_in: usize = 0; // bytes inserted before `pos`
    var shift_out: usize = 0; // bytes removed before `pos`
    for (edits) |e| {
        if (pos < e.start) break;
        if (pos > e.end or (pos == e.end and e.start != e.end)) {
            shift_in += e.text.len;
            shift_out += e.end - e.start;
            continue;
        }
        // On an insertion point, at the start of a replaced range, or inside
        // one.
        const at = e.start + shift_in - shift_out;
        if (e.start == e.end) return if (bias == .after) at + e.text.len else at;
        if (pos == e.start) return at;
        return if (bias == .after) at + e.text.len else at;
    }
    return pos + shift_in - shift_out;
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

fn expectText(d: *const Document, want: []const u8) !void {
    const got = try d.buffer.toOwned(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "edit, undo and redo restore text and selections" {
    var d = try Document.init(testing.allocator, "hello world");
    defer d.deinit();

    const before = [_]Selection{.{ .anchor = 6, .head = 11 }};
    const after = [_]Selection{Selection.caret(11)};
    try testing.expect(try d.edit(&.{.{ .start = 6, .end = 11, .text = "there" }}, .{ .before = &before, .after = &after }));
    try expectText(&d, "hello there");
    try testing.expect(d.isDirty());

    const undone = (try d.undo()).?;
    try expectText(&d, "hello world");
    try testing.expectEqualSlices(Selection, &before, undone.before.items);
    try testing.expect(!d.isDirty());
    try testing.expect(try d.undo() == null);

    const redone = (try d.redo()).?;
    try expectText(&d, "hello there");
    try testing.expectEqualSlices(Selection, &after, redone.after.items);
    try testing.expect(try d.redo() == null);
}

test "markUnsaved stays dirty through undo until saved" {
    var d = try Document.init(testing.allocator, "recovered");
    defer d.deinit();
    try testing.expect(!d.isDirty());
    d.markUnsaved();
    try testing.expect(d.isDirty());
    _ = try d.edit(&.{.{ .start = 0, .end = 0, .text = "x" }}, .{});
    _ = try d.undo();
    try testing.expect(d.isDirty());
    d.markSaved();
    try testing.expect(!d.isDirty());
}

test "several cursors edit as one step" {
    var d = try Document.init(testing.allocator, "a\nb\nc");
    defer d.deinit();
    const edits = [_]Edit{
        .{ .start = 0, .end = 0, .text = "- " },
        .{ .start = 2, .end = 2, .text = "- " },
        .{ .start = 4, .end = 4, .text = "- " },
    };
    try testing.expect(try d.edit(&edits, .{}));
    try expectText(&d, "- a\n- b\n- c");
    // Where each cursor ends up, worked out from the edits alone.
    try testing.expectEqual(@as(usize, 2), mapThroughEdits(&edits, 0, .after));
    try testing.expectEqual(@as(usize, 6), mapThroughEdits(&edits, 2, .after));
    try testing.expectEqual(@as(usize, 10), mapThroughEdits(&edits, 4, .after));
    try testing.expectEqual(@as(usize, 11), mapThroughEdits(&edits, 5, .before));

    _ = try d.undo();
    try expectText(&d, "a\nb\nc");
}

test "another view follows an edit, its undo and its redo" {
    var d = try Document.init(testing.allocator, "a\nb\nc");
    defer d.deinit();
    // A second pane has its cursor on the "c" while the first one edits.
    var other: usize = 4;
    _ = try d.edit(&.{ .{ .start = 0, .end = 1, .text = "AAA" }, .{ .start = 2, .end = 2, .text = "> " } }, .{});
    try expectText(&d, "AAA\n> b\nc");
    const tx = &d.history.undo_stack.items[0];
    other = tx.map(other, .after);
    try testing.expectEqual(@as(?u8, 'c'), d.buffer.byteAt(other));

    other = (try d.undo()).?.unmap(other, .after);
    try testing.expectEqual(@as(usize, 4), other);
    other = (try d.redo()).?.map(other, .after);
    try testing.expectEqual(@as(?u8, 'c'), d.buffer.byteAt(other));
}

test "invalid edits are refused and change nothing" {
    var d = try Document.init(testing.allocator, "abcdef");
    defer d.deinit();
    try testing.expectError(error.InvalidEdit, d.edit(&.{ .{ .start = 3, .end = 5 }, .{ .start = 4, .end = 6 } }, .{}));
    try testing.expectError(error.InvalidEdit, d.edit(&.{.{ .start = 4, .end = 2 }}, .{}));
    try testing.expectError(error.InvalidEdit, d.edit(&.{.{ .start = 2, .end = 99 }}, .{}));
    try testing.expect(!try d.edit(&.{.{ .start = 2, .end = 2 }}, .{}));
    try expectText(&d, "abcdef");
    try testing.expect(!d.isDirty());
    try testing.expectEqual(@as(u64, 0), d.revision);
}

fn typeAt(d: *Document, pos: usize, text: []const u8, time_ms: u64) !void {
    const after = [_]Selection{Selection.caret(pos + text.len)};
    _ = try d.edit(&.{.{ .start = pos, .end = pos, .text = text }}, .{ .kind = .typing, .time_ms = time_ms, .after = &after });
}

test "a run of typing is one undo step, a pause starts another" {
    var d = try Document.init(testing.allocator, "");
    defer d.deinit();
    try typeAt(&d, 0, "h", 0);
    try typeAt(&d, 1, "e", 200);
    try typeAt(&d, 2, "y", 400);
    try typeAt(&d, 3, "!", 5000); // after a pause
    try expectText(&d, "hey!");
    try testing.expectEqual(@as(usize, 1), d.buffer.pieces.items.len);

    _ = try d.undo();
    try expectText(&d, "hey");
    const tx = (try d.undo()).?;
    try expectText(&d, "");
    try testing.expectEqual(@as(usize, 3), tx.changes.items.len);
    // Redo brings the whole run back and puts the cursor at its end.
    const redone = (try d.redo()).?;
    try expectText(&d, "hey");
    try testing.expectEqual(@as(usize, 3), redone.after.items[0].head);
}

test "moving the cursor or changing kind breaks the group" {
    var d = try Document.init(testing.allocator, "");
    defer d.deinit();
    try typeAt(&d, 0, "a", 0);
    d.breakUndoGroup();
    try typeAt(&d, 1, "b", 10);
    _ = try d.edit(&.{.{ .start = 1, .end = 2 }}, .{ .kind = .erasing, .time_ms = 20 });
    try expectText(&d, "a");
    _ = try d.undo();
    try expectText(&d, "ab");
    _ = try d.undo();
    try expectText(&d, "a");
    _ = try d.undo();
    try expectText(&d, "");
}

test "dirty follows the saved state through undo and redo" {
    var d = try Document.init(testing.allocator, "x");
    defer d.deinit();
    try testing.expect(!d.isDirty());
    try typeAt(&d, 1, "a", 0);
    d.markSaved();
    try testing.expect(!d.isDirty());
    try typeAt(&d, 2, "b", 10); // must not merge into the saved step
    try testing.expect(d.isDirty());
    _ = try d.undo();
    try expectText(&d, "xa");
    try testing.expect(!d.isDirty()); // back to what is on disk
    _ = try d.undo();
    try testing.expect(d.isDirty());
    _ = try d.redo();
    try testing.expect(!d.isDirty());

    // A new edit after undo drops the redo branch.
    _ = try d.undo();
    try typeAt(&d, 1, "z", 9000);
    try testing.expect(try d.redo() == null);
    try testing.expect(d.isDirty());
}

test "an edit after undo cannot be confused with the saved state" {
    var d = try Document.init(testing.allocator, "");
    defer d.deinit();
    try typeAt(&d, 0, "a", 0);
    d.markSaved();
    _ = try d.undo();
    try typeAt(&d, 0, "b", 5000);
    try testing.expect(d.isDirty()); // "b" is not what was saved
}

// Random multi-cursor edits against a plain byte array, then undo all the
// way back and redo all the way forward, checking the text at every step.
test "fuzz edits, undo and redo against a reference" {
    const alphabet = "ab\n cd\n";
    var seed: u64 = 1;
    while (seed <= 16) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const rnd = prng.random();
        const a = testing.allocator;

        var d = try Document.init(a, "seed text\nline two\n");
        defer d.deinit();
        // states[i] is the text after i undo steps have been recorded.
        var states = std.ArrayList([]u8).empty;
        defer {
            for (states.items) |s| a.free(s);
            states.deinit(a);
        }
        try states.append(a, try d.buffer.toOwned(a));

        var step: usize = 0;
        while (step < 120) : (step += 1) {
            const ref = states.items[states.items.len - 1];
            var edits: [4]Edit = undefined;
            var texts: [4][6]u8 = undefined;
            const want = 1 + rnd.uintLessThan(usize, 4);
            var n: usize = 0;
            var at: usize = 0;
            while (n < want and at <= ref.len) : (n += 1) {
                const start = at + rnd.uintLessThan(usize, ref.len - at + 1);
                const end = start + rnd.uintLessThan(usize, @min(ref.len - start, 5) + 1);
                const text_len = rnd.uintLessThan(usize, 7);
                for (texts[n][0..text_len]) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
                edits[n] = .{ .start = start, .end = end, .text = texts[n][0..text_len] };
                at = end + 1; // keep them apart, so none overlap or touch
            }

            // The reference result, built front to back.
            var next = std.ArrayList(u8).empty;
            defer next.deinit(a);
            var pos: usize = 0;
            for (edits[0..n]) |e| {
                try next.appendSlice(a, ref[pos..e.start]);
                // Both ends of every edit map to where the reference puts
                // the new text.
                try testing.expectEqual(next.items.len, mapThroughEdits(edits[0..n], e.start, .before));
                try next.appendSlice(a, e.text);
                try testing.expectEqual(next.items.len, mapThroughEdits(edits[0..n], e.end, .after));
                pos = e.end;
            }
            try next.appendSlice(a, ref[pos..]);
            try testing.expectEqual(next.items.len, mapThroughEdits(edits[0..n], ref.len, .after));

            // `.other` so each one is its own undo step.
            if (try d.edit(edits[0..n], .{})) {
                try expectText(&d, next.items);
                try states.append(a, try a.dupe(u8, next.items));
            } else {
                try testing.expectEqualStrings(ref, next.items);
            }
        }

        var i = states.items.len - 1;
        while (i > 0) : (i -= 1) {
            try testing.expect(try d.undo() != null);
            try expectText(&d, states.items[i - 1]);
        }
        try testing.expect(try d.undo() == null);
        try testing.expect(!d.isDirty());
        // Undo heals the piece list completely: one piece, the original file.
        try testing.expectEqual(@as(usize, 1), d.buffer.pieces.items.len);
        while (i + 1 < states.items.len) : (i += 1) {
            try testing.expect(try d.redo() != null);
            try expectText(&d, states.items[i + 1]);
        }
        try testing.expect(try d.redo() == null);
    }
}

test "a failed allocation leaves the document as it was" {
    const Check = struct {
        fn run(allocator: Allocator) !void {
            var d = try Document.init(allocator, "one two three");
            defer d.deinit();
            const edits = [_]Edit{ .{ .start = 0, .end = 3, .text = "1" }, .{ .start = 8, .end = 13, .text = "3\n" } };
            const sel = [_]Selection{Selection.caret(0)};
            _ = d.edit(&edits, .{ .before = &sel, .after = &sel }) catch |e| {
                try expectIs(&d, "one two three");
                try testing.expect(!d.isDirty());
                return e;
            };
            try expectIs(&d, "1 two 3\n");
            _ = d.undo() catch |e| {
                try expectIs(&d, "1 two 3\n");
                return e;
            };
            try expectIs(&d, "one two three");
            _ = d.redo() catch |e| {
                try expectIs(&d, "one two three");
                return e;
            };
            try expectIs(&d, "1 two 3\n");
        }
        fn expectIs(d: *const Document, want: []const u8) !void {
            var at: usize = 0;
            var it = d.buffer.chunks(0, d.len());
            while (it.next()) |chunk| {
                try testing.expectEqualStrings(want[at..][0..chunk.len], chunk);
                at += chunk.len;
            }
            try testing.expectEqual(want.len, at);
            try testing.expectEqual(std.mem.count(u8, want, "\n") + 1, d.buffer.lineCount());
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{});
}
