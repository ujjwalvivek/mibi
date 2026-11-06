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
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIBI = os.path.join(ROOT, "zig-out", "bin", "mibi.exe")
SHOT_DIR = os.path.join(ROOT, "experiments", "out", "screens")
ROWS, COLS = 24, 80

# The status bar shows the version; read it from the manifest so a release
# does not break the tests.
import re as _re
VERSION = _re.search(r'\.version = "([^"]+)"', open(os.path.join(ROOT, "build.zig.zon"), encoding="utf-8").read()).group(1)


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
        self.bg = None
        # SGR 7 / 27 (and 0): a terminal with reverse video on draws the text
        # colour on the background colour and vice versa.
        self.reverse = False
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
        fg, bg = self.fg, self.bg
        if self.reverse:
            fg, bg = bg, fg  # what a real terminal shows for a reversed cell
        if self.c < self.cols:
            self.grid[self.r][self.c] = ch
            self.fg_grid[self.r][self.c] = fg
            self.bg_grid[self.r][self.c] = bg
        if w == 2 and self.c + 1 < self.cols:
            # The second half of a wide glyph is painted by the same cell.
            self.grid[self.r][self.c + 1] = ""
            self.fg_grid[self.r][self.c + 1] = fg
            self.bg_grid[self.r][self.c + 1] = bg
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
        """Track foreground, background and reverse video for the tests."""
        i = 0
        while i < len(nums):
            n = nums[i]
            if n == 0:
                self.fg = None
                self.bg = None
                self.reverse = False
            elif n == 7:
                self.reverse = True
            elif n == 27:
                self.reverse = False
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

STATE_ROOT = os.path.join(ROOT, "experiments", "out", "state")


class Mibi:
    def __init__(self, args, cwd=ROOT, rows=ROWS, cols=COLS, keep_session=False, state=None):
        # Session state lives outside the project (MIBI_STATE_DIR); each check
        # gets its own directory so nothing leaks between them.
        os.makedirs(STATE_ROOT, exist_ok=True)
        self.state = state or os.path.join(STATE_ROOT, "state-" + uuid.uuid4().hex[:8])
        if not keep_session:
            shutil.rmtree(self.state, ignore_errors=True)
        os.makedirs(self.state, exist_ok=True)
        os.environ["MIBI_STATE_DIR"] = self.state
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
        try:
            self.proc.write(keys)
        except EOFError:
            # The pty is gone: the editor exited underneath us. Report it with
            # the last screen instead of an opaque "Pty is closed" traceback.
            raise AssertionError("the editor exited while keys were sent:\n" + self.screen_text())
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
    assert_in(screen, f"mibi {VERSION}", "status bar")
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
def help_has_no_terminal_row(m, path):
    """The help panel no longer documents a terminal."""
    m.send("\x1bOP")  # F1
    assert m.wait_for("mibi controls"), "help panel did not open"
    m.wait_quiet()
    screen = m.screen_text()
    assert "terminal" not in screen.lower(), f"the help panel still mentions a terminal:\n{screen}"
    m.shot("61-help-no-terminal")


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
        # Column 0 is the block cursor, drawn with reverse video, so it reports
        # the swapped colours; the second character carries the plain text one.
        fg = proc.screen.fg_at(1, 1)
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
        # The first text cell is the block cursor (reverse video), so read the
        # second character for Dracula's plain #f8f8f2 text colour.
        fg = proc.screen.fg_at(1, 3)
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
        before = proc.screen.fg_at(2, 2)  # "world": clear of the block cursor
        proc.send("\x1bOQ")  # F2
        assert proc.wait_for("Theme"), "theme picker did not open"
        proc.send("\x1b[B")  # down
        proc.send("\x1b[B")
        proc.send("\r")  # accept
        proc.wait_quiet()
        after = proc.screen.fg_at(2, 2)
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
        # The first text cell is the block cursor (reverse video), so read the
        # second character for the saved theme's plain text colour.
        fg = again.screen.fg_at(1, 3)
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
def command_palette_has_no_terminal_actions(m, path):
    """The command palette no longer offers any terminal action."""
    m.send("\x10")  # Ctrl+P
    assert m.wait_for("Commands"), "command palette did not open"
    m.wait_quiet()
    screen = m.screen_text()
    assert "terminal" not in screen.lower(), f"the palette still lists a terminal action:\n{screen}"
    # Filtering for it must not bring one back either.
    m.send("term")
    m.wait_quiet()
    filtered = m.screen_text()
    assert "Commands" in filtered, f"typing closed the palette:\n{filtered}"
    assert "terminal" not in filtered.lower(), f"a terminal action survived the filter:\n{filtered}"
    m.shot("62-palette-no-terminal")


@check
def mouse_click_places_the_cursor(m, path):
    """A left click on a text row moves the cursor to that cell."""
    m.send("\x1b[<0;5;3M")  # click: screen row 3 (second text line), column 5
    m.wait_quiet()
    status = m.screen_text().splitlines()[-1]
    assert "2:3" in status, f"click did not move the cursor: {status!r}"
    m.shot("19-mouse")


@check
def f8_does_nothing(m, path):
    """F8 is gone: it must not open a panel, a shell or a status-bar pill."""
    m.wait_quiet()
    before = m.screen_text()
    m.send("\x1b[19~")  # F8
    m.wait_quiet(settle=0.4)
    time.sleep(0.3)
    after = m.screen_text()
    assert m.alive(), "the editor died on F8"
    assert "cmd.exe" not in after.lower(), f"F8 started a shell:\n{after}"
    assert "cmd.exe" not in m.screen.title.lower(), f"F8 set a shell title: {m.screen.title!r}"
    assert ">_" not in after, f"an F8 terminal pill is still on the status bar: {after.splitlines()[-1]!r}"
    assert after == before, (
        "F8 changed the screen:\n--- before ---\n" + before + "\n--- after ---\n" + after)
    m.shot("60-f8-nothing")


@check
def drag_selects_text(m, path):
    """Pressing and dragging over text selects it, and typing replaces it."""
    work = os.path.join(SHOT_DIR, "work-drag")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "drag.txt"), "w", encoding="utf-8") as f:
        f.write("alpha beta gamma\nsecond line\n")
    proc = Mibi(["drag.txt"], cwd=work)
    try:
        assert proc.wait_for("alpha beta gamma"), "editor did not start"
        proc.wait_quiet()
        # "beta" starts at column 6 (screen column 9); drag to the end of the
        # line (offset 16, screen column 19) and type over the selection.
        proc.proc.write("\x1b[<0;9;2M")
        proc.wait_quiet()
        proc.proc.write("\x1b[<32;19;2M")
        proc.wait_quiet()
        proc.proc.write("\x1b[<0;19;2m")
        proc.wait_quiet()
        proc.send("Z")
        proc.wait_quiet()
        screen = proc.screen_text()
        assert "alpha Z" in screen, f"drag select did not replace the range:\n{screen}"
        assert "second line" in screen, f"drag select ate the next line:\n{screen}"
        proc.shot("42-drag-select")
    finally:
        proc.close()


@check
def global_keys_work_with_the_tree_focused(m, path):
    """F-keys still reach the editor while the file tree has the focus."""
    work = os.path.join(SHOT_DIR, "work-tree-keys")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("hello\nworld\n")
    proc = Mibi(["notes.txt"], cwd=work)
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.wait_quiet()
        proc.send("\x02")  # Ctrl+B: the tree takes the keyboard
        proc.wait_quiet()
        assert "notes.txt" in proc.screen_text(), "the tree did not open"
        # F9 and F1 are global actions: they must work even though the tree owns
        # the keyboard.
        proc.send("\x1b[20~")  # F9: reload an unchanged file
        assert proc.wait_for("up to date"), "F9 was swallowed by the tree:\n" + proc.screen_text()
        proc.send("\x1bOP")  # F1
        assert proc.wait_for("mibi controls"), "F1 was swallowed by the tree:\n" + proc.screen_text()
        proc.shot("45-tree-keys")
    finally:
        proc.close()


@check
def selection_stays_on_its_line(m, path):
    """A selection on one line does not paint the start of the next one."""
    work = os.path.join(SHOT_DIR, "work-sel-line")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "two.txt"), "w", encoding="utf-8") as f:
        f.write("alpha beta gamma\nsecond line here\n")
    proc = Mibi(["two.txt"], cwd=work)
    try:
        assert proc.wait_for("alpha beta gamma"), "editor did not start"
        proc.wait_quiet()
        # Double click on "second" in the SECOND line (screen row 3, column 4).
        proc.proc.write("\x1b[<0;4;3M\x1b[<0;4;3m" * 2)
        proc.wait_quiet()
        selected = proc.screen.bg_at(2, 4)
        assert selected is not None, "no selection painted on the clicked line"
        first_row = [proc.screen.bg_at(1, c) for c in range(0, 40)]
        assert selected not in first_row, f"the selection bled onto the previous line: {first_row}"
        proc.shot("46-selection-line")
    finally:
        proc.close()


@check
def focus_returns_to_the_editor(m, path):
    """Clicking the tree and then the text hands the keyboard back to the editor."""
    work = os.path.join(SHOT_DIR, "work-focus")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "one.txt"), "w", encoding="utf-8") as f:
        f.write("alpha\nbeta\ngamma\n")
    proc = Mibi(["one.txt"], cwd=work)
    try:
        assert proc.wait_for("alpha"), "editor did not start"
        proc.wait_quiet()
        proc.send("\x02")  # Ctrl+B: tree takes the keyboard
        proc.wait_quiet()
        proc.send("\x1b[<0;3;3M")  # click a tree row
        proc.send("\x1b[<0;3;3m")
        proc.wait_quiet()
        proc.send("\x1b[<0;30;2M")  # click the text area
        proc.send("\x1b[<0;30;2m")
        proc.wait_quiet()
        proc.send("\x1b[B")  # down arrow must move the editor cursor
        proc.wait_quiet()
        status = proc.screen_text().splitlines()[-1]
        assert "2:" in status, f"arrow keys still go to the tree: {status!r}"
        proc.shot("47-focus")
    finally:
        proc.close()


@check
def conflicted_file_is_flagged_and_reloads(m, path):
    """A file changed under unsaved edits is flagged, and F9 takes the disk copy."""
    work = os.path.join(SHOT_DIR, "work-conflict")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    target = os.path.join(work, "conf.txt")
    with open(target, "w", encoding="utf-8") as f:
        f.write("alpha\n")
    proc = Mibi(["conf.txt"], cwd=work)
    try:
        assert proc.wait_for("alpha"), "editor did not start"
        proc.wait_quiet()
        proc.send("X")  # unsaved edit
        proc.wait_quiet()
        with open(target, "w", encoding="utf-8") as f:
            f.write("beta\n")  # the file moves on underneath
        deadline = time.time() + 5
        while time.time() < deadline and "[!]" not in proc.screen_text():
            time.sleep(0.1)
        screen = proc.screen_text()
        assert "[!]" in screen, f"no conflict marker on the tab:\n{screen}"

        proc.send("\x1b[20~")  # F9: first press only warns
        proc.wait_quiet()
        assert "unsaved edits" in proc.screen_text(), "F9 did not warn before discarding edits"

        proc.send("\x1b[20~")  # F9 again: take the disk copy
        assert proc.wait_for("beta"), "F9 did not reload the file:\n" + proc.screen_text()
        assert "[!]" not in proc.screen_text(), "the conflict marker survived the reload"
        proc.shot("48-conflict")
    finally:
        proc.close()


@check
def shift_wheel_scrolls_sideways(m, path):
    """Shift + wheel scrolls the editor horizontally."""
    work = os.path.join(SHOT_DIR, "work-hscroll")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "wide.txt"), "w", encoding="utf-8") as f:
        f.write("start-" + "x" * 200 + "-end\n")
    proc = Mibi(["wide.txt"], cwd=work)
    try:
        assert proc.wait_for("start-"), "editor did not start"
        proc.wait_quiet()
        assert "start-" in proc.screen_text()
        for _ in range(3):
            proc.proc.write("\x1b[<69;20;3M")  # shift + wheel down
        proc.wait_quiet()
        screen = proc.screen_text()
        assert "start-" not in screen, f"the view did not scroll sideways:\n{screen}"
        assert "xxx" in screen, f"the line scrolled out entirely:\n{screen}"
        proc.shot("50-hscroll")
    finally:
        proc.close()


@check
def status_message_survives_mouse_motion(m, path):
    """Moving the pointer must not wipe a status message."""
    work = os.path.join(SHOT_DIR, "work-msg")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "msg.txt"), "w", encoding="utf-8") as f:
        f.write("hello\nworld\n")
    proc = Mibi(["msg.txt"], cwd=work)
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.wait_quiet()
        proc.send("\x1b[20~")  # F9: reload, which reports "already up to date"
        proc.wait_quiet()
        assert "up to date" in proc.screen_text(), "no message to test with"
        for _ in range(6):
            proc.proc.write("\x1b[<35;10;5M")  # pointer motion, no buttons
        proc.wait_quiet()
        assert "up to date" in proc.screen_text(), "a mouse move cleared the message"
    finally:
        proc.close()


@check
def status_message_expires(m, path):
    """A status message ages out after a few seconds without input."""
    m.send("\x1b[20~")  # F9 on an unchanged file reports "already up to date"
    assert m.wait_for("up to date"), "no status message to test with:\n" + m.screen_text()
    # No input from here on: the idle tick has to clear it by itself.
    deadline = time.time() + 8
    while time.time() < deadline and "up to date" in m.screen_text():
        time.sleep(0.2)
    screen = m.screen_text()
    assert "up to date" not in screen, f"the status message never expired:\n{screen}"
    assert m.alive(), "the editor died while the message expired"
    status = screen.splitlines()[-1]
    assert "mibi" in status, f"the status bar was damaged: {status!r}"
    m.shot("64-message-expired")


@check
def status_message_expires_while_the_mouse_moves(m, path):
    """The cleared message must be repainted even when only mouse motion comes."""
    m.send("\x1b[20~")  # F9 on an unchanged file reports "already up to date"
    assert m.wait_for("up to date"), "no status message to test with:\n" + m.screen_text()
    deadline = time.time() + 8
    while time.time() < deadline and "up to date" in m.screen_text():
        m.proc.write("\x1b[<35;10;5M")  # pointer motion, no buttons
        time.sleep(0.5)
    screen = m.screen_text()
    assert "up to date" not in screen, (
        "the message expired internally but the screen was never repainted:\n" + screen)
    assert m.alive(), "the editor died while the message expired"
    m.shot("66-message-expired-mouse")


@check
def double_and_triple_click_select(m, path):
    """Double click selects a word, triple click selects the whole line."""
    work = os.path.join(SHOT_DIR, "work-clicks")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "words.txt"), "w", encoding="utf-8") as f:
        f.write("alpha beta gamma\nsecond line\n")
    proc = Mibi(["words.txt"], cwd=work)
    try:
        assert proc.wait_for("alpha beta gamma"), "editor did not start"
        proc.wait_quiet()
        # "beta" starts at column 6; the gutter is 2 cells, so screen column 9
        # of the first text row (screen row 2) lands inside the word. The clicks
        # go out as one write: send() settles between keystrokes, which is far
        # slower than a double click.
        proc.proc.write("\x1b[<0;9;2M\x1b[<0;9;2m" * 2)
        proc.wait_quiet()
        proc.send("X")
        proc.wait_quiet()
        screen = proc.screen_text()
        assert "alpha X gamma" in screen, f"double click did not select the word:\n{screen}"

        proc.send("\x1a")  # undo the replacement
        proc.wait_quiet()
        # Three clicks in one burst: the whole line gets selected.
        proc.proc.write("\x1b[<0;9;2M\x1b[<0;9;2m" * 3)
        proc.wait_quiet()
        proc.send("Y")
        proc.wait_quiet()
        screen = proc.screen_text()
        assert "alpha beta gamma" not in screen, f"triple click did not select the line:\n{screen}"
        assert "Y" in screen and "second line" in screen, f"triple click lost the next line:\n{screen}"
        proc.shot("19b-double-click")
    finally:
        proc.close()


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


def _unpainted_cells(screen):
    """Every (row, col) whose background is still the terminal's own."""
    return [(r, c) for r in range(screen.rows) for c in range(screen.cols)
            if screen.bg_at(r, c) is None]


def _assert_fully_painted(proc, what):
    """Fail unless every cell of the frame has a background of its own.

    An unpainted cell shows the terminal's own background, which is the
    "unpainted block" the screen checks exist to catch.
    """
    # Let the first full frame (and any repaint after opening the tree) land.
    proc.wait_quiet()
    time.sleep(0.2)
    proc.wait_quiet()
    screen = proc.screen
    for label, row in (("tab bar", 0), ("status bar", screen.rows - 1)):
        gaps = [c for c in range(screen.cols) if screen.bg_at(row, c) is None]
        if gaps:
            raise AssertionError(
                f"{what}: the {label} has {len(gaps)} unpainted cells (columns {gaps[:8]})")
    missing = _unpainted_cells(screen)
    if missing:
        raise AssertionError(
            f"{what}: {len(missing)} of {screen.rows * screen.cols} cells have no background "
            f"(first: {missing[:8]}) - the terminal's own background shows through")


@check
def chrome_is_fully_painted(m, path):
    """No window size leaves a cell unpainted: the whole frame gets a colour."""
    work = os.path.join(SHOT_DIR, "work-chrome")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("hello\nworld\n")

    for rows, cols in ((20, 40), (24, 80), (30, 120)):
        for tree in (False, True):
            what = f"{cols}x{rows}" + (" with tree" if tree else "")
            proc = Mibi(["notes.txt"], cwd=work, rows=rows, cols=cols)
            try:
                assert proc.wait_for("hello"), f"{what}: editor did not start"
                proc.wait_quiet()
                if tree:
                    proc.send("\x02")  # Ctrl+B: the file tree takes a column
                    proc.wait_quiet()
                    assert "notes.txt" in proc.screen_text(), f"{what}: the tree did not open"
                _assert_fully_painted(proc, what)
                proc.shot("63-chrome-" + what.replace(" ", "-"))
            finally:
                proc.close()


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
        proc.send("j")  # select the "sub" folder (folders sort first)
        proc.wait_quiet()
        proc.send("\r")  # expand it
        proc.wait_quiet()
        proc.send("X")  # unsaved edit
        proc.wait_quiet()
        proc.send("\x11")  # quit
        proc.wait_quiet()
        proc.send("y")
        proc.wait_quiet()
    finally:
        proc.close()

    again = Mibi([], cwd=work, keep_session=True, state=proc.state)
    try:
        assert again.wait_for("Xhello", timeout=5), "unsaved edit was not restored"
        again.wait_quiet()
        text = again.screen_text()
        assert "sub" in text, "file tree was not reopened"
        # The folder that was open is still open, and its file is listed.
        assert "inner.txt" in text, f"the tree forgot its open folders:\n{text}"
        again.shot("26-session")
    finally:
        again.close()


@check
def split_layout_persists(m, path):
    """The split layout and both documents come back after a restart."""
    work = os.path.join(SHOT_DIR, "work-split-session")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("hello\nworld")

    proc = Mibi(["notes.txt"], cwd=work)
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.wait_quiet()
        proc.send("\x1b[15~")  # F5: split
        proc.wait_quiet()
        proc.send("scratch")  # typed into the new pane
        proc.wait_quiet()
        proc.send("\x11")  # quit
        proc.wait_quiet()
        proc.send("y")
        proc.wait_quiet()
    finally:
        proc.close()

    again = Mibi([], cwd=work, keep_session=True, state=proc.state)
    try:
        assert again.wait_for("hello", timeout=5), "the document was not restored"
        again.wait_quiet()
        screen = again.screen_text()
        assert "\u2502" in screen, f"the split was not restored:\n{screen}"
        assert "scratch" in screen, f"the second pane's text was not restored:\n{screen}"
        again.shot("33-split-session")
    finally:
        again.close()


@check
def dragging_a_tab_reorders_it(m, path):
    """Press on a tab, drag to the other one, release: the tabs swap."""
    m.send("\x14")  # second tab
    m.wait_quiet()
    before = m.screen_text().splitlines()[0]
    assert "notes.txt" in before and "No Name" in before, f"unexpected tabs: {before!r}"
    # Press on the first tab, drag right over the second, release.
    m.send("\x1b[<0;3;1M")
    m.send("\x1b[<32;20;1M")
    m.send("\x1b[<0;20;1m")
    m.wait_quiet()
    after = m.screen_text().splitlines()[0]
    assert "No Name" in after, f"tab did not move: {after!r}"
    assert after.index("No Name") < after.index("notes.txt"), f"tabs not swapped: {after!r}"
    m.shot("27-tab-drag")


@check
def tabs_show_names_and_reveal_paths(m, path):
    """Tabs show the file name; hover and drag reveal the path."""
    work = os.path.join(SHOT_DIR, "work-tabnames")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(os.path.join(work, "src"))
    with open(os.path.join(work, "src", "main.zig"), "w", encoding="utf-8") as f:
        f.write("const a = 1;\n")
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("hello\n")

    proc = Mibi(["src/main.zig"], cwd=work)
    try:
        assert proc.wait_for("const"), "editor did not start"
        proc.wait_quiet()
        bar = proc.screen_text().splitlines()[0]
        assert "main.zig" in bar and "src/main.zig" not in bar, f"tab shows a path: {bar!r}"

        proc.send("\x14")  # second tab
        proc.wait_quiet()
        proc.send("\x1b[<35;2;1M")  # hover the first tab
        proc.wait_quiet()
        status = proc.screen_text().splitlines()[-1]
        assert "main.zig" in status, f"hover did not reveal the name: {status!r}"

        proc.send("\x1b[<0;3;1M")  # press the first tab
        proc.wait_quiet()
        proc.send("\x1b[<32;20;1M")  # drag it right
        proc.wait_quiet()
        mid = proc.screen_text().splitlines()[0]
        assert "main.zig" in mid, f"drag chip missing the name: {mid!r}"
        proc.send("\x1b[<0;20;1m")  # release
        proc.wait_quiet()
        proc.shot("28-tabs")
    finally:
        proc.close()


@check
def markdown_gets_highlighting(m, path):
    """Markdown headings, list markers and inline code are coloured."""
    work = os.path.join(SHOT_DIR, "work-md")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "notes.md"), "w", encoding="utf-8") as f:
        f.write("# Heading\n- item\n`code` here\n")

    proc = Mibi(["notes.md"], cwd=work)
    try:
        assert proc.wait_for("Heading"), "editor did not start"
        proc.wait_quiet()
        heading_fg = proc.screen.fg_at(1, 2)  # 'H' after "# "
        item_fg = proc.screen.fg_at(2, 0)  # the list marker
        code_fg = proc.screen.fg_at(3, 1)  # inside the backticks
        assert heading_fg != item_fg, f"heading and list share a colour: {heading_fg}"
        assert code_fg != item_fg, f"inline code and list share a colour: {code_fg}"
        proc.shot("29-markdown")
    finally:
        proc.close()


@check
def tab_bar_has_new_and_close_buttons(m, path):
    """The tab bar's + opens a tab, each tab's x closes it, hover lights them."""
    m.wait_quiet()
    bar = m.screen_text().splitlines()[0]
    assert "+" in bar and " x" in bar, f"no tab buttons: {bar!r}"
    # The close button keeps a cell of padding before the tab's edge.
    assert "x " in bar, f"no padding after the close button: {bar!r}"

    plus = bar.index("+") + 1
    plain = m.screen.bg_at(0, plus - 1)
    m.send(f"\x1b[<35;{plus};1M")  # hover the +
    m.wait_quiet()
    assert m.screen.bg_at(0, plus - 1) != plain, "hovering the + did not highlight it"

    m.send(f"\x1b[<0;{plus};1M")
    m.wait_quiet()
    bar = m.screen_text().splitlines()[0]
    assert "No Name" in bar, f"the + did not open a tab: {bar!r}"

    close = bar.rindex("x") + 1
    plain = m.screen.bg_at(0, close - 1)
    m.send(f"\x1b[<35;{close};1M")  # hover the x
    m.wait_quiet()
    assert m.screen.bg_at(0, close - 1) != plain, "hovering the x did not highlight it"

    m.send(f"\x1b[<0;{close};1M")
    m.wait_quiet()
    bar = m.screen_text().splitlines()[0]
    assert "No Name" not in bar, f"the x did not close the tab: {bar!r}"
    m.shot("30-tab-buttons")


@check
def tab_strip_scrolls_when_it_overflows(m, path):
    """Too many tabs: arrows appear at both ends and the wheel scrolls them."""
    m.wait_quiet()
    for _ in range(6):
        m.send("\x14")  # Ctrl+T
    m.wait_quiet()
    bar = m.screen_text().splitlines()[0]
    assert "\u2039" in bar and "\u203a" in bar, f"no scroll arrows: {bar!r}"
    assert bar.startswith("\u2039"), f"the left arrow is not at the left edge: {bar!r}"
    assert bar.rstrip().endswith("+"), f"the + is not pinned right: {bar!r}"
    assert "[No Name]" in bar, f"the active tab is not visible: {bar!r}"
    # The strip starts at its end (the active tab is the last one), so the
    # right arrow is dim and the first tab is scrolled out of sight.
    assert "notes.txt" not in bar, f"the strip did not follow the active tab: {bar!r}"
    next_col = bar.index("\u203a")
    dim = m.screen.fg_at(0, next_col)

    m.send("\x1b[<64;20;1M")  # wheel up over the tab bar
    m.wait_quiet()
    bar = m.screen_text().splitlines()[0]
    assert m.screen.fg_at(0, next_col) != dim, f"the wheel did not scroll the strip: {bar!r}"

    for _ in range(8):
        m.send("\x1b[<64;20;1M")
    m.wait_quiet()
    first = m.screen_text().splitlines()[0]
    assert "notes.txt" in first, f"the strip did not scroll back to the start: {first!r}"
    m.shot("31-tab-scroll")


@check
def splitting_creates_two_panes(m, path):
    """F5 splits into two views of the same file."""
    m.send("\x1b[15~")  # F5
    m.wait_quiet()
    lines = m.screen_text().splitlines()
    seps = {row.index("\u2502") for row in lines if "\u2502" in row}
    assert seps, f"no pane separator:\n" + "\n".join(lines)
    sep = seps.pop()
    left = "\n".join(row[:sep] for row in lines[1:-1])
    right = "\n".join(row[sep + 1:] for row in lines[1:-1])
    assert "hello" in left and "hello" in right, f"both panes should show the file:\n{left!r}\n---\n{right!r}"

    # The panes are two views of one buffer: an edit shows in both.
    m.send("X")
    m.wait_quiet()
    lines = m.screen_text().splitlines()
    left = "\n".join(row[:sep] for row in lines[1:-1])
    right = "\n".join(row[sep + 1:] for row in lines[1:-1])
    assert "Xhello" in left and "Xhello" in right, f"the views are not the same buffer:\n{left!r}\n---\n{right!r}"
    m.shot("32-split")


@check
def esc_closes_the_help_panel(m, path):
    """Esc dismisses the help panel."""
    m.send("\x1f")  # Ctrl+?
    m.wait_quiet()
    assert "mibi controls" in m.screen_text(), "the help panel did not open"
    m.send("\x1b")  # Esc
    m.wait_quiet()
    assert "mibi controls" not in m.screen_text(), "Esc did not close the help panel"


@check
def dragging_a_tab_onto_a_pane_splits_it(m, path):
    """Drag a tab onto the right third of a pane: it lands there as a split."""
    m.send("\x1b[15~")  # F5: two panes
    m.wait_quiet()
    plain_bg = m.screen.bg_at(5, 65)
    m.send("\x1b[<0;3;1M")  # press the notes.txt tab
    m.send("\x1b[<32;72;12M")  # drag it over the right pane's right third
    m.wait_quiet()
    hint = m.screen_text()
    assert "\u250c" not in hint, f"the drop hint should be a tint, not a box:\n{hint}"
    assert m.screen.bg_at(5, 65) != plain_bg, "the drop hint did not tint the area"
    m.shot("34-drop-hint")
    m.send("\x1b[<0;72;12m")  # release
    m.wait_quiet()
    screen = m.screen_text()
    lines = screen.splitlines()
    seps = {row.index("\u2502") for row in lines if "\u2502" in row}
    assert seps, f"the drop did not split the window:\n{screen}"
    sep = seps.pop()
    right = "\n".join(row[sep + 1:] for row in lines[1:-1])
    assert "hello" in right, f"the dropped tab is not in the right pane:\n{right!r}"
    m.shot("35-drag-split")


@check
def dragging_a_tab_down_splits_the_pane(m, path):
    """Press a tab and drag straight down: the drag promotes and the pane splits."""
    m.wait_quiet()
    m.send("\x1b[<0;3;1M")  # press the tab
    m.send("\x1b[<32;3;12M")  # straight down into the text area
    m.wait_quiet()
    hint = m.screen_text()
    assert "\u250c" not in hint, f"the drop hint should be a tint, not a box:\n{hint}"
    m.send("\x1b[<0;3;12m")  # release
    m.wait_quiet()
    screen = m.screen_text()
    assert "\u2502" in screen, f"the vertical drag did not split the pane:\n{screen}"
    m.shot("36-drag-down")


@check
def the_tree_follows_the_disk(m, path):
    """A file created while the editor sits idle shows up in the tree."""
    work = os.path.join(SHOT_DIR, "work-hot")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    with open(os.path.join(work, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("hello")
    proc = Mibi(["notes.txt"], cwd=work)
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.wait_quiet()
        proc.send("\x02")  # open the tree
        proc.wait_quiet()
        assert "fresh.txt" not in proc.screen_text()

        with open(os.path.join(work, "fresh.txt"), "w", encoding="utf-8") as f:
            f.write("new")
        # No keystrokes: the idle tick has to notice by itself.
        deadline = time.time() + 5
        while time.time() < deadline and "fresh.txt" not in proc.screen_text():
            time.sleep(0.1)
        assert "fresh.txt" in proc.screen_text(), "the tree did not pick up a new file"
        proc.shot("38-hot-tree")
    finally:
        proc.close()


@check
def open_file_follows_the_disk(m, path):
    """A file rewritten on disk while the editor sits idle is reloaded."""
    work = os.path.join(SHOT_DIR, "work-hot-file")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    target = os.path.join(work, "live.txt")
    with open(target, "w", encoding="utf-8") as f:
        f.write("first version\n")
    proc = Mibi(["live.txt"], cwd=work)
    try:
        assert proc.wait_for("first version"), "editor did not start"
        proc.wait_quiet()
        with open(target, "w", encoding="utf-8") as f:
            f.write("second version\n")
        # No keystrokes: the idle tick has to notice by itself.
        deadline = time.time() + 5
        while time.time() < deadline and "second version" not in proc.screen_text():
            time.sleep(0.1)
        screen = proc.screen_text()
        assert "second version" in screen, f"the buffer did not reload from disk:\n{screen}"
        assert "reloaded live.txt" in screen, f"no reload notice in the status line:\n{screen}"
        proc.shot("39-hot-file")
    finally:
        proc.close()


@check
def formatting_without_a_tool_reports_it(m, path):
    """F4 with no formatter configured says so instead of doing nothing."""
    m.send("\x1bOS")  # F4 (SS3 form)
    m.wait_quiet()
    status = m.screen_text().splitlines()[-1]
    assert "formatter" in status.lower(), f"no message for a missing formatter: {status!r}"


@check
def unicode_and_wide_cells(m, path):
    """A CJK character takes two cells and does not break the layout."""
    m.send("\x1b[F")  # End of the current line
    m.send(" \u4e2d\u6587")
    screen = m.screen_text()
    assert_in(screen, "\u4e2d\u6587", "CJK text on screen")
    assert_in(screen, f"mibi {VERSION}", "status bar still intact")
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
def editor_survives_stress(m, path):
    """Typing, splitting, resizing, reloading and saving keep the editor alive."""
    work = os.path.join(SHOT_DIR, "work-stress")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    target = os.path.join(work, "notes.txt")
    with open(target, "w", encoding="utf-8") as f:
        f.write("hello\nworld\n")
    typed = ("0123456789abcdef" * 10)[:150]

    proc = Mibi(["notes.txt"], cwd=work)
    try:
        assert proc.wait_for("hello"), "editor did not start"
        proc.wait_quiet()
        # Type in bursts, the way a fast keyboard (or a paste) delivers bytes.
        for i in range(0, len(typed), 30):
            proc.proc.write(typed[i:i + 30])
            time.sleep(0.05)
        proc.wait_quiet()
        assert proc.alive(), "the editor died while typing"
        assert "[+]" in proc.screen_text(), "the typed text did not dirty the buffer"

        proc.send("\x1b[15~")  # F5: split into two panes
        proc.wait_quiet()
        assert "\u2502" in proc.screen_text(), "F5 did not split the panes"

        proc.resize(30, 100)  # a bigger window, then back to the original size
        assert proc.wait_for("100x30", timeout=5), "the resize was not applied"
        proc.resize(24, 80)
        assert proc.wait_for("80x24", timeout=5), "the second resize was not applied"

        proc.send("\x1b[20~")  # F9 on a dirty buffer only warns
        proc.wait_quiet()
        assert "unsaved edits" in proc.screen_text(), "F9 did not warn about the unsaved text"

        proc.send("\x13")  # Ctrl+S: save the typed text
        proc.wait_quiet()
        time.sleep(0.3)
        assert "[+]" not in proc.screen_text(), "the buffer stayed dirty after Ctrl+S"

        proc.send("\x1b[15;2~")  # Shift+F5: close the split pane
        proc.wait_quiet()
        assert proc.alive(), "the editor died closing the pane"
        # The 155-column first line scrolled the view right, which hides short
        # lines; go home to see the untouched second line again.
        proc.send("\x1b[H")  # Home
        proc.wait_quiet()
        screen = proc.screen_text()
        assert "world" in screen, f"the second line is gone:\n{screen}"
        proc.send("\x1b[F")  # End: the tail of the first line is back in view
        proc.wait_quiet()
        screen = proc.screen_text()
        assert "hello" in screen, f"the first line lost its text:\n{screen}"
        status = screen.splitlines()[-1]
        assert "mibi" in status, f"the status bar is gone: {status!r}"
        proc.shot("65-stress")
    finally:
        proc.close()

    with open(target, encoding="utf-8") as f:
        saved = f.read()
    assert typed in saved, f"the typed text was not saved ({len(saved)} bytes on disk)"
    assert "hello" in saved and "world" in saved, f"the file lost its original text: {saved!r}"


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
            # The first frame can take a while on a busy machine (ConPTY spawn
            # plus a cold start), and every check needs it, so wait generously
            # instead of failing the check on a slow spawn.
            if not m.wait_for("hello", timeout=15):
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
    _clean_root_session()
    print(f"screenshots: {SHOT_DIR}")
    try:
        os.unlink(path)
    except OSError:
        pass
    return 1 if failed else 0


def _clean_root_session():
    """The checks run with cwd=ROOT, so remove the session they leave behind."""
    for name in os.listdir(ROOT):
        if name.startswith("mibi-session"):
            try:
                os.remove(os.path.join(ROOT, name))
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
