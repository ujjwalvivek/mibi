# The web build

mibi also runs in a browser. It is the same Zig editor compiled to
WebAssembly, with [xterm.js](https://xtermjs.org/) as the terminal and an
in-memory filesystem in place of the operating system. The text model,
widgets, commands, keys, syntax highlighting and themes are the native ones;
the web build is a platform module, an entry point and a static page.

It is deployed to Cloudflare Pages at <https://mibi.ujjwalvivek.com> by
`.github/workflows/deploy-web.yml`, on every push to `main` that touches the
editor or the page and on every release tag, after the web tests pass.

## Build and run

```powershell
.\build.ps1 web
python -m http.server 8765 --directory zig-out/web
# http://localhost:8765/
```

On Linux and macOS, `zig build web` and `python3 -m http.server` the same way.
Any static server works; the page needs nothing from it but files.

`zig build web` installs the whole site in `zig-out/web`:

| Path | What it is |
| --- | --- |
| `mibi.wasm` | the editor: `wasm32-freestanding`, no libc, about 200 KB |
| `index.html`, `main.js` | the page: toolbar, xterm.js, storage, folders |
| `host.js` | the wasm editor as a JavaScript object; the only caller of its exports |
| `folder.js` | a real folder kept in step with the editor, both ways |
| `storage.js` | the session in the origin private file system (or IndexedDB) |
| `vendor/` | xterm.js 5.5.0, its fit addon, the Maple Mono NF subset, their licences ([web/VENDOR.md](../web/VENDOR.md)) |
| `syntax.d/`, `themes/`, `assets.txt` | the native data files, and the list the page fetches |
| `mibi.ini.example`, `LICENSE` | the default settings, and mibi's licence |
| `_headers` | caching and the wasm content type, for Cloudflare Pages |

Source lives in `web/site/` (served as is), `src/platform/web/` and
`src/web_main.zig`. After adding a language or a theme, run
`tools/web-assets.ps1` to update `web/site/assets.txt`; a test fails until you
do.

## How it fits together

```
src/core, src/ui, src/app        unchanged
src/platform/web.zig             the platform module the wasm build selects
src/platform/web/vfs.zig         the in-memory filesystem (no host calls; native tests)
src/platform/web/os.zig          the platform interface over it, plus three host calls
src/web_main.zig                 the exports the page calls: the loop, inverted
web/site/host.js                 those exports as an Editor object
web/site/folder.js, storage.js   real folders and persistence
web/site/main.js, index.html     the page
```

The native loop blocks in `poll`; a page cannot. The page calls in with each
event instead (`mibi_input` with the bytes from xterm.js `onData`,
`mibi_resize`, `mibi_tick` every 500 ms, `mibi_flush` 30 ms after an
unfinished escape sequence) and writes each frame that comes back to xterm.js.
The input is decoded by the same `ansi.Decoder` as on Unix, so the editor sees
the bytes a terminal would send. xterm.js already speaks everything the
renderer writes: the alternate screen, SGR mouse reports, focus reports,
bracketed paste and true colour. The page turns the editor's OSC 52 copy into
a clipboard write and its OSC 2 title into `document.title`.

`host.js` hands every frame to one callback, whoever caused it. The renderer
sends only what changed since the last frame, so a frame that never reached
xterm.js would leave the screen wrong; one path for frames makes that
impossible.

## Files

The editor sees one filesystem:

```
/workspace/      the user's files: a real folder, or imported files
/state/          the session: tabs, panes, cursors, unsaved text
/mibi.ini        default settings, as shipped next to the native binary
/syntax.d/, /themes/   fetched from the site on every load, never stored
/welcome.txt     the first visit's tab
```

`/workspace` is the working directory, so a `mibi.ini` there wins over
`/mibi.ini`, as natively.

### A real folder (Chromium-based browsers)

**Open folder** uses `showDirectoryPicker`. The folder is read into
`/workspace` (text files only: binary files, files over 4 MB and `.git`,
`node_modules`, build output and similar directories are skipped; at most
5,000 files). From then on `folder.js` keeps the two in step:

- **Saves go to disk** about 300 ms later, through `createWritable`, which
  writes a swap file and replaces the original whole. The filesystem records
  each `/workspace` path the editor writes or deletes; reading the folder in
  is never recorded, so it is never written back.
- **Changes made elsewhere come in.** The folder is checked every 2.5 seconds
  while the page is visible, and when it regains focus. A new or changed file
  is read in and gets a new stamp; the editor's own idle tick then does what
  it does natively: a clean tab reloads, a tab with unsaved changes keeps them
  and says the file changed on disk. Deleted files and directories leave the
  workspace.
- **A save never overwrites someone else's change.** Before writing, the size
  and modification time on disk are compared with what was last read. If the
  file changed since (another program saved between two checks), the save is
  not written: the folder's version comes into the editor, the tab goes back
  to unsaved with the user's text in it, and the status line says so. Saving
  again is then a deliberate overwrite. Deleting works the same way.
- **Failures are kept.** A write that fails (quota, a locked file) goes back
  on the list and is tried with the next one; the status line says so. If the
  browser withdraws permission while the folder is open, the toolbar offers
  **Reconnect**, and saves made meanwhile go out after it. If the folder
  disappears, tabs keep their text.

Folder checks and writes never run at once: each waits for the one before.

The folder is remembered (its handle, in IndexedDB) and opens again on the
next visit. When the browser wants permission again first, the page asks
before the editor starts: open the folder, or use the browser's own files.
**Close folder** goes back to the browser's files.

### Without a real folder

**Open files**, **Open folder** (in browsers without the picker) and dropping
files on the page import copies into `/workspace`. They stay in this browser
with the session. **Download** writes the focused file out.

## Storage

Every workspace has its own session, as every working directory does
natively: the browser's own files are one workspace, and each real folder
another. Opening a different folder, or closing one, saves everything and
reloads the page into the other workspace. A tab restored in the wrong folder
could otherwise save one project's text into another. Folders are told apart
with `isSameEntry`, the only comparison the API offers, so each folder ever
opened is remembered with a random id.

A workspace's session is one blob: the persisted files serialised by
`Vfs.serialize` (`MIBIVFS1`: a count, then path and data pairs). With a real
folder only `/state` is in it; without one, the workspace too. It goes to
`mibi-<workspace>.bin` in the origin private file system, or IndexedDB where a
page cannot write OPFS files. `/mibi.ini` is kept once, apart from the
sessions, so settings follow you between workspaces. Writes queue behind each
other, so an older blob never lands after a newer one. It is written at most once a second
while something changes, and when the page is hidden (the last moment a
closing tab can be relied on). Before that, the session is saved into the
filesystem (`mibi_checkpoint`), not left for the next autosave. The page asks
the browser to keep the storage persistent. A blob that does not parse whole is
ignored rather than half-loaded. The first run moves an old `localStorage`
session over and deletes it.

Only one tab runs the editor (a Web Lock). A second tab offers to take over;
the first then saves and stops, so two never overwrite each other's session.

## What is different from native

| | Web |
| --- | --- |
| Editing, tabs, splits, search and replace, the tree, pickers, themes, mouse, paste, wrap, session | the same |
| Files | a real folder in Chromium-based browsers; imported copies elsewhere |
| Formatters (`F4`) and the filter (`Alt+X`) | "not available in this build": a page cannot run programs |
| Kitty keyboard protocol | no effect: xterm.js does not implement it |
| Keys the browser keeps | `Ctrl+W`, `Ctrl+T`, `Ctrl+N` and a few more never reach the page; the toolbar has every editor key that matters |
| `Ctrl+Q` | saves the session and shows a Reopen button; a page cannot close its tab |
| Font | a bundled subset of Maple Mono NF, so the tree's icons need no installed font |

## Tests

```sh
zig build test-web                  # the filesystem, natively (part of zig build test)
zig build web
node --test web/test/web.test.mjs   # the page's own code, on the real mibi.wasm
```

The Node tests load the built `mibi.wasm` through `host.js` and drive it as
the page does: typing, saving, line endings, the session across a reload, a
damaged blob, and `folder.js` against an in-memory folder that implements the
same handle API (`web/test/memfs.mjs`): reading a folder in, saves, new
directories, outside changes to clean and dirty tabs, the save conflict,
deletions, failed writes and ordering. CI runs them on Linux, macOS and
Windows; the size gate holds `mibi.wasm` to its budget.

`?send=` feeds URL-encoded bytes in as if typed, for checking a deployed
build: `?send=%0f` is `Ctrl+O`.
