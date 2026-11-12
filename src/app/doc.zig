//! An open document as the app sees it: the text model plus what ties it to
//! a file (path, line endings, the time it was last read) and to the screen
//! (its language, the cursor to come back to).

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const os = @import("platform").os;

/// Files larger than this are refused rather than loaded into memory.
pub const max_file = 64 * 1024 * 1024;

/// Where a view of the document was, so a tab comes back to the same place.
pub const ViewState = struct {
    anchor: usize = 0,
    head: usize = 0,
    scroll_row: usize = 0,
    scroll_col: usize = 0,
};

pub const Doc = struct {
    allocator: Allocator,
    /// Stable for the life of the document; tab order is not.
    id: u32,
    document: core.Document,
    highlighter: *core.highlight.Highlighter,
    path: ?[]u8 = null,
    /// What the file looked like when it was last read or written, to
    /// notice changes made outside the editor.
    stamp: u64 = 0,
    /// The cursor and scroll of the last pane that showed this document.
    last: ViewState = .{},
    /// The revision whose text the session's buffer file holds, or null
    /// when there is no buffer file. Saves rewriting it when nothing changed.
    session_revision: ?u64 = null,

    /// `data` is the file's bytes as read; line endings are normalised here.
    pub fn create(allocator: Allocator, id: u32, path: ?[]const u8, data: []const u8) !*Doc {
        const self = try allocator.create(Doc);
        errdefer allocator.destroy(self);

        const copy = try allocator.dupe(u8, data);
        defer allocator.free(copy);
        const ending = core.text.detectLineEnding(copy);
        const normal = core.text.normalizeLineEndings(copy);

        self.* = .{
            .allocator = allocator,
            .id = id,
            .document = try core.Document.init(allocator, normal),
            .highlighter = undefined,
        };
        errdefer self.document.deinit();
        self.document.line_ending = ending;
        self.highlighter = try core.highlight.Highlighter.create(allocator, &self.document);
        errdefer self.highlighter.destroy();
        if (path) |p| {
            self.path = try allocator.dupe(u8, p);
            self.stamp = os.fileStamp(p);
        }
        return self;
    }

    /// Every view of the document must be destroyed first.
    pub fn destroy(self: *Doc) void {
        self.highlighter.destroy();
        self.document.deinit();
        if (self.path) |p| self.allocator.free(p);
        self.allocator.destroy(self);
    }

    pub fn isDirty(self: *const Doc) bool {
        return self.document.isDirty();
    }

    /// The name shown on the tab.
    pub fn name(self: *const Doc) []const u8 {
        return if (self.path) |p| baseName(p) else "[No Name]";
    }

    pub fn setPath(self: *Doc, path: []const u8) !void {
        const copy = try self.allocator.dupe(u8, path);
        if (self.path) |p| self.allocator.free(p);
        self.path = copy;
    }

    /// The text as it goes to disk: with the file's own line endings.
    pub fn bytesForDisk(self: *const Doc, allocator: Allocator) ![]u8 {
        const buf = &self.document.buffer;
        const extra = if (self.document.line_ending == .crlf) buf.lineCount() - 1 else 0;
        var out = try std.ArrayList(u8).initCapacity(allocator, buf.len() + extra);
        errdefer out.deinit(allocator);
        var chunks = buf.chunks(0, buf.len());
        while (chunks.next()) |chunk| {
            if (extra == 0) {
                out.appendSliceAssumeCapacity(chunk);
                continue;
            }
            for (chunk) |b| {
                if (b == '\n') out.appendAssumeCapacity('\r');
                out.appendAssumeCapacity(b);
            }
        }
        return out.toOwnedSlice(allocator);
    }

    /// Write the document to its path.
    pub fn save(self: *Doc) !void {
        const path = self.path orelse return error.NoPath;
        const bytes = try self.bytesForDisk(self.allocator);
        defer self.allocator.free(bytes);
        // All or nothing: a save that fails must not cost the file on disk.
        try os.writeFileAtomic(path, bytes);
        self.document.markSaved();
        self.stamp = os.fileStamp(path);
    }
};

/// The last component of a path ("src/main.zig" -> "main.zig").
pub fn baseName(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    var i = end;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/' or path[i - 1] == '\\') return path[i..end];
    }
    return path[0..end];
}

/// Paths compared the way a user means them: a leading "./" is the same as
/// none, so the tree ("./notes.txt") and a command-line argument
/// ("notes.txt") are one document, not two tabs.
pub fn pathsEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, stripDotSlash(a), stripDotSlash(b));
}

fn stripDotSlash(p: []const u8) []const u8 {
    var s = p;
    while (std.mem.startsWith(u8, s, "./") or std.mem.startsWith(u8, s, ".\\")) s = s[2..];
    return s;
}

/// The single edit that turns the document into `new`: the part between the
/// common start and the common end. Replacing a whole buffer with a
/// formatter's output this way leaves cursors outside the changed part where
/// they were.
pub fn replacement(buf: *const core.Buffer, new: []const u8) ?core.Edit {
    const old_len = buf.len();
    var prefix: usize = 0;
    {
        var chunks = buf.chunks(0, old_len);
        outer: while (chunks.next()) |chunk| {
            for (chunk) |b| {
                if (prefix >= new.len or new[prefix] != b) break :outer;
                prefix += 1;
            }
        }
    }
    var suffix: usize = 0;
    while (suffix < old_len - prefix and suffix < new.len - prefix and
        buf.byteAt(old_len - 1 - suffix).? == new[new.len - 1 - suffix]) suffix += 1;
    if (prefix == old_len and prefix == new.len) return null;
    return .{ .start = prefix, .end = old_len - suffix, .text = new[prefix .. new.len - suffix] };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

test "line endings are normalised in memory and restored on disk" {
    const doc = try Doc.create(testing.allocator, 1, null, "one\r\ntwo\r\nthree");
    defer doc.destroy();
    try testing.expectEqual(core.text.LineEnding.crlf, doc.document.line_ending);
    try testing.expectEqual(@as(usize, 13), doc.document.len());
    const bytes = try doc.bytesForDisk(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("one\r\ntwo\r\nthree", bytes);

    const unix = try Doc.create(testing.allocator, 2, null, "a\nb\n");
    defer unix.destroy();
    const same = try unix.bytesForDisk(testing.allocator);
    defer testing.allocator.free(same);
    try testing.expectEqualStrings("a\nb\n", same);
}

test "save writes the file and clears the dirty flag" {
    const path = "mibi-doc-test.txt";
    defer os.deleteFile(path) catch {};
    const doc = try Doc.create(testing.allocator, 1, path, "");
    defer doc.destroy();
    _ = try doc.document.edit(&.{.{ .start = 0, .end = 0, .text = "hello\n" }}, .{});
    try testing.expect(doc.isDirty());
    try doc.save();
    try testing.expect(!doc.isDirty());
    const back = try os.readFileAlloc(testing.allocator, path, 1024);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("hello\n", back);
    try testing.expectEqualStrings("mibi-doc-test.txt", doc.name());

    const unnamed = try Doc.create(testing.allocator, 2, null, "x");
    defer unnamed.destroy();
    try testing.expectError(error.NoPath, unnamed.save());
    try testing.expectEqualStrings("[No Name]", unnamed.name());
}

test "names and path comparison" {
    try testing.expectEqualStrings("main.zig", baseName("src/main.zig"));
    try testing.expectEqualStrings("main.zig", baseName("C:\\src\\main.zig"));
    try testing.expectEqualStrings("dir", baseName("a/dir/"));
    try testing.expectEqualStrings("x", baseName("x"));
    try testing.expect(pathsEqual("./notes.txt", "notes.txt"));
    try testing.expect(pathsEqual(".\\a", "./a"));
    try testing.expect(!pathsEqual("a/notes.txt", "notes.txt"));
}

test "replacement is the smallest single edit" {
    var buf = try core.Buffer.init(testing.allocator, "fn  main(){}\n");
    defer buf.deinit();
    const e = replacement(&buf, "fn main() {}\n").?;
    // Common start "fn ", common end "{}\n"; " main()" becomes "main() ".
    try testing.expectEqual(@as(usize, 3), e.start);
    try testing.expectEqual(@as(usize, 10), e.end);
    try testing.expectEqualStrings("main() ", e.text);
    try testing.expect(replacement(&buf, "fn  main(){}\n") == null);

    const grow = replacement(&buf, "fn  main(){}\n\n").?;
    try testing.expectEqual(@as(usize, 13), grow.start);
    try testing.expectEqual(@as(usize, 13), grow.end);
    const shrink = replacement(&buf, "").?;
    try testing.expectEqual(@as(usize, 0), shrink.start);
    try testing.expectEqual(@as(usize, 13), shrink.end);
    // Repeated text: prefix and suffix must not overlap.
    var aa = try core.Buffer.init(testing.allocator, "aa");
    defer aa.deinit();
    const one = replacement(&aa, "a").?;
    try testing.expectEqual(@as(usize, 1), one.end - one.start);
    try testing.expectEqualStrings("", one.text);
}
