//! Undo history: a document's changes as transactions that can be replayed
//! in either direction.
//!
//! A change records a position, the pieces it removed and the pieces it put
//! in. Both sides are spans of the buffer's stores, which never move, so a
//! change costs a few words however much text it covers, and undoing it is
//! the same splice with the two sides swapped.
//!
//! A transaction is the changes of one user action (one per cursor) plus the
//! selections before and after, so undo puts the cursor back where the edit
//! was made. Runs of typing merge into one transaction.

const std = @import("std");
const Allocator = std.mem.Allocator;
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;
const Piece = buffer.Piece;
const Selection = @import("selection.zig").Selection;

/// What kind of action a transaction was, for grouping.
pub const Kind = enum {
    /// Inserting characters one after another.
    typing,
    /// Backspace or delete, one character at a time.
    erasing,
    /// Anything else: paste, cut, replace, format. Never merged.
    other,
};

/// Which way a position on the edge of a change leans.
pub const Bias = enum { before, after };

/// A range of `Transaction.pieces`.
const Run = struct { start: u32, len: u32 };

pub const Change = struct {
    /// Where the change applies, in the document as it is when this change's
    /// turn comes (changes of one transaction apply in order).
    pos: usize,
    removed_len: usize,
    inserted_len: usize,
    removed: Run,
    inserted: Run,

    /// Where `pos` ends up after this change has been applied.
    pub fn map(self: Change, pos: usize, bias: Bias) usize {
        return mapThrough(self.pos, self.removed_len, self.inserted_len, pos, bias);
    }

    /// Where `pos` ends up after this change has been undone.
    pub fn unmap(self: Change, pos: usize, bias: Bias) usize {
        return mapThrough(self.pos, self.inserted_len, self.removed_len, pos, bias);
    }
};

fn mapThrough(at: usize, removed: usize, inserted: usize, pos: usize, bias: Bias) usize {
    const end = at + removed;
    if (pos < at) return pos;
    if (pos > end) return pos - removed + inserted;
    if (removed == 0) {
        // A pure insertion exactly at `pos`: the bias decides the side.
        return if (bias == .after) at + inserted else at;
    }
    // The edges of a replaced range stay on the outside of the new text.
    if (pos == at) return at;
    if (pos == end) return at + inserted;
    // Inside text that no longer exists.
    return if (bias == .after) at + inserted else at;
}

pub const Transaction = struct {
    /// Identifies the document state after this transaction; see `History`.
    id: u64 = 0,
    kind: Kind = .other,
    /// Millisecond timestamp of the last change in it, from the caller.
    time_ms: u64 = 0,
    changes: std.ArrayList(Change) = .empty,
    /// Backing store for every change's `removed` and `inserted` runs.
    pieces: std.ArrayList(Piece) = .empty,
    before: std.ArrayList(Selection) = .empty,
    after: std.ArrayList(Selection) = .empty,

    pub fn deinit(self: *Transaction, allocator: Allocator) void {
        self.changes.deinit(allocator);
        self.pieces.deinit(allocator);
        self.before.deinit(allocator);
        self.after.deinit(allocator);
        self.* = undefined;
    }

    fn run(self: *const Transaction, r: Run) []const Piece {
        return self.pieces.items[r.start..][0..r.len];
    }

    /// Record a change. `removed` and `inserted` are copied.
    pub fn add(self: *Transaction, allocator: Allocator, pos: usize, removed: []const Piece, inserted: []const Piece) !void {
        try self.changes.ensureUnusedCapacity(allocator, 1);
        try self.pieces.ensureUnusedCapacity(allocator, removed.len + inserted.len);
        var change = Change{ .pos = pos, .removed_len = 0, .inserted_len = 0, .removed = undefined, .inserted = undefined };
        change.removed = .{ .start = @intCast(self.pieces.items.len), .len = @intCast(removed.len) };
        self.pieces.appendSliceAssumeCapacity(removed);
        change.inserted = .{ .start = @intCast(self.pieces.items.len), .len = @intCast(inserted.len) };
        self.pieces.appendSliceAssumeCapacity(inserted);
        for (removed) |p| change.removed_len += p.len;
        for (inserted) |p| change.inserted_len += p.len;
        self.changes.appendAssumeCapacity(change);
    }

    /// Splices and inserted pieces needed to apply or revert it.
    fn reserveFor(self: *const Transaction, b: *Buffer) !void {
        try b.reserve(self.changes.items.len, self.pieces.items.len);
    }

    /// Apply every change, in order. All or nothing.
    pub fn apply(self: *const Transaction, b: *Buffer) !void {
        try self.reserveFor(b);
        for (self.changes.items) |c| b.splice(c.pos, c.removed_len, self.run(c.inserted));
    }

    /// Undo every change, last first. All or nothing.
    pub fn revert(self: *const Transaction, b: *Buffer) !void {
        try self.reserveFor(b);
        var i = self.changes.items.len;
        while (i > 0) {
            i -= 1;
            const c = self.changes.items[i];
            b.splice(c.pos, c.inserted_len, self.run(c.removed));
        }
    }

    /// Where a position in the document before the transaction is after it.
    pub fn map(self: *const Transaction, pos: usize, bias: Bias) usize {
        var p = pos;
        for (self.changes.items) |c| p = c.map(p, bias);
        return p;
    }

    /// The reverse of `map`: from after the transaction to before it.
    pub fn unmap(self: *const Transaction, pos: usize, bias: Bias) usize {
        var p = pos;
        var i = self.changes.items.len;
        while (i > 0) {
            i -= 1;
            p = self.changes.items[i].unmap(p, bias);
        }
        return p;
    }
};

pub const History = struct {
    /// Typing separated by a longer pause than this starts a new undo step.
    pub const group_gap_ms = 1000;
    /// Undo steps kept; older ones are dropped.
    pub const max_steps = 1000;

    allocator: Allocator,
    undo_stack: std.ArrayList(Transaction) = .empty,
    redo_stack: std.ArrayList(Transaction) = .empty,
    next_id: u64 = 1,
    /// Id of the state that is on disk. 0 is the state the document was
    /// opened in.
    saved_id: u64 = 0,
    /// Id of the state below the oldest undo step. It starts as 0 and moves
    /// up when old steps are dropped.
    base_id: u64 = 0,
    /// Set when the next transaction must start a new undo step even if it
    /// looks like a continuation (the cursor moved, the file was saved).
    sealed: bool = true,

    pub fn init(allocator: Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *History) void {
        clear(self.allocator, &self.undo_stack);
        clear(self.allocator, &self.redo_stack);
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
        self.* = undefined;
    }

    fn clear(allocator: Allocator, stack: *std.ArrayList(Transaction)) void {
        for (stack.items) |*t| t.deinit(allocator);
        stack.clearRetainingCapacity();
    }

    /// Id of the current document state: the last transaction applied, or 0.
    pub fn currentId(self: *const History) u64 {
        const items = self.undo_stack.items;
        return if (items.len == 0) self.base_id else items[items.len - 1].id;
    }

    /// True when the document differs from what was last saved.
    pub fn isDirty(self: *const History) bool {
        return self.currentId() != self.saved_id;
    }

    pub fn markSaved(self: *History) void {
        self.saved_id = self.currentId();
        self.sealed = true;
    }

    /// The next transaction starts its own undo step.
    pub fn seal(self: *History) void {
        self.sealed = true;
    }

    /// Make room to record `tx`, so that `push` cannot fail. Called before
    /// the transaction is applied: recording an edit must never be the step
    /// that fails after the text has already changed.
    pub fn reserve(self: *History, tx: *const Transaction) !void {
        if (self.canMerge(tx)) {
            const top = &self.undo_stack.items[self.undo_stack.items.len - 1];
            try top.changes.ensureUnusedCapacity(self.allocator, tx.changes.items.len);
            try top.pieces.ensureUnusedCapacity(self.allocator, tx.pieces.items.len);
            try top.after.ensureTotalCapacity(self.allocator, tx.after.items.len);
        } else {
            try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        }
    }

    /// Take ownership of a transaction that has just been applied. It either
    /// becomes a new undo step or, for a run of typing, joins the last one.
    /// Needs `reserve(tx)` first; never fails. `tx` is left empty.
    pub fn push(self: *History, tx: *Transaction) void {
        if (self.canMerge(tx)) {
            const top = &self.undo_stack.items[self.undo_stack.items.len - 1];
            const offset: u32 = @intCast(top.pieces.items.len);
            top.pieces.appendSliceAssumeCapacity(tx.pieces.items);
            for (tx.changes.items) |c| {
                var moved = c;
                moved.removed.start += offset;
                moved.inserted.start += offset;
                top.changes.appendAssumeCapacity(moved);
            }
            top.after.clearRetainingCapacity();
            top.after.appendSliceAssumeCapacity(tx.after.items);
            top.time_ms = tx.time_ms;
            // Still the same undo step, so the same state id. A step never
            // merges across a save (`markSaved` seals it), so `saved_id`
            // cannot be pointing at it.
            tx.deinit(self.allocator);
        } else {
            tx.id = self.next_id;
            self.next_id += 1;
            self.undo_stack.appendAssumeCapacity(tx.*);
            if (self.undo_stack.items.len > max_steps) {
                var oldest = self.undo_stack.orderedRemove(0);
                self.base_id = oldest.id;
                oldest.deinit(self.allocator);
            }
        }
        tx.* = .{};
        clear(self.allocator, &self.redo_stack);
        self.sealed = false;
    }

    fn canMerge(self: *const History, tx: *const Transaction) bool {
        if (self.sealed or tx.kind == .other) return false;
        const items = self.undo_stack.items;
        if (items.len == 0) return false;
        const top = &items[items.len - 1];
        if (top.kind != tx.kind) return false;
        // Same number of cursors, or the "after" selections of the group
        // would not line up with its changes.
        if (top.after.items.len != tx.after.items.len) return false;
        return tx.time_ms -| top.time_ms <= group_gap_ms;
    }

    /// Revert the last step. Returns it (valid until the next call into the
    /// history) so the caller can restore `before` and remap other views, or
    /// null when there is nothing to undo.
    pub fn undo(self: *History, b: *Buffer) !?*const Transaction {
        if (self.undo_stack.items.len == 0) return null;
        try self.redo_stack.ensureUnusedCapacity(self.allocator, 1);
        const top = &self.undo_stack.items[self.undo_stack.items.len - 1];
        try top.revert(b);
        self.redo_stack.appendAssumeCapacity(self.undo_stack.pop().?);
        self.sealed = true;
        return &self.redo_stack.items[self.redo_stack.items.len - 1];
    }

    /// Re-apply the last undone step; see `undo`.
    pub fn redo(self: *History, b: *Buffer) !?*const Transaction {
        if (self.redo_stack.items.len == 0) return null;
        try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        const top = &self.redo_stack.items[self.redo_stack.items.len - 1];
        try top.apply(b);
        self.undo_stack.appendAssumeCapacity(self.redo_stack.pop().?);
        self.sealed = true;
        return &self.undo_stack.items[self.undo_stack.items.len - 1];
    }
};

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "positions map through a change" {
    // Replace [4, 7) with five bytes.
    const c = Change{ .pos = 4, .removed_len = 3, .inserted_len = 5, .removed = undefined, .inserted = undefined };
    try testing.expectEqual(@as(usize, 2), c.map(2, .after));
    try testing.expectEqual(@as(usize, 4), c.map(4, .before));
    try testing.expectEqual(@as(usize, 4), c.map(5, .before)); // inside the removed text
    try testing.expectEqual(@as(usize, 9), c.map(5, .after));
    try testing.expectEqual(@as(usize, 9), c.map(7, .after));
    try testing.expectEqual(@as(usize, 12), c.map(10, .before));
    try testing.expectEqual(@as(usize, 10), c.unmap(12, .before));

    // A pure insertion: a position exactly there leans either way.
    const ins = Change{ .pos = 4, .removed_len = 0, .inserted_len = 2, .removed = undefined, .inserted = undefined };
    try testing.expectEqual(@as(usize, 4), ins.map(4, .before));
    try testing.expectEqual(@as(usize, 6), ins.map(4, .after));
    try testing.expectEqual(@as(usize, 7), ins.map(5, .before));
}
