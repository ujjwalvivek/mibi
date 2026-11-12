# mibi architecture: decisions for the rebuild

Status: **accepted**, 2026-11-12; step 2 (the core) is built. This record reassesses the design from phase 0
up. It says what stays, what is replaced, and why, and it fixes the order of
the work. It supersedes section 3 of the local `PLAN.md`; the product scope in
that plan (ox-lite, no plugins, no embedded terminal) is unchanged.

## Where the code stands

Measured at `d57e27a` (2026-11-06), the newest commit on GitHub.

| Fact | Evidence |
| --- | --- |
| Only Windows compiled | `src/term.zig` passed a `u32` poll timeout where `std.posix.poll` takes `i32`; every Linux and macOS target failed |
| Tests could not run on Unix | the test module in `build.zig` did not link libc |
| 2 of 136 tests were Windows-only by accident | one wrote into `experiments/out/screens/`, one expected `findstr` output from `cat -n` |
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
  in `experiments/README.md`.
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

`core` and `ui` each get their own test step whose module graph does not
include `platform`, so an import in the wrong direction fails to compile
instead of being caught in review. This is also what makes the editor testable
without a terminal: a UI test feeds events and reads the cell grid.

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

`platform/input` produces one type on every OS:

```zig
const Event = union(enum) {
    key: struct { code: KeyCode, mods: Mods },
    text: []const u8,       // typed or pasted, already UTF-8
    paste: []const u8,      // bracketed paste, one undo step
    mouse: Mouse,
    resize: Size,
    focus: bool,
    tick,
};
```

Windows builds events directly from console records. Unix has a decoder that is
a pure function over bytes, fuzzed with split and malformed sequences. The
keymap matches `Event.key` against bindings without building a string per key.

### 7. One command table

`keys.Action` already names 45 actions, but the default bindings, the palette
entries, the help text and the dispatch `switch` are four separate lists in
`main.zig`. A single table (`id`, title, default keys, function) generates all
four, and `[keys]` in `mibi.ini` only overrides it.

### 8. Widgets with a focus stack

Input handlers thread `running`, `prompt`, `help`, `msg_buf`, `msg` and
`view_rows` through every call. Each widget becomes a struct with
`handle(event) bool` and `draw(grid, rect)`; the app keeps a focus stack
(prompt, picker, help, tree, panes) and offers each event from the top down.
App-wide state (status message, config, quit flag) lives in one `App` struct.

### 9. The regex engine the plan chose

The plan locked a Pike VM: linear time, no backtracking blow-up. What shipped
is a backtracking VM with a step cap, so a hostile or unlucky pattern silently
stops matching. The parser and bytecode stay; the executor becomes a Pike VM
with the same capture semantics, checked against the existing tests plus the
classic `(a*)*b` cases.

### 10. A real allocator

`std.heap.page_allocator` is the general allocator in 38 places. It maps at
least one page per allocation and makes a system call each time. It was chosen
because it costs zero bytes. The rebuild uses an arena that is reset every
frame for drawing and input scratch, and one long-lived allocator for
documents; `experiments/` gets a probe for the size cost of
`std.heap.smp_allocator` against a small free-list allocator before one is
picked.

### 11. Every platform is checked on every change

CI runs the unit tests on Linux, macOS and Windows and the size gate on all
five targets. The screen tests move from ConPTY-only Python to an in-process
harness (events in, cell grid out) that runs everywhere, with a thin
real-terminal smoke test per OS for the platform layer.

## Not changing, on purpose

- No embedded terminal. `src/pty.zig` is deleted in the rebuild.
- No plugins, LSP or tree-sitter in v1.
- No rope, no tree-structured piece table, until the benchmark asks for one.
- The on-disk formats (`mibi.ini`, `themes/*.ini`, `syntax.d/*.ini`, session
  file) keep working.

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

## Order of work

Each step ends with all tests green on three platforms and the size gate
passing. The old code keeps working until the step that replaces it lands.

1. **Baseline** (done): build fixes, portable tests, CI, this record.
2. **Core** (done): buffer, document, view, selections, transactions, undo,
   search, Pike VM, in `src/core/` with its own test step. Width and UTF-8
   moved in unchanged. Model-based fuzz tests for buffer and undo. The syntax
   lexer moves in at the start of step 3, with the pane that draws it.
3. **Platform and UI:** typed events, command table, widgets, app loop. Features
   are ported in the plan's phase order (terminal and render, core editing,
   documents and UI, ox-lite), each with in-process screen tests. `main.zig`
   shrinks to the entry point and `pty.zig` goes.
4. **Phase 6 and release:** bracketed paste, soft wrap, atomic save, bracket
   matching, line operations and comment toggle from the plan's v1 list,
   packaging, README and changelog rewritten from the code, tagged release.

## Open questions

- Kitty keyboard protocol: it would make `Ctrl+Shift` chords and `Esc`
  unambiguous on terminals that support it. Proposed as opt-in after step 3.
