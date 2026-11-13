// The wasm editor as a JavaScript object. Every export of src/web_main.zig is
// called from here and nowhere else, so the ABI (pointers, lengths, the
// result buffer) stays in one file. Nothing here touches the DOM: the page
// (main.js) and the tests (web/test) both drive the editor through it.
//
// Every frame the editor draws goes to `onFrame`, whoever caused it. The
// renderer only sends what changed since the last frame, so a frame that
// never reached the terminal would leave it wrong until a full repaint.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export class Editor {
  /** Instantiate mibi.wasm from its bytes (or a fetch Response). */
  static async load(source, { now = () => performance.now(), log = console.log } = {}) {
    let memory = null;
    const imports = {
      env: {
        mibi_now_ms: now,
        mibi_write: (fd, ptr, len) => log(`[mibi:${fd}] ${decoder.decode(new Uint8Array(memory.buffer, ptr, len))}`),
        mibi_exit: (code) => {
          throw new Error(`mibi exited with code ${code}`);
        },
      },
    };
    let instance;
    if (typeof Response !== "undefined" && source instanceof Response) {
      if (!source.ok) throw new Error(`mibi.wasm: HTTP ${source.status}`);
      const streaming = WebAssembly.instantiateStreaming && source.headers.get("content-type") === "application/wasm";
      ({ instance } = streaming
        ? await WebAssembly.instantiateStreaming(source, imports)
        : await WebAssembly.instantiate(await source.arrayBuffer(), imports));
    } else {
      ({ instance } = await WebAssembly.instantiate(source, imports));
    }
    memory = instance.exports.memory;
    if (!memory) throw new Error("mibi.wasm has no memory export");
    return new Editor(instance.exports);
  }

  constructor(exports) {
    this.x = exports;
    this.stopped = false;
    /** Called with each frame's ANSI bytes. */
    this.onFrame = () => {};
  }

  #emit() {
    const len = this.x.mibi_frame_len();
    if (len) this.onFrame(this.#view(this.x.mibi_frame_ptr(), len).slice());
  }

  // --- lifecycle -----------------------------------------------------------

  /** Start the editor. Seed the filesystem first. */
  init(cols, rows) {
    const rc = this.x.mibi_init(cols, rows);
    if (rc !== 0) throw new Error(`the editor could not start (mibi_init returned ${rc})`);
    this.#emit();
  }

  /** Terminal bytes (a string from xterm.js onData, or bytes). */
  input(data) {
    const bytes = typeof data === "string" ? encoder.encode(data) : data;
    if (!bytes.length || this.stopped) return;
    this.#withBytes(bytes, (p, n) => this.x.mibi_input(p, n));
    this.#emit();
  }

  flush() {
    this.x.mibi_flush();
    this.#emit();
  }

  /** True while the decoder holds a lone ESC or half a sequence. */
  get pending() {
    return this.x.mibi_pending() !== 0;
  }

  resize(cols, rows) {
    this.x.mibi_resize(cols, rows);
    this.#emit();
  }

  /** Idle tick: reload files changed underneath, autosave the session. */
  tick() {
    this.x.mibi_tick();
    this.#emit();
  }

  /** Save the session into the filesystem now (before persisting it). */
  checkpoint() {
    this.x.mibi_checkpoint();
  }

  /** The theme's background as "#rrggbb", or null when it is the terminal's. */
  get background() {
    const rgb = this.x.mibi_background();
    return rgb < 0 ? null : "#" + rgb.toString(16).padStart(6, "0");
  }

  get quit() {
    return this.x.mibi_quit() !== 0;
  }

  /** Save the session and hand the terminal back. No input after this. */
  shutdown() {
    if (this.stopped) return;
    this.x.mibi_shutdown();
    this.stopped = true;
    this.#emit();
  }

  // --- editor --------------------------------------------------------------

  /** Run a command from the editor's table by name ("save", "find", ...). */
  command(name) {
    const rc = this.#withString(name, (p, n) => this.x.mibi_command(p, n));
    if (rc === 2) throw new Error(`no such command: ${name}`);
    this.#emit();
  }

  open(path) {
    const rc = this.#withString(path, (p, n) => this.x.mibi_open(p, n));
    this.#emit();
    return rc === 0;
  }

  /** A line in the editor's status bar. */
  notify(text) {
    this.#withString(text, (p, n) => this.x.mibi_notify(p, n));
    this.#emit();
  }

  /** A save the folder refused (it changed there): tabs go back to unsaved. */
  conflict(path) {
    const tabs = this.#withString(path, (p, n) => this.x.mibi_conflict(p, n));
    this.#emit();
    return tabs;
  }

  /** The focused tab's bytes and file name ("" when untitled). */
  current() {
    const len = this.x.mibi_current_bytes();
    if (len < 0) return null;
    const bytes = this.#result(len);
    const name = decoder.decode(this.#result(this.x.mibi_current_name()));
    return { bytes, name };
  }

  // --- filesystem ----------------------------------------------------------

  /** Create or replace a file from outside the editor (never written back). */
  put(path, data) {
    const bytes = typeof data === "string" ? encoder.encode(data) : data;
    const rc = this.#withString(path, (pp, pn) => this.#withBytes(bytes, (dp, dn) => this.x.mibi_vfs_put(pp, pn, dp, dn)));
    if (rc !== 0) throw new Error(`could not store ${path}`);
  }

  remove(path) {
    this.#withString(path, (p, n) => this.x.mibi_vfs_remove(p, n));
  }

  removeTree(path) {
    this.#withString(path, (p, n) => this.x.mibi_vfs_remove_tree(p, n));
  }

  /** A file's bytes, or null when there is no such file. */
  read(path) {
    const len = this.#withString(path, (p, n) => this.x.mibi_vfs_read(p, n));
    return len < 0 ? null : this.#result(len);
  }

  readText(path) {
    const bytes = this.read(path);
    return bytes && decoder.decode(bytes);
  }

  has(path) {
    return this.read(path) !== null;
  }

  /** Record the editor's /workspace writes for a real folder. */
  track(on) {
    this.x.mibi_vfs_track(on ? 1 : 0);
  }

  /** The /workspace paths written or deleted since the last call. */
  takeChanged() {
    const len = this.x.mibi_vfs_take_changed();
    if (len <= 0) return [];
    return decoder.decode(this.#result(len)).split("\n");
  }

  markChanged(path) {
    this.#withString(path, (p, n) => this.x.mibi_vfs_mark_changed(p, n));
  }

  /** The persisted files as one blob (without /workspace when a folder holds it). */
  serialize(includeWorkspace) {
    const len = this.x.mibi_vfs_serialize(includeWorkspace ? 1 : 0);
    if (len < 0) throw new Error("out of memory serialising the workspace");
    return this.#result(len);
  }

  deserialize(bytes) {
    return this.#withBytes(bytes, (p, n) => this.x.mibi_vfs_deserialize(p, n)) === 0;
  }

  get dirty() {
    return this.x.mibi_vfs_dirty() !== 0;
  }

  clean() {
    this.x.mibi_vfs_clean();
  }

  // --- memory --------------------------------------------------------------

  // Views are made fresh every time: memory.buffer is replaced when it grows.
  #view(ptr, len) {
    // Exports return u32s, which JavaScript reads as signed.
    return new Uint8Array(this.x.memory.buffer, ptr >>> 0, len >>> 0);
  }

  #result(len) {
    return len > 0 ? this.#view(this.x.mibi_result_ptr(), len).slice() : new Uint8Array(0);
  }

  #withBytes(bytes, fn) {
    // A zero-length allocation is still a valid pointer to pass.
    const len = bytes.length;
    const ptr = this.x.mibi_alloc(len);
    if (!ptr && len) throw new Error("out of memory");
    try {
      if (len) this.#view(ptr, len).set(bytes);
      return fn(ptr, len);
    } finally {
      if (ptr) this.x.mibi_free(ptr, len);
    }
  }

  #withString(text, fn) {
    return this.#withBytes(encoder.encode(text), fn);
  }
}

/** Text as the editor wants it, or null for what it cannot edit (binary, not UTF-8). */
export function decodeText(buffer) {
  const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  const head = bytes.subarray(0, Math.min(bytes.length, 8192));
  if (head.includes(0)) return null;
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return bytes;
  } catch {
    return null;
  }
}
