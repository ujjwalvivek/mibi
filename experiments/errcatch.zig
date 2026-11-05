pub fn main() void {
    mayFail() catch return;
}
fn mayFail() !void {
    return error.Nope;
}
