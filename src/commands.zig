//! Every command the editor has, in one table.
//!
//! The table is the single source for four things that used to be written out
//! separately and drift apart: the default key bindings, the names accepted
//! in `[keys]` of `mibi.ini`, the command palette, and the help panel. Adding
//! a command is adding a row here and a case in `App.run`.

const std = @import("std");
const event = @import("ui/event.zig");
const Key = event.Key;

pub const Command = enum {
    // Files and tabs.
    save,
    save_as,
    open,
    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    quit,
    // Editing.
    undo,
    redo,
    copy,
    cut,
    paste,
    duplicate_line,
    delete_line,
    move_line_up,
    move_line_down,
    toggle_comment,
    indent,
    dedent,
    insert_newline,
    insert_tab,
    backspace,
    delete_forward,
    delete_word_back,
    delete_word_forward,
    format,
    // Selection and cursors.
    select_all,
    clear_selection,
    add_cursor_above,
    add_cursor_below,
    // Movement. Shift with any of these keys extends the selection.
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
    move_doc_start,
    move_doc_end,
    // Search.
    find,
    find_next,
    find_prev,
    replace,
    goto,
    // Panels and panes.
    command_palette,
    theme_picker,
    toggle_tree,
    help,
    split_columns,
    split_rows,
    close_pane,
    next_pane,
    prev_pane,

    pub fn fromName(name: []const u8) ?Command {
        return std.meta.stringToEnum(Command, name);
    }

    pub fn info(self: Command) *const Info {
        return &table[@intFromEnum(self)];
    }

    /// Movement commands: Shift plus their key extends the selection.
    pub fn isMotion(self: Command) bool {
        return @intFromEnum(self) >= @intFromEnum(Command.move_up) and
            @intFromEnum(self) <= @intFromEnum(Command.move_doc_end);
    }
};

pub const Info = struct {
    command: Command,
    /// What the command palette and the help panel call it.
    title: []const u8,
    /// Default bindings, in `Key.parse` notation. The first one is the one
    /// shown next to the command.
    keys: []const []const u8 = &.{},
    /// Listed in the command palette. Commands that only make sense as a key
    /// (typing a newline, moving the cursor) are not.
    palette: bool = true,
};

/// One row per command, in enum order (checked at compile time).
pub const table = [_]Info{
    .{ .command = .save, .title = "Save", .keys = &.{"ctrl+s"} },
    .{ .command = .save_as, .title = "Save as..." },
    .{ .command = .open, .title = "Open file...", .keys = &.{"ctrl+o"} },
    .{ .command = .new_tab, .title = "New tab", .keys = &.{"ctrl+t"} },
    .{ .command = .close_tab, .title = "Close tab", .keys = &.{"ctrl+w"} },
    .{ .command = .next_tab, .title = "Next tab", .keys = &.{"ctrl+pgdn"} },
    .{ .command = .prev_tab, .title = "Previous tab", .keys = &.{"ctrl+pgup"} },
    .{ .command = .quit, .title = "Quit", .keys = &.{"ctrl+q"} },

    .{ .command = .undo, .title = "Undo", .keys = &.{"ctrl+z"} },
    .{ .command = .redo, .title = "Redo", .keys = &.{"ctrl+y"} },
    .{ .command = .copy, .title = "Copy", .keys = &.{"ctrl+c"} },
    .{ .command = .cut, .title = "Cut", .keys = &.{"ctrl+x"} },
    .{ .command = .paste, .title = "Paste", .keys = &.{"ctrl+v"} },
    .{ .command = .duplicate_line, .title = "Duplicate line", .keys = &.{"ctrl+d"} },
    .{ .command = .delete_line, .title = "Delete line", .keys = &.{"ctrl+k"} },
    .{ .command = .move_line_up, .title = "Move line up", .keys = &.{"alt+up"} },
    .{ .command = .move_line_down, .title = "Move line down", .keys = &.{"alt+down"} },
    .{ .command = .toggle_comment, .title = "Toggle comment", .keys = &.{"ctrl+/"} },
    .{ .command = .indent, .title = "Indent" },
    .{ .command = .dedent, .title = "Dedent", .keys = &.{"shift+tab"} },
    .{ .command = .insert_newline, .title = "Insert newline", .keys = &.{"enter"}, .palette = false },
    .{ .command = .insert_tab, .title = "Insert tab", .keys = &.{"tab"}, .palette = false },
    .{ .command = .backspace, .title = "Delete backward", .keys = &.{"backspace"}, .palette = false },
    .{ .command = .delete_forward, .title = "Delete forward", .keys = &.{"delete"}, .palette = false },
    .{ .command = .delete_word_back, .title = "Delete word backward", .keys = &.{ "ctrl+backspace", "alt+backspace" }, .palette = false },
    .{ .command = .delete_word_forward, .title = "Delete word forward", .keys = &.{"ctrl+delete"}, .palette = false },
    .{ .command = .format, .title = "Format with the configured tool", .keys = &.{"f4"} },

    .{ .command = .select_all, .title = "Select all", .keys = &.{"ctrl+a"} },
    .{ .command = .clear_selection, .title = "Clear selection", .keys = &.{"esc"}, .palette = false },
    .{ .command = .add_cursor_above, .title = "Add cursor above", .keys = &.{"ctrl+alt+up"} },
    .{ .command = .add_cursor_below, .title = "Add cursor below", .keys = &.{"ctrl+alt+down"} },

    .{ .command = .move_up, .title = "Move up", .keys = &.{"up"}, .palette = false },
    .{ .command = .move_down, .title = "Move down", .keys = &.{"down"}, .palette = false },
    .{ .command = .move_left, .title = "Move left", .keys = &.{"left"}, .palette = false },
    .{ .command = .move_right, .title = "Move right", .keys = &.{"right"}, .palette = false },
    .{ .command = .move_word_left, .title = "Move word left", .keys = &.{"ctrl+left"}, .palette = false },
    .{ .command = .move_word_right, .title = "Move word right", .keys = &.{"ctrl+right"}, .palette = false },
    .{ .command = .move_home, .title = "Line start", .keys = &.{"home"}, .palette = false },
    .{ .command = .move_end, .title = "Line end", .keys = &.{"end"}, .palette = false },
    .{ .command = .page_up, .title = "Page up", .keys = &.{"pgup"}, .palette = false },
    .{ .command = .page_down, .title = "Page down", .keys = &.{"pgdn"}, .palette = false },
    .{ .command = .move_doc_start, .title = "Start of file", .keys = &.{"ctrl+home"}, .palette = false },
    .{ .command = .move_doc_end, .title = "End of file", .keys = &.{"ctrl+end"}, .palette = false },

    .{ .command = .find, .title = "Find", .keys = &.{"ctrl+f"} },
    .{ .command = .find_next, .title = "Find next", .keys = &.{"f3"} },
    .{ .command = .find_prev, .title = "Find previous", .keys = &.{"shift+f3"} },
    .{ .command = .replace, .title = "Replace", .keys = &.{"ctrl+r"} },
    .{ .command = .goto, .title = "Go to line", .keys = &.{"ctrl+g"} },

    .{ .command = .command_palette, .title = "Command palette", .keys = &.{"ctrl+p"}, .palette = false },
    .{ .command = .theme_picker, .title = "Choose theme", .keys = &.{"f2"} },
    .{ .command = .toggle_tree, .title = "Toggle file tree", .keys = &.{"ctrl+b"} },
    .{ .command = .help, .title = "Toggle help", .keys = &.{"f1"} },
    .{ .command = .split_columns, .title = "Split side by side", .keys = &.{"f5"} },
    .{ .command = .split_rows, .title = "Split stacked", .keys = &.{"f7"} },
    .{ .command = .close_pane, .title = "Close pane", .keys = &.{ "shift+f5", "shift+f7" } },
    .{ .command = .next_pane, .title = "Next pane", .keys = &.{"f6"} },
    .{ .command = .prev_pane, .title = "Previous pane", .keys = &.{ "shift+f6", "ctrl+f6" } },
};

comptime {
    @setEvalBranchQuota(200_000);
    const fields = @typeInfo(Command).@"enum".fields;
    if (table.len != fields.len) @compileError("commands.table must have one row per Command");
    for (table, 0..) |row, i| {
        if (@intFromEnum(row.command) != i) @compileError("commands.table is out of order at " ++ fields[i].name);
        for (row.keys) |spec| {
            if (Key.parse(spec) == null) @compileError("bad default key: " ++ spec);
        }
    }
}

const Binding = struct { key: Key, command: Command };

const default_bindings = blk: {
    @setEvalBranchQuota(200_000);
    var n: usize = 0;
    for (table) |row| n += row.keys.len;
    var out: [n]Binding = undefined;
    var i: usize = 0;
    for (table) |row| {
        for (row.keys) |spec| {
            out[i] = .{ .key = Key.parse(spec).?, .command = row.command };
            i += 1;
        }
    }
    break :blk out;
};

/// What a key press means: a command, and for movement whether it extends
/// the selection.
pub const Resolved = struct {
    command: Command,
    extend: bool = false,
};

/// The defaults plus the user's `[keys]` overrides.
pub const KeyMap = struct {
    pub const max_user = 64;

    user: [max_user]Binding = undefined,
    count: usize = 0,

    /// Bind `spec` (as written in `mibi.ini`) to a command. Returns false
    /// when the key name does not parse or the table is full.
    pub fn bind(self: *KeyMap, spec: []const u8, command: Command) bool {
        const key = Key.parse(spec) orelse return false;
        for (self.user[0..self.count]) |*b| {
            if (b.key.eql(key)) {
                b.command = command;
                return true;
            }
        }
        if (self.count >= max_user) return false;
        self.user[self.count] = .{ .key = key, .command = command };
        self.count += 1;
        return true;
    }

    fn exact(self: *const KeyMap, key: Key) ?Command {
        for (self.user[0..self.count]) |b| {
            if (b.key.eql(key)) return b.command;
        }
        for (default_bindings) |b| {
            if (!b.key.eql(key)) continue;
            // A command the user moved to another key gives up its default.
            if (self.userKeyFor(b.command) != null) continue;
            return b.command;
        }
        return null;
    }

    pub fn resolve(self: *const KeyMap, key: Key) ?Resolved {
        if (self.exact(key)) |command| return .{ .command = command };
        if (key.mods.shift) {
            if (self.exact(key.withoutShift())) |command| {
                if (command.isMotion()) return .{ .command = command, .extend = true };
            }
        }
        return null;
    }

    fn userKeyFor(self: *const KeyMap, command: Command) ?Key {
        for (self.user[0..self.count]) |b| {
            if (b.command == command) return b.key;
        }
        return null;
    }

    /// The key shown next to a command: the user's binding if there is one,
    /// otherwise the first default that the user has not taken for something
    /// else.
    pub fn keyFor(self: *const KeyMap, command: Command) ?Key {
        if (self.userKeyFor(command)) |key| return key;
        for (default_bindings) |b| {
            if (b.command != command) continue;
            if (self.exact(b.key) == command) return b.key;
        }
        return null;
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn k(spec: []const u8) Key {
    return Key.parse(spec).?;
}

test "defaults resolve, and shift extends movement only" {
    const map = KeyMap{};
    try testing.expectEqual(Command.save, map.resolve(k("ctrl+s")).?.command);
    try testing.expectEqual(Command.find_prev, map.resolve(k("shift+f3")).?.command);
    try testing.expect(!map.resolve(k("shift+f3")).?.extend);

    const right = map.resolve(k("shift+right")).?;
    try testing.expectEqual(Command.move_right, right.command);
    try testing.expect(right.extend);
    const word = map.resolve(k("ctrl+shift+left")).?;
    try testing.expectEqual(Command.move_word_left, word.command);
    try testing.expect(word.extend);

    // Shift+Tab is its own command, not "tab, extended".
    try testing.expectEqual(Command.dedent, map.resolve(k("shift+tab")).?.command);
    // Shift on a non-movement key does not fall back.
    try testing.expect(map.resolve(k("shift+f1")) == null);
    try testing.expect(map.resolve(k("x")) == null);
}

test "a user binding overrides the default and frees the old key" {
    var map = KeyMap{};
    try testing.expect(map.bind("ctrl+n", .new_tab));
    try testing.expectEqual(Command.new_tab, map.resolve(k("ctrl+n")).?.command);
    // new_tab moved, so its default key no longer triggers it.
    try testing.expect(map.resolve(k("ctrl+t")) == null);

    // Taking a key that another command had by default.
    try testing.expect(map.bind("Ctrl+S", .quit));
    try testing.expectEqual(Command.quit, map.resolve(k("ctrl+s")).?.command);
    try testing.expect(map.keyFor(.save) == null);
    try testing.expect(map.keyFor(.quit).?.eql(k("ctrl+s")));

    // Binding the same key again replaces it.
    try testing.expect(map.bind("ctrl+s", .save));
    try testing.expectEqual(Command.save, map.resolve(k("ctrl+s")).?.command);
    try testing.expect(!map.bind("not a key+", .save));
}

test "keyFor shows the first default" {
    const map = KeyMap{};
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("ctrl+s", map.keyFor(.save).?.format(&buf));
    try testing.expectEqualStrings("shift+f5", map.keyFor(.close_pane).?.format(&buf));
    try testing.expect(map.keyFor(.save_as) == null);
}

test "every command name round-trips and no default key is bound twice" {
    inline for (@typeInfo(Command).@"enum".fields) |field| {
        try testing.expectEqual(@field(Command, field.name), Command.fromName(field.name).?);
    }
    try testing.expect(Command.fromName("nope") == null);
    for (default_bindings, 0..) |a, i| {
        for (default_bindings[i + 1 ..]) |b| {
            try testing.expect(!a.key.eql(b.key));
        }
    }
}
