# Stay Behind: the project so far, in the owner's ideas

A short account of where this project came from, which of the owner's ideas still hold, and what was decided for the
new game. The full record, in his own words, is `docs/design/requirements.md`.

## 1. How it began (Rovloc)

- A first-person co-op horror game for 1 to 4 players in a dark, ruined school at night, built for Roblox and then
  for a website that had to run on school Chromebooks.
- Each floor had a job (restore the power with fuses, find the janitor's keys) while a tall monster hunted you. You
  hid in lockers, crawled through vents and carried a torch.
- It grew a story: friends walk out of school joking, a small cute thing crawls out of a bin, takes the friend Danny
  and turns him into the monster; later came a roof chase, a parachute and an escape across the city to a plane.
- On 19 November 2026 the owner replaced all of that with the game in section 3. The old versions are frozen, not
  deleted.

## 2. Ideas of his that carry over

**The look**
- As real as it can be made: "they should look like real life", with real-looking people and real light and shadow.
  His comparisons were games made in Unreal and Counter-Strike 2, and now "as realistic as gta six".
- The surroundings must be scary, not only the monster: a school after hours, dark and ruined, with signs of what
  happened. Gray-leaning but with real faded colour; no orange or copper wash; no black-and-white checkerboard floors.
- Light you can see in the air, dust in the beams, wet floors, small things moving: "crazy looking".

**The monster (now "the hunter")**
- His favourite design stays: a very long, very narrow pale face tapering to a point; huge black slanted eye holes
  with a pinprick of light in each; two dark streaks under the eyes; a wrinkled brow; big old veined hands with long
  fingers; a hood; a body as tall and thin as the face is narrow. "The face is supposed to be slim like body." The
  picture is `docs/design/art/higgsfield/picks/monster-favourite-B3.png`.
- The body has to be frightening by itself, and scary before odd.
- He is noticed often and attacks rarely. He stays within a radius of you, and something happens (heard close,
  glimpsed, a near miss) about every 15 to 20 seconds when you sprint, 30 when you walk and 60 when you crouch.
  These are his starting numbers ("only ideas"); the point is that sneaking pays.
- He must not simply teleport behind you, and he can follow through vents and small gaps.
- He speaks real words, says your name sometimes and mocks you, but not too often. His voice is an eerie whisper.

**Sound and voices**
- Real recorded sounds, never thin synthetic tones or "wooden clicks". His footsteps are heavy and heard from far
  away, so you know he is around.
- People must sound human; the first voices were "a little robotic". He chose voice 3 for Danny and for Kayla and the
  whispering voice for the monster (`docs/design/voices`).
- "Amazing audio with the right tracks and audio for everything."

**Play**
- Fun, eerie and scary in every part, with moments people remember: "i dont wanna be a boring game".
- "I also dont want the game to be too hard."

**How he wants the work done**
- Ask him instead of guessing.
- Use Higgsfield for pictures and other generated art where it helps. Never buy or rent anything without his word.
- His bar: "perfect no errors exactly as beautiful as I want". He wants pictures and playable builds as they are
  ready.

## 3. The new game (decided 21 November 2026)

- **What it is:** a single-player survival horror game in Unreal Engine 5.8 on his gaming PC, with co-op perhaps
  later. First-person play, third-person cutscenes, 8 to 10 hours in chapters with an epilogue. The horror is
  modelled on the Silent Hill 2 remake, the Dead Space remake, Alien: Isolation, Outlast 2 and Amnesia: The Bunker;
  the story on Red Dead Redemption 2. Their patterns are used, never their content.
- **The story:** an evening event at the school. Danny (16) and his friend Kayla leave early and see a mothership
  over the city; a small ship lands and the hunter crawls out; they hide in the basement. Most people are taken
  alive up to the mothership. Five to eight survivors live in a basement safe room with a generator; Danny brings
  back what they need, and not all of them make it. Kayla guides him by radio and is taken when the rescue
  helicopter is shot down. Danny parachutes into the city, knocks out an alien, takes its gun and its ship, flies to
  the mothership, frees who he can, gets Kayla into a pod, and stays behind to set off the self-destruct by hand. The
  epilogue is played as Kayla. Quiet choices (who you helped, what you shared, who you left) change the last chapter.
  It is meant to be sad.
- **The creatures:** the hunter can appear anywhere and whispers in eerie versions of the voices of people it took.
  Each area also has its own kind with its own rule: the Dark Dwellers (the basement, when the generator fails), the
  Listeners, the Still Ones, the Mimics and the Swarm (the school's floors), the Patrol (the city), the Brute (the
  mothership).
- **The rules of play:** nothing can be killed in the school; you hide, distract and scare things off. From the city
  on there is the alien gun with very little energy. Survival is medium-weight: a small backpack and scarce
  batteries, fuel, medicine and parts. Saving is by hand in safe rooms, plus an autosave at each chapter. Puzzles
  are complex and fair, with their own difficulty setting, and their codes and item places change each playthrough.
  An alien symbol language is learned piece by piece, and the self-destruct is the last puzzle. He wants Easter
  eggs, small clever mechanics and lived-in detail "like the stuff on the floor".
- **The later chapters:** the city is a few dense blocks; the flight is steered along a set course; the mothership
  is a full two-hour chapter with a low-gravity stretch.
- **Tone:** graphic horror for the aliens and for Danny's own death scenes. What happened to the other students
  stays off screen.
- **Music:** a quiet, eerie score and a few original songs at the biggest moments.
- **Title:** Stay Behind (working title).

## 4. Where it stands

- Unreal Engine 5.8.4 is installed on his PC. Nothing has been built in it yet.
- Research is being written (`docs/design/unreal/research`). From it comes the written game map: the full story,
  each creature's rules, the puzzles, the chapters and the build plan. He approves it before anything is built.
- Still to be put to him: who voices the characters, how strong the language is, why the aliens came, and how the
  large Unreal files are backed up.
- The first thing to build after his approval is one finished slice (a basement safe room, a stretch of tunnel, the
  hunter, one puzzle) to prove the look on his PC.
