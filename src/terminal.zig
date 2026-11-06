//! The embedded terminal: a pseudo terminal, a VT screen, and the small amount
//! of policy between them - spawn the shell, pump its output into the screen,
//! forward keys, and notice when it exits.

const std = @import("std");
const os = @import("os.zig");
const pty = @import("pty.zig");
const vterm = @import("vterm.zig");

/// Longest shell command line we accept from the config.
const MAX_COMMAND = 256;

/// Re-exported so the editor can map terminal colours without importing the
/// VT module itself.
pub const Color = vterm.Color;

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    child: pty.Pty,
    vt: vterm.Vt,
    /// Exit status once the shell is gone; null while it runs.
    exit_code: ?i32 = null,
    /// Title the shell set with OSC 0/2, shown in the panel border.
    title: [64]u8 = [_]u8{0} ** 64,
    title_len: usize = 0,
    /// Scrollback position in lines from the live screen (0 = live).
    view: usize = 0,

    /// Start `command` (empty = the platform shell) in a pseudo terminal.
    pub fn spawn(allocator: std.mem.Allocator, command: ?[]const u8, cols: u16, rows: u16) !Terminal {
        var buf: [MAX_COMMAND]u8 = undefined;
        var argv_buf: [8][]const u8 = undefined;
        const argv = try shellArgv(allocator, command, &buf, &argv_buf);
        var vt = try vterm.Vt.init(allocator, cols, rows);
        errdefer vt.deinit();
        const child = try pty.Pty.spawn(allocator, argv, cols, rows);
        return .{ .allocator = allocator, .child = child, .vt = vt };
    }

    pub fn deinit(self: *Terminal) void {
        self.child.deinit();
        self.vt.deinit();
    }

    /// Tell the shell and the screen about a new size. The screen is resized
    /// first so the next frame is never drawn at the old width.
    pub fn resize(self: *Terminal, cols: u16, rows: u16) !void {
        try self.vt.resize(cols, rows);
        self.child.resize(cols, rows) catch {};
        self.view = 0;
    }

    /// Read whatever the shell has produced and feed it to the screen.
    /// Returns true when the screen changed, so the caller can repaint.
    pub fn pump(self: *Terminal) bool {
        if (self.exit_code != null) return false;
        var buf: [8192]u8 = undefined;
        var changed = false;
        var rounds: usize = 0;
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
        // Windows keeps the output pipe open until the pseudo console is
        // closed, which only `exited()` does, so poll it even when read has not
        // reported EOF yet.
        self.noteExit();
        return changed;
    }

    /// Bytes from the keyboard go straight to the shell: the input layer has
    /// already turned them into the same escape sequences a terminal sends.
    pub fn sendKeys(self: *Terminal, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.child.write(bytes) catch {};
        // Typing means "back to the live screen", like every other terminal.
        if (self.view != 0) {
            self.view = 0;
            self.vt.setViewOffset(0);
        }
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

    /// Scroll the scrollback view by `delta` lines (negative = back in time).
    pub fn scroll(self: *Terminal, delta: isize) void {
        const total = self.vt.scrollbackLen();
        const cur: isize = @intCast(self.view);
        var want = cur + delta;
        if (want < 0) want = 0;
        if (want > @as(isize, @intCast(total))) want = @intCast(total);
        self.view = @intCast(want);
        self.vt.setViewOffset(self.view);
    }
};

/// The shell to run: the configured command split on spaces, or the platform
/// default. `buf` holds the bytes the slices point into.
fn shellArgv(
    allocator: std.mem.Allocator,
    command: ?[]const u8,
    buf: *[MAX_COMMAND]u8,
    out: *[8][]const u8,
) ![]const []const u8 {
    if (command) |cmd| {
        if (cmd.len > 0) return splitArgs(cmd, buf, out);
    }
    // COMSPEC on Windows, $SHELL elsewhere, with a plain fallback each.
    const env_name = if (pty.is_windows) "COMSPEC" else "SHELL";
    if (os.getEnvAlloc(allocator, env_name)) |value| {
        defer allocator.free(value);
        if (value.len > 0 and value.len <= buf.len) {
            @memcpy(buf[0..value.len], value);
            out[0] = buf[0..value.len];
            return out[0..1];
        }
    } else |_| {}
    const fallback = if (pty.is_windows) "cmd.exe" else "/bin/sh";
    @memcpy(buf[0..fallback.len], fallback);
    out[0] = buf[0..fallback.len];
    return out[0..1];
}

/// Split a command line on whitespace. Quoting is not supported on purpose:
/// the terminal command is a program plus simple arguments, and the config
/// file is ours to keep simple.
fn splitArgs(cmd: []const u8, buf: *[MAX_COMMAND]u8, out: *[8][]const u8) []const []const u8 {
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
