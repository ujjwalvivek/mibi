# mibi architecture: decisions for the rebuild

Status: **accepted**, 2026-11-12; all four steps are built and released as v0.1.0. This record reassesses the design from phase 0
up. It says what stays, what is replaced, and why, and it fixes the order of
the work. It supersedes section 3 of the local `PLAN.md`; the product scope in
that plan (ox-lite, no plugins, no embedded terminal) is unchanged.

## Where the code stands

Measured at `d57e27a` (2026-11-06), the newest commit on GitHub.

| Fact | Evidence |
| --- | --- |
| Only Windows compiled | `src/term.zig` passed a `u32` poll timeout where `std.posix.poll` takes `i32`; every Linux and macOS target failed |
| Tests could not run on Unix | the test module in `build.zig` did not link libc |
| 2 of 136 tests were Windows-only by accident | one wrote into a probe output directory, one expected `findstr` output from `cat -n` |
| No CI | no `.github/`; the size gate and screen tests are PowerShell and ConPTY only |
| `src/main.zig` is 4,506 of 12,108 lines | input decoding, prompts, session file, mouse, tabs, tree, pickers, help and all drawing in one file; 67 of the tests live there |
| The plan and the repo disagree | `PLAN.md` describes v0.0.4; more than ten commits were reverted, leaving the repo between v0.0.2 and v0.0.3 with `src/pty.zig` still in it. Phase 5b and 6 are rebuilt from the plan, not recovered |

The first four are fixed: all five targets build, the old tests pass on
Linux, and CI now runs the tests on three platforms plus the size gate. Sizes after the fix: 143,880 to 215,040 bytes, all under budget.

The lesson is the first decision below: "cross-platform" was a claim nobody
checked, because the project is developed on Windows and nothing else ran.

## What stays

These were good decisions and the measurements still hold.

- **Zig 0.16, std only, no dependencies.** The size floor and the two 480 KB
  traps (`main` returning an error, `std.Io.Threaded`) are real and documented
  in [SIZE.md](SIZE.md).
- **A raw OS layer** (`os.zig`): kernel32 on Windows, libc on Unix.
- **A cell grid with a diff** as the renderer.
- **Data, not code,** for languages (`syntax.d`), themes and config (INI).
- **The generated Unicode width table.**
- **The split tree over a fixed pool,** and the fuzzy matcher.
- **The 1 MB ceiling** with per-target regression budgets.

## What is replaced

### 1. Three layers with a rule the build enforces

Today every module may call the OS, and `main.zig` reaches into everything.

```
src/core/      text model. No OS, no terminal, no globals.
               buffer, document, view, selections, edit transactions,
               undo, search, regex, syntax, width, utf8
src/ui/        widgets. Read core, draw into a cell grid, take events.
               No OS calls.
               editor pane, tabs, tree, picker, prompt, help, status, layout
src/platform/  os, terminal, input decoding, clipboard, file stamps, spawn
src/app.zig    owns the state, runs the loop, maps events to commands
src/main.zig   entry point only
```

As built, each layer is a module in `build.zig`, and a Zig file cannot import
a path outside its own module, only the modules it was given:

| Module | Root | May import |
| --- | --- | --- |
| `core` | `src/core/core.zig` | nothing |
| `ui` | `src/ui/ui.zig` | `core` |
| `platform` | `src/platform/platform.zig` | `ui`, for the event types it produces |
| application | `src/main.zig` | all three |

An import in the wrong direction is a compile error, not a review comment.
Each module is also a test binary (`zig build test-core`, `test-ui`,
`test-platform`, `test-app`; `zig build test` runs all four). This is what
makes the editor testable without a terminal: a test feeds events and reads
the cell grid.

### 2. A buffer that never copies the document

`Buffer.flat()` rebuilds a contiguous copy of the whole file and the whole line
index after every edit. 14 call sites in `editor.zig` depend on it. Typing in a 100 MB file
copies 100 MB per keystroke; that is the opposite of what a piece table is for.

The piece table stays, with three changes:

- **Line indexes on the sources, not on the document.** Both sources are
  immutable or append-only (`original` never changes, `add` only grows), so the
  offset of every newline in each can be recorded once and never invalidated.
  Each piece carries its newline count. Finding line N is a walk over piece
  counts, then a binary search in that source's index. No rebuild, ever.
- **Reads go through pieces.** `lineSlice(row, scratch)` returns a slice into
  the source when the line sits inside one piece (the common case) and copies
  into the caller's scratch only when it spans pieces. Search and save iterate
  pieces. `flat()` is deleted.
- **Typing coalesces.** An insert that continues the previous one extends that
  piece instead of adding a new one, so the piece count follows the number of
  edit *sites*, not keystrokes. `delete` edits the list in place rather than
  building a new list each time.

The list stays an array. A balanced tree would make edits O(log pieces), but
with coalescing the count stays in the hundreds for real sessions, and an array
is half the code. The fuzz test against a reference string carries over and
gains a line-index check per step; a benchmark with 100,000 edit sites decides
whether the tree is ever needed.

### 3. Edits are transactions; undo replays them

Undo currently stores a full copy of the piece list per step (up to 512 of
them), and restores nothing but text: the cursor lands wherever it happens to
be valid.

Every change becomes a `Transaction`: a list of `{pos, removed, inserted}`
where both sides are spans into the append-only buffers, plus the selections
before and after. Undo applies the inverse and restores the selections. Cost is
proportional to the edit, not to the document. Grouping (a run of typing is one
step) becomes a property of the transaction, with a time gap as the plan
specified.

### 4. Selections are a list; the single cursor is the list of length one

Multi-cursor was added beside the single cursor: `cursor` plus `cursors`, with
`moveLeft` / `moveLeftOne`, `backspace` / `backspaceOne` pairs, and extra
cursors that cannot hold a selection. Every new command has to be written
twice.

A view holds `[]Selection` (`anchor`, `head`, preferred column). Every command
maps over the list and merges overlaps afterwards. One code path, extra cursors
get selections for free, and "select next occurrence" becomes a few lines.

### 5. Document and view are different things

`Editor` holds both the file (buffer, undo, path, syntax cache) and one way of
looking at it (cursor, scroll). Splits work around this by copying
`view_cursor` / `view_row` / `view_col` in and out of the pane node.

`Document` owns the text, history, path, disk stamp, language and syntax cache.
`View` owns selections, scroll and wrap state, and points at a document. A pane
holds a view. An edit in one view shifts the selections of the others through
the transaction, so two panes on one file stay correct without special cases.

### 6. Typed events instead of bytes

`main.zig` parses a byte stream, and the Windows backend converts console
records *into* ANSI bytes so that the same parser can read them back. Mouse,
paste, focus and resize all pass through that.

As built (`src/ui/event.zig`), there is one type on every OS:

```zig
const Event = union(enum) {
    key: Key,            // codepoint or named key, plus ctrl/alt/shift
    mouse: Mouse,        // press, release, drag, wheel; button, cell, mods
    paste: []const u8,   // bracketed paste, one undo step
    focus: bool,
    resize,
};
```

Unix has a decoder (`platform/ansi.zig`) that is a pure function over bytes:
it holds back half a sequence until the rest arrives, and is fuzzed with split
and malformed input. Windows builds events directly from console records
(`platform/win_input.zig`); the translation takes plain structs rather than
kernel32 types, so it is tested on every platform. The keymap matches keys
against bindings without building a string per key. There is no `tick` event:
the loop calls `app.tick()` when input has been quiet for half a second.

### 7. One command table

`keys.Action` already names 45 actions, but the default bindings, the palette
entries, the help text and the dispatch `switch` are four separate lists in
`main.zig`. A single table (`id`, title, default keys, function) generates all
four, and `[keys]` in `mibi.ini` only overrides it.

### 8. Widgets, and one place that owns the state

Input handlers threaded `running`, `prompt`, `help`, `msg_buf`, `msg` and
`view_rows` through every call. Now each widget in `src/ui/` is a struct that
takes events and draws into a rectangle of the cell grid, and knows nothing
else. App-wide state (documents, panes, status message, config, quit flag)
lives in one `App` struct, which offers a key to whatever is on top: picker,
then prompt, then the file tree when it has focus, then the keymap, then the
text. That order is five lines in `App.handleKey`; a general focus stack was
planned and turned out not to be needed for a fixed set of overlays.

### 9. The regex engine the plan chose

The plan locked a Pike VM: linear time, no backtracking blow-up. What shipped
is a backtracking VM with a step cap, so a hostile or unlucky pattern silently
stops matching. The parser and bytecode stay; the executor becomes a Pike VM
with the same capture semantics, checked against the existing tests plus the
classic `(a*)*b` cases.

### 10. A real allocator

`std.heap.page_allocator` was the general allocator in 38 places. It maps at
least one page per allocation and makes a system call each time. It was chosen
because it costs zero bytes. As built (`platform/heap.zig`): libc `malloc` on
Unix, which is linked for termios anyway, and the process heap (`HeapAlloc`)
on Windows, which links no libc. Both cost a few hundred bytes of glue. The
per-frame arena that was planned is not there: drawing allocates one scratch
line per pane, which did not justify a second allocator.

### 11. Every platform is checked on every change

CI runs the unit tests on Linux, macOS and Windows and the size gate on all
five targets. The screen tests moved from ConPTY-only Python to an in-process
harness (`src/app/test.zig`: events in, cell grid out) that runs everywhere.
One of them fails every allocation in turn across a long editing scenario and
checks that nothing crashes or leaks. `tools/smoke.py` then runs the built binary in a pseudo-terminal on Linux and
macOS and checks what no in-process test can: raw mode, real escape sequences,
a resize, a save, and the terminal handed back on exit. Windows has no pty to
script from CI; there the platform layer is covered by the translator tests.

## Not changing, on purpose

- No embedded terminal. `src/pty.zig` is deleted in the rebuild.
- No plugins, LSP or tree-sitter in v1.
- No rope, no tree-structured piece table, until the benchmark asks for one.
- The on-disk formats `mibi.ini`, `themes/*.ini` and `syntax.d/*.ini` keep
  working. The session file is the exception: it is a new format (version 2,
  plain lines, one per tab and pane) and an old session is ignored once.

## What the core looks like now

Step 2 is in `src/core/`, about 5,100 lines with tests (width table included), and compiles on its
own (`zig build test-core`) with no libc and no OS layer.

| File | What it is |
| --- | --- |
| `buffer.zig` | Piece table. One primitive, `splice`, that cannot fail once capacity is reserved. Newline indexes on the two stores; no document copy. |
| `history.zig` | Transactions of changes that reference store spans. Undo is the same splice reversed. Typing merges within one second. Tracks the saved state, so undoing back to it clears the dirty flag. |
| `document.zig` | Buffer plus history. `edit` takes a list of edits and applies them all or not at all. Observers are told about every change. |
| `selection.zig` | Anchor and head; sorting and merging of a selection list. |
| `view.zig` | Selections, scroll, and every editing command, each written once for any number of cursors. |
| `text.zig` | Cells and columns, cursor boundaries that keep combining marks with their base, word classes, line-ending detection. |
| `regex.zig` | Parser, compiler and Pike VM. Streams chunks; syntax errors carry a position and a reason. |
| `search.zig` | Find, find previous, replace all. Plain search is the same engine with the needle escaped. |

Decisions made while building it, beyond the list above:

- **Line endings are normalised on load.** A document is always `\n` in
  memory and remembers whether the file was CRLF, to write it back the same
  way. The old code carried `\r` through every column calculation.
- **Failure is handled by reserving first.** An edit reserves room in the
  piece list and the history, then performs steps that cannot fail. There is
  no rollback code, because there is nothing to roll back. Every module has a
  test that fails each allocation in turn and checks nothing changed.
- **Tests build in Debug.** They used to inherit `ReleaseSmall`, which turns
  off the bounds, overflow and aliasing checks. Switching found an aliasing
  `@memcpy` in `config.zig` the same day.
- **Cursor movement is by displayed character,** not by codepoint: a base
  letter and its combining marks are one stop. Full grapheme clusters (emoji
  joined with ZWJ) are not handled yet.
- **Word characters include everything outside ASCII,** in movement, whole-word
  search and `\b` alike, so the three agree.

## What sits on the core now

| Where | What it is |
| --- | --- |
| `core/ini.zig`, `syntax.zig`, `highlight.zig` | The INI reader, the lexer driven by `syntax.d`, and a per-document cache of the lexer state at each line start, dropped from the first changed line down. |
| `ui/event.zig` | Keys, mouse, paste, focus, resize; key names as written in `mibi.ini`. |
| `ui/screen.zig` | Cells, styles, rectangles, and the diff. A changed row is repainted whole, so a glyph the terminal draws wider than expected heals on the next change. |
| `ui/layout.zig` | The split tree: stable pane ids, at most eight panes. |
| `ui/editor_pane.zig`, `tabbar.zig`, `picker.zig`, `line_edit.zig`, `theme.zig` | The widgets. |
| `platform/os.zig`, `heap.zig` | Files, directories, child processes, the clock, the allocator. |
| `platform/term.zig`, `ansi.zig`, `win_input.zig` | Raw mode, the alternate screen, signals, and input as events. |
| `commands.zig` | The one table: command, title, default keys, whether the palette lists it. Bindings, palette and help are generated from it. |
| `config.zig`, `langs.zig` | `mibi.ini`, themes and `syntax.d` read from disk into the pure types. |
| `app.zig`, `app/*.zig` | The editor: documents and panes, prompts, pickers, mouse, drawing, the file tree, the formatter, reload from disk, the session. |
| `main.zig` | Arguments, start-up, the run loop, and restoring the terminal on every way out. 245 lines, from 4,506. |

Decisions made while building it:

- **A pane owns a view; a document may be in several panes.** Each view has
  its own cursors and scroll. A tab remembers where its last view was.
- **Scrolling is not moving.** The view scrolls to the cursor only after a
  command or an edit, so the wheel can look elsewhere without dragging the
  cursor along.
- **Errors become status messages.** `App.handle` cannot fail: out of memory
  or a failed save is said in the status line and the editor carries on.
- **The app has no clock and no terminal.** The loop sets `now_ms` and writes
  out whatever the app queued (window title, clipboard), so tests are exact.
- **Unix terminals are asked for the mouse, focus and bracketed paste.** The
  old code only had a mouse on Windows.
- **A closed terminal saves the session.** SIGHUP and SIGTERM leave through
  the normal exit path; the Windows close button calls the same save.
- **Selections that end at the start of a line do not include that line** in
  indent, comment and move-line commands, as in other editors.
- **Soft wrap is a property of the view, computed on demand.** There is no
  cache of wrapped lines to invalidate: `core/text.zig` folds one line at a
  time, and only the lines on screen (or stepped over by the cursor) are
  folded. The scroll position is a line plus a row inside it.
- **Help is F1 only.** `ctrl+/` toggles a line comment.
- **Sizes grew by about 40 KB** (172,680 to 249,856 bytes across the five
  targets, budgets reset with 5% headroom). The old binary did less.

## Order of work

Each step ends with all tests green on three platforms and the size gate
passing. The old code keeps working until the step that replaces it lands.

1. **Baseline** (done): build fixes, portable tests, CI, this record.
2. **Core** (done): buffer, document, view, selections, transactions, undo,
   search, Pike VM, in `src/core/` with its own test step. Width and UTF-8
   moved in unchanged. Model-based fuzz tests for buffer and undo. The syntax
   lexer moves in at the start of step 3, with the pane that draws it.
3. **Platform and UI** (done): typed events, command table, widgets, app
   loop, each feature with in-process screen tests. `main.zig` is the entry
   point; `pty.zig`, the old `editor.zig`, `buffer.zig`, `regex.zig`,
   `render.zig` and `keys.zig` are gone.
4. **Phase 6 and release:** bracketed paste, soft wrap, atomic save, line
   operations, comment toggle, bracket matching, the command filter and
   packaging (`tools/package.sh`, a release workflow on tags) are done.
   Released as v0.1.0.

## Open questions

- None recorded.

The kitty keyboard protocol, open at the time of the rebuild, is built as the
opt-in `kitty_keys` setting. The terminal is asked for disambiguated escape
codes and event types (`CSI > 3 u`) while the alternate screen is up, and the
push is undone on every exit path (`CSI < u`). `Esc` then arrives as
`CSI 27u`, so the decoder's lone-ESC timeout only matters on terminals that do
not implement the protocol.

## The web build

The browser build is the same four layers. Only the platform module and the
entry point are its own; `build.zig` compiles `core`, `ui` and the app for
`wasm32-freestanding` with `src/platform/web.zig` in place of
`src/platform/platform.zig`. Nothing in `core`, `ui` or `src/app` knows which
one it got. [WEB.md](WEB.md) has the details; these are the decisions.

- **The terminal stays the interface.** The editor already writes a cell
  grid as ANSI and reads input as terminal bytes, and xterm.js speaks both:
  the alternate screen, SGR mouse, focus, bracketed paste, true colour. So the
  page feeds xterm.js `onData` into the same `ansi.Decoder` Unix uses and
  writes frames back. No renderer or widget changed. A canvas renderer of the
  cell grid stays possible later; it was not needed to get parity.
- **Freestanding wasm, not WASI.** A page is not a POSIX process; WASI would
  add a shim layer to emulate files and a clock the browser does not have,
  and still leave the loop to invert. The module imports three functions
  (clock, console, exit) and exports the rest.
- **The loop is inverted, not emulated.** `src/main.zig` blocks in `poll`;
  `src/web_main.zig` exports one function per event (`mibi_input`,
  `mibi_resize`, `mibi_tick`, `mibi_flush`) with the same handling, burst
  cap and autosave cadence, and each leaves a frame. The ABI is numbers and
  pointers only; variable-length results come back through one result buffer.
  `web/site/host.js` is its only caller and hands every frame to one callback,
  because a dropped diff frame would leave the screen wrong.
- **The filesystem lives in the module.** `platform/web/vfs.zig` holds files
  by absolute path with stamps, and implements the platform interface the app
  already uses (read, atomic write, delete, list, stamp). Writes carry an
  origin: the editor's writes to `/workspace` are recorded for a real folder,
  the page's (assets, imports, a folder read in) never are, so nothing is
  written back that came from there. The VFS makes no host calls, so it is
  tested natively in `zig build test`.
- **A real folder is kept in step, not mounted.** The File System Access API
  is asynchronous and the editor's file calls are not, so the folder is
  mirrored: read in, checked for changes every few seconds, and written to
  after saves. Outside changes then reach the editor exactly as on native,
  through stamps and its idle reload. Before a write, the file's size and
  modification time are compared with what was last read; a file changed
  since is not overwritten, and the tab goes back to unsaved instead. That is
  stricter than native, whose save simply wins, because here a few seconds
  separate the last look from the write.
- **Storage is OPFS, one blob per workspace.** The session (and, without a
  real folder, the workspace) is serialised whole and written with
  `createWritable`, which swaps the file in atomically; IndexedDB holds it
  where a page cannot write OPFS files. `localStorage` was a 5 MB,
  string-only, synchronous limit. Each real folder has its own session, as
  each working directory does natively, and switching folders reloads the
  page: a session restored over the wrong folder could save one project's
  text into another. One Web Lock keeps a second tab from overwriting the
  first tab's session.
- **xterm.js is the one dependency, and only on the web side.** The Zig
  build still has none. xterm.js (MIT) and the Maple Mono NF subset (OFL-1.1)
  are vendored under `web/site/vendor` with their licences, served with the
  site, so a build needs no network. Writing a terminal emulator for the page
  would be a second editor-sized project for no gain in the editor.
- **Same budgets.** `mibi.wasm` is held to a size budget in the size gate
  like every native target (about 200 KB, under the 1 MB ceiling), and the
  web tests run in CI on all three systems: the Zig VFS tests, and Node tests
  that drive the built module through `host.js` and `folder.js` against an
  in-memory folder with the same handle API.
