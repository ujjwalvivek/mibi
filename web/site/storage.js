// Where the editor's state lives between visits: the session, unsaved
// buffers, and (without a real folder) the workspace itself, as the one
// blob `Editor.serialize` makes. Each workspace has its own blob, as each
// working directory has its own session natively: "browser" for the files
// kept in the page, and one per real folder (`folderKey`). A tab restored in
// the wrong folder could otherwise save one project's text into another.
//
// The origin private file system first: no size cap beyond the browser's
// quota, binary as it is, and createWritable swaps the file in whole. Where
// OPFS cannot write from a page (older Safari), IndexedDB holds the same
// bytes. The first run after an upgrade moves the old localStorage copy over
// and deletes it.
//
// IndexedDB also keeps the real folder's handle, which survives a reload
// (its permission does not).

const LEGACY_KEY = "mibi.vfs";

/** The store for one workspace: `load()` and `save(bytes)` its blob. */
export async function openStore(key) {
  const store = (await opfsStore(key)) || idbStore(key);
  if (key === "browser") await migrateLegacy(store);
  // Ask the browser not to evict this origin's data under storage pressure.
  navigator.storage?.persist?.().catch(() => {});
  return store;
}

async function opfsStore(key) {
  const FILE = `mibi-${key}.bin`;
  try {
    const root = await navigator.storage.getDirectory();
    const handle = await root.getFileHandle(FILE, { create: true });
    if (typeof handle.createWritable !== "function") return null;
    return {
      kind: "opfs",
      async load() {
        const file = await handle.getFile();
        return file.size ? new Uint8Array(await file.arrayBuffer()) : null;
      },
      async save(bytes) {
        const writable = await handle.createWritable();
        await writable.write(bytes);
        await writable.close();
      },
      async clear() {
        await root.removeEntry(FILE).catch(() => {});
      },
    };
  } catch {
    return null;
  }
}

function idbStore(key) {
  return {
    kind: "indexeddb",
    load: () => kvGet(`state:${key}`).then((v) => v || null),
    save: (bytes) => kvSet(`state:${key}`, bytes),
    clear: () => kvSet(`state:${key}`, null),
  };
}

/**
 * A stable key for a real folder. Handles cannot be compared by name or
 * path, only with isSameEntry, so every folder ever opened is remembered
 * with a random id.
 */
export async function folderKey(handle) {
  const known = (await kvGet("folders").catch(() => null)) || [];
  for (const entry of known) {
    if (await entry.handle.isSameEntry(handle).catch(() => false)) return entry.id;
  }
  const id = "folder-" + crypto.randomUUID();
  known.push({ id, handle });
  await kvSet("folders", known);
  return id;
}

async function migrateLegacy(store) {
  // A build of early 0.2 kept one blob for every workspace, in OPFS.
  try {
    const root = await navigator.storage.getDirectory();
    const old = await root.getFileHandle("mibi-state.bin");
    const file = await old.getFile();
    if (file.size && !(await store.load())) await store.save(new Uint8Array(await file.arrayBuffer()));
    await root.removeEntry("mibi-state.bin");
  } catch {
    // Not there, or no OPFS.
  }
  let legacy = null;
  try {
    legacy = localStorage.getItem(LEGACY_KEY);
  } catch {
    return;
  }
  if (!legacy) return;
  try {
    if (!(await store.load())) {
      const bin = atob(legacy);
      const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
      await store.save(bytes);
    }
    localStorage.removeItem(LEGACY_KEY);
  } catch (err) {
    console.warn("mibi: could not move the old localStorage session", err);
  }
}

// --- a small key-value store in IndexedDB ------------------------------------

let db = null;

function openDb() {
  db ??= new Promise((resolve, reject) => {
    const req = indexedDB.open("mibi", 1);
    req.onupgradeneeded = () => {
      if (!req.result.objectStoreNames.contains("kv")) req.result.createObjectStore("kv");
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return db;
}

export async function kvGet(key) {
  const conn = await openDb();
  return new Promise((resolve, reject) => {
    const req = conn.transaction("kv", "readonly").objectStore("kv").get(key);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export async function kvSet(key, value) {
  const conn = await openDb();
  return new Promise((resolve, reject) => {
    const tx = conn.transaction("kv", "readwrite");
    if (value === null || value === undefined) tx.objectStore("kv").delete(key);
    else tx.objectStore("kv").put(value, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}
