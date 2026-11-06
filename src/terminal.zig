//! The embedded terminal: a pseudo terminal, a VT screen, and the small amount
//! of policy between them - spawn the shell, pump its output into the screen,
//! forward keys, and notice when it exits.

const std = @import("std");
const os = @import("os.zig");
const pty = @import("pty.zig");
const vterm = @import("vterm.zig");

/// Longest shell command line we accept from the config.
const MAX_COMMAND = 256;

/// Longest argv we build: a configured command split into words, or a shell
/// candidate plus its flags.
const MAX_ARGV = 8;

/// Re-exported so the editor can map terminal colours without importing the
/// VT module itself.
pub const Color = vterm.Color;

/// One shell to try when no `[terminal] command` is configured.
const ShellCandidate = struct {
    exe: []const u8,
    /// Extra arguments. `-NoLogo` only silences the copyright banner; the
    /// profile still loads because `-NoProfile` is deliberately never passed.
    args: []const []const u8 = &.{},
};

/// Windows shells, best first. PowerShell 7 (`pwsh.exe`) is the modern one and
/// gets the user's full profile; Windows PowerShell is next, then cmd.exe as
/// the always-present fallback. A candidate that cannot be created is skipped,
/// so a machine without PowerShell 7 still lands somewhere usable.
const windows_shells = [_]ShellCandidate{
    .{ .exe = "pwsh.exe", .args = &.{"-NoLogo"} },
    .{ .exe = "powershell.exe", .args = &.{"-NoLogo"} },
    .{ .exe = "cmd.exe" },
};

/// Unix fallback when `$SHELL` is unset (or cannot be started).
const unix_fallback = "/bin/sh";

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    child: pty.Pty,
    vt: vterm.Vt,
    /// Exit status once the shell is gone; null while it runs.
    exit_code: ?i32 = null,
    /// Title the shell set with OSC 0/2, shown in the panel border.
    title: [64]u8 = [_]u8{0} ** 64,
    title_len: usize = 0,
    /// Scrollback position in lines above the live screen (0 = live). Mirrors
    /// `vt.viewOffset()`; the renderer reads it to place the title and to keep
    /// the cursor on the live screen only.
    view: usize = 0,

    /// Start `command` (empty = the platform shell) in a pseudo terminal.
    ///
    /// The configured command is the only candidate: the user asked for that
    /// program, so a failure is reported instead of silently running something
    /// else. Without one, the platform list is tried in order and the first
    /// shell that actually spawns wins; if every candidate fails the last error
    /// is returned.
    pub fn spawn(allocator: std.mem.Allocator, command: ?[]const u8, cols: u16, rows: u16) !Terminal {
        // The screen is allocated before the child so a spawn failure leaves no
        // half-built terminal behind.
        var vt = try vterm.Vt.init(allocator, cols, rows);
        errdefer vt.deinit();
        const child = try spawnShellPty(allocator, command, cols, rows);
        return .{ .allocator = allocator, .child = child, .vt = vt };
    }

    pub fn deinit(self: *Terminal) void {
        self.child.deinit();
        self.vt.deinit();
    }

    /// Tell the shell and the screen about a new size. The screen is resized
    /// first so the next frame is never drawn at the old width. A resize
    /// re-lays-out the grid, so a parked scrollback view is dropped: its offset
    /// would point at different lines afterwards.
    pub fn resize(self: *Terminal, cols: u16, rows: u16) !void {
        try self.vt.resize(cols, rows);
        self.child.resize(cols, rows) catch {};
        self.vt.scrollToLive();
        self.view = 0;
    }

    /// Read whatever the shell has produced and feed it to the screen.
    /// Returns true when the screen changed, so the caller can repaint.
    pub fn pump(self: *Terminal) bool {
        if (self.exit_code != null) return false;
        var buf: [8192]u8 = undefined;
        var changed = false;
        var rounds: usize = 0;
        // The autoscroll policy needs to know what the reader was looking at
        // before the shell wrote anything.
        const sb_before = self.vt.scrollbackLen();
        const view_before = self.vt.viewOffset();
        // Bounded: a chatty program must not starve the editor's input.
        while (rounds < 16) : (rounds += 1) {
            const n = self.child.read(&buf) catch |e| switch (e) {
                error.EndOfStream => {
                    self.noteExit();
                    break;
                },
                else => break,
            };
            if (n == 0) break;
            changed = true;
            self.vt.feed(buf[0..n]);
            const reply = self.vt.takeReply();
            if (reply.len > 0) self.child.write(reply) catch {};
        }
        if (self.vt.title().len > 0) self.setTitle(self.vt.title());
        // Autoscroll: a reader parked in the history keeps the same lines under
        // their eyes (the offset moves with the lines that just scrolled off),
        // while a reader at the bottom simply follows the output. Anything that
        // resets the screen (RIS, `ED 3`, alt-screen) drops the offset, and the
        // mirror below picks that up.
        const added = self.vt.scrollbackLen() -| sb_before;
        if (view_before > 0 and added > 0) self.vt.setViewOffset(anchoredView(view_before, added));
        // The shell can drop the scrollback (`ED 3`) or reset the screen
        // (`RIS`); those park the view at live, so mirror it for the renderer.
        self.view = self.vt.viewOffset();
        // Windows keeps the output pipe open until the pseudo console is
        // closed, which only `exited()` does, so poll it even when read has not
        // reported EOF yet.
        self.noteExit();
        return changed;
    }

    /// Bytes from the keyboard go straight to the shell, with one translation:
    /// the console reports Backspace as 0x08 (Ctrl+H), but a terminal sends DEL
    /// (0x7f) and every line editor expects that. cmd.exe treats 0x08 as "clear
    /// the rest of the line", which is why one Backspace wiped a typed command.
    pub fn sendKeys(self: *Terminal, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (std.mem.indexOfScalar(u8, bytes, backspace_from_console)) |_| {
            var buf: [256]u8 = undefined;
            var off: usize = 0;
            while (off < bytes.len) {
                const n = @min(bytes.len - off, buf.len);
                const used = translateKeys(buf[0..n], bytes[off .. off + n]);
                self.child.write(buf[0..used]) catch {};
                off += used;
            }
        } else {
            self.child.write(bytes) catch {};
        }
        // Typing means "back to the live screen", like every other terminal.
        self.scrollToLive();
    }

    /// The system clipboard's text, clipped into `buf`, or null when there is
    /// none. This is what a right click pastes: mibi's own register only holds
    /// what was copied inside mibi, so a fresh editor would paste nothing.
    pub fn clipboardText(self: *Terminal, allocator: std.mem.Allocator, buf: []u8) ?[]const u8 {
        _ = self; // the clipboard is the platform's, not the terminal's
        return systemClipboardText(allocator, buf);
    }

    /// Paste the system clipboard into the shell, framed for bracketed paste
    /// when the shell asked for it. Returns false when the clipboard is empty
    /// or unavailable, so the caller can leave the status line alone.
    pub fn pasteClipboard(self: *Terminal, allocator: std.mem.Allocator, scratch: []u8) bool {
        const text = self.clipboardText(allocator, scratch) orelse return false;
        var framed: [4096]u8 = undefined;
        self.sendKeys(self.pasteBytes(text, &framed));
        return true;
    }

    pub fn outputHandle(self: *const Terminal) pty.Handle {
        return self.child.outputHandle();
    }

    pub fn alive(self: *const Terminal) bool {
        return self.exit_code == null;
    }

    /// Exit status, or null while the shell is still running.
    pub fn exited(self: *Terminal) ?i32 {
        if (self.exit_code) |code| return code;
        self.noteExit();
        return self.exit_code;
    }

    fn noteExit(self: *Terminal) void {
        if (self.exit_code != null) return;
        // `exited` is null while the shell still runs, so only a real exit is
        // recorded here.
        if (self.child.exited()) |code| self.exit_code = code;
    }

    pub fn kill(self: *Terminal) void {
        self.child.kill();
        self.noteExit();
    }

    pub fn titleText(self: *const Terminal) []const u8 {
        return self.title[0..self.title_len];
    }

    fn setTitle(self: *Terminal, text: []const u8) void {
        const n = @min(text.len, self.title.len);
        @memcpy(self.title[0..n], text[0..n]);
        self.title_len = n;
    }

    /// Scroll the scrollback view by `delta` lines, wheel style: negative goes
    /// back in time (wheel up / page up), positive returns toward the live
    /// screen. Clamped to the scrollback, so holding a key parks at one end.
    ///
    /// The offset is kept in `view` as well because the renderer reads it to
    /// decide whether the cursor is on the live screen.
    pub fn scroll(self: *Terminal, delta: isize) void {
        self.vt.scrollBy(delta);
        self.view = self.vt.viewOffset();
    }

    /// Jump back to the live screen (the shell prompt).
    pub fn scrollToLive(self: *Terminal) void {
        self.vt.scrollToLive();
        self.view = 0;
    }

    /// True when the panel shows the live screen rather than scrollback.
    pub fn atLive(self: *const Terminal) bool {
        return self.view == 0;
    }

    /// Lines of scrollback available above the live screen.
    pub fn scrollbackLen(self: *const Terminal) usize {
        return self.vt.scrollbackLen();
    }

    /// The live cursor; `visible` is the shell's last `?25` mode, so the
    /// renderer can draw a filled block when shown and a hollow one when the
    /// shell hid it (ConPTY/cmd hides the cursor on startup).
    pub fn cursor(self: *const Terminal) vterm.Cursor {
        return self.vt.cursor();
    }

    /// Whether the shell asked for bracketed paste (`?2004`). When it did, a
    /// paste must be framed so the shell does not run each pasted line.
    pub fn bracketedPaste(self: *const Terminal) bool {
        return self.vt.bracketedPaste();
    }

    /// Format a paste into `buf` and return the bytes to send: `text` framed in
    /// `ESC[200~`/`ESC[201~` when the shell enabled bracketed paste, the raw
    /// text otherwise. Allocation-free and clamped to `buf`.
    pub fn pasteBytes(self: *const Terminal, text: []const u8, buf: []u8) []const u8 {
        return framePaste(self.vt.bracketedPaste(), text, buf);
    }
};

/// What the console reports for the Backspace key (Ctrl+H), and what a terminal
/// has to send instead.
const backspace_from_console: u8 = 0x08;
const backspace_to_shell: u8 = 0x7f;

/// Copy `src` into `dst` mapping the console's Backspace to DEL. Returns the
/// number of bytes written (the caller hands the same length back).
fn translateKeys(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    for (src[0..n], 0..) |b, i| dst[i] = if (b == backspace_from_console) backspace_to_shell else b;
    return n;
}

/// Where the scrollback view should sit after `added` new lines landed while
/// the reader was `view` lines above the live screen: the same lines stay under
/// their eyes, so the offset grows with the scrollback. A reader at live (0)
/// stays at live and simply follows the output.
fn anchoredView(view: usize, added: usize) usize {
    if (view == 0 or added == 0) return view;
    return view + added;
}

const win = if (pty.is_windows) struct {
    extern "user32" fn OpenClipboard(hwnd: ?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn CloseClipboard() callconv(.winapi) i32;
    extern "user32" fn GetClipboardData(uFormat: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalLock(hMem: *anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalUnlock(hMem: *anyopaque) callconv(.winapi) i32;
    const CF_UNICODETEXT: u32 = 13;
} else struct {};

/// The system clipboard's text, clipped into `buf`, or null when the clipboard
/// is empty or unavailable. Free-standing so it can be called (and probed)
/// without a running shell.
pub fn systemClipboardText(allocator: std.mem.Allocator, buf: []u8) ?[]const u8 {
    if (buf.len == 0) return null;
    if (pty.is_windows) return clipboardWindows(buf);
    return clipboardUnix(allocator, buf);
}

/// The Windows clipboard as UTF-8. Every step can fail (another process may
/// hold the clipboard), and a failure is "no text", never an error the caller
/// has to handle.
fn clipboardWindows(buf: []u8) ?[]const u8 {
    if (win.OpenClipboard(null) == 0) return null;
    defer _ = win.CloseClipboard();
    const handle = win.GetClipboardData(win.CF_UNICODETEXT) orelse return null;
    const raw = win.GlobalLock(handle) orelse return null;
    defer _ = win.GlobalUnlock(handle);
    const units: [*]const u16 = @ptrCast(@alignCast(raw));
    var n: usize = 0;
    while (units[n] != 0) n += 1;
    return utf16ToUtf8(units[0..n], buf);
}

/// UTF-16 code units to UTF-8, clamped to `buf`. A clamp never splits a
/// codepoint, and a lone surrogate becomes U+FFFD instead of failing the paste.
fn utf16ToUtf8(src: []const u16, buf: []u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const cp: u21 = blk: {
            const u = src[i];
            if (u >= 0xD800 and u <= 0xDBFF and i + 1 < src.len and
                src[i + 1] >= 0xDC00 and src[i + 1] <= 0xDFFF)
            {
                const pair = [_]u16{ u, src[i + 1] };
                i += 2;
                break :blk std.unicode.utf16DecodeSurrogatePair(&pair) catch 0xFFFD;
            }
            i += 1;
            if (u >= 0xD800 and u <= 0xDFFF) break :blk 0xFFFD;
            break :blk @intCast(u);
        };
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch continue;
        if (out + n > buf.len) break; // keep the clamp on a codepoint boundary
        @memcpy(buf[out..][0..n], tmp[0..n]);
        out += n;
    }
    if (out == 0) return null;
    return buf[0..out];
}

/// The Unix clipboard, through whichever helper is installed. The commands are
/// tried in order and the first one that exits 0 with output wins; a missing
/// tool just falls through. `os.runCommand` already bounds the wait, so a
/// wedged helper cannot freeze the editor.
fn clipboardUnix(allocator: std.mem.Allocator, buf: []u8) ?[]const u8 {
    const commands = [_][]const []const u8{
        &.{ "wl-paste", "--no-newline" },
        &.{ "xclip", "-selection", "clipboard", "-o" },
        &.{"pbpaste"},
    };
    const data_dir = os.dataDirAlloc(allocator) catch null;
    defer if (data_dir) |d| allocator.free(d);
    const state_dir = data_dir orelse ".";
    for (commands) |argv| {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);
        const res = os.runCommand(allocator, state_dir, argv, "", &out, 800) catch continue;
        if (res.timed_out or res.exit_code != 0 or out.items.len == 0) continue;
        const n = @min(out.items.len, buf.len);
        @memcpy(buf[0..n], out.items[0..n]);
        return buf[0..n];
    }
    return null;
}

/// The pure half of `pasteBytes`, so the framing rules are testable without a
/// running shell. When the buffer cannot hold both markers, the raw text is the
/// only safe answer: half a marker would corrupt the shell's parser.
fn framePaste(enabled: bool, text: []const u8, buf: []u8) []const u8 {
    const start = "\x1b[200~";
    const end = "\x1b[201~";
    if (!enabled or buf.len < start.len + end.len) return buf[0..copyInto(buf, text)];
    var n = copyInto(buf, start);
    // Leave room for the closing marker: an unterminated paste would leave the
    // shell waiting for `ESC[201~` forever.
    n += copyInto(buf[n .. buf.len - end.len], text);
    n += copyInto(buf[n..], end);
    return buf[0..n];
}

/// Start the shell process: the configured command, or the first platform
/// candidate that spawns. The VT screen is the caller's, so a failed candidate
/// costs nothing but a retry.
fn spawnShellPty(allocator: std.mem.Allocator, command: ?[]const u8, cols: u16, rows: u16) !pty.Pty {
    if (command) |cmd| {
        if (cmd.len > 0) {
            var buf: [MAX_COMMAND]u8 = undefined;
            var argv_buf: [MAX_ARGV][]const u8 = undefined;
            const argv = splitArgs(cmd, &buf, &argv_buf);
            // A configured shell has no fallback: running a different program
            // than the one asked for would be worse than an error.
            return pty.Pty.spawn(allocator, argv, cols, rows);
        }
    }

    // The last error is what the caller reports when nothing starts, so keep
    // the most recent one rather than the first.
    var last: anyerror = error.SpawnFailed;
    if (pty.is_windows) {
        for (windows_shells) |candidate| {
            var argv_buf: [MAX_ARGV][]const u8 = undefined;
            argv_buf[0] = candidate.exe;
            for (candidate.args, 0..) |arg, i| argv_buf[i + 1] = arg;
            const argv = argv_buf[0 .. candidate.args.len + 1];
            if (pty.Pty.spawn(allocator, argv, cols, rows)) |child| {
                return child;
            } else |e| {
                last = e;
            }
        }
        return last;
    }

    // Unix: `$SHELL` first, then /bin/sh. A bogus `$SHELL` that forks but fails
    // in the child cannot be told apart here (execvp failure shows as exit 127),
    // but an unset or unspawnable one falls through to the fallback.
    var buf: [MAX_COMMAND]u8 = undefined;
    if (os.getEnvAlloc(allocator, "SHELL")) |value| {
        defer allocator.free(value);
        if (value.len > 0 and value.len <= buf.len) {
            @memcpy(buf[0..value.len], value);
            const argv = [_][]const u8{buf[0..value.len]};
            if (pty.Pty.spawn(allocator, &argv, cols, rows)) |child| {
                return child;
            } else |e| {
                last = e;
            }
        }
    } else |_| {}
    const argv = [_][]const u8{unix_fallback};
    if (pty.Pty.spawn(allocator, &argv, cols, rows)) |child| return child else |e| last = e;
    return last;
}

/// Copy `src` into `dst`, returning how many bytes were written. Clamping at
/// the destination is the whole point: paste buffers are caller-sized.
fn copyInto(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    if (n > 0) @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// Split a command line on whitespace. Quoting is not supported on purpose:
/// the terminal command is a program plus simple arguments, and the config
/// file is ours to keep simple.
fn splitArgs(cmd: []const u8, buf: *[MAX_COMMAND]u8, out: *[MAX_ARGV][]const u8) []const []const u8 {
    var count: usize = 0;
    var b: usize = 0;
    var i: usize = 0;
    while (i < cmd.len and count < out.len) {
        while (i < cmd.len and (cmd[i] == ' ' or cmd[i] == '\t')) i += 1;
        if (i >= cmd.len or b >= buf.len) break;
        const start = b;
        while (i < cmd.len and cmd[i] != ' ' and cmd[i] != '\t' and b < buf.len) : (i += 1) {
            buf[b] = cmd[i];
            b += 1;
        }
        out[count] = buf[start..b];
        count += 1;
    }
    return out[0..count];
}

// --- tests -----------------------------------------------------------------

test "pasteBytes frames bracketed pastes and clamps to the buffer" {
    var buf: [32]u8 = undefined;
    // Mode off: the text goes through untouched.
    try std.testing.expectEqualStrings("a\nb", framePaste(false, "a\nb", &buf));
    // Mode on: framed so the shell sees one paste, not two submitted lines.
    try std.testing.expectEqualStrings("\x1b[200~a\nb\x1b[201~", framePaste(true, "a\nb", &buf));

    // Too small for both markers: raw text beats half an escape sequence.
    var tiny: [3]u8 = undefined;
    try std.testing.expectEqualStrings("abc", framePaste(true, "abcdef", &tiny));
    // A buffer that fits the markers but not the text truncates the middle,
    // keeping the framing intact.
    var mid: [16]u8 = undefined;
    const cut = framePaste(true, "abcdefghijklmnop", &mid);
    try std.testing.expectEqual(@as(usize, 16), cut.len);
    try std.testing.expect(std.mem.startsWith(u8, cut, "\x1b[200~"));
    try std.testing.expect(std.mem.endsWith(u8, cut, "\x1b[201~"));
    // Raw text is clamped too.
    var small: [2]u8 = undefined;
    try std.testing.expectEqualStrings("ab", framePaste(false, "abcdef", &small));
}

test "keys forward untouched except the console's Backspace" {
    var buf: [16]u8 = undefined;
    // Backspace from the console becomes DEL, which is what shells expect.
    try std.testing.expectEqual(@as(usize, 1), translateKeys(&buf, "\x08"));
    try std.testing.expectEqual(@as(u8, 0x7f), buf[0]);
    // Everything else is byte-for-byte: DEL stays DEL, Ctrl+C stays Ctrl+C.
    try std.testing.expectEqual(@as(usize, 2), translateKeys(&buf, "\x7f\x03"));
    try std.testing.expectEqual(@as(u8, 0x7f), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x03), buf[1]);
    // A word with a Backspace in the middle keeps its other bytes.
    const used = translateKeys(&buf, "ab\x08c");
    try std.testing.expectEqual(@as(usize, 4), used);
    try std.testing.expectEqualSlices(u8, "ab\x7fc", buf[0..used]);
    // The destination clamps.
    var small: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), translateKeys(&small, "abc"));
}

test "autoscroll keeps a reader's place and follows at live" {
    // At live, new output keeps the view at live: the panel follows the shell.
    try std.testing.expectEqual(@as(usize, 0), anchoredView(0, 7));
    // Reading history: the offset moves with the lines that scrolled off, so
    // the same lines stay on screen.
    try std.testing.expectEqual(@as(usize, 5), anchoredView(3, 2));
    // No new lines: nothing moves.
    try std.testing.expectEqual(@as(usize, 3), anchoredView(3, 0));
}

test "utf16 clipboard text becomes utf8, clamped on codepoint boundaries" {
    var buf: [16]u8 = undefined;
    // Plain ASCII.
    try std.testing.expectEqualStrings("hello", utf16ToUtf8(&[_]u16{ 'h', 'e', 'l', 'l', 'o' }, &buf).?);
    // A non-BMP character (emoji) is a surrogate pair in UTF-16.
    const emoji = [_]u16{ 0xD83D, 0xDE00 };
    try std.testing.expectEqualStrings("\u{1F600}", utf16ToUtf8(&emoji, &buf).?);
    // A lone surrogate becomes the replacement character rather than failing.
    try std.testing.expectEqualStrings("\u{FFFD}", utf16ToUtf8(&[_]u16{0xD83D}, &buf).?);
    // Empty text is "no clipboard".
    try std.testing.expect(utf16ToUtf8(&[_]u16{}, &buf) == null);
    // A buffer that cannot hold a whole codepoint stops before it: two cells
    // for the emoji do not fit in three bytes.
    var tight: [3]u8 = undefined;
    try std.testing.expect(utf16ToUtf8(&emoji, &tight) == null);
    // ... but the ASCII before it is kept.
    const mixed = [_]u16{ 'a', 'b', 0xD83D, 0xDE00 };
    try std.testing.expectEqualStrings("ab", utf16ToUtf8(&mixed, &tight).?);
}

test "resize honours a grid smaller than the panel and keeps the scrollback" {
    var vt = try vterm.Vt.init(std.testing.allocator, 40, 10);
    defer vt.deinit();
    // Push more lines than fit, so there is scrollback to preserve.
    var i: usize = 0;
    while (i < 20) : (i += 1) vt.feed("line\r\n");
    try std.testing.expect(vt.scrollbackLen() > 0);
    const before = vt.scrollbackLen();
    // The panel passes the inner size, which is smaller than the panel itself.
    try vt.resize(30, 8);
    try std.testing.expectEqual(@as(u16, 30), vt.cols());
    try std.testing.expectEqual(@as(u16, 8), vt.rows());
    // The cursor stays inside the new grid and the history survives.
    const cur = vt.cursor();
    try std.testing.expect(cur.x < vt.cols());
    try std.testing.expect(cur.y < vt.rows());
    try std.testing.expect(vt.scrollbackLen() >= before);
}

test "resize survives a tiny inner size" {
    var vt = try vterm.Vt.init(std.testing.allocator, 40, 10);
    defer vt.deinit();
    vt.feed("hello world\r\nsecond line\r\n");
    // The panel can be squeezed very small; the grid must stay valid and the
    // cursor inside it, or the renderer would read out of bounds.
    for ([_]struct { c: u16, r: u16 }{
        .{ .c = 20, .r = 3 },
        .{ .c = 1, .r = 1 },
        .{ .c = 2, .r = 2 },
        .{ .c = 80, .r = 12 },
    }) |size| {
        try vt.resize(size.c, size.r);
        try std.testing.expectEqual(size.c, vt.cols());
        try std.testing.expectEqual(size.r, vt.rows());
        const cur = vt.cursor();
        try std.testing.expect(cur.x < vt.cols());
        try std.testing.expect(cur.y < vt.rows());
        // Every visible row is exactly `cols` cells: the renderer indexes them.
        var row: u16 = 0;
        while (row < vt.rows()) : (row += 1) {
            try std.testing.expectEqual(@as(usize, vt.cols()), vt.line(row).len);
        }
    }
}
