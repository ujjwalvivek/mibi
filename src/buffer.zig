//! Piece-table text buffer.
//!
//! The document is a list of pieces; each piece points into either the
//! immutable `original` bytes (loaded from disk) or the append-only `add`
//! buffer (everything typed). Edits only touch the piece list, so insert and
//! delete are cheap regardless of file size. `flat` materialises the current
//! text for rendering and saving, and is rebuilt only when dirty.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Source = enum { original, add };

pub const Piece = struct { source: Source, start: usize, len: usize };

/// A saved buffer state for undo/redo. The add buffer is append-only, so a
/// state is just the piece list.
pub const Snapshot = struct { pieces: []Piece };

pub const Buffer = struct {
    allocator: Allocator,
    original: []u8,
    add: std.ArrayList(u8),
    pieces: std.ArrayList(Piece),
    flat_buf: std.ArrayList(u8),
    flat_dirty: bool,

    pub fn init(allocator: Allocator, data: []const u8) !Buffer {
        const original = try allocator.dupe(u8, data);
        errdefer allocator.free(original);
        var pieces = std.ArrayList(Piece).empty;
        errdefer pieces.deinit(allocator);
        if (data.len > 0) {
            try pieces.append(allocator, .{ .source = .original, .start = 0, .len = data.len });
        }
        return .{
            .allocator = allocator,
            .original = original,
            .add = std.ArrayList(u8).empty,
            .pieces = pieces,
            .flat_buf = std.ArrayList(u8).empty,
            .flat_dirty = true,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.original);
        self.add.deinit(self.allocator);
        self.pieces.deinit(self.allocator);
        self.flat_buf.deinit(self.allocator);
    }

    pub fn len(self: *const Buffer) usize {
        var n: usize = 0;
        for (self.pieces.items) |p| n += p.len;
        return n;
    }

    /// Insert `bytes` at byte offset `pos`.
    pub fn insert(self: *Buffer, pos: usize, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const add_start = self.add.items.len;
        try self.add.appendSlice(self.allocator, bytes);

        var idx: usize = 0;
        var off: usize = 0;
        while (idx < self.pieces.items.len and off + self.pieces.items[idx].len < pos) : (idx += 1) {
            off += self.pieces.items[idx].len;
        }
        const within = pos - off;
        if (idx < self.pieces.items.len) {
            const p = self.pieces.items[idx];
            if (within == 0) {
                // insert before this piece
            } else if (within >= p.len) {
                idx += 1;
            } else {
                self.pieces.items[idx] = .{ .source = p.source, .start = p.start, .len = within };
                try self.pieces.insert(self.allocator, idx + 1, .{
                    .source = p.source,
                    .start = p.start + within,
                    .len = p.len - within,
                });
                idx += 1;
            }
        }
        try self.pieces.insert(self.allocator, idx, .{ .source = .add, .start = add_start, .len = bytes.len });
        self.flat_dirty = true;
    }

    /// Delete `count` bytes starting at byte offset `pos`.
    pub fn delete(self: *Buffer, pos: usize, count: usize) !void {
        if (count == 0) return;
        const end = pos + count;
        var out = std.ArrayList(Piece).empty;
        errdefer out.deinit(self.allocator);
        var off: usize = 0;
        for (self.pieces.items) |p| {
            const p_start = off;
            const p_end = off + p.len;
            off = p_end;
            if (p_end <= pos or p_start >= end) {
                try out.append(self.allocator, p);
                continue;
            }
            if (p_start < pos) {
                try out.append(self.allocator, .{ .source = p.source, .start = p.start, .len = pos - p_start });
            }
            if (p_end > end) {
                const skip = end - p_start;
                try out.append(self.allocator, .{ .source = p.source, .start = p.start + skip, .len = p_end - end });
            }
        }
        self.pieces.deinit(self.allocator);
        self.pieces = out;
        self.flat_dirty = true;
    }

    /// The whole document as a contiguous slice (rebuilt when dirty).
    pub fn flat(self: *Buffer) []const u8 {
        if (self.flat_dirty) {
            self.flat_buf.clearRetainingCapacity();
            for (self.pieces.items) |p| {
                const src = switch (p.source) {
                    .original => self.original,
                    .add => self.add.items,
                };
                const end = p.start + p.len;
                if (end > src.len) break; // defensive: never index out of bounds
                self.flat_buf.appendSlice(self.allocator, src[p.start..end]) catch break;
            }
            self.flat_dirty = false;
        }
        return self.flat_buf.items;
    }

    pub fn snapshot(self: *Buffer) !Snapshot {
        return .{ .pieces = try self.allocator.dupe(Piece, self.pieces.items) };
    }

    pub fn freeSnapshot(self: *Buffer, s: Snapshot) void {
        self.allocator.free(s.pieces);
    }

    pub fn restore(self: *Buffer, s: Snapshot) !void {
        self.pieces.clearRetainingCapacity();
        try self.pieces.appendSlice(self.allocator, s.pieces);
        // The add buffer is append-only and must never be truncated: redo
        // restores piece lists that point into bytes an earlier undo wrote.
        self.flat_dirty = true;
    }
};

test "piece table insert and delete" {
    var b = try Buffer.init(std.testing.allocator, "hello world");
    defer b.deinit();

    try b.insert(5, ",");
    try std.testing.expectEqualStrings("hello, world", b.flat());

    try b.insert(0, ">> ");
    try std.testing.expectEqualStrings(">> hello, world", b.flat());

    try b.delete(0, 3);
    try std.testing.expectEqualStrings("hello, world", b.flat());

    try b.delete(5, 1);
    try std.testing.expectEqualStrings("hello world", b.flat());

    try b.insert(b.len(), "!");
    try std.testing.expectEqualStrings("hello world!", b.flat());
}

test "piece table snapshot and restore" {
    var b = try Buffer.init(std.testing.allocator, "abc");
    defer b.deinit();

    const s = try b.snapshot();
    defer b.freeSnapshot(s);

    try b.insert(3, "def");
    try std.testing.expectEqualStrings("abcdef", b.flat());

    try b.restore(s);
    try std.testing.expectEqualStrings("abc", b.flat());
}
