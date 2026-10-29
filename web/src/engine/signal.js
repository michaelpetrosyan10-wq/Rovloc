// A typed, immediate-fire signal (Shared/Util/Signal.luau). Handlers run in connection order; a handler that throws
// is logged and does not stop the others.

/** @template {any[]} T */
export class Signal {
  constructor() {
    /** @type {Array<(...args: T) => void>} */
    this.handlers = [];
  }

  /**
   * @param {(...args: T) => void} fn
   * @returns {() => void} disconnect
   */
  connect(fn) {
    this.handlers.push(fn);
    return () => {
      const i = this.handlers.indexOf(fn);
      if (i >= 0) this.handlers.splice(i, 1);
    };
  }

  /** @param {(...args: T) => void} fn */
  once(fn) {
    const off = this.connect((...args) => {
      off();
      fn(...args);
    });
    return off;
  }

  /** @param {T} args */
  fire(...args) {
    const list = this.handlers.slice();
    for (const fn of list) {
      try {
        fn(...args);
      } catch (err) {
        console.warn('[signal] handler failed', err);
      }
    }
  }

  clear() {
    this.handlers.length = 0;
  }
}
