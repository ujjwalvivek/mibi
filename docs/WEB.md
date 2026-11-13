# The web build

mibi also runs in a browser. It is the **same Zig editor** compiled to
WebAssembly, with the terminal replaced by [xterm.js](https://xtermjs.org/) and
the operating system replaced by a virtual filesystem. The text model, widgets,
commands, keybindings, syntax highlighting and themes are the native ones; the
web build is a platform backend and a static host, not a second editor.

This is the "terminal in a page" surface: every editor feature that does not
need a real process or a real folder works exactly as it does on the desktop.

## Build and run

```powershell
.\build.ps1 web
python -m http.server 8765 --directory zig-out/web
# open http://localhost:8765/
```

On Linux and macOS:

```sh
zig build web
python3 -m http.server 8765 --directory zig-out/web
```

`zig build web` installs a self-contained site in `zig-out/web`:

| File | What it is |
| --- | --- |
| `mibi.wasm` | the editor, `wasm32-freestanding`, no libc and no `std.Io` |
| `index.html`, `main.js` | the host: xterm.js, input, frames, storage, file import/export |
| `xterm.js`, `xterm.css`, `addon-fit.js` | vendored xterm.js 5.5.0 and fit addon 0.10.0 (MIT) |
| `MapleMono-NF-Regular.woff2` | a WOFF2 subset of Maple Mono NF, the terminal font (OFL-1.1) |
| `syntax.d/`, `themes/`, `assets.txt` | the data files the host seeds into the virtual filesystem |
| `mibi.ini.example` | seeded as `/workspace/mibi.ini` on a first visit |

`tools/web-assets.ps1` regenerates `web/assets.txt` after adding a language or a
theme. The vendored xterm files are updated from `web/node_modules`; see
`web/vendor/README.md`.

## How it fits together

```
src/core, src/ui, src/app      unchanged
src/platform/web.zig           the web platform module
src/platform/web/os.zig        virtual filesystem, clock, host calls
src/web_main.zig               exported ABI: init, input, tick, frames, VFS
web/index.html, web/main.js    xterm.js host and the page
```

The native loop blocks in `poll`; the browser cannot. `src/web_main.zig` is the
event-driven equivalent:

- `mibi_init(cols, rows)` builds the app, loads `/syntax.d`, restores the
  session and returns the first frame.
- `mibi_input(bytes)` feeds terminal bytes through the same `ansi.Decoder` the
  Unix build uses, handles every event, and returns a frame.
- `mibi_flush()` resolves a lone ESC or a split sequence after 30 ms.
- `mibi_resize(cols, rows)` and `mibi_tick()` mirror the native resize and idle
  tick, including the two-second session autosave.
- `mibi_frame_ptr()` / `mibi_frame_len()` expose the ANSI frame; the host writes
  it to xterm.js.
- `mibi_vfs_*` seed, read and serialise the virtual filesystem, and report the
  `/workspace` paths a real folder still has to receive.

The host is deliberately thin. xterm.js supplies the terminal emulation (the
alternate screen, SGR mouse reports, focus reports, bracketed paste, true
colour) and `onData` gives the editor the same bytes a real terminal would.
The host also turns the editor's OSC 52 copy sequence into a browser clipboard
write, and OSC 2 into `document.title`.

## What works

| Feature | Web |
| --- | --- |
| Editing, UTF-8, undo/redo, selections, multi-cursor | yes |
| Tabs, splits, pane focus, layout restore | yes |
| Search/replace, regex, go-to-line | yes |
| File tree, fuzzy picker, command palette, theme picker | yes, over the virtual workspace |
| Syntax highlighting, themes, `mibi.ini`, keybindings | yes |
| Mouse click/drag/wheel, bracketed paste, focus | yes, through xterm.js |
| Soft wrap, matching brackets, line operations, comment toggle | yes |
| Session restore (tabs, splits, cursors, unsaved buffers) | yes, in this browser |
| Internal clipboard and OSC 52 to the system clipboard | yes, where the browser allows clipboard writes |
| Open folder in Chromium | a real folder; Save writes back through the File System Access API |
| Open files, and Open folder elsewhere | a snapshot in the virtual workspace; Download exports |
| Toolbar for browser-reserved keys | yes: Find, Replace, Go to, Palette, Tree, Split, panes, tabs, Keys, Quit |
| Drag and drop files onto the page | yes, files (not folders) |

## Real folders (Chromium)

`Open folder` uses `showDirectoryPicker` when the browser has it. The handle is
stored in IndexedDB; after a reload the browser asks for permission again and
the toolbar shows **Reconnect**. Import reads text files into `/workspace`,
skipping `.git`, `node_modules`, `.zig-cache`, `zig-out`, `target`, `dist`,
`build`, `.next`, files over 2 MB, files that do not decode as UTF-8, and stops
at 2,000 files.

Saves, theme changes and `mibi.ini` edits are written back through
`createWritable`: the web platform records every changed `/workspace` path and
the host writes them to the folder about 300 ms after the keystroke. **Refresh**
re-reads the folder; it updates files but does not remove files deleted on
disk. There is no conflict detection: if another program changes a file while
the editor has it open, the next save wins. A closed tab can lose a keystroke
that had not reached the 300 ms sync.

Browsers without the File System Access API use the `webkitdirectory` snapshot
instead, and the workspace is kept in `localStorage` like before.

## Toolbar

The toolbar duplicates the keys a browser reserves, so they have a mouse
equivalent: `Ctrl+W`/`Ctrl+T` (Close/New), `Ctrl+R` (Replace), `Ctrl+F` (Find),
`Ctrl+G` (Go to), `Ctrl+P` (Palette), `Ctrl+B` (Tree), `Ctrl+PgUp`/`PgDn`
(previous/next tab), `F5`/`F7` (split), `Shift+F5` (close pane), `F6`/`Shift+F6`
(panes), `F1` (Keys) and `Ctrl+Q` (Quit). It also has the host's own actions:
Open files, Open folder, Download and the web notes.

## Font

The page bundles a WOFF2 subset of **Maple Mono NF** and uses it for the whole
surface. The subset covers Latin, punctuation, arrows, box drawing and the
Nerd Font icon ranges the file tree uses, so the icons work without installing
anything. It is OFL-1.1; see `LICENSE.MapleMono-NF.txt` in the built site.
`tools/subset-font.ps1` regenerates the subset from a full Maple Mono NF TTF.

## What cannot be the same

These are flagged in the page's `?` panel as well.

- **External commands.** Formatters (`F4`) and the filter (`Alt+X`) spawn a
  child process. A browser cannot. The command reports "not available in this
  build" in the status line.
- **A real folder is Chromium-only.** Firefox and Safari import a snapshot
  instead. Even in Chromium, Refresh does not delete files removed on disk, and
  a file changed outside the editor can be overwritten by the next save.
  Files over 2 MB, binary files and heavy directories are skipped on import.
  The folder handle survives a reload in IndexedDB, but the permission has to
  be granted again with the Reconnect button.
- **The kitty keyboard protocol.** xterm.js does not implement it, so
  `kitty_keys` has no effect in the browser.
- **Some browser shortcuts.** `Ctrl+W`, `Ctrl+T`, `Ctrl+N`, `Ctrl+R`, `F5` and
  `F12` are reserved by the browser and cannot always be intercepted. The
  toolbar duplicates every editor key that matters, including Find, Replace,
  splits, panes, tabs, Keys and Quit.
- **Nerd Font icons.** The web build bundles a subset of Maple Mono NF, so the
  file tree's icons work without installing a font. Glyphs outside the subset
  fall back to the browser's fonts.
- **Quit.** `Ctrl+Q` does not close the tab. It saves the session and shows a
  "Session saved" overlay with a Reopen button.
- **Storage size.** The workspace and session are serialised into
  `localStorage` (about 5 MB). Download important files. IndexedDB or OPFS is
  the next step for larger workspaces.
- **Multiple browser tabs.** Each tab is its own wasm instance; they share the
  same `localStorage` key, so the last writer wins. Use one editor tab.
- **Binary files, file permissions, symlinks, printing, process environment.**
  Not applicable to the virtual filesystem.
- **Mobile keyboards.** xterm.js has a hidden textarea and generally works, but
  the toolbar is the reliable way to open/save on a phone; this is untested.

## Storage

The virtual filesystem is seeded at every load:

- `/syntax.d/*.ini` and `/themes/*.ini` come from the site (`assets.txt`).
- `/workspace/mibi.ini` comes from `mibi.ini.example` if the user has not
  edited one.
- `/workspace/welcome.txt` is created on a first visit.

The workspace and session are persisted, not the seeded assets:

```
/workspace/*      imported and saved files, mibi.ini
/state/session    tabs, panes, cursors, tree state
/state/buffer-*   unsaved buffers
```

Without a real folder, the host serialises both as a small binary blob
(`MIBIVFS1`), base64-encodes it and stores it under `mibi.vfs` in
`localStorage`, at most every two seconds and on `beforeunload`. With a real
folder, only `/state` is serialised: the workspace is already on disk.
`localStorage.removeItem('mibi.vfs')` resets the session (and, without a
folder, the workspace).

## Testing hook

`?send=` feeds URL-encoded bytes through the same `mibi_input` path as a
keyboard, which is useful for smoke tests and for checking a build without a
keyboard:

```
http://localhost:8765/?send=%13                 # Ctrl+S
http://localhost:8765/?send=%0fmibi%0d          # Ctrl+O, type "mibi", Enter
http://localhost:8765/?send=%1b[15~             # F5 (split)
```

`?opfs=1` creates and imports a small directory in the origin private file
system, which exercises the real-folder import/sync path without a native
directory picker. It is for development only.

This is a debug hook, not part of the editor's normal interface.

## Next steps

- Delete and conflict handling for real folders: remove files deleted on disk
  and warn when a file changed outside while it is open.
- OPFS/IndexedDB instead of `localStorage` for large snapshot workspaces.
- A canvas renderer if the terminal-in-a-page look is not what is wanted; the
  cell grid in `src/ui/screen.zig` can be drawn directly.
- LSP over a WebSocket transport, once the native client exists.
