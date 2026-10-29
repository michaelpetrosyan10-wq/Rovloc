// Saved progress: one localStorage JSON blob with a schema version and ordered migrations (the web stand-in for
// MatchAndDataService/DataMigration). Reads never throw: a blocked or corrupt store falls back to defaults in memory
// (the game still runs, it just forgets on reload). Writes are debounced and coalesced.

const STORAGE_KEY = 'rovloc.save';
const WRITE_DELAY_MS = 400;

/**
 * @typedef {{ version: number, data: Record<string, any> }} SaveBlob
 * @typedef {(data: Record<string, any>) => Record<string, any>} Migration
 */

export class Save {
  /**
   * @param {{ version?: number, defaults?: Record<string, any>, migrations?: Record<number, Migration>, key?: string }} [options]
   */
  constructor(options = {}) {
    this.key = options.key || STORAGE_KEY;
    this.version = options.version || 1;
    this.defaults = options.defaults || {};
    /** migrations[n] upgrades data written by version n - 1 to version n */
    this.migrations = options.migrations || {};
    this.persistent = true;
    this.timer = 0;
    /** @type {Record<string, any>} */
    this.data = this._load();
  }

  /** Registers defaults for keys that do not exist yet (later systems call this at start-up). */
  define(defaults) {
    for (const [k, v] of Object.entries(defaults)) if (!(k in this.data)) this.data[k] = clone(v);
  }

  /** Sets the schema version and its migrations (W4 owns the game's schema). Re-reads the stored blob. */
  configure({ version, defaults, migrations }) {
    if (version) this.version = version;
    if (defaults) this.defaults = defaults;
    if (migrations) this.migrations = migrations;
    this.data = this._load();
  }

  get(key, fallback) {
    return key in this.data ? this.data[key] : fallback;
  }

  set(key, value) {
    this.data[key] = clone(value);
    this._schedule();
  }

  /** Atomically updates the blob through `fn(data)` (it mutates or returns a new object). */
  update(fn) {
    const next = fn(this.data);
    if (next && typeof next === 'object') this.data = next;
    this._schedule();
    return this.data;
  }

  /** Writes now (also called on pagehide). */
  flush() {
    clearTimeout(this.timer);
    this.timer = 0;
    try {
      localStorage.setItem(this.key, JSON.stringify({ version: this.version, data: this.data }));
      this.persistent = true;
    } catch {
      this.persistent = false;
    }
  }

  reset() {
    this.data = clone(this.defaults);
    this.flush();
  }

  _schedule() {
    if (this.timer) return;
    this.timer = setTimeout(() => this.flush(), WRITE_DELAY_MS);
  }

  _load() {
    let blob = null;
    try {
      const raw = localStorage.getItem(this.key);
      blob = raw ? JSON.parse(raw) : null;
    } catch {
      this.persistent = false;
      blob = null;
    }
    let data = blob && typeof blob === 'object' && blob.data && typeof blob.data === 'object' ? blob.data : {};
    let version = blob && Number.isInteger(blob.version) ? blob.version : this.version;
    while (version < this.version) {
      version++;
      const migrate = this.migrations[version];
      if (migrate) {
        try {
          data = migrate(data) || data;
        } catch (err) {
          console.warn('[save] migration', version, 'failed', err);
        }
      }
    }
    const merged = clone(this.defaults);
    for (const [k, v] of Object.entries(data)) merged[k] = v;
    return merged;
  }
}

function clone(v) {
  return v === undefined ? undefined : JSON.parse(JSON.stringify(v));
}
