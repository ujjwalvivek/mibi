//! Loads the language definitions in a `syntax.d` directory into a
//! `syntax.Registry`. The registry itself only parses text; the file access
//! lives here so the core stays free of the OS.

const std = @import("std");
const os = @import("os.zig");
const syntax = @import("core/syntax.zig");

/// Load every `*.ini` in `dir`, in name order. Returns how many languages
/// were parsed. A missing directory or a broken file is not an error: that
/// language is simply not highlighted.
pub fn loadDir(registry: *syntax.Registry, dir: []const u8) usize {
    const allocator = registry.allocator;
    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    os.listDirNames(allocator, dir, &names) catch return 0;

    var count: usize = 0;
    os.sortStrings(names.items);
    for (names.items) |name| {
        if (!std.mem.endsWith(u8, name, ".ini")) continue;
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
        const data = os.readFileAlloc(allocator, path, 1024 * 1024) catch continue;
        defer allocator.free(data);
        registry.parse(data) catch continue;
        count += 1;
    }
    return count;
}

test "a missing syntax.d directory is not an error" {
    var reg = syntax.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 0), loadDir(&reg, "no-such-syntax-dir"));
    try std.testing.expect(reg.find("x.zig") == null);
}

test "the repository syntax.d loads and knows common languages" {
    var reg = syntax.Registry.init(std.testing.allocator);
    defer reg.deinit();
    const count = loadDir(&reg, "syntax.d");
    try std.testing.expect(count >= 8);
    try std.testing.expectEqualStrings("Zig", reg.find("src/main.zig").?.name);
    try std.testing.expectEqualStrings("C", reg.find("main.c").?.name);
    try std.testing.expectEqualStrings("Rust", reg.find("lib.rs").?.name);
    try std.testing.expectEqualStrings("Python", reg.find("x.py").?.name);
    try std.testing.expectEqualStrings("json", reg.find("package.json").?.name);
    try std.testing.expect(reg.find("README") == null);
}
