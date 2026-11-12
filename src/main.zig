//! mibi: a small terminal text editor.
//!
//! This file is the process: arguments, start-up, the run loop, and getting
//! the terminal back in every way the program can end. The editor itself is
//! `app.zig`, which never touches a terminal: it takes events and draws
//! cells, and this loop carries both across.

const std = @import("std");
const os = @import("platform").os;
const term = @import("platform").term;
const heap = @import("platform").heap;
const screen = @import("ui").screen;
const config_mod = @import("config.zig");
const langs = @import("langs.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const session = app_mod.session;

/// How long the loop waits for input before it looks at the world (files
/// changed on disk, a session to save).
const idle_ms = 500;
/// The session file is rewritten at most this often while typing.
const autosave_ms = 2000;
/// Events handled between two frames. Held-down keys and pasted text arrive
/// in bursts; drawing once per burst keeps up, and the cap keeps a very long
/// burst from freezing the picture.
const burst = 512;

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
};

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, _: ?usize) noreturn {
    // Whatever was being edited is in the session as of the last autosave;
    // the terminal must not be left raw on top of that.
    term.restore();
    os.writeAll(os.STDERR, "mibi: internal error: ") catch {};
    os.writeAll(os.STDERR, msg) catch {};
    os.writeAll(os.STDERR, "\n") catch {};
    os.exit(1);
}

pub fn main(init: std.process.Init.Minimal) void {
    run(init) catch |err| {
        term.restore();
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "mibi: {s}\n", .{app_mod.describe(err)}) catch "mibi: failed\n";
        os.writeAll(os.STDERR, msg) catch {};
        os.exit(1);
    };
}

const usage =
    \\usage: mibi [file]
    \\
    \\  mibi            pick up where the last session in this directory left off
    \\  mibi <file>     open the file as a tab (it is created on the first save)
    \\  mibi --version  print the version
    \\
    \\F1 inside the editor lists the keys. Settings live in mibi.ini.
    \\
;

fn run(init: std.process.Init.Minimal) !void {
    const allocator = heap.allocator;

    var args = try init.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    var in_terminal = false;
    var path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            return os.writeAll(os.STDOUT, "mibi " ++ app_mod.version ++ "\n");
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return os.writeAll(os.STDOUT, usage);
        } else if (std.mem.eql(u8, arg, "--in-terminal")) {
            in_terminal = true; // the Windows launcher's promise that a terminal hosts us
        } else if (path == null) {
            path = arg;
        }
    }

    if (!term.isTty()) return error.NotATerminal;

    // Double-clicking a console program on Windows gives it a console window
    // of its own, which is not where an editor wants to live. Say so instead
    // of running in it.
    if (os.is_windows and !in_terminal and !os.inWindowsTerminal() and os.consoleProcessCount() <= 1) {
        os.hideConsoleWindow();
        os.messageBox(
            "mibi is a terminal text editor.\n\n" ++
                "Open it from a terminal window instead of double-clicking:\n\n" ++
                "    mibi <file>     in Windows Terminal (or any terminal)\n" ++
                "    mibi.cmd        in assets\\windows-terminal\\\n\n" ++
                "The README covers the Windows Terminal profile, colours and keys.",
            "mibi",
        );
        return;
    }

    const exe_dir = os.exeDirAlloc(allocator) catch null;
    defer if (exe_dir) |d| allocator.free(d);
    const state_dir = stateDirAlloc(allocator) catch null;
    defer if (state_dir) |d| allocator.free(d);
    if (state_dir) |d| os.makeDirAll(d) catch {};

    var app = App.init(allocator, .{
        .config = config_mod.load(allocator, exe_dir),
        .exe_dir = exe_dir,
        .state_dir = state_dir,
    });
    defer app.deinit();
    loadLanguages(&app);

    // The last session comes back first (tabs, panes, cursors, and the text
    // of anything that was never saved); a file named on the command line
    // joins it as a tab. A file that cannot be read stops here, before the
    // screen is taken over, with the reason on stderr.
    const restored = session.load(&app);
    if (path) |p| {
        try app.openPath(p);
    } else if (!restored) {
        _ = try app.addDoc(null, "");
    }
    if (app.config.theme_missing) app.setMessage("theme \"{s}\" not found", .{app.config.themeName()});

    try term.enterRaw();
    defer term.restore();
    try term.enterScreen();

    // The window's close button ends a Windows process without unwinding.
    closing_app = &app;
    term.installCloseHandler(saveOnClose);
    defer closing_app = null;
    // Every other way out comes through here.
    defer session.save(&app);

    try loop(allocator, &app);
}

fn loop(allocator: std.mem.Allocator, app: *App) !void {
    var input = term.Input.init(allocator);
    defer input.deinit();
    const first = term.size();
    var s = try screen.Screen.init(allocator, first.cols, first.rows);
    defer s.deinit();
    // The terminal's contents are unknown: paint every row once.
    s.invalidate();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var last_save = os.ticksMs();
    var redraw = true;
    while (!app.quit) {
        if (redraw) {
            app.draw(&s);
            out.clearRetainingCapacity();
            // A frame that cannot be built (out of memory) is skipped; the
            // next event tries again.
            if (s.diff(&out)) |_| {
                out.appendSlice(allocator, app.term_out.items) catch {};
                app.term_out.clearRetainingCapacity();
                try term.write(out.items);
            } else |_| s.invalidate();
            redraw = false;
        }

        var ev = input.next(idle_ms) catch |err| switch (err) {
            error.Closed => return, // the terminal went away: save and leave
            else => return err,
        };
        app.now_ms = os.ticksMs();
        if (ev == null) {
            // Quiet: see whether a file changed under us.
            redraw = app.tick();
        }
        var handled: usize = 0;
        while (ev) |e| {
            switch (e) {
                .resize => {
                    const size = term.size();
                    try s.resize(size.cols, size.rows);
                    s.invalidate();
                },
                // Some terminals hold painting back while in the
                // background: repaint every row when the window returns.
                .focus => |gained| if (gained) s.invalidate(),
                else => {},
            }
            app.handle(e);
            redraw = true;
            handled += 1;
            if (app.quit or handled >= burst) break;
            ev = input.next(0) catch null;
        }

        if (app.session_dirty and app.now_ms -% last_save >= autosave_ms) {
            session.save(app);
            last_save = app.now_ms;
        }
    }
}

var closing_app: ?*App = null;

fn saveOnClose() void {
    if (closing_app) |app| session.save(app);
}

/// Language definitions are data files in `syntax.d`, next to the binary or,
/// when running from a source checkout, in the working directory.
fn loadLanguages(app: *App) void {
    if (app.exe_dir) |dir| {
        var buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/syntax.d", .{dir})) |sub| {
            _ = langs.loadDir(&app.registry, sub);
        } else |_| {}
    }
    if (app.registry.langs.items.len == 0) _ = langs.loadDir(&app.registry, "syntax.d");
}

/// Where the session lives. Not the project folder: a directory per working
/// directory under the user's data directory keeps projects clean.
/// `MIBI_STATE_DIR` overrides it.
fn stateDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    if (os.getEnvAlloc(allocator, "MIBI_STATE_DIR")) |v| {
        if (v.len > 0) return v;
        allocator.free(v);
    } else |_| {}
    const data = try os.dataDirAlloc(allocator);
    defer allocator.free(data);
    const cwd = try os.cwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fmt.allocPrint(allocator, "{s}/sessions/{x}", .{ data, std.hash.Fnv1a_64.hash(cwd) });
}

test {
    _ = @import("app.zig");
    _ = @import("app/doc.zig");
    _ = @import("app/files.zig");
    _ = @import("app/pickers.zig");
    _ = @import("app/prompt.zig");
    _ = @import("app/tree.zig");
    _ = @import("commands.zig");
    _ = @import("config.zig");
    _ = @import("langs.zig");
}
