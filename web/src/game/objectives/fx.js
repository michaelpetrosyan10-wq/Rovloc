// fx.js: the objectives' small effects: a short-lived glow light (the keypad turning green), fading over its last
// moments. Everything is cleared at the end of a run.

export class ObjectiveFx {
  /** @param {import('../env.js').Env} env */
  constructor(env) {
    this.env = env;
    /** @type {{light: any, until: number, fade: number, brightness: number}[]} */
    this.lights = [];
  }

  /** A point light for `seconds` (fading over the last `fade`); returns its handle. */
  glow(at, color, brightness, range, seconds, fade = 0.4) {
    const light = this.env.addLight({ position: at.clone(), color, brightness, range });
    this.lights.push({ light, until: seconds === Infinity ? Infinity : this.env.now() + seconds, fade, brightness });
    return light;
  }

  clear() {
    for (const l of this.lights) l.light.remove();
    this.lights.length = 0;
  }

  frame() {
    const now = this.env.now();
    for (let i = this.lights.length - 1; i >= 0; i--) {
      const l = this.lights[i];
      const left = l.until - now;
      if (left <= 0) {
        l.light.remove();
        this.lights.splice(i, 1);
      } else if (left < l.fade) l.light.set({ brightness: l.brightness * (left / l.fade) });
    }
  }
}
