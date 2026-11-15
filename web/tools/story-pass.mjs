// story-pass.mjs: how the test bots get through the Back Lot by the rules (docs/design/game-spec-v2.md 2.3, 4.1), for
// the tools whose subject is later (lives-test, radar-test, objective-run, game-smoke):
//
//   passOpening(tab, G, ff)    the opening: from Skip.From in, hold Skip (Enter) Skip.Hold: alone the vote passes at
//                              once, the fade, the last shot to its end (the hand-over)
//   passPrologue(tab, G, ff)   the prologue: push the lid (hold Interact), the climb-out, stood at the hatch, "Climb in"
//                              (hold Interact): alone everyone is in, the chute's cut, on to the Basement
//   passBackLot(tab, G, ff)    both
//
// `G(fn, arg)` runs fn(game, dev, arg) in the page; `ff(seconds)` steps the page's game at 30 Hz. The page must be a
// solo run deployed on the Back Lot. Returns what the page shows after it: {phase, stage, level}.

/** A frame of the hatch's approach: in front of the hatch, inside its ChuteHatch trigger, facing it (check.mjs too). */
export const AT_HATCH = [30, 21.5, 294.5, 1, 0, 0, 0, 1, 0, 0, 0, 1];

export async function passOpening(tab, G, ff) {
  let at = await G((g) => ({ t: g.cinematics.time(), from: g.cinematics.story.Skip.From, hold: g.cinematics.story.Skip.Hold,
    active: g.cinematics.active() }));
  if (!at.active) return G((g) => ({ phase: g.phase, stage: g.stage, level: g.level }));
  if (at.t < at.from + 0.05) await ff(at.from + 0.05 - at.t);
  await tab.keyboard.down('Enter');
  await ff(at.hold + 0.1);
  await tab.keyboard.up('Enter');
  // the fade, then the last shot to the hand-over
  at = await G((g) => ({ fade: g.cinematics.story.Skip.Fade }));
  await ff(at.fade + 0.1);
  const left = await G((g) => (g.cinematics.current ? g.cinematics.current.length - g.cinematics.time() : 0));
  await ff(left + 0.1);
  return G((g) => ({ phase: g.phase, stage: g.stage, level: g.level, prologue: g.prologue.state }));
}

export async function passPrologue(tab, G, ff) {
  const p = await G((g) => g.prologue.p);
  await tab.keyboard.down('KeyE');
  await ff(p.LidHold + 0.15);
  await tab.keyboard.up('KeyE');
  await ff(p.ClimbOut + 0.2);
  await G((g, dev, frame) => {
    g.env.teleport(frame);
    g.env.setLook(0, -0.6);
  }, AT_HATCH);
  await ff(0.3);
  await tab.keyboard.down('KeyE');
  await ff(p.ClimbHold + 0.15);
  await tab.keyboard.up('KeyE');
  await ff(p.ChuteCut + 0.4);
  return G((g) => ({ phase: g.phase, stage: g.stage, level: g.level }));
}

export async function passBackLot(tab, G, ff) {
  await passOpening(tab, G, ff);
  return passPrologue(tab, G, ff);
}

/**
 * The same for pages playing in real time (a squad; coop-test, radar-test): every page votes the opening away once the
 * vote is offered (the squad's vote passes), then each climbs out, is stood at the hatch (its own place there) and
 * climbs in: everyone is in, the host's cut, the Basement on every page. `G(page, fn, arg)` runs fn in a page;
 * `until(page, fn, arg, seconds)` polls it. Resolves to each page's {phase, level} after it (null where it never got
 * there).
 */
export async function passBackLotLive(pages, G, until) {
  for (const p of pages) {
    await until(p, (g) => g.cinematics.active() && g.cinematics.time() > g.cinematics.story.Skip.From + 0.1, null, 60);
  }
  for (const p of pages) await G(p, (g) => g.cinematics.skip.vote());
  for (const p of pages) await until(p, (g) => g.prologue.state === 'Bin' && !g.cinematics.active(), null, 40);
  for (const p of pages) await G(p, (g) => g.prologue.climbOut());
  for (const p of pages) await until(p, (g) => g.prologue.state === 'Lot', null, 20);
  for (const p of pages) {
    await G(p, (g) => {
      g.env.teleport([28.2 + g.prologue.slot * 0.9, 21.5, 294.5, 1, 0, 0, 0, 1, 0, 0, 0, 1]);
      g.prologue.climbIn();
    });
  }
  const out = [];
  for (const p of pages) {
    out.push(await until(p, (g) => (g.level === 'Level0_Basement' && g.phase === 'InRun' ? { phase: g.phase, level: g.level } : null),
      null, 40));
  }
  return out;
}
