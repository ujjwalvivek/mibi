# Changelog

## v0.2.0

- The web build: the editor compiles to `wasm32-freestanding` and runs in a
  browser through xterm.js, with the same keys, tabs, splits, pickers,
  themes and session. See [WEB.md](WEB.md).
  - In Chromium-based browsers, Open folder works on a real folder: saves are
    written to disk, changes made elsewhere come in within a few seconds
    (clean tabs reload, tabs with unsaved changes keep them), deleted files
    leave the workspace, and a save never overwrites a file that changed on
    disk since it was read: the tab goes back to unsaved instead.
  - Elsewhere, imported files stay in the browser; Download writes one out.
  - Each workspace (the browser's own files, and each real folder) has its
    own session, in the origin private file system (IndexedDB as a
    fallback), not `localStorage`; an old `localStorage` session is moved
    over. Settings are shared between workspaces. One tab runs the editor at
    a time.
  - The page is one top bar in the house style: where the files are and how
    they are, Open folder, Open files, Download, the command palette, and a
    keys panel. `alt+t`, `alt+w` and `alt+pgup/pgdn` stand in for the four
    keys a browser never hands over; every other key works as natively.
  - Formatters, the filter and the kitty keyboard protocol are not available.
  - Deployed to Cloudflare Pages at <https://mibi.ujjwalvivek.com> after the
    web tests pass.
  - The file tree's Nerd Font icons use the NFMono subset, so they fit one
    cell, including the bold selected row; they no longer clip.
  - One-finger drags scroll the editor on phones, vertically and sideways; a
    tap is still a click.
- `Unsupported` errors (the web build's missing child processes) say "not
  available in this build" in the status line.
- Kitty keyboard protocol, opt-in with `kitty_keys = true` in `[editor]`.
  On terminals that implement it, `Ctrl+Shift` chords and `Escape` arrive as
  distinct keys instead of colliding with other control bytes, and key
  releases are dropped rather than acting twice. The editor pushes the mode
  when it takes the screen and pops it on exit. Windows is unchanged: console
  records already carry the modifiers.

## v0.1.0

**The rebuild**

The editor was taken apart and put back together on a new structure; see
[ARCHITECTURE.md](ARCHITECTURE.md). What that changes for someone using it:

- Linux and macOS work, and are tested on every push along with Windows.
  Before, only the Windows build compiled.
- The mouse, focus reports and bracketed paste now work on Unix terminals.
- Regex search runs in linear time; no pattern can stall the editor.
- Two panes can show the same file, each with its own cursors and scroll.
- New commands: delete line (`Ctrl+K`), move line (`Alt+Up` / `Alt+Down`),
  toggle comment (`Ctrl+/`), dedent (`Shift+Tab`), delete word
  (`Ctrl+Backspace` / `Ctrl+Delete`), start and end of file, save as.
  `Ctrl+click` adds a cursor; double and triple click select a word and a line.
- The wheel scrolls without moving the cursor.
- Help is `F1` only: `Ctrl+/` is now the comment toggle.
- Undo no longer keeps a copy of the document per step, and undoing back to
  the saved state clears the modified marker.
- Closing the terminal window (or SIGHUP / SIGTERM) saves the session.
- `Ctrl+Q` no longer asks about unsaved changes: they are in the session and
  come back with the tabs. Closing a tab with unsaved changes still asks,
  because that does discard them.
- Saving is all or nothing: the text goes to a temporary file that then takes
  the old one's place, so a crash or a full disk cannot leave half a file.
  Permissions, symbolic links and hard links are kept.
- Files changed by another program are now noticed on macOS too.
- Soft wrap: `Alt+Z`, or `soft_wrap = true` in `[editor]`. Lines fold at the
  pane's width, between words where possible, and the cursor moves by the
  rows on screen.
- Matching brackets are highlighted; `Ctrl+]` jumps to the partner.
- Filter (`Alt+X`): pipe the selection or the file through a shell command.
- Running out of memory is reported in the status line instead of ending the
  program.
- The embedded terminal is gone.
- The session file has a new format. A session saved by v0.0.2 is not read;
  the first start after upgrading opens empty.
- Binaries are about 40 KB larger (173 to 250 KB depending on the target).

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
