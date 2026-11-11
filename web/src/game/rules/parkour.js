// parkour.js: the port of Shared/Rules/ParkourRules.luau (docs/design/game-spec-v2.md 3.1; invariants I8 and I9),
// function for function. Pure: plain numbers and tables in and out, no engine, clock or randomness. The numbers are the
// world's own (world.json meta.parkourConfig), never a copy here: parkourRules(meta) binds the functions to them. Every
// curve is a function of the time since its start, and a start lands on a 30 Hz tick, so the motion is the same at any
// frame rate. tools/parkour-test.mjs replays every ParkourRules row of build/cache/golden.json against this port.
//
//   startTick     the time a move started at `time` begins: the next 30 Hz tick at or after it
//   leap          the leap at `t` seconds after its start, taking off `takeoff` studs before the near lip: `along` the
//                 leap direction (a straight line to Overshoot past the far edge, the side offset kept), `height` over
//                 the take-off (a parabola of apex Apex), `done` once Seconds have passed
//   leapLength    the studs a leap covers from a take-off `takeoff` before the lip
//   jumpPress     what a jump press does: a leap Request inside the approach band (the Band studs before the strip's
//                 end, or up to Coyote seconds after running off the edge), a free Jump elsewhere on the ground, None
//                 in the air
//   canLeap       whether a leap starts this tick (Leap), or why not: Outside, Slow, Heading, NoRequest
//   assistOn      the Leap assist setting for a device: Auto is on for touch and gamepad, off for the keyboard
//   serverLeap    the Roblox server's check of a leap: in the strip, observed speed and facing
//   slideStarts   whether a crouch press starts a slide (on the ground, sprinting, fast enough) or crouches
//   slide         the slide at `t`: its speed (SpeedStart falling linearly to SpeedEnd), the distance so far, done
//   slideEnd      how a slide ends: Standing with the headroom for it, else Crouching
//   hardLanding   a landing after a fall of `fall` studs: hard (slowed, HardLanding noise) from Fall; never damage
//   hurdleOk, wallOk, gapOk, slideBarOk, streetOk, freeJumpOk, landingOk  the envelope (I9)

/**
 * @typedef {{inStrip: boolean, sinceEdge: number, requestAge: number, speed: number, heading: number, assist: boolean}} LeapAsk
 *   sinceEdge: seconds since the root left the lip (-1: still on this side); requestAge: seconds since the request was
 *   made (-1: none); speed: horizontal studs per second; heading: degrees between the motion and the leap direction
 */

const EPS = 1e-6;
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

/**
 * The parkour rules bound to a world's numbers.
 * @param {{parkourConfig: Record<string, Record<string, number>>}} meta
 */
export function parkourRules(meta) {
  const config = meta && meta.parkourConfig;
  if (!config || !config.Leap || !config.Slide || !config.Tick) throw new Error('the world carries no parkourConfig');
  const LEAP = config.Leap;
  const SLIDE = config.Slide;

  function startTick(time) {
    const hz = config.Tick.Hz;
    return Math.ceil(time * hz - EPS) / hz;
  }

  function leapLength(takeoff) {
    return takeoff + LEAP.Gap + LEAP.Overshoot;
  }

  /** @returns {{along: number, height: number, done: boolean}} */
  function leap(t, takeoff) {
    const u = clamp(t / LEAP.Seconds, 0, 1);
    return {
      along: leapLength(takeoff) * u,
      height: 4 * LEAP.Apex * u * (1 - u),
      done: t >= LEAP.Seconds - EPS,
    };
  }

  /** @returns {'Request'|'Jump'|'None'} */
  function jumpPress(onGround, toEdge, sinceEdge) {
    if (onGround) return toEdge >= 0 && toEdge <= LEAP.Band ? 'Request' : 'Jump';
    return sinceEdge >= 0 && sinceEdge <= LEAP.Coyote + EPS ? 'Request' : 'None';
  }

  /** @param {LeapAsk} ask @returns {'Leap'|'Outside'|'Slow'|'Heading'|'NoRequest'} */
  function canLeap(ask) {
    const justPast = ask.sinceEdge >= 0 && ask.sinceEdge <= LEAP.Coyote + EPS;
    if (!ask.inStrip && !justPast) return 'Outside';
    if (ask.speed < LEAP.MinSpeed) return 'Slow';
    if (ask.heading > LEAP.MaxHeading) return 'Heading';
    const live = ask.requestAge >= 0 && ask.requestAge <= LEAP.RequestHold + EPS;
    if (live || (ask.assist && ask.inStrip)) return 'Leap';
    return 'NoRequest';
  }

  function assistOn(setting, device) {
    if (setting === 'On') return true;
    if (setting === 'Off') return false;
    return device !== 'KeyboardMouse';
  }

  function serverLeap(inStrip, observedSpeed, facing) {
    return inStrip && observedSpeed >= LEAP.ServerMinSpeed && facing <= LEAP.ServerMaxHeading;
  }

  function slideStarts(onGround, sprinting, speed) {
    return onGround && sprinting && speed >= SLIDE.MinSpeed;
  }

  /** @returns {{speed: number, distance: number, done: boolean}} */
  function slide(t) {
    const s = clamp(t, 0, SLIDE.Seconds);
    const fall = (SLIDE.SpeedStart - SLIDE.SpeedEnd) / SLIDE.Seconds;
    return {
      speed: SLIDE.SpeedStart - fall * s,
      distance: SLIDE.SpeedStart * s - (fall * s * s) / 2,
      done: t >= SLIDE.Seconds - EPS,
    };
  }

  /** @returns {'Standing'|'Crouching'} */
  function slideEnd(headroom) {
    return headroom >= SLIDE.StandHeight ? 'Standing' : 'Crouching';
  }

  /** @returns {{hard: boolean, seconds: number, speedFactor: number, noise: string, damage: number}} */
  function hardLanding(fall) {
    const c = config.HardLanding;
    if (fall >= c.Fall) return { hard: true, seconds: c.Seconds, speedFactor: c.SpeedFactor, noise: 'HardLanding', damage: 0 };
    return { hard: false, seconds: 0, speedFactor: 1, noise: '', damage: 0 };
  }

  function hurdleOk(height, depth) {
    const c = config.Hurdle;
    return height >= c.Min - EPS && height <= c.Max + EPS && depth <= c.MaxDepth + EPS;
  }

  function wallOk(height) {
    return height >= config.Wall.Min - EPS;
  }

  function gapOk(width) {
    return Math.abs(width - LEAP.Gap) <= 1e-3;
  }

  function slideBarOk(clear, solidTop, depth) {
    return Math.abs(clear - SLIDE.Clear) <= 1e-3 && solidTop >= SLIDE.SolidTop - EPS && depth <= SLIDE.MaxDepth + EPS;
  }

  function streetOk(width) {
    return width >= config.Street.Min - EPS;
  }

  function freeJumpOk(longest) {
    return longest < config.FreeJump.Max;
  }

  function landingOk(drop) {
    return drop >= -EPS && drop <= LEAP.LandingDrop + EPS;
  }

  return Object.freeze({
    config,
    startTick,
    leapLength,
    leap,
    jumpPress,
    canLeap,
    assistOn,
    serverLeap,
    slideStarts,
    slide,
    slideEnd,
    hardLanding,
    hurdleOk,
    wallOk,
    gapOk,
    slideBarOk,
    streetOk,
    freeJumpOk,
    landingOk,
  });
}
