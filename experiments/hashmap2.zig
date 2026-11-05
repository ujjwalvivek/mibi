const std = @import("std");
pub fn main() void {
    var m = std.StringHashMap(u32).init(std.heap.page_allocator);
    defer m.deinit();
    m.put("a", 1) catch return;
    std.mem.doNotOptimizeAway(&m);
}
