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

/// One read (or one drain of console key events) that produced this many bytes
/// at once is a paste, not typing: the fastest human repeat rate and the
/// longest key sequence both stay well below it.
const paste_burst_bytes: usize = 8;

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
    extern "kernel32" fn GetNumberOfConsoleInputEvents(h: HANDLE, n: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
    const WAIT_TIMEOUT: DWORD = 0x00000102;
    /// Physical key state. Windows Terminal does not always copy the modifier
    /// keys into the mouse record, so the wheel falls back to asking the system.
    extern "user32" fn GetAsyncKeyState(vKey: i32) callconv(.winapi) i16;
    const VK_SHIFT: i32 = 0x10;
    const VK_CONTROL: i32 = 0x11;
    const VK_MENU: i32 = 0x12;
    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const fn (u32) callconv(.winapi) BOOL,
        add: BOOL,
    ) callconv(.winapi) BOOL;

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
    const MOUSE_HWHEELED: DWORD = 0x0008;
    const MOUSE_MOVED: DWORD = 0x0001;
    /// `dwEventFlags` bit marking the second click of a double click.
    const DOUBLE_CLICK_FLAG: DWORD = 0x0002;

    const KEY_EVENT: u16 = 0x0001;
    const FOCUS_EVENT: u16 = 0x0010;
    const WINDOW_BUFFER_SIZE_EVENT: u16 = 0x0004;

    /// Last focus state reported by the console: 1 focused, 0 not, -1 unknown.
    var focus_state: i8 = -1;
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

    /// Set by the tests: a synthetic mouse record must not pick up whatever the
    /// human is holding down while the suite runs.
    var async_modifiers = true;

    /// Modifier bits from a mouse record: 1 = shift, 2 = alt, 4 = ctrl.
    fn modifiersFromState(state: u32) u16 {
        var bits: u16 = 0;
        if (state & SHIFT_PRESSED != 0) bits |= 1;
        if (state & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED) != 0) bits |= 2;
        if (state & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED) != 0) bits |= 4;
        return bits;
    }

    /// The same bits from the physical keyboard, for the record that arrived
    /// without them. `& 0x8000` is "the key is down now".
    fn modifiersFromKeyboard() u16 {
        const down: i16 = @bitCast(@as(u16, 0x8000));
        var bits: u16 = 0;
        if (GetAsyncKeyState(VK_SHIFT) & down != 0) bits |= 1;
        if (GetAsyncKeyState(VK_MENU) & down != 0) bits |= 2;
        if (GetAsyncKeyState(VK_CONTROL) & down != 0) bits |= 4;
        return bits;
    }

    /// Translate a mouse event into an SGR mouse sequence
    /// (`ESC [ < button ; x ; y M`), 1-based like a real terminal.
    fn translateMouse(m: MOUSE_EVENT_RECORD, out: []u8) usize {
        const x: u16 = @intCast(m.dwMousePosition.X + 1);
        const y: u16 = @intCast(m.dwMousePosition.Y + 1);
        var button: u16 = 0;
        if (m.dwEventFlags & (MOUSE_WHEELED | MOUSE_HWHEELED) != 0) {
            // The high word is the signed wheel delta; the low word is the
            // button state and carries no direction.
            const delta: i16 = @bitCast(@as(u16, @truncate(m.dwButtonState >> 16)));
            if (m.dwEventFlags & MOUSE_HWHEELED != 0) {
                // Horizontal wheel: 66 is left, 67 is right.
                button = if (delta > 0) 67 else 66;
            } else {
                button = if (delta > 0) 64 else 65; // up / down
            }
            // SGR mouse puts the modifiers in the button field (shift 4, alt 8,
            // ctrl 16). The editor uses shift+wheel to scroll sideways, so the
            // wheel keeps them; button presses stay plain to keep click
            // handling simple.
            var mods = modifiersFromState(m.dwControlKeyState);
            if (async_modifiers) mods |= modifiersFromKeyboard();
            if (mods & 1 != 0) button += 4;
            if (mods & 2 != 0) button += 8;
            if (mods & 4 != 0) button += 16;
        } else if (m.dwButtonState & win.FROM_LEFT_1ST_BUTTON_PRESSED != 0) {
            // Dragging with the button held is reported as motion (bit 32).
            button = if (m.dwEventFlags & win.MOUSE_MOVED != 0) 32 else 0;
        } else if (m.dwButtonState & win.FROM_LEFT_2ND_BUTTON_PRESSED != 0) {
            button = 1;
        } else if (m.dwButtonState & win.RIGHTMOST_BUTTON_PRESSED != 0) {
            button = 2;
        } else if (m.dwEventFlags & win.MOUSE_MOVED != 0) {
            button = 35; // motion with nothing held: ignore in the editor
        } else if (m.dwEventFlags & win.DOUBLE_CLICK_FLAG != 0) {
            // The console flags the second click of a double click and may have
            // already cleared the button bits; it is still a press, and the
            // editor needs it to count clicks.
            button = 0;
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
            0x72 => return csi(out, mod, 'R', 0), // F3: find next
            0x73 => return csi(out, mod, '~', 14), // F4: format
            0x74 => return csi(out, mod, '~', 15), // F5: split side by side
            0x75 => return csi(out, mod, '~', 17), // F6: pane focus
            0x76 => return csi(out, mod, '~', 18), // F7: split stacked
            0x77 => return csi(out, mod, '~', 19), // F8
            0x78 => return csi(out, mod, '~', 20), // F9
            0x79 => return csi(out, mod, '~', 21), // F10
            0x7a => return csi(out, mod, '~', 23), // F11
            0x7b => return csi(out, mod, '~', 24), // F12
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

    fn readInput(buf: []u8, timeout_ms: u32) !Input {
        const h = inHandle() orelse return error.NoHandle;
        var res: Input = .{};
        // A short wait lets the editor tick while nothing is typed.
        if (WaitForSingleObject(h, timeout_ms) == WAIT_TIMEOUT) {
            idle = true;
            return res;
        }
        var n: usize = 0;
        // Only key events count towards the paste heuristic: a mouse report is
        // a dozen bytes and would otherwise look like a burst.
        var key_bytes: usize = 0;
        while (true) {
            // Never block inside ReadConsoleInputW. When the queue is empty the
            // call waits for the next record with no timeout, and after a
            // key-up (which translates to zero bytes) that starved the idle
            // tick forever: no status-message aging, no disk housekeeping, no
            // autosave until the next keypress. Checking the queue first keeps
            // the caller's timeout in charge.
            var avail: DWORD = 0;
            if (GetNumberOfConsoleInputEvents(h, &avail) == 0 or avail == 0) break;
            var rec: INPUT_RECORD = undefined;
            var read: DWORD = 0;
            if (ReadConsoleInputW(h, &rec, 1, &read) == 0) {
                if (n > 0) break;
                return error.ReadFailed;
            }
            if (read == 0) {
                if (n > 0) break;
                res.n = n;
                return res;
            }
            // A resize is not input, but it must wake the run loop so the
            // screen is repainted at the new size without waiting for a key.
            if (rec.EventType == FOCUS_EVENT) {
                const now_focused = rec.Event.FocusEvent.bSetFocus != 0;
                const want: i8 = if (now_focused) 1 else 0;
                if (want != focus_state) {
                    focus_state = want;
                    focus_changed = true;
                }
                if (n > 0) break;
                res.n = n;
                return res;
            }
            if (rec.EventType == WINDOW_BUFFER_SIZE_EVENT) {
                resized = true;
                if (n > 0) break;
                res.n = n;
                return res;
            }
            if (rec.EventType == KEY_EVENT and rec.Event.KeyEvent.bKeyDown != 0) {
                const wrote = translateKey(rec.Event.KeyEvent, buf[n..]);
                n += wrote;
                key_bytes += wrote;
            }
            if (rec.EventType == MOUSE_EVENT) {
                n += translateMouse(rec.Event.MouseEvent, buf[n..]);
            }
            if (n >= buf.len) break;
        }
        res.n = n;
        // A console reports a paste as a burst of key events; there is no
        // bracketed-paste marker to look for here, so the burst is the signal.
        res.paste = looksLikePaste(key_bytes, buf[0..n]);
        return res;
    }
} else struct {};

/// What one blocking read produced: bytes for the editor, if any.
pub const Input = struct {
    n: usize = 0,
    /// True only at a real end of input (a closed stdin on Unix). A Windows
    /// console never reports EOF: zero records just mean "nothing yet".
    eof: bool = false,
    /// True when this read looks like a paste burst rather than typing.
    ///
    /// Heuristic, not a promise: one read (Windows: one drain of KEY_EVENTs)
    /// that produced at least `paste_burst_bytes` bytes, or at least two bytes
    /// including a line break, is treated as a paste. A single key is never a
    /// paste, and a lone Enter is one byte, so pressing Enter is still a
    /// keypress. Short pastes on Unix are caught by their bracketed-paste
    /// markers instead: `stripBracketedPaste` reports those, so a caller that
    /// wants one undo step per paste ORs the two signals.
    paste: bool = false,
};

/// True when a burst of `produced` bytes (the bytes key events translated to)
/// looks like a paste. `bytes` is the whole read, scanned for a line break; a
/// mouse report contains no CR/LF, so it cannot fake one.
fn looksLikePaste(produced: usize, bytes: []const u8) bool {
    if (produced >= paste_burst_bytes) return true;
    if (produced < 2) return false;
    for (bytes) |b| {
        // A console reports Enter as CR, so a pasted line break can arrive as
        // either byte; both count as "multi-line".
        if (b == '\n' or b == '\r') return true;
    }
    return false;
}

/// The markers a host adds around a paste once `?2004h` is on.
const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";

/// Room for the longest marker plus slack; the hold never needs more.
const pending_marker_max: usize = 8;

/// Bytes held back from the end of the previous chunk that may be the start of
/// a paste marker (e.g. `ESC[20`). A read boundary can fall anywhere, and a
/// partial marker must never be typed into the buffer as text.
var pending_marker: [pending_marker_max]u8 = undefined;
var pending_marker_len: usize = 0;

/// What `stripBracketedPaste` found in one chunk.
pub const PasteChunk = struct {
    /// The chunk with the paste markers removed; a slice of the caller's buffer.
    text: []const u8,
    /// True when a `ESC[200~`/`ESC[201~` marker was involved: leading,
    /// trailing, or completed from a held prefix.
    paste: bool,
};

/// Remove the bracketed-paste framing from one input chunk.
///
/// A leading `ESC[200~` and a trailing `ESC[201~` are dropped and `paste` is
/// set. Anything else is returned unchanged, so ordinary typing and escape
/// sequences pass straight through. A marker cut by the read boundary is held
/// in a small pending buffer and prepended to the next chunk, so neither half
/// is ever typed as text. Calling this with an empty chunk flushes a held
/// prefix that turned out not to be a marker.
///
/// `buf` must have room for `in.len + pending_marker_max` bytes (the held
/// prefix is re-emitted together with the new bytes) and must not alias `in`;
/// the returned text points into `buf`.
pub fn stripBracketedPaste(buf: []u8, in: []const u8) PasteChunk {
    const held = pending_marker[0..pending_marker_len];
    pending_marker_len = 0;
    if (held.len + in.len > buf.len) {
        // The caller broke the buffer contract. Dropping the held bytes is the
        // only safe answer: truncating the user's text would lose real input.
        const n = @min(in.len, buf.len);
        @memcpy(buf[0..n], in[0..n]);
        return .{ .text = buf[0..n], .paste = false };
    }
    @memcpy(buf[0..held.len], held);
    @memcpy(buf[held.len..][0..in.len], in);
    var text = buf[0 .. held.len + in.len];
    var paste = false;

    if (std.mem.startsWith(u8, text, paste_start)) {
        text = text[paste_start.len..];
        paste = true;
    }
    if (std.mem.endsWith(u8, text, paste_end)) {
        text = text[0 .. text.len - paste_end.len];
        paste = true;
    }

    // An empty chunk is the caller saying "nothing more right now": whatever is
    // held is emitted as text instead of being held forever.
    if (in.len == 0) return .{ .text = text, .paste = paste };

    // A chunk that ends exactly on the start marker: hold it whole, the paste
    // body arrives next read and the marker is stripped as leading then.
    if (std.mem.endsWith(u8, text, paste_start)) {
        const keep = paste_start.len;
        @memcpy(pending_marker[0..keep], text[text.len - keep ..]);
        pending_marker_len = keep;
        text = text[0 .. text.len - keep];
        return .{ .text = text, .paste = true };
    }

    // A marker cut mid-way: hold the trailing proper prefix (two bytes at
    // least - a lone ESC is the Esc key, and delaying it would make Esc feel
    // broken - and one byte short of the full marker).
    const tail = partialMarkerTail(text);
    if (tail > 0) {
        @memcpy(pending_marker[0..tail], text[text.len - tail ..]);
        pending_marker_len = tail;
        text = text[0 .. text.len - tail];
    }
    return .{ .text = text, .paste = paste };
}

/// Length of the longest suffix of `text` that is a proper prefix (2..5 bytes)
/// of either paste marker, or 0 when there is none.
fn partialMarkerTail(text: []const u8) usize {
    var len: usize = @min(text.len, paste_start.len - 1);
    while (len >= 2) : (len -= 1) {
        const tail = text[text.len - len ..];
        if (std.mem.eql(u8, tail, paste_start[0..len]) or std.mem.eql(u8, tail, paste_end[0..len])) return len;
    }
    return 0;
}

/// Forget any held marker prefix (tests start from a clean splitter).
fn resetPasteSplitter() void {
    pending_marker_len = 0;
}

/// Set when the console was resized since the last call (Windows only).
var resized = false;

/// True once after a resize event; the run loop uses it to repaint at once.
pub fn takeResize() bool {
    const r = resized;
    resized = false;
    return r;
}

/// Set when the console gained or lost focus (Windows only).
var focus_changed = false;

/// Last focus state: 1 focused, 0 not, -1 not reported yet (Windows only).
pub fn focusState() i8 {
    if (!is_windows) return -1;
    return win.focus_state;
}

/// True once after the console gained or lost focus.
pub fn takeFocusChange() bool {
    const f = focus_changed;
    focus_changed = false;
    return f;
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
    // Ask the host to frame pastes with ESC[200~/ESC[201~ so a multi-line paste
    // is one chunk instead of keystrokes the editor would run line by line.
    // Unix only: a Windows console reports pasted text as key events and has no
    // such mode, so the burst heuristic is the signal there.
    if (!is_windows) try os.writeAll(os.STDOUT, "\x1b[?2004h");
}

pub fn leaveAltScreen() !void {
    // Hand the mode back before leaving: the shell prompt after us must not
    // inherit bracketed paste.
    if (!is_windows) try os.writeAll(os.STDOUT, "\x1b[?2004l");
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

var close_handler: ?*const fn () void = null;

fn ctrlHandlerRoutine(event: u32) callconv(.winapi) i32 {
    // 2 = CTRL_CLOSE_EVENT (the window's X), 5 = logoff, 6 = shutdown. The
    // process is terminated without running its defers, so this is the only
    // chance to save.
    if (event == 2 or event == 5 or event == 6) {
        if (close_handler) |h| h();
    }
    return 0;
}

/// Save state when the console window is closed from its X button.
pub fn installCloseHandler(handler: *const fn () void) void {
    if (!is_windows) return;
    close_handler = handler;
    _ = win.SetConsoleCtrlHandler(ctrlHandlerRoutine, 1);
}

/// Blocking read of one input chunk as ANSI bytes. Returns what it read; a
/// timeout with nothing typed sets the idle flag and returns zero bytes.
pub fn readInput(buf: []u8, timeout_ms: u32) !Input {
    if (is_windows) return win.readInput(buf, timeout_ms);
    // Unix: poll first, so an idle editor still wakes up on its tick.
    var fds = [1]std.posix.pollfd{.{ .fd = os.STDIN, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&fds, @intCast(timeout_ms)) catch 1;
    if (ready == 0) {
        idle = true;
        return .{};
    }
    const n = try os.read(os.STDIN, buf);
    return .{ .n = n, .eof = n == 0, .paste = looksLikePaste(n, buf[0..n]) };
}

/// Milliseconds between idle wake-ups (housekeeping ticks).
pub const IDLE_MS = 500;
var idle: bool = false;

/// True when the last read returned only because the timeout expired.
pub fn takeIdle() bool {
    const v = idle;
    idle = false;
    return v;
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

test "windows mouse translation (Windows only)" {
    if (comptime !is_windows) return;
    var buf: [32]u8 = undefined;
    // Synthetic records must not pick up the modifiers the human happens to be
    // holding while the suite runs.
    const was_async = win.async_modifiers;
    win.async_modifiers = false;
    defer win.async_modifiers = was_async;

    var m: win.MOUSE_EVENT_RECORD = std.mem.zeroes(win.MOUSE_EVENT_RECORD);
    m.dwMousePosition = .{ .X = 4, .Y = 6 };

    // Hover: motion with nothing held, ignored by the editor but still reported.
    m.dwEventFlags = win.MOUSE_MOVED;
    var n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<35;5;7M", buf[0..n]);

    // Left press, then release.
    m.dwEventFlags = 0;
    m.dwButtonState = win.FROM_LEFT_1ST_BUTTON_PRESSED;
    n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<0;5;7M", buf[0..n]);
    m.dwButtonState = 0;
    n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<0;5;7m", buf[0..n]);

    // Right press, and the second click of a double click.
    m.dwButtonState = win.RIGHTMOST_BUTTON_PRESSED;
    n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<2;5;7M", buf[0..n]);
    m.dwButtonState = 0;
    m.dwEventFlags = win.DOUBLE_CLICK_FLAG;
    n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<0;5;7M", buf[0..n]);

    // Drag: left held while moving.
    m.dwEventFlags = win.MOUSE_MOVED;
    m.dwButtonState = win.FROM_LEFT_1ST_BUTTON_PRESSED;
    n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<32;5;7M", buf[0..n]);

    // Vertical wheel: the signed high word is the delta, positive is up.
    m.dwEventFlags = win.MOUSE_WHEELED;
    m.dwButtonState = @as(u32, 1) << 16;
    n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<64;5;7M", buf[0..n]);
    m.dwButtonState = @as(u32, 0xFFFF) << 16; // -1
    n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<65;5;7M", buf[0..n]);

    // Modifiers ride in the button field on wheel events: shift 4, ctrl 16.
    m.dwButtonState = @as(u32, 1) << 16;
    m.dwControlKeyState = win.SHIFT_PRESSED;
    n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<68;5;7M", buf[0..n]);
    m.dwControlKeyState = win.LEFT_CTRL_PRESSED;
    n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<80;5;7M", buf[0..n]);
    m.dwControlKeyState = win.LEFT_ALT_PRESSED;
    n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<72;5;7M", buf[0..n]);

    // Horizontal wheel: 67 is right, 66 is left.
    m.dwControlKeyState = 0;
    m.dwEventFlags = win.MOUSE_HWHEELED;
    m.dwButtonState = @as(u32, 1) << 16;
    n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<67;5;7M", buf[0..n]);
    m.dwButtonState = @as(u32, 0xFFFF) << 16;
    n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<66;5;7M", buf[0..n]);

    // Coordinates are 1-based: cell (0,0) is reported as 1;1.
    m.dwEventFlags = win.MOUSE_MOVED;
    m.dwButtonState = 0;
    m.dwMousePosition = .{ .X = 0, .Y = 0 };
    n = win.translateMouse(m, &buf);
    try std.testing.expectEqualStrings("\x1b[<35;1;1M", buf[0..n]);
}

test "windows mouse modifiers fall back to the keyboard (Windows only)" {
    if (comptime !is_windows) return;
    // The pure half: what a record's own state says, and what the fallback
    // contributes, must combine without double counting.
    try std.testing.expectEqual(@as(u16, 0), win.modifiersFromState(0));
    try std.testing.expectEqual(@as(u16, 1), win.modifiersFromState(win.SHIFT_PRESSED));
    try std.testing.expectEqual(@as(u16, 2), win.modifiersFromState(win.RIGHT_ALT_PRESSED));
    try std.testing.expectEqual(@as(u16, 4), win.modifiersFromState(win.RIGHT_CTRL_PRESSED));
    const both = win.modifiersFromState(win.SHIFT_PRESSED) | win.modifiersFromState(win.LEFT_CTRL_PRESSED);
    try std.testing.expectEqual(@as(u16, 5), both);
}

test "stripBracketedPaste leaves plain text alone" {
    var buf: [64]u8 = undefined;
    resetPasteSplitter();
    const c = stripBracketedPaste(&buf, "hello");
    try std.testing.expectEqualStrings("hello", c.text);
    try std.testing.expect(!c.paste);

    // Arrow keys and function keys start with ESC but are not markers.
    const arrow = stripBracketedPaste(&buf, "\x1b[A");
    try std.testing.expectEqualStrings("\x1b[A", arrow.text);
    try std.testing.expect(!arrow.paste);
    const f1 = stripBracketedPaste(&buf, "\x1bOP");
    try std.testing.expectEqualStrings("\x1bOP", f1.text);
    try std.testing.expect(!f1.paste);
    // A lone ESC is the Esc key: it must pass through, not be held.
    const esc = stripBracketedPaste(&buf, "\x1b");
    try std.testing.expectEqualStrings("\x1b", esc.text);
    try std.testing.expect(!esc.paste);
}

test "stripBracketedPaste removes the framing markers" {
    var buf: [64]u8 = undefined;
    resetPasteSplitter();
    var c = stripBracketedPaste(&buf, "\x1b[200~hello\x1b[201~");
    try std.testing.expectEqualStrings("hello", c.text);
    try std.testing.expect(c.paste);

    resetPasteSplitter();
    c = stripBracketedPaste(&buf, "\x1b[200~hello");
    try std.testing.expectEqualStrings("hello", c.text);
    try std.testing.expect(c.paste);

    resetPasteSplitter();
    c = stripBracketedPaste(&buf, "hello\x1b[201~");
    try std.testing.expectEqualStrings("hello", c.text);
    try std.testing.expect(c.paste);

    // An empty framed paste is still a paste.
    resetPasteSplitter();
    c = stripBracketedPaste(&buf, "\x1b[200~\x1b[201~");
    try std.testing.expectEqualStrings("", c.text);
    try std.testing.expect(c.paste);
}

test "stripBracketedPaste holds a split start marker" {
    var buf: [64]u8 = undefined;
    resetPasteSplitter();
    // The read boundary fell inside ESC[200~: nothing may leak as text.
    var c = stripBracketedPaste(&buf, "\x1b[20");
    try std.testing.expectEqualStrings("", c.text);
    try std.testing.expect(!c.paste);
    c = stripBracketedPaste(&buf, "0~hello\x1b[201~");
    try std.testing.expectEqualStrings("hello", c.text);
    try std.testing.expect(c.paste);
}

test "stripBracketedPaste holds a split end marker" {
    var buf: [64]u8 = undefined;
    resetPasteSplitter();
    // The body arrives now; the closing marker is cut in half.
    var c = stripBracketedPaste(&buf, "hello\x1b[20");
    try std.testing.expectEqualStrings("hello", c.text);
    try std.testing.expect(!c.paste);
    c = stripBracketedPaste(&buf, "1~");
    try std.testing.expectEqualStrings("", c.text);
    try std.testing.expect(c.paste);
}

test "stripBracketedPaste holds a start marker that ends the chunk" {
    var buf: [64]u8 = undefined;
    resetPasteSplitter();
    // A whole marker at the end: the paste body starts in the next read.
    var c = stripBracketedPaste(&buf, "abc\x1b[200~");
    try std.testing.expectEqualStrings("abc", c.text);
    try std.testing.expect(c.paste);
    c = stripBracketedPaste(&buf, "body");
    try std.testing.expectEqualStrings("body", c.text);
    try std.testing.expect(c.paste);
}

test "stripBracketedPaste flushes a held prefix that was not a marker" {
    var buf: [64]u8 = undefined;
    resetPasteSplitter();
    // ESC[20 is also how CSI 20 A starts: when the next byte disproves the
    // marker, the held bytes are typed out again, in order.
    _ = stripBracketedPaste(&buf, "\x1b[20");
    const c = stripBracketedPaste(&buf, "A");
    try std.testing.expectEqualStrings("\x1b[20A", c.text);
    try std.testing.expect(!c.paste);

    // An empty chunk means "nothing more is coming": flush instead of holding.
    resetPasteSplitter();
    _ = stripBracketedPaste(&buf, "\x1b[20");
    const flush = stripBracketedPaste(&buf, "");
    try std.testing.expectEqualStrings("\x1b[20", flush.text);
    try std.testing.expect(!flush.paste);
}

test "stripBracketedPaste survives a too-small buffer" {
    var buf: [64]u8 = undefined;
    resetPasteSplitter();
    _ = stripBracketedPaste(&buf, "\x1b[20"); // held
    // The contract is buf.len >= in.len + 8; a broken caller loses the held
    // bytes rather than panicking or truncating the new ones.
    var small: [4]u8 = undefined;
    const c = stripBracketedPaste(&small, "0123456789");
    try std.testing.expectEqualStrings("0123", c.text);
    try std.testing.expect(!c.paste);
}

test "paste burst thresholds" {
    // A single key is a keypress, never a paste.
    try std.testing.expect(!looksLikePaste(0, ""));
    try std.testing.expect(!looksLikePaste(1, "a"));
    // A lone Enter is one byte: pressing Enter must not look like a paste.
    try std.testing.expect(!looksLikePaste(1, "\r"));
    try std.testing.expect(!looksLikePaste(1, "\n"));
    // Two keys typed quickly are not a paste either...
    try std.testing.expect(!looksLikePaste(2, "ab"));
    try std.testing.expect(!looksLikePaste(7, "abcdefg"));
    // ...but a real burst, or a multi-line burst, is.
    try std.testing.expect(looksLikePaste(8, "abcdefgh"));
    try std.testing.expect(looksLikePaste(2, "a\n"));
    try std.testing.expect(looksLikePaste(2, "a\r")); // a console Enter is CR
    try std.testing.expect(looksLikePaste(3, "a\rb"));
}

test "a single key event is not a paste burst (Windows only)" {
    if (comptime !is_windows) return;
    var buf: [16]u8 = undefined;
    var k: win.KEY_EVENT_RECORD = std.mem.zeroes(win.KEY_EVENT_RECORD);
    k.bKeyDown = 1;
    k.UnicodeChar = 'a';
    const n = win.translateKey(k, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expect(!looksLikePaste(n, buf[0..n]));
    // Enter alone stays a keypress too.
    k.UnicodeChar = '\r';
    const m = win.translateKey(k, &buf);
    try std.testing.expectEqual(@as(usize, 1), m);
    try std.testing.expect(!looksLikePaste(m, buf[0..m]));
}
