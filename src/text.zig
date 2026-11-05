//! Small UTF-8 helpers shared by the editor and the renderer.

const std = @import("std");

/// Decode the next UTF-8 codepoint at `s[i.*]`, advancing `i.*`. Invalid bytes
/// become U+FFFD so a broken file still renders.
pub fn nextCp(s: []const u8, i: *usize) u21 {
    const b = s[i.*];
    const len = std.unicode.utf8ByteSequenceLength(b) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + len > s.len) {
        i.* += 1;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(s[i.* .. i.* + len]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    i.* += len;
    return cp;
}

/// Decode the codepoint starting at byte offset `off` (or space at end).
pub fn cpAt(s: []const u8, off: usize) u21 {
    if (off >= s.len) return ' ';
    var i = off;
    return nextCp(s, &i);
}
