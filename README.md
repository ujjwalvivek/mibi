# mibi

<img src="assets/png/mibi-128.png" width="96" alt="mibi">

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

## Configuration

`.build.ps1` seeds `zig-out\bin\mibi.ini` from `mibi.ini.example` the first
time it builds (later builds leave your edits alone). Copy it next to the binary
or into the directory you run mibi from; it is optional and every key falls back
to a default. Unknown keys are ignored.

```ini
[editor]
tab_width = 2
line_numbers = false
syntax = true

[theme]
background = #0e0e0e   ; unset keeps the terminal's own background
text = #d8dee9
keyword1 = #c678dd
comment = #6a7382
```

The theme controls the whole palette: editor text, gutter, selection, tab bar,
status line, help panel and the syntax classes. Colours are `#rrggbb` or `#rgb`.

The current line is tinted with `line_hl` (derived from the background and
text colours when a theme does not set it).

27 themes ship in `themes/` (VS Code Dark+/Light+, Catppuccin Mocha/Macchiato/
Frappé/Latte, Rosé Pine/Moon/Dawn, Tokyo Night/Storm, Kanagawa, Everforest,
GitHub Dark/Light, Ayu Dark, Horizon, Dracula, Nord, Gruvbox, One Dark,
Monokai, Solarized, Material Palenight, Nightfox, Oxocarbon, Flexoki). Pick one
with `theme = catppuccin-mocha` in `[editor]`; keys in `[theme]` then override
it. Themes are data files, so adding one costs no binary size.

Language definitions are separate: drop a `.ini` into `syntax.d/` (kibi's
format, 52 languages ship with mibi) and it is picked up at startup.

## Running in your terminal

mibi is a terminal text editor: it runs inside a terminal, and the window
chrome belongs to that terminal. Double-clicking the executable does not start
a stray console — it shows a short message telling you to open a terminal,
then exits.

- `mibi <file>` from a terminal you already have open uses that window and
  profile, and sets the tab title (`mibi - notes.txt`).
- `--in-terminal` skips the double-click check (used by scripts and tests).
- `assets/windows-terminal/install.ps1` adds a Windows Terminal profile (icon,
  colour scheme, font). See
  [assets/windows-terminal/README.md](assets/windows-terminal/README.md) for
  chrome-less settings (F11 focus mode, hiding tabs from the title bar).
- Double-clicking an unsigned local build also makes Windows SmartScreen ask
  "Windows protected your PC"; click _Run anyway_, or launch from a terminal.

## Icons

`assets/` holds the app icon (`mibi.svg`, `mibi.ico` and PNGs from 16 to
1024 px). Windows builds embed `mibi.ico` as a resource, and
`.\build.ps1` installs the icons under `zig-out/share/mibi/icons` for
packaging.

## Controls

| Key                       | Action                                                |
| ------------------------- | ----------------------------------------------------- |
| _type_                    | insert text                                           |
| `Enter`                   | new line                                              |
| `Tab`                     | insert 4 spaces                                       |
| `Backspace` / `Delete`    | delete before / after the cursor                      |
| arrows                    | move                                                  |
| `Ctrl+arrows`             | move by word                                          |
| `Home` / `End`            | start / end of line                                   |
| `PgUp` / `PgDn`           | move a page                                           |
| `Shift` + movement        | extend the selection                                  |
| `Ctrl+A`                  | select all                                            |
| `Esc`                     | clear the selection (or cancel a prompt)              |
| `Ctrl+C` / `Ctrl+X`       | copy / cut selection (or line)                        |
| `Ctrl+V`                  | paste from the register                               |
| `Ctrl+D`                  | duplicate the current line                            |
| `Ctrl+Z` / `Ctrl+Y`       | undo / redo                                           |
| `Ctrl+F`                  | find (incremental); `F3` / `Shift+F3` next / previous; `Ctrl+R` in the prompt toggles regex |
| `Ctrl+R`                  | replace all                                           |
| `Ctrl+G`                  | go to `line[:column]`                                 |
| `Ctrl+S`                  | save; asks for a name if the buffer is unnamed        |
| `Ctrl+O`                  | fuzzy file picker: type to filter, Enter opens in a new tab |
| `Ctrl+T` / `Ctrl+W`       | new tab / close tab (closing the last one quits)      |
| `Ctrl+PgUp` / `Ctrl+PgDn` | previous / next tab                                   |
| `F2`                      | theme picker (arrows preview live, Enter keeps and saves, Esc restores) |
| `Ctrl+P`                  | command palette: every action, fuzzy-filtered |
| `Ctrl+?` / `F1`           | help panel; shows your bindings, hinted at the status bar's right edge |
| `Ctrl+Q`                  | quit (asks first if any tab has unsaved edits)        |

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
- Regular expressions: `Ctrl+R` inside find/replace switches the search to a
  full pattern engine (classes, groups, alternation, anchors, `* + ? {n,m}`,
  `\d \w \s \b`, lazy quantifiers).
- File tree sidebar (`Ctrl+B`): directories expand with Enter/`j`/`k` or a
  click, files open in a tab, and every entry has a one-cell type icon.
- Mouse: click text to place the cursor, click a tab to switch to it, click
  picker rows (click again to accept), click the status-bar hint for help;
  the wheel moves one line per notch. Quick-edit mode is turned off so the
  console reports clicks to the editor.
- Configurable keybindings and a colour theme via `mibi.ini` (`[keys]` and
  `[theme]`), with the whole palette and every action bindable. The help
  panel renders the keys you actually bound.
- Picking a theme with `F2` writes `theme = <name>` into the `mibi.ini` that
  was loaded, so the next start comes up in it.
- Fuzzy pickers for opening files (`Ctrl+O`), switching themes (`F2`, live
  preview) and running any action (`Ctrl+P` command palette).
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
src/config.zig   mibi.ini: settings, theme, key bindings
src/keys.zig     key names, actions and the key map
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

| Target            |   Bytes |
| ----------------- | ------: |
| aarch64-linux-gnu |  95,376 |
| x86_64-linux-gnu  |  105,336 |
| x86_64-macos      |  116,220 |
| aarch64-macos     | 144,424 |
| x86_64-windows    | 163,328 |

## Not yet

Splits, file tree, multi-cursor, macros, regex, embedded terminal.
