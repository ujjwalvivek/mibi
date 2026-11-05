//! Piece-table text buffer.
//!
//! The document is a list of pieces; each piece points into either the
//! immutable `original` bytes (loaded from disk) or the append-only `add`
//! buffer (everything typed). Edits only touch the piece list, so insert and
//! delete are cheap regardless of file size. `flat` materialises the current
//! text for rendering and saving, and is rebuilt only when dirty.
//!
//! The flat rebuild also produces `line_starts`, a cached offset of every line
//! beginning. Row lookups are then a binary search instead of a scan from byte
//! zero, which keeps a frame O(visible lines) rather than O(file size) per row.
//! The total byte length is maintained incrementally for the same reason.

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
    /// Byte offset of the start of every line. Always at least `.{0}`.
    line_starts: std.ArrayList(usize),
    /// Total document length in bytes, kept in step with the piece list.
    total: usize,
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
            .line_starts = std.ArrayList(usize).empty,
            .total = data.len,
            .flat_dirty = true,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.original);
        self.add.deinit(self.allocator);
        self.pieces.deinit(self.allocator);
        self.flat_buf.deinit(self.allocator);
        self.line_starts.deinit(self.allocator);
    }

    pub fn len(self: *const Buffer) usize {
        return self.total;
    }

    /// Insert `bytes` at byte offset `pos`.
    pub fn insert(self: *Buffer, pos: usize, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const at = @min(pos, self.total);
        const add_start = self.add.items.len;
        try self.add.appendSlice(self.allocator, bytes);

        var idx: usize = 0;
        var off: usize = 0;
        while (idx < self.pieces.items.len and off + self.pieces.items[idx].len < at) : (idx += 1) {
            off += self.pieces.items[idx].len;
        }
        const within = at - off;
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
        self.total += bytes.len;
        self.flat_dirty = true;
    }

    /// Delete `count` bytes starting at byte offset `pos`.
    pub fn delete(self: *Buffer, pos: usize, count: usize) !void {
        if (count == 0 or pos >= self.total) return;
        const n = @min(count, self.total - pos);
        const end = pos + n;
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
        self.total -= n;
        self.flat_dirty = true;
    }

    /// Rebuild `flat_buf` and the line index from the piece list.
    fn rebuild(self: *Buffer) void {
        self.flat_buf.clearRetainingCapacity();
        self.line_starts.clearRetainingCapacity();
        // Never leave the index empty: a document always has one line.
        self.line_starts.append(self.allocator, 0) catch {
            self.flat_dirty = false;
            return;
        };
        for (self.pieces.items) |p| {
            const src = switch (p.source) {
                .original => self.original,
                .add => self.add.items,
            };
            const end = p.start + p.len;
            if (end > src.len) break; // defensive: never index out of bounds
            const chunk = src[p.start..end];
            const base = self.flat_buf.items.len;
            self.flat_buf.appendSlice(self.allocator, chunk) catch break;
            var i: usize = 0;
            while (std.mem.indexOfScalarPos(u8, chunk, i, '\n')) |nl| {
                self.line_starts.append(self.allocator, base + nl + 1) catch break;
                i = nl + 1;
            }
        }
        self.flat_dirty = false;
    }

    /// The whole document as a contiguous slice (rebuilt when dirty).
    pub fn flat(self: *Buffer) []const u8 {
        if (self.flat_dirty) self.rebuild();
        return self.flat_buf.items;
    }

    /// Start offset of every line, valid until the next edit.
    pub fn lineStarts(self: *Buffer) []const usize {
        if (self.flat_dirty) self.rebuild();
        return self.line_starts.items;
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
        var total: usize = 0;
        for (s.pieces) |p| total += p.len;
        self.total = total;
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
    try std.testing.expectEqual(@as(usize, 3), b.len()); // total recomputed on restore
}

/// The cached line index must equal a scan of the flat text.
fn expectLineStartsMatch(b: *Buffer) !void {
    const f = b.flat();
    var expected = std.ArrayList(usize).empty;
    defer expected.deinit(std.testing.allocator);
    try expected.append(std.testing.allocator, 0);
    for (f, 0..) |c, i| {
        if (c == '\n') try expected.append(std.testing.allocator, i + 1);
    }
    try std.testing.expectEqualSlices(usize, expected.items, b.lineStarts());
}

test "line index tracks inserts and deletes" {
    var b = try Buffer.init(std.testing.allocator, "one\ntwo\nthree");
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 3), b.lineStarts().len);
    try std.testing.expectEqual(@as(usize, 13), b.len());
    try expectLineStartsMatch(&b);

    try b.insert(3, "\nX"); // "one\nX\ntwo\nthree"
    try std.testing.expectEqual(@as(usize, 4), b.lineStarts().len);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 4, 6, 10 }, b.lineStarts());
    try std.testing.expectEqual(@as(usize, 15), b.len());

    try b.delete(0, 2); // "e\nX\ntwo\nthree"
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 2, 4, 8 }, b.lineStarts());
    try std.testing.expectEqual(@as(usize, 13), b.len());

    // Delete across a line boundary.
    try b.delete(1, 3); // "etwo\nthree"
    try std.testing.expectEqualStrings("etwo\nthree", b.flat());
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 5 }, b.lineStarts());
    try expectLineStartsMatch(&b);

    // Insert exactly at a line start and at the very end.
    try b.insert(0, "Z\n");
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 2, 7 }, b.lineStarts());
    try b.insert(b.len(), "\n");
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 2, 7, 13 }, b.lineStarts());
    try expectLineStartsMatch(&b);
}

test "empty and newline-only buffers always have one line" {
    var empty = try Buffer.init(std.testing.allocator, "");
    defer empty.deinit();
    try std.testing.expectEqualSlices(usize, &[_]usize{0}, empty.lineStarts());
    try std.testing.expectEqual(@as(usize, 0), empty.len());

    var nl = try Buffer.init(std.testing.allocator, "\n");
    defer nl.deinit();
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1 }, nl.lineStarts());
}

test "delete is clamped to the document and keeps len correct" {
    var b = try Buffer.init(std.testing.allocator, "abcdef");
    defer b.deinit();

    try b.delete(3, 100); // clamps to the end
    try std.testing.expectEqualStrings("abc", b.flat());
    try std.testing.expectEqual(@as(usize, 3), b.len());

    try b.delete(99, 1); // past the end: no-op
    try std.testing.expectEqualStrings("abc", b.flat());
    try std.testing.expectEqual(@as(usize, 3), b.len());
}

test "piece table matches a reference string under random edits" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    var b = try Buffer.init(allocator, "seed text\nwith lines\n");
    defer b.deinit();
    var model = std.ArrayList(u8).empty;
    defer model.deinit(allocator);
    try model.appendSlice(allocator, "seed text\nwith lines\n");

    var step: usize = 0;
    while (step < 600) : (step += 1) {
        if (model.items.len > 0 and rand.boolean()) {
            const pos = rand.uintLessThan(usize, model.items.len);
            const max_count = @min(@as(usize, 8), model.items.len - pos);
            const count = 1 + rand.uintLessThan(usize, max_count);
            try b.delete(pos, count);
            try model.replaceRange(allocator, pos, count, "");
        } else {
            const pos = rand.uintLessThan(usize, model.items.len + 1);
            const len = 1 + rand.uintLessThan(usize, 6);
            var tmp: [8]u8 = undefined;
            const alphabet = "ab\n xy";
            for (tmp[0..len]) |*c| c.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
            try b.insert(pos, tmp[0..len]);
            try model.insertSlice(allocator, pos, tmp[0..len]);
        }
        try std.testing.expectEqual(model.items.len, b.len());
        try std.testing.expectEqualStrings(model.items, b.flat());
        try expectLineStartsMatch(&b);
    }
}
