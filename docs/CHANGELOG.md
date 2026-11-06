# Changelog

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
