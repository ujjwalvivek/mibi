//! The terminal: raw mode, the alternate screen, its size, and input as
//! typed events.
//!
//! Unix terminals send bytes, which `ansi.Decoder` turns into events. The
//! Windows console sends INPUT_RECORDs, which `win_input.Translator` turns
//! into the same events; reading the console as a byte stream is unreliable
//! there. Output is ANSI on both: Windows gets virtual-terminal processing
//! switched on. Everything above this file sees `Event`s and cells only.

const std = @import("std");
const builtin = @import("builtin");
const os = @import("os.zig");
const ansi = @import("ansi.zig");
const win_input = @import("win_input.zig");
const event = @import("ui").event;
const Event = event.Event;

const is_windows = builtin.os.tag == .windows;

pub const Size = struct { rows: u16, cols: u16 };

/// How long a lone ESC byte waits for the rest of a sequence before it is
/// taken as the Escape key.
const esc_wait_ms = 30;

var raw = false;
var on_alt_screen = false;
var saved_unix: std.posix.termios = undefined;
var saved_out_mode: u32 = 0;
var saved_in_mode: u32 = 0;
var saved_out_cp: u32 = 0;
var saved_in_cp: u32 = 0;

const win = if (is_windows) struct {
    const HANDLE = std.os.windows.HANDLE;
    const DWORD = u32;
    const BOOL = i32;

    const COORD = extern struct { X: i16, Y: i16 };
    const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: u16,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
    };

    const KEY_EVENT_RECORD = extern struct {
        bKeyDown: i32,
        wRepeatCount: u16,
        wVirtualKeyCode: u16,
        wVirtualScanCode: u16,
        UnicodeChar: u16,
        dwControlKeyState: u32,
    };
    const MOUSE_EVENT_RECORD = extern struct {
        dwMousePosition: COORD,
        dwButtonState: u32,
        dwControlKeyState: u32,
        dwEventFlags: u32,
    };
    /// The event union sits at offset 4: WORD EventType, then padding.
    const INPUT_RECORD = extern struct {
        EventType: u16,
        _pad: u16,
        Event: extern union {
            KeyEvent: KEY_EVENT_RECORD,
            MouseEvent: MOUSE_EVENT_RECORD,
            FocusEvent: extern struct { bSetFocus: i32 },
        },
    };

    extern "kernel32" fn GetStdHandle(n: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(.winapi) i32;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleCP(wCodePageID: u32) callconv(.winapi) i32;
    extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
    extern "kernel32" fn GetConsoleMode(h: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleMode(h: HANDLE, mode: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleScreenBufferInfo(h: HANDLE, info: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadConsoleInputW(h: HANDLE, buf: *INPUT_RECORD, len: DWORD, read: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
    const WAIT_TIMEOUT: DWORD = 0x00000102;
    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const fn (u32) callconv(.winapi) BOOL,
        add: BOOL,
    ) callconv(.winapi) BOOL;

    const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
    const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));

    const KEY_EVENT: u16 = 0x0001;
    const MOUSE_EVENT: u16 = 0x0002;
    const WINDOW_BUFFER_SIZE_EVENT: u16 = 0x0004;
    const FOCUS_EVENT: u16 = 0x0010;

    const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
    const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
    const ENABLE_LINE_INPUT: DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: DWORD = 0x0004;
    const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
    const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
    const ENABLE_QUICK_EDIT_MODE: DWORD = 0x0040;
    const ENABLE_EXTENDED_FLAGS: DWORD = 0x0080;

    fn inHandle() ?HANDLE {
        return GetStdHandle(STD_INPUT_HANDLE);
    }
    fn outHandle() ?HANDLE {
        return GetStdHandle(STD_OUTPUT_HANDLE);
    }

    fn next(translator: *win_input.Translator, timeout_ms: u32) Input.Error!?Event {
        const h = inHandle() orelse return error.Closed;
        while (true) {
            if (WaitForSingleObject(h, timeout_ms) == WAIT_TIMEOUT) return null;
            var rec: INPUT_RECORD = undefined;
            var got: DWORD = 0;
            if (ReadConsoleInputW(h, &rec, 1, &got) == 0) return error.Closed;
            if (got == 0) continue;
            switch (rec.EventType) {
                KEY_EVENT => {
                    const k = rec.Event.KeyEvent;
                    if (k.bKeyDown == 0) continue;
                    const key = translator.key(.{
                        .vk = k.wVirtualKeyCode,
                        .unit = k.UnicodeChar,
                        .state = k.dwControlKeyState,
                    }) orelse continue;
                    return .{ .key = key };
                },
                MOUSE_EVENT => {
                    const m = rec.Event.MouseEvent;
                    const mouse = translator.mouse(.{
                        .x = m.dwMousePosition.X,
                        .y = m.dwMousePosition.Y,
                        .buttons = m.dwButtonState,
                        .state = m.dwControlKeyState,
                        .flags = m.dwEventFlags,
                    }) orelse continue;
                    return .{ .mouse = mouse };
                },
                FOCUS_EVENT => return .{ .focus = rec.Event.FocusEvent.bSetFocus != 0 },
                WINDOW_BUFFER_SIZE_EVENT => return .resize,
                else => continue,
            }
        }
    }
} else struct {};

// --- signals (Unix) ----------------------------------------------------------

/// Set from signal handlers, read by `Input.next`. A plain store is all a
/// handler may do.
var winch = std.atomic.Value(bool).init(false);
var hangup = std.atomic.Value(bool).init(false);

fn onWinch(_: std.posix.SIG) callconv(.c) void {
    winch.store(true, .release);
}

fn onHangup(_: std.posix.SIG) callconv(.c) void {
    hangup.store(true, .release);
}

fn installSignals() void {
    if (is_windows) return;
    // Reads and writes restart after a signal; `poll` never does, which is
    // what wakes `next`.
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = onWinch },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.WINCH, &act, null);
    // A closed terminal window or a polite kill: leave through the normal
    // exit path, which saves the session.
    act.handler = .{ .handler = onHangup };
    std.posix.sigaction(.HUP, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

// --- input -------------------------------------------------------------------

pub const Input = struct {
    pub const Error = error{ Closed, OutOfMemory };

    decoder: ansi.Decoder,
    translator: win_input.Translator = .{},

    pub fn init(allocator: std.mem.Allocator) Input {
        return .{ .decoder = ansi.Decoder.init(allocator) };
    }

    pub fn deinit(self: *Input) void {
        self.decoder.deinit();
    }

    /// Wait up to `timeout_ms` for the next event. Null means nothing
    /// happened in that time. `error.Closed` means the terminal went away.
    pub fn next(self: *Input, timeout_ms: u32) Error!?Event {
        if (is_windows) return win.next(&self.translator, timeout_ms);
        while (true) {
            if (hangup.load(.acquire)) return error.Closed;
            if (winch.swap(false, .acq_rel)) return .resize;
            if (self.decoder.next(false)) |ev| return ev;
            // Half a sequence (or a lone ESC) is waiting: give the rest a
            // moment to arrive, then take what is there as it stands.
            const held = self.decoder.pending();
            const wait: u32 = if (held) esc_wait_ms else timeout_ms;
            var fds = [1]std.posix.pollfd{.{ .fd = os.STDIN, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.c.poll(&fds, 1, @intCast(@min(wait, std.math.maxInt(i32))));
            if (ready < 0) continue; // interrupted by a signal: the flags above say which
            if (ready == 0) {
                if (held) {
                    if (self.decoder.next(true)) |ev| return ev;
                }
                return null;
            }
            var buf: [4096]u8 = undefined;
            const n = os.read(os.STDIN, &buf) catch {
                // Interrupted between poll and read; anything else shows up
                // as a hang-up on the next round.
                if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) return error.Closed;
                continue;
            };
            if (n == 0) return error.Closed;
            try self.decoder.feed(buf[0..n]);
        }
    }
};

// --- modes -------------------------------------------------------------------

/// True when stdin and stdout are both an interactive terminal.
pub fn isTty() bool {
    if (is_windows) {
        var mode: u32 = 0;
        const hin = win.inHandle() orelse return false;
        if (win.GetConsoleMode(hin, &mode) == 0) return false;
        const hout = win.outHandle() orelse return false;
        return win.GetConsoleMode(hout, &mode) != 0;
    } else {
        return std.c.isatty(os.STDIN) != 0 and std.c.isatty(os.STDOUT) != 0;
    }
}

/// Enter raw mode: no echo, no line buffering, no signals from keys.
pub fn enterRaw() !void {
    if (is_windows) {
        const in = win.inHandle() orelse return error.NoConsole;
        const out = win.outHandle() orelse return error.NoConsole;
        if (win.GetConsoleMode(in, &saved_in_mode) == 0) return error.NotATerminal;
        if (win.GetConsoleMode(out, &saved_out_mode) == 0) return error.NotATerminal;

        // Records are translated here, so no virtual-terminal input. Quick
        // edit would swallow the mouse.
        const in_mode = (saved_in_mode &
            ~(win.ENABLE_LINE_INPUT | win.ENABLE_ECHO_INPUT | win.ENABLE_PROCESSED_INPUT |
                win.ENABLE_QUICK_EDIT_MODE)) |
            win.ENABLE_MOUSE_INPUT | win.ENABLE_WINDOW_INPUT | win.ENABLE_EXTENDED_FLAGS;
        const out_mode = saved_out_mode |
            win.ENABLE_PROCESSED_OUTPUT | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        _ = win.SetConsoleMode(in, in_mode);
        _ = win.SetConsoleMode(out, out_mode);

        saved_out_cp = win.GetConsoleOutputCP();
        saved_in_cp = win.GetConsoleCP();
        _ = win.SetConsoleOutputCP(65001);
        _ = win.SetConsoleCP(65001);
    } else {
        saved_unix = try std.posix.tcgetattr(os.STDIN);
        var t = saved_unix;
        t.lflag.ICANON = false;
        t.lflag.ECHO = false;
        t.lflag.ISIG = false;
        t.lflag.IEXTEN = false;
        t.iflag.IXON = false;
        t.iflag.ICRNL = false;
        t.oflag.OPOST = false;
        t.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        t.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(os.STDIN, .NOW, t);
        installSignals();
    }
    raw = true;
}

/// What a Unix terminal is asked to report: mouse presses and drags in SGR
/// form, focus changes, and pastes wrapped in brackets. The Windows console
/// reports all of that through its records already.
const reports_on = if (is_windows) "" else "\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[?2004h";
const reports_off = if (is_windows) "" else "\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1002l";

/// Switch to the alternate screen, so the shell's contents come back on
/// exit. Auto-wrap goes off (?7l): every cell is positioned absolutely and
/// the terminal must never wrap or scroll on its own.
pub fn enterScreen() !void {
    on_alt_screen = true;
    try write("\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[2J\x1b[H" ++ reports_on);
}

/// Put the terminal back exactly as it was. Safe to call twice, and from a
/// panic.
pub fn restore() void {
    if (on_alt_screen) {
        write(reports_off ++ "\x1b[?7h\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        on_alt_screen = false;
    }
    if (!raw) return;
    if (is_windows) {
        if (win.inHandle()) |h| _ = win.SetConsoleMode(h, saved_in_mode);
        if (win.outHandle()) |h| _ = win.SetConsoleMode(h, saved_out_mode);
        if (saved_out_cp != 0) _ = win.SetConsoleOutputCP(saved_out_cp);
        if (saved_in_cp != 0) _ = win.SetConsoleCP(saved_in_cp);
    } else {
        std.posix.tcsetattr(os.STDIN, .NOW, saved_unix) catch {};
    }
    raw = false;
}

/// Current terminal size in cells.
pub fn size() Size {
    if (is_windows) {
        var info: win.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        const h = win.outHandle() orelse return .{ .rows = 24, .cols = 80 };
        if (win.GetConsoleScreenBufferInfo(h, &info) == 0) return .{ .rows = 24, .cols = 80 };
        const cols: i32 = @as(i32, info.srWindow.Right) - info.srWindow.Left + 1;
        const rows: i32 = @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1;
        return .{ .cols = @intCast(@max(cols, 1)), .rows = @intCast(@max(rows, 1)) };
    } else {
        var ws: std.posix.winsize = undefined;
        if (std.c.ioctl(os.STDOUT, std.posix.T.IOCGWINSZ, &ws) != 0) return .{ .rows = 24, .cols = 80 };
        return .{ .cols = @max(ws.col, 1), .rows = @max(ws.row, 1) };
    }
}

var close_handler: ?*const fn () void = null;

fn ctrlHandlerRoutine(code: u32) callconv(.winapi) i32 {
    // 2 = CTRL_CLOSE_EVENT (the window's X), 5 = logoff, 6 = shutdown. The
    // process is terminated without running its defers, so this is the only
    // chance to save.
    if (code == 2 or code == 5 or code == 6) {
        if (close_handler) |h| h();
    }
    return 0;
}

/// Windows: run `handler` when the console window is closed from its X
/// button. Unix reports the same thing as `error.Closed` from `Input.next`.
pub fn installCloseHandler(handler: *const fn () void) void {
    if (!is_windows) return;
    close_handler = handler;
    _ = win.SetConsoleCtrlHandler(ctrlHandlerRoutine, 1);
}

pub fn write(bytes: []const u8) !void {
    try os.writeAll(os.STDOUT, bytes);
}
