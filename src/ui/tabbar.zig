//! The row of tabs at the top: one per open document, a `+` pinned to the
//! right, and arrows when the tabs do not fit.
//!
//! `draw` works out the geometry and remembers it, so a mouse position can
//! be turned back into "which tab, or which button" with `hit`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const screen = @import("screen.zig");
const text = @import("core").text;
const Theme = @import("theme.zig").Theme;

pub const Tab = struct {
    name: []const u8,
    dirty: bool = false,
};

/// What is under a cell of the tab bar.
pub const Hit = union(enum) {
    none,
    tab: usize,
    close: usize,
    plus,
    prev,
    next,

    pub fn eql(a: Hit, b: Hit) bool {
        return std.meta.eql(a, b);
    }
};

/// A tab being dragged with the mouse.
pub const Drag = struct {
    from: usize,
    /// The tab it would be dropped on.
    to: usize,
    /// Where the pointer is.
    x: usize,
};

const Geometry = struct {
    /// Offset in the unscrolled strip, and width.
    start: usize,
    width: usize,
    /// Screen cells `[x0, x1)`, when visible.
    x0: usize = hidden,
    x1: usize = 0,
    close_x: usize = hidden,
};

const hidden = std.math.maxInt(usize);

pub const TabBar = struct {
    allocator: Allocator,
    tabs: std.ArrayList(Geometry) = .empty,
    /// Strip offset of the first visible tab; always a tab start.
    scroll: usize = 0,
    scroll_max: usize = 0,
    /// The active tab at the last draw: a change scrolls it into view.
    drawn_active: ?usize = null,
    hover: Hit = .none,
    plus_x: usize = hidden,
    prev_x: usize = hidden,
    next_x: usize = hidden,

    pub fn init(allocator: Allocator) TabBar {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TabBar) void {
        self.tabs.deinit(self.allocator);
    }

    fn labelWidth(tab: Tab) usize {
        // " name " or " name [+] ", then a pad, the x, and a pad so the x
        // never touches the edge of the tab.
        return text.cellWidth(tab.name, 1) + (if (tab.dirty) @as(usize, 6) else 2) + 3;
    }

    /// The tab start at or after `target`.
    fn snap(self: *const TabBar, target: usize) usize {
        for (self.tabs.items) |t| {
            if (t.start >= target) return t.start;
        }
        return if (self.tabs.items.len > 0) self.tabs.items[self.tabs.items.len - 1].start else 0;
    }

    /// Scroll the strip one tab left (-1) or right (+1).
    pub fn scrollBy(self: *TabBar, dir: i8) void {
        if (self.scroll_max == 0) return;
        var target = self.scroll;
        if (dir > 0) {
            for (self.tabs.items) |t| {
                if (t.start > self.scroll) {
                    target = t.start;
                    break;
                }
            }
        } else {
            var i = self.tabs.items.len;
            while (i > 0) {
                i -= 1;
                if (self.tabs.items[i].start < self.scroll) {
                    target = self.tabs.items[i].start;
                    break;
                }
            }
        }
        self.scroll = @min(target, self.scroll_max);
    }

    pub fn hit(self: *const TabBar, x: usize) Hit {
        if (x == self.prev_x) return .prev;
        if (x == self.next_x) return .next;
        if (self.plus_x != hidden and x >= self.plus_x and x < self.plus_x + 3) return .plus;
        for (self.tabs.items, 0..) |t, i| {
            if (x == t.close_x) return .{ .close = i };
            if (t.x0 != hidden and x >= t.x0 and x < t.x1) return .{ .tab = i };
        }
        return .none;
    }

    /// Whether tab `index` was (at least partly) on screen at the last draw.
    pub fn isVisible(self: *const TabBar, index: usize) bool {
        return index < self.tabs.items.len and self.tabs.items[index].x0 != hidden;
    }

    pub fn draw(
        self: *TabBar,
        s: *screen.Screen,
        y: usize,
        tabs: []const Tab,
        active: usize,
        drag: ?Drag,
        theme: *const Theme,
    ) void {
        const w = s.cols;
        const bar_bg = theme.tab_bg;
        s.fill(.{ .y = y, .w = w, .h = 1 }, .{ .bg = bar_bg });
        self.plus_x = hidden;
        self.prev_x = hidden;
        self.next_x = hidden;

        // Strip geometry. If memory is short the bar shows the tabs it has
        // room to describe; the documents are all still there.
        self.tabs.clearRetainingCapacity();
        self.tabs.ensureTotalCapacity(self.allocator, tabs.len) catch {};
        var total: usize = 0;
        for (tabs, 0..) |tab, i| {
            if (i >= self.tabs.capacity) break;
            const width = labelWidth(tab);
            self.tabs.appendAssumeCapacity(.{ .start = total, .width = width });
            total += width + 1; // one blank cell between tabs
        }
        if (total > 0) total -= 1;
        const n = self.tabs.items.len;

        if (w < 8) {
            self.scroll = 0;
            self.scroll_max = 0;
            return;
        }
        self.plus_x = w - 3;
        var x0: usize = 0;
        var avail = w - 4; // the tab area ends one cell before " + "
        const overflow = total > avail;
        if (overflow) {
            x0 = 1;
            self.prev_x = 0;
            self.next_x = w - 5;
            avail -= 2; // an arrow at each end
        }

        // The furthest scroll: the first tab from which the rest fits.
        self.scroll_max = 0;
        if (overflow) {
            self.scroll_max = self.tabs.items[n - 1].start;
            for (self.tabs.items) |t| {
                if (total - t.start <= avail) {
                    self.scroll_max = t.start;
                    break;
                }
            }
        }
        var scroll = self.snap(@min(self.scroll, self.scroll_max));
        // A change of active tab scrolls it into view; scrolling by hand
        // stays where it was put.
        if (overflow and active < n and self.drawn_active != active) {
            const a = self.tabs.items[active];
            if (a.width >= avail or a.start < scroll) {
                scroll = a.start;
            } else if (a.start + a.width > scroll + avail) {
                scroll = self.snap(@min(a.start + a.width - avail, self.scroll_max));
            }
        }
        self.scroll = scroll;
        self.drawn_active = active;
        const strip_end = x0 + avail;

        {
            const hot = self.hover == .plus;
            _ = s.text(self.plus_x, y, w, " + ", .{
                .bg = if (hot) theme.accent else bar_bg,
                .fg = if (hot) bar_bg else theme.accent,
                .attr = .{ .bold = true },
            });
        }
        if (overflow) {
            const can_prev = scroll > 0;
            const can_next = scroll < self.scroll_max;
            const hot_prev = self.hover == .prev and can_prev;
            const hot_next = self.hover == .next and can_next;
            s.put(self.prev_x, y, .{
                .ch = 0x2039,
                .bg = if (hot_prev) theme.accent else bar_bg,
                .fg = if (hot_prev) bar_bg else if (can_prev) theme.accent else theme.gutter,
                .attr = .{ .bold = can_prev },
            });
            s.put(self.next_x, y, .{
                .ch = 0x203a,
                .bg = if (hot_next) theme.accent else bar_bg,
                .fg = if (hot_next) bar_bg else if (can_next) theme.accent else theme.gutter,
                .attr = .{ .bold = can_next },
            });
        }

        for (self.tabs.items, 0..) |*t, i| {
            if (t.start < scroll) continue; // scrolled off to the left
            const tx = x0 + (t.start - scroll);
            if (tx >= strip_end) break;
            const end = @min(tx + t.width, strip_end);
            const is_active = i == active;
            const hovered = self.hover.eql(.{ .tab = i }) or self.hover.eql(.{ .close = i });
            const dragging = if (drag) |d| d.from == i else false;
            const bg = if (dragging) theme.accent else if (is_active) theme.tab_active_bg else if (hovered) theme.selection else bar_bg;
            const fg = if (dragging) bar_bg else if (is_active or hovered) theme.text else theme.gutter;
            s.fill(.{ .x = tx, .y = y, .w = end - tx, .h = 1 }, .{ .bg = bg });
            const style = screen.Style{
                .bg = bg,
                .fg = fg,
                .attr = .{ .bold = is_active or dragging, .underline = hovered and !is_active },
            };
            var x = s.text(tx + 1, y, end, tabs[i].name, style);
            if (tabs[i].dirty) x = s.text(x, y, end, " [+]", style);
            const close_x = x + 2; // the label's trailing blank, then a pad
            if (close_x + 1 < end) { // the x and the cell after it both fit
                const hot = self.hover.eql(.{ .close = i });
                s.put(close_x, y, .{
                    .ch = 'x',
                    .bg = if (hot) theme.accent else bg,
                    .fg = if (hot or dragging) bar_bg else theme.gutter,
                    .attr = .{ .bold = hot or hovered },
                });
                t.close_x = close_x;
            }
            t.x0 = tx;
            t.x1 = end;
        }

        // While dragging: a marker where the tab would land, and the tab's
        // name following the pointer.
        if (drag) |d| {
            if (d.to < n and self.tabs.items[d.to].x0 != hidden) {
                s.put(self.tabs.items[d.to].x0, y, .{ .ch = 0x2502, .bg = bar_bg, .fg = theme.accent });
            }
            if (d.from < tabs.len) {
                const chip = screen.Style{ .bg = theme.accent, .fg = bar_bg, .attr = .{ .bold = true } };
                const start = d.x -| 1;
                const x = s.text(start, y, w, " ", chip);
                const after = s.text(x, y, w, tabs[d.from].name, chip);
                _ = s.text(after, y, w, " ", chip);
            }
        }
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    s: screen.Screen,
    bar: TabBar,
    theme: Theme = .{},
    buf: [256]u8 = undefined,

    fn init(cols: usize) !Fixture {
        return .{ .s = try screen.Screen.init(testing.allocator, cols, 1), .bar = TabBar.init(testing.allocator) };
    }

    fn deinit(self: *Fixture) void {
        self.s.deinit();
        self.bar.deinit();
    }

    fn draw(self: *Fixture, tabs: []const Tab, active: usize) []const u8 {
        self.s.clear();
        self.bar.draw(&self.s, 0, tabs, active, null, &self.theme);
        return self.s.rowText(0, &self.buf);
    }
};

test "tabs are laid out with a close button and one blank between them" {
    var f = try Fixture.init(40);
    defer f.deinit();
    const row = f.draw(&.{ .{ .name = "[No Name]" }, .{ .name = "a.zig", .dirty = true } }, 0);
    try testing.expect(std.mem.startsWith(u8, row, " [No Name]  x   a.zig [+]  x "));
    try testing.expect(std.mem.endsWith(u8, row, " +"));

    // The x is not the tab's last cell.
    try testing.expectEqual(@as(usize, 12), f.bar.tabs.items[0].close_x);
    try testing.expectEqual(@as(usize, 14), f.bar.tabs.items[0].x1);
    try testing.expect(f.bar.hit(3).eql(.{ .tab = 0 }));
    try testing.expect(f.bar.hit(12).eql(.{ .close = 0 }));
    try testing.expect(f.bar.hit(13).eql(.{ .tab = 0 }));
    try testing.expect(f.bar.hit(14).eql(.none)); // the gap
    try testing.expect(f.bar.hit(15).eql(.{ .tab = 1 }));
    try testing.expect(f.bar.hit(38).eql(.plus));
    try testing.expect(f.bar.hit(30).eql(.none));
}

test "a wide name is measured in cells, not bytes" {
    var f = try Fixture.init(40);
    defer f.deinit();
    _ = f.draw(&.{.{ .name = "\xe4\xb8\xad\xe6\x96\x87.txt" }}, 0);
    // 2+2 cells of CJK, ".txt", two blanks around, pad, x, pad.
    try testing.expectEqual(@as(usize, 13), f.bar.tabs.items[0].width);
    try testing.expectEqual(@as(usize, 11), f.bar.tabs.items[0].close_x);
}

test "too many tabs scroll, with arrows, and the active tab stays visible" {
    var f = try Fixture.init(40);
    defer f.deinit();
    const tabs = [_]Tab{.{ .name = "[No Name]" }} ** 13;
    _ = f.draw(&tabs, 12);
    try testing.expect(f.bar.scroll_max > 0);
    try testing.expectEqual(@as(usize, 0), f.bar.prev_x);
    try testing.expect(f.bar.next_x != hidden);
    try testing.expect(f.bar.isVisible(12));
    try testing.expect(!f.bar.isVisible(0));
    try testing.expect(f.bar.hit(0).eql(.prev));

    // Scrolling by hand walks one tab at a time and is not undone by a
    // redraw with the same active tab.
    const before = f.bar.scroll;
    f.bar.scrollBy(-1);
    try testing.expect(f.bar.scroll < before);
    while (f.bar.scroll > 0) f.bar.scrollBy(-1);
    _ = f.draw(&tabs, 12);
    try testing.expectEqual(@as(usize, 0), f.bar.scroll);
    try testing.expect(f.bar.isVisible(0));
    try testing.expect(!f.bar.isVisible(12));

    // Changing the active tab scrolls it back into view.
    _ = f.draw(&tabs, 11);
    try testing.expect(f.bar.isVisible(11));
    f.bar.scrollBy(1);
    f.bar.scrollBy(1);
    try testing.expect(f.bar.scroll <= f.bar.scroll_max);
}

test "a tab cut off by the edge has no close button" {
    var f = try Fixture.init(20);
    defer f.deinit();
    _ = f.draw(&.{ .{ .name = "one.txt" }, .{ .name = "two.txt" }, .{ .name = "three.txt" } }, 0);
    var cut: usize = 0;
    for (f.bar.tabs.items) |t| {
        if (t.x0 != hidden and t.x1 - t.x0 < t.width) {
            cut += 1;
            try testing.expectEqual(hidden, t.close_x);
        }
    }
    try testing.expect(cut <= 1);
}

test "hover lights the button, and a drag shows where the tab lands" {
    var f = try Fixture.init(40);
    defer f.deinit();
    const tabs = [_]Tab{ .{ .name = "a" }, .{ .name = "b" } };
    f.bar.hover = .{ .close = 1 };
    _ = f.draw(&tabs, 0);
    const close_x = f.bar.tabs.items[1].close_x;
    try testing.expect(f.s.at(close_x, 0).bg.eql(f.theme.accent));
    try testing.expect(!f.s.at(f.bar.tabs.items[0].close_x, 0).bg.eql(f.theme.accent));

    f.bar.hover = .none;
    f.s.clear();
    f.bar.draw(&f.s, 0, &tabs, 0, .{ .from = 0, .to = 1, .x = 20 }, &f.theme);
    try testing.expectEqual(@as(u21, 0x2502), f.s.at(f.bar.tabs.items[1].x0, 0).ch);
    try testing.expectEqual(@as(u21, 'a'), f.s.at(20, 0).ch); // the chip under the pointer
    try testing.expect(f.s.at(20, 0).bg.eql(f.theme.accent));
}

test "a bar too narrow for anything draws nothing and does not crash" {
    var f = try Fixture.init(6);
    defer f.deinit();
    try testing.expectEqualStrings("", f.draw(&.{.{ .name = "x" }}, 0));
    try testing.expect(f.bar.hit(2).eql(.none));
    try testing.expectEqualStrings("", f.draw(&.{}, 0));
}
