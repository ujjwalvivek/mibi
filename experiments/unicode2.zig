const std = @import("std");
pub fn main() void {
    const s = "h\xc3\xa9llo";
    var it = std.unicode.Utf8View.init(s) catch return;
    var i = it.iterator();
    var n: usize = 0;
    while (i.nextCodepoint()) |cp| n +%= cp;
    std.mem.doNotOptimizeAway(&n);
}
