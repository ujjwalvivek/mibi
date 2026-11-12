//! Pane layout: a binary tree of splits over a fixed pool of nodes.
//!
//! The tree only knows geometry. A leaf is a pane, identified by its node
//! index, and that index stays the same for as long as the pane exists:
//! splitting adds nodes around it and closing a neighbour relinks the parent,
//! neither moves the leaf. The app keeps what a pane shows (document, cursor,
//! scroll) in its own table indexed by that id.
//!
//! The pool is fixed, so splitting and closing never allocate and cannot fail
//! halfway through.

const std = @import("std");
const screen = @import("screen.zig");

pub const Rect = screen.Rect;

/// How a split divides its rectangle.
pub const Dir = enum {
    /// Side by side, separated by a vertical line.
    columns,
    /// Stacked, separated by a horizontal line.
    rows,
};

pub const max_panes = 8;
pub const max_nodes = 2 * max_panes - 1;
const none: u8 = 0xff;

const Node = struct {
    leaf: bool = true,
    parent: u8 = none,
    dir: Dir = .columns,
    /// Percent of the rectangle given to `a`.
    ratio: u8 = 50,
    a: u8 = none,
    b: u8 = none,
};

pub const PaneRect = struct {
    pane: u8,
    rect: Rect,
};

pub const Separator = struct {
    x: usize,
    y: usize,
    dir: Dir,
    /// Cells the line covers: the height for `columns`, the width for `rows`.
    len: usize,
};

pub const Tree = struct {
    nodes: [max_nodes]Node = [_]Node{.{}} ** max_nodes,
    used: [max_nodes]bool = [_]bool{false} ** max_nodes,
    root: u8 = none,
    focus: u8 = none,
    /// Panes in layout order (left to right, top to bottom).
    leaves: [max_panes]u8 = undefined,
    leaf_count: usize = 0,
    /// Filled by `layout`, read by drawing and by the mouse.
    rects: [max_panes]PaneRect = undefined,
    rect_count: usize = 0,
    seps: [max_panes]Separator = undefined,
    sep_count: usize = 0,

    /// A tree with no panes. `open` adds the first.
    pub const empty: Tree = .{};

    fn take(self: *Tree) ?u8 {
        for (&self.used, 0..) |*u, i| {
            if (!u.*) {
                u.* = true;
                self.nodes[i] = .{};
                return @intCast(i);
            }
        }
        return null;
    }

    pub fn isEmpty(self: *const Tree) bool {
        return self.root == none;
    }

    pub fn count(self: *const Tree) usize {
        return self.leaf_count;
    }

    /// The focused pane, or null when there are none.
    pub fn focused(self: *const Tree) ?u8 {
        return if (self.focus == none) null else self.focus;
    }

    pub fn setFocus(self: *Tree, pane: u8) void {
        if (pane < max_nodes and self.used[pane] and self.nodes[pane].leaf) self.focus = pane;
    }

    /// Add the first pane to an empty tree and focus it.
    pub fn open(self: *Tree) ?u8 {
        if (!self.isEmpty()) return null;
        const pane = self.take() orelse return null;
        self.root = pane;
        self.focus = pane;
        self.collect();
        return pane;
    }

    /// Split `pane` in two and return the new pane, which takes the
    /// left/top half when `first` is set and the right/bottom half
    /// otherwise. The focus moves to it. Null when the pane limit is reached.
    pub fn split(self: *Tree, pane: u8, dir: Dir, first: bool) ?u8 {
        if (self.leaf_count >= max_panes or !self.used[pane] or !self.nodes[pane].leaf) return null;
        const join = self.take() orelse return null;
        const new = self.take() orelse {
            self.used[join] = false;
            return null;
        };
        const parent = self.nodes[pane].parent;
        self.nodes[join] = .{
            .leaf = false,
            .parent = parent,
            .dir = dir,
            .a = if (first) new else pane,
            .b = if (first) pane else new,
        };
        self.replaceChild(parent, pane, join);
        self.nodes[pane].parent = join;
        self.nodes[new].parent = join;
        self.focus = new;
        self.collect();
        return new;
    }

    fn replaceChild(self: *Tree, parent: u8, old: u8, new: u8) void {
        if (parent == none) {
            self.root = new;
        } else if (self.nodes[parent].a == old) {
            self.nodes[parent].a = new;
        } else {
            self.nodes[parent].b = new;
        }
    }

    fn firstLeaf(self: *const Tree, start: u8) u8 {
        var idx = start;
        while (!self.nodes[idx].leaf) idx = self.nodes[idx].a;
        return idx;
    }

    /// Close `pane`. Its sibling takes the space; closing the last pane
    /// empties the tree. If it had the focus, the focus moves to the pane
    /// that took its place.
    pub fn remove(self: *Tree, pane: u8) void {
        if (pane >= max_nodes or !self.used[pane] or !self.nodes[pane].leaf) return;
        const parent = self.nodes[pane].parent;
        self.used[pane] = false;
        if (parent == none) {
            self.root = none;
            self.focus = none;
            self.collect();
            return;
        }
        const sibling = if (self.nodes[parent].a == pane) self.nodes[parent].b else self.nodes[parent].a;
        const grand = self.nodes[parent].parent;
        self.replaceChild(grand, parent, sibling);
        self.nodes[sibling].parent = grand;
        self.used[parent] = false;
        if (self.focus == pane) self.focus = self.firstLeaf(sibling);
        self.collect();
    }

    /// Move the focus to the next (or previous) pane in layout order.
    pub fn cycleFocus(self: *Tree, delta: isize) void {
        if (self.leaf_count <= 1) return;
        const at = std.mem.indexOfScalar(u8, self.leaves[0..self.leaf_count], self.focus) orelse 0;
        const n: isize = @intCast(self.leaf_count);
        self.focus = self.leaves[@intCast(@mod(@as(isize, @intCast(at)) + delta, n))];
    }

    /// The pane containing a screen cell, if any.
    pub fn paneAt(self: *const Tree, x: usize, y: usize) ?u8 {
        for (self.rects[0..self.rect_count]) |pr| {
            if (pr.rect.contains(x, y)) return pr.pane;
        }
        return null;
    }

    pub fn rectOf(self: *const Tree, pane: u8) ?Rect {
        for (self.rects[0..self.rect_count]) |pr| {
            if (pr.pane == pane) return pr.rect;
        }
        return null;
    }

    fn collect(self: *Tree) void {
        self.leaf_count = 0;
        if (self.root != none) self.collectIn(self.root);
    }

    fn collectIn(self: *Tree, idx: u8) void {
        const n = self.nodes[idx];
        if (n.leaf) {
            self.leaves[self.leaf_count] = idx;
            self.leaf_count += 1;
            return;
        }
        self.collectIn(n.a);
        self.collectIn(n.b);
    }

    /// Lay the panes out inside `r`, caching the rectangles and separators.
    pub fn layout(self: *Tree, r: Rect) void {
        self.rect_count = 0;
        self.sep_count = 0;
        if (self.root != none) self.layoutIn(self.root, r);
    }

    fn layoutIn(self: *Tree, idx: u8, r: Rect) void {
        const n = self.nodes[idx];
        if (n.leaf) {
            self.rects[self.rect_count] = .{ .pane = idx, .rect = r };
            self.rect_count += 1;
            return;
        }
        const along = if (n.dir == .columns) r.w else r.h;
        if (along < 3) {
            // Too small to divide: the first child gets everything and the
            // second is simply not shown until there is room again.
            self.layoutIn(n.a, r);
            return;
        }
        const usable = along - 1; // one cell for the separator
        const first = std.math.clamp(usable * n.ratio / 100, 1, usable - 1);
        if (n.dir == .columns) {
            self.layoutIn(n.a, .{ .x = r.x, .y = r.y, .w = first, .h = r.h });
            self.seps[self.sep_count] = .{ .x = r.x + first, .y = r.y, .dir = .columns, .len = r.h };
            self.sep_count += 1;
            self.layoutIn(n.b, .{ .x = r.x + first + 1, .y = r.y, .w = usable - first, .h = r.h });
        } else {
            self.layoutIn(n.a, .{ .x = r.x, .y = r.y, .w = r.w, .h = first });
            self.seps[self.sep_count] = .{ .x = r.x, .y = r.y + first, .dir = .rows, .len = r.w };
            self.sep_count += 1;
            self.layoutIn(n.b, .{ .x = r.x, .y = r.y + first + 1, .w = r.w, .h = usable - first });
        }
    }

    // --- persistence ---
    // The shape is stored preorder: a leaf or a split, then the first
    // child's subtree, then the second's. Leaves appear in layout order, so
    // the i-th leaf of the list is `leaves[i]` on both sides.

    pub const Shape = union(enum) {
        leaf,
        split: struct { dir: Dir, ratio: u8 },
    };

    /// Write the shape into `out` and return the part used.
    pub fn encode(self: *const Tree, out: *[max_nodes]Shape) []Shape {
        var n: usize = 0;
        if (self.root != none) self.encodeIn(self.root, out, &n);
        return out[0..n];
    }

    fn encodeIn(self: *const Tree, idx: u8, out: *[max_nodes]Shape, n: *usize) void {
        const node = self.nodes[idx];
        if (node.leaf) {
            out[n.*] = .leaf;
            n.* += 1;
            return;
        }
        out[n.*] = .{ .split = .{ .dir = node.dir, .ratio = node.ratio } };
        n.* += 1;
        self.encodeIn(node.a, out, n);
        self.encodeIn(node.b, out, n);
    }

    /// Rebuild a tree from a shape, or null when the shape is malformed. The
    /// focus is on the first pane.
    pub fn decode(shape: []const Shape) ?Tree {
        if (shape.len == 0 or shape.len > max_nodes) return null;
        var t: Tree = .empty;
        var at: usize = 0;
        const root = t.build(shape, &at, none) orelse return null;
        if (at != shape.len) return null;
        t.root = root;
        t.collect();
        t.focus = t.leaves[0];
        return t;
    }

    fn build(self: *Tree, shape: []const Shape, at: *usize, parent: u8) ?u8 {
        if (at.* >= shape.len) return null;
        const item = shape[at.*];
        at.* += 1;
        const slot = self.take() orelse return null;
        self.nodes[slot].parent = parent;
        switch (item) {
            .leaf => {},
            .split => |sp| {
                const a = self.build(shape, at, slot) orelse return null;
                const b = self.build(shape, at, slot) orelse return null;
                self.nodes[slot] = .{
                    .leaf = false,
                    .parent = parent,
                    .dir = sp.dir,
                    .ratio = std.math.clamp(sp.ratio, 5, 95),
                    .a = a,
                    .b = b,
                };
            },
        }
        return slot;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn one() Tree {
    var t: Tree = .empty;
    _ = t.open().?;
    return t;
}

test "an empty tree gets its first pane from open" {
    var t: Tree = .empty;
    try testing.expect(t.isEmpty());
    try testing.expect(t.focused() == null);
    const pane = t.open().?;
    try testing.expectEqual(@as(usize, 1), t.count());
    try testing.expectEqual(pane, t.focused().?);
    try testing.expect(t.open() == null); // only for an empty tree
}

test "splitting columns puts the new pane on the right and keeps the old id" {
    var t = one();
    const old = t.focused().?;
    const new = t.split(old, .columns, false).?;
    try testing.expectEqual(new, t.focused().?); // focus moves to the new pane
    try testing.expectEqual(old, t.leaves[0]);
    try testing.expectEqual(new, t.leaves[1]);

    t.layout(.{ .w = 80, .h = 20 });
    try testing.expectEqual(@as(usize, 2), t.rect_count);
    try testing.expectEqual(@as(usize, 1), t.sep_count);
    const left = t.rectOf(old).?;
    const right = t.rectOf(new).?;
    try testing.expectEqual(@as(usize, 0), left.x);
    try testing.expectEqual(@as(usize, 39), left.w); // (80 - 1 separator) at 50%
    try testing.expectEqual(@as(usize, 40), right.x);
    try testing.expectEqual(@as(usize, 40), right.w); // the odd cell goes right
    try testing.expectEqual(@as(usize, 39), t.seps[0].x);
    try testing.expectEqual(Dir.columns, t.seps[0].dir);
    try testing.expectEqual(@as(usize, 20), left.h);
}

test "splitting first puts the new pane on the left or top" {
    var t = one();
    const old = t.focused().?;
    const new = t.split(old, .rows, true).?;
    try testing.expectEqual(new, t.leaves[0]);
    t.layout(.{ .y = 1, .w = 40, .h = 11 });
    const top = t.rectOf(new).?;
    const bottom = t.rectOf(old).?;
    try testing.expectEqual(@as(usize, 1), top.y);
    try testing.expectEqual(@as(usize, 5), top.h); // (11 - 1 separator) at 50%
    try testing.expectEqual(@as(usize, 7), bottom.y);
    try testing.expectEqual(@as(usize, 5), bottom.h);
    try testing.expectEqual(@as(usize, 6), t.seps[0].y);
    try testing.expectEqual(Dir.rows, t.seps[0].dir);
}

test "a pane is found from a screen cell" {
    var t = one();
    const left = t.focused().?;
    const right = t.split(left, .columns, false).?;
    t.layout(.{ .y = 1, .w = 40, .h = 10 });
    try testing.expectEqual(@as(?u8, left), t.paneAt(3, 3));
    try testing.expectEqual(@as(?u8, right), t.paneAt(30, 3));
    try testing.expectEqual(@as(?u8, null), t.paneAt(19, 3)); // the separator
    try testing.expectEqual(@as(?u8, null), t.paneAt(3, 20)); // outside
}

test "closing a pane gives its space to the sibling, whose id does not change" {
    var t = one();
    const a = t.focused().?;
    const b = t.split(a, .columns, false).?;
    const c = t.split(b, .rows, false).?;
    try testing.expectEqual(@as(usize, 3), t.count());

    // Close the middle pane: a and c keep their ids, c takes b's place.
    t.remove(b);
    try testing.expectEqual(@as(usize, 2), t.count());
    try testing.expectEqual(a, t.leaves[0]);
    try testing.expectEqual(c, t.leaves[1]);
    try testing.expectEqual(c, t.focused().?);

    t.remove(c);
    try testing.expectEqual(a, t.focused().?);
    t.layout(.{ .w = 80, .h = 20 });
    try testing.expectEqual(@as(usize, 80), t.rectOf(a).?.w); // full width again

    t.remove(a);
    try testing.expect(t.isEmpty());
    try testing.expect(t.focused() == null);
}

test "closing a pane that is not focused leaves the focus alone" {
    var t = one();
    const a = t.focused().?;
    const b = t.split(a, .columns, false).?;
    t.remove(a);
    try testing.expectEqual(b, t.focused().?);
    try testing.expectEqual(@as(usize, 1), t.count());
}

test "focus cycles in layout order" {
    var t = one();
    const first = t.focused().?;
    const second = t.split(first, .columns, false).?;
    const third = t.split(second, .columns, false).?;
    try testing.expectEqual(third, t.focused().?);
    t.cycleFocus(1);
    try testing.expectEqual(first, t.focused().?);
    t.cycleFocus(1);
    try testing.expectEqual(second, t.focused().?);
    t.cycleFocus(-1);
    try testing.expectEqual(first, t.focused().?);
}

test "the node pool is recycled, and the pane limit holds" {
    var t = one();
    const base = t.focused().?;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const new = t.split(base, .columns, false).?;
        t.remove(new);
    }
    try testing.expectEqual(@as(usize, 1), t.count());
    i = 0;
    while (i < max_panes - 1) : (i += 1) {
        try testing.expect(t.split(t.focused().?, .columns, false) != null);
    }
    try testing.expectEqual(@as(usize, max_panes), t.count());
    try testing.expect(t.split(t.focused().?, .columns, false) == null); // full
}

test "a pane too small to divide shows only its first half" {
    var t = one();
    const a = t.focused().?;
    _ = t.split(a, .columns, false).?;
    t.layout(.{ .w = 2, .h = 5 });
    try testing.expectEqual(@as(usize, 1), t.rect_count);
    try testing.expectEqual(@as(usize, 0), t.sep_count);
    try testing.expectEqual(@as(usize, 2), t.rectOf(a).?.w);
}

test "a layout survives an encode/decode round trip" {
    var t = one();
    const a = t.focused().?;
    const b = t.split(a, .columns, false).?;
    _ = t.split(b, .rows, false).?;
    var buf: [max_nodes]Tree.Shape = undefined;
    const shape = t.encode(&buf);
    try testing.expectEqual(@as(usize, 5), shape.len); // split, leaf, split, leaf, leaf

    var back = Tree.decode(shape).?;
    try testing.expectEqual(@as(usize, 3), back.count());
    t.layout(.{ .w = 80, .h = 20 });
    back.layout(.{ .w = 80, .h = 20 });
    try testing.expectEqual(t.rect_count, back.rect_count);
    for (t.rects[0..t.rect_count], back.rects[0..back.rect_count]) |x, y| {
        try testing.expectEqual(x.rect, y.rect);
    }
    try testing.expectEqual(t.sep_count, back.sep_count);
    // The decoded tree is a working tree: its panes can be closed.
    back.remove(back.leaves[1]);
    try testing.expectEqual(@as(usize, 2), back.count());
}

test "a malformed layout is rejected" {
    try testing.expect(Tree.decode(&.{}) == null);
    // A split with a single child.
    try testing.expect(Tree.decode(&.{ .{ .split = .{ .dir = .columns, .ratio = 50 } }, .leaf }) == null);
    // Something after a complete tree.
    try testing.expect(Tree.decode(&.{ .leaf, .leaf }) == null);
    // More panes than the pool holds.
    var big: [max_nodes + 2]Tree.Shape = undefined;
    for (&big) |*s| s.* = .{ .split = .{ .dir = .rows, .ratio = 50 } };
    try testing.expect(Tree.decode(&big) == null);
    const single = Tree.decode(&.{.leaf}).?;
    try testing.expectEqual(@as(usize, 1), single.count());
}
