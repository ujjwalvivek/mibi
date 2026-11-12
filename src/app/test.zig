//! The editor, driven the way a person drives it: key presses and mouse
//! events in, the screen and the document out. No terminal is involved.

const std = @import("std");
const testing = std.testing;
const os = @import("platform").os;
const event = @import("ui").event;
const screen = @import("ui").screen;
const config_mod = @import("../config.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = event.Key;

const Harness = struct {
    app: App,
    s: screen.Screen,
    arena: std.heap.ArenaAllocator,
    buf: [512]u8 = undefined,

    fn init(content: []const u8) !Harness {
        return initSized(content, 60, 12);
    }

    fn initSized(content: []const u8, cols: usize, rows: usize) !Harness {
        return initWith(testing.allocator, content, cols, rows);
    }

    fn initWith(allocator: std.mem.Allocator, content: []const u8, cols: usize, rows: usize) !Harness {
        var h = try initBare(allocator, cols, rows);
        errdefer h.deinit();
        _ = try h.app.addDoc(null, content);
        h.draw();
        return h;
    }

    /// No document yet: the state the session is loaded into at start-up.
    fn initBare(allocator: std.mem.Allocator, cols: usize, rows: usize) !Harness {
        return .{
            .s = try screen.Screen.init(allocator, cols, rows),
            .app = App.init(allocator, .{}),
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn deinit(self: *Harness) void {
        self.app.deinit();
        self.s.deinit();
        self.arena.deinit();
    }

    fn draw(self: *Harness) void {
        self.app.draw(&self.s);
    }

    /// Press keys, given in `mibi.ini` notation and separated by blanks:
    /// `try h.keys("ctrl+a ctrl+x")`.
    fn keys(self: *Harness, specs: []const u8) !void {
        var it = std.mem.tokenizeScalar(u8, specs, ' ');
        while (it.next()) |spec| {
            const key = Key.parse(spec) orelse return error.BadKeyInTest;
            self.app.now_ms += 10;
            self.app.handle(.{ .key = key });
        }
        self.draw();
    }

    /// Type text, one key per character.
    fn typeText(self: *Harness, typed: []const u8) !void {
        var view = try std.unicode.Utf8View.init(typed);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            self.app.now_ms += 10;
            self.app.handle(.{ .key = switch (cp) {
                '\n' => .{ .special = .enter },
                '\t' => .{ .special = .tab },
                else => Key.char(cp),
            } });
        }
        self.draw();
    }

    fn mouse(self: *Harness, kind: event.Mouse.Kind, x: u16, y: u16) void {
        self.app.now_ms += 10;
        const button: event.Mouse.Button = switch (kind) {
            .press, .release, .drag => .left,
            else => .none,
        };
        self.app.handle(.{ .mouse = .{ .kind = kind, .button = button, .x = x, .y = y } });
        self.draw();
    }

    fn click(self: *Harness, x: u16, y: u16) void {
        self.mouse(.press, x, y);
        self.mouse(.release, x, y);
    }

    /// The focused document's text.
    fn text(self: *Harness) []const u8 {
        return self.app.doc().document.buffer.toOwned(self.arena.allocator()) catch "<out of memory>";
    }

    fn row(self: *Harness, y: usize) []const u8 {
        return self.s.rowText(y, &self.buf);
    }

    fn lastRow(self: *Harness) []const u8 {
        return self.row(self.s.rows - 1);
    }

    fn head(self: *Harness) usize {
        return self.app.view().primarySelection().head;
    }

    fn expectText(self: *Harness, want: []const u8) !void {
        try testing.expectEqualStrings(want, self.text());
    }
};

test "typing, enter, tab, backspace, delete" {
    var h = try Harness.init("");
    defer h.deinit();
    try h.typeText("abc");
    try h.expectText("abc");
    try h.keys("enter");
    try h.expectText("abc\n");
    try h.keys("tab");
    try h.expectText("abc\n    ");
    try h.keys("backspace");
    try h.expectText("abc\n");
    try h.typeText("x");
    try h.keys("left delete");
    try h.expectText("abc\n");
    try h.keys("delete"); // at the end: nothing to delete
    try h.expectText("abc\n");
}

test "movement: arrows, home, end, word, page, file" {
    var h = try Harness.init("one two three\nfour\nfive");
    defer h.deinit();
    try h.keys("right right");
    try testing.expectEqual(@as(usize, 2), h.head());
    try h.keys("end");
    try testing.expectEqual(@as(usize, 13), h.head());
    try h.keys("home ctrl+right");
    try testing.expectEqual(@as(usize, 3), h.head());
    try h.keys("ctrl+right ctrl+left");
    try testing.expectEqual(@as(usize, 4), h.head());
    try h.keys("down");
    try testing.expectEqual(@as(usize, 18), h.head()); // "four" is shorter: its end
    try h.keys("down");
    try testing.expectEqual(@as(usize, 23), h.head()); // back out to column 4 on "five"
    try h.keys("ctrl+home");
    try testing.expectEqual(@as(usize, 0), h.head());
    try h.keys("ctrl+end");
    try testing.expectEqual(@as(usize, 23), h.head());
}

test "page down and page up move by the height of the pane" {
    var h = try Harness.init("0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n21\n22\n23\n24");
    defer h.deinit();
    // 12 rows: a tab bar, ten rows of text, a status line.
    try h.keys("pgdn");
    try testing.expectEqual(@as(usize, 10), h.app.doc().document.buffer.lineOf(h.head()));
    try h.keys("pgdn pgup");
    try testing.expectEqual(@as(usize, 10), h.app.doc().document.buffer.lineOf(h.head()));
    try h.keys("pgup pgup");
    try testing.expectEqual(@as(usize, 0), h.head());
}

test "selection: extend with shift, replace by typing, clear with esc" {
    var h = try Harness.init("hello world");
    defer h.deinit();
    try h.keys("shift+right shift+right ctrl+shift+right");
    const sel = h.app.view().primarySelection();
    try testing.expectEqual(@as(usize, 0), sel.anchor);
    try testing.expectEqual(@as(usize, 5), sel.head);
    try h.keys("esc");
    try testing.expect(h.app.view().primarySelection().isEmpty());
    try testing.expectEqual(@as(usize, 5), h.head());

    try h.keys("shift+home");
    try h.typeText("HEY");
    try h.expectText("HEY world");
    try h.keys("ctrl+a");
    try h.typeText("x");
    try h.expectText("x");
}

test "copy, cut and paste, and the terminal is offered the clipboard" {
    var h = try Harness.init("abc def");
    defer h.deinit();
    try h.keys("shift+right shift+right shift+right ctrl+c");
    try testing.expectEqualStrings("abc", h.app.clipboard.items);
    // OSC 52 with the text in base64.
    try testing.expect(std.mem.indexOf(u8, h.app.term_out.items, "\x1b]52;c;YWJj\x07") != null);
    try h.keys("end ctrl+v");
    try h.expectText("abc defabc");
    try h.keys("ctrl+a ctrl+x");
    try h.expectText("");
    try testing.expectEqualStrings("abc defabc", h.app.clipboard.items);
    try h.keys("ctrl+v ctrl+v");
    try h.expectText("abc defabcabc defabc");
}

test "copy and cut with nothing selected take the whole line" {
    var h = try Harness.init("one\ntwo\nthree");
    defer h.deinit();
    try h.keys("down ctrl+x");
    try h.expectText("one\nthree");
    try testing.expectEqualStrings("two\n", h.app.clipboard.items);
    try h.keys("ctrl+v");
    try h.expectText("one\ntwo\nthree");
}

test "undo and redo, a run of typing is one step, and a new edit drops the redo" {
    var h = try Harness.init("");
    defer h.deinit();
    try h.typeText("abc");
    h.app.now_ms += 5000; // a pause: the next word is its own step
    try h.typeText("def");
    try h.keys("ctrl+z");
    try h.expectText("abc");
    try h.keys("ctrl+z");
    try h.expectText("");
    try h.keys("ctrl+z");
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "nothing to undo") != null);
    try h.keys("ctrl+y ctrl+y");
    try h.expectText("abcdef");
    try h.keys("ctrl+z");
    try h.typeText("!");
    try h.keys("ctrl+y");
    try h.expectText("abc!");
}

test "line commands: duplicate, delete, move" {
    var h = try Harness.init("one\ntwo\nthree");
    defer h.deinit();
    try h.keys("ctrl+d");
    try h.expectText("one\none\ntwo\nthree");
    try h.keys("ctrl+k");
    try h.expectText("one\ntwo\nthree");
    // The cursor is on "two" now: the line that took the deleted one's place.
    try h.keys("alt+down");
    try h.expectText("one\nthree\ntwo");
    try h.keys("alt+down"); // at the bottom already
    try h.expectText("one\nthree\ntwo");
    try h.keys("alt+up alt+up");
    try h.expectText("two\none\nthree");
}

test "tab indents a selection, shift+tab takes it back" {
    var h = try Harness.init("a\nb\nc");
    defer h.deinit();
    try h.keys("shift+down shift+end tab");
    try h.expectText("    a\n    b\nc");
    try h.keys("shift+tab");
    try h.expectText("a\nb\nc");
}

test "toggle comment uses the language's marker, and says when there is none" {
    var h = try Harness.init("");
    defer h.deinit();
    try h.app.registry.parse("name=C\nextensions=c\nsingleline_comment_start=//\nkeywords_1=int\n");
    _ = try h.app.addDoc("mibi-no-such-file.c", "int x;\nint y;");
    try h.keys("shift+down shift+end ctrl+/");
    try h.expectText("// int x;\n// int y;");
    try h.keys("ctrl+/");
    try h.expectText("int x;\nint y;");

    try h.keys("ctrl+pgup ctrl+/"); // the unnamed tab: no language
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "no line comment") != null);
}

test "the frame: tab bar, numbered text, status line" {
    var h = try Harness.init("one\ntwo");
    defer h.deinit();
    try testing.expect(std.mem.startsWith(u8, h.row(0), " [No Name]  x "));
    try testing.expectEqualStrings("1 one", h.row(1));
    try testing.expectEqualStrings("2 two", h.row(2));
    try testing.expectEqualStrings("", h.row(3));
    try testing.expect(std.mem.startsWith(u8, h.lastRow(), " mibi  [No Name]  1:1  2L  LF"));
    try testing.expect(std.mem.endsWith(u8, h.lastRow(), "f1 help"));

    try h.typeText("x");
    try testing.expect(std.mem.startsWith(u8, h.row(0), " [No Name] [+]  x "));
    try testing.expect(std.mem.startsWith(u8, h.lastRow(), " mibi  [No Name] [+]  1:2  2L"));
    // The terminal's title follows the document.
    try testing.expect(std.mem.indexOf(u8, h.app.term_out.items, "\x1b]2;mibi - [No Name] [+]\x07") != null);
}

test "the status column counts cells, not bytes" {
    var h = try Harness.init("\xe4\xb8\xad\tx");
    defer h.deinit();
    try h.keys("end");
    // A wide character (2), a tab to column 4, one letter.
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "  1:6  ") != null);
}

test "a screen too small to draw on does not crash" {
    var h = try Harness.initSized("text", 3, 2);
    defer h.deinit();
    try h.typeText("more");
    try h.keys("ctrl+p f1 f5");
    try h.s.resize(1, 1);
    h.draw();
    try h.s.resize(0, 0);
    h.draw();
}

test "f1 toggles the help panel, esc closes it, and it shows rebound keys" {
    var h = try Harness.initSized("x", 70, 30);
    defer h.deinit();
    _ = h.app.config.keys.bind("ctrl+n", .new_tab);
    try h.keys("f1");
    try testing.expect(h.app.help);
    var found_title = false;
    var found_rebound = false;
    var y: usize = 0;
    while (y < h.s.rows) : (y += 1) {
        if (std.mem.indexOf(u8, h.row(y), "controls") != null) found_title = true;
        if (std.mem.indexOf(u8, h.row(y), "ctrl+n / ctrl+w") != null) found_rebound = true;
    }
    try testing.expect(found_title);
    try testing.expect(found_rebound);
    try h.keys("esc");
    try testing.expect(!h.app.help);
    // Esc with nothing to close is harmless.
    try h.keys("esc");
    try h.expectText("x");
}

test "an open prompt is not hidden by the help panel" {
    var h = try Harness.init("x");
    defer h.deinit();
    try h.keys("f1 ctrl+f");
    try testing.expect(std.mem.startsWith(u8, h.lastRow(), "Find: "));
}

test "find searches as you type, enter keeps the match, esc goes back" {
    var h = try Harness.init("alpha beta gamma beta");
    defer h.deinit();
    try h.keys("ctrl+f");
    try h.typeText("be");
    var sel = h.app.view().primarySelection();
    try testing.expectEqual(@as(usize, 6), sel.start());
    try testing.expectEqual(@as(usize, 8), sel.end());
    try h.typeText("ta");
    try h.keys("enter");
    try testing.expect(h.app.prompt == null);
    sel = h.app.view().primarySelection();
    try testing.expectEqual(@as(usize, 6), sel.start());
    try testing.expectEqual(@as(usize, 10), sel.end());

    try h.keys("f3");
    try testing.expectEqual(@as(usize, 17), h.app.view().primarySelection().start());
    try h.keys("f3"); // wraps to the first
    try testing.expectEqual(@as(usize, 6), h.app.view().primarySelection().start());
    try h.keys("shift+f3"); // and back around to the last
    try testing.expectEqual(@as(usize, 17), h.app.view().primarySelection().start());

    // Esc puts the cursor back where the search started.
    try h.keys("ctrl+home ctrl+f");
    try h.typeText("gam");
    try testing.expectEqual(@as(usize, 11), h.app.view().primarySelection().start());
    try h.keys("esc");
    try testing.expectEqual(@as(usize, 0), h.head());
    try testing.expect(h.app.view().primarySelection().isEmpty());
}

test "a search with no match says so and does not move" {
    var h = try Harness.init("alpha");
    defer h.deinit();
    try h.keys("right ctrl+f");
    try h.typeText("zzz");
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "not found") != null);
    try testing.expectEqual(@as(usize, 1), h.head());
    try h.keys("enter f3");
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "not found") != null);
    try h.expectText("alpha");
}

test "find is smart about case, and ctrl+r switches to regular expressions" {
    var h = try Harness.init("Foo foo f.o");
    defer h.deinit();
    try h.keys("ctrl+f");
    try h.typeText("foo");
    try testing.expectEqual(@as(usize, 0), h.app.view().primarySelection().start()); // lower case matches Foo
    try h.keys("esc ctrl+f");
    try h.typeText("f.o");
    try testing.expectEqual(@as(usize, 8), h.app.view().primarySelection().start()); // literal dot
    try h.keys("ctrl+r"); // now a pattern: any character
    try testing.expectEqual(@as(usize, 0), h.app.view().primarySelection().start());
    try testing.expect(h.app.search_regex);
    try h.keys("esc ctrl+f");
    try h.typeText("(");
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "regex:") != null);
    try h.keys("esc");
    try h.expectText("Foo foo f.o");
}

test "replace asks twice and replaces everything as one undo step" {
    var h = try Harness.init("a-b-c");
    defer h.deinit();
    try h.keys("ctrl+r");
    try testing.expect(std.mem.startsWith(u8, h.lastRow(), "Replace: "));
    try h.typeText("-");
    try h.keys("enter");
    try testing.expect(std.mem.startsWith(u8, h.lastRow(), "With: "));
    try h.typeText("+");
    try h.keys("enter");
    try h.expectText("a+b+c");
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "2 replaced") != null);
    try h.keys("ctrl+z");
    try h.expectText("a-b-c");
}

test "regex replace expands capture groups" {
    var h = try Harness.init("john smith\njane doe");
    defer h.deinit();
    h.app.search_regex = true;
    try h.keys("ctrl+r");
    try h.typeText("(\\w+) (\\w+)");
    try h.keys("enter");
    try h.typeText("$2, $1");
    try h.keys("enter");
    try h.expectText("smith, john\ndoe, jane");
}

test "go to line and column" {
    var h = try Harness.init("one\ntwo\nthree");
    defer h.deinit();
    try h.keys("ctrl+g");
    try h.typeText("3:2");
    try h.keys("enter");
    try testing.expectEqual(@as(usize, 9), h.head());
    try h.keys("ctrl+g");
    try h.typeText("99");
    try h.keys("enter");
    try testing.expectEqual(@as(usize, 8), h.head()); // clamped to the last line
    try h.keys("ctrl+g");
    try h.typeText("nonsense");
    try h.keys("enter");
    try testing.expectEqual(@as(usize, 8), h.head());
}

test "keys that mean nothing in a prompt neither close it nor edit the document" {
    var h = try Harness.init("text");
    defer h.deinit();
    try h.keys("ctrl+g up down f5 pgdn ctrl+d");
    try testing.expect(h.app.prompt != null);
    try h.typeText("1");
    try h.keys("left");
    try h.typeText("0");
    try testing.expectEqualStrings("01", h.app.prompt.?.input.value());
    try h.keys("esc");
    try h.expectText("text");
}

test "quit asks before discarding unsaved changes" {
    var h = try Harness.init("");
    defer h.deinit();
    try h.typeText("x");
    try h.keys("ctrl+q");
    try testing.expect(std.mem.startsWith(u8, h.lastRow(), "Unsaved changes - quit"));
    try testing.expect(!h.app.quit);
    try h.keys("n");
    try testing.expect(h.app.prompt == null);
    try testing.expect(!h.app.quit);
    try h.expectText("x"); // the answer was not typed into the document

    try h.keys("ctrl+q enter"); // enter is "no"
    try testing.expect(!h.app.quit);
    try h.keys("ctrl+q y");
    try testing.expect(h.app.quit);
}

test "with a session, quit does not ask: the unsaved text is kept for the next start" {
    defer for ([_][]const u8{ "session", "buffer-1.txt" }) |f| os.deleteFile(f) catch {};
    var h = try Harness.init("");
    defer h.deinit();
    h.app.state_dir = ".";
    try h.typeText("work in progress");
    try h.keys("ctrl+q");
    try testing.expect(h.app.quit);
    try testing.expect(h.app.prompt == null);
    app_mod.session.save(&h.app);
    try expectFile("buffer-1.txt", "work in progress");
}

test "quit with nothing unsaved does not ask, and a dirty background tab does" {
    var h = try Harness.init("");
    defer h.deinit();
    try h.keys("ctrl+q");
    try testing.expect(h.app.quit);

    h.app.quit = false;
    try h.typeText("x");
    try h.keys("ctrl+t ctrl+q"); // the dirty tab is not the focused one
    try testing.expect(!h.app.quit);
    try testing.expect(h.app.prompt != null);
}

test "tabs: new, cycle, close, and closing the last one quits" {
    var h = try Harness.init("one");
    defer h.deinit();
    try h.keys("ctrl+t");
    try testing.expectEqual(@as(usize, 2), h.app.docs.items.len);
    try testing.expectEqual(@as(usize, 1), h.app.activeIndex());
    try h.typeText("two");
    try h.keys("ctrl+pgup");
    try h.expectText("one");
    try h.keys("ctrl+pgup"); // wraps
    try h.expectText("two");
    try h.keys("ctrl+pgdn");
    try h.expectText("one");

    try h.keys("ctrl+w"); // clean: closes without asking
    try testing.expectEqual(@as(usize, 1), h.app.docs.items.len);
    try h.expectText("two");
    try h.keys("ctrl+w"); // dirty: asks
    try testing.expect(std.mem.startsWith(u8, h.lastRow(), "Unsaved changes - close"));
    try h.keys("y");
    try testing.expect(h.app.quit); // it was the last tab
}

test "a tab comes back to where its cursor was" {
    var h = try Harness.init("one two");
    defer h.deinit();
    try h.keys("end ctrl+t ctrl+pgup");
    try testing.expectEqual(@as(usize, 7), h.head());
}

test "the tab bar: click to switch, x to close, + for a new tab" {
    var h = try Harness.init("one");
    defer h.deinit();
    try h.keys("ctrl+t");
    try testing.expect(std.mem.startsWith(u8, h.row(0), " [No Name]  x   [No Name]  x "));
    h.click(3, 0);
    try h.expectText("one");
    h.click(27, 0); // the second tab's x
    try testing.expectEqual(@as(usize, 1), h.app.docs.items.len);
    h.click(58, 0); // " + " at the right edge
    try testing.expectEqual(@as(usize, 2), h.app.docs.items.len);
    try h.expectText("");
}

test "the close button on the last tab asks or quits, like ctrl+w" {
    var h = try Harness.init("");
    defer h.deinit();
    try h.typeText("x");
    h.click(16, 0); // " [No Name] [+]  x "
    try testing.expect(h.app.prompt != null);
    try h.keys("n");
    try h.keys("ctrl+z");
    h.click(12, 0);
    try testing.expect(h.app.quit);
}

test "a click on a tab is not a drag; a real drag reorders" {
    var h = try Harness.init("first");
    defer h.deinit();
    try h.keys("ctrl+t");
    try h.typeText("second");
    const first = h.app.docs.items[0];
    h.mouse(.press, 3, 0);
    h.mouse(.drag, 4, 0); // a wobble, not a drag
    try testing.expect(h.app.mouse.drag == null);
    h.mouse(.release, 4, 0);
    try testing.expectEqual(first, h.app.docs.items[0]);

    h.mouse(.press, 3, 0);
    h.mouse(.drag, 20, 0); // onto the second tab
    try testing.expect(h.app.mouse.drag != null);
    h.mouse(.release, 20, 0);
    try testing.expectEqual(first, h.app.docs.items[1]);
    try h.expectText("first"); // still the focused document
    try testing.expect(h.app.mouse.drag == null);
}

test "dragging a tab into the text splits the pane there" {
    var h = try Harness.init("first");
    defer h.deinit();
    try h.keys("ctrl+t");
    try h.typeText("second");
    h.mouse(.press, 3, 0); // the first tab; it takes over the only pane
    h.mouse(.drag, 55, 5); // the right third of the pane
    try testing.expectEqual(app_mod.mouse.DropSide.right, h.app.mouse.drop.?.side);
    h.mouse(.release, 55, 5);
    try testing.expectEqual(@as(usize, 2), h.app.layout.count());
    try h.expectText("first");
    try testing.expectEqual(@as(usize, 2), h.app.docs.items.len); // no document was created
}

test "a mouse click places the cursor; the wheel scrolls without moving it" {
    var h = try Harness.init("0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15");
    defer h.deinit();
    h.click(3, 3); // gutter is " N ": text starts at column 3; row 3 is line index 2
    try testing.expectEqual(@as(usize, 4), h.head());
    h.mouse(.wheel_down, 10, 5);
    try testing.expectEqual(@as(usize, 3), h.app.view().scroll_row);
    try testing.expectEqual(@as(usize, 4), h.head());
    try testing.expectEqualStrings(" 4 3", h.row(1));
    h.mouse(.wheel_up, 10, 5);
    h.mouse(.wheel_up, 10, 5);
    try testing.expectEqual(@as(usize, 0), h.app.view().scroll_row);
    // Typing brings the cursor back into view.
    h.mouse(.wheel_down, 10, 5);
    h.mouse(.wheel_down, 10, 5);
    try h.typeText("x");
    try testing.expectEqual(@as(usize, 2), h.app.view().scroll_row);
}

test "double click selects a word, triple a line, drag a range, shift extends" {
    var h = try Harness.init("hello world\nsecond line");
    defer h.deinit();
    h.click(9, 1); // inside "world" (gutter is two cells)
    h.click(9, 1);
    var sel = h.app.view().primarySelection();
    try testing.expectEqual(@as(usize, 6), sel.start());
    try testing.expectEqual(@as(usize, 11), sel.end());
    h.click(9, 1);
    sel = h.app.view().primarySelection();
    try testing.expectEqual(@as(usize, 0), sel.start());
    try testing.expectEqual(@as(usize, 12), sel.end());

    h.app.now_ms += 5000; // a pause: counting starts over
    h.mouse(.press, 2, 1);
    h.mouse(.drag, 5, 2);
    h.mouse(.release, 5, 2);
    sel = h.app.view().primarySelection();
    try testing.expectEqual(@as(usize, 0), sel.anchor);
    try testing.expectEqual(@as(usize, 15), sel.head);

    h.app.now_ms += 5000;
    h.click(2, 1);
    h.app.now_ms += 5000;
    h.app.handle(.{ .mouse = .{ .kind = .press, .button = .left, .x = 7, .y = 1, .mods = .{ .shift = true } } });
    sel = h.app.view().primarySelection();
    try testing.expectEqual(@as(usize, 0), sel.anchor);
    try testing.expectEqual(@as(usize, 5), sel.head);
}

test "ctrl+click adds a cursor" {
    var h = try Harness.init("aaa\nbbb");
    defer h.deinit();
    h.app.handle(.{ .mouse = .{ .kind = .press, .button = .left, .x = 3, .y = 2, .mods = .{ .ctrl = true } } });
    try testing.expectEqual(@as(usize, 2), h.app.view().selections.items.len);
    try h.typeText("X");
    try h.expectText("Xaaa\nbXbb");
}

test "ctrl+alt+down adds a cursor, and typing and backspace act at each" {
    var h = try Harness.init("aa\nbb\ncc");
    defer h.deinit();
    try h.keys("ctrl+alt+down ctrl+alt+down");
    try h.typeText("x");
    try h.expectText("xaa\nxbb\nxcc");
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "3 cursors") != null);
    try h.keys("backspace");
    try h.expectText("aa\nbb\ncc");
    try h.keys("esc");
    try testing.expect(!h.app.view().hasMultiple());
    try h.keys("ctrl+z ctrl+z"); // each multi-cursor edit is one step
    try h.expectText("aa\nbb\ncc");
}

test "the command palette lists commands with their keys and runs the chosen one" {
    var h = try Harness.init("one");
    defer h.deinit();
    try h.keys("ctrl+p");
    try testing.expect(std.mem.indexOf(u8, h.row(1), "Commands") != null);
    try h.typeText("dupl");
    try testing.expect(std.mem.indexOf(u8, h.row(2), "Duplicate line") != null);
    try testing.expect(std.mem.endsWith(u8, h.row(2), "ctrl+d"));
    try h.keys("enter");
    try testing.expect(h.app.picker == null);
    try h.expectText("one\none");

    // Esc closes it without running anything.
    try h.keys("ctrl+p");
    try h.typeText("quit");
    try h.keys("esc");
    try testing.expect(!h.app.quit);
    try h.expectText("one\none"); // and the filter was not typed into the text
}

test "the palette can open a prompt" {
    var h = try Harness.init("one");
    defer h.deinit();
    try h.keys("ctrl+p");
    try h.typeText("go to");
    try h.keys("enter");
    try testing.expect(h.app.picker == null);
    try testing.expect(std.mem.startsWith(u8, h.lastRow(), "Go to line:"));
}

test "syntax highlighting colours keywords and comments, and follows edits" {
    var h = try Harness.init("");
    defer h.deinit();
    try h.app.registry.parse("name=C\nextensions=c\nsingleline_comment_start=//\nmultiline_comment_delims=/*, */\nkeywords_1=int\n");
    _ = try h.app.addDoc("mibi-no-such-file.c", "int a; // note\nint b;\nint c;");
    h.draw();
    const theme = h.app.config.theme;
    try testing.expect(h.s.at(3, 1).fg.eql(theme.keyword1)); // column 2 is under the cursor
    try testing.expect(h.s.at(9, 1).fg.eql(theme.comment));
    try testing.expect(h.s.at(2, 2).fg.eql(theme.keyword1));
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "  C") != null);

    // Opening a block comment on the first line re-colours the lines below.
    try h.typeText("/* ");
    try testing.expect(h.s.at(2, 2).fg.eql(theme.comment));
    try testing.expect(h.s.at(2, 3).fg.eql(theme.comment));
    try h.keys("ctrl+z");
    try testing.expect(h.s.at(2, 2).fg.eql(theme.keyword1));
}

test "configuration: theme colours, line numbers, tab width, syntax off" {
    var h = try Harness.init("\tx");
    defer h.deinit();
    @import("../config.zig").apply(&h.app.config, "tab_width = 2\nline_numbers = false\n[theme]\ntext = #ff0000\n");
    // Settings are read when a view is made: open a fresh tab.
    _ = try h.app.addDoc(null, "\tx");
    h.draw();
    try testing.expectEqualStrings("  x", h.row(1));
    try testing.expect(h.s.at(2, 1).fg.eql(.{ .rgb = .{ .r = 0xff, .g = 0, .b = 0 } }));
    try h.keys("end tab");
    try h.expectText("\tx  ");
}

test "a key binding from the config reaches the editor and replaces the default" {
    var h = try Harness.init("one");
    defer h.deinit();
    @import("../config.zig").apply(&h.app.config, "[keys]\nctrl+n = new_tab\nf9 = duplicate_line\nctrl+d = move_end\n");
    try h.keys("ctrl+n");
    try testing.expectEqual(@as(usize, 2), h.app.docs.items.len);
    try h.keys("ctrl+t"); // new_tab moved away from its default
    try testing.expectEqual(@as(usize, 2), h.app.docs.items.len);
    try h.keys("ctrl+pgup f9");
    try h.expectText("one\none");
    try h.keys("ctrl+home ctrl+d"); // ctrl+d is now "end of line"
    try testing.expectEqual(@as(usize, 3), h.head());
    try h.keys("ctrl+home shift+ctrl+d"); // and shift extends, since it is a movement
    try testing.expectEqual(@as(usize, 0), h.app.view().primarySelection().anchor);
    try h.expectText("one\none");
}

test "splitting shows the same document twice, each pane with its own cursor" {
    var h = try Harness.init("one two");
    defer h.deinit();
    try h.keys("end f5");
    try testing.expectEqual(@as(usize, 2), h.app.layout.count());
    try testing.expectEqual(@as(usize, 1), h.app.docs.items.len);
    try testing.expectEqual(@as(usize, 7), h.head()); // the new pane starts where the old one was
    try h.keys("home");
    try h.typeText("X");
    try h.expectText("Xone two");
    // The other pane is the same text, and its cursor moved with the edit.
    try h.keys("f6");
    try h.expectText("Xone two");
    try testing.expectEqual(@as(usize, 8), h.head());
    try h.keys("f6");
    try testing.expectEqual(@as(usize, 1), h.head());
    // Both halves are drawn.
    try testing.expect(std.mem.indexOf(u8, h.row(1), "1 Xone two") != null);
    try testing.expect(std.mem.lastIndexOf(u8, h.row(1), "1 Xone two").? > 20);
}

test "closing a pane keeps the document; closing the tab closes every pane showing it" {
    var h = try Harness.init("one");
    defer h.deinit();
    try h.keys("f5 f7");
    try testing.expectEqual(@as(usize, 3), h.app.layout.count());
    try h.keys("shift+f5");
    try testing.expectEqual(@as(usize, 2), h.app.layout.count());
    try testing.expectEqual(@as(usize, 1), h.app.docs.items.len);

    try h.keys("ctrl+t"); // a second document, in the focused pane
    try h.typeText("two");
    try h.keys("f6"); // the other pane still shows the first
    try h.expectText("one");
    try h.keys("ctrl+w"); // close "one": its pane goes with it
    try testing.expectEqual(@as(usize, 1), h.app.layout.count());
    try testing.expectEqual(@as(usize, 1), h.app.docs.items.len);
    try h.expectText("two");
    try h.keys("shift+f5"); // the last pane always stays
    try testing.expectEqual(@as(usize, 1), h.app.layout.count());
}

test "clicking a pane focuses it and places the cursor there" {
    var h = try Harness.init("left right");
    defer h.deinit();
    try h.keys("f5"); // focus is on the new, right pane
    const right = h.app.layout.focused().?;
    h.click(4, 1);
    try testing.expect(h.app.layout.focused().? != right);
    try testing.expectEqual(@as(usize, 2), h.head());
    h.click(40, 1);
    try testing.expectEqual(right, h.app.layout.focused().?);
}

test "there is a limit to the panes, and reaching it is said, not crashed" {
    var h = try Harness.initSized("x", 200, 40);
    defer h.deinit();
    var i: usize = 0;
    while (i < 12) : (i += 1) try h.keys("f5");
    try testing.expectEqual(@as(usize, 8), h.app.layout.count());
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "no room") != null);
    while (h.app.layout.count() > 1) try h.keys("shift+f5");
    try h.typeText("y");
    try h.expectText("yx");
}

test "bracketed paste goes in as one undo step, with line endings normalised" {
    var h = try Harness.init("");
    defer h.deinit();
    h.app.handle(.{ .paste = "one\r\ntwo\rthree" });
    try h.expectText("one\ntwo\nthree");
    try h.keys("ctrl+z");
    try h.expectText("");
    // In a prompt the paste goes to the prompt, as one line.
    try h.keys("ctrl+f");
    h.app.handle(.{ .paste = "a\nb" });
    try testing.expectEqualStrings("ab", h.app.prompt.?.input.value());
    try h.keys("esc");
    try h.expectText("");
}

// --- files -------------------------------------------------------------------
//
// These touch the disk, in the working directory like the other file tests.

fn expectFile(path: []const u8, want: []const u8) !void {
    const got = try os.readFileAlloc(testing.allocator, path, 1 << 20);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "ctrl+o picks a file, which takes the place of an untouched empty tab" {
    const path = "mibi-open-test.txt";
    defer os.deleteFile(path) catch {};
    try os.writeFile(path, "from disk\r\nsecond\r\n");

    var h = try Harness.init("");
    defer h.deinit();
    try h.keys("ctrl+o");
    try h.typeText("mibi-open-test");
    try h.keys("enter");
    try testing.expect(h.app.picker == null);
    try testing.expectEqual(@as(usize, 1), h.app.docs.items.len);
    try h.expectText("from disk\nsecond\n"); // one kind of line break in memory
    try testing.expect(std.mem.indexOf(u8, h.row(0), path) != null);
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "CRLF") != null);

    // Saving writes the file's own line endings back.
    try h.typeText("X");
    try testing.expect(h.app.doc().isDirty());
    try h.keys("ctrl+s");
    try testing.expect(!h.app.doc().isDirty());
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "Saved") != null);
    try expectFile(path, "Xfrom disk\r\nsecond\r\n");

    // Opening it again goes to its tab rather than making a second one.
    try h.keys("ctrl+t");
    try h.app.openPath(path);
    try testing.expectEqual(@as(usize, 2), h.app.docs.items.len);
    try testing.expectEqual(@as(usize, 0), h.app.activeIndex());
}

test "a file that cannot be opened is said in the picker, and nothing opens" {
    var h = try Harness.init("keep");
    defer h.deinit();
    try h.keys("ctrl+o");
    try h.typeText("src");
    try h.keys("enter"); // a directory: the picker goes into it
    try testing.expect(h.app.picker != null);
    try h.keys("esc");
    try testing.expect(h.app.picker == null);
    try testing.expectEqual(@as(usize, 1), h.app.docs.items.len);
    try h.expectText("keep");
}

test "saving an unnamed tab asks for a name; a failed save keeps it unnamed and unsaved" {
    const path = "mibi-saveas-test.c";
    defer os.deleteFile(path) catch {};

    var h = try Harness.init("");
    defer h.deinit();
    try h.app.registry.parse("name=C\nextensions=c\nkeywords_1=int\n");
    try h.typeText("int x;");
    try h.keys("ctrl+s");
    try testing.expect(std.mem.startsWith(u8, h.lastRow(), "Save as:"));

    try h.typeText("mibi-no-such-dir/x.c");
    try h.keys("enter");
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "Save failed") != null);
    try testing.expect(h.app.doc().path == null);
    try testing.expect(h.app.doc().isDirty());

    try h.keys("ctrl+s");
    try h.typeText(path);
    try h.keys("enter");
    try testing.expect(!h.app.doc().isDirty());
    try testing.expectEqualStrings(path, h.app.doc().path.?);
    try expectFile(path, "int x;");
    // The new name decides the language.
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "  C") != null);
}

test "f4 runs the configured formatter, undoably, and says why when it cannot" {
    var h = try Harness.initSized("b\na\n", 100, 12);
    defer h.deinit();
    try h.keys("f4");
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "Save the file first") != null);

    _ = try h.app.addDoc("mibi-format-test.txt", "b\na\n");
    try h.keys("f4");
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "No formatter configured") != null);

    // Numbering the lines stands in for a formatter: a real child process
    // that reads the text and prints a different one.
    config_mod.apply(&h.app.config, if (os.is_windows) "[format]\ntxt = cmd.exe /c findstr /n .\n" else "[format]\ntxt = cat -n\n");
    try h.keys("f4");
    const sep = if (os.is_windows) ":" else "\t"; // `1:b` or `     1<tab>b`
    try testing.expect(std.mem.indexOf(u8, h.text(), "1" ++ sep ++ "b") != null);
    try testing.expect(std.mem.indexOf(u8, h.text(), "2" ++ sep ++ "a") != null);
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "Formatted") != null);
    try testing.expect(h.app.doc().isDirty());
    try h.keys("ctrl+z"); // one step back to what it was
    try h.expectText("b\na\n");

    config_mod.apply(&h.app.config, "[format]\nmd = mibi-no-such-program\n");
    _ = try h.app.addDoc("mibi-format-test.md", "x\n");
    try h.keys("f4");
    try h.expectText("x\n");
    try testing.expect(h.lastRow().len > 0); // it said something, and did not crash
}

test "a file changed on disk is reloaded when clean and left alone when not" {
    const path = "mibi-reload-test.txt";
    defer os.deleteFile(path) catch {};
    try os.writeFile(path, "first\n");

    var h = try Harness.initSized("", 100, 12);
    defer h.deinit();
    try h.app.openPath(path);
    try testing.expect(!h.app.tick()); // nothing changed yet

    try os.writeFile(path, "first\nand more\n");
    try testing.expect(h.app.tick());
    h.draw();
    try h.expectText("first\nand more\n");
    try testing.expect(!h.app.doc().isDirty());
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "reloaded") != null);
    // The reload is an edit like any other: the old text is one undo away.
    try h.keys("ctrl+z");
    try h.expectText("first\n");
    try h.keys("ctrl+y");

    try h.typeText("mine ");
    try os.writeFile(path, "theirs, and longer than before\n");
    try testing.expect(h.app.tick());
    h.draw();
    try h.expectText("mine first\nand more\n");
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "changed on disk") != null);
    try testing.expect(!h.app.tick()); // said once, not every half second
}

test "the session brings back tabs, panes, cursors and unsaved text" {
    const path = "mibi-session-test.txt";
    const files = [_][]const u8{ path, "session", "buffer-1.txt", "buffer-2.txt", "buffer-3.txt" };
    defer for (files) |f| os.deleteFile(f) catch {};
    try os.writeFile(path, "saved one\nsaved two\n");

    {
        var h = try Harness.init("");
        defer h.deinit();
        h.app.state_dir = ".";
        try h.typeText("never saved"); // tab 1: unnamed, with text
        try h.app.openPath(path); // tab 2: a file,
        try h.keys("down end");
        try h.typeText("!"); // with a change that is not on disk
        try h.keys("f5"); // and shown in two panes
        try h.keys("ctrl+home");
        try testing.expect(h.app.session_dirty);
        app_mod.session.save(&h.app);
        try testing.expect(!h.app.session_dirty);
    }
    try expectFile(path, "saved one\nsaved two\n"); // the session never writes the file itself

    var h = try Harness.initBare(testing.allocator, 60, 12);
    defer h.deinit();
    h.app.state_dir = ".";
    try testing.expect(app_mod.session.load(&h.app));
    h.draw();
    try testing.expectEqual(@as(usize, 2), h.app.docs.items.len);
    try testing.expectEqual(@as(usize, 2), h.app.layout.count());
    try h.expectText("saved one\nsaved two!\n");
    try testing.expect(h.app.doc().isDirty());
    try testing.expectEqual(@as(usize, 0), h.head());
    try h.keys("f6"); // the other pane kept its own cursor
    try testing.expectEqual(@as(usize, "saved one\nsaved two!".len), h.head());
    try h.keys("ctrl+pgup");
    try h.expectText("never saved");
    try testing.expect(h.app.doc().path == null);
}

test "a session file that is damaged or from another version is ignored" {
    defer os.deleteFile("session") catch {};
    var h = try Harness.init("mine");
    defer h.deinit();
    h.app.state_dir = ".";
    for ([_][]const u8{ "", "mibi-session 1\ndoc 1 0 0 0 0 0 x\n", "mibi-session 2\ndoc x y z\npane 99 0 0 0 0 1\nsplit 7 7\n\xff\xfe" }) |bad| {
        try os.writeFile("session", bad);
        _ = app_mod.session.load(&h.app);
        h.draw();
        try testing.expect(h.app.docs.items.len >= 1);
        try h.expectText("mine");
    }
}

test "the file tree: ctrl+b shows it, the keys walk it, enter opens, ctrl+b twice hides it" {
    var h = try Harness.initSized("", 80, 40);
    defer h.deinit();
    try h.keys("ctrl+b");
    try testing.expect(h.app.tree != null and h.app.tree_focus);
    var found: ?usize = null;
    for (1..h.s.rows - 1) |y| {
        const text = h.row(y);
        if (std.mem.indexOf(u8, text, "build.zig") != null and std.mem.indexOf(u8, text, ".zon") == null) found = y;
    }
    try testing.expect(found != null);

    // Typing goes to the tree, not into the document.
    try h.typeText("jjkx");
    try h.expectText("");

    // A click selects a row; a second click opens it.
    h.click(3, @intCast(found.?));
    h.click(3, @intCast(found.?));
    try testing.expect(std.mem.endsWith(u8, h.app.doc().path.?, "build.zig"));
    try testing.expect(h.app.doc().document.len() > 0);

    try h.keys("ctrl+b"); // focus is back in the tree
    try testing.expect(h.app.tree_focus);
    try h.keys("ctrl+b");
    try testing.expect(h.app.tree == null);

    // Too narrow for both: the tree gives way to the text.
    var narrow = try Harness.initSized("text", 30, 10);
    defer narrow.deinit();
    try narrow.keys("ctrl+b");
    try testing.expect(std.mem.startsWith(u8, narrow.row(1), "1 text"));
}

test "the theme picker previews as it moves, esc puts the old theme back, enter saves it" {
    const ini = "mibi-theme-test.ini";
    defer os.deleteFile(ini) catch {};
    try os.writeFile(ini, "[editor]\ntab_width = 2\n");

    var h = try Harness.initSized("text", 60, 20);
    defer h.deinit();
    h.app.config.setSource(ini);
    const before = h.app.config.theme;
    try h.keys("f2");
    try h.typeText("dracula");
    try testing.expect(!h.app.config.theme.background.eql(before.background));
    try h.keys("esc");
    try testing.expect(h.app.config.theme.background.eql(before.background));

    try h.keys("f2");
    try h.typeText("dracula");
    try h.keys("enter");
    try testing.expect(!h.app.config.theme.background.eql(before.background));
    try testing.expectEqualStrings("dracula", h.app.config.themeName());
    try expectFile(ini, "[editor]\ntab_width = 2\ntheme = dracula\n");
}

test "a file name outside ASCII is shown as it is" {
    var h = try Harness.init("");
    defer h.deinit();
    _ = try h.app.addDoc("mibi-h\xc3\xa9llo-\xe6\x97\xa5\xe6\x9c\xac.txt", "x");
    h.draw();
    try testing.expect(std.mem.indexOf(u8, h.row(0), "h\xc3\xa9llo-\xe6\x97\xa5\xe6\x9c\xac.txt") != null);
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "h\xc3\xa9llo-\xe6\x97\xa5\xe6\x9c\xac.txt") != null);
}

// --- running out of memory -----------------------------------------------------

test "an allocation failure anywhere is survived: no crash, no leak, the text intact" {
    var fail_at: usize = 0;
    while (fail_at < 4000) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_at });
        var h = Harness.initWith(failing.allocator(), "one two\nthree four\n", 60, 14) catch continue;
        defer h.deinit();
        try h.keys("ctrl+d end");
        try h.typeText(" five");
        try h.keys("ctrl+f");
        try h.typeText("t.o");
        try h.keys("ctrl+r enter ctrl+r");
        try h.typeText("o");
        try h.keys("enter");
        try h.typeText("0");
        try h.keys("enter ctrl+p");
        try h.typeText("stacked");
        try h.keys("enter f6 ctrl+t");
        try h.typeText("new tab");
        try h.keys("ctrl+a ctrl+c ctrl+v ctrl+v ctrl+z ctrl+y ctrl+pgup");
        try h.keys("ctrl+alt+down tab shift+tab alt+down ctrl+k f1 f1 f2 down esc ctrl+b ctrl+b ctrl+b alt+z down up pgdn");
        h.app.handle(.{ .paste = "pasted\r\ntext" });
        h.mouse(.press, 6, 2);
        h.mouse(.drag, 9, 3);
        h.mouse(.release, 9, 3);
        h.draw();
        // Whatever failed, the documents are still whole and readable.
        for (h.app.docs.items) |d| {
            const text = d.document.buffer.toOwned(testing.allocator) catch continue;
            defer testing.allocator.free(text);
            try testing.expect(std.unicode.utf8ValidateSlice(text));
        }
        if (!failing.has_induced_failure) break;
    }
    try testing.expect(fail_at > 50); // the scenario allocates, so the loop did real work
    try testing.expect(fail_at < 4000); // and it ended because a run got through untouched
}

// --- soft wrap -----------------------------------------------------------------

test "alt+z folds long lines; up and down move by the rows you see" {
    // 30 columns: 2 for the line number, 1 kept free, 27 of text.
    var h = try Harness.initSized("alpha beta gamma delta epsilon zeta eta theta iota\nend", 30, 10);
    defer h.deinit();
    try testing.expectEqualStrings("1 alpha beta gamma delta epsil", h.row(1)); // cut off, not folded
    try h.keys("alt+z");
    try testing.expectEqualStrings("1 alpha beta gamma delta", h.row(1));
    try testing.expectEqualStrings("  epsilon zeta eta theta iota", h.row(2));
    try testing.expectEqualStrings("2 end", h.row(3));
    try testing.expectEqualStrings("word wrap on", h.app.message());

    // Down goes to the row below on screen, in the same column, though it
    // is the same line of the file.
    try h.keys("right right down");
    try testing.expectEqual(@as(usize, "alpha beta gamma delta ep".len), h.head());
    try h.keys("down");
    try testing.expectEqual(@as(usize, "alpha beta gamma delta epsilon zeta eta theta iota\nen".len), h.head());
    try h.keys("down"); // the last row: to the end of the text
    try testing.expectEqual(h.text().len, h.head());
    try h.keys("up up");
    try testing.expectEqual(@as(usize, 2), h.head()); // the column it set out from is remembered
    try h.keys("up"); // the first row: to the start
    try testing.expectEqual(@as(usize, 0), h.head());

    // Home and end still mean the line of the file.
    try h.keys("end");
    try testing.expectEqual(@as(usize, 50), h.head());

    // A click on a folded row lands on that row's text.
    h.click(2, 2);
    try testing.expectEqual(@as(usize, "alpha beta gamma delta ".len), h.head());

    try h.keys("alt+z");
    try testing.expectEqualStrings("2 end", h.row(2));
}

test "with wrap the window follows the cursor through a long line, and the wheel scrolls rows" {
    var h = try Harness.initSized("", 20, 6); // 4 rows of text, 17 cells wide
    defer h.deinit();
    config_mod.apply(&h.app.config, "soft_wrap = true\n");
    try h.typeText("aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll mmmm nnnn oooo pppp");
    // Typing ran past the bottom: the window starts inside the line, so
    // the first row has no number, and the cursor is on the last row.
    try testing.expect(h.app.view().scroll_sub > 0);
    try testing.expectEqualStrings("  mmmm nnnn oooo", h.row(3));
    try testing.expectEqualStrings("  pppp", h.row(4));
    try testing.expect(h.s.at(6, 4).attr.reverse);

    try h.keys("ctrl+home");
    try testing.expectEqualStrings("1 aaaa bbbb cccc", h.row(1));
    h.mouse(.wheel_down, 5, 2);
    try testing.expectEqualStrings("  jjjj kkkk llll", h.row(1)); // three rows down
    try testing.expectEqual(@as(usize, 0), h.head()); // the cursor stayed
    h.mouse(.wheel_up, 5, 2);
    h.mouse(.wheel_up, 5, 2);
    try testing.expectEqualStrings("1 aaaa bbbb cccc", h.row(1));

    // Narrowing the window re-folds without losing the place.
    try h.keys("ctrl+end");
    h.s.deinit();
    h.s = try screen.Screen.init(testing.allocator, 12, 6);
    h.draw();
    try testing.expect(h.app.view().wrap_cols == 9);
    var found = false;
    for (1..5) |y| {
        for (0..12) |x| {
            if (h.s.at(x, y).attr.reverse) found = true;
        }
    }
    try testing.expect(found);
}

test "ctrl+] jumps between a bracket and its partner, and shift selects up to it" {
    var h = try Harness.init("if (a[0]) { b(); }");
    defer h.deinit();
    try h.keys("right right right ctrl+]"); // on "("
    try testing.expectEqual(@as(usize, 8), h.head());
    try h.keys("ctrl+]");
    try testing.expectEqual(@as(usize, 3), h.head());
    try h.keys("end ctrl+]"); // just after "}"
    try testing.expectEqual(@as(usize, 10), h.head());
    try h.keys("shift+ctrl+]");
    const sel = h.app.view().primarySelection();
    try testing.expectEqual(@as(usize, 10), sel.start());
    try testing.expectEqual(@as(usize, 17), sel.end());
    // Nowhere near a bracket: nothing moves.
    try h.keys("home ctrl+]");
    try testing.expectEqual(@as(usize, 0), h.head());
}

test "alt+x pipes the selection, or everything, through a shell command" {
    var h = try Harness.initSized("pear\napple\nfig\n", 100, 12);
    defer h.deinit();
    // Dropping the lines that hold a word; on Unix through a pipe, to show
    // that the line really goes to a shell.
    const drop = if (os.is_windows) "findstr /v " else "cat | grep -v ";
    try h.keys("alt+x");
    try testing.expect(std.mem.startsWith(u8, h.lastRow(), "Filter through:"));
    try h.typeText(drop);
    try h.typeText("fig");
    try h.keys("enter");
    try h.expectText("pear\napple\n");
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "Filtered through") != null);
    try h.keys("ctrl+z"); // one step
    try h.expectText("pear\napple\nfig\n");

    // Only the selection goes through, and what comes back stays selected.
    try h.keys("ctrl+home shift+down shift+down alt+x");
    try h.typeText(drop);
    try h.typeText("pear");
    try h.keys("enter");
    try h.expectText("apple\nfig\n");
    const sel = h.app.view().primarySelection();
    try testing.expectEqual(@as(usize, 0), sel.start());
    try testing.expectEqual(@as(usize, "apple\n".len), sel.end());

    // A command that fails changes nothing and says so.
    try h.keys("alt+x");
    try h.typeText("exit 3");
    try h.keys("enter");
    try h.expectText("apple\nfig\n");
    try testing.expect(std.mem.indexOf(u8, h.lastRow(), "exit code 3") != null);

    // Esc, or an empty command, does nothing.
    try h.keys("alt+x esc alt+x enter");
    try testing.expect(h.app.prompt == null);
    try h.expectText("apple\nfig\n");
}
