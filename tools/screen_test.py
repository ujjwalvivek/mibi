"""ConPTY screen test for mibi (Windows only).

Runs the real binary inside a pseudo console, drives it with real keystrokes and
renders what the terminal receives, so the console path in src/term.zig and
src/os.zig (ReadConsoleInputW translation, WriteFile, resize) is exercised - the
unit tests cannot reach it.

    python tools/screen_test.py            # run every check
    python tools/screen_test.py -k find    # only checks whose name contains "find"

Requires pywinpty (`pip install pywinpty`). Screenshots are written to
experiments/out/screens/*.txt for inspection. Exit code 0 means every check
passed.
"""

import os
import subprocess
import sys
import shutil
import tempfile
import threading
import time
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIBI = os.path.join(ROOT, "zig-out", "bin", "mibi.exe")
SHOT_DIR = os.path.join(ROOT, "experiments", "out", "screens")
ROWS, COLS = 24, 80


# --- a very small terminal emulator ----------------------------------------

def cell_width(ch):
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


class Screen:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[" "] * cols for _ in range(rows)]
        self.fg_grid = [[None] * cols for _ in range(rows)]
        self.bg_grid = [[None] * cols for _ in range(rows)]
        self.r = self.c = 0
        self.fg = None
        self.title = ""
        self._pending = ""

    def clear(self):
        self.grid = [[" "] * self.cols for _ in range(self.rows)]
        self.fg_grid = [[None] * self.cols for _ in range(self.rows)]
        self.bg_grid = [[None] * self.cols for _ in range(self.rows)]
        self.r = self.c = 0

    def _put(self, ch):
        w = cell_width(ch)
        if self.r >= self.rows:
            return
        if self.c < self.cols:
            self.grid[self.r][self.c] = ch
            self.fg_grid[self.r][self.c] = self.fg
        self.bg_grid[self.r][self.c] = self.bg
        if w == 2 and self.c + 1 < self.cols:
            self.grid[self.r][self.c + 1] = ""  # continuation of a wide glyph
        self.c += w
        if self.c >= self.cols:  # auto-wrap is off in mibi, but stay safe
            self.c = self.cols - 1

    def feed(self, text):
        data = self._pending + text
        self._pending = ""
        i = 0
        while i < len(data):
            ch = data[i]
            if ch == "\x1b":
                n = self._escape(data, i)
                if n == 0:
                    self._pending = data[i:]
                    return
                i += n
                continue
            if ch == "\r":
                self.c = 0
            elif ch == "\n":
                self.r = min(self.r + 1, self.rows - 1)
            elif ch == "\b":
                self.c = max(0, self.c - 1)
            elif ch >= " ":
                self._put(ch)
            i += 1

    def _escape(self, data, i):
        if i + 1 >= len(data):
            return 0
        kind = data[i + 1]
        if kind == "[":
            j = i + 2
            while j < len(data) and not ("@" <= data[j] <= "~"):
                j += 1
            if j >= len(data):
                return 0
            self._csi(data[i + 2:j], data[j])
            return j + 1 - i
        if kind == "]":  # OSC ... BEL / ST
            j = i + 2
            while j < len(data):
                if data[j] == "\x07":
                    self._osc(data[i + 2:j])
                    return j + 1 - i
                if data[j] == "\x1b" and j + 1 < len(data) and data[j + 1] == "\\":
                    self._osc(data[i + 2:j])
                    return j + 2 - i
                j += 1
            return 0
        return 2  # two-character escape

    def _csi(self, params, final):
        body = params[1:] if params.startswith("?") else params
        nums = [int(p) if p.isdigit() else 0 for p in body.split(";")] if body else []
        p0 = nums[0] if nums else 0
        p1 = nums[1] if len(nums) > 1 else 0
        if final in "Hf":
            self.r = max(0, (p0 or 1) - 1)
            self.c = max(0, (p1 or 1) - 1)
        elif final == "J":
            if p0 in (0, 2, 3):
                self.clear()
        elif final == "m":
            self._sgr(nums)
        elif final == "K":
            for x in range(self.c, self.cols):
                self.grid[self.r][x] = " "
        elif final == "A":
            self.r = max(0, self.r - (p0 or 1))
        elif final == "B":
            self.r = min(self.rows - 1, self.r + (p0 or 1))
        elif final == "C":
            self.c = min(self.cols - 1, self.c + (p0 or 1))
        elif final == "D":
            self.c = max(0, self.c - (p0 or 1))
        # SGR (m), private modes (h/l), window ops (t), DA (c): ignored

    def _osc(self, body):
        """Remember the window title (OSC 2)."""
        if body.startswith("2;"):
            self.title = body[2:]

    def _sgr(self, nums):
        """Track foreground and background true colours for the tests."""
        i = 0
        while i < len(nums):
            n = nums[i]
            if n == 0:
                self.fg = None
                self.bg = None
            elif n == 39:
                self.fg = None
            elif n == 49:
                self.bg = None
            elif n in (38, 48) and i + 4 < len(nums) and nums[i + 1] == 2:
                colour = (nums[i + 2], nums[i + 3], nums[i + 4])
                if n == 38:
                    self.fg = colour
                else:
                    self.bg = colour
                i += 4
            i += 1

    def bg_at(self, row, col):
        if 0 <= row < self.rows and 0 <= col < self.cols:
            return self.bg_grid[row][col]
        return None

    def fg_at(self, row, col):
        if 0 <= row < self.rows and 0 <= col < self.cols:
            return self.fg_grid[row][col]
        return None

    def lines(self):
        return ["".join(row).rstrip() for row in self.grid]

    def text(self):
        return "\n".join(self.lines())

    def row(self, n):
        return self.lines()[n]

    def find(self, needle):
        return any(needle in line for line in self.lines())


# --- driver ----------------------------------------------------------------

class Mibi:
    def __init__(self, args, cwd=ROOT, rows=ROWS, cols=COLS, keep_session=False):
        # Each check starts from a clean slate: a leftover session file would
        # restore tabs and dirty buffers from an earlier run.
        if cwd and not keep_session:
            for name in os.listdir(cwd) if os.path.isdir(cwd) else []:
                if name.startswith("mibi-session"):
                    try:
                        os.remove(os.path.join(cwd, name))
                    except OSError:
                        pass
        from winpty import PtyProcess
        self.screen = Screen(rows, cols)
        self._lock = threading.Lock()
        self._eof = False
        self.proc = PtyProcess.spawn([MIBI, "--in-terminal"] + args, dimensions=(rows, cols),
                                     cwd=cwd)
        self._thread = threading.Thread(target=self._reader, daemon=True)
        self._thread.start()

    def _reader(self):
        while not self._eof:
            try:
                data = self.proc.read(65536)
            except EOFError:
                return
            except Exception:
                return
            if not data:
                return
            with self._lock:
                self.screen.feed(data)

    def screen_text(self):
        with self._lock:
            return self.screen.text()

    def wait_for(self, needle, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if needle in self.screen_text():
                return True
            time.sleep(0.03)
        return False

    def wait_quiet(self, settle=0.25, timeout=5.0):
        """Wait until the screen stops changing."""
        deadline = time.time() + timeout
        last = None
        stable_since = time.time()
        while time.time() < deadline:
            now = self.screen_text()
            if now != last:
                last = now
                stable_since = time.time()
            elif time.time() - stable_since >= settle:
                return
            time.sleep(0.02)

    def send(self, keys, settle=0.25):
        self.proc.write(keys)
        self.wait_quiet(settle)

    def resize(self, rows, cols, settle=0.4):
        # The editor repaints every row after a resize, so a fresh grid is fine.
        with self._lock:
            self.screen = Screen(rows, cols)
        self.proc.setwinsize(rows, cols)
        time.sleep(settle)
        self.wait_quiet(settle)

    def alive(self):
        return self.proc.isalive()

    def shot(self, name):
        os.makedirs(SHOT_DIR, exist_ok=True)
        path = os.path.join(SHOT_DIR, name + ".txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write(self.screen_text() + "\n")
        return path

    def close(self):
        self._eof = True
        if self.proc.isalive():
            try:
                self.proc.write("\x11")  # Ctrl+Q
                time.sleep(0.2)
            except Exception:
                pass
        if self.proc.isalive():
            try:
                subprocess.run(["taskkill", "/PID", str(self.proc.pid), "/F"],
                               capture_output=True, timeout=5)
            except Exception:
                pass
        try:
            self.proc.close(force=True)
        except Exception:
            pass


# --- checks ----------------------------------------------------------------

CHECKS = []


def check(fn):
    CHECKS.append(fn)
    return fn


def assert_in(screen, needle, what=""):
    assert needle in screen, f"expected {needle!r} on screen ({what}):\n{screen}"


def assert_not_in(screen, needle, what=""):
    assert needle not in screen, f"did not expect {needle!r} on screen ({what}):\n{screen}"


@check
def startup_renders_file(m, path):
    """Opening a file shows the tab bar, the gutter, the text and the status."""
    assert m.wait_for("hello"), "no text after startup"
    screen = m.screen_text()
    assert "F1 help" in screen.splitlines()[-1], "status bar hint missing"
    assert "notes.txt" in m.screen.title, f"window title not set: {m.screen.title!r}"
    assert_in(screen, "notes.txt", "tab bar")
    assert_in(screen, "1 hello", "gutter + first line")
    assert_in(screen, "2 world", "second line")
    assert_in(screen, "mibi 0.0.1", "status bar")
    assert_in(screen, "2L", "line count")
    assert_in(screen, "80x24", "terminal size")
    m.shot("01-startup")


@check
def typing_edits_and_marks_dirty(m, path):
    """Typing inserts at the cursor and the status bar shows [+]."""
    m.send("X")
    screen = m.screen_text()
    assert_in(screen, "Xhello", "typed character before the cursor")
    assert_in(screen, "[+]", "dirty marker")
    assert_in(screen, "1:2", "cursor moved right")
    m.shot("02-typed")


@check
def help_panel_toggles(m, path):
    """Ctrl+? opens the controls panel; Ctrl+? closes it again."""
    m.send("\x1f")
    assert m.wait_for("mibi controls"), "help panel did not open"
    screen = m.screen_text()
    assert_in(screen, "quit (asks if unsaved)"), "quit line missing"
    assert_in(screen, "ctrl+q"), "quit key missing"
    assert_in(screen, "find / next / previous"), "find line missing"
    m.shot("03-help")
    m.send("\x1f")
    m.wait_quiet()
    assert_not_in(m.screen_text(), "mibi controls")


@check
def quit_guard_asks_and_cancels(m, path):
    """Ctrl+Q on a dirty buffer asks; n keeps editing."""
    m.send("x")  # make the buffer dirty
    m.send("\x11")
    assert m.wait_for("quit without saving? (y/N)"), "no confirm prompt"
    m.shot("04-quit-confirm")
    m.send("n")
    m.wait_quiet()
    assert_not_in(m.screen_text(), "quit without saving?")
    assert m.alive(), "editor exited on 'n'"


@check
def find_prompt_ignores_arrows(m, path):
    """The find prompt stays open on arrow keys and jumps to the match."""
    m.send("\x06")  # Ctrl+F
    assert m.wait_for("Find:"), "find prompt missing"
    m.send("world")
    m.send("\x1b[C")  # Right: must not cancel the prompt
    m.wait_quiet()
    assert_in(m.screen_text(), "Find: world", "prompt survived an arrow key")
    m.send("\x1b")  # Esc closes it
    m.wait_quiet()
    assert_not_in(m.screen_text(), "Find:")
    m.shot("05-find")


@check
def goto_and_replace(m, path):
    """Ctrl+G moves the cursor; Ctrl+R replaces all."""
    m.send("\x07")  # Ctrl+G
    assert m.wait_for("Go to line:"), "goto prompt missing"
    m.send("2\r")
    m.wait_quiet()
    assert m.wait_for("2:1"), "goto did not move to line 2"
    m.send("\x12")  # Ctrl+R
    assert m.wait_for("Replace:"), "replace prompt missing"
    m.send("world\r")
    assert m.wait_for("With:"), "replace-with prompt missing"
    m.send("there\r")
    m.wait_quiet()
    assert m.wait_for("1 replaced"), "replace count not reported"
    assert_in(m.screen_text(), "there", "replacement text on screen")
    m.shot("06-replace")


@check
def tabs_open_switch_and_close(m, path):
    """Ctrl+T opens a tab, Ctrl+PgUp/PgDn switch, Ctrl+W closes it."""
    m.send("\x14")  # Ctrl+T
    screen = m.screen_text()
    assert_in(screen, "[No Name]", "new tab label")
    assert_in(screen, "notes.txt", "first tab still listed")
    m.send("draft")
    assert m.wait_for("draft"), "typing did not go to the new tab"

    m.send("\x1b[5;5~")  # Ctrl+PgUp -> first tab
    m.wait_quiet()
    assert_in(m.screen_text(), "hello", "did not switch back to the first tab")
    m.send("\x1b[6;5~")  # Ctrl+PgDn -> second tab
    m.wait_quiet()
    assert_in(m.screen_text(), "draft", "did not switch to the second tab")

    m.send("\x17")  # Ctrl+W on a dirty tab asks first
    assert m.wait_for("close without saving? (y/N)"), "no close confirmation"
    m.shot("09-tabs")
    m.send("y")
    m.wait_quiet()
    screen = m.screen_text()
    assert_in(screen, "notes.txt")
    assert_not_in(screen, "draft", "the closed tab is gone")


@check
def open_adds_a_tab(m, path):
    """Ctrl+O opens a file into a new tab instead of replacing the buffer."""
    m.send("\x0f")  # Ctrl+O
    assert m.wait_for("Open file"), "file picker missing"
    m.send("other.txt")
    m.send("\r")
    m.wait_quiet()
    screen = m.screen_text()
    assert_in(screen, "second file", "opened file content")
    assert_in(screen, "notes.txt", "first tab still open")
    assert_in(screen, "other.txt", "second tab listed")
    m.shot("10-open-tab")


@check
def syntax_highlighting_emits_colours(m, path):
    """A .zig file is highlighted: keywords differ from plain identifiers."""
    m.send("\x0f")  # Ctrl+O
    assert m.wait_for("Open file"), "file picker missing"
    m.send("sample.zig")
    m.send("\r")
    m.wait_quiet()
    text = m.screen_text()
    assert_in(text, "const", "zig file opened")
    row = next(i for i, line in enumerate(text.splitlines()) if "const" in line)
    col = text.splitlines()[row].index("const")
    keyword = m.screen.fg_at(row, col + 1)  # 'o' of "const"; the cursor covers 'c'
    plain = m.screen.fg_at(row, col + 7)  # 't' of "std"
    assert keyword is not None, "keyword cell has no true-colour foreground"
    assert keyword != plain, f"keyword colour {keyword} equals plain {plain}"
    m.shot("11-syntax")


@check
def config_file_sets_theme_and_gutter(m, path):
    """mibi.ini can hide line numbers and recolour the text."""
    cfg_dir = os.path.join(SHOT_DIR, "work-cfg")
    os.makedirs(cfg_dir, exist_ok=True)
    with open(os.path.join(cfg_dir, "mibi.ini"), "w", encoding="utf-8") as f:
        f.write("[editor]\nline_numbers = false\n\n[theme]\ntext = #ff0000\n")
    with open(os.path.join(cfg_dir, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("hello\nworld")

    proc = Mibi(["notes.txt"], cwd=cfg_dir)
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.wait_quiet()
        lines = proc.screen_text().splitlines()
        assert lines[1].startswith("hello"), f"line numbers not hidden: {lines[1]!r}"
        fg = proc.screen.fg_at(1, 0)
        assert fg == (255, 0, 0), f"theme text colour not applied: {fg}"
        proc.shot("12-config")
    finally:
        proc.close()


@check
def named_theme_is_applied(m, path):
    """`theme = dracula` loads themes/dracula.ini from next to the binary."""
    cfg_dir = os.path.join(SHOT_DIR, "work-theme")
    os.makedirs(cfg_dir, exist_ok=True)
    with open(os.path.join(cfg_dir, "mibi.ini"), "w", encoding="utf-8") as f:
        f.write("[editor]\ntheme = dracula\n")
    with open(os.path.join(cfg_dir, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("hello")

    proc = Mibi(["notes.txt"], cwd=cfg_dir)
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.wait_quiet()
        fg = proc.screen.fg_at(1, 2)  # first text cell: Dracula's #f8f8f2
        assert fg == (248, 248, 242), f"theme text colour not applied: {fg}"
        proc.shot("13-theme")
    finally:
        proc.close()


@check
def ctrl_o_picker_opens_a_file(m, path):
    """Ctrl+O lists the directory; typing filters it and Enter opens the file."""
    work = os.path.join(SHOT_DIR, "work-picker")
    os.makedirs(work, exist_ok=True)
    for name, text in (("alpha.txt", "alpha body"), ("beta.txt", "beta body")):
        with open(os.path.join(work, name), "w", encoding="utf-8") as f:
            f.write(text)
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("hello")

    proc = Mibi(["notes.txt"], cwd=work)
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.send("\x0f")  # Ctrl+O
        assert proc.wait_for("Open file"), "picker did not open"
        proc.send("beta")
        assert proc.wait_for("beta.txt"), "filter did not narrow the list"
        proc.send("\r")
        assert proc.wait_for("beta body"), "file did not open"
        proc.shot("14-picker")
    finally:
        proc.close()


@check
def f2_theme_picker_applies_a_theme(m, path):
    """F2 lists themes; Enter keeps the previewed one."""
    proc = Mibi([path])
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.wait_quiet()
        before = proc.screen.fg_at(1, 2)
        proc.send("\x1bOQ")  # F2
        assert proc.wait_for("Theme"), "theme picker did not open"
        proc.send("\x1b[B")  # down
        proc.send("\x1b[B")
        proc.send("\r")  # accept
        proc.wait_quiet()
        after = proc.screen.fg_at(1, 2)
        assert after != before, f"theme preview did not change colours ({before} -> {after})"
        proc.shot("15-theme-picker")
    finally:
        proc.close()


@check
def help_reflects_rebound_keys(m, path):
    """The help panel shows the user's binding instead of the built-in key."""
    work = os.path.join(SHOT_DIR, "work-help-keys")
    os.makedirs(work, exist_ok=True)
    with open(os.path.join(work, "mibi.ini"), "w", encoding="utf-8") as f:
        f.write("[keys]\nctrl+n = save\n")
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("hello")

    proc = Mibi(["notes.txt"], cwd=work)
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.send("\x1f")  # help
        assert proc.wait_for("mibi controls"), "help panel did not open"
        lines = proc.screen_text().splitlines()
        save_line = next(l for l in lines if "save" in l and "asks" not in l)
        assert "ctrl+n" in save_line, f"rebinding not shown: {save_line!r}"
        proc.shot("16-help-rebound")
    finally:
        proc.close()


@check
def theme_choice_persists(m, path):
    """A theme picked with F2 is written to mibi.ini and used on restart."""
    work = os.path.join(SHOT_DIR, "work-theme-save")
    os.makedirs(work, exist_ok=True)
    with open(os.path.join(work, "mibi.ini"), "w", encoding="utf-8") as f:
        f.write("[editor]\ntab_width = 2\n")
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("hello")

    proc = Mibi(["notes.txt"], cwd=work)
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.wait_quiet()
        proc.send("\x1bOQ")  # F2
        assert proc.wait_for("Theme"), "theme picker did not open"
        proc.send("\x1b[B")  # one down -> catppuccin-frappe
        proc.send("\r")
        proc.wait_quiet()
    finally:
        proc.close()

    with open(os.path.join(work, "mibi.ini"), encoding="utf-8") as f:
        saved = f.read()
    assert "theme = " in saved, f"theme not persisted: {saved!r}"
    assert "tab_width = 2" in saved, f"other settings lost: {saved!r}"

    again = Mibi(["notes.txt"], cwd=work)
    try:
        assert again.wait_for("hello"), "restart failed"
        again.wait_quiet()
        fg = again.screen.fg_at(1, 2)
        assert fg == (198, 208, 245), f"saved theme not applied on restart: {fg}"
    finally:
        again.close()


@check
def theme_background_covers_the_text_area(m, path):
    """Every text-area cell carries the theme background, not the terminal's."""
    work = os.path.join(SHOT_DIR, "work-bg")
    os.makedirs(work, exist_ok=True)
    with open(os.path.join(work, "mibi.ini"), "w", encoding="utf-8") as f:
        f.write("[editor]\ntheme = flexoki-dark\n")
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("one\ntwo\n")

    proc = Mibi(["notes.txt"], cwd=work)
    try:
        assert proc.wait_for("one"), "editor did not start"
        proc.wait_quiet()
        theme_bg = (16, 15, 15)  # flexoki-dark #100f0f
        # Row 1 is the cursor line and carries the tint; check the others.
        for row in range(2, proc.screen.rows - 1):
            for col in range(proc.screen.cols):
                bg = proc.screen.bg_at(row, col)
                assert bg in (None, theme_bg), f"row {row} col {col} has bg {bg}"
        proc.shot("17-background")
    finally:
        proc.close()


@check
def command_palette_runs_actions(m, path):
    """Ctrl+P lists every action; picking one runs it."""
    m.send("\x10")  # Ctrl+P
    assert m.wait_for("Commands"), "command palette did not open"
    m.send("new_tab")
    m.send("\r")
    m.wait_quiet()
    text = m.screen_text()
    assert "[No Name]" in text, f"new_tab did not run: {text.splitlines()[0]!r}"
    m.shot("18-palette")


@check
def mouse_click_places_the_cursor(m, path):
    """A left click on a text row moves the cursor to that cell."""
    m.send("\x1b[<0;5;3M")  # click: screen row 3 (second text line), column 5
    m.wait_quiet()
    status = m.screen_text().splitlines()[-1]
    assert "2:3" in status, f"click did not move the cursor: {status!r}"
    m.shot("19-mouse")


@check
def mouse_clicks_tabs_and_picker(m, path):
    """Click a tab to switch, click picker rows to select and accept."""
    work = os.path.join(SHOT_DIR, "work-click")
    os.makedirs(work, exist_ok=True)
    with open(os.path.join(work, "a.txt"), "w", encoding="utf-8") as f:
        f.write("alpha\nbeta\ngamma\ndelta")
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("hello\nworld\nthird\nfourth")

    proc = Mibi(["notes.txt"], cwd=work)
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.wait_quiet()

        # One wheel notch moves one line.
        proc.send("\x1b[<65;5;3M")
        proc.wait_quiet()
        status = proc.screen_text().splitlines()[-1]
        assert "2:1" in status, f"wheel did not move one line: {status!r}"

        # A second tab, then click the first one in the tab bar.
        proc.send("\x14")
        proc.wait_quiet()
        proc.send("\x1b[<0;4;1M")
        proc.wait_quiet()
        status = proc.screen_text().splitlines()[-1]
        assert "notes.txt" in status, f"tab click did not switch: {status!r}"

        # Click a picker row once to select it, again to accept.
        proc.send("\x0f")
        assert proc.wait_for("Open file"), "picker did not open"
        proc.send("\x1b[<0;5;3M")
        proc.wait_quiet()
        proc.send("\x1b[<0;5;3M")
        assert proc.wait_for("alpha"), "picker click did not open the file"
        proc.shot("20-mouse-clicks")
    finally:
        proc.close()


@check
def mouse_click_toggles_the_help_hint(m, path):
    """Clicking the status-bar help hint opens the panel."""
    m.send("\x1b[<0;76;24M")  # the hint sits at the right edge of the last row
    assert m.wait_for("mibi controls"), "help hint click did not open the panel"
    m.shot("21-help-hint")


@check
def status_bar_fills_the_last_cell(m, path):
    """The bottom-right cell is painted, leaving no unpainted block."""
    m.wait_quiet()
    row = m.screen.rows - 1
    bg = m.screen.bg_at(row, m.screen.cols - 1)
    assert bg is not None, "bottom-right cell has no background"
    m.shot("22-status-edge")


@check
def cursor_line_has_a_tint(m, path):
    """The line holding the cursor is tinted; other lines keep the background."""
    work = os.path.join(SHOT_DIR, "work-tint")
    os.makedirs(work, exist_ok=True)
    with open(os.path.join(work, "mibi.ini"), "w", encoding="utf-8") as f:
        f.write("[editor]\ntheme = flexoki-dark\n")
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("one\ntwo\nthree")

    proc = Mibi(["notes.txt"], cwd=work)
    try:
        assert proc.wait_for("one"), "editor did not start"
        proc.wait_quiet()
        cursor_bg = proc.screen.bg_at(1, 40)  # cursor is on the first text line
        other_bg = proc.screen.bg_at(2, 40)
        assert cursor_bg is not None, "cursor line has no background"
        assert cursor_bg != other_bg, f"no line tint: {cursor_bg} vs {other_bg}"
        proc.shot("23-line-tint")
    finally:
        proc.close()


@check
def file_tree_lists_and_opens(m, path):
    """Ctrl+B opens the tree; Enter expands a directory and opens a file."""
    work = os.path.join(SHOT_DIR, "work-tree")
    os.makedirs(os.path.join(work, "sub"), exist_ok=True)
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("hello\nworld")
    with open(os.path.join(work, "sub", "inner.txt"), "w", encoding="utf-8") as f:
        f.write("inner body")

    proc = Mibi(["notes.txt"], cwd=work)
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.wait_quiet()
        proc.send("\x02")  # Ctrl+B
        proc.wait_quiet()
        text = proc.screen_text()
        assert " sub" in text, f"tree missing the directory entry: {text[:160]!r}"
        assert " notes.txt" in text, "tree missing the file entry"

        proc.send("\x1b[B")  # down past the ".." row to the sub directory
        proc.wait_quiet()
        proc.send("\r")
        proc.wait_quiet()
        assert "inner.txt" in proc.screen_text(), "directory did not expand"

        proc.send("\x1b[B")  # down to inner.txt
        proc.wait_quiet()
        proc.send("\r")
        assert proc.wait_for("inner body"), "tree did not open the file"
        proc.shot("24-tree")
    finally:
        proc.close()


@check
def regex_search_finds_patterns(m, path):
    """Ctrl+R in the find prompt turns on regex and \\d+ finds the digits."""
    work = os.path.join(SHOT_DIR, "work-regex")
    os.makedirs(work, exist_ok=True)
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("abc 123\ndef 456")

    proc = Mibi(["notes.txt"], cwd=work)
    try:
        assert proc.wait_for("abc"), "editor did not start"
        proc.wait_quiet()
        proc.send("\x06")  # Ctrl+F
        proc.send("\x12")  # Ctrl+R: regex on
        proc.send("\\d+")
        proc.wait_quiet()
        proc.send("\r")
        proc.wait_quiet()
        status = proc.screen_text().splitlines()[-1]
        assert "1:5" in status, f"regex find did not land on the digits: {status!r}"
        proc.shot("25-regex")
    finally:
        proc.close()


@check
def session_restores_tabs_and_unsaved_edits(m, path):
    """Quitting and restarting brings back the tabs, the unsaved text and the tree."""
    work = os.path.join(SHOT_DIR, "work-session")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(os.path.join(work, "sub"))
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("hello\nworld")
    with open(os.path.join(work, "sub", "inner.txt"), "w", encoding="utf-8") as f:
        f.write("inner")

    proc = Mibi(["notes.txt"], cwd=work)
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.wait_quiet()
        proc.send("\x02")  # open the tree
        proc.wait_quiet()
        proc.send("X")  # unsaved edit
        proc.wait_quiet()
        proc.send("\x11")  # quit
        proc.wait_quiet()
        proc.send("y")
        proc.wait_quiet()
    finally:
        proc.close()

    again = Mibi([], cwd=work, keep_session=True)
    try:
        assert again.wait_for("Xhello", timeout=5), "unsaved edit was not restored"
        again.wait_quiet()
        text = again.screen_text()
        assert "sub" in text, "file tree was not reopened"
        again.shot("26-session")
    finally:
        again.close()


@check
def unicode_and_wide_cells(m, path):
    """A CJK character takes two cells and does not break the layout."""
    m.send("\x1b[F")  # End of the current line
    m.send(" \u4e2d\u6587")
    screen = m.screen_text()
    assert_in(screen, "\u4e2d\u6587", "CJK text on screen")
    assert_in(screen, "mibi 0.0.1", "status bar still intact")
    m.shot("07-unicode")


@check
def resize_redraws(m, path):
    """Resizing the console re-renders at the new size."""
    m.resize(30, 100)
    assert m.wait_for("100x30", timeout=5), "status bar did not pick up the resize"
    m.shot("08-resized")
    m.resize(24, 80)
    assert m.wait_for("80x24", timeout=5)


@check
def save_writes_disk(m, path):
    """Ctrl+S writes the buffer to disk."""
    m.send("\x13")
    m.wait_quiet()
    time.sleep(0.2)
    with open(path, "r", encoding="utf-8") as f:
        data = f.read()
    assert "hello" in data, f"file not saved: {data!r}"
    assert "[+]" not in m.screen_text(), "still marked dirty after save"


@check
def quit_saves_nothing_and_exits(m, path):
    """A second Ctrl+Q after a dirty edit asks again; y exits."""
    m.send("!")
    m.wait_quiet()
    m.send("\x11")
    assert m.wait_for("quit without saving? (y/N)"), "no confirm prompt"
    m.send("y")
    deadline = time.time() + 5
    while time.time() < deadline and m.alive():
        time.sleep(0.05)
    assert not m.alive(), "editor did not exit on 'y'"


# --- main ------------------------------------------------------------------

def main():
    only = None
    if "-k" in sys.argv:
        only = sys.argv[sys.argv.index("-k") + 1]

    if not os.path.exists(MIBI):
        print(f"missing {MIBI}; run .\\build.ps1 first", file=sys.stderr)
        return 2

    os.makedirs(SHOT_DIR, exist_ok=True)
    tmpdir = os.path.join(SHOT_DIR, "work")
    os.makedirs(tmpdir, exist_ok=True)
    path = os.path.join(tmpdir, "notes.txt")

    selected = [c for c in CHECKS if only is None or only in c.__name__]
    # Each check gets a fresh editor so they cannot interfere. The editor runs
    # with the work directory as cwd and a short file name, so the status bar
    # fits in 80 columns.
    results = []
    for fn in selected:
        with open(path, "w", encoding="utf-8") as f:
            f.write("hello\nworld")
        with open(os.path.join(tmpdir, "other.txt"), "w", encoding="utf-8") as f:
            f.write("second file\n")
        with open(os.path.join(tmpdir, "sample.zig"), "w", encoding="utf-8") as f:
            f.write('const std = @import("std");\n\npub fn main() void {\n    const x = 1; // note\n}\n')
        m = Mibi(["notes.txt"], cwd=tmpdir)
        try:
            if not m.wait_for("hello"):
                raise AssertionError("startup timed out:\n" + m.screen_text())
            m.wait_quiet()
            fn(m, path)
            results.append((fn.__name__, True, ""))
            print(f"PASS {fn.__name__}")
        except AssertionError as e:
            results.append((fn.__name__, False, str(e)))
            print(f"FAIL {fn.__name__}\n{e}")
            try:
                m.shot("fail-" + fn.__name__)
            except Exception:
                pass
        except Exception as e:  # noqa: BLE001
            results.append((fn.__name__, False, repr(e)))
            print(f"ERROR {fn.__name__}: {e!r}")
        finally:
            m.close()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} screen checks passed")
    print(f"screenshots: {SHOT_DIR}")
    try:
        os.unlink(path)
    except OSError:
        pass
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
