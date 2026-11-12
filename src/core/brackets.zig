//! Bracket pairs: `()`, `[]`, `{}`.
//!
//! Matching counts brackets of the same kind and nothing else. It does not
//! know about strings or comments, so a bracket inside a string counts; that
//! is wrong now and then and never slow. The search stops after `reach`
//! bytes: it runs for every frame drawn, and a pair further apart than that
//! is not on screen together anyway.

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;

/// How far from the bracket its partner is looked for, in bytes.
pub const reach: usize = 64 * 1024;

pub const Pair = struct {
    /// Offset of the bracket the search started from.
    from: usize,
    /// Offset of its partner.
    to: usize,
};

const Kind = struct { open: u8, close: u8, forward: bool };

fn kindOf(b: u8) ?Kind {
    return switch (b) {
        '(' => .{ .open = '(', .close = ')', .forward = true },
        '[' => .{ .open = '[', .close = ']', .forward = true },
        '{' => .{ .open = '{', .close = '}', .forward = true },
        ')' => .{ .open = '(', .close = ')', .forward = false },
        ']' => .{ .open = '[', .close = ']', .forward = false },
        '}' => .{ .open = '{', .close = '}', .forward = false },
        else => null,
    };
}

/// The partner of the bracket at `pos`, if `pos` holds a bracket and its
/// partner is within reach.
pub fn partner(buf: *const Buffer, pos: usize, scratch: *std.ArrayList(u8), allocator: std.mem.Allocator) ?usize {
    const kind = kindOf(buf.byteAt(pos) orelse return null) orelse return null;
    var depth: usize = 0;
    if (kind.forward) {
        var at = pos + 1;
        var chunks = buf.chunks(at, @min(buf.len(), at + reach));
        while (chunks.next()) |chunk| {
            for (chunk) |b| {
                if (b == kind.open) {
                    depth += 1;
                } else if (b == kind.close) {
                    if (depth == 0) return at;
                    depth -= 1;
                }
                at += 1;
            }
        }
        return null;
    }
    // Backward: the pieces only run forward, so read the window first. Out
    // of memory means no highlight, nothing worse.
    const start = pos -| reach;
    scratch.clearRetainingCapacity();
    scratch.ensureTotalCapacity(allocator, pos - start) catch return null;
    var chunks = buf.chunks(start, pos);
    while (chunks.next()) |chunk| scratch.appendSliceAssumeCapacity(chunk);
    var i = scratch.items.len;
    while (i > 0) {
        i -= 1;
        const b = scratch.items[i];
        if (b == kind.close) {
            depth += 1;
        } else if (b == kind.open) {
            if (depth == 0) return start + i;
            depth -= 1;
        }
    }
    return null;
}

/// The pair a caret at `caret` is touching: the bracket under it, or else
/// the one just before it.
pub fn around(buf: *const Buffer, caret: usize, scratch: *std.ArrayList(u8), allocator: std.mem.Allocator) ?Pair {
    if (partner(buf, caret, scratch, allocator)) |to| return .{ .from = caret, .to = to };
    if (caret == 0) return null;
    if (partner(buf, caret - 1, scratch, allocator)) |to| return .{ .from = caret - 1, .to = to };
    return null;
}

const testing = std.testing;

fn expectPartner(text: []const u8, pos: usize, want: ?usize) !void {
    var buf = try Buffer.init(testing.allocator, text);
    defer buf.deinit();
    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(testing.allocator);
    try testing.expectEqual(want, partner(&buf, pos, &scratch, testing.allocator));
}

test "partners are found in both directions, through nesting and other kinds" {
    const text = "f(a[1], {b(2)}) ]";
    try expectPartner(text, 1, 14);
    try expectPartner(text, 14, 1);
    try expectPartner(text, 3, 5);
    try expectPartner(text, 8, 13);
    try expectPartner(text, 13, 8);
    try expectPartner(text, 10, 12);
    try expectPartner(text, 0, null); // not a bracket
    try expectPartner(text, 16, null); // nothing opens it
    try expectPartner("((", 0, null);
    try expectPartner("", 0, null);
}

test "around prefers the bracket under the caret, then the one before it" {
    var buf = try Buffer.init(testing.allocator, "(ab)(c)");
    defer buf.deinit();
    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(testing.allocator);
    const a = testing.allocator;
    try testing.expectEqual(Pair{ .from = 0, .to = 3 }, around(&buf, 0, &scratch, a).?);
    try testing.expectEqual(Pair{ .from = 0, .to = 3 }, around(&buf, 1, &scratch, a).?); // just after "("
    try testing.expectEqual(Pair{ .from = 4, .to = 6 }, around(&buf, 4, &scratch, a).?); // under, not before
    try testing.expectEqual(Pair{ .from = 6, .to = 4 }, around(&buf, 7, &scratch, a).?); // before, at the end
    try testing.expectEqual(@as(?Pair, null), around(&buf, 2, &scratch, a));
}

test "a pair spread over edited pieces is still found, and the search gives up past its reach" {
    var buf = try Buffer.init(testing.allocator, "()");
    defer buf.deinit();
    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(testing.allocator);
    try buf.insert(1, "x");
    try buf.insert(2, "[y]");
    try testing.expectEqual(@as(?usize, 5), partner(&buf, 0, &scratch, testing.allocator));
    try testing.expectEqual(@as(?usize, 0), partner(&buf, 5, &scratch, testing.allocator));

    const filler = try testing.allocator.alloc(u8, reach + 10);
    defer testing.allocator.free(filler);
    @memset(filler, '.');
    try buf.insert(1, filler);
    try testing.expectEqual(@as(?usize, null), partner(&buf, 0, &scratch, testing.allocator));
    try testing.expectEqual(@as(?usize, null), partner(&buf, buf.len() - 1, &scratch, testing.allocator));
}
