const std = @import("std");
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try std.fmt.allocPrint(a, "mibi {d} {s}\n", .{ 42, "x" });
    _ = try std.posix.write(1, s);
}
