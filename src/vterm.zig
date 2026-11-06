//! VT/ANSI parser, screen buffer and scrollback for the embedded terminal.
//!
//! This is a deliberately small v1: enough of xterm to run a shell, a pager or
//! a full-screen TUI, not the complete DEC repertoire. The parser is a
//! byte-at-a-time state machine, so escape sequences and UTF-8 codepoints that
//! are split across `feed` calls resume where they left off. Nothing allocates
//! while parsing: the screen, the alternate screen and the scrollback ring are
//! all sized by `init`/`resize`.
//!
//! Deliberate v1 omissions, kept simple on purpose: no background-colour erase
//! (erasing always writes default-background blanks), no reflow on resize, no
//! mouse reporting beyond the mode flags, no colon-form SGR, and combining
//! marks are dropped rather than composed onto the previous cell.

const std = @import("std");
const width = @import("width.zig");

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const Attr = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    blink: bool = false,
    strike: bool = false,
    hidden: bool = false,
};

pub const Cell = struct {
    ch: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attr: Attr = .{},
};

pub const Cursor = struct { x: u16, y: u16, visible: bool = true };

pub const MouseMode = enum { off, click, drag };

// Scrollback is a fixed ring so `feed` never allocates. The whole ring is
// allocated up front (2000 lines of `cols` cells): a few megabytes for a wide
// terminal, which is the price of the no-allocation rule.
const max_scrollback = 2000;

// Screen-size ceilings. A real terminal never gets near these; the clamp stops
// a bogus size from the pty layer from asking for gigabytes.
const max_cols = 512;
const max_rows = 256;

const max_params = 16;
const max_title = 64;
const osc_buf_len = 128;
const reply_buf_len = 64;

const SavedCursor = struct {
    x: u16,
    y: u16,
    fg: Color,
    bg: Color,
    attr: Attr,
};

const State = enum {
    ground,
    escape, // saw ESC
    escape_intermediate, // saw ESC + 0x20..0x2f; consume one more byte
    csi_param, // inside ESC [ ...: params, prefix and intermediates
    csi_intermediate, // saw CSI + 0x20..0x2f; consume through the final
    csi_ignore, // malformed CSI: consume through the final
    osc, // saw ESC ]
    osc_esc, // saw ESC inside an OSC (maybe ST)
    string, // DCS/SOS/PM/APC body
    string_esc, // saw ESC inside such a string
};

pub const Vt = struct {
    allocator: std.mem.Allocator,
    ncols: u16,
    nrows: u16,
    /// Active screen, row-major `nrows * ncols` cells.
    cells: []Cell,
    /// The inactive screen: the alternate screen when `alt_active`, else the
    /// saved main screen.
    other: []Cell,
    alt_active: bool = false,

    /// Scrollback ring: `max_scrollback` lines of `ncols` cells each.
    sb: []Cell,
    sb_head: usize = 0, // index of the oldest line once the ring is full
    sb_len: usize = 0,

    cur: Cursor = .{ .x = 0, .y = 0 },
    pending_wrap: bool = false,

    // scroll region, 0-based inclusive rows
    scroll_top: u16 = 0,
    scroll_bottom: u16 = 0,
    origin: bool = false,

    autowrap: bool = true,
    app_cursor: bool = false,
    bracketed_paste: bool = false,
    mouse: MouseMode = .off,

    fg: Color = .default,
    bg: Color = .default,
    attr: Attr = .{},

    saved: SavedCursor = .{ .x = 0, .y = 0, .fg = .default, .bg = .default, .attr = .{} },
    alt_saved: SavedCursor = .{ .x = 0, .y = 0, .fg = .default, .bg = .default, .attr = .{} },

    title_buf: [max_title]u8 = [_]u8{0} ** max_title,
    title_len: usize = 0,

    state: State = .ground,
    params: [max_params]u16 = [_]u16{0} ** max_params,
    param_count: u8 = 0,
    param_value: u16 = 0,
    param_digits: bool = false,
    private_byte: u8 = 0,

    // an incomplete UTF-8 sequence carried across feed calls
    utf8_buf: [4]u8 = [_]u8{0} ** 4,
    utf8_len: u8 = 0,
    utf8_need: u8 = 0,

    osc_buf: [osc_buf_len]u8 = [_]u8{0} ** osc_buf_len,
    osc_len: usize = 0,

    reply_buf: [reply_buf_len]u8 = [_]u8{0} ** reply_buf_len,
    reply_len: usize = 0,

    view: usize = 0,

    pub fn init(allocator: std.mem.Allocator, cols_in: u16, rows_in: u16) !Vt {
        // a zero size would make every index invalid; the pty can report one
        // while the window is being created.
        const c = clampSize(cols_in, max_cols);
        const r = clampSize(rows_in, max_rows);
        const n = @as(usize, c) * @as(usize, r);
        const cells = try allocator.alloc(Cell, n);
        errdefer allocator.free(cells);
        const other = try allocator.alloc(Cell, n);
        errdefer allocator.free(other);
        const sb = try allocator.alloc(Cell, @as(usize, max_scrollback) * @as(usize, c));
        errdefer allocator.free(sb);
        @memset(cells, Cell{});
        @memset(other, Cell{});
        @memset(sb, Cell{});
        return .{
            .allocator = allocator,
            .ncols = c,
            .nrows = r,
            .cells = cells,
            .other = other,
            .sb = sb,
            .scroll_bottom = r - 1,
        };
    }

    pub fn deinit(self: *Vt) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.other);
        self.allocator.free(self.sb);
    }

    pub fn resize(self: *Vt, cols_in: u16, rows_in: u16) !void {
        const nc = clampSize(cols_in, max_cols);
        const nr = clampSize(rows_in, max_rows);
        if (nc == self.ncols and nr == self.nrows) return;

        const old_c = @as(usize, self.ncols);
        const old_r = @as(usize, self.nrows);
        const new_c = @as(usize, nc);
        const new_r = @as(usize, nr);
        const drop = if (old_r > new_r) old_r - new_r else 0;

        const new_cells = try self.allocator.alloc(Cell, new_c * new_r);
        errdefer self.allocator.free(new_cells);
        const new_other = try self.allocator.alloc(Cell, new_c * new_r);
        errdefer self.allocator.free(new_other);
        const new_sb = try self.allocator.alloc(Cell, @as(usize, max_scrollback) * new_c);
        errdefer self.allocator.free(new_sb);
        @memset(new_cells, Cell{});
        @memset(new_other, Cell{});
        @memset(new_sb, Cell{});

        // no reflow: rows keep their cells and are clipped or padded at the
        // new width. Shrinking rows anchors the bottom (a shell prompt stays
        // visible) and the lines that fall off the top become scrollback;
        // growing pads blank rows at the bottom.
        copyScreen(new_cells, self.cells, old_c, old_r, new_c, new_r, drop);
        copyScreen(new_other, self.other, old_c, old_r, new_c, new_r, drop);

        const main_old = if (self.alt_active) self.other else self.cells;

        var head: usize = 0;
        var len: usize = 0;
        var i: usize = 0;
        while (i < self.sb_len) : (i += 1) {
            const phys = (self.sb_head + i) % max_scrollback;
            ringPush(new_sb, max_scrollback, &head, &len, new_c, self.sb[phys * old_c ..][0..old_c]);
        }
        // the main screen's top lines are the newest scrollback entries
        if (drop > 0) {
            var d: usize = 0;
            while (d < drop) : (d += 1) {
                ringPush(new_sb, max_scrollback, &head, &len, new_c, main_old[d * old_c ..][0..old_c]);
            }
        }

        const was_full = self.scroll_top == 0 and @as(usize, self.scroll_bottom) + 1 == old_r;

        self.allocator.free(self.cells);
        self.allocator.free(self.other);
        self.allocator.free(self.sb);
        self.cells = new_cells;
        self.other = new_other;
        self.sb = new_sb;
        self.sb_head = head;
        self.sb_len = len;
        self.ncols = nc;
        self.nrows = nr;
        self.pending_wrap = false;
        self.view = @min(self.view, self.sb_len);

        if (drop > 0) {
            self.cur.y = if (@as(usize, self.cur.y) >= drop) @intCast(@as(usize, self.cur.y) - drop) else 0;
        }
        self.cur.x = @min(self.cur.x, nc - 1);
        self.cur.y = @min(self.cur.y, nr - 1);

        // a full-screen region stays full; a custom one follows the rows it
        // was anchored to and is clamped into the new screen.
        if (was_full) {
            self.scroll_top = 0;
            self.scroll_bottom = nr - 1;
        } else {
            if (drop > 0) {
                self.scroll_top = if (@as(usize, self.scroll_top) >= drop) @intCast(@as(usize, self.scroll_top) - drop) else 0;
                self.scroll_bottom = if (@as(usize, self.scroll_bottom) >= drop) @intCast(@as(usize, self.scroll_bottom) - drop) else 0;
            }
            self.scroll_top = @min(self.scroll_top, nr - 1);
            self.scroll_bottom = @min(self.scroll_bottom, nr - 1);
            if (self.scroll_top >= self.scroll_bottom) {
                self.scroll_top = 0;
                self.scroll_bottom = nr - 1;
            }
        }

        self.saved.x = @min(self.saved.x, nc - 1);
        self.saved.y = @min(self.saved.y, nr - 1);
        self.alt_saved.x = @min(self.alt_saved.x, nc - 1);
        self.alt_saved.y = @min(self.alt_saved.y, nr - 1);
    }

    pub fn feed(self: *Vt, bytes: []const u8) void {
        for (bytes) |b| self.consume(b);
    }

    /// One screen row, `ncols` cells, with the scrollback view applied. Rows
    /// past `nrows` return an empty slice.
    pub fn line(self: *const Vt, row: u16) []const Cell {
        if (row >= self.nrows) return &[_]Cell{};
        const c = @as(usize, self.ncols);
        const r = @as(usize, row);
        const n = @min(self.view, self.sb_len);
        if (n == 0) return self.cells[r * c ..][0..c];
        if (r < n) {
            const from_oldest = self.sb_len - n + r;
            const phys = (self.sb_head + from_oldest) % max_scrollback;
            return self.sb[phys * c ..][0..c];
        }
        const live = r - n;
        if (live >= self.nrows) return &[_]Cell{};
        return self.cells[live * c ..][0..c];
    }

    pub fn cols(self: *const Vt) u16 {
        return self.ncols;
    }

    pub fn rows(self: *const Vt) u16 {
        return self.nrows;
    }

    /// The live cursor, even while the scrollback view is offset (the
    /// renderer hides it when `viewOffset` is not zero).
    pub fn cursor(self: *const Vt) Cursor {
        return self.cur;
    }

    pub fn title(self: *const Vt) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn appCursor(self: *const Vt) bool {
        return self.app_cursor;
    }

    pub fn bracketedPaste(self: *const Vt) bool {
        return self.bracketed_paste;
    }

    pub fn mouseMode(self: *const Vt) MouseMode {
        return self.mouse;
    }

    /// DA/DSR/CPR answers; reading clears the buffer.
    pub fn takeReply(self: *Vt) []const u8 {
        const n = self.reply_len;
        self.reply_len = 0;
        return self.reply_buf[0..n];
    }

    pub fn scrollbackLen(self: *const Vt) usize {
        return self.sb_len;
    }

    pub fn viewOffset(self: *const Vt) usize {
        return self.view;
    }

    pub fn setViewOffset(self: *Vt, offset: usize) void {
        self.view = @min(offset, self.sb_len);
    }

    // --- parser ---------------------------------------------------------

    fn consume(self: *Vt, b: u8) void {
        switch (self.state) {
            .ground => self.ground(b),
            .escape => self.escapeByte(b),
            .escape_intermediate => self.state = if (b == 0x1b) .escape else .ground,
            .csi_param => self.csiByte(b),
            .csi_intermediate, .csi_ignore => {
                if (b == 0x1b) {
                    self.state = .escape;
                } else if (b >= 0x40 and b <= 0x7e) {
                    self.state = .ground;
                }
            },
            .osc => self.oscByte(b),
            .osc_esc => self.oscEsc(b),
            .string => self.stringByte(b),
            .string_esc => self.state = if (b == '\\' or b == 0x07) .ground else .string,
        }
    }

    fn ground(self: *Vt, b: u8) void {
        switch (b) {
            0x1b => self.state = .escape,
            0x00, 0x07, 0x0e, 0x0f => {}, // NUL, BEL, SO, SI: ignored
            0x08 => self.backspace(),
            0x09 => self.tab(),
            0x0a, 0x0b, 0x0c => {
                self.pending_wrap = false;
                self.index();
            },
            0x0d => {
                self.cur.x = 0;
                self.pending_wrap = false;
            },
            0x7f => {},
            else => {
                if (b < 0x20) return; // other C0 controls: ignored
                if (b < 0x80) {
                    self.putCp(b);
                } else {
                    self.utf8Byte(b);
                }
            },
        }
    }

    fn utf8Byte(self: *Vt, b: u8) void {
        if (self.utf8_len == 0) {
            const need: u8 = switch (b) {
                0xc2...0xdf => 2,
                0xe0...0xef => 3,
                0xf0...0xf4 => 4,
                else => 0, // stray continuation or invalid lead: drop it
            };
            if (need == 0) return;
            self.utf8_buf[0] = b;
            self.utf8_len = 1;
            self.utf8_need = need;
            return;
        }
        if (b < 0x80 or b > 0xbf) {
            // the pending sequence was truncated; drop it and reprocess this
            // byte from the start, since it may open a new one.
            self.utf8_len = 0;
            self.utf8_need = 0;
            self.ground(b);
            return;
        }
        self.utf8_buf[@as(usize, self.utf8_len)] = b;
        self.utf8_len += 1;
        if (self.utf8_len < self.utf8_need) return;
        const cp = std.unicode.utf8Decode(self.utf8_buf[0..@as(usize, self.utf8_len)]) catch {
            self.utf8_len = 0;
            self.utf8_need = 0;
            return;
        };
        self.utf8_len = 0;
        self.utf8_need = 0;
        self.putCp(cp);
    }

    fn escapeByte(self: *Vt, b: u8) void {
        switch (b) {
            '7' => {
                self.saveCursor();
                self.state = .ground;
            },
            '8' => {
                self.restoreCursor();
                self.state = .ground;
            },
            'D' => {
                self.index();
                self.state = .ground;
            },
            'E' => {
                self.cur.x = 0;
                self.index();
                self.state = .ground;
            },
            'M' => {
                self.reverseIndex();
                self.state = .ground;
            },
            'c' => {
                self.fullReset();
                self.state = .ground;
            },
            '[' => {
                self.resetCsi();
                self.state = .csi_param;
            },
            ']' => {
                self.osc_len = 0;
                self.state = .osc;
            },
            'P', 'X', '^', '_' => self.state = .string, // DCS, SOS, PM, APC
            '\\' => self.state = .ground, // stray string terminator
            0x20...0x2f => self.state = .escape_intermediate,
            0x1b => {},
            else => self.state = .ground, // unknown final byte: ignored
        }
    }

    fn csiByte(self: *Vt, b: u8) void {
        switch (b) {
            0x30...0x39 => {
                self.param_digits = true;
                const d: u32 = b - '0';
                const v = @as(u32, self.param_value) * 10 + d;
                self.param_value = @intCast(@min(v, 9999));
                self.state = .csi_param;
            },
            ';' => {
                self.pushParam();
                self.state = .csi_param;
            },
            ':' => {
                // sub-parameters (colon-form SGR) are not implemented; keep
                // the numbers separate instead of running them together.
                self.pushParam();
                self.state = .csi_param;
            },
            '?', '>', '=', '<' => {
                if (self.param_count == 0 and !self.param_digits) self.private_byte = b;
                self.state = .csi_param;
            },
            0x20...0x2f => self.state = .csi_intermediate,
            0x40...0x7e => {
                self.pushParamIfAny();
                self.dispatchCsi(b);
                self.resetCsi();
                self.state = .ground;
            },
            0x1b => {
                self.resetCsi();
                self.state = .escape;
            },
            else => {
                if (b >= 0x80) self.state = .csi_ignore;
            },
        }
    }

    fn oscByte(self: *Vt, b: u8) void {
        switch (b) {
            0x07 => {
                self.finishOsc();
                self.state = .ground;
            },
            0x1b => self.state = .osc_esc,
            else => {
                if (self.osc_len < osc_buf_len) {
                    self.osc_buf[self.osc_len] = b;
                    self.osc_len += 1;
                }
            },
        }
    }

    fn oscEsc(self: *Vt, b: u8) void {
        self.finishOsc();
        if (b == '\\') {
            self.state = .ground;
        } else {
            // an ESC that is not ST aborts the OSC; whatever follows starts a
            // new escape sequence rather than being swallowed.
            self.state = .escape;
            self.escapeByte(b);
        }
    }

    fn stringByte(self: *Vt, b: u8) void {
        switch (b) {
            0x07 => self.state = .ground, // forgiving: BEL also ends these
            0x1b => self.state = .string_esc,
            else => {},
        }
    }

    fn finishOsc(self: *Vt) void {
        defer self.osc_len = 0;
        const buf = self.osc_buf[0..self.osc_len];
        const semi = std.mem.indexOfScalar(u8, buf, ';') orelse return;
        const code = buf[0..semi];
        // OSC 0 and 2 set the window title; 1 (icon name) and the rest are
        // ignored in v1.
        if (!std.mem.eql(u8, code, "0") and !std.mem.eql(u8, code, "2")) return;
        self.setTitle(buf[semi + 1 ..]);
    }

    fn setTitle(self: *Vt, s: []const u8) void {
        // keep the title valid UTF-8: stop at the first codepoint that would
        // not fit whole in the 64-byte cap.
        var n: usize = 0;
        while (n < s.len and n < max_title) {
            const seq_len: usize = std.unicode.utf8ByteSequenceLength(s[n]) catch break;
            if (n + seq_len > s.len or n + seq_len > max_title) break;
            _ = std.unicode.utf8Decode(s[n..][0..seq_len]) catch break;
            n += seq_len;
        }
        @memcpy(self.title_buf[0..n], s[0..n]);
        self.title_len = n;
    }

    fn pushParam(self: *Vt) void {
        if (self.param_count < max_params) {
            self.params[self.param_count] = if (self.param_digits) self.param_value else 0;
            self.param_count += 1;
        }
        self.param_value = 0;
        self.param_digits = false;
    }

    fn pushParamIfAny(self: *Vt) void {
        if (self.param_digits or self.param_count > 0) self.pushParam();
    }

    fn resetCsi(self: *Vt) void {
        self.param_count = 0;
        self.param_value = 0;
        self.param_digits = false;
        self.private_byte = 0;
    }

    fn dispatchCsi(self: *Vt, final: u8) void {
        // a private prefix marks a different command family; v1 implements
        // only the `?` mode set and ignores the rest.
        if (self.private_byte != 0) {
            switch (final) {
                'h' => self.setModes(true),
                'l' => self.setModes(false),
                else => {},
            }
            return;
        }
        switch (final) {
            'A' => self.moveUp(self.param(0, 1)),
            'B' => self.moveDown(self.param(0, 1)),
            'C' => self.moveRight(self.param(0, 1)),
            'D' => self.moveLeft(self.param(0, 1)),
            'E' => {
                self.moveDown(self.param(0, 1));
                self.cur.x = 0;
            },
            'F' => {
                self.moveUp(self.param(0, 1));
                self.cur.x = 0;
            },
            'G' => self.setCol(self.param(0, 1)),
            'H', 'f' => self.cup(self.param(0, 1), self.param(1, 1)),
            'J' => self.eraseDisplay(self.rawParam(0)),
            'K' => self.eraseLine(self.rawParam(0)),
            'L' => self.insertLines(self.param(0, 1)),
            'M' => self.deleteLines(self.param(0, 1)),
            'P' => self.deleteChars(self.param(0, 1)),
            '@' => self.insertChars(self.param(0, 1)),
            'X' => self.eraseChars(self.param(0, 1)),
            'S' => self.scrollUp(self.scroll_top, self.scroll_bottom, self.param(0, 1), true),
            'T' => self.scrollDown(self.scroll_top, self.scroll_bottom, self.param(0, 1)),
            'd' => self.setRow(self.param(0, 1)),
            '`' => self.setCol(self.param(0, 1)),
            'r' => self.setScrollRegion(),
            's' => self.saveCursor(),
            'u' => self.restoreCursor(),
            'm' => self.sgr(),
            'h' => self.setModes(true),
            'l' => self.setModes(false),
            'c' => {
                // DA1; `> c` (DA2) is a private sequence and already ignored
                if (self.rawParam(0) == 0) self.reply("\x1b[?62;c");
            },
            'n' => switch (self.rawParam(0)) {
                5 => self.reply("\x1b[0n"),
                6 => self.reportCursor(),
                else => {},
            },
            else => {},
        }
    }

    fn rawParam(self: *const Vt, i: usize) u16 {
        if (i >= self.param_count) return 0;
        return self.params[i];
    }

    fn param(self: *const Vt, i: usize, default: u16) u16 {
        const v = self.rawParam(i);
        return if (v == 0) default else v;
    }

    fn reply(self: *Vt, bytes: []const u8) void {
        const room = reply_buf_len - self.reply_len;
        const n = @min(room, bytes.len);
        if (n == 0) return;
        @memcpy(self.reply_buf[self.reply_len..][0..n], bytes[0..n]);
        self.reply_len += n;
    }

    fn reportCursor(self: *Vt) void {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
            @as(u32, self.cur.y) + 1,
            @as(u32, self.cur.x) + 1,
        }) catch return;
        self.reply(s);
    }

    // --- screen ---------------------------------------------------------

    fn putCp(self: *Vt, cp: u21) void {
        const w = width.cellWidth(cp);
        // combining marks and zero-width format characters are dropped: v1
        // draws precomposed text only, so a mark has no cell to attach to.
        if (w == 0) return;
        if (self.pending_wrap) {
            if (self.autowrap) {
                self.index();
                self.cur.x = 0;
            }
            self.pending_wrap = false;
        }
        if (w == 2 and self.ncols >= 2) {
            if (@as(u32, self.cur.x) + 2 > @as(u32, self.ncols)) {
                // the glyph cannot straddle the right edge: wrap, or sit in
                // the last two cells when autowrap is off
                if (self.autowrap and self.cur.x > 0) {
                    self.index();
                    self.cur.x = 0;
                } else {
                    self.cur.x = self.ncols - 2;
                }
            }
            self.setCell(self.cur.x, self.cur.y, self.makeCell(cp));
            // the second half of a wide glyph is marked with ch = 0 so the
            // renderer skips it (the glyph covers both cells)
            self.setCell(self.cur.x + 1, self.cur.y, .{ .ch = 0 });
            self.cur.x += 2;
            if (self.cur.x >= self.ncols) {
                self.cur.x = self.ncols - 1;
                self.pending_wrap = self.autowrap;
            }
            return;
        }
        self.setCell(self.cur.x, self.cur.y, self.makeCell(cp));
        if (self.cur.x + 1 < self.ncols) {
            self.cur.x += 1;
        } else {
            // deferred wrap: the move happens when the next printable arrives
            self.pending_wrap = self.autowrap;
        }
    }

    fn setCell(self: *Vt, x: u16, y: u16, cell: Cell) void {
        if (x >= self.ncols or y >= self.nrows) return;
        self.cells[@as(usize, y) * @as(usize, self.ncols) + @as(usize, x)] = cell;
    }

    fn makeCell(self: *const Vt, cp: u21) Cell {
        return .{ .ch = cp, .fg = self.fg, .bg = self.bg, .attr = self.attr };
    }

    fn backspace(self: *Vt) void {
        self.pending_wrap = false;
        if (self.cur.x > 0) self.cur.x -= 1;
    }

    fn tab(self: *Vt) void {
        self.pending_wrap = false;
        const next = (@as(u32, self.cur.x) / 8 + 1) * 8;
        self.cur.x = @intCast(@min(next, @as(u32, self.ncols - 1)));
    }

    fn index(self: *Vt) void {
        self.pending_wrap = false;
        if (self.cur.y == self.scroll_bottom) {
            self.scrollUp(self.scroll_top, self.scroll_bottom, 1, true);
        } else if (self.cur.y + 1 < self.nrows) {
            self.cur.y += 1;
        }
    }

    fn reverseIndex(self: *Vt) void {
        self.pending_wrap = false;
        if (self.cur.y == self.scroll_top) {
            self.scrollDown(self.scroll_top, self.scroll_bottom, 1);
        } else if (self.cur.y > 0) {
            self.cur.y -= 1;
        }
    }

    fn moveUp(self: *Vt, n: u16) void {
        self.pending_wrap = false;
        const top: u32 = if (self.origin) self.scroll_top else 0;
        const y: u32 = self.cur.y;
        const target = if (y >= n) y - n else 0;
        self.cur.y = @intCast(@max(target, top));
    }

    fn moveDown(self: *Vt, n: u16) void {
        self.pending_wrap = false;
        const bottom: u32 = if (self.origin) self.scroll_bottom else self.nrows - 1;
        self.cur.y = @intCast(@min(@as(u32, self.cur.y) + n, bottom));
    }

    fn moveLeft(self: *Vt, n: u16) void {
        self.pending_wrap = false;
        self.cur.x = if (self.cur.x >= n) self.cur.x - n else 0;
    }

    fn moveRight(self: *Vt, n: u16) void {
        self.pending_wrap = false;
        self.cur.x = @intCast(@min(@as(u32, self.cur.x) + n, @as(u32, self.ncols - 1)));
    }

    fn setCol(self: *Vt, col: u16) void {
        self.pending_wrap = false;
        self.cur.x = @min(col - 1, self.ncols - 1);
    }

    fn setRow(self: *Vt, row: u16) void {
        self.pending_wrap = false;
        if (self.origin) {
            const y = @as(u32, self.scroll_top) + row - 1;
            self.cur.y = @intCast(@min(y, @as(u32, self.scroll_bottom)));
        } else {
            self.cur.y = @min(row - 1, self.nrows - 1);
        }
    }

    fn cup(self: *Vt, row: u16, col: u16) void {
        self.setCol(col);
        self.setRow(row);
    }

    fn eraseDisplay(self: *Vt, mode: u16) void {
        self.pending_wrap = false;
        switch (mode) {
            0 => {
                self.eraseInRow(self.cur.y, self.cur.x, self.ncols - 1);
                var y = self.cur.y + 1;
                while (y < self.nrows) : (y += 1) self.blankRow(y);
            },
            1 => {
                var y: u16 = 0;
                while (y < self.cur.y) : (y += 1) self.blankRow(y);
                self.eraseInRow(self.cur.y, 0, self.cur.x);
            },
            2 => self.blankScreen(),
            3 => {
                // xterm's ED 3 also drops the saved lines
                self.blankScreen();
                self.clearScrollback();
            },
            else => {},
        }
    }

    fn eraseLine(self: *Vt, mode: u16) void {
        self.pending_wrap = false;
        switch (mode) {
            0 => self.eraseInRow(self.cur.y, self.cur.x, self.ncols - 1),
            1 => self.eraseInRow(self.cur.y, 0, self.cur.x),
            2 => self.eraseInRow(self.cur.y, 0, self.ncols - 1),
            else => {},
        }
    }

    fn eraseInRow(self: *Vt, y: u16, left: u16, right: u16) void {
        if (y >= self.nrows or left > right or left >= self.ncols) return;
        const c = @as(usize, self.ncols);
        const r = @min(right, self.ncols - 1);
        const start = @as(usize, y) * c + @as(usize, left);
        const end = @as(usize, y) * c + @as(usize, r) + 1;
        @memset(self.cells[start..end], Cell{});
    }

    fn insertChars(self: *Vt, n: u16) void {
        self.pending_wrap = false;
        const c = @as(usize, self.ncols);
        const x = @as(usize, self.cur.x);
        const row = self.cells[@as(usize, self.cur.y) * c ..][0..c];
        const count = @min(@as(usize, n), c - x);
        var i: usize = c;
        while (i > x + count) {
            i -= 1;
            row[i] = row[i - count];
        }
        @memset(row[x..][0..count], Cell{});
    }

    fn deleteChars(self: *Vt, n: u16) void {
        self.pending_wrap = false;
        const c = @as(usize, self.ncols);
        const x = @as(usize, self.cur.x);
        const row = self.cells[@as(usize, self.cur.y) * c ..][0..c];
        const count = @min(@as(usize, n), c - x);
        var i: usize = x;
        while (i + count < c) : (i += 1) row[i] = row[i + count];
        @memset(row[c - count ..], Cell{});
    }

    fn eraseChars(self: *Vt, n: u16) void {
        self.pending_wrap = false;
        const c = @as(usize, self.ncols);
        const x = @as(usize, self.cur.x);
        const row = self.cells[@as(usize, self.cur.y) * c ..][0..c];
        const count = @min(@as(usize, n), c - x);
        @memset(row[x..][0..count], Cell{});
    }

    fn insertLines(self: *Vt, n: u16) void {
        self.pending_wrap = false;
        if (self.cur.y < self.scroll_top or self.cur.y > self.scroll_bottom) return;
        self.scrollDown(self.cur.y, self.scroll_bottom, n);
    }

    fn deleteLines(self: *Vt, n: u16) void {
        self.pending_wrap = false;
        if (self.cur.y < self.scroll_top or self.cur.y > self.scroll_bottom) return;
        self.scrollUp(self.cur.y, self.scroll_bottom, n, false);
    }

    fn scrollUp(self: *Vt, top: u16, bottom: u16, n: u16, save_lines: bool) void {
        if (top > bottom or bottom >= self.nrows) return;
        const height = bottom - top + 1;
        const count = @min(n, height);
        // only lines leaving the top of the main screen become scrollback;
        // the alternate screen has none, and a scrolling region below the
        // top simply loses what scrolls out of it.
        if (save_lines and top == 0 and !self.alt_active) {
            var i: u16 = 0;
            while (i < count) : (i += 1) self.pushScrollbackRow(i);
        }
        const c = @as(usize, self.ncols);
        var y: u16 = top;
        while (y + count <= bottom) : (y += 1) {
            const dst = @as(usize, y) * c;
            const src = @as(usize, y + count) * c;
            std.mem.copyForwards(Cell, self.cells[dst..][0..c], self.cells[src..][0..c]);
        }
        while (y <= bottom) : (y += 1) self.blankRow(y);
    }

    fn scrollDown(self: *Vt, top: u16, bottom: u16, n: u16) void {
        if (top > bottom or bottom >= self.nrows) return;
        const height = bottom - top + 1;
        const count = @min(n, height);
        const c = @as(usize, self.ncols);
        var y: u16 = bottom - count + 1;
        // copy from the bottom up so a row is read before it is overwritten
        while (y > top) {
            y -= 1;
            const dst = @as(usize, y + count) * c;
            const src = @as(usize, y) * c;
            std.mem.copyForwards(Cell, self.cells[dst..][0..c], self.cells[src..][0..c]);
        }
        var i: u16 = top;
        while (i < top + count) : (i += 1) self.blankRow(i);
    }

    fn pushScrollbackRow(self: *Vt, y: u16) void {
        const c = @as(usize, self.ncols);
        var slot: usize = undefined;
        if (self.sb_len < max_scrollback) {
            slot = (self.sb_head + self.sb_len) % max_scrollback;
            self.sb_len += 1;
        } else {
            // the ring is full: the oldest line is dropped
            slot = self.sb_head;
            self.sb_head = (self.sb_head + 1) % max_scrollback;
        }
        const dst = slot * c;
        const src = @as(usize, y) * c;
        @memcpy(self.sb[dst..][0..c], self.cells[src..][0..c]);
    }

    fn blankRow(self: *Vt, y: u16) void {
        const c = @as(usize, self.ncols);
        const start = @as(usize, y) * c;
        @memset(self.cells[start..][0..c], Cell{});
    }

    fn blankScreen(self: *Vt) void {
        @memset(self.cells, Cell{});
    }

    fn clearScrollback(self: *Vt) void {
        self.sb_head = 0;
        self.sb_len = 0;
        self.view = 0;
    }

    fn setScrollRegion(self: *Vt) void {
        self.pending_wrap = false;
        if (self.param_count == 0) {
            self.scroll_top = 0;
            self.scroll_bottom = self.nrows - 1;
        } else {
            const top = self.param(0, 1);
            const bottom = self.param(1, self.nrows);
            if (top < bottom and bottom <= self.nrows) {
                self.scroll_top = top - 1;
                self.scroll_bottom = bottom - 1;
            } else {
                // an invalid region resets to the full screen (v1 is lenient)
                self.scroll_top = 0;
                self.scroll_bottom = self.nrows - 1;
            }
        }
        self.cur.x = 0;
        self.cur.y = if (self.origin) self.scroll_top else 0;
    }

    fn saveCursor(self: *Vt) void {
        self.saved = .{ .x = self.cur.x, .y = self.cur.y, .fg = self.fg, .bg = self.bg, .attr = self.attr };
        self.pending_wrap = false;
    }

    fn restoreCursor(self: *Vt) void {
        self.cur.x = @min(self.saved.x, self.ncols - 1);
        self.cur.y = @min(self.saved.y, self.nrows - 1);
        self.fg = self.saved.fg;
        self.bg = self.saved.bg;
        self.attr = self.saved.attr;
        self.pending_wrap = false;
    }

    fn sgr(self: *Vt) void {
        if (self.param_count == 0) {
            self.resetAttrs();
            return;
        }
        var i: usize = 0;
        while (i < self.param_count) : (i += 1) {
            switch (self.params[i]) {
                0 => self.resetAttrs(),
                1 => self.attr.bold = true,
                2 => self.attr.dim = true,
                3 => self.attr.italic = true,
                4 => self.attr.underline = true,
                5 => self.attr.blink = true,
                7 => self.attr.reverse = true,
                8 => self.attr.hidden = true,
                9 => self.attr.strike = true,
                21 => self.attr.bold = false, // double underline in ECMA-48; bold off in practice
                22 => {
                    self.attr.bold = false;
                    self.attr.dim = false;
                },
                23 => self.attr.italic = false,
                24 => self.attr.underline = false,
                25 => self.attr.blink = false,
                27 => self.attr.reverse = false,
                28 => self.attr.hidden = false,
                29 => self.attr.strike = false,
                30...37 => self.fg = .{ .indexed = @intCast(self.params[i] - 30) },
                39 => self.fg = .default,
                40...47 => self.bg = .{ .indexed = @intCast(self.params[i] - 40) },
                49 => self.bg = .default,
                90...97 => self.fg = .{ .indexed = @intCast(self.params[i] - 90 + 8) },
                100...107 => self.bg = .{ .indexed = @intCast(self.params[i] - 100 + 8) },
                38, 48 => {
                    const is_fg = self.params[i] == 38;
                    if (i + 1 < self.param_count) {
                        const kind = self.params[i + 1];
                        if (kind == 5 and i + 2 < self.param_count) {
                            const col: u8 = @intCast(@min(self.params[i + 2], 255));
                            if (is_fg) self.fg = .{ .indexed = col } else self.bg = .{ .indexed = col };
                            i += 2;
                        } else if (kind == 2 and i + 4 < self.param_count) {
                            const r: u8 = @intCast(@min(self.params[i + 2], 255));
                            const g: u8 = @intCast(@min(self.params[i + 3], 255));
                            const b: u8 = @intCast(@min(self.params[i + 4], 255));
                            if (is_fg) {
                                self.fg = .{ .rgb = .{ .r = r, .g = g, .b = b } };
                            } else {
                                self.bg = .{ .rgb = .{ .r = r, .g = g, .b = b } };
                            }
                            i += 4;
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn resetAttrs(self: *Vt) void {
        self.fg = .default;
        self.bg = .default;
        self.attr = .{};
    }

    fn setModes(self: *Vt, on: bool) void {
        // non-private modes (insert, line feed/new line) are not implemented
        if (self.private_byte != '?') return;
        var i: usize = 0;
        while (i < self.param_count) : (i += 1) {
            switch (self.params[i]) {
                1 => self.app_cursor = on,
                6 => self.setOrigin(on),
                7 => self.autowrap = on,
                25 => self.cur.visible = on,
                47, 1047, 1049 => self.setAlt(on),
                1000 => self.mouse = if (on) .click else .off,
                1002 => self.mouse = if (on) .drag else .off,
                2004 => self.bracketed_paste = on,
                else => {}, // unknown modes are ignored
            }
        }
    }

    fn setOrigin(self: *Vt, on: bool) void {
        self.origin = on;
        self.pending_wrap = false;
        self.cur.x = 0;
        self.cur.y = if (on) self.scroll_top else 0;
    }

    fn setAlt(self: *Vt, on: bool) void {
        if (on == self.alt_active) return;
        if (on) {
            // 1049 semantics: remember where the main cursor was, clear the
            // alternate screen and home the cursor.
            self.alt_saved = .{ .x = self.cur.x, .y = self.cur.y, .fg = self.fg, .bg = self.bg, .attr = self.attr };
            std.mem.swap([]Cell, &self.cells, &self.other);
            self.alt_active = true;
            @memset(self.cells, Cell{});
            self.cur.x = 0;
            self.cur.y = 0;
            self.pending_wrap = false;
            self.view = 0;
        } else {
            std.mem.swap([]Cell, &self.cells, &self.other);
            self.alt_active = false;
            self.cur.x = @min(self.alt_saved.x, self.ncols - 1);
            self.cur.y = @min(self.alt_saved.y, self.nrows - 1);
            self.fg = self.alt_saved.fg;
            self.bg = self.alt_saved.bg;
            self.attr = self.alt_saved.attr;
            self.pending_wrap = false;
        }
        // v1 keeps one scroll region for both screens
        self.scroll_top = 0;
        self.scroll_bottom = self.nrows - 1;
    }

    fn fullReset(self: *Vt) void {
        self.resetAttrs();
        self.origin = false;
        self.autowrap = true;
        self.app_cursor = false;
        self.bracketed_paste = false;
        self.mouse = .off;
        self.cur = .{ .x = 0, .y = 0 };
        self.pending_wrap = false;
        self.scroll_top = 0;
        self.scroll_bottom = self.nrows - 1;
        self.blankScreen();
        self.clearScrollback();
        self.utf8_len = 0;
        self.utf8_need = 0;
        if (self.alt_active) {
            std.mem.swap([]Cell, &self.cells, &self.other);
            self.alt_active = false;
            @memset(self.other, Cell{});
        }
        // the title is left alone: the shell sets it again on startup
    }
};

fn clampSize(v: u16, max: u16) u16 {
    if (v == 0) return 1;
    return @min(v, max);
}

fn copyRow(dst: []Cell, src: []const Cell) void {
    const n = @min(dst.len, src.len);
    if (n > 0) @memcpy(dst[0..n], src[0..n]);
}

fn copyScreen(dst: []Cell, src: []const Cell, old_c: usize, old_r: usize, new_c: usize, new_r: usize, drop: usize) void {
    var y: usize = 0;
    while (y < new_r) : (y += 1) {
        const src_y = y + drop;
        if (src_y >= old_r) break;
        copyRow(dst[y * new_c ..][0..new_c], src[src_y * old_c ..][0..old_c]);
    }
}

fn ringPush(ring: []Cell, cap: usize, head: *usize, len: *usize, cols: usize, src: []const Cell) void {
    var slot: usize = undefined;
    if (len.* < cap) {
        slot = (head.* + len.*) % cap;
        len.* += 1;
    } else {
        slot = head.*;
        head.* = (head.* + 1) % cap;
    }
    const dst = ring[slot * cols ..][0..cols];
    const n = @min(cols, src.len);
    if (n > 0) @memcpy(dst[0..n], src[0..n]);
    if (n < cols) @memset(dst[n..], Cell{});
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

/// Decode a row back to text, skipping wide-glyph continuation cells and
/// trimming trailing blanks.
fn expectRow(v: *const Vt, y: u16, want: []const u8) !void {
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    for (v.line(y)) |cell| {
        if (cell.ch == 0) continue;
        var tmp: [4]u8 = undefined;
        const len: usize = std.unicode.utf8Encode(cell.ch, &tmp) catch continue;
        if (n + len > buf.len) break;
        @memcpy(buf[n..][0..len], tmp[0..len]);
        n += len;
    }
    try testing.expectEqualStrings(want, std.mem.trimEnd(u8, buf[0..n], " "));
}

fn expectColor(actual: Color, want: Color) !void {
    const ok = switch (want) {
        .default => switch (actual) {
            .default => true,
            else => false,
        },
        .indexed => |w| switch (actual) {
            .indexed => |a| a == w,
            else => false,
        },
        .rgb => |w| switch (actual) {
            .rgb => |a| a.r == w.r and a.g == w.g and a.b == w.b,
            else => false,
        },
    };
    try testing.expect(ok);
}

test "plain text fills cells and wraps at the right edge" {
    var v = try Vt.init(testing.allocator, 4, 2);
    defer v.deinit();
    v.feed("ab");
    try expectRow(&v, 0, "ab");
    v.feed("cdef");
    try expectRow(&v, 0, "abcd");
    try expectRow(&v, 1, "ef");
    try testing.expectEqual(@as(u16, 1), v.cursor().y);
    try testing.expectEqual(@as(u16, 2), v.cursor().x);
}

test "deferred wrap waits for the next printable" {
    var v = try Vt.init(testing.allocator, 3, 2);
    defer v.deinit();
    v.feed("abc");
    // the line is full but the cursor has not wrapped yet
    try testing.expectEqual(@as(u16, 0), v.cursor().y);
    try testing.expectEqual(@as(u16, 2), v.cursor().x);
    v.feed("d");
    try expectRow(&v, 0, "abc");
    try expectRow(&v, 1, "d");
    try testing.expectEqual(@as(u16, 1), v.cursor().y);
    try testing.expectEqual(@as(u16, 1), v.cursor().x);
}

test "deferred wrap scrolls only when the wrap happens" {
    var v = try Vt.init(testing.allocator, 3, 1);
    defer v.deinit();
    v.feed("abc");
    try testing.expectEqual(@as(usize, 0), v.scrollbackLen());
    v.feed("d");
    try testing.expectEqual(@as(usize, 1), v.scrollbackLen());
    try expectRow(&v, 0, "d");
    try testing.expectEqual(@as(u16, 0), v.cursor().y);
}

test "cr lf vt ff and reverse index" {
    var v = try Vt.init(testing.allocator, 4, 3);
    defer v.deinit();
    v.feed("ab\r\ncd");
    try expectRow(&v, 1, "cd");
    try testing.expectEqual(@as(u16, 2), v.cursor().x);
    // reverse index at the top scrolls the screen down
    v.feed("\x1b[1;1H\x1bM");
    try expectRow(&v, 0, "");
    try expectRow(&v, 1, "ab");
    try expectRow(&v, 2, "cd");
    // vt and ff index like lf
    v.feed("\x1b[2;1H\x0b");
    try testing.expectEqual(@as(u16, 2), v.cursor().y);
    v.feed("\x0c");
    try testing.expectEqual(@as(u16, 2), v.cursor().y);
}

test "cursor moves clamp to the screen" {
    var v = try Vt.init(testing.allocator, 5, 3);
    defer v.deinit();
    v.feed("\x1b[10;10H");
    try testing.expectEqual(@as(u16, 4), v.cursor().x);
    try testing.expectEqual(@as(u16, 2), v.cursor().y);
    v.feed("\x1b[99A");
    try testing.expectEqual(@as(u16, 0), v.cursor().y);
    v.feed("\x1b[99D");
    try testing.expectEqual(@as(u16, 0), v.cursor().x);
    v.feed("\x1b[99B");
    try testing.expectEqual(@as(u16, 2), v.cursor().y);
    v.feed("\x1b[99C");
    try testing.expectEqual(@as(u16, 4), v.cursor().x);
    v.feed("\x1b[2;3H\x1b[1A\x1b[1D");
    try testing.expectEqual(@as(u16, 0), v.cursor().y);
    try testing.expectEqual(@as(u16, 1), v.cursor().x);
}

test "cup and hvp default to 1,1" {
    var v = try Vt.init(testing.allocator, 5, 3);
    defer v.deinit();
    v.feed("\x1b[3;4H");
    try testing.expectEqual(@as(u16, 2), v.cursor().y);
    try testing.expectEqual(@as(u16, 3), v.cursor().x);
    v.feed("\x1b[H");
    try testing.expectEqual(@as(u16, 0), v.cursor().y);
    try testing.expectEqual(@as(u16, 0), v.cursor().x);
    v.feed("\x1b[2;3f");
    try testing.expectEqual(@as(u16, 1), v.cursor().y);
    try testing.expectEqual(@as(u16, 2), v.cursor().x);
    v.feed("\x1b[;H");
    try testing.expectEqual(@as(u16, 0), v.cursor().y);
    try testing.expectEqual(@as(u16, 0), v.cursor().x);
}

test "cha hpa and vpa set the column and row" {
    var v = try Vt.init(testing.allocator, 5, 3);
    defer v.deinit();
    v.feed("\x1b[4G");
    try testing.expectEqual(@as(u16, 3), v.cursor().x);
    v.feed("\x1b[2`");
    try testing.expectEqual(@as(u16, 1), v.cursor().x);
    v.feed("\x1b[3d");
    try testing.expectEqual(@as(u16, 2), v.cursor().y);
    v.feed("\x1b[99d");
    try testing.expectEqual(@as(u16, 2), v.cursor().y);
}

test "erase display variants" {
    var v = try Vt.init(testing.allocator, 4, 3);
    defer v.deinit();
    v.feed("aaaa\r\nbbbb\r\ncccc");
    v.feed("\x1b[2;2H\x1b[0J");
    try expectRow(&v, 0, "aaaa");
    try expectRow(&v, 1, "b");
    try expectRow(&v, 2, "");
    v.feed("\x1b[2J");
    v.feed("\x1b[1;1Haaaa\r\nbbbb\r\ncccc");
    v.feed("\x1b[2;2H\x1b[1J");
    try expectRow(&v, 0, "");
    try expectRow(&v, 1, "  bb");
    try expectRow(&v, 2, "cccc");
}

test "erase line variants" {
    var v = try Vt.init(testing.allocator, 5, 1);
    defer v.deinit();
    v.feed("abcde\x1b[1;3H\x1b[0K");
    try expectRow(&v, 0, "ab");
    v.feed("\x1b[1;1Habcde\x1b[1;3H\x1b[1K");
    try expectRow(&v, 0, "   de");
    v.feed("\x1b[1;1Habcde\x1b[1;3H\x1b[2K");
    try expectRow(&v, 0, "");
}

test "insert and delete characters" {
    var v = try Vt.init(testing.allocator, 6, 1);
    defer v.deinit();
    v.feed("abcdef");
    v.feed("\x1b[1;3H\x1b[2@");
    try expectRow(&v, 0, "ab  cd");
    v.feed("\x1b[1;1H\x1b[2P");
    try expectRow(&v, 0, "  cd");
}

test "erase characters blanks a run" {
    var v = try Vt.init(testing.allocator, 6, 1);
    defer v.deinit();
    v.feed("abcdef");
    v.feed("\x1b[1;2H\x1b[3X");
    try expectRow(&v, 0, "a   ef");
}

test "insert and delete lines in the scroll region" {
    var v = try Vt.init(testing.allocator, 4, 4);
    defer v.deinit();
    v.feed("1\r\n2\r\n3\r\n4");
    v.feed("\x1b[2;1H\x1b[2L");
    try expectRow(&v, 0, "1");
    try expectRow(&v, 1, "");
    try expectRow(&v, 2, "");
    try expectRow(&v, 3, "2");
    v.feed("\x1b[1;1H\x1b[2M");
    try expectRow(&v, 0, "");
    try expectRow(&v, 1, "2");
    try expectRow(&v, 2, "");
    try expectRow(&v, 3, "");
}

test "sgr sets attributes and indexed colours" {
    var v = try Vt.init(testing.allocator, 4, 1);
    defer v.deinit();
    v.feed("\x1b[1;4;31;44mA\x1b[0mB\x1b[91;104mC");
    const a = v.line(0)[0];
    try testing.expectEqual(@as(u21, 'A'), a.ch);
    try testing.expect(a.attr.bold and a.attr.underline);
    try testing.expect(!a.attr.dim and !a.attr.italic);
    try expectColor(a.fg, .{ .indexed = 1 });
    try expectColor(a.bg, .{ .indexed = 4 });
    const b = v.line(0)[1];
    try testing.expect(!b.attr.bold and !b.attr.underline);
    try expectColor(b.fg, .default);
    try expectColor(b.bg, .default);
    const c = v.line(0)[2];
    try expectColor(c.fg, .{ .indexed = 9 });
    try expectColor(c.bg, .{ .indexed = 12 });
}

test "sgr 256 colour and truecolour" {
    var v = try Vt.init(testing.allocator, 4, 1);
    defer v.deinit();
    v.feed("\x1b[38;5;196;48;5;17mX");
    const x = v.line(0)[0];
    try expectColor(x.fg, .{ .indexed = 196 });
    try expectColor(x.bg, .{ .indexed = 17 });
    v.feed("\x1b[38;2;10;20;30;48;2;1;2;3mY");
    const y = v.line(0)[1];
    try expectColor(y.fg, .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } });
    try expectColor(y.bg, .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } });
}

test "sgr resets clear attributes and colours" {
    var v = try Vt.init(testing.allocator, 3, 1);
    defer v.deinit();
    v.feed("\x1b[1;2;3;4;5;7;8;9;38;5;9;48;2;1;2;3mZ");
    v.feed("\x1b[22;23;24;25;27;28;29;39;49mZ");
    const z = v.line(0)[1];
    try testing.expect(!z.attr.bold and !z.attr.dim and !z.attr.italic);
    try testing.expect(!z.attr.underline and !z.attr.blink and !z.attr.reverse);
    try testing.expect(!z.attr.hidden and !z.attr.strike);
    try expectColor(z.fg, .default);
    try expectColor(z.bg, .default);
    // 21 turns bold off
    v.feed("\x1b[1m\x1b[21mQ");
    try testing.expect(!v.line(0)[2].attr.bold);
}

test "scroll region confines line feeds and reverse index" {
    var v = try Vt.init(testing.allocator, 2, 4);
    defer v.deinit();
    v.feed("\x1b[2;3r"); // rows 2..3, 1-based
    // rows outside the region are untouched by scrolling
    v.feed("\x1b[1;1HA\x1b[4;1HD\x1b[2;1Hb\x1b[3;1Hc");
    try expectRow(&v, 0, "A");
    try expectRow(&v, 1, "b");
    try expectRow(&v, 2, "c");
    try expectRow(&v, 3, "D");
    v.feed("\x1b[3;1H\n"); // lf at the bottom of the region
    try expectRow(&v, 0, "A");
    try expectRow(&v, 1, "c");
    try expectRow(&v, 2, "");
    try expectRow(&v, 3, "D");
    // reverse index at the top of the region scrolls down inside it
    v.feed("\x1b[2;1H\x1bM");
    try expectRow(&v, 0, "A");
    try expectRow(&v, 1, "");
    try expectRow(&v, 2, "c");
    try expectRow(&v, 3, "D");
}

test "su and sd scroll the region and feed the scrollback" {
    var v = try Vt.init(testing.allocator, 3, 3);
    defer v.deinit();
    v.feed("1\r\n2\r\n3");
    v.feed("\x1b[1S");
    try expectRow(&v, 0, "2");
    try expectRow(&v, 1, "3");
    try expectRow(&v, 2, "");
    try testing.expectEqual(@as(usize, 1), v.scrollbackLen());
    v.feed("\x1b[1T");
    try expectRow(&v, 0, "");
    try expectRow(&v, 1, "2");
    try expectRow(&v, 2, "3");
}

test "esc 7 and esc 8 save and restore the cursor and attributes" {
    var v = try Vt.init(testing.allocator, 5, 3);
    defer v.deinit();
    v.feed("\x1b[2;3H\x1b[31;44m\x1b7");
    v.feed("\x1b[1;1H\x1b[0m");
    v.feed("\x1b8x");
    const c = v.line(1)[2];
    try testing.expectEqual(@as(u21, 'x'), c.ch);
    try expectColor(c.fg, .{ .indexed = 1 });
    try expectColor(c.bg, .{ .indexed = 4 });
}

test "csi s and u save and restore the cursor" {
    var v = try Vt.init(testing.allocator, 5, 3);
    defer v.deinit();
    v.feed("\x1b[2;3H\x1b[s");
    v.feed("\x1b[1;1H");
    v.feed("\x1b[u");
    try testing.expectEqual(@as(u16, 2), v.cursor().x);
    try testing.expectEqual(@as(u16, 1), v.cursor().y);
    v.feed("x");
    try testing.expectEqual(@as(u21, 'x'), v.line(1)[2].ch);
}

test "alternate screen clears and restores the main screen" {
    var v = try Vt.init(testing.allocator, 4, 2);
    defer v.deinit();
    v.feed("main");
    v.feed("\x1b[?1049h");
    try expectRow(&v, 0, "");
    try testing.expectEqual(@as(u16, 0), v.cursor().x);
    v.feed("alt");
    try expectRow(&v, 0, "alt");
    v.feed("\x1b[?1049l");
    try expectRow(&v, 0, "main");
    try testing.expectEqual(@as(u16, 3), v.cursor().x);
    try testing.expectEqual(@as(u16, 0), v.cursor().y);
}

test "alternate screen 1047 also clears and restores" {
    var v = try Vt.init(testing.allocator, 4, 2);
    defer v.deinit();
    v.feed("main\x1b[?1047halt\x1b[?1047l");
    try expectRow(&v, 0, "main");
}

test "autowrap off overwrites the last cell" {
    var v = try Vt.init(testing.allocator, 3, 2);
    defer v.deinit();
    v.feed("\x1b[?7labcde");
    try expectRow(&v, 0, "abe");
    try expectRow(&v, 1, "");
    try testing.expectEqual(@as(u16, 2), v.cursor().x);
    try testing.expectEqual(@as(u16, 0), v.cursor().y);
}

test "wide characters take two cells" {
    var v = try Vt.init(testing.allocator, 4, 2);
    defer v.deinit();
    v.feed("\xe4\xb8\xada"); // U+4E2D is East Asian Wide
    try testing.expectEqual(@as(u21, 0x4e2d), v.line(0)[0].ch);
    try testing.expectEqual(@as(u21, 0), v.line(0)[1].ch);
    try testing.expectEqual(@as(u21, 'a'), v.line(0)[2].ch);
    try testing.expectEqual(@as(u16, 3), v.cursor().x);
}

test "a wide character wraps instead of straddling the edge" {
    var v = try Vt.init(testing.allocator, 3, 2);
    defer v.deinit();
    v.feed("ab\xe4\xb8\xad");
    try expectRow(&v, 0, "ab");
    try testing.expectEqual(@as(u21, 0x4e2d), v.line(1)[0].ch);
    try testing.expectEqual(@as(u21, 0), v.line(1)[1].ch);
    try testing.expectEqual(@as(u16, 1), v.cursor().y);
}

test "combining marks are dropped" {
    var v = try Vt.init(testing.allocator, 3, 1);
    defer v.deinit();
    v.feed("e\xcc\x81x"); // e + combining acute + x
    try testing.expectEqual(@as(u21, 'e'), v.line(0)[0].ch);
    try testing.expectEqual(@as(u21, 'x'), v.line(0)[1].ch);
    try testing.expectEqual(@as(u16, 2), v.cursor().x);
}

test "utf-8 split across feeds resumes" {
    var v = try Vt.init(testing.allocator, 4, 1);
    defer v.deinit();
    v.feed("\xe4\xb8");
    try testing.expectEqual(@as(u16, 0), v.cursor().x);
    try testing.expectEqual(@as(u21, ' '), v.line(0)[0].ch);
    v.feed("\xad");
    try testing.expectEqual(@as(u21, 0x4e2d), v.line(0)[0].ch);
    try testing.expectEqual(@as(u16, 2), v.cursor().x);
}

test "osc sets the title from 0 and 2 and ignores others" {
    var v = try Vt.init(testing.allocator, 8, 1);
    defer v.deinit();
    v.feed("\x1b]0;hello\x07");
    try testing.expectEqualStrings("hello", v.title());
    v.feed("\x1b]2;world\x1b\\");
    try testing.expectEqualStrings("world", v.title());
    v.feed("\x1b]1;icon\x07");
    try testing.expectEqualStrings("world", v.title());
    v.feed("ok");
    try expectRow(&v, 0, "ok");
}

test "the title is capped at 64 bytes" {
    var v = try Vt.init(testing.allocator, 8, 1);
    defer v.deinit();
    var buf: [100]u8 = undefined;
    @memset(buf[0..], 'x');
    v.feed("\x1b]0;");
    v.feed(&buf);
    v.feed("\x07");
    try testing.expectEqual(@as(usize, 64), v.title().len);
}

test "da and dsr replies" {
    var v = try Vt.init(testing.allocator, 5, 3);
    defer v.deinit();
    v.feed("\x1b[c");
    try testing.expectEqualStrings("\x1b[?62;c", v.takeReply());
    v.feed("\x1b[5n");
    try testing.expectEqualStrings("\x1b[0n", v.takeReply());
    try testing.expectEqualStrings("", v.takeReply());
}

test "cpr reports the cursor position" {
    var v = try Vt.init(testing.allocator, 5, 3);
    defer v.deinit();
    v.feed("\x1b[2;3H\x1b[6n");
    try testing.expectEqualStrings("\x1b[2;3R", v.takeReply());
}

test "scrollback ring keeps the newest 2000 lines" {
    var v = try Vt.init(testing.allocator, 2, 2);
    defer v.deinit();
    var i: usize = 0;
    while (i < 2100) : (i += 1) v.feed("x\r\n");
    try testing.expectEqual(@as(usize, 2000), v.scrollbackLen());
}

test "view offset shows scrollback above the live screen" {
    var v = try Vt.init(testing.allocator, 3, 2);
    defer v.deinit();
    v.feed("a\r\nb\r\nc");
    try testing.expectEqual(@as(usize, 1), v.scrollbackLen());
    v.setViewOffset(1);
    try testing.expectEqual(@as(usize, 1), v.viewOffset());
    try expectRow(&v, 0, "a");
    try expectRow(&v, 1, "b");
    v.setViewOffset(99);
    try testing.expectEqual(@as(usize, 1), v.viewOffset());
    v.setViewOffset(0);
    try expectRow(&v, 0, "b");
    try expectRow(&v, 1, "c");
    try testing.expectEqual(@as(u16, 1), v.cursor().y);
}

test "resize grow keeps content and pads blanks" {
    var v = try Vt.init(testing.allocator, 4, 2);
    defer v.deinit();
    v.feed("ab\r\ncd");
    try v.resize(6, 4);
    try testing.expectEqual(@as(u16, 6), v.cols());
    try testing.expectEqual(@as(u16, 4), v.rows());
    try expectRow(&v, 0, "ab");
    try expectRow(&v, 1, "cd");
    try expectRow(&v, 2, "");
    try expectRow(&v, 3, "");
    try testing.expectEqual(@as(u16, 1), v.cursor().y);
    try testing.expectEqual(@as(u16, 2), v.cursor().x);
    try testing.expectEqual(@as(usize, 0), v.scrollbackLen());
}

test "resize shrink moves the top rows into scrollback" {
    var v = try Vt.init(testing.allocator, 4, 4);
    defer v.deinit();
    v.feed("1\r\n2\r\n3\r\n4");
    try v.resize(4, 2);
    try expectRow(&v, 0, "3");
    try expectRow(&v, 1, "4");
    try testing.expectEqual(@as(usize, 2), v.scrollbackLen());
    try testing.expectEqual(@as(u16, 1), v.cursor().y);
    v.setViewOffset(2);
    try expectRow(&v, 0, "1");
    try expectRow(&v, 1, "2");
}

test "resize clamps the cursor" {
    var v = try Vt.init(testing.allocator, 6, 3);
    defer v.deinit();
    v.feed("\x1b[3;6H");
    try v.resize(3, 2);
    try testing.expect(v.cursor().x < v.cols());
    try testing.expect(v.cursor().y < v.rows());
    try testing.expectEqual(@as(u16, 2), v.cursor().x);
    try testing.expectEqual(@as(u16, 1), v.cursor().y);
}

test "origin mode makes cup relative to the scroll region" {
    var v = try Vt.init(testing.allocator, 5, 4);
    defer v.deinit();
    v.feed("\x1b[2;3r");
    v.feed("\x1b[?6h");
    try testing.expectEqual(@as(u16, 1), v.cursor().y);
    v.feed("\x1b[1;1H");
    try testing.expectEqual(@as(u16, 1), v.cursor().y);
    v.feed("\x1b[2;1H");
    try testing.expectEqual(@as(u16, 2), v.cursor().y);
    v.feed("\x1b[9;1H");
    try testing.expectEqual(@as(u16, 2), v.cursor().y);
    v.feed("\x1b[?6l");
    v.feed("\x1b[3;1H");
    try testing.expectEqual(@as(u16, 2), v.cursor().y);
}

test "ht moves to the next multiple of eight" {
    var v = try Vt.init(testing.allocator, 20, 1);
    defer v.deinit();
    v.feed("a\tb");
    try testing.expectEqual(@as(u21, 'b'), v.line(0)[8].ch);
    try testing.expectEqual(@as(u16, 9), v.cursor().x);
    v.feed("\t");
    try testing.expectEqual(@as(u16, 16), v.cursor().x);
    v.feed("\t");
    try testing.expectEqual(@as(u16, 19), v.cursor().x);
}

test "modes report app cursor mouse and bracketed paste" {
    var v = try Vt.init(testing.allocator, 4, 2);
    defer v.deinit();
    try testing.expect(!v.appCursor());
    v.feed("\x1b[?1h\x1b[?2004h\x1b[?1000h");
    try testing.expect(v.appCursor());
    try testing.expect(v.bracketedPaste());
    try testing.expectEqual(MouseMode.click, v.mouseMode());
    v.feed("\x1b[?1002h");
    try testing.expectEqual(MouseMode.drag, v.mouseMode());
    v.feed("\x1b[?1002l\x1b[?1000l");
    try testing.expectEqual(MouseMode.off, v.mouseMode());
    v.feed("\x1b[?25l");
    try testing.expect(!v.cursor().visible);
    v.feed("\x1b[?25h");
    try testing.expect(v.cursor().visible);
    v.feed("\x1b[?9999h");
    try testing.expect(v.appCursor());
}

test "ed 3 clears the scrollback" {
    var v = try Vt.init(testing.allocator, 2, 2);
    defer v.deinit();
    v.feed("a\r\nb\r\nc");
    try testing.expectEqual(@as(usize, 1), v.scrollbackLen());
    v.feed("\x1b[3J");
    try testing.expectEqual(@as(usize, 0), v.scrollbackLen());
    try expectRow(&v, 0, "");
    try expectRow(&v, 1, "");
}

test "dcs and apc payloads are consumed, not printed" {
    var v = try Vt.init(testing.allocator, 8, 1);
    defer v.deinit();
    v.feed("\x1bPq#stuff\x1b\\ok");
    try expectRow(&v, 0, "ok");
    v.feed("\x1b_apc\x07ok");
    try expectRow(&v, 0, "okok");
    v.feed("\x1b^pm\x1b\\x");
    try expectRow(&v, 0, "okokx");
}

test "ris resets modes attributes and the screen" {
    var v = try Vt.init(testing.allocator, 4, 2);
    defer v.deinit();
    v.feed("\x1b[1;31mab\r\ncd\x1b[?25l\x1b[?7l\x1b[2;3r");
    v.feed("\x1bc");
    try expectRow(&v, 0, "");
    try expectRow(&v, 1, "");
    try testing.expectEqual(@as(u16, 0), v.cursor().x);
    try testing.expectEqual(@as(u16, 0), v.cursor().y);
    try testing.expect(v.cursor().visible);
    v.feed("x");
    const c = v.line(0)[0];
    try expectColor(c.fg, .default);
    try testing.expect(!c.attr.bold);
    // autowrap is back on: the fifth character wraps
    v.feed("abcd");
    try testing.expectEqual(@as(u16, 1), v.cursor().y);
}

test "fuzz: arbitrary bytes never panic or leave the grid" {
    var v = try Vt.init(testing.allocator, 17, 5);
    defer v.deinit();
    var prng = std.Random.DefaultPrng.init(0x5eed_1234);
    const rand = prng.random();
    var buf: [128]u8 = undefined;
    var round: usize = 0;
    while (round < 400) : (round += 1) {
        rand.bytes(&buf);
        const len = rand.uintLessThan(usize, buf.len + 1);
        v.feed(buf[0..len]);
        if (round % 37 == 0) {
            const nc = rand.uintLessThan(u16, 40) + 1;
            const nr = rand.uintLessThan(u16, 12) + 1;
            try v.resize(nc, nr);
        }
        try testing.expectEqual(@as(usize, v.cols()), v.line(0).len);
        const cur = v.cursor();
        try testing.expect(cur.x < v.cols());
        try testing.expect(cur.y < v.rows());
        try testing.expect(v.viewOffset() <= v.scrollbackLen());
    }
}
