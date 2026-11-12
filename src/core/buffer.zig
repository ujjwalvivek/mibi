//! Piece-table text buffer.
//!
//! The document is a list of pieces. Each piece is a span of one of two byte
//! stores: `original` (the file as loaded, never modified) or `add`
//! (everything inserted since, append-only). An edit only changes the piece
//! list, so its cost does not depend on the size of the file.
//!
//! Nothing here ever builds a contiguous copy of the document. Because both
//! stores are immutable or append-only, the offset of every newline in each
//! is recorded once and stays valid for the life of the buffer. A piece
//! carries the number of newlines it covers, so:
//!
//!   - `lineStart(row)` walks piece counts, then binary-searches one store's
//!     newline index;
//!   - `lineOf(offset)` does the same in the other direction;
//!   - readers get text through `slice` (zero-copy when the range sits in one
//!     piece) or `chunks` (search, save).
//!
//! Costs: an edit and a lookup are O(pieces). Consecutive typing extends the
//! previous piece, so the piece count follows the number of places edited,
//! not the number of keystrokes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Source = enum(u1) { original, add };

/// A span of one store. `nl` is the number of `\n` bytes inside it.
pub const Piece = struct {
    source: Source,
    start: usize,
    len: usize,
    nl: usize,
};

pub const Buffer = struct {
    allocator: Allocator,
    original: []const u8,
    add: std.ArrayList(u8),
    /// Offsets of every `\n` in `original`, ascending.
    original_nl: []const usize,
    /// Offsets of every `\n` in `add`, ascending; grows with `add`.
    add_nl: std.ArrayList(usize),
    pieces: std.ArrayList(Piece),
    /// Document length in bytes.
    total: usize,
    /// Number of `\n` bytes in the document.
    total_nl: usize,

    /// Takes a copy of `data`.
    pub fn init(allocator: Allocator, data: []const u8) !Buffer {
        const original = try allocator.dupe(u8, data);
        errdefer allocator.free(original);

        const count = std.mem.count(u8, original, "\n");
        const index = try allocator.alloc(usize, count);
        errdefer allocator.free(index);
        var n: usize = 0;
        for (original, 0..) |c, i| {
            if (c == '\n') {
                index[n] = i;
                n += 1;
            }
        }

        var pieces = std.ArrayList(Piece).empty;
        errdefer pieces.deinit(allocator);
        if (original.len > 0) {
            try pieces.append(allocator, .{ .source = .original, .start = 0, .len = original.len, .nl = count });
        }
        return .{
            .allocator = allocator,
            .original = original,
            .add = .empty,
            .original_nl = index,
            .add_nl = .empty,
            .pieces = pieces,
            .total = original.len,
            .total_nl = count,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.original);
        self.allocator.free(self.original_nl);
        self.add.deinit(self.allocator);
        self.add_nl.deinit(self.allocator);
        self.pieces.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: *const Buffer) usize {
        return self.total;
    }

    /// A document always has at least one line; a trailing `\n` starts an
    /// empty last line.
    pub fn lineCount(self: *const Buffer) usize {
        return self.total_nl + 1;
    }

    // --- stores ----------------------------------------------------------

    fn bytes(self: *const Buffer, source: Source) []const u8 {
        return switch (source) {
            .original => self.original,
            .add => self.add.items,
        };
    }

    fn newlines(self: *const Buffer, source: Source) []const usize {
        return switch (source) {
            .original => self.original_nl,
            .add => self.add_nl.items,
        };
    }

    /// Index of the first entry in `index` that is >= `offset`.
    fn lowerBound(index: []const usize, offset: usize) usize {
        var lo: usize = 0;
        var hi: usize = index.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (index[mid] < offset) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Number of newlines in `source[start..end]`.
    fn countNewlines(self: *const Buffer, source: Source, start: usize, end: usize) usize {
        const index = self.newlines(source);
        return lowerBound(index, end) - lowerBound(index, start);
    }

    fn makePiece(self: *const Buffer, source: Source, start: usize, length: usize) Piece {
        return .{
            .source = source,
            .start = start,
            .len = length,
            .nl = self.countNewlines(source, start, start + length),
        };
    }

    fn pieceBytes(self: *const Buffer, p: Piece) []const u8 {
        return self.bytes(p.source)[p.start .. p.start + p.len];
    }

    // --- locating --------------------------------------------------------

    const Location = struct {
        /// Index of the piece, or `pieces.len` at the end of the document.
        index: usize,
        /// Document offset where that piece starts.
        offset: usize,
        /// Newlines before that piece.
        nl: usize,
    };

    /// The piece containing document offset `pos`. An offset on a boundary
    /// belongs to the piece that starts there.
    fn locate(self: *const Buffer, pos: usize) Location {
        var loc = Location{ .index = 0, .offset = 0, .nl = 0 };
        for (self.pieces.items) |p| {
            if (pos < loc.offset + p.len) break;
            loc.offset += p.len;
            loc.nl += p.nl;
            loc.index += 1;
        }
        return loc;
    }

    /// Split the piece under `pos` so that a piece boundary falls exactly at
    /// `pos`, and return the index of the piece that starts there. Needs room
    /// for one more piece.
    fn splitAt(self: *Buffer, pos: usize) usize {
        const loc = self.locate(pos);
        if (loc.index == self.pieces.items.len or loc.offset == pos) return loc.index;
        const p = self.pieces.items[loc.index];
        const head = pos - loc.offset;
        const left = self.makePiece(p.source, p.start, head);
        const right = Piece{ .source = p.source, .start = p.start + head, .len = p.len - head, .nl = p.nl - left.nl };
        self.pieces.insertAssumeCapacity(loc.index + 1, right);
        self.pieces.items[loc.index] = left;
        return loc.index + 1;
    }

    // --- editing ---------------------------------------------------------
    //
    // Every edit is one primitive, `splice`: remove a range and put a run of
    // pieces in its place. It cannot fail once capacity is reserved, which is
    // what lets a multi-part edit (several cursors, undo of a group) be all
    // or nothing: reserve for every part first, then apply.

    /// Copy `text` into the append-only store and return the span that holds
    /// it. The document does not change until the span is spliced in.
    pub fn store(self: *Buffer, text: []const u8) !Piece {
        const start = self.add.items.len;
        const text_nl = std.mem.count(u8, text, "\n");
        try self.add.ensureUnusedCapacity(self.allocator, text.len);
        try self.add_nl.ensureUnusedCapacity(self.allocator, text_nl);
        self.add.appendSliceAssumeCapacity(text);
        for (text, 0..) |c, i| {
            if (c == '\n') self.add_nl.appendAssumeCapacity(start + i);
        }
        return .{ .source = .add, .start = start, .len = text.len, .nl = text_nl };
    }

    /// Room for `splices` calls to `splice` that insert `inserted` pieces in
    /// total.
    pub fn reserve(self: *Buffer, splices: usize, inserted: usize) !void {
        // Each splice splits at most twice.
        try self.pieces.ensureUnusedCapacity(self.allocator, 2 * splices + inserted);
    }

    /// The pieces that make up `[start, end)`, trimmed to the range, appended
    /// to `out`. Read-only: this is how an edit remembers what it removes
    /// without copying the text.
    pub fn spans(self: *const Buffer, start: usize, end: usize, allocator: Allocator, out: *std.ArrayList(Piece)) !void {
        const e = @min(end, self.total);
        const s = @min(start, e);
        if (s == e) return;
        var loc = self.locate(s);
        while (loc.offset < e and loc.index < self.pieces.items.len) {
            const p = self.pieces.items[loc.index];
            const from = if (s > loc.offset) s - loc.offset else 0;
            const to = @min(p.len, e - loc.offset);
            try out.append(allocator, self.makePiece(p.source, p.start + from, to - from));
            loc.offset += p.len;
            loc.index += 1;
        }
    }

    /// Replace `count` bytes at `pos` with `run`. Both are clamped to the
    /// document. Needs capacity from `reserve`; never fails.
    pub fn splice(self: *Buffer, pos: usize, count: usize, run: []const Piece) void {
        const at = @min(pos, self.total);
        const n = @min(count, self.total - at);
        const first = self.splitAt(at);
        const last = self.splitAt(at + n);
        for (self.pieces.items[first..last]) |p| {
            self.total -= p.len;
            self.total_nl -= p.nl;
        }
        for (run) |p| {
            std.debug.assert(p.len > 0);
            self.total += p.len;
            self.total_nl += p.nl;
        }
        self.pieces.replaceRangeAssumeCapacity(first, last - first, run);
        // Heal the seams: neighbours that are contiguous in their store become
        // one piece again. This is what keeps typing in one piece, and what
        // makes undo give back the piece list it started from.
        self.mergeAt(first + run.len);
        self.mergeAt(first);
    }

    /// Merge piece `index` into piece `index - 1` when they are adjacent
    /// spans of the same store.
    fn mergeAt(self: *Buffer, index: usize) void {
        if (index == 0 or index >= self.pieces.items.len) return;
        const prev = &self.pieces.items[index - 1];
        const next = self.pieces.items[index];
        if (prev.source != next.source or prev.start + prev.len != next.start) return;
        prev.len += next.len;
        prev.nl += next.nl;
        _ = self.pieces.orderedRemove(index);
    }

    /// Insert `text` at byte offset `pos` (clamped to the document).
    pub fn insert(self: *Buffer, pos: usize, text: []const u8) !void {
        if (text.len == 0) return;
        try self.reserve(1, 1);
        const piece = try self.store(text);
        self.splice(pos, 0, &.{piece});
    }

    /// Delete `count` bytes starting at `pos` (clamped to the document).
    pub fn delete(self: *Buffer, pos: usize, count: usize) !void {
        if (count == 0 or pos >= self.total) return;
        try self.reserve(1, 0);
        self.splice(pos, count, &.{});
    }

    // --- lines -----------------------------------------------------------

    /// Byte offset where line `row` (0-based) starts. Rows past the end give
    /// the document length.
    pub fn lineStart(self: *const Buffer, row: usize) usize {
        if (row == 0) return 0;
        if (row > self.total_nl) return self.total;
        // The line starts one byte after the `row`-th newline.
        var offset: usize = 0;
        var seen: usize = 0;
        for (self.pieces.items) |p| {
            if (seen + p.nl >= row) {
                const index = self.newlines(p.source);
                const first = lowerBound(index, p.start);
                const at = index[first + (row - seen) - 1];
                return offset + (at - p.start) + 1;
            }
            seen += p.nl;
            offset += p.len;
        }
        unreachable; // total_nl is the sum of the piece counts
    }

    /// Byte offset just past the last byte of line `row`, not counting its
    /// `\n`.
    pub fn lineEnd(self: *const Buffer, row: usize) usize {
        if (row >= self.total_nl) return self.total;
        return self.lineStart(row + 1) - 1;
    }

    /// The 0-based line that contains byte offset `pos`.
    pub fn lineOf(self: *const Buffer, pos: usize) usize {
        const at = @min(pos, self.total);
        const loc = self.locate(at);
        if (loc.index == self.pieces.items.len) return loc.nl;
        const p = self.pieces.items[loc.index];
        return loc.nl + self.countNewlines(p.source, p.start, p.start + (at - loc.offset));
    }

    // --- reading ---------------------------------------------------------

    /// The byte at `pos`, or null past the end.
    pub fn byteAt(self: *const Buffer, pos: usize) ?u8 {
        if (pos >= self.total) return null;
        const loc = self.locate(pos);
        const p = self.pieces.items[loc.index];
        return self.bytes(p.source)[p.start + (pos - loc.offset)];
    }

    /// Iterates the document as contiguous chunks, starting at `from`.
    pub const Chunks = struct {
        buffer: *const Buffer,
        index: usize,
        /// Bytes to skip in the first chunk.
        skip: usize,
        /// Bytes still to hand out.
        remaining: usize,

        pub fn next(self: *Chunks) ?[]const u8 {
            while (self.remaining > 0 and self.index < self.buffer.pieces.items.len) {
                const all = self.buffer.pieceBytes(self.buffer.pieces.items[self.index]);
                self.index += 1;
                const rest = all[self.skip..];
                self.skip = 0;
                if (rest.len == 0) continue;
                const out = rest[0..@min(rest.len, self.remaining)];
                self.remaining -= out.len;
                return out;
            }
            return null;
        }
    };

    /// Chunks covering `[start, end)`, both clamped to the document.
    pub fn chunks(self: *const Buffer, start: usize, end: usize) Chunks {
        const e = @min(end, self.total);
        const s = @min(start, e);
        const loc = self.locate(s);
        return .{ .buffer = self, .index = loc.index, .skip = s - loc.offset, .remaining = e - s };
    }

    /// The text in `[start, end)`. When the range lies inside one piece the
    /// result points straight into the store and `scratch` is untouched;
    /// otherwise the range is assembled in `scratch`. Either way the slice is
    /// only valid until the next edit or the next use of `scratch`.
    pub fn slice(self: *const Buffer, start: usize, end: usize, scratch: *std.ArrayList(u8)) ![]const u8 {
        var it = self.chunks(start, end);
        const first = it.next() orelse return "";
        if (it.remaining == 0) return first;
        scratch.clearRetainingCapacity();
        try scratch.ensureTotalCapacity(self.allocator, first.len + it.remaining);
        scratch.appendSliceAssumeCapacity(first);
        while (it.next()) |chunk| scratch.appendSliceAssumeCapacity(chunk);
        return scratch.items;
    }

    /// Line `row` without its `\n`; see `slice` for the lifetime.
    pub fn line(self: *const Buffer, row: usize, scratch: *std.ArrayList(u8)) ![]const u8 {
        return self.slice(self.lineStart(row), self.lineEnd(row), scratch);
    }

    /// A newly allocated copy of the whole document.
    pub fn toOwned(self: *const Buffer, allocator: Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.total);
        var at: usize = 0;
        var it = self.chunks(0, self.total);
        while (it.next()) |chunk| {
            @memcpy(out[at..][0..chunk.len], chunk);
            at += chunk.len;
        }
        return out;
    }
};

// --- tests ---------------------------------------------------------------

const testing = std.testing;

fn expectText(b: *const Buffer, want: []const u8) !void {
    const got = try b.toOwned(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
    try testing.expectEqual(want.len, b.len());
}

test "insert and delete" {
    var b = try Buffer.init(testing.allocator, "hello world");
    defer b.deinit();

    try b.insert(5, ",");
    try expectText(&b, "hello, world");
    try b.insert(0, ">> ");
    try expectText(&b, ">> hello, world");
    try b.delete(0, 3);
    try expectText(&b, "hello, world");
    try b.delete(5, 1);
    try expectText(&b, "hello world");
    try b.insert(b.len(), "!");
    try expectText(&b, "hello world!");
    try b.insert(999, "?"); // clamped to the end
    try expectText(&b, "hello world!?");
    try b.delete(11, 999); // clamped to the end
    try expectText(&b, "hello world");
    try b.delete(0, b.len());
    try expectText(&b, "");
    try testing.expectEqual(@as(usize, 1), b.lineCount());
}

test "an empty buffer has one empty line" {
    var b = try Buffer.init(testing.allocator, "");
    defer b.deinit();
    try testing.expectEqual(@as(usize, 1), b.lineCount());
    try testing.expectEqual(@as(usize, 0), b.lineStart(0));
    try testing.expectEqual(@as(usize, 0), b.lineEnd(0));
    try testing.expectEqual(@as(usize, 0), b.lineOf(0));
    try testing.expectEqual(@as(?u8, null), b.byteAt(0));
}

test "lines across pieces" {
    var b = try Buffer.init(testing.allocator, "one\ntwo\nthree");
    defer b.deinit();
    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), b.lineCount());
    try testing.expectEqualStrings("two", try b.line(1, &scratch));

    try b.insert(5, "\nX\n"); // one, t / X / wo, three
    try expectText(&b, "one\nt\nX\nwo\nthree");
    try testing.expectEqual(@as(usize, 5), b.lineCount());
    try testing.expectEqualStrings("t", try b.line(1, &scratch));
    try testing.expectEqualStrings("X", try b.line(2, &scratch));
    try testing.expectEqualStrings("wo", try b.line(3, &scratch));
    try testing.expectEqualStrings("three", try b.line(4, &scratch));
    try testing.expectEqual(@as(usize, 2), b.lineOf(6));
    try testing.expectEqual(@as(usize, 2), b.lineOf(7)); // the newline belongs to its line
    try testing.expectEqual(@as(usize, 3), b.lineOf(8));
    try testing.expectEqual(b.len(), b.lineStart(99));

    try b.delete(3, 1); // join the first two lines
    try testing.expectEqualStrings("onet", try b.line(0, &scratch));
    try testing.expectEqual(@as(usize, 4), b.lineCount());
}

test "a trailing newline starts an empty last line" {
    var b = try Buffer.init(testing.allocator, "a\n");
    defer b.deinit();
    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), b.lineCount());
    try testing.expectEqual(@as(usize, 2), b.lineStart(1));
    try testing.expectEqualStrings("", try b.line(1, &scratch));
}

test "typing extends one piece" {
    var b = try Buffer.init(testing.allocator, "ab");
    defer b.deinit();
    for ("hello\nthere", 0..) |c, i| try b.insert(1 + i, &.{c});
    try expectText(&b, "ahello\nthereb");
    try testing.expectEqual(@as(usize, 3), b.pieces.items.len);
    try testing.expectEqual(@as(usize, 2), b.lineCount());

    // An insert somewhere else starts a new piece; so does coming back.
    try b.insert(0, "X");
    try b.insert(8, "Y");
    try expectText(&b, "Xahello\nYthereb");
}

test "slice is zero-copy inside one piece" {
    var b = try Buffer.init(testing.allocator, "0123456789");
    defer b.deinit();
    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(testing.allocator);

    const inside = try b.slice(2, 5, &scratch);
    try testing.expectEqualStrings("234", inside);
    try testing.expect(inside.ptr == b.original.ptr + 2);
    try testing.expectEqual(@as(usize, 0), scratch.items.len);

    try b.insert(4, "ab");
    try testing.expectEqualStrings("23ab45", try b.slice(2, 8, &scratch));
    try testing.expectEqualStrings("", try b.slice(7, 3, &scratch)); // empty when reversed
    try testing.expectEqualStrings("89", try b.slice(10, 99, &scratch));
}

test "chunks cover a range exactly" {
    var b = try Buffer.init(testing.allocator, "abcdef");
    defer b.deinit();
    try b.insert(3, "XYZ");
    try b.insert(0, "<");
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    var it = b.chunks(2, 8);
    while (it.next()) |chunk| try out.appendSlice(testing.allocator, chunk);
    try testing.expectEqualStrings("bcXYZd", out.items);
}

test "splice puts back exactly what spans took out" {
    var b = try Buffer.init(testing.allocator, "one\ntwo\nthree");
    defer b.deinit();
    try b.insert(4, "X");
    try b.insert(9, "Y\n");
    try expectText(&b, "one\nXtwo\nY\nthree");
    const before = try testing.allocator.dupe(Piece, b.pieces.items);
    defer testing.allocator.free(before);

    var removed = std.ArrayList(Piece).empty;
    defer removed.deinit(testing.allocator);
    try b.spans(5, 5, testing.allocator, &removed); // an empty range has no pieces
    try testing.expectEqual(@as(usize, 0), removed.items.len);
    try b.spans(2, 11, testing.allocator, &removed);
    try b.reserve(2, removed.items.len);
    b.splice(2, 9, &.{});
    try expectText(&b, "onthree");
    try testing.expectEqual(@as(usize, 1), b.lineCount());
    b.splice(2, 0, removed.items);
    try expectText(&b, "one\nXtwo\nY\nthree");
    // Not just the same text: the same pieces, so repeated undo and redo
    // cannot fragment the list.
    try testing.expectEqualSlices(Piece, before, b.pieces.items);
}

// The buffer against a plain byte array: every operation is applied to
// both, and everything the buffer can report is compared after each step.
test "fuzz against a reference" {
    const alphabet = "ab\n \nxyz\n";
    var seed: u64 = 1;
    while (seed <= 24) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const rnd = prng.random();

        var ref = std.ArrayList(u8).empty;
        defer ref.deinit(testing.allocator);
        // Start from a file of random size, sometimes empty.
        const initial = rnd.uintLessThan(usize, 60);
        for (0..initial) |_| try ref.append(testing.allocator, alphabet[rnd.uintLessThan(usize, alphabet.len)]);

        var b = try Buffer.init(testing.allocator, ref.items);
        defer b.deinit();
        var scratch = std.ArrayList(u8).empty;
        defer scratch.deinit(testing.allocator);

        var step: usize = 0;
        while (step < 400) : (step += 1) {
            const roll = rnd.uintLessThan(u8, 10);
            if (roll < 6) {
                var text: [12]u8 = undefined;
                const n = rnd.uintLessThan(usize, text.len + 1);
                for (text[0..n]) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
                // Bias towards continuing at the same place, like typing.
                const pos = rnd.uintLessThan(usize, ref.items.len + 2);
                try b.insert(pos, text[0..n]);
                try ref.insertSlice(testing.allocator, @min(pos, ref.items.len), text[0..n]);
            } else {
                const pos = rnd.uintLessThan(usize, ref.items.len + 2);
                const count = rnd.uintLessThan(usize, 20);
                try b.delete(pos, count);
                if (pos < ref.items.len) {
                    const n = @min(count, ref.items.len - pos);
                    ref.replaceRangeAssumeCapacity(pos, n, &.{});
                }
            }
            try checkAgainst(&b, ref.items, rnd, &scratch);
        }
    }
}

fn checkAgainst(b: *const Buffer, ref: []const u8, rnd: std.Random, scratch: *std.ArrayList(u8)) !void {
    try expectText(b, ref);

    // Line index: every line start and end, from the reference text.
    var row: usize = 0;
    var start: usize = 0;
    for (ref, 0..) |c, i| {
        if (c != '\n') continue;
        try testing.expectEqual(start, b.lineStart(row));
        try testing.expectEqual(i, b.lineEnd(row));
        try testing.expectEqualStrings(ref[start..i], try b.line(row, scratch));
        row += 1;
        start = i + 1;
    }
    try testing.expectEqual(start, b.lineStart(row));
    try testing.expectEqual(ref.len, b.lineEnd(row));
    try testing.expectEqual(row + 1, b.lineCount());

    // Spot checks: offset to line, single bytes, arbitrary ranges.
    for (0..4) |_| {
        const pos = rnd.uintLessThan(usize, ref.len + 1);
        try testing.expectEqual(std.mem.count(u8, ref[0..pos], "\n"), b.lineOf(pos));
        try testing.expectEqual(if (pos < ref.len) @as(?u8, ref[pos]) else null, b.byteAt(pos));
        const end = pos + rnd.uintLessThan(usize, ref.len - pos + 1);
        try testing.expectEqualStrings(ref[pos..end], try b.slice(pos, end, scratch));
    }

    // No empty pieces, and the cached totals match the list.
    var total: usize = 0;
    var total_nl: usize = 0;
    for (b.pieces.items) |p| {
        try testing.expect(p.len > 0);
        try testing.expectEqual(std.mem.count(u8, b.pieceBytes(p), "\n"), p.nl);
        total += p.len;
        total_nl += p.nl;
    }
    try testing.expectEqual(total, b.total);
    try testing.expectEqual(total_nl, b.total_nl);
}

test "allocation failure leaves the buffer intact" {
    // Every allocation point in insert and delete is made to fail in turn;
    // whatever happens, the buffer must still equal one of the two states.
    const Check = struct {
        fn run(allocator: Allocator) !void {
            var b = try Buffer.init(allocator, "one\ntwo\nthree");
            defer b.deinit();
            b.insert(5, "X\nY") catch |e| {
                try expectStill(&b, "one\ntwo\nthree");
                return e;
            };
            b.delete(2, 6) catch |e| {
                try expectStill(&b, "one\ntX\nYwo\nthree");
                return e;
            };
            try expectStill(&b, "onwo\nthree");
        }
        fn expectStill(b: *const Buffer, want: []const u8) !void {
            var at: usize = 0;
            var it = b.chunks(0, b.len());
            while (it.next()) |chunk| {
                try testing.expectEqualStrings(want[at..][0..chunk.len], chunk);
                at += chunk.len;
            }
            try testing.expectEqual(want.len, at);
            try testing.expectEqual(std.mem.count(u8, want, "\n") + 1, b.lineCount());
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{});
}
