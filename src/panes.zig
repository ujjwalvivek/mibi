//! Pane layout: a binary tree of splits over a fixed pool of nodes.
//!
//! Leaves hold a document *id* (stable across tab reordering, unlike an
//! index). The pool is fixed and recycling, so splitting and closing panes
//! never allocates and cannot fail halfway through a redraw.

const std = @import("std");

/// How a split divides its rectangle.
pub const Dir = enum {
    /// Side by side, separated by a vertical line.
    columns,
    /// Stacked, separated by a horizontal line.
    rows,
};

pub const MAX_PANES = 8;
const MAX_NODES = 2 * MAX_PANES - 1;

pub const Rect = struct {
    x: usize = 0,
    y: usize = 0,
    w: usize = 0,
    h: usize = 0,

    pub fn contains(self: Rect, x: usize, y: usize) bool {
        return x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self.h;
    }
};

pub const Node = struct {
    leaf: bool = true,
    /// Leaf: the document shown here (a stable id, not a tab index).
    doc: u32 = 0,
    dir: Dir = .columns,
    /// Percent of the rectangle given to `a`.
    ratio: u8 = 50,
    a: u8 = 0,
    b: u8 = 0,
};

pub const PaneRect = struct {
    node: u8,
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
    nodes: [MAX_NODES]Node = [_]Node{.{}} ** MAX_NODES,
    free: [MAX_NODES]u8 = undefined,
    free_len: usize = 0,
    root: u8 = 0,
    focus: u8 = 0,
    /// Number of leaves (panes) currently in the tree.
    live: usize = 0,
    /// Layout cache, filled by `layout` and used by the mouse.
    rects: [MAX_PANES]PaneRect = undefined,
    rect_count: usize = 0,
    seps: [MAX_PANES]Separator = undefined,
    sep_count: usize = 0,
    leaves: [MAX_PANES]u8 = undefined,
    leaf_count: usize = 0,

    pub fn init(doc: u32) Tree {
        var t = Tree{};
        t.nodes[0] = .{ .leaf = true, .doc = doc };
        t.root = 0;
        t.focus = 0;
        t.live = 1;
        var i: u8 = 1;
        while (i < MAX_NODES) : (i += 1) t.putFree(i);
        t.collect();
        return t;
    }

    /// An empty tree: no panes at all (the session has no documents).
    pub fn empty() Tree {
        var t = Tree{};
        var i: u8 = 0;
        while (i < MAX_NODES) : (i += 1) t.putFree(i);
        t.live = 0;
        return t;
    }

    fn takeFree(self: *Tree) ?u8 {
        if (self.free_len == 0) return null;
        self.free_len -= 1;
        return self.free[self.free_len];
    }

    fn putFree(self: *Tree, idx: u8) void {
        if (self.free_len < self.free.len) {
            self.free[self.free_len] = idx;
            self.free_len += 1;
        }
    }

    pub fn focusedNode(self: *const Tree) ?*const Node {
        if (self.live == 0) return null;
        return &self.nodes[self.focus];
    }

    pub fn focusedDoc(self: *const Tree) ?u32 {
        const n = self.focusedNode() orelse return null;
        return n.doc;
    }

    pub fn setFocusedDoc(self: *Tree, doc: u32) void {
        if (self.live == 0) {
            self.* = Tree.init(doc);
            return;
        }
        self.nodes[self.focus].doc = doc;
    }

    /// The pane showing `doc`, if any.
    pub fn paneWithDoc(self: *const Tree, doc: u32) ?u8 {
        for (self.leaves[0..self.leaf_count]) |idx| {
            if (self.nodes[idx].doc == doc) return idx;
        }
        return null;
    }

    /// Split the focused pane; `a` keeps the old document, `b` shows `doc`.
    /// The focus moves to the new pane.
    pub fn split(self: *Tree, dir: Dir, doc: u32) bool {
        if (self.live == 0) return false;
        return self.splitAt(self.focus, dir, doc, false);
    }

    /// Split the leaf `node` and show `doc` in the new pane. With `first` the
    /// new pane takes the left/top half, otherwise the right/bottom half.
    pub fn splitAt(self: *Tree, node: u8, dir: Dir, doc: u32, first: bool) bool {
        if (self.live == 0 or self.leaf_count >= MAX_PANES) return false;
        if (!self.nodes[node].leaf) return false;
        const na = self.takeFree() orelse return false;
        const nb = self.takeFree() orelse {
            self.putFree(na);
            return false;
        };
        const old_doc = self.nodes[node].doc;
        if (first) {
            self.nodes[na] = .{ .leaf = true, .doc = doc };
            self.nodes[nb] = .{ .leaf = true, .doc = old_doc };
        } else {
            self.nodes[na] = .{ .leaf = true, .doc = old_doc };
            self.nodes[nb] = .{ .leaf = true, .doc = doc };
        }
        self.nodes[node] = .{ .leaf = false, .dir = dir, .ratio = 50, .a = na, .b = nb };
        self.focus = if (first) na else nb;
        self.live += 1;
        self.collect();
        return true;
    }

    fn parentOf(self: *const Tree, idx: u8) ?u8 {
        return self.parentIn(self.root, idx);
    }

    fn parentIn(self: *const Tree, start: u8, idx: u8) ?u8 {
        const n = self.nodes[start];
        if (n.leaf) return null;
        if (n.a == idx or n.b == idx) return start;
        if (self.parentIn(n.a, idx)) |p| return p;
        return self.parentIn(n.b, idx);
    }

    fn firstLeaf(self: *const Tree, start: u8) u8 {
        var idx = start;
        while (!self.nodes[idx].leaf) idx = self.nodes[idx].a;
        return idx;
    }

    /// Close the focused pane. Its sibling takes the parent's place; closing
    /// the last pane empties the tree.
    pub fn removeFocused(self: *Tree) void {
        if (self.live == 0) return;
        const f = self.focus;
        const p = self.parentOf(f) orelse {
            self.* = Tree.empty();
            return;
        };
        const sib = if (self.nodes[p].a == f) self.nodes[p].b else self.nodes[p].a;
        self.nodes[p] = self.nodes[sib];
        self.putFree(sib);
        self.putFree(f);
        self.live -= 1;
        self.focus = self.firstLeaf(p);
        self.collect();
    }

    /// Move the focus to the next (or previous) pane in layout order.
    pub fn cycleFocus(self: *Tree, delta: isize) void {
        if (self.leaf_count <= 1) return;
        var i: usize = 0;
        while (i < self.leaf_count) : (i += 1) {
            if (self.leaves[i] == self.focus) break;
        }
        if (i >= self.leaf_count) i = 0;
        const n: isize = @intCast(self.leaf_count);
        const next: usize = @intCast(@mod(@as(isize, @intCast(i)) + delta, n));
        self.focus = self.leaves[next];
    }

    /// The pane containing a screen cell, if any.
    pub fn paneAt(self: *const Tree, x: usize, y: usize) ?u8 {
        for (self.rects[0..self.rect_count]) |pr| {
            if (pr.rect.contains(x, y)) return pr.node;
        }
        return null;
    }

    pub fn rectOf(self: *const Tree, node: u8) ?Rect {
        for (self.rects[0..self.rect_count]) |pr| {
            if (pr.node == node) return pr.rect;
        }
        return null;
    }

    /// Refresh the leaf list (layout order: left to right, top to bottom).
    pub fn collect(self: *Tree) void {
        self.leaf_count = 0;
        if (self.live == 0) return;
        self.collectIn(self.root);
    }

    fn collectIn(self: *Tree, idx: u8) void {
        if (self.leaf_count >= MAX_PANES) return;
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
        if (self.live == 0) return;
        self.layoutIn(self.root, r);
    }

    fn layoutIn(self: *Tree, idx: u8, r: Rect) void {
        if (self.rect_count >= MAX_PANES) return;
        const n = self.nodes[idx];
        if (n.leaf) {
            self.rects[self.rect_count] = .{ .node = idx, .rect = r };
            self.rect_count += 1;
            return;
        }
        if (n.dir == .columns) {
            if (r.w < 3) {
                // Too narrow to divide: give everything to the first child.
                self.layoutIn(n.a, r);
                return;
            }
            const usable = r.w - 1; // one column for the separator
            var aw = usable * n.ratio / 100;
            if (aw < 1) aw = 1;
            if (aw > usable - 1) aw = usable - 1;
            self.layoutIn(n.a, .{ .x = r.x, .y = r.y, .w = aw, .h = r.h });
            if (self.sep_count < self.seps.len) {
                self.seps[self.sep_count] = .{ .x = r.x + aw, .y = r.y, .dir = .columns, .len = r.h };
                self.sep_count += 1;
            }
            self.layoutIn(n.b, .{ .x = r.x + aw + 1, .y = r.y, .w = usable - aw, .h = r.h });
        } else {
            if (r.h < 3) {
                self.layoutIn(n.a, r);
                return;
            }
            const usable = r.h - 1;
            var ah = usable * n.ratio / 100;
            if (ah < 1) ah = 1;
            if (ah > usable - 1) ah = usable - 1;
            self.layoutIn(n.a, .{ .x = r.x, .y = r.y, .w = r.w, .h = ah });
            if (self.sep_count < self.seps.len) {
                self.seps[self.sep_count] = .{ .x = r.x, .y = r.y + ah, .dir = .rows, .len = r.w };
                self.sep_count += 1;
            }
            self.layoutIn(n.b, .{ .x = r.x, .y = r.y + ah + 1, .w = r.w, .h = usable - ah });
        }
    }
};

// --- persistence -----------------------------------------------------------
// The layout is stored preorder: a leaf or a split, then the first child's
// subtree, then the second's.

pub const Encoded = union(enum) {
    leaf: u32,
    split: struct { dir: Dir, ratio: u8 },
};

/// Append the layout to `list` in preorder (does nothing for an empty tree).
pub fn encode(self: *const Tree, list: *std.ArrayList(Encoded), allocator: std.mem.Allocator) !void {
    if (self.live == 0) return;
    try encodeIn(self, self.root, list, allocator);
}

fn encodeIn(self: *const Tree, idx: u8, list: *std.ArrayList(Encoded), allocator: std.mem.Allocator) !void {
    const n = self.nodes[idx];
    if (n.leaf) {
        try list.append(allocator, .{ .leaf = n.doc });
        return;
    }
    try list.append(allocator, .{ .split = .{ .dir = n.dir, .ratio = n.ratio } });
    try encodeIn(self, n.a, list, allocator);
    try encodeIn(self, n.b, list, allocator);
}

/// Rebuild a tree from a preorder list, or null when the list is malformed.
pub fn decode(list: []const Encoded) ?Tree {
    if (list.len == 0) return null;
    var t = Tree.empty();
    var idx: usize = 0;
    const root = buildNode(&t, list, &idx) orelse return null;
    if (idx != list.len or t.live == 0) return null;
    t.root = root;
    t.focus = t.firstLeaf(root);
    t.collect();
    return t;
}

fn buildNode(t: *Tree, list: []const Encoded, idx: *usize) ?u8 {
    if (idx.* >= list.len) return null;
    const e = list[idx.*];
    idx.* += 1;
    const slot = t.takeFree() orelse return null;
    switch (e) {
        .leaf => |doc| {
            t.nodes[slot] = .{ .leaf = true, .doc = doc };
            t.live += 1;
            return slot;
        },
        .split => |sp| {
            const a = buildNode(t, list, idx) orelse return null;
            const b = buildNode(t, list, idx) orelse return null;
            t.nodes[slot] = .{
                .leaf = false,
                .dir = sp.dir,
                .ratio = sp.ratio,
                .a = a,
                .b = b,
            };
            return slot;
        },
    }
}

test "a layout survives an encode/decode round trip" {
    var t = Tree.init(1);
    _ = t.split(.columns, 2);
    _ = t.split(.rows, 3);
    var list = std.ArrayList(Encoded).empty;
    defer list.deinit(std.testing.allocator);
    try encode(&t, &list, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), list.items.len); // split, leaf, split, leaf, leaf

    var back = decode(list.items).?;
    try std.testing.expectEqual(@as(usize, 3), back.live);
    t.layout(.{ .x = 0, .y = 0, .w = 80, .h = 20 });
    back.layout(.{ .x = 0, .y = 0, .w = 80, .h = 20 });
    try std.testing.expectEqual(t.rect_count, back.rect_count);
    var i: usize = 0;
    while (i < t.rect_count) : (i += 1) {
        try std.testing.expectEqual(t.rects[i].rect.x, back.rects[i].rect.x);
        try std.testing.expectEqual(t.rects[i].rect.y, back.rects[i].rect.y);
        try std.testing.expectEqual(t.rects[i].rect.w, back.rects[i].rect.w);
        try std.testing.expectEqual(t.rects[i].rect.h, back.rects[i].rect.h);
        try std.testing.expectEqual(t.nodes[t.rects[i].node].doc, back.nodes[back.rects[i].node].doc);
    }
    try std.testing.expectEqual(@as(usize, t.sep_count), back.sep_count);
}

test "a malformed layout is rejected" {
    try std.testing.expectEqual(@as(?Tree, null), decode(&[_]Encoded{}));
    // A split with a single child cannot be decoded.
    try std.testing.expectEqual(@as(?Tree, null), decode(&[_]Encoded{.{ .split = .{ .dir = .columns, .ratio = 50 } }}));
    // A complete single leaf is fine.
    const one = decode(&[_]Encoded{.{ .leaf = 9 }}).?;
    try std.testing.expectEqual(@as(usize, 1), one.live);
    try std.testing.expectEqual(@as(?u32, 9), one.focusedDoc());
}

// --- tests -----------------------------------------------------------------

test "a new tree is one pane showing the document" {
    const t = Tree.init(7);
    try std.testing.expectEqual(@as(usize, 1), t.live);
    try std.testing.expectEqual(@as(?u32, 7), t.focusedDoc());
    try std.testing.expectEqual(@as(usize, 1), t.leaf_count);
}

test "splitting columns puts the new document on the right" {
    var t = Tree.init(1);
    try std.testing.expect(t.split(.columns, 2));
    try std.testing.expectEqual(@as(usize, 2), t.live);
    try std.testing.expectEqual(@as(?u32, 2), t.focusedDoc()); // focus moves to the new pane

    t.layout(.{ .x = 0, .y = 0, .w = 80, .h = 20 });
    try std.testing.expectEqual(@as(usize, 2), t.rect_count);
    try std.testing.expectEqual(@as(usize, 1), t.sep_count);
    const left = t.rects[0].rect;
    const right = t.rects[1].rect;
    try std.testing.expectEqual(@as(usize, 0), left.x);
    try std.testing.expectEqual(@as(usize, 39), left.w); // (80 - 1 separator) at 50%
    try std.testing.expectEqual(@as(usize, 40), right.x); // one column for the separator
    try std.testing.expectEqual(@as(usize, 40), right.w); // the odd cell goes right
    try std.testing.expectEqual(@as(usize, 39), t.seps[0].x);
    try std.testing.expectEqual(Dir.columns, t.seps[0].dir);
    try std.testing.expectEqual(@as(usize, 0), left.y);
    try std.testing.expectEqual(@as(usize, 20), left.h);
}

test "splitting rows stacks the panes" {
    var t = Tree.init(1);
    try std.testing.expect(t.split(.rows, 2));
    t.layout(.{ .x = 0, .y = 1, .w = 40, .h = 11 });
    const top = t.rects[0].rect;
    const bottom = t.rects[1].rect;
    try std.testing.expectEqual(@as(usize, 1), top.y);
    try std.testing.expectEqual(@as(usize, 5), top.h); // (11 - 1 separator) at 50%
    try std.testing.expectEqual(@as(usize, 7), bottom.y); // one row for the separator
    try std.testing.expectEqual(@as(usize, 5), bottom.h);
    try std.testing.expectEqual(@as(usize, 6), t.seps[0].y);
    try std.testing.expectEqual(Dir.rows, t.seps[0].dir);
}

test "a pane is found from a screen cell" {
    var t = Tree.init(1);
    _ = t.split(.columns, 2);
    t.layout(.{ .x = 0, .y = 1, .w = 40, .h = 10 });
    const left = t.rects[0].node;
    const right = t.rects[1].node;
    try std.testing.expectEqual(@as(?u8, left), t.paneAt(3, 3));
    try std.testing.expectEqual(@as(?u8, right), t.paneAt(30, 3));
    try std.testing.expectEqual(@as(?u8, null), t.paneAt(3, 20)); // outside
}

test "closing a pane gives its space back to the sibling" {
    var t = Tree.init(1);
    _ = t.split(.columns, 2);
    const left_doc = t.nodes[t.leaves[0]].doc;
    // Focus is on the new (right) pane; closing it leaves the left one.
    t.removeFocused();
    try std.testing.expectEqual(@as(usize, 1), t.live);
    try std.testing.expectEqual(@as(usize, 1), t.leaf_count);
    t.layout(.{ .x = 0, .y = 0, .w = 40, .h = 10 });
    try std.testing.expectEqual(@as(usize, 40), t.rects[0].rect.w); // full width again
    try std.testing.expectEqual(left_doc, t.focusedDoc().?);

    // Closing the last pane empties the tree.
    t.removeFocused();
    try std.testing.expectEqual(@as(usize, 0), t.live);
    try std.testing.expectEqual(@as(?u32, null), t.focusedDoc());
}

test "a nested split closes back to one pane" {
    var t = Tree.init(1);
    _ = t.split(.columns, 2);
    _ = t.split(.rows, 3);
    try std.testing.expectEqual(@as(usize, 3), t.live);
    t.layout(.{ .x = 0, .y = 0, .w = 80, .h = 20 });
    try std.testing.expectEqual(@as(usize, 3), t.rect_count);
    try std.testing.expectEqual(@as(usize, 2), t.sep_count);
    t.removeFocused();
    try std.testing.expectEqual(@as(usize, 2), t.live);
    t.removeFocused();
    try std.testing.expectEqual(@as(usize, 1), t.live);
    t.layout(.{ .x = 0, .y = 0, .w = 80, .h = 20 });
    try std.testing.expectEqual(@as(usize, 80), t.rects[0].rect.w);
}

test "focus cycles in layout order" {
    var t = Tree.init(1);
    _ = t.split(.columns, 2);
    _ = t.split(.columns, 3);
    try std.testing.expectEqual(@as(usize, 3), t.live);
    const first = t.leaves[0];
    const second = t.leaves[1];
    const third = t.leaves[2];
    try std.testing.expectEqual(third, t.focus);
    t.cycleFocus(1);
    try std.testing.expectEqual(first, t.focus);
    t.cycleFocus(1);
    try std.testing.expectEqual(second, t.focus);
    t.cycleFocus(-1);
    try std.testing.expectEqual(first, t.focus);
}

test "the node pool is recycled, so splits do not leak" {
    var t = Tree.init(1);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        _ = t.split(.columns, @intCast(i + 2));
        t.removeFocused();
    }
    try std.testing.expectEqual(@as(usize, 1), t.live);
    // Still able to split up to the pane limit.
    i = 0;
    while (i < MAX_PANES - 1) : (i += 1) {
        try std.testing.expect(t.split(.columns, @intCast(i + 2)));
    }
    try std.testing.expectEqual(MAX_PANES, t.live);
    try std.testing.expect(!t.split(.columns, 99)); // full
}

test "documents can be looked up by id" {
    var t = Tree.init(10);
    _ = t.split(.columns, 20);
    try std.testing.expectEqual(@as(?u8, t.leaves[0]), t.paneWithDoc(10));
    try std.testing.expectEqual(@as(?u8, t.leaves[1]), t.paneWithDoc(20));
    try std.testing.expectEqual(@as(?u8, null), t.paneWithDoc(30));
}
