const std = @import("std");
pub fn main() void {
    run() catch {};
}
fn run() !void {
    try mayFail();
}
fn mayFail() !void {
    var x: u8 = 1;
    std.mem.doNotOptimizeAway(&x);
    return error.Nope;
}
