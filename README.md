# mibi

<img src="assets/png/mibi-128.png" width="96" alt="mibi">

A tiny, modern terminal text editor. Non-modal, in the spirit of nano/micro,
built in Zig with no third-party dependencies.

Status: **v0.0.3** - phases 0-5 are complete: piece-table editing, tabs,
panes, search/replace, syntax highlighting, themes, an embedded terminal on
`F8`, plus this release's selection fixes, terminal polish and panel surfaces.
Cross-platform (Linux, macOS, Windows).

```
mibi                # new buffer
mibi <file>         # open a file (a missing file opens empty and saves there)
```

## Build

Everything is scoped to this folder; nothing is installed globally. The Zig
toolchain (0.16.0) is fetched into `tools/zig` on first use.

```powershell
.\build.ps1                             # -> zig-out\bin\mibi.exe (ReleaseSmall)
.\build.ps1 run                         # build and run
.\build.ps1 test                        # unit tests
.\build.ps1 size                        # build every target and check the size gate
.\build.ps1 -Doptimize=Debug
.\build.ps1 -Dtarget=x86_64-linux-gnu   # cross-compile
```

## Configuration

`.\build.ps1` seeds `zig-out\bin\mibi.ini` from `config/mibi.ini.example` the first
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
tree_bg = #14141c      ; sidebar surface
panel_bg = #1a1a24     ; terminal panel surface
tab_bar_bg = #22222e   ; tab strip surface

[terminal]
command = cmd.exe     ; the shell F8 runs (default: pwsh, powershell, then cmd)
height = 12           ; panel rows, title row included
padding = 1           ; cells of horizontal padding inside the panel (0-4)
```

The theme controls the whole palette: editor text, gutter, selection, tab bar,
status line, help panel and the syntax classes. Colours are `#rrggbb` or `#rgb`.
Surfaces have keys of their own - `tree_bg` (sidebar), `tab_bar_bg` (tab strip),
`panel_bg` (terminal panel) and `bar_bg` (status line). Each has an explicit
default shade, so the planes read apart even when a theme sets none of them.

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
- The embedded terminal (`F8`) needs a pseudo console: ConPTY on Windows 10
  1809 or newer (Windows Terminal and current conhost both provide it), and a
  POSIX pty on Linux and macOS. If the shell cannot be started, the status bar
  says why instead of leaving an empty panel.
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

| Key                       | Action                                                                                      |
| ------------------------- | ------------------------------------------------------------------------------------------- |
| _type_                    | insert text                                                                                 |
| _mouse_                   | click places the cursor, drag selects, wheel scrolls; right click pastes into the shell     |
| `Enter`                   | new line                                                                                    |
| `Tab`                     | insert 4 spaces                                                                             |
| `Backspace` / `Delete`    | delete before / after the cursor                                                            |
| arrows                    | move                                                                                        |
| `Ctrl+arrows`             | move by word                                                                                |
| `Home` / `End`            | start / end of line                                                                         |
| `PgUp` / `PgDn`           | move a page                                                                                 |
| `Shift` + movement        | extend the selection                                                                        |
| `Ctrl+A`                  | select all                                                                                  |
| `Esc`                     | clear the selection (or cancel a prompt)                                                    |
| `Ctrl+C` / `Ctrl+X`       | copy / cut selection (or line)                                                              |
| `Ctrl+V`                  | paste from the register                                                                     |
| `Ctrl+D`                  | duplicate the current line                                                                  |
| `Ctrl+Z` / `Ctrl+Y`       | undo / redo                                                                                 |
| `Ctrl+Alt+Up` / `Down`    | add a cursor above / below (Esc drops them)                                                 |
| `Ctrl+F`                  | find (incremental); `F3` / `Shift+F3` next / previous; `Ctrl+R` in the prompt toggles regex |
| `Ctrl+R`                  | replace all                                                                                 |
| `Ctrl+G`                  | go to `line[:column]`                                                                       |
| `Ctrl+S`                  | save; asks for a name if the buffer is unnamed                                              |
| `Ctrl+O`                  | fuzzy file picker: type to filter, Enter opens in a new tab                                 |
| `Ctrl+T` / `Ctrl+W`       | new tab / close tab (closing the last one quits)                                            |
| `Ctrl+PgUp` / `Ctrl+PgDn` | previous / next tab                                                                         |
| `F5` / `F7`               | split the pane side by side / stacked                                                       |
| `Shift+F5` / `Shift+F7`   | close the focused pane (its file stays open as a tab)                                       |
| `F6` / `Shift+F6`         | next / previous pane (or click a pane)                                                      |
| `F2`                      | theme picker (arrows preview live, Enter keeps and saves, Esc restores)                     |
| `F8`                      | embedded terminal: opens it, then hands the keyboard back and forth                         |
| `Shift+F8`                | close the terminal panel                                                                    |
| `Shift+PgUp` / `PgDn`     | scroll the terminal's scrollback (any key goes back to live)                                |
| `Shift+Up` / `Down`       | scroll the terminal's scrollback a line (any key goes back to live)                         |
| `Shift+Home` / `End`      | terminal scrollback: oldest line / back to live                                             |
| `Ctrl+P`                  | command palette: every action, fuzzy-filtered                                               |
| `Ctrl+?` / `F1`           | help panel (Esc closes it); hints at the status bar's right edge                            |
| `Ctrl+Q`                  | quit (asks first if any tab has unsaved edits)                                              |

## Features

- UTF-8 text, decoded to codepoints, with a generated Unicode width table
  (CJK and emoji take two cells, combining marks zero).
- Piece-table buffer: cheap edits, good on large files. A cached line index
  keeps row lookups a binary search, so drawing stays proportional to the
  visible rows rather than the file size.
- Cursor with column memory; word movement; selection whose band is kept
  visible on every theme (a `selection` colour too close to the background is
  blended towards the text colour). Click-drag selects a run of text, a double
  click selects the word, a triple click the line.
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
- Hot reload: a half-second idle tick re-lists the tree and re-stamps every
  open file, so a file created or rewritten by another tool shows up without
  touching the keyboard. A reload is announced in the status bar
  (`reloaded notes.txt from disk`) and never overwrites a buffer with unsaved
  edits. Nothing is written to the terminal while the editor is idle, and a
  window that regains focus repaints every cell, so a terminal that held
  painting back while it was in the background catches up at once. The file
  stamp is `FindFirstFileW` on Windows and `statx` (Linux) / `fstatat`
  (macOS) elsewhere.
- Mouse: click text to place the cursor (a double click selects the word, a
  triple click the whole line, a drag selects a run of text), click a tab to
  switch to it, click picker rows (click again to accept), click the status-bar
  hint for help; the wheel moves one line per notch. Over the tab bar the wheel
  scrolls the strip instead, and over the terminal panel it scrolls the shell's
  scrollback. Right click in the terminal panel pastes into the shell.
  Quick-edit mode is turned off so the console reports clicks to the editor.
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
- Embedded terminal (`F8`): a real shell in a pseudo terminal (ConPTY on
  Windows, `posix_openpt` + `fork` elsewhere) drawn in a panel under the panes,
  with its own VT parser (`src/vterm.zig`), 256-colour and true-colour SGR, a
  scrollback of 2000 lines (wheel and `Shift+Up`/`Down` a line, `Shift+PgUp`/
  `PgDn` a page, `Shift+Home`/`End` to the oldest line and back to live, any key
  returns to live), and the shell's window kept in step with the panel. The
  shell is `pwsh.exe`, then `powershell.exe`, then `cmd.exe` on Windows
  (`$SHELL`, then `/bin/sh` elsewhere), each with `-NoLogo` and the user's
  profile; `[terminal] command` overrides it, and `height` / `padding` size the
  panel. The panel has a surface colour of its own, and its cursor is always
  visible: a filled block while the shell shows it, hollow when the shell hides
  it (the alt screen restores it on entry and exit). The title row names the
  shell and shows `-N lines` while you are scrolled back. A drag inside the
  panel selects and copies on release (the register plus OSC 52); right click
  pastes, bracketed when the shell asked for it. `F8` hands the keyboard back
  and `Shift+F8` closes the panel. The scrollback ring is allocated when the
  terminal opens (~2.5 MB at 80 columns, ~6 MB at 200).
- Cell-grid **diff renderer**: changed rows are rewritten in full.
- Raw mode, alternate screen, resize handling, auto-wrap disabled, UTF-8
  console codepage set on Windows.
- Cross-platform from one codebase: `src/os.zig` (kernel32 / libc), `src/term.zig`.

## Architecture

```
src/main.zig     entry, input decoding, prompts, tabs, drawing
src/editor.zig   cursor, selection, editing, undo/redo, clipboard, search, files
src/buffer.zig   piece table + cached line index
src/panes.zig    split tree, per-pane documents
src/tree.zig     file tree sidebar
src/picker.zig   fuzzy file/theme/command pickers
src/syntax.zig   data-driven highlighter (reads syntax.d/*.ini)
src/regex.zig    Pike VM regex engine
src/ini.zig      small INI reader
src/config.zig   mibi.ini: settings, theme, key bindings
src/keys.zig     key names, actions and the key map
src/render.zig   cell grid + ANSI diff
src/term.zig     raw mode, alt screen, size, input
src/terminal.zig the embedded terminal: pty + VT screen + key forwarding
src/pty.zig      pseudo terminal (ConPTY / posix_openpt + fork)
src/vterm.zig    VT/ANSI parser, screen buffer and scrollback
src/os.zig       raw OS layer (no std.Io)
src/text.zig     UTF-8 helpers
src/width.zig    generated Unicode width table
```

## Size

ReleaseSmall, stripped, cross-compiled. `.\build.ps1 size` rebuilds every
target and fails if one grows past its budget (re-based after v0.0.3, hard
ceiling 1 MB); see `experiments/README.md` for the probe data.

| Target            |   Bytes |
| ----------------- | ------: |
| aarch64-linux-gnu | 166,016 |
| x86_64-linux-gnu  | 181,592 |
| x86_64-macos      | 191,083 |
| aarch64-macos     | 220,296 |
| x86_64-windows    | 240,640 |

## Changelog

See [docs/CHANGELOG.md](docs/CHANGELOG.md); the current release is **v0.0.3**.

## Licence

MIT - see [LICENSE](LICENSE). The installer copies the licence next to the
binary, so an installed mibi always carries it.

## Formatting

`F4` runs the formatter configured for the file's extension. mibi pipes the
buffer to the command on stdin and replaces the buffer with what it prints, so
any tool works - Prettier, Biome, `zig fmt`, `black`, `gofmt`, `rustfmt`,
`clang-format`, `shfmt`, `taplo`, `dprint`, whatever you have:

```ini
[format]
on_save = false
zig  = zig fmt --stdin
py   = black -q -
js   = prettier --stdin-filepath {file}
css  = biome format --stdin-file-path {file}
```

`{file}` becomes the file's path so tools can pick a parser. The edit is one
undo step and keeps the cursor. Failures are reported, never silent: no
formatter for the type, the tool missing, a non-zero exit, empty output or a
10 second timeout all leave the buffer untouched and say so in the status line.
`on_save = true` formats before every save.

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

The embedded terminal is deliberately not part of the session: it is a running
process, so it starts fresh on every launch (`F8` opens one, `Shift+F8` closes
it).

## Not yet

LSP and completion, macros (dropped by decision), and the phase 6 polish:
bracketed paste in the editor, matching brackets, soft wrap and atomic save.
