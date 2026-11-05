const std = @import("std");
pub fn main() void {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.heap.page_allocator);
    list.append(std.heap.page_allocator, 'x') catch return;
    std.mem.doNotOptimizeAway(list.items.ptr);
}
