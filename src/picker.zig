//! Fuzzy picker state: a filterable list used for opening files and choosing a
//! theme. Rendering lives in main.zig; this file is pure state so it can be
//! unit tested.

const std = @import("std");

pub const Mode = enum { open_file, theme };

pub const MAX_FILTER = 96;
pub const MAX_DIR = 512;

pub const Item = struct {
    text: []u8,
    is_dir: bool = false,
};

pub const Picker = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Item),
    /// Indices into `items` that match the filter, in list order.
    filtered: std.ArrayList(usize),
    filter: [MAX_FILTER]u8 = undefined,
    filter_len: usize = 0,
    selected: usize = 0,
    scroll: usize = 0,
    dir: [MAX_DIR]u8 = undefined,
    dir_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Picker {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(Item).empty,
            .filtered = std.ArrayList(usize).empty,
        };
    }

    pub fn deinit(self: *Picker) void {
        self.clear();
        self.items.deinit(self.allocator);
        self.filtered.deinit(self.allocator);
    }

    pub fn clear(self: *Picker) void {
        for (self.items.items) |item| self.allocator.free(item.text);
        self.items.clearRetainingCapacity();
        self.filtered.clearRetainingCapacity();
        self.filter_len = 0;
        self.selected = 0;
        self.scroll = 0;
    }

    pub fn add(self: *Picker, text: []const u8, is_dir: bool) !void {
        try self.items.append(self.allocator, .{
            .text = try self.allocator.dupe(u8, text),
            .is_dir = is_dir,
        });
    }

    pub fn setDir(self: *Picker, dir: []const u8) void {
        const n = @min(dir.len, self.dir.len);
        @memcpy(self.dir[0..n], dir[0..n]);
        self.dir_len = n;
    }

    pub fn dirName(self: *const Picker) []const u8 {
        return self.dir[0..self.dir_len];
    }

    pub fn filterText(self: *const Picker) []const u8 {
        return self.filter[0..self.filter_len];
    }

    pub fn pushFilter(self: *Picker, c: u8) void {
        if (self.filter_len >= self.filter.len) return;
        self.filter[self.filter_len] = c;
        self.filter_len += 1;
        self.refilter();
    }

    pub fn popFilter(self: *Picker) void {
        if (self.filter_len == 0) return;
        self.filter_len -= 1;
        self.refilter();
    }

    pub fn refilter(self: *Picker) void {
        self.filtered.clearRetainingCapacity();
        const query = self.filterText();
        for (self.items.items, 0..) |item, i| {
            if (fuzzyMatch(query, item.text)) self.filtered.append(self.allocator, i) catch {};
        }
        self.selected = 0;
        self.scroll = 0;
    }

    pub fn count(self: *const Picker) usize {
        return self.filtered.items.len;
    }

    /// Move the selection by `delta`, wrapping around.
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

    /// Keep the selected row inside a viewport of `rows` lines.
    pub fn ensureVisible(self: *Picker, rows: usize) void {
        if (rows == 0) return;
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + rows) self.scroll = self.selected + 1 - rows;
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

test "fuzzyMatch is a case-insensitive subsequence match" {
    try std.testing.expect(fuzzyMatch("", "anything"));
    try std.testing.expect(fuzzyMatch("src", "src/main.zig"));
    try std.testing.expect(fuzzyMatch("smz", "src/main.zig")); // subsequence
    try std.testing.expect(fuzzyMatch("SRC", "src/main.zig"));
    try std.testing.expect(!fuzzyMatch("xyz", "src/main.zig"));
    try std.testing.expect(!fuzzyMatch("mainsrc", "src/main.zig")); // order matters
}

test "filtering keeps list order and resets the selection" {
    var p = Picker.init(std.testing.allocator);
    defer p.deinit();
    try p.add("alpha.zig", false);
    try p.add("beta.zig", false);
    try p.add("src", true);
    p.refilter();
    try std.testing.expectEqual(@as(usize, 3), p.count());

    p.pushFilter('b');
    try std.testing.expectEqual(@as(usize, 1), p.count());
    try std.testing.expectEqualStrings("beta.zig", p.selectedItem().?.text);

    p.popFilter();
    p.pushFilter('z');
    try std.testing.expectEqual(@as(usize, 2), p.count()); // both .zig files
    try std.testing.expectEqual(@as(usize, 0), p.selected);

    p.pushFilter('s'); // "zs" matches nothing
    try std.testing.expectEqual(@as(usize, 0), p.count());
    try std.testing.expect(p.selectedItem() == null);
}

test "selection wraps and the viewport follows it" {
    var p = Picker.init(std.testing.allocator);
    defer p.deinit();
    try p.add("a", false);
    try p.add("b", false);
    try p.add("c", false);
    p.refilter();

    p.move(-1); // wrap to the last item
    try std.testing.expectEqualStrings("c", p.selectedItem().?.text);
    p.move(1); // wrap to the first
    try std.testing.expectEqualStrings("a", p.selectedItem().?.text);

    p.move(2);
    p.ensureVisible(2);
    try std.testing.expectEqual(@as(usize, 1), p.scroll);
}

test "directories are marked" {
    var p = Picker.init(std.testing.allocator);
    defer p.deinit();
    try p.add("src", true);
    try p.add("main.zig", false);
    p.refilter();
    try std.testing.expect(p.selectedItem().?.is_dir);
    p.move(1);
    try std.testing.expect(!p.selectedItem().?.is_dir);
}
