//! The browser's filesystem: files held in the wasm module's memory, keyed by
//! absolute path. Nothing in this file calls the host, so it builds and is
//! tested natively (`zig build test-web`); `os.zig` wraps one instance of it
//! behind the platform interface.
//!
//! Writes come from two sides, and the difference matters:
//!
//!   .editor  a save, the session, `mibi.ini`. With a real folder attached,
//!            the path is recorded so the host can write it back.
//!   .host    the host seeding assets, importing files, or following a real
//!            folder. Never recorded: it is already where it came from.
//!
//! Every write that changes a file's bytes gives it a new stamp, which is how
//! the editor's `refreshFromDisk` notices a file changed underneath it.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The editor's working directory. Relative paths are resolved against it.
pub const workspace = "/workspace";
/// Longest path accepted, after normalisation.
pub const max_path = 4096;

pub const Origin = enum { editor, host };

const File = struct {
    data: []u8,
    stamp: u64,
};

pub const Vfs = struct {
    allocator: Allocator,
    files: std.StringHashMap(File),
    /// Every directory that exists: each file's parents, plus directories made
    /// explicitly. A directory outlives its files, as on a real disk.
    dirs: std.StringHashMap(void),
    /// Workspace paths the editor wrote or deleted since the host last took
    /// them. Only kept while `track` is on (a real folder is attached).
    changed: std.StringHashMap(void),
    track: bool = false,
    stamp_counter: u64 = 0,
    /// Something persisted (not an asset) changed since `markClean`.
    dirty: bool = false,

    pub fn init(allocator: Allocator) Vfs {
        return .{
            .allocator = allocator,
            .files = std.StringHashMap(File).init(allocator),
            .dirs = std.StringHashMap(void).init(allocator),
            .changed = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Vfs) void {
        var it = self.files.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.data);
        }
        self.files.deinit();
        freeKeys(self.allocator, &self.dirs);
        self.dirs.deinit();
        freeKeys(self.allocator, &self.changed);
        self.changed.deinit();
        self.* = undefined;
    }

    // --- files -------------------------------------------------------------

    /// Create or replace a file. Writing the bytes a file already has is not
    /// a change: the stamp stays, so the editor does not reload for nothing.
    pub fn put(self: *Vfs, path: []const u8, data: []const u8, origin: Origin) !void {
        var buf: [max_path]u8 = undefined;
        const key = canonical(path, &buf) orelse return error.NameTooLong;
        if (key.len == 1) return error.IsDir;
        if (self.dirs.contains(key)) return error.IsDir;
        try self.checkParents(key);

        if (self.files.getPtr(key)) |f| {
            if (std.mem.eql(u8, f.data, data)) return;
            const copy = try self.allocator.dupe(u8, data);
            self.allocator.free(f.data);
            f.data = copy;
            f.stamp = self.nextStamp();
        } else {
            try self.addParents(key);
            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);
            const copy = try self.allocator.dupe(u8, data);
            errdefer self.allocator.free(copy);
            try self.files.put(key_copy, .{ .data = copy, .stamp = self.nextStamp() });
        }
        try self.touched(key, origin);
    }

    /// Remove a file. Returns false when there was nothing to remove.
    pub fn remove(self: *Vfs, path: []const u8, origin: Origin) !bool {
        var buf: [max_path]u8 = undefined;
        const key = canonical(path, &buf) orelse return false;
        const old = self.files.fetchRemove(key) orelse return false;
        defer self.allocator.free(old.key);
        defer self.allocator.free(old.value.data);
        try self.touched(key, origin);
        return true;
    }

    /// Remove a directory and everything under it. Only the host does this,
    /// when a real folder lost a directory.
    pub fn removeTree(self: *Vfs, path: []const u8) void {
        var buf: [max_path]u8 = undefined;
        const key = canonical(path, &buf) orelse return;
        if (key.len == 1) return;
        removeUnder(self.allocator, File, &self.files, key, freeFile);
        removeUnder(self.allocator, void, &self.dirs, key, null);
        if (!isPersisted(key)) return;
        self.dirty = true;
    }

    /// A file's bytes, owned by the VFS; null when there is no such file.
    pub fn get(self: *const Vfs, path: []const u8) ?[]const u8 {
        var buf: [max_path]u8 = undefined;
        const key = canonical(path, &buf) orelse return null;
        const f = self.files.get(key) orelse return null;
        return f.data;
    }

    /// Changes whenever the file's bytes do; 0 when there is no such file.
    pub fn stamp(self: *const Vfs, path: []const u8) u64 {
        var buf: [max_path]u8 = undefined;
        const key = canonical(path, &buf) orelse return 0;
        const f = self.files.get(key) orelse return 0;
        return f.stamp;
    }

    // --- directories -------------------------------------------------------

    pub fn isDirectory(self: *const Vfs, path: []const u8) bool {
        var buf: [max_path]u8 = undefined;
        const key = canonical(path, &buf) orelse return false;
        return key.len == 1 or self.dirs.contains(key);
    }

    pub fn makeDirAll(self: *Vfs, path: []const u8) !void {
        var buf: [max_path]u8 = undefined;
        const key = canonical(path, &buf) orelse return error.NameTooLong;
        if (key.len == 1) return;
        if (self.files.contains(key)) return error.NotDir;
        try self.checkParents(key);
        try self.addParents(key);
        try self.addDir(key);
    }

    /// The names directly inside `path`, files and directories, unsorted.
    /// Each name is allocated with `allocator`.
    pub fn list(self: *const Vfs, allocator: Allocator, path: []const u8, out: *std.ArrayList([]u8)) !void {
        var buf: [max_path]u8 = undefined;
        const key = canonical(path, &buf) orelse return error.FileNotFound;
        if (!self.isDirectory(key)) return error.FileNotFound;
        var fit = self.files.keyIterator();
        while (fit.next()) |k| try addChildName(allocator, key, k.*, out);
        var dit = self.dirs.keyIterator();
        while (dit.next()) |k| try addChildName(allocator, key, k.*, out);
    }

    // --- changes for a real folder -------------------------------------------

    /// Start or stop recording the editor's workspace writes. Stopping forgets
    /// what was recorded.
    pub fn setTracking(self: *Vfs, on: bool) void {
        self.track = on;
        if (!on) self.clearChanged();
    }

    /// Hand the recorded paths to the host and forget them, as one
    /// newline-separated list appended to `out`. A path the host fails to
    /// write goes back with `markChanged`.
    pub fn takeChanged(self: *Vfs, out: *std.ArrayList(u8)) !void {
        var it = self.changed.keyIterator();
        var first = true;
        while (it.next()) |k| {
            if (!first) try out.append(self.allocator, '\n');
            try out.appendSlice(self.allocator, k.*);
            first = false;
        }
        self.clearChanged();
    }

    pub fn markChanged(self: *Vfs, path: []const u8) !void {
        var buf: [max_path]u8 = undefined;
        const key = canonical(path, &buf) orelse return error.NameTooLong;
        try self.record(key);
    }

    pub fn changedCount(self: *const Vfs) usize {
        return self.changed.count();
    }

    fn clearChanged(self: *Vfs) void {
        freeKeys(self.allocator, &self.changed);
        self.changed.clearRetainingCapacity();
    }

    // --- persistence -------------------------------------------------------

    pub const magic = "MIBIVFS1";

    /// Write every persisted file (not the seeded assets) as
    /// `magic, count, { path_len, path, data_len, data }*`, little-endian
    /// u32s. Without `include_workspace` only `/state` and the like go out:
    /// a real folder's files already live on disk.
    pub fn serialize(self: *const Vfs, out: *std.ArrayList(u8), include_workspace: bool) !void {
        try out.appendSlice(self.allocator, magic);
        const count_at = out.items.len;
        try appendU32(self.allocator, out, 0);
        var count: u32 = 0;
        var it = self.files.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (!isPersisted(key)) continue;
            if (!include_workspace and inWorkspace(key)) continue;
            try appendU32(self.allocator, out, @intCast(key.len));
            try out.appendSlice(self.allocator, key);
            try appendU32(self.allocator, out, @intCast(e.value_ptr.data.len));
            try out.appendSlice(self.allocator, e.value_ptr.data);
            count += 1;
        }
        std.mem.writeInt(u32, out.items[count_at..][0..4], count, .little);
    }

    /// Load what `serialize` wrote. The data is checked whole before any of
    /// it is applied, so a truncated blob changes nothing.
    pub fn deserialize(self: *Vfs, data: []const u8) !void {
        var r: Reader = .{ .data = data };
        const count = try r.header();
        var n: u32 = 0;
        while (n < count) : (n += 1) _ = try r.entry();
        if (r.i != data.len) return error.BadData;

        r = .{ .data = data };
        _ = try r.header();
        n = 0;
        while (n < count) : (n += 1) {
            const e = try r.entry();
            try self.put(e.path, e.body, .host);
        }
    }

    pub fn markClean(self: *Vfs) void {
        self.dirty = false;
    }

    // --- internals -----------------------------------------------------------

    fn nextStamp(self: *Vfs) u64 {
        self.stamp_counter += 1;
        return self.stamp_counter;
    }

    fn touched(self: *Vfs, key: []const u8, origin: Origin) !void {
        if (isPersisted(key)) self.dirty = true;
        if (origin == .editor) try self.record(key);
    }

    fn record(self: *Vfs, key: []const u8) !void {
        if (!self.track or !inWorkspace(key) or self.changed.contains(key)) return;
        const copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(copy);
        try self.changed.put(copy, {});
    }

    /// A path cannot run through a file: `/a/b` fails when `/a` is a file.
    fn checkParents(self: *const Vfs, key: []const u8) !void {
        var i: usize = 1;
        while (i < key.len) : (i += 1) {
            if (key[i] == '/' and self.files.contains(key[0..i])) return error.NotDir;
        }
    }

    fn addParents(self: *Vfs, key: []const u8) !void {
        var i: usize = 1;
        while (i < key.len) : (i += 1) {
            if (key[i] == '/') try self.addDir(key[0..i]);
        }
    }

    fn addDir(self: *Vfs, key: []const u8) !void {
        if (self.dirs.contains(key)) return;
        const copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(copy);
        try self.dirs.put(copy, {});
    }
};

/// Normalise `path` into `buf`: absolute, no `.` or `..`, no repeated or
/// trailing slash. A relative path starts at `/workspace`; `..` stops at the
/// root. Null when the result does not fit or the path is empty.
pub fn canonical(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len == 0 or buf.len < workspace.len) return null;
    var n: usize = 0;
    if (path[0] != '/') {
        @memcpy(buf[0..workspace.len], workspace);
        n = workspace.len;
    }
    var segments = std.mem.tokenizeScalar(u8, path, '/');
    while (segments.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            while (n > 0 and buf[n - 1] != '/') n -= 1;
            if (n > 0) n -= 1;
            continue;
        }
        if (n + 1 + seg.len > buf.len) return null;
        buf[n] = '/';
        @memcpy(buf[n + 1 ..][0..seg.len], seg);
        n += 1 + seg.len;
    }
    if (n == 0) {
        buf[0] = '/';
        n = 1;
    }
    return buf[0..n];
}

/// The seeded language definitions and themes come from the site on every
/// load; they are never stored.
fn isPersisted(key: []const u8) bool {
    return !(std.mem.startsWith(u8, key, "/syntax.d/") or std.mem.startsWith(u8, key, "/themes/"));
}

fn inWorkspace(key: []const u8) bool {
    return key.len > workspace.len + 1 and std.mem.startsWith(u8, key, workspace) and key[workspace.len] == '/';
}

/// If `key` is strictly inside `dir`, add its first component below `dir`.
fn addChildName(allocator: Allocator, dir: []const u8, key: []const u8, out: *std.ArrayList([]u8)) !void {
    const rest = if (dir.len == 1)
        key[1..]
    else if (key.len > dir.len + 1 and std.mem.startsWith(u8, key, dir) and key[dir.len] == '/')
        key[dir.len + 1 ..]
    else
        return;
    if (rest.len == 0) return;
    const name = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
    for (out.items) |item| {
        if (std.mem.eql(u8, item, name)) return;
    }
    const copy = try allocator.dupe(u8, name);
    errdefer allocator.free(copy);
    try out.append(allocator, copy);
}

fn freeKeys(allocator: Allocator, map: *std.StringHashMap(void)) void {
    var it = map.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
}

fn freeFile(allocator: Allocator, f: File) void {
    allocator.free(f.data);
}

/// Remove `dir` and every key below it from `map`.
fn removeUnder(
    allocator: Allocator,
    comptime V: type,
    map: *std.StringHashMap(V),
    dir: []const u8,
    comptime free_value: ?fn (Allocator, V) void,
) void {
    while (true) {
        var victim: ?[]const u8 = null;
        var it = map.keyIterator();
        while (it.next()) |k| {
            const key = k.*;
            if (std.mem.eql(u8, key, dir) or
                (key.len > dir.len and std.mem.startsWith(u8, key, dir) and key[dir.len] == '/'))
            {
                victim = key;
                break;
            }
        }
        const key = victim orelse return;
        const old = map.fetchRemove(key).?;
        if (free_value) |f| f(allocator, old.value);
        allocator.free(old.key);
    }
}

fn appendU32(allocator: Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(allocator, &b);
}

const Reader = struct {
    data: []const u8,
    i: usize = 0,

    fn header(r: *Reader) !u32 {
        if (r.data.len < Vfs.magic.len or !std.mem.eql(u8, r.data[0..Vfs.magic.len], Vfs.magic)) return error.BadData;
        r.i = Vfs.magic.len;
        return r.u32le();
    }

    fn entry(r: *Reader) !struct { path: []const u8, body: []const u8 } {
        const path = try r.bytes();
        const body = try r.bytes();
        return .{ .path = path, .body = body };
    }

    fn bytes(r: *Reader) ![]const u8 {
        const len = try r.u32le();
        if (len > r.data.len - r.i) return error.BadData;
        defer r.i += len;
        return r.data[r.i..][0..len];
    }

    fn u32le(r: *Reader) !u32 {
        if (r.data.len - r.i < 4) return error.BadData;
        defer r.i += 4;
        return std.mem.readInt(u32, r.data[r.i..][0..4], .little);
    }
};

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn expectCanonical(want: ?[]const u8, path: []const u8) !void {
    var buf: [64]u8 = undefined;
    const got = canonical(path, &buf);
    if (want) |w| try testing.expectEqualStrings(w, got.?) else try testing.expect(got == null);
}

test "paths are absolute and normalised, relative ones start in the workspace" {
    try expectCanonical("/workspace/a.txt", "a.txt");
    try expectCanonical("/workspace/src/a.zig", "./src//a.zig/");
    try expectCanonical("/a", "/workspace/../../a");
    try expectCanonical("/", "/..");
    try expectCanonical("/", "/");
    try expectCanonical("/workspace", ".");
    try expectCanonical(null, "");
    try expectCanonical(null, "/" ++ "x" ** 80);
}

test "put, get and stamps: same bytes keep the stamp, new bytes change it" {
    var v = Vfs.init(testing.allocator);
    defer v.deinit();
    try v.put("a.txt", "one", .editor);
    try testing.expectEqualStrings("one", v.get("/workspace/a.txt").?);
    const s1 = v.stamp("a.txt");
    try testing.expect(s1 != 0);
    try v.put("a.txt", "one", .host);
    try testing.expectEqual(s1, v.stamp("a.txt"));
    try v.put("a.txt", "two", .host);
    try testing.expect(v.stamp("a.txt") != s1);
    try testing.expectEqual(@as(u64, 0), v.stamp("missing"));
    try testing.expect(v.get("missing") == null);
}

test "directories come from file parents and outlive their files" {
    var v = Vfs.init(testing.allocator);
    defer v.deinit();
    try v.put("/workspace/src/core/a.zig", "", .editor);
    try testing.expect(v.isDirectory("/workspace/src"));
    try testing.expect(v.isDirectory("/workspace/src/core"));
    try testing.expect(!v.isDirectory("/workspace/src/core/a.zig"));
    try testing.expect(try v.remove("/workspace/src/core/a.zig", .editor));
    try testing.expect(!try v.remove("/workspace/src/core/a.zig", .editor));
    try testing.expect(v.isDirectory("/workspace/src/core"));
    try testing.expectError(error.IsDir, v.put("/workspace/src", "x", .editor));
    try testing.expectError(error.IsDir, v.put("/", "x", .editor));
    try v.put("/workspace/file", "", .editor);
    try testing.expectError(error.NotDir, v.put("/workspace/file/inner", "", .editor));
    try testing.expectError(error.NotDir, v.makeDirAll("/workspace/file"));
}

test "listing gives each child once, files and directories" {
    var v = Vfs.init(testing.allocator);
    defer v.deinit();
    try v.put("/workspace/b.txt", "", .host);
    try v.put("/workspace/src/a.zig", "", .host);
    try v.put("/workspace/src/b.zig", "", .host);
    try v.makeDirAll("/workspace/empty/deep");
    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |n| testing.allocator.free(n);
        names.deinit(testing.allocator);
    }
    try v.list(testing.allocator, "/workspace", &names);
    std.mem.sort([]u8, names.items, {}, lessThan);
    try testing.expectEqual(@as(usize, 3), names.items.len);
    try testing.expectEqualStrings("b.txt", names.items[0]);
    try testing.expectEqualStrings("empty", names.items[1]);
    try testing.expectEqualStrings("src", names.items[2]);
    try testing.expectError(error.FileNotFound, v.list(testing.allocator, "/workspace/b.txt", &names));
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "only the editor's workspace writes are recorded, and only while tracking" {
    var v = Vfs.init(testing.allocator);
    defer v.deinit();
    try v.put("/workspace/untracked.txt", "x", .editor);
    try testing.expectEqual(@as(usize, 0), v.changedCount());

    v.setTracking(true);
    try v.put("/workspace/from-disk.txt", "x", .host);
    try v.put("/state/session", "x", .editor);
    try v.put("/workspace/saved.txt", "x", .editor);
    try v.put("/workspace/saved.txt", "y", .editor);
    _ = try v.remove("/workspace/untracked.txt", .editor);
    try testing.expectEqual(@as(usize, 2), v.changedCount());

    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    try v.takeChanged(&out);
    try testing.expectEqual(@as(usize, 0), v.changedCount());
    var lines = std.mem.splitScalar(u8, out.items, '\n');
    var seen: usize = 0;
    while (lines.next()) |line| {
        try testing.expect(std.mem.eql(u8, line, "/workspace/saved.txt") or
            std.mem.eql(u8, line, "/workspace/untracked.txt"));
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 2), seen);

    try v.markChanged("saved.txt");
    try testing.expectEqual(@as(usize, 1), v.changedCount());
    v.setTracking(false);
    try testing.expectEqual(@as(usize, 0), v.changedCount());
}

test "removing a tree takes its files and directories" {
    var v = Vfs.init(testing.allocator);
    defer v.deinit();
    try v.put("/workspace/gone/a.txt", "", .host);
    try v.put("/workspace/gone/deep/b.txt", "", .host);
    try v.put("/workspace/gone2/c.txt", "", .host);
    v.removeTree("/workspace/gone");
    try testing.expect(v.get("/workspace/gone/a.txt") == null);
    try testing.expect(v.get("/workspace/gone/deep/b.txt") == null);
    try testing.expect(!v.isDirectory("/workspace/gone/deep"));
    try testing.expect(!v.isDirectory("/workspace/gone"));
    try testing.expect(v.get("/workspace/gone2/c.txt") != null);
}

test "serialise and restore, with or without the workspace, never the assets" {
    var v = Vfs.init(testing.allocator);
    defer v.deinit();
    try v.put("/syntax.d/zig.ini", "asset", .host);
    try v.put("/workspace/a.txt", "alpha", .editor);
    try v.put("/state/session", "tabs", .editor);
    try v.put("/workspace/empty.txt", "", .editor);

    var all = std.ArrayList(u8).empty;
    defer all.deinit(testing.allocator);
    try v.serialize(&all, true);
    var state = std.ArrayList(u8).empty;
    defer state.deinit(testing.allocator);
    try v.serialize(&state, false);

    var w = Vfs.init(testing.allocator);
    defer w.deinit();
    try w.deserialize(all.items);
    try testing.expectEqualStrings("alpha", w.get("/workspace/a.txt").?);
    try testing.expectEqualStrings("", w.get("/workspace/empty.txt").?);
    try testing.expectEqualStrings("tabs", w.get("/state/session").?);
    try testing.expect(w.get("/syntax.d/zig.ini") == null);

    var s = Vfs.init(testing.allocator);
    defer s.deinit();
    try s.deserialize(state.items);
    try testing.expect(s.get("/workspace/a.txt") == null);
    try testing.expectEqualStrings("tabs", s.get("/state/session").?);
}

test "a damaged blob is refused whole" {
    var v = Vfs.init(testing.allocator);
    defer v.deinit();
    try v.put("/state/a", "one", .editor);
    try v.put("/state/b", "two", .editor);
    var blob = std.ArrayList(u8).empty;
    defer blob.deinit(testing.allocator);
    try v.serialize(&blob, true);

    var w = Vfs.init(testing.allocator);
    defer w.deinit();
    try testing.expectError(error.BadData, w.deserialize(blob.items[0 .. blob.items.len - 1]));
    try testing.expectError(error.BadData, w.deserialize("NOTMIBI!\x00\x00\x00\x00"));
    try testing.expectError(error.BadData, w.deserialize("MIBI"));
    try testing.expectEqual(@as(usize, 0), w.files.count());
    // A count that promises more entries than there are bytes.
    var lying = try testing.allocator.dupe(u8, blob.items);
    defer testing.allocator.free(lying);
    std.mem.writeInt(u32, lying[Vfs.magic.len..][0..4], 3, .little);
    try testing.expectError(error.BadData, w.deserialize(lying));
    try testing.expectEqual(@as(usize, 0), w.files.count());
}

test "persisting is needed after user data changes, not after seeding assets" {
    var v = Vfs.init(testing.allocator);
    defer v.deinit();
    try v.put("/themes/dark.ini", "x", .host);
    try testing.expect(!v.dirty);
    try v.put("/state/session", "x", .editor);
    try testing.expect(v.dirty);
    v.markClean();
    try v.put("/state/session", "x", .editor);
    try testing.expect(!v.dirty);
}
