# Rovloc: what the player wants now (requirements for spec v2)

This file wins over `finale-spec.md` (spec v1) wherever they differ. Spec v1 was written before the player added the
city escape, cut two floors, and asked for the radar, the lives and the gray look.

## 1. The player's words (verbatim, newest last)

**Earlier, already designed in spec v1** (keep unless changed below):
- "Remake the roof because it just being fully open is kinda boring. Just make it like one final chase like door 100 on
  doors, you just run through a bunch of obstacles and do parkour ... I also want the game to actually be like scary
  and I don't like floor 4 so remake that as well." Floor 4 became the **Auditorium** (player's choice).
- "I want there to be like lore in the game. So in the beginning there's a cutscene, you, your friend, and everyone
  else in your party are walking out of school talking making jokes. While in your way out, something comes out of the
  trash bin, at first it looks harmless, but then it jumps on your friends face, he screams in agony and he transforms
  into the monster. You and everyone in your party run, hiding in different bins. He goes to ruin the school and kill
  everyone and you hide until night. While playing, he calls you and your friends names, and I want him to speak to
  you like if hes behind you or something or if he is chasing you. For the ending ... you find a gun on the roof after
  the parkour, and you have a chance to shoot him. If you do, there's another cutscene of your friend dying in the
  rain, if you dont, he goes on to pick you up and push you off the ledge."

**New (Nov 5–10):**
- "Make it so the tab button that tells you where the doors are or the fuses are etc isn't like always allowed and the
  cd isn't enough. I want you to remake it to like a radar and when you find batteries around the map, it will
  recharge the radar and it will show u where the fuses or like the door is for a bit. Make sure you add much more
  batteries around the map then."
- "I also don't want the game to be too hard because there's so many floors, so make it so each floor, you can get
  healed if you're down, and if you get hard killed, you get 1 respawn. And if you have the syringe it gives you an
  extra one."
- "Also make sure you keep the same like dark scary theme for all levels like the basement is kinda like copper
  looking idk if i like that yk i want it to be like gray and scary, also you can remove the white and black tiles off
  the floors for the levels that have them i don't really like that."
- "What I want is not for it to be like so 1 sided. So basically after you kill him and jump off with the parachute,
  you now have to escape the city, which is outside and the only way to escape is to get to the airport and get to the
  plane fly and land in the Bahamas. Make the city be basically so after you shoot and kill your friend, the mask
  climbs on someone else like the school janitor who was just chilling in a closet the whole time. After you shoot he
  comes out confused cuz he was sleeping the whole time and then the mask crawls on him and he turns into the monster
  as u parachute. So make it so you must escape the city and make your way to the airport like rooftop parkour etc.
  But since we adding another part, we should scrap some of the first part cuz I don't want the game to be that long.
  So just make it so the game still makes sense while scrapping some floors."

## 2. The player's choices (asked and answered Nov 10)
| Question | Choice |
|---|---|
| Which school floors stay | **Basement, Hallways, Auditorium.** The Science Hall and the Gym are cut. The pool was already cut. |
| How the city plays | **Rooftops, then airport**: two stages. A rooftop maze with parkour (planks, fire escapes, jumps between buildings) where you sneak and hide like in the school, then the airport. |
| The plane | **Takeoff chase, then cutscene**: you start the plane and steer it down the runway yourself while he chases it; after lift-off a cutscene shows the flight and the sunny landing in the Bahamas. |
| Build order | **Website first**, then the Roblox port. Both must end up the exact same game. |

## 3. The game flow now
1. Lobby (as today) → deploy.
2. **Opening cutscene** on the school's back lot (the mask takes the friend, Danny; everyone hides in bins until night)
   → short prologue → into the Basement.
3. **Basement.** Objective unchanged: restore power (3 fuses, breaker panel, main breaker). The monster hunts here.
4. **Hallways.** Objective unchanged: the janitor's master keys, the padlocked stairwell. The classroom scare, the gate
   and its bypass vent stay. **The janitor is asleep in his closet on this floor the whole time** (foreshadowing).
5. **Auditorium.** New floor from spec v1 (reels, projectors, the loud film, the hidden exit).
6. **Roof: "The Last Run".** The parkour chase from spec v1, ending at the revolver and the standoff.
   - **Don't shoot** (or lower the gun, or run out of time): he carries you to the ledge and throws you off. Bad ending;
     the run ends.
   - **Shoot:** cutscene, Danny dies in the rain. Then the janitor wanders out onto the roof, confused, having slept
     through everything. The mask crawls onto him and he transforms **as the players parachute off the roof**.
7. **City 1: Rooftops.** The janitor-monster hunts you across the rooftops toward the airport.
8. **City 2: Airport.** Get to the plane and get it started → **playable takeoff chase** down the runway → cutscene:
   the flight and the landing in the Bahamas, in daylight. Good ending.

Target length for a first full run: **about 45 minutes** (roughly 8 minutes per stage for the five sneaking stages,
plus the cutscenes, the roof chase and the takeoff).

## 4. Lead's decisions (settled; design within them)
- **Names and backstory from spec v1 stay:** the friend is Danny Reyes; the 1989 Hale brothers; the bell tower holds
  the revolver. The player was shown these and didn't object.
- **The parachute is back**, but only as the roof → city transition after the shot. Reuse the existing parachute
  mechanic (pack, jump, cord, canopy, landing) where it helps; a pure cutscene is not enough, since the player said
  "as u parachute". The old bolt-cutter / crate search stays removed.
- **The janitor-monster** is the same mask on a new host: the Tall Man rig with janitor traits (torn grey jumpsuit,
  a key ring that jingles as an honest audio tell). Same behaviour rules as `docs/MONSTER.md`. The mask keeps Danny's
  memories, so it still knows the players' names.
- **Radar** (replaces the Tab hint entirely):
  - Tab (and its touch/gamepad buttons) is now "Radar". No free hints, no cooldown-only hints.
  - Every battery picked up gives the radar one charge (it holds a few) and still tops up the torch as today.
  - A scan shows, for a few seconds, where the things you still need are: the remaining objective items, the station
    for the current step, and the exit once it is unlocked. Exact positions, not just rooms.
  - Much more batteries on every stage (about three times today's candidates), with a fair guaranteed minimum per run.
  - Keep it forgiving: the player asked for it because the game is hard to navigate.
- **Lives** (the lead's reading of the player's words; the player may adjust the numbers):
  - **Once per stage**, a downed player can get back up without help. Teammates can still revive as today.
  - **One respawn per stage** after a kill on Standard (amended Nov 10: "each floor ... if you get hard killed, you get
    1 respawn" reads per floor; Nightmare gets one per run), at the current stage's entry, with the monster moved away
    and a short grace.
  - **The syringe gives one extra respawn** (once per run).
  - Per player in co-op. Say what Nightmare changes, if anything.
- **Look (corrected by the player on Nov 11):** "By gray feel i didn't mean everything look gray, I meant like look at
  threshold its like dark gray theme, that doesnt mean all colors are actually gray ... a spooky theme like a school after
  hours dark and ruined but not all gray." So: a dark, ruined school at night, gray-leaning overall like Threshold, with
  real faded colours in the materials (paint, lockers, wood, brick, rust, painted mains). No orange wash (the basement was
  "copper looking"), no all-gray frame, no black and white checkerboard floors anywhere. The Bahamas ending is the one
  bright, warm scene in the game.
- **Stun flasks stay** as a mechanic (cleaning chemicals), with spawn spots on the remaining stages.
- **Kept from before:** tunnels unless necessary; random exits (3 stairwells per side) between school floors; random
  item spots with the fairness rules; hiding spots (lockers, barrels, cabinets, drapes); crawlways; bear traps in the
  basement; co-op for 1–4 players; Standard and Nightmare; the perk shop; graphics tiers Max..Potato that change only
  visuals.
- **Removed on both platforms:** the Science Hall (reagents, acid), the Gym (coach's key, generator), the pool
  (swimming, oxygen, the grab struggle, floodlights, the valve wheel), the bolt cutters and crate search, the Tab hint.

## 5. Constraints every design must meet
- **Two native platforms, one game.** The website (three.js, `web/`) is built first; Roblox (Luau, `src/`) is ported
  from it. Maps, props and the monster rig come from the shared Luau world builder, so both platforms get identical
  worlds. Rules live in small pure modules with golden tables so the port can match exactly.
- **Gameplay never depends on graphics tier or frame rate.** Spec v1 found that the web player moves once per rendered
  frame, so a sprint jump goes 6.2 studs at 144 fps and 9.5 at 10 fps. Fixing this (player physics on the fixed 30 Hz
  tick) is required before any parkour is built.
- **School Chromebooks.** The Potato tier must hold 60 fps. The city is outdoors, where zone culling helps less:
  design the rooftops with occluders, night, storm and fog so the visible set stays small. Give a budget.
- **Content limits.** The school massacre is implied, never shown. The gun is one old revolver with one bullet, used
  only on the monster. The shot and the deaths are not gory. Ending B cuts to black before impact.
- **Scope discipline.** The player's weekly usage limit is the bottleneck. Mark every feature **P0** (must ship) or
  **P1** (polish if budget allows). Prefer fewer, stronger set pieces over long lists.
- **Fairness.** A hiding spot within 25 studs of every objective step. No blind jumps. A clean run of any chase always
  escapes. The monster is never faster than a sprinting player outside scripted chases with their own fairness proof.

## 6. Later player feedback (newest last; these win over sections 4 and 5 where they differ)
- **Nov 11, the look:** "I liked the original Icl I just want it to have a more scary theme like I dont want only the monster
  to be scary but the surroundings too". Done: the original look is restored (no checkerboard). In progress: the
  scary-surroundings pass (traces of him, signs of what happened, writing, dying lights, distant sounds; no gore).
- **Nov 15, the monster:** "i never really see the monster unless he like tp's behind me ... when he tps i can js run its not
  really that good ... maybe keep him always in a certain radius with me or make the detection better ... find a good
  solution". In progress: the presence director (he stays 35 to 90 studs away in waves), presence beats (Peek, Glimpse,
  Shadow, Pass-by), wider detection (noise, the lit torch), persistent chases and cut-off teleports; still never faster
  than a sprint, every teleport warned.
- **Nov 15, fun:** "make sure its also fun and scary in the city do some cool stuff and same for in the school i dont wanna
  be a boring game yk?" Lead's decision: every stage gets at least two signature moments and something new to do, and these
  move from P1 to P0 inside the stage packages:
  - Basement: the wall phone rings in the dark workshop; lights die one by one down the corridor behind you while he hunts.
  - Hallways: the PA crackles and whispers a player's name; a row of lockers slams in a wave; the janitor's snore and "Wake him".
  - Auditorium: the loud film you must survive; mannequins that are not where they were when the lights come back; his
    curtain call in the spotlight; the brick wall flying up to show the hidden exit.
  - Roof: the storm chase with lightning showing him behind you and hurdles smashing; the leaps; one bullet; the mask
    crawling onto the janitor as you jump.
  - Rooftops: he lands on the roof with his keys jingling; pigeons burst up when he is near; the dead billboard lights up
    on his silhouette; he must run round by the gantries while you leap, so you watch him come.
  - Airport: the departure board flips to spell a name; the baggage belt starts by itself; the 20-second hangar door.
  - Takeoff and ending: dodge the rows while he runs you down, a flask thrown from the plane; the Bahamas at sunrise; a
    key jingle after the credits.
- **Nov 15, sound and voice:** "i want the sounds to actually be scary. Rn its like this vibecoded high pitched sound. I also
  want his footsteps to be louder so people know when hes around, and i want him to talk remember i said that but hes not
  talking like him say the name sometimes or like mock you or something but dont overdo it. Make the sounds of the monster be
  scary and his footsteps be scary and other sounds be scary too like the glass its all lame sounds". Lead's decisions:
  - A SOUND REDESIGN package (after the monster-presence and scary-surroundings jobs land, since all three touch the sound
    presets): every sound rebuilt from noise, body resonance, sub-bass and room reverb instead of thin high tones: his
    footfalls heavy and low and audible from far (the tell that he is around), breath, the mask's porcelain rattle, the
    jumpscare, the teleport hiss, glass, doors, lockers, the breaker, stingers, the heartbeat. An audit tool renders every
    preset offline and fails any sound that is a bare tone or sits mostly above 2 kHz without body; loudness targets per
    kind. Agents cannot hear: the player is the final judge on the beta.
  - THE TALKING MONSTER (spec 3.4, WP12) moves up: right after the cutscene package lands (it brings speech and subtitles).
    He says a player's name sometimes and mocks them when they hide or run; rare (well under one line a minute on average),
    never two lines close together.

### Nov 15 (later): sound redesign, how it is built (lead decision; amends spec 5.5 "no sound files")
- Every sound is still made only by our own code (no recording, no third-party sample), but by a real synthesis kit
  (web/sounds/kit, plain JS DSP in Node, seeded and deterministic) rendered OFFLINE at build time into audio files that ship
  with the site (web/build/audio -> site). At run time the game only plays files. The Roblox port uploads the same renders
  (packed into a few sheets and sliced with PlaybackRegion, to stay inside the audio upload quota).
- Phase A (workflow wf_bc53397b-3a3, task wzome3enb, launched Nov 15 17:25 UTC; adds files only: web/sounds/, docs/SOUND.md,
  web/package.json scripts): kit, render pipeline, audit with numeric class rules and spectrogram sheets, sound board
  (web/build/soundboard, to publish at /beta/sounds/ for the player's ear), the whole cast voiced (presets, inline recipes,
  the three in-flight jobs' sounds, spec 5.5). Reference set: his footsteps (audible at 80 studs above the bed, through one
  wall at 45; 10 dB above a player's), his throat/body, the players' footsteps, glass.
- Phase B (after the three in-flight jobs land AND phase A is done): the run-time switch (the game plays the files; distance
  model: gain, low-pass and reverb share by distance and walls; at most one shared convolver; his footsteps as presets with
  the long roll-off; ambience and scary-surroundings events on the new sounds), shared metadata in SynthPresets, gates, beta.
- The sound board goes on the beta as soon as phase A is done, before phase B, so the player can say which sounds are still lame.

### Nov 15 (21:35 UTC): the player on the first 64 generated sounds (sound board)
- Verbatim: "Its got like this wooden thing like the clicks yk they dont sound good fix that reference other horror games use their sounds"
- Lead decision: STOP pure synthesis as the source of the game's sounds. It reads as wooden knocks (modal bodies) and clicks (the porcelain ticks, the rattle gate).
  Other horror games use RECORDINGS (foley, animal and human vocals pitched down, layered, in a room): do the same.
  Never copy another game's files (copyright). Sources: CC0 only (Kenney audio packs; OpenGameArt pages that state CC0), every file traced in a sources list
  (page, author, licence, sha256). The kit stays for processing (pitch, filter, layer, room, limiter, loudness, encode) and for abstract layers (sub, drones, risers).
  The "porcelain tick" signature is dropped unless a real ceramic recording is used, sparingly.
- Environment "rovloc" created (env_01XJJ5N1zoGzHMogNyoT5Dqd; hosts kenney.nl, opengameart.org; this session switched to it, network only).
- Sources downloaded to scratchpad/sound-sources/{kenney,oga}/<pack>/ with source.json each (tools: scratchpad/sound-tools/fetch_oga.py, fetch_kenney_browser.mjs).
- Candidates page built by the lead from those recordings (scratchpad/sound-tools/picks.py -> site/beta/sounds/picks/, commit b788a05): his footsteps A-D,
  his breathing A-D, his growl A-E, the jumpscare A-C, glass A-B, a door A-C, your footsteps A-B. The player picks letters; the rebuild follows the picks.
- The synthesized world/air voices (105 sounds) are CANCELLED; all 169 sounds get rebuilt from recordings once the player has confirmed the direction.

### Nov 15 (23:00 UTC): the player on the beta's opening
- Verbatim: "Okay the cutscene has bad graphics make them look like actual people and i can only get out of the bin until a long time fisx sthis"
- Bin: fixed (37dd942: the lid prompt answers whichever way the player looks; on the beta 353e307). The retiming (Full 78 -> 61 s, AutoClimbOut 20 -> 8, a hint) is job "opening-pace".

### Nov 16 (about 02:00 UTC): the player, after the bin fix
- Verbatim: "bro why cant he go thru the small little holes, also the cutscene still really bad i want it to look realistic realistic looking horror game bro. and if opus 5.5 wont hurt the perforamnce ig u can switch to that"
- SMALL HOLES (lead's reading: "he" is the monster, as everywhere in the player's messages; the holes are the vents, crawlways and crawl-only gaps he cannot enter today: MONSTER.md "never uses a vent", crawlOnly portals shut to him). DECISION: he gets a way through: he folds himself and crawls (the thing came out of a bin folded up). Fair: slower in a duct than a player who scurries, always heard (scraping), never camps a duct's exit, every duct keeps a second way out. Package "the fold", right after the presence package lands. If the player meant something else they will say.
- REALISTIC: the player rejects low-poly people ("i want it to look realistic realistic looking horror game"). DECISION: a spike first (job "realistic-opening-spike"): realistic humans from a real human model (MakeHuman family, CC0), skeletal animation, PBR materials, sun shadows, atmosphere, on Max and High, a cheap version on Potato (tiers are visual only; Potato keeps 60 FPS on a Chromebook). Then the whole opening, then the rest of the game. The cancelled low-poly people work stays cancelled.
- MODEL: the player allows Opus 5.5 again. Measured on Nov 16 01:05-01:44 UTC: three fable/max workers emptied a whole 5-hour window in 39 minutes (1.8M tokens, 433 tool calls); opus/high gets about 850 tool calls from a window. DECISION: workers on opus/high from Nov 16 06:05 UTC; the lead stays on the session's model.

### Nov 16 ~12:05 UTC, the player (verbatim)
"okay keep going send the beta and pics when ready and i want the game to actually be realistic like look like human yk
then its scary, make thhe monster also look creepier you changed the face the body is not scary tho"
- Decisions (lead): (1) beta + pictures are sent as soon as the combined tree is green and the realistic spike reports.
  (2) REALISTIC HUMANS are the bar for every person in the game (the opening's five kids, co-op teammates, the janitor
  later): real human models (MakeHuman CC0 base + CC0 skins, clothes, hair), motion capture, real light and shadow.
  (3) THE MONSTER'S BODY gets a redesign to the same realistic standard and must be frightening by itself: the mask
  (face) stays as the player accepted it; the body is what fails. Direction: a human body gone wrong, not a costume:
  far too tall and thin, arms that hang to the knees, long fingers, a spine and ribs that show, a neck and joints that
  sit and bend slightly wrong, skin or cloth with real texture, movement that is wrong for a human (too still, then too
  fast; a head that turns first). No blood or gore (I12). Gameplay untouched: same height (11 studs), same hitbox,
  same speeds; Potato keeps 60 FPS with a cheap version. The Roblox port gets the same mesh later.

### Nov 16 ~12:55 UTC, the player (verbatim)
"Yeah so basically i want the game to look realistic as realsitic as possible and to have a scary eerie feel."
- Decision (lead): this is now the LOOK LAW for the whole game, on every stage: as realistic as a browser allows on Max
  and High (real human models, real scanned materials, real light and shadow, a film camera), the same picture made
  cheaper on the lower tiers (tiers stay visual only; Potato keeps 60 FPS), and an eerie mood (darkness that hides,
  light that fails, air with depth, things half seen). Order of work: people (kids, teammates) -> the monster's body
  -> the school's materials, light and camera -> every later stage is built to this law from the start.
- First pictures (spike, lead's own reading, 13:00): the walking shot reads as real kids with a low sun and long shadows;
  the close-up face is still a mannequin (flat skin, dark eye sockets, jagged collar), the Potato face is destroyed by
  the low LOD, and the standing teammate's idle pose is wrong (crouched, arms out, feet off the floor). Fix all three
  with the CC0 MakeHuman skins, eyes, hair and clothes now reachable, a face-safe LOD, and a proper idle.

### Nov 16 ~13:12 UTC, the player (verbatim)
"And for the cuts center number1 it should be like they walk out of school telling jokes,make their voices sound human
I want them to actually talk. I want the monster to talk too real words. Like make the gsme look realistic if u needs
rework anything do so. The thing crawls out of a garbage bin, jumps on the floor a couple of times, he bends down and
is saying like this is so cute to me, then while hes looking away, it crawls on him and he slowly transitions to the
monster. Look at other roblox or other popular horror games online see their graphics sound design of walls scaryness
yk. Recreate all this just for my game"
Decisions (lead):
- OPENING v3 (cutscene number 1), the player's beats kept exactly: (1) the kids walk out of the school telling jokes,
  really talking; (2) a small thing crawls out of a garbage bin and hops on the ground a couple of times; (3) Danny
  bends down to it and says to the player's kid something like "this is so cute"; (4) while he is looking away (at the
  player), it crawls onto him; (5) he slowly changes into the monster. Then the others run and hide in the bins, the
  lockdown, night, the hand-over to the player in the bin (the pace package's tail and 8 s climb-out stay).
- THE MONSTER IS DANNY. The thing rides him. Its small porcelain face is the mask the player accepted, grown over
  Danny's face; the monster's body (task 46) is Danny's body grown wrong, in what is left of his clothes; the monster
  speaks with Danny's voice gone wrong (WP12), says the player's name sometimes, and can say "so cute" back.
- THE THING: an original design, cute at first glance: kitten-sized, pale and soft, a small smooth porcelain face (the
  mask in miniature: big dark eyes, a tiny painted smile), hops like a frog, makes a small sound. Not taken from any
  existing game or character.
- THE CHANGE: slow, in several shots, no blood or gore: limbs lengthening, joints cracking (sound), cloth tearing at
  the seams, the porcelain spreading over his face; partly against the light and through the other kids' faces.
  Technique: Danny and the monster are the same MakeHuman topology, so the body is a morph (shape key) plus bone
  rescaling; fitted clothes follow.
- VOICES: every line is spoken by a human-sounding voice rendered offline with an open speech model whose licence
  allows commercial use, shipped as files like the sounds (subtitles stay; a jaw and lip flap follows the audio).
  Laughs, gasps and screams come from CC0 recordings. The kids sound like teenagers. The monster: Danny's voice
  lowered, slowed, doubled with a whisper. The player's name: a set of common first names rendered in advance; a name
  not in the set gets the lines without a name. Never clone a real person's voice.
  Sources reachable: Kokoro (Apache-2.0) from GitHub release assets (k2-fsa/sherpa-onnx tts-models; pip sherpa-onnx or
  kokoro-onnx) and Hugging Face (huggingface.co + us.aws.cdn.hf.co allowed by the owner on Nov 16): candidates to
  compare for acting (laughs, emotion): Chatterbox / Chatterbox Turbo (MIT), Orpheus (Apache-2.0), Dia (Apache-2.0),
  Parler-TTS (Apache-2.0), Pocket TTS. Not allowed: XTTS (non-commercial), F5-TTS and Fish Speech (NC).
- RESEARCH (asked for): study popular horror games, Roblox ones (DOORS, The Mimic, Pressure, Apeirophobia ...) and
  others (P.T., Outlast, Amnesia, Resident Evil 7, Phasmophobia, Poppy Playtime, FNAF ...): their light, their walls
  and materials, their sound design, how they pace scares, how their monsters look, move and sound, how characters
  talk. Take TECHNIQUES only; every character, level, texture, sound and line in ROVLOC stays original. WebSearch works
  from this session.
- REWORK PERMISSION: "if u needs rework anything do so": the renderer, the materials pipeline, the cutscene system,
  avatars and the monster's rig may be reworked for the look; gameplay rules, map sizes, hitboxes stay (tiers visual
  only).
- STORY CONSEQUENCES to settle (story editor): what the squad wants in the school now (get out; maybe get Danny back),
  the endings on the roof (the gun: what was Danny), the janitor, the lines of later cutscenes.

### Nov 16 ~15:20 UTC, the player (verbatim)
"Okay zo just saying it 1 more time make the monster appear more make the game ultra realistic look online for realistic
like survival games or like cs2 yk recreate graphics on that. Make it have actual scary sounds from horror gsmed
popular, and make it eerie but I dont want the monster coming every minute maybe like just make it stay in a radius and
make it be able to crawl under the little holes and make it just more fun idk look at threshold on roblox I want the
monster to appear same times as that reference that and look online for popular well done games and try to recreate
monster logic for what I want. Make sure he talks good English make sure in the cut scenes the sounds and talking is
good I want the game to be realistic asf."
Decisions (lead):
- MONSTER v3 = two layers. LURK: he stays inside a radius of the squad most of the time (a leash, walked distance),
  moving, HEARD (his far footsteps, his voice) and now and then SEEN far off (the end of a corridor, crossing a
  junction), never attacking out of that: this is "appear more". HUNT: direct approaches and chases are events, NOT
  every minute: their cadence is taken from THRESHOLD on Roblox (research it: how often its entity shows itself and
  attacks, the cues before, the quiet after); until the research is in, Standard = a direct encounter about every
  2.5 to 4 minutes and never two within 90 s. Each hunt has a build-up (sound, lights) and a release (quiet).
  The known pattern for this is a director with a menace gauge (pressure builds while he is near, then he is sent
  away and the players breathe): study Alien: Isolation's director, Resident Evil 2's stalker (heard through walls),
  Amnesia, Outlast, Phasmophobia's hunts, DOORS's cue-then-event entities, and THRESHOLD itself.
- Presence targets are restated (MONSTER.md 20, presence-sim): a heard or far-seen cue at least every 60-90 s;
  direct encounters per the THRESHOLD cadence (mean interval, minimum 90 s apart); the careless bot 0.3-0.8 downs a
  floor and at most 20 % of floors with two or more; the careful bot none. The old "longest gap 150 s" target
  counted close presence: it is replaced by the two measures above.
- THE FOLD (task 45) is part of v3: he follows into vents and crawlways by folding and crawling, slower than a
  crawling player, always heard, never waits at an exit, every duct keeps a second way out.
- "More fun": counterplay that feels good (hide, break the line, the flask, luring him with noise), near misses, his
  voice; decided after the research.
- GRAPHICS reference: Counter-Strike 2 and realistic survival games: clean physically based materials from scans, baked
  indirect light and occlusion, sharp readable surfaces, real props, a film camera. Research how they get it and what
  of it a browser can do (look bible v2).
- SOUNDS "from popular horror games": we cannot take another game's sound files (copyright: the game could be taken
  down). We study how those games' sounds are made and what they are (which sounds, how low, how long, when) and
  rebuild that from free CC0 recordings. Told the player again on Nov 16.
- "He talks good English": the monster's and the kids' lines are written in natural, correct English and must be
  understood: an automatic transcription of every rendered line must return its words (the monster's processed
  voice included); subtitles always. Cutscene mix: speech clear over the ambience (ducking), no line cut off.

### Nov 16 ~15:30 UTC, the player CORRECTS the lead (verbatim)
"No I meant I wanted more interactions 4 minutes too much maybe one every 20 sec or 15 if sprinting and 30 sec if
walking and like 1 min if crouching only ideas"
Decisions (lead): THIS REPLACES the "direct encounter every 2.5 to 4 minutes" line above. The player wants MANY
interactions, paced by how loudly the player moves (his numbers are starting values, "only ideas"):
- SPRINTING: an interaction about every 15-20 s. WALKING: about every 30 s. CROUCHING: about every 60 s.
  (Standing still or hidden: slower still. In co-op the loudest nearby player sets the pace for that area.)
- An INTERACTION is any moment the player notices him: heard close (footsteps, breath, a spoken line), seen (a peek
  round a corner, a glimpse crossing a junction, a shadow following, a pass-by), a warned teleport, a vent crawl-by,
  or a chase. Most interactions are NOT attacks: chases keep their own budget (about the package's 2-5 a floor on
  Standard, never two within about 60-90 s, quiet after a catch), so the game stays "not too hard": the careless bot
  0.3-0.8 downs a floor, at most 20 % of floors with two or more; the careful bot none.
- This gives sneaking a point: sprint and he is on you constantly; crouch and he mostly leaves you alone.
- He still stays inside a radius of the squad (lurks), crawls through the small holes (the fold), talks, and the
  THRESHOLD research still sets the reference for how its entity paces its appearances.
- presence-sim measures it: the mean gap between interactions per movement mode (a sprinting bot, a walking bot, a
  crouching bot), against 15-20 / 30 / 60 s, plus the chase budget and the downs targets. MONSTER.md 20 is rewritten.

### Nov 16 ~16:10 UTC, the player (verbatim)
"ALSO FOR THE GSME USE UNREAL ENGINE AND CONNECT TO HIGGSFIELD"   then   "Are you connecting?"
Decisions (lead):
- UNREAL ENGINE: not possible for this game. Unreal cannot export to a browser and cannot run on a school Chromebook
  (the game's main target) or inside Roblox (the second target); the Unreal Editor cannot run in this cloud container
  (no GPU, no desktop); it would restart the game from zero. Told the player plainly. The realistic look is pushed as
  far as a browser allows (look bible; research on CS2-style techniques).
- HIGGSFIELD (an AI image and video generation service): its official Claude connector is a custom connector at
  https://mcp.higgsfield.ai/mcp, authorised with the player's own Higgsfield account (sources say a paid plan and
  credits are needed; every generation spends credits). The lead cannot add a connector: the PLAYER adds it at
  https://claude.ai/customize/connectors, and connectors are only read when a session starts, so THIS session will not
  see it: once the player says it is connected, start a HELPER cloud session (create_session, same environment), steer
  it with send_message and read its results with list_events; it generates and commits the files to the branch.
  Best use: the OPENING CUTSCENE AS A PHOTOREAL VIDEO with talking characters (kids joking, the thing from the bin,
  Danny's change), played as a video file in the website (works on a Chromebook; skip vote and co-op sync as today);
  also concept images for the monster's body and the thing so the player can pick. Not for gameplay graphics (those
  are real time). Open points: the player's credit budget (ask for a cap before spending), Higgsfield's rules on
  realistic minors and horror (the cast may have to read as older teens; the change shown without gore), commercial
  rights of the outputs (read their terms), Roblox cannot play such a video (keeps the in-engine cutscene).

### Nov 16 ~16:20 UTC, the player (verbatim)
"Ill connect higgsfield when I get home make all graphics and everything with that make it look like games on unreal
editor but for web and roblox"
Decisions (lead):
- The player connects Higgsfield later today. LOOK TARGET restated: like a game made in Unreal, delivered on the web
  and on Roblox (the look law; the honest ceiling was told to the player).
- WHAT HIGGSFIELD MAKES (it produces images and video, not 3D and not the live picture): (1) the cutscenes as
  photoreal video with speaking characters (the opening first; later the endings); (2) concept sheets for the
  monster's body, the thing and the five kids, which the player picks from and the 3D models then follow; (3) flat
  art the live game shows: the sky and skyline behind the lot, posters, notices, yearbook photos, a missing-person
  poster of Danny, graffiti, stains and other wall decals, signs, screens; (4) the title screen, loading art, the
  Roblox icon and thumbnails; (5) texture sources where a scan is not available (made seamless, with normal and
  roughness maps derived). The live 3D look itself (materials, light, models, camera) is built in the engine to match.
- PREPARE BEFORE THE PLAYER CONNECTS: the opening v3 script and a shot list (one entry per clip of 5-10 s: the
  picture, the camera, the line spoken, what must stay the same from clip to clip), a prompt pack for the concept
  sheets and the wall art, and the video player in the website (a video cutscene with subtitles, the skip vote, co-op
  start in step, the hand-over to play). Then the helper session only has to generate.

### Nov 16 ~17:40 UTC, the player (verbatim): STANDING INSTRUCTION FOR THE END
"Okay but when the full website is finished run gsme test bug sweeps and any changes I want with fable 5.2 max ultracode"
Decision (lead): once the full website is finished (every stage, the look, sounds, voices), the FINAL PHASE runs on
Fable 5.2 at MAX effort with ultracode workflows: the whole-game test (every requirement in this file checked against
the real game), bug sweeps (finders -> adversarial verification -> fixes -> re-test, repeated until two rounds find
nothing new), and every change the player asks for from then on. Until then: Opus/high builds and fixes, Fable/high
for writing, design and judging (the player agreed on Nov 16). Tell the player what the max-effort phase costs in
usage windows when it starts.

### Nov 16 ~19:45 UTC, the player (verbatim)
"okay keep going send the beta when ready and ill connect higgsfield I want most graphics work done with jiggsfield
for now do stuff u dont need higgsfield for and once I connect u use that"
Decisions (lead):
- ART PRODUCTION WAITS FOR HIGGSFIELD: no new hand-made art until it is connected (the kids' skins and clothes, the
  monster's body, the lot restaged, new wall art and texture sets). The opening's pictures become Higgsfield video.
- BUILT NOW (none of it needs Higgsfield): tonight's beta; monster v3 (the interaction clock, the lurk radius, tells,
  the strain gauge, the chase budget, the vents); every line spoken (the kids and the monster); the opening v3
  script, shot list and prompt pack; the website's video-cutscene player; the stage runtimes; then the engine's own
  light and camera (bounced light in the bake, the HDR film response, the torch), which no image generator supplies.
- WHEN THE PLAYER SAYS IT IS CONNECTED: ask once for a credit cap, start a helper session (connectors load only at a
  session's start), check that it has the Higgsfield tools, then generate in the order of the shot list.

### Nov 16 ~21:30 UTC, the player (verbatim)
"Higgsfield is connected take a look see if u can use it"
What the lead found (read through the connector, nothing generated, no credit spent):
- The connector "Higgsfield AI" IS loaded in the lead's own session (no helper session needed). Its tools:
  list_workspaces, workspace_select, balance, models_list, models_get, show_generations and
  import-claude-motion-from-url. Its own instructions say: "This connector cannot generate media, upload arbitrary
  files, or make purchases." So the lead can read the account, the model catalogue and finished generations (with
  their result links), but cannot start a generation or upload a reference picture.
- A second connector named "Higg" is in the player's list with its sign-in not finished (connect_incomplete); it
  may be the custom one (mcp.higgsfield.ai) with the generation tools. Only the player can finish it.
- Balance: 10 credits, free plan. Not enough for a video cutscene; some video models need a paid plan.
- The catalogue (models and their settings) is digested in the story folder: higgsfield-live.md.
Decisions (lead):
- No credit is spent and nothing is bought without the player's own word and a cap.
- The prompt pack is written so that EITHER the lead runs it (if generation tools and credits appear) OR the player
  pastes each recipe into the Higgsfield app himself and the lead collects the results through show_generations.
- The opening v3 is ALSO built in the game engine (real-time, the new script, real voices) so that the game does
  not depend on credits; a Higgsfield video replaces it later through the video-cutscene player if one is made.
