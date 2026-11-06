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

## Installing

```powershell
.\build.ps1            # build into zig-out\bin
.\tools\install.ps1    # copy the binary, syntax.d and themes to %LOCALAPPDATA%\Programs\Mibi
```

After that every `build.ps1` run updates the installed copy automatically (if it
exists), so the `mibi` Windows Terminal profile always launches the binary you
just built. `tools\install.ps1` also writes `mibi.cmd`, which opens the editor
in the `mibi` profile so it gets the Maple Mono NF font.

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
| `Ctrl+Alt+Up` / `Down`    | add a cursor above / below (Esc drops them)           |
| `Ctrl+F`                  | find (incremental); `F3` / `Shift+F3` next / previous; `Ctrl+R` in the prompt toggles regex |
| `Ctrl+R`                  | replace all                                           |
| `Ctrl+G`                  | go to `line[:column]`                                 |
| `Ctrl+S`                  | save; asks for a name if the buffer is unnamed        |
| `Ctrl+O`                  | fuzzy file picker: type to filter, Enter opens in a new tab |
| `Ctrl+T` / `Ctrl+W`       | new tab / close tab (closing the last one quits)      |
| `Ctrl+PgUp` / `Ctrl+PgDn` | previous / next tab                                   |
| `F5` / `F7`               | split the pane side by side / stacked                 |
| `Shift+F5` / `Shift+F7`   | close the focused pane (its file stays open as a tab)  |
| `F6` / `Shift+F6`         | next / previous pane (or click a pane)                |
| `F2`                      | theme picker (arrows preview live, Enter keeps and saves, Esc restores) |
| `Ctrl+P`                  | command palette: every action, fuzzy-filtered |
| `Ctrl+?` / `F1`           | help panel (Esc closes it); hints at the status bar's right edge |
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
  pattern engine (classes and ranges, groups with captures, alternation,
  anchors, `\d \w \s \b`, `* + ? {n,m}` with lazy variants). Replacements
  expand `$0`..`$9` from the captured groups. Backtracking is step-capped and
  there are no backreferences yet.
- File tree sidebar (`Ctrl+B`): directories expand with Enter/`j`/`k` or a
  click, files open in a tab. The open folders and the selected entry are
  restored with the session, so it comes back where you left it. Icons are Nerd Font glyphs: see
  [assets/fonts/README.md](assets/fonts/README.md) for installing Maple Mono NF
  and `tools/install-font.ps1`; `icons = ascii` in `[editor]` falls back to
  letter markers.
- Mouse: click text to place the cursor, click a tab to switch to it, click
  picker rows (click again to accept), click the status-bar hint for help;
  the wheel moves one line per notch. Over the tab bar the wheel scrolls the
  strip instead. Quick-edit mode is turned off so the console reports clicks
  to the editor.
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
- Multiple cursors (`Ctrl+Alt+Up` / `Ctrl+Alt+Down`): typing, backspace and
  delete apply at every cursor, movement moves them together, `Esc` drops
  them. Extra cursors are drawn as blocks like the main one.
- Split panes (`F5` side by side, `F7` stacked): a binary split tree with
  a `│`/`─` rule between panes, the rule glowing next to the focused
  pane. Each pane edits its own document with its own cursor, selection and
  scroll; `F6` cycles the focus and clicking inside a pane focuses it and puts
  the cursor there. `Shift+F5` / `Shift+F7` closes a pane and leaves its file
  open as a tab, so a split can be undone without closing anything. Dragging a
  tab onto a pane's left/right third (or top/bottom half) splits that pane with
  the tab, and the target half is tinted while you drag. Splitting shows another
  open file when there is one (an unused empty scratch tab is reused, so
  `[No Name]` tabs do not pile up). Closing a tab closes its pane, and the
  layout is saved in the session file.
- Multiple documents as tabs: file names only in the tab bar, a `+` button
  pinned to the right edge and a per-tab `x` to close (with a cell of padding
  so it does not touch the tab edge; hovering `x`, `+` or the scroll arrows
  lights them up). When the tabs do not fit, `‹` / `›` arrows appear at both
  ends and the wheel over the bar scrolls the strip; the active tab is always
  scrolled into view. Closing the last tab quits, exactly like `Ctrl+W`.
  Per-document dirty markers, Ctrl+T / Ctrl+W, Ctrl+PgUp / Ctrl+PgDn, and a
  quit that checks every tab.
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
| aarch64-linux-gnu |  125,624 |
| x86_64-linux-gnu  |  137,248 |
| x86_64-macos      |  145,214 |
| aarch64-macos     |  181,560 |
| x86_64-windows    |  196,608 |

## Changelog

See [CHANGELOG.md](CHANGELOG.md); the current release is **v0.0.2**.

## Licence

MIT - see [LICENSE](LICENSE). The installer copies the licence next to the
binary, so an installed mibi always carries it.

## Session state

mibi reopens your last session and keeps unsaved buffers across restarts. That
state is **not** written into the folder you are working in: it lives under the
user data directory, one directory per project (an FNV-1a hash of the working
directory):

```
%LOCALAPPDATA%\Mibi\sessions\<hash>\mibi-session
%LOCALAPPDATA%\Mibi\sessions\<hash>\mibi-session-buf-<n>.txt
```

`mibi-session` lists the tabs, cursors, split layout and file-tree state;
`mibi-session-buf-<n>.txt` holds the text of a buffer that has unsaved changes.
Set `MIBI_STATE_DIR` to put them somewhere else (the tests use it to keep each
run isolated).

## Not yet

Multi-cursor, macros, embedded terminal.
