//! Regular expressions: a parser, a compiler to a small bytecode, and a Pike
//! VM that runs it.
//!
//! The VM advances every possible match in lockstep, one codepoint at a time,
//! so the time to search is proportional to (text length x pattern size) for
//! every pattern. There is no backtracking and therefore no pattern that
//! makes the editor hang, and no step limit that makes a search quietly give
//! up.
//!
//! Matching is streaming: the text is fed in chunks, which is how a piece
//! table hands it out, and nothing needs the document as one slice.
//!
//! Syntax: literals, `.`, classes `[a-z]` `[^...]`, `\d \w \s` and their
//! negations, `\b \B`, `^ $` (line anchors), groups `( )` and `(?: )`,
//! alternation `|`, and the quantifiers `* + ? {n} {n,} {n,m}`, each with an
//! optional lazy `?`. Matching is by codepoint; `.` never matches a newline.
//! Semantics are leftmost-first, as in Perl: among matches starting at the
//! same place, the one a backtracking engine would find first.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ Syntax, TooBig, OutOfMemory };

/// Where and why a pattern failed to compile.
pub const Diagnostic = struct {
    offset: usize = 0,
    message: []const u8 = "",
};

pub const Options = struct {
    /// ASCII letters match either case.
    ignore_case: bool = false,
};

/// Capture slots kept per match: group n is slots 2n and 2n+1, group 0 is
/// the whole match. Groups past 9 match but are not recorded, since a
/// replacement can only refer to `$0`..`$9`.
pub const max_slots = 20;
pub const Captures = [max_slots]?usize;

pub const Match = struct {
    start: usize,
    end: usize,
    captures: Captures,
};

/// Largest compiled program. Counted repetition copies its operand, so
/// `(a{500}){500}` would otherwise be a quarter of a million instructions.
const max_insts = 20_000;
const max_repeat = 1000;

const Range = struct { lo: u21, hi: u21 };

const Class = struct {
    negated: bool,
    ranges: []const Range,

    fn has(self: Class, cp: u21) bool {
        for (self.ranges) |r| {
            if (cp >= r.lo and cp <= r.hi) return true;
        }
        return false;
    }
};

const Inst = union(enum) {
    char: u21,
    /// Any codepoint except `\n`.
    any,
    class: u32,
    /// Try `first`, then `second`: the order is the priority.
    split: struct { first: u32, second: u32 },
    jmp: u32,
    line_start,
    line_end,
    word_boundary,
    not_word_boundary,
    save: u32,
    match,
};

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    insts: []const Inst = &.{},
    classes: []const Class = &.{},
    groups: usize = 0,
    ignore_case: bool = false,
    /// When every match must start with this byte, the searcher can skip
    /// ahead to it instead of stepping the VM over every codepoint.
    first_byte: ?u8 = null,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

// --- parser --------------------------------------------------------------

const Node = union(enum) {
    empty,
    char: u21,
    any,
    class: Class,
    line_start,
    line_end,
    word_boundary,
    not_word_boundary,
    concat: []const *const Node,
    alternate: []const *const Node,
    repeat: struct { node: *const Node, min: u32, max: ?u32, greedy: bool },
    /// `index` 0 is a non-capturing group.
    group: struct { node: *const Node, index: u32 },
};

const Parser = struct {
    a: Allocator,
    pattern: []const u8,
    pos: usize = 0,
    groups: u32 = 0,
    diagnostic: ?*Diagnostic,

    fn fail(self: *Parser, offset: usize, message: []const u8) Error {
        if (self.diagnostic) |d| d.* = .{ .offset = offset, .message = message };
        return error.Syntax;
    }

    fn peek(self: *const Parser) ?u8 {
        return if (self.pos < self.pattern.len) self.pattern[self.pos] else null;
    }

    fn eat(self: *Parser, c: u8) bool {
        if (self.peek() != c) return false;
        self.pos += 1;
        return true;
    }

    fn node(self: *Parser, value: Node) Error!*const Node {
        const n = try self.a.create(Node);
        n.* = value;
        return n;
    }

    /// The codepoint at the cursor. A byte that is not valid UTF-8 stands
    /// for itself, so any input can be searched for.
    fn codepoint(self: *Parser) u21 {
        const b = self.pattern[self.pos];
        const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
        if (len > 1 and self.pos + len <= self.pattern.len) {
            if (std.unicode.utf8Decode(self.pattern[self.pos..][0..len])) |cp| {
                self.pos += len;
                return cp;
            } else |_| {}
        }
        self.pos += 1;
        return b;
    }

    fn parseAlternate(self: *Parser) Error!*const Node {
        var branches = std.ArrayList(*const Node).empty;
        try branches.append(self.a, try self.parseConcat());
        while (self.eat('|')) try branches.append(self.a, try self.parseConcat());
        if (branches.items.len == 1) return branches.items[0];
        return self.node(.{ .alternate = branches.items });
    }

    fn parseConcat(self: *Parser) Error!*const Node {
        var parts = std.ArrayList(*const Node).empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try parts.append(self.a, try self.parseRepeat());
        }
        if (parts.items.len == 0) return self.node(.empty);
        if (parts.items.len == 1) return parts.items[0];
        return self.node(.{ .concat = parts.items });
    }

    fn parseRepeat(self: *Parser) Error!*const Node {
        const at = self.pos;
        var atom = try self.parseAtom();
        while (self.peek()) |c| {
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (c) {
                '*' => self.pos += 1,
                '+' => {
                    self.pos += 1;
                    min = 1;
                },
                '?' => {
                    self.pos += 1;
                    max = 1;
                },
                '{' => {
                    const counted = self.parseCount() orelse break; // a literal `{`
                    min = counted.min;
                    max = counted.max;
                    if (min > max_repeat or (max orelse 0) > max_repeat) return self.fail(at, "repeat count is too large");
                    if (max != null and max.? < min) return self.fail(at, "repeat range is reversed");
                },
                else => break,
            }
            switch (atom.*) {
                .line_start, .line_end, .word_boundary, .not_word_boundary, .empty => return self.fail(at, "nothing to repeat"),
                else => {},
            }
            const greedy = !self.eat('?');
            atom = try self.node(.{ .repeat = .{ .node = atom, .min = min, .max = max, .greedy = greedy } });
        }
        return atom;
    }

    /// `{n}`, `{n,}` or `{n,m}` at the cursor. Anything else is not a
    /// quantifier: the cursor is left alone and the brace is a literal.
    fn parseCount(self: *Parser) ?struct { min: u32, max: ?u32 } {
        const saved = self.pos;
        self.pos += 1;
        const min = self.parseNumber() orelse {
            self.pos = saved;
            return null;
        };
        var max: ?u32 = min;
        if (self.eat(',')) max = self.parseNumber();
        if (!self.eat('}')) {
            self.pos = saved;
            return null;
        }
        return .{ .min = min, .max = max };
    }

    fn parseNumber(self: *Parser) ?u32 {
        const start = self.pos;
        var n: u32 = 0;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            n = @min(n * 10 + (c - '0'), max_repeat + 1);
            self.pos += 1;
        }
        return if (self.pos == start) null else n;
    }

    fn parseAtom(self: *Parser) Error!*const Node {
        const at = self.pos;
        switch (self.pattern[self.pos]) {
            '(' => {
                self.pos += 1;
                var index: u32 = 0;
                if (self.eat('?')) {
                    if (!self.eat(':')) return self.fail(at, "unsupported group; only (?: ) is known");
                } else {
                    self.groups += 1;
                    index = self.groups;
                }
                const inner = try self.parseAlternate();
                if (!self.eat(')')) return self.fail(at, "missing )");
                return self.node(.{ .group = .{ .node = inner, .index = index } });
            },
            '[' => return self.parseClass(),
            '.' => {
                self.pos += 1;
                return self.node(.any);
            },
            '^' => {
                self.pos += 1;
                return self.node(.line_start);
            },
            '$' => {
                self.pos += 1;
                return self.node(.line_end);
            },
            '*', '+', '?' => return self.fail(at, "nothing to repeat"),
            '\\' => return self.parseEscape(),
            else => return self.node(.{ .char = self.codepoint() }),
        }
    }

    const digits = [_]Range{.{ .lo = '0', .hi = '9' }};
    const word = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } };
    const space = [_]Range{ .{ .lo = '\t', .hi = '\r' }, .{ .lo = ' ', .hi = ' ' } };

    /// The ranges of a class escape (`\d`, `\w`, `\s`), or null.
    fn escapeRanges(c: u8) ?[]const Range {
        return switch (c) {
            'd', 'D' => &digits,
            'w', 'W' => &word,
            's', 'S' => &space,
            else => null,
        };
    }

    /// A single-character escape: `\n`, `\t`, or an escaped punctuation
    /// mark. Letters and digits that mean nothing are refused, so a typo is
    /// an error and not a silent literal.
    fn escapedChar(self: *Parser, at: usize) Error!u21 {
        if (self.pos >= self.pattern.len) return self.fail(at, "pattern ends with a backslash");
        const c = self.pattern[self.pos];
        switch (c) {
            'n' => {
                self.pos += 1;
                return '\n';
            },
            't' => {
                self.pos += 1;
                return '\t';
            },
            'r' => {
                self.pos += 1;
                return '\r';
            },
            'a'...'m', 'o'...'q', 's', 'u'...'z', 'A'...'Z', '0'...'9' => return self.fail(at, "unknown escape"),
            else => return self.codepoint(),
        }
    }

    fn parseEscape(self: *Parser) Error!*const Node {
        const at = self.pos;
        self.pos += 1;
        if (self.peek()) |c| {
            if (escapeRanges(c)) |ranges| {
                self.pos += 1;
                return self.node(.{ .class = .{ .negated = std.ascii.isUpper(c), .ranges = ranges } });
            }
            if (c == 'b' or c == 'B') {
                self.pos += 1;
                return self.node(if (c == 'b') .word_boundary else .not_word_boundary);
            }
        }
        return self.node(.{ .char = try self.escapedChar(at) });
    }

    fn parseClass(self: *Parser) Error!*const Node {
        const at = self.pos;
        self.pos += 1;
        const negated = self.eat('^');
        var ranges = std.ArrayList(Range).empty;
        var first = true;
        while (true) : (first = false) {
            const c = self.peek() orelse return self.fail(at, "missing ]");
            // A `]` straight after the opening bracket is a literal.
            if (c == ']' and !first) {
                self.pos += 1;
                break;
            }
            const item_at = self.pos;
            var lo: u21 = undefined;
            if (c == '\\') {
                self.pos += 1;
                if (self.peek()) |e| {
                    if (escapeRanges(e)) |set| {
                        if (std.ascii.isUpper(e)) return self.fail(item_at, "negated escape inside a class");
                        self.pos += 1;
                        try ranges.appendSlice(self.a, set);
                        continue;
                    }
                }
                lo = try self.escapedChar(item_at);
            } else {
                lo = self.codepoint();
            }
            var hi = lo;
            // `a-z`, but a `-` before the closing bracket is a literal.
            if (self.peek() == '-' and self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] != ']') {
                self.pos += 1;
                if (self.peek() == '\\') {
                    const esc_at = self.pos;
                    self.pos += 1;
                    hi = try self.escapedChar(esc_at);
                } else {
                    hi = self.codepoint();
                }
                if (hi < lo) return self.fail(item_at, "class range is reversed");
            }
            try ranges.append(self.a, .{ .lo = lo, .hi = hi });
        }
        return self.node(.{ .class = .{ .negated = negated, .ranges = ranges.items } });
    }
};

// --- compiler ------------------------------------------------------------

const Compiler = struct {
    a: Allocator,
    insts: std.ArrayList(Inst) = .empty,
    classes: std.ArrayList(Class) = .empty,

    fn emit(self: *Compiler, inst: Inst) Error!u32 {
        if (self.insts.items.len >= max_insts) return error.TooBig;
        try self.insts.append(self.a, inst);
        return @intCast(self.insts.items.len - 1);
    }

    fn here(self: *const Compiler) u32 {
        return @intCast(self.insts.items.len);
    }

    /// A split whose preferred branch is the next instruction (`greedy`) or
    /// the far one. The far target is filled in by `patch`.
    fn emitSplit(self: *Compiler) Error!u32 {
        return self.emit(.{ .split = .{ .first = 0, .second = 0 } });
    }

    fn patch(self: *Compiler, split: u32, near: u32, far: u32, greedy: bool) void {
        self.insts.items[split] = .{ .split = if (greedy)
            .{ .first = near, .second = far }
        else
            .{ .first = far, .second = near } };
    }

    fn gen(self: *Compiler, n: *const Node) Error!void {
        switch (n.*) {
            .empty => {},
            .char => |c| _ = try self.emit(.{ .char = c }),
            .any => _ = try self.emit(.any),
            .class => |c| {
                try self.classes.append(self.a, c);
                _ = try self.emit(.{ .class = @intCast(self.classes.items.len - 1) });
            },
            .line_start => _ = try self.emit(.line_start),
            .line_end => _ = try self.emit(.line_end),
            .word_boundary => _ = try self.emit(.word_boundary),
            .not_word_boundary => _ = try self.emit(.not_word_boundary),
            .concat => |parts| for (parts) |p| try self.gen(p),
            .group => |g| {
                if (g.index == 0) return self.gen(g.node);
                _ = try self.emit(.{ .save = g.index * 2 });
                try self.gen(g.node);
                _ = try self.emit(.{ .save = g.index * 2 + 1 });
            },
            .alternate => |branches| {
                // split b1, L2; b1; jmp end; L2: split b2, L3; ... ; bn; end:
                var jumps = std.ArrayList(u32).empty;
                for (branches, 0..) |b, i| {
                    if (i + 1 == branches.len) {
                        try self.gen(b);
                        break;
                    }
                    const split = try self.emitSplit();
                    try self.gen(b);
                    try jumps.append(self.a, try self.emit(.{ .jmp = 0 }));
                    self.patch(split, split + 1, self.here(), true);
                }
                for (jumps.items) |j| self.insts.items[j] = .{ .jmp = self.here() };
            },
            .repeat => |r| {
                // The mandatory copies, all but the last when the tail is an
                // unbounded loop (it loops back over that last copy).
                const looped = r.max == null and r.min > 0;
                var i: u32 = 0;
                while (i + @intFromBool(looped) < r.min) : (i += 1) try self.gen(r.node);
                if (r.max) |max| {
                    // Optional copies, nested: each one can only be reached
                    // through the one before, and all of them exit together.
                    var splits = std.ArrayList(u32).empty;
                    while (i < max) : (i += 1) {
                        try splits.append(self.a, try self.emitSplit());
                        try self.gen(r.node);
                    }
                    for (splits.items) |s| self.patch(s, s + 1, self.here(), r.greedy);
                } else if (looped) {
                    // x+ : L: x; split L, next
                    const start = self.here();
                    try self.gen(r.node);
                    const split = try self.emitSplit();
                    self.patch(split, start, split + 1, r.greedy);
                } else {
                    // x* : L: split body, next; body: x; jmp L
                    const split = try self.emitSplit();
                    try self.gen(r.node);
                    _ = try self.emit(.{ .jmp = split });
                    self.patch(split, split + 1, self.here(), r.greedy);
                }
            },
        }
    }
};

/// The byte every match must begin with, if the pattern makes that certain.
fn firstByte(n: *const Node) ?u8 {
    return switch (n.*) {
        .char => |c| if (c < 0x80) @as(u8, @intCast(c)) else null,
        .concat => |parts| firstByte(parts[0]),
        .group => |g| firstByte(g.node),
        .repeat => |r| if (r.min > 0) firstByte(r.node) else null,
        else => null,
    };
}

/// Compile `pattern`. On `error.Syntax`, `diagnostic` (if given) says where
/// and why.
pub fn compile(allocator: Allocator, pattern: []const u8, options: Options, diagnostic: ?*Diagnostic) Error!Program {
    var program = Program{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer program.arena.deinit();
    // The syntax tree is only needed until the bytecode exists.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    var parser = Parser{ .a = scratch.allocator(), .pattern = pattern, .diagnostic = diagnostic };
    const root = try parser.parseAlternate();
    if (parser.pos < pattern.len) return parser.fail(parser.pos, "unmatched )");

    var compiler = Compiler{ .a = scratch.allocator() };
    try compiler.gen(root);
    _ = try compiler.emit(.match);

    const a = program.arena.allocator();
    program.insts = try a.dupe(Inst, compiler.insts.items);
    const classes = try a.alloc(Class, compiler.classes.items.len);
    for (compiler.classes.items, classes) |c, *out| {
        out.* = .{ .negated = c.negated, .ranges = try a.dupe(Range, c.ranges) };
    }
    program.classes = classes;
    program.groups = parser.groups;
    program.ignore_case = options.ignore_case;
    if (!options.ignore_case) program.first_byte = firstByte(root);
    return program;
}

// --- matcher -------------------------------------------------------------

fn isWord(cp: ?u21) bool {
    const c = cp orelse return false;
    // Everything outside ASCII counts as a word character, the same rule the
    // editor uses for word movement.
    return c >= 0x80 or std.ascii.isAlphanumeric(@intCast(c)) or c == '_';
}

fn foldCase(cp: u21) u21 {
    return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
}

/// Threads in priority order, each a program counter with its captures.
const ThreadList = struct {
    pcs: []u32,
    captures: []?usize,
    len: usize = 0,
    slots: usize,

    fn add(self: *ThreadList, pc: u32, captures: []const ?usize) void {
        self.pcs[self.len] = pc;
        @memcpy(self.capturesOf(self.len), captures);
        self.len += 1;
    }

    fn capturesOf(self: *ThreadList, i: usize) []?usize {
        return self.captures[i * self.slots ..][0..self.slots];
    }
};

/// Runs one program over a stream of text. Allocated once per program; a
/// search allocates nothing.
pub const Matcher = struct {
    allocator: Allocator,
    program: *const Program,
    slots: usize,
    /// Threads waiting for the next codepoint: reached by consuming the last
    /// one, not yet followed through splits and assertions.
    pending: ThreadList,
    /// Threads standing on an instruction that consumes a codepoint.
    current: ThreadList,
    /// Work stack for following splits without recursion.
    stack: []Frame,
    /// Captures of the thread being followed.
    work: []?usize,
    /// `seen[pc] == generation` when `pc` has been reached in this step. Two
    /// threads on one instruction would behave identically from here on, so
    /// only the first (the higher priority) is kept; this is what bounds the
    /// work per codepoint by the size of the program.
    seen: []u32,
    generation: u32 = 0,

    /// Byte offset of the next codepoint.
    pos: usize = 0,
    prev: ?u21 = null,
    best: ?Match = null,
    /// Partial UTF-8 sequence carried between chunks.
    partial: [4]u8 = undefined,
    partial_len: u3 = 0,
    partial_need: u3 = 0,

    const Frame = union(enum) {
        visit: u32,
        restore: struct { slot: u32, value: ?usize },
    };

    pub fn init(allocator: Allocator, program: *const Program) !Matcher {
        const n = program.insts.len;
        const slots = @min(max_slots, 2 * (program.groups + 1));
        var self: Matcher = .{
            .allocator = allocator,
            .program = program,
            .slots = slots,
            .pending = undefined,
            .current = undefined,
            .stack = &.{},
            .work = &.{},
            .seen = &.{},
        };
        self.pending = try makeList(allocator, n, slots);
        errdefer freeList(allocator, &self.pending);
        self.current = try makeList(allocator, n, slots);
        errdefer freeList(allocator, &self.current);
        // Each instruction is visited once per closure and can leave one
        // restore frame behind it.
        self.stack = try allocator.alloc(Frame, 2 * n + 2);
        errdefer allocator.free(self.stack);
        self.work = try allocator.alloc(?usize, slots);
        errdefer allocator.free(self.work);
        self.seen = try allocator.alloc(u32, n);
        @memset(self.seen, 0);
        return self;
    }

    fn makeList(allocator: Allocator, n: usize, slots: usize) !ThreadList {
        const pcs = try allocator.alloc(u32, n);
        errdefer allocator.free(pcs);
        const captures = try allocator.alloc(?usize, n * slots);
        return .{ .pcs = pcs, .captures = captures, .slots = slots };
    }

    fn freeList(allocator: Allocator, list: *ThreadList) void {
        allocator.free(list.pcs);
        allocator.free(list.captures);
    }

    pub fn deinit(self: *Matcher) void {
        freeList(self.allocator, &self.pending);
        freeList(self.allocator, &self.current);
        self.allocator.free(self.stack);
        self.allocator.free(self.work);
        self.allocator.free(self.seen);
        self.* = undefined;
    }

    /// Begin a search at byte offset `pos`. `prev` is the byte before it, if
    /// there is one, so `^` and `\b` see what precedes the search.
    pub fn start(self: *Matcher, pos: usize, prev: ?u8) void {
        self.pos = pos;
        self.prev = if (prev) |b| b else null;
        self.best = null;
        self.pending.len = 0;
        self.partial_len = 0;
        self.partial_need = 0;
    }

    /// Feed the next chunk of text. Returns true once the result is final
    /// and the rest of the text does not need to be seen.
    pub fn feed(self: *Matcher, chunk: []const u8) bool {
        var i: usize = 0;
        while (i < chunk.len) {
            // Nothing in flight and no match yet: every match starts with a
            // known byte, so jump to its next occurrence.
            if (self.program.first_byte) |b| {
                if (self.pending.len == 0 and self.best == null and self.partial_need == 0) {
                    const skip = std.mem.indexOfScalarPos(u8, chunk, i, b) orelse {
                        self.pos += chunk.len - i;
                        self.prev = chunk[chunk.len - 1];
                        return false;
                    };
                    if (skip > i) {
                        self.pos += skip - i;
                        self.prev = chunk[skip - 1];
                        i = skip;
                    }
                }
            }
            const byte = chunk[i];
            i += 1;
            if (self.decode(byte)) |cp| {
                if (self.step(cp.value, cp.len)) return true;
                if (cp.again) {
                    // An invalid sequence ended at a byte that starts a new
                    // one: that byte has not been consumed yet.
                    if (self.decode(byte)) |next| {
                        if (self.step(next.value, next.len)) return true;
                    }
                }
            }
        }
        return false;
    }

    /// The text has ended. Returns the match, if any.
    pub fn finish(self: *Matcher) ?Match {
        if (self.partial_need != 0) {
            // A sequence cut off by the end of the text is one bad codepoint.
            const len = self.partial_len;
            self.partial_need = 0;
            self.partial_len = 0;
            _ = self.step(0xFFFD, len);
        }
        _ = self.step(null, 0);
        return self.best;
    }

    const Decoded = struct { value: u21, len: u3, again: bool = false };

    /// Incremental UTF-8 decoding. Bytes that do not form a valid sequence
    /// come out as U+FFFD, so matching never stalls on binary data.
    fn decode(self: *Matcher, byte: u8) ?Decoded {
        if (self.partial_need == 0) {
            if (byte < 0x80) return .{ .value = byte, .len = 1 };
            const len = std.unicode.utf8ByteSequenceLength(byte) catch return .{ .value = 0xFFFD, .len = 1 };
            self.partial[0] = byte;
            self.partial_len = 1;
            self.partial_need = len - 1;
            return null;
        }
        if (byte & 0xC0 != 0x80) {
            const len = self.partial_len;
            self.partial_need = 0;
            self.partial_len = 0;
            return .{ .value = 0xFFFD, .len = len, .again = true };
        }
        self.partial[self.partial_len] = byte;
        self.partial_len += 1;
        self.partial_need -= 1;
        if (self.partial_need != 0) return null;
        const len = self.partial_len;
        self.partial_len = 0;
        const cp = std.unicode.utf8Decode(self.partial[0..len]) catch 0xFFFD;
        return .{ .value = cp, .len = len };
    }

    /// Advance over one codepoint (`null` at the end of the text). Returns
    /// true when the search is over.
    fn step(self: *Matcher, cp: ?u21, len: usize) bool {
        // Follow the waiting threads to instructions that consume input.
        // This is done now, not when they were created, because `$` and `\b`
        // need to know the codepoint that comes next.
        self.current.len = 0;
        self.generation +%= 1;
        if (self.generation == 0) {
            // Wrapped: stale marks could now look current.
            @memset(self.seen, 0);
            self.generation = 1;
        }
        for (0..self.pending.len) |i| {
            @memcpy(self.work, self.pending.capturesOf(i));
            self.follow(self.pending.pcs[i], cp);
        }
        // A match may start here, at the lowest priority: anything already
        // in flight started earlier, and leftmost wins.
        if (self.best == null) {
            @memset(self.work, null);
            self.work[0] = self.pos;
            self.follow(0, cp);
        }

        self.pending.len = 0;
        const insts = self.program.insts;
        for (0..self.current.len) |i| {
            const pc = self.current.pcs[i];
            const captures = self.current.capturesOf(i);
            const advance = switch (insts[pc]) {
                .match => {
                    var m = Match{ .start = captures[0].?, .end = self.pos, .captures = @splat(null) };
                    @memcpy(m.captures[0..self.slots], captures);
                    m.captures[1] = self.pos;
                    self.best = m;
                    // Threads after this one have lower priority: whatever
                    // they would find loses to this match.
                    break;
                },
                .char => |want| if (cp) |c| (if (self.program.ignore_case) foldCase(c) == foldCase(want) else c == want) else false,
                .any => if (cp) |c| c != '\n' else false,
                .class => |index| if (cp) |c| self.inClass(self.program.classes[index], c) else false,
                else => unreachable, // `follow` only stops on consuming instructions
            };
            if (advance) self.pending.add(pc + 1, captures);
        }

        self.prev = cp;
        self.pos += len;
        return self.best != null and self.pending.len == 0;
    }

    fn inClass(self: *const Matcher, class: Class, cp: u21) bool {
        var hit = class.has(cp);
        if (!hit and self.program.ignore_case and cp < 0x80) {
            const c: u8 = @intCast(cp);
            hit = class.has(std.ascii.toLower(c)) or class.has(std.ascii.toUpper(c));
        }
        return hit != class.negated;
    }

    /// Add `pc` and everything reachable from it without consuming input to
    /// `current`, in priority order. `self.work` holds the captures and is
    /// restored on the way back out of each `save`.
    fn follow(self: *Matcher, pc0: u32, next: ?u21) void {
        const insts = self.program.insts;
        var top: usize = 0;
        self.stack[top] = .{ .visit = pc0 };
        top += 1;
        while (top > 0) {
            top -= 1;
            const pc = switch (self.stack[top]) {
                .restore => |r| {
                    self.work[r.slot] = r.value;
                    continue;
                },
                .visit => |pc| pc,
            };
            if (self.seen[pc] == self.generation) continue;
            self.seen[pc] = self.generation;
            const after: ?u32 = switch (insts[pc]) {
                .char, .any, .class, .match => {
                    self.current.add(pc, self.work);
                    continue;
                },
                .jmp => |target| target,
                .split => |s| split: {
                    // Pushed second, so popped first: the preferred branch.
                    self.stack[top] = .{ .visit = s.second };
                    top += 1;
                    break :split s.first;
                },
                .save => |slot| save: {
                    if (slot < self.slots) {
                        self.stack[top] = .{ .restore = .{ .slot = slot, .value = self.work[slot] } };
                        top += 1;
                        self.work[slot] = self.pos;
                    }
                    break :save pc + 1;
                },
                .line_start => if (self.prev == null or self.prev.? == '\n') pc + 1 else null,
                .line_end => if (next == null or next.? == '\n') pc + 1 else null,
                .word_boundary => if (isWord(self.prev) != isWord(next)) pc + 1 else null,
                .not_word_boundary => if (isWord(self.prev) == isWord(next)) pc + 1 else null,
            };
            if (after) |target| {
                self.stack[top] = .{ .visit = target };
                top += 1;
            }
        }
    }
};

/// Search a contiguous slice: the leftmost match starting at or after
/// `from`. For prompts and tests; documents are searched in chunks.
pub fn find(matcher: *Matcher, haystack: []const u8, from: usize) ?Match {
    if (from > haystack.len) return null;
    matcher.start(from, if (from > 0) haystack[from - 1] else null);
    _ = matcher.feed(haystack[from..]);
    return matcher.finish();
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

/// Compile, search `haystack` from 0, and compare the match with `want`
/// ("start-end", or null for no match).
fn expectMatch(pattern: []const u8, haystack: []const u8, want: ?[2]usize) !void {
    try expectMatchOptions(pattern, .{}, haystack, want);
}

fn expectMatchOptions(pattern: []const u8, options: Options, haystack: []const u8, want: ?[2]usize) !void {
    var program = try compile(testing.allocator, pattern, options, null);
    defer program.deinit();
    var matcher = try Matcher.init(testing.allocator, &program);
    defer matcher.deinit();
    const got = find(&matcher, haystack, 0);
    if (want) |w| {
        try testing.expect(got != null);
        try testing.expectEqual(w[0], got.?.start);
        try testing.expectEqual(w[1], got.?.end);
    } else {
        try testing.expect(got == null);
    }

    // The same search fed one byte at a time must agree: this is what a
    // document split into many pieces looks like.
    matcher.start(0, null);
    for (haystack) |*b| {
        if (matcher.feed(b[0..1])) break;
    }
    const split = matcher.finish();
    try testing.expectEqual(got == null, split == null);
    if (got) |g| {
        try testing.expectEqual(g.start, split.?.start);
        try testing.expectEqual(g.end, split.?.end);
    }
}

test "literals, dot and leftmost match" {
    try expectMatch("a.c", "xxabcxx", .{ 2, 5 });
    try expectMatch("a.c", "xxaxcxx", .{ 2, 5 });
    try expectMatch("a.c", "xxacxx", null);
    try expectMatch("a.c", "a\nc", null); // dot never crosses a line
    try expectMatch("", "abc", .{ 0, 0 });
    try expectMatch("abc", "", null);
    try expectMatch("b", "abcb", .{ 1, 2 });
}

test "classes and escapes" {
    try expectMatch("[a-c]+", "xxabcabx", .{ 2, 7 });
    try expectMatch("[^a-c]+", "abxyzc", .{ 2, 5 });
    try expectMatch("\\d+", "abc 123 def", .{ 4, 7 });
    try expectMatch("\\D+", "12ab34", .{ 2, 4 });
    try expectMatch("\\w+", "  foo_1!", .{ 2, 7 });
    try expectMatch("\\s+", "a \t\nb", .{ 1, 4 });
    try expectMatch("[\\d.]+", "v1.25b", .{ 1, 5 });
    try expectMatch("[]a]+", "x]a]", .{ 1, 4 }); // leading ] is a literal
    try expectMatch("[a-]+", "x-a-", .{ 1, 4 }); // trailing - is a literal
    try expectMatch("a\\.b", "axb a.b", .{ 4, 7 });
    try expectMatch("\\(\\)", "f()", .{ 1, 3 });
    try expectMatch("a\\tb", "a\tb", .{ 0, 3 });
}

test "anchors are per line" {
    try expectMatch("^[a-z]+$", "hello", .{ 0, 5 });
    try expectMatch("^[a-z]+$", "Hello", null);
    try expectMatch("^b", "a\nb", .{ 2, 3 });
    try expectMatch("a$", "a\nb", .{ 0, 1 });
    try expectMatch("^$", "a\n\nb", .{ 2, 2 });
    try expectMatch("^", "", .{ 0, 0 });
}

test "word boundaries" {
    try expectMatch("\\bfoo\\b", "a foo b", .{ 2, 5 });
    try expectMatch("\\bfoo\\b", "afoob", null);
    try expectMatch("\\bfoo\\b", "foo", .{ 0, 3 });
    try expectMatch("\\Boo", "foo", .{ 1, 3 });
    try expectMatch("\\bé", "x é", .{ 2, 4 }); // non-ASCII letters are word characters
}

test "quantifiers, greedy and lazy" {
    try expectMatch("a*", "aaab", .{ 0, 3 });
    try expectMatch("a*?", "aaab", .{ 0, 0 });
    try expectMatch("a+?", "aaab", .{ 0, 1 });
    try expectMatch("ab?c", "ac abc", .{ 0, 2 });
    try expectMatch("<.+>", "<a><b>", .{ 0, 6 });
    try expectMatch("<.+?>", "<a><b>", .{ 0, 3 });
    try expectMatch("a{2,4}", "a", null);
    try expectMatch("a{2,4}", "aaaaa", .{ 0, 4 });
    try expectMatch("a{2,4}?", "aaaaa", .{ 0, 2 });
    try expectMatch("x{3}", "xx", null);
    try expectMatch("x{3}", "xxxx", .{ 0, 3 });
    try expectMatch("b{2,}", "xbbbbby", .{ 1, 6 });
    try expectMatch("a{0}b", "ab", .{ 1, 2 });
    try expectMatch("(ab)+", "xxababab", .{ 2, 8 });
    try expectMatch("a{,2}", "a{,2}", .{ 0, 5 }); // not a quantifier: literal braces
    try expectMatch("a{x", "a{x", .{ 0, 3 });
}

test "alternation prefers the first branch" {
    try expectMatch("cat|dog", "a dog here", .{ 2, 5 });
    try expectMatch("a|ab", "ab", .{ 0, 1 }); // leftmost-first, not longest
    try expectMatch("ab|a", "ab", .{ 0, 2 });
    try expectMatch("(a|ab)(c|bcd)", "abcd", .{ 0, 4 });
    try expectMatch("x(|y)z", "xz xyz", .{ 0, 2 });
}

test "captures" {
    var program = try compile(testing.allocator, "(a+)-(b+)|(c)", .{}, null);
    defer program.deinit();
    var matcher = try Matcher.init(testing.allocator, &program);
    defer matcher.deinit();
    try testing.expectEqual(@as(usize, 3), program.groups);

    const m = find(&matcher, "xx aa-bbb yy", 0).?;
    try testing.expectEqual(@as(usize, 3), m.start);
    try testing.expectEqual(@as(usize, 9), m.end);
    try testing.expectEqual(@as(?usize, 3), m.captures[2]);
    try testing.expectEqual(@as(?usize, 5), m.captures[3]);
    try testing.expectEqual(@as(?usize, 6), m.captures[4]);
    try testing.expectEqual(@as(?usize, 9), m.captures[5]);
    try testing.expectEqual(@as(?usize, null), m.captures[6]); // the other branch

    // The last iteration of a repeated group is the one that is kept.
    var rep = try compile(testing.allocator, "(?:(\\w)-)+", .{}, null);
    defer rep.deinit();
    var rm = try Matcher.init(testing.allocator, &rep);
    defer rm.deinit();
    const r = find(&rm, "a-b-c-", 0).?;
    try testing.expectEqual(@as(usize, 6), r.end);
    try testing.expectEqual(@as(?usize, 4), r.captures[2]);
}

test "search from an offset sees what comes before it" {
    var program = try compile(testing.allocator, "^b|\\bc", .{}, null);
    defer program.deinit();
    var matcher = try Matcher.init(testing.allocator, &program);
    defer matcher.deinit();
    // From offset 1 in "ab": the b is not at a line start.
    try testing.expect(find(&matcher, "ab", 1) == null);
    try testing.expectEqual(@as(usize, 2), find(&matcher, "a\nb", 2).?.start);
    try testing.expect(find(&matcher, "ac", 1) == null); // no boundary between a and c
    try testing.expect(find(&matcher, "abc", 99) == null);
}

test "ignore case" {
    try expectMatchOptions("hello", .{ .ignore_case = true }, "say HeLLo", .{ 4, 9 });
    try expectMatchOptions("[a-c]+", .{ .ignore_case = true }, "xABCx", .{ 1, 4 });
    try expectMatchOptions("[^a]", .{ .ignore_case = true }, "Aab", .{ 2, 3 });
    try expectMatchOptions("hello", .{}, "say HeLLo", null);
}

test "unicode: codepoints, not bytes" {
    try expectMatch("日.語", "x日本語", .{ 1, 10 });
    try expectMatch("[α-ω]+", "abc αβγ", .{ 4, 10 });
    try expectMatch("é+", "ééé", .{ 0, 6 });
    try expectMatch(".", "é", .{ 0, 2 }); // one codepoint, two bytes
    try expectMatch("a.b", "a\xffb", .{ 0, 3 }); // an invalid byte is one unknown character
    try expectMatch("x", "\xe6\x97x", .{ 2, 3 }); // a cut-off sequence does not swallow what follows
}

test "the first-byte skip does not change results" {
    try expectMatch("needle", "hay hay nee needle hay", .{ 12, 18 });
    try expectMatch("n+eedle", "nnneedle", .{ 0, 8 });
    try expectMatch("\\bnew", "renew new", .{ 6, 9 });
    try expectMatch("(n)x", "nnnx", .{ 2, 4 });
}

test "patterns that defeat backtracking run in linear time" {
    // (a*)*b against a long run of a's is exponential for a backtracking
    // engine. Here it is one pass.
    const text = "a" ** 5000;
    try expectMatch("(a*)*b", text, null);
    try expectMatch("(a|aa)+$", text ++ "!", null);
    try expectMatch("(x+x+)+y", "x" ** 3000, null);
    try expectMatch("(a*)*", text, .{ 0, 5000 });
}

test "syntax errors say where and why" {
    const cases = [_]struct { pattern: []const u8, offset: usize, message: []const u8 }{
        .{ .pattern = "a(b", .offset = 1, .message = "missing )" },
        .{ .pattern = "ab)", .offset = 2, .message = "unmatched )" },
        .{ .pattern = "*a", .offset = 0, .message = "nothing to repeat" },
        .{ .pattern = "a|*", .offset = 2, .message = "nothing to repeat" },
        .{ .pattern = "^*", .offset = 0, .message = "nothing to repeat" },
        .{ .pattern = "[abc", .offset = 0, .message = "missing ]" },
        .{ .pattern = "[z-a]", .offset = 1, .message = "class range is reversed" },
        .{ .pattern = "a{3,1}", .offset = 0, .message = "repeat range is reversed" },
        .{ .pattern = "a{5000}", .offset = 0, .message = "repeat count is too large" },
        .{ .pattern = "\\q", .offset = 0, .message = "unknown escape" },
        .{ .pattern = "ab\\", .offset = 2, .message = "pattern ends with a backslash" },
        .{ .pattern = "(?=a)", .offset = 0, .message = "unsupported group; only (?: ) is known" },
        .{ .pattern = "[\\D]", .offset = 1, .message = "negated escape inside a class" },
    };
    for (cases) |c| {
        var diag = Diagnostic{};
        try testing.expectError(error.Syntax, compile(testing.allocator, c.pattern, .{}, &diag));
        try testing.expectEqual(c.offset, diag.offset);
        try testing.expectEqualStrings(c.message, diag.message);
    }
}

test "a pattern that would compile to a huge program is refused" {
    try testing.expectError(error.TooBig, compile(testing.allocator, "((a{200}){200}){200}", .{}, null));
}

test "compile cleans up after allocation failure" {
    const Check = struct {
        fn run(allocator: Allocator) !void {
            var program = try compile(allocator, "(a|b)+[c-e]{2,3}\\d*x", .{}, null);
            defer program.deinit();
            var matcher = try Matcher.init(allocator, &program);
            defer matcher.deinit();
            try testing.expect(find(&matcher, "abcd9x", 0) != null);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{});
}
