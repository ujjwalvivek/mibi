//! A grid of cells and the code that puts it on a terminal.
//!
//! Widgets draw into the back buffer. `diff` compares it with the front
//! buffer (what the terminal shows) and writes the escape sequences for the
//! rows that changed. Nothing here touches a file descriptor: `diff` appends
//! bytes to a list and the caller writes them, which is also what lets tests
//! read a frame back as text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const utf8 = @import("core").utf8;
const width = @import("core").width;

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: struct { r: u8, g: u8, b: u8 },

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |x| b == .indexed and b.indexed == x,
            .rgb => |x| b == .rgb and x.r == b.rgb.r and x.g == b.rgb.g and x.b == b.rgb.b,
        };
    }

    pub fn isDefault(self: Color) bool {
        return self == .default;
    }
};

pub const Attr = packed struct(u8) {
    bold: bool = false,
    underline: bool = false,
    reverse: bool = false,
    dim: bool = false,
    italic: bool = false,
    _pad: u3 = 0,
};

pub const Cell = struct {
    ch: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attr: Attr = .{},
    /// Second cell of a wide character: never written, the wide glyph covers it.
    cont: bool = false,

    fn eql(a: Cell, b: Cell) bool {
        return a.ch == b.ch and a.cont == b.cont and
            @as(u8, @bitCast(a.attr)) == @as(u8, @bitCast(b.attr)) and
            a.fg.eql(b.fg) and a.bg.eql(b.bg);
    }
};

/// How a run of text is painted.
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    attr: Attr = .{},
};

pub const Rect = struct {
    x: usize = 0,
    y: usize = 0,
    w: usize = 0,
    h: usize = 0,

    pub fn contains(self: Rect, x: usize, y: usize) bool {
        return x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self.h;
    }

    pub fn right(self: Rect) usize {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) usize {
        return self.y + self.h;
    }
};

pub const Screen = struct {
    allocator: Allocator,
    cols: usize,
    rows: usize,
    front: []Cell,
    back: []Cell,

    pub fn init(allocator: Allocator, cols: usize, rows: usize) !Screen {
        const n = cols * rows;
        const front = try allocator.alloc(Cell, n);
        errdefer allocator.free(front);
        const back = try allocator.alloc(Cell, n);
        @memset(front, Cell{});
        @memset(back, Cell{});
        return .{ .allocator = allocator, .cols = cols, .rows = rows, .front = front, .back = back };
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.front);
        self.allocator.free(self.back);
    }

    /// Change the size. Both buffers start blank, and the caller should clear
    /// the terminal too (see `invalidate`), because what it shows is unknown.
    pub fn resize(self: *Screen, cols: usize, rows: usize) !void {
        if (cols == self.cols and rows == self.rows) return;
        const next = try Screen.init(self.allocator, cols, rows);
        self.deinit();
        self.* = next;
    }

    /// Forget what the terminal shows, so the next `diff` repaints every row.
    pub fn invalidate(self: *Screen) void {
        // A cell no widget ever draws, so every row compares as changed.
        @memset(self.front, Cell{ .ch = 0 });
    }

    pub fn area(self: *const Screen) Rect {
        return .{ .w = self.cols, .h = self.rows };
    }

    pub fn clear(self: *Screen) void {
        @memset(self.back, Cell{});
    }

    pub fn put(self: *Screen, x: usize, y: usize, cell: Cell) void {
        if (x >= self.cols or y >= self.rows) return;
        self.back[y * self.cols + x] = cell;
    }

    pub fn at(self: *const Screen, x: usize, y: usize) Cell {
        return self.back[y * self.cols + x];
    }

    /// Paint a rectangle with blanks in `style`.
    pub fn fill(self: *Screen, r: Rect, style: Style) void {
        var y = r.y;
        while (y < @min(r.bottom(), self.rows)) : (y += 1) {
            var x = r.x;
            while (x < @min(r.right(), self.cols)) : (x += 1) {
                self.back[y * self.cols + x] = .{ .fg = style.fg, .bg = style.bg, .attr = style.attr };
            }
        }
    }

    /// Write UTF-8 text starting at `x`, never reaching `max_x`. Control
    /// bytes are dropped, wide characters take two cells and combining marks
    /// none. Returns the column after the last cell written.
    pub fn text(self: *Screen, x: usize, y: usize, max_x: usize, s: []const u8, style: Style) usize {
        const limit = @min(max_x, self.cols);
        var cx = x;
        var i: usize = 0;
        while (i < s.len) {
            const cp = utf8.nextCp(s, &i);
            if (cp < 0x20 or cp == 0x7f) continue;
            const w = width.cellWidth(cp);
            if (w == 0) continue;
            if (cx + w > limit) break;
            self.put(cx, y, .{ .ch = cp, .fg = style.fg, .bg = style.bg, .attr = style.attr });
            if (w == 2) self.put(cx + 1, y, .{ .fg = style.fg, .bg = style.bg, .attr = style.attr, .cont = true });
            cx += w;
        }
        return cx;
    }

    /// The characters of row `y` as UTF-8, trailing blanks removed. For tests
    /// and for nothing else.
    pub fn rowText(self: *const Screen, y: usize, buf: []u8) []const u8 {
        var n: usize = 0;
        var x: usize = 0;
        while (x < self.cols) : (x += 1) {
            const cell = self.back[y * self.cols + x];
            if (cell.cont) continue;
            var enc: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.ch, &enc) catch continue;
            if (n + len > buf.len) break;
            @memcpy(buf[n..][0..len], enc[0..len]);
            n += len;
        }
        return std.mem.trimEnd(u8, buf[0..n], " ");
    }

    /// Append to `out` the bytes that turn what the terminal shows into the
    /// back buffer, and remember the back buffer as shown.
    ///
    /// Changed rows are repainted whole. A per-cell diff is smaller, but once
    /// terminal and front buffer disagree about a single cell (a glyph the
    /// terminal draws wider than the width table says) it leaves stale cells
    /// behind; a whole row heals itself on the next change.
    pub fn diff(self: *Screen, out: *std.ArrayList(u8)) !void {
        var y: usize = 0;
        while (y < self.rows) : (y += 1) {
            const row = y * self.cols;
            const back = self.back[row..][0..self.cols];
            const front = self.front[row..][0..self.cols];
            var changed = false;
            for (back, front) |b, f| {
                if (!b.eql(f)) {
                    changed = true;
                    break;
                }
            }
            if (!changed) continue;

            var buf: [24]u8 = undefined;
            try out.appendSlice(self.allocator, std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{y + 1}) catch unreachable);
            var last: ?Cell = null;
            for (back) |b| {
                if (b.cont) continue;
                const same_style = if (last) |l|
                    l.fg.eql(b.fg) and l.bg.eql(b.bg) and @as(u8, @bitCast(l.attr)) == @as(u8, @bitCast(b.attr))
                else
                    false;
                if (!same_style) try appendSgr(self.allocator, out, b);
                last = b;
                var enc: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(b.ch, &enc) catch blk: {
                    enc[0] = '?';
                    break :blk 1;
                };
                try out.appendSlice(self.allocator, enc[0..len]);
            }
            @memcpy(front, back);
        }
    }
};

fn appendSgr(allocator: Allocator, out: *std.ArrayList(u8), cell: Cell) !void {
    // Always lead with 0: a plain cell must clear what the cell before it set
    // (the block cursor's reverse), or it leaks into every later cell.
    try out.appendSlice(allocator, "\x1b[0");
    const codes = [_]struct { on: bool, code: []const u8 }{
        .{ .on = cell.attr.bold, .code = ";1" },
        .{ .on = cell.attr.dim, .code = ";2" },
        .{ .on = cell.attr.italic, .code = ";3" },
        .{ .on = cell.attr.underline, .code = ";4" },
        .{ .on = cell.attr.reverse, .code = ";7" },
    };
    for (codes) |c| {
        if (c.on) try out.appendSlice(allocator, c.code);
    }
    var buf: [32]u8 = undefined;
    inline for (.{ .{ cell.fg, "3" }, .{ cell.bg, "4" } }) |pair| {
        const s = switch (pair[0]) {
            .default => std.fmt.bufPrint(&buf, ";{s}9", .{pair[1]}),
            .indexed => |n| std.fmt.bufPrint(&buf, ";{s}8;5;{d}", .{ pair[1], n }),
            .rgb => |c| std.fmt.bufPrint(&buf, ";{s}8;2;{d};{d};{d}", .{ pair[1], c.r, c.g, c.b }),
        } catch unreachable;
        try out.appendSlice(allocator, s);
    }
    try out.append(allocator, 'm');
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "diff repaints changed rows, then nothing" {
    var s = try Screen.init(testing.allocator, 4, 2);
    defer s.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);

    s.put(1, 0, .{ .ch = 'A' });
    try s.diff(&out);
    try testing.expect(std.mem.indexOf(u8, out.items, "A") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1;1H") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2;1H") == null);

    out.clearRetainingCapacity();
    try s.diff(&out);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // After invalidate every row is sent again.
    s.invalidate();
    try s.diff(&out);
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2;1H") != null);
}

test "every style change resets attributes" {
    var s = try Screen.init(testing.allocator, 2, 1);
    defer s.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    s.put(0, 0, .{ .ch = 'a', .attr = .{ .reverse = true } });
    s.put(1, 0, .{ .ch = 'b' });
    try s.diff(&out);
    try testing.expectEqualStrings("\x1b[1;1H\x1b[0;7;39;49ma\x1b[0;39;49mb", out.items);
}

test "colours are written as indexed or rgb" {
    var s = try Screen.init(testing.allocator, 1, 1);
    defer s.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    s.put(0, 0, .{ .ch = 'x', .fg = .{ .indexed = 9 }, .bg = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .attr = .{ .bold = true } });
    try s.diff(&out);
    try testing.expectEqualStrings("\x1b[1;1H\x1b[0;1;38;5;9;48;2;1;2;3mx", out.items);
}

test "text honours display width and clips" {
    var s = try Screen.init(testing.allocator, 8, 1);
    defer s.deinit();
    var buf: [64]u8 = undefined;
    // e-acute, a wide CJK character, a combining mark, a control byte.
    const end = s.text(0, 0, 8, "\xc3\xa9\xe4\xb8\xadx\xcc\x81\x07y", .{});
    try testing.expectEqual(@as(usize, 5), end);
    try testing.expectEqual(@as(u21, 0xe9), s.at(0, 0).ch);
    try testing.expectEqual(@as(u21, 0x4e2d), s.at(1, 0).ch);
    try testing.expect(s.at(2, 0).cont);
    try testing.expectEqual(@as(u21, 'x'), s.at(3, 0).ch);
    try testing.expectEqual(@as(u21, 'y'), s.at(4, 0).ch);
    try testing.expectEqualStrings("\xc3\xa9\xe4\xb8\xadxy", s.rowText(0, &buf));

    // A wide character that would straddle the limit is not drawn at all.
    s.clear();
    try testing.expectEqual(@as(usize, 1), s.text(0, 0, 2, "a\xe4\xb8\xad", .{}));
    try testing.expectEqualStrings("a", s.rowText(0, &buf));
}

test "fill and resize" {
    var s = try Screen.init(testing.allocator, 4, 3);
    defer s.deinit();
    const red = Color{ .indexed = 1 };
    s.fill(.{ .x = 1, .y = 1, .w = 10, .h = 10 }, .{ .bg = red });
    try testing.expect(s.at(0, 0).bg.isDefault());
    try testing.expect(s.at(1, 1).bg.eql(red));
    try testing.expect(s.at(3, 2).bg.eql(red));
    try s.resize(2, 2);
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expect(s.at(1, 1).bg.isDefault());
}
