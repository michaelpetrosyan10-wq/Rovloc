// tracks.js: the port of Shared/Sequence/CinematicTracks.luau (docs/design/game-spec-v2.md 2.3), function for function.
// Pure: plain data in and out; the timelines are the world's own (world.json meta.storyConfig), never a copy here:
// cinematicTracks(meta) binds the functions to them. tools/story-test.mjs replays every CinematicTracks row of
// build/cache/golden.json against this port (I11).
//
//   ease(kind, u)                    cut 0 until u reaches 1, linear u, smooth smoothstep
//   catmullRom(points, times, t)     centripetal Catmull-Rom through points at times (the ends repeated), clamped
//   quantise(time, tick)             the first tick at or after `time` (a timeline's startAt, I8)
//   length(id, cut)                  a cut's length
//   toSource(id, cut, t)             the Full time a cut's time t shows, and its segment
//   sample(id, cut, t, binding)      everything the timeline shows at t (shot, view, camera, actors, lights, props,
//                                    rain, fade, card, day, rigs); binding: party actor -> its bin's slot
//   events(id, cut, t0, t1, players) the one-shot events (Sound, Shake) whose cut time is in (t0, t1]
//   lines(id, cut, t0, t1, players)  the lines starting in (t0, t1] that this many players hear, whole inside the cut
//   cast(runSeed, slots)             the seeded order of the squad's slots: P1, P2, ... (StoryCast)
//   cutFor(id, members)              "Short" when every member has seen the Full cut and none wants Full; else "Full"
//   skipOffered / skipPasses / skipTarget   the skip vote (2.3)
//   words / lineFits                 a line's words; whether it fits its slot
//   climbOutAt / chuteCutAt          the prologue's timers (4.1)
//
// Vectors are {x, y, z} in the timeline's origin frame (its CutsceneMark's), yaws in degrees (Roblox's: 0 looks along
// the frame's -Z).

import { Rng, shuffle } from '../util.js';

const EPS = 1e-9;
const KNOT_MIN = 1e-4;

/** A Luau array as JSON carries it: an empty table arrives as {} (JSON cannot tell it from an empty list). */
export const items = (list) => (Array.isArray(list) ? list : []);
/** Luau's % (floored). */
const mod = (a, b) => a - Math.floor(a / b) * b;
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const vec = (x, y, z) => ({ x, y, z });
const lerpVec = (a, b, u) => vec(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u, a.z + (b.z - a.z) * u);
const distance = (a, b) => {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const dz = b.z - a.z;
  return Math.sqrt(dx * dx + dy * dy + dz * dz);
};
/** The signed shortest turn from a to b (degrees, -180 < d <= 180). */
const turn = (a, b) => {
  let d = mod(b - a, 360);
  if (d > 180) d -= 360;
  return d;
};
const deg = (r) => (r * 180) / Math.PI;
const rad = (d) => (d * Math.PI) / 180;

/**
 * The cinematic tracks bound to a world's story.
 * @param {{storyConfig: any}} meta
 */
export function cinematicTracks(meta) {
  const story = meta && meta.storyConfig;
  if (!story || !story.Timelines) throw new Error('the world carries no storyConfig');

  const timelineOf = (id) => {
    const timeline = story.Timelines[id];
    if (!timeline) throw new Error(`CinematicTracks: no timeline ${id}`);
    return timeline;
  };
  const segmentsOf = (timeline, cut) => items((timeline.cuts && timeline.cuts[cut]) || timeline.cuts.Full);

  function ease(kind, u) {
    const v = clamp(u, 0, 1);
    if (kind === 'cut') return v >= 1 ? 1 : 0;
    if (kind === 'smooth') return v * v * (3 - 2 * v);
    return v;
  }

  /** Barry and Goldman's pyramid over four points at knots k0..k3, evaluated at s in [k1, k2]. */
  function pyramid(p, k, s) {
    const mix = (a, b, ka, kb) => lerpVec(a, b, (s - ka) / (kb - ka));
    const a1 = mix(p[0], p[1], k[0], k[1]);
    const a2 = mix(p[1], p[2], k[1], k[2]);
    const a3 = mix(p[2], p[3], k[2], k[3]);
    const b1 = mix(a1, a2, k[0], k[2]);
    const b2 = mix(a2, a3, k[1], k[3]);
    return mix(b1, b2, k[1], k[2]);
  }

  function catmullRom(points, times, t) {
    const n = points.length;
    if (n === 1 || t <= times[0]) return vec(points[0].x, points[0].y, points[0].z);
    if (t >= times[n - 1]) return vec(points[n - 1].x, points[n - 1].y, points[n - 1].z);
    let i = 0;
    while (i < n - 2 && t >= times[i + 1]) i++;
    const p1 = points[i];
    const p2 = points[i + 1];
    if (distance(p1, p2) < EPS) return vec(p1.x, p1.y, p1.z);
    const p0 = points[Math.max(i - 1, 0)];
    const p3 = points[Math.min(i + 2, n - 1)];
    const k = [0, 0, 0, 0];
    k[1] = k[0] + Math.max(Math.sqrt(distance(p0, p1)), KNOT_MIN);
    k[2] = k[1] + Math.max(Math.sqrt(distance(p1, p2)), KNOT_MIN);
    k[3] = k[2] + Math.max(Math.sqrt(distance(p2, p3)), KNOT_MIN);
    const u = (t - times[i]) / (times[i + 1] - times[i]);
    return pyramid([p0, p1, p2, p3], k, k[1] + (k[2] - k[1]) * u);
  }

  function quantise(time, tick) {
    return Math.ceil(time / tick - 1e-6) * tick;
  }

  function length(id, cut) {
    let total = 0;
    for (const s of segmentsOf(timelineOf(id), cut)) total += s.to - s.from;
    return total;
  }

  function toSource(id, cut, t) {
    const segments = segmentsOf(timelineOf(id), cut);
    let index = 0;
    for (let i = 0; i < segments.length; i++) if (t >= segments[i].at - EPS) index = i;
    const s = segments[index];
    return { t: clamp(s.from + (t - s.at), s.from, s.to), segment: index + 1 };
  }

  const segmentOf = (segments, source) => {
    for (const s of segments) if (source >= s.from - EPS && source < s.to - EPS) return s;
    return null;
  };
  const toCut = (segments, source) => {
    const s = segmentOf(segments, source);
    return s ? s.at + (source - s.from) : null;
  };
  const heardBy = (entry, players) => players >= (entry.minPlayers ?? 1) && players <= (entry.maxPlayers ?? 4);
  const trackOf = (timeline, actor) => items(timeline.actors).find((tr) => tr.actor === actor) || null;

  function resolveKeys(timeline, track, binding) {
    const out = [];
    const bins = timeline.points ? timeline.points.Bins : null;
    let last = null;
    for (const k of items(track.keys)) {
      let r;
      if (k.attach) {
        r = { t: k.t, parent: k.attach, offset: k.offset || vec(0, 0, 0), yaw: k.yaw ?? 0,
          cut: k.ease === 'cut' || (last !== null && last.parent !== k.attach) };
      } else {
        let pos = k.pos || null;
        if (k.bin) {
          const slot = binding[track.actor];
          const bin = bins && slot !== undefined ? bins[slot - 1] : null;
          pos = bin ? bin[k.bin] : null;
          if (!pos && last) pos = last.pos;
        }
        const p = pos || vec(0, 0, 0);
        let yaw = k.yaw;
        if (yaw === undefined || yaw === null) {
          yaw = last ? last.yaw : 0;
          const from = last ? last.pos : null;
          if (from && k.bin !== 'Over' && k.bin !== 'Inside') {
            const dx = p.x - from.x;
            const dz = p.z - from.z;
            if (dx * dx + dz * dz > 1e-4) yaw = deg(Math.atan2(-dx, -dz));
          }
        }
        r = { t: k.t, pos: vec(p.x, p.y, p.z), yaw, parent: null,
          cut: k.ease === 'cut' || (last !== null && last.parent !== null && last.parent !== undefined) };
      }
      out.push(r);
      last = r;
    }
    return out;
  }

  function actorPose(timeline, actor, t, binding, depth) {
    const track = trackOf(timeline, actor);
    if (!track || items(track.keys).length === 0) return { pos: vec(0, 0, 0), yaw: 0 };
    const keys = resolveKeys(timeline, track, binding);
    let i = 0;
    for (let j = 0; j < keys.length; j++) if (keys[j].t <= t + EPS) i = j;
    let first = i;
    while (first > 0 && !keys[first].cut) first--;
    let finish = i;
    while (finish < keys.length - 1 && !keys[finish + 1].cut) finish++;
    const here = keys[i];
    const next = i < finish ? keys[i + 1] : null;
    const u = next && t > here.t ? (t - here.t) / (next.t - here.t) : 0;
    let yaw = here.yaw;
    if (next) yaw = here.yaw + turn(here.yaw, next.yaw) * ease('smooth', u);
    if (here.parent) {
      let offset = here.offset;
      if (next && next.offset) offset = lerpVec(offset, next.offset, ease('smooth', u));
      const parent = depth < 2 ? actorPose(timeline, here.parent, t, binding, depth + 1) : { pos: vec(0, 0, 0), yaw: 0 };
      const a = rad(parent.yaw);
      const c = Math.cos(a);
      const s = Math.sin(a);
      const pos = vec(parent.pos.x + c * offset.x + s * offset.z, parent.pos.y + offset.y, parent.pos.z - s * offset.x + c * offset.z);
      return { pos, yaw: parent.yaw + yaw };
    }
    const points = [];
    const times = [];
    for (let j = first; j <= finish; j++) {
      points.push(keys[j].pos);
      times.push(keys[j].t);
    }
    return { pos: catmullRom(points, times, t), yaw };
  }

  const clipAt = (track, t) => {
    let found = null;
    for (const c of items(track.clips)) if (c.t0 <= t + EPS) found = c;
    return found;
  };

  function cameraAt(timeline, t) {
    const keys = items(timeline.camera);
    if (keys.length === 0) return null;
    let i = 0;
    for (let j = 0; j < keys.length; j++) if (keys[j].t <= t + EPS) i = j;
    const here = keys[i];
    const next = keys[i + 1];
    if (!next || next.ease === 'cut' || next.t <= here.t) return { eye: here.eye, target: here.target, fov: here.fov };
    const u = ease(next.ease, (t - here.t) / (next.t - here.t));
    return { eye: lerpVec(here.eye, next.eye, u), target: lerpVec(here.target, next.target, u),
      fov: here.fov + (next.fov - here.fov) * u };
  }

  function fadeAt(timeline, t) {
    let level = 0;
    for (const e of items(timeline.events)) {
      if (e.kind !== 'Fade' || e.t > t + EPS) continue;
      const seconds = e.args.seconds;
      const u = seconds > 0 ? clamp((t - e.t) / seconds, 0, 1) : 1;
      level = level + (e.args.to - level) * u;
    }
    return level;
  }

  function dayAt(timeline, t) {
    const keys = items(timeline.day);
    if (keys.length === 0) return { amount: 0, tint: vec(1, 1, 1) };
    let i = 0;
    for (let j = 0; j < keys.length; j++) if (keys[j].t <= t + EPS) i = j;
    const here = keys[i];
    const next = keys[i + 1];
    if (!next || t <= here.t) return { amount: here.amount, tint: vec(here.tint.x, here.tint.y, here.tint.z) };
    const u = (t - here.t) / (next.t - here.t);
    return { amount: here.amount + (next.amount - here.amount) * u, tint: lerpVec(here.tint, next.tint, u) };
  }

  function sample(id, cut, t, binding) {
    const timeline = timelineOf(id);
    const source = toSource(id, cut, t).t;
    const shots = items(timeline.shots);
    let shot = shots[0];
    for (const s of shots) if (s.t0 <= source + EPS) shot = s;
    const events = items(timeline.events);
    const rigs = {};
    for (const e of events) if (e.kind === 'Rig' && e.t <= source + EPS) rigs[e.args.actor] = e.args.into;
    const actors = {};
    for (const track of items(timeline.actors)) {
      const pose = actorPose(timeline, track.actor, source, binding, 0);
      const clip = clipAt(track, source);
      const name = clip ? clip.name : 'Hidden';
      const swapped = rigs[track.actor] !== undefined && rigs[track.actor] !== track.actor;
      const bound = track.kind !== 'Party' || binding[track.actor] !== undefined;
      actors[track.actor] = { pos: pose.pos, yaw: pose.yaw, clip: name, clipTime: clip ? source - clip.t0 : 0,
        rate: clip && clip.slow ? 1 / clip.slow : 1, visible: name !== 'Hidden' && !swapped && bound };
    }
    let card = null;
    for (const e of events) {
      if (e.kind === 'Card' && e.t <= source + EPS && source < e.t + e.args.seconds) {
        card = { text: e.args.text, age: source - e.t, seconds: e.args.seconds };
      }
    }
    const lights = {};
    const props = {};
    let rain = false;
    for (const e of events) {
      if (e.t > source + EPS) continue;
      if (e.kind === 'Light') lights[e.args.group] = e.args.mode;
      else if (e.kind === 'Prop') props[e.args.actor ? `${e.args.id}:${e.args.actor}` : e.args.id] = e.args.state;
      else if (e.kind === 'Rain') rain = e.args.on;
    }
    const out = { shot: shot.id, view: shot.view, source, actors, lights, props, rain, fade: fadeAt(timeline, source),
      day: dayAt(timeline, source), rigs };
    const camera = cameraAt(timeline, source);
    if (camera) out.camera = camera;
    if (card) out.card = card;
    return out;
  }

  function events(id, cut, t0, t1, players) {
    const timeline = timelineOf(id);
    const segments = segmentsOf(timeline, cut);
    const out = [];
    items(timeline.events).forEach((e, i) => {
      if ((e.kind !== 'Sound' && e.kind !== 'Shake') || !heardBy(e, players)) return;
      const at = toCut(segments, e.t);
      if (at !== null && at > t0 + EPS && at <= t1 + EPS) out.push({ index: i + 1, at, t: e.t, kind: e.kind, args: e.args });
    });
    out.sort((a, b) => (a.at === b.at ? a.index - b.index : a.at - b.at));
    return out;
  }

  function lines(id, cut, t0, t1, players) {
    const timeline = timelineOf(id);
    const segments = segmentsOf(timeline, cut);
    const out = [];
    for (const line of items(timeline.lines)) {
      const s = heardBy(line, players) ? segmentOf(segments, line.t) : null;
      if (!s || line.t + line.slot > s.to + EPS) continue;
      const at = s.at + (line.t - s.from);
      if (at > t0 + EPS && at <= t1 + EPS) out.push({ id: line.id, at, slot: line.slot });
    }
    out.sort((a, b) => a.at - b.at);
    return out;
  }

  function cast(runSeed, slots) {
    const order = items(slots).slice().sort((a, b) => a - b);
    return shuffle(order, Rng.seeded(runSeed, 'StoryCast'));
  }

  function cutFor(id, members) {
    const timeline = timelineOf(id);
    const list = items(members);
    if (!timeline.cuts.Short || list.length === 0) return 'Full';
    for (const m of list) if (!m.seenFull || m.wantsFull) return 'Full';
    return 'Short';
  }

  function skipTarget(id, cut) {
    const timeline = timelineOf(id);
    const shots = items(timeline.shots);
    const last = shots[shots.length - 1];
    let best = length(id, cut);
    for (const s of segmentsOf(timeline, cut)) {
      const from = Math.max(s.from, last.t0);
      if (from < s.to - EPS) best = Math.min(best, s.at + (from - s.from));
    }
    return best;
  }

  function skipOffered(id, cut, t) {
    return t >= story.Skip.From - EPS && t < skipTarget(id, cut) - EPS;
  }

  function skipPasses(id, players, voters, unseen) {
    const timeline = timelineOf(id);
    const v = items(voters);
    const u = items(unseen);
    if (players <= 0 || v.length * 2 <= players) return false;
    if (timeline.skip === 'SeenOnly' && u.length > 0) return false;
    const voted = new Set(v);
    return u.every((m) => voted.has(m));
  }

  function words(text) {
    const m = String(text).match(/\S+/g);
    return m ? m.length : 0;
  }

  function lineFits(text, rate, slot) {
    const n = words(text);
    return n <= story.Speech.MaxWords && n / (story.Speech.WordsPerSecond * rate) <= slot + EPS;
  }

  function climbOutAt(handOver) {
    return handOver + story.Prologue.AutoClimbOut;
  }

  function chuteCutAt(handOver, firstIn, allIn) {
    const p = story.Prologue;
    let due = handOver + p.MaxSeconds;
    if (firstIn >= 0) due = Math.min(due, firstIn + p.ChuteWait);
    if (allIn >= 0) due = Math.min(due, allIn);
    return due;
  }

  return { story, ease, catmullRom, quantise, length, toSource, sample, events, lines, cast, cutFor, skipOffered,
    skipPasses, skipTarget, words, lineFits, climbOutAt, chuteCutAt, timeline: (id) => story.Timelines[id] || null };
}
