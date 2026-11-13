// The page: xterm.js in front of the wasm editor. Keys and mouse go in as the
// bytes a terminal would send, frames come back as ANSI and go to xterm.js.
// The rest is what a browser has instead of an operating system: storage for
// the session (storage.js), a real folder or imported files for /workspace
// (folder.js), and buttons for the keys the browser keeps for itself.
//
// One workspace per page load. The files kept in the browser and each real
// folder have their own session, so switching between them reloads the page
// into the other one, as starting mibi in another directory does natively.

import { Editor, decodeText } from "./host.js";
import { FolderSync } from "./folder.js";
import { openStore, folderKey, kvGet, kvSet } from "./storage.js";

const PERSIST_MS = 1000; // at most this often while typing, and on hide
const SCAN_MS = 2500; // how often a real folder is checked for changes
const PUSH_MS = 300; // how soon a save reaches the real folder
const ESC_MS = 30; // native's escape wait

const $ = (id) => document.getElementById(id);
const ui = {
  overlay: $("overlay"),
  overlayTitle: $("overlay-title"),
  overlayText: $("overlay-text"),
  overlayButton: $("overlay-button"),
  overlayAlt: $("overlay-alt"),
  closeFolder: $("close-folder"),
  help: $("help"),
  fileInput: $("file-input"),
  folderInput: $("folder-input"),
  folderAction: $("folder-action"),
  hint: $("hint"),
};

let editor = null;
let term = null;
let fit = null;
let store = null; // this workspace's session
let settingsSaved = null; // /mibi.ini as last stored, shared by every workspace
let folder = null; // FolderSync, when a real folder is open
let pendingHandle = null; // the folder lost its permission while open
let notices = []; // status lines from before the editor started
let lastPersist = 0;
let persistTimer = 0;
let saving = Promise.resolve(); // storage writes, one after another
let persistAgain = false; // the last save failed: try again even if nothing changed
let scanning = false;
let flushTimer = 0;
let pushTimer = 0;

const welcome = `mibi on the web
==============

The same editor as the terminal build, compiled to WebAssembly and running in
xterm.js. Everything in the editor works as it does natively: tabs, splits,
search and replace, the file tree, the pickers, themes, the mouse, the
session. F1 lists the keys.

Your files: Open folder works on a real folder in Chromium-based browsers;
saves go straight to disk and changes made elsewhere show up here. Other
browsers import a copy (Open files, Open folder, or drop files on the page)
that stays in this browser; Download writes the current file out.

Settings live in /mibi.ini (Ctrl+O, then type /mibi.ini). A mibi.ini in
your folder wins, as it does natively.

Not here: formatters and the filter command (a page cannot run programs),
and the keys the browser keeps for itself. The toolbar has those keys, and
the ? button says what else differs.
`;

// --- start -------------------------------------------------------------------

async function boot() {
  try {
    showOverlay("Starting mibi…", "Loading the editor.", null);
    if (!(await holdTabLock())) return;
    editor = await Editor.load(await fetch("mibi.wasm"));
    await setupTerminal();
    editor.onFrame = write;

    const handle = await folderFromLastTime();
    store = await openStore(handle ? await folderKey(handle) : "browser");
    const saved = await store.load().catch((err) => {
      console.warn("mibi: could not read the saved session", err);
      return null;
    });
    if (saved && !editor.deserialize(saved)) say("the saved session was damaged and could not be restored");

    await seedAssets();
    if (handle) await attachFolder(handle);
    // Outside /workspace, so it is never mistaken for the user's files.
    if (!saved && !handle) editor.put("/welcome.txt", welcome);
    editor.clean();

    editor.init(term.cols, term.rows);
    wire();
    ui.overlay.hidden = true;
    for (const text of notices.splice(0)) editor.notify(text);
    term.focus();
    setInterval(idle, 500);
    setInterval(() => folder && !document.hidden && scanFolder(), SCAN_MS);

    // ?send=<bytes> feeds input as if typed: for checking a deployed build
    // without a keyboard, e.g. ?send=%0f (Ctrl+O).
    const send = new URLSearchParams(location.search).get("send");
    if (send) input(send);
  } catch (err) {
    console.error(err);
    showOverlay("mibi could not start", String(err?.message || err), "Reload");
  }
}

/** A status line now, or once the editor is up. */
function say(text) {
  if (editor && !editor.stopped && ui.overlay.hidden) editor.notify(text);
  else notices.push(text);
}

/**
 * The folder open last time, once the browser lets us use it again. The
 * permission does not always survive a reload, and asking needs a click, so
 * the page asks before the editor starts: the session belongs to the folder.
 */
async function folderFromLastTime() {
  const handle = await kvGet("folder").catch(() => null);
  if (!handle) return null;
  try {
    if ((await handle.queryPermission({ mode: "readwrite" })) === "granted") return handle;
  } catch {
    return null;
  }
  const choice = await new Promise((resolve) => {
    showOverlay(
      `Open ${handle.name} again?`,
      "The browser needs your permission again to edit this folder. Without it, mibi opens the files kept in this browser instead.",
      `Open ${handle.name}`,
      async () => resolve(await handle.requestPermission({ mode: "readwrite" }).catch(() => "denied")),
      "Use the browser's files",
      () => resolve("skip"),
    );
  });
  showOverlay("Starting mibi…", "Loading the editor.", null);
  if (choice === "granted") return handle;
  await kvSet("folder", null).catch(() => {});
  return null;
}

/** One editor per browser: two tabs would overwrite each other's session. */
async function holdTabLock() {
  if (!navigator.locks) return true;
  const take = (steal) =>
    new Promise((resolve) => {
      navigator.locks
        .request("mibi-editor", steal ? { steal: true } : { ifAvailable: true }, (lock) => {
          resolve(!!lock);
          // Held until the page goes away, or another tab takes it.
          return lock ? new Promise(() => {}) : undefined;
        })
        .catch(() => lostTabLock());
    });
  if (await take(false)) return true;
  showOverlay(
    "mibi is open in another tab",
    "Two tabs would overwrite each other's session. Use the other tab, or move the editor here (the other tab stops).",
    "Use it here",
    async () => {
      await take(true);
      // The other tab saves as it stops; give that write a moment to land.
      await new Promise((resolve) => setTimeout(resolve, 400));
      location.reload();
    },
  );
  return false;
}

function lostTabLock() {
  if (!editor || editor.stopped) return;
  editor.checkpoint();
  persist();
  editor.shutdown();
  showOverlay("mibi moved to another tab", "This tab has stopped so the two do not overwrite each other.", "Use it here", () =>
    location.reload(),
  );
}

async function setupTerminal() {
  // xterm.js measures a cell once, when it opens. Measured on the fallback
  // font, the grid comes out wider than the page once the real one arrives.
  await document.fonts.load('14px "Maple Mono NF"').catch(() => {});
  term = new Terminal({
    cursorBlink: true,
    scrollback: 0,
    fontFamily: '"Maple Mono NF", monospace',
    fontSize: 14,
    theme: { background: "#0e0e0e", foreground: "#d8dee9", cursor: "#d8dee9", selectionBackground: "#334566" },
    macOptionIsMeta: true,
  });
  fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open($("terminal"));
  fit.fit();
  term.onTitleChange((title) => title && (document.title = title));
}

function wire() {
  term.onData(input);
  term.onResize(({ cols, rows }) => !editor.stopped && editor.resize(cols, rows));

  // Keep the editor's keys from the browser where the browser allows it.
  // Ctrl+W, Ctrl+T, Ctrl+N and a few more it never gives up: the toolbar
  // has those.
  term.attachCustomKeyEventHandler((event) => {
    if (event.type !== "keydown") return true;
    if ((event.ctrlKey || event.metaKey) && !event.altKey && event.key.length === 1) {
      if ("sopfbkdgtwnqrazy".includes(event.key.toLowerCase())) event.preventDefault();
    }
    if (event.key === "F1" || event.key === "F5" || event.key === "F6" || event.key === "F7") event.preventDefault();
    return true;
  });

  // The window, and the toolbar wrapping onto another row, both change the
  // terminal's size. Fit again now too: it may have moved before this.
  new ResizeObserver(() => fit.fit()).observe($("terminal"));
  fit.fit();
  editor.resize(term.cols, term.rows);

  $("open-files").addEventListener("click", () => ui.fileInput.click());
  $("open-folder").addEventListener("click", openFolder);
  ui.folderAction.addEventListener("click", () => (pendingHandle ? reconnectFolder() : scanFolder()));
  ui.closeFolder.addEventListener("click", () => switchTo(null));
  $("download").addEventListener("click", download);
  for (const button of document.querySelectorAll("[data-command]")) {
    button.addEventListener("click", () => command(button.dataset.command));
  }
  $("help-button").addEventListener("click", () => {
    ui.help.hidden = !ui.help.hidden;
    if (ui.help.hidden) term.focus();
  });

  ui.fileInput.addEventListener("change", async () => {
    await importFiles(ui.fileInput.files);
    ui.fileInput.value = "";
  });
  ui.folderInput.addEventListener("change", async () => {
    await importFiles(ui.folderInput.files);
    ui.folderInput.value = "";
  });
  document.addEventListener("dragover", (event) => event.preventDefault());
  document.addEventListener("drop", async (event) => {
    event.preventDefault();
    if (event.dataTransfer?.files.length) await importFiles(event.dataTransfer.files);
  });

  // The last chance to keep the session: hidden comes before a tab closes.
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) return scanFolder();
    if (editor.stopped) return;
    editor.checkpoint();
    persist();
    pushFolder();
  });
  window.addEventListener("focus", () => scanFolder());
  window.addEventListener("pagehide", () => {
    if (editor.stopped) return;
    editor.checkpoint();
    persist();
  });
}

// --- the editor ---------------------------------------------------------------

function write(bytes) {
  if (!bytes.length) return;
  copyToClipboard(bytes);
  term.write(bytes);
}

function input(data) {
  if (editor.stopped) return;
  editor.input(data);
  if (flushTimer) clearTimeout(flushTimer);
  if (editor.pending) {
    flushTimer = setTimeout(() => {
      flushTimer = 0;
      if (editor.stopped) return;
      editor.flush();
      after();
    }, ESC_MS);
  }
  after();
}

function command(name) {
  if (editor.stopped) return;
  editor.command(name);
  after();
  term.focus();
}

/** After anything the editor did: storage, the folder, and quitting. */
function after() {
  if (editor.quit) return quit();
  schedulePersist();
  schedulePush();
}

function idle() {
  if (editor.stopped) return;
  editor.tick();
  schedulePersist();
}

function quit() {
  editor.checkpoint();
  editor.shutdown();
  persist();
  pushFolder();
  showOverlay("Session saved", "The editor has quit. Your tabs and unsaved text are kept in this browser.", "Reopen", () =>
    location.reload(),
  );
}

/** Pick the last OSC 52 copy out of a frame and put it on the system clipboard. */
function copyToClipboard(bytes) {
  if (!bytes.includes(0x1b)) return;
  const text = new TextDecoder().decode(bytes);
  const re = /\x1b\]52;[^;]*;([A-Za-z0-9+/=]*)(?:\x07|\x1b\\)/g;
  let payload = null;
  for (let m; (m = re.exec(text)); ) payload = m[1];
  if (payload === null) return;
  try {
    const raw = Uint8Array.from(atob(payload), (c) => c.charCodeAt(0));
    navigator.clipboard?.writeText(new TextDecoder().decode(raw)).catch(() => {});
  } catch (err) {
    console.warn("mibi: clipboard", err);
  }
}

// --- storage -----------------------------------------------------------------

function schedulePersist() {
  if (persistTimer || !(editor.dirty || persistAgain)) return;
  const wait = Math.max(0, PERSIST_MS - (Date.now() - lastPersist));
  persistTimer = setTimeout(() => {
    persistTimer = 0;
    persist();
  }, wait);
}

/**
 * Store the session (and the workspace, without a real folder) as it is now.
 * Writes queue behind each other, so an older one never lands last. The
 * promise settles when this one is stored.
 */
function persist() {
  if (!store) return saving;
  const settings = editor.read("/mibi.ini");
  if (settings && !sameBytes(settings, settingsSaved)) {
    settingsSaved = settings;
    kvSet("settings", settings).catch((err) => console.warn("mibi: settings", err));
  }
  if (!(editor.dirty || persistAgain)) return saving;
  lastPersist = Date.now();
  const bytes = editor.serialize(!folder);
  editor.clean();
  persistAgain = false;
  saving = saving
    .then(() => store.save(bytes))
    .catch((err) => {
      console.warn("mibi: could not save the session", err);
      persistAgain = true;
      say(`could not keep the session in this browser (${err?.name || err})`);
    });
  return saving;
}

function sameBytes(a, b) {
  return !!b && a.length === b.length && a.every((x, i) => x === b[i]);
}

/** Everything written out and stored, before the page goes somewhere else. */
async function settle() {
  if (editor.stopped) return;
  editor.checkpoint();
  await pushFolder();
  await persist();
}

// --- real folders --------------------------------------------------------------

function showFolder(text, action) {
  ui.hint.textContent = text;
  ui.folderAction.hidden = !action;
  if (action) ui.folderAction.textContent = action;
}

async function openFolder() {
  if (!window.showDirectoryPicker) return ui.folderInput.click();
  let handle;
  try {
    handle = await window.showDirectoryPicker({ mode: "readwrite" });
  } catch (err) {
    if (err?.name === "AbortError") return;
    // An embedded or insecure page: fall back to a snapshot.
    if (err?.name === "SecurityError" || err?.name === "NotAllowedError") return ui.folderInput.click();
    return say(`could not open the folder (${err?.message || err})`);
  }
  if (folder && (await folder.handle.isSameEntry(handle))) return scanFolder();
  await switchTo(handle);
}

/** Reload into another workspace: a folder, or the browser's own files (null). */
async function switchTo(handle) {
  showOverlay("Switching workspace…", "Saving this one first.", null);
  await settle();
  await kvSet("folder", handle).catch(() => {});
  location.reload();
}

async function attachFolder(handle) {
  folder = new FolderSync(editor, handle);
  pendingHandle = null;
  const report = await folder.scan();
  editor.track(true);
  showFolder(`folder: ${handle.name}`, "Refresh");
  ui.closeFolder.hidden = false;
  if (folder.truncated) say(`${handle.name}: only the first ${folder.options.maxFiles} files were read`);
  else if (report.skipped) say(`${handle.name}: ${report.skipped} binary or large files are not shown`);
}

/** The same folder after the browser withdrew permission: no reload needed. */
async function reconnectFolder() {
  try {
    if ((await pendingHandle.requestPermission({ mode: "readwrite" })) !== "granted") return;
    const handle = pendingHandle;
    folder = new FolderSync(editor, handle);
    pendingHandle = null;
    await folder.scan();
    showFolder(`folder: ${handle.name}`, "Refresh");
    editor.tick();
    // Saves made while it was away are still recorded: write them now.
    pushFolder();
  } catch (err) {
    say(`could not reconnect the folder (${err?.message || err})`);
  }
  term.focus();
}

async function scanFolder() {
  // A big folder can take longer than the interval; one scan at a time.
  if (!folder || editor.stopped || scanning) return;
  scanning = true;
  try {
    const r = await folder.scan();
    if (r.added || r.changed || r.removed) editor.tick();
  } catch (err) {
    folderFailed(err);
  } finally {
    scanning = false;
  }
}

function schedulePush() {
  if (!folder || pushTimer) return;
  pushTimer = setTimeout(() => {
    pushTimer = 0;
    pushFolder();
  }, PUSH_MS);
}

async function pushFolder() {
  if (!folder) return;
  try {
    const r = await folder.push();
    if (r.failed.length) {
      const { rel, err } = r.failed[0];
      if (isFolderGone(err)) return folderFailed(err);
      say(`could not write ${rel} to the folder (${err?.name || err}); it will be tried again`);
      schedulePush();
    } else if (r.deleted.length && !r.written.length) {
      say(`deleted ${r.deleted.join(", ")} from the folder`);
    }
    // A conflict has already said so in the status bar.
  } catch (err) {
    folderFailed(err);
  }
}

function isFolderGone(err) {
  return err?.name === "NotAllowedError" || err?.name === "SecurityError";
}

function folderFailed(err) {
  console.warn("mibi: folder", err);
  if (!folder) return;
  if (isFolderGone(err)) {
    // Keep recording writes: they go out after Reconnect.
    pendingHandle = folder.handle;
    folder = null;
    showFolder(`folder: ${pendingHandle.name} (needs permission)`, "Reconnect");
    say("the folder needs permission again: press Reconnect");
  } else if (err?.name === "NotFoundError") {
    const name = folder.name;
    folder = null;
    editor.track(false);
    showFolder(`folder: ${name} (gone)`, null);
    say(`the folder ${name} is gone; open tabs keep their text`);
  }
}

// --- files without a folder ------------------------------------------------------

async function importFiles(files) {
  let first = null;
  let skipped = 0;
  for (const file of Array.from(files || [])) {
    const bytes = decodeText(await file.arrayBuffer().catch(() => new ArrayBuffer(0)));
    if (!bytes) {
      skipped += 1;
      continue;
    }
    const path = "/workspace/" + (file.webkitRelativePath || file.name).replace(/\\/g, "/");
    editor.put(path, bytes);
    first ??= path;
  }
  if (first) editor.open(first);
  editor.tick();
  if (skipped) say(`${skipped} binary files were not imported`);
  after();
  term.focus();
}

function download() {
  const current = editor.current();
  if (!current) return;
  const url = URL.createObjectURL(new Blob([current.bytes], { type: "text/plain;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = current.name || "untitled.txt";
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  term.focus();
}

async function seedAssets() {
  const manifest = await fetch("assets.txt").then((r) => (r.ok ? r.text() : ""), () => "");
  if (!manifest) console.warn("mibi: no assets.txt; languages and themes are missing");
  const jobs = manifest
    .split("\n")
    .map((line) => line.trim().split(/\s+/))
    .filter(([kind, name]) => kind && name)
    .map(([kind, name]) => {
      const path = `${kind === "syntax" ? "syntax.d" : "themes"}/${name}`;
      return fetch(path)
        .then((r) => (r.ok ? r.arrayBuffer() : Promise.reject(new Error(`HTTP ${r.status}`))))
        .then((buf) => editor.put("/" + path, new Uint8Array(buf)))
        .catch((err) => console.warn(`mibi: ${path}`, err));
    });
  // The settings next to the "binary", as native ships them: the user's own
  // edits, kept once for every workspace, or the example on a first visit.
  settingsSaved = await kvGet("settings").catch(() => null);
  if (settingsSaved) editor.put("/mibi.ini", settingsSaved);
  else {
    jobs.push(
      fetch("mibi.ini.example")
        .then((r) => (r.ok ? r.arrayBuffer() : null))
        .then((buf) => buf && editor.put("/mibi.ini", new Uint8Array(buf)))
        .catch(() => {}),
    );
  }
  await Promise.all(jobs);
}

// --- overlay -------------------------------------------------------------------

function showOverlay(title, text, button, onClick = () => location.reload(), alt = null, onAlt = null) {
  ui.overlayTitle.textContent = title;
  ui.overlayText.textContent = text;
  ui.overlayButton.hidden = !button;
  if (button) {
    ui.overlayButton.textContent = button;
    ui.overlayButton.onclick = onClick;
  }
  ui.overlayAlt.hidden = !alt;
  if (alt) {
    ui.overlayAlt.textContent = alt;
    ui.overlayAlt.onclick = onAlt;
  }
  ui.overlay.hidden = false;
}

boot();
