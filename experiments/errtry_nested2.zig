const std = @import("std");
pub const panic = std.debug.FullPanic(struct {
    fn f(_: []const u8, _: ?usize) noreturn {
        @trap();
    }
}.f);
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
};
pub fn main() void {
    run() catch |e| fail(e);
}
fn run() !void {
    try mayFail();
}
fn mayFail() !void {
    return error.Nope;
}
fn fail(_: anyerror) noreturn {
    @trap();
}
