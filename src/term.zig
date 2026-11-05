//! Terminal control: raw mode, alternate screen, size, and input.
//!
//! Cross-platform by construction. Windows reads console INPUT_RECORDs with
//! `ReadConsoleInputW` and translates them to the same ANSI byte stream Unix
//! produces, because `ReadFile` on a console input handle is unreliable (it can
//! return 0 bytes). Output uses the console API with virtual-terminal
//! processing enabled so we emit the same ANSI on both platforms. No `std.Io`.

const std = @import("std");
const builtin = @import("builtin");
const os = @import("os.zig");

const is_windows = builtin.os.tag == .windows;

pub const Size = struct { rows: u16, cols: u16 };

var active = false;
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
    extern "kernel32" fn GetNumberOfConsoleInputEvents(h: HANDLE, n: *DWORD) callconv(.winapi) BOOL;

    const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
    const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));

    const MOUSE_EVENT: u16 = 0x0002;
    const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
    const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
    const ENABLE_LINE_INPUT: DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: DWORD = 0x0004;
    const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
    const ENABLE_EXTENDED_FLAGS: DWORD = 0x0080;
const ENABLE_QUICK_EDIT_MODE: DWORD = 0x0040;
    const FROM_LEFT_1ST_BUTTON_PRESSED: DWORD = 0x0001;
    const FROM_LEFT_2ND_BUTTON_PRESSED: DWORD = 0x0004;
    const RIGHTMOST_BUTTON_PRESSED: DWORD = 0x0002;
    const MOUSE_WHEELED: DWORD = 0x0004;
const MOUSE_MOVED: DWORD = 0x0001;

    const KEY_EVENT: u16 = 0x0001;
    const WINDOW_BUFFER_SIZE_EVENT: u16 = 0x0004;
    const RIGHT_ALT_PRESSED: u32 = 0x0001;
    const LEFT_ALT_PRESSED: u32 = 0x0002;
    const RIGHT_CTRL_PRESSED: u32 = 0x0004;
    const LEFT_CTRL_PRESSED: u32 = 0x0008;
    const SHIFT_PRESSED: u32 = 0x0010;

    var pending_high: u16 = 0;

    fn inHandle() ?HANDLE {
        return GetStdHandle(STD_INPUT_HANDLE);
    }
    fn outHandle() ?HANDLE {
        return GetStdHandle(STD_OUTPUT_HANDLE);
    }

    fn csi(out: []u8, mod: u16, final: u8, base: u16) usize {
        const s = if (base == 0)
            (if (mod == 1)
                std.fmt.bufPrint(out, "\x1b[{c}", .{final})
            else
                std.fmt.bufPrint(out, "\x1b[1;{d}{c}", .{ mod, final }))
        else
            (if (mod == 1)
                std.fmt.bufPrint(out, "\x1b[{d}~", .{base})
            else
                std.fmt.bufPrint(out, "\x1b[{d};{d}~", .{ base, mod }));
        const written = s catch return 0;
        return written.len;
    }

    /// Translate a mouse event into an SGR mouse sequence
    /// (`ESC [ < button ; x ; y M`), 1-based like a real terminal.
    fn translateMouse(m: MOUSE_EVENT_RECORD, out: []u8) usize {
        const x: u16 = @intCast(m.dwMousePosition.X + 1);
        const y: u16 = @intCast(m.dwMousePosition.Y + 1);
        var button: u16 = 0;
        if (m.dwEventFlags & win.MOUSE_WHEELED != 0) {
            const delta: i16 = @bitCast(@as(u16, @truncate(m.dwButtonState >> 16)));
            button = if (delta > 0) 64 else 65;
        } else if (m.dwButtonState & win.FROM_LEFT_1ST_BUTTON_PRESSED != 0) {
            // Dragging with the button held is reported as motion (bit 32).
            button = if (m.dwEventFlags & win.MOUSE_MOVED != 0) 32 else 0;
        } else if (m.dwButtonState & win.FROM_LEFT_2ND_BUTTON_PRESSED != 0) {
            button = 1;
        } else if (m.dwButtonState & win.RIGHTMOST_BUTTON_PRESSED != 0) {
            button = 2;
        } else if (m.dwEventFlags & win.MOUSE_MOVED != 0) {
            button = 35; // motion with nothing held: ignore in the editor
        } else {
            // Release: reported so a drag can finish.
            const written = std.fmt.bufPrint(out, "\x1b[<0;{d};{d}m", .{ x, y }) catch return 0;
            return written.len;
        }
        const written = std.fmt.bufPrint(out, "\x1b[<{d};{d};{d}M", .{ button, x, y }) catch return 0;
        return written.len;
    }

    /// Translate one key event into ANSI bytes. Returns the number written.
    fn translateKey(k: KEY_EVENT_RECORD, out: []u8) usize {
        const ctrl = (k.dwControlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) != 0;
        const shift = (k.dwControlKeyState & SHIFT_PRESSED) != 0;
        const alt = (k.dwControlKeyState & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED)) != 0;
        var mod: u16 = 1;
        if (shift) mod += 1;
        if (alt) mod += 2;
        if (ctrl) mod += 4;

        switch (k.wVirtualKeyCode) {
            0x26 => return csi(out, mod, 'A', 0), // up
            0x28 => return csi(out, mod, 'B', 0), // down
            0x27 => return csi(out, mod, 'C', 0), // right
            0x25 => return csi(out, mod, 'D', 0), // left
            0x24 => return csi(out, mod, 'H', 0), // home
            0x23 => return csi(out, mod, 'F', 0), // end
            0x21 => return csi(out, mod, '~', 5), // page up
            0x22 => return csi(out, mod, '~', 6), // page down
            0x2E => return csi(out, mod, '~', 3), // delete
            0x2D => return csi(out, mod, '~', 2), // insert
            else => {},
        }

        // Ctrl+/ and Ctrl+? both arrive as '/' with Ctrl held.
        if (ctrl and k.wVirtualKeyCode == 0xBF) {
            out[0] = 0x1f;
            return 1;
        }
        if (k.wVirtualKeyCode == 0x71) { // F2
        out[0] = 0x1b;
        out[1] = 'O';
        out[2] = 'Q';
        return 3;
    }
    if (k.wVirtualKeyCode == 0x70) { // F1
            const seq = "\x1bOP";
            @memcpy(out[0..seq.len], seq);
            return seq.len;
        }

        const ch = k.UnicodeChar;
        if (ch == 0) return 0;
        if (pending_high != 0) {
            if (std.unicode.utf16IsLowSurrogate(ch)) {
                const cp = std.unicode.utf16DecodeSurrogatePair(&.{ pending_high, ch }) catch 0xFFFD;
                pending_high = 0;
                return std.unicode.utf8Encode(cp, out) catch 0;
            }
            pending_high = 0;
        }
        if (std.unicode.utf16IsHighSurrogate(ch)) {
            pending_high = ch;
            return 0;
        }
        if (ch < 0x80) {
            out[0] = @intCast(ch);
            return 1;
        }
        return std.unicode.utf8Encode(ch, out) catch 0;
    }

    fn readInput(buf: []u8) !usize {
        const h = inHandle() orelse return error.NoHandle;
        var n: usize = 0;
        while (true) {
            if (n > 0) {
                var avail: DWORD = 0;
                if (GetNumberOfConsoleInputEvents(h, &avail) == 0 or avail == 0) break;
            }
            var rec: INPUT_RECORD = undefined;
            var read: DWORD = 0;
            if (ReadConsoleInputW(h, &rec, 1, &read) == 0) {
                if (n > 0) break;
                return error.ReadFailed;
            }
            if (read == 0) {
                if (n > 0) break;
                return 0;
            }
            // A resize is not input, but it must wake the run loop so the
            // screen is repainted at the new size without waiting for a key.
            if (rec.EventType == WINDOW_BUFFER_SIZE_EVENT) {
                resized = true;
                if (n > 0) break;
                return 0;
            }
            if (rec.EventType == KEY_EVENT and rec.Event.KeyEvent.bKeyDown != 0) {
                n += translateKey(rec.Event.KeyEvent, buf[n..]);
            }
            if (rec.EventType == MOUSE_EVENT) {
                n += translateMouse(rec.Event.MouseEvent, buf[n..]);
            }
            if (n >= buf.len) break;
        }
        return n;
    }
} else struct {};

/// Set when the console was resized since the last call (Windows only).
var resized = false;

/// True once after a resize event; the run loop uses it to repaint at once.
pub fn takeResize() bool {
    const r = resized;
    resized = false;
    return r;
}

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

        // We translate INPUT_RECORDs ourselves, so no virtual-terminal input.
        const in_mode = (saved_in_mode &
            ~(win.ENABLE_LINE_INPUT | win.ENABLE_ECHO_INPUT | win.ENABLE_PROCESSED_INPUT |
                win.ENABLE_QUICK_EDIT_MODE)) |
            win.ENABLE_MOUSE_INPUT | win.ENABLE_EXTENDED_FLAGS;
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
    }
    active = true;
}

/// Restore the terminal to its original state.
pub fn restore() void {
    if (!active) return;
    if (is_windows) {
        if (win.inHandle()) |h| _ = win.SetConsoleMode(h, saved_in_mode);
        if (win.outHandle()) |h| _ = win.SetConsoleMode(h, saved_out_mode);
        if (saved_out_cp != 0) _ = win.SetConsoleOutputCP(saved_out_cp);
        if (saved_in_cp != 0) _ = win.SetConsoleCP(saved_in_cp);
    } else {
        std.posix.tcsetattr(os.STDIN, .NOW, saved_unix) catch {};
    }
    active = false;
}

pub fn enterAltScreen() !void {
    // Disable auto-wrap (?7l): with absolute cursor positioning we never want
    // the terminal to wrap and scroll on its own.
    try os.writeAll(os.STDOUT, "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[2J\x1b[H");
}

pub fn leaveAltScreen() !void {
    try os.writeAll(os.STDOUT, "\x1b[?7h\x1b[0m\x1b[?25h\x1b[?1049l");
}

/// Set the terminal/tab title (OSC 2). Terminals show this in their chrome,
/// which is the closest a TUI gets to customising the window it lives in.
pub fn setTitle(title: []const u8) !void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\x1b]2;{s}\x07", .{title}) catch return;
    try os.writeAll(os.STDOUT, s);
}

/// Current terminal size in cells.
pub fn size() Size {
    if (is_windows) {
        var info: win.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        const h = win.outHandle() orelse return .{ .rows = 24, .cols = 80 };
        if (win.GetConsoleScreenBufferInfo(h, &info) == 0) return .{ .rows = 24, .cols = 80 };
        const cols: i32 = @as(i32, info.srWindow.Right) - info.srWindow.Left + 1;
        const rows: i32 = @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1;
        return .{
            .cols = @intCast(@max(cols, 1)),
            .rows = @intCast(@max(rows, 1)),
        };
    } else {
        var ws: std.posix.winsize = undefined;
        if (std.c.ioctl(os.STDOUT, std.posix.T.IOCGWINSZ, &ws) != 0) return .{ .rows = 24, .cols = 80 };
        return .{
            .cols = @max(ws.col, 1),
            .rows = @max(ws.row, 1),
        };
    }
}

/// Blocking read of one input chunk as ANSI bytes. Returns bytes read.
pub fn readInput(buf: []u8) !usize {
    if (is_windows) return win.readInput(buf);
    return os.read(os.STDIN, buf);
}

pub fn write(bytes: []const u8) !void {
    try os.writeAll(os.STDOUT, bytes);
}

test "windows key translation (Windows only)" {
    if (comptime !is_windows) return;
    var buf: [16]u8 = undefined;

    var k: win.KEY_EVENT_RECORD = std.mem.zeroes(win.KEY_EVENT_RECORD);
    k.bKeyDown = 1;
    k.UnicodeChar = 'a';
    try std.testing.expectEqual(@as(usize, 1), win.translateKey(k, &buf));
    try std.testing.expectEqual(@as(u8, 'a'), buf[0]);

    // Ctrl+Z -> 0x1a
    k.UnicodeChar = 0x1a;
    k.dwControlKeyState = win.LEFT_CTRL_PRESSED;
    try std.testing.expectEqual(@as(usize, 1), win.translateKey(k, &buf));
    try std.testing.expectEqual(@as(u8, 0x1a), buf[0]);

    // Ctrl+Right -> CSI 1;5C
    k.UnicodeChar = 0;
    k.dwControlKeyState = win.LEFT_CTRL_PRESSED;
    k.wVirtualKeyCode = 0x27;
    const n = win.translateKey(k, &buf);
    try std.testing.expectEqualStrings("\x1b[1;5C", buf[0..n]);

    // Shift+Up -> CSI 1;2A
    k.dwControlKeyState = win.SHIFT_PRESSED;
    k.wVirtualKeyCode = 0x26;
    const m = win.translateKey(k, &buf);
    try std.testing.expectEqualStrings("\x1b[1;2A", buf[0..m]);

    // PageDown -> CSI 6~
    k.dwControlKeyState = 0;
    k.wVirtualKeyCode = 0x22;
    const p = win.translateKey(k, &buf);
    try std.testing.expectEqualStrings("\x1b[6~", buf[0..p]);

    // F1 -> help
    k.wVirtualKeyCode = 0x70;
    const f = win.translateKey(k, &buf);
    try std.testing.expectEqualStrings("\x1bOP", buf[0..f]);

    // Ctrl+/ -> 0x1f
    k.wVirtualKeyCode = 0xBF;
    k.dwControlKeyState = win.LEFT_CTRL_PRESSED;
    const s = win.translateKey(k, &buf);
    try std.testing.expectEqual(@as(usize, 1), s);
    try std.testing.expectEqual(@as(u8, 0x1f), buf[0]);
}
