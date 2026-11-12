//! The frame: tab bar, file tree, panes, status line, and whatever panel is
//! open on top. A pure function of the app's state into a `Screen`, apart
//! from two things it records for the mouse: where the panes are and how
//! large the screen is.

const std = @import("std");
const core = @import("core");
const commands = @import("../commands.zig");
const screen = @import("ui").screen;
const editor_pane = @import("ui").editor_pane;
const tabbar = @import("ui").tabbar;
const tree_mod = @import("tree.zig");
const app_mod = @import("../app.zig");
const prompt = @import("prompt.zig");
const pickers = @import("pickers.zig");
const App = app_mod.App;
const Command = commands.Command;

const tree_width = 28;

/// Columns the file tree takes. On a narrow screen it is not drawn at all:
/// the text matters more.
pub fn sidebarWidth(app: *const App) usize {
    return if (app.tree != null and app.cols >= tree_width + 20) tree_width else 0;
}

pub fn draw(app: *App, s: *screen.Screen) void {
    app.cols = s.cols;
    app.rows = s.rows;
    s.clear();
    const w = s.cols;
    const h = s.rows;
    if (h < 3 or w < 4) return;
    const theme = &app.config.theme;
    if (!theme.background.isDefault()) s.fill(s.area(), .{ .bg = theme.background });

    drawTabs(app, s);
    const side = sidebarWidth(app);
    if (side > 0) drawTree(app, s, side);

    // Row 0 is the tab bar and the last row the status line; the tree takes
    // the left columns.
    app.pane_area = .{ .x = side, .y = 1, .w = w - side, .h = h - 2 };
    app.layout.layout(app.pane_area);
    const focus = app.layout.focused();
    for (app.layout.rects[0..app.layout.rect_count]) |pr| {
        const p = &(app.panes[pr.pane] orelse continue);
        const v = p.view;
        if (p.reveal) {
            v.scrollToCursor(pr.rect.h, editor_pane.textCols(v, pr.rect.w, app.config.line_numbers));
            p.reveal = false;
        }
        v.scroll_row = @min(v.scroll_row, v.doc.buffer.lineCount() - 1);
        editor_pane.draw(s, pr.rect, v, .{
            .theme = theme,
            .line_numbers = app.config.line_numbers,
            .focused = focus == pr.pane,
            .highlighter = if (p.doc.highlighter.lang != null) p.doc.highlighter else null,
        });
    }

    if (app.mouse.drag != null) {
        if (app.mouse.drop) |zone| drawDropHint(app, s, zone);
    }
    drawSeparators(app, s);

    if (app.prompt != null) {
        prompt.draw(app, s);
    } else {
        drawStatus(app, s);
        // The help panel covers the bottom rows, so it gives way to a
        // prompt, which lives on the last one.
        if (app.help) drawHelp(app, s);
    }
    if (app.picker != null) pickers.draw(app, s);
    updateTitle(app);
}

fn drawTabs(app: *App, s: *screen.Screen) void {
    var fallback = std.heap.stackFallback(2048, app.allocator);
    const a = fallback.get();
    const tabs = a.alloc(tabbar.Tab, app.docs.items.len) catch return;
    defer a.free(tabs);
    for (app.docs.items, tabs) |d, *t| t.* = .{ .name = d.name(), .dirty = d.isDirty() };
    app.tabbar.draw(s, 0, tabs, app.activeIndex(), app.mouse.drag, &app.config.theme);
}

fn drawTree(app: *App, s: *screen.Screen, width: usize) void {
    const t = &app.tree.?;
    const theme = &app.config.theme;
    const rows = s.rows - 2;
    if (app.tree_focus) t.ensureVisible(rows);
    // A bar like the tab strip and the status line: its own surface.
    const bg = theme.bar_bg;
    s.fill(.{ .y = 1, .w = width, .h = rows }, .{ .bg = bg });

    var row: usize = 0;
    while (row < rows and t.scroll + row < t.entries.items.len) : (row += 1) {
        const index = t.scroll + row;
        const e = t.entries.items[index];
        const selected = index == t.selected;
        const row_bg = if (selected) (if (app.tree_focus) theme.selection else theme.tab_bg) else bg;
        const y = 1 + row;
        // The whole row, so the highlight is a bar rather than a word.
        if (selected) s.fill(.{ .y = y, .w = width, .h = 1 }, .{ .bg = row_bg });
        const icon = if (e.is_parent)
            (if (app.config.icons_unicode) "\u{f062}" else "^")
        else
            tree_mod.iconFor(e.name, e.is_dir, e.is_dir and t.isExpanded(e.path), app.config.icons_unicode);
        const style = screen.Style{
            .bg = row_bg,
            .fg = if (!selected and e.is_dir) theme.keyword2 else theme.text,
            .attr = .{ .bold = selected },
        };
        var x = 2 + @min(e.depth * 2, width - 8);
        x = s.text(x, y, width, icon, style);
        _ = s.text(x + 1, y, width, e.name, style);
    }
}

fn drawDropHint(app: *App, s: *screen.Screen, zone: app_mod.mouse.DropZone) void {
    const r = zone.rect(app.layout.rectOf(zone.pane) orelse return);
    // Only the background changes, so the text under the target stays
    // readable.
    var y = r.y;
    while (y < @min(r.bottom(), s.rows)) : (y += 1) {
        var x = r.x;
        while (x < @min(r.right(), s.cols)) : (x += 1) {
            var cell = s.at(x, y);
            cell.bg = app.config.theme.selection;
            s.put(x, y, cell);
        }
    }
}

fn drawSeparators(app: *App, s: *screen.Screen) void {
    const theme = &app.config.theme;
    const focus_rect = if (app.layout.focused()) |f| app.layout.rectOf(f) else null;
    for (app.layout.seps[0..app.layout.sep_count]) |sep| {
        // The lines beside the focused pane take the accent colour.
        var hot = false;
        if (focus_rect) |fr| {
            hot = if (sep.dir == .columns)
                (fr.x == sep.x + 1 or fr.right() == sep.x) and fr.y < sep.y + sep.len and sep.y < fr.bottom()
            else
                (fr.y == sep.y + 1 or fr.bottom() == sep.y) and fr.x < sep.x + sep.len and sep.x < fr.right();
        }
        const fg = if (hot) theme.accent else theme.gutter;
        var k: usize = 0;
        while (k < sep.len) : (k += 1) {
            if (sep.dir == .columns) {
                s.put(sep.x, sep.y + k, .{ .ch = 0x2502, .fg = fg, .bg = theme.background });
            } else {
                s.put(sep.x + k, sep.y, .{ .ch = 0x2500, .fg = fg, .bg = theme.background });
            }
        }
    }
}

fn drawStatus(app: *App, s: *screen.Screen) void {
    const theme = &app.config.theme;
    const w = s.cols;
    const y = s.rows - 1;
    const d = app.doc();
    const v = app.view();
    const head = v.primarySelection().head;
    const row = d.document.buffer.lineOf(head);

    var msg = app.message();
    // Hovering a tab shows its full path: the tab only has room for a name.
    switch (app.tabbar.hover) {
        .tab, .close => |i| if (i < app.docs.items.len) {
            if (app.docs.items[i].path) |p| msg = p;
        },
        else => {},
    }

    var buf: [512]u8 = undefined;
    var cursors_buf: [32]u8 = undefined;
    const cursors = if (v.hasMultiple())
        std.fmt.bufPrint(&cursors_buf, "  {d} cursors", .{v.selections.items.len}) catch ""
    else
        "";
    const status = std.fmt.bufPrint(&buf, " mibi  {s}{s}  {d}:{d}  {d}L  {s}{s}{s}{s}  {s}", .{
        d.path orelse "[No Name]",
        if (d.isDirty()) " [+]" else "",
        row + 1,
        v.cellOf(head) + 1,
        d.document.buffer.lineCount(),
        if (d.document.line_ending == .crlf) "CRLF" else "LF",
        if (d.highlighter.lang != null) "  " else "",
        if (d.highlighter.lang) |l| l.name else "",
        cursors,
        msg,
    }) catch " mibi";

    s.fill(.{ .y = y, .w = w, .h = 1 }, .{ .bg = theme.bar_bg });
    // The hint keeps the right edge; the status text is cut before it.
    var hint_buf: [64]u8 = undefined;
    var key_buf: [48]u8 = undefined;
    const hint = if (app.config.keys.keyFor(.help)) |k|
        std.fmt.bufPrint(&hint_buf, "{s} help", .{k.format(&key_buf)}) catch "help"
    else
        "";
    const hint_x = if (hint.len > 0 and w > hint.len + 2) w - hint.len - 1 else w;
    _ = s.text(0, y, hint_x -| 1, status, .{ .bg = theme.bar_bg, .fg = theme.accent });
    if (hint_x < w) _ = s.text(hint_x, y, w, hint, .{ .bg = theme.bar_bg, .fg = theme.hint_fg });
}

const HelpRow = struct {
    commands: []const Command = &.{},
    /// For things that are not commands (the mouse).
    keys: []const u8 = "",
    text: []const u8,
};

/// The help panel. Keys come from the key map, so a rebound key shows here
/// as what it is now.
const help_rows = [_]HelpRow{
    .{ .commands = &.{ .move_word_left, .move_word_right }, .text = "move by word (shift selects)" },
    .{ .commands = &.{ .move_home, .move_end }, .text = "line start / end" },
    .{ .commands = &.{ .move_doc_start, .move_doc_end }, .text = "start / end of file" },
    .{ .commands = &.{ .select_all, .clear_selection }, .text = "select all / clear" },
    .{ .commands = &.{ .copy, .cut, .paste }, .text = "copy / cut / paste" },
    .{ .commands = &.{ .undo, .redo }, .text = "undo / redo" },
    .{ .commands = &.{ .duplicate_line, .delete_line }, .text = "duplicate / delete line" },
    .{ .commands = &.{ .move_line_up, .move_line_down }, .text = "move line up / down" },
    .{ .commands = &.{.toggle_comment}, .text = "comment / uncomment" },
    .{ .commands = &.{ .add_cursor_above, .add_cursor_below }, .text = "add a cursor above / below" },
    .{ .commands = &.{ .find, .find_next, .find_prev }, .text = "find / next / previous" },
    .{ .commands = &.{ .replace, .goto }, .text = "replace / go to line[:col]" },
    .{ .commands = &.{ .save, .open }, .text = "save / open file" },
    .{ .commands = &.{ .command_palette, .theme_picker }, .text = "command palette / themes" },
    .{ .commands = &.{ .new_tab, .close_tab }, .text = "new / close tab" },
    .{ .commands = &.{ .next_tab, .prev_tab }, .text = "next / previous tab" },
    .{ .commands = &.{ .split_columns, .split_rows }, .text = "split side by side / stacked" },
    .{ .commands = &.{ .close_pane, .next_pane }, .text = "close pane / next pane" },
    .{ .commands = &.{.toggle_tree}, .text = "file tree (arrows, enter)" },
    .{ .commands = &.{.format}, .text = "format with the configured tool" },
    .{ .keys = "click, drag, wheel", .text = "cursor, selection, tabs / scroll" },
    .{ .commands = &.{ .help, .quit }, .text = "this help / quit" },
};

fn drawHelp(app: *App, s: *screen.Screen) void {
    const theme = &app.config.theme;
    const w = s.cols;
    const h = s.rows;
    const panel_h = @min(h - 1, help_rows.len + 1);
    const top = h - panel_h;
    const style = screen.Style{ .bg = theme.help_bg, .fg = theme.text };
    s.fill(.{ .y = top, .w = w, .h = panel_h }, style);
    _ = s.text(1, top, w, "mibi " ++ app_mod.version ++ " controls", .{ .bg = theme.help_bg, .fg = theme.accent });
    const text_x = 30;
    for (help_rows, 0..) |row, i| {
        const y = top + 1 + i;
        if (y >= h) break;
        var x: usize = 2;
        if (row.keys.len > 0) x = s.text(x, y, w, row.keys, style);
        var shown: usize = 0;
        for (row.commands) |command| {
            const key = app.config.keys.keyFor(command) orelse continue;
            var key_buf: [48]u8 = undefined;
            if (shown > 0) x = s.text(x, y, w, " / ", .{ .bg = theme.help_bg, .fg = theme.hint_fg });
            x = s.text(x, y, w, key.format(&key_buf), style);
            shown += 1;
        }
        _ = s.text(@max(x + 2, text_x), y, w, row.text, .{ .bg = theme.help_bg, .fg = theme.hint_fg });
    }
}

/// Keep the terminal's title in step with the focused document, so the
/// window says "mibi - notes.txt" and not the path of the executable.
fn updateTitle(app: *App) void {
    const d = app.doc();
    var buf: [200]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "mibi - {s}{s}", .{ d.name(), if (d.isDirty()) " [+]" else "" }) catch "mibi";
    if (std.mem.eql(u8, title, app.title.items)) return;
    app.title.clearRetainingCapacity();
    app.title.appendSlice(app.allocator, title) catch return;
    // OSC 2. Control bytes in a file name must not end the sequence early.
    app.term_out.ensureUnusedCapacity(app.allocator, title.len + 8) catch return;
    app.term_out.appendSliceAssumeCapacity("\x1b]2;");
    for (title) |b| app.term_out.appendAssumeCapacity(if (b < 0x20 or b == 0x7f) '?' else b);
    app.term_out.appendAssumeCapacity(0x07);
}
