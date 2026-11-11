// strings/kit.js: the lines of the player kit (docs/design/game-spec-v2.md 3.1, 3.2): the radar (its touch button,
// markers, the empty press, the battery's Full prompt), the look-back's button, the Leap assist setting and the
// first-time hints of the slide, the leap and the radar; Shared/Strings.luau's keys, value for value.

import { defineStrings } from './index.js';

defineStrings({
  // input (the touch buttons; the controls list)
  'Input.Radar': 'RADAR',
  'Input.LookBack': 'LOOK BACK',
  'Tutorial.Control.Radar': 'Radar scan, or your objective',
  // the radar (RadarRules)
  'Radar.Empty': 'Radar empty. Batteries blink.',
  'Radar.Charges': 'RADAR %d/%d',
  'Radar.Marker.Battery': 'BATTERY',
  'Radar.Marker.Exit': 'EXIT',
  'Radar.Marker.Item': '%s %d/%d',
  'Radar.Marker.Dropped': '%s (DROPPED)',
  'Prompt.Full': 'Full',
  // the Leap assist setting
  'Settings.LeapAssist': 'Leap assist',
  'Settings.LeapAssist.Auto': 'Auto',
  'Settings.LeapAssist.Auto.Info': 'On for touch and controllers, off for keyboard.',
  'Settings.LeapAssist.On': 'On',
  'Settings.LeapAssist.On.Info': 'Leaps start for you at the strip when you are fast and lined up.',
  'Settings.LeapAssist.Off': 'Off',
  'Settings.LeapAssist.Off.Info': 'Press jump on the strip yourself.',
  // the first-time hints
  'Hint.Slide': 'A bar across the way. Crouch while you sprint to slide under it.',
  'Hint.Leap': 'A leap strip. Sprint straight at the gap and jump on the stripes.',
  'Hint.Radar': 'A scan shows what you need, through the walls. It never shows him.',
  'Hint.Input.Slide': 'Slide',
  'Hint.Input.Sprint': 'Sprint',
  'Hint.Input.Radar': 'Scan',
});
