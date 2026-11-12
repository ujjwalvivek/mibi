//! Input as the editor sees it: keys, mouse, paste, focus. The platform layer
//! turns terminal bytes (Unix) or console records (Windows) into these; from
//! here on nothing knows what an escape sequence is.

const std = @import("std");

pub const Mods = packed struct(u8) {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    _pad: u5 = 0,

    pub fn none(self: Mods) bool {
        return @as(u8, @bitCast(self)) == 0;
    }
};

/// Keys that are not characters.
pub const Special = enum(u8) {
    none,
    enter,
    tab,
    backspace,
    esc,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

const special_names = [_]struct { name: []const u8, special: Special }{
    .{ .name = "enter", .special = .enter },
    .{ .name = "tab", .special = .tab },
    .{ .name = "backspace", .special = .backspace },
    .{ .name = "esc", .special = .esc },
    .{ .name = "up", .special = .up },
    .{ .name = "down", .special = .down },
    .{ .name = "left", .special = .left },
    .{ .name = "right", .special = .right },
    .{ .name = "home", .special = .home },
    .{ .name = "end", .special = .end },
    .{ .name = "pgup", .special = .page_up },
    .{ .name = "pgdn", .special = .page_down },
    .{ .name = "insert", .special = .insert },
    .{ .name = "delete", .special = .delete },
    .{ .name = "f1", .special = .f1 },
    .{ .name = "f2", .special = .f2 },
    .{ .name = "f3", .special = .f3 },
    .{ .name = "f4", .special = .f4 },
    .{ .name = "f5", .special = .f5 },
    .{ .name = "f6", .special = .f6 },
    .{ .name = "f7", .special = .f7 },
    .{ .name = "f8", .special = .f8 },
    .{ .name = "f9", .special = .f9 },
    .{ .name = "f10", .special = .f10 },
    .{ .name = "f11", .special = .f11 },
    .{ .name = "f12", .special = .f12 },
    // Spellings people type in a config file.
    .{ .name = "escape", .special = .esc },
    .{ .name = "return", .special = .enter },
    .{ .name = "pageup", .special = .page_up },
    .{ .name = "pagedown", .special = .page_down },
    .{ .name = "del", .special = .delete },
};

/// One key press. Either `special` is set, or `cp` is the character.
///
/// A character typed as text has no modifiers: Shift is already in the
/// character (`A`, not shift+`a`). A character with Ctrl or Alt is a
/// shortcut and is always lower case (`ctrl+s`), with `shift` set only when
/// the platform can tell (Windows can, most Unix terminals cannot).
pub const Key = struct {
    cp: u21 = 0,
    special: Special = .none,
    mods: Mods = .{},

    pub fn char(cp: u21) Key {
        return .{ .cp = cp };
    }

    pub fn ctrl(cp: u21) Key {
        return .{ .cp = cp, .mods = .{ .ctrl = true } };
    }

    pub fn named(special: Special, mods: Mods) Key {
        return .{ .special = special, .mods = mods };
    }

    pub fn eql(a: Key, b: Key) bool {
        return a.cp == b.cp and a.special == b.special and
            @as(u8, @bitCast(a.mods)) == @as(u8, @bitCast(b.mods));
    }

    /// A character to insert, as opposed to a shortcut.
    pub fn isText(self: Key) bool {
        return self.special == .none and self.cp >= 0x20 and self.cp != 0x7f and
            !self.mods.ctrl and !self.mods.alt;
    }

    pub fn withoutShift(self: Key) Key {
        var k = self;
        k.mods.shift = false;
        return k;
    }

    /// Parse a name as written in `mibi.ini`: `ctrl+s`, `Shift+Ctrl+Left`,
    /// `f1`, `alt+up`. Modifier order and case do not matter.
    pub fn parse(spec: []const u8) ?Key {
        var key = Key{};
        var base: []const u8 = "";
        var rest = std.mem.trim(u8, spec, " \t");
        while (rest.len > 0) {
            // A lone "+" (or a trailing one, as in "ctrl++") is the key itself.
            const plus = std.mem.indexOfScalarPos(u8, rest, 1, '+') orelse rest.len;
            const part = std.mem.trim(u8, rest[0..plus], " \t");
            rest = if (plus < rest.len) rest[plus + 1 ..] else "";
            if (part.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
                key.mods.ctrl = true;
            } else if (std.ascii.eqlIgnoreCase(part, "alt")) {
                key.mods.alt = true;
            } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
                key.mods.shift = true;
            } else {
                if (base.len != 0) return null;
                base = part;
            }
        }
        if (base.len == 0) return null;
        for (special_names) |entry| {
            if (std.ascii.eqlIgnoreCase(base, entry.name)) {
                key.special = entry.special;
                return key;
            }
        }
        if (std.ascii.eqlIgnoreCase(base, "space")) {
            key.cp = ' ';
            return key;
        }
        const n = std.unicode.utf8ByteSequenceLength(base[0]) catch return null;
        if (n != base.len) return null;
        var cp = std.unicode.utf8Decode(base) catch return null;
        if (cp < 0x80) cp = std.ascii.toLower(@intCast(cp));
        // "ctrl+?" is the historical name of the byte terminals send for
        // ctrl+/ ; accept it.
        if (cp == '?' and key.mods.ctrl) cp = '/';
        key.cp = cp;
        return key;
    }

    /// The canonical name: modifiers in the order ctrl, alt, shift, then the
    /// key, all lower case. `parse(format(k))` is `k`.
    pub fn format(self: Key, buf: []u8) []const u8 {
        var n: usize = 0;
        const parts = [_]struct { on: bool, text: []const u8 }{
            .{ .on = self.mods.ctrl, .text = "ctrl+" },
            .{ .on = self.mods.alt, .text = "alt+" },
            .{ .on = self.mods.shift, .text = "shift+" },
        };
        for (parts) |p| {
            if (!p.on) continue;
            if (n + p.text.len > buf.len) return buf[0..n];
            @memcpy(buf[n..][0..p.text.len], p.text);
            n += p.text.len;
        }
        var cp_buf: [4]u8 = undefined;
        const base: []const u8 = blk: {
            if (self.special != .none) {
                for (special_names) |entry| {
                    if (entry.special == self.special) break :blk entry.name;
                }
            }
            if (self.cp == ' ') break :blk "space";
            const len = std.unicode.utf8Encode(self.cp, &cp_buf) catch break :blk "?";
            break :blk cp_buf[0..len];
        };
        const len = @min(base.len, buf.len - n);
        @memcpy(buf[n..][0..len], base[0..len]);
        return buf[0 .. n + len];
    }
};

pub const Mouse = struct {
    pub const Kind = enum { press, release, drag, move, wheel_up, wheel_down };
    pub const Button = enum { left, middle, right, none };

    kind: Kind,
    button: Button = .none,
    /// Cell coordinates, zero-based.
    x: u16,
    y: u16,
    mods: Mods = .{},
};

pub const Event = union(enum) {
    key: Key,
    mouse: Mouse,
    /// Text pasted by the terminal (bracketed paste). The bytes are only
    /// valid until the next event is read.
    paste: []const u8,
    /// The window gained or lost focus.
    focus: bool,
    /// The terminal changed size; ask the terminal for the new one.
    resize,
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "parse reads modifiers in any order and case" {
    try testing.expect(Key.parse("Shift+Ctrl+Left").?.eql(.{ .special = .left, .mods = .{ .ctrl = true, .shift = true } }));
    try testing.expect(Key.parse("control+s").?.eql(Key.ctrl('s')));
    try testing.expect(Key.parse(" CTRL + S ").?.eql(Key.ctrl('s')));
    try testing.expect(Key.parse("F1").?.eql(.{ .special = .f1 }));
    try testing.expect(Key.parse("ESC").?.eql(.{ .special = .esc }));
    try testing.expect(Key.parse("ctrl+pgup").?.eql(.{ .special = .page_up, .mods = .{ .ctrl = true } }));
    try testing.expect(Key.parse("ctrl+?").?.eql(Key.ctrl('/')));
    try testing.expect(Key.parse("ctrl++").?.eql(Key.ctrl('+')));
    try testing.expect(Key.parse("+").?.eql(Key.char('+')));
    try testing.expect(Key.parse("alt+space").?.eql(.{ .cp = ' ', .mods = .{ .alt = true } }));
    try testing.expect(Key.parse("") == null);
    try testing.expect(Key.parse("ctrl+") == null);
    try testing.expect(Key.parse("ctrl+ab") == null);
    try testing.expect(Key.parse("a+b") == null);
}

test "format is canonical and round-trips" {
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("ctrl+shift+left", Key.parse("Shift+Ctrl+Left").?.format(&buf));
    try testing.expectEqualStrings("ctrl+alt+up", Key.parse("alt+ctrl+up").?.format(&buf));
    try testing.expectEqualStrings("ctrl+/", Key.ctrl('/').format(&buf));
    try testing.expectEqualStrings("space", Key.char(' ').format(&buf));
    try testing.expectEqualStrings("\xc3\xa9", Key.char(0xe9).format(&buf));

    const samples = [_][]const u8{ "ctrl+s", "f12", "shift+tab", "alt+backspace", "ctrl+alt+shift+pgdn", "ctrl+space", "x" };
    for (samples) |name| {
        const key = Key.parse(name).?;
        try testing.expectEqualStrings(name, key.format(&buf));
        try testing.expect(Key.parse(key.format(&buf)).?.eql(key));
    }
}

test "text is a character without ctrl or alt" {
    try testing.expect(Key.char('a').isText());
    try testing.expect(Key.char(0x4e2d).isText());
    try testing.expect(!Key.ctrl('a').isText());
    try testing.expect(!(Key{ .special = .enter }).isText());
    try testing.expect(!(Key{ .cp = 'a', .mods = .{ .alt = true } }).isText());
}
