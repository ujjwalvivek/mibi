const std = @import("std");
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
};
pub fn main() void {
    mayFail() catch {};
}
fn mayFail() !void {
    var x: u8 = 1;
    std.mem.doNotOptimizeAway(&x);
    return error.Nope;
}
