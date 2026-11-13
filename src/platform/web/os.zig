//! The browser's operating system: the platform interface of `../os.zig`,
//! implemented over one in-memory filesystem (`vfs.zig`) and three host
//! calls (the clock, the console and exit). There are no processes, no
//! terminals and no environment.
//!
//! Paths are absolute; a relative one is resolved against `/workspace`, the
//! editor's working directory. The host seeds `/syntax.d` and `/themes`, keeps
//! `/state` (the session) in browser storage, and fills `/workspace` from
//! imported files or a real folder, through the exports in `src/web_main.zig`.

const std = @import("std");
const heap = @import("heap.zig");
pub const vfs_mod = @import("vfs.zig");

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

var fs_state: ?vfs_mod.Vfs = null;

/// The one filesystem. Created on first use, so the host can seed it before
/// the editor starts.
pub fn vfs() *vfs_mod.Vfs {
    if (fs_state == null) fs_state = vfs_mod.Vfs.init(heap.allocator);
    return &fs_state.?;
}

// --- files -------------------------------------------------------------------

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const data = vfs().get(path) orelse {
        if (vfs().isDirectory(path)) return error.IsDir;
        return error.FileNotFound;
    };
    if (data.len > max) return error.FileTooBig;
    return allocator.dupe(u8, data);
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    try vfs().put(path, bytes, .editor);
}

/// Every write to the VFS is all or nothing already.
pub fn writeFileAtomic(path: []const u8, bytes: []const u8) !void {
    try writeFile(path, bytes);
}

/// A file that is already gone is not an error, as on native.
pub fn deleteFile(path: []const u8) !void {
    _ = try vfs().remove(path, .editor);
}

pub fn fileStamp(path: []const u8) u64 {
    return vfs().stamp(path);
}

pub fn isDirectory(path: []const u8) bool {
    return vfs().isDirectory(path);
}

pub fn makeDirAll(path: []const u8) !void {
    try vfs().makeDirAll(path);
}

/// Append the names of the entries in `path` to `out` (caller frees each).
pub fn listDirNames(allocator: std.mem.Allocator, path: []const u8, out: *std.ArrayList([]u8)) !void {
    vfs().list(allocator, path, out) catch |err| return switch (err) {
        error.FileNotFound => error.OpenFailed,
        else => err,
    };
}

/// Insertion sort, as native: `std.mem.sort` costs more bytes than these
/// small lists are worth.
pub fn sortStrings(items: [][]u8) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, items[j], items[j - 1])) : (j -= 1) {
            std.mem.swap([]u8, &items[j], &items[j - 1]);
        }
    }
}

/// One line of directory entries, sorted and space-separated (like `ls`).
pub fn listDirLine(allocator: std.mem.Allocator, path: []const u8, out: *std.ArrayList(u8)) !void {
    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    try listDirNames(allocator, path, &names);
    sortStrings(names.items);
    for (names.items, 0..) |n, i| {
        if (i > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, n);
    }
}

// --- the process -------------------------------------------------------------

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

/// Input arrives through `mibi_input`, never by reading.
pub fn read(fd: u32, buf: []u8) !usize {
    _ = fd;
    _ = buf;
    return error.Unsupported;
}

pub fn exit(code: u8) noreturn {
    mibi_exit(code);
}

pub fn cwdAlloc(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, vfs_mod.workspace);
}

pub fn dataDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "/state");
}

pub fn exeDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "/");
}

pub fn exePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "/mibi");
}

pub fn getEnvAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    _ = allocator;
    _ = name;
    return error.EnvironmentVariableNotFound;
}

pub fn hasEnv(name: []const u8) bool {
    _ = name;
    return false;
}

pub const RunResult = struct {
    exit_code: i32 = -1,
    timed_out: bool = false,
};

/// There are no child processes in a browser. Formatters and the filter
/// report this as an ordinary error in the status line.
pub fn runCommand(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    argv: []const []const u8,
    input: []const u8,
    out: *std.ArrayList(u8),
    timeout_ms: u32,
) !RunResult {
    _ = allocator;
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
