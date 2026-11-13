// The web host: load the wasm editor, drive it through xterm.js, and keep the
// virtual workspace in localStorage. Everything the editor sees is the same
// byte stream a real terminal would give it.

"use strict";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

let wasm = null;
let memory = null;
let term = null;
let fit = null;
let stopped = false;
let flushTimer = 0;
let lastPersist = 0;
let syncTimer = 0;
let folderSyncing = false;
let dirHandle = null;
let pendingDirHandle = null;

const overlay = document.getElementById("overlay");
const overlayTitle = document.getElementById("overlay-title");
const overlayText = document.getElementById("overlay-text");
const overlayButton = document.getElementById("overlay-button");
const help = document.getElementById("help");
const fileInput = document.getElementById("file-input");
const folderInput = document.getElementById("folder-input");
const folderAction = document.getElementById("folder-action");
const hint = document.getElementById("hint");

const welcome = `mibi on the web
==============

This is the same editor as the terminal build, running as WebAssembly inside
xterm.js.

What works: editing, tabs, splits, search and replace, regex, themes, syntax
highlighting, the file tree, the command palette, multiple cursors, the mouse,
paste, soft wrap, undo/redo, and the session (kept in this browser).

What does not: formatters and the filter command (a browser cannot spawn a
process), live reload from outside the editor, and some browser shortcuts.
In Chromium, Open folder is a real folder and Save writes back to it; other
browsers import a snapshot. The ? button has the full list.

Use Open files or Open folder to bring files in. Download writes the current
file to your disk.

Press F1 for the editor's own key list.
`;

async function boot() {
  try {
    showOverlay("Starting mibi…", "Loading the WebAssembly editor.", null);
    await loadWasm();
    setupTerminal();
    restoreVfs();
    await seedAssets();
    await restoreFolder();
    // With a real folder, its own mibi.ini and files are the workspace; do not
    // seed the welcome file into someone's project.
    if (!dirHandle && !pendingDirHandle) await seedDefaults();

    const rc = wasm.mibi_init(term.cols, term.rows);
    if (rc !== 0) throw new Error("the editor could not start (mibi_init returned " + rc + ")");

    wire();
    if (dirHandle) {
      wasm.mibi_tick();
      flushFrame();
    }
    overlay.hidden = true;
    term.focus();
    setInterval(tick, 500);

    // A small automation hook: ?send=hello feeds bytes through the same path
    // as xterm.js input. Handy for smoke tests and for checking a build
    // without a keyboard.
    const params = new URLSearchParams(location.search);
    if (params.has("opfs")) await testOpfsFolder();
    if (params.has("send")) sendInput(params.get("send"));
  } catch (err) {
    console.error(err);
    showOverlay("mibi could not start", String((err && err.message) || err), "Reload");
  }
}

async function loadWasm() {
  const imports = {
    env: {
      mibi_now_ms: () => performance.now(),
      mibi_write: (fd, ptr, len) => {
        if (!memory) return;
        const text = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
        console.log("[mibi:" + fd + "]", text);
      },
      mibi_exit: (code) => {
        throw new Error("mibi exited with code " + code);
      },
    },
  };
  const response = await fetch("mibi.wasm");
  if (!response.ok) throw new Error("mibi.wasm: HTTP " + response.status);
  const bytes = await response.arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, imports);
  wasm = instance.exports;
  memory = wasm.memory;
  if (!memory) throw new Error("mibi.wasm has no memory export");
}

function setupTerminal() {
  term = new Terminal({
    convertEol: false,
    cursorBlink: true,
    scrollback: 0,
    fontFamily: '"Maple Mono NF"',
    fontSize: 14,
    theme: {
      background: "#0e0e0e",
      foreground: "#d8dee9",
      cursor: "#d8dee9",
      selectionBackground: "#334566",
    },
    macOptionIsMeta: true,
  });
  fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(document.getElementById("terminal"));
  fit.fit();
  term.onTitleChange((title) => {
    if (title) document.title = title;
  });
}

function wire() {
  term.onData(sendInput);
  term.onResize(({ cols, rows }) => {
    if (!wasm || stopped) return;
    wasm.mibi_resize(cols, rows);
    flushFrame();
  });

  // Stop the browser from taking the editor's keys where it allows us to.
  // Ctrl+W/T/N, Ctrl+R, F5 and F12 are reserved by the browser in practice.
  term.attachCustomKeyEventHandler((event) => {
    if (event.type !== "keydown") return true;
    if ((event.ctrlKey || event.metaKey) && !event.altKey) {
      const key = event.key.toLowerCase();
      if ("sopfbkdgtwnqrazy".includes(key) && key.length === 1) event.preventDefault();
    }
    if (event.key === "F1" || event.key === "F5") event.preventDefault();
    return true;
  });

  window.addEventListener("resize", () => fit.fit());
  document.fonts.ready.then(() => fit.fit());

  document.getElementById("open-files").addEventListener("click", () => fileInput.click());
  document.getElementById("open-folder").addEventListener("click", () => {
    if (window.showDirectoryPicker) openRealFolder();
    else folderInput.click();
  });
  folderAction.addEventListener("click", reconnectOrRefreshFolder);
  document.getElementById("new").addEventListener("click", () => {
    if (wasm && !stopped) {
      wasm.mibi_new();
      flushFrame();
      maybePersist(true);
      term.focus();
    }
  });
  document.getElementById("close-tab").addEventListener("click", () => {
    if (wasm && !stopped) {
      wasm.mibi_close_tab();
      flushFrame();
      maybePersist(true);
      checkQuit();
      term.focus();
    }
  });
  document.getElementById("save").addEventListener("click", () => {
    if (wasm && !stopped) {
      wasm.mibi_save();
      flushFrame();
      maybePersist(true);
      scheduleSync();
      term.focus();
    }
  });
  document.getElementById("download").addEventListener("click", () => {
    downloadCurrent();
    term.focus();
  });
  document.querySelectorAll("[data-command]").forEach((button) => {
    button.addEventListener("click", () => runCommand(button.dataset.command));
  });
  document.getElementById("help-button").addEventListener("click", () => {
    help.hidden = !help.hidden;
    if (help.hidden) term.focus();
  });

  fileInput.addEventListener("change", async () => {
    await importFiles(fileInput.files);
    fileInput.value = "";
  });
  folderInput.addEventListener("change", async () => {
    await importFiles(folderInput.files);
    folderInput.value = "";
    setHint("imported folder");
  });

  document.addEventListener("dragover", (event) => event.preventDefault());
  document.addEventListener("drop", async (event) => {
    event.preventDefault();
    if (event.dataTransfer && event.dataTransfer.files.length) {
      await importFiles(event.dataTransfer.files);
    }
  });

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) maybePersist(true);
  });
  window.addEventListener("beforeunload", () => {
    if (wasm && !stopped) {
      wasm.mibi_shutdown();
      maybePersist(true);
    }
  });

  overlayButton.addEventListener("click", () => location.reload());
}

function sendInput(data) {
  if (!wasm || stopped) return;
  const bytes = encoder.encode(data);
  if (!bytes.length) return;
  const ptr = wasm.mibi_alloc(bytes.length);
  if (!ptr) return;
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  wasm.mibi_input(ptr, bytes.length);
  wasm.mibi_free(ptr, bytes.length);
  flushFrame();
  scheduleFlush();
  maybePersist();
  scheduleSync();
  checkQuit();
}

function scheduleFlush() {
  if (flushTimer) clearTimeout(flushTimer);
  if (!wasm || !wasm.mibi_pending()) return;
  flushTimer = setTimeout(() => {
    flushTimer = 0;
    if (!wasm || stopped) return;
    wasm.mibi_flush();
    flushFrame();
    checkQuit();
  }, 30);
}

function tick() {
  if (!wasm || stopped) return;
  wasm.mibi_tick();
  flushFrame();
  maybePersist();
  checkQuit();
}

function checkQuit() {
  if (wasm && !stopped && wasm.mibi_quit()) shutdown();
}

// Run a command from the editor's table by name. The toolbar uses this for
// keys the browser reserves, so the key and the button do the same thing.
function runCommand(name) {
  if (!wasm || stopped) return;
  const bytes = encoder.encode(name);
  const ptr = wasm.mibi_alloc(bytes.length);
  if (!ptr) return;
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  const rc = wasm.mibi_command(ptr, bytes.length);
  wasm.mibi_free(ptr, bytes.length);
  if (rc !== 0) return;
  flushFrame();
  maybePersist();
  scheduleSync();
  checkQuit();
  term.focus();
}

function shutdown() {
  if (!wasm || stopped) return;
  wasm.mibi_shutdown();
  flushFrame();
  maybePersist(true);
  syncChanged();
  stopped = true;
  showOverlay(
    "Session saved",
    "The editor has quit. Your tabs and unsaved text are kept in this browser.",
    "Reopen",
  );
}

function flushFrame() {
  if (!wasm || !term) return;
  const len = wasm.mibi_frame_len();
  if (!len) return;
  const ptr = wasm.mibi_frame_ptr();
  const bytes = new Uint8Array(memory.buffer, ptr, len).slice();
  handleOsc52(bytes);
  term.write(bytes);
}

// The editor copies with OSC 52, as it does on a real terminal. xterm.js does
// not act on it, so the host writes the system clipboard.
function handleOsc52(bytes) {
  if (bytes.indexOf(0x1b) === -1) return;
  const text = decoder.decode(bytes);
  const marker = "\x1b]52;";
  let at = text.indexOf(marker);
  while (at !== -1) {
    const bell = text.indexOf("\x07", at);
    const st = text.indexOf("\x1b\\", at);
    let end = -1;
    if (bell !== -1 && (st === -1 || bell < st)) end = bell;
    else if (st !== -1) end = st;
    if (end === -1) break;
    const body = text.slice(at + marker.length, end);
    const semi = body.indexOf(";");
    if (semi !== -1) {
      const payload = body.slice(semi + 1);
      try {
        const bin = atob(payload);
        const raw = Uint8Array.from(bin, (c) => c.charCodeAt(0));
        navigator.clipboard.writeText(decoder.decode(raw)).catch(() => {});
      } catch (err) {
        console.warn("mibi: clipboard", err);
      }
    }
    at = text.indexOf(marker, end + 1);
  }
}

// --- virtual filesystem ------------------------------------------------------

function vfsPut(path, text) {
  const p = encoder.encode(path);
  const d = encoder.encode(text);
  if (!p.length) return false;
  const pp = wasm.mibi_alloc(p.length);
  if (!pp) return false;
  new Uint8Array(memory.buffer, pp, p.length).set(p);
  const dp = d.length ? wasm.mibi_alloc(d.length) : 0;
  if (d.length && !dp) {
    wasm.mibi_free(pp, p.length);
    return false;
  }
  if (d.length) new Uint8Array(memory.buffer, dp, d.length).set(d);
  const rc = wasm.mibi_vfs_put(pp, p.length, dp, d.length);
  wasm.mibi_free(pp, p.length);
  if (dp) wasm.mibi_free(dp, d.length);
  return rc === 0;
}

function vfsHas(path) {
  const p = encoder.encode(path);
  const pp = wasm.mibi_alloc(p.length);
  if (!pp) return false;
  new Uint8Array(memory.buffer, pp, p.length).set(p);
  const rc = wasm.mibi_vfs_has(pp, p.length);
  wasm.mibi_free(pp, p.length);
  return rc !== 0;
}

function openPath(path) {
  const p = encoder.encode(path);
  const pp = wasm.mibi_alloc(p.length);
  if (!pp) return;
  new Uint8Array(memory.buffer, pp, p.length).set(p);
  wasm.mibi_open(pp, p.length);
  wasm.mibi_free(pp, p.length);
  flushFrame();
}

function restoreVfs() {
  let saved = null;
  try {
    saved = localStorage.getItem("mibi.vfs");
  } catch (err) {
    console.warn("mibi: localStorage unavailable", err);
    return;
  }
  if (!saved) return;
  try {
    const bytes = fromBase64(saved);
    const ptr = wasm.mibi_alloc(bytes.length);
    if (!ptr) return;
    new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
    wasm.mibi_vfs_deserialize(ptr, bytes.length);
    wasm.mibi_free(ptr, bytes.length);
  } catch (err) {
    console.warn("mibi: could not restore the workspace", err);
  }
}

function maybePersist(force = false) {
  if (!wasm || stopped || !wasm.mibi_vfs_dirty()) return;
  const now = Date.now();
  if (!force && now - lastPersist < 2000) return;
  lastPersist = now;
  try {
    // With a real folder, the workspace lives on disk; only the session and
    // unsaved buffers belong in localStorage.
    const len = dirHandle ? wasm.mibi_vfs_serialize_state() : wasm.mibi_vfs_serialize();
    if (!len) return;
    const ptr = wasm.mibi_vfs_serialized_ptr();
    const bytes = new Uint8Array(memory.buffer, ptr, len).slice();
    localStorage.setItem("mibi.vfs", toBase64(bytes));
    wasm.mibi_vfs_clean();
  } catch (err) {
    console.warn("mibi: could not persist the workspace", err);
  }
}

function toBase64(bytes) {
  let text = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    text += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(text);
}

function fromBase64(text) {
  const bin = atob(text);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

// --- real folders (File System Access API) -----------------------------------

function setHint(text) {
  hint.textContent = text;
}

function showFolderAction(label) {
  folderAction.hidden = false;
  folderAction.textContent = label;
}

async function openRealFolder() {
  if (!window.showDirectoryPicker) {
    folderInput.click();
    return;
  }
  try {
    const handle = await window.showDirectoryPicker({ mode: "readwrite" });
    dirHandle = handle;
    pendingDirHandle = null;
    idbSet("folder", handle).catch(() => {});
    await importDirectory(handle);
    wasm.mibi_vfs_clear_changed();
    setHint("folder: " + handle.name);
    showFolderAction("Refresh");
    wasm.mibi_tick();
    flushFrame();
    term.focus();
  } catch (err) {
    if (err && err.name === "AbortError") return;
    if (err && (err.name === "SecurityError" || err.name === "NotAllowedError")) {
      // Embedded or insecure context: fall back to the snapshot picker.
      folderInput.click();
      return;
    }
    console.warn("mibi: open folder", err);
    showOverlay("Could not open the folder", String((err && err.message) || err), "Reload");
  }
}

async function restoreFolder() {
  let handle = null;
  try {
    handle = await idbGet("folder");
  } catch (err) {
    console.warn("mibi: folder handle", err);
    return;
  }
  if (!handle) return;
  try {
    const perm = await handle.queryPermission({ mode: "readwrite" });
    if (perm === "granted") {
      dirHandle = handle;
      await importDirectory(handle);
      wasm.mibi_vfs_clear_changed();
      setHint("folder: " + handle.name);
      showFolderAction("Refresh");
    } else {
      pendingDirHandle = handle;
      setHint("folder: " + handle.name + " (reconnect)");
      showFolderAction("Reconnect");
    }
  } catch (err) {
    console.warn("mibi: restore folder", err);
  }
}

async function reconnectOrRefreshFolder() {
  if (pendingDirHandle) {
    try {
      const perm = await pendingDirHandle.requestPermission({ mode: "readwrite" });
      if (perm !== "granted") return;
      dirHandle = pendingDirHandle;
      pendingDirHandle = null;
      await importDirectory(dirHandle);
      wasm.mibi_vfs_clear_changed();
      setHint("folder: " + dirHandle.name);
      showFolderAction("Refresh");
      wasm.mibi_tick();
      flushFrame();
      term.focus();
    } catch (err) {
      console.warn("mibi: reconnect folder", err);
    }
    return;
  }
  if (!dirHandle) return;
  try {
    await importDirectory(dirHandle);
    wasm.mibi_vfs_clear_changed();
    wasm.mibi_tick();
    flushFrame();
    term.focus();
  } catch (err) {
    console.warn("mibi: refresh folder", err);
  }
}

const skippedDirs = new Set([
  ".git", "node_modules", ".zig-cache", "zig-out", "target", "dist", "build", ".next",
]);

/// Read a real folder into /workspace. Text files only; the tree, pickers and
/// editor then work on the snapshot. Writes are synced back by syncChanged.
async function importDirectory(handle, prefix = "", stats = { count: 0 }) {
  if (!wasm) return;
  for await (const [name, entry] of handle.entries()) {
    if (stats.count >= 2000) return;
    if (entry.kind === "directory") {
      if (skippedDirs.has(name)) continue;
      if (prefix.split("/").length > 12) continue;
      await importDirectory(entry, prefix + name + "/", stats);
      continue;
    }
    const path = "/workspace/" + prefix + name;
    try {
      const file = await entry.getFile();
      if (file.size > 2 * 1024 * 1024) continue;
      const buf = await file.arrayBuffer();
      const text = decodeText(buf);
      if (text === null) continue;
      vfsPut(path, text);
      stats.count += 1;
    } catch (err) {
      console.warn("mibi: import " + path, err);
    }
  }
}

function decodeText(buf) {
  const n = Math.min(buf.byteLength, 4096);
  const head = new Uint8Array(buf, 0, n);
  for (let i = 0; i < n; i += 1) if (head[i] === 0) return null;
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(buf);
  } catch {
    return null;
  }
}

/// Write the editor's changed /workspace files back to the real folder.
async function syncChanged() {
  if (!dirHandle || folderSyncing || !wasm || stopped) return;
  const count = wasm.mibi_vfs_changed_count();
  if (!count) return;
  folderSyncing = true;
  let ok = true;
  try {
    for (let i = 0; i < count; i += 1) {
      const len = wasm.mibi_vfs_changed_path_len(i);
      const ptr = wasm.mibi_vfs_changed_path_ptr(i);
      if (!len) continue;
      const path = decoder.decode(new Uint8Array(memory.buffer, ptr, len).slice());
      if (!path.startsWith("/workspace/")) continue;
      const rel = path.slice("/workspace/".length);
      if (!rel) continue;
      const has = withWasmString(path, (p, n) => wasm.mibi_vfs_has(p, n) !== 0);
      if (has === null) throw new Error("out of memory");
      if (has) {
        const data = withWasmString(path, (p, n) => {
          const l = wasm.mibi_vfs_file_len(p, n);
          const q = wasm.mibi_vfs_file_ptr(p, n);
          return new Uint8Array(memory.buffer, q, l).slice();
        });
        if (data === null) throw new Error("out of memory");
        await writeToFolder(rel, data);
      } else {
        await removeFromFolder(rel);
      }
    }
  } catch (err) {
    ok = false;
    console.warn("mibi: folder sync", err);
  } finally {
    folderSyncing = false;
  }
  if (ok) {
    // If the editor changed more files while this pass ran, keep the new ones
    // for the next pass instead of clearing them.
    if (wasm.mibi_vfs_changed_count() === count) wasm.mibi_vfs_clear_changed();
    else scheduleSync();
  } else {
    scheduleSync();
  }
}

function scheduleSync() {
  if (!dirHandle) return;
  if (syncTimer) clearTimeout(syncTimer);
  syncTimer = setTimeout(() => {
    syncTimer = 0;
    syncChanged();
  }, 300);
}

async function writeToFolder(rel, data) {
  const parts = rel.split("/").filter(Boolean);
  if (!parts.length) return;
  let dir = dirHandle;
  for (let i = 0; i < parts.length - 1; i += 1) {
    dir = await dir.getDirectoryHandle(parts[i], { create: true });
  }
  const file = await dir.getFileHandle(parts[parts.length - 1], { create: true });
  const writable = await file.createWritable();
  await writable.write(data);
  await writable.close();
}

async function removeFromFolder(rel) {
  const parts = rel.split("/").filter(Boolean);
  if (!parts.length) return;
  let dir = dirHandle;
  for (let i = 0; i < parts.length - 1; i += 1) {
    dir = await dir.getDirectoryHandle(parts[i]);
  }
  try {
    await dir.removeEntry(parts[parts.length - 1]);
  } catch {
    // Already gone.
  }
}

function withWasmString(text, fn) {
  const bytes = encoder.encode(text);
  const ptr = wasm.mibi_alloc(bytes.length);
  if (!ptr) return null;
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  try {
    return fn(ptr, bytes.length);
  } finally {
    wasm.mibi_free(ptr, bytes.length);
  }
}

// FileSystemDirectoryHandle survives a reload in IndexedDB; permission does
// not, so the page offers a Reconnect button.
let dbPromise = null;

function openDb() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    const req = indexedDB.open("mibi", 1);
    req.onupgradeneeded = () => {
      if (!req.result.objectStoreNames.contains("kv")) req.result.createObjectStore("kv");
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbPromise;
}

async function idbGet(key) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction("kv", "readonly");
    const req = tx.objectStore("kv").get(key);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function idbSet(key, value) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction("kv", "readwrite");
    tx.objectStore("kv").put(value, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

// A browser test for the real-folder path that does not need a native picker:
// ?opfs=1 imports a demo directory from the origin private file system.
async function testOpfsFolder() {
  try {
    const root = await navigator.storage.getDirectory();
    const dir = await root.getDirectoryHandle("mibi-test", { create: true });
    let file;
    try {
      file = await dir.getFileHandle("hello.txt");
    } catch {
      file = await dir.getFileHandle("hello.txt", { create: true });
      const writable = await file.createWritable();
      await writable.write("hello from the file system access API\n");
      await writable.close();
    }
    dirHandle = dir;
    await importDirectory(dir);
    wasm.mibi_vfs_clear_changed();
    wasm.mibi_tick();
    flushFrame();
    setHint("folder: mibi-test (opfs)");
    showFolderAction("Refresh");
  } catch (err) {
    console.warn("mibi: opfs test", err);
  }
}

// --- assets and files --------------------------------------------------------

async function seedAssets() {
  let manifest = "";
  try {
    const response = await fetch("assets.txt");
    if (!response.ok) throw new Error("HTTP " + response.status);
    manifest = await response.text();
  } catch (err) {
    console.warn("mibi: no assets.txt; syntax and themes will be missing", err);
    return;
  }
  const jobs = [];
  for (const raw of manifest.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    const [kind, name] = line.split(/\s+/, 2);
    if (!kind || !name) continue;
    const dir = kind === "syntax" ? "syntax.d" : "themes";
    const path = "/" + dir + "/" + name;
    if (vfsHas(path)) continue;
    jobs.push(
      fetch(dir + "/" + name)
        .then((response) => {
          if (!response.ok) throw new Error("HTTP " + response.status);
          return response.text();
        })
        .then((text) => vfsPut(path, text))
        .catch((err) => console.warn("mibi: asset " + path, err)),
    );
  }
  await Promise.all(jobs);
}

async function seedDefaults() {
  if (!vfsHas("/workspace/mibi.ini")) {
    try {
      const response = await fetch("mibi.ini.example");
      if (response.ok) vfsPut("/workspace/mibi.ini", await response.text());
    } catch (err) {
      console.warn("mibi: config example", err);
    }
  }
  if (!vfsHas("/workspace/welcome.txt")) vfsPut("/workspace/welcome.txt", welcome);
}

async function importFiles(files) {
  const list = Array.from(files || []);
  if (!list.length || !wasm) return;
  let first = null;
  for (const file of list) {
    try {
      const text = await file.text();
      const relative = (file.webkitRelativePath || file.name).replace(/\\/g, "/");
      const path = "/workspace/" + relative;
      vfsPut(path, text);
      if (!first) first = path;
    } catch (err) {
      console.warn("mibi: could not read " + file.name, err);
    }
  }
  if (first) openPath(first);
  maybePersist(true);
  scheduleSync();
  term.focus();
}

function downloadCurrent() {
  if (!wasm || stopped) return;
  const len = wasm.mibi_current_bytes();
  if (!len) return;
  const ptr = wasm.mibi_current_ptr();
  const bytes = new Uint8Array(memory.buffer, ptr, len).slice();
  const nameLen = wasm.mibi_current_name_len();
  const namePtr = wasm.mibi_current_name_ptr();
  let name = nameLen
    ? decoder.decode(new Uint8Array(memory.buffer, namePtr, nameLen))
    : "untitled.txt";
  if (name === "[No Name]") name = "untitled.txt";
  const blob = new Blob([bytes], { type: "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// --- overlay -----------------------------------------------------------------

function showOverlay(title, text, button) {
  overlayTitle.textContent = title;
  overlayText.textContent = text;
  if (button) {
    overlayButton.hidden = false;
    overlayButton.textContent = button;
  } else {
    overlayButton.hidden = true;
  }
  overlay.hidden = false;
}

boot();
