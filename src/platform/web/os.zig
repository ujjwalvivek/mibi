//! The browser's operating system: a virtual filesystem held in the wasm
//! module's memory, plus the few host calls the editor needs (the clock and
//! stderr). There are no processes, no terminals and no real paths.
//!
//! Paths are absolute. A relative path is resolved against `/workspace`, which
//! is the editor's working directory. The host seeds `/syntax.d` and `/themes`
//! from the site, and may write `/workspace` files through the exported VFS
//! functions in `src/web_main.zig`.

const std = @import("std");
const heap = @import("heap.zig");

const allocator = heap.allocator;

pub const is_windows = false;
pub const STDIN: u32 = 0;
pub const STDOUT: u32 = 1;
pub const STDERR: u32 = 2;

/// The host's monotonic clock, in milliseconds.
extern "env" fn mibi_now_ms() f64;
/// Write to the host's console (used only by the panic path).
extern "env" fn mibi_write(fd: u32, ptr: [*]const u8, len: usize) void;
/// Leave the module. The host turns this into an exception or an overlay.
extern "env" fn mibi_exit(code: u32) noreturn;

const File = struct {
    data: []u8,
    stamp: u64,
};

var files: std.StringHashMap(File) = undefined;
var files_ready = false;
var dirs: std.StringHashMap(void) = undefined;
var dirs_ready = false;
var stamp_counter: u64 = 0;
var dirty = false;

/// Files written by the editor that a real folder still has to receive. The
/// host reads this list after a command or a keystroke and writes the files
/// back through the File System Access API.
var changed: std.StringHashMap(void) = undefined;
var changed_ready = false;

fn changedMap() *std.StringHashMap(void) {
    if (!changed_ready) {
        changed = std.StringHashMap(void).init(allocator);
        changed_ready = true;
    }
    return &changed;
}

fn markChanged(key: []const u8) !void {
    if (!std.mem.startsWith(u8, key, "/workspace/")) return;
    const m = changedMap();
    if (m.contains(key)) return;
    const copy = try allocator.dupe(u8, key);
    errdefer allocator.free(copy);
    try m.put(copy, {});
}

fn map() *std.StringHashMap(File) {
    if (!files_ready) {
        files = std.StringHashMap(File).init(allocator);
        files_ready = true;
    }
    return &files;
}

fn dirMap() *std.StringHashMap(void) {
    if (!dirs_ready) {
        dirs = std.StringHashMap(void).init(allocator);
        dirs_ready = true;
    }
    return &dirs;
}

/// Normalise `path` into `buf`: absolute, no `.`/`..`, no trailing slash.
fn canonicalInto(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len == 0 or buf.len == 0) return null;
    var n: usize = 0;
    if (path[0] == '/') {
        buf[0] = '/';
        n = 1;
    } else {
        const prefix = "/workspace";
        if (buf.len < prefix.len) return null;
        @memcpy(buf[0..prefix.len], prefix);
        n = prefix.len;
    }
    var i: usize = if (path[0] == '/') 1 else 0;
    while (i < path.len) {
        while (i < path.len and path[i] == '/') i += 1;
        if (i >= path.len) break;
        const start = i;
        while (i < path.len and path[i] != '/') i += 1;
        const seg = path[start..i];
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            while (n > 0 and buf[n - 1] != '/') n -= 1;
            if (n > 1) n -= 1;
            continue;
        }
        if (n > 0 and buf[n - 1] != '/') {
            if (n >= buf.len) return null;
            buf[n] = '/';
            n += 1;
        }
        if (n + seg.len > buf.len) return null;
        @memcpy(buf[n..][0..seg.len], seg);
        n += seg.len;
    }
    if (n == 0) {
        buf[0] = '/';
        n = 1;
    }
    return buf[0..n];
}

fn putDir(key: []const u8) !void {
    const m = dirMap();
    if (m.contains(key)) return;
    const copy = try allocator.dupe(u8, key);
    errdefer allocator.free(copy);
    try m.put(copy, {});
    dirty = true;
}

/// Add `path` and every parent directory. `path` itself is a directory.
fn addDir(path: []const u8) !void {
    try putDir("/");
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') try putDir(path[0..i]);
    }
    try putDir(path);
}

/// Add the parents of a file path, not the path itself.
fn addFileParents(path: []const u8) !void {
    try putDir("/");
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') try putDir(path[0..i]);
    }
}

/// Put a file into the virtual filesystem. Used by the host to seed the
/// language definitions, themes and imported files.
pub fn putFile(path: []const u8, data: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const key = canonicalInto(path, &buf) orelse return error.InvalidPath;
    try addFileParents(key);
    const m = map();
    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    const data_copy = try allocator.dupe(u8, data);
    errdefer allocator.free(data_copy);
    if (m.fetchRemove(key)) |old| {
        allocator.free(old.key);
        allocator.free(old.value.data);
    }
    stamp_counter += 1;
    try m.put(key_copy, .{ .data = data_copy, .stamp = stamp_counter });
    try markChanged(key);
    dirty = true;
}

/// A file's bytes, or null when it is missing. The slice is owned by the VFS.
pub fn getFile(path: []const u8) ?[]const u8 {
    var buf: [1024]u8 = undefined;
    const key = canonicalInto(path, &buf) orelse return null;
    const f = map().get(key) orelse return null;
    return f.data;
}

pub fn hasFile(path: []const u8) bool {
    return getFile(path) != null;
}

pub fn isDirty() bool {
    return dirty;
}

pub fn markClean() void {
    dirty = false;
}

fn isDirectoryKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (key.len == 1 and key[0] == '/') return true;
    if (map().contains(key)) return false;
    if (dirMap().contains(key)) return true;
    // A directory also exists if anything is stored under it.
    var it = map().keyIterator();
    while (it.next()) |kp| {
        const k = kp.*;
        if (k.len > key.len and std.mem.startsWith(u8, k, key) and k[key.len] == '/') return true;
    }
    return false;
}

pub fn isDirectory(path: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const key = canonicalInto(path, &buf) orelse return false;
    return isDirectoryKey(key);
}

pub fn readFileAlloc(allocator_: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    var buf: [1024]u8 = undefined;
    const key = canonicalInto(path, &buf) orelse return error.FileNotFound;
    const f = map().get(key) orelse {
        if (isDirectoryKey(key)) return error.IsDir;
        return error.FileNotFound;
    };
    if (f.data.len > max) return error.FileTooBig;
    return allocator_.dupe(u8, f.data);
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const key = canonicalInto(path, &buf) orelse return error.InvalidPath;
    if (isDirectoryKey(key)) return error.IsDir;
    try putFile(key, bytes);
}

pub fn writeFileAtomic(path: []const u8, bytes: []const u8) !void {
    try writeFile(path, bytes);
}

pub fn deleteFile(path: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const key = canonicalInto(path, &buf) orelse return;
    const m = map();
    if (m.fetchRemove(key)) |old| {
        allocator.free(old.key);
        allocator.free(old.value.data);
        try markChanged(key);
        dirty = true;
    }
}

pub fn makeDirAll(path: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const key = canonicalInto(path, &buf) orelse return error.InvalidPath;
    try addDir(key);
}

pub fn listDirNames(allocator_: std.mem.Allocator, path: []const u8, out: *std.ArrayList([]u8)) !void {
    var buf: [1024]u8 = undefined;
    const key = canonicalInto(path, &buf) orelse return error.OpenFailed;
    if (!isDirectoryKey(key)) return error.OpenFailed;

    // Files: take the next path segment after the directory.
    var it = map().keyIterator();
    while (it.next()) |kp| {
        const k = kp.*;
        var rest: []const u8 = undefined;
        if (key.len == 1 and key[0] == '/') {
            rest = k[1..];
        } else if (k.len > key.len and std.mem.startsWith(u8, k, key) and k[key.len] == '/') {
            rest = k[key.len + 1 ..];
        } else continue;
        if (rest.len == 0) continue;
        const name = if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest[0..slash] else rest;
        if (name.len == 0) continue;
        if (containsName(out.items, name)) continue;
        try out.append(allocator_, try allocator_.dupe(u8, name));
    }

    // Directories that exist but hold no files yet.
    var dit = dirMap().keyIterator();
    while (dit.next()) |kp| {
        const k = kp.*;
        var rest: []const u8 = undefined;
        if (key.len == 1 and key[0] == '/') {
            rest = k[1..];
        } else if (k.len > key.len and std.mem.startsWith(u8, k, key) and k[key.len] == '/') {
            rest = k[key.len + 1 ..];
        } else continue;
        if (rest.len == 0) continue;
        const name = if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest[0..slash] else rest;
        if (name.len == 0) continue;
        if (containsName(out.items, name)) continue;
        try out.append(allocator_, try allocator_.dupe(u8, name));
    }
}

fn containsName(items: []const []u8, name: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

pub fn sortStrings(items: [][]u8) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, items[j], items[j - 1])) : (j -= 1) {
            std.mem.swap([]u8, &items[j], &items[j - 1]);
        }
    }
}

pub fn listDirLine(allocator_: std.mem.Allocator, path: []const u8, out: *std.ArrayList(u8)) !void {
    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |n| allocator_.free(n);
        names.deinit(allocator_);
    }
    try listDirNames(allocator_, path, &names);
    sortStrings(names.items);
    for (names.items, 0..) |n, i| {
        if (i > 0) try out.append(allocator_, ' ');
        try out.appendSlice(allocator_, n);
    }
}

pub fn ticksMs() u64 {
    const ms = mibi_now_ms();
    if (!(ms > 0)) return 0;
    if (ms >= 18446744073709551615.0) return std.math.maxInt(u64);
    return @intFromFloat(ms);
}

pub fn write(fd: u32, bytes: []const u8) !usize {
    mibi_write(fd, bytes.ptr, bytes.len);
    return bytes.len;
}

pub fn writeAll(fd: u32, bytes: []const u8) !void {
    _ = try write(fd, bytes);
}

pub fn read(fd: u32, buf: []u8) !usize {
    _ = fd;
    _ = buf;
    return error.Unsupported;
}

pub fn exit(code: u8) noreturn {
    mibi_exit(code);
}

pub fn cwdAlloc(allocator_: std.mem.Allocator) ![]u8 {
    return allocator_.dupe(u8, "/workspace");
}

pub fn dataDirAlloc(allocator_: std.mem.Allocator) ![]u8 {
    return allocator_.dupe(u8, "/state");
}

pub fn exeDirAlloc(allocator_: std.mem.Allocator) ![]u8 {
    return allocator_.dupe(u8, "/");
}

pub fn exePathAlloc(allocator_: std.mem.Allocator) ![]u8 {
    return allocator_.dupe(u8, "/mibi");
}

pub fn getEnvAlloc(allocator_: std.mem.Allocator, name: []const u8) ![]u8 {
    _ = allocator_;
    _ = name;
    return error.EnvironmentVariableNotFound;
}

pub fn hasEnv(name: []const u8) bool {
    _ = name;
    return false;
}

pub fn fileStamp(path: []const u8) u64 {
    var buf: [1024]u8 = undefined;
    const key = canonicalInto(path, &buf) orelse return 0;
    const f = map().get(key) orelse return 0;
    return f.stamp;
}

pub const RunResult = struct {
    exit_code: i32 = -1,
    timed_out: bool = false,
};

/// There are no child processes in a browser. Formatters and the filter
/// command report this as a normal error, in the status line.
pub fn runCommand(
    allocator_: std.mem.Allocator,
    state_dir: []const u8,
    argv: []const []const u8,
    input: []const u8,
    out: *std.ArrayList(u8),
    timeout_ms: u32,
) !RunResult {
    _ = allocator_;
    _ = state_dir;
    _ = argv;
    _ = input;
    _ = out;
    _ = timeout_ms;
    return error.Unsupported;
}

pub fn inWindowsTerminal() bool {
    return false;
}

pub fn consoleProcessCount() u32 {
    return 0;
}

pub fn hideConsoleWindow() void {}

pub fn messageBox(text: []const u8, caption: []const u8) void {
    _ = text;
    _ = caption;
}

// --- persistence -------------------------------------------------------------

const magic = "MIBIVFS1";

fn skipPersist(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "/syntax.d/") or
        std.mem.startsWith(u8, key, "/themes/");
}

fn appendU32(out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(allocator, &b);
}

fn readU32(data: []const u8, i: *usize) ?u32 {
    if (i.* + 4 > data.len) return null;
    var b: [4]u8 = undefined;
    @memcpy(&b, data[i.*..][0..4]);
    i.* += 4;
    return std.mem.readInt(u32, &b, .little);
}

/// How many files the editor has written since the host last synced them.
pub fn changedCount() usize {
    return changedMap().count();
}

/// The i-th changed path, in no particular order. The slice is owned by the
/// changed set.
pub fn changedPathAt(index: usize) ?[]const u8 {
    var it = changedMap().keyIterator();
    var i: usize = 0;
    while (it.next()) |kp| {
        if (i == index) return kp.*;
        i += 1;
    }
    return null;
}

/// Forget the changed set. The host calls this after writing every path to
/// the real folder.
pub fn clearChanged() void {
    var it = changedMap().keyIterator();
    while (it.next()) |kp| allocator.free(kp.*);
    changedMap().clearRetainingCapacity();
}

/// Serialise the session (and optionally the workspace) for the host to keep
/// in local storage. With a real folder, the workspace is on disk and only
/// `/state` needs persisting.
pub fn serialize(out: *std.ArrayList(u8), include_workspace: bool) !void {
    try out.appendSlice(allocator, magic);
    var count: u32 = 0;
    var it = map().keyIterator();
    while (it.next()) |kp| {
        const key = kp.*;
        if (skipPersist(key)) continue;
        if (!include_workspace and std.mem.startsWith(u8, key, "/workspace/")) continue;
        count += 1;
    }
    try appendU32(out, count);
    it = map().keyIterator();
    while (it.next()) |kp| {
        const key = kp.*;
        if (skipPersist(key)) continue;
        if (!include_workspace and std.mem.startsWith(u8, key, "/workspace/")) continue;
        const f = map().get(key).?;
        try appendU32(out, @intCast(key.len));
        try out.appendSlice(allocator, key);
        try appendU32(out, @intCast(f.data.len));
        try out.appendSlice(allocator, f.data);
    }
}

pub fn deserialize(data: []const u8) !void {
    if (data.len < magic.len + 4 or !std.mem.eql(u8, data[0..magic.len], magic)) return error.BadData;
    var i: usize = magic.len;
    const count = readU32(data, &i) orelse return error.BadData;
    var n: u32 = 0;
    while (n < count) : (n += 1) {
        const path_len = readU32(data, &i) orelse return error.BadData;
        if (i + path_len > data.len) return error.BadData;
        const path = data[i..][0..path_len];
        i += path_len;
        const data_len = readU32(data, &i) orelse return error.BadData;
        if (i + data_len > data.len) return error.BadData;
        const body = data[i..][0..data_len];
        i += data_len;
        try putFile(path, body);
    }
}
