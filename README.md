# mibi

A tiny, modern terminal text editor. Non-modal, in the spirit of nano/micro,
built in Zig with no third-party dependencies.

Status: **Phase 2 complete** - it opens, edits, selects, copies, undoes and
saves real files. Cross-platform (Linux, macOS, Windows).

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
| `←` `→` `↑` `↓` | move |
| `Ctrl+←` / `Ctrl+→` | move by word |
| `Home` / `End` | start / end of line |
| `PgUp` / `PgDn` | move a page |
| `Shift` + any movement | extend the selection |
| `Ctrl+A` | select all |
| `Esc` | clear the selection (or cancel a prompt) |
| `Ctrl+C` | copy selection (or line) → register + system clipboard (OSC 52) |
| `Ctrl+X` | cut selection (or line) |
| `Ctrl+V` | paste from the register |
| `Ctrl+D` | duplicate the current line |
| `Ctrl+Z` / `Ctrl+Y` | undo / redo (runs of typing undo together) |
| `Ctrl+S` | save; asks for a name if the buffer is unnamed |
| `Ctrl+O` | open a file (type a path) |
| `Ctrl+Q` | quit |

## Features

- UTF-8 text, decoded to codepoints (no byte mojibake), tab expansion.
- Piece-table buffer: cheap edits, good on large files.
- Cursor with column memory through short lines; word movement.
- Selection with a highlight, and a block cursor.
- Clipboard register plus **OSC 52** so copy reaches the system clipboard.
- Undo/redo with typing grouped into single steps.
- Line numbers, status bar (name, dirty `[+]`, cursor, line count, size).
- File open/save, and Save-As / Open prompts.
- Cell-grid **diff renderer**: only changed cells are written to the terminal.
- Raw mode, alternate screen, resize handling, auto-wrap disabled, UTF-8
  console codepage set on Windows.
- Cross-platform from one codebase: `src/os.zig` (kernel32 / libc), `src/term.zig`.

## Architecture

```
src/main.zig     entry, input decoding, prompts, drawing
src/editor.zig   cursor, selection, editing, undo/redo, clipboard, files
src/buffer.zig   piece table
src/render.zig   cell grid + ANSI diff
src/term.zig     raw mode, alt screen, size
src/os.zig       raw OS layer (no std.Io)
```

## Size

ReleaseSmall, stripped, cross-compiled (see `experiments/README.md`):

| Target | Bytes |
| --- | ---: |
| x86_64-linux-gnu | ~33 KB |
| aarch64-linux-gnu | ~31 KB |
| x86_64-macos | ~34 KB |
| aarch64-macos | ~70 KB |
| x86_64-windows | ~76 KB |

## Not yet

Tabs/multiple files, search & replace, syntax highlighting, config, keybinds,
themes, mouse, splits, file tree, command palette, multi-cursor, macros, regex,
embedded terminal. See `PLAN.md`.
