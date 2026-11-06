//! Minimal platform layer for mibi.
//!
//! Deliberately avoids `std.Io.Threaded`: pulling in the async/threading
//! runtime costs ~480 KB, which is most of the budget. A terminal editor only
//! needs blocking reads and writes, so we call the OS directly.
//!
//! Unix uses libc (`std.c`); Windows uses kernel32 through our own `extern`
//! declarations, since Zig's std does not expose the console API.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

pub const STDIN: u32 = 0;
pub const STDOUT: u32 = 1;
pub const STDERR: u32 = 2;

const win = struct {
    const HANDLE = std.os.windows.HANDLE;
    const DWORD = u32;

    extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn ExitProcess(uExitCode: DWORD) callconv(.winapi) noreturn;
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: *DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: *DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) c_int;
    extern "kernel32" fn FindFirstFileW(
        lpFileName: [*:0]const u16,
        lpFindFileData: *WIN32_FIND_DATAW,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn FindNextFileW(hFindFile: HANDLE, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) c_int;
    extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.winapi) c_int;
    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
    extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) c_int;
    extern "kernel32" fn GetModuleFileNameW(hModule: ?HANDLE, lpFilename: [*]u16, nSize: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: [*]u16, nSize: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) DWORD;
    extern "kernel32" fn GetConsoleProcessList(lProcessList: [*]DWORD, dwProcessCount: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "user32" fn MessageBoxW(hWnd: ?*anyopaque, lpText: [*:0]const u16, lpCaption: [*:0]const u16, uType: c_uint) callconv(.winapi) c_int;
    extern "user32" fn ShowWindow(hWnd: ?*anyopaque, nCmdShow: c_int) callconv(.winapi) c_int;


    const FILETIME = extern struct { dwLowDateTime: u32, dwHighDateTime: u32 };
    const WIN32_FIND_DATAW = extern struct {
        dwFileAttributes: u32,
        ftCreationTime: FILETIME,
        ftLastAccessTime: FILETIME,
        ftLastWriteTime: FILETIME,
        nFileSizeHigh: u32,
        nFileSizeLow: u32,
        dwReserved0: u32,
        dwReserved1: u32,
        cFileName: [260]u16,
        cAlternateFileName: [14]u16,
    };

    const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
    const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
    const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));

    const GENERIC_READ: DWORD = 0x80000000;
    const GENERIC_WRITE: DWORD = 0x40000000;
    const FILE_SHARE_READ: DWORD = 0x00000001;
    const OPEN_EXISTING: DWORD = 3;
    const CREATE_ALWAYS: DWORD = 2;
    const FILE_ATTRIBUTE_NORMAL: DWORD = 0x00000080;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

    const ERROR_FILE_NOT_FOUND: DWORD = 2;
    const ERROR_PATH_NOT_FOUND: DWORD = 3;
    const ERROR_ACCESS_DENIED: DWORD = 5;

    fn handle(fd: u32) ?HANDLE {
        return switch (fd) {
            STDIN => GetStdHandle(STD_INPUT_HANDLE),
            STDOUT => GetStdHandle(STD_OUTPUT_HANDLE),
            else => GetStdHandle(STD_ERROR_HANDLE),
        };
    }

    /// Map a failed CreateFileW/WriteFile to a meaningful error.
    fn lastError() anyerror {
        return switch (GetLastError()) {
            ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => error.FileNotFound,
            ERROR_ACCESS_DENIED => error.AccessDenied,
            else => error.OpenFailed,
        };
    }
};

/// Write all of `bytes` to `fd`. Returns the number of bytes written.
/// Monotonic milliseconds (since boot on Windows, since an arbitrary point on
/// Unix). Used for the autosave timer; `std.time` has no clock in Zig 0.16.
pub fn ticksMs() u64 {
    if (is_windows) return win.GetTickCount64();
    var ts: std.posix.timespec = undefined;
    if (std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub fn write(fd: u32, bytes: []const u8) !usize {
    if (is_windows) {
        var n: u32 = 0;
        const h = win.handle(fd) orelse return error.NoHandle;
        if (win.WriteFile(h, bytes.ptr, @intCast(bytes.len), &n, null) == 0) return error.WriteFailed;
        return n;
    } else {
        const rc = std.c.write(@intCast(fd), bytes.ptr, bytes.len);
        if (rc < 0) return error.WriteFailed;
        return @intCast(rc);
    }
}

/// Write all of `bytes`, looping over short writes.
pub fn writeAll(fd: u32, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) i += try write(fd, bytes[i..]);
}

/// Read up to `buf.len` bytes from `fd`. Returns the number read.
pub fn read(fd: u32, buf: []u8) !usize {
    if (is_windows) {
        var n: u32 = 0;
        const h = win.handle(fd) orelse return error.NoHandle;
        if (win.ReadFile(h, buf.ptr, @intCast(buf.len), &n, null) == 0) return error.ReadFailed;
        return n;
    } else {
        const rc = std.c.read(@intCast(fd), buf.ptr, buf.len);
        if (rc < 0) return error.ReadFailed;
        return @intCast(rc);
    }
}

/// Terminate the process with `code`.
pub fn exit(code: u8) noreturn {
    if (is_windows) {
        win.ExitProcess(code);
    } else {
        std.c.exit(code);
    }
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

/// Read a whole file into a newly allocated buffer. Fails past `max` bytes.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    if (is_windows) {
        const wpath = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        defer allocator.free(wpath);
        const h = win.CreateFileW(
            wpath.ptr,
            win.GENERIC_READ,
            win.FILE_SHARE_READ,
            null,
            win.OPEN_EXISTING,
            win.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (h == win.INVALID_HANDLE_VALUE) return win.lastError();
        defer _ = win.CloseHandle(h);
        return readAllWindows(allocator, h, max);
    } else {
        const z = try allocator.dupeZ(u8, path);
        defer allocator.free(z);
        const fd = std.c.open(z.ptr, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
        if (fd < 0) return openError(fd);
        defer _ = std.c.close(fd);
        return readAllUnix(allocator, fd, max);
    }
}

/// Map a failed `open` to the errors callers care about.
fn openError(rc: c_int) anyerror {
    if (is_windows) return error.OpenFailed;
    return switch (std.c.errno(rc)) {
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .ISDIR => error.IsDir,
        else => error.OpenFailed,
    };
}

fn readAllUnix(allocator: std.mem.Allocator, fd: i32, max: usize) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..@intCast(n)]);
        if (list.items.len > max) return error.FileTooBig;
    }
    return list.toOwnedSlice(allocator);
}

fn readAllWindows(allocator: std.mem.Allocator, h: win.HANDLE, max: usize) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        if (win.ReadFile(h, &buf, buf.len, &n, null) == 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
        if (list.items.len > max) return error.FileTooBig;
    }
    return list.toOwnedSlice(allocator);
}

/// Write `bytes` to `path`, creating or truncating it.
pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    if (is_windows) {
        const wpath = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path);
        defer std.heap.page_allocator.free(wpath);
        const h = win.CreateFileW(
            wpath.ptr,
            win.GENERIC_WRITE,
            0,
            null,
            win.CREATE_ALWAYS,
            win.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (h == win.INVALID_HANDLE_VALUE) return win.lastError();
        defer _ = win.CloseHandle(h);
        var i: usize = 0;
        while (i < bytes.len) {
            var n: u32 = 0;
            if (win.WriteFile(h, bytes[i..].ptr, @intCast(bytes.len - i), &n, null) == 0) return error.WriteFailed;
            if (n == 0) return error.WriteFailed;
            i += n;
        }
    } else {
        const z = try std.heap.page_allocator.dupeZ(u8, path);
        defer std.heap.page_allocator.free(z);
        const fd = std.c.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
        if (fd < 0) return openError(fd);
        defer _ = std.c.close(fd);
        var i: usize = 0;
        while (i < bytes.len) {
            const n = std.c.write(fd, bytes[i..].ptr, bytes.len - i);
            if (n <= 0) return error.WriteFailed;
            i += @intCast(n);
        }
    }
}

const macos = struct {
    extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;
};

fn dirnameAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const i = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return allocator.dupe(u8, ".");
    return allocator.dupe(u8, path[0..i]);
}

/// Full path of the running executable.
pub fn exePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    if (is_windows) {
        var buf: [4096]u16 = undefined;
        const n = win.GetModuleFileNameW(null, &buf, @intCast(buf.len));
        if (n == 0 or n >= buf.len) return error.ExePathFailed;
        return std.unicode.utf16LeToUtf8Alloc(allocator, buf[0..n]);
    }
    if (builtin.os.tag == .linux) {
        var buf: [4096]u8 = undefined;
        const n = std.c.readlink("/proc/self/exe", &buf, buf.len);
        if (n <= 0) return error.ExePathFailed;
        return allocator.dupe(u8, buf[0..@intCast(n)]);
    }
    if (builtin.os.tag == .macos) {
        var buf: [4096]u8 = undefined;
        var size: u32 = buf.len;
        if (macos._NSGetExecutablePath(&buf, &size) != 0) return error.ExePathFailed;
        return allocator.dupe(u8, std.mem.sliceTo(&buf, 0));
    }
    return error.ExePathFailed;
}

/// Directory holding the running executable (no trailing separator).
pub fn exeDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    const path = try exePathAlloc(allocator);
    defer allocator.free(path);
    return dirnameAlloc(allocator, path);
}

/// Whether an environment variable exists. Used to detect Windows Terminal
/// (it sets WT_SESSION in everything it hosts).
pub fn hasEnv(name: []const u8) bool {
    if (is_windows) {
        const wname = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, name) catch return false;
        defer std.heap.page_allocator.free(wname);
        var buf: [4]u16 = undefined;
        return win.GetEnvironmentVariableW(wname.ptr, &buf, buf.len) != 0;
    }
    return false;
}

/// True when the process was started by Windows Terminal (or on a platform
/// where the launcher owns the window, so there is nothing to hand off).
pub fn inWindowsTerminal() bool {
    if (is_windows) return hasEnv("WT_SESSION");
    return true;
}

/// True when `path` names a directory.
pub fn isDirectory(path: []const u8) bool {
    if (is_windows) {
        const wpath = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path) catch return false;
        defer std.heap.page_allocator.free(wpath);
        const attrs = win.GetFileAttributesW(wpath.ptr);
        if (attrs == 0xFFFFFFFF) return false; // INVALID_FILE_ATTRIBUTES
        return (attrs & 0x10) != 0; // FILE_ATTRIBUTE_DIRECTORY
    }
    const z = std.heap.page_allocator.dupeZ(u8, path) catch return false;
    defer std.heap.page_allocator.free(z);
    const dir = std.c.opendir(z.ptr) orelse return false;
    defer _ = std.c.closedir(dir);
    return true;
}

/// How many processes share this console. One means the console window was
/// created just for us (a double-click or a shortcut), not a real terminal.
pub fn consoleProcessCount() u32 {
    if (is_windows) {
        var pids: [4]win.DWORD = undefined;
        return win.GetConsoleProcessList(&pids, pids.len);
    }
    return 2; // Unix terminals always have a shell attached
}

/// Hide our own console window (the flash before the message box).
pub fn hideConsoleWindow() void {
    if (is_windows) {
        if (win.GetConsoleWindow()) |hwnd| _ = win.ShowWindow(hwnd, 0); // SW_HIDE
    }
}

/// Blocking message box, used to explain that mibi needs a terminal.
pub fn messageBox(text: []const u8, caption: []const u8) void {
    if (is_windows) {
        const allocator = std.heap.page_allocator;
        const wtext = std.unicode.utf8ToUtf16LeAllocZ(allocator, text) catch return;
        defer allocator.free(wtext);
        const wcaption = std.unicode.utf8ToUtf16LeAllocZ(allocator, caption) catch return;
        defer allocator.free(wcaption);
        _ = win.MessageBoxW(null, wtext.ptr, wcaption.ptr, 0x00000040); // MB_ICONINFORMATION
    }
}

/// Delete `path`. A file that is already gone is not an error.
pub fn deleteFile(path: []const u8) !void {
    if (is_windows) {
        const wpath = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path);
        defer std.heap.page_allocator.free(wpath);
        if (win.DeleteFileW(wpath.ptr) == 0) {
            if (win.GetLastError() == win.ERROR_FILE_NOT_FOUND) return;
            return error.DeleteFailed;
        }
    } else {
        const z = try std.heap.page_allocator.dupeZ(u8, path);
        defer std.heap.page_allocator.free(z);
        const rc = std.c.unlink(z.ptr);
        if (rc < 0) {
            if (std.c.errno(rc) == .NOENT) return;
            return error.DeleteFailed;
        }
    }
}

// ---------------------------------------------------------------------------
// Directory listing (for path prompts)
// ---------------------------------------------------------------------------
/// Append the names of the entries in `path` to `out` (caller frees each).
pub fn listDirNames(allocator: std.mem.Allocator, path: []const u8, out: *std.ArrayList([]u8)) !void {
    if (is_windows) return listDirWindows(allocator, path, out);
    return listDirUnix(allocator, path, out);
}

/// Sort a small list of strings in place. Insertion sort keeps the binary
/// small: `std.mem.sort` costs several KB per element type instantiation and
/// these lists (directory entries, syntax files) are tiny.
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

const unix_dir = if (is_windows) struct {} else struct {
    const DIR = opaque {};
    extern "c" fn opendir(pathname: [*:0]const u8) ?*DIR;
    extern "c" fn readdir(dir: *DIR) ?*std.c.dirent;
    extern "c" fn closedir(dir: *DIR) c_int;
};

fn listDirUnix(allocator: std.mem.Allocator, path: []const u8, out: *std.ArrayList([]u8)) !void {
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const dir = unix_dir.opendir(z.ptr) orelse return error.OpenFailed;
    defer _ = unix_dir.closedir(dir);
    while (unix_dir.readdir(dir)) |ent| {
        const name = std.mem.sliceTo(ent.name[0..], 0);
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        try out.append(allocator, try allocator.dupe(u8, name));
    }
}

fn listDirWindows(allocator: std.mem.Allocator, path: []const u8, out: *std.ArrayList([]u8)) !void {
    var pat = std.ArrayList(u8).empty;
    defer pat.deinit(allocator);
    try pat.appendSlice(allocator, path);
    if (pat.items.len == 0 or (pat.items[pat.items.len - 1] != '/' and pat.items[pat.items.len - 1] != '\\')) {
        try pat.append(allocator, '\\');
    }
    try pat.append(allocator, '*');
    const wpat = try std.unicode.utf8ToUtf16LeAllocZ(allocator, pat.items);
    defer allocator.free(wpat);
    var fd: win.WIN32_FIND_DATAW = undefined;
    const h = win.FindFirstFileW(wpat.ptr, &fd);
    if (h == win.INVALID_HANDLE_VALUE) return;
    defer _ = win.FindClose(h);
    while (true) {
        const name = std.mem.sliceTo(fd.cFileName[0..], 0);
        const is_dot = name.len == 1 and name[0] == '.';
        const is_dotdot = name.len == 2 and name[0] == '.' and name[1] == '.';
        if (name.len > 0 and !is_dot and !is_dotdot) {
            try out.append(allocator, try std.unicode.utf16LeToUtf8Alloc(allocator, name));
        }
        if (win.FindNextFileW(h, &fd) == 0) break;
    }
}
