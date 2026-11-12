//! File tree state: a flattened list of visible entries under a root
//! directory, with expanded directories tracked by path.

const std = @import("std");
const os = @import("platform").os;

pub const MAX_PATH = 512;

pub const Entry = struct {
    /// Name shown in the tree.
    name: []u8,
    /// Path relative to the root ("" is the root itself).
    path: []u8,
    is_dir: bool,
    depth: usize,
    /// The synthetic ".." row that walks up one directory.
    is_parent: bool = false,
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    root: [MAX_PATH]u8 = undefined,
    root_len: usize = 0,
    parent: [MAX_PATH]u8 = undefined,
    parent_len: usize = 0,
    entries: std.ArrayList(Entry),
    expanded: std.ArrayList([]u8),
    selected: usize = 0,
    scroll: usize = 0,
    /// Signature of the directory listings last read, for the idle refresh.
    listing_sig: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, root: []const u8) !Tree {
        var t = Tree{
            .allocator = allocator,
            .entries = std.ArrayList(Entry).empty,
            .expanded = std.ArrayList([]u8).empty,
        };
        t.setRoot(root);
        errdefer t.deinit();
        try t.reload();
        return t;
    }

    pub fn deinit(self: *Tree) void {
        self.clearEntries();
        self.entries.deinit(self.allocator);
        for (self.expanded.items) |p| self.allocator.free(p);
        self.expanded.deinit(self.allocator);
    }

    pub fn rootPath(self: *const Tree) []const u8 {
        return self.root[0..self.root_len];
    }

    fn setRoot(self: *Tree, root: []const u8) void {
        const n = @min(root.len, self.root.len);
        @memcpy(self.root[0..n], root[0..n]);
        self.root_len = n;
        self.parent_len = 0;
        const p = parentOf(self.rootPath()) orelse return;
        const m = @min(p.len, self.parent.len);
        @memcpy(self.parent[0..m], p[0..m]);
        self.parent_len = m;
    }

    pub fn parentPath(self: *const Tree) []const u8 {
        return self.parent[0..self.parent_len];
    }

    /// Walk up one directory (the ".." row).
    pub fn goUp(self: *Tree) !void {
        if (self.parent_len == 0) return;
        var buf: [MAX_PATH]u8 = undefined;
        const parent = self.parentPath();
        const n = @min(parent.len, buf.len);
        @memcpy(buf[0..n], parent[0..n]);
        self.setRoot(buf[0..n]);
        for (self.expanded.items) |p| self.allocator.free(p);
        self.expanded.clearRetainingCapacity();
        self.selected = 0;
        try self.reload();
    }

    /// The directory above `path`, or null at the filesystem root.
    fn parentOf(path: []const u8) ?[]const u8 {
        var end = path.len;
        while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
        var i = end;
        while (i > 0) : (i -= 1) {
            if (path[i - 1] == '/' or path[i - 1] == '\\') {
                if (i == 1) return path[0..1]; // "/" or "C:\"
                return path[0 .. i - 1];
            }
        }
        // Relative paths without a separator: "." lives above, and a bare
        // name lives in the working directory.
        if (std.mem.eql(u8, path, ".")) return "..";
        if (std.mem.eql(u8, path, "..")) return "../..";
        return ".";
    }

    fn clearEntries(self: *Tree) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.name);
            self.allocator.free(e.path);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Rebuild the visible list: root children, then expanded directories.
    pub fn reload(self: *Tree) !void {
        self.clearEntries();
        if (self.parent_len > 0) {
            try self.addEntry("..", "", true, 0, true);
        }
        try self.addDir("", 0);
        self.selected = @min(self.selected, if (self.entries.items.len > 0) self.entries.items.len - 1 else 0);
    }

    fn addEntry(self: *Tree, name: []const u8, path: []const u8, is_dir: bool, depth: usize, is_parent: bool) !void {
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const own_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(own_name);
        const own_path = try self.allocator.dupe(u8, path);
        self.entries.appendAssumeCapacity(.{
            .name = own_name,
            .path = own_path,
            .is_dir = is_dir,
            .depth = depth,
            .is_parent = is_parent,
        });
    }

    fn addDir(self: *Tree, rel: []const u8, depth: usize) !void {
        var dir_buf: [MAX_PATH * 2]u8 = undefined;
        const dir = if (rel.len == 0)
            self.rootPath()
        else
            std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ self.rootPath(), rel }) catch return;

        var names = std.ArrayList([]u8).empty;
        defer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }
        os.listDirNames(self.allocator, dir, &names) catch return;
        os.sortStrings(names.items);

        // Directories first, then files, each alphabetically.
        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            for (names.items) |name| {
                if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                // The editor's own state files are not part of the project.
                var path_buf: [MAX_PATH * 2]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
                const is_dir = os.isDirectory(path);
                if ((pass == 0) != is_dir) continue;

                var rel_buf: [MAX_PATH * 2]u8 = undefined;
                const rel_path = if (rel.len == 0)
                    name
                else
                    std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ rel, name }) catch continue;

                try self.addEntry(name, rel_path, is_dir, depth, false);
                if (is_dir and self.isExpanded(rel_path)) {
                    try self.addDir(rel_path, depth + 1);
                }
            }
        }
    }

    pub fn isExpanded(self: *const Tree, path: []const u8) bool {
        for (self.expanded.items) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    pub fn toggleDir(self: *Tree, path: []const u8) !void {
        if (self.isExpanded(path)) {
            var i: usize = 0;
            while (i < self.expanded.items.len) : (i += 1) {
                if (std.mem.eql(u8, self.expanded.items[i], path)) {
                    self.allocator.free(self.expanded.items[i]);
                    _ = self.expanded.orderedRemove(i);
                    break;
                }
            }
        } else {
            try self.expanded.append(self.allocator, try self.allocator.dupe(u8, path));
        }
        try self.reload();
    }

    /// Expand a directory (used to restore the sidebar from the session).
    /// The caller reloads once after adding every saved path.
    pub fn expand(self: *Tree, path: []const u8) !void {
        if (path.len == 0 or self.isExpanded(path)) return;
        try self.expanded.append(self.allocator, try self.allocator.dupe(u8, path));
    }

    /// Select the visible entry with this path, if there is one.
    pub fn selectPath(self: *Tree, path: []const u8) void {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.path, path)) {
                self.selected = i;
                return;
            }
        }
    }

    /// Re-read the directories this tree shows when the listing changed, and
    /// keep the selected entry selected. Cheap enough to run twice a second.
    pub fn refreshIfChanged(self: *Tree) bool {
        var sig: u64 = 0xcbf29ce484222325;
        var names = std.ArrayList([]u8).empty;
        defer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }
        if (!self.stampDirs(&sig, &names)) return false; // listing unavailable
        if (sig == self.listing_sig) return false;
        self.listing_sig = sig;
        var sel_buf: [MAX_PATH * 2]u8 = undefined;
        var sel_len: usize = 0;
        if (self.selectedPath(&sel_buf)) |p| sel_len = @min(p.len, sel_buf.len);
        self.reload() catch return false;
        if (sel_len > 0) self.selectPath(sel_buf[0..sel_len]);
        return true;
    }

    fn stampDirs(self: *Tree, sig: *u64, names: *std.ArrayList([]u8)) bool {
        var ok = true;
        self.stampOne(self.rootPath(), sig, names) catch {
            ok = false;
        };
        for (self.expanded.items) |dir| {
            var buf: [MAX_PATH * 2]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.rootPath(), dir }) catch continue;
            self.stampOne(full, sig, names) catch {
                ok = false;
            };
        }
        return ok;
    }

    fn stampOne(self: *Tree, dir: []const u8, sig: *u64, names: *std.ArrayList([]u8)) !void {
        names.clearRetainingCapacity();
        try os.listDirNames(self.allocator, dir, names);
        os.sortStrings(names.items);
        for (names.items) |name| {
            for (name) |b| {
                sig.* ^= b;
                sig.* *%= 0x100000001b3;
            }
            sig.* ^= '/';
            sig.* *%= 0x100000001b3;
        }
        sig.* ^= 0xff;
        sig.* *%= 0x100000001b3;
    }

    pub fn count(self: *const Tree) usize {
        return self.entries.items.len;
    }

    pub fn move(self: *Tree, delta: isize) void {
        const n = self.entries.items.len;
        if (n == 0) return;
        const i: isize = @as(isize, @intCast(self.selected)) + delta;
        self.selected = @intCast(std.math.clamp(i, 0, @as(isize, @intCast(n - 1))));
    }

    pub fn selectedEntry(self: *const Tree) ?*const Entry {
        if (self.selected >= self.entries.items.len) return null;
        return &self.entries.items[self.selected];
    }

    /// Absolute path of the selected entry.
    pub fn selectedPath(self: *const Tree, buf: []u8) ?[]const u8 {
        const e = self.selectedEntry() orelse return null;
        if (e.path.len == 0) return null;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.rootPath(), e.path }) catch null;
    }

    pub fn ensureVisible(self: *Tree, rows: usize) void {
        if (rows == 0) return;
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + rows) self.scroll = self.selected + 1 - rows;
    }
};

// --- icons -----------------------------------------------------------------
/// Nerd Font glyphs per file type (single cell each). `[editor] icons = ascii`
/// falls back to letter markers for terminals without a patched font.
pub fn iconFor(name: []const u8, is_dir: bool, expanded: bool, unicode: bool) []const u8 {
    if (is_dir) {
        if (!unicode) return if (expanded) "v" else ">";
        return if (expanded) "\u{f07c}" else "\u{f07b}"; // folder / folder-open
    }
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse {
        return if (unicode) "\u{f15b}" else ".";
    };
    const ext = name[dot + 1 ..];
    if (!unicode) {
        const ascii = [_]struct { ext: []const u8, glyph: []const u8 }{
            .{ .ext = "zig", .glyph = "z" }, .{ .ext = "rs", .glyph = "r" },
            .{ .ext = "py", .glyph = "p" },  .{ .ext = "js", .glyph = "j" },
            .{ .ext = "ts", .glyph = "t" },  .{ .ext = "md", .glyph = "m" },
            .{ .ext = "sh", .glyph = "$" },  .{ .ext = "html", .glyph = "<" },
        };
        for (ascii) |row| {
            if (std.ascii.eqlIgnoreCase(ext, row.ext)) return row.glyph;
        }
        return ".";
    }
    const table = [_]struct { ext: []const u8, glyph: []const u8 }{
        .{ .ext = "zig", .glyph = "\u{e6a9}" }, // zig
        .{ .ext = "rs", .glyph = "\u{e7a8}" }, // rust
        .{ .ext = "py", .glyph = "\u{e73c}" }, // python
        .{ .ext = "js", .glyph = "\u{e74e}" }, // javascript
        .{ .ext = "ts", .glyph = "\u{e628}" }, // typescript
        .{ .ext = "json", .glyph = "\u{e60b}" }, // json
        .{ .ext = "toml", .glyph = "\u{e615}" }, // config
        .{ .ext = "yaml", .glyph = "\u{e615}" },
        .{ .ext = "yml", .glyph = "\u{e615}" },
        .{ .ext = "ini", .glyph = "\u{e615}" },
        .{ .ext = "md", .glyph = "\u{e73e}" }, // markdown
        .{ .ext = "txt", .glyph = "\u{f15c}" }, // file-text
        .{ .ext = "sh", .glyph = "\u{f489}" }, // terminal
        .{ .ext = "c", .glyph = "\u{e61e}" }, // c
        .{ .ext = "h", .glyph = "\u{f0fd}" }, // h-square
        .{ .ext = "cpp", .glyph = "\u{e61d}" }, // c++
        .{ .ext = "go", .glyph = "\u{e627}" }, // go
        .{ .ext = "lua", .glyph = "\u{e620}" }, // lua
        .{ .ext = "html", .glyph = "\u{e736}" }, // html5
        .{ .ext = "css", .glyph = "\u{e749}" }, // css3
        .{ .ext = "svg", .glyph = "\u{f1c5}" }, // file-image
        .{ .ext = "png", .glyph = "\u{f1c5}" },
        .{ .ext = "jpg", .glyph = "\u{f1c5}" },
    };
    for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row.ext)) return row.glyph;
    }
    return "\u{f15b}";
}

// --- tests -----------------------------------------------------------------
test "the tree lists the working directory" {
    var tree = try Tree.init(std.testing.allocator, ".");
    defer tree.deinit();
    try std.testing.expect(tree.count() > 0);
    // The repository has a src directory; it must be listed and expandable.
    var found = false;
    for (tree.entries.items) |e| {
        if (e.is_dir and std.mem.eql(u8, e.name, "src")) found = true;
    }
    try std.testing.expect(found);
}

test "icons follow the extension" {
    try std.testing.expectEqualStrings("\u{f07b}", iconFor("src", true, false, true));
    try std.testing.expectEqualStrings("\u{f07c}", iconFor("src", true, true, true));
    try std.testing.expectEqualStrings("\u{e6a9}", iconFor("main.zig", false, false, true));
    try std.testing.expectEqualStrings(">", iconFor("src", true, false, false));
    try std.testing.expectEqualStrings("z", iconFor("main.zig", false, false, false));
    try std.testing.expectEqualStrings(".", iconFor("Makefile", false, false, false));
}
