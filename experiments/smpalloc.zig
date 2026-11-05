const std = @import("std");
pub fn main() !void {
    const buf = try std.heap.smp_allocator.alloc(u8, 100);
    defer std.heap.smp_allocator.free(buf);
    buf[0] = 1;
    std.mem.doNotOptimizeAway(buf);
}
