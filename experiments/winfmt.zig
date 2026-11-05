const std = @import("std");
extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(h: ?*anyopaque, b: [*]const u8, n: u32, w: *u32, o: ?*anyopaque) callconv(.winapi) c_int;

pub fn main() void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "mibi {d}\n", .{42}) catch return;
    var w: u32 = 0;
    _ = WriteFile(GetStdHandle(@bitCast(@as(i32, -11))), s.ptr, @intCast(s.len), &w, null);
}
