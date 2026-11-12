//! Data-driven syntax highlighting.
//!
//! Language definitions are data, not code: `syntax.d/*.ini` files (kibi's
//! format) are parsed at startup, so adding a language is dropping in a file.
//! The lexer is line-oriented and carries a tiny state across lines so
//! multi-line comments and multi-line strings colour correctly.
//!
//! Reading the files is the caller's job (`src/langs.zig`); this module only
//! parses text it is handed. `highlight.zig` caches the per-line state.

const std = @import("std");
const ini = @import("ini.zig");

pub const Class = enum(u8) {
    normal,
    number,
    string,
    ml_string,
    comment,
    ml_comment,
    keyword1,
    keyword2,
};

pub const Span = struct {
    start: usize,
    end: usize,
    class: Class,
};

/// A line never needs more spans than this; the tail stays unhighlighted.
pub const MAX_SPANS = 96;

/// One language, as described by a `syntax.d/*.ini` file.
pub const Lang = struct {
    name: []u8,
    /// Extensions including the leading dot, e.g. ".zig".
    extensions: [][]u8,
    numbers: bool = true,
    /// Characters that open/close a single-line string (concatenated).
    quotes: []u8 = &.{},
    /// Tokens that start a single-line comment, e.g. "//" or "#".
    sl_comment_starts: [][]u8 = &.{},
    ml_comment_open: []u8 = &.{},
    ml_comment_close: []u8 = &.{},
    /// Delimiter that starts and ends a multi-line string (e.g. `"""`).
    ml_string_delim: []u8 = &.{},
    keywords1: [][]u8 = &.{},
    /// Markdown gets line-oriented rules (headings, lists, fences, links)
    /// instead of the generic token lexer.
    markdown: bool = false,
    keywords2: [][]u8 = &.{},

    fn deinit(self: *Lang, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        freeList(allocator, self.extensions);
        allocator.free(self.quotes);
        freeList(allocator, self.sl_comment_starts);
        allocator.free(self.ml_comment_open);
        allocator.free(self.ml_comment_close);
        allocator.free(self.ml_string_delim);
        freeList(allocator, self.keywords1);
        freeList(allocator, self.keywords2);
    }
};

fn freeList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

/// Every language loaded from `syntax.d`. Load once, then call `find`.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    langs: std.ArrayList(Lang),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator, .langs = std.ArrayList(Lang).empty };
    }

    pub fn deinit(self: *Registry) void {
        for (self.langs.items) |*lang| lang.deinit(self.allocator);
        self.langs.deinit(self.allocator);
    }

    /// Parse one definition. Errors leave the registry unchanged.
    pub fn parse(self: *Registry, data: []const u8) !void {
        var lang = Lang{ .name = try self.allocator.dupe(u8, ""), .extensions = try self.allocator.alloc([]u8, 0) };
        errdefer lang.deinit(self.allocator);
        var have_extensions = false;

        var reader = ini.Reader{ .text = data };
        while (reader.next()) |entry| {
            if (std.mem.eql(u8, entry.key, "markdown")) {
                lang.markdown = std.ascii.eqlIgnoreCase(std.mem.trim(u8, entry.value, " \t"), "true");
                continue;
            }
            if (std.mem.eql(u8, entry.key, "name")) {
                self.allocator.free(lang.name);
                lang.name = try self.allocator.dupe(u8, entry.value);
            } else if (std.mem.eql(u8, entry.key, "extensions")) {
                const parts = try ini.splitList(self.allocator, entry.value);
                defer freeList(self.allocator, parts);
                var exts = std.ArrayList([]u8).empty;
                errdefer {
                    for (exts.items) |e| self.allocator.free(e);
                    exts.deinit(self.allocator);
                }
                for (parts) |part| {
                    const ext = if (part.len > 0 and part[0] == '.')
                        try self.allocator.dupe(u8, part)
                    else
                        try std.fmt.allocPrint(self.allocator, ".{s}", .{part});
                    try exts.append(self.allocator, ext);
                }
                const new_exts = try exts.toOwnedSlice(self.allocator);
                freeList(self.allocator, lang.extensions);
                lang.extensions = new_exts;
                have_extensions = new_exts.len > 0;
            } else if (std.mem.eql(u8, entry.key, "highlight_numbers")) {
                lang.numbers = !std.mem.eql(u8, entry.value, "false");
            } else if (std.mem.eql(u8, entry.key, "singleline_string_quotes")) {
                self.allocator.free(lang.quotes);
                lang.quotes = try quoteChars(self.allocator, entry.value);
            } else if (std.mem.eql(u8, entry.key, "singleline_comment_start")) {
                freeList(self.allocator, lang.sl_comment_starts);
                lang.sl_comment_starts = try ini.splitList(self.allocator, entry.value);
            } else if (std.mem.eql(u8, entry.key, "multiline_comment_delims")) {
                const parts = try ini.splitList(self.allocator, entry.value);
                defer freeList(self.allocator, parts);
                if (parts.len >= 2) {
                    const open = try self.allocator.dupe(u8, parts[0]);
                    errdefer self.allocator.free(open);
                    const close = try self.allocator.dupe(u8, parts[1]);
                    self.allocator.free(lang.ml_comment_open);
                    self.allocator.free(lang.ml_comment_close);
                    lang.ml_comment_open = open;
                    lang.ml_comment_close = close;
                }
            } else if (std.mem.eql(u8, entry.key, "multiline_string_delim")) {
                self.allocator.free(lang.ml_string_delim);
                lang.ml_string_delim = try self.allocator.dupe(u8, entry.value);
            } else if (std.mem.eql(u8, entry.key, "keywords_1")) {
                freeList(self.allocator, lang.keywords1);
                lang.keywords1 = try ini.splitList(self.allocator, entry.value);
            } else if (std.mem.eql(u8, entry.key, "keywords_2")) {
                freeList(self.allocator, lang.keywords2);
                lang.keywords2 = try ini.splitList(self.allocator, entry.value);
            }
        }
        if (!have_extensions or lang.name.len == 0) return error.InvalidSyntaxFile;
        try self.langs.append(self.allocator, lang);
    }

    /// The language whose extension matches `path`, or null.
    pub fn find(self: *Registry, path: ?[]const u8) ?*const Lang {
        const p = path orelse return null;
        for (self.langs.items) |*lang| {
            for (lang.extensions) |ext| {
                if (endsWithIgnoreCase(p, ext)) return lang;
            }
        }
        return null;
    }
};

/// Quote characters from a value like `", '` (commas and spaces dropped).
fn quoteChars(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (value) |c| {
        if (c == ',' or c == ' ' or c == '\t') continue;
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const tail = haystack[haystack.len - needle.len ..];
    return std.ascii.eqlIgnoreCase(tail, needle);
}

// --- lexer -----------------------------------------------------------------

/// State carried from one line to the next.
pub const State = packed struct {
    in_ml_comment: bool = false,
    in_ml_string: bool = false,
};

const Ctx = struct {
    spans: []Span,
    n: usize = 0,

    fn add(self: *Ctx, start: usize, end: usize, class: Class) void {
        if (self.n >= self.spans.len or end <= start) return;
        self.spans[self.n] = .{ .start = start, .end = end, .class = class };
        self.n += 1;
    }
};

fn startsWithAt(text: []const u8, i: usize, needle: []const u8) bool {
    if (needle.len == 0 or i + needle.len > text.len) return false;
    return std.mem.eql(u8, text[i .. i + needle.len], needle);
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c == '@';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c == '@';
}

fn inList(list: []const []u8, word: []const u8) bool {
    for (list) |w| {
        if (std.mem.eql(u8, w, word)) return true;
    }
    return false;
}

/// Highlight one line, updating `state` for the next line. Returns the number
/// of spans written (sorted and non-overlapping).
pub fn highlight(lang: *const Lang, text: []const u8, state: *State, spans: []Span) usize {
    if (lang.markdown or std.ascii.eqlIgnoreCase(lang.name, "Markdown")) {
        return highlightMarkdown(text, state, spans);
    }
    var ctx = Ctx{ .spans = spans };
    var i: usize = 0;

    if (state.in_ml_comment) {
        if (lang.ml_comment_close.len > 0) {
            if (std.mem.indexOfPos(u8, text, 0, lang.ml_comment_close)) |p| {
                ctx.add(0, p + lang.ml_comment_close.len, .ml_comment);
                i = p + lang.ml_comment_close.len;
                state.in_ml_comment = false;
            } else {
                ctx.add(0, text.len, .ml_comment);
                return ctx.n;
            }
        } else {
            state.in_ml_comment = false;
        }
    }

    if (state.in_ml_string) {
        const delim = lang.ml_string_delim;
        if (delim.len > 0) {
            if (std.mem.indexOfPos(u8, text, 0, delim)) |p| {
                ctx.add(0, p + delim.len, .ml_string);
                i = p + delim.len;
                state.in_ml_string = false;
            } else {
                ctx.add(0, text.len, .ml_string);
                return ctx.n;
            }
        } else {
            state.in_ml_string = false;
        }
    }

    while (i < text.len) {
        const c = text[i];

        // Multi-line comment start (before single-line: "/*" vs "//" differ,
        // but "/*" must not be read as a line comment in a language with "/").
        if (lang.ml_comment_open.len > 0 and startsWithAt(text, i, lang.ml_comment_open)) {
            const from = i;
            if (std.mem.indexOfPos(u8, text, i + lang.ml_comment_open.len, lang.ml_comment_close)) |p| {
                ctx.add(from, p + lang.ml_comment_close.len, .ml_comment);
                i = p + lang.ml_comment_close.len;
            } else {
                ctx.add(from, text.len, .ml_comment);
                state.in_ml_comment = true;
                break;
            }
            continue;
        }

        // Multi-line string delimiter.
        if (lang.ml_string_delim.len > 0 and startsWithAt(text, i, lang.ml_string_delim)) {
            const from = i;
            const open_len = lang.ml_string_delim.len;
            if (std.mem.indexOfPos(u8, text, i + open_len, lang.ml_string_delim)) |p| {
                ctx.add(from, p + open_len, .ml_string);
                i = p + open_len;
            } else {
                ctx.add(from, text.len, .ml_string);
                state.in_ml_string = true;
                break;
            }
            continue;
        }

        // Single-line comment.
        var comment_len: usize = 0;
        for (lang.sl_comment_starts) |start| {
            if (startsWithAt(text, i, start) and start.len > comment_len) comment_len = start.len;
        }
        if (comment_len > 0) {
            ctx.add(i, text.len, .comment);
            break;
        }

        // Single-line string.
        if (lang.quotes.len > 0 and std.mem.indexOfScalar(u8, lang.quotes, c) != null) {
            const quote = c;
            var j = i + 1;
            while (j < text.len) : (j += 1) {
                if (text[j] == '\\' and j + 1 < text.len) {
                    j += 1;
                    continue;
                }
                if (text[j] == quote) {
                    j += 1;
                    break;
                }
            }
            ctx.add(i, j, .string);
            i = j;
            continue;
        }

        // Number.
        if (lang.numbers and std.ascii.isDigit(c) and (i == 0 or !isIdentChar(text[i - 1]))) {
            var j = i;
            while (j < text.len and (isIdentChar(text[j]) or text[j] == '.')) j += 1;
            ctx.add(i, j, .number);
            i = j;
            continue;
        }

        // Identifier: keyword lists.
        if (isIdentStart(c)) {
            var j = i + 1;
            while (j < text.len and isIdentChar(text[j])) j += 1;
            const word = text[i..j];
            if (inList(lang.keywords1, word)) {
                ctx.add(i, j, .keyword1);
            } else if (inList(lang.keywords2, word)) {
                ctx.add(i, j, .keyword2);
            }
            i = j;
            continue;
        }

        i += 1;
    }
    return ctx.n;
}

/// Advance the state past one line without keeping the spans.
pub fn advance(lang: *const Lang, text: []const u8, state: *State) void {
    var scratch: [MAX_SPANS]Span = undefined;
    _ = highlight(lang, text, state, &scratch);
}

/// Markdown: line-oriented rules, with fences and HTML comments carrying
/// state across lines.
fn highlightMarkdown(text: []const u8, state: *State, spans: []Span) usize {
    var ctx = Ctx{ .spans = spans };
    var i: usize = 0;

    if (state.in_ml_comment) {
        if (std.mem.indexOfPos(u8, text, 0, "-->")) |p| {
            ctx.add(0, p + 3, .ml_comment);
            state.in_ml_comment = false;
            i = p + 3;
        } else {
            ctx.add(0, text.len, .ml_comment);
            return ctx.n;
        }
    }
    if (state.in_ml_string) {
        if (std.mem.indexOfPos(u8, text, 0, "```")) |p| {
            ctx.add(0, p + 3, .ml_string);
            state.in_ml_string = false;
            i = p + 3;
        } else {
            ctx.add(0, text.len, .ml_string);
            return ctx.n;
        }
    }

    if (i == 0 and std.mem.startsWith(u8, text, "```")) {
        ctx.add(0, text.len, .ml_string);
        state.in_ml_string = true;
        return ctx.n;
    }

    // Heading: 1-6 '#' then a space.
    if (text.len > 0 and text[0] == '#') {
        var h: usize = 0;
        while (h < text.len and text[h] == '#') h += 1;
        if (h <= 6 and h < text.len and (text[h] == ' ' or text[h] == '\t')) {
            ctx.add(0, text.len, .keyword1);
            return ctx.n;
        }
    }
    if (text.len > 0 and text[0] == '>') {
        ctx.add(0, text.len, .comment);
        return ctx.n;
    }

    // List marker.
    {
        var k: usize = 0;
        while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
        if (k < text.len) {
            const c = text[k];
            if ((c == '-' or c == '*' or c == '+') and k + 1 < text.len and text[k + 1] == ' ') {
                ctx.add(k, k + 2, .keyword2);
            } else if (c >= '0' and c <= '9') {
                var d = k;
                while (d < text.len and text[d] >= '0' and text[d] <= '9') d += 1;
                if (d < text.len and (text[d] == '.' or text[d] == ')') and d + 1 < text.len and text[d + 1] == ' ') {
                    ctx.add(k, d + 2, .keyword2);
                }
            }
        }
    }

    // Inline: code spans, bold, links, HTML comments.
    var j: usize = i;
    while (j < text.len) {
        if (text[j] == '`') {
            if (std.mem.indexOfPos(u8, text, j + 1, "`")) |p| {
                ctx.add(j, p + 1, .string);
                j = p + 1;
                continue;
            }
        }
        if (text[j] == '*' and j + 1 < text.len and text[j + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, j + 2, "**")) |p| {
                ctx.add(j, p + 2, .keyword2);
                j = p + 2;
                continue;
            }
        }
        if (text[j] == '[') {
            if (std.mem.indexOfPos(u8, text, j + 1, "](")) |p| {
                if (std.mem.indexOfPos(u8, text, p + 2, ")")) |q| {
                    ctx.add(j, q + 1, .string);
                    j = q + 1;
                    continue;
                }
            }
        }
        if (text[j] == '<' and std.mem.startsWith(u8, text[j..], "<!--")) {
            if (std.mem.indexOfPos(u8, text, j + 4, "-->")) |p| {
                ctx.add(j, p + 3, .ml_comment);
                j = p + 3;
                continue;
            }
            ctx.add(j, text.len, .ml_comment);
            state.in_ml_comment = true;
            return ctx.n;
        }
        j += 1;
    }
    return ctx.n;
}

// --- tests -----------------------------------------------------------------

fn classAt(spans: []const Span, off: usize) Class {
    for (spans) |s| {
        if (off >= s.start and off < s.end) return s.class;
    }
    return .normal;
}

fn testRegistry() !Registry {
    var reg = Registry.init(std.testing.allocator);
    errdefer reg.deinit();
    try reg.parse(
        \\name=C
        \\extensions=c, h
        \\highlight_numbers=true
        \\singleline_string_quotes=", '
        \\singleline_comment_start=//
        \\multiline_comment_delims=/*, */
        \\keywords_1=int, char, static, const, return
        \\keywords_2=size_t, uint8_t
        \\
    );
    return reg;
}

test "registry parses a definition and matches extensions" {
    var reg = try testRegistry();
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 1), reg.langs.items.len);
    const c = reg.find("main.c").?;
    try std.testing.expectEqualStrings("C", c.name);
    try std.testing.expectEqualStrings(".c", c.extensions[0]);
    try std.testing.expectEqualStrings(".h", c.extensions[1]);
    try std.testing.expect(reg.find("main.C") != null); // extension match is case-insensitive
    try std.testing.expect(reg.find("notes.txt") == null);
    try std.testing.expect(reg.find(null) == null);
}

test "markdown gets headings, lists, code and links" {
    const md = Lang{
        .name = @constCast("Markdown"),
        .extensions = @constCast(&[_][]u8{}),
        .markdown = true,
    };
    var state = State{};
    var spans: [MAX_SPANS]Span = undefined;

    var n = highlight(&md, "# Title", &state, &spans);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Class.keyword1, spans[0].class);

    n = highlight(&md, "- item", &state, &spans);
    try std.testing.expectEqual(Class.keyword2, spans[0].class);

    n = highlight(&md, "see [docs](https://example.com)", &state, &spans);
    try std.testing.expectEqual(Class.string, spans[0].class);

    n = highlight(&md, "```zig", &state, &spans);
    try std.testing.expectEqual(Class.ml_string, spans[0].class);
    try std.testing.expect(state.in_ml_string);
    _ = highlight(&md, "const x = 1;", &state, &spans);
    try std.testing.expectEqual(Class.ml_string, spans[0].class);
    _ = highlight(&md, "```", &state, &spans);
    try std.testing.expect(!state.in_ml_string);
}

test "keywords, types, numbers and strings" {
    var reg = try testRegistry();
    defer reg.deinit();
    const lang = reg.find("x.c").?;
    var st = State{};
    var spans: [MAX_SPANS]Span = undefined;
    const n = highlight(lang, "static int count = 42; char *s = \"hi\";", &st, &spans);
    try std.testing.expectEqual(Class.keyword1, classAt(spans[0..n], 0)); // static
    try std.testing.expectEqual(Class.keyword1, classAt(spans[0..n], 7)); // int
    try std.testing.expectEqual(Class.normal, classAt(spans[0..n], 11)); // count
    try std.testing.expectEqual(Class.number, classAt(spans[0..n], 19)); // 42
    try std.testing.expectEqual(Class.string, classAt(spans[0..n], 33)); // "hi"
}

test "line comments and block comments carry state" {
    var reg = try testRegistry();
    defer reg.deinit();
    const lang = reg.find("x.c").?;
    var st = State{};
    var spans: [MAX_SPANS]Span = undefined;

    const n = highlight(lang, "int x; // int y;", &st, &spans);
    try std.testing.expectEqual(Class.comment, classAt(spans[0..n], 7));
    try std.testing.expect(!st.in_ml_comment);

    _ = highlight(lang, "int a; /* start", &st, &spans);
    try std.testing.expect(st.in_ml_comment);
    const n2 = highlight(lang, "still comment", &st, &spans);
    try std.testing.expectEqual(Class.ml_comment, classAt(spans[0..n2], 0));
    const n3 = highlight(lang, "end */ int b;", &st, &spans);
    try std.testing.expect(!st.in_ml_comment);
    try std.testing.expectEqual(Class.ml_comment, classAt(spans[0..n3], 0));
    try std.testing.expectEqual(Class.keyword1, classAt(spans[0..n3], 9));
}

test "multi-line strings carry state" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.parse(
        \\name=Python
        \\extensions=py
        \\singleline_string_quotes=", '
        \\singleline_comment_start=#
        \\multiline_string_delim="""
        \\keywords_1=def, return
        \\
    );
    const lang = reg.find("x.py").?;
    var st = State{};
    var spans: [MAX_SPANS]Span = undefined;

    _ = highlight(lang, "s = \"\"\"hello", &st, &spans);
    try std.testing.expect(st.in_ml_string);
    const n2 = highlight(lang, "still a string", &st, &spans);
    try std.testing.expectEqual(Class.ml_string, classAt(spans[0..n2], 0));
    _ = highlight(lang, "end\"\"\" + x", &st, &spans);
    try std.testing.expect(!st.in_ml_string);
}
