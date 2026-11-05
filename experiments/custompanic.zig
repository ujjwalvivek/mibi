const std = @import("std");
pub const panic = std.debug.FullPanic(struct {
    fn f(_: []const u8, _: ?usize) noreturn {
        std.process.exit(1);
    }
}.f);
pub fn main() void {}
