// Player settings (SettingsSchema + SettingsController): keys, ranges and defaults, sanitized on every write and
// persisted in the save blob under "settings".

import { SettingsList } from './config.js';
import { Signal } from './signal.js';

export class Settings {
  /** @param {import('./save.js').Save} save */
  constructor(save) {
    this.save = save;
    /** @type {Signal<[string, any]>} (key, value) after a change */
    this.changed = new Signal();
    /** @type {Record<string, any>} */
    this.values = {};
    for (const s of SettingsList) this.values[s.key] = s.default;
    const stored = save.get('settings', {});
    for (const [k, v] of Object.entries(stored || {})) {
      const clean = Settings.sanitize(k, v);
      if (clean !== undefined) this.values[k] = clean;
    }
  }

  static schema(key) {
    return SettingsList.find((s) => s.key === key);
  }

  /** Every entry the settings menu draws, in order. */
  static visible() {
    return SettingsList.filter((s) => !s.hidden);
  }

  /** Clamps, snaps and type-checks one value; undefined for unknown keys or wrong types. */
  static sanitize(key, value) {
    const s = Settings.schema(key);
    if (!s) return undefined;
    if (s.kind === 'Bool') return typeof value === 'boolean' ? value : undefined;
    if (s.kind === 'Choice') return s.options.includes(value) ? value : undefined;
    if (typeof value !== 'number' || !Number.isFinite(value)) return undefined;
    const snapped = Math.round(value / s.step) * s.step;
    return Math.min(s.max, Math.max(s.min, Number(snapped.toFixed(4))));
  }

  get(key) {
    return this.values[key];
  }

  set(key, value) {
    const clean = Settings.sanitize(key, value);
    if (clean === undefined || clean === this.values[key]) return;
    this.values[key] = clean;
    this.save.set('settings', this.values);
    this.changed.fire(key, clean);
  }
}
