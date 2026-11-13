// The web build tested as the page uses it: the real mibi.wasm, driven
// through host.js, with folder.js syncing an in-memory folder. Run after
// `zig build web`:
//
//   node --test web/test/
//
// MIBI_WASM points at another build of the module.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { Editor, decodeText } from "../site/host.js";
import { FolderSync } from "../site/folder.js";
import { DirHandle } from "./memfs.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));
const wasm = await readFile(process.env.MIBI_WASM || root + "zig-out/web/mibi.wasm");

const CTRL_S = "\x13";
const text = (bytes) => new TextDecoder().decode(bytes);

/** A fresh editor, what it draws, and the clock it runs on. */
async function start({ seed = () => {}, cols = 100, rows = 30 } = {}) {
  const clock = { ms: 1000 };
  const editor = await Editor.load(wasm, { now: () => clock.ms, log: () => {} });
  let screen = "";
  const show = (bytes) => {
    screen += text(bytes);
    return bytes;
  };
  editor.onFrame = show;
  seed(editor);
  editor.init(cols, rows);
  return {
    editor,
    clock,
    show,
    /** Everything drawn since the last call, escape sequences removed. */
    drawn() {
      const plain = screen.replace(/\x1b\[[0-9;?<>=]*[ -\/]*[@-~]/g, "").replace(/\x1b\][^\x07]*\x07/g, "");
      screen = "";
      return plain;
    },
    type(data) {
      editor.input(data);
    },
    /** Let time pass and run the idle tick, as the page's timer does. */
    idle(ms = 600) {
      clock.ms += ms;
      editor.tick();
    },
    tab() {
      return text(editor.current().bytes);
    },
  };
}

test("starts, draws the alternate screen, and opens the welcome file on a first visit", async () => {
  const t = await start({ seed: (e) => e.put("/welcome.txt", "hello from the welcome file\n") });
  assert.match(t.drawn(), /hello from the welcome file/);
  assert.equal(t.editor.current().name, "welcome.txt");
});

test("typing and saving write through with the file's own line endings", async () => {
  const t = await start({ seed: (e) => e.put("/workspace/notes.txt", "one\r\ntwo\r\n") });
  assert.ok(t.editor.open("/workspace/notes.txt"));
  t.type("zero ");
  t.type(CTRL_S);
  assert.equal(t.editor.readText("/workspace/notes.txt"), "zero one\r\ntwo\r\n");
  assert.equal(t.tab(), "zero one\r\ntwo\r\n");
});

test("commands run by name, and an unknown one is an error", async () => {
  const t = await start();
  t.editor.command("new_tab");
  t.drawn();
  t.editor.command("format");
  assert.match(t.drawn(), /Save the file first/);
  assert.throws(() => t.editor.command("no_such_command"), /no such command/);
});

test("a formatter reports that a page cannot run programs", async () => {
  const t = await start({
    seed: (e) => {
      e.put("/workspace/mibi.ini", "[format]\nzig = zig fmt --stdin\n");
      e.put("/workspace/a.zig", "const a=1;\n");
    },
  });
  t.editor.open("/workspace/a.zig");
  t.drawn();
  t.editor.command("format");
  assert.match(t.drawn(), /Could not start the formatter \(not available in this/);
});

test("a lone ESC waits for the flush, as on a terminal", async () => {
  const t = await start();
  t.type("\x1b");
  assert.equal(t.editor.pending, true);
  t.editor.flush();
  assert.equal(t.editor.pending, false);
});

test("the session survives a reload: tabs and unsaved text come back", async () => {
  const a = await start({ seed: (e) => e.put("/workspace/a.txt", "saved text\n") });
  a.editor.open("/workspace/a.txt");
  a.type("unsaved ");
  a.editor.checkpoint();
  assert.ok(a.editor.dirty);
  const blob = a.editor.serialize(true);

  const b = await start({ seed: (e) => assert.ok(e.deserialize(blob)) });
  assert.equal(b.editor.current().name, "a.txt");
  assert.equal(b.tab(), "unsaved saved text\n");
  assert.equal(b.editor.readText("/workspace/a.txt"), "saved text\n", "the file itself was never saved");
});

test("a damaged session blob is refused and changes nothing", async () => {
  const a = await start({ seed: (e) => e.put("/workspace/a.txt", "x") });
  const blob = a.editor.serialize(true);
  const b = await start({ seed: (e) => assert.equal(e.deserialize(blob.slice(0, blob.length - 1)), false) });
  assert.equal(b.editor.has("/workspace/a.txt"), false);
});

test("without the workspace, the blob keeps only the session", async () => {
  const t = await start({ seed: (e) => e.put("/workspace/big.txt", "x".repeat(10000)) });
  t.editor.checkpoint();
  assert.ok(t.editor.serialize(false).length < t.editor.serialize(true).length - 9000);
});

// --- real folders ------------------------------------------------------------

async function withFolder(files) {
  const dir = new DirHandle("project");
  for (const [rel, data] of Object.entries(files)) dir.writeText(rel, data);
  const t = await start();
  const sync = new FolderSync(t.editor, dir);
  const report = await sync.scan();
  t.editor.track(true);
  return { ...t, dir, sync, report };
}

test("a folder is read in, skipping binary files and heavy directories", async () => {
  const t = await withFolder({
    "README.md": "# hi\n",
    "src/main.zig": "const x = 1;\n",
    "logo.png": new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0, 1, 2]),
    "node_modules/dep/index.js": "x",
  });
  assert.deepEqual(t.report, { added: 2, changed: 0, removed: 0, skipped: 1 });
  assert.equal(t.editor.readText("/workspace/src/main.zig"), "const x = 1;\n");
  assert.equal(t.editor.has("/workspace/logo.png"), false);
  assert.equal(t.editor.has("/workspace/node_modules/dep/index.js"), false);
  assert.deepEqual(t.editor.takeChanged(), [], "reading the folder in is not a change to write back");
});

test("a save is written to the folder", async () => {
  const t = await withFolder({ "a.txt": "alpha\n" });
  t.editor.open("/workspace/a.txt");
  t.type("new ");
  t.type(CTRL_S);
  const r = await t.sync.push();
  assert.deepEqual(r.written, ["a.txt"]);
  assert.equal(t.dir.readText("a.txt"), "new alpha\n");
  assert.deepEqual(await t.sync.scan(), { added: 0, changed: 0, removed: 0, skipped: 0 }, "our own write is not news");
});

test("a new file saved into a new directory creates both", async () => {
  const t = await withFolder({});
  t.editor.open("/workspace/docs/new.md");
  t.type("fresh");
  t.type(CTRL_S);
  await t.sync.push();
  assert.equal(t.dir.readText("docs/new.md"), "fresh");
});

test("a file changed on disk reloads a clean tab", async () => {
  const t = await withFolder({ "a.txt": "before\n" });
  t.editor.open("/workspace/a.txt");
  t.drawn();
  t.dir.writeText("a.txt", "after\n");
  assert.equal((await t.sync.scan()).changed, 1);
  t.idle();
  assert.equal(t.tab(), "after\n");
  assert.match(t.drawn(), /reloaded a\.txt/);
});

test("a file changed on disk leaves a tab with unsaved changes alone", async () => {
  const t = await withFolder({ "a.txt": "before\n" });
  t.editor.open("/workspace/a.txt");
  t.type("mine ");
  t.drawn();
  t.dir.writeText("a.txt", "theirs\n");
  await t.sync.scan();
  t.idle();
  assert.equal(t.tab(), "mine before\n");
  assert.match(t.drawn(), /a\.txt changed on disk; your unsaved changes/);
});

test("a save over a file that changed on disk since it was read is not written", async () => {
  const t = await withFolder({ "a.txt": "before\n" });
  t.editor.open("/workspace/a.txt");
  t.type("mine ");
  // Another program writes after the last scan and before the save lands.
  t.dir.writeText("a.txt", "theirs\n");
  t.type(CTRL_S);
  t.drawn();
  const r = await t.sync.push();
  assert.deepEqual(r.conflicts, ["a.txt"]);
  assert.equal(t.dir.readText("a.txt"), "theirs\n", "the other program's text stays on disk");
  assert.equal(t.tab(), "mine before\n", "ours stays in the tab");
  assert.equal(t.editor.readText("/workspace/a.txt"), "theirs\n");
  assert.match(t.drawn(), /a\.txt changed on disk since it was read/);
  t.idle();
  assert.equal(t.tab(), "mine before\n", "and is not replaced by a reload");

  // Saving again is a deliberate overwrite.
  t.type(CTRL_S);
  const again = await t.sync.push();
  assert.deepEqual(again.written, ["a.txt"]);
  assert.equal(t.dir.readText("a.txt"), "mine before\n");
});

test("files and directories deleted on disk leave the workspace", async () => {
  const t = await withFolder({ "keep.txt": "k", "gone.txt": "g", "old/inner/x.txt": "x" });
  t.dir.delete("gone.txt");
  t.dir.delete("old");
  const r = await t.sync.scan();
  assert.equal(r.removed, 2);
  assert.equal(t.editor.has("/workspace/gone.txt"), false);
  assert.equal(t.editor.has("/workspace/old/inner/x.txt"), false);
  assert.equal(t.editor.has("/workspace/keep.txt"), true);
});

test("a write that fails is kept for the next push", async () => {
  const t = await withFolder({ "a.txt": "a" });
  t.editor.open("/workspace/a.txt");
  t.type("b");
  t.type(CTRL_S);
  const real = t.dir.getFileHandle.bind(t.dir);
  t.dir.getFileHandle = async (name, opts) => {
    if (opts?.create) throw Object.assign(new Error("disk full"), { name: "QuotaExceededError" });
    return real(name, opts);
  };
  const r = await t.sync.push();
  assert.equal(r.failed.length, 1);
  t.dir.getFileHandle = real;
  const again = await t.sync.push();
  assert.deepEqual(again.written, ["a.txt"]);
  assert.equal(t.dir.readText("a.txt"), "ba");
});

test("scans and pushes run one at a time, in order", async () => {
  const t = await withFolder({ "a.txt": "a" });
  t.editor.open("/workspace/a.txt");
  t.type("b");
  t.type(CTRL_S);
  const order = [];
  await Promise.all([t.sync.push().then(() => order.push("push")), t.sync.scan().then(() => order.push("scan"))]);
  assert.deepEqual(order, ["push", "scan"]);
  assert.equal(t.dir.readText("a.txt"), "ba");
});

// --- the site ----------------------------------------------------------------

test("assets.txt lists every language and theme the native build ships", async () => {
  const listed = (await readFile(root + "web/site/assets.txt", "utf8")).replace(/^﻿/, "").split(/\r?\n/).filter(Boolean).sort();
  const want = [
    ...(await readdir(root + "syntax.d")).filter((f) => f.endsWith(".ini")).map((f) => `syntax ${f}`),
    ...(await readdir(root + "themes")).filter((f) => f.endsWith(".ini")).map((f) => `theme ${f}`),
  ].sort();
  assert.deepEqual(listed, want, "run tools/web-assets.ps1");
});

test("decodeText takes UTF-8 text and refuses binary", () => {
  assert.ok(decodeText(new TextEncoder().encode("héllo")));
  assert.equal(decodeText(new Uint8Array([0x68, 0, 0x69])), null);
  assert.equal(decodeText(new Uint8Array([0xff, 0xfe, 0x41])), null);
});
