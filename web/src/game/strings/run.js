// strings/run.js: the lines of the run's structure and lives (docs/design/game-spec-v2.md 0.1, 3.3, 4.10): the stage
// cards (Shared/Strings.luau's Stage.Card.<id>, value for value), the stand-in of a stage still being built, the
// chapter strip, the lives HUD and the downed screen's get-up, the respawn, and the results' new rows.

import { defineStrings } from './index.js';

defineStrings({
  // The stage cards (StageConfig: the run's stages, by id; BackLot and Bahamas show none)
  'Stage.Card.Level0_Basement': 'FLOOR B · BASEMENT',
  'Stage.Card.Level1_Hallways': 'FLOOR 1 · HALLWAYS',
  'Stage.Card.Level2_Auditorium': 'FLOOR 2 · AUDITORIUM',
  'Stage.Card.Level3_Roof': 'THE ROOF · THE LAST RUN',
  'Stage.Card.City1_Rooftops': 'PART TWO · THE CITY · ROOFTOPS',
  'Stage.Card.City2_Airport': 'THE CITY · AIRPORT',
  'Stage.Card.Runway': 'WHEELS UP',
  // A stage with no script yet: what it is, and the honest line
  'Stage.Name.BackLot': 'THE BACK LOT',
  'Stage.Name.Bahamas': 'THE BAHAMAS',
  'StandIn.Line': 'This part of the night is still being built.',
  'StandIn.Skip': 'Press %s to go on',
  'StandIn.SkipTouch': 'Tap SKIP to go on',
  'Input.Skip': 'SKIP',
  // The chapter strip on the results
  'Results.Chapters': 'CHAPTER %d / %d',
  'Results.Night': 'THE NIGHT TOOK YOU',
  'Results.RespawnsUsed': 'Chances used: %d',
  // Lives (LivesRules)
  'Lives.NotYet': 'NOT YET.',
  'Lives.GetUp.KeyboardMouse': 'HOLD E TO GET UP',
  'Lives.GetUp.Gamepad': 'HOLD X TO GET UP',
  'Lives.GetUp.Touch': 'HOLD GET UP',
  'Lives.GetUpButton': 'GET UP',
  'Lives.GetUpUsed': 'You already got up once on this floor.',
  'Lives.Dropped': '%s dropped it here.',
  'Lives.You': 'You',
  'Lives.OutOfRespawns': 'No more chances. Watch over your squad.',
  'Lives.Teammate': '%s · %s',
  'Lives.State.Alive': 'UP',
  'Lives.State.Downed': 'DOWN',
  'Lives.State.Dead': 'OUT',
  'Hint.GetUp': 'You can get up once on each floor. Hold on, then hold to stand.',
});
