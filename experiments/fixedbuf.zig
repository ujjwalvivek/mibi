const std = @import("std");
pub fn main() !void {
    var backing: [1 << 20]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const a = fba.allocator();
    const buf = try a.alloc(u8, 100);
    buf[0] = 1;
    std.mem.doNotOptimizeAway(buf);
}
