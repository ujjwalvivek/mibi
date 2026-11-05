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
        self.r = self.c = 0
        self._pending = ""

    def clear(self):
        self.grid = [[" "] * self.cols for _ in range(self.rows)]
        self.r = self.c = 0

    def _put(self, ch):
        w = cell_width(ch)
        if self.r >= self.rows:
            return
        if self.c < self.cols:
            self.grid[self.r][self.c] = ch
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
                    return j + 1 - i
                if data[j] == "\x1b" and j + 1 < len(data) and data[j + 1] == "\\":
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
    def __init__(self, args, cwd=ROOT, rows=ROWS, cols=COLS):
        from winpty import PtyProcess
        self.screen = Screen(rows, cols)
        self._lock = threading.Lock()
        self._eof = False
        self.proc = PtyProcess.spawn([MIBI] + args, dimensions=(rows, cols),
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
    """Opening a file shows the gutter, the text and the status bar."""
    assert m.wait_for("hello"), "no text after startup"
    screen = m.screen_text()
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
    assert_in(screen, "Ctrl+Q                 quit (asks if unsaved)")
    assert_in(screen, "Ctrl+F                 find")
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
