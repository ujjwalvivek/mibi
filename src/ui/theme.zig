//! The colours of the interface, and how they are read from text.

const std = @import("std");
const screen = @import("screen.zig");

pub const Color = screen.Color;

/// The palette used by the renderer.
pub const Theme = struct {
    /// Screen background; `.default` keeps the terminal's own background.
    background: Color = .default,
    text: Color = rgb(0xd8, 0xde, 0xe9),
    gutter: Color = rgb(0x5c, 0x63, 0x70),
    selection: Color = rgb(0x33, 0x45, 0x66),
    bar_bg: Color = rgb(0x28, 0x28, 0x38),
    accent: Color = rgb(0x8b, 0xd4, 0x50),
    hint_bg: Color = rgb(0x1e, 0x1e, 0x2a),
    hint_fg: Color = rgb(0x88, 0x92, 0xa4),
    tab_bg: Color = rgb(0x1e, 0x1e, 0x2a),
    tab_active_bg: Color = rgb(0x33, 0x45, 0x66),
    help_bg: Color = rgb(0x1a, 0x1a, 0x24),
    comment: Color = rgb(0x6a, 0x73, 0x82),
    keyword1: Color = rgb(0xc6, 0x78, 0xdd),
    keyword2: Color = rgb(0xe5, 0xc0, 0x7b),
    string: Color = rgb(0x98, 0xc3, 0x79),
    number: Color = rgb(0xd1, 0x9a, 0x66),
    /// Current-line tint. Unset means "background nudged toward the text".
    line_hl: Color = .default,

    /// The tint painted behind the line holding the cursor.
    pub fn lineHighlight(self: Theme) Color {
        if (std.meta.activeTag(self.line_hl) != .default) return self.line_hl;
        switch (self.background) {
            .rgb => |bg| switch (self.text) {
                .rgb => |fg| return rgb(
                    blend(bg.r, fg.r, 7),
                    blend(bg.g, fg.g, 7),
                    blend(bg.b, fg.b, 7),
                ),
                else => return self.background,
            },
            else => return self.background,
        }
    }

    /// Set the colour named `key` from `#rrggbb` or `#rgb`. Unknown keys and
    /// bad values are ignored, so a theme file from a newer version loads.
    pub fn set(theme: *Theme, key: []const u8, value: []const u8) void {
        const color = parseColor(value) orelse return;
        inline for (@typeInfo(Theme).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, key)) {
                @field(theme, field.name) = color;
                return;
            }
        }
    }
};

fn blend(a: u8, b: u8, pct: u32) u8 {
    const av: u32 = a;
    const bv: u32 = b;
    return @intCast((av * (100 - pct) + bv * pct) / 100);
}

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .rgb = .{ .r = r, .g = g, .b = b } };
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexByte(s: []const u8) ?u8 {
    const hi = hexVal(s[0]) orelse return null;
    const lo = hexVal(s[1]) orelse return null;
    return hi * 16 + lo;
}

/// Parse `#rrggbb` or `#rgb`; anything else is rejected.
pub fn parseColor(value: []const u8) ?Color {
    var v = std.mem.trim(u8, value, " \t");
    if (v.len > 0 and v[0] == '#') v = v[1..];
    if (v.len == 3) {
        const r = hexVal(v[0]) orelse return null;
        const g = hexVal(v[1]) orelse return null;
        const b = hexVal(v[2]) orelse return null;
        return rgb(r * 17, g * 17, b * 17);
    }
    if (v.len != 6) return null;
    const r = hexByte(v[0..2]) orelse return null;
    const g = hexByte(v[2..4]) orelse return null;
    const b = hexByte(v[4..6]) orelse return null;
    return rgb(r, g, b);
}

// --- tests -----------------------------------------------------------------

test "parses colours in #rrggbb and #rgb" {
    const a = parseColor("#c678dd").?;
    try std.testing.expectEqual(@as(u8, 0xc6), a.rgb.r);
    try std.testing.expectEqual(@as(u8, 0x78), a.rgb.g);
    try std.testing.expectEqual(@as(u8, 0xdd), a.rgb.b);

    const b = parseColor("#fff").?;
    try std.testing.expectEqual(@as(u8, 0xff), b.rgb.r);
    try std.testing.expectEqual(@as(u8, 0xff), b.rgb.b);

    try std.testing.expect(parseColor("nope") == null);
    try std.testing.expect(parseColor("#12345") == null);
}

test "the current-line tint is derived or explicit" {
    var theme = Theme{ .background = rgb(0x1e, 0x1e, 0x2e), .text = rgb(0xcd, 0xd6, 0xf4) };
    const derived = theme.lineHighlight();
    try std.testing.expect(std.meta.activeTag(derived) == .rgb);
    try std.testing.expect(!std.meta.eql(derived, theme.background));
    // Light theme: the tint goes darker instead of lighter.
    var light = Theme{ .background = rgb(0xf0, 0xf0, 0xf0), .text = rgb(0x20, 0x20, 0x20) };
    const dark_tint = light.lineHighlight();
    try std.testing.expect(dark_tint.rgb.r < 0xf0);
    // An explicit colour wins.
    theme.line_hl = rgb(0x11, 0x22, 0x33);
    try std.testing.expectEqual(rgb(0x11, 0x22, 0x33), theme.lineHighlight());
}
