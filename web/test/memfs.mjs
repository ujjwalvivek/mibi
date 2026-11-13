// An in-memory folder with the slice of the File System Access API that
// folder.js uses: entries, getFile, createWritable, removeEntry. Each write
// moves a fake clock, so lastModified changes the way it does on a disk.

let clock = 1_700_000_000_000;

class NotFound extends Error {
  constructor(name) {
    super(`${name} not found`);
    this.name = "NotFoundError";
  }
}

class FileHandle {
  kind = "file";
  constructor(name, bytes = new Uint8Array(0)) {
    this.name = name;
    this.bytes = bytes;
    this.lastModified = ++clock;
  }
  async getFile() {
    const bytes = this.bytes.slice();
    return {
      size: bytes.length,
      lastModified: this.lastModified,
      arrayBuffer: async () => bytes.buffer,
    };
  }
  async createWritable() {
    const chunks = [];
    return {
      write: async (data) => chunks.push(typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data)),
      close: async () => {
        const len = chunks.reduce((n, c) => n + c.length, 0);
        const out = new Uint8Array(len);
        let at = 0;
        for (const c of chunks) {
          out.set(c, at);
          at += c.length;
        }
        this.bytes = out;
        this.lastModified = ++clock;
      },
      abort: async () => {},
    };
  }
}

export class DirHandle {
  kind = "directory";
  constructor(name = "root") {
    this.name = name;
    this.children = new Map();
  }
  async *entries() {
    for (const entry of [...this.children]) yield entry;
  }
  async getDirectoryHandle(name, { create = false } = {}) {
    let d = this.children.get(name);
    if (!d && create) this.children.set(name, (d = new DirHandle(name)));
    if (!d) throw new NotFound(name);
    if (d.kind !== "directory") throw Object.assign(new Error("not a directory"), { name: "TypeMismatchError" });
    return d;
  }
  async getFileHandle(name, { create = false } = {}) {
    let f = this.children.get(name);
    if (!f && create) this.children.set(name, (f = new FileHandle(name)));
    if (!f) throw new NotFound(name);
    if (f.kind !== "file") throw Object.assign(new Error("not a file"), { name: "TypeMismatchError" });
    return f;
  }
  async removeEntry(name) {
    if (!this.children.delete(name)) throw new NotFound(name);
  }

  // --- for the tests: change the folder "from outside" ---------------------

  #walk(rel, create) {
    const parts = rel.split("/");
    let dir = this;
    for (const p of parts.slice(0, -1)) {
      let next = dir.children.get(p);
      if (!next) {
        if (!create) return null;
        dir.children.set(p, (next = new DirHandle(p)));
      }
      dir = next;
    }
    return { dir, name: parts[parts.length - 1] };
  }
  writeText(rel, text) {
    const { dir, name } = this.#walk(rel, true);
    const bytes = typeof text === "string" ? new TextEncoder().encode(text) : text;
    const f = dir.children.get(name);
    if (f) {
      f.bytes = bytes;
      f.lastModified = ++clock;
    } else dir.children.set(name, new FileHandle(name, bytes));
  }
  readText(rel) {
    const w = this.#walk(rel, false);
    const f = w && w.dir.children.get(w.name);
    return f && f.kind === "file" ? new TextDecoder().decode(f.bytes) : null;
  }
  delete(rel) {
    const w = this.#walk(rel, false);
    if (w) w.dir.children.delete(w.name);
  }
}
