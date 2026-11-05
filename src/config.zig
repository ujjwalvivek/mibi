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
    /// Name of a theme from `themes/<name>.ini` (empty = built-in default).
    theme_name: [32]u8 = [_]u8{0} ** 32,
    theme_name_len: usize = 0,
    /// The `mibi.ini` that was loaded (empty when the defaults were used).
    source: [1024]u8 = [_]u8{0} ** 1024,
    source_len: usize = 0,

    pub fn themeName(self: *const Config) []const u8 {
        return self.theme_name[0..self.theme_name_len];
    }

    pub fn sourcePath(self: *const Config) []const u8 {
        return self.source[0..self.source_len];
    }

    pub fn setSource(self: *Config, path: []const u8) void {
        const n = @min(path.len, self.source.len);
        @memcpy(self.source[0..n], path[0..n]);
        self.source_len = n;
    }
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
        } else if (std.mem.eql(u8, entry.key, "theme")) {
            const v = std.mem.trim(u8, entry.value, " \t");
            const n = @min(v.len, config.theme_name.len);
            @memcpy(config.theme_name[0..n], v[0..n]);
            config.theme_name_len = n;
        }
    }
}

/// Load the first `mibi.ini` found next to the executable or in the working
/// directory. A missing file yields the defaults.
pub fn load(allocator: std.mem.Allocator, exe_dir: ?[]const u8) Config {
    var config = Config{};
    var path_buf: [1024]u8 = undefined;

    // The working directory wins: a project's mibi.ini overrides the one that
    // ships next to the binary.
    const text: ?[]u8 = blk: {
        if (readFile(allocator, "mibi.ini")) |t| {
            config.setSource("mibi.ini");
            break :blk t;
        }
        if (exe_dir) |dir| {
            if (std.fmt.bufPrint(&path_buf, "{s}/mibi.ini", .{dir})) |path| {
                if (readFile(allocator, path)) |t| {
                    config.setSource(path);
                    break :blk t;
                }
            } else |_| {}
        }
        break :blk null;
    };
    defer if (text) |t| allocator.free(t);
    const data = text orelse return config;

    // A named theme is the base; keys in this file's [theme] then override it.
    var name_buf: [32]u8 = undefined;
    if (themeNameFrom(data, &name_buf)) |name| {
        if (loadTheme(allocator, exe_dir, name)) |theme| config.theme = theme;
    }
    apply(&config, data);
    return config;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    return os.readFileAlloc(allocator, path, 1024 * 1024) catch null;
}

/// The `theme = <name>` value, if the config sets one.
fn themeNameFrom(text: []const u8, buf: []u8) ?[]const u8 {
    var reader = ini.Reader{ .text = text };
    while (reader.next()) |entry| {
        if (std.mem.eql(u8, entry.section, "theme")) continue; // colour keys
        if (!std.mem.eql(u8, entry.key, "theme")) continue;
        const value = std.mem.trim(u8, entry.value, " \t");
        if (value.len == 0 or value.len > buf.len) return null;
        @memcpy(buf[0..value.len], value);
        return buf[0..value.len];
    }
    return null;
}

/// Load `themes/<name>.ini` from next to the executable, else from the working
/// directory. The name is restricted to file-name characters.
pub fn loadTheme(allocator: std.mem.Allocator, exe_dir: ?[]const u8, name: []const u8) ?Theme {
    if (name.len == 0) return null;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return null;
    }
    var theme = Theme{};
    // Working directory first, then next to the executable.
    var cwd_buf: [1024]u8 = undefined;
    if (std.fmt.bufPrint(&cwd_buf, "themes/{s}.ini", .{name})) |path| {
        if (loadThemeFile(allocator, path, &theme)) return theme;
    } else |_| {}
    var path_buf: [1024]u8 = undefined;
    if (exe_dir) |dir| {
        if (std.fmt.bufPrint(&path_buf, "{s}/themes/{s}.ini", .{ dir, name })) |path| {
            if (loadThemeFile(allocator, path, &theme)) return theme;
        } else |_| {}
    }
    return null;
}

/// Persist a theme choice in the config file: replace `theme = ...` inside
/// `[editor]`, add it to that section, or append a new section. Everything else
/// in the file is preserved verbatim.
pub fn saveTheme(allocator: std.mem.Allocator, config: *Config, name: []const u8) !void {
    const path = if (config.source_len > 0) config.sourcePath() else "mibi.ini";
    saveThemeTo(allocator, path, name) catch {
        // The loaded file may be read-only (an install directory): fall back to
        // a config in the working directory, which takes precedence anyway.
        if (std.mem.eql(u8, path, "mibi.ini")) return error.SaveFailed;
        try saveThemeTo(allocator, "mibi.ini", name);
        config.setSource("mibi.ini");
        return;
    };
    config.setSource(path);
}

fn saveThemeTo(allocator: std.mem.Allocator, path: []const u8, name: []const u8) !void {
    const existing: ?[]u8 = os.readFileAlloc(allocator, path, 1024 * 1024) catch null;
    defer if (existing) |e| allocator.free(e);
    const text = existing orelse "";

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    if (text.len == 0) {
        try out.appendSlice(allocator, "[editor]\ntheme = ");
        try out.appendSlice(allocator, name);
        try out.append(allocator, '\n');
    } else {
        var in_editor = false;
        var wrote = false;
        var saw_editor = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0 and trimmed[0] == '[') {
                if (in_editor and !wrote) {
                    try appendThemeLine(allocator, &out, name);
                    wrote = true;
                }
                in_editor = std.mem.eql(u8, trimmed, "[editor]");
                if (in_editor) saw_editor = true;
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
                continue;
            }
            if (in_editor and isThemeKey(trimmed)) {
                try appendThemeLine(allocator, &out, name);
                wrote = true;
                continue;
            }
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
        if (in_editor and !wrote) try appendThemeLine(allocator, &out, name);
        if (!saw_editor) {
            try out.appendSlice(allocator, "\n[editor]\ntheme = ");
            try out.appendSlice(allocator, name);
            try out.append(allocator, '\n');
        }
    }
    try os.writeFile(path, out.items);
}

fn appendThemeLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    try out.appendSlice(allocator, "theme = ");
    try out.appendSlice(allocator, name);
    try out.append(allocator, '\n');
}

fn isThemeKey(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "theme")) return false;
    const rest = std.mem.trimStart(u8, line["theme".len..], " \t");
    return rest.len > 0 and rest[0] == '=';
}

fn loadThemeFile(allocator: std.mem.Allocator, path: []const u8, theme: *Theme) bool {
    const data = os.readFileAlloc(allocator, path, 64 * 1024) catch return false;
    defer allocator.free(data);
    var reader = ini.Reader{ .text = data };
    while (reader.next()) |entry| setThemeColor(theme, entry.key, entry.value);
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

test "saveTheme replaces, adds and preserves" {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "experiments/out/screens/mibi-save-test.ini", .{}) catch unreachable;

    // Existing theme line is replaced, other settings stay.
    try os.writeFile(path, "[editor]\ntab_width = 2\ntheme = nord\nsyntax = false\n");
    var config = Config{};
    config.setSource(path);
    try saveTheme(std.testing.allocator, &config, "dracula");
    const after = try os.readFileAlloc(std.testing.allocator, path, 4096);
    defer std.testing.allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "theme = dracula") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "tab_width = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "syntax = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "nord") == null);

    // No theme line: it is added inside [editor].
    try os.writeFile(path, "[editor]\ntab_width = 8\n");
    try saveTheme(std.testing.allocator, &config, "tokyonight");
    const added = try os.readFileAlloc(std.testing.allocator, path, 4096);
    defer std.testing.allocator.free(added);
    try std.testing.expect(std.mem.indexOf(u8, added, "theme = tokyonight") != null);
    try std.testing.expect(std.mem.indexOf(u8, added, "tab_width = 8") != null);

    // No [editor] section at all: one is appended.
    try os.writeFile(path, "[theme]\ntext = #ffffff\n");
    try saveTheme(std.testing.allocator, &config, "nord");
    const appended = try os.readFileAlloc(std.testing.allocator, path, 4096);
    defer std.testing.allocator.free(appended);
    try std.testing.expect(std.mem.indexOf(u8, appended, "theme = nord") != null);
    try std.testing.expect(std.mem.indexOf(u8, appended, "text = #ffffff") != null);

    // A missing file is created.
    os.deleteFile(path) catch {};
    try saveTheme(std.testing.allocator, &config, "kanagawa");
    const created = try os.readFileAlloc(std.testing.allocator, path, 4096);
    defer std.testing.allocator.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "theme = kanagawa") != null);
}

test "parses the theme name" {
    var config = Config{};
    apply(&config, "[editor]\ntheme = nord\n");
    try std.testing.expectEqualStrings("nord", config.themeName());
}

test "loads a named theme from themes/" {
    const dracula = loadTheme(std.testing.allocator, null, "dracula").?;
    try std.testing.expectEqual(rgb(0x28, 0x2a, 0x36), dracula.background);
    try std.testing.expectEqual(rgb(0xff, 0x79, 0xc6), dracula.keyword1);
    try std.testing.expect(loadTheme(std.testing.allocator, null, "nope") == null);
    try std.testing.expect(loadTheme(std.testing.allocator, null, "../etc/passwd") == null);
}

test "inline theme keys override a named theme" {
    var config = Config{};
    config.theme = loadTheme(std.testing.allocator, null, "dracula").?;
    apply(&config, "[theme]\ntext = #ff0000\n");
    try std.testing.expectEqual(rgb(0xff, 0x00, 0x00), config.theme.text);
    try std.testing.expectEqual(rgb(0x28, 0x2a, 0x36), config.theme.background);
}

test "a missing config file keeps the defaults" {
    const config = load(std.testing.allocator, "no-such-dir");
    try std.testing.expectEqual(@as(usize, 4), config.tab_width);
}
