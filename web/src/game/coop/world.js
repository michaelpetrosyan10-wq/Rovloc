// world.js: the host's world, mirrored on the clients.
//
// Host-run systems. The level controllers (Level0-5: the basement beats, the classroom scare, the flask restock, the
// gym's pressure, the roof finale) and the Creature's level hook decide on the host only: on a client they are marked
// `hostOnly` and the game skips their ticks and level hooks (game.js _follows). What they do is sent as it happens,
// while one of them is the running system (game.current): scene timelines ({t: 'seq'}, start time relative, Vector3 /
// Matrix4 args encoded, `subject` true on the page of the player the scene happened to), lighting changes ({t: 'light'}:
// overrides, bursts, group factors, lightning, the storm), one-shot sounds ({t: 'snd'}) and toasts ({t: 'note2'}).
// Doors, from anything on the host ({t: 'door'}: the airlock seals, the scenes' slams, the objectives' unlocks), and
// grates the Creature kicks ({t: 'grate'}); the Creature's one-shot animations ({t: 'cact'}: NeckSnap, Vanish, Lunge,
// DoorSmash, Reveal) with their start time.
// Digest. Once a second the host sends the doors', grates' and floor objectives' state ({t: 'dig'}); a client whose
// own copy disagrees in two digests running (a lost or late event) is put right: a door set, a grate forced, a step
// count copied, a floor unlocked.

import * as THREE from 'three';

const DIGEST_SECONDS = 1;
export const HOST_ONLY = new Set(['Level0', 'Level1', 'Level2', 'Level3', 'Level5', 'CreatureLevels']);

/** Encodes timeline args (Vector3 -> {v: [x, y, z]}, Matrix4 -> {m: [16]}); functions are dropped. */
export function encodeArgs(args) {
  const out = {};
  for (const [k, v] of Object.entries(args || {})) {
    const e = encodeValue(v);
    if (e !== undefined) out[k] = e;
  }
  return out;
}

function encodeValue(v) {
  if (v === null || typeof v === 'number' || typeof v === 'string' || typeof v === 'boolean') return v;
  if (v && v.isVector3) return { v: [v.x, v.y, v.z] };
  if (v && v.isMatrix4) return { m: Array.from(v.elements) };
  if (Array.isArray(v)) return v.map(encodeValue);
  return undefined;
}

export function decodeArgs(args) {
  const out = {};
  for (const [k, v] of Object.entries(args || {})) out[k] = decodeValue(v);
  return out;
}

function decodeValue(v) {
  if (v && typeof v === 'object' && !Array.isArray(v)) {
    if (Array.isArray(v.v)) return new THREE.Vector3(v.v[0], v.v[1], v.v[2]);
    if (Array.isArray(v.m)) return new THREE.Matrix4().fromArray(v.m);
  }
  if (Array.isArray(v)) return v.map(decodeValue);
  return v;
}

const vec = (p) => (p ? [p.x, p.y, p.z] : null);
const unvec = (a) => (Array.isArray(a) ? new THREE.Vector3(a[0], a[1], a[2]) : null);

export class WorldNet {
  /** @param {import('./index.js').Coop} coop */
  constructor(coop) {
    this.coop = coop;
    this.game = coop.game;
    this.env = coop.game.env;
    this.installed = false;
    this.restore = [];
    this.digestClock = 0;
    /** @type {Map<string, number>} mismatch counts per digest entry */
    this.strikes = new Map();
    /** the member a scene being started happened to (Level 1 sets it around its play) */
    this.sceneSubject = null;
    /** mirror() is running: a host-run part of a shared system */
    this.forced = false;
    this.handlers = {
      seq: (from, msg) => this._onSeq(msg),
      light: (from, msg) => this._onLight(msg),
      snd: (from, msg) => this._onSound(msg),
      note2: (from, msg) => this.game.notify(msg.k, ...(msg.a || [])),
      door: (from, msg) => this._onDoor(msg),
      grate: (from, msg) => this._onGrate(msg),
      cact: (from, msg) => this._onCreatureAction(msg),
      dig: (from, msg) => this._onDigest(msg),
    };
  }

  /** Marks the host-run systems (they follow on a client). */
  sessionStarted() {
    for (const s of this.game.systems) if (HOST_ONLY.has(s.name)) s.hostOnly = true;
    if (this.coop.isHost()) this._installHost();
  }

  sessionEnding() {
    for (const fn of this.restore.splice(0)) fn();
    this.installed = false;
    for (const s of this.game.systems) if (HOST_ONLY.has(s.name)) s.hostOnly = false;
  }

  /** Whether the running code is a host-run system (its effects are mirrored). */
  _mirroring() {
    if (!this.coop.isHost() || this.coop.actor) return false;
    if (this.forced) return true;
    const s = this.game.current;
    return !!s && !!s.hostOnly;
  }

  /** Host: runs `fn` with its scenes, lights, sounds and toasts mirrored on the clients (a host-run part of a system). */
  mirror(fn) {
    const before = this.forced;
    this.forced = true;
    try {
      return fn();
    } finally {
      this.forced = before;
    }
  }

  /** Replaces obj[name] with a wrapper (restored when the room closes). */
  _wrap(obj, name, make) {
    if (!obj || typeof obj[name] !== 'function') return;
    const original = obj[name];
    const own = Object.prototype.hasOwnProperty.call(obj, name);
    obj[name] = make(original.bind(obj));
    this.restore.push(() => {
      if (own) obj[name] = original;
      else delete obj[name];
    });
  }

  _installHost() {
    if (this.installed) return;
    this.installed = true;
    const game = this.game;
    const env = this.env;
    const coop = this.coop;
    const now = () => env.now();
    this._wrap(game.seq, 'play', (play) => (id, startAt, args = {}) => {
      if (this._mirroring()) {
        coop.broadcast({ t: 'seq', id, in: Math.max(0, startAt - now()), args: encodeArgs(args), sub: this.sceneSubject });
      }
      return play(id, startAt, args);
    });
    const light = (name, op, encode) => this._wrap(env, name, (fn) => (...a) => {
      if (this._mirroring()) coop.broadcast({ t: 'light', op, a: encode(a) });
      return fn(...a);
    });
    light('setLightOverride', 'override', (a) => [a[0], a[1] ?? null]);
    light('burstLight', 'burst', (a) => [a[0]]);
    light('setGroupFactor', 'group', (a) => [a[0], a[1] ?? null]);
    light('lightning', 'lightning', (a) => [a[0] ?? 1, a[1] ?? 2]);
    light('setStormEnabled', 'storm', (a) => [!!a[0]]);
    this._wrap(game, 'playAt', (fn) => (preset, position, opts = {}) => {
      if (this._mirroring() && !opts.loop && !opts.follow && position) {
        coop.broadcast({ t: 'snd', p: preset, at: vec(position.isVector3 ? position : new THREE.Vector3(...position)),
          v: opts.volume ?? null, s: opts.speed ?? null });
      }
      return fn(preset, position, opts);
    });
    this._wrap(game, 'notify', (fn) => (key, ...args) => {
      if (this._mirroring()) coop.broadcast({ t: 'note2', k: key, a: args });
      return fn(key, ...args);
    });
    if (game.doors && game.doors.stateChanged) {
      const off = game.doors.stateChanged.connect((door, previous, state) => {
        if (!coop.isHost()) return;
        const seconds = door.motion ? door.motion.seconds : 0;
        coop.broadcast({ t: 'door', id: door.id, s: state, sec: seconds });
      });
      this.restore.push(off);
    }
    if (game.vents) {
      this._wrap(game.vents, 'force', (fn) => (id, state) => {
        const r = fn(id, state);
        coop.broadcast({ t: 'grate', id, s: state });
        return r;
      });
    }
    const view = game.creature && game.creature.c ? game.creature.c.view : null;
    if (view) {
      this._wrap(view, 'playAction', (fn) => (name, startAt) => {
        const at = Number.isFinite(startAt) ? startAt : now();
        coop.broadcast({ t: 'cact', n: name, in: at - now() });
        return fn(name, startAt);
      });
    }
  }

  // ---------------------------------------------------------------------------------------------------- client side

  _onSeq(msg) {
    if (!this.coop.isClient()) return;
    const args = decodeArgs(msg.args);
    args.subject = !!msg.sub && msg.sub === this.coop.localId;
    this.game.seq.play(msg.id, this.env.now() + (msg.in || 0), args);
  }

  _onLight(msg) {
    if (!this.coop.isClient()) return;
    const env = this.env;
    const a = msg.a || [];
    if (msg.op === 'override') env.setLightOverride(a[0], a[1]);
    else if (msg.op === 'burst') env.burstLight(a[0]);
    else if (msg.op === 'group') env.setGroupFactor(a[0], a[1]);
    else if (msg.op === 'lightning') env.lightning(a[0], a[1]);
    else if (msg.op === 'storm') env.setStormEnabled(a[0]);
  }

  _onSound(msg) {
    if (!this.coop.isClient()) return;
    const at = unvec(msg.at);
    if (!at) return;
    const opts = {};
    if (msg.v !== null && msg.v !== undefined) opts.volume = msg.v;
    if (msg.s !== null && msg.s !== undefined) opts.speed = msg.s;
    this.game.playAt(msg.p, at, opts);
  }

  _onDoor(msg) {
    if (!this.coop.isClient() || !this.game.doors) return;
    const door = this.game.doors.get(msg.id);
    if (door && door.state !== msg.s) this.game.doors.setState(door, msg.s, msg.sec);
  }

  _onGrate(msg) {
    if (!this.coop.isClient() || !this.game.vents) return;
    if (this.game.vents.stateOf(msg.id) !== msg.s) this.game.vents.force(msg.id, msg.s);
  }

  _onCreatureAction(msg) {
    if (!this.coop.isClient()) return;
    const view = this.game.creature && this.game.creature.c ? this.game.creature.c.view : null;
    if (view) view.playAction(msg.n, this.env.now() + (msg.in || 0));
  }

  // ---------------------------------------------------------------------------------------------------- digest

  _digest() {
    const game = this.game;
    const doors = {};
    if (game.doors && game.doors.byId) for (const d of game.doors.byId.values()) doors[d.id] = d.state;
    const grates = {};
    if (game.vents && game.vents.grates) for (const g of game.vents.grates.values()) grates[g.id] = g.state;
    const floors = {};
    if (game.floors) {
      for (const [level, f] of game.floors.floors) {
        const taken = [...f.taken].sort();
        floors[level] = { p: Object.fromEntries(f.progress), u: f.unlocked, t: taken,
          h: taken.filter((id) => { const e = this.env.entity(id); return !e || e.hidden; }) };
      }
    }
    return { t: 'dig', d: doors, g: grates, o: floors };
  }

  _strike(key, wrong) {
    if (!wrong) {
      this.strikes.delete(key);
      return false;
    }
    const n = (this.strikes.get(key) || 0) + 1;
    this.strikes.set(key, n);
    return n >= 2;
  }

  _onDigest(msg) {
    const game = this.game;
    if (!this.coop.isClient() || !game.run) return;
    if (game.doors) {
      for (const [id, state] of Object.entries(msg.d || {})) {
        const door = game.doors.get(id);
        if (!door) continue;
        if (this._strike(`d:${id}`, door.state !== state && !game.doors.isMoving(door))) game.doors.setState(door, state);
      }
    }
    if (game.vents) {
      for (const [id, state] of Object.entries(msg.g || {})) {
        const mine = game.vents.stateOf(id);
        const settling = mine === 'Unscrewing' || state === 'Unscrewing';
        if (this._strike(`g:${id}`, mine !== state && !settling)) game.vents.force(id, state);
      }
    }
    if (game.floors) {
      for (const [level, o] of Object.entries(msg.o || {})) {
        const f = game.floors.floor(level);
        if (!f) continue;
        const taken = o.t || [];
        const same = Object.entries(o.p || {}).every(([k, v]) => f.count(k) === v) && f.unlocked === o.u &&
          taken.length === f.taken.size && taken.every((id) => f.taken.has(id));
        if (this._strike(`o:${level}`, !same)) {
          for (const [k, v] of Object.entries(o.p || {})) f.progress.set(k, v);
          // items the squad has taken (a late joiner never saw them go): gone from the world here too
          f.taken = new Set(taken);
          for (const id of o.h || []) this.env.setEntityVisible(id, false);
          if (o.u && !f.unlocked) f.unlock();
          f.refresh();
        }
      }
    }
  }

  tick(dt) {
    if (!this.coop.isHost() || !this.game.run) return;
    this.digestClock += dt;
    if (this.digestClock < DIGEST_SECONDS) return;
    this.digestClock = 0;
    this.coop.broadcast(this._digest());
  }

  endRun() {
    this.strikes.clear();
  }
}
