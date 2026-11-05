//! User configuration: `mibi.ini`, hand-rolled INI.
//!
//! Every setting has a default, so a missing or partial file is fine. Colours
//! are `#rrggbb` (or `#rgb`) and live under `[theme]`; editor behaviour lives
//! under `[editor]`. Unknown keys are ignored so newer configs keep working.

const std = @import("std");
const os = @import("os.zig");
const ini = @import("ini.zig");
const keys = @import("keys.zig");
const render = @import("render.zig");

pub const Color = render.Color;

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
};

fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .rgb = .{ .r = r, .g = g, .b = b } };
}

pub const Config = struct {
    theme: Theme = .{},
    keys: keys.KeyMap = .{},
    tab_width: usize = 4,
    line_numbers: bool = true,
    syntax: bool = true,
};

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
fn parseColor(value: []const u8) ?Color {
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

fn parseBool(value: []const u8) ?bool {
    const v = std.mem.trim(u8, value, " \t");
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "on")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "no") or std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "off")) return false;
    return null;
}

fn setThemeColor(theme: *Theme, key: []const u8, value: []const u8) void {
    const color = parseColor(value) orelse return;
    inline for (@typeInfo(Theme).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, key)) {
            @field(theme, field.name) = color;
            return;
        }
    }
}

/// Apply an INI document to `config`. Sections are optional: a bare
/// `key = value` is treated as `[editor]`.
pub fn apply(config: *Config, text: []const u8) void {
    var reader = ini.Reader{ .text = text };
    while (reader.next()) |entry| {
        if (std.mem.eql(u8, entry.section, "theme")) {
            setThemeColor(&config.theme, entry.key, entry.value);
            continue;
        }
        if (std.mem.eql(u8, entry.section, "keys")) {
            if (keys.actionFromName(entry.value)) |action| config.keys.add(entry.key, action);
            continue;
        }
        if (std.mem.eql(u8, entry.key, "tab_width")) {
            const n = std.fmt.parseInt(usize, std.mem.trim(u8, entry.value, " \t"), 10) catch continue;
            config.tab_width = @min(@max(n, 1), 16);
        } else if (std.mem.eql(u8, entry.key, "line_numbers")) {
            if (parseBool(entry.value)) |b| config.line_numbers = b;
        } else if (std.mem.eql(u8, entry.key, "syntax")) {
            if (parseBool(entry.value)) |b| config.syntax = b;
        }
    }
}

/// Load the first `mibi.ini` found next to the executable or in the working
/// directory. A missing file yields the defaults.
pub fn load(allocator: std.mem.Allocator, exe_dir: ?[]const u8) Config {
    var config = Config{};
    var path_buf: [1024]u8 = undefined;
    if (exe_dir) |dir| {
        if (std.fmt.bufPrint(&path_buf, "{s}/mibi.ini", .{dir})) |path| {
            if (loadFile(allocator, path, &config)) return config;
        } else |_| {}
    }
    _ = loadFile(allocator, "mibi.ini", &config);
    return config;
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8, config: *Config) bool {
    const data = os.readFileAlloc(allocator, path, 1024 * 1024) catch return false;
    defer allocator.free(data);
    apply(config, data);
    return true;
}

// --- tests -----------------------------------------------------------------

test "defaults are the shipped look" {
    const config = Config{};
    try std.testing.expectEqual(@as(usize, 4), config.tab_width);
    try std.testing.expect(config.line_numbers);
    try std.testing.expect(config.syntax);
    try std.testing.expectEqual(rgb(0xd8, 0xde, 0xe9), config.theme.text);
}

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

test "applies editor settings and theme colours" {
    var config = Config{};
    apply(&config,
        \\tab_width = 2
        \\line_numbers = false
        \\syntax = off
        \\
        \\[theme]
        \\text = #ff0000
        \\comment = #00ff00
        \\unknown_key = #0000ff
    );
    try std.testing.expectEqual(@as(usize, 2), config.tab_width);
    try std.testing.expect(!config.line_numbers);
    try std.testing.expect(!config.syntax);
    try std.testing.expectEqual(rgb(0xff, 0x00, 0x00), config.theme.text);
    try std.testing.expectEqual(rgb(0x00, 0xff, 0x00), config.theme.comment);
    // An unknown colour key must not disturb the defaults.
    try std.testing.expectEqual(rgb(0xc6, 0x78, 0xdd), config.theme.keyword1);
}

test "tab width is clamped" {
    var config = Config{};
    apply(&config, "tab_width = 0\n");
    try std.testing.expectEqual(@as(usize, 1), config.tab_width);
    apply(&config, "tab_width = 99\n");
    try std.testing.expectEqual(@as(usize, 16), config.tab_width);
}

test "parses [keys] bindings and ignores unknown actions" {
    var config = Config{};
    apply(&config,
        \\[keys]
        \\ctrl+n = new_tab
        \\F2 = save
        \\ctrl+shift+left = move_word_left
        \\ctrl+j = not_an_action
    );
    try std.testing.expectEqual(keys.Action.new_tab, config.keys.lookup("ctrl+n").?);
    try std.testing.expectEqual(keys.Action.save, config.keys.lookup("f2").?);
    try std.testing.expectEqual(keys.Action.move_word_left, config.keys.lookup("ctrl+shift+left").?);
    try std.testing.expectEqual(@as(usize, 3), config.keys.count); // the bad one was skipped
}

test "a missing config file keeps the defaults" {
    const config = load(std.testing.allocator, "no-such-dir");
    try std.testing.expectEqual(@as(usize, 4), config.tab_width);
}
