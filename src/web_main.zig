//! The browser entry point: the same editor as `src/main.zig`, with the loop
//! turned inside out. Native blocks in `poll`; a page cannot, so the host
//! calls in with each event (`mibi_input`, `mibi_resize`, `mibi_tick`) and
//! writes the frame that comes back to xterm.js. The platform under it is
//! `platform/web.zig`, an in-memory filesystem and three host calls.
//!
//! The ABI is plain numbers. Strings and bytes go in through memory the host
//! takes with `mibi_alloc`; anything variable-length comes back through one
//! result buffer (`mibi_result_ptr`), valid until the next call that fills it.
//! `web/host.js` is the only caller and wraps every export.

const std = @import("std");
const ui = @import("ui");
const platform = @import("platform");
const os = platform.os;
const vfs_mod = os.vfs_mod;
const heap = platform.heap;
const ansi = platform.ansi;
const app_mod = @import("app.zig");
const doc_mod = @import("app/doc.zig");
const config_mod = @import("config.zig");
const langs = @import("langs.zig");
const session = app_mod.session;
const screen = ui.screen;
const App = app_mod.App;

const allocator = heap.allocator;

/// As in `src/main.zig`: the session autosave cadence and the most events
/// handled before a frame is drawn.
const autosave_ms = 2000;
const burst = 512;

/// What `term.enterScreen` turns on (without the kitty keyboard protocol,
/// which xterm.js does not speak), and what `term.restore` turns off.
const screen_on = "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[?2004h";
const screen_off = "\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1002l\x1b[?7h\x1b[0m\x1b[?25h\x1b[?1049l";

const State = struct {
    app: App,
    screen: screen.Screen,
    decoder: ansi.Decoder,
    last_save: u64,
    first_frame: bool = true,
    stopped: bool = false,
};

var state: ?State = null;
var frame: std.ArrayList(u8) = .empty;
var result: std.ArrayList(u8) = .empty;

/// The running editor, or null before `mibi_init` and after `mibi_shutdown`.
fn live() ?*State {
    const s = if (state) |*s| s else return null;
    return if (s.stopped) null else s;
}

fn drawFrame(s: *State) void {
    frame.clearRetainingCapacity();
    if (s.first_frame) {
        frame.appendSlice(allocator, screen_on) catch return;
        s.first_frame = false;
    }
    s.app.draw(&s.screen);
    // A frame that cannot be built (out of memory) is skipped; the next one
    // repaints everything.
    s.screen.diff(&frame) catch {
        s.screen.invalidate();
        return;
    };
    frame.appendSlice(allocator, s.app.term_out.items) catch {};
    s.app.term_out.clearRetainingCapacity();
}

fn drain(s: *State, flush: bool) void {
    s.app.now_ms = os.ticksMs();
    var handled: usize = 0;
    while (s.decoder.next(flush)) |ev| {
        switch (ev) {
            // As native: repaint every row when the page comes back.
            .focus => |gained| if (gained) s.screen.invalidate(),
            else => {},
        }
        s.app.handle(ev);
        handled += 1;
        if (s.app.quit or handled >= burst) break;
    }
}

fn str(ptr: [*]const u8, len: usize) []const u8 {
    return ptr[0..len];
}

fn report(s: *State, err: anyerror) void {
    s.app.setMessage("{s}", .{app_mod.describe(err)});
}

// --- lifecycle ---------------------------------------------------------------

/// Start the editor on a `cols` x `rows` terminal. Seed the filesystem first:
/// the config, languages and session are read here. 0 on success.
export fn mibi_init(cols: u32, rows: u32) u32 {
    if (state != null) return 0;
    const exe_dir = os.exeDirAlloc(allocator) catch null;
    const state_dir = os.dataDirAlloc(allocator) catch null;
    var app = App.init(allocator, .{
        .config = config_mod.load(allocator, exe_dir),
        .exe_dir = exe_dir,
        .state_dir = state_dir,
    });
    _ = langs.loadDir(&app.registry, "/syntax.d");
    if (!session.load(&app)) {
        // A first visit opens the welcome file, if the host left one.
        var opened = false;
        if (os.vfs().get("/welcome.txt") != null) {
            if (app.openPath("/welcome.txt")) |_| opened = true else |_| {}
        }
        if (!opened) _ = app.addDoc(null, "") catch {
            app.deinit();
            return 1;
        };
    }
    if (app.config.theme_missing) app.setMessage("theme \"{s}\" not found", .{app.config.themeName()});
    const scr = screen.Screen.init(allocator, @max(cols, 2), @max(rows, 2)) catch {
        app.deinit();
        return 1;
    };
    app.now_ms = os.ticksMs();
    state = .{
        .app = app,
        .screen = scr,
        .decoder = ansi.Decoder.init(allocator),
        .last_save = app.now_ms,
    };
    drawFrame(&state.?);
    return 0;
}

/// Terminal bytes, as xterm.js `onData` gives them.
export fn mibi_input(ptr: [*]const u8, len: usize) void {
    const s = live() orelse return;
    s.decoder.feed(str(ptr, len)) catch return;
    drain(s, false);
    drawFrame(s);
}

/// The terminal was quiet: a lone ESC, or the start of a sequence that never
/// finished, is a key after all. The host calls this 30 ms after input that
/// left `mibi_pending` set, like the native escape wait.
export fn mibi_flush() void {
    const s = live() orelse return;
    drain(s, true);
    drawFrame(s);
}

export fn mibi_pending() u32 {
    const s = live() orelse return 0;
    return @intFromBool(s.decoder.pending());
}

export fn mibi_resize(cols: u32, rows: u32) void {
    const s = live() orelse return;
    s.screen.resize(@max(cols, 2), @max(rows, 2)) catch return;
    s.screen.invalidate();
    s.app.handle(.resize);
    drawFrame(s);
}

/// Idle: follow files changed underneath the editor, and save the session on
/// the native cadence. Leaves an empty frame when nothing changed on screen.
export fn mibi_tick() void {
    const s = live() orelse return;
    frame.clearRetainingCapacity();
    s.app.now_ms = os.ticksMs();
    if (s.app.tick()) drawFrame(s);
    if (s.app.session_dirty and s.app.now_ms -% s.last_save >= autosave_ms) {
        session.save(&s.app);
        s.last_save = s.app.now_ms;
    }
}

/// The theme's background as 0xRRGGBB, or -1 when the theme leaves it to
/// the terminal. The page paints the strips around the cell grid with it, so
/// a theme change does not leave a band of the old colour at the edges.
export fn mibi_background() i32 {
    const s = live() orelse return -1;
    return switch (s.app.config.theme.background) {
        .rgb => |c| @as(i32, c.r) << 16 | @as(i32, c.g) << 8 | c.b,
        else => -1,
    };
}

/// Save the session now, not at the next autosave: the page is being hidden
/// or closed, and storage gets one chance.
export fn mibi_checkpoint() void {
    const s = live() orelse return;
    if (!s.app.session_dirty) return;
    session.save(&s.app);
    s.last_save = os.ticksMs();
}

/// 1 once a command has asked to quit.
export fn mibi_quit() u32 {
    const s = live() orelse return 0;
    return @intFromBool(s.app.quit);
}

/// Save the session and leave the frame that hands the terminal back. Safe to
/// call more than once; the editor takes no more input after it.
export fn mibi_shutdown() void {
    const s = live() orelse return;
    session.save(&s.app);
    frame.clearRetainingCapacity();
    frame.appendSlice(allocator, screen_off) catch {};
    s.stopped = true;
}

// --- buffers -----------------------------------------------------------------

export fn mibi_alloc(len: usize) ?[*]u8 {
    const buf = allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn mibi_free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

export fn mibi_frame_ptr() [*]const u8 {
    return frame.items.ptr;
}

export fn mibi_frame_len() usize {
    return frame.items.len;
}

export fn mibi_result_ptr() [*]const u8 {
    return result.items.ptr;
}

fn setResult(bytes: []const u8) i32 {
    result.clearRetainingCapacity();
    result.appendSlice(allocator, bytes) catch return -1;
    return @intCast(bytes.len);
}

// --- the filesystem, from the host's side ------------------------------------

/// Create or replace a file the host brings in (an asset, an import, a file
/// from a real folder). Not recorded for write-back. 0 on success.
export fn mibi_vfs_put(path_ptr: [*]const u8, path_len: usize, data_ptr: [*]const u8, data_len: usize) u32 {
    os.vfs().put(str(path_ptr, path_len), str(data_ptr, data_len), .host) catch return 1;
    return 0;
}

/// A file deleted from the real folder.
export fn mibi_vfs_remove(path_ptr: [*]const u8, path_len: usize) void {
    _ = os.vfs().remove(str(path_ptr, path_len), .host) catch {};
}

/// A directory deleted from the real folder, with everything under it.
export fn mibi_vfs_remove_tree(path_ptr: [*]const u8, path_len: usize) void {
    os.vfs().removeTree(str(path_ptr, path_len));
}

/// The file's bytes into the result buffer, or -1 when there is no file.
export fn mibi_vfs_read(path_ptr: [*]const u8, path_len: usize) i32 {
    const data = os.vfs().get(str(path_ptr, path_len)) orelse return -1;
    return setResult(data);
}

/// Record the editor's workspace writes for a real folder (1), or stop (0).
export fn mibi_vfs_track(on: u32) void {
    os.vfs().setTracking(on != 0);
}

/// The workspace paths the editor wrote or deleted since the last call,
/// newline-separated, into the result buffer. They are forgotten here; put
/// back a path that could not be written with `mibi_vfs_mark_changed`.
export fn mibi_vfs_take_changed() i32 {
    result.clearRetainingCapacity();
    os.vfs().takeChanged(&result) catch return -1;
    return @intCast(result.items.len);
}

export fn mibi_vfs_mark_changed(path_ptr: [*]const u8, path_len: usize) void {
    os.vfs().markChanged(str(path_ptr, path_len)) catch {};
}

/// The persisted files into the result buffer: everything (1), or only what
/// is not under `/workspace` (0), for when a real folder holds the workspace.
export fn mibi_vfs_serialize(include_workspace: u32) i32 {
    result.clearRetainingCapacity();
    os.vfs().serialize(&result, include_workspace != 0) catch return -1;
    return @intCast(result.items.len);
}

/// Load a blob from `mibi_vfs_serialize`. A damaged one changes nothing.
export fn mibi_vfs_deserialize(ptr: [*]const u8, len: usize) u32 {
    os.vfs().deserialize(str(ptr, len)) catch return 1;
    return 0;
}

/// 1 when something worth persisting changed since `mibi_vfs_clean`.
export fn mibi_vfs_dirty() u32 {
    return @intFromBool(os.vfs().dirty);
}

export fn mibi_vfs_clean() void {
    os.vfs().markClean();
}

// --- the editor, from the host's side ----------------------------------------

/// Open a file as a tab, or switch to it. 0 on success.
export fn mibi_open(path_ptr: [*]const u8, path_len: usize) u32 {
    const s = live() orelse return 1;
    s.app.openPath(str(path_ptr, path_len)) catch |err| {
        report(s, err);
        drawFrame(s);
        return 1;
    };
    drawFrame(s);
    return 0;
}

/// Run a command by its name in the command table. The toolbar uses this for
/// the keys a browser keeps for itself. 0 on success, 2 for an unknown name.
export fn mibi_command(name_ptr: [*]const u8, name_len: usize) u32 {
    const s = live() orelse return 1;
    const command = app_mod.Command.fromName(str(name_ptr, name_len)) orelse return 2;
    s.app.run(command, false) catch |err| report(s, err);
    drawFrame(s);
    return 0;
}

/// A line for the status bar from the host: a folder that went away, a
/// storage error.
export fn mibi_notify(ptr: [*]const u8, len: usize) void {
    const s = live() orelse return;
    s.app.setMessage("{s}", .{str(ptr, len)});
    drawFrame(s);
}

/// The host did not write a save back to the real folder, because the file
/// changed there after the editor last read it; it has put the folder's
/// version into the filesystem instead. Every tab on that path goes back to
/// unsaved, so nothing is lost and the next save is a deliberate overwrite.
/// Returns how many tabs that was.
export fn mibi_conflict(path_ptr: [*]const u8, path_len: usize) u32 {
    const s = live() orelse return 0;
    var want_buf: [vfs_mod.max_path]u8 = undefined;
    const want = vfs_mod.canonical(str(path_ptr, path_len), &want_buf) orelse return 0;
    var n: u32 = 0;
    for (s.app.docs.items) |d| {
        const p = d.path orelse continue;
        var buf: [vfs_mod.max_path]u8 = undefined;
        const have = vfs_mod.canonical(p, &buf) orelse continue;
        if (!std.mem.eql(u8, have, want)) continue;
        d.document.markUnsaved();
        // The folder's version is the one on disk now; it is not news to
        // report again as a change from outside.
        d.stamp = os.fileStamp(p);
        s.app.setMessage("{s} changed on disk since it was read; kept yours unsaved, save again to overwrite", .{d.name()});
        s.app.session_dirty = true;
        n += 1;
    }
    drawFrame(s);
    return n;
}

/// The focused tab's text as it goes to disk (its own line endings), into
/// the result buffer.
export fn mibi_current_bytes() i32 {
    const s = live() orelse return -1;
    const d = focusedDoc(s) orelse return -1;
    const bytes = d.bytesForDisk(allocator) catch return -1;
    defer allocator.free(bytes);
    return setResult(bytes);
}

/// The focused tab's file name, into the result buffer ("" when untitled).
export fn mibi_current_name() i32 {
    const s = live() orelse return -1;
    const d = focusedDoc(s) orelse return -1;
    return setResult(if (d.path) |p| doc_mod.baseName(p) else "");
}

fn focusedDoc(s: *State) ?*app_mod.Doc {
    const id = s.app.layout.focused() orelse return null;
    const pane = s.app.panes[id] orelse return null;
    return pane.doc;
}
