//! User configuration: `mibi.ini`, hand-rolled INI.
//!
//! Every setting has a default, so a missing or partial file is fine. Colours
//! are `#rrggbb` (or `#rgb`) and live under `[theme]`; editor behaviour lives
//! under `[editor]`. Unknown keys are ignored so newer configs keep working.

const std = @import("std");
const os = @import("platform").os;
const ini = @import("core").ini;
const commands = @import("commands.zig");
const theme_mod = @import("ui").theme;

pub const Color = theme_mod.Color;
pub const Theme = theme_mod.Theme;
const rgb = theme_mod.rgb;

pub const Config = struct {
    theme: Theme = .{},
    keys: commands.KeyMap = .{},
    tab_width: usize = 4,
    line_numbers: bool = true,
    syntax: bool = true,
    /// Unicode icons in the file tree (false = one-letter ASCII markers).
    /// ASCII is the default because many terminal fonts lack emoji glyphs.
    icons_unicode: bool = true,
    /// Name of a theme from `themes/<name>.ini` (empty = built-in default).
    theme_name: [32]u8 = [_]u8{0} ** 32,
    theme_name_len: usize = 0,
    /// The `mibi.ini` that was loaded (empty when the defaults were used).
    source: [1024]u8 = [_]u8{0} ** 1024,
    source_len: usize = 0,
    /// Set when the saved theme name has no matching themes/<name>.ini.
    theme_missing: bool = false,
    /// `[format]`: one command per file extension, and whether to run it on
    /// every save.
    format_rules: [16]FormatRule = [_]FormatRule{.{}} ** 16,
    format_count: usize = 0,
    format_on_save: bool = false,

    pub const FormatRule = struct {
        ext: [16]u8 = [_]u8{0} ** 16,
        ext_len: usize = 0,
        cmd: [256]u8 = [_]u8{0} ** 256,
        cmd_len: usize = 0,

        pub fn extension(self: *const FormatRule) []const u8 {
            return self.ext[0..self.ext_len];
        }

        pub fn command(self: *const FormatRule) []const u8 {
            return self.cmd[0..self.cmd_len];
        }
    };

    /// The formatter command configured for this path's extension, if any.
    pub fn formatCommandFor(self: *const Config, path: ?[]const u8) ?[]const u8 {
        const p = path orelse return null;
        const ext = extensionOf(p);
        if (ext.len == 0) return null;
        for (self.format_rules[0..self.format_count]) |*r| {
            if (std.ascii.eqlIgnoreCase(r.extension(), ext)) return r.command();
        }
        return null;
    }

    pub fn themeName(self: *const Config) []const u8 {
        return self.theme_name[0..self.theme_name_len];
    }

    pub fn setThemeName(self: *Config, name: []const u8) void {
        const n = @min(name.len, self.theme_name.len);
        @memcpy(self.theme_name[0..n], name[0..n]);
        self.theme_name_len = n;
    }

    pub fn sourcePath(self: *const Config) []const u8 {
        return self.source[0..self.source_len];
    }

    pub fn setSource(self: *Config, path: []const u8) void {
        const n = @min(path.len, self.source.len);
        // `path` may be `sourcePath()` itself, so the ranges can overlap.
        std.mem.copyForwards(u8, self.source[0..n], path[0..n]);
        self.source_len = n;
    }
};

fn parseBool(value: []const u8) ?bool {
    const v = std.mem.trim(u8, value, " \t");
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "on")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "no") or std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "off")) return false;
    return null;
}

/// The extension of a path, without the dot ("" when there is none).
pub fn extensionOf(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        const c = path[i - 1];
        if (c == '/' or c == '\\') return "";
        if (c == '.') return path[i..];
    }
    return "";
}

/// Apply an INI document to `config`. Sections are optional: a bare
/// `key = value` is treated as `[editor]`.
pub fn apply(config: *Config, text: []const u8) void {
    var reader = ini.Reader{ .text = text };
    while (reader.next()) |entry| {
        if (std.mem.eql(u8, entry.section, "theme")) {
            config.theme.set(entry.key, entry.value);
            continue;
        }
        if (std.mem.eql(u8, entry.section, "keys")) {
            if (commands.Command.fromName(entry.value)) |command| _ = config.keys.bind(entry.key, command);
            continue;
        }
        if (std.mem.eql(u8, entry.section, "format")) {
            if (std.mem.eql(u8, entry.key, "on_save")) {
                if (parseBool(entry.value)) |b| config.format_on_save = b;
            } else if (config.format_count < config.format_rules.len) {
                const r = &config.format_rules[config.format_count];
                var key = std.mem.trim(u8, entry.key, " \t");
                if (key.len > 0 and key[0] == '.') key = key[1..];
                if (key.len == 0) continue;
                const n = @min(key.len, r.ext.len);
                @memcpy(r.ext[0..n], key[0..n]);
                r.ext_len = n;
                const v = std.mem.trim(u8, entry.value, " \t");
                const m = @min(v.len, r.cmd.len);
                @memcpy(r.cmd[0..m], v[0..m]);
                r.cmd_len = m;
                config.format_count += 1;
            }
            continue;
        }
        // Sections this version does not know (an old `[terminal]`) are
        // skipped, so an existing config keeps loading.
        if (entry.section.len > 0 and !std.mem.eql(u8, entry.section, "editor")) continue;
        if (std.mem.eql(u8, entry.key, "tab_width")) {
            const n = std.fmt.parseInt(usize, std.mem.trim(u8, entry.value, " \t"), 10) catch continue;
            config.tab_width = @min(@max(n, 1), 16);
        } else if (std.mem.eql(u8, entry.key, "line_numbers")) {
            if (parseBool(entry.value)) |b| config.line_numbers = b;
        } else if (std.mem.eql(u8, entry.key, "syntax")) {
            if (parseBool(entry.value)) |b| config.syntax = b;
        } else if (std.mem.eql(u8, entry.key, "icons")) {
            const v = std.mem.trim(u8, entry.value, " \t");
            config.icons_unicode = !std.ascii.eqlIgnoreCase(v, "ascii");
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
        if (loadTheme(allocator, exe_dir, name)) |theme| {
            config.theme = theme;
        } else {
            config.theme_missing = true;
        }
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
    config.theme_missing = false;

    // There is usually more than one config (the working directory's and the
    // one next to the binary). Write the choice into the other one as well so
    // launching from a different directory does not bring back the old theme.
    var other_buf: [1024]u8 = undefined;
    if (otherConfigPath(allocator, config, &other_buf)) |other| {
        if (!std.mem.eql(u8, other, path)) {
            saveThemeTo(allocator, other, name) catch {};
        }
    }
}

/// The config path that was *not* loaded, if one exists.
fn otherConfigPath(allocator: std.mem.Allocator, self: *const Config, buf: []u8) ?[]const u8 {
    if (self.source_len == 0) return null;
    const loaded = self.sourcePath();
    // Loaded from the working directory: the other one sits next to the exe.
    if (!std.mem.startsWith(u8, loaded, "mibi.ini") and !std.mem.eql(u8, loaded, "mibi.ini")) {
        if (readFile(allocator, "mibi.ini")) |t| {
            allocator.free(t);
            return "mibi.ini";
        }
        return null;
    }
    // Loaded "mibi.ini": look for one next to the executable.
    const exe_dir = os.exeDirAlloc(allocator) catch return null;
    defer allocator.free(exe_dir);
    const candidate = std.fmt.bufPrint(buf, "{s}/mibi.ini", .{exe_dir}) catch return null;
    if (readFile(allocator, candidate)) |t| {
        allocator.free(t);
        return candidate;
    }
    return null;
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
        // The last line's own line break is not an extra, empty line.
        const body = if (text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
        var lines = std.mem.splitScalar(u8, body, '\n');
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
    while (reader.next()) |entry| theme.set(entry.key, entry.value);
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
    const Key = @import("ui").event.Key;
    try std.testing.expectEqual(commands.Command.new_tab, config.keys.resolve(Key.parse("ctrl+n").?).?.command);
    try std.testing.expectEqual(commands.Command.save, config.keys.resolve(Key.parse("f2").?).?.command);
    try std.testing.expectEqual(commands.Command.move_word_left, config.keys.resolve(Key.parse("ctrl+shift+left").?).?.command);
    try std.testing.expectEqual(@as(usize, 3), config.keys.count); // the bad one was skipped
}

test "saveTheme replaces, adds and preserves" {
    // In the working directory, like the other file tests: a scratch
    // directory that only exists on one machine makes the test fail elsewhere.
    const path = "mibi-save-test.ini";
    defer os.deleteFile(path) catch {};

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
