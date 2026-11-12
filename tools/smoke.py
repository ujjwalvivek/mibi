#!/usr/bin/env python3
"""Real-terminal smoke test for Linux and macOS.

The unit tests drive the editor in process, without a terminal. This runs the
built binary in a pseudo-terminal and checks the part they cannot reach: raw
mode, the run loop, input decoding from real bytes, resize, saving, and that
the terminal is put back on the way out.

    python3 tools/smoke.py zig-out/bin/mibi
"""

import fcntl
import os
import pty
import select
import signal
import struct
import sys
import tempfile
import termios
import time


def main() -> int:
    exe = os.path.abspath(sys.argv[1])
    work = tempfile.mkdtemp(prefix="mibi-smoke-")
    state = os.path.join(work, "state")
    os.mkdir(state)
    path = os.path.join(work, "note.txt")
    with open(path, "w") as f:
        f.write("first\nsecond\n")

    pid, fd = pty.fork()
    if pid == 0:
        # The size is set before the editor starts: a resize sent while it
        # is still starting would arrive before it listens for one.
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        os.chdir(work)
        os.environ["MIBI_STATE_DIR"] = state
        os.environ["TERM"] = "xterm-256color"
        os.execv(exe, [exe, "note.txt"])

    out = bytearray()

    def pump(seconds: float) -> None:
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    out.extend(os.read(fd, 65536))
                except OSError:
                    return

    def send(data: bytes, wait: float = 0.3) -> None:
        os.write(fd, data)
        pump(wait)

    def resize(rows: int, cols: int) -> None:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.kill(pid, signal.SIGWINCH)
        pump(0.3)

    failures = []

    def check(what: str, ok: bool) -> None:
        print(("ok    " if ok else "FAIL  ") + what)
        if not ok:
            failures.append(what)

    pump(0.8)
    check("enters the alternate screen", b"\x1b[?1049h" in out)
    check("asks for mouse reports and bracketed paste", b"\x1b[?1006h" in out and b"\x1b[?2004h" in out)
    # The first letter is under the cursor, so it is styled apart from the rest.
    check("draws the file", b"irst" in out and b"second" in out)

    send(b"\x1b[F")  # End, as a real escape sequence
    send(b"!")
    send(b"\x1b[200~ pasted\x1b[201~")  # bracketed paste
    del out[:]
    resize(30, 100)
    check("repaints after a resize", b"first! pasted" in out)
    send(b"\x1b")  # a lone Escape must not swallow what follows
    send(b"\x13")  # ctrl+s
    with open(path) as f:
        saved = f.read()
    check("saves what was typed and pasted", saved == "first! pasted\nsecond\n")

    send(b"\x14")  # ctrl+t: a new tab
    send(b"kept for next time")
    del out[:]
    send(b"\x11", 0.6)  # ctrl+q
    done, status = os.waitpid(pid, os.WNOHANG)
    if not done:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    check("quits on ctrl+q", done == pid)
    check("exits cleanly", done == pid and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0)
    check("leaves the alternate screen and turns reports off", b"\x1b[?1049l" in out and b"\x1b[?1006l" in out)
    session = os.path.join(state, "session")
    check("writes the session", os.path.exists(session))
    buffers = [n for n in os.listdir(state) if n.startswith("buffer-")]
    kept = any(open(os.path.join(state, n)).read() == "kept for next time" for n in buffers)
    check("keeps the unsaved tab for the next start", kept)

    print("smoke test:", "FAILED" if failures else "ok")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
