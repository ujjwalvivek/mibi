//! A small regular-expression engine: parse a pattern to bytecode and run it
//! with a backtracking VM. Supports literals, `.`, character classes, escapes
//! (`\d \w \s \b \n \t`), groups, alternation, anchors and the quantifiers
//! `* + ? {n} {n,} {n,m}` (with an optional lazy `?`).

const std = @import("std");

pub const Error = error{ Parse, OutOfMemory };

pub const Class = struct {
    negated: bool = false,
    /// Ranges of bytes; single bytes are stored as [c, c].
    ranges: std.ArrayList([2]u8),

    pub fn matches(self: *const Class, c: u8) bool {
        var hit = false;
        for (self.ranges.items) |r| {
            if (c >= r[0] and c <= r[1]) {
                hit = true;
                break;
            }
        }
        return hit != self.negated;
    }
};

pub const Inst = union(enum) {
    char: u8,
    any,
    class: usize,
    split: [2]usize,
    jmp: usize,
    bol,
    eol,
    word_boundary,
    not_word_boundary,
    /// Record the current position in a capture slot (group start/end).
    save: usize,
    accept,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    insts: std.ArrayList(Inst),
    classes: std.ArrayList(Class),
    /// Number of capture groups (slots = 2 per group, group 0 is the whole match).
    groups: usize = 0,

    pub fn deinit(self: *Program) void {
        for (self.classes.items) |*c| c.ranges.deinit(self.allocator);
        self.classes.deinit(self.allocator);
        self.insts.deinit(self.allocator);
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    pos: usize = 0,
    groups: usize = 0,
    prog: *Program,

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.pattern.len) self.pattern[self.pos] else null;
    }

    fn next(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.pos += 1;
        return c;
    }

    fn emit(self: *Parser, inst: Inst) !usize {
        try self.prog.insts.append(self.allocator, inst);
        return self.prog.insts.items.len - 1;
    }

    /// alternation := concat ('|' concat)*
    fn parseAlternation(self: *Parser) Error!void {
        const split_idx = try self.emit(.{ .split = .{ 0, 0 } });
        try self.parseConcat();
        if (self.peek() == '|') {
            _ = self.next();
            const jmp_idx = try self.emit(.{ .jmp = 0 });
            try self.parseAlternation();
            // Both branches converge here.
            const cont = self.prog.insts.items.len;
            self.prog.insts.items[split_idx] = .{ .split = .{ split_idx + 1, jmp_idx + 1 } };
            self.prog.insts.items[jmp_idx] = .{ .jmp = cont };
        } else {
            self.prog.insts.items[split_idx] = .{ .split = .{ split_idx + 1, split_idx + 1 } };
        }
    }

    fn parseConcat(self: *Parser) Error!void {
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try self.parseRepeat();
        }
    }

    /// Quantifiers. The atom is always the last thing emitted, so the parser
    /// truncates it and re-parses it once per copy; that avoids patching jump
    /// targets across duplicated code.
    fn parseRepeat(self: *Parser) Error!void {
        const atom_pos = self.pos;
        const atom_start = self.prog.insts.items.len;
        try self.parseAtom();
        const atom_end = self.prog.insts.items.len;
        if (atom_end == atom_start) return; // empty atom: nothing to repeat

        const c = self.peek() orelse return;
        var end_pos: usize = self.pos;
        switch (c) {
            '*' => {
                _ = self.next();
                const is_lazy = self.lazy();
                end_pos = self.pos;
                self.prog.insts.shrinkRetainingCapacity(atom_start);
                const split_idx = try self.emit(.{ .split = .{ 0, 0 } });
                self.pos = atom_pos;
                try self.parseAtom();
                try self.prog.insts.append(self.allocator, .{ .jmp = split_idx });
                const exit = self.prog.insts.items.len;
                self.prog.insts.items[split_idx] = if (is_lazy)
                    .{ .split = .{ exit, split_idx + 1 } }
                else
                    .{ .split = .{ split_idx + 1, exit } };
            },
            '+' => {
                _ = self.next();
                const is_lazy = self.lazy();
                end_pos = self.pos;
                const split_idx = try self.emit(.{ .split = .{ atom_start, atom_end + 1 } });
                if (is_lazy) self.prog.insts.items[split_idx] = .{ .split = .{ atom_end + 1, atom_start } };
            },
            '?' => {
                _ = self.next();
                const is_lazy = self.lazy();
                end_pos = self.pos;
                self.prog.insts.shrinkRetainingCapacity(atom_start);
                const split_idx = try self.emit(.{ .split = .{ 0, 0 } });
                self.pos = atom_pos;
                try self.parseAtom();
                const exit = self.prog.insts.items.len;
                self.prog.insts.items[split_idx] = if (is_lazy)
                    .{ .split = .{ exit, split_idx + 1 } }
                else
                    .{ .split = .{ split_idx + 1, exit } };
            },
            '{' => {
                const saved = self.pos;
                _ = self.next();
                var lo: usize = 0;
                var digits: usize = 0;
                while (self.peek()) |ch| {
                    if (ch >= '0' and ch <= '9') {
                        digits = digits * 10 + (ch - '0');
                        _ = self.next();
                    } else break;
                }
                if (digits == 0 and self.peek() != ',') {
                    self.pos = saved; // literal '{'
                    return;
                }
                lo = digits;
                var hi: ?usize = lo;
                if (self.peek() == ',') {
                    _ = self.next();
                    var d2: usize = 0;
                    var any = false;
                    while (self.peek()) |ch| {
                        if (ch >= '0' and ch <= '9') {
                            d2 = d2 * 10 + (ch - '0');
                            any = true;
                            _ = self.next();
                        } else break;
                    }
                    hi = if (any) d2 else null;
                }
                if (self.peek() == '}') _ = self.next();
                end_pos = self.pos;
                if (lo > 64 or (hi orelse 0) > 64) return; // refuse absurd counts

                self.prog.insts.shrinkRetainingCapacity(atom_start);
                var copies: usize = 0;
                while (copies < lo) : (copies += 1) {
                    self.pos = atom_pos;
                    try self.parseAtom();
                }
                var splits = std.ArrayList(usize).empty;
                defer splits.deinit(self.allocator);
                if (hi) |h| {
                    while (copies < h) : (copies += 1) {
                        const split_idx = try self.emit(.{ .split = .{ 0, 0 } });
                        try splits.append(self.allocator, split_idx);
                        self.pos = atom_pos;
                        try self.parseAtom();
                    }
                    const exit = self.prog.insts.items.len;
                    for (splits.items) |si| {
                        self.prog.insts.items[si] = .{ .split = .{ si + 1, exit } };
                    }
                } else {
                    // {n,}: n copies then a star.
                    const split_idx = try self.emit(.{ .split = .{ 0, 0 } });
                    self.pos = atom_pos;
                    try self.parseAtom();
                    try self.prog.insts.append(self.allocator, .{ .jmp = split_idx });
                    const exit = self.prog.insts.items.len;
                    self.prog.insts.items[split_idx] = .{ .split = .{ split_idx + 1, exit } };
                }
            },
            else => {},
        }
        self.pos = end_pos;
    }

    /// Optional lazy marker after a quantifier (`*?`, `+?`, `??`).
    fn lazy(self: *Parser) bool {
        if (self.peek() == '?') {
            _ = self.next();
            return true;
        }
        return false;
    }

    fn parseAtom(self: *Parser) Error!void {
        const c = self.next() orelse return;
        switch (c) {
            '(' => {
                var capturing = true;
                if (self.peek() == '?') {
                    _ = self.next();
                    if (self.peek() == ':') {
                        _ = self.next();
                        capturing = false;
                    }
                }
                var slot: usize = 0;
                if (capturing) {
                    self.groups += 1;
                    slot = self.groups; // groups are numbered from 1
                    _ = try self.emit(.{ .save = slot * 2 });
                }
                try self.parseAlternation();
                if (self.peek() == ')') _ = self.next();
                if (capturing) _ = try self.emit(.{ .save = slot * 2 + 1 });
            },
            '[' => try self.parseClass(),
            '.' => _ = try self.emit(.{.any = {}}),
            '^' => _ = try self.emit(.{.bol = {}}),
            '$' => _ = try self.emit(.{.eol = {}}),
            '\\' => try self.parseEscape(),
            else => _ = try self.emit(.{ .char = c }),
        }
    }

    fn parseEscape(self: *Parser) Error!void {
        const c = self.next() orelse return;
        switch (c) {
            'd' => try self.emitClass("0-9", false),
            'D' => try self.emitClass("0-9", true),
            'w' => try self.emitClass("a-zA-Z0-9_", false),
            'W' => try self.emitClass("a-zA-Z0-9_", true),
            's' => try self.emitClass(" \\t\\r\\n", false),
            'S' => try self.emitClass(" \\t\\r\\n", true),
            'b' => _ = try self.emit(.{.word_boundary = {}}),
            'B' => _ = try self.emit(.{.not_word_boundary = {}}),
            'n' => _ = try self.emit(.{ .char = '\n' }),
            't' => _ = try self.emit(.{ .char = '\t' }),
            'r' => _ = try self.emit(.{ .char = '\r' }),
            else => _ = try self.emit(.{ .char = c }),
        }
    }

    fn emitClass(self: *Parser, spec: []const u8, negated: bool) Error!void {
        var class = Class{ .negated = negated, .ranges = std.ArrayList([2]u8).empty };
        var i: usize = 0;
        while (i < spec.len) : (i += 1) {
            if (i + 2 < spec.len and spec[i + 1] == '-') {
                try class.ranges.append(self.allocator, .{ spec[i], spec[i + 2] });
                i += 2;
            } else {
                try class.ranges.append(self.allocator, .{ spec[i], spec[i] });
            }
        }
        try self.prog.classes.append(self.allocator, class);
        _ = try self.emit(.{ .class = self.prog.classes.items.len - 1 });
    }

    fn parseClass(self: *Parser) Error!void {
        var class = Class{ .ranges = std.ArrayList([2]u8).empty };
        if (self.peek() == '^') {
            _ = self.next();
            class.negated = true;
        }
        while (self.peek()) |c| {
            if (c == ']') {
                _ = self.next();
                break;
            }
            _ = self.next();
            if (c == '\\') {
                const esc = self.next() orelse break;
                switch (esc) {
                    'd' => {
                        try class.ranges.append(self.allocator, .{ '0', '9' });
                        continue;
                    },
                    'w' => {
                        try class.ranges.append(self.allocator, .{ 'a', 'z' });
                        try class.ranges.append(self.allocator, .{ 'A', 'Z' });
                        try class.ranges.append(self.allocator, .{ '0', '9' });
                        try class.ranges.append(self.allocator, .{ '_', '_' });
                        continue;
                    },
                    's' => {
                        try class.ranges.append(self.allocator, .{ ' ', ' ' });
                        try class.ranges.append(self.allocator, .{ '\t', '\t' });
                        try class.ranges.append(self.allocator, .{ '\r', '\r' });
                        try class.ranges.append(self.allocator, .{ '\n', '\n' });
                        continue;
                    },
                    else => {
                        try class.ranges.append(self.allocator, .{ esc, esc });
                        continue;
                    },
                }
            }
            if (self.peek() == '-' and self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] != ']') {
                _ = self.next();
                const hi = self.next() orelse break;
                try class.ranges.append(self.allocator, .{ c, hi });
            } else {
                try class.ranges.append(self.allocator, .{ c, c });
            }
        }
        try self.prog.classes.append(self.allocator, class);
        _ = try self.emit(.{ .class = self.prog.classes.items.len - 1 });
    }
};

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) Error!Program {
    var prog = Program{
        .allocator = allocator,
        .insts = std.ArrayList(Inst).empty,
        .classes = std.ArrayList(Class).empty,
    };
    var parser = Parser{ .allocator = allocator, .pattern = pattern, .prog = &prog };
    parser.parseAlternation() catch |e| {
        prog.deinit();
        return e;
    };
    prog.groups = parser.groups;
    return prog;
}

pub const Match = struct { start: usize, end: usize };
pub const MAX_SLOTS = 20;

const MAX_STEPS = 200_000;

/// Find the leftmost match at or after `from`.
pub fn find(prog: *const Program, text: []const u8, from: usize) ?Match {
    var caps: [MAX_SLOTS]?usize = .{null} ** MAX_SLOTS;
    return findCaptures(prog, text, from, &caps);
}

/// Like `find`, and fills `caps` with the capture positions on success
/// (slot 2n = group n start, 2n+1 = end; group 0 is the whole match).
pub fn findCaptures(prog: *const Program, text: []const u8, from: usize, caps: *[MAX_SLOTS]?usize) ?Match {
    var steps: usize = 0;
    var start = from;
    while (start <= text.len) : (start += 1) {
        for (caps) |*c| c.* = null;
        if (matchAt(prog, text, start, 0, &steps, caps)) |end| {
            caps[0] = start;
            caps[1] = end;
            return .{ .start = start, .end = end };
        }
        if (steps > MAX_STEPS) return null;
    }
    return null;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn matchAt(prog: *const Program, text: []const u8, pos: usize, pc: usize, steps: *usize, caps: *[MAX_SLOTS]?usize) ?usize {
    steps.* += 1;
    if (steps.* > MAX_STEPS) return null;
    if (pc >= prog.insts.items.len) return pos;
    switch (prog.insts.items[pc]) {
        .char => |c| {
            if (pos < text.len and text[pos] == c) return matchAt(prog, text, pos + 1, pc + 1, steps, caps);
            return null;
        },
        .any => {
            if (pos < text.len and text[pos] != '\n') return matchAt(prog, text, pos + 1, pc + 1, steps, caps);
            return null;
        },
        .class => |ci| {
            if (pos < text.len and prog.classes.items[ci].matches(text[pos]))
                return matchAt(prog, text, pos + 1, pc + 1, steps, caps);
            return null;
        },
        .split => |s| {
            if (matchAt(prog, text, pos, s[0], steps, caps)) |end| return end;
            return matchAt(prog, text, pos, s[1], steps, caps);
        },
        .jmp => |t| return matchAt(prog, text, pos, t, steps, caps),
        .bol => {
            if (pos == 0 or text[pos - 1] == '\n') return matchAt(prog, text, pos, pc + 1, steps, caps);
            return null;
        },
        .eol => {
            if (pos == text.len or text[pos] == '\n') return matchAt(prog, text, pos, pc + 1, steps, caps);
            return null;
        },
        .word_boundary => {
            const before = pos > 0 and isWordByte(text[pos - 1]);
            const after = pos < text.len and isWordByte(text[pos]);
            if (before != after) return matchAt(prog, text, pos, pc + 1, steps, caps);
            return null;
        },
        .not_word_boundary => {
            const before = pos > 0 and isWordByte(text[pos - 1]);
            const after = pos < text.len and isWordByte(text[pos]);
            if (before == after) return matchAt(prog, text, pos, pc + 1, steps, caps);
            return null;
        },
        .save => |slot| {
            if (slot < caps.len) caps[slot] = pos;
            return matchAt(prog, text, pos, pc + 1, steps, caps);
        },
        .accept => return pos,
    }
}

// --- tests -----------------------------------------------------------------
test "literal and dot matching" {
    const a = std.testing.allocator;
    var p = try compile(a, "a.c");
    defer p.deinit();
    try std.testing.expect(find(&p, "xxabcxx", 0) != null);
    const m = find(&p, "xxabcxx", 0).?;
    try std.testing.expectEqual(@as(usize, 2), m.start);
    try std.testing.expectEqual(@as(usize, 5), m.end);
    try std.testing.expect(find(&p, "xxaxcxx", 0) != null);
    try std.testing.expect(find(&p, "xxacxx", 0) == null);
}

test "classes, anchors and quantifiers" {
    const a = std.testing.allocator;
    var p = try compile(a, "^[a-z]+$");
    defer p.deinit();
    try std.testing.expect(find(&p, "hello", 0) != null);
    try std.testing.expect(find(&p, "Hello", 0) == null);
    try std.testing.expect(find(&p, "hello world", 0) == null);

    var q = try compile(a, "\\d+");
    defer q.deinit();
    const m = find(&q, "abc 123 def", 0).?;
    try std.testing.expectEqual(@as(usize, 4), m.start);
    try std.testing.expectEqual(@as(usize, 7), m.end);
}

test "repetition ranges" {
    const a = std.testing.allocator;
    var p = try compile(a, "a{2,4}");
    defer p.deinit();
    try std.testing.expect(find(&p, "a", 0) == null);
    try std.testing.expect(find(&p, "aa", 0) != null);
    const m = find(&p, "aaaaa", 0).?;
    try std.testing.expectEqual(@as(usize, 4), m.end);

    var q = try compile(a, "x{3}");
    defer q.deinit();
    try std.testing.expect(find(&q, "xx", 0) == null);
    try std.testing.expect(find(&q, "xxx", 0) != null);

    var r = try compile(a, "b{2,}");
    defer r.deinit();
    try std.testing.expect(find(&r, "b", 0) == null);
    const rm = find(&r, "xbbbbby", 0).?;
    try std.testing.expectEqual(@as(usize, 6), rm.end);
}

test "capture groups record their spans" {
    const a = std.testing.allocator;
    var p = try compile(a, "(a+)-(b+)");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 2), p.groups);
    var caps: [MAX_SLOTS]?usize = .{null} ** MAX_SLOTS;
    const m = findCaptures(&p, "xx aa-bbb yy", 0, &caps).?;
    try std.testing.expectEqual(@as(usize, 3), m.start);
    try std.testing.expectEqual(@as(usize, 9), m.end);
    try std.testing.expectEqual(@as(usize, 3), caps[2].?); // group 1 start
    try std.testing.expectEqual(@as(usize, 5), caps[3].?); // group 1 end
    try std.testing.expectEqual(@as(usize, 6), caps[4].?); // group 2 start
    try std.testing.expectEqual(@as(usize, 9), caps[5].?); // group 2 end
}

test "alternation, groups and word boundaries" {
    const a = std.testing.allocator;
    var p = try compile(a, "cat|dog");
    defer p.deinit();
    const m = find(&p, "a dog here", 0).?;
    try std.testing.expectEqual(@as(usize, 2), m.start);

    var g = try compile(a, "(ab)+");
    defer g.deinit();
    const gm = find(&g, "xxababab", 0).?;
    try std.testing.expectEqual(@as(usize, 8), gm.end);

    var b = try compile(a, "\\bfoo\\b");
    defer b.deinit();
    try std.testing.expect(find(&b, "a foo b", 0) != null);
    try std.testing.expect(find(&b, "afoob", 0) == null);
}
