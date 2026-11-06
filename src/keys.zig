//! Key names, editor actions and the user's key bindings (`[keys]` in
//! `mibi.ini`).
//!
//! Keys are named canonically: modifiers in the order ctrl, alt, shift,
//! lower-case, then the key — `ctrl+s`, `shift+up`, `ctrl+pgup`, `f1`, `esc`.
//! The editor computes the canonical name of every key it decodes and looks it
//! up here first; a binding overrides the built-in behaviour.

const std = @import("std");

pub const Action = enum {
    save,
    open,
    quit,
    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    undo,
    redo,
    copy,
    cut,
    paste,
    duplicate_line,
    select_all,
    find,
    find_next,
    find_prev,
    replace,
    goto,
    help,
    clear_selection,
    insert_newline,
    insert_tab,
    backspace,
    delete_forward,
    move_up,
    move_down,
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_home,
    move_end,
    page_up,
    page_down,
    theme_picker,
    command_palette,
    split_columns,
    split_rows,
    close_pane,
    add_cursor_below,
    format,
    add_cursor_above,
    next_pane,
    prev_pane,
    reload_file,
};

pub fn actionFromName(name: []const u8) ?Action {
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return @field(Action, field.name);
    }
    return null;
}

pub const MAX_BINDINGS = 64;
pub const MAX_KEY = 48;

/// The user's overrides. Fixed storage keeps `Config` a plain value type.
pub const KeyMap = struct {
    keys: [MAX_BINDINGS][MAX_KEY]u8 = undefined,
    lens: [MAX_BINDINGS]u8 = undefined,
    actions: [MAX_BINDINGS]Action = undefined,
    count: usize = 0,

    pub fn add(self: *KeyMap, spec: []const u8, action: Action) void {
        if (self.count >= MAX_BINDINGS) return;
        var buf: [MAX_KEY]u8 = undefined;
        const key = canonical(&buf, spec) orelse return;
        const i = self.count;
        @memcpy(self.keys[i][0..key.len], key);
        self.lens[i] = @intCast(key.len);
        self.actions[i] = action;
        self.count += 1;
    }

    pub fn lookup(self: *const KeyMap, name: []const u8) ?Action {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (std.mem.eql(u8, self.keys[i][0..self.lens[i]], name)) return self.actions[i];
        }
        return null;
    }

    /// The key bound to `action`, if the user rebound it (the help panel shows
    /// this instead of the built-in key).
    pub fn keyFor(self: *const KeyMap, action: Action) ?[]const u8 {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.actions[i] == action) return self.keys[i][0..self.lens[i]];
        }
        return null;
    }
};

/// Normalise `Shift+Ctrl+Left` to `ctrl+shift+left`.
pub fn canonical(buf: []u8, spec: []const u8) ?[]const u8 {
    var ctrl = false;
    var alt = false;
    var shift = false;
    var base: []const u8 = "";
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, spec, " \t"), '+');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (p.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(p, "ctrl") or std.ascii.eqlIgnoreCase(p, "control")) {
            ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(p, "alt")) {
            alt = true;
        } else if (std.ascii.eqlIgnoreCase(p, "shift")) {
            shift = true;
        } else {
            base = p;
        }
    }
    if (base.len == 0) return null;
    var n: usize = 0;
    if (ctrl) {
        @memcpy(buf[n..][0..5], "ctrl+");
        n += 5;
    }
    if (alt) {
        @memcpy(buf[n..][0..4], "alt+");
        n += 4;
    }
    if (shift) {
        @memcpy(buf[n..][0..6], "shift+");
        n += 6;
    }
    for (base) |c| {
        if (n >= buf.len) return null;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

// --- tests -----------------------------------------------------------------

test "canonicalises modifier order and case" {
    var buf: [MAX_KEY]u8 = undefined;
    try std.testing.expectEqualStrings("ctrl+shift+left", canonical(&buf, "Shift+Ctrl+Left").?);
    try std.testing.expectEqualStrings("ctrl+s", canonical(&buf, "control+s").?);
    try std.testing.expectEqualStrings("ctrl+s", canonical(&buf, " CTRL + S ").?);
    try std.testing.expectEqualStrings("f1", canonical(&buf, "F1").?);
    try std.testing.expectEqualStrings("esc", canonical(&buf, "ESC").?);
    try std.testing.expect(canonical(&buf, "") == null);
    try std.testing.expect(canonical(&buf, "ctrl+") == null);
}

test "key map stores and finds bindings" {
    var map = KeyMap{};
    try std.testing.expect(map.lookup("ctrl+n") == null);
    map.add("ctrl+n", .new_tab);
    map.add("Shift+Ctrl+S", .save); // canonicalised to ctrl+shift+s
    try std.testing.expectEqual(Action.new_tab, map.lookup("ctrl+n").?);
    try std.testing.expectEqual(Action.save, map.lookup("ctrl+shift+s").?);
    try std.testing.expect(map.lookup("ctrl+s") == null);
}

test "action names round-trip" {
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const a = @field(Action, field.name);
        try std.testing.expectEqual(a, actionFromName(field.name).?);
    }
    try std.testing.expect(actionFromName("nope") == null);
}
