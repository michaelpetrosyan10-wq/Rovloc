# Stay Behind: creatures, AI and encounters

Research report 03, 21 Nov 2026. Topic: the hunter and the seven creature kinds, how they meet the player, and how to
build them in Unreal Engine 5.8. It builds on `docs/design/research/monster.md` (the two-level director, the
references' monster systems) and `docs/design/monster/monster-v3-spec.md` (the interaction clock, strain, backstage,
chase tokens, near misses). It does not repeat them.

Tags: **[checked: url]** a source found this session says it (mostly search-result summaries: WebFetch could not
reach dev.epicgames.com or other hosts from this session, so pages were not read in full); **[from memory]** my own
knowledge, not confirmed this session; **[proposal]** my design recommendation.

The one rule: we take PATTERNS, never CONTENT. Every look and sound below is new; where a pattern comes from a
reference game, the game is named only to say where the pattern was seen.

---

## 0. Findings first

1. **One director for the whole game, eight "configurations".** Alien: Isolation kept one stalker fresh by switching
   its frontstage/backstage set-ups over the campaign [checked: gamedeveloper.com, Revisiting the AI of Alien:
   Isolation, via monster.md 2.1]; Dead Space's remake grades about 350 authored events ("content bricks") on a 1 to
   11 intensity scale and tracks peaks and valleys so high-intensity beats never come back to back [checked:
   gamedeveloper.com, Diving into the nightmarish new systems of the Dead Space remake; destructoid.com]. Stay Behind
   needs the same thing at chapter scale: the v3 Lurker clock and strain gauge stay, but each chapter loads its own
   configuration (which hunter beats are allowed, the leash, the chase budget, how much room the local kind gets).
   Why it matters: 8 to 10 hours with one stalker is three times Alien: Isolation's problem area, and that game's
   mid-game is the part players most often call too long [from memory].
2. **The hunter must be absent on purpose for long stretches.** The local kind's TEACH phase on every floor runs with
   the hunter off the map. A rule cannot be learned while two rules are pressing at once. Target: the hunter active
   in roughly half of the play time [proposal].
3. **The hunter learns, but only from what the player survives.** Alien: Isolation unlocks locked branches of the
   alien's behaviour tree as the player meets conditions, and its lead AI programmer said none of the conditions come
   from events that end in the player's death [checked: gamedeveloper.com, The Perfect Organism; deepwavegame.github.io
   breakdown, secondary]. The secondary source adds: heavy vent use makes it search vents more; a deterrent tool makes
   it wait it out [checked: deepwavegame.github.io, not official]. Stay Behind should keep a "habits ledger" and show
   each learned behaviour the first time it appears.
4. **Two kinds of borrowed voice, kept apart.** The hunter's stolen whisper is always an honest position cue (it plays
   from where the hunter is, broken and processed); the Mimics' calls are clean lies from the wrong place. If both lie,
   the player cannot learn either.
5. **"Taken, not killed" collides with graphic death scenes.** If every creature takes people alive, a gory death for
   Danny breaks the story's own rule. The fix is a rule the player can read: the hunter and the Patrol TAKE (they want
   people alive); the feral local kinds MAUL. This must be put to the player (see the end).
6. **Every kind needs one rule a player can say in a sentence, one far tell, one near tell, two counters, and a
   teach-test-twist on its floor.** Readability is where similar games are criticised: a review of A Quiet Place: The
   Road Ahead says stealth horror "lives or dies on readability" and that its feedback became inconsistent, and its
   noise rule is instant death [checked: androidexperto.com / geekchamp.com review summaries; xboxtavern.com].
7. **Still Ones and Mimics are the two kinds most likely to feel unfair.** The look-away rule is an old trope (SCP-173;
   Containment Breach solved backpedalling with a forced blink meter [checked: wikipedia.org SCP - Containment
   Breach]); mimic fairness depends on a consistent tell (player discussions settle on "it does not respond to you"
   [checked: steamcommunity.com Lethal Company discussions]).
8. **State Tree for creature brains, a C++ subsystem for the director, Mass plus Niagara for the Swarm.** State Tree
   has utility-scored state selection [checked: dev.epicgames.com, StateTree Selectors Overview] and in 5.8 its rewind
   debugger shows condition, task and utility names and breakpoints work in linked assets [checked: UE 5.8 release
   notes, search summary]. A 5.7 forum benchmark found State Tree costlier than Behavior Tree at 100 to 400 agents
   [checked: forums.unrealengine.com, StateTree Performance vs BehaviorTree], which does not matter for under ten
   full creatures.
9. **Navigation is the hardest engineering item.** Recast supports one navmesh per agent size [checked:
   forums.unrealengine.com, Multiple Nav Meshes for multiple Agents], so the Brute gets its own; native navmesh does
   not do walls or ceilings [checked: forums.unrealengine.com, AI walk on wall and ceiling], so the hunter's vents
   and the Swarm's ceilings need an authored graph.
10. **The previous game proved its monster by simulation; keep that.** Unreal's Automation Spec, Functional Test actors
    and headless runs (`UnrealEditor-Cmd ... -ExecCmds="Automation RunTests ..."`) support it [checked:
    dev.epicgames.com automation test framework; tessl.io guide]. Port the Lurker rules as a pure, seeded C++ library
    so the same numbers run in the game and in a test without a level.

---

## 1. The hunter across the whole game

### 1.1 What carries over from v3 unchanged
The two brains (director steers to an area, the creature finds the player with its own senses); the interaction clock
paid by how the player moves; strain and backstage; the catalogue of cheap heard beats, seen beats and close beats;
chase tokens and the no-token near miss; warned arrivals only; sounds played from where the body really is. These
were measured in simulation and the player approved the cadence. Keep the names (H1..C4, F, NearMiss) so the old
sim targets can be re-used as acceptance tests.

### 1.2 What a long game adds
**Chapter configurations [proposal, pattern from Alien: Isolation's front/backstage set-ups].** One data asset per
chapter (UE Primary Data Asset) holding: which catalogue types are unlocked; leash band; chase-token period; the share
of time the hunter is on the map; whether it may enter the local kind's core area; and the habits it has already
learned. Suggested arc:

| Chapter | Hunter | Why |
|---|---|---|
| Opening (event night) | Seen once, far, crawling out of the ship. Third-person cutscene. No AI. | The promise. |
| Basement, first night | Heard only (H1, H3 in the pipes), never seen close. | Fear before knowledge. |
| Basement, power failure | Absent while the Dark Dwellers are taught; returns for the fuel run. | One rule at a time. |
| Floor 1 to 4, each | Absent in TEACH; seen and heard in TEST; close beats and a chase in TWIST. | Teaches the shape of a floor. |
| Roof | Its one long chase that the level funnels (built escape route). | Earned set piece. |
| City | Rare: it is now a distant silhouette on rooftops; the Patrol owns the streets. | Variety; the hunter becomes "the one that followed you". |
| Mothership | Full return, now with every learned habit, plus the Brute. | The final exam. |

**Learning (the habits ledger) [proposal, pattern from Alien: Isolation's unlocking tree].** Count, per save: hides in
each hiding-spot class (locker, under-desk, crawlspace, vent); distraction throws by item; times the player broke line
of sight through the same door; vent use. Each count above a threshold unlocks one counter-behaviour: checks that
hiding class first; ignores the first bottle thrown; waits at the far end of the favourite vent; closes a door behind
it. Rules: never unlock from a death (the Alien rule); show it the first time as a visible beat (it opens the locker
next to yours, slowly, and leaves); cap at one new habit per chapter; Easy unlocks none of the punishing ones.
Why: it turns an 8-hour stalker into a character with a memory of Danny, which the story wants.

**Absence [proposal].** Dead Space's director explicitly avoids back-to-back high-intensity beats [checked:
gamedeveloper.com]. Add a chapter-level "off-stage" state above backstage: the hunter is not simulated near the player
at all for a known stretch (story scenes in the safe room, the teach phases, puzzle rooms the player has sealed). The
player should be able to feel the difference between "it is in the vents" and "it is gone for now": the safe room's
radio goes quiet of its whisper; the pipes stop knocking.

**Rules the player can read across 8 hours.** Keep the hunter's own rules few and constant for the whole game:
1. It never enters a lit safe room while the door is barred (sanctuary; pattern from RE2's save rooms, monster.md 2.3).
2. You always hear it before it can reach you (the tell guarantee from v3).
3. It sees in the dark better than you, but it cannot see into a closed hiding place it did not watch you enter.
4. Fire and very loud sudden noise make it flinch and withdraw; nothing in the school kills it (pattern from Amnesia:
   The Bunker, where shots, fire and explosions drive the monster off for a while but cannot kill it in the campaign
   [checked: primagames.com; commonsensegamer.com; gamepressure.com]).
5. It takes, it does not eat: when it catches Danny it drags him (see section 3).

### 1.3 How it relates to the local kinds
- **Shared menace budget.** The local kind and the hunter both spend from one strain gauge per player. When a local
  kind has just pressed the player (a Listener passed within 3 m), the hunter's clock runs at half rate for that
  player. That is how the two never stack into unfairness [proposal; extends v3 strain].
- **The hunter obeys local physics, not local rules.** It is not blind on the Listener floor, but it is affected by
  the same things the player uses: a dark corridor hides Danny from it as well; the Swarm swarms it too (a great
  "monster vs monster" beat: it shakes them off in a vent, and the player hears the fight).
- **Twist pairing.** Each floor's TWIST is where the hunter and the local rule push against each other. Listeners: the
  hunter's arrival makes you want to run, and running is what the Listeners hear. Still Ones: the hunter's whisper
  behind you makes you turn your head. Mimics: you cannot tell a person, a Mimic and the hunter's whisper apart if
  the tells are not distinct (so they must be). Swarm: hiding still keeps you safe from the hunter but the Swarm
  follows warmth, and a still body is still warm.

### 1.4 The stolen whisper
The player asked for it to "whisper in the voices of people it took but ... an eerie creepy version".
- **Only voices the player heard before.** Each survivor and named student records 20 to 40 short lines in normal
  scenes (jokes, a call-out, a nickname for Danny). When that person is taken, their lines join the hunter's bank. The
  player recognises the voice because they lived with it: this is the sad payload (pattern: Red Dead 2 makes the
  loss land through time spent with people [from memory]).
- **Fragments, not sentences.** It replays pieces out of order, with the wrong breath: "Danny ... you said ... the
  door". Processing (MetaSounds): pitch drop of 2 to 4 semitones on consonants only, time-stretch of vowels, a
  breath layer reversed, a second copy 40 ms late and detuned. Never a clean line.
- **Always honest about position.** It plays from the hunter's real location, with real occlusion. It is a TELL, never
  a lure. That is the difference from the Mimics (1.3) and avoids the "friend's voice leads you into a trap" set
  piece flagged in monster.md section 1.
- **Choices feed it.** Someone Danny left behind (a quiet choice) is the voice it uses most in the last chapter.
  Kayla's voice joins after the helicopter, used rarely (at most once per chapter) so it stays unbearable.
- **Budget.** v3's H5 rule stands: at most one whisper per two minutes per player.

---

## 2. The seven kinds

Format for each: rule (as the player would say it), senses, tells, counters, teach/test/twist, failure, with the
hunter, pitfalls, look and sound. All looks and sounds are [proposal] and original.

### 2.1 Dark Dwellers (basement, when the power fails)
- **Rule:** "They live in the dark. Light hurts them. The generator is the light."
- **Senses:** touch and smell in darkness; they cannot enter a lit volume at all. They sense Danny's light going out.
- **Tells:** far: the basement lights flicker and the generator note sags before fuel runs out (a gauge on the
  generator, read in the world, no HUD); near: a soft multi-voiced breathing that stops when you face it, wet
  movement just outside the torch cone.
- **Counters:** the generator (fuel is the currency, pattern from Amnesia: The Bunker, where an empty generator makes
  the monster bolder [checked earlier: monster.md 2.2]); the torch (batteries); road flares and glow sticks that make
  temporary safe pools; routing power through a breaker panel (which rooms are lit is a puzzle and a choice).
- **Teach:** the first outage happens inside the safe room with the survivors around; a torch beam catches one and it
  shrivels back into a crack. **Test:** a fuel run through a dark storage maze, laying flares as a breadcrumb trail.
  **Twist:** the breaker panel can light only two of three circuits: the infirmary fridge (medicine), the corridor to
  the fuel, or the survivors' room. This is a quiet choice the last chapter remembers.
- **Failure:** pulled into darkness from the edge of a light pool; graphic (allowed).
- **With the hunter:** the hunter does not fear light, so a lit room is safe from Dwellers but not from it. That
  teaches early that "safe" is per creature.
- **Pitfalls:** darkness so dark the screen is unreadable (players turn gamma up and the horror dies); light-as-rule is
  A Plague Tale's core loop [checked: pcgamer.com; wccftech.com interviews], so make ours about scarce fuel and
  routing, not torches against a sea.
- **Look:** flat, membrane-like bodies that hang in ceiling corners like wet sheets, with too many thin fingers; in
  light they blister and smoke. **Sound:** a chorus of small inhalations, paper-tearing when burned, a low hum that
  rises as the generator sags.

### 2.2 Listeners (floor 1, if the floors keep the map's order)
- **Rule:** "They are blind. They hear everything. Quiet floors, loud floors."
- **Senses:** hearing only, range by loudness and by walked distance (not straight line). They also hear a sound's
  direction, and turn their whole head-fan toward it.
- **Tells:** far: their listening hum stops when they lock onto a sound (silence as a tell); near: the fan opens.
- **Counters:** surface choice (carpet, tile, broken glass, water, dropped papers: the "stuff on the floor" detail
  becomes a mechanic); masking sound (the school's heating knocks every so often, rain on the gym roof, a stuck PA
  hum: move during the mask); throwables; closing doors; holding breath. Never the real microphone (monster.md 4:
  privacy and permissions).
- **Teach:** a Listener behind the glass of a trophy case; Danny steps on glass, it slams the case. **Test:** a debris
  corridor with two of them and timed masking knocks. **Twist:** a phone in Danny's backpack, picked up from a taken
  student, starts receiving calls (switch it off or throw it as a lure; it is also a story clue).
- **Failure:** grabbed and torn; graphic.
- **With the hunter:** the hunter's arrival tempts a sprint; sprinting is what Listeners hear. The player must choose
  which threat to obey.
- **Pitfalls:** instant death from one noise with no escape and inconsistent feedback (the Road Ahead criticism
  [checked]); echolocation clicking is another game's signature [from memory]: do not use it. Give a short grace: a
  heard noise makes them turn and come, not kill.
- **Look:** tall, eyeless, the head a fan of thin membranes like folded gills that spread when listening, the skin
  stretched as if the body grew around a skeleton too small. **Sound:** a breathy tone through the fan, a dry clack
  of the membranes snapping shut.

### 2.3 Still Ones (floor 2)
- **Rule:** "They move only when nothing is watching them. Light counts as watching; dark does not."
- **Senses:** they know if they are observed (in Danny's view, lit, not occluded), and they move toward warmth.
- **Tells:** a tick of shifting joints each time one moves out of sight; they are always slightly closer; they stop
  in mid-reach, so the pose tells you where they were going.
- **Counters:** keep them lit and in view; leave a WATCHING device to hold a corridor (the school's CCTV room, a phone
  propped up recording, a camcorder): this is a small, important mechanic. Its battery runs out.
- **Teach:** one Still One in a lit classroom; you leave and come back, it has moved two desks. **Test:** walk a
  corridor of them with a failing fluorescent light. **Twist:** the power on this floor strobes: each dark frame is
  a step for them.
- **Failure:** you turn back and it is there; the death is fast and graphic.
- **With the hunter:** its whisper from behind makes you turn your head; a twist, used once or twice only.
- **Pitfalls:** the obvious exploit is walking backwards forever. Containment Breach answered it with a forced blink
  [checked: wikipedia.org]; we answer it with flicker, doors (you must look at the handle), and two Still Ones on
  opposite sides. Also: "observed" must be generous (half a body in view counts) or deaths feel like a lie.
- **Look:** not statues; long, folded figures of dark bark-like chitin with their faces hidden in their own hands,
  and when caught moving, the hands are a little open. **Sound:** none when watched; a wet wood-bend creak and a
  tick when not.

### 2.4 Mimics (floor 3)
- **Rule:** "From behind they look like people. They call in a voice you know. They never answer you."
- **Senses:** sight and hearing like a person; they learn voices they hear (in the story: from the taken).
- **Tells:** they always face away; they never answer a question; the room tone drops a little around them; their
  breath is missing between words.
- **Counters:** the radio code word: Kayla sets one at the safe room; real survivors answer it, Mimics repeat it back
  [proposal]. A thrown object: a person flinches, a Mimic does not. Distance: they need you close.
- **Teach:** Kayla's voice calls from the end of a corridor while she is talking to you on the radio at the same time.
  **Test:** several people in the dark library, one real survivor to save (a quiet choice). **Twist:** a real
  survivor too scared to answer the code; the player must find a second tell.
- **Failure:** it turns, the face unfolds; graphic.
- **With the hunter:** keep their voices distinct from its whisper (1.4): theirs are clean, full sentences, from the
  wrong place.
- **Pitfalls:** unfair if there is no consistent tell; fan debates on other games' mimics settle on "does not
  respond" as the fair tell [checked: steamcommunity.com]. Never use the body of a taken student: the Mimics grow a
  shape, they do not wear a person (keeps students off screen).
- **Look:** from behind a hoodie-shaped growth, the "hair" a texture; from the front a smooth face with a vertical seam
  that opens sideways. **Sound:** perfect voice, no breath, a faint second voice under it.

### 2.5 The Swarm (floor 4)
- **Rule:** "They feel warmth and movement. Cold and stillness hide you."
- **Senses:** heat and motion within a short range; heat sources draw them from vents.
- **Tells:** ceiling tiles bulge, dust trickles, a chitter like rice in a pan moving through the ducts; they glow faintly
  brighter as they near warmth (a tell that is also beautiful).
- **Counters:** cold (CO2 extinguisher, the cafeteria freezer, open windows); heat decoys (a kettle, a space heater, a
  burning bin); sealing vents with tape; standing still.
- **Teach:** a heater in a classroom: the Swarm pours onto it, ignoring Danny. **Test:** a corridor with vents where
  you must move between cold spots. **Twist:** Danny is wounded and bleeding (warmer); or the heating comes on.
- **Failure:** covered, stung, slowed; a struggle; graphic.
- **With the hunter:** stillness saves from one and not the other.
- **Pitfalls:** fights and swarms of small things are hard to read; A Plague Tale's swarm of 5,000 worked because it
  was run as a horde, not 5,000 brains [checked: pcgamer.com; blog.playstation.com]; Dead Space's small enemies are
  a known annoyance [from memory].
- **Look:** finger-length segmented things, translucent, with absorbed heat glowing inside. **Sound:** chitter,
  scrabbling in metal, a rising whine when a mass forms.

### 2.6 The Patrol (city)
- **Rule:** "They hunt with lamps and scanners. They take people. Break their beams."
- **Senses:** sight in a lamp cone; a scanner pulse that sees heat through thin walls, with visible and audible sweeps.
- **Tells:** the pulse's sound (built from the alien language's phonemes, which ties the symbol language to the world);
  lamp beams sweeping.
- **Counters:** metal hides heat (cars, dumpsters); interference (car alarms, live power lines); cold water; the
  takedown from behind (once, scripted, then systemic later with the gun's low energy).
- **Teach:** from a roof, watch them take a person (off screen, sound only). **Test:** cross a block. **Twist:** Danny
  takes a scanner: he can now see them through walls, but it can be heard.
- **Failure:** taken: a capture scene; with the gun, a real fight that is short and lethal.
- **With the hunter:** the hunter tracks Danny to the city; the Patrol covers the streets.
- **Pitfalls:** generic stealth guards; unclear vision cones. Alien: Isolation's human and android patrols worked by
  being few and audible [from memory].
- **Look:** armour that looks grown, lamps in a cluster on one shoulder like eyes. **Sound:** pulse, the language.

### 2.7 The Brute (mothership)
- **Rule:** "It is slow. It tears hiding places open. Hide where it cannot reach, or keep moving."
- **Senses:** smell and sound, short sight.
- **Tells:** its steps shake the deck; it sniffs before it tears; hiding places it can tear are made of soft
  material, the ones it cannot are metal or too small (readable from the look).
- **Counters:** crawlspaces; loops around big rooms; low gravity: it is heavy and turns slowly while Danny can push off.
- **Teach:** watch it tear a pod open from a safe vent. **Test:** a hold with soft and hard hiding places.
  **Twist:** the low-gravity stretch.
- **Failure:** torn out; graphic.
- **With the hunter:** both on the ship; the Brute negates hiding, the hunter negates running.
- **Pitfalls:** it denies hiding, the main verb, so the level must give clear safe spots and loops; a big slow
  pursuer was RE2's success when it could be out-routed but not out-waited (monster.md 2.3).
- **Look:** a huge body carrying hull plating grown into its flesh, with glowing veins. **Sound:** vocal fry, the
  scrape of plates, a designed tearing sound.

---

## 3. "Taken, not killed"
- **Who takes and who kills.** The hunter and the Patrol take people (they want them alive for the ship); the feral
  kinds (Dwellers, Listeners, Still Ones, Mimics, Swarm, Brute) maul. When the hunter catches Danny, the scene cuts
  as he is dragged into the dark (a game over that is not gore); the feral kinds' deaths are graphic. This keeps the
  story's rule and the player's wish for graphic deaths [proposal; must be asked].
- **Students off screen.** The evidence of the taken: dropped phones, shoes, drag marks, a hoodie on a fence, sticky
  residue where someone was cocooned; never bodies.
- **Death scenes.** Dead Space's remake builds enemies in layers (bone, organs, tendons, fat, skin) that peel off
  [checked: gamesradar.com; techradar.com]: this is the reference for how graphic is possible. Keep them short and
  skippable, with a fast reload near the last checkpoint (Outlast 2 was patched after players called its
  trial-and-error chases unfair, monster.md 2.4).

---

## 4. Unreal Engine 5.8 implementation
- **Brains:** State Tree for each creature (utility selection [checked], rewind debugger in 5.8 [checked]).
- **Director:** a C++ World Subsystem with a pure rules library, seeded random numbers.
- **Senses:** AI Perception sight and hearing; a custom sense needs a config class and an implementation class
  [checked: unrealcommunity.wiki; answers.unrealengine.com]; noise by surface (physical materials); being observed
  (Still Ones) computed by a subsystem query (view, light and occlusion traces) rather than a perception sense;
  light read from authored light volumes and a registry of lamps (there is no cheap way to read light on the CPU
  [from memory]).
- **EQS** for hide, search and peek points [from memory]. **Smart Objects** for hiding places used by both the player
  and the creatures (search, tear) using the find, claim, use flow [checked: dev.epicgames.com Smart Objects].
- **Navigation:** one navmesh per agent size (the Brute's own) [checked]; vents and ceilings on an authored graph or a
  surface-navigation plugin from Fab (check its licence and 5.8 support) [checked: fab.com listings].
- **Swarm:** Mass for the simulation, Niagara for the rendering, a few hero actors [checked: forum reports; Plague
  Tale pattern].
- **Animation:** Motion Matching and the Game Animation Sample are set up for humanoids [checked:
  dev.epicgames.com motion matching]; the 5.8 sample adds a powered ragdoll through Physics Control and Smart Object
  interactions [checked: unrealengine.com tech blog]; Control Rig for procedural gaits (the Locomotor node; custom
  two-bone solvers are advised for legs [checked: secondary sources]); look-at through Control Rig. Make awareness
  legible: the head turns before the body moves, and every state change has a sound.
- **Audio:** MetaSounds; Audio Insights is production ready in 5.8 [checked: unrealengine.com 5.8 news].
- **Testing:** Automation Spec, Functional Test actors, headless runs [checked]; Gauntlet for orchestration (forum
  reports of issues on 5.7 [checked]); simulated players as AI controllers with the old profiles (Sprinter, Walker,
  Croucher, Hider, Mixed); a fixed time step and seeds for determinism [from memory]; Visual Logger and the Gameplay
  Debugger for traces [from memory].

---

## 5. What I could not verify
- The 5.8 release notes in full (only search summaries); Mover's status in 5.8; whether EQS is still marked
  experimental; Physics Control's status.
- Silent Hill 2 remake's specific enemy behaviours (hiding, playing dead, radio static): interviews confirm enemies
  hidden using light, darkness and objects and the AI rebuilt from the ground up [checked: gamingbible.com;
  wccftech.com], not the details.
- Alien: Isolation's locker learning; its default timer numbers.
- The fixed time step flags for deterministic runs.

## 6. Sources
- gamedeveloper.com/design/the-perfect-organism-the-ai-of-alien-isolation
- gamedeveloper.com/design/revisiting-the-ai-of-alien-isolation
- deepwavegame.github.io/news/alien-isolation-behavioral-ai-breakdown
- pcgamer.com/alien-isolation-hands-on-pc-gamer-vs-the-monster
- gamedeveloper.com/design/diving-into-the-nightmarish-new-systems-of-the-dead-space-remake
- destructoid.com/dead-space-remakes-intensity-director-explained/
- ea.com/technology/news/inside-dead-space-4-the-intensity-director
- gamesradar.com/dead-space-peeling-tech-makes-dismemberment-even-grosser-in-a-good-way
- techradar.com/news/dead-space-remakes-new-necromorph-tech-is-really-a-peeling
- primagames.com/tips/can-you-kill-the-beast-monster-in-amnesia-the-bunker-answered
- commonsensegamer.com/can-you-kill-the-monster-in-amnesia-the-bunker-and-how-to-avoid/
- gamepressure.com/amnesia-the-bunker/tips-and-tricks/z610ca1
- gamingbible.com/features/silent-hill-2-remake-developer-interview-398071-20240816
- wccftech.com/silent-hill-2-remake-enemy-ai-is-fully-overhauled-to-improve-combat-devs-its-a-more-interesting-experience/
- xboxtavern.com/a-quiet-place-the-road-ahead-review/
- gamescreed.com/reviews/a-quiet-place-the-road-ahead-review
- wikipedia.org/wiki/SCP_-_Secret_Laboratory (Containment Breach blink meter)
- steamcommunity.com/app/1966720/discussions (Lethal Company mimic tell)
- gamedev.net/blogs/entry/2274434-designing-the-perfect-monster-for-a-survival-horror-game
- pcgamer.com/every-rat-in-a-plague-tale-innocence-will-behave-like-a-filthy-little-individual-creature
- blog.playstation.com/archive/2019/05/09/how-a-plague-tale-innocences-horrifying-rat-swarm-was-created
- dev.epicgames.com/documentation/en-us/unreal-engine/unreal-engine-5-8-release-notes
- unrealengine.com/news/unreal-engine-5-8-is-now-available
- unrealengine.com/tech-blog/download-the-latest-game-animation-sample-project-now-updated-for-ue-5-8
- dev.epicgames.com/documentation/en-us/unreal-engine/overview-of-state-tree-in-unreal-engine
- dev.epicgames.com/documentation/unreal-engine/statetree-selectors-overview
- forums.unrealengine.com/t/statetree-performance-vs-behaviortree/2705328
- dev.epicgames.com/documentation/unreal-engine/ai-perception-in-unreal-engine
- unrealcommunity.wiki/create-a-custom-sense-for-the-aiperception-system-98caf2
- dev.epicgames.com/documentation/unreal-engine/smart-objects-in-unreal-engine---overview
- forums.unrealengine.com/t/ai-multiple-nav-meshes-for-multiple-agents/334486
- forums.unrealengine.com/t/ai-walk-on-wall-and-ceiling/477633
- fab.com/listings/575661f9-a0a9-470b-840d-3ddf6eb08f7b (Dynamic Surface Navigation)
- forums.unrealengine.com/t/mass-5-5-mass-entity-thousands-of-units/2487745
- dev.epicgames.com/documentation/en-us/unreal-engine/motion-matching-in-unreal-engine
- dev.epicgames.com/documentation/en-us/unreal-engine/API/Plugins/PhysicsControl
- forums.unrealengine.com/t/community-tutorial-step-by-step-control-rig-procedural-walk-spider/726662
- trentriek.github.io/Unreal/ProceduralLlamaGait.html
- dev.epicgames.com/documentation/en-us/unreal-engine/automation-test-framework-in-unreal-engine
- tessl.io/registry/testland/unreal-automation-system
