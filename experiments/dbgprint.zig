const std = @import("std");
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
};
pub fn main() !void {
    std.debug.print("mibi {d} {s}\n", .{ 42, "x" });
}
