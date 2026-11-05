const std = @import("std");
pub fn main() void {
    var x: u8 = 1;
    std.mem.doNotOptimizeAway(&x);
}
