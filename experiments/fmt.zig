const std = @import("std");
pub fn main() !void {
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "mibi {d} {s}\n", .{ 42, "x" });
    _ = try std.posix.write(1, s);
}
