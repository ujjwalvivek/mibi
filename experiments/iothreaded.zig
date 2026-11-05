const std = @import("std");
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
};
pub fn main() !void {
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "mibi {d} {s}\n", .{ 42, "x" });
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.File.stdout().writeStreamingAll(io, s);
}
