//! Terminal input decoder: the bytes a Unix terminal sends, turned into
//! `Event`s. Pure: bytes in, events out, no file descriptors, so it is tested
//! (and fuzzed) without a terminal.
//!
//! A read can end anywhere, including the middle of an escape sequence or a
//! UTF-8 character, so the decoder keeps what it could not finish and asks for
//! more. The one real ambiguity is a lone ESC byte, which is both the Escape
//! key and the start of every sequence: `next(false)` holds it back, and the
//! caller says `next(true)` once the terminal has been quiet for a moment.

const std = @import("std");
const Allocator = std.mem.Allocator;
const event = @import("ui").event;
const Event = event.Event;
const Key = event.Key;
const Mods = event.Mods;
const Special = event.Special;

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";

pub const Decoder = struct {
    allocator: Allocator,
    /// Bytes received and not yet turned into events.
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    /// The text of a bracketed paste, while it arrives and until the event
    /// that carries it has been handled.
    paste: std.ArrayList(u8) = .empty,
    in_paste: bool = false,

    pub fn init(allocator: Allocator) Decoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Decoder) void {
        self.buf.deinit(self.allocator);
        self.paste.deinit(self.allocator);
    }

    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        if (self.pos == self.buf.items.len) {
            self.buf.clearRetainingCapacity();
            self.pos = 0;
        } else if (self.pos > 4096) {
            const rest = self.buf.items.len - self.pos;
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.pos..]);
            self.buf.shrinkRetainingCapacity(rest);
            self.pos = 0;
        }
        try self.buf.appendSlice(self.allocator, bytes);
    }

    /// True when bytes are waiting that only more input, or a timeout, can
    /// resolve. The run loop uses a short timeout while this holds.
    pub fn pending(self: *const Decoder) bool {
        return self.pos < self.buf.items.len and !self.in_paste;
    }

    /// The next event, or null when more bytes are needed. With `flush` the
    /// input is taken as complete: a held-back ESC becomes the Escape key and
    /// an unfinished sequence is dropped.
    pub fn next(self: *Decoder, flush: bool) ?Event {
        while (true) {
            if (self.in_paste) return self.continuePaste();
            const rest = self.buf.items[self.pos..];
            if (rest.len == 0) return null;
            switch (parse(rest, flush)) {
                .incomplete => return null,
                .skip => |n| self.pos += n,
                .event => |r| {
                    self.pos += r.len;
                    return r.event;
                },
                .paste_begin => |n| {
                    self.pos += n;
                    self.in_paste = true;
                    self.paste.clearRetainingCapacity();
                },
            }
        }
    }

    fn continuePaste(self: *Decoder) ?Event {
        const rest = self.buf.items[self.pos..];
        if (std.mem.indexOf(u8, rest, paste_end)) |at| {
            self.paste.appendSlice(self.allocator, rest[0..at]) catch {};
            self.pos += at + paste_end.len;
            self.in_paste = false;
            return .{ .paste = self.paste.items };
        }
        // Keep back a tail that could be the start of the end marker.
        const keep = @min(rest.len, paste_end.len - 1);
        const take = rest.len - keep;
        self.paste.appendSlice(self.allocator, rest[0..take]) catch {};
        self.pos += take;
        return null;
    }
};

const Parsed = union(enum) {
    incomplete,
    /// Bytes that mean nothing to the editor.
    skip: usize,
    event: struct { event: Event, len: usize },
    paste_begin: usize,
};

fn key(k: Key, len: usize) Parsed {
    return .{ .event = .{ .event = .{ .key = k }, .len = len } };
}

fn parse(bytes: []const u8, flush: bool) Parsed {
    const b = bytes[0];
    if (b == 0x1b) return parseEscape(bytes, flush);
    if (b < 0x20 or b == 0x7f) return key(controlKey(b), 1);
    if (b < 0x80) return key(Key.char(b), 1);

    const n = std.unicode.utf8ByteSequenceLength(b) catch return .{ .skip = 1 };
    if (bytes.len < n) return if (flush) .{ .skip = bytes.len } else .incomplete;
    const cp = std.unicode.utf8Decode(bytes[0..n]) catch return .{ .skip = 1 };
    return key(Key.char(cp), n);
}

/// The key behind a C0 control byte.
fn controlKey(b: u8) Key {
    return switch (b) {
        0x00 => Key.ctrl(' '),
        0x09 => .{ .special = .tab },
        0x0a, 0x0d => .{ .special = .enter },
        0x08, 0x7f => .{ .special = .backspace },
        0x1b => .{ .special = .esc },
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => Key.ctrl(@as(u21, b) + 'a' - 1),
        0x1c => Key.ctrl('\\'),
        0x1d => Key.ctrl(']'),
        0x1e => Key.ctrl('^'),
        0x1f => Key.ctrl('/'),
        else => unreachable,
    };
}

fn parseEscape(bytes: []const u8, flush: bool) Parsed {
    if (bytes.len == 1) {
        return if (flush) key(.{ .special = .esc }, 1) else .incomplete;
    }
    switch (bytes[1]) {
        '[' => return parseCsi(bytes, flush),
        'O' => {
            // SS3: the application-mode spelling of arrows and F1-F4.
            if (bytes.len < 3) return if (flush) key(.{ .cp = 'o', .mods = .{ .alt = true, .shift = true } }, 2) else .incomplete;
            const special: Special = switch (bytes[2]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                'P' => .f1,
                'Q' => .f2,
                'R' => .f3,
                'S' => .f4,
                else => return .{ .skip = 3 },
            };
            return key(.{ .special = special }, 3);
        },
        // ESC ESC: the first is the Escape key; the second starts over.
        0x1b => return key(.{ .special = .esc }, 1),
        else => {
            // ESC followed by a key is that key with Alt held.
            switch (parse(bytes[1..], flush)) {
                .event => |r| switch (r.event) {
                    .key => |k| {
                        var with_alt = k;
                        with_alt.mods.alt = true;
                        if (with_alt.cp >= 'A' and with_alt.cp <= 'Z') {
                            with_alt.cp += 'a' - 'A';
                            with_alt.mods.shift = true;
                        }
                        return key(with_alt, 1 + r.len);
                    },
                    else => return .{ .skip = 1 },
                },
                .incomplete => return .incomplete,
                else => return .{ .skip = 1 },
            }
        },
    }
}

fn modsFrom(param: u16) Mods {
    const bits = if (param == 0) 0 else param - 1;
    return .{ .shift = bits & 1 != 0, .alt = bits & 2 != 0, .ctrl = bits & 4 != 0 };
}

fn parseCsi(bytes: []const u8, flush: bool) Parsed {
    // ESC [ parameters(0x30-0x3f) intermediates(0x20-0x2f) final(0x40-0x7e)
    var i: usize = 2;
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x3f) i += 1;
    if (i >= bytes.len) {
        // Unfinished. A real sequence is short; anything longer is noise.
        if (flush or bytes.len > 64) return .{ .skip = bytes.len };
        return .incomplete;
    }
    const final = bytes[i];
    const len = i + 1;
    if (final < 0x40 or final > 0x7e) return .{ .skip = len };
    const body = bytes[2..i];

    if (body.len > 0 and body[0] == '<') return parseMouse(body[1..], final, len);

    var params = [_]u16{0} ** 4;
    var count: usize = 0;
    for (body) |c| {
        if (c >= '0' and c <= '9') {
            params[count] = params[count] *| 10 +| (c - '0');
        } else if (c == ';') {
            if (count < params.len - 1) count += 1;
        } else if (c == ':') {
            // Sub-parameters (kitty): not used, but must not corrupt the rest.
            return .{ .skip = len };
        } else {
            return .{ .skip = len };
        }
    }
    const mods = modsFrom(params[1]);

    const special: Special = switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'P' => .f1,
        'Q' => .f2,
        'R' => .f3,
        'S' => .f4,
        'Z' => return key(.{ .special = .tab, .mods = .{ .shift = true } }, len),
        'I' => return .{ .event = .{ .event = .{ .focus = true }, .len = len } },
        'O' => return .{ .event = .{ .event = .{ .focus = false }, .len = len } },
        '~' => switch (params[0]) {
            1, 7 => .home,
            4, 8 => .end,
            2 => .insert,
            3 => .delete,
            5 => .page_up,
            6 => .page_down,
            11 => .f1,
            12 => .f2,
            13 => .f3,
            14 => .f4,
            15 => .f5,
            17 => .f6,
            18 => .f7,
            19 => .f8,
            20 => .f9,
            21 => .f10,
            23 => .f11,
            24 => .f12,
            200 => return .{ .paste_begin = len },
            else => return .{ .skip = len },
        },
        // CSI u: a key by codepoint, for terminals that spell them out.
        'u' => {
            const cp: u21 = params[0];
            var k: Key = switch (cp) {
                9 => .{ .special = .tab },
                13 => .{ .special = .enter },
                27 => .{ .special = .esc },
                127 => .{ .special = .backspace },
                0x20...0x7e => .{ .cp = cp },
                else => return .{ .skip = len },
            };
            k.mods = mods;
            if (k.cp >= 'A' and k.cp <= 'Z' and (mods.ctrl or mods.alt)) k.cp += 'a' - 'A';
            // Shift on a plain character is already in the character.
            if (k.special == .none and !mods.ctrl and !mods.alt) k.mods.shift = false;
            return key(k, len);
        },
        else => return .{ .skip = len },
    };
    return key(.{ .special = special, .mods = mods }, len);
}

/// SGR mouse report: `ESC [ < button ; x ; y M` (press, motion) or `m`
/// (release), coordinates 1-based.
fn parseMouse(body: []const u8, final: u8, len: usize) Parsed {
    if (final != 'M' and final != 'm') return .{ .skip = len };
    var params = [_]u16{0} ** 3;
    var count: usize = 0;
    for (body) |c| {
        if (c >= '0' and c <= '9') {
            params[count] = params[count] *| 10 +| (c - '0');
        } else if (c == ';' and count < 2) {
            count += 1;
        } else {
            return .{ .skip = len };
        }
    }
    if (count != 2 or params[1] == 0 or params[2] == 0) return .{ .skip = len };
    const code = params[0];
    var mouse = event.Mouse{
        .kind = .press,
        .x = params[1] - 1,
        .y = params[2] - 1,
        .mods = .{ .shift = code & 4 != 0, .alt = code & 8 != 0, .ctrl = code & 16 != 0 },
    };
    const button: event.Mouse.Button = switch (code & 3) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .none,
    };
    if (code & 64 != 0) {
        mouse.kind = if (code & 1 == 0) .wheel_up else .wheel_down;
    } else if (code & 32 != 0) {
        mouse.kind = if (button == .none) .move else .drag;
        mouse.button = button;
    } else {
        mouse.kind = if (final == 'm') .release else .press;
        mouse.button = button;
    }
    return .{ .event = .{ .event = .{ .mouse = mouse }, .len = len } };
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Decode `bytes` in one piece and write a readable transcript: one event
/// per line.
fn transcript(allocator: Allocator, decoder: *Decoder, out: *std.ArrayList(u8), flush: bool) !void {
    while (decoder.next(flush)) |ev| {
        var buf: [64]u8 = undefined;
        switch (ev) {
            .key => |k| try out.appendSlice(allocator, k.format(&buf)),
            .mouse => |m| try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "mouse {s} {s} {d},{d}{s}", .{
                @tagName(m.kind), @tagName(m.button), m.x, m.y, if (m.mods.ctrl) " ctrl" else "",
            })),
            .paste => |text| {
                try out.appendSlice(allocator, "paste:");
                try out.appendSlice(allocator, text);
            },
            .focus => |on| try out.appendSlice(allocator, if (on) "focus in" else "focus out"),
            .resize => try out.appendSlice(allocator, "resize"),
        }
        try out.append(allocator, '\n');
    }
}

fn expectDecodes(bytes: []const u8, expected: []const u8) !void {
    var decoder = Decoder.init(testing.allocator);
    defer decoder.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    try decoder.feed(bytes);
    try transcript(testing.allocator, &decoder, &out, true);
    try testing.expectEqualStrings(expected, out.items);
}

test "text, control keys and utf-8" {
    try expectDecodes("a", "a\n");
    try expectDecodes("A", "A\n");
    try expectDecodes("\x13", "ctrl+s\n");
    try expectDecodes("\r", "enter\n");
    try expectDecodes("\t", "tab\n");
    try expectDecodes("\x7f", "backspace\n");
    try expectDecodes("\x1f", "ctrl+/\n");
    try expectDecodes("\x00", "ctrl+space\n");
    try expectDecodes("h\xc3\xa9\xe4\xb8\xad", "h\n\xc3\xa9\n\xe4\xb8\xad\n");
    try expectDecodes("\xf0\x9f\x98\x80", "\xf0\x9f\x98\x80\n");
    // A stray continuation byte is dropped, not turned into a key.
    try expectDecodes("\x80a", "a\n");
}

test "arrows, navigation and function keys with modifiers" {
    try expectDecodes("\x1b[A", "up\n");
    try expectDecodes("\x1b[1;2A", "shift+up\n");
    try expectDecodes("\x1b[1;5C", "ctrl+right\n");
    try expectDecodes("\x1b[1;6D", "ctrl+shift+left\n");
    try expectDecodes("\x1b[1;7B", "ctrl+alt+down\n");
    try expectDecodes("\x1b[H\x1b[F", "home\nend\n");
    try expectDecodes("\x1b[1~\x1b[4~", "home\nend\n");
    try expectDecodes("\x1b[3~", "delete\n");
    try expectDecodes("\x1b[3;5~", "ctrl+delete\n");
    try expectDecodes("\x1b[5~\x1b[6;5~", "pgup\nctrl+pgdn\n");
    try expectDecodes("\x1bOP\x1bOQ\x1bOR\x1bOS", "f1\nf2\nf3\nf4\n");
    try expectDecodes("\x1b[1;2R", "shift+f3\n");
    try expectDecodes("\x1b[15~\x1b[17~\x1b[18;2~\x1b[24~", "f5\nf6\nshift+f7\nf12\n");
    try expectDecodes("\x1b[Z", "shift+tab\n");
    try expectDecodes("\x1bOA", "up\n");
}

test "escape alone, escape twice and alt keys" {
    try expectDecodes("\x1b", "esc\n");
    try expectDecodes("\x1b\x1b", "esc\nesc\n");
    try expectDecodes("\x1bx", "alt+x\n");
    try expectDecodes("\x1bX", "alt+shift+x\n");
    try expectDecodes("\x1b\x7f", "alt+backspace\n");
    try expectDecodes("\x1b\x1b[A", "esc\nup\n");
}

test "a lone escape waits for more input until flushed" {
    var decoder = Decoder.init(testing.allocator);
    defer decoder.deinit();
    try decoder.feed("\x1b");
    try testing.expect(decoder.next(false) == null);
    try testing.expect(decoder.pending());
    try decoder.feed("[A");
    try testing.expectEqual(Special.up, decoder.next(false).?.key.special);
    try testing.expect(!decoder.pending());

    try decoder.feed("\x1b");
    try testing.expect(decoder.next(false) == null);
    try testing.expectEqual(Special.esc, decoder.next(true).?.key.special);
    try testing.expect(decoder.next(true) == null);
}

test "mouse reports" {
    try expectDecodes("\x1b[<0;5;3M", "mouse press left 4,2\n");
    try expectDecodes("\x1b[<0;5;3m", "mouse release left 4,2\n");
    try expectDecodes("\x1b[<2;1;1M", "mouse press right 0,0\n");
    try expectDecodes("\x1b[<32;10;2M", "mouse drag left 9,1\n");
    try expectDecodes("\x1b[<35;10;2M", "mouse move none 9,1\n");
    try expectDecodes("\x1b[<64;1;1M\x1b[<65;1;1M", "mouse wheel_up none 0,0\nmouse wheel_down none 0,0\n");
    try expectDecodes("\x1b[<16;2;2M", "mouse press left 1,1 ctrl\n");
    // Malformed reports are dropped.
    try expectDecodes("\x1b[<0;5Ma", "a\n");
    try expectDecodes("\x1b[<0;0;0Ma", "a\n");
}

test "focus and unknown sequences" {
    try expectDecodes("\x1b[I\x1b[O", "focus in\nfocus out\n");
    try expectDecodes("\x1b[?1;2ca", "a\n");
    try expectDecodes("\x1b[99~a", "a\n");
    try expectDecodes("\x1b[97;5u", "ctrl+a\n");
    try expectDecodes("\x1b[13;2u", "shift+enter\n");
}

test "bracketed paste arrives as one event, escapes and all" {
    try expectDecodes("\x1b[200~hello\r\n\x1b[A world\x1b[201~x", "paste:hello\r\n\x1b[A world\nx\n");
    try expectDecodes("\x1b[200~\x1b[201~", "paste:\n");
}

test "any split of the input decodes the same" {
    const input = "a\xc3\xa9\x1b[1;5C\x1b[<0;5;3M\x1bOP\x13\x1b[200~pa\x1bste\x1b[201~\xf0\x9f\x98\x80\x1b[6~z";
    var whole = std.ArrayList(u8).empty;
    defer whole.deinit(testing.allocator);
    {
        var decoder = Decoder.init(testing.allocator);
        defer decoder.deinit();
        try decoder.feed(input);
        try transcript(testing.allocator, &decoder, &whole, true);
    }
    // Every way of cutting the input in two.
    for (1..input.len) |cut| {
        var decoder = Decoder.init(testing.allocator);
        defer decoder.deinit();
        var out = std.ArrayList(u8).empty;
        defer out.deinit(testing.allocator);
        try decoder.feed(input[0..cut]);
        try transcript(testing.allocator, &decoder, &out, false);
        try decoder.feed(input[cut..]);
        try transcript(testing.allocator, &decoder, &out, true);
        try testing.expectEqualStrings(whole.items, out.items);
    }
    // One byte at a time.
    var decoder = Decoder.init(testing.allocator);
    defer decoder.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(testing.allocator);
    for (input) |b| {
        try decoder.feed(&.{b});
        try transcript(testing.allocator, &decoder, &out, false);
    }
    try transcript(testing.allocator, &decoder, &out, true);
    try testing.expectEqualStrings(whole.items, out.items);
}

test "random bytes never crash the decoder" {
    var prng = std.Random.DefaultPrng.init(0x6d696269);
    const random = prng.random();
    var decoder = Decoder.init(testing.allocator);
    defer decoder.deinit();
    const interesting = "\x1b[<;~MmOuZ0123456789\x7f\xc3\xf0\x80";
    var round: usize = 0;
    while (round < 4000) : (round += 1) {
        var chunk: [24]u8 = undefined;
        const n = random.intRangeAtMost(usize, 1, chunk.len);
        for (chunk[0..n]) |*b| {
            b.* = if (random.boolean()) interesting[random.uintLessThan(usize, interesting.len)] else random.int(u8);
        }
        try decoder.feed(chunk[0..n]);
        const flush = random.uintLessThan(u8, 4) == 0;
        while (decoder.next(flush)) |_| {}
    }
}
