//! A one-line text field: the prompt's input and the picker's filter.
//!
//! It is a real (small) editor rather than "append a byte, drop a byte": the
//! cursor moves, by character and by word, and never lands inside a UTF-8
//! sequence or between a character and its combining marks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("core").text;
const event = @import("event.zig");
const screen = @import("screen.zig");

pub const LineEdit = struct {
    allocator: Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Byte offset of the cursor.
    cursor: usize = 0,

    pub fn init(allocator: Allocator) LineEdit {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LineEdit) void {
        self.buf.deinit(self.allocator);
    }

    pub fn value(self: *const LineEdit) []const u8 {
        return self.buf.items;
    }

    /// Replace the contents and put the cursor at the end.
    pub fn set(self: *LineEdit, new: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.allocator, new);
        self.cursor = self.buf.items.len;
    }

    pub fn clear(self: *LineEdit) void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
    }

    /// Insert at the cursor. Line breaks and other control bytes are
    /// dropped: this is one line.
    pub fn insert(self: *LineEdit, bytes: []const u8) !void {
        try self.buf.ensureUnusedCapacity(self.allocator, bytes.len);
        for (bytes) |b| {
            if (b < 0x20 or b == 0x7f) continue;
            self.buf.insertAssumeCapacity(self.cursor, b);
            self.cursor += 1;
        }
    }

    fn remove(self: *LineEdit, start: usize, end: usize) void {
        self.buf.replaceRangeAssumeCapacity(start, end - start, "");
        self.cursor = start;
    }

    /// Apply a key. Returns true when the key was an editing key, whether or
    /// not it changed anything; false means the key is the caller's (Enter,
    /// Esc, Tab, arrows up and down, shortcuts).
    pub fn handleKey(self: *LineEdit, key: event.Key) !bool {
        const line = self.buf.items;
        if (key.isText()) {
            var enc: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(key.cp, &enc) catch return true;
            try self.insert(enc[0..len]);
            return true;
        }
        const word = key.mods.ctrl or key.mods.alt;
        switch (key.special) {
            .left => self.cursor = if (word) text.prevWordStart(line, self.cursor) else text.prevBoundary(line, self.cursor),
            .right => self.cursor = if (word) text.nextWordEnd(line, self.cursor) else text.nextBoundary(line, self.cursor),
            .home => self.cursor = 0,
            .end => self.cursor = line.len,
            .backspace => {
                const start = if (word) text.prevWordStart(line, self.cursor) else text.prevBoundary(line, self.cursor);
                self.remove(start, self.cursor);
            },
            .delete => {
                const end = if (word) text.nextWordEnd(line, self.cursor) else text.nextBoundary(line, self.cursor);
                self.remove(self.cursor, end);
            },
            else => return false,
        }
        return true;
    }

    /// Draw the text in `[x, max_x)` on row `y`, scrolled so the cursor is
    /// visible, with a block cursor.
    pub fn draw(self: *const LineEdit, s: *screen.Screen, x: usize, y: usize, max_x: usize, style: screen.Style) void {
        if (max_x <= x) return;
        const line = self.buf.items;
        const room = max_x - x;
        const cursor_cell = text.cellWidth(line[0..self.cursor], 1);
        // Scroll by whole characters until the cursor's cell fits.
        var start: usize = 0;
        var skipped: usize = 0;
        while (cursor_cell - skipped >= room and start < line.len) {
            const next = text.nextBoundary(line, start);
            skipped += text.cellWidth(line[start..next], 1);
            start = next;
        }
        _ = s.text(x, y, max_x, line[start..], style);
        const cx = x + (cursor_cell - skipped);
        if (cx < max_x) {
            var cell = s.at(cx, y);
            if (cell.cont) cell = .{ .fg = style.fg, .bg = style.bg };
            cell.attr.reverse = true;
            s.put(cx, y, cell);
        }
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const Key = event.Key;

fn typeText(le: *LineEdit, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch unreachable;
        _ = try le.handleKey(Key.char(std.unicode.utf8Decode(s[i..][0..n]) catch unreachable));
        i += n;
    }
}

fn press(le: *LineEdit, spec: []const u8) !bool {
    return le.handleKey(Key.parse(spec).?);
}

test "typing, moving and deleting" {
    var le = LineEdit.init(testing.allocator);
    defer le.deinit();
    try typeText(&le, "helo");
    _ = try press(&le, "left");
    try typeText(&le, "l");
    try testing.expectEqualStrings("hello", le.value());
    _ = try press(&le, "home");
    _ = try press(&le, "delete");
    try testing.expectEqualStrings("ello", le.value());
    _ = try press(&le, "end");
    _ = try press(&le, "backspace");
    try testing.expectEqualStrings("ell", le.value());
    // At the edges nothing happens, and the key is still consumed.
    try testing.expect(try press(&le, "delete"));
    _ = try press(&le, "home");
    try testing.expect(try press(&le, "backspace"));
    try testing.expectEqualStrings("ell", le.value());
}

test "words and multi-byte characters" {
    var le = LineEdit.init(testing.allocator);
    defer le.deinit();
    try typeText(&le, "src/caf\xc3\xa9 \xe4\xb8\xad");
    _ = try press(&le, "backspace"); // the whole CJK character
    try testing.expectEqualStrings("src/caf\xc3\xa9 ", le.value());
    _ = try press(&le, "ctrl+backspace");
    try testing.expectEqualStrings("src/", le.value());
    _ = try press(&le, "ctrl+left");
    _ = try press(&le, "ctrl+left");
    try testing.expectEqual(@as(usize, 0), le.cursor);
    _ = try press(&le, "ctrl+delete");
    try testing.expectEqualStrings("/", le.value());
}

test "keys that are not editing are left to the caller" {
    var le = LineEdit.init(testing.allocator);
    defer le.deinit();
    try testing.expect(!try press(&le, "enter"));
    try testing.expect(!try press(&le, "esc"));
    try testing.expect(!try press(&le, "up"));
    try testing.expect(!try press(&le, "ctrl+s"));
    try testing.expectEqualStrings("", le.value());
}

test "set, clear, and control bytes are dropped on insert" {
    var le = LineEdit.init(testing.allocator);
    defer le.deinit();
    try le.set("abc");
    try testing.expectEqual(@as(usize, 3), le.cursor);
    try le.insert("d\ne\tf");
    try testing.expectEqualStrings("abcdef", le.value());
    le.clear();
    try testing.expectEqualStrings("", le.value());
}

test "draw scrolls to keep the cursor in view" {
    var s = try screen.Screen.init(testing.allocator, 8, 1);
    defer s.deinit();
    var le = LineEdit.init(testing.allocator);
    defer le.deinit();
    var buf: [32]u8 = undefined;

    try le.set("abc");
    le.draw(&s, 2, 0, 8, .{});
    try testing.expectEqualStrings("  abc", s.rowText(0, &buf));
    try testing.expect(s.at(5, 0).attr.reverse); // cursor after the text

    s.clear();
    try le.set("0123456789");
    le.draw(&s, 2, 0, 8, .{});
    // Six cells: the last five characters and the cursor.
    try testing.expectEqualStrings("  56789", s.rowText(0, &buf));
    try testing.expect(s.at(7, 0).attr.reverse);

    s.clear();
    le.cursor = 0;
    le.draw(&s, 2, 0, 8, .{});
    try testing.expectEqualStrings("  012345", s.rowText(0, &buf));
    try testing.expect(s.at(2, 0).attr.reverse);
}
