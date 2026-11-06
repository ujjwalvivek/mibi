# Changelog

## Unreleased

**Phase 6 polish**

- Matching brackets: the pair next to the cursor is painted in the theme accent,
  including a partner on another line, and the cursor block itself turns accent
  when it sits on a bracket.
- Paste is one edit: a pasted block (bracketed by the terminal or a plain
  burst) is inserted in one undo step, and CR/CRLF in it become `\n`. On Unix
  mibi enables bracketed-paste mode (`?2004h`) while it owns the terminal.
- CI: `.github/workflows/ci.yml` builds and tests on Linux and Windows and
  enforces the six-target size gate on Linux.
- Packaging: `tools/package.ps1` and `tools/package.sh` stage
  `dist/mibi-<version>-<target>/` (binary, `syntax.d`, `themes`, licence, README,
  example config) and archive it; `.gitattributes` pins LF in the repository.

**Removed**

- The embedded terminal panel: `F8` / `Shift+F8`, the `[terminal] command` /
  `height` / `padding` keys, the `>_` status button and the panel chevron are
  gone, along with `src/pty.zig`, `src/vterm.zig` and `src/terminal.zig`. mibi
  no longer ships a pseudo terminal, and `F8` does nothing. It is still a
  terminal-UI editor - it runs inside the terminal you already have - and
  formatters (`F4`) and external commands are unaffected: they run tools in the
  background through `os.runCommand`, which never used a pty.

**Keyboard focus**

- The keyboard has exactly one owner: the editor or the file tree, and every
  click sets it. Clicking the tree and then the text no longer leaves the tree
  owning the keyboard (the arrows moved the tree selection instead of the
  cursor).
- Global keys (`F4`..`F9`) reach the editor while the file tree has the focus;
  the tree's escape-sequence handling used to swallow them.

**Selection**

- The selection is painted by buffer offset, so it no longer bleeds onto the
  first columns of the following line.
- A theme whose `selection` colour sits too close to its background is blended
  towards the text colour, so the band is always visible.
- Double click selects the word under the pointer, triple click the whole line,
  and click-drag selects a range in both directions.

**Undo**

- An edit that consumed a selection records the far edge of the edit, so undo
  leaves the cursor after the restored text (redo returns to where the edit left
  it). Typing is still grouped into one undo step.

**Files changed on disk**

- A file that changes on disk while its buffer has unsaved edits is no longer
  ignored silently: the tab shows `[!]`, the status line says
  `<file> changed on disk - F9 reloads, Ctrl+S overwrites`, and the first
  `Ctrl+S` only warns (a second one overwrites). `F9` reloads from disk,
  warning once if the buffer has unsaved edits and discarding them on the second
  press. Clean buffers still reload on their own within half a second.

**Status bar**

- The `F1 help` hint is a solid themed pill.

**Fixed**

- The input loop no longer blocks inside `ReadConsoleInputW` after a key-up:
  that starved the idle tick, so status messages never aged out, files changed
  on disk were never noticed, and the session was never autosaved until the
  next keypress. Zero-length reads are no longer treated as end of input
  either, which used to make the editor exit under load.
- Status messages clear after four seconds instead of lingering, and survive
  mouse motion.
- Reloading a file from disk drops the undo history instead of restoring piece
  lists that point into the old buffer (undo after a reload could truncate the
  document).
- An escape sequence split across reads is held until it completes: a lone
  `ESC` no longer closes the help panel or a picker and then types the rest of
  the sequence (`F1` used to insert `OP` into the buffer).
- `Shift`+wheel scrolls horizontally in real terminals: Windows Terminal does
  not always put the modifiers in the mouse record, so shift is read from the
  keyboard state as well; a real horizontal wheel (`66`/`67`) works too.
- Every chrome cell (tab bar, status line and pane borders) is painted on the
  first full frame, so no cell shows the terminal's own background.
- Hover highlights are painted again: tab-bar buttons and arrows, and the
  `F1 help` pill.
- Editor freezes and crashes are fixed.
- The terminal panel's invisible cursor and the chevron that collapsed the panel
  on hover (and could take the shell down) went with the panel.

## v0.0.3 - 2026-11-06

**Embedded terminal (phase 5)**

- `F8` opens a real shell in a panel under the panes: ConPTY on Windows,
  `posix_openpt` + `fork` on Unix (`src/pty.zig`), rendered by our own VT parser
  (`src/vterm.zig`: cursor addressing, scroll regions, alt screen, 16/256/
  true-colour SGR, wide characters, deferred wrap, DA/DSR replies) with a
  2000-line scrollback.
- The keyboard goes to the shell while the panel is focused; `F8` hands it back
  and `Shift+F8` closes the panel. `Shift+PgUp`/`PgDn` and `Shift+Up`/`Down`
  scroll the scrollback, and any key returns to the live screen.
- The shell's window follows the panel, so resizing the console or the panel
  resizes the child too. `[terminal] command` picks the shell, `height` the
  panel size.

**Selection**

- Double click selects the word under the pointer and triple click the whole
  line (the drag-select and contrast work landed after this release; see
  Unreleased).
- Undo after deleting a selection leaves the cursor after the restored text,
  and redo puts it back where the edit left it; typing is still grouped into one
  undo step.

**Terminal UX**

- The shell is picked in order: `pwsh.exe`, then `powershell.exe`, then
  `cmd.exe`, each with `-NoLogo` and the user's profile (never `-NoProfile`), so
  aliases and the prompt work; the first that spawns wins (PowerShell 7.6.9 on
  this machine). `[terminal] command` still overrides it, and Unix falls back
  from `$SHELL` to `/bin/sh`.
- The panel has a surface colour of its own and `[terminal] padding` cells of
  horizontal padding, and its cursor is always visible: a filled block while the
  shell shows it, a hollow one when the shell has hidden it. Entering and
  leaving the alt screen restores cursor visibility, so a full-screen program
  cannot leave the prompt cursorless.
- Scrollback now works in both directions: the sign in `Terminal.scroll` was
  inverted, so a wheel-up from the live screen clamped to zero. The wheel and
  `Shift+Up`/`Down` scroll a line, `Shift+PgUp`/`PgDn` a page, `Shift+Home` jumps
  to the oldest line and `Shift+End` returns to live; any key goes back to live.
- The title row names the shell and shows `-N lines` while you are scrolled
  back, and `F8` no longer writes to the status line.
- A drag inside the panel selects and copies on release (the register plus
  OSC 52, with a `copied N chars` note); right click pastes, bracketed when the
  shell asked for it.

**Surfaces**

- The sidebar, tab strip, status line and terminal panel each draw their own
  background shade: `[theme] tree_bg` (#14141c, sidebar), `tab_bar_bg` (#22222e,
  strip), `panel_bg` (#1a1a24, terminal panel) and the existing `bar_bg`
  (#282838, status line). Each default is an explicit shade, so the planes read
  apart.

**Hot reload**

- An idle tick every half second re-lists the file tree and re-stamps every
  open file, so changes made by another tool appear on their own. Measured on
  Windows with the editor's window in the background: a new tree entry and a
  rewritten buffer both showed up within one tick, with no keystrokes.
- Reloads are announced in the status bar (`reloaded notes.txt from disk`), so
  a change that landed while the window was in the background is visible the
  moment you look at it. A buffer with unsaved edits is never overwritten.
- The editor writes nothing to the terminal while it is idle, and repaints
  every cell (not a per-row diff) when it gains focus or picks up a background
  change, so a terminal that deferred painting is corrected at once.
- File stamps now work on every platform: `statx` on Linux, `fstatat` on
  macOS (previously Windows only, so open files never reloaded elsewhere).

**Formatting**

- `F4` runs the per-language formatter configured in `[format]`
  (`format_on_save` is opt-in). There is no built-in re-indent: a missing
  command is reported in the status bar instead of guessing.

**Release**

- 202 unit tests and 48 screen checks pass, and the size gate is green on all
  six targets (166,064 to 240,640 bytes).

## v0.0.2

Phase 4 of the plan: the editor now behaves like a real one, not a demo.

**Panes**

- Split panes (`F5` side by side, `F7` stacked) are two **views of one
  buffer**, each with its own cursor and scroll. `F6` / `Shift+F6` cycle the
  focus, `Shift+F5` / `Shift+F7` close a pane and keep the file open.
- Drag a tab onto a pane's left/right third (or top/bottom half) to make
  another view there; the target half is tinted while you drag.

**Tabs**

- One tab bar with file names only, a pinned `+`, a padded `x` per tab, hover
  highlights, and `‹` / `›` arrows plus wheel scrolling when the strip
  overflows.
- Drag to reorder; a press only becomes a drag after the pointer really moves.

**Documents and navigation**

- File tree (`Ctrl+B`) with Nerd Font icons, persisted root, open folders and
  selection.
- Fuzzy file picker (`Ctrl+O`), theme picker (`F2`, live preview) and command
  palette (`Ctrl+P`).
- Regex search and replace (`Ctrl+R` in the find prompt): classes, groups with
  captures, alternation, anchors, lazy quantifiers, `$0`..`$9` expansion.

**Session**

- Tabs, cursors, split layout, tree state and unsaved buffers are restored on
  restart, and saved when the window is closed with its X button.
- State lives in `%LOCALAPPDATA%\Mibi\sessions\<hash>` (one per project), not
  in the folder you are editing. `MIBI_STATE_DIR` overrides it.

**UI**

- Data-file themes (27 of them) with a live picker, a help panel that shows
  your actual bindings, and a darker sidebar that matches the tab and status
  bars.
- `Esc` closes the help panel.

**Fixes worth naming**

- `Ctrl+\` could not be bound (the console reports it as `Ctrl+?`); split is
  `F5`.
- F3 / F5 / F6 / F7 were dropped by the console input layer.
- Closing the last tab from the tab bar crashed the editor.
- Opening a file from the tree duplicated the tab (`./notes.txt` vs
  `notes.txt`).
- The file tree never reopened, because `tree_root` lines also matched `tree`.

## v0.0.1

Foundation through phase 3: a Zig 0.16 terminal editor with a piece-table
buffer, cell-grid diff renderer, Unicode width table, selection, undo/redo,
OSC 52 clipboard, find/replace, go-to-line, tabs, line numbers, data-driven
syntax highlighting (`syntax.d/*.ini`, 52 languages), themes and configurable
keybindings.
