const std = @import("std");
pub fn main() void {
    const buf = std.heap.page_allocator.alloc(u8, 100) catch return;
    defer std.heap.page_allocator.free(buf);
    buf[0] = 1;
    std.mem.doNotOptimizeAway(buf);
}
