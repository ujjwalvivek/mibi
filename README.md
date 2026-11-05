# mibi

A tiny, modern terminal text editor. Non-modal, in the spirit of nano/micro,
built in Zig with no third-party dependencies.

Status: **Phase 3 in progress** - Phase 2 (open, edit, select, copy, undo,
save) is complete and hardened, plus the Unicode width table,
find/replace/go-to-line, a help panel, multiple documents in tabs and data-driven
syntax highlighting.
Cross-platform (Linux, macOS, Windows).

```
mibi                # new buffer
mibi <file>         # open a file (a missing file opens empty and saves there)
```

## Build

Everything is scoped to this folder; nothing is installed globally. The Zig
toolchain (0.16.0) is fetched into `tools/zig` on first use.

```powershell
.\build.ps1                 # -> zig-out\bin\mibi.exe (ReleaseSmall)
.\build.ps1 run             # build and run
.\build.ps1 test            # unit tests
.\build.ps1 size            # build every target and check the size gate
.\build.ps1 -Doptimize=Debug
.\build.ps1 -Dtarget=x86_64-linux-gnu   # cross-compile
```

## Controls

| Key | Action |
| --- | --- |
| *type* | insert text |
| `Enter` | new line |
| `Tab` | insert 4 spaces |
| `Backspace` / `Delete` | delete before / after the cursor |
| arrows | move |
| `Ctrl+arrows` | move by word |
| `Home` / `End` | start / end of line |
| `PgUp` / `PgDn` | move a page |
| `Shift` + movement | extend the selection |
| `Ctrl+A` | select all |
| `Esc` | clear the selection (or cancel a prompt) |
| `Ctrl+C` / `Ctrl+X` | copy / cut selection (or line) |
| `Ctrl+V` | paste from the register |
| `Ctrl+D` | duplicate the current line |
| `Ctrl+Z` / `Ctrl+Y` | undo / redo |
| `Ctrl+F` | find (incremental); `F3` / `Shift+F3` next / previous |
| `Ctrl+R` | replace all |
| `Ctrl+G` | go to `line[:column]` |
| `Ctrl+S` | save; asks for a name if the buffer is unnamed |
| `Ctrl+O` | open a file in a new tab (Tab completes the path) |
| `Ctrl+T` / `Ctrl+W` | new tab / close tab (closing the last one quits) |
| `Ctrl+PgUp` / `Ctrl+PgDn` | previous / next tab |
| `Ctrl+?` / `F1` | help panel |
| `Ctrl+Q` | quit (asks first if any tab has unsaved edits) |

## Features

- UTF-8 text, decoded to codepoints, with a generated Unicode width table
  (CJK and emoji take two cells, combining marks zero).
- Piece-table buffer: cheap edits, good on large files. A cached line index
  keeps row lookups a binary search, so drawing stays proportional to the
  visible rows rather than the file size.
- Cursor with column memory; word movement; selection with a highlight.
- Clipboard register plus **OSC 52** so copy reaches the system clipboard.
- Undo/redo with typing grouped into single steps.
- Find (incremental), replace all, and go-to-line.
- Syntax highlighting from `syntax.d/*.ini` definitions (kibi's format): 52
  languages ship in the repo, and adding one is dropping in a file - no
  rebuild. Multi-line comments and strings carry state across lines.
- Line numbers, status bar (name, dirty `[+]`, cursor, line count, size).
- Multiple documents as tabs: a tab bar with per-document dirty markers,
  Ctrl+T / Ctrl+W, Ctrl+PgUp / Ctrl+PgDn, and a quit that checks every tab.
- File open/save; path prompts list the directory; Tab completes. A failed
  open or save reports the actual OS error rather than failing silently.
- Cell-grid **diff renderer**: changed rows are rewritten in full.
- Raw mode, alternate screen, resize handling, auto-wrap disabled, UTF-8
  console codepage set on Windows.
- Cross-platform from one codebase: `src/os.zig` (kernel32 / libc), `src/term.zig`.

## Architecture

```
src/main.zig     entry, input decoding, prompts, tabs, drawing
src/editor.zig   cursor, selection, editing, undo/redo, clipboard, search, files
src/buffer.zig   piece table + cached line index
src/syntax.zig   data-driven highlighter (reads syntax.d/*.ini)
src/ini.zig      small INI reader
src/render.zig   cell grid + ANSI diff
src/term.zig     raw mode, alt screen, size, input
src/os.zig       raw OS layer (no std.Io)
src/text.zig     UTF-8 helpers
src/width.zig    generated Unicode width table
```

## Size

ReleaseSmall, stripped, cross-compiled. `.\build.ps1 size` rebuilds every
target and fails if one grows past its budget (Phase 1 <= 80 KB, Phase 2 <=
150 KB, hard ceiling 1 MB); see `experiments/README.md` for the probe data.

| Target | Bytes |
| --- | ---: |
| aarch64-linux-gnu | 58,080 |
| x86_64-linux-gnu | 63,576 |
| x86_64-macos | 71,020 |
| aarch64-macos | 107,304 |
| x86_64-windows | 115,200 |

## Not yet

Config file, configurable keybindings, themes, mouse, splits, file tree,
command palette, multi-cursor, macros, regex, embedded terminal.
