pub fn main() !void {
    try mayFail();
}
fn mayFail() !void {
    return error.Nope;
}
