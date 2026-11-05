const std = @import("std");
pub fn main() void {
    mayFail() catch {};
}
fn mayFail() !void {
    var x: u8 = 1;
    std.mem.doNotOptimizeAway(&x);
    return error.Nope;
}
