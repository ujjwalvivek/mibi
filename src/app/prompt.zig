//! The one-line prompt on the bottom row: find, replace, go to line, save
//! as, and the yes/no questions before unsaved work is thrown away.

const std = @import("std");
const core = @import("core");
const os = @import("platform").os;
const event = @import("ui").event;
const screen = @import("ui").screen;
const LineEdit = @import("ui").line_edit.LineEdit;
const app_mod = @import("../app.zig");
const doc_mod = @import("doc.zig");
const files = @import("files.zig");
const App = app_mod.App;

pub const Kind = enum {
    save_as,
    find,
    /// Replace, first question: what to look for.
    replace_find,
    /// Replace, second question: what to put there.
    replace_with,
    goto,
    /// A shell command to pipe the selection (or everything) through.
    filter,
    confirm_quit,
    confirm_close,

    fn label(self: Kind) []const u8 {
        return switch (self) {
            .save_as => "Save as: ",
            .find => "Find: ",
            .replace_find => "Replace: ",
            .replace_with => "With: ",
            .goto => "Go to line: ",
            .filter => "Filter through: ",
            .confirm_quit => "Unsaved changes - quit without saving? (y/N) ",
            .confirm_close => "Unsaved changes - close without saving? (y/N) ",
        };
    }

    fn isQuestion(self: Kind) bool {
        return self == .confirm_quit or self == .confirm_close;
    }

    fn isSearch(self: Kind) bool {
        return self == .find or self == .replace_find;
    }
};

pub const Prompt = struct {
    kind: Kind,
    input: LineEdit,
    /// Replace: what the first question was answered with.
    needle: std.ArrayList(u8) = .empty,
    /// Where the view was when a search prompt opened. The search runs from
    /// here as the text is typed, and Esc comes back here.
    origin: doc_mod.ViewState = .{},

    pub fn deinit(self: *Prompt) void {
        self.needle.deinit(self.input.allocator);
        self.input.deinit();
    }
};

pub fn open(app: *App, kind: Kind) !void {
    close(app);
    const v = app.view();
    const sel = v.primarySelection();
    app.prompt = .{
        .kind = kind,
        .input = LineEdit.init(app.allocator),
        .origin = .{ .anchor = sel.anchor, .head = sel.head, .scroll_row = v.scroll_row, .scroll_col = v.scroll_col },
    };
    if (kind == .save_as) {
        if (app.doc().path) |path| try app.prompt.?.input.set(path);
    }
}

pub fn close(app: *App) void {
    if (app.prompt) |*p| p.deinit();
    app.prompt = null;
}

fn restoreOrigin(app: *App, p: *const Prompt) void {
    const v = app.view();
    v.setSelection(.{ .anchor = p.origin.anchor, .head = p.origin.head });
    v.scroll_row = p.origin.scroll_row;
    v.scroll_col = p.origin.scroll_col;
}

pub fn handleKey(app: *App, key: event.Key) !void {
    const p = &app.prompt.?;
    if (p.kind.isQuestion()) {
        // Anything but an explicit yes is a no: the safe answer.
        const yes = key.isText() and (key.cp == 'y' or key.cp == 'Y');
        const kind = p.kind;
        close(app);
        if (!yes) return;
        switch (kind) {
            .confirm_quit => app.quit = true,
            .confirm_close => app.removeDoc(app.activeIndex()),
            else => unreachable,
        }
        return;
    }
    if (key.mods.none()) switch (key.special) {
        .esc => {
            if (p.kind.isSearch()) restoreOrigin(app, p);
            return close(app);
        },
        .enter => return execute(app),
        .tab => {
            if (p.kind == .save_as) try completePath(app.allocator, &p.input);
            return;
        },
        else => {},
    };
    if (key.eql(event.Key.ctrl('r')) and (p.kind.isSearch() or p.kind == .replace_with)) {
        app.search_regex = !app.search_regex;
        if (p.kind.isSearch()) try changed(app);
        if (app.message().len == 0) app.setMessage("{s}", .{if (app.search_regex) "regex on" else "regex off"});
        return;
    }
    // Arrow keys up and down, function keys and shortcuts mean nothing
    // here, and must not close the prompt or reach the document.
    if (try p.input.handleKey(key)) try changed(app);
}

/// The prompt's text changed: a search prompt searches as you type.
pub fn changed(app: *App) !void {
    const p = &app.prompt.?;
    if (!p.kind.isSearch()) return;
    try app.setSearch(p.input.value());
    if (app.search == null or !app.selectMatchFrom(p.origin.head)) {
        restoreOrigin(app, p);
        if (app.search != null) app.setMessage("not found", .{});
    }
}

fn execute(app: *App) !void {
    const p = &app.prompt.?;
    const text = p.input.value();
    switch (p.kind) {
        .save_as => {
            if (text.len > 0) {
                const path = try app.allocator.dupe(u8, text);
                defer app.allocator.free(path);
                close(app);
                return app.saveAs(path);
            }
        },
        .find => {
            // Already searched as it was typed; the match stays selected.
            if (text.len > 0 and app.search != null and app.view().primarySelection().isEmpty()) {
                app.setMessage("not found", .{});
            }
        },
        .replace_find => {
            if (text.len == 0) return close(app);
            p.needle.clearRetainingCapacity();
            try p.needle.appendSlice(app.allocator, text);
            p.input.clear();
            p.kind = .replace_with;
            return; // stays open for the second question
        },
        .replace_with => {
            // Put the cursor back first: replacing moves it with the text.
            restoreOrigin(app, p);
            try app.setSearch(p.needle.items);
            if (app.search) |*s| {
                const n = try s.replaceAll(app.view(), text);
                app.setMessage("{d} replaced", .{n});
            }
        },
        .goto => gotoLine(app, text),
        .filter => {
            const command = try app.allocator.dupe(u8, text);
            defer app.allocator.free(command);
            close(app);
            return files.filter(app, command);
        },
        .confirm_quit, .confirm_close => unreachable,
    }
    close(app);
}

/// "12" or "12:5": line, and optionally column, both counted from 1.
fn gotoLine(app: *App, text: []const u8) void {
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, text, " "), ':');
    const line = std.fmt.parseInt(usize, parts.first(), 10) catch return;
    const col = if (parts.next()) |c| std.fmt.parseInt(usize, c, 10) catch 1 else 1;
    if (line == 0) return;
    const buf = &app.doc().document.buffer;
    const row = @min(line - 1, buf.lineCount() - 1);
    const start = buf.lineStart(row);
    app.view().setCaret(@min(start + (col -| 1), buf.lineEnd(row)));
    app.pane().reveal = true;
}

/// The directory part of a typed path, or "." when there is none.
pub fn promptDir(text: []const u8) []const u8 {
    var i = text.len;
    while (i > 0) : (i -= 1) {
        const c = text[i - 1];
        if (c == '/' or c == '\\') return text[0..i];
    }
    return ".";
}

/// Tab completion: extend the last path component to the longest prefix
/// shared by the directory entries that start with it.
fn completePath(allocator: std.mem.Allocator, input: *LineEdit) !void {
    const text = input.value();
    const dir = promptDir(text);
    const has_dir = std.mem.indexOfAny(u8, text, "/\\") != null;
    const base = if (has_dir) text[dir.len..] else text;
    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    os.listDirNames(allocator, dir, &names) catch return;
    var prefix: ?[]const u8 = null;
    for (names.items) |n| {
        if (!std.mem.startsWith(u8, n, base)) continue;
        prefix = if (prefix) |pr| pr[0 .. std.mem.indexOfDiff(u8, pr, n) orelse pr.len] else n;
    }
    const found = prefix orelse return;
    if (found.len <= base.len) return;
    const head_len = text.len - base.len;
    const completed = try std.mem.concat(allocator, u8, &.{ text[0..head_len], found });
    defer allocator.free(completed);
    try input.set(completed);
}

pub fn draw(app: *App, s: *screen.Screen) void {
    const p = &app.prompt.?;
    const theme = &app.config.theme;
    const w = s.cols;
    const y = s.rows - 1;

    // Saving: one line of what is in the directory being typed, like `ls`.
    if (p.kind == .save_as and s.rows >= 3) {
        var line = std.ArrayList(u8).empty;
        defer line.deinit(app.allocator);
        os.listDirLine(app.allocator, promptDir(p.input.value()), &line) catch {};
        s.fill(.{ .y = y - 1, .w = w, .h = 1 }, .{ .bg = theme.hint_bg });
        _ = s.text(0, y - 1, w, line.items, .{ .bg = theme.hint_bg, .fg = theme.hint_fg });
    }

    s.fill(.{ .y = y, .w = w, .h = 1 }, .{ .bg = theme.bar_bg });
    var x = s.text(0, y, w, p.kind.label(), .{ .bg = theme.bar_bg, .fg = theme.accent });
    if (p.kind.isQuestion()) return;
    // On the right: what went wrong (a bad pattern, nothing found), or
    // else how the search reads its text.
    var right = w;
    var note = app.message();
    if (note.len == 0 and (p.kind.isSearch() or p.kind == .replace_with)) {
        note = if (app.search_regex) "regex  ctrl+r: plain" else "plain  ctrl+r: regex";
    }
    if (note.len > 0 and w > x + note.len + 12) {
        right = w - note.len - 2;
        _ = s.text(right + 1, y, w, note, .{ .bg = theme.bar_bg, .fg = theme.hint_fg });
    }
    x = @min(x, right);
    p.input.draw(s, x, y, right, .{ .bg = theme.bar_bg, .fg = theme.text });
}

test "promptDir extracts the directory part of a path" {
    try std.testing.expectEqualStrings(".", promptDir("notes.txt"));
    try std.testing.expectEqualStrings("src/", promptDir("src/ma"));
    try std.testing.expectEqualStrings("a/b/", promptDir("a/b/"));
    try std.testing.expectEqualStrings("C:\\x\\", promptDir("C:\\x\\y"));
}
