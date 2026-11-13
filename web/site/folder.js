// A real folder (File System Access API) kept in step with the editor's
// /workspace, both ways.
//
//   scan()  folder -> editor. New and changed files are read in, deleted ones
//           removed. The editor's own idle tick then does what it does
//           natively: reload a clean tab, keep a tab with unsaved changes
//           and say the file changed on disk.
//   push()  editor -> folder. Every path the editor wrote or deleted goes
//           out, unless the folder's copy changed since it was last read.
//           Then nothing is overwritten: the folder's version comes in, the
//           tab goes back to unsaved, and the next save is a deliberate one.
//
// "Changed" is judged by size and lastModified against what the last scan or
// write saw. The two never run at once: every operation waits its turn.
//
// Only the handle API is used (entries, getFile, createWritable,
// removeEntry), so the tests drive this with an in-memory folder.

import { decodeText } from "./host.js";

const WS = "/workspace/";

export const defaults = {
  maxFiles: 5000,
  maxBytes: 4 * 1024 * 1024,
  maxDepth: 16,
  skipDirs: new Set([".git", ".hg", ".svn", "node_modules", ".zig-cache", ".zig-cache-global", "zig-out", "target", "dist", "build", ".next", "__pycache__", ".venv"]),
};

export class FolderSync {
  constructor(editor, handle, options = {}) {
    this.editor = editor;
    this.handle = handle;
    this.options = { ...defaults, ...options };
    /** rel path -> { size, lastModified, text } as last read or written */
    this.known = new Map();
    this.knownDirs = new Set();
    this.truncated = false;
    this.queue = Promise.resolve();
  }

  get name() {
    return this.handle.name;
  }

  /** Run `fn` after everything queued before it, whatever they did. */
  #serial(fn) {
    const run = this.queue.then(fn, fn);
    this.queue = run.catch(() => {});
    return run;
  }

  /** Bring the folder's changes into the editor. */
  scan() {
    return this.#serial(() => this.#scan());
  }

  /** Write the editor's changes to the folder. */
  push() {
    return this.#serial(() => this.#push());
  }

  async #scan() {
    const seen = new Set();
    const seenDirs = new Set();
    const report = { added: 0, changed: 0, removed: 0, skipped: 0 };
    this.truncated = false;
    await this.#walk(this.handle, "", 0, seen, seenDirs, report);

    for (const rel of this.known.keys()) {
      if (seen.has(rel)) continue;
      // With the walk cut short, an unseen file may still be there.
      if (this.truncated) continue;
      this.known.delete(rel);
      this.editor.remove(WS + rel);
      report.removed += 1;
    }
    if (!this.truncated) {
      for (const dir of this.knownDirs) {
        if (!seenDirs.has(dir)) this.editor.removeTree(WS + dir);
      }
      this.knownDirs = seenDirs;
    } else {
      for (const dir of seenDirs) this.knownDirs.add(dir);
    }
    return report;
  }

  async #walk(dir, prefix, depth, seen, seenDirs, report) {
    for await (const [name, entry] of dir.entries()) {
      if (entry.kind === "directory") {
        if (this.options.skipDirs.has(name) || depth >= this.options.maxDepth) continue;
        const rel = prefix + name;
        seenDirs.add(rel);
        await this.#walk(entry, rel + "/", depth + 1, seen, seenDirs, report);
        continue;
      }
      if (seen.size >= this.options.maxFiles) {
        this.truncated = true;
        return;
      }
      const rel = prefix + name;
      seen.add(rel);
      try {
        const file = await entry.getFile();
        const was = this.known.get(rel);
        if (was && was.size === file.size && was.lastModified === file.lastModified) continue;
        const meta = { size: file.size, lastModified: file.lastModified, text: false };
        this.known.set(rel, meta);
        if (file.size > this.options.maxBytes) {
          if (was && was.text) this.editor.remove(WS + rel);
          report.skipped += 1;
          continue;
        }
        const bytes = decodeText(await file.arrayBuffer());
        if (!bytes) {
          // No longer text: the editor's copy would be a lie.
          if (was && was.text) this.editor.remove(WS + rel);
          report.skipped += 1;
          continue;
        }
        meta.text = true;
        this.editor.put(WS + rel, bytes);
        if (was && was.text) report.changed += 1;
        else report.added += 1;
      } catch (err) {
        // Unreadable now (locked, permission): try again on the next scan.
        this.known.delete(rel);
        seen.delete(rel);
        console.warn(`mibi: could not read ${rel}`, err);
      }
    }
  }

  async #push() {
    const report = { written: [], deleted: [], conflicts: [], failed: [] };
    for (const path of this.editor.takeChanged()) {
      if (!path.startsWith(WS)) continue;
      const rel = path.slice(WS.length);
      try {
        const bytes = this.editor.read(path);
        const disk = await this.#stat(rel);
        const was = this.known.get(rel);
        const moved = disk && (!was || was.size !== disk.size || was.lastModified !== disk.lastModified);
        if (bytes === null) {
          // Deleted in the editor. Leave a file that changed since.
          if (!disk) {
            this.known.delete(rel);
          } else if (moved) {
            report.conflicts.push(rel);
          } else {
            await this.#remove(rel);
            this.known.delete(rel);
            report.deleted.push(rel);
          }
          continue;
        }
        if (moved) {
          await this.#takeTheirs(rel, path);
          report.conflicts.push(rel);
          continue;
        }
        const file = await this.#write(rel, bytes);
        this.known.set(rel, { size: file.size, lastModified: file.lastModified, text: true });
        report.written.push(rel);
      } catch (err) {
        // Keep it for the next push rather than lose the write.
        this.editor.markChanged(path);
        report.failed.push({ rel, err });
      }
    }
    return report;
  }

  /** The folder's version wins the file; the editor's text stays in the tab. */
  async #takeTheirs(rel, path) {
    const file = await this.#fileHandle(rel).then((h) => h.getFile());
    const meta = { size: file.size, lastModified: file.lastModified, text: false };
    const bytes = file.size <= this.options.maxBytes ? decodeText(await file.arrayBuffer()) : null;
    if (bytes) {
      meta.text = true;
      this.editor.put(path, bytes);
    } else {
      this.editor.remove(path);
    }
    this.known.set(rel, meta);
    this.editor.conflict(path);
  }

  async #stat(rel) {
    try {
      const file = await (await this.#fileHandle(rel)).getFile();
      return { size: file.size, lastModified: file.lastModified };
    } catch (err) {
      if (err && (err.name === "NotFoundError" || err.name === "TypeMismatchError")) return null;
      throw err;
    }
  }

  async #dirFor(rel, create) {
    const parts = rel.split("/");
    let dir = this.handle;
    for (const part of parts.slice(0, -1)) dir = await dir.getDirectoryHandle(part, { create });
    return { dir, name: parts[parts.length - 1] };
  }

  async #fileHandle(rel, create = false) {
    const { dir, name } = await this.#dirFor(rel, create);
    return dir.getFileHandle(name, { create });
  }

  async #write(rel, bytes) {
    const handle = await this.#fileHandle(rel, true);
    // createWritable writes a swap file and swaps it in on close: a failed
    // write leaves the old file whole.
    const writable = await handle.createWritable();
    try {
      await writable.write(bytes);
      await writable.close();
    } catch (err) {
      await writable.abort?.().catch(() => {});
      throw err;
    }
    for (let i = rel.indexOf("/"); i !== -1; i = rel.indexOf("/", i + 1)) this.knownDirs.add(rel.slice(0, i));
    return handle.getFile();
  }

  async #remove(rel) {
    const { dir, name } = await this.#dirFor(rel, false);
    await dir.removeEntry(name);
  }
}
