//! Windows console input records turned into `Event`s.
//!
//! The console reports keys as virtual-key codes plus a UTF-16 unit, and the
//! mouse as button masks. This file is the translation and nothing else: it
//! takes plain structs, not kernel32 types, so it compiles and is tested on
//! every platform even though only the Windows terminal layer calls it.

const std = @import("std");
const event = @import("../ui/event.zig");
const Event = event.Event;
const Key = event.Key;
const Mods = event.Mods;
const Special = event.Special;

// dwControlKeyState bits.
pub const RIGHT_ALT: u32 = 0x0001;
pub const LEFT_ALT: u32 = 0x0002;
pub const RIGHT_CTRL: u32 = 0x0004;
pub const LEFT_CTRL: u32 = 0x0008;
pub const SHIFT: u32 = 0x0010;

// dwButtonState bits.
pub const BUTTON_LEFT: u32 = 0x0001;
pub const BUTTON_RIGHT: u32 = 0x0002;
pub const BUTTON_MIDDLE: u32 = 0x0004;

// dwEventFlags bits.
pub const MOUSE_MOVED: u32 = 0x0001;
pub const DOUBLE_CLICK: u32 = 0x0002;
pub const MOUSE_WHEELED: u32 = 0x0004;

pub const KeyRecord = struct {
    vk: u16,
    /// UTF-16 code unit, 0 when the key produces no character.
    unit: u16 = 0,
    state: u32 = 0,
};

pub const MouseRecord = struct {
    x: i16,
    y: i16,
    buttons: u32 = 0,
    state: u32 = 0,
    flags: u32 = 0,
};

pub const Translator = struct {
    /// First half of a surrogate pair, waiting for the second.
    high_surrogate: u16 = 0,
    /// Buttons held at the last mouse record, to tell a release from motion.
    held: u32 = 0,

    /// A key-down record. Null when the record is not a key the editor sees
    /// (a modifier on its own, half of a surrogate pair).
    pub fn key(self: *Translator, rec: KeyRecord) ?Key {
        const ctrl = rec.state & (LEFT_CTRL | RIGHT_CTRL) != 0;
        const alt = rec.state & (LEFT_ALT | RIGHT_ALT) != 0;
        const shift = rec.state & SHIFT != 0;
        const mods = Mods{ .ctrl = ctrl, .alt = alt, .shift = shift };

        const special: Special = switch (rec.vk) {
            0x08 => .backspace,
            0x09 => .tab,
            0x0d => .enter,
            0x1b => .esc,
            0x21 => .page_up,
            0x22 => .page_down,
            0x23 => .end,
            0x24 => .home,
            0x25 => .left,
            0x26 => .up,
            0x27 => .right,
            0x28 => .down,
            0x2d => .insert,
            0x2e => .delete,
            0x70...0x7b => @enumFromInt(@intFromEnum(Special.f1) + (rec.vk - 0x70)),
            else => .none,
        };
        if (special != .none) {
            self.high_surrogate = 0;
            return .{ .special = special, .mods = mods };
        }

        // AltGr is reported as right Alt plus left Ctrl. When it produced a
        // character, that character is text, not a shortcut.
        const altgr = rec.state & RIGHT_ALT != 0 and rec.state & LEFT_CTRL != 0 and rec.unit >= 0x20;

        if ((ctrl or alt) and !altgr) {
            const cp: u21 = switch (rec.vk) {
                'A'...'Z' => @as(u21, rec.vk) + ('a' - 'A'),
                '0'...'9' => rec.vk,
                0x20 => ' ',
                0xbf => '/',
                0xdc => '\\',
                0xdd => ']',
                0xdb => '[',
                0xbd => '-',
                0xbb => '=',
                else => return null,
            };
            return .{ .cp = cp, .mods = mods };
        }

        const unit = rec.unit;
        if (unit == 0) return null;
        if (self.high_surrogate != 0) {
            const high = self.high_surrogate;
            self.high_surrogate = 0;
            if (std.unicode.utf16IsLowSurrogate(unit)) {
                const cp = std.unicode.utf16DecodeSurrogatePair(&.{ high, unit }) catch return null;
                return Key.char(cp);
            }
        }
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            self.high_surrogate = unit;
            return null;
        }
        if (std.unicode.utf16IsLowSurrogate(unit) or unit < 0x20 or unit == 0x7f) return null;
        return Key.char(unit);
    }

    pub fn mouse(self: *Translator, rec: MouseRecord) ?event.Mouse {
        var out = event.Mouse{
            .kind = .press,
            .x = @intCast(@max(rec.x, 0)),
            .y = @intCast(@max(rec.y, 0)),
            .mods = .{
                .ctrl = rec.state & (LEFT_CTRL | RIGHT_CTRL) != 0,
                .alt = rec.state & (LEFT_ALT | RIGHT_ALT) != 0,
                .shift = rec.state & SHIFT != 0,
            },
        };
        const buttons = rec.buttons & (BUTTON_LEFT | BUTTON_RIGHT | BUTTON_MIDDLE);
        const was = self.held;

        if (rec.flags & MOUSE_WHEELED != 0) {
            // The wheel delta is the high word of the button state, signed.
            const delta: i16 = @bitCast(@as(u16, @truncate(rec.buttons >> 16)));
            out.kind = if (delta > 0) .wheel_up else .wheel_down;
            return out;
        }
        self.held = buttons;

        if (rec.flags & MOUSE_MOVED != 0) {
            if (buttons == 0) {
                out.kind = .move;
            } else {
                out.kind = .drag;
                out.button = buttonOf(buttons);
            }
            return out;
        }
        if (buttons & ~was != 0) {
            out.button = buttonOf(buttons & ~was);
            return out;
        }
        if (rec.flags & DOUBLE_CLICK != 0) {
            // The second click of a double click can arrive with the button
            // bits already clear; it is still a press, and click counting
            // needs it.
            out.button = if (buttons != 0) buttonOf(buttons) else .left;
            return out;
        }
        if (was & ~buttons != 0) {
            out.kind = .release;
            out.button = buttonOf(was & ~buttons);
            return out;
        }
        if (buttons == 0) {
            // A release with nothing known to be held: report it anyway so a
            // drag that started outside our bookkeeping still ends.
            out.kind = .release;
            out.button = .left;
            return out;
        }
        return null;
    }
};

fn buttonOf(mask: u32) event.Mouse.Button {
    if (mask & BUTTON_LEFT != 0) return .left;
    if (mask & BUTTON_RIGHT != 0) return .right;
    if (mask & BUTTON_MIDDLE != 0) return .middle;
    return .none;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn expectKey(expected: []const u8, rec: KeyRecord) !void {
    var t = Translator{};
    var buf: [48]u8 = undefined;
    const k = t.key(rec) orelse return error.NoKey;
    try testing.expectEqualStrings(expected, k.format(&buf));
}

test "characters, shortcuts and special keys" {
    try expectKey("a", .{ .vk = 'A', .unit = 'a' });
    try expectKey("A", .{ .vk = 'A', .unit = 'A', .state = SHIFT });
    try expectKey("ctrl+z", .{ .vk = 'Z', .unit = 0x1a, .state = LEFT_CTRL });
    try expectKey("ctrl+shift+s", .{ .vk = 'S', .unit = 0x13, .state = RIGHT_CTRL | SHIFT });
    try expectKey("alt+x", .{ .vk = 'X', .unit = 'x', .state = LEFT_ALT });
    try expectKey("ctrl+/", .{ .vk = 0xbf, .unit = 0x1f, .state = LEFT_CTRL });
    try expectKey("ctrl+right", .{ .vk = 0x27, .state = LEFT_CTRL });
    try expectKey("shift+up", .{ .vk = 0x26, .state = SHIFT });
    try expectKey("ctrl+alt+down", .{ .vk = 0x28, .state = LEFT_CTRL | LEFT_ALT });
    try expectKey("pgdn", .{ .vk = 0x22 });
    try expectKey("f1", .{ .vk = 0x70 });
    try expectKey("shift+f7", .{ .vk = 0x76, .state = SHIFT });
    try expectKey("f12", .{ .vk = 0x7b });
    try expectKey("enter", .{ .vk = 0x0d, .unit = 0x0d });
    try expectKey("ctrl+backspace", .{ .vk = 0x08, .unit = 0x7f, .state = LEFT_CTRL });
    try expectKey("shift+tab", .{ .vk = 0x09, .unit = 0x09, .state = SHIFT });
    try expectKey("esc", .{ .vk = 0x1b, .unit = 0x1b });
    try expectKey("\xc3\xa9", .{ .vk = 0x32, .unit = 0xe9 });
}

test "modifier keys alone and altgr characters" {
    var t = Translator{};
    try testing.expect(t.key(.{ .vk = 0x11, .state = LEFT_CTRL }) == null); // Ctrl itself
    try testing.expect(t.key(.{ .vk = 0x10, .state = SHIFT }) == null); // Shift itself
    // AltGr+Q on a German layout types '@'.
    var buf: [8]u8 = undefined;
    const k = t.key(.{ .vk = 'Q', .unit = '@', .state = RIGHT_ALT | LEFT_CTRL }).?;
    try testing.expectEqualStrings("@", k.format(&buf));
    try testing.expect(k.isText());
}

test "surrogate pairs become one character" {
    var t = Translator{};
    try testing.expect(t.key(.{ .vk = 0xe7, .unit = 0xd83d }) == null);
    const k = t.key(.{ .vk = 0xe7, .unit = 0xde00 }).?;
    try testing.expectEqual(@as(u21, 0x1f600), k.cp);
    // A low surrogate with no high one before it is dropped.
    try testing.expect(t.key(.{ .vk = 0xe7, .unit = 0xde00 }) == null);
}

test "mouse press, drag, release, wheel and motion" {
    var t = Translator{};
    var m = t.mouse(.{ .x = 4, .y = 2, .buttons = BUTTON_LEFT }).?;
    try testing.expectEqual(event.Mouse.Kind.press, m.kind);
    try testing.expectEqual(event.Mouse.Button.left, m.button);
    try testing.expectEqual(@as(u16, 4), m.x);

    m = t.mouse(.{ .x = 6, .y = 2, .buttons = BUTTON_LEFT, .flags = MOUSE_MOVED }).?;
    try testing.expectEqual(event.Mouse.Kind.drag, m.kind);

    m = t.mouse(.{ .x = 6, .y = 2 }).?;
    try testing.expectEqual(event.Mouse.Kind.release, m.kind);
    try testing.expectEqual(event.Mouse.Button.left, m.button);

    m = t.mouse(.{ .x = 1, .y = 1, .flags = MOUSE_MOVED }).?;
    try testing.expectEqual(event.Mouse.Kind.move, m.kind);

    m = t.mouse(.{ .x = 1, .y = 1, .buttons = @as(u32, 120) << 16, .flags = MOUSE_WHEELED }).?;
    try testing.expectEqual(event.Mouse.Kind.wheel_up, m.kind);
    m = t.mouse(.{ .x = 1, .y = 1, .buttons = @as(u32, @as(u16, @bitCast(@as(i16, -120)))) << 16, .flags = MOUSE_WHEELED }).?;
    try testing.expectEqual(event.Mouse.Kind.wheel_down, m.kind);

    m = t.mouse(.{ .x = 0, .y = 0, .buttons = BUTTON_RIGHT }).?;
    try testing.expectEqual(event.Mouse.Button.right, m.button);
}

test "the second click of a double click is a press" {
    var t = Translator{};
    _ = t.mouse(.{ .x = 1, .y = 1, .buttons = BUTTON_LEFT });
    _ = t.mouse(.{ .x = 1, .y = 1 });
    const m = t.mouse(.{ .x = 1, .y = 1, .buttons = BUTTON_LEFT, .flags = DOUBLE_CLICK }).?;
    try testing.expectEqual(event.Mouse.Kind.press, m.kind);
    try testing.expectEqual(event.Mouse.Button.left, m.button);
}
