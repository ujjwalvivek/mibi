//! A filterable list: the file picker, the theme picker and the command
//! palette are all this, with different items.
//!
//! The picker owns its items and the filter text and reports what a key did;
//! what "accept" means (open the file, apply the theme, run the command) is
//! the app's business.

const std = @import("std");
const Allocator = std.mem.Allocator;
const event = @import("event.zig");
const screen = @import("screen.zig");
const Theme = @import("theme.zig").Theme;
const LineEdit = @import("line_edit.zig").LineEdit;

pub const Item = struct {
    text: []u8,
    /// Shown dimmed at the right edge: the key bound to a command.
    detail: []u8 = &.{},
    is_dir: bool = false,
    /// Whatever the owner needs to find the thing again (a command's index).
    tag: u32 = 0,
};

/// What a key press did to the picker.
pub const Outcome = enum {
    /// Not a picker key.
    ignored,
    /// The filter text changed.
    filtered,
    /// The highlighted item changed.
    moved,
    accept,
    cancel,
};

pub const Picker = struct {
    allocator: Allocator,
    items: std.ArrayList(Item) = .empty,
    /// Indices into `items` that match the filter, best first.
    filtered: std.ArrayList(u32) = .empty,
    filter: LineEdit,
    selected: usize = 0,
    scroll: usize = 0,
    /// Where the list was last drawn, for clicks.
    list_rect: screen.Rect = .{},

    pub fn init(allocator: Allocator) Picker {
        return .{ .allocator = allocator, .filter = LineEdit.init(allocator) };
    }

    pub fn deinit(self: *Picker) void {
        self.clear();
        self.items.deinit(self.allocator);
        self.filtered.deinit(self.allocator);
        self.filter.deinit();
    }

    /// Drop every item and the filter text.
    pub fn clear(self: *Picker) void {
        for (self.items.items) |item| {
            self.allocator.free(item.text);
            self.allocator.free(item.detail);
        }
        self.items.clearRetainingCapacity();
        self.filtered.clearRetainingCapacity();
        self.filter.clear();
        self.selected = 0;
        self.scroll = 0;
    }

    pub fn add(self: *Picker, item: struct { text: []const u8, detail: []const u8 = "", is_dir: bool = false, tag: u32 = 0 }) !void {
        try self.items.ensureUnusedCapacity(self.allocator, 1);
        const text = try self.allocator.dupe(u8, item.text);
        errdefer self.allocator.free(text);
        const detail = try self.allocator.dupe(u8, item.detail);
        self.items.appendAssumeCapacity(.{ .text = text, .detail = detail, .is_dir = item.is_dir, .tag = item.tag });
    }

    /// Recompute the matches. Items that contain the filter as written come
    /// before items that only contain its letters in order; within each group
    /// the list order is kept.
    pub fn refilter(self: *Picker) !void {
        self.filtered.clearRetainingCapacity();
        const query = self.filter.value();
        try self.filtered.ensureTotalCapacity(self.allocator, self.items.items.len);
        for ([_]bool{ true, false }) |want_substring| {
            for (self.items.items, 0..) |item, i| {
                if (!fuzzyMatch(query, item.text)) continue;
                const substring = query.len == 0 or std.ascii.indexOfIgnoreCase(item.text, query) != null;
                if (substring == want_substring) self.filtered.appendAssumeCapacity(@intCast(i));
            }
        }
        self.selected = 0;
        self.scroll = 0;
    }

    pub fn count(self: *const Picker) usize {
        return self.filtered.items.len;
    }

    /// Move the highlight by `delta`, wrapping around.
    pub fn move(self: *Picker, delta: isize) void {
        const n = self.filtered.items.len;
        if (n == 0) return;
        const i: isize = @as(isize, @intCast(self.selected)) + delta;
        self.selected = @intCast(@mod(i, @as(isize, @intCast(n))));
    }

    pub fn selectedItem(self: *const Picker) ?*const Item {
        if (self.selected >= self.filtered.items.len) return null;
        return &self.items.items[self.filtered.items[self.selected]];
    }

    /// Highlight the item called `name`, if it is in the list.
    pub fn selectByName(self: *Picker, name: []const u8) void {
        for (self.filtered.items, 0..) |index, at| {
            if (std.mem.eql(u8, self.items.items[index].text, name)) {
                self.selected = at;
                return;
            }
        }
    }

    pub fn handleKey(self: *Picker, key: event.Key) !Outcome {
        if (key.mods.none()) {
            switch (key.special) {
                .enter => return .accept,
                .esc => return .cancel,
                .up => return self.step(-1),
                .down => return self.step(1),
                .page_up => return self.step(-@as(isize, @intCast(@max(self.list_rect.h, 1)))),
                .page_down => return self.step(@intCast(@max(self.list_rect.h, 1))),
                else => {},
            }
        }
        if (key.eql(event.Key.ctrl('p'))) return self.step(-1);
        if (key.eql(event.Key.ctrl('n'))) return self.step(1);
        const before = self.filter.value().len;
        const cursor = self.filter.cursor;
        if (!try self.filter.handleKey(key)) return .ignored;
        if (self.filter.value().len == before and self.filter.cursor != cursor) return .moved;
        try self.refilter();
        return .filtered;
    }

    fn step(self: *Picker, delta: isize) Outcome {
        if (@abs(delta) > 1) {
            // Paging stops at the ends instead of wrapping.
            const n: isize = @intCast(self.filtered.items.len);
            if (n == 0) return .moved;
            const to = std.math.clamp(@as(isize, @intCast(self.selected)) + delta, 0, n - 1);
            self.selected = @intCast(to);
        } else {
            self.move(delta);
        }
        return .moved;
    }

    /// A click at a screen cell: the first click highlights a row, a click on
    /// the highlighted row accepts it.
    pub fn handleClick(self: *Picker, x: usize, y: usize) Outcome {
        if (!self.list_rect.contains(x, y)) return .ignored;
        const index = self.scroll + (y - self.list_rect.y);
        if (index >= self.filtered.items.len) return .ignored;
        if (index == self.selected) return .accept;
        self.selected = index;
        return .moved;
    }

    pub fn scrollBy(self: *Picker, delta: isize) void {
        const n = self.filtered.items.len;
        const rows = self.list_rect.h;
        const max: isize = if (n > rows) @intCast(n - rows) else 0;
        self.scroll = @intCast(std.math.clamp(@as(isize, @intCast(self.scroll)) + delta, 0, max));
        // Keep the highlight on screen so the next key starts from what is
        // visible.
        if (rows > 0) self.selected = std.math.clamp(self.selected, self.scroll, self.scroll + rows - 1);
        if (n > 0) self.selected = @min(self.selected, n - 1);
    }

    /// Draw over `area`: a title row, the list, and the filter line at the
    /// bottom.
    pub fn draw(self: *Picker, s: *screen.Screen, area: screen.Rect, title: []const u8, theme: *const Theme) void {
        self.list_rect = .{};
        if (area.h < 4 or area.w < 24) return;
        s.fill(area, .{ .bg = theme.background });

        const right = area.right();
        var head_buf: [256]u8 = undefined;
        const head = std.fmt.bufPrint(&head_buf, " {s} ({d}/{d})", .{ title, self.count(), self.items.items.len }) catch title;
        _ = s.text(area.x + 1, area.y, right, head, .{ .fg = theme.accent, .bg = theme.background, .attr = .{ .bold = true } });

        const list = screen.Rect{ .x = area.x + 1, .y = area.y + 1, .w = area.w - 2, .h = area.h - 2 };
        self.list_rect = list;
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + list.h) self.scroll = self.selected + 1 - list.h;

        var row: usize = 0;
        while (row < list.h and self.scroll + row < self.filtered.items.len) : (row += 1) {
            const item = self.items.items[self.filtered.items[self.scroll + row]];
            const selected = self.scroll + row == self.selected;
            const bg = if (selected) theme.selection else theme.background;
            const fg = if (!selected and item.is_dir) theme.keyword2 else theme.text;
            const y = list.y + row;
            if (selected) s.fill(.{ .x = list.x, .y = y, .w = list.w, .h = 1 }, .{ .bg = bg });
            const style = screen.Style{ .fg = fg, .bg = bg, .attr = .{ .bold = selected } };
            var x = s.text(list.x + 1, y, list.right(), item.text, style);
            if (item.is_dir) x = s.text(x, y, list.right(), "/", style);
            if (item.detail.len > 0 and x + item.detail.len + 3 < list.right()) {
                _ = s.text(list.right() - item.detail.len - 1, y, list.right(), item.detail, .{ .fg = theme.hint_fg, .bg = bg });
            }
        }

        const y = area.bottom() - 1;
        const bar = screen.Style{ .fg = theme.text, .bg = theme.bar_bg };
        s.fill(.{ .x = area.x, .y = y, .w = area.w, .h = 1 }, bar);
        const hint = "Enter select  Esc cancel";
        const hint_x = if (area.w > hint.len + 24) right - hint.len - 1 else right;
        const x = s.text(area.x + 1, y, right, " > ", .{ .fg = theme.accent, .bg = theme.bar_bg });
        self.filter.draw(s, x, y, if (hint_x < right) hint_x - 1 else right, bar);
        if (hint_x < right) _ = s.text(hint_x, y, right, hint, .{ .fg = theme.hint_fg, .bg = theme.bar_bg });
    }
};

/// Case-insensitive subsequence match (fzf-style): the query characters must
/// appear in order somewhere in the text.
pub fn fuzzyMatch(query: []const u8, text: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (text) |c| {
        if (std.ascii.toLower(c) == std.ascii.toLower(query[qi])) {
            qi += 1;
            if (qi == query.len) return true;
        }
    }
    return false;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const Key = event.Key;

fn press(p: *Picker, spec: []const u8) !Outcome {
    return p.handleKey(Key.parse(spec).?);
}

fn sample() !Picker {
    var p = Picker.init(testing.allocator);
    errdefer p.deinit();
    try p.add(.{ .text = "alpha.zig" });
    try p.add(.{ .text = "beta.zig" });
    try p.add(.{ .text = "src", .is_dir = true });
    try p.add(.{ .text = "zebra.txt" });
    try p.refilter();
    return p;
}

test "fuzzyMatch is a case-insensitive subsequence match" {
    try testing.expect(fuzzyMatch("", "anything"));
    try testing.expect(fuzzyMatch("src", "src/main.zig"));
    try testing.expect(fuzzyMatch("smz", "src/main.zig"));
    try testing.expect(fuzzyMatch("SRC", "src/main.zig"));
    try testing.expect(!fuzzyMatch("xyz", "src/main.zig"));
    try testing.expect(!fuzzyMatch("mainsrc", "src/main.zig")); // order matters
}

test "typing filters, and exact matches come first" {
    var p = try sample();
    defer p.deinit();
    try testing.expectEqual(@as(usize, 4), p.count());

    try testing.expectEqual(Outcome.filtered, try press(&p, "z"));
    // Three names contain a z; the list order is kept.
    try testing.expectEqual(@as(usize, 3), p.count());
    try testing.expectEqualStrings("alpha.zig", p.selectedItem().?.text);

    try testing.expectEqual(Outcome.filtered, try press(&p, "e"));
    // In beta.zig the e comes before the z, so "ze" does not match it.
    try testing.expectEqual(@as(usize, 1), p.count());
    try testing.expectEqualStrings("zebra.txt", p.selectedItem().?.text);

    try testing.expectEqual(Outcome.filtered, try press(&p, "backspace"));
    try testing.expectEqual(Outcome.filtered, try press(&p, "backspace"));
    try testing.expectEqual(@as(usize, 4), p.count());

    p.filter.clear();
    try p.filter.set("a.z");
    try p.refilter();
    try testing.expectEqual(@as(usize, 2), p.count());
    try testing.expectEqualStrings("alpha.zig", p.selectedItem().?.text);
}

test "a substring match is listed before a scattered match" {
    var p = Picker.init(testing.allocator);
    defer p.deinit();
    try p.add(.{ .text = "s_e_t.txt" });
    try p.add(.{ .text = "settings.ini" });
    try p.filter.set("set");
    try p.refilter();
    try testing.expectEqual(@as(usize, 2), p.count());
    try testing.expectEqualStrings("settings.ini", p.selectedItem().?.text);
}

test "arrows wrap, enter accepts, esc cancels" {
    var p = try sample();
    defer p.deinit();
    try testing.expectEqual(Outcome.moved, try press(&p, "up"));
    try testing.expectEqualStrings("zebra.txt", p.selectedItem().?.text);
    try testing.expectEqual(Outcome.moved, try press(&p, "down"));
    try testing.expectEqualStrings("alpha.zig", p.selectedItem().?.text);
    try testing.expectEqual(Outcome.moved, try press(&p, "ctrl+n"));
    try testing.expectEqualStrings("beta.zig", p.selectedItem().?.text);
    try testing.expectEqual(Outcome.accept, try press(&p, "enter"));
    try testing.expectEqual(Outcome.cancel, try press(&p, "esc"));
    try testing.expectEqual(Outcome.ignored, try press(&p, "f5"));
}

test "selectByName and an empty result" {
    var p = try sample();
    defer p.deinit();
    p.selectByName("src");
    try testing.expectEqualStrings("src", p.selectedItem().?.text);
    p.selectByName("missing");
    try testing.expectEqualStrings("src", p.selectedItem().?.text);
    try p.filter.set("qqq");
    try p.refilter();
    try testing.expect(p.selectedItem() == null);
    try testing.expectEqual(Outcome.moved, try press(&p, "down")); // nothing to move to, no crash
}

test "draw shows the title, items, details and filter; clicks select then accept" {
    var s = try screen.Screen.init(testing.allocator, 40, 8);
    defer s.deinit();
    var p = Picker.init(testing.allocator);
    defer p.deinit();
    try p.add(.{ .text = "Save", .detail = "ctrl+s" });
    try p.add(.{ .text = "docs", .is_dir = true });
    try p.refilter();
    _ = try press(&p, "s");
    const theme = Theme{};
    p.draw(&s, s.area(), "Commands", &theme);

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("  Commands (2/2)", s.rowText(0, &buf));
    try testing.expect(std.mem.startsWith(u8, s.rowText(1, &buf), "  Save"));
    try testing.expect(std.mem.endsWith(u8, s.rowText(1, &buf), "ctrl+s"));
    try testing.expectEqualStrings("  docs/", s.rowText(2, &buf));
    try testing.expect(std.mem.startsWith(u8, s.rowText(7, &buf), "  > s"));

    try testing.expectEqual(Outcome.moved, p.handleClick(5, 2));
    try testing.expectEqualStrings("docs", p.selectedItem().?.text);
    try testing.expectEqual(Outcome.accept, p.handleClick(5, 2));
    try testing.expectEqual(Outcome.ignored, p.handleClick(5, 5)); // below the items
    try testing.expectEqual(Outcome.ignored, p.handleClick(5, 0)); // the title
}

test "a long list scrolls to keep the highlight visible" {
    var s = try screen.Screen.init(testing.allocator, 30, 6);
    defer s.deinit();
    var p = Picker.init(testing.allocator);
    defer p.deinit();
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var name: [16]u8 = undefined;
        try p.add(.{ .text = try std.fmt.bufPrint(&name, "item{d:0>2}", .{i}) });
    }
    try p.refilter();
    const theme = Theme{};
    p.draw(&s, s.area(), "T", &theme);
    try testing.expectEqual(@as(usize, 4), p.list_rect.h);
    _ = try press(&p, "up"); // wraps to the last
    p.draw(&s, s.area(), "T", &theme);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("  item19", s.rowText(4, &buf));
    try testing.expectEqual(@as(usize, 16), p.scroll);
    _ = try press(&p, "pgup");
    try testing.expectEqual(@as(usize, 15), p.selected);
    p.scrollBy(-100);
    try testing.expectEqual(@as(usize, 0), p.scroll);
    try testing.expectEqual(@as(usize, 3), p.selected);
}
