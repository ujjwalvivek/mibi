//! The browser entry point. This is the same editor as `src/main.zig`, with
//! the terminal replaced by an xterm.js host: the host feeds bytes in through
//! `mibi_input`, reads the ANSI frame back out, and calls `mibi_tick` when
//! nothing is happening. The platform layer under it is `platform/web.zig`,
//! a virtual filesystem and a handful of host calls.
//!
//! Nothing here is browser-specific except the exported ABI. The app, the
//! widgets and the text model are the native ones.

const std = @import("std");
const core = @import("core");
const ui = @import("ui");
const platform = @import("platform");
const os = platform.os;
const heap = platform.heap;
const ansi = platform.ansi;
const app_mod = @import("app.zig");
const config_mod = @import("config.zig");
const langs = @import("langs.zig");
const session = app_mod.session;
const screen = ui.screen;
const Event = ui.event.Event;
const App = app_mod.App;

const allocator = heap.allocator;

/// What the host has to turn on before the first frame, exactly as
/// `term.enterScreen` does on a real terminal.
const screen_on = "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[?2004h";
const screen_off = "\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1002l\x1b[?7h\x1b[0m\x1b[?25h\x1b[?1049l";

var app: App = undefined;
var screen_state: screen.Screen = undefined;
var decoder: ansi.Decoder = undefined;
var out: std.ArrayList(u8) = .empty;
var serialized: std.ArrayList(u8) = .empty;
var current: std.ArrayList(u8) = .empty;
var initialized = false;
var stopped = false;
var first_frame = true;
var exe_dir: ?[]const u8 = null;
var state_dir: ?[]const u8 = null;
var last_save: u64 = 0;

fn drawFrame() void {
    if (!initialized) return;
    out.clearRetainingCapacity();
    if (first_frame) {
        out.appendSlice(allocator, screen_on) catch {};
        first_frame = false;
    }
    app.draw(&screen_state);
    screen_state.diff(&out) catch {
        screen_state.invalidate();
        return;
    };
    out.appendSlice(allocator, app.term_out.items) catch {};
    app.term_out.clearRetainingCapacity();
}

fn handle(ev: Event) void {
    app.handle(ev);
}

fn drain(flush: bool) void {
    app.now_ms = os.ticksMs();
    var handled: usize = 0;
    while (decoder.next(flush)) |ev| {
        handle(ev);
        handled += 1;
        if (app.quit or handled >= 512) break;
    }
}

fn focusedDoc() ?*app_mod.Doc {
    const id = app.layout.focused() orelse return null;
    const pane = app.panes[id] orelse return null;
    return pane.doc;
}

// --- lifecycle ---------------------------------------------------------------

/// Start the editor. `cols` and `rows` are the terminal's size in cells.
/// Returns 0 on success, 1 when the editor could not start.
export fn mibi_init(cols: u32, rows: u32) u32 {
    if (initialized) return 0;
    exe_dir = os.exeDirAlloc(allocator) catch null;
    state_dir = os.dataDirAlloc(allocator) catch null;
    app = App.init(allocator, .{
        .config = config_mod.load(allocator, exe_dir),
        .exe_dir = exe_dir,
        .state_dir = state_dir,
    });
    _ = langs.loadDir(&app.registry, "/syntax.d");
    const restored = session.load(&app);
    if (!restored) {
        // A first visit opens the welcome file; otherwise a blank buffer.
        if (os.hasFile("/workspace/welcome.txt")) {
            app.openPath("/workspace/welcome.txt") catch {
                _ = app.addDoc(null, "") catch return 1;
            };
        } else {
            _ = app.addDoc(null, "") catch return 1;
        }
    }
    if (app.config.theme_missing) app.setMessage("theme \"{s}\" not found", .{app.config.themeName()});
    screen_state = screen.Screen.init(allocator, @max(cols, 2), @max(rows, 2)) catch return 1;
    decoder = ansi.Decoder.init(allocator);
    out = .empty;
    serialized = .empty;
    current = .empty;
    initialized = true;
    stopped = false;
    first_frame = true;
    app.now_ms = os.ticksMs();
    last_save = app.now_ms;
    drawFrame();
    return 0;
}

/// Feed terminal bytes (what xterm.js `onData` gives us).
export fn mibi_input(ptr: [*]const u8, len: usize) void {
    if (!initialized or stopped) return;
    decoder.feed(ptr[0..len]) catch return;
    drain(false);
    drawFrame();
}

/// The terminal was quiet: a lone ESC (or the tail of a sequence) is complete.
export fn mibi_flush() void {
    if (!initialized or stopped) return;
    drain(true);
    drawFrame();
}

/// True when the decoder is holding bytes that need more input or a flush.
export fn mibi_pending() u32 {
    if (!initialized or stopped) return 0;
    return if (decoder.pending()) 1 else 0;
}

/// The host resized the terminal.
export fn mibi_resize(cols: u32, rows: u32) void {
    if (!initialized or stopped) return;
    screen_state.resize(@max(cols, 2), @max(rows, 2)) catch return;
    screen_state.invalidate();
    app.handle(.resize);
    drawFrame();
}

/// An idle tick: follow files changed on disk, and save the session on the
/// same two-second cadence as the native loop.
export fn mibi_tick() void {
    if (!initialized or stopped) return;
    app.now_ms = os.ticksMs();
    if (app.tick()) drawFrame();
    if (app.session_dirty and app.now_ms -% last_save >= 2000) {
        session.save(&app);
        last_save = app.now_ms;
    }
}

/// True after Ctrl+Q (or another command that quits).
export fn mibi_quit() u32 {
    return if (app.quit) 1 else 0;
}

/// Save the session and write the sequences that put the terminal back.
/// The host should write the current frame before dropping the instance.
export fn mibi_shutdown() void {
    if (!initialized or stopped) return;
    session.save(&app);
    out.clearRetainingCapacity();
    out.appendSlice(allocator, screen_off) catch {};
    stopped = true;
}

/// Free everything. Call after `mibi_shutdown`, once the final frame is shown.
export fn mibi_deinit() void {
    if (initialized) {
        app.deinit();
        screen_state.deinit();
        decoder.deinit();
    }
    out.deinit(allocator);
    serialized.deinit(allocator);
    current.deinit(allocator);
    if (exe_dir) |d| allocator.free(d);
    if (state_dir) |d| allocator.free(d);
    exe_dir = null;
    state_dir = null;
    initialized = false;
}

// --- frame -------------------------------------------------------------------

export fn mibi_frame_ptr() [*]const u8 {
    return out.items.ptr;
}

export fn mibi_frame_len() usize {
    return out.items.len;
}

// --- host memory -------------------------------------------------------------

export fn mibi_alloc(len: usize) ?[*]u8 {
    const buf = allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn mibi_free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

// --- files -------------------------------------------------------------------

/// Put a file into the virtual filesystem. The host calls this to seed
/// `syntax.d`, `themes` and imported files.
export fn mibi_vfs_put(path_ptr: [*]const u8, path_len: usize, data_ptr: [*]const u8, data_len: usize) u32 {
    os.putFile(path_ptr[0..path_len], data_ptr[0..data_len]) catch return 1;
    return 0;
}

export fn mibi_vfs_has(path_ptr: [*]const u8, path_len: usize) u32 {
    return if (os.hasFile(path_ptr[0..path_len])) 1 else 0;
}

/// Serialise the workspace and session. The host reads `serialized_ptr` and
/// `serialized_len`, then calls `mibi_vfs_clean`.
export fn mibi_vfs_serialize() usize {
    serialized.clearRetainingCapacity();
    os.serialize(&serialized, true) catch return 0;
    return serialized.items.len;
}

/// Serialise only `/state` (the session and unsaved buffers). With a real
/// folder, the workspace is already on disk and does not belong in local
/// storage.
export fn mibi_vfs_serialize_state() usize {
    serialized.clearRetainingCapacity();
    os.serialize(&serialized, false) catch return 0;
    return serialized.items.len;
}

/// A file's bytes, for writing back to a real folder. Check
/// `mibi_vfs_has` first; an empty file is valid.
export fn mibi_vfs_file_len(path_ptr: [*]const u8, path_len: usize) usize {
    const f = os.getFile(path_ptr[0..path_len]) orelse return 0;
    return f.len;
}

export fn mibi_vfs_file_ptr(path_ptr: [*]const u8, path_len: usize) [*]const u8 {
    const f = os.getFile(path_ptr[0..path_len]) orelse return empty[0..].ptr;
    return f.ptr;
}

/// How many workspace files changed since the last clear.
export fn mibi_vfs_changed_count() usize {
    return os.changedCount();
}

export fn mibi_vfs_changed_path_len(index: usize) usize {
    const path = os.changedPathAt(index) orelse return 0;
    return path.len;
}

export fn mibi_vfs_changed_path_ptr(index: usize) [*]const u8 {
    const path = os.changedPathAt(index) orelse return empty[0..].ptr;
    return path.ptr;
}

export fn mibi_vfs_clear_changed() void {
    os.clearChanged();
}

export fn mibi_vfs_serialized_ptr() [*]const u8 {
    return serialized.items.ptr;
}

export fn mibi_vfs_deserialize(ptr: [*]const u8, len: usize) u32 {
    os.deserialize(ptr[0..len]) catch return 1;
    return 0;
}

export fn mibi_vfs_dirty() u32 {
    return if (os.isDirty()) 1 else 0;
}

export fn mibi_vfs_clean() void {
    os.markClean();
}

/// Open a file from the virtual filesystem.
export fn mibi_open(path_ptr: [*]const u8, path_len: usize) u32 {
    if (!initialized or stopped) return 1;
    app.openPath(path_ptr[0..path_len]) catch return 1;
    drawFrame();
    return 0;
}

/// A new, empty tab.
export fn mibi_new() u32 {
    if (!initialized or stopped) return 1;
    _ = app.addDoc(null, "") catch return 1;
    drawFrame();
    return 0;
}

/// Close the focused tab. Unsaved changes still ask, as on native.
export fn mibi_close_tab() void {
    if (!initialized or stopped) return;
    app.run(.close_tab, false) catch |err| app.setMessage("{s}", .{app_mod.describe(err)});
    drawFrame();
}

/// Run a command by its name from the command table. The web toolbar uses
/// this for keys the browser reserves (Ctrl+W/T/N/R, F5, F6, F7, ...).
export fn mibi_command(name_ptr: [*]const u8, name_len: usize) u32 {
    if (!initialized or stopped) return 1;
    const command = app_mod.Command.fromName(name_ptr[0..name_len]) orelse return 2;
    app.run(command, false) catch |err| app.setMessage("{s}", .{app_mod.describe(err)});
    drawFrame();
    return 0;
}

/// Save the focused document. Errors become a status message, as on native.
export fn mibi_save() void {
    if (!initialized or stopped) return;
    app.run(.save, false) catch |err| app.setMessage("{s}", .{app_mod.describe(err)});
    drawFrame();
}

/// The focused document's text, with its file's line endings, for download.
export fn mibi_current_bytes() usize {
    current.clearRetainingCapacity();
    const doc = focusedDoc() orelse return 0;
    const bytes = doc.bytesForDisk(allocator) catch return 0;
    defer allocator.free(bytes);
    current.appendSlice(allocator, bytes) catch return 0;
    return current.items.len;
}

export fn mibi_current_ptr() [*]const u8 {
    return current.items.ptr;
}

export fn mibi_current_path_len() usize {
    const doc = focusedDoc() orelse return 0;
    return if (doc.path) |p| p.len else 0;
}

export fn mibi_current_path_ptr() [*]const u8 {
    const doc = focusedDoc() orelse return empty[0..].ptr;
    return if (doc.path) |p| p.ptr else empty[0..].ptr;
}

export fn mibi_current_name_len() usize {
    const doc = focusedDoc() orelse return 0;
    return doc.name().len;
}

export fn mibi_current_name_ptr() [*]const u8 {
    const doc = focusedDoc() orelse return empty[0..].ptr;
    return doc.name().ptr;
}

const empty: [0]u8 = .{};
