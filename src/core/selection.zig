//! Selections: where the user is in a document.
//!
//! A selection is an anchor and a head (the end that moves, where the cursor
//! is drawn). A plain cursor is a selection whose two ends are equal. A view
//! holds a list of them; with one entry it is an ordinary editor, with more
//! it is multi-cursor, and commands do not need to know which.

const std = @import("std");

pub const Selection = struct {
    anchor: usize,
    head: usize,
    /// Display column to return to when moving vertically through shorter
    /// lines. Cleared by any horizontal movement or edit.
    goal: ?usize = null,

    pub fn caret(pos: usize) Selection {
        return .{ .anchor = pos, .head = pos };
    }

    pub fn start(self: Selection) usize {
        return @min(self.anchor, self.head);
    }

    pub fn end(self: Selection) usize {
        return @max(self.anchor, self.head);
    }

    pub fn isEmpty(self: Selection) bool {
        return self.anchor == self.head;
    }

    fn forward(self: Selection) bool {
        return self.head >= self.anchor;
    }
};

fn lessThan(_: void, a: Selection, b: Selection) bool {
    if (a.start() != b.start()) return a.start() < b.start();
    return a.end() < b.end();
}

/// Sort `items` by position and merge the ones that overlap, so that no two
/// cursors ever edit the same text. Two carets at one position merge; ranges
/// that only touch stay separate. Returns the merged prefix of `items`.
///
/// `primary` is the index of the selection the view scrolls to; it is updated
/// to wherever that selection (or the one that absorbed it) ended up.
pub fn normalize(items: []Selection, primary: *usize) []Selection {
    if (items.len == 0) return items;
    const main = items[@min(primary.*, items.len - 1)];
    std.mem.sort(Selection, items, {}, lessThan);

    var n: usize = 1;
    for (items[1..]) |next| {
        const last = &items[n - 1];
        const overlap = next.start() < last.end() or
            (next.start() == last.start()) or
            (next.isEmpty() and next.start() == last.end() and last.isEmpty());
        if (!overlap) {
            items[n] = next;
            n += 1;
            continue;
        }
        const lo = last.start();
        const hi = @max(last.end(), next.end());
        // Keep the direction of the first one, so extending a selection over
        // a neighbour does not flip which end moves.
        last.* = if (last.forward())
            .{ .anchor = lo, .head = hi, .goal = last.goal }
        else
            .{ .anchor = hi, .head = lo, .goal = last.goal };
    }

    primary.* = 0;
    for (items[0..n], 0..) |s, i| {
        if (s.start() <= main.head and main.head <= s.end()) {
            primary.* = i;
            break;
        }
    }
    return items[0..n];
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "caret and range accessors" {
    const c = Selection.caret(4);
    try testing.expect(c.isEmpty());
    const back = Selection{ .anchor = 9, .head = 3 };
    try testing.expectEqual(@as(usize, 3), back.start());
    try testing.expectEqual(@as(usize, 9), back.end());
    try testing.expect(!back.isEmpty());
}

test "normalize sorts and keeps the primary" {
    var items = [_]Selection{ Selection.caret(20), Selection.caret(5), Selection.caret(11) };
    var primary: usize = 0; // the caret at 20
    const out = normalize(&items, &primary);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(@as(usize, 5), out[0].head);
    try testing.expectEqual(@as(usize, 11), out[1].head);
    try testing.expectEqual(@as(usize, 2), primary);
}

test "normalize merges overlaps and duplicate carets" {
    var items = [_]Selection{
        .{ .anchor = 0, .head = 5 },
        .{ .anchor = 3, .head = 8 }, // overlaps the first
        Selection.caret(12),
        Selection.caret(12), // duplicate
        .{ .anchor = 20, .head = 15 }, // backward
        .{ .anchor = 18, .head = 25 }, // overlaps it
    };
    var primary: usize = 3;
    const out = normalize(&items, &primary);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(Selection{ .anchor = 0, .head = 8 }, out[0]);
    try testing.expectEqual(Selection.caret(12), out[1]);
    try testing.expectEqual(Selection{ .anchor = 25, .head = 15 }, out[2]); // still backward
    try testing.expectEqual(@as(usize, 1), primary);
}

test "ranges that only touch stay separate" {
    var items = [_]Selection{ .{ .anchor = 0, .head = 4 }, .{ .anchor = 4, .head = 9 } };
    var primary: usize = 1;
    const out = normalize(&items, &primary);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(usize, 1), primary);
}

test "a caret inside a range is absorbed" {
    var items = [_]Selection{ .{ .anchor = 2, .head = 9 }, Selection.caret(5) };
    var primary: usize = 1;
    const out = normalize(&items, &primary);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(usize, 0), primary);
}
