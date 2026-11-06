//! Pseudo terminal: a child process attached to a pty master we can read,
//! write and resize.
//!
//! Windows uses ConPTY (`CreatePseudoConsole`, Windows 10 1809+); Unix builds
//! the pair from `posix_openpt` + `fork`, because `forkpty`/`openpty` live in
//! libutil, which mibi does not link. Everything is raw kernel32/libc: no
//! `std.Io`, no threads (see experiments/README.md for why that matters).
//!
//! `read` never blocks: it returns 0 when nothing is available yet. On Windows
//! that is a `PeekNamedPipe` probe, on Unix the master fd is `O_NONBLOCK`.
//! Callers wait on `outputHandle` and poll `exited`. `exited` is also what
//! closes the ConPTY, and that is what lets the output pipe reach EOF once the
//! child is gone - so poll it rather than relying on `read` alone.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

/// kernel32 HANDLE on Windows, file descriptor on Unix.
pub const Handle = if (is_windows) *anyopaque else i32;

const win = if (is_windows) struct {
    const HANDLE = *anyopaque;
    const DWORD = u32;
    const BOOL = i32;
    const HPCON = HANDLE;

    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x0008_0000;
    const WAIT_OBJECT_0: DWORD = 0;
    /// ProcThreadAttributeValue(22, FALSE, TRUE, FALSE): the pseudo console.
    const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x0002_0016;
    const ERROR_BROKEN_PIPE: DWORD = 109;
    const ERROR_HANDLE_EOF: DWORD = 38;

    const COORD = extern struct { X: i16, Y: i16 };

    const STARTUPINFOW = extern struct {
        cb: DWORD = 0,
        lpReserved: ?[*:0]u16 = null,
        lpDesktop: ?[*:0]u16 = null,
        lpTitle: ?[*:0]u16 = null,
        dwX: DWORD = 0,
        dwY: DWORD = 0,
        dwXSize: DWORD = 0,
        dwYSize: DWORD = 0,
        dwXCountChars: DWORD = 0,
        dwYCountChars: DWORD = 0,
        dwFillAttribute: DWORD = 0,
        dwFlags: DWORD = 0,
        wShowWindow: u16 = 0,
        cbReserved2: u16 = 0,
        lpReserved2: ?[*]u8 = null,
        hStdInput: HANDLE = INVALID_HANDLE_VALUE,
        hStdOutput: HANDLE = INVALID_HANDLE_VALUE,
        hStdError: HANDLE = INVALID_HANDLE_VALUE,
    };

    /// `STARTUPINFOW` plus the attribute list pointer; `cb` must cover both.
    const STARTUPINFOEXW = extern struct {
        StartupInfo: STARTUPINFOW,
        lpAttributeList: ?*anyopaque = null,
    };

    const PROCESS_INFORMATION = extern struct {
        hProcess: HANDLE = INVALID_HANDLE_VALUE,
        hThread: HANDLE = INVALID_HANDLE_VALUE,
        dwProcessId: DWORD = 0,
        dwThreadId: DWORD = 0,
    };

    extern "kernel32" fn CreatePipe(hReadPipe: *HANDLE, hWritePipe: *HANDLE, lpPipeAttributes: ?*anyopaque, nSize: DWORD) callconv(.winapi) BOOL;
    // Plain kernel32 exports on Windows 10 1809+; no runtime lookup needed.
    extern "kernel32" fn CreatePseudoConsole(size: COORD, hInput: HANDLE, hOutput: HANDLE, dwFlags: DWORD, phPC: *HPCON) callconv(.winapi) c_long;
    extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: COORD) callconv(.winapi) c_long;
    extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
    extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: DWORD, flags: DWORD, size: *usize) callconv(.winapi) BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: DWORD, attribute: usize, value: *anyopaque, size: usize, prev: ?*anyopaque, ret: ?*usize) callconv(.winapi) BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn CreateProcessW(
        lpApplicationName: ?[*:0]const u16,
        lpCommandLine: [*:0]u16,
        lpProcessAttributes: ?*anyopaque,
        lpThreadAttributes: ?*anyopaque,
        bInheritHandles: BOOL,
        dwCreationFlags: DWORD,
        lpEnvironment: ?*anyopaque,
        lpCurrentDirectory: ?[*:0]const u16,
        lpStartupInfo: *STARTUPINFOW,
        lpProcessInformation: *PROCESS_INFORMATION,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadFile(hFile: HANDLE, buf: [*]u8, want: DWORD, got: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(hFile: HANDLE, buf: [*]const u8, want: DWORD, wrote: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn PeekNamedPipe(pipe: HANDLE, buf: ?[*]u8, size: DWORD, read: ?*DWORD, avail: ?*DWORD, left: ?*DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn TerminateProcess(hProcess: HANDLE, code: c_uint) callconv(.winapi) BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
    extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;

    /// Close a handle and forget it, so a later error path cannot close it twice.
    fn close(h: *HANDLE) void {
        if (h.* != INVALID_HANDLE_VALUE) {
            _ = CloseHandle(h.*);
            h.* = INVALID_HANDLE_VALUE;
        }
    }

    /// Clamp a cell count to the signed COORD range.
    fn coord(v: u16) i16 {
        return @intCast(@min(v, @as(u16, std.math.maxInt(i16))));
    }
} else struct {};

const unix = if (is_windows) struct {} else struct {
    /// Same layout on Linux and macOS: four unsigned shorts.
    const Winsize = extern struct { row: u16, col: u16, xpixel: u16, ypixel: u16 };

    // std.c only carries the ioctl numbers it uses, and macOS lacks both.
    const TIOCSCTTY: c_ulong = if (builtin.os.tag == .macos) 0x2000_7461 else 0x540e;
    const TIOCSWINSZ: c_ulong = if (builtin.os.tag == .macos) 0x8008_7467 else 0x5414;

    const WNOHANG: c_int = 1;
    const SIGHUP: c_int = 1;
    const SIGKILL: c_int = 9;

    // The rest of the pty API is not in std.c; declare what we call.
    extern "c" fn posix_openpt(oflag: c_int) c_int;
    extern "c" fn grantpt(fd: c_int) c_int;
    extern "c" fn unlockpt(fd: c_int) c_int;
    extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
    extern "c" fn setsid() c_int;
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn fork() c_int;
    extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
    extern "c" fn kill(pid: c_int, sig: c_int) c_int;
};

pub const Pty = struct {
    // Windows state (all null on Unix).
    hpc: ?*anyopaque = null,
    h_in: ?*anyopaque = null,
    h_out: ?*anyopaque = null,
    h_process: ?*anyopaque = null,
    // Unix state (unused on Windows).
    master: i32 = -1,
    pid: i32 = -1,
    reaped: bool = false,
    /// Set once the child has exited.
    exit_code: ?i32 = null,

    /// Start `argv` on a new pseudo terminal of `cols` x `rows` cells.
    pub fn spawn(allocator: std.mem.Allocator, argv: []const []const u8, cols: u16, rows: u16) !Pty {
        if (is_windows) {
            return spawnWindows(allocator, argv, cols, rows);
        } else {
            return spawnUnix(allocator, argv, cols, rows);
        }
    }

    /// Close the pty and reap the child. Kills a child that is still running:
    /// a Pty owns its process, and deinit must not leave an orphan behind.
    pub fn deinit(self: *Pty) void {
        if (is_windows) {
            // Close the pseudo console first: the conhost it owns is what keeps
            // the output pipe open.
            if (self.hpc) |hpc| {
                win.ClosePseudoConsole(hpc);
                self.hpc = null;
            }
            win.close(&self.h_in);
            win.close(&self.h_out);
            if (self.h_process) |h| {
                if (self.exit_code == null) {
                    _ = win.WaitForSingleObject(h, 500);
                    if (win.WaitForSingleObject(h, 0) != win.WAIT_OBJECT_0) _ = win.TerminateProcess(h, 1);
                    _ = win.WaitForSingleObject(h, 2000);
                }
                _ = win.CloseHandle(h);
                self.h_process = null;
            }
        } else {
            if (self.master >= 0) {
                _ = std.c.close(self.master);
                self.master = -1;
            }
            if (!self.reaped and self.pid > 0) {
                _ = unix.kill(self.pid, unix.SIGKILL);
                var status: c_int = 0;
                while (true) {
                    const rc = unix.waitpid(self.pid, &status, 0);
                    if (rc == self.pid) {
                        self.exit_code = decodeStatus(status);
                        break;
                    }
                    if (rc < 0 and std.c.errno(rc) != .INTR) break;
                }
                self.reaped = true;
            }
        }
    }

    /// The handle to wait on for output readiness: waitable HANDLE / pollable fd.
    pub fn outputHandle(self: *const Pty) Handle {
        if (is_windows) {
            return self.h_out orelse win.INVALID_HANDLE_VALUE;
        } else {
            return self.master;
        }
    }

    /// Read what is available. 0 means "nothing yet"; EndOfStream at EOF.
    pub fn read(self: *Pty, buf: []u8) !usize {
        if (is_windows) {
            if (buf.len == 0) return 0;
            const h = self.h_out orelse return error.PtyClosed;
            // A synchronous pipe read would block, so probe first; this is
            // what makes the "0 = nothing available" contract true.
            var avail: win.DWORD = 0;
            if (win.PeekNamedPipe(h, null, 0, null, &avail, null) == 0) {
                const err = win.GetLastError();
                if (err == win.ERROR_BROKEN_PIPE or err == win.ERROR_HANDLE_EOF) return error.EndOfStream;
                return error.ReadFailed;
            }
            if (avail == 0) return 0;
            var got: win.DWORD = 0;
            const want: win.DWORD = @intCast(@min(buf.len, @as(usize, avail)));
            if (win.ReadFile(h, buf.ptr, want, &got, null) == 0) return error.ReadFailed;
            return got;
        } else {
            if (buf.len == 0) return 0;
            const rc = std.c.read(self.master, buf.ptr, buf.len);
            if (rc > 0) return @intCast(rc);
            if (rc == 0) return error.EndOfStream;
            const err = std.c.errno(rc);
            if (err == .AGAIN or err == .INTR) return 0;
            // EIO is how Linux reports "the slave side is gone".
            if (err == .IO) return error.EndOfStream;
            return error.ReadFailed;
        }
    }

    /// Write all of `bytes` to the child's input.
    pub fn write(self: *Pty, bytes: []const u8) !void {
        if (is_windows) {
            const h = self.h_in orelse return error.PtyClosed;
            var i: usize = 0;
            while (i < bytes.len) {
                var wrote: win.DWORD = 0;
                if (win.WriteFile(h, bytes[i..].ptr, @intCast(bytes.len - i), &wrote, null) == 0) return error.WriteFailed;
                if (wrote == 0) return error.WriteFailed;
                i += wrote;
            }
        } else {
            var i: usize = 0;
            while (i < bytes.len) {
                const rc = std.c.write(self.master, bytes[i..].ptr, bytes.len - i);
                if (rc < 0) {
                    const err = std.c.errno(rc);
                    if (err == .AGAIN) {
                        // The master is non-blocking; wait for the child to drain.
                        sleepMs(1);
                        continue;
                    }
                    if (err == .INTR) continue;
                    return error.WriteFailed;
                }
                if (rc == 0) return error.WriteFailed;
                i += @intCast(rc);
            }
        }
    }

    /// Tell the child (and the terminal driver) about a new size.
    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        if (is_windows) {
            const hpc = self.hpc orelse return error.PtyClosed;
            if (win.ResizePseudoConsole(hpc, .{ .X = win.coord(cols), .Y = win.coord(rows) }) != 0) return error.ResizeFailed;
        } else {
            try setWinsize(self.master, cols, rows);
        }
    }

    /// Exit code once the child is gone, null while it is still running.
    pub fn exited(self: *Pty) ?i32 {
        if (is_windows) {
            if (self.exit_code) |code| return code;
            const h = self.h_process orelse return null;
            if (win.WaitForSingleObject(h, 0) != win.WAIT_OBJECT_0) return null;
            var code: win.DWORD = 0;
            if (win.GetExitCodeProcess(h, &code) == 0) return null;
            // The conhost keeps the output pipe open after the child dies;
            // closing the pseudo console is what lets read() see EOF.
            if (self.hpc) |hpc| {
                win.ClosePseudoConsole(hpc);
                self.hpc = null;
            }
            self.exit_code = @intCast(code);
            return self.exit_code;
        } else {
            if (self.reaped) return self.exit_code;
            var status: c_int = 0;
            while (true) {
                const rc = unix.waitpid(self.pid, &status, unix.WNOHANG);
                if (rc == 0) return null;
                if (rc < 0) {
                    if (std.c.errno(rc) == .INTR) continue;
                    // Someone else collected it; report an unknown code.
                    self.reaped = true;
                    self.exit_code = -1;
                    return -1;
                }
                self.reaped = true;
                self.exit_code = decodeStatus(status);
                return self.exit_code;
            }
        }
    }

    /// Hang up the shell, then insist after a short grace period.
    pub fn kill(self: *Pty) void {
        if (is_windows) {
            if (self.exit_code != null) return;
            const h = self.h_process orelse return;
            if (win.WaitForSingleObject(h, 0) != win.WAIT_OBJECT_0) _ = win.TerminateProcess(h, 1);
        } else {
            if (self.reaped) return;
            _ = unix.kill(self.pid, unix.SIGHUP);
            var i: usize = 0;
            while (i < 20) : (i += 1) {
                if (self.exited() != null) return;
                sleepMs(10);
            }
            _ = unix.kill(self.pid, unix.SIGKILL);
            var status: c_int = 0;
            while (true) {
                const rc = unix.waitpid(self.pid, &status, 0);
                if (rc == self.pid) {
                    self.reaped = true;
                    self.exit_code = decodeStatus(status);
                    break;
                }
                if (rc < 0 and std.c.errno(rc) != .INTR) {
                    self.reaped = true;
                    break;
                }
            }
        }
    }
};

fn spawnWindows(allocator: std.mem.Allocator, argv: []const []const u8, cols: u16, rows: u16) !Pty {
    if (argv.len == 0) return error.InvalidCommand;

    var self = Pty{};
    errdefer self.deinit();

    var in_read: win.HANDLE = win.INVALID_HANDLE_VALUE;
    var in_write: win.HANDLE = win.INVALID_HANDLE_VALUE;
    var out_read: win.HANDLE = win.INVALID_HANDLE_VALUE;
    var out_write: win.HANDLE = win.INVALID_HANDLE_VALUE;
    errdefer {
        win.close(&in_read);
        win.close(&in_write);
        win.close(&out_read);
        win.close(&out_write);
    }

    if (win.CreatePipe(&in_read, &in_write, null, 0) == 0) return error.PipeFailed;
    if (win.CreatePipe(&out_read, &out_write, null, 0) == 0) return error.PipeFailed;

    // conhost reads in_read and writes out_write; both ends stay ours to close.
    var hpc: win.HPCON = win.INVALID_HANDLE_VALUE;
    if (win.CreatePseudoConsole(.{ .X = win.coord(cols), .Y = win.coord(rows) }, in_read, out_write, 0, &hpc) != 0)
        return error.PseudoConsoleFailed;
    self.hpc = hpc;
    // conhost duplicated them; keeping our copies would hold the pipes open.
    win.close(&in_read);
    win.close(&out_write);

    // The attribute list is opaque: probe its size, allocate, then fill it in.
    var attr_size: usize = 0;
    _ = win.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    if (attr_size == 0) return error.AttributeListFailed;
    const words = (attr_size + @sizeOf(usize) - 1) / @sizeOf(usize);
    const attrs = try allocator.alloc(usize, words);
    defer allocator.free(attrs);
    if (win.InitializeProcThreadAttributeList(@ptrCast(attrs.ptr), 1, 0, &attr_size) == 0) return error.AttributeListFailed;
    defer win.DeleteProcThreadAttributeList(@ptrCast(attrs.ptr));
    if (win.UpdateProcThreadAttribute(@ptrCast(attrs.ptr), 0, win.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(win.HPCON), null, null) == 0)
        return error.AttributeListFailed;

    const cmd = try buildCommandLine(allocator, argv);
    defer allocator.free(cmd);

    var si: win.STARTUPINFOEXW = .{};
    si.StartupInfo.cb = @intCast(@sizeOf(win.STARTUPINFOEXW));
    si.lpAttributeList = @ptrCast(attrs.ptr);
    var pi: win.PROCESS_INFORMATION = .{};
    const ok = win.CreateProcessW(
        null,
        cmd.ptr,
        null,
        null,
        0, // no inherited handles: the pseudo console carries the pipes
        win.EXTENDED_STARTUPINFO_PRESENT,
        null, // inherit our environment
        null,
        @ptrCast(&si),
        &pi,
    );
    if (ok == 0) return error.SpawnFailed;
    _ = win.CloseHandle(pi.hThread);
    self.h_process = pi.hProcess;
    self.h_in = in_write;
    in_write = win.INVALID_HANDLE_VALUE;
    self.h_out = out_read;
    out_read = win.INVALID_HANDLE_VALUE;
    return self;
}

fn spawnUnix(allocator: std.mem.Allocator, argv: []const []const u8, cols: u16, rows: u16) !Pty {
    if (argv.len == 0) return error.InvalidCommand;

    const oflags: c_int = @bitCast(std.c.O{ .ACCMODE = .RDWR, .NOCTTY = true });
    const master = unix.posix_openpt(oflags);
    if (master < 0) return error.OpenPtyFailed;
    errdefer _ = std.c.close(master);
    if (unix.grantpt(master) != 0) return error.GrantPtyFailed;
    if (unix.unlockpt(master) != 0) return error.UnlockPtyFailed;
    const slave_name = unix.ptsname(master) orelse return error.PtyNameFailed;

    // Open the slave before forking so a failure is a spawn error, not a child
    // that dies quietly. O_NOCTTY keeps it from becoming our controlling tty.
    var slave = std.c.open(slave_name, .{ .ACCMODE = .RDWR, .NOCTTY = true }, @as(c_uint, 0));
    if (slave < 0) return error.OpenPtyFailed;
    errdefer {
        if (slave >= 0) _ = std.c.close(slave);
    }

    // argv as a null-terminated vector; the child needs it after the fork.
    const argvz = try allocator.alloc(?[*:0]const u8, argv.len + 1);
    defer allocator.free(argvz);
    var owned = std.ArrayList([:0]u8).empty;
    defer {
        for (owned.items) |z| allocator.free(z);
        owned.deinit(allocator);
    }
    for (argv, 0..) |arg, i| {
        const z = try allocator.dupeZ(u8, arg);
        try owned.append(allocator, z);
        argvz[i] = z.ptr;
    }
    argvz[argv.len] = null;

    // Best effort: the child sets its own size on the first SIGWINCH otherwise.
    setWinsize(master, cols, rows) catch {};

    const pid = unix.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child: new session, then adopt the slave as the controlling terminal.
        _ = unix.setsid();
        _ = unix.ioctl(slave, unix.TIOCSCTTY, @as(c_int, 0));
        _ = std.c.dup2(slave, 0);
        _ = std.c.dup2(slave, 1);
        _ = std.c.dup2(slave, 2);
        if (slave > 2) _ = std.c.close(slave);
        _ = std.c.close(master);
        _ = unix.setenv("TERM", "xterm-256color", 1);
        _ = unix.setenv("COLORTERM", "truecolor", 1);
        _ = unix.execvp(argvz[0].?, @ptrCast(argvz.ptr));
        std.c._exit(127);
    }

    // Parent: only the master stays open, and it must not block on read.
    _ = std.c.close(slave);
    slave = -1;
    setNonBlocking(master);
    return Pty{ .master = master, .pid = pid };
}

fn setNonBlocking(fd: i32) void {
    const fl = std.c.fcntl(fd, std.c.F.GETFL);
    if (fl < 0) return;
    const nonblock: u32 = @bitCast(std.c.O{ .NONBLOCK = true });
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(@as(u32, @bitCast(fl)) | nonblock)));
}

fn setWinsize(fd: i32, cols: u16, rows: u16) !void {
    var ws = unix.Winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    if (unix.ioctl(fd, unix.TIOCSWINSZ, &ws) != 0) return error.ResizeFailed;
}

/// Build the UTF-16 command line CreateProcessW parses. `lpApplicationName` is
/// null, so the first quoted token doubles as the program name.
fn buildCommandLine(allocator: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    for (argv, 0..) |arg, i| {
        if (i > 0) try buf.append(allocator, ' ');
        try appendQuoted(&buf, allocator, arg);
    }
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, buf.items);
}

/// Quote one argument the way the CRT's parser expects: wrap it when it holds
/// whitespace or a quote, and double the backslashes that sit before a quote.
fn appendQuoted(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, arg: []const u8) !void {
    var needs = arg.len == 0;
    for (arg) |c| {
        if (c == ' ' or c == '\t' or c == '"') {
            needs = true;
            break;
        }
    }
    if (!needs) {
        try buf.appendSlice(allocator, arg);
        return;
    }
    try buf.append(allocator, '"');
    var slashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            slashes += 1;
            continue;
        }
        // 2n+1: n pairs collapse back to n, the odd one escapes the quote.
        const run: usize = if (c == '"') slashes * 2 + 1 else slashes;
        var i: usize = 0;
        while (i < run) : (i += 1) try buf.append(allocator, '\\');
        slashes = 0;
        try buf.append(allocator, c);
    }
    // Trailing backslashes must not escape the closing quote.
    var i: usize = 0;
    while (i < slashes * 2) : (i += 1) try buf.append(allocator, '\\');
    try buf.append(allocator, '"');
}

/// Decode a waitpid status without WIFEXITED/WEXITSTATUS (std has no macros).
fn decodeStatus(status: c_int) i32 {
    const s: u32 = @bitCast(status);
    if ((s & 0x7f) == 0) return @intCast((s >> 8) & 0xff);
    return @intCast(128 + (s & 0x7f));
}

fn sleepMs(ms: u64) void {
    if (is_windows) {
        win.Sleep(@intCast(ms));
    } else {
        var ts = std.c.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&ts, null);
    }
}
