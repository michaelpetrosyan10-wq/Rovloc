// strings/story.js: the lines of the story's presentation (docs/design/game-spec-v2.md 2.3, 2.4, 4.1, 3.4): the skip
// vote, the prologue's prompts and waits, and the title screen's name prompt. The spoken lines and the cards are the
// story's own data (StoryConfig, world.json meta.storyConfig).

import { defineStrings } from './index.js';

defineStrings({
  // The skip vote (2.3)
  'Story.Skip': 'HOLD %s TO SKIP',
  'Story.SkipTouch': 'HOLD SKIP TO SKIP',
  'Story.SkipVotes': '%d / %d WANT TO SKIP',
  'Story.SkipWaits': 'SOMEONE IS SEEING THIS FOR THE FIRST TIME',
  'Story.SkipFirstTime': 'EVERYONE HAS TO HAVE SEEN THIS FIRST',
  // The prologue (4.1)
  'Prologue.PushLid': 'Push the lid',
  'Prologue.ClimbIn': 'Climb in',
  'Prologue.Dark': 'You slide into the dark…',
  'Prologue.Waiting': '%d / %d IN THE CHUTE',
  'Prologue.Chained': 'Chained.',
  'Prologue.Find': 'The chute hatch, by the wall.',
  // The name prompt (3.4)
  'Name.Title': 'What do your friends call you?',
  'Name.Hint': 'One word. The story uses it; you can change it in Settings.',
  'Name.Preview': 'They will call you %s.',
  'Name.None': 'No name will be used.',
  'Name.Ok': 'THAT\'S ME',
  'Name.Skip': 'NO NAME',
});
