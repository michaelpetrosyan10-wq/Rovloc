// radar.js: the port of Shared/Rules/RadarRules.luau (docs/design/game-spec-v2.md 3.2; invariant I15), function for
// function. Pure: plain data in and out, no engine, clock or randomness. The numbers are the world's own (world.json
// meta.radarConfig, both difficulties; meta.stageConfig.sneaking for the sneaking stages), never a copy here:
// radarRules(meta) binds the functions to them. Charges are personal; a scan is a squad event. tools/radar-test.mjs
// replays every RadarRules row of build/cache/golden.json against this port.
//
//   startCharges     the charges a run starts with
//   arrival          a sneaking stage's arrival floor: reaching one of the difficulty's ArrivalFloor stages with no
//                    charge gives one
//   battery          a battery picked up: +BatteryCharge and +BatteryTorch, each to its full; with both full it is not
//                    taken (the prompt reads "Full" and it stays)
//   refusal          why a scan is refused without cost (Downed, Dead, Hiding, Seated, Cutscene, Stage: the roof or
//                    the runway, Live: a squad scan is showing), Empty when there is no charge (the objective sheet
//                    opens), else Ok
//   scan             a scan's cost and times: one charge, the markers from the raise to RaiseSeconds + ScanSeconds
//   targets          what a scan shows for an objective view: every item still needed for the open step and every
//                    dropped one, the open step's stations not yet done, the exit once it is unlocked, the batteries
//                    within DotRange; never the Creature, never a teammate
//   batteriesPlaced  batteries a sneaking stage holds for a squad of `players`
//   guaranteedScans  the scans a run guarantees with no battery ever found (the start, then each arrival floor)
//   metres           a marker's distance in metres

/**
 * @typedef {{id: string, step: string, carried: boolean, dropped: boolean}} Item
 * @typedef {{id: string, step: string, done: boolean}} Station
 * @typedef {{id: string, distance: number}} Battery
 * @typedef {{openStep: string, items: Item[], stations: Station[], exit: {id: string, unlocked: boolean},
 *   batteries: Battery[], creature?: {id: string}, teammates?: {id: string}[]}} View
 * @typedef {{kind: 'Item'|'Station'|'Exit'|'Battery', id: string}} Target
 * @typedef {{charges: number, lifeState: string, moveState: string, cutscene: boolean, stage: string,
 *   squadScanLive: boolean}} Asker
 */

/** A Luau array as JSON carries it: an empty table arrives as {} (JSON cannot tell it from an empty list). */
const items = (list) => (Array.isArray(list) ? list : []);

/**
 * The radar rules bound to a world's numbers.
 * @param {{radarConfig: any, stageConfig: {sneaking: string[]}}} meta
 */
export function radarRules(meta) {
  const config = meta && meta.radarConfig;
  if (!config || !config.Standard || !config.Nightmare) throw new Error('the world carries no radarConfig');
  const sneaking = new Set(items(meta.stageConfig && meta.stageConfig.sneaking));
  const noScan = new Set(items(config.NoScanStages));

  /** RadarConfig.of: Standard's numbers for anything but "Nightmare". */
  const of = (difficulty) => (difficulty === 'Nightmare' ? config.Nightmare : config.Standard);

  function startCharges(difficulty) {
    return of(difficulty).StartCharges;
  }

  function arrival(difficulty, stageId, charges) {
    if (charges <= 0 && sneaking.has(stageId) && items(of(difficulty).ArrivalFloor).includes(stageId)) return 1;
    return charges;
  }

  /** @returns {{taken: boolean, charges: number, torch: number}} */
  function battery(difficulty, charges, torch, torchMax) {
    const max = of(difficulty).MaxCharges;
    if (charges >= max && torch >= torchMax) return { taken: false, charges, torch };
    return {
      taken: true,
      charges: Math.min(max, charges + config.BatteryCharge),
      torch: Math.min(torchMax, torch + config.BatteryTorch),
    };
  }

  /** @param {Asker} asker */
  function refusal(asker) {
    if (asker.lifeState === 'Downed') return 'Downed';
    if (asker.lifeState !== 'Alive') return 'Dead';
    if (asker.moveState === 'Hiding') return 'Hiding';
    if (asker.moveState === 'Seated') return 'Seated';
    if (asker.cutscene) return 'Cutscene';
    if (noScan.has(asker.stage)) return 'Stage';
    if (asker.squadScanLive) return 'Live';
    if (asker.charges <= 0) return 'Empty';
    return 'Ok';
  }

  /** @returns {{charges: number, showAt: number, endsAt: number}} */
  function scan(difficulty, charges, now) {
    const c = of(difficulty);
    const showAt = now + c.RaiseSeconds;
    return { charges: Math.max(0, charges - 1), showAt, endsAt: showAt + c.ScanSeconds };
  }

  /** @param {View} view @returns {Target[]} */
  function targets(view) {
    const out = [];
    for (const item of items(view.items)) {
      if (item.dropped || (item.step === view.openStep && !item.carried)) out.push({ kind: 'Item', id: item.id });
    }
    for (const station of items(view.stations)) {
      if (station.step === view.openStep && !station.done) out.push({ kind: 'Station', id: station.id });
    }
    if (view.exit.unlocked) out.push({ kind: 'Exit', id: view.exit.id });
    for (const b of items(view.batteries)) {
      if (b.distance <= config.DotRange) out.push({ kind: 'Battery', id: b.id });
    }
    return out;
  }

  function batteriesPlaced(difficulty, players) {
    const c = of(difficulty);
    const extra = Math.min(4, Math.max(1, Math.floor(players))) - 1;
    return Math.min(c.BatteriesMax, c.BatteriesBase + c.BatteriesPerExtraPlayer * extra);
  }

  function guaranteedScans(difficulty) {
    let charges = startCharges(difficulty);
    let scans = 0;
    for (const stageId of items(meta.stageConfig && meta.stageConfig.sneaking)) {
      charges = arrival(difficulty, stageId, charges);
      scans += charges;
      charges = 0;
    }
    return scans;
  }

  function metres(studs) {
    return Math.floor(studs * config.MetresPerStud + 0.5);
  }

  return Object.freeze({
    config,
    of,
    startCharges,
    arrival,
    battery,
    refusal,
    scan,
    targets,
    batteriesPlaced,
    guaranteedScans,
    metres,
  });
}
