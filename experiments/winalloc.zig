const std = @import("std");
extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(h: ?*anyopaque, b: [*]const u8, n: u32, w: *u32, o: ?*anyopaque) callconv(.winapi) c_int;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const s = try std.fmt.allocPrint(arena.allocator(), "mibi {d} {s}\n", .{ 42, "x" });
    var w: u32 = 0;
    _ = WriteFile(GetStdHandle(@bitCast(@as(i32, -11))), s.ptr, @intCast(s.len), &w, null);
}
