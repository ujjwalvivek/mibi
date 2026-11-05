const std = @import("std");
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
};
pub fn main() !void {
    try mayFail();
}
fn mayFail() !void {
    return error.Nope;
}
