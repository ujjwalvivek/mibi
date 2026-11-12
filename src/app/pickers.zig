//! The three pickers: open a file, choose a theme, run a command. The list
//! and its filter are `ui/picker.zig`; this file fills the list and decides
//! what choosing an item does.

const std = @import("std");
const os = @import("platform").os;
const commands = @import("../commands.zig");
const config_mod = @import("../config.zig");
const event = @import("ui").event;
const screen = @import("ui").screen;
const Picker = @import("ui").picker.Picker;
const app_mod = @import("../app.zig");
const App = app_mod.App;

pub const Mode = enum { files, themes, commands };

pub const State = struct {
    picker: Picker,
    mode: Mode,
    /// Files: the directory being listed.
    dir: std.ArrayList(u8) = .empty,
    /// Themes: what to go back to on Esc, since moving through the list
    /// previews each one.
    theme_before: config_mod.Theme = .{},

    pub fn deinit(self: *State) void {
        self.dir.deinit(self.picker.allocator);
        self.picker.deinit();
    }
};

pub fn open(app: *App, mode: Mode) !void {
    close(app);
    var state = State{ .picker = Picker.init(app.allocator), .mode = mode, .theme_before = app.config.theme };
    errdefer state.deinit();
    switch (mode) {
        .files => try listDir(app, &state, "."),
        .themes => {
            try listThemes(app, &state.picker);
            state.picker.selectByName(app.config.themeName());
        },
        .commands => {
            for (commands.table) |row| {
                if (!row.palette) continue;
                var key_buf: [48]u8 = undefined;
                const key = if (app.config.keys.keyFor(row.command)) |k| k.format(&key_buf) else "";
                try state.picker.add(.{ .text = row.title, .detail = key, .tag = @intFromEnum(row.command) });
            }
            try state.picker.refilter();
        },
    }
    app.picker = state;
}

pub fn close(app: *App) void {
    if (app.picker) |*p| p.deinit();
    app.picker = null;
}

fn listDir(app: *App, state: *State, dir: []const u8) !void {
    // `dir` may point into the state being replaced.
    const copy = try app.allocator.dupe(u8, dir);
    defer app.allocator.free(copy);
    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |n| app.allocator.free(n);
        names.deinit(app.allocator);
    }
    try os.listDirNames(app.allocator, copy, &names);
    os.sortStrings(names.items);

    state.picker.clear();
    state.dir.clearRetainingCapacity();
    try state.dir.appendSlice(app.allocator, copy);
    try state.picker.add(.{ .text = "..", .is_dir = true });
    // Directories first, then files, each in name order.
    for ([_]bool{ true, false }) |want_dir| {
        for (names.items) |name| {
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var buf: [1024]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ copy, name }) catch continue;
            const is_dir = os.isDirectory(path);
            if (is_dir == want_dir) try state.picker.add(.{ .text = name, .is_dir = is_dir });
        }
    }
    try state.picker.refilter();
    // Start on the first real entry, not on "..".
    if (state.picker.count() > 1) state.picker.selected = 1;
}

fn listThemes(app: *App, picker: *Picker) !void {
    var exe_buf: [1024]u8 = undefined;
    var dirs = [2]?[]const u8{ "themes", null };
    if (app.exe_dir) |d| dirs[1] = std.fmt.bufPrint(&exe_buf, "{s}/themes", .{d}) catch null;
    for (dirs) |maybe_dir| {
        const dir = maybe_dir orelse continue;
        var names = std.ArrayList([]u8).empty;
        defer {
            for (names.items) |n| app.allocator.free(n);
            names.deinit(app.allocator);
        }
        os.listDirNames(app.allocator, dir, &names) catch continue;
        os.sortStrings(names.items);
        next: for (names.items) |name| {
            if (!std.mem.endsWith(u8, name, ".ini")) continue;
            const stem = name[0 .. name.len - 4];
            // The same theme in both places is listed once.
            for (picker.items.items) |item| {
                if (std.mem.eql(u8, item.text, stem)) continue :next;
            }
            try picker.add(.{ .text = stem });
        }
    }
    try picker.refilter();
}

/// The directory above `dir`, in the same relative style.
fn parentDir(buf: []u8, dir: []const u8) []const u8 {
    if (std.mem.eql(u8, dir, ".")) return "..";
    const last = if (std.mem.lastIndexOfAny(u8, dir, "/\\")) |i| dir[i + 1 ..] else dir;
    if (std.mem.eql(u8, last, "..")) return std.fmt.bufPrint(buf, "{s}/..", .{dir}) catch dir;
    if (last.len == dir.len) return "."; // one component: back to the start
    return if (dir.len - last.len == 1) dir[0..1] else dir[0 .. dir.len - last.len - 1];
}

/// Apply the highlighted theme right away, so moving through the list shows
/// each one.
fn preview(app: *App) void {
    const state = &app.picker.?;
    if (state.mode != .themes) return;
    const item = state.picker.selectedItem() orelse return;
    if (config_mod.loadTheme(app.allocator, app.exe_dir, item.text)) |theme| app.config.theme = theme;
}

pub fn handleKey(app: *App, key: event.Key) !void {
    const state = &app.picker.?;
    switch (try state.picker.handleKey(key)) {
        .ignored => {},
        .filtered, .moved => preview(app),
        .accept => try accept(app),
        .cancel => cancel(app),
    }
}

pub fn handleMouse(app: *App, m: event.Mouse) !void {
    const state = &app.picker.?;
    switch (m.kind) {
        .wheel_up => state.picker.scrollBy(-3),
        .wheel_down => state.picker.scrollBy(3),
        .press => if (m.button == .left) switch (state.picker.handleClick(m.x, m.y)) {
            .accept => try accept(app),
            .moved => preview(app),
            else => {},
        },
        else => {},
    }
}

fn cancel(app: *App) void {
    const state = &app.picker.?;
    if (state.mode == .themes) app.config.theme = state.theme_before;
    close(app);
}

fn accept(app: *App) !void {
    const state = &app.picker.?;
    const item = state.picker.selectedItem() orelse return close(app);
    switch (state.mode) {
        .commands => {
            const command: commands.Command = @enumFromInt(item.tag);
            close(app);
            try app.run(command, false);
        },
        .themes => {
            var name_buf: [64]u8 = undefined;
            const name = name_buf[0..@min(item.text.len, name_buf.len)];
            @memcpy(name, item.text[0..name.len]);
            close(app);
            // The preview already applied it; persist the choice so the
            // next start comes up in this theme.
            config_mod.saveTheme(app.allocator, &app.config, name) catch |err| {
                return app.setMessage("theme: {s} (not saved: {s})", .{ name, app_mod.describe(err) });
            };
            app.config.setThemeName(name);
            app.setMessage("theme: {s} (saved)", .{name});
        },
        .files => {
            var buf: [1024]u8 = undefined;
            const dir = state.dir.items;
            if (std.mem.eql(u8, item.text, "..")) {
                var parent_buf: [1024]u8 = undefined;
                return listDir(app, state, parentDir(&parent_buf, dir));
            }
            const path = if (std.mem.eql(u8, dir, "."))
                std.fmt.bufPrint(&buf, "{s}", .{item.text})
            else
                std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, item.text });
            const full = path catch return app.setMessage("path too long", .{});
            if (item.is_dir) return listDir(app, state, full);
            // On failure the picker stays open so another file can be chosen.
            app.openPath(full) catch |err| return app.setMessage("Cannot open: {s}", .{app_mod.describe(err)});
            close(app);
        },
    }
}

pub fn draw(app: *App, s: *screen.Screen) void {
    const state = &app.picker.?;
    var title_buf: [300]u8 = undefined;
    const title = switch (state.mode) {
        .files => std.fmt.bufPrint(&title_buf, "Open file: {s}", .{state.dir.items}) catch "Open file",
        .themes => "Theme",
        .commands => "Commands",
    };
    // Below the tab bar, over everything else.
    state.picker.draw(s, .{ .y = 1, .w = s.cols, .h = s.rows -| 1 }, title, &app.config.theme);
    // An error while the picker is open (a file that would not open) has
    // nowhere else to show.
    const msg = app.message();
    if (msg.len > 0 and s.rows > 2 and s.cols > msg.len + 4) {
        _ = s.text(s.cols - msg.len - 2, 1, s.cols, msg, .{ .fg = app.config.theme.hint_fg, .bg = app.config.theme.background });
    }
}

test "parentDir walks up in relative terms" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("..", parentDir(&buf, "."));
    try std.testing.expectEqualStrings(".", parentDir(&buf, "src"));
    try std.testing.expectEqualStrings("src", parentDir(&buf, "src/core"));
    try std.testing.expectEqualStrings("../..", parentDir(&buf, ".."));
    try std.testing.expectEqualStrings("..", parentDir(&buf, "../x"));
    try std.testing.expectEqualStrings("/", parentDir(&buf, "/usr"));
}
