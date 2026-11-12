//! The mouse: tabs (click, close, drag to reorder, drag into a pane to
//! split), the file tree, the text (click, double and triple click, drag to
//! select, shift and ctrl click) and the wheel.

const std = @import("std");
const event = @import("ui").event;
const layout = @import("ui").layout;
const screen = @import("ui").screen;
const editor_pane = @import("ui").editor_pane;
const tabbar = @import("ui").tabbar;
const app_mod = @import("../app.zig");
const pickers = @import("pickers.zig");
const drawing = @import("draw.zig");
const App = app_mod.App;

/// A press becomes a drag only after the pointer has moved this far, so
/// clicking a tab never flashes the drag marker.
const drag_threshold = 3;
/// Clicks on the same cell closer together than this count as a double or
/// triple click.
const click_ms = 500;
/// Lines one notch of the wheel scrolls.
const wheel_lines = 3;

pub const DropSide = enum { left, right, top, bottom };

/// Where a dragged tab would land: a half of a pane.
pub const DropZone = struct {
    pane: u8,
    side: DropSide,

    pub fn rect(self: DropZone, r: screen.Rect) screen.Rect {
        return switch (self.side) {
            .left => .{ .x = r.x, .y = r.y, .w = (r.w + 1) / 2, .h = r.h },
            .right => .{ .x = r.x + r.w / 2, .y = r.y, .w = r.w - r.w / 2, .h = r.h },
            .top => .{ .x = r.x, .y = r.y, .w = r.w, .h = (r.h + 1) / 2 },
            .bottom => .{ .x = r.x, .y = r.y + r.h / 2, .w = r.w, .h = r.h - r.h / 2 },
        };
    }
};

pub const State = struct {
    /// A tab that was pressed and not yet released.
    press_tab: ?usize = null,
    press_x: usize = 0,
    press_y: usize = 0,
    /// Set once the press has moved far enough to be a drag.
    drag: ?tabbar.Drag = null,
    drop: ?DropZone = null,
    /// The pane in which a drag is selecting text.
    selecting: ?u8 = null,
    click_count: u8 = 0,
    click_at_ms: u64 = 0,
    click_x: usize = 0,
    click_y: usize = 0,
};

/// Which part of which pane the pointer is over: the left and right thirds
/// split side by side, the middle splits top or bottom.
fn dropZoneAt(app: *const App, x: usize, y: usize) ?DropZone {
    const pane = app.layout.paneAt(x, y) orelse return null;
    const r = app.layout.rectOf(pane) orelse return null;
    if (r.w < 2 or r.h < 2) return null;
    const rx = x - r.x;
    const ry = y - r.y;
    const side: DropSide = if (rx * 3 < r.w)
        .left
    else if (rx * 3 >= r.w * 2)
        .right
    else if (ry * 2 < r.h)
        .top
    else
        .bottom;
    return .{ .pane = pane, .side = side };
}

fn tabUnder(app: *const App, x: usize) ?usize {
    return switch (app.tabbar.hit(x)) {
        .tab, .close => |i| i,
        else => null,
    };
}

pub fn handle(app: *App, m: event.Mouse) !void {
    if (app.picker != null) return pickers.handleMouse(app, m);
    const st = &app.mouse;
    const x: usize = m.x;
    const y: usize = m.y;

    switch (m.kind) {
        .move => {
            app.tabbar.hover = if (y == 0) app.tabbar.hit(x) else .none;
        },
        .wheel_up, .wheel_down => {
            const down = m.kind == .wheel_down;
            if (y == 0) return app.tabbar.scrollBy(if (down) 1 else -1);
            if (app.tree) |*t| {
                if (x < drawing.sidebarWidth(app)) {
                    const max = t.count() -| 1;
                    t.scroll = if (down) @min(t.scroll + wheel_lines, max) else t.scroll -| wheel_lines;
                    return;
                }
            }
            // The pane under the pointer scrolls, focused or not, and its
            // cursor stays where it is.
            const id = app.layout.paneAt(x, y) orelse return;
            const p = &app.panes[id].?;
            const last = p.view.doc.buffer.lineCount() - 1;
            p.view.scroll_row = if (down) @min(p.view.scroll_row + wheel_lines, last) else p.view.scroll_row -| wheel_lines;
            p.reveal = false;
        },
        .press => {
            if (m.button != .left) return;
            // A press always starts fresh: a release that never arrived
            // must not leave a drag marker behind.
            st.* = .{ .click_count = st.click_count, .click_at_ms = st.click_at_ms, .click_x = st.click_x, .click_y = st.click_y };
            app.message_len = 0;
            if (app.prompt != null) return;
            if (y == 0) return pressTabBar(app, x);
            try pressBody(app, m);
        },
        .drag => {
            if (m.button != .left) return;
            if (st.press_tab) |from| {
                if (st.drag == null) {
                    const dx = if (x > st.press_x) x - st.press_x else st.press_x - x;
                    const dy = if (y > st.press_y) y - st.press_y else st.press_y - y;
                    // Either axis counts: straight down from the tab bar
                    // into a pane is a drag too.
                    if (@max(dx, dy) < drag_threshold) return;
                    st.drag = .{ .from = from, .to = from, .x = x };
                }
                st.drag.?.x = x;
                st.drag.?.to = if (y == 0) tabUnder(app, x) orelse from else from;
                // Over the text a drop means "split this pane here".
                st.drop = if (y == 0) null else dropZoneAt(app, x, y);
                return;
            }
            if (st.selecting) |id| {
                const p = &(app.panes[id] orelse return);
                const r = app.layout.rectOf(id) orelse return;
                // Outside the pane the nearest cell counts, so dragging
                // past an edge selects to it.
                const cx = std.math.clamp(x, r.x, r.right() -| 1);
                const cy = std.math.clamp(y, r.y, r.bottom() -| 1);
                p.view.extendTo(editor_pane.offsetAt(p.view, r, app.config.line_numbers, cx, cy));
                p.reveal = true;
            }
        },
        .release => {
            if (st.drag) |d| {
                if (st.drop) |zone| {
                    if (d.from < app.docs.items.len) {
                        const dir: layout.Dir = if (zone.side == .left or zone.side == .right) .columns else .rows;
                        const first = zone.side == .left or zone.side == .top;
                        try app.splitPane(zone.pane, dir, first, app.docs.items[d.from]);
                    }
                } else {
                    app.moveTab(d.from, d.to);
                }
            }
            st.press_tab = null;
            st.drag = null;
            st.drop = null;
            st.selecting = null;
        },
    }
}

fn pressTabBar(app: *App, x: usize) !void {
    switch (app.tabbar.hit(x)) {
        .prev => app.tabbar.scrollBy(-1),
        .next => app.tabbar.scrollBy(1),
        .plus => _ = try app.addDoc(null, ""),
        .close => |i| try app.requestCloseTab(i),
        .tab => |i| {
            try app.focusDoc(i);
            app.mouse.press_tab = i;
            app.mouse.press_x = x;
            app.mouse.press_y = 0;
        },
        .none => {},
    }
}

fn pressBody(app: *App, m: event.Mouse) !void {
    const st = &app.mouse;
    const x: usize = m.x;
    const y: usize = m.y;

    // File tree: click a row to select it, click it again to open it.
    if (app.tree) |*t| {
        if (x < drawing.sidebarWidth(app) and y >= 1 and y + 1 < app.rows) {
            const index = t.scroll + (y - 1);
            if (index < t.count()) {
                const again = index == t.selected and app.tree_focus;
                t.selected = index;
                app.tree_focus = true;
                if (again) try app.openTreeSelection();
            }
            return;
        }
    }

    // Status line: the help hint at the right end toggles the panel.
    if (y + 1 == app.rows) {
        if (app.cols > 10 and x + 10 > app.cols) app.help = !app.help;
        return;
    }

    const id = app.layout.paneAt(x, y) orelse return;
    const r = app.layout.rectOf(id).?;
    app.focusPane(id);
    const p = app.pane();
    const pos = editor_pane.offsetAt(p.view, r, app.config.line_numbers, x, y);
    p.reveal = true;

    // The same cell again, soon enough, is a double click; once more a
    // triple. Anywhere else, or after a pause, starts over at one.
    const repeated = st.click_count > 0 and app.now_ms -% st.click_at_ms <= click_ms and
        x == st.click_x and y == st.click_y;
    st.click_count = if (!repeated or st.click_count >= 3) 1 else st.click_count + 1;
    st.click_at_ms = app.now_ms;
    st.click_x = x;
    st.click_y = y;

    if (m.mods.shift) {
        p.view.extendTo(pos);
    } else if (m.mods.ctrl or m.mods.alt) {
        try p.view.addCaret(pos);
    } else switch (st.click_count) {
        2 => p.view.selectWordAt(pos),
        3 => p.view.selectLineAt(pos),
        else => {
            p.view.setCaret(pos);
            st.selecting = id;
        },
    }
}
