// Console metrics probe: what does Windows actually report?
const std = @import("std");

const DWORD = u32;
const HANDLE = *anyopaque;
const COORD = extern struct { X: i16, Y: i16 };
const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
const Info = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: u16,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};
extern "kernel32" fn GetStdHandle(n: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetConsoleScreenBufferInfo(h: HANDLE, info: *Info) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(h: HANDLE, b: [*]const u8, n: DWORD, w: *DWORD, o: ?*anyopaque) callconv(.winapi) i32;

fn out(s: []const u8) void {
    var w: DWORD = 0;
    _ = WriteFile(GetStdHandle(@bitCast(@as(i32, -11))).?, s.ptr, @intCast(s.len), &w, null);
}

pub fn main() void {
    var buf: [512]u8 = undefined;
    const h = GetStdHandle(@bitCast(@as(i32, -11)));
    if (h == null) {
        out("GetStdHandle: null\n");
        return;
    }
    var info: Info = undefined;
    const ok = GetConsoleScreenBufferInfo(h.?, &info);
    const s = std.fmt.bufPrint(&buf, "ok={d}\n  dwSize={d}x{d}\n  srWindow L={d} T={d} R={d} B={d} => {d}x{d}\n  maxWin={d}x{d}\n", .{
        ok,
        info.dwSize.X,       info.dwSize.Y,
        info.srWindow.Left,  info.srWindow.Top,
        info.srWindow.Right, info.srWindow.Bottom,
        @as(i32, info.srWindow.Right) - info.srWindow.Left + 1,
        @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1,
        info.dwMaximumWindowSize.X, info.dwMaximumWindowSize.Y,
    }) catch "fmt error\n";
    out(s);
}
