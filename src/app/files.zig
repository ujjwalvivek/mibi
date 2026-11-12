//! What the editor does with the world outside its own text: running a
//! formatter, noticing files that changed on disk, and the clipboard.

const std = @import("std");
const core = @import("core");
const os = @import("platform").os;
const app_mod = @import("../app.zig");
const doc_mod = @import("doc.zig");
const App = app_mod.App;

/// Split a configured command into arguments, replacing `{file}` with the
/// path so a tool can pick its parser from the name. The arguments are
/// stored in `buf`; returns how many there are.
pub fn buildArgv(cmd: []const u8, file: []const u8, out: [][]const u8, buf: []u8) usize {
    var n: usize = 0;
    var b: usize = 0;
    var i: usize = 0;
    while (i < cmd.len and n < out.len) {
        while (i < cmd.len and (cmd[i] == ' ' or cmd[i] == '\t')) i += 1;
        if (i >= cmd.len) break;
        const start = b;
        while (i < cmd.len and cmd[i] != ' ' and cmd[i] != '\t') {
            const is_file = std.mem.startsWith(u8, cmd[i..], "{file}");
            const piece: []const u8 = if (is_file) file else cmd[i .. i + 1];
            i += if (is_file) 6 else 1;
            const room = @min(piece.len, buf.len - b);
            @memcpy(buf[b..][0..room], piece[0..room]);
            b += room;
        }
        out[n] = buf[start..b];
        n += 1;
    }
    return n;
}

/// Run the formatter configured for the focused file on its text and
/// replace the text with what it prints. Every way this can fail is said in
/// the status line; with `quiet` (format on save) only real failures are.
pub fn format(app: *App, quiet: bool) !void {
    const d = app.doc();
    const path = d.path orelse {
        if (!quiet) app.setMessage("Save the file first: no formatter for an untitled buffer", .{});
        return;
    };
    const cmd = app.config.formatCommandFor(path) orelse {
        if (!quiet) app.setMessage("No formatter configured for this file type", .{});
        return;
    };
    var argv_buf: [16][]const u8 = undefined;
    var text_buf: [1024]u8 = undefined;
    const argc = buildArgv(cmd, path, &argv_buf, &text_buf);
    if (argc == 0) return app.setMessage("Formatter command is empty", .{});

    const input = try d.document.buffer.toOwned(app.allocator);
    defer app.allocator.free(input);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(app.allocator);
    const res = os.runCommand(app.allocator, app.state_dir orelse ".", argv_buf[0..argc], input, &out, 10_000) catch |err| {
        return app.setMessage("Could not start the formatter ({s})", .{app_mod.describe(err)});
    };
    if (res.timed_out) return app.setMessage("Formatter timed out", .{});
    if (res.exit_code != 0) return app.setMessage("Formatter failed (exit code {d})", .{res.exit_code});
    if (out.items.len == 0) return app.setMessage("Formatter produced no output", .{});

    const formatted = core.text.normalizeLineEndings(out.items);
    const edit = doc_mod.replacement(&d.document.buffer, formatted) orelse {
        if (!quiet) app.setMessage("Already formatted", .{});
        return;
    };
    const v = app.view();
    v.now_ms = app.now_ms;
    try v.applyEdits(&.{edit});
    app.setMessage("Formatted", .{});
}

/// Pipe text through a shell command and put what it prints in its place:
/// the selection if there is one, otherwise the whole document. This is the
/// editor's extension point: `sort`, `jq .`, `column -t`, anything that
/// reads standard input.
///
/// The command line goes to the system's shell (`sh -c`, or `cmd.exe /c`), so
/// pipes and quotes work as they do in a terminal. A command that fails
/// changes nothing and its exit code is reported.
pub fn filter(app: *App, command: []const u8) !void {
    const line = std.mem.trim(u8, command, " \t");
    if (line.len == 0) return;
    const d = app.doc();
    const v = app.view();
    const sel = v.primarySelection();
    const start = if (sel.isEmpty()) 0 else sel.start();
    const end = if (sel.isEmpty()) d.document.len() else sel.end();

    var input = std.ArrayList(u8).empty;
    defer input.deinit(app.allocator);
    try input.ensureTotalCapacity(app.allocator, end - start);
    var chunks = d.document.buffer.chunks(start, end);
    while (chunks.next()) |chunk| input.appendSliceAssumeCapacity(chunk);

    var argv_buf: [18][]const u8 = undefined;
    var word_buf: [1024]u8 = undefined;
    var argc: usize = 0;
    if (os.is_windows) {
        argv_buf[0] = "cmd.exe";
        argv_buf[1] = "/c";
        argc = 2 + buildArgv(line, "", argv_buf[2..], &word_buf);
    } else {
        argv_buf[0] = "sh";
        argv_buf[1] = "-c";
        argv_buf[2] = line;
        argc = 3;
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(app.allocator);
    const res = os.runCommand(app.allocator, app.state_dir orelse ".", argv_buf[0..argc], input.items, &out, 10_000) catch |err| {
        return app.setMessage("Could not run the command ({s})", .{app_mod.describe(err)});
    };
    if (res.timed_out) return app.setMessage("The command took more than 10 seconds and was stopped", .{});
    if (res.exit_code != 0) return app.setMessage("The command failed (exit code {d}); nothing was changed", .{res.exit_code});

    const result = core.text.normalizeLineEndings(out.items);
    if (std.mem.eql(u8, result, input.items)) return app.setMessage("The command changed nothing", .{});
    v.now_ms = app.now_ms;
    try v.applyEdits(&.{.{ .start = start, .end = end, .text = result }});
    // What came back is selected, ready to be filtered again or typed over.
    if (!sel.isEmpty()) v.setSelection(.{ .anchor = start, .head = start + result.len });
    app.pane().reveal = true;
    app.session_dirty = true;
    app.setMessage("Filtered through {s}", .{line});
}

/// Follow changes made outside the editor: the file tree, and open files
/// that have no unsaved changes. A file with unsaved changes is never
/// replaced. Returns true when something on screen changed.
pub fn refreshFromDisk(app: *App) bool {
    var changed = false;
    if (app.tree) |*t| {
        if (t.refreshIfChanged()) changed = true;
    }
    for (app.docs.items) |d| {
        const path = d.path orelse continue;
        const stamp = os.fileStamp(path);
        if (stamp == d.stamp or stamp == 0) continue;
        d.stamp = stamp; // one look per change, whatever happens next
        if (d.isDirty()) {
            app.setMessage("{s} changed on disk; your unsaved changes are kept", .{d.name()});
            changed = true;
            continue;
        }
        reload(app, d, path) catch continue;
        app.setMessage("reloaded {s} from disk", .{d.name()});
        changed = true;
    }
    return changed;
}

fn reload(app: *App, d: *app_mod.Doc, path: []const u8) !void {
    const data = try os.readFileAlloc(app.allocator, path, doc_mod.max_file);
    defer app.allocator.free(data);
    d.document.line_ending = core.text.detectLineEnding(data);
    const text = core.text.normalizeLineEndings(data);
    const edit = doc_mod.replacement(&d.document.buffer, text) orelse return;
    // One undoable step, so the text from before the reload is not lost.
    _ = try d.document.edit(&.{edit}, .{});
    d.document.markSaved();
}

// --- clipboard -------------------------------------------------------------

/// Terminals cap how much they accept; past this only the editor's own
/// clipboard holds the text.
const osc52_max = 96 * 1024;

/// Remember `text` as the clipboard and offer it to the terminal (OSC 52),
/// which hands it to the system clipboard when it supports that.
pub fn setClipboard(app: *App, text: []const u8) !void {
    if (text.len == 0) return;
    app.clipboard.clearRetainingCapacity();
    try app.clipboard.appendSlice(app.allocator, text);

    const slice = text[0..@min(text.len, osc52_max)];
    const encoder = std.base64.standard.Encoder;
    try app.term_out.ensureUnusedCapacity(app.allocator, encoder.calcSize(slice.len) + 16);
    app.term_out.appendSliceAssumeCapacity("\x1b]52;c;");
    const dest = app.term_out.addManyAsSliceAssumeCapacity(encoder.calcSize(slice.len));
    _ = encoder.encode(dest, slice);
    app.term_out.appendAssumeCapacity(0x07);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "buildArgv splits on blanks and substitutes the file name" {
    var argv: [16][]const u8 = undefined;
    var buf: [256]u8 = undefined;
    var n = buildArgv("  prettier --stdin-filepath  {file} ", "src/a b.js", &argv, &buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("prettier", argv[0]);
    try testing.expectEqualStrings("--stdin-filepath", argv[1]);
    try testing.expectEqualStrings("src/a b.js", argv[2]); // one argument, blank and all

    n = buildArgv("tool --path={file}.bak", "x.txt", &argv, &buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("--path=x.txt.bak", argv[1]);

    try testing.expectEqual(@as(usize, 0), buildArgv("   ", "x", &argv, &buf));
    // A buffer too small truncates instead of overflowing.
    var tiny: [4]u8 = undefined;
    n = buildArgv("abcdefgh", "x", &argv, &tiny);
    try testing.expectEqualStrings("abcd", argv[0]);
}
