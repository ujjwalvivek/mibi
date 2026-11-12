//! Minimal INI reader for `syntax.d/*.ini` and the config file.
//!
//! Flat `key = value` lines, optional `[section]` headers, and `;`/`#` comment
//! lines. Values are taken verbatim (trimmed), so a value may contain `#`
//! (Python's comment marker) without being cut. Inline comments are not
//! stripped for the same reason.

const std = @import("std");

pub const Entry = struct {
    section: []const u8,
    key: []const u8,
    value: []const u8,
};

pub const Reader = struct {
    text: []const u8,
    pos: usize = 0,
    section: []const u8 = "",

    pub fn next(self: *Reader) ?Entry {
        while (self.pos < self.text.len) {
            const start = self.pos;
            var end = start;
            while (end < self.text.len and self.text[end] != '\n') end += 1;
            self.pos = if (end < self.text.len) end + 1 else end;

            const raw = std.mem.trim(u8, self.text[start..end], " \t\r");
            if (raw.len == 0 or raw[0] == ';' or raw[0] == '#') continue;
            if (raw[0] == '[') {
                if (std.mem.lastIndexOfScalar(u8, raw, ']')) |close| {
                    self.section = std.mem.trim(u8, raw[1..close], " \t");
                }
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, raw, '=') orelse continue;
            const key = std.mem.trim(u8, raw[0..eq], " \t");
            const value = std.mem.trim(u8, raw[eq + 1 ..], " \t");
            if (key.len == 0) continue;
            return .{ .section = self.section, .key = key, .value = value };
        }
        return null;
    }
};

/// Split a comma-separated list, trimming each item and dropping empties.
pub fn splitList(allocator: std.mem.Allocator, value: []const u8) ![][]u8 {
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const item = std.mem.trim(u8, part, " \t");
        if (item.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, item));
    }
    return out.toOwnedSlice(allocator);
}

test "reads keys, values, comments and sections" {
    const text =
        \\; a comment
        \\# another
        \\name=Zig
        \\extensions = zig, zir
        \\singleline_comment_start=//
        \\singleline_string_quotes=", '
        \\
        \\[theme]
        \\comment = #6a7382
    ;
    var r = Reader{ .text = text };
    const a = r.next().?;
    try std.testing.expectEqualStrings("name", a.key);
    try std.testing.expectEqualStrings("Zig", a.value);
    try std.testing.expectEqualStrings("", a.section);

    const b = r.next().?;
    try std.testing.expectEqualStrings("extensions", b.key);
    try std.testing.expectEqualStrings("zig, zir", b.value);

    const c = r.next().?;
    try std.testing.expectEqualStrings("//", c.value);

    const d = r.next().?;
    try std.testing.expectEqualStrings("\", '", d.value);

    const e = r.next().?;
    try std.testing.expectEqualStrings("theme", e.section);
    try std.testing.expectEqualStrings("comment", e.key);
    try std.testing.expectEqualStrings("#6a7382", e.value); // '#' kept in the value
    try std.testing.expect(r.next() == null);
}

test "splitList trims and drops empty items" {
    const items = try splitList(std.testing.allocator, " a , b,,c ");
    defer {
        for (items) |i| std.testing.allocator.free(i);
        std.testing.allocator.free(items);
    }
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("a", items[0]);
    try std.testing.expectEqualStrings("b", items[1]);
    try std.testing.expectEqualStrings("c", items[2]);
}
