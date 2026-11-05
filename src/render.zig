//! Cell-grid renderer: a front buffer (what is on screen) and a back buffer
//! (what we want). `render` diffs them and emits only the changed cells as
//! ANSI. No `std.Io`, no external TUI library.

const std = @import("std");
const term = @import("term.zig");

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const Attr = packed struct {
    bold: bool = false,
    underline: bool = false,
    reverse: bool = false,
};

pub const Cell = struct {
    ch: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attr: Attr = .{},
};

fn colorEql(a: Color, b: Color) bool {
    return switch (a) {
        .default => b == .default,
        .indexed => |x| b == .indexed and b.indexed == x,
        .rgb => |x| switch (b) {
            .rgb => |y| x.r == y.r and x.g == y.g and x.b == y.b,
            else => false,
        },
    };
}

fn cellEql(a: Cell, b: Cell) bool {
    return a.ch == b.ch and
        @as(u3, @bitCast(a.attr)) == @as(u3, @bitCast(b.attr)) and
        colorEql(a.fg, b.fg) and colorEql(a.bg, b.bg);
}

pub const Screen = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    front: []Cell,
    back: []Cell,
    out: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !Screen {
        const n = @as(usize, cols) * @as(usize, rows);
        const front = try allocator.alloc(Cell, n);
        errdefer allocator.free(front);
        const back = try allocator.alloc(Cell, n);
        @memset(front, Cell{});
        @memset(back, Cell{});
        return .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .front = front,
            .back = back,
            .out = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.front);
        self.allocator.free(self.back);
        self.out.deinit(self.allocator);
    }

    pub fn resize(self: *Screen, cols: u16, rows: u16) !void {
        if (cols == self.cols and rows == self.rows) return;
        const n = @as(usize, cols) * @as(usize, rows);
        const front = try self.allocator.alloc(Cell, n);
        const back = try self.allocator.alloc(Cell, n);
        @memset(front, Cell{});
        @memset(back, Cell{});
        self.allocator.free(self.front);
        self.allocator.free(self.back);
        self.front = front;
        self.back = back;
        self.cols = cols;
        self.rows = rows;
    }

    /// Fill the back buffer with blanks.
    pub fn clear(self: *Screen) void {
        @memset(self.back, Cell{});
    }

    pub fn put(self: *Screen, x: u16, y: u16, cell: Cell) void {
        if (x >= self.cols or y >= self.rows) return;
        self.back[@as(usize, y) * self.cols + x] = cell;
    }

    pub fn putStr(self: *Screen, x: u16, y: u16, s: []const u8, cell: Cell) void {
        var cx = x;
        for (s) |byte| {
            // Phase 1: treat input as bytes for ASCII; proper UTF-8 decode and
            // width handling arrive with the width table.
            if (cx >= self.cols) break;
            var c = cell;
            c.ch = byte;
            self.put(cx, y, c);
            cx += 1;
        }
    }

    fn append(self: *Screen, bytes: []const u8) !void {
        try self.out.appendSlice(self.allocator, bytes);
    }

    fn appendMoveTo(self: *Screen, x: u16, y: u16) !void {
        var tmp: [24]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "\x1b[{d};{d}H", .{ @as(u32, y) + 1, @as(u32, x) + 1 });
        try self.append(s);
    }

    fn appendSgr(self: *Screen, cell: Cell) !void {
        var fg_buf: [24]u8 = undefined;
        var bg_buf: [24]u8 = undefined;
        const fg = switch (cell.fg) {
            .default => "39",
            .indexed => |n| try std.fmt.bufPrint(&fg_buf, "38;5;{d}", .{n}),
            .rgb => |c| try std.fmt.bufPrint(&fg_buf, "38;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
        };
        const bg = switch (cell.bg) {
            .default => "49",
            .indexed => |n| try std.fmt.bufPrint(&bg_buf, "48;5;{d}", .{n}),
            .rgb => |c| try std.fmt.bufPrint(&bg_buf, "48;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
        };
        var pre_buf: [8]u8 = undefined;
        var p: usize = 0;
        if (cell.attr.bold) {
            pre_buf[p] = '1';
            p += 1;
        }
        if (cell.attr.underline) {
            if (p > 0) {
                pre_buf[p] = ';';
                p += 1;
            }
            pre_buf[p] = '4';
            p += 1;
        }
        if (cell.attr.reverse) {
            if (p > 0) {
                pre_buf[p] = ';';
                p += 1;
            }
            pre_buf[p] = '7';
            p += 1;
        }
        var sgr_buf: [80]u8 = undefined;
        // Always lead with `0`: a plain cell must clear attributes the block
        // cursor (reverse) set, or it leaks into every later cell.
        const sgr = if (p == 0)
            try std.fmt.bufPrint(&sgr_buf, "\x1b[0;{s};{s}m", .{ fg, bg })
        else
            try std.fmt.bufPrint(&sgr_buf, "\x1b[0;{s};{s};{s}m", .{ pre_buf[0..p], fg, bg });
        try self.append(sgr);
    }

    /// Emit the difference between back and front, then make front match back.
    pub fn render(self: *Screen) !void {
        try self.renderToBuffer();
        try term.write(self.out.items);
    }

    /// Repaint each changed row in full. Repainting whole rows (rather than
    /// individual cells) keeps the terminal and the front buffer in step even
    /// after a desync - a per-cell diff could leave stale cells behind once the
    /// two drifted apart, which is what left stray columns on screen.
    pub fn renderToBuffer(self: *Screen) !void {
        self.out.clearRetainingCapacity();

        var y: u16 = 0;
        while (y < self.rows) : (y += 1) {
            const row_start = @as(usize, y) * self.cols;

            var changed = false;
            var x: u16 = 0;
            while (x < self.cols) : (x += 1) {
                if (!cellEql(self.back[row_start + x], self.front[row_start + x])) {
                    changed = true;
                    break;
                }
            }
            if (!changed) continue;

            try self.appendMoveTo(0, y);

            var last_fg: Color = .{ .indexed = 255 }; // force first SGR
            var last_bg: Color = .{ .indexed = 255 };
            var last_attr: Attr = .{ .bold = true, .underline = true, .reverse = true };

            x = 0;
            while (x < self.cols) : (x += 1) {
                const i = row_start + x;
                const b = self.back[i];

                // Never touch the bottom-right cell: writing it can scroll the
                // whole screen on some terminals.
                if (x == self.cols - 1 and y == self.rows - 1) {
                    self.front[i] = b;
                    continue;
                }

                if (!colorEql(last_fg, b.fg) or !colorEql(last_bg, b.bg) or
                    @as(u3, @bitCast(last_attr)) != @as(u3, @bitCast(b.attr)))
                {
                    try self.appendSgr(b);
                    last_fg = b.fg;
                    last_bg = b.bg;
                    last_attr = b.attr;
                }

                var cbuf: [4]u8 = undefined;
                const clen = std.unicode.utf8Encode(b.ch, &cbuf) catch blk: {
                    cbuf[0] = '?';
                    break :blk 1;
                };
                try self.append(cbuf[0..clen]);

                self.front[i] = b;
            }
        }
    }
};

test "render repaints changed rows, then nothing" {
    var s = try Screen.init(std.testing.allocator, 4, 2);
    defer s.deinit();

    s.clear();
    s.put(1, 0, .{ .ch = 'A' });
    try s.renderToBuffer();

    try std.testing.expect(std.mem.indexOf(u8, s.out.items, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.out.items, "\x1b[1;1H") != null);

    // Nothing changed since the last frame.
    try s.renderToBuffer();
    try std.testing.expectEqual(@as(usize, 0), s.out.items.len);
}

test "render encodes utf-8" {
    var s = try Screen.init(std.testing.allocator, 3, 1);
    defer s.deinit();

    s.clear();
    s.put(0, 0, .{ .ch = 0x00E9 }); // e-acute
    try s.renderToBuffer();
    try std.testing.expect(std.mem.indexOf(u8, s.out.items, "\xc3\xa9") != null);
}

test "every sgr resets attributes" {
    var s = try Screen.init(std.testing.allocator, 2, 2);
    defer s.deinit();

    s.clear();
    s.put(0, 0, .{ .ch = 'a', .attr = .{ .reverse = true } });
    s.put(1, 0, .{ .ch = 'b' });
    try s.renderToBuffer();

    // A plain cell's SGR must begin with a reset, or reverse leaks.
    try std.testing.expect(std.mem.indexOf(u8, s.out.items, "\x1b[0;39;49m") != null);
    // No bare (non-resetting) colour sequence may be emitted.
    try std.testing.expect(std.mem.indexOf(u8, s.out.items, "\x1b[39;") == null);
}
