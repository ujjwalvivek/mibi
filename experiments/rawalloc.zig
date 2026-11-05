const std = @import("std");
const win = std.os.windows;
extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyopaque, dwSize: usize, flAllocationType: u32, flProtect: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(lpAddress: ?*anyopaque, dwSize: usize, dwFreeType: u32) callconv(.winapi) c_int;

pub fn main() !void {
    _ = win;
    const p = VirtualAlloc(null, 1 << 20, 0x3000, 0x04) orelse return error.OutOfMemory;
    const buf: [*]u8 = @ptrCast(p);
    buf[0] = 1;
    std.mem.doNotOptimizeAway(buf);
    _ = VirtualFree(p, 0, 0x8000);
}
