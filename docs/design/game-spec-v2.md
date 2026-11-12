# ROVLOC spec v2: the whole game

The single spec of the game as the player wants it on 10 Nov: a three-floor school, the roof chase and the choice, the
janitor twist, the parachute, two city stages, a playable takeoff and one sunny ending. Website (three.js, `web/`)
first, then Roblox (Luau, `src/`); both native, both the same game. It replaces `finale-spec.md` (spec v1).

**Conventions**
- Studs and seconds. Numbers are Standard; the Nightmare value follows in [brackets] where it differs.
- Coordinates are level-local unless marked "world": x 0..400 west to east, z 0..288 north to south, y above the level
  floor. Yaw 0 faces north.
- **P0** = must ship. **P1** = polish, built only if budget remains. Everything is P0 unless it is tagged P1.
- Whatever this spec does not mention stays as it is today: `docs/MONSTER.md`, `docs/MAPS.md`, the Basement and
  Hallways objectives, the perk shop, the lobby, the graphics tiers.
- "In view" always means MONSTER.md §7.1: within an 80-degree half-angle of the view direction with a clear line, or
  within 8 studs of the eye.
- The repository today still holds the Science Hall, the Gym, the flooded pool and the maze roof. Nothing of spec v1
  has been built. The work packages in §7 start from that tree.

---

## 0. Overview

### 0.1 The run (about 46 minutes the first time)

| # | Stage id (the one id both platforms use) | Kind | Card | Par (min:s) |
|---|---|---|---|---|
| 0 | `BackLot` (a set) | opening cutscene, then a 25-stud walk | none | 2:20 (1:10 on replays) |
| 1 | `Level0_Basement` | sneak | FLOOR B · BASEMENT | 8:00 |
| 2 | `Level1_Hallways` | sneak | FLOOR 1 · HALLWAYS | 8:00 |
| 3 | `Level2_Auditorium` | sneak | FLOOR 2 · AUDITORIUM | 7:30 |
| 4 | `Level3_Roof` | chase, standoff, twist, parachute | THE ROOF · THE LAST RUN | 4:00 |
| 5 | `City1_Rooftops` | sneak, parkour | PART TWO · THE CITY · ROOFTOPS | 8:00 |
| 6 | `City2_Airport` | sneak | THE CITY · AIRPORT | 7:00 |
| 7 | `Runway` (a set) | takeoff chase | WHEELS UP | 0:45 |
| 8 | `Bahamas` (a set) | ending cutscene | none | 0:45 |

- **Rhythm:** three slow stages, a chase and the choice, two slow stages, a chase, release.
- **The two ways it ends.** Do not shoot on the roof: Ending B, "The Fall", and the run ends there. Shoot: the second
  half plays and ends in "Sunrise". A squad that runs out of lives gets "THE NIGHT TOOK YOU".
- **Id scheme (§4.2).** The six playable levels are `LevelId`s; the three sets are `SetId`s; `StageConfig.Order` is
  the list above. Every table in the game (cards, credits, lives, radar, batteries, flasks, objectives, voice odds) is
  keyed by stage id. `ObjectiveConfig.floor` stays a dense 0..5 over the six levels.

### 0.2 What is new since spec v1
- **A second half:** the janitor twist, the parachute as the roof-to-city hand-over, `City1_Rooftops`,
  `City2_Airport`, the playable takeoff, the Bahamas cutscene (§2.5, §2.7, §4.6 to §4.9).
- **A shorter school:** Basement, Hallways, Auditorium. The Auditorium moves down to the old science storey; the roof
  comes down with it (§4.2).
- **Radar** replaces the Tab hint (§3.2). **Lives:** one get-up per stage, one respawn per stage [one per run on
  Nightmare], the syringe adds one for the run (§3.3).
- **The gray look** on every stage; no checkerboard floors; the Bahamas is the one bright scene (§5).
- **A leaner build:** the theatre is flat (no Tiers, catwalks, rake or trap room); parkour is jump, slide and one
  sampled leap; the roof chaser follows one rule with a simulated table; cutscene actors use the avatar renderer.

### 0.3 What is removed, and what waits as P1
- **Removed on both platforms (§6):** the Science Hall, the Gym, the pool, the bolt cutters and crate search, the Tab
  hint, the maze roof, the old escape finale.
- **Cut from spec v1 for good:** Tiers (stacked heights in a room), the changeover lever, the booth alert, the seat
  speed zone, the noise-refresh rule, the clock-face climb, dual lanes, the lightning warp, the radio mast, revolver
  sway in the hit test, the Inner voice channel, Kokoro TTS.
- **P1, in the order to build if budget remains:**
  1. notes, the Journal and the Memories menu (v1's 29 notes);
  2. the dread layer: presence dimming, score stems, StareBuild, tinnitus;
  3. presence AI: Peek, Shadow, Glimpse, vantage holds, habit memory;
  4. theatre extras: the changeover, the silhouette card on the film, mannequins, the Drape hiding kind, claps and bow;
  5. flourishes: vault and mantle animations, the collapsing catwalk, pigeons as a tell, a cockpit mirror, a flask
     thrown from the plane, the key sting after the credits;
  6. voice extras: lures in Danny's clean voice, Memory and Isolated lines, the PA scare, speaking extras (Kayla,
     Marcus, Mr. Kessler), facial expressions.

### 0.4 Budget
**Website:** 16 work packages (6 World, 9 Web, 1 Tests), §7.1. **Roblox port:** 8 packages, §7.2. The game is playable
end to end, through stub stages, after the first two packages; each later package replaces one stub.

---

## 1. Invariants (a test asserts each one; §8)

| # | Rule |
|---|---|
| **I1 Honest monster audio** | Footfalls, breath, rattle, key jingle, sniff and voice play only at the real monster, at its planned teleport spot (the warning), or on the true line from the listener toward it (the Ear whisper). The Device channel (a phone) is band-passed and labelled. No set piece imitates any of these |
| **I2 Teleport tell** | Every teleport is preceded by the trio: lights stutter, TeleportHiss, the target's torch stutters. TeleportHiss is used by nothing else. The torch stutter is otherwise used only by the reveal or fake-out phantom and the catch |
| **I3 Cosmetic is cosmetic** | Set pieces, the film, the curtain, scripted light groups, the radar, the keys and every cutscene never change collision, nav, the baked light probes, noise pulses or the brain's inputs. No scare ever emits a NoiseKind |
| **I4 Chase fairness** | A clean run of the Last Run and of Wheels Up always escapes, on both difficulties, at 20, 60 and 144 fps, on every tier. Outside those two scripted chases the monster's horizontal speed never exceeds 18.5. In the Last Run it never exceeds 21.3 [21.9], and only while it is more than τ\* behind. A fall never damages. There is never a blind jump |
| **I5 Standoff fairness** | The fire window is 13.5 s [10.0]. A blocked, late or rejected shot never uses the round. The hit test never reads the tier, the frame rate or a render |
| **I6 One source of numbers** | Every new number lives in a shared Luau config and reaches the web through `world.json` meta. Where the web keeps a mirror (`engine/config.js`), `data-test` compares every key |
| **I7 Authority** | The Roblox server or the web host owns item picks, the chaser, catches, voice selection, scares, skip votes, the gun, endings, respawns and takeoff validation. Clients render and send intents |
| **I8 Tick-quantised motion** | The player's body, the slide, the leap, the roof chaser, cutscene actors and the plane advance on the fixed 30 Hz tick, or are pure functions of `t − startAt` with the start quantised to a tick. Results are identical at 20, 30, 60 and 144 fps |
| **I9 Parkour envelope** | Required hurdles are 2.4 to 2.8 high; unclimbable walls at least 5.5; slide bars leave 4.2 with solid above; leap gaps are exactly 12, which no free jump crosses on either platform; no free jump over a gap is ever required |
| **I10 Graphics tiers are visual only** | A graphics tier never changes collision, queries, nav or information. Guidance (beacons, chevrons, leap strips and pads, runway lights, radar markers, battery LEDs, the clock faces, the airport beacon) is unlit emissive geometry, never fogged, never `Detail`, the same on every tier. No designed tell depends on shadows or particles |
| **I11 Pure rules twice** | `LivesRules`, `RadarRules`, `ParkourRules`, `ChaseRules`, `EndingRules`, `TakeoffRules`, `VoiceRules`, `ScareRules`, `NameSanitizer`, `CinematicTracks` and `FilmSpec` timing are written in Luau under `Shared/`, ported to JS, and both pass the same golden JSON written by the export. The four directors (chase, takeoff, voice, scare) also pass scenario replays: one input trace, identical event logs |
| **I12 Content limits** | The massacre is implied, never shown. One old revolver, one bullet, used only on the monster. No blood. The shot and both deaths are not gory. Ending B cuts to black before impact |
| **I13 Safe moments** | Nobody can be caught, downed or killed during a cutscene, the prologue, the aftermath (from the shot to the first touchdown), a respawn's grace, or while seated in the plane before the engines start |
| **I14 Fair objectives** | On the five sneaking stages a hiding spot stands within 25 studs walked of every objective step. Every stage can be finished without a single radar scan |
| **I15 Radar** | A scan never shows the monster and is never an AI noise. On Standard a player reaches every sneaking stage with at least one charge |
| **I16 Stage ids** | No code indexes a table by a level's number. `Removal.spec` and `data-test` fail on any leftover removed id |

---

## 2. Story and cutscenes

### 2.1 The spine
**Rovloc High, 1989.**
- The drama club staged *The Masque* with an old porcelain mask from the prop room. On opening night it took the lead,
  **Michael Hale**. He became the Tall Man. The school locked down; people died (implied).
- The night watchman, his older brother **Walter Hale**, cornered it on the **bell tower** with a revolver and could
  not shoot. At dawn it was gone.
- Three weeks on, Walter found the mask in a steam tunnel, cold and still. He crated it ("MASQUE — DO NOT REMOVE —
  W.H."), filmed a warning, wired the scene-dock door to the projector, and left one bullet and his old jump kit on
  the tower. He retired in 2019 and died in 2025.

**Tonight, a Friday in November.**
- Facilities clears the prop room; the crate goes to the dumpsters behind the school.
- At 3:14 PM **Danny Reyes**, the players' friend, lifts out a pretty, broken mask. It is the parasite. It latches
  onto his face, and the Tall Man stands where Danny was.
- The party hides in the bins until midnight. The lockdown drops steel shutters on every door and window.
- **Gus Pruitt**, the night janitor, sleeps through all of it in his closet with his hearing aid out (§4.3).

**Why you climb.** The yard is chained and the school is shuttered. The bell tower is the one place the shutters never
covered. Each floor's objective breaks one seal: power (Basement), Gus's master keys (Hallways), Walter's hidden dock
door (Auditorium).

**The rule that makes the twist fair: the mask rides one host at a time.** It has Danny, so it walks past Gus all
night. It keeps every host's memories and speaks in its current host's voice: on Gus it still knows your names.

**Why the city.** The tower's fire escape rotted years ago; Walter's jump kit is the way down, and the storm carries
the canopies across the street onto the rooftops. The city is blacked out and evacuated. The one thing still
working is the airport: its beacon sweeps the cloud.

**Endings.** **B, "The Fall":** you hesitate as Walter did. **"Sunrise":** you do what Walter could not, lose Danny,
and get out.

### 2.2 Cast

| Who | Look | Voice (web pitch / rate; Roblox Pitch / Speed) | Drawn by |
|---|---|---|---|
| **Danny Reyes**, 16 | grey hoodie, **red beanie**, white sneakers, backpack. Catchphrase: "Wait up, you guys!" | clean: 1.15 / 1.05; 1.0 / 1.05 | the avatar renderer with a costume from `CastConfig` |
| **The Tall Man (Danny)** | MONSTER-LOOK.md, unchanged | Danny's voice at 0.4 / 0.82; 0.6 effective / 0.85 | the Creature rig |
| **Gus Pruitt**, 58, night janitor | grey jumpsuit with a "GUS" patch, work boots, a ring of keys on his belt, a hearing aid, a torch | clean: 0.7 / 0.9; 0.8 / 0.9 | the avatar renderer with a costume |
| **The Tall Janitor (Gus)** | §4.7 | Gus's voice at 0.25 / 0.78; 0.5 effective / 0.8 | the Creature rig, host `Gus` |
| **The party** P1..P4 | the real players. Web: the co-op avatars in slot colours, the local player included. Roblox: clones of the real avatars | none (players do not speak) | avatars |
| **The mask crawler** | the Tall Man's mask at 0.45 scale (about 0.6 tall) on eight pale two-segment finger-legs, 0.9 long | clicking, a music-box tick | web `mask.js` scaled plus legs; Roblox parts. Numbers in `CastConfig` |
| **Walter Hale** | seen only as film cards and white paint | none | text |

Actors have no facial animation (P1). Clips (the avatar animator's): Idle, Walk, Run, Crouch, Kneel, Lie, Stagger,
HandsToFace, Sit, Point.

### 2.3 How cutscenes work (one contract for all five)
- **Data.** `Shared/Config/StoryConfig.luau` holds every timeline: camera keys `{t, eye, target, fov, ease}` (ease is
  `cut`, `linear` or `smooth`), actor tracks `{actor, keys {t, pos, yaw}, clips {t0, name}}` (positions interpolate as
  centripetal Catmull-Rom), and events `{t, kind, args}` for voice, sound, prop, light, fade, card and rig swap.
  Positions are relative to a set's `CutsceneMark` anchors. It exports as `meta.story`.
- **Sampling.** `Shared/Sequence/CinematicTracks.sample(timeline, t)` is pure (I11). A timeline starts at an authority
  `startAt` quantised to a tick; late pages fast-forward; letterbox bars are 12 %.
- **Lines.** Every spoken line has a start time and a slot (its longest allowed duration) and at most 12 words.
  Subtitles follow the data. The web cancels an utterance at its slot's end; Roblox raises Speed within its range
  until `TimeLength` fits. `story-test` asserts words ÷ (2.6 × the voice's rate) ≤ slot and that no two lines
  overlap. Authored timelines are exempt from the voice gap rules (§3.4).
- **Name slots.** `{P1}`..`{P4}` are the players in a seeded order (`StoryCast|runSeed`); `{you}` is each page's own
  player; `{shooter}` fired the shot. Every line with a slot has a nameless twin, used when a name is empty, filtered
  or "The monster says names" is Off. Solo: lines that need P2 or more are skipped.
- **Control.** A `Cutscene` lock holds every player from the timeline's start (own point of view unless a shot says
  cinematic). I13 holds throughout.
- **Skip vote.** Hold Skip 1.0 s: Enter, gamepad Start, or the SKIP button (never Space or B). It passes when more
  than half the players have voted and every player who has not seen this cutscene has voted. Solo: at once. Offered
  from 5 s in. A pass cuts everyone to the timeline's last shot with a 0.6 s fade.
- **Full or Short.** The opening and the twist have a Short cut. Short plays when every member has seen the Full one
  and none has set "Cutscenes on replays: Full".
- **Leaving and joining.** A leaver's actor stays until the next cut, then is hidden. A joiner sees the timeline from
  its current time.
- **Flash and motion.** `FlashScale` scales every lightning flash and strobe; `MotionScale` scales shake and
  cinematic point-of-view moves.

### 2.4 The opening (Full 78.0 s; Short 26.0 s) on the Back Lot (§4.1)
Match phases: `Deploying` (the squad is placed at the bin marks; the composed lines are preloaded) →
`Prologue` {opening → bin → walk → chute} → `InRun` at Basement activation.

| Shot | t | Picture | Sound and lines (start, slot) |
|---|---|---|---|
| S1 | 0.0–4.0 | Crane down from the bell-tower clock (3:12) over the roof to the lot. Overcast grey. Card: "ROVLOC HIGH · FRIDAY · 3:12 PM" | the final bell |
| S2 | 4.0–9.0 | The staff doors bang open. The party walks out; Danny walks backwards in front of them | DANNY (4.6, 4.0): "Did you SEE Kessler's face when the frog got loose?" |
| S3 | 9.0–14.5 | Two-shot, Danny and P1 | DANNY (9.3, 3.4): "{P1}, back me up. Funniest thing ever." · (12.9, 1.6): "Worth the detention." |
| S4 | 14.5–19.5 | Past the dumpsters, toward the gate | DANNY (14.8, 3.2): "Sal's? Last one there buys the pizza." · with 2+ players (18.0, 1.5): "{P2}, you're paying." |
| S5 | 19.5–23.0 | Close on Dumpster A: the lid ajar, DISCARD boxes, the torn crate, a pale shape | faint clicking · DANNY, off (21.0, 1.6): "Wait. Guys. Wait up." |
| S6 | 23.0–28.5 | Danny lifts out a hand-sized porcelain face, cracked and pretty, and holds it up to his own | DANNY (23.6, 2.6): "Ha! Look at this thing." · (26.4, 1.8): "Booo. I'm the Phantom." |
| S7 | 28.5–31.5 | Insert only the audience sees: eight pale finger-legs unfold from the rim | one music-box tick |
| S8 | 31.5–34.0 | **The latch.** It springs onto his face in 0.25 s; the legs wrap his head; he staggers into the dumpster | a crack · DANNY, muffled (32.0, 2.0): "Get it— GET IT OFF!" |
| S9 | 34.0–39.0 | Wide: the party recoils. The yard lamp flickers. His sneakers lift off the ground and fall, empty. At 38.6 the lamp dies for 0.4 s: the Danny actor is swapped for the Creature rig, folded | cracking, a wet breath (no gore) |
| S10 | 39.0–43.0 | Low angle: the Tall Man unfolds to 11 studs where Danny stood (the FadeIn pose, slowed 3.25×). Its head cocks | 0.8 s of silence, then the Screech |
| S11 | 43.0–47.5 | The party runs. Each avatar dives into its slot's bin. Lids slam | lids, breathing |
| S12 | 47.5–58.0 | **Inside a bin**, one shared shot through the lid gap. 47.5–51 its legs pass. 52 it stops. 52–54 fingertips drag along the lid. 54–57 the mask lowers into the gap, inches away, head cocked. 57.2 its head snaps toward the school | nails on metal · whisper, Ear, each page its own name (54.5, 2.5): "I know you're close, {you}." · 57.0 a scream inside the school |
| S13 | 58.0–65.0 | Through the gap: it ducks through the staff doors. The windows go dark floor by floor. Lockdown shutters crash down | fire bell, glass, brief distant screams · PA: "LOCKDOWN. LOCKDOWN." |
| S14 | 65.0–73.0 | Time-lapse through the gap: grey, orange, deep blue (`dayAmount` 0.65 → 0). Clock cards: 3:14 PM, 5:47, 9:03, 11:52. Rain from 70 | rain on the lid |
| S15 | 73.0–78.0 | Black. The bell tolls twelve. Fade into first person inside your bin. Prompt: "Push the lid" | whisper, Ear (74.5, 1.5): "{you}…" |

**Short cut:** S1 (0–3), S6 from "Booo." (3–6.5), S8 (6.5–9), S9 and S10 (9–15.5), S11 (15.5–18.5), S13 from the
windows (18.5–22.5), S15 (22.5–26).

The Creature in S9 to S13 is Scripted and uses only existing actions (FadeIn, Stare, ReachIn for the fingertips).

### 2.5 Ending A, "One Bullet", and the twist (from the shot, T; staging in §4.6)

| Shot | t from T | Picture | Sound and lines |
|---|---|---|---|
| A1 | 0.0–1.6 | A muzzle flash on a lightning strike. A white crack races across the mask (`raceCracks`). It staggers back two steps (the Stunned pose); its smoke pours upward | a dry crack the rain swallows; the bell hums; its scream thins to a human breath |
| A2 | 1.6–4.0 | It sinks down (the Dormant pose). At 2.4 the mask drops off whole and breaks in two on the deck (the `MaskHalves` prop) | porcelain clatter at 2.9 |
| A3 | 4.0–7.0 | Cinematic camera. The body dissolves (the FadeOut dissolve); Danny lies there in his grey hoodie and red beanie, pale, whole, eyes half open | rain |
| A4 | 7.0–20.0 | The party kneels round him, the shooter nearest | DANNY, clean, weak, rate 0.85 (7.5, 2.4): "{shooter}…? Hey." · (10.2, 2.8): "I didn't mean any of it." · (13.3, 3.8): "Tell my mom I'm sorry I was late." · (17.4, 2.0): "…wait up, you guys." His eyes close at 19.5 |
| A5 | 20.0–23.0 | The shooter takes the red beanie. The rain thins. It feels over | the bell's last hum |
| J1 | 23.0–26.0 | Behind them the bolted hatch rattles. A key scrapes; the bolt slides | the first clear key jingle |
| J2 | 26.0–32.0 | The hatch lifts: a torch beam, then Gus in his grey jumpsuit, fitting his hearing aid | GUS (26.6, 2.6): "Who's ringing my bell at midnight?" · (29.3, 2.6): "You kids can't be up here." |
| J3 | 32.0–36.0 | He sees Danny. He kneels and sets the torch down; its beam lies across the two halves of the mask | GUS (32.3, 3.2): "Is that the Reyes boy? Oh no." |
| J4 | 36.0–39.5 | A half twitches. Finger-legs unfold from both. They drag together and click into one face with a black seam | clicking; the music-box tick |
| J5 | 39.5–42.0 | It skitters up his sleeve and springs onto his face (0.25 s). The legs wrap his head | GUS, muffled (40.0, 2.0): "Get it— GET IT OFF—" |
| J6 | 42.0–44.0 | He staggers back toward the east parapet. The torch rolls, strobing the party. Cut to first person | thunder |

- **C = T + 44.0** (control returns; §4.6). **Short twist** (8.0 s, replaces J1 to J6): J2 (2.0), J4 (2.5), J5 (2.5),
  J6 (1.0); then C = T + 31.0.
- Marks follow the placement rule in §4.6. Downed players are stood up at T and take their kneel marks.

### 2.6 Ending B, "The Fall" (20.0 s; skippable once every member has seen it)

| t | The victim (the gun's holder, else the nearest player) | Everyone else |
|---|---|---|
| 0.0–1.6 | The catch (the Jumpscare action and camera, to its static cut). An unfired revolver clatters to the deck | watch live |
| 1.6–2.0 | black | — |
| 2.0–6.0 | Point of view held out over the west parapet: the street 78 studs below, rain falling into the dark, its long fingers round the lens (the ReachIn pose). Both voices at once (2.4, 3.4): "You were always my best friend, {you}." | watch |
| 6.0–8.5 | It lets go. The camera falls 40 studs over 2.5 s (ease-in), watching its silhouette on the ledge against the lightning and the clock | — |
| 8.5 | **Cut to black before any impact.** 1.5 s of silence | cut to black |
| 10.0–16.0 | Co-op: the bell tolls once; "Your turn."; black. Solo: a whisper, "{you}…", and a bin lid creaking shut | — |
| 16.0–20.0 | Card: "THE FALL" | — |

Everyone is Taken. Ending B is an ending, not a death: no respawn undoes it.

### 2.7 "Sunrise" (44.0 s), the one bright scene; set and looks in §5

| Shot | t | Picture | Sound and lines |
|---|---|---|---|
| H1 | 0–4 | Outside, low: the wheels leave the runway. He leaps; his fingers rake the gear leg; he drops away into the rain | engines; his scream thinning |
| H2 | 4–9 | Cloud, lightning below, then out on top: stars and a moonlit cloud deck. The cabin: the squad in their seats, shaking | the storm cuts to an engine drone |
| H3 | 9–15 | The red beanie on the dash. Time-lapse: the stars wheel; the horizon goes violet, pink, gold (`dayAmount` 0 → 1). Dash clock 12:52 → 6:10 | the game's first major chord |
| H4 | 15–22 | Turquoise shallows, sandbars, the plane's shadow on the water. Card: "THE BAHAMAS · 6:41 AM" | gulls |
| H5 | 22–29 | A sunlit island strip beside a beach. A bouncy landing. The props wind down | tyres chirp |
| H6 | 29–38 | The squad (P1..P4 by slot) steps out squinting, walks onto the sand and sits. The shooter hangs the red beanie on a driftwood post facing the sea | surf · with 2+ players, subtitle only, P2 (33.0): "…Sal's is gonna be closed, huh." |
| H7 | 38–44 | Wide and rising: beach, plane, small figures, the sun. "ROVLOC", then "SUNRISE" | the chord resolves |

P1: H8, three seconds in the wheel well's shadow: a ring of keys swinging on the gear leg; one jingle.

### 2.8 Lore in the world (P0: fixed text only; the note reader is P1)
- **Graffiti** uses the planner's existing `Lore` landmark slots (text changes only, never `Detail`). 1989 lines are
  faded paint; tonight's are fresh marker.

| Stage | Lines |
|---|---|
| Basement | "HE HEARS YOU RUN" (1989) · "CRAWL →" (1989) · "3 FUSES" (tonight) · "IT CAME OUT OF THE BINS" (tonight) |
| Hallways | "DON'T LOOK AT HIS FACE" (1989) · "IT KNOWS NAMES" · "NOT DANNY" (tonight) · "WHEN IT LOOKS AWAY — GO" (tonight) |
| Auditorium | "THE SHOW MUST GO ON" (1989) · "WATCH IT TO THE END" (1989, at the booth) · "THE FLATS ARE FAKE" (Scenery Store) |
| Roof | Walter's white paint: "UP" · "→" · inside the tower: "LADDER'S GONE. USE THE KIT. — W.H." · on the lockbox: "ONE. I COULDN'T." |
| Rooftops | "AIRPORT →" in evacuation stencil · "LIGHTS OUT 9 PM — CITY ORDER" · "SKYBRIDGE TO TERMINAL ←" on the W roof |
| Airport | "LAST FLIGHT LEFT 8:40" on the split-flap board · "N714RV — FUEL THEN FLY" on the hangar whiteboard |

- **Walter's film** (§4.4) carries the 1989 story, the dock door and the bullet as silent-film cards; **Gus's
  signs** (§4.3) carry the janitor.

---

## 3. Systems

### 3.1 Player physics on the fixed tick, and parkour

**The fix (game-wide, before any parkour).** Today the web moves the body once per rendered frame
(`player.frame` → `body.step(dt)`), so a sprint jump goes 6.2 studs at 144 fps and 9.5 at 10 fps.
- The body now steps inside the 30 Hz tick, in 2 substeps of 1/60 s: velocity smoothing, gravity, collide-and-slide and
  the floor probe all use the substep.
- Jump, crouch, slide and leap presses are latched and consumed at the next tick. The wish direction is read from the
  yaw at the tick.
- The renderer draws the body interpolated between its last two tick states (`loop.alpha`). Look stays per frame.
- Every motion override (vent rail, parachute, leap) advances on the tick too.
- Roblox already simulates on a fixed step; the port measures its Humanoid (RP02) and writes
  `ParkourConfig.RobloxEnvelope`.

**The moves** (`Shared/Config/ParkourConfig.luau`; pure curves in `Shared/Rules/ParkourRules.luau`).

| Move | Geometry | How | Cost of getting it wrong | Monster |
|---|---|---|---|---|
| **Hurdle** (free jump) | top 2.4–2.8 over the lane, ≤ 3 deep, lane-wide. Too high to step over (the web's legs climb about 1.9, Roblox about 2.0), well inside a jump (the web mounts 4.4, Roblox about 4.5; measured by `parkour-test`) | Jump (apex 2.5) | you stop against it and jump again: about 0.5 s | smashes it aside behind the runners (cosmetic) |
| **Slide** (new MoveState `Sliding`) | bar with 4.2 clear under it and solid from 4.2 to at least 9.7, ≤ 6 deep | Crouch while sprinting at ≥ 15 on the ground (the press is consumed: it does not toggle crouch): 0.70 s, speed 17 falling to 13 (10.5 studs), body 3.7 high, eye −1.5, steering ≤ 30°/s, no jump. It ends standing if there is headroom, else crouched | no slide: crouch-walk under at 5.5, about 0.8 s lost | smashes the bar |
| **Leap** (the one sampled move) | gap exactly 12 edge to edge, landing level or ≤ 2 lower; a 4-stud take-off strip with hazard paint and chevrons; a lit pad ≥ 8 deep | below | not sprinting, misaligned or no press: you run off the edge and fall | cannot follow (city); crosses on its rail (roof) |
| **Plank** (free walking; city only) | 3.0 wide, 0.5 thick, 12 long | walk, crouch or sprint across | step off the side: you fall | cannot |
| **Fire-escape stair** | 4 wide, risers ≤ 1.0, treads ≥ 1.25, 3.5 rails | walk | — | cannot (no floor for it) |
| **Drop** | any height | walk off | a fall of ≥ 8 is a **hard landing**: 0.6 s at 40 % speed, a camera dip, noise `HardLanding`. **Never damage** | — |

**The leap, exactly.**
- **Request.** Inside the approach band (the 8 studs before the strip's end) a Jump press never starts a free jump: it
  is held as a leap request for 0.3 s. A press up to 0.10 s after running off the edge also counts.
- **Start.** At the first tick the root is inside the strip (or past the edge within the 0.10 s) with a live request,
  horizontal speed ≥ 15 and heading within 35° of the leap direction.
- **Motion.** `ParkourRules.leap(t)`: 0.60 s; a straight line along the leap direction from the take-off point to 2.0
  past the far edge, the side offset kept; height a parabola with apex +2.0; no collision and no input during it; exit
  speed 17 along the leap direction, then normal physics.
- **Leap assist** (setting; default On for touch and gamepad, Off for keyboard): the request is made for you at the
  strip when the speed and heading tests pass. The same curve runs.
- **Never blind.** From the eye of a sprinting player (feet + 4.4), 20 studs before the strip, 5 rays to the pad are
  clear (`data-test`), also at `FlashScale` 0.
- **Roblox.** The client samples the curve in `PreSimulation` with the character in the `Traversing` collision group
  (collides with nothing). The server checks strip, observed speed ≥ 11 and facing within 60°, exempts
  `MovementAuthority` for 0.9 s, and never corrects mid-arc. Leaps are allowed in `InRun` on any level.

**Envelope constants** (asserted on both platforms, I9): required hurdles ≤ 2.8; walls ≥ 5.5; the longest free jump
either body makes is under 10 studs (8.2 on the level and 8.6 onto a landing 2 lower on the web; `parkour-test` records it, RP02 measures Roblox); leap
gaps and every street or alley are ≥ 12.

| Action | Keyboard | Gamepad | Touch |
|---|---|---|---|
| Jump, leap | Space | A | JUMP |
| Crouch, slide | C (never Ctrl on the web) | B | CROUCH |
| Look back (hold; on foot only): a 150° turn of the view in 0.18 s; movement keeps its heading | V | R3 | LOOK BACK |
| Radar | Tab | D-pad right | RADAR |

Noise: a slide is `Slide` (High 60) once; a leap or hurdle landing is JumpLand (26); `HardLanding` is High 60.
First-time hints: Hurdle, Slide (the roof pen, §4.5), Leap (the first strip), Radar, GetUp.

### 3.2 Radar (replaces the Tab hint; `RadarConfig`, `RadarRules`)

| | Standard | Nightmare |
|---|---|---|
| Charges held / at run start | 3 / 1 | 3 / 1 |
| A scan lasts | 8 s | 6 s |
| Battery candidates per sneaking stage (today 10–12) | 36 | 36 |
| Batteries placed per sneaking stage (today 2 [1]) | 6, +1 per extra player (max 9) | 4, +1 per extra player (max 7) |
| Arrival floor: reach a sneaking stage with 0 charges and get 1 | every stage | Basement and Rooftops only |
| **Guaranteed scans in a run with no battery ever found** | **5** | 2 |

- **Input.** Tab, D-pad right or RADAR. One charge, a 0.4 s raise, then the scan. Refused (no cost) while Hiding,
  Downed, seated, in a cutscene, on the roof or the runway, or while a squad scan is live.
- **A battery** gives +1 charge and +45 torch, as today's pickup. With both full the prompt reads "Full" and the
  battery stays. Every battery blinks a cold-white LED (0.2 s every 2 s, emissive, never `Detail`).
- **What a scan shows**, at exact positions, through walls, anywhere on the stage:
  - every item still needed for the open step ("FUSE 2/3"), and any dropped objective item;
  - the station or stations of the open step (the breaker panel, a projector, each open feeder, the wing, the cabin);
  - the exit, once it is unlocked;
  - batteries within 50 studs, as small dots.
- **Markers.** A diamond with an icon, a name and the straight distance in metres (0.28 m per stud, as today), plus a
  chevron round the crosshair toward the nearest one. It reuses today's pointer and marker code in `ui/objectives.js`.
- **Never the monster, never teammates** (I15).
- **With no charge**, Tab opens the objective sheet with a dry click and the line "Radar empty. Batteries blink."
  There is no pointer. `NudgeDelay`, `NudgeCooldown` and the room nudge are deleted.
- **Noise.** A soft ping plays in 3D for players within 30 studs. It is not a NoiseKind: the monster never hears it.
- **Placement** (RunDirector's `Batteries|<stage>` stream; checked on 16 golden seeds per stage): one battery 20–60
  walked from the entry, one within 40 of the objective's main station, every pair ≥ 30 apart, none in a dead end.
- **HUD.** Three pips beside the battery bar. During a scan a cold-green ring drains round the crosshair. Green lives
  only here and on the airport beacon.
- **Co-op.** Charges and batteries are personal (first come, as today). A scan is a squad event (`Radar {by, startAt,
  seconds}`): every page on the stage shows it, each with its own chevron.

### 3.3 Lives (`LivesConfig`, `LivesRules`)

| Rule | Standard | Nightmare |
|---|---|---|
| First lethal hit on a stage (a catch, or damage that empties health) | **Downed**: crawl 2.5, bleed-out 35 s | the same |
| **Get up** (alone, once per stage) | from 3 s after going down, hold Interact 4 s: up at 50 health | hold 6 s: 35 health |
| A teammate's revive (4 s, 50 health, as today) | at any time instead | the same |
| The next lethal hit on that stage, a catch while Downed, or the bleed-out ending | **Killed** | Killed |
| **Respawns**, per player (the player's words: "each floor ... if you get hard killed, you get 1 respawn") | **1 on every stage**, +1 per run with the Adrenaline Syringe | 1 per run, +1 per run with the syringe |
| Free attempts at each scripted chase (the Last Run, Wheels Up), per squad | 3 | 2 |

- **Per stage.** `downsThisStage` resets at each stage's activation. MONSTER.md §9 changes one phrase: Downed "for a
  victim not yet downed on this stage".
- **The stage respawn (Standard).** At the activation of each of the seven playable stages (Basement, Hallways,
  Auditorium, Roof, Rooftops, Airport, Runway) every player's stage respawn is set back to 1. It is never banked: an
  unused one does not carry over. On Nightmare there is no stage respawn: one respawn for the whole run
  (`LivesConfig.RespawnsPerStage` 1 [0], `RespawnsPerRun` 0 [1], `SyringeRespawns` 1 [1]). "Respawns left" below
  always means stage + run + syringe, spent in that order.
- **What the monster does meanwhile.** A catch already puts the pacing in Relax for at least 25 [15] s (catch
  cooldown 14.4 [8.8] s): it may not chase, catch, stare or teleport, and it withdraws 35–140 studs away. Getting up
  takes 7 [9] s from the catch, so it always fits. A down from a bear trap has no such truce.
- **The respawn.** 4 s of black ("NOT YET."), then your slot's spawn at the current stage's entry, at 50 [35] health.
  - *The monster is moved away.* If it is within 70 studs walked of that entry it warps, unwarned and unseen, to the
    nearest land spot ≥ 70 walked from the entry and ≥ 45 from every player. Its next teleport is ≥ 45 s off.
  - *Grace.* You are `ignored` (not seen, heard or caught) for 10 [6] s.
  - *Kept.* Radar charges (at least 1), the torch (at least 50 %), flasks, the squad's objective progress. A carried
    objective item lies where you fell and is pinned on every HUD for 10 s.
  - *A respawn gives the stage's get-up back.*
- **The syringe** becomes passive: one extra respawn, spent last. Its button, its stamina use and the `Syringe` input
  action are removed. Shop text: "One more chance."
- **Scripted chases** never spend a Down or a personal respawn. A failed attempt beyond the free ones spends one
  respawn from the squad: the member with the most left, lowest slot first. With none left the run ends.
- **Out of respawns** in co-op: you spectate, and stand up at 50 health at the next stage's entry when the squad
  gets there (today's checkpoint rule; the roof pen, the landing roof and the plane count as entries). Solo: "THE
  NIGHT TOOK YOU". The run ends when nobody is Alive or Downed and nobody has a respawn left.
- **HUD.** Beside the health bar: a heart pip per respawn (the syringe's is a syringe glyph) and a get-up chevron
  that greys out once used on this stage. Downed screen: the ring, "HOLD [E] TO GET UP" from 3 s, teammates' status.

### 3.4 The talking monster (`VoiceConfig`, `VoiceRules`; the authority runs `VoiceDirector`)

**Principles.** Honest (I1): a voice on Head, Spot or Ear means it is really there, in that direction. Rare: about
one line per 45 s outside chases. Earned: the run's first unscripted line waits for its first teleport warning or
chase. Escalating: it says your name with probability 0.3 (Basement), 0.5 (Hallways), 0.7 (Auditorium), 0.9 (roof
and city). In the city the voice is Gus's and the lines are a janitor's, but it still knows your names.

| Category | Trigger | Anchor · listener · whose `{name}` | Chance · cooldown | Lines (host Danny) | Added for host Gus |
|---|---|---|---|---|---|
| **Calling** | Patrol; nobody seen for 20 s; nearest player 20–70 walked; rolled every 15 s; never in Relax | Head · all in range · the nearest Alive player | 0.35 · 45 s | "{name}… where'd you go?" · "Come out, {name}. It's just me." · "Olly olly oxen free…" · "Guys?… Guys?" | "Who took my keys, {name}?" · "No running on my roof." · a five-note whistle |
| **Heard** | entering InvestigateNoise | Head · all · the noise's source if a player | 0.35 · 20 s | "I heard that." · "{name}? Was that you?" · "Running in the halls, {name}?" | — |
| **Behind** | Patrol, Teleport stalk or Search; a player 8–26 from its eye, its bearing more than 110° off their view, a clear line or one wall, unseen by them for 6 s | **Ear** · that player · them | 0.5 · 40 s per player | "Don't turn around, {name}." · "I'm right behind you." · "I can hear your heart, {name}." | "Wet floor, {name}." |
| **Sniff** | a breath check's warning (0.9 s in) | Ear · the hider · them | 0.4 · 15 s | "I can hear you breathing." · "Knock knock." · "Are you in here, {name}?" | — |
| **Saw you hide** | arriving in HidingResponse | Head · the hider · them | 1.0 · per watch | "I saw you, {name}." · "Peekaboo." | "I've got a key for every door." |
| **LookAway** | each LookAway start, after the grunt | Head · all | 1.0 · 3 per watch | "I'm not looking…" · "Go on. I won't look." | — |
| **Ready** | exactly 3.0 s before the timed HidingResponse ReachIn (§3.6); never the breath-check ReachIn | Head · all | always | "Ready or not…" · "Here I come." | — |
| **Chase** | WallChase entry + 0.8 s (0.8); then every 5–8 s while the target is ≥ 8 ahead, at most 2 a chase (0.7) | Head · all · the target | 5 s | "THERE you are!" · "Found you, {name}!" · "Wait up! WAIT UP!" · "Why are you running?!" | "Lights out, kids!" · "Don't leave me again, {name}!" |
| **Teleport** | the warning's start, when the spot is Behind | **Spot** · the target · them | 0.6 · per teleport | "Behind you." · "Boo." · "{name}." | — |
| **Stunned** | a flask stun | Head · all · the thrower | 1.0 · 30 s | "AGH! That HURTS, {name}!" | — |
| **Scripted** | cutscenes, the standoff, the aftermath, set pieces | per scene | — | §2, §4 | §2, §4 |

**Rules** (pure; a 30-minute soak asserts each)
- One line at a time per listener; ≥ 8 s between lines a listener hears (≥ 3 s for Ready, Chase and Stunned);
  ≤ 4 per rolling 60 s. Scripted lines are exempt.
- Each category is a no-repeat bag per listener, seeded `Voice|runSeed|category`. The named form is picked with the
  stage's probability from `Rng.seeded(runSeed, "VoiceName|" .. n)`; the same name is not said to a listener twice
  within 45 s.
- Silence: none within 1.5 s of a stinger, reveal or catch; none in cutscenes (scripted only); none in a stage's first
  25 s; Calling never in Relax or during a chase.
- Lead: Calling and Behind are chosen ≥ 1.0 s ahead and re-checked at play time; the other categories have 0.3 s. A
  line not ready by its start plays only if ≤ 0.6 s late; otherwise the subtitle and the throat layer play alone.
- The mean rate outside chases is between one per 35 s and one per 60 s per listener on a reference trace.
- The voice is never a noise the AI hears and never changes the brain's state.

**Where it comes from**

| Channel | Where | Level |
|---|---|---|
| **Head** | its eye + 0.3, tracking the replicated head every frame | `gain(d, walls) = min(1, 8/d) × 0.5^walls`, fading linearly to 0 from 60 to 90 studs; a low-pass per wall at 2,400 / 1,100 / 600 Hz (walls counted as hearing counts them, at 5 Hz) |
| **Spot** | the planned teleport spot + 4, where the hiss plays | 0.8 |
| **Ear** | a dry copy 2.5 studs from the listener's head along the true direction to its head, tracking both | 0.8 |
| **Device** | the phone's speaker (§3.5); band-pass 400–3,000 Hz; labelled PHONE | 0.7 |

**Names.** One shared pure `NameSanitizer`: the first token after splitting CamelCase, underscores and digits;
letters, ' and - only; 2–12 characters; checked against a built-in blocklist with leetspeak normalised; otherwise the
nameless twin.
- Web: the title screen asks once, "What do your friends call you?" (saved, editable in Settings). The host
  re-sanitises every name in a join packet and composes each line per recipient.
- Roblox: the `DisplayName` through the same sanitizer, then `TextService` filtering (broadcast for Head, per user for
  whispers); a "#" or an empty result uses the twin.
- Voices: the web scores its voices per role (+3 local, +1 English, +2 a name hint: Danny young male, Gus older
  male); with a single voice, §2.2's pitch and rate tell the roles apart. A `VoiceConfig` validator keeps every
  Roblox Pitch and Speed inside the documented range.

**What each platform plays** (same line, timing, anchor and subtitle on both)

| Layer | Web | Roblox |
|---|---|---|
| Words | one `SpeechSynthesisUtterance` per line (≤ 12 words), `volume = master × voice × gain(d, walls)` set at its start; pitch and rate from §2.2 | `AudioTextToSpeech` → pitch shifter → EQ → reverb → `AudioEmitter` at the anchor; the 12 likeliest lines per stage pre-created at activation |
| Body (carries direction and size) | the **throat layer**: an HRTF panner at the true anchor (direction only) with a `GainNode` at `gain(d, walls)`: a breathy growl and a whisper double gated by `VoiceRules.syllables(text)` spread over the line's length | a growl bed of `AudioPlayer` layers on the same emitter, the same envelope |
| Fallback | no voices or a speech error: the throat layer and the subtitle | load failure or > 1.5 s: the growl bed, a murmur and the subtitle |

**Subtitles.** Label DANNY (struck through) for the monster in the school, GUS (struck through) in the city; italics
for Ear; a direction glyph ▴ (bearing within 45°), ▸, ◂, ▾ (beyond 135°). Shown for clamp(1.5 + 0.06 × characters,
2.5, 7) s. Opacity 100 % within 20 studs, falling to 50 % at 60. "Subtitles" governs speech; "Captions" governs
sound effects.

**Settings (both platforms).** Monster voice: Voice and subtitles (default) / Subtitles only. The monster says
names: On (default) / Off, honoured per page for every synthesized voice. Voice volume. Cutscenes on replays: Short
(default) / Full. Leap assist.

### 3.5 The scare director (`ScareRules`, pure; P0 is a gate and seven set pieces)

**The gate.** A set piece may fire for a player only when all of these hold:
- it has not fired this run; no other set piece fired for them in the last 90 s; the stage is ≥ 25 s old;
- no chase, catch, breath check, revive, held objective prompt or cutscene involves them;
- the monster is ≥ 40 studs away, not warping, and no teleport warning started in the last 8 s.

A blocked trigger re-arms (up to 3 tries). Ambience drops 18 dB for 1.5 s before a set piece with a visual payoff.
Arrival beats (the Curtain Call, "He lands") skip the gate but obey I13. Gameplay stingers (StareSting, ChaseSting,
RevealSting) are never capped. The existing Basement beats that emit a real noise keep their own seeded timers,
outside the director (I3).

| Stage | Set piece (once per run) | Trigger | What happens | Who |
|---|---|---|---|---|
| Basement | **The phone** | ≥ 90 s on the floor; the `WallPhone` (workshop keep-room) 20–40 from a player and out of their view | it rings up to 4 times. Answer (hold 0.6 s): 1.5 s of static, then, Device: "{name}? …wait up." Ignored: it stops. Sound only | the answerer |
| Hallways | **Classroom 108** | existing | existing | existing |
| Auditorium | **The Curtain Call** | arrival (§4.4) | it stands under the ghost light on the stage; the light bursts | squad |
| Roof | **The gate** | the chase's start (§4.5) | lightning blows the gate chain; the bell tolls once | squad |
| Rooftops | **He lands** | 4 s after the last touchdown | far to the east a huge impact on a tin roof; three car alarms start below, each nearer; all cut off at once; then one key jingle at his real spawn spot (I1) | squad |
| Rooftops | **The billboard** | the first player within 30 of the N roof's billboard | its dead floodlights buzz on at 2 Hz (never the teleport tell): a toothpaste smile; on the second flicker the smile is the seamed mask; dark | players within 60 |
| Airport | **The board** | the first player in the Concourse | the split-flap board clatters through every row and stops on "{NAME} · {NAME} · … · DEPARTED" (the squad's names, or "PASSENGER"); one row keeps flapping | players within 60 |

### 3.6 Hiding spots, and the monster's rule changes

**Hiding.** The three kinds and every rule of MONSTER.md §8 stay. New looks are a `HideSkin` attribute (model and
camera only): Locker `Wardrobe`, `MeterCloset`, `ToolCrib` · Cabinet `FilmCabinet`, `TicketBooth`, `PropTrunk`,
`RoadCase`, `ACHousing`, `BaggageCart`, `ToolChest`, `CheckInDesk` · Barrel `TarDrum`, `RainButt`, `OilDrum`. The opening's bins
are not hiding spots (no Creature is active there).

**No new Creature action in P0.** Every scripted beat in this spec uses Stare, ReachIn, LookAway, FadeIn, FadeOut,
Jumpscare, DoorSmash, LockerRip, the chase lope and the Stunned and Dormant poses. A P1 action needs a MONSTER-LOOK
table first: length, phases, hitbox and eye, sounds, Potato form.

**Amendments to MONSTER.md (both platforms; each has a creature-sim case)**

| § | Change |
|---|---|
| 5 | Spawn-hold stages: Basement, Rooftops, Airport. The Auditorium has the Curtain Call, the Hallways its classroom scare. No roof finale phases |
| 6.7 | The timed ReachIn comes at `max(since + 30 [24], arrival + 3.1)`, so "Ready or not…" always leads it by 3.0 s |
| 6.10, 7.1 pools | AquaticStalk, pool warps, the Swim pose and the Underwater catch are deleted |
| 7.1 | A warp or placement destination must lie in a walkable component that holds a hunted player, with doors as they are now (it can never strand itself behind the Auditorium's hidden door) |
| 7.2 | RoomKind `Yard` (open air) counts with Tunnel and Gallery: it may teleport onto the target's roof or apron zone. Candidates there are the 5-stud land lattice. Every land spot has a fixture within 32 for the warning (validated) |
| 7.2 (7) | Teleports are blocked during any objective survive countdown (the film, the hangar door), on the roof, and during the takeoff |
| 8.2 | The 45 s shove waits while the Creature is within 30 studs of the spot and not chasing, as it already waits for a running breath check |
| 9 | Downed is per stage (§3.3). `ignored` players (respawn grace, seated in the plane) are never seen, heard or caught |
| 10 | It never leaves walkable rooms. Rooms of kind `Gap` give it no floor. Where a walkable room meets a Gap through an opening, a `CreatureBlock` collider stands (Roblox) and the web's locomotion clamps to the same rect (`meta.creatureBlocks`). A target in a Gap or a crawlway is unreachable: it walks to the nearest walkable point within 3 of the lip, faces them and holds until sight breaks or the chase times out (22 [28] s) |
| 11 | Host Gus: `KeyJingle` on every footfall (§4.7). It is an output; the AI never reads it |
| all | Every rule distance and ETA (teleport bands, spawn holds, respawn relocation, withdraw) is measured on the exported walk graph on both platforms. Roblox's PathfindingService only steers between its waypoints |

### 3.7 Co-op rules (1–4 players; everything new is host or server authoritative)

| System | Rule |
|---|---|
| Cutscenes | one `startAt`; skip vote (§2.3); per-page `{you}` lines |
| Lives | per player; scripted-chase attempts per squad (§3.3) |
| Radar | charges personal; a scan is shared (§3.2) |
| Voice | the authority picks; each recipient gets its own composed text; Ear lines go to one player |
| Objectives | shared progress; items are carried per player and dropped on a down, as today |
| The Last Run | the chaser hunts the rearmost active runner; only that runner can be caught; one survivor through the shutter saves the attempt (§4.5) |
| The gun | one holder; drop to pass; an idle holder drops it (§4.6) |
| The jump | everyone jumps on their own; nobody can be left behind (§4.6) |
| The plane | first aboard flies; everyone flies; the pilot's page simulates and the authority validates (§4.9) |
| Events | each feature registers its own messages in `coop/events.js` (web) or `RemoteRegistry` (Roblox): validator, rate limit, allowed phases and life states |

---

## 4. Stages

### 4.1 `BackLot`: the opening's set and the short prologue
World coordinates; street level is y 18. The lot lies south of the school's south façade (z 288): x 0..80, z 290..350.

| Piece | Where (world x, z) |
|---|---|
| Chain-link fence, 10 high, with an invisible wall to 14 | round the lot |
| Street gate, chained ("Chained.") | x 20..36 on z 350 |
| **Staff doors**, 8 wide, with a roll-down lockdown shutter and a red LOCKDOWN strobe (dressing on the façade; nothing behind them) | x 56..64 on z 288 |
| **Yard lamp** on a 16-stud pole (one cold fixture, group `Scripted:BL_Lamp`) | (28, 330) |
| **Bins** (start marks by player slot): Dumpster A, slot 1 · the skip, slot 2 · the wheelie bin, slot 3 · Dumpster B, slot 4 | (10, 334) · (34, 338) · (48, 336) · (22, 340) |
| "DRAMA — PROP ROOM — DISCARD" boxes and the torn crate "MASQUE — DO NOT REMOVE — W.H." | beside Dumpster A |
| **Coal-chute hatch**: sloped steel doors against the façade, lit by the strobe | (30, 290.5) |
| Window glow cards on the south façade, two rows of six (groups `Scripted:BL_Windows_1`, `_2`) | z 288 |
| Bike rack, basketball hoop, pallets, puddles (`Detail` 2–3) | — |
| The bell tower over the roofline, its clock faces lit | — |

**Prologue (after S15; at most 50 s; the Creature is hidden and Dormant at its Basement spawn; I13).**
1. **Out of the bin.** "Push the lid" (hold 0.6 s) plays a 1.2 s climb-out. After 20 s in the bin it happens by itself.
2. **The lot at night.** Rain, the strobe, the gate chained, the staff doors shuttered. The only way on is the hatch,
   25–45 studs away.
3. **The chute.** "Climb in" (0.6 s) puts that player into a black wait ("You slide into the dark…"). When every Alive
   player is in, or 30 s after the first, everyone gets the same 1.6 s cut (long fingers push the hatch shut; a bolt
   drops), and anyone still outside is placed in it.
4. **Landing.** The Basement activates; the squad stands at its existing spawn in the delivery bay (a chute-mouth prop
   is added there as dressing). **The run timer starts here.**

No hiding rules, no noise and no monster in the lot. A joiner during the prologue starts at the next free bin.

### 4.2 The shorter school: the stack, the ids, and the Basement

| Level | Prefix | Elevation (world y) | Height | Entered from | Left by |
|---|---|---|---|---|---|
| `Level0_Basement` | L0 | 0 | 16 | the chute (its spawn, west) | east stairs |
| `Level1_Hallways` | L1 | 18 | 14 | east | west stairs |
| `Level2_Auditorium` | L2 | 34 | 28 | west | east stairs |
| `Level3_Roof` | L3 | 64 | open | the three east housings | the bell tower (west), then the jump |
| `City1_Rooftops` | C1 | origin (1400, 40, 0) | open | the landing roof (east) | the skybridge door (west) |
| `City2_Airport` | C2 | origin (1400, 0, 1200) | open | Arrivals (east) | the plane |

- **Stairs.** `WorldConfig.LevelOrder` becomes the four school levels, so the existing code generates
  `Stairwell_0_1` (east), `Stairwell_1_2` (west) and `Stairwell_2_3` (east), each with its `_North` and `_South`
  candidates. Rises are 18, 16 and 30 studs, inside what `StairwellBuilder` builds today. Random exits stay.
- **Sets.** `Runway` at origin (3000, 0, 1200); `Bahamas` at (3000, 0, 2400); `BackLot` is part of the school exterior.
- **Which level am I on.** `levelAt(p)` returns the level or set whose box holds p (x, y and z), so sets and city
  levels get their own film, exposure and acoustics.
- **Transitions.** Stair airlocks between the school floors, as today. Roof to Rooftops: the jump (§4.6). Rooftops
  to Airport: the skybridge airlock gathers as today (20 s straggler rule), then a 1.5 s fade places the squad at
  Arrivals. Airport to Runway: boarding (§4.8). Runway to Bahamas: lift-off.
- **The bell tower** now tops out 78 studs above the street (belfry deck at world 96).

**Basement** (objective unchanged: 3 fuses, the panel, the main breaker; bear traps stay).
- **Stun flasks** are cleaning chemicals now, labelled "G. PRUITT — DO NOT MIX". 8 `FlaskCandidate`s: the storage
  cage's shelves ×2, the workshop bench, the boiler room shelf, 4 tunnel niche shelves. A run places 3 [2].
- **Batteries:** 36 candidates, 6 [4] placed (§3.2).
- **Added props:** the `WallPhone` in the workshop (§3.5); the chute mouth.
- **How they are added.** A post-plan pass (`ExtraAnchors`, its own `Rng` keys) adds the extra battery and flask
  anchors. The planned rooms, doors and zone graph of the Basement and the Hallways keep their hash (a spec asserts).
- **Pacing.** Crossing 1,901 studs (2:53 at a walk) + fuse detours 2:00 + the panel 0:10 + hiding 2:30, less what
  the radar saves: about 7:30–8:00. The bot gate is 6–9 min at walking pace on four seeds; the only knob, if it
  fails, is `crossingTarget` (1,820 → 1,600).

**Flasks per run:** Basement 3 [2], Hallways 3 [2], Auditorium 2 [1], Rooftops 2 [1], Airport 2 [1]: 12 [7].

### 4.3 Hallways, and the janitor asleep in his closet
Objective unchanged: find the master keys (1 of 14 hooks, all west of the gate), unlock the stairwell (4 s). The
classroom scare, the gate and its bypass vent stay.

**Gus Pruitt** has been the night janitor since 2018; Walter Hale trained him. He is hard of hearing and naps on a
cot before his 11 PM shift, hearing aid out. The lockdown cut the mains at 3:31 and killed his alarm; he sleeps until
the one sound he always wakes to: his bell (the shot rings it, §4.6).

**Foreshadowing (all cosmetic, I3).**
- **The closet** (`L1_JanitorCloset`, x 98..118, z 270..288). Along the west wall, behind a hung blanket: a cot,
  boots, a shape under an army blanket. On the shelf: a transistor radio hissing an old tune (the tune the Tall
  Janitor whistles), a hearing aid in a dish, a clock-radio blinking 12:00.
- **The prompt** on the cot, "Wake him" (hold 1.5 s, once per run): he rolls over. GUS: "Mmh… five more minutes."
  Nothing wakes him. It is not a noise.
- **The snore:** every 4.5 s, 3D, heard to 24 studs (−6 dB through the door). Never an AI noise.
- **Signs** (decals): on the door, "NIGHT SHIFT SLEEPING. KNOCK LOUD. — GUS"; in the main office, a roster,
  "NIGHTS: G. PRUITT 11 PM – 7 AM".
- **His keys are the objective, and they are not in his closet.** The closet's hook is empty, with a tag: "MASTER
  RING — if it's not here I left it on a cart. — G." The 14 candidates: 10 hooks in tunnel niches and 2 in the main
  office (as today), and 2 on mop-cart handles that replace the closet's two. The fob reads GUS. Tracker: "Find
  Gus's master keys".
- **His trail:** 6 mop carts with WET FLOOR signs across the west half (landmarks, never `Detail`). Two hold the key
  hooks; four hold flask candidates.
- **The monster and Gus.** It never reacts to him (one host at a time). P1: if it enters the closet it sniffs the
  locker and ignores the cot.

**Other changes.** 8 flask candidates (the closet shelf ×2, the 4 carts, 2 Kitchen Service niches); 3 [2] placed. 36
battery candidates. No checkerboard (§5). Pacing: crossing 1,685 (2:33) + the scare, gate and vent 1:00 + keys 1:15
+ hiding 2:30: about 7:20.

### 4.4 `Level2_Auditorium`: "Showtime" (new floor; flat; about 7:30)

**In one breath.** Cross the Box Office tunnels into the foyer. In the dark house the curtain opens on its own (the
Curtain Call). Find two film reels backstage and in the tunnels. Thread both projectors in the booth and strike the
lamp. The 60 s film is loud: hide or keep moving. When the reel ends, Walter's switch flies a brick-painted flat out
of the scene dock and opens the hidden door behind it: the only way east.

**Frame.** A tunnel floor like the others (TunnelPlanner), one floor height everywhere. Entry vestibules west
(`L2_AirlockNorthWest` / `West` / `SouthWest`, x 0..14); exit vestibules east (x 386..400); the route is random as
today.

```
 z\x 0  14            96    124  140 150                200     226        276      316   342      386 400
  0  +--+------------- CABLE RUNS (tunnels, z 0..72) ------------------------------------+ DOCK    +--+
 72  |NW| BOX OFFICE  |      +----+-----------------------------+----------+------+-----+ TUNNELS |NE|
     |  | (tunnels)   |      |VesN| HOUSE  seats rows 1..10     | STAGE    | PROP |DRS N| (east   |  |
124  |W |             |FOYER |BOOTH  centre aisle z 138..150    | prosc.   +------+-----+  of the |E |
144  |  |             |      |A B | front floor x 200..226      | 80 wide  | SCENE DOCK [HIDDEN DOOR] LOADING |
164  |  |             |      |VesS|                             | screen   +------+-----+  DOCK    |  |
216  |SW|             +------+----+-----------------------------+----------+ COST |DRS S|         |SE|
288  +--+------ SCENERY STORE (z 216..288) ------ WARDROBE RUN ---------------------------+---------+--+
```

| Room (kind) | Rect x × z | Height | Contents and doors |
|---|---|---|---|
| `L2_Foyer` (Foyer) | 96..124 × 108..180 | 20 | ticket booth (Cabinet `TicketBooth`), the 1989 poster "THE MASQUE". Ports west at z 120 and z 168. Doors east into both vestibules and the booth |
| `L2_VestibuleN` / `S` (Corridor) | 124..140 × 108..124 / 164..180 | 12 | sound locks: doors to the foyer (west), the house (east) and the booth (its north or south door) |
| `L2_Booth` (Office) | 124..140 × 124..164 | 12 | **Projector A** (132, 136) and **B** (132, 152) at two glazed ports in the east wall (4 wide, y 6.5..8). 2 Cabinets `FilmCabinet` at (127, 128) and (127, 160). Three doors: foyer (z 144), VestibuleN, VestibuleS |
| `L2_House` (Auditorium) | 140..226 × 72..216 | 26 | seats (below); 2 Lockers (usher closets) at (144, 76) and (144, 212); ports north (z 72, x 213) and south (z 216, x 213) |
| `L2_Stage` (Stage) | 226..276 × 72..216 | 26 | the proscenium is an 80-wide Doorway in the x 226 wall (z 104..184). The **screen** stands at x 266, z 120..168, y 2..22 (walk round either end). **Ghost light** on a stand at (246, 7, 144). 2 Cabinets `PropTrunk` in the wings. Ports north and south (x 250). **Speaker point** (222, 8, 144) |
| `L2_PropRoom` (Storage) | 276..316 × 72..120 | 14 | shelves of masks and props, the empty crate space ("MASQUE" stencil), 2 Cabinets `PropTrunk`. Doors: stage (z 92), scene dock (x 296), DressingN (z 96). Port north (x 296) |
| `L2_SceneDock` (Storage) | 276..342 × 120..168 | 22 | painted flats, a workbench, 2 Cabinets `RoadCase` (one at (334, 130)). The **hidden door**: a `Gate` with skin `BrickFlat`, 10 wide × 12 high, in the east wall at z 139..149, behind a brick-painted flat. Doors: stage (8 wide, z 144), prop room, costume store, both dressing rooms |
| `L2_CostumeStore` (Storage) | 276..316 × 168..216 | 14 | racks (dressing), 3 Lockers `Wardrobe`. Doors: stage (z 196), scene dock, DressingS. Port south (x 296) |
| `L2_DressingN` / `S` (Dressing) | 316..342 × 72..120 / 168..216 | 12 | mirrors ringed with bulbs, 3 Lockers each. Ports north / south (x 330) |
| `L2_LoadingDock` (Storage) | 342..386 × 120..168 | 16 | east of the hidden door. 2 Cabinets `RoadCase`. Ports north and south (x 364) into the Dock tunnels and the three exits |

- **Seats.** 10 rows at x 152, 157 … 197 (pitch 5). Two blocks, z 80..138 and z 150..208. Side aisles 8 wide, the
  centre aisle 12, a rear cross-aisle (x 140..150) and the front floor (x 200..226). Each row block is one
  `MonsterPassthrough` slab for the backs, 3.2 high and 0.6 thick (players collide; the Creature wades through at
  full pace on both platforms, with a PassThrough modifier on Roblox). Cushions are visual only. No cover is claimed
  for seats, and no seat is a required move.
- **The curtain** is cosmetic and never queried: it is closed only while the Creature is held for the Curtain Call,
  and open from then on. The stage is level with the house.
- **No dead ends:** every theatre room has at least 2 exits; the booth has 3 doors.
- **Tunnels.** Regions: Box Office (x 14..96), Cable Runs (z 0..72), Scenery Store (z 216..288, x 96..226), Wardrobe
  Run (z 216..288, x 226..342), Loading Dock (x 342..386). One barrier: **x 342, z 0..288**, crossed only by the
  hidden door; no crawlway crosses it. `TunnelRules` counts a hidden `Gate` as open for connectivity and the crossing,
  and as closed for item and hide reach.
- **Rules:** crossing 650–1,000 (target 800); crawlways 4–8; hide reach 30; objective hide reach 25; dead ends ≤ 6.
- **Counts:** batteries 36; flask candidates 6 (prop room ×2, costume store ×2, booth, scene dock); no bear traps; no
  ScareStep triggers; 3 of the planner's PatrolWaypoints flagged as release points for the Curtain Call.
- **Light groups.** Base (the AI's light): 1 EXIT sign in 4, aisle lights (cold white 0.08, range 4, 40 % lit), the
  booth's red lamp 0.3, 40 % of the mirror bulbs. Scripted (never the AI's light): `L2_GhostLight`, the projector
  beam and the screen's glow, the stage work lights that come on at the reveal. Baked luminance ≤ 0.05 in the house
  outside those pools.

**The objective** (`ObjectiveConfig` floor 2)
```
{ floor = 2, levelId = "Level2_Auditorium", id = "Showtime", title = "Objective.Floor.Showtime",
  item  = { prop = "FilmReel", candidate = "FilmReelCandidate", count = 2, hold = 0.6, object = "Prompt.FilmReel" },
  steps = { { id = "FindReels", count = 2 }, { id = "ThreadReels", count = 2 },
            { id = "StrikeLamp", count = 1 }, { id = "WatchFilm", count = 1, seconds = 60 } },
  lockStep = "WatchFilm", lockVariant = "Keypad", holds = { ThreadReel = 2.5, StrikeLamp = 2.0 } }
-- Tuning: FilmLead 3.0, FilmScorePeriod 4, ProjectorRunPeriod 2, FlatRise 18, FlatSeconds 8, DockDoorSeconds 4
```

| # | Step | Where | Hold | Noise (rank, radius) | Notes |
|---|---|---|---|---|---|
| 1 | **FindReels** 0/2 | 2 of 12 candidates | 0.6 | — | 16 mm cans, "THE MASQUE · 1989". Carried like any item |
| 2 | **ThreadReels** 0/2 | projector A, projector B | 2.5 each | ObjectiveWork (Normal 34) at the start and each second | either reel fits either projector; partial progress is kept |
| 3 | **StrikeLamp** | projector A | 2.0 | `LampStrike` (Critical 130) at the booth on completion | locked ("Thread both reels") until 2/2. Film time 0 = strike + 3.0 s |
| 4 | **WatchFilm** 60 s | — | — | `FilmScore` (Normal 90) every 4 s at the speaker point; `ProjectorRun` (Normal 30) every 2 s at projector A | teleports are blocked from the strike to the reveal. The film always runs to its end: no fail state |
| → | **Reveal** | scene dock | — | ObjectiveClunk (High 110) at the run's exit lock | 60.0 the switch clunks, WatchFilm completes, the run's Keypad shows "INTERLOCK RELEASED". 60.3–68.3 the flat flies up 18 studs (visual, no collision). 68.5–72.5 the hidden door rolls up; it is passable from 70.5. 60–66 the aisle lights chase toward the dock (scripted group) |

- **Reel candidates (12):** prop room shelf ×2, costume store table ×2, DressingN, DressingS, the scene dock's
  workbench, the north wing's prop table, and 4 tunnel niches (one each in Box Office, Cable Runs, Scenery Store,
  Wardrobe Run). Never in the booth, the house, the foyer or east of x 342. The usual pick rules hold: ≥ 35 walked
  from the entry, different rooms, ≥ 25 apart, a hide within 25.
- **Hide reach:** projector A and B to a film cabinet 9.4 each; the hidden door to the road case 16.1; every reel
  candidate and every exit ≤ 25 (validated). No hide stands within 20 of the speaker point.
- **Tracker:** "Find the film reels 0/2" → "Thread the projectors 0/2" → "Strike the lamp" → "The film 0:60 — stay
  alive" → "The way out: the scene dock".

**The film** (`Shared/Config/FilmSpec.luau`: a list of cards, drawn the same by both platforms: web canvas 512 × 192,
Roblox SurfaceGui; 12 frames a second on every tier; grain from `Rng.seeded("FilmGrain", frame)`)

| Film t | Card |
|---|---|
| 0–5 | countdown leader 8…3, a beep at 2 |
| 5–10 | "ROVLOC HIGH DRAMA CLUB presents THE MASQUE · 1989" |
| 10–26 | shadow-play: five small figures on a stage; a tall masked one rises among them and cocks its head (rects and ovals with keyframes in 0..1 screen units) |
| 26–30 | the picture jitters; a 6-frame white burn |
| 30–34 | intertitle: "IF YOU ARE WATCHING THIS, IT IS BACK." |
| 34–38 | "IT WEARS A FACE. IT KEEPS THEIR VOICE." |
| 38–44 | "THE WAY OUT IS THROUGH THE DOCK, BEHIND THE BRICK FLAT." |
| 44–52 | "ON THE TOWER: ONE BULLET. I COULD NOT. HE WAS MY BROTHER. — W.H." |
| 52–58 | an arrow: "SCENE DOCK →" and this run's exit: "NORTH STAIR", "MIDDLE STAIR" or "SOUTH STAIR" |
| 58–60 | the tail flaps; white |

The beam is an unlit additive cone from projector A's port to the screen (no light source, so it is the same on
every tier and on Roblox). The screen is emissive.

**The Curtain Call (arrival; replaces the spawn hold here; existing Creature actions only).**
- **Hold.** At activation the Creature is taken (Scripted), hidden, at the mark (246, 0, 144) under the ghost light,
  head bowed. The curtain is closed.
- **Trigger:** a player inside the house or the stage with a clear line to the mark (the curtain ignored) within 80.
  Then, from S:

| Time | Event |
|---|---|
| S + 0.0 | the fly motor groans; the curtain opens over 3.0 s |
| S + 3.0 | it is revealed, bowed. It waits up to 6 s for a look: a player's view within 25° of its head, within 80, a clear line (L; else L = S + 9) |
| L + 0.6 | the Stare action: its head lifts and cocks toward the looker |
| L + 1.6 | Head: "Welcome to the show, {name}." (2.4 s) |
| L + 4.2 | the ghost light bursts; the stage goes black |
| L + 4.4 | hidden, and placed at the release point ≥ 45 from every player, unseen, in the squad's component |
| L + 10.4 | released into Patrol. The floor's grace (20 [12] s) counts from here; the first teleport comes no sooner than grace + 45 |

- **Silent path** (no reveal; hidden placement at once, release 6 s later): 45 s pass with no trigger; a player comes
  within 20 of the mark before S + 3; a High or Critical player noise sounds on the floor; or a player can see the
  mark at activation.
- It is Scripted until the release: no stare chase and no catch before then.

**What the monster does during the film.** `LampStrike` pulls it to the booth, where it investigates for 6–10 s and
sniffs up to 2 hides within 15: the film cabinets. Then each `FilmScore` pulse re-targets it to the stage front. So:
do not hide in the booth; hide away from the speakers, loop the foyer and vestibules, use the crawlways, throw a
flask, or let a teammate's sprint draw it off. The stay-limit rule (§3.6) never shoves a hider out under its nose.

**Co-op.** Reels are carried per player; anyone threads or strikes; the film clock and the reveal are one event.

### 4.5 `Level3_Roof`: "The Last Run"

**Overview.** An obstacle chase in the style of DOORS' door 100, about 33 s clean from the middle arrival (39 s from
the north or south one), from the stair housings to Walter's bell tower. On the roof the Creature is Scripted: a rail
chaser driven by `ChaseRules`, with no senses, no teleports and no patrol. That is what makes I4 provable.

**The roof** (deck y 0 = world 64; open; fenced course; nothing else is walkable).
- **Housings** (as today): x 386..400, z 16..40 / 132..156 / 248..272; their doors open west at z_h = 28 / 144 / 260.
- **The pen** outside the run's housing: x 342..386, z_h − 12..z_h + 12, fenced 8 high. Two practice fixtures span it,
  so everyone meets them calmly, with first-time hints: a **hurdle** at x 372..374 and a **slide bar** at
  x 362..364. The **gather zone** is x 342..356. The **gate**, 8 wide, is at (342, z_h).
- **The lane** is 12 wide between 8-high mesh and duct walls. Cold-white chevrons every 15 studs; white strobes at
  every fixture; the tower's clock faces always visible (I10).

| § | Centre line (x, z) | Length | Fixtures |
|---|---|---|---|
| Spur N (S mirrors about z 144) | gate (342, 28) → (318, 28) → (318, 138) → M (318, 144) | 140 | hurdle H0 at z 70; slide bar B0 at z 108..112 |
| 1 | middle gate (342, 144) → M (318, 144) → (296, 144) | 46 | hurdle H1 at x 306 |
| 2 | (296, 144) → (296, 84) | 60 | slide bar B1 at z 116..112 |
| 3 | (296, 84) → (224, 84) | 72 | **leap L1**: strip x 272..268, well x 268..256, pad x 256..248 |
| 4 | (224, 84) → (224, 204) | 120 | hurdle H2 at z 112; slide bar B2 at z 146..150; hurdle H3 at z 182 |
| 5 | (224, 204) → (144, 204) | 80 | **leap L2**: strip x 194..190, well x 190..178, pad x 178..170 |
| 6 | (144, 204) → (144, 88) | 116 | hurdles H4 at z 172 and H5 at z 124 |
| 7 | (144, 88) → the shutter (40, 88) | 104 | hurdle H6 at x 104; slide bar B3 = **the tower's shutter**, half down, at x 42..40 |

- **Clean time:** 598 studs at 19, + 0.15 s for each of 6 corners and 3 bars: **32.8 s**. North or south (+116
  studs, 2 corners, 1 bar): 39.4 s.
  `ChaseCourse` exports the polyline, the fixtures and each point's clean-time coordinate (`meta.chaseCourse`).
- **Wells** (the two fall zones): a `Gap` room 12 along the lane, lane-wide, 10 deep, with an 8-wide alcove beside
  the lane holding a stair (10 risers × 1.0, treads 1.25, 4 wide) up to a landing next to the pad. A fall costs
  about 2.6 s and never hurts.
- **Lightning cues** (a full-sky flash, then thunder): at the gate; when the lead runner is 25 studs before each
  strip; when the lead enters §7. The base storm flashes every U(6, 11) s.

**Arrival and the gate.**
1. The squad arrives together through the airlock. The roof door opens 1.2 s after the first player enters the
   housing. The tracker: "GET TO THE GATE".
2. **Gather.** The scene starts (S) when every Alive player is in the gather zone, or 25 s after the first player
   entered the pen. At S + 0.35 the housing door slams (a 0.35 s blackout); anyone not yet in the gather zone is
   placed in it during the blackout.
3. S + 1.9 / 3.0 / 3.55: it pounds the door. S + 4.1: reveal. **S + 4.6 = t0: the smash.** In the same instant
   lightning blows the gate's chain and the bell tolls once. The chase runs from t0.
4. **Adrenaline.** From t0 until a runner passes the shutter: any forward input runs at 19 (sprint is latched on
   every device), stamina does not drain, crouch and slide work as usual.

**The chaser** (`Shared/Rules/ChaseRules.luau`, ported to `mechanics/chase.js`; everything in clean-time seconds)

| Quantity | Rule |
|---|---|
| Progress p of a runner | the clean-time coordinate of their projection onto the centre line (nearest point on the current or next segment, 1.5-stud hysteresis: the next segment wins unless it is more than 1.5 farther, and it never goes back). It never decreases, except that a runner more than 2 below the deck is in the well and held at its entry coordinate e; climbing out, it resumes from its projection. The pen is negative: 14 studs behind the gate is −0.74. Clean time: each corner's 0.15 s is spread over 2 studs either side of it, each bar's over the bar |
| Quarry | the active runner with the smallest p (Alive, not caught, not yet under the shutter), re-picked every tick |
| Chaser coordinate c | starts at −τ0 at t0, with **τ0 = 2.6 [2.4]** |
| Gap | g = p(quarry) − c |
| Advance per second | **ρ = 0.86 [0.93]** while g ≤ τ\*; **ρ = 1.12 [1.15]** while g > τ\*; **τ\* = 1.6 [1.2]**. Each tick's ρ is read from the gap at the start of the tick |
| Where it is | the course point at coordinate c. It moves at ρ × the local clean pace: at most 21.3 [21.9] studs/s on the flat, slower through fixtures |
| Loom | while the quarry is in a well, c advances no further than e − 0.3: it stands at the lip and stares down (the Stare action). After **8 [6] s** of looming over that quarry it reaches down (the ReachIn action) and that runner is caught |
| Catch | g ≤ **0.25** (about 4.7 studs) on 3 consecutive ticks, the quarry not in a well. Only the quarry can be caught, so c is always behind every active runner |
| Lag | the quarry's progress is read from its timestamped report against c at that timestamp (a 30 Hz history, rewound at most 0.4 s). Pages draw the chaser from the rail state `{c, ρ, t}`, so the gap on screen is the authority's |
| Fixtures | when c reaches a hurdle or bar, the prop switches to its `Smashed` node behind the runners (cosmetic; collision is static). It crosses wells along the centre line |

**The table the specs assert** (simulated on the tick by `ChaseRules`, the same on all three arrivals; a stall is time
with no progress: a bump is 15 ticks, a slow bar 24, a fall 78 in the well; "apart" and "later" are start to start; a
runner stands at the gate at t0, and every mistake is made at a fixture after the gap has settled, the worst one
given. Earlier mistakes cost less)

| Run | Standard | Nightmare |
|---|---|---|
| Clean | never caught; the gap settles at τ\* after 8.3 s (about 30 studs behind) and never drops below 1.58 | never caught; settles after 8.0 s; never below 1.17 |
| One bumped hurdle (0.5 s) | dips to 1.16, recovers | dips to 0.73 |
| One bar crouch-walked (0.8 s) | dips to 0.90 | dips to 0.45 |
| Longest single stall survived | **1.57 s** (47 ticks) | **1.00 s** (30 ticks) |
| Two bumps 2 s apart | 0.94 | 0.37 |
| A bump, then a slow bar 3 s later | 0.82 | caught |
| Two slow bars 3 s apart | 0.52 | caught |
| A fall (2.6 s in the well), then clean | Loom; rejoin at 0.93; escapes | the same |
| A fall, then a slow bar 2 s after rejoining | escapes (dips to 0.52) | escapes (dips to 0.33) |
| Staying in a well | caught at 8 s | caught at 6 s |
| Standing at the gate | caught at 2.5 s | at 2.1 s |

- **Margins.** Standard's mistakes all escape with at least 9 ticks to spare. Nightmare's double mistakes sit close to
  its 30-tick budget by design: two bumps 2 s apart escape with up to 3 more ticks of stall, a fall then a slow bar
  with up to 2 more; a bump then a slow bar is caught down to a 22-tick bar (2 to spare), two slow bars down to a
  12-tick one.

**Catches, attempts and resets.**
- A caught runner gets the Hallway catch moment (2.05 s) and lies Downed where they fell, bleed-out frozen; the
  chaser holds 3.0 s, then takes the next quarry.
- **Success:** at least one runner passes under the shutter. It slams 0.5 s after the last active runner is through
  or caught. Every caught runner stands up inside the tower at 50 health (a lightning cut).
- **Wipe:** every runner is caught. A 1.2 s fade, "Again.", and the squad stands in the pen at max(current, 50)
  health; the gather replays 5 s later. Attempts follow §3.3 (3 [2] free). The HUD shows "2 tries left".
- **A retry resets:** the housing door, every `Smashed` fixture, the gate, lightning cue flags, adrenaline, the rail
  state and every runner's progress. `roof-chase-bot` asserts that attempt 2 repeats attempt 1 for the same inputs.
  Solo: a catch is a wipe.

**The objective** (`ObjectiveConfig` floor 3, `LastRun`): steps `ReachTower` (the first runner under the shutter),
`TakeRevolver`, `Standoff` (the shot, or Ending B), `Jump` (the first touchdown). No exit lock. The roof is exempt
from the hide-reach and entry-clearance rules (it has no hiding and no hunting), stated in the config and both tests.

### 4.6 The bell tower: the revolver, the choice, the twist, the jump

**The tower.**
- `L3_BellTower` (kind Tower): x 5.5..38.5 × z 71.5..104.5, 32 high. A stair of 4 flights × 8 risers × 1.0 (treads
  1.4, 6 wide, built with `StairwellBuilder`'s flights): about 7 s at a walk. Walking speed returns here.
- `L3_Belfry` (kind Yard): the deck at +32 (world 96), x 4..40 × z 70..106, open. A 3.5 parapet with invisible
  blockers to 9 on all four sides. The bell hangs overhead (its lip 12 above the deck) in a frame on four corner
  posts, so the deck is clear. Bone-white clock faces glow below the deck on all four sides.
- **Hatch** (the stair's top) at (34, 100). **Walter's lockbox** at the north parapet (22, 73). **The jump kit**
  (today's `ParachuteCrate`, re-skinned as an army trunk, "W. HALE — JUMP KIT", 4 packs) at the west parapet (7, 80),
  latched. **The jump gate**: a chained mesh gate in the west parapet, z 92..100, 8 wide, blocked until C.

**The revolver.**
- "Open the lockbox" (hold 1.0 s; one player at a time), then "Take the revolver" (0.6 s): old, six-shot, one round.
  A 1.6 s load plays in the hand (cosmetic; you can move).
- The first taker is the **holder**. Before the standoff it cannot fire. Tap Drop to pass it; anyone picks it up
  (0.6 s).
- **The standoff starts at T_s** = max(first belfry arrival + 12, revolver taken + 5), and not before every active
  runner is on the belfry or 20 s have passed since the shutter slammed. At T_s − 1 anyone still on the stair is
  lifted through the hatch with a fade, and the hatch bolts.
- If nobody holds the revolver at T_s + 4.0: "Go on. Pick it up, {name}." (to the nearest player). Taken during the
  standoff, it can fire 0.6 s later.

**The standoff** (one Scripted timeline; t from T_s; everyone walks at 11 at most)

| t | Monster | Voice |
|---|---|---|
| −1.6 | the teleport warning on the belfry: the clock glow and the hatch lamp stutter, the hiss at its spot, torches stutter (I2) | — |
| 0.0–0.8 | FadeIn at whichever of four spots is farthest from the holder (with no holder, from the players' centre): E (35, 88), N (22, 75), S (22, 101), W (9, 88) | — |
| 0.8–2.0 | the Stare | Monster (1.0, 1.0): "{name}." |
| **2.0** | **Fire is enabled** (a button already held at that moment is ignored until it is released) | — |
| 2.0–5.5 | walks to 20 studs from the holder | — |
| 5.5 | stops | Danny, clean, breaking (5.6, 3.2): "It's me. It's still me. Please… don't." |
| 8.8–10.5 | walks to 13 | — |
| 10.5 | stops | Monster (10.6, 2.4): "You hid. You always hide." |
| 13.2 | — | Danny, quiet (13.2, 1.0): "…do it." |
| 13.4–15.5 | walks to 4 | — |
| **15.5** | contact: **Ending B** | — |

- **Speed rule.** Each walk's speed is the remaining distance to its stop ÷ the remaining time, clamped to 2–9. If
  the holder is already nearer than a stop distance it holds. If it is still over 4 away at 15.5 it lunges at 12; at
  17.0 a lightning cut puts it on the holder. The holder walking into it earlier makes it stop and hold until 15.5.
  It walks straight lines on the open deck, re-aimed every 0.35 s; non-holders pass through it.
- **Window:** 2.0 → 15.5 = **13.5 s**. Nightmare: every event after 2.0 moves to 2.0 + (t − 2.0) × 0.7407 (exactly
  10.0 / 13.5): contact at 12.0, a **10.0 s** window (I5); its second line ("You hid…") is cut so no two lines overlap.
- **Lowering the gun** (hold 1.5 s) is the choice not to shoot: "I knew you wouldn't." It walks in at 6. In co-op a
  teammate may still take the gun from a lowered holder (hold 1.2 s) and fire.
- **An idle holder** (no look, move or aim input for 4 s during the standoff) drops the gun at their feet.

| Revolver context (replaces Throw and Jump while holding) | Keyboard and mouse | Gamepad | Touch |
|---|---|---|---|
| **Fire** | LMB | RT | FIRE: a 120 px button, right side, clear of the look area; fires on press and release inside it. The movement buttons are hidden |
| Lower (hold 1.5 s) / Drop (tap, under 0.3 s) | G | D-pad down | LOWER, bottom left |
| Take from a lowered holder / pick up | E (1.2 s / 0.6 s) | X | the prompt |

**What counts as shooting him** (pure `Shared/Rules/EndingRules.luau`)
- The shot is the camera's centre ray at the fire tick, 60 long. There is no sway in the test.
- It **hits** if it passes through the Biped hitbox (2.6 × 11 × 2.7) grown by the input's margin: mouse 0.6, gamepad
  1.2, touch 1.8 studs. Any hit is Ending A; on screen the bullet always strikes the mask. A choice, not an aim test.
- A ray blocked by the world (it meets the world before the hitbox or, missing the hitbox, within its 60) does not
  fire: the reticle shows "no clear shot" and the round is kept. Teammates never block.
- A clear miss uses the round: "Missed." It closes at 9; contact is Ending B.
- **Authority** (web host and Roblox server, the same rules). Accept a shot whose client time is inside the window
  and that arrives within 0.35 s of its end. Its origin must be within 3 of the holder's head and its direction
  within 25° of the looks relayed within ±0.15 s. Test it against the monster's pose rewound by the one-way latency
  plus the render delay, 0.5 s at most. A rejected shot never uses the round and never counts as a miss.

**Ending A's staging.** Danny's mark is the monster's position at T, moved to stand ≥ 4 from every parapet. Kneel
marks lie on a ring of radius 2.5 at 0°, ±70° and 180° from the shooter's bearing. Camera keys are relative to the
mark. Gus comes up through the hatch. Everyone is control-locked from T: own view until T + 4.0, then cinematic.

**The aftermath: from C to the canopy** (C = T + 44.0, or T + 31.0 with the Short twist; I13 holds until the first
touchdown)

| When | What happens |
|---|---|
| C + 0 | control returns. Tracker: "TAKE A PARACHUTE. JUMP." The jump kit unlatches; the gate's chain drops and its blocker lifts. Gus (the actor) thrashes near the east parapet at (33, 88), 27 studs from the kit |
| C + 8.0 | a lightning blackout of 0.4 s: the actor is swapped for the Creature rig, host Gus, folded |
| C + 8.4–11.0 | the Tall Janitor unfolds to 11 studs (the FadeIn pose, slowed, no dissolve), the jumpsuit splitting. One key jingle |
| C + 11.0 | the Stare at the nearest player. Gus's voice, deep (11.2, 1.6): "…{name}?" |
| C + 13.0 | it walks at the nearest player at 7. The keys jingle on every step |
| **The sweep** | when it comes within 6 of anyone, or at C + 20: everyone still on the belfry is given a pack if they have none and is shoved through the gate (0.8 s, scripted). Nobody is caught |

- **Packs** are today's mechanic: a 0.5 s grab, one each, co-op claims as today. Walking through the gate without one
  buckles a free one on. Today's "fall without a pack" death is deleted.
- **The fall is `parachute.js` as it stands:** freefall; the cord on Space, A or PULL CORD; auto-deploy after 3.5 s;
  canopy descent 9 and drift 7. The existing **look-back camera** stares up at the ledge, so whichever second of
  the timeline is running (Gus thrashing, the swap, the unfolding, the stare from the parapet) is watched from
  under the canopy. That is "he transforms as you parachute". Two seconds after the last jump he steps onto the
  parapet and stares down (today's ledge staging).
- **Hand-over.** Six seconds after the canopy opens, a 0.6 s cloud whiteout moves the jumper to `City1_Rooftops`, 60
  studs above their slot's landing mark, still under the canopy. The look-back is released. Card: "PART TWO · THE
  CITY" for 2.5 s. Touchdown is about 6.7 s later. `forceLand` at 30 s stays.
- **Rooftops activates** at the first touchdown. Its spawn hold and grace start at the last touchdown, or 30 s after
  the first.
- **Co-op.** Everyone jumps on their own. Players who are dead and out of respawns float down 5 s after the first
  landing (the checkpoint rule).

**Ending B with a second half.** It is staged as §2.6 and still ends the run. Triggers: contact with no shot; a
lowered gun nobody takes; a clear miss. Its results card shows the chapter strip with chapters 5 to 8 as locked
silhouettes ("4 / 8") and the line "Walter couldn't either. There is another way this night ends."

### 4.7 `City1_Rooftops` (about 8 minutes)

**Concept.** A ring of eight flat rooftops round one tall dark tower, in a canyon of taller buildings. You land on the
east roof; the airport skybridge leaves from the west roof. To open its door you close three feeder switches, on
both sides of the ring. Every switch is loud, so every switch brings him; the gaps between roofs are how you get
away, because he has to go round.

```
 z\x  0 12              124 136               264 276              388 400
  0   +--+---------------+--+------------------+--+----------------+--+
 12   |  | NW  Pigeon    |  | N  Billboard     |  | NE  Water      |  |     G = gantry (he can cross), outer end
      |  |  Lofts    F3  |G3|  F2          LP1 |G2|  Tower   F1    |  |     P = plank, LP = leap (players only),
 96   |  +-G4-----LP2----+##+-------alley------+##+--P1--------G1--+  |         inner end
108   |  | W  Skybridge  |  | THE MERIDIAN     |  | E  Laundry     |  |     ## = corner stack (solid, 30 high)
144   |EX|<- exit door   |  | (tower, 48 high, |  |  landing marks |  |     F = feeder cabinet (3 of 6 a run)
180   |  +-G5-----P3-----+##+  unwalkable)     +##+--LP4-------G8--+  |     alleys are 12 wide, their decks 12 down
192   |  | SW  Cinema    |  | S  Sawtooth      |  | SE  Tenement   |  |
      |  |  F4       LP3 |G6|  Works  F5    P4 |G7|           F6   |  |
276   +--+---------------+--+------------------+--+----------------+--+
```

**Layout** (hand-laid `LayoutSchema`; deck y 0 = world 40; a 400 × 288 frame at its own origin).
- **Roofs** (rooms of kind `Yard`, two zones each, open, 3.5 parapets):

| Roof | Rect x × z | Its landmark (a solid occluder) | Bulkhead (12 × 12 × 10) |
|---|---|---|---|
| E "Laundry" (entry) | 276..388 × 108..180 | laundry lines; 4 landing marks round (340, 144) | (300..312, 114..126) |
| NE "Water Tower" | 276..388 × 12..96 | tank on a skirted base 16 × 16 × 8 at (324..340, 40..56) | (350..362, 70..82) |
| N "Billboard" | 136..264 × 12..96 | billboard 48 × 16 on a screened 6-high frame along z 20 (x 176..224), facing south | (146..158, 76..88) |
| NW "Pigeon Lofts" | 12..124 × 12..96 | two loft sheds 10 × 8 × 7 | (80..92, 70..82) |
| W "Skybridge" (exit) | 12..124 × 108..180 | vent stack 14 × 14 × 12 at (60..74, 137..151), hiding the door from the east | (84..96, 160..172) |
| SW "Cinema" | 12..124 × 192..276 | sign scaffold 6 × 20 × 24 at (30..36, 220..240); three sawtooth skylights 8 high | (100..112, 222..234) |
| S "Sawtooth Works" | 136..264 × 192..276 | four sawtooth skylights 24 × 10 × 8; a chimney 8 × 8 × 20 at (196..204, 250..258) | (146..158, 222..234) |
| SE "Tenement" | 276..388 × 192..276 | three chimney stacks 6 × 6 × 10, coops, dishes | (350..362, 200..212) |

- **The tower** ("The Meridian"): x 136..264 × z 108..180, 48 high, unwalkable. With the four corner stacks and a
  12-wide band of façades 30–44 high round the edge, it means no view ever holds more than your own roof, the two
  next to it and their alleys.
- **Alleys** (rooms of kind `Gap`): x 124..136, x 264..276, z 96..108, z 180..192. Their floor is a scaffold deck 12
  below, wall to wall, under orange debris netting (never `Detail`: orange netting always means "safe to fall").
  Below it: black fog and a few street-lamp dots. The street cannot be reached.
- **Exit:** the skybridge door at (12, 144) into `C1_Skybridge` (the airlock, x 0..12, z 132..156).
- **Crossing:** 420–650 studs from the landing to the exit; half the ring is about 450.
- **Each roof also has** 2 AC banks (10 × 6 × 6), a tar kettle and 2–4 lit fixtures (the bulkhead lamp, a sign,
  red obstruction lamps). Bulkheads and landmarks keep 20 studs clear behind every leap strip and pad.

**Crossing between roofs** (each of the ring's eight alleys has a gantry, two fire escapes, and a plank or a leap)

| Link | Geometry | Count | Noise | The monster |
|---|---|---|---|---|
| **Gantry** (a `Yard` room) | steel bridge 6 wide, 3.5 mesh rails, at the alley's outer end | 8: G1 x 372..378 · G2 z 18..24 · G3 z 18..24 · G4 x 22..28 · G5 x 22..28 · G6 z 264..270 · G7 z 264..270 · G8 x 372..378 | walking | walks it |
| **Plank** | 3 wide, 12 long, at the inner end | 4: P1 x 288..291 · P2 z 84..87 · P3 x 109..112 · P4 z 201..204 | Walk 22 / CrouchWalk 5 | cannot |
| **Leap** (§3.1) | a 12-wide corridor with a strip and a pad on both lips, at the inner end | 4: LP1 z 78..90 · LP2 x 100..112 · LP3 z 198..210 · LP4 x 288..300 | Sprint 60, then JumpLand 26 | cannot |
| **Fire escape** (§3.1) | a stair from each roof down to the alley deck: on one side at a third of the alley's length, on the other at two thirds | 22 flights: 16 on the ring's alleys, 6 on the four alleys beside the tower | Walk 22 | cannot |

- **Why it works.** The inner link is 63–85 studs from that alley's gantry. Cross a plank or a leap and he must go
  round: 126–170 studs, 7.6–10.3 s at chase pace. Break his line of sight behind a bulkhead in that time and the
  chase ends (4 [5] s unseen is Search).
- **The quiet way** is a plank at a crouch, or the fire escapes. **The fast way** is a leap, and he hears it.
- Every parapet has openings only at links. The façade band is closed by an invisible wall.

**If you fall between buildings** you land on the alley deck: a hard landing (§3.1: 0.6 s slowed, `HardLanding` High
60, no damage). A fire escape is within 40 studs walked of every deck point. He cannot come down (no floor for him)
and cannot reach you (the deck is 12 below; his reach is 5), but he may see you and hold at the lip (§3.6) until the
chase times out, and he may be on your roof when you climb back. Alleys are the city's crawlways.

**Hiding spots (40; a hide within 30 studs walked of every roof point):** per roof one Locker `MeterCloset` set into
the bulkhead, 2 Cabinets `ACHousing`, 2 Barrels (`TarDrum` or `RainButt`). Alley decks, planks and fire escapes are
refuges, not hides: he still sees you there.

**The objective: "Power the Skybridge"** (`ObjectiveConfig` floor 4; no carried item)
```
{ floor = 4, levelId = "City1_Rooftops", id = "PowerSkybridge", title = "Objective.Floor.PowerSkybridge",
  stations = { prop = "FeederCabinet", candidate = "FeederCandidate", count = 3 },  -- 3 of 6, by run seed
  steps = { { id = "CloseFeeders", count = 3 } },
  lockStep = "CloseFeeders", lockVariant = "Keypad", holds = { CloseFeeder = 3.0 } }
```

| Step | Where | Hold | Noise | What happens |
|---|---|---|---|---|
| **CloseFeeders** 0/3 | 3 red-lit feeder cabinets ("FEEDER 1".."6"; the other three show a dead lamp) | 3.0 each | ObjectiveWork (Normal 34) at the start and each second; **ObjectiveClunk (High 110) at the cabinet on completion** | that roof's sign and bulkhead lamp come on (a scripted group: cosmetic, never the AI's light) |
| → exit | the skybridge door, W roof | — | ObjectiveClunk (High 110) at the door | its Keypad turns from "NO POWER" to open; the skybridge lights come on; the airlock gathers as today |

- **Feeder candidates and their nearest hide** (straight studs; ≤ 25 walked is validated): F1 NE, on the tank base
  (332, 57): AC housing 14.9 · F2 N, at the billboard's east leg (226, 22): tar drum 13.4 · F3 NW, on the bulkhead
  (79, 76): meter closet 9.9 · F4 SW, on the sign scaffold (37, 230): AC housing 16.6 · F5 S, on the chimney
  (200, 249): rain butt 15.0 · F6 SE, on the bulkhead (349, 206): meter closet 9.9. The exit door: AC housing 21.3.
- **Picks:** 3 of 6 from `Rng.seeded(seed, "Objective|City1_Rooftops")`, at least one of F1–F3 (the north arc) and
  one of F4–F6 (the south arc), so every run walks both sides of the ring.
- **Fair.** A clunk reaches 110 studs: he comes at 9 (InvestigateNoise) and takes 8–25 s. Each feeder has a hide
  within 25 and a player-only link within 60.
- **Co-op.** Anyone closes a feeder; two players can split the arcs; a decoy's sprint holds him a roof away.
- **Time.** Land and scan 0:40 · three feeders with the walks between 3:30 · getting away from him three times 2:30
  · to the door and the airlock 1:00.
- **Counts:** batteries 36 (4 a roof, 4 on alley decks); flask candidates 6 (roofers' solvent by the tar kettles on
  NE, N, NW, SW, S, SE).

**How he hunts outdoors** (the same brain; nothing in MONSTER.md §14 is relaxed)
- **Routes.** Roofs and gantries are his floor; alleys, planks, leaps and stairs are not (§3.6). He never leaves a
  roof's edge.
- **Hearing.** Open air has few walls: a walk still carries 22, a sprint 60, a clunk 110. Rain masks nothing for him.
- **Sight.** 20 studs in the dark, 38 in a lit pool, 70 with your torch on (× 0.75 crouched). Baked luminance stays
  ≤ 0.2 on at least 70 % of roof area; the pools are under the fixtures. Lightning never lights you for the AI.
- **Teleports** are unchanged (12–24 walked, never in view, never within 12, the warning trio). Outdoors they land on
  the roof lattice (§3.6).
- **The stare** and **HidingResponse** are unchanged.
- **Spawn hold:** 70–140 walked from the landing marks, out of sight: in practice the N, S, NW or SW roof.

**The Tall Janitor** (the same rig, host `Gus`: the rig spec asserts identical joints, metrics, hitboxes, speeds and
timings; only welded cosmetic parts and attributes differ)

| | Danny's Tall Man (the school) | Gus's Tall Janitor (the city) |
|---|---|---|
| Body | bare shadow, tatters | a torn grey jumpsuit over the shadow: collar, a chest panel with a "GUS" patch, split sleeves, legs shredded at the knee (≤ 40 parts); work boots |
| Mask | whole, one great crack | the same mask re-knit: a black seam down the middle, the halves 0.03 out of line, the left pinprick dead |
| **Keys** | — | a ring of 11 keys on his left hip (a 2-bone chain; it glints in a torch within 30) |
| Footfalls | bare, heavy | boots; the storm covers them beyond about 30 studs |
| Voice | Danny's, pitched down | Gus's gravel, saying your names (§3.4); he whistles the closet radio's tune |

- **`KeyJingle`** plays at his hip on every footfall: heard to 45 studs at a stalk and 70 in a chase, −6 dB per wall,
  never masked by the rain. It stops 0.4 s after he stops.
- **What the keys change.** You can place him by ear in the open. **Silence means he has stopped:** a stare, a watch
  on your hiding spot, a hold at a roof's lip. One clink marks each LookAway's start (with the grunt) and each
  teleport's FadeIn (after the trio). The keys are an output (I1, I3): the AI never reads them.

**Scare set pieces:** "He lands" and "The billboard" (§3.5). P1: pigeons go up when he passes a roost (an honest tell).

### 4.8 `City2_Airport` (about 7 minutes)

```
 z\x 0 12                 110             210              310      350      386 400
 12  +-+-------------------+---------------+----------------+--------+--------+-+
 24  | | HANGAR A  N714RV  | APRON NW      | APRON NE       |  YARD N         | |
     | |  [big door east]  |   mast        |    parked plane|                 | |
100  | |  switch  side door+--containers-- + --containers---+--------+        | |
120  | +-------------------+ APRON W       | APRON E        |BAGGAGE |CONCOU- | |
144  | | TAXI LANE         |  parked plane |    mast        +--------+RSE     |A|  <- entry
168  | +-------------------+               |                |SECURITY|  board | |
188  | | HANGAR B          +--containers-- + --containers---+--------+        | |
     | |  parts, tools     | APRON SW      | APRON SE       |GATE LNG|        | |
228  | |                   |  fuel shelter |    bowser      +--------+--------+ |
264  | +-------------------+               |                |  YARD S         | |
276  +-+-------------------+---------------+----------------+-----------------+-+
```

**Layout** (hand-laid; flat; y 0 = world 0 at its own origin; a fence and an invisible wall close the 12-wide edge).

| Room (kind) | Rect x × z | Notes |
|---|---|---|
| `C2_Arrivals` (Airlock, entry) | 386..400 × 132..156 | the skybridge's stair lobby |
| `C2_Concourse` (Corridor) | 350..386 × 60..228, 16 high | check-in desks (2 Cabinets `CheckInDesk`), seat rows, the split-flap board at (352, 9, 144). Doors to all three terminal rooms and to both yards |
| `C2_Baggage` / `C2_Security` / `C2_GateLounge` | 310..350 × 60..132 / 132..180 / 180..228 | joined north to south. Baggage has a roll door to Apron NE (z 84); the lounge a door to Apron SE (z 204). 3 Lockers in Security, 2 Cabinets `BaggageCart` in Baggage |
| `C2_YardN` / `C2_YardS` (Yard) | 310..386 × 12..60 / 228..276 | service yards open to the apron: the ways round the terminal |
| Apron (6 `Yard` zones) | x 110..210 and 210..310 × z 12..100, 100..188, 188..276 | wet concrete. **Container rows** 12 high and 8 wide stand along x 210 (gaps 16 wide at z 56, 144, 232) and along z 100 and z 188 (gaps at x 160 and x 260). Two lit masts (pools the AI counts as lit) at (160, 56) and (260, 144). Two tied-down planes, a bowser at (240, 200), a fuel shelter at (160..180, 252..264), 4 Cabinets `BaggageCart` (one at (228, 214)) |
| `C2_HangarA` (Hangar) | 12..110 × 24..120, 24 high | **the plane N714RV** at (60, 72), nose east. The **big door** (a `Gate`, skin `HangarDoor`, 48 × 18) in the east wall, z 48..96, shut. A side door (z 120, x 90). The **switch** at (106, 100). 3 Lockers `ToolCrib`, 2 Cabinets `ToolChest` at (44, 98) and (96, 112) |
| `C2_TaxiLane` (Yard) | 12..110 × 120..168 | between the hangars; open to Apron W; a blast fence to the west (the runway beyond is scenery) |
| `C2_HangarB` (Hangar) | 12..110 × 168..264, 24 high | a stripped fuselage, a parts cage, benches. Doors: north (x 90), a half-open roll door east (z 216). 2 Lockers, 1 Cabinet `ToolChest` at (84, 236) |

- No parkour here: this stage is cover and noise. Crossing 380–560. Hides: 28 (8 Lockers, 11 Cabinets, 9 Barrels
  `OilDrum`: 2 at the fuel shelter, one in each yard, 3 on the apron, 2 in the taxi lane); a hide or a
  container-row gap within 35 of every apron point.
- Counts: batteries 36; flask candidates 6 (de-icer: both hangars ×2, Security, the shelter); spawn hold as §4.7.
  The Tall Janitor hunts as on the rooftops (apron zones are `Yard`); his keys echo in the hangars.

**The objective: "Preflight"** (`ObjectiveConfig` floor 5)
```
{ floor = 5, levelId = "City2_Airport", id = "Preflight", title = "Objective.Floor.Preflight",
  item  = { prop = "FuelCan", candidate = "FuelCanCandidate", count = 2, hold = 0.6, object = "Prompt.FuelCan" },
  steps = { { id = "FindFuel", count = 2 }, { id = "FuelPlane", count = 2 },
            { id = "OpenHangar", count = 1, seconds = 20 }, { id = "Board", count = 1 } },
  lockStep = "Board", holds = { FuelPlane = 2.5, HangarSwitch = 2.0, Board = 0.8, StartEngines = 3.0 } }
```

| # | Step | Where | Hold | Noise | Nearest hide (straight studs) |
|---|---|---|---|---|---|
| 1 | **FindFuel** 0/2 (red jerry cans) | 2 of 10: the fuel shelter ×3 · Hangar B ×3 · the bowser · Baggage · Yard S · Yard N | 0.6 | — | shelter: oil drums 14 · Hangar B: tool cribs and chest ≤ 22.4 · bowser: baggage cart 18.4 · Baggage: cart 17.9 · yards: drum 15.6 |
| 2 | **FuelPlane** 0/2 | the wing filler (60, 84) | 2.5 each | ObjectiveWork (Normal 34) at the start and each second | tool chest 21.3 |
| 3 | **OpenHangar** | the switch (106, 100); locked ("Fuel her first") until 2/2 | 2.0, then 20 s | `MotorStart` (Critical 130) at the door, then `MotorRun` (Normal 90) every 4 s; teleports blocked | tool chest 15.6 |
| 4 | **Board** | the cabin door (56, 78), once the big door is open ("N714RV READY") | 0.8 each | the first boarding: ObjectiveClunk (High 110) at the plane | tool chest 23.3 |
| → | **START** | the pilot's seat | 3.0 | `EngineStart` (Critical 170) | — |

**Boarding (1–4 players).**
- Four seats. The first aboard takes the left front seat and flies. P1: "Swap seats".
- A seated player is `ignored` by the brain (§3.6): the cabin is safe, and the pressure is on whoever is still
  outside.
- The first boarding starts the airlock's 20 s straggler clock. START unlocks when every Alive player is aboard or
  the clock ends, and fires by itself 10 s after that.
- A Downed player may crawl aboard (hold 2 s) and is stood up in the seat. Players who are dead, spectating or left
  behind are in their seats when the takeoff starts (the checkpoint rule): **everybody flies**.
- **Time.** Orient and scan 0:30 · two cans 2:30 · to Hangar A and fuel 1:20 · the door 0:25 · boarding 0:30 ·
  hiding 1:45.

### 4.9 `Runway`: "Wheels Up" (the playable takeoff; about 45 s)

**Sequence.** START (3.0 s hold) → a 3 s spin-up in the hangar → a 6 s scripted taxi in two cuts to the threshold,
during which he bursts out of the terminal behind you → **t = 0** on the `Runway` set: a strip 60 wide and 1,500
long, edge lights blue, centre-line lights white, every obstacle under a red beacon. He is Scripted throughout.

| | Keyboard | Gamepad | Touch |
|---|---|---|---|
| Steer | A / D or ← / → | left stick | ◀ ▶ pads, bottom left (110 px each) |
| Pull up | hold Space or S | hold A | hold PULL UP, bottom right (130 px) |
| Look round (passengers; the pilot too) | mouse; V looks back | right stick; R3 | drag; LOOK BACK |

**The rules** (`Shared/Rules/TakeoffRules.luau` and `TakeoffConfig`, on the 30 Hz tick; s is distance down the
runway, v speed, x the offset from the centre line)

| Rule | Value |
|---|---|
| Speed | the throttle is locked open: +2.5 studs/s² up to 70 |
| Rotate | from v ≥ 60 the HUD shouts "PULL UP!": holding it for 1.0 s lifts off. Held early, it starts counting at 60 (each tick that starts at v ≥ 60 counts; v gains its 2.5 first, then s gains v) |
| Steering | x moves at up to 16 studs/s (a 0.25 s ramp), within ±25. The plane's hit box is 10 wide |
| Obstacle rows | at s = 70, 150, 250, 360, 470, 580, 800, 910, 1,020, 1,130, 1,240, 1,350: baggage carts, a stalled bowser, barriers, a parked wing. Each row leaves one gap 22 wide, centred at x = −18, 0 or +18; the next gap is at most 18 aside. Three authored patterns, picked by run seed; rows 1 and 2 always block the centre |
| Seeing them | red beacons and the lights are unfogged emissive (I10), visible from 200 studs: at least 2.9 s ahead at top speed |
| A knock | v becomes max(0.6 v, v − 8 [v − 10]), with a jolt and sparks. Never the end by itself |
| **He chases** (t 0–16) | he runs at 22 from 126 [118] studs behind the tail. If the gap reaches 4 he tears the tail off |
| **He stands ahead** (s = 690) | when you pass s = 450: the teleport trio (runway lights stutter, the hiss in the cockpit, the landing light stutters), then lightning shows him on the centre line, covering the centre gap. Pass on either side; the next row's gap (s = 800) is always in the centre. Hit him: a knock, and half thrust for 2 s while he hangs on the wing |
| The end of the runway | s = 1,450. Not airborne by then: the plane ploughs through the fence |

**The table `takeoff-bot` asserts** (simulated on the tick; identical at 20, 60 and 144 fps and on every tier)

| Run | Standard | Nightmare |
|---|---|---|
| Clean | wheels up at **25.0 s, 782 studs**; his closest is 29.6 studs at 8.8 s | the same lift-off; closest 21.6 |
| Row 1 hit | closest 8.6 (he rakes the rudder); up at 28.0 s, 828 | caught at 10.1 s |
| Rows 1 and 2 hit, or no steering at all | caught at 13.0 s | caught |
| Any 3 knocks that do not include both rows 1 and 2 | always airborne, by 1,365 at the latest | — |
| Any 2 knocks that do not include row 1 | airborne by 1,184 | always airborne, by 1,274 |
| Hitting only him | up at 29.2 s, 1,010 | 30.0 s, 1,048 |
| Never pulling up | off the end at 34.7 s | the same |
| Pulling up 6 s late | still up, at 1,191 | the same |

- **Why a clean run always lifts off.** It needs steering of at most 18 studs between rows (1.4 s; the tightest pair
  of rows is 1.57 s apart at top speed) and one 1.0 s hold. Each row is in sight before the one before it is passed.
  Speed, gap and knocks are functions of ticks. 22 studs/s is allowed only here; this table is its proof (I4).
- **What a mistake costs.** A knock is about 3.2 s of acceleration: 45–230 studs more runway. Early knocks let him
  reach the tail; late ones eat the runway.
- **HUD.** A SPEED bar with the 60 mark; a RUNWAY bar; "HE'S 30 m BEHIND" for the first 16 s; knock pips; the PULL UP
  cue. No radar.
- **Failing.** Tail torn off, or off the end: a 1.2 s fade, "Again.", and the line-up 5 s later. Attempts follow
  §3.3: 3 [2] free, then each costs a squad respawn; with none left, "THE NIGHT TOOK YOU". Nobody is Downed here.
- **Co-op.** The pilot's page simulates the rules and sends `{s, v, x}` every tick. The authority checks the speed
  profile and |x| ≤ 25, and resolves every row and his stand from the reported x. Passengers ride and look; if the
  pilot leaves, the next seat flies. Roblox: the pilot's client simulates; the server validates with the same module.

### 4.10 Endings, results and saves

| | **Sunrise** | **The Fall** (Ending B) | Out of lives |
|---|---|---|---|
| Title | SUNRISE | THE FALL | THE NIGHT TOOK YOU |
| Card | sand-coloured, the only bright card. "You got out." · "Danny Reyes · 2010–2026" | black. "The school kept you." · "Walter couldn't either. There is another way this night ends." | as today |
| Chapter strip | 8 / 8 | 4 / 8, the rest as locked silhouettes | the stage reached |
| Stats | time (Basement activation → wheels up), survivors n/N, downs, respawns used, radar scans, Last Run tries, takeoff tries and knocks, the shooter, the pilot | time, downs, Last Run tries | as today |
| Credits (× 1.5 on Nightmare) | 20 × 6 stages + **150** escape + **50** the first time | 20 × 3 + **25** the first time | 20 × stages cleared |

- "Stages cleared" counts the six levels only. At Sunrise everyone aboard is Escaped; in The Fall everyone is
  Taken; a player who left the session is Dead.
- **Saved** (web `profile.js`, schema + 1 with a migration; Roblox `MatchAndDataService`, schema + 1): `IntroSeen`,
  `TwistSeen`, `EndingsSeen {Fall, Sunrise}`, `BestTimeSunrise`, `SpeakName` (web), the first-time hint flags
  (Hurdle, Slide, Leap, Radar, GetUp, Revolver, Takeoff), and the settings of §3.4. `Escapes` stays as an alias of
  `EndingsSeen.Sunrise` for old saves. The web join packet carries `IntroSeen`, `TwistSeen` and `EndingsSeen`.

---

## 5. Art direction, performance and sound

### 5.1 The rule of the look
- **Every stage is dark, cold, gray and scary.** No warm light anywhere before the Bahamas.
- **Two accents only.** **Red** means threat or locked: emergency lamps, lock lights, obstacle beacons on the runway.
  **Cold white** means help: guidance beacons, chevrons, arrows, battery LEDs, EXIT signs (their green goes).
- **Green** exists in two places: the radar on the HUD, and the airport beacon (the goal you can see from the roofs).
- **No black-and-white checkerboard floors anywhere.** `Finishes` drops its checker rule and `SurfaceArt.checker`;
  the `CheckerTile` texture and the `CheckerLight` key are retired.
- **The gate:** on three reference views per school stage, at Max and at Potato, the mean HSV saturation of the frame
  is ≤ 0.15; no palette key a school layout uses has saturation above 0.25, the red accent aside.

### 5.2 Per stage (RGB; "was" values are today's `Palette` and `LightingMood`)

| Stage | Surfaces | Lights and air |
|---|---|---|
| **Basement** | red `Brick` (was 92, 56, 44) → `BlockGray`, painted concrete block (70, 72, 74). `ConcreteStained` (74, 72, 60) → (68, 70, 72). `PipeCopper` (112, 82, 58) → `PipeLead` (84, 86, 88). `MetalRust` (98, 70, 50) → mill scale (76, 74, 72). `WoodPanel` → (62, 60, 58). The regions' red, yellow, blue and green mains become dark iron (58, 60, 62) with a 0.5-stud band in the old hue at 30 % saturation, so regions still read | bulbs (255, 196, 140) → cold white (206, 220, 232). Level cast (236, 200, 136) → (196, 206, 220). Haze colour (62, 50, 36) → (40, 44, 50). The orange boiler glow (255, 118, 40) → small blue pilot flames (120, 170, 255). Emergency reds stay |
| **Hallways** | corridors: `VinylGray` (88, 90, 92), plain worn sheet vinyl with a darker traffic lane (wear paint). `PlasterGreen` (82, 98, 80) → `PlasterAsh` (104, 106, 108). `WainscotOxblood` (92, 44, 40) → `WainscotSlate` (58, 62, 66). Classroom vinyl → speckled gray (110, 112, 112) | the sick-green cast (168, 236, 196) → cold fluorescent (200, 214, 226). Haze (42, 52, 48) → (42, 46, 50) |
| **Auditorium** | curtains and seats charcoal (48, 46, 50) with a tenth of wine; stage boards (70, 66, 62); walls `PlasterAsh`; backstage block gray | aisle lights cold white; the ghost light a bare cold bulb; the beam white; cast (200, 210, 226); haze (40, 44, 52) |
| **Roof** | wet slate (52, 54, 58), zinc (96, 100, 104), mesh and duct in galvanized gray | clock faces bone white (220, 226, 232); white strobes; cold lightning; rain |
| **Back Lot** | asphalt (40, 40, 42), the gray block façade, galvanized bins | day: flat overcast (`dayAmount` 0.65); night: the one cold lamp and the red strobe |
| **Rooftops** | tar (30, 32, 34), zinc, soot brick (60, 56, 54), dead neon tubes, orange netting in the alleys (the one warm colour, and it means "safe") | 97 % of windows dark; three signs flicker ice blue (150, 200, 255); the cloud's underside a teal gray (44, 52, 58); the airport beacon sweeps white and green on the western sky |
| **Airport** | wet concrete (72, 76, 80) with worn white paint; galvanized hangars (112, 118, 120); containers in four grays; the plane white (210, 214, 218) with a faded teal stripe (70, 120, 124) so it reads in the dark | blue taxiway edge lights (60, 110, 255); white runway lights; red obstruction lamps; two cold masts |
| **Bahamas** | sea turquoise (64, 196, 196); sand (236, 214, 170); palms (46, 120, 70); a sky from blue (120, 190, 255) to cream (255, 236, 200) | a gold sun (255, 214, 140); `dayAmount` 1; saturation +0.15; exposure +0.6 EV. The only stage with a positive saturation |

- **Film.** Every stage but the Bahamas grades to saturation ≤ −0.35 with a cold tint (232, 238, 245).
- **Textures.** Colour maps that carry their own hue (`RustedMetal`, `StainedConcrete`, `WornWood`) are regenerated
  or desaturated so the palette's gray is what shows at Max; Low and Potato already show the plain palette colour.
- **`dayAmount`** is one uniform for the three sets: it adds `dayAmount × (ambient + sun × max(N·L, 0))`, unshadowed,
  to every material (Roblox: the same number drives `ClockTime`, `Brightness` and `Ambient`). Under the Bahamas'
  palms and plane, blob shadows are dark discs.
- **Darkness you can still read.** On every tier the torch (range 40) shows a 3.2-stud object at 20 studs: its mean
  screen luminance is ≥ 0.08 and at least twice its background (a screenshot check).

### 5.3 What Potato shows for the new visuals (collision, queries and information never change)

| Visual | Max | Potato |
|---|---|---|
| Rain | streak particles and a screen layer | one screen-space streak quad |
| Lightning | a sky flash and a light | the light only (scaled by `FlashScale` on every tier) |
| The film and the split-flap board | canvas at 512 × 192; per-flap animation | canvas at 256 × 96; three flap frames; the same text and timing |
| The mask's crack, drop and the crawler | `raceCracks`, 20 shards, sculpted legs | `raceCracks`, 8 shards, the same legs |
| Smashed fixtures | 6–10 debris parts (`Detail` 2) | the fixture's 2-part `Smashed` node |
| City skyline | 12 cards with a few lit windows (`Detail` 1) | the solid façades alone |
| Alley netting, leap paint, beacons, runway lights | emissive, unfogged | the same (I10) |
| The sea | scrolling normal map | flat colour with a white shore line |

### 5.4 Performance budgets for the outdoor stages (Potato must hold 60 fps)

| Potato budget | Rooftops | Airport | Runway | Bahamas | Roof | Back Lot |
|---|---|---|---|---|---|---|
| Triangles in the worst view | ≤ 160k | ≤ 150k | ≤ 60k | ≤ 30k | ≤ 120k | ≤ 80k |
| Draw calls | ≤ 60 | ≤ 60 | ≤ 40 | ≤ 20 | ≤ 50 | ≤ 40 |
| Zones a zone may see (PVS) | ≤ 14 (mean ≤ 10) | ≤ 14 | — | — | ≤ 8 | — |
| Fixtures lit (the tier's 10 nearest, unshadowed) | 10 of ≤ 60 | 10 of ≤ 80 | 1 (the landing light) | 0 | 10 of ≤ 40 | 2 |
| Whole stage baked (triangles) / Roblox parts | ≤ 350k / ≤ 9,000 | ≤ 300k / ≤ 8,000 | ≤ 60k / ≤ 1,200 | ≤ 30k / ≤ 600 | ≤ 200k / ≤ 5,000 | ≤ 80k / ≤ 1,200 |
| Frame time at 4× CPU throttle | median ≤ 10 ms, worst ≤ 16.7 ms, on every column | | | | | |

How the layouts meet them:
- **Own origins.** Each city stage and each set is its own level far from the others, so level culling never draws
  two. On Roblox, which holds the whole world, the three cut floors free about 35,500 static parts (the counts in
  ARCHITECTURE.md), and the new stages are budgeted at 36,000 in all (the Auditorium at ≤ 11,000).
- **Occlusion.** On the rooftops the central tower, the corner stacks, the façade band, the bulkheads and the
  billboard hold the PVS at ≤ 14 zones a view. On the apron the 12-high container rows do the same. The roof course
  is a fenced S: from any point you see two legs of it.
- **Haze closes at 120 studs on every tier** on both city stages and the roof (the level's own value equals
  Potato's), so a Potato player sees exactly as far as a Max player. Beyond it: one black street plane and the
  skyline.
- **Cheap surfaces.** Outdoor faces bake at 8–16 studs a quad. Interiors are only the terminal's four rooms and two
  hangars. At most 12 palette materials a stage. At least 35 % of each city stage's triangles are `Detail`.
- **No particles on Potato;** rain is one quad; lightning is a uniform. **The runway** is a strip with instanced
  lights and at most 3 obstacle rows in view.
- **The gate** (`npm run check`): perf places on the landing roof, the N roof facing the billboard, Apron E, the
  runway at 60 studs/s, the roof course's §4 and the belfry, on Potato and Max, plus a Roblox MicroProfiler pass in
  RP08.

### 5.5 New sounds (synthesized on both platforms; no sound files)
Each sound has a preset id, a bus, a caption key and a web recipe written by the package that needs it; the Roblox
port mirrors the envelope numbers in `SynthPresets`, and RP08 runs an A/B listening checklist.

| Sound | Where | Character |
|---|---|---|
| `KeyJingle` | the Tall Janitor's hip, every footfall | 3–5 bright metal ticks, 2.4–6 kHz, 120 ms, random spread; 3D |
| `Snore`, `RadioTune` (and his whistle) | Gus's closet; the city | a 0.9 s filtered-noise inhale and a sag; five slow notes (A4, C5, E5, D5, A4), band-passed 400–3,000 Hz |
| `RadarPing`, `RadarEmpty` | the player | a soft two-tone ping at 1,320 and 1,760 Hz; a dry relay click |
| `LampStrike`, `FilmScore`, `ProjectorRun` | the booth, the speaker point | an arc crack; a crackly, wobbling string loop; a 24 Hz sprocket chatter |
| `BellToll`, `ShutterSlam`, `RevolverShot`, `MaskClatter` | the roof | a struck partial stack on 110 Hz with an 8 s tail; a steel slam; a dry crack with a 0.3 s tail; two tumbling clacks |
| `CrawlerClick`, `MusicBoxTick` | cutscenes | porcelain ticks at 3–7 kHz; one plucked high note |
| `SlideScrape`, `LeapWhoosh`, `HardLanding` | the player | grit noise for 0.7 s; wind for 0.6 s; a body thud and a grunt |
| `MotorStart`, `MotorRun`, `EngineStart`, `EngineLoop`, `PlaneKnock`, `TailTear` | the hangar, the plane | a relay and a rising whine; a chain rumble; a starter, then two radials at 38 Hz; a metal bang; rending sheet metal |
| `TinRoofImpact`, `CarAlarm`, `FlapBoard`, `PhoneRing` | set pieces | a boom on sheet metal; a two-tone alarm; a clatter of plastic flaps; a mechanical bell at 20 Hz |
| `Surf`, `Gulls`, `SunriseChord` | the Bahamas | slow filtered noise; three cries; a D major chord, the game's first |

---

## 6. Removals (both platforms; `Removal.spec` and `data-test` fail on any leftover)

| Area | Removed |
|---|---|
| Science Hall | `Level2_ScienceHall` (layout, level script and controller, the BurnChain objective), `FumeHoodBuilder`, `AcidFlaskBuilder`, reagents and the acid flask, the Chain exit lock, `flasksScienceHall` |
| Gym | `Level3_Gymnasium` (layout, level script and controller, the GymGenerator objective), `GeneratorBuilder`, the coach's key, the locker search, the store lock and door, the gym's beats |
| Pool | `Level4_FloodedPool`, `PoolWaterBuilder`, `FloodedPoolService`, `SwimController`, `StruggleController`, web `pool.js`, creature `water.js` and `states/aquatic.js`, AquaticStalk, `Util/WaterRules`, `LayoutSchema`'s Basin type, `TunnelRules.underWater`, `ObjectivePlaces`' pool helpers (DryFooting, ClimbBand, swimToDry), the swim and underwater MoveStates and CameraStates, oxygen and its meter, the struggle, the Treading / Freestyle / Splash noises and the Water medium, the Swim hitbox and eye, the valve wheel, `HatchValveBuilder`, `FloodlightSwitchBuilder`, `flasksPool` |
| Old roof | the maze cells, the bolt cutters and the CutCrate objective (`CrateChain`, the crate lock), the roof's `Cover` hide kind, the pace-by-gap final sprint, the Finale / FinaleSky / Touchdown scenes, the landing field, "fall without a pack" |
| Kept from the old roof | the stair housings, the RoofDoor smash scene, `parachute.js` / `ParachuteService` / `ParachuteMotion`, the pack crate (re-skinned), the look-back camera, the ledge staging |
| Tab hint | `NudgeDelay`, `NudgeCooldown`, the room nudge, the GOAL button (it becomes RADAR) |
| Syringe | its button, the `Syringe` input action, the stamina use, the solo self-revive (the get-up replaces it) |
| Ids | `Level2_ScienceHall`, `Level3_Gymnasium`, `Level4_FloodedPool`, `Level5_Roof`, `Stairwell_3_4*`, `Stairwell_4_5*`, every `L4_` and `L5_` room, anchor and door id |
| Strings, hints, docs | the pool, swim, reagent, gym, crate and Tab-hint strings; the hints `Water`, `ObjHatchValve`, `ObjCrateChain`; DevTools commands for the pool and the old finale; `docs/store/STORE.md`'s pool and crate bullets; the thumbnails `thumb-3-pool` and `thumb-5-roof` |
| Specs and tools | `Pool.spec`, `Parachute.spec`'s crate cases, the pool and maze parts of `Roof.spec`, `Layouts.spec` and `PropsHideAndEscape.spec`; the web tools' pool checks; `playtest.mjs` swim actions |

New DevTools commands on both platforms: go to a stage, set film time, set the chaser's gap, force the shot or
Ending B, start the takeoff, trigger a scare id, add radar charges, set respawns.

**Contracts WP01 adds** (each also listed where it is used)
- `LevelId`: `Level2_Auditorium`, `Level3_Roof`, `City1_Rooftops`, `City2_Airport`. `SetId`: `BackLot`, `Runway`,
  `Bahamas`. Match phase `Prologue`.
- `RoomKind`: Foyer, Auditorium, Stage, Dressing, Tower, Hangar, Yard, Gap. `Gate` skins: BrickFlat, HangarDoor,
  MeshGate, Shutter. `HideSkin` values (§3.6). Collision groups `CreatureBlock`, `Traversing`.
- `AnchorKind`: FilmReelCandidate, Projector, SpeakerPoint, GhostLight, CourseNode, LeapStrip, RevolverLockbox,
  JumpKit, FeederCandidate, FuelCanCandidate, WingFiller, HangarSwitch, CabinDoor, Seat, LandingMark, CutsceneMark,
  BinStart, WallPhone, Billboard, FlapBoard. `TriggerKind`: GatherZone, Shutter, FallZone, ChuteHatch, JumpGate.
- `MoveState`: Sliding (eye as Crouching), Leaping (eye from the curve), Seated (eye 1.2 over the root).
  `CameraState`: Cinematic, Cockpit, LookBack. `InputContext`: Revolver, Cockpit, Seat.
- Input actions: Radar (was Objective), LookBack, Skip, Fire, LowerGun, Steer, PullUp.
- `NoiseKind`: Slide (High 60), HardLanding (High 60), LampStrike (Critical 130), FilmScore (Normal 90),
  ProjectorRun (Normal 30), MotorStart (Critical 130), MotorRun (Normal 90), EngineStart (Critical 170).
- Prompt kinds: PushLid, ClimbIn, WakeHim, AnswerPhone, ThreadReel, StrikeLamp, GetUp, OpenLockbox, TakeRevolver,
  PickUpRevolver, CloseFeeder, FuelPlane, HangarSwitch, Board, StartEngines.

---

## 7. Work packages

**Rules for every package**
- One package is what one agent builds and tests in one sitting (60–90 minutes). Sizes: S, M, L. All are P0 unless
  marked P1.
- Platforms: **World** (the shared Luau builder: maps, props, rigs, and the pure rule modules it validates with),
  **Web**, **Roblox**, **Tests**.
- A package is done when its own tests pass and the standing gates stay green (§8.1).
- **Pure rules** live in Luau under `Shared/Rules` and `Shared/Config` with a `golden()` table, written by the
  package named as owner; the JS port is written by the Web package that uses it. A Web package may own such Luau
  files: they are inert on Roblox until the port.
- **So that parallel packages own different files:** WP01 makes the export generic (any `Shared/Config` or
  `Shared/Rules` module with `exportMeta()` lands in `meta.<name>`; goldens land in `build/cache/golden.json`),
  declares every new enum, tag, attribute, prompt kind, input action and setting, and registers an empty stub for
  every new prop builder. WP02 does the same for the web: stub systems, `strings/<package>.js`, `coop/events.js`.
- **Co-op is not a separate package:** every Web package ships its own co-op messages and a two-page case.
- **Roblox is parked** from WP01 (its runtime specs are tagged `port-pending`; `rojo build`, `luau-lsp` and selene
  stay green) and unparked by RP01.
- **Order:** WP01 → {WP02, WP03, WP05, WP06, WP07, WP08} → {WP04, WP11} → {WP09, WP10, WP12} → {WP13, WP14} → WP15 →
  WP16. The game is playable end to end, through stubs, after WP02.

### 7.1 The website (16 packages: 6 World, 9 Web, 1 Tests)

**WP01 · World · Stage scheme, cuts and contracts** · depends on: none · L · P0
- *Owns:* `Shared/Config/{StageConfig, WorldConfig, ObjectiveConfig, DifficultyConfig, GameConfig, TutorialConfig,
  InputConfig, SettingsSchema, ParkourConfig, RadarConfig, LivesConfig}`; `Shared/Rules/{LivesRules, RadarRules,
  ParkourRules}`; `Shared/{Enums, Tags, Attributes, CollisionGroups, Strings, Types}`; `World/RunDirector`;
  `ProceduralWorldBuilder/{LayoutSchema, ZoneGraph, TunnelRules, ObjectivePlaces, Props/init}` and the room shells in
  `SchoolShellBuilder`; `Layouts/Level2_Auditorium` (a stub floor) and `Layouts/Level3_Roof` (today's roof,
  renamed); every layout, prop builder, Roblox service, controller and spec that §6 deletes;
  `web/tools/export-world.luau`.
- *Delivers:* the stage order and id scheme (§0.1, §4.2) with elevations 0 / 18 / 34 / 64 and three stair pairs;
  the six objective specs as data; the `Yard` and `Gap` room kinds (a Gap's floor `drop`, no Creature floor,
  `CreatureBlock` at its openings) and `Gate` skins; the three pure rule modules with goldens; RunDirector's
  battery, flask and feeder picks with their placement rules; every §6 removal on the Luau side; all new contract
  entries and builder stubs; the generic export; the Roblox runtime parked but building.
- *Tests:* `tools/verify.sh` green; `Removal.spec`; `StageConfig.spec` (order, keys, dense floors 0..5);
  `Layouts.spec` on a fixture with Yard, Gap and a hidden Gate; `LivesRules`, `RadarRules` and `ParkourRules` specs
  against their goldens; `RunDirector.spec` on 16 seeds per stage (§3.2's battery rules, flask counts, feeder
  arcs); export, bake and `data-test` pass on the four-level school.

**WP02 · Web · Run structure and lives** · depends on: WP01 · L · P0
- *Owns:* `web/src/game/{config.js, game.js, match.js, life.js, start.js, profile.js, strings/}`;
  `game/mechanics/airlock.js`; `game/levels/` (renames, and stubs for level2, city1, city2 and runway);
  `game/objectives/{index.js, config.js}` and the deleted floor scripts; the deleted `mechanics/pool.js`,
  `creature/water.js` and `creature/states/aquatic.js`; `game/ui/{results.js, lives.js}`;
  `game/coop/{events.js, run.js}`; `game/creatureApi.js`; `engine/{world.js, config.js}`;
  `web/tools/{game-smoke.mjs, lives-test.mjs}`.
- *Delivers:* the run driven by `StageConfig` from the lobby to the results, with a stub (card, fade, skip) for
  every stage not built yet; `levelAt` by box; the fade after the skybridge airlock; stage cards and the chapter
  strip; every web-side removal; lives (§3.3): per-stage downs, get-up, respawn with the monster moved and the
  grace, the passive syringe, squad attempts, the HUD pips; the co-op message registry; a creature event feed
  (state changes, LookAway, the ReachIn's schedule, sniff and teleport warnings, stuns) and a `setHost()` stub for
  the voice, scare and city packages; every new input, setting and string namespace declared.
- *Tests:* `lives-test.mjs` (the `LivesRules` golden; get-up timing on both difficulties; a respawn is ≥ 70 walked
  from the monster and ignored for 10 [6] s; attempts spend squad respawns in order; the checkpoint return);
  `game-smoke` runs lobby → every stage or stub → results on both difficulties; `creature-sim` soaks without the
  pool; a two-page case (down, get-up, respawn, checkpoint); `tier-parity`.

**WP03 · World · Gray look, school content and the Back Lot** · depends on: WP01 · L · P0
- *Owns:* `ProceduralWorldBuilder/{Palette, Finishes, SurfaceArt, LightingMood, MaterialLibrary, ExtraAnchors}`;
  `Layouts/{Level0_Basement, Level1_Hallways}`; `Props/{MopCartBuilder, WallPhoneBuilder, JanitorCotBuilder,
  BackLotBuilder}`; the exterior in `SchoolShellBuilder` (the lot, façade doors, window cards);
  `Shared/Config/CastConfig.luau`; `tools/textures` recolours; `GrayLook.spec`, `ExtraAnchors.spec`, `BackLot.spec`.
- *Delivers:* §5.1–5.2 for the school, the roof and the lot (no checker anywhere); 36 battery and 8 flask
  candidates on both floors through the post-plan pass; Gus's closet, signs, six mop carts and the moved key hooks
  (§4.3); the wall phone and the chute mouth; the Back Lot set with bins, marks, hatch, lamp and scripted light
  groups (§4.1); the graffiti text (§2.8); Danny's and Gus's costumes and the crawler's numbers in `CastConfig`.
- *Tests:* `GrayLook.spec` (the palette saturation rule; no checker SurfaceGui or texture reference);
  `ExtraAnchors.spec` (counts; the two floors' rooms, doors and zone graph keep their hash; 14 key candidates, none
  in the closet, all west of the gate, a hide within 25 of each); `BackLot.spec` (fence closed, a mark per slot,
  the hatch 25–45 studs from every bin); `data-test`; `npm run check` screenshots meet the saturation gate at Max
  and Potato.

**WP04 · Web · Player kit: fixed-tick physics, slide, leap, radar** · depends on: WP02 · L · P0
- *Owns:* `engine/{physics.js, player.js, loop.js, camera.js}`; `game/mechanics/{slide.js, leap.js, batteries.js}`;
  `game/rules/{parkour.js, radar.js}`; `game/ui/{radar.js, objectives.js}`; `game/objectives/base.js` (the
  `radarTargets()` hook); `game/worldData.js` (battery, flask and station picks); `web/tools/{parkour-test.mjs,
  radar-test.mjs}`.
- *Delivers:* the body on the 30 Hz tick with two substeps and render interpolation (§3.1); `Sliding`; the sampled
  leap with its approach band, buffer, coyote time and assist; hard landings; look-back; the radar (§3.2) with
  charges, the arrival floor, markers, the empty-press sheet and the shared scan; battery LEDs; the Tab nudge
  deleted.
- *Tests:* `parkour-test.mjs` (tick-sampled positions identical at 20, 30, 60 and 144 fps to 1e-6; apex 2.50 ±
  0.02; a 2.6 hurdle mounts and a 5.5 wall never does; the longest free jump is recorded and under 10; the leap
  curve equals the Luau golden; early, on-time and late presses; no leap under 15 studs/s or beyond 35°; the 5-ray
  pad test); `radar-test.mjs` (charges, the floor, refusals, targets per step, never the monster, one scan on two
  pages); `data-test` replays battery and flask plans for 16 seeds; `tier-parity`, `creature-sim` and `game-smoke`
  stay green.

**WP05 · World · The Auditorium** · depends on: WP01 · L · P0
- *Owns:* `Layouts/Level2_Auditorium.luau`; `Props/{TheatreBuilder, SeatingBuilder, ProjectorBuilder}`;
  `Shared/Config/FilmSpec.luau`; `Auditorium.spec`, `FilmSpec.spec`.
- *Delivers:* §4.4's plan, keep-rooms, seats, tunnels and regions; the projectors, 12 reel candidates, screen,
  ghost light, curtain, brick flat and hidden `Gate`; 22 keep-room hides with their skins; the light groups; the
  film's cards; 36 battery and 6 flask candidates; the floor's seed.
- *Tests:* `Auditorium.spec` (the x 342 barrier is crossed only by the hidden door; every theatre room has ≥ 2
  exits; a hide within 25 walked of all 12 reel candidates, both projectors, the hidden door and the three exits;
  none within 20 of the speaker point; crossing 650–1,000; seat slabs are `MonsterPassthrough`); every
  `TunnelPlanner.spec` rule; `FilmSpec.spec` (cards tile 0–60 s; text ≤ 64 characters); `data-test`; ≤ 11,000
  parts.

**WP06 · World · The roof: course, bell tower and props** · depends on: WP01 · L · P0
- *Owns:* `Layouts/Level3_Roof.luau` (rewritten); `World/ChaseCourse.luau`; `Shared/Rules/{ChaseRules,
  EndingRules}.luau`; `Shared/Config/{ChaseConfig, EndingConfig}.luau`; `Props/{CourseBuilder, BellTowerBuilder,
  RevolverBuilder, JumpKitBuilder}`; `RoofCourse.spec`, `ChaseRules.spec`, `EndingRules.spec`.
- *Delivers:* the pens, practice fixtures, gates, fenced course, hurdles and bars with `Smashed` nodes, both wells
  with stairs, strips and pads (§4.5); the tower's stair, belfry, bell, clock faces, hatch, shutter, blockers,
  lockbox, revolver, jump kit and jump gate (§4.6); `meta.chaseCourse` with clean-time coordinates; both pure
  modules with goldens.
- *Tests:* `RoofCourse.spec` (connected from all three pens to the shutter; every fixture inside its
  `ParkourConfig` band; the 5-ray pad test from 20 studs back at eye 4.4; each well has a forward stair; no edge
  leaves the building; belfry blockers 9 high); `ChaseRules.spec` (every row of §4.5's table on 3 arrivals × 2
  difficulties; speed ≤ 21.3 [21.9]; only the quarry is caught; a mid-pack faller never gets a clean runner
  caught); `EndingRules.spec` (window 13.5 [10.0]; margins per input; blocked, late, flick and rejected shots);
  ≤ 5,000 parts.

**WP07 · World · Rooftops and the janitor skin** · depends on: WP01 · L · P0
- *Owns:* `Layouts/City1_Rooftops.luau`; `World/OutdoorRules.luau`; `Props/{RooftopBuilder, GantryBuilder,
  FireEscapeBuilder, FeederBuilder, MaskHalvesBuilder}`; `CreatureRigBuilder` (host `Gus`); `Rooftops.spec`; the
  `CreatureRig.spec` additions.
- *Delivers:* §4.7's eight roofs, tower, corner stacks, façade band, netted alley decks, 8 gantries, 4 planks, 4
  leap corridors, 22 fire-escape flights, 40 hides, 6 feeder cabinets, the billboard, the skybridge airlock,
  landing marks, patrol loops and spawns; the Tall Janitor's parts, key ring and mask-seam attributes; the
  `MaskHalves` prop.
- *Tests:* `Rooftops.spec` through `OutdoorRules` (each zone sees ≤ 14 zones; a hide within 30 walked of every
  roof point and 25 of every feeder and the exit; every roof has two gantries and a player-only link; every
  walkable gap is 12 wide; a stair within 40 of every deck point; the street unreachable; a fixture within 32 of
  every land spot; crossing 420–650); `CreatureRig.spec` (host Gus keeps every joint, metric and hitbox; ≤ 40
  added parts, none colliding); `data-test`; ≤ 9,000 parts and ≤ 350k baked triangles.

**WP08 · World · Airport, plane, runway and Bahamas** · depends on: WP01 · L · P0
- *Owns:* `Layouts/City2_Airport.luau`; `Props/{AirportBuilder, PlaneBuilder, RunwayBuilder, BahamasBuilder}`;
  `Shared/Rules/TakeoffRules.luau`; `Shared/Config/TakeoffConfig.luau`; `Airport.spec`, `TakeoffRules.spec`.
- *Delivers:* §4.8's terminal, yards, apron with container rows and masts, both hangars, the big door, the fuel
  shelter, 10 can candidates, 28 hides and the split-flap board; the plane (four seats, cabin door, wing filler,
  props, gear); the `Runway` set with lights, three obstacle patterns and his stand mark; the `Bahamas` set (strip,
  beach, sea, 6 palms, the post); `TakeoffRules` with its golden.
- *Tests:* `Airport.spec` through `OutdoorRules` (a hide within 25 walked of every can candidate, the wing, the
  switch and the cabin door; zones see ≤ 14; crossing 380–560; a hide or a row gap within 35 of every apron
  point); `TakeoffRules.spec` (every row of §4.9's table; in all three patterns every gap is 22 wide and adjacent
  gaps are ≤ 18 apart; rows 1 and 2 block the centre); `data-test`; §5.4's part and triangle budgets.

**WP09 · Web · Auditorium runtime and the school's scares** · depends on: WP04, WP05 · L · P0
- *Owns:* `game/levels/{level2.js, level0.js}`; `game/objectives/{steps.js, floor2.js}`; `game/mechanics/film.js`;
  `game/story/scares.js`; `Shared/Rules/ScareRules.luau`; `game/rules/scares.js`; `creature/` changes for
  MONSTER.md §6.7, §7.1, §7.2 (7) and §8.2; `web/tools/{auditorium-test.mjs, scare-soak.mjs}`.
- *Delivers:* generic objective steps (find, deliver, work, survive, stations) that floors 2, 4 and 5 use;
  Showtime with the film canvas, beam, reveal and hidden door (§4.4); the Curtain Call; the scare gate (§3.5) and
  the Basement phone; the four monster amendments.
- *Tests:* `auditorium-test.mjs` (a bot plays Showtime on four seeds in 6–9 min; teleports blocked from strike to
  reveal; the hidden door shut to players and nav before 70.5 s; a hider near the monster is not shoved; the
  Curtain Call's reveal and its silent paths; no warp destination east of x 342 before the reveal; the film clock
  in step on two pages); `scare-soak.mjs` (30 simulated minutes: each set piece once, the gate's rules, no
  NoiseKind emitted); the `ScareRules` golden.

**WP10 · Web · The Last Run** · depends on: WP04, WP06 · L · P0
- *Owns:* `game/levels/level3.js`; `game/mechanics/chase.js`; `game/rules/chase.js`; `game/objectives/floor3.js`;
  `game/ui/chaseHud.js`; `web/tools/roof-chase-bot.mjs`.
- *Delivers:* the pen, practice hints, gather and gate scene; adrenaline; the chase director on `ChaseRules` with
  progress, quarry, Loom, catches with lag compensation, `Smashed` fixtures and lightning cues; attempts, wipes
  and the reset list; the shutter, the tower climb and caught runners standing up inside; the tries HUD.
- *Tests:* `roof-chase-bot.mjs` on the real engine (clean, bump, slow-bar, faller, well-camper and idle bots × 3
  arrivals × 2 difficulties × 20, 60 and 144 fps × Max and Potato: outcomes equal the `ChaseRules` golden and gap
  traces agree within 0.02 s; a four-bot run where only the straggler is caught; a mid-pack faller; attempt 2
  repeats attempt 1; a catch decided correctly at 250 ms of injected latency); the scenario replay log equals the
  Luau one.

**WP11 · Web · Cinematics, the opening and the prologue** · depends on: WP02, WP03 · L · P0
- *Owns:* `game/story/{cinematics.js, actors.js, opening.js, prologue.js, skipVote.js}`;
  `Shared/Sequence/CinematicTracks.luau`; `Shared/Config/StoryConfig.luau`; `Shared/Rules/NameSanitizer.luau`;
  `game/rules/names.js`; `engine/audio/tts.js`; `game/ui/{subtitles.js, namePrompt.js}`;
  `engine/{materials.js, renderer.js}` (`dayAmount`); `game/coop/avatars.js` (costumes and clips);
  `web/tools/story-test.mjs`.
- *Delivers:* the cutscene player (§2.3) with letterbox, cuts, actor tracks, events, rig swaps, skip votes and
  Short cuts; costumed actors and the mask crawler; the title-screen name prompt and the sanitizer; speech and
  subtitles as primitives; the opening's two cuts (§2.4); the prologue (§4.1) into the Basement.
- *Tests:* `story-test.mjs` (hand-over at 78.0 s Full and 26.0 s Short; every line fits its slot and none
  overlap; the vote matrix 1/1, 1/2, 2/3, 2/4, 3/4 with and without first-timers; a bin per slot; per-page
  `{you}`; the auto climb-out at 20 s; the chute's 30 s rule; the run clock starts at Basement activation; I13
  throughout; `CinematicTracks` and `NameSanitizer` goldens; actor positions identical at 20 and 144 fps; two
  pages within one tick).

**WP12 · Web · The talking monster** · depends on: WP11 · L · P0
- *Owns:* `game/story/voice.js`; `game/rules/voice.js`; `Shared/Rules/VoiceRules.luau`;
  `Shared/Config/VoiceConfig.luau`; `engine/audio/voice.js`; `web/tools/voice-soak.mjs`.
- *Delivers:* the ten categories and both hosts' lines (§3.4); the director with caps, bags, name odds and leads;
  the Head, Ear, Spot and Device channels with the shared gain curve and wall filter; the throat layer and the
  fallback; per-recipient composition in co-op; the settings.
- *Tests:* `voice-soak.mjs` (30 simulated minutes on three stages: no overlap; gaps ≥ 8 s, or 3 s for event lines;
  ≤ 4 per 60 s; bags never repeat before empty; Ready exactly 3.0 s before every timed ReachIn and never before a
  breath-check one; the first line waits for a chase or a teleport; a mean rate of one per 35–60 s; "says names"
  Off leaves no name in any utterance; Ear and Head direction error ≤ 5°; the gain golden; the scenario replay
  log equals the Luau one; each of two pages hears its own name).

**WP13 · Web · The standoff, the endings, the twist and the jump** · depends on: WP07, WP10, WP11 · L · P0
- *Owns:* `game/mechanics/{revolver.js, parachute.js}`; `game/story/{standoff.js, endings.js, twist.js,
  aftermath.js}`; `game/rules/ending.js`; `game/ui/revolverHud.js`; `creature/{look.js, mask.js}` (host Gus, the
  seam, the mask's drop); `web/tools/ending-test.mjs`.
- *Delivers:* the lockbox and revolver with the Revolver input context on three devices; T_s and the standoff
  timeline; the hit test and its authority rules; Ending A with the placement rule; the twist (Full and Short);
  the aftermath to the sweep; packs for everyone; the hand-over onto the landing roof; Ending B and its results
  card.
- *Tests:* `ending-test.mjs` (a hit at t 5 gives Ending A; no shot gives contact at 15.5 ± 0.05 [12.0]; a lowered
  gun and a clear miss give B; a blocked shot keeps the round; a last-moment shot at 200 ms latency and a flick
  shot are accepted; an idle holder drops it and a teammate fires; a holder who leaves; a straggler on the stair
  is lifted; twist lengths 21.0 s and 8.0 s; nobody can be caught from T to touchdown; the sweep at C + 20 leaves
  no one behind; each slot lands on its mark; Rooftops activates at the first touchdown; saves written).

**WP14 · Web · The city stages** · depends on: WP07, WP08, WP09 · L · P0
- *Owns:* `game/levels/{city1.js, city2.js}`; `game/objectives/{floor4.js, floor5.js}`;
  `game/mechanics/{falls.js, boarding.js, keys.js}`; `creature/{nav.js, locomotion.js, states/teleport.js}` (Yard,
  Gap, the edge clamp, the lip hold); `web/tools/city-test.mjs`.
- *Delivers:* both city objectives on the generic steps (feeders with their lights; cans, wing, hangar door,
  boarding); the Tall Janitor switch and `KeyJingle`; MONSTER.md's §5, §7.2, §9 and §10 amendments; "He lands",
  the billboard and the board; seated players ignored; the straggler clock and START.
- *Tests:* `city-test.mjs` (bots finish Rooftops and Airport on four seeds each in 6–9 min at walking pace; in a
  30-minute soak per stage the monster never leaves walkable rooms, never crosses a player-only link, never
  exceeds 18.5, teleports only onto the lattice with a warned fixture, and holds at the lip for a target in an
  alley; a fall never damages and makes `HardLanding`; the keys sound only at his position and stop 0.4 s after
  he does; set pieces fire once, inside the gate; boarding with 1–4 players, a Downed player and a straggler; two
  pages).

**WP15 · Web · Wheels Up and Sunrise** · depends on: WP11, WP14 · L · P0
- *Owns:* `game/levels/runway.js`; `game/mechanics/takeoff.js`; `game/rules/takeoff.js`; `game/story/sunrise.js`;
  `game/ui/{takeoffHud.js, resultsSunrise.js}`; `web/tools/takeoff-bot.mjs`.
- *Delivers:* the spin-up and taxi cuts; the takeoff on `TakeoffRules` with keyboard, gamepad and touch controls,
  the HUD, obstacle rows, his chase and his stand; pilot authority with validation and seat hand-over; fails and
  attempts; the Sunrise cutscene (§2.7); the Sunrise results card, credits and saves.
- *Tests:* `takeoff-bot.mjs` (every row of §4.9's table × 2 difficulties × 20, 60 and 144 fps × Max and Potato,
  equal to the golden to the tick; one steering trace gives one outcome from keyboard, gamepad and touch; a pilot
  who leaves; a failure beyond the free attempts spends a respawn, and ends the run with none left; the scenario
  replay log equals the Luau one; Sunrise runs 44.0 s; results fields and saves).

**WP16 · Tests · Release gate** · depends on: WP09, WP12, WP13, WP15 · L · P0
- *Owns:* `web/tools/{full-run.mjs, coop-soak.mjs}` and the new cases in `check.mjs`, `tier-parity.mjs` and
  `playtest.mjs`; `docs/` (a new `STORY.md`; `MONSTER.md`, `MONSTER-LOOK.md`, `MAPS.md` and `ARCHITECTURE.md`
  updated); `web/DATA.md`; `site/beta/`.
- *Delivers:* the full-run bots; the four-page soak; the perf, gray-look and torch gates; the docs; the beta build.
- *Tests:* `full-run.mjs` (title → Sunrise on both difficulties; a second run → The Fall; a third → out of lives;
  45 ± 8 min at bot pace); `coop-soak.mjs` (four pages, a full run, one page throttled to 20 fps with 250 ms of
  latency: the same stage outcomes on every page); `tier-parity` on all six levels and both chases; `npm run
  check` with §5.4's places and budgets, the saturation gate and the torch gate; `playtest.mjs` for 30 minutes per
  stage with no stuck spot or softlock; `data-test` and `Removal.spec` clean.

### 7.2 The Roblox port (8 packages, after WP16; all Roblox, L, P0; the shared Luau rules, configs and world exist)

| Id · title | Depends on | Owns | Delivers | Tests |
|---|---|---|---|---|
| **RP01** · Foundations: flow, lives, radar | WP16 | `RunLifecycleService`, `LevelDirector`, `CheckpointAirlockService`, `LifeStateService`, `DownedReviveService`, `LoadoutService`, `FlashlightService`, `MatchAndDataService`, `Levels/init`, the HUD's lives, radar and stage cards, and their specs | the runtime unparked; the `StageConfig` flow with the fade transition and stubs; lives; radar; saves and results | one Lune spec per service against the shared goldens; the server lifecycle spec runs every stage or stub on both difficulties |
| **RP02** · Movement and the monster's rule changes | RP01 | `PlayerStateService` (Sliding), `Gameplay/LeapController`, `Mechanics/LeapService`, `MovementAuthority`, `CollisionService` (`Traversing`, `CreatureBlock`), `MonsterAIService` (§3.6), `CreatureController` (host Gus, the keys) | slide and leap with server validation; the Humanoid's measured envelope in `ParkourConfig.RobloxEnvelope`; every MONSTER.md amendment; rule distances on the shared walk graph; the Tall Janitor | `Movement.spec` (leap window checks, the exemption, no mid-arc correction, the slide profile); an envelope run in Studio or Open Cloud asserting I9's margins; `MonsterDeltas.spec` on shared fixtures (the same seed and positions give the web's decisions) |
| **RP03** · Story presentation and the opening | RP01 | `Match/CinematicController`, `Story/StoryService`, `NpcRigBuilder`, `MaskCrawlerRigBuilder`, the name filter, `HUD/Subtitles` | the cutscene player on `CinematicTracks`; actors from `CastConfig` and avatar clones; the crawler; the opening, the prologue and skip votes | `StoryService.spec` (the vote matrix, gathers, timeouts, phases); `CinematicTracks` goldens; a Studio checklist that every line's `TimeLength` fits its slot |
| **RP04** · The talking monster | RP03 | `Story/VoiceDirectorService`, `Core/VoiceController`, `Shared/Audio/VoiceTTS` | the director on `VoiceRules`; the `AudioTextToSpeech` chain, the growl bed on the same emitter, a per-wall EQ table, the fallback; `TextService` filtering; the settings | `VoiceDirectorService.spec` (the soak; per-recipient text; the filter mocked; the scenario replay log equals the web's) |
| **RP05** · Stage controllers: Auditorium, Rooftops, Airport | RP02 | `ObjectiveService` (generic steps), `Level2_AuditoriumController`, `City1_RooftopsController`, `City2_AirportController`, `Gameplay/FilmController`, `Story/ScareService`, `Mechanics/BoardingService` | the three objectives; the film on a SurfaceGui; the Curtain Call; the set pieces; falls; boarding | `Objectives.spec` per stage; `ScareService.spec`; lifecycle bots finish each stage |
| **RP06** · The Last Run | RP02 | `Level3_RoofController` (the pen, gate, chase director, shutter and tower) | §4.5 on `ChaseRules`, with lag compensation and attempts | `RoofChase.spec` (the scenario replay equals the web's event log; four bots; the reset list) |
| **RP07** · The standoff, the endings, the twist and the jump | RP03, RP06 | `Mechanics/RevolverService`, `Gameplay/RevolverController`, `Match/EndingController`, `ParachuteService` (the hand-over) | §4.6 and §2.5–2.6 | `Standoff.spec` (every `EndingRules` case and the authority tolerances); `Aftermath.spec` (I13, the sweep, the landing marks) |
| **RP08** · Wheels Up, Sunrise and the parity gate | RP04, RP05, RP07 | `Mechanics/TakeoffService`, `Gameplay/TakeoffController`, the Sunrise scene and results; the `GraphicsTiers.spec` additions; `publish.yml` | the takeoff with pilot validation; Sunrise; results; the cross-platform gate (§8.3); the publish | `Takeoff.spec` (§4.9's table); scenario replays for the chase, takeoff, voice and scare directors equal the web's logs; run-plan goldens for every stage; `GraphicsTiers.spec` on the new levels; §5.4's part budgets; the A/B sound checklist; a MicroProfiler pass at Potato settings |

### 7.3 P1 packages (only if budget remains; website first, each with a Roblox twin of the same size)

| Id | Title | Platform | Depends on | Size | Owns · delivers · tests |
|---|---|---|---|---|---|
| P1-01 | Notes, Journal and Memories | Web | WP16 | M | `game/story/notes.js`, `Shared/Config/LoreConfig.luau`, `ui/journal.js` · v1's notes with fixed anchors, the reader, the Journal, replays of seen cutscenes · `notes-test` (ids valid; a fixed note has one anchor; reading is no noise) |
| P1-02 | The dread layer | Web | WP16 | M | `engine/lighting.js` additions, `engine/audio/score.js` · presence dimming per light group, score stems, StareBuild, tinnitus · `scare-soak` cases (dimming is per group on both platforms; never the teleport tell) |
| P1-03 | Presence AI | Web | WP16 | L | `creature/states/{peek, shadow, glimpse}.js`, MONSTER.md §16 · Peek, Shadow, Glimpse (each with its own placement band), vantage holds, habit memory · `creature-sim` cases per mode |
| P1-04 | Theatre extras | Web | WP16 | L | `mechanics/film.js` additions, `Props/{MannequinBuilder, DrapeBuilder}` · the changeover, the silhouette card, mannequins, the Drape kind, claps and bow · `auditorium-test` cases |
| P1-05 | Flourishes and voice extras | Web | WP16 | M | `mechanics/{vault.js, mirror.js}`, `VoiceConfig` additions · vault and mantle animations, the collapse, pigeons, the cockpit mirror, lures, Memory lines, the PA scare, the key sting · `parkour-test` and `voice-soak` cases |

---

## 8. Test plan and gates

### 8.1 Standing gates (every package keeps them green)
- **Luau:** `tools/verify.sh`: project files, `rojo build`, `luau-lsp` strict, selene, stylua, capscan, the Lune
  layouts, world build and specs. During the web phase the Roblox runtime specs tagged `port-pending` are skipped;
  RP01 removes the tag.
- **Web** (with a baked world): `data-test`, `npm run check`, `tier-parity`, `creature-sim`, `game-smoke`,
  `objective-run` (Basement, Hallways), `coop-test`, `net-test`. A test is never weakened to pass; a changed
  golden changes the Luau module and its JS port in the same package.

### 8.2 Which test asserts which invariant

| Invariant | Asserted by |
|---|---|
| I1 honest audio | `voice-soak` (anchor direction), `city-test` (keys only at his position), `scare-soak` (no set piece plays a monster sound) |
| I2 teleport tell | `creature-sim` (every teleport warned), `takeoff-bot` and `ending-test` (the trio before his stand and before the standoff), `scare-soak` (the billboard never hisses) |
| I3 cosmetic | `scare-soak` (no NoiseKind), `auditorium-test` (curtain, film and scripted lights change no decision), `tier-parity` |
| I4 chases | `ChaseRules.spec`, `roof-chase-bot`, `TakeoffRules.spec`, `takeoff-bot`, `city-test` (≤ 18.5; falls never damage), `parkour-test` (5 rays) |
| I5 standoff | `EndingRules.spec`, `ending-test` |
| I6 one source | `data-test` (every mirrored key equal) |
| I7 authority | the two-page case in every web tool; one Lune spec per Roblox service (validators, rate limits, phases) |
| I8 ticks | `parkour-test`, `story-test`, `roof-chase-bot`, `takeoff-bot` at 20, 60 and 144 fps; `tier-parity` |
| I9 envelope | `RoofCourse.spec`, `Rooftops.spec`, `parkour-test`, RP02's envelope run |
| I10 tiers and guidance | `GraphicsTiers.spec`; `npm run check` screenshots at Potato with `FlashScale` 0 (every strip, pad, beacon and marker visible) |
| I11 pure rules | each `*Rules.spec`, the JS golden checks in `data-test`, the scenario replays |
| I12 content | a review checklist in WP16 (no blood decal or texture; one revolver; both endings' cuts) and the Roblox maturity questionnaire in RP08 |
| I13 safe moments | `story-test`, `ending-test`, `lives-test`, `city-test` (seated players) |
| I14 fair objectives | `ExtraAnchors.spec`, `Auditorium.spec`, `Rooftops.spec`, `Airport.spec`; `full-run` once with the radar disabled |
| I15 radar | `radar-test` |
| I16 ids | `Removal.spec`, `StageConfig.spec`, `data-test` |

### 8.3 Cross-platform parity (the port's gate, RP08)
- **Goldens:** every pure module passes the same JSON in Luau and in JS.
- **Scenario replays:** per-tick input traces recorded from the web bots (positions, looks, events) are fed to the
  Luau chase, takeoff, voice and scare directors under Lune; the event logs (catch ticks, lift-off tick, line ids,
  scare ids) are identical.
- **Run plans:** RunDirector's picks for 16 seeds per stage match pick for pick (items, stations, batteries, flasks,
  exits).
- **Movement:** the Humanoid's measured envelope keeps I9's margins; a slide covers 10.5 ± 0.5 studs.
- **World and look:** one builder gives one world (as today); §5.4's part budgets; the gray gate on Roblox
  screenshots; the sound A/B checklist; every scripted line's `TimeLength` fits its slot.

### 8.4 Release numbers
- A bot's full run takes 45 ± 8 min; each sneaking stage 6–9 min at walking pace on four seeds. Potato holds
  §5.4: median ≤ 10 ms and worst ≤ 16.7 ms at 4× CPU throttle at every perf place.
- Mean saturation ≤ 0.15 on the school's reference views; the torch gate passes on every tier.
- Placement rules hold on 16 seeds per stage. Soaks of 30 simulated minutes per stage end with no NaN, no stuck
  state, no softlock.
- Bots reach Sunrise, The Fall and the out-of-lives screen, solo and with four pages.

---

## Appendix A. What happened to the 173 critique points
Numbers are positions in `finale-critiques.json`, counted from 1 (1–37 are critic 2, 38–173 critic 1).

### A.1 Rejected

| # | The critique asked for | Why not |
|---|---|---|
| 10 | a Roblox prerequisite gate (old brain, locker-only hiding, stamina 16, agent height 8) | out of date: the parity port (f51ac3e) already ships the MONSTER.md brain, `HideSpotService`, stamina 7 and agent height 9; RP02 checks its decisions against shared fixtures instead |
| 9, 78 | the plank as a railed, sampled move | planks are now 3 wide, plain walking, and never on a timed or required path; a rail adds a move for no fairness gain |
| 109 | a `PrologueSeen` flag and a second skip vote | the prologue is a 25-stud walk with its own timers; there is nothing to skip |
| 125 (part) | a definition of "Whisper only" | the mode is cut; two voice modes remain |
| 135 | a shared sway function with goldens, and torch steadying | sway leaves the hit test (the shot is the camera's centre ray); steadying is cut |
| 138 | a placement solver for Ending A | one clamp rule on an open deck does it, now that the bell frame stands on corner posts |
| 153 | full layer recipes for every new sound in the spec | too long here: §5.5 fixes character and key numbers, the owning package writes the recipe, RP08 runs an A/B check |
| 170 (part) | scenario replays for the dread director | the dread budget is cut to a pure gate; replays cover the chase, takeoff, voice and scare directors |

### A.2 Dropped: the content is removed, or waits as P1
- Tiers, catwalks, the rake, the trap room, ladders, the seat speed zone: 16, 18, 45–48, 51–54, 56, 64, 65, 74.
- The changeover, the booth alert, the noise-refresh rule, the silhouette card: 15, 36, 59, 62, 67, and 60's
  restrike half.
- Mannequins, vantage holds, Peek, Shadow, Glimpse, habit memory, presence dimming: 19, 21, 24, 71, 72, 75, 148,
  154, 156–159.
- The clock-face climb, the mast, the collapse, drops and pitched roofs on the old course: 33, 84, 85, 93, 94, 96.
- The Back Lot tutorial, the lure, the wall silhouette: 100, 106, 107. Sampled vault and crawl-under: 80.
- Notes and Memories: 111–113, and 114's note picks.
- The dread budget, the locker cascade, tinnitus, StareBuild, score stems: 145, 146, 149, 151, 152.

### A.3 Resolved, and where

| Critiques | Where |
|---|---|
| 1, 76 · 3 · 4, 87, 89 · 14 · 83 · 86, 88 · 90, 91, 92 · 37, 131 | §4.5: the gather zone · adrenaline · quarry and single lane · lag · the course · the rule and its table · resets, catches, cues · the objective |
| 5, 30, 97, 133, 134 · 6, 137 · 13, 141 · 28 · 132 · 136 | §4.6: the open deck, blockers, stop distances, lunge cap · shot authority · T_s and the hatch · the idle holder · the lockbox · the Revolver context |
| 2, 81, 82 · 8, 29, 171 · 12 · 32, 95 · 77 · 79 · 27 | §3.1: the leap's band and buffer · fixed-tick body, envelope, RP02 · the Roblox leap · never blind · slide bars · the consumed press · no Ctrl, no Space or B for Skip |
| 7 · 11 · 17 · 160 · 20 | §3.6: the stay limit · the walk graph · reachable destinations · no new actions · the one view definition (Conventions) |
| 22, 116–124, 126–130 · 125 · 34 | §3.4: Ready, leads, channels, names, bags, gain, platform layers, rate · subtitles · web volume and slots |
| 23, 144, 147, 150, 161 | §3.5: no noise from scares, the gate, stingers, each set piece's trigger and text |
| 31 · 35, 68, 69 · 49, 50, 57, 58, 73 · 55, 70 · 61, 63, 66 · 26 · 60 (part) | §4.4: seats · the Curtain Call · the plan, ports, counts, hidden door, reach numbers · curtain and light groups · reveal, reels, film format · the beam · the locked strike |
| 98, 99, 101, 102, 104, 105, 108, 110, 172 · 103 · 44 · 162 | §2.3, §2.4, §4.1: slots, the data contract, cast, phases, timeouts, replays, joiners · §2.5 the mask · §2.1 · flash and motion |
| 38, 39, 42, 43 · 25, 40, 41 · 173 | §1 (I2, I4, I11, I6) · I10 and §5.3 · §5.4 |
| 115 · 167 · 139, 140, 142, 143 · 114 (part) | §4.2 `ExtraAnchors` · `levelAt` · §2.6, §3.3, §4.10 · the join packet |
| 155 · 163–166 · 168, 169 · 170 | §5.2 the torch gate · §6 · §7.2 · I11 and §8.3 |

---

## Spec amendments (made while building; newest last)
- 3.1 (WP04a, measured): the web's step-up is about 1.9, not 1.6 (a probe reach of exactly StepHeight let the body walk through a block a little higher than a step), so a standing jump mounts 4.4, not 4.1. Hurdles (2.4 to 2.8) and walls (5.5) keep their margins. The longest free jump is 8.2 on the level, 8.6 onto a landing 2 lower.
- 3.3 (lead, Nov 10): respawns are 1 per stage on Standard and 1 per run on Nightmare, plus the syringe's one per run.
- 4.5 (rules batch, simulated by `ChaseRules`): the chaser's rule text made exact where it was open (ρ read from the gap at the start of each tick; the projection's hysteresis favours the next segment and never goes back; a fall sets progress back to e, the only decrease; the Loom counts 8 [6] s over that quarry; each corner's 0.15 s spread over ±2 studs, each bar's over the bar; the table's scenarios defined in its caption). No rule number changed.
- 4.5 (rules batch): Clean's floor 1.56 [1.16] → 1.58 [1.17] (the dip is the projection reaching each corner 1.5 studs early); Nightmare's clean gap settles after 8.0 s (added).
- 4.5 (rules batch): one bumped hurdle 1.11 [0.67] → 1.16 [0.73]; one bar crouch-walked 0.85 [0.39] → 0.90 [0.45].
- 4.5 (rules batch): longest single stall survived 1.50 s [0.97 s] → 1.57 s, 47 ticks [1.00 s, 30 ticks].
- 4.5 (rules batch): two bumps 2 s apart 0.88 [0.31] → 0.94 [0.37]; a bump then a slow bar 3 s later 0.76 → 0.82 (Nightmare still caught); two slow bars 3 s apart 0.46 → 0.52 (Nightmare still caught).
- 4.5 (rules batch): standing at the gate, caught at 2.4 s [2.0 s] → 2.5 s [2.1 s] (2.53 [2.13]: the gap must close to 0.25 at the hold rate, then 3 ticks).
- 4.5 (rules batch): the fall-then-slow-bar row now states its dip, 0.52 [0.33], and a Margins note gives every row's slack; Nightmare's double mistakes sit 2 to 3 ticks from the catch line by design, so no rule number was changed for them.
- 4.6 (rules batch): Nightmare's time scale is exactly 10.0 / 13.5 (0.7407); 0.741 gave a 10.0035 s window. A miss whose ray meets the world within 60 counts as blocked (round kept).
- 4.9 (rules batch, simulated by `TakeoffRules`): the clean run's closest approach is at 8.8 s, not 8.7 s (29.6 [21.6] studs unchanged).
- 4.9 (rules batch): rows 1 and 2 hit, or no steering, is caught at 13.0 s (12.97), not 12.9 s.
- 4.9 (rules batch): the rotate rule made exact (a tick that starts at v ≥ 60 counts; v gains before s); with it every other entry of the table reproduces: 25.0 s / 782, 28.0 s / 828, 10.1 s, 1,365, 1,184 [1,274], 29.2 s / 1,010 [30.0 s / 1,048], 34.7 s, 1,191.
- 2.3 (WP01b): the gamepad's Skip is Y on both platforms, not Start: Roblox keeps Start for its own menu (Space and B stay out, as the spec wants).
- 3.2 (WP01b): the battery placement's walks are all on the walk graph (the 30-stud pair spacing too), and a dead end is a room with fewer than two ways in or out (doors, crawlway mouths, open grates).
- 7 (WP01b): WP01 registers no empty prop builder stubs; `Props/init` finds every builder module in its folder (name order), so a package adds its builder's file and nothing else.
- 4.4 (WP05): the Auditorium's crawlway reach is 100 (measured 92.9), not the default 60: with the 4–8 crawlways 4.4 allows, a floor whose tunnels ring a 246 × 144 theatre (about 1,950 studs of tunnel to reach every port, fold the Box Office and serve the dock) cannot keep a culvert within 60; eight keep one within 100, and the theatre's 22 keep-room hides are the floor's refuge.
- 4.4 (WP05): the ghost light's stand stands at (243, 7, 141), 4.2 studs downstage of the Curtain Call's mark (246, 0, 144): the table put the light and the mark on one point, which would stand the stand inside the Creature. Its pool still holds the mark.
- 4.4 (WP05): the projection ports are glazed frames on both faces of the booth's east wall (4 wide, y 6.5..8), not openings cut in it (a layout window is a facade's); the beam starts at each projector's BeamOrigin and the port's PortCenter.
- 4.4 (WP05): the hidden door carries no ScriptedId (the bake types every scripted Gate as the hallway's gate); both runtimes find it by its DoorId, `L2_Door_Hidden`; the flat over it is its own model, `Flat_L2_Door_Hidden`, with no DoorId (entity ids stay unique). Its grille mounts on the loading dock's face; the flat covers the opening on the scene dock's.
- 4.4 (WP05): the route's fairness (RunDirector.routeChecks) walks the hidden door open (the squad leaves after the film), as the crossing does; item and hide walks keep it shut.
- 4.4 (WP05): the Curtain Call's three release points are `CutsceneMark` anchors `L2_Release_1..3` whose `ref` names the planner's PatrolWaypoint; the mark is `CutsceneMark` `L2_Mark_CurtainCall` at (246, 5, 144). A patrol hop the planner walks straight through the house or the stage gets a waypoint in the room's middle (no two waypoints more than 140 walked apart).
- 3.3 (WP02b): the get-up's hold is Interact while Downed; InputConfig's Interact lists no Downed context (on Roblox the GetUp prompt reads its key itself), so the website's input adds Downed to Interact's live contexts and no other prompt answers a Downed or dead player.
- 3.3 (WP02b): the shop text is the spec's "One more chance." on the website; Strings.luau's `Perk.AdrenalineSyringe.Desc` ("One more chance for the run.") takes it on the port.
- 4.10 (WP02b): out of lives the title is "THE NIGHT TOOK YOU" (web `Results.Night`); Strings.luau's `Results.Wiped` ("THE SCHOOL KEPT YOU") takes it on the port.
- 4.10 (WP02b): the credits of 4.10 (150 for the escape, 50 the first time, x1.5 on Nightmare) are in no shared config yet (I6), so the website keeps today's reward, GameConfig's CreditsPerLevelCleared per level cleared (the roof counts at its touchdown) + CreditsEscapeBonus on an escape, until a config carries them.
- 4.10 (WP02b): profile schema 2 drops v1's BestTime (it timed the four-level school); EndingsSeen.Sunrise is set from Escapes on migration; BestTimeSunrise starts empty.
- 3.1 (WP04b): a `LeapStrip` anchor stands at the near lip's centre on the strip's floor, its LookVector the leap direction; the strip runs StripLength back from it, the gap and the pad beyond; its `Width` attribute is the strip's width across the leap (Street.Min, a leap corridor's 12, when it names none). The spec named the anchor kind but not its frame.
- 3.1 (WP04b): the look-back turns over the left shoulder (the spec names no side); the slide steers toward the move input's heading (yaw and stick), at most SteerRate; the hard landing's camera dip scales with MotionScale.
- 3.2 (WP04b): a radar item marker reads "<ITEM> i/n" with i its place among the open step's picked items (FUSE 1/3 .. 3/3); a station marker is named by its entity's first prompt (BREAKER PANEL, STAIRWELL DOOR); a teammate's scan pings at that teammate's last pose on the other pages.
- 5.1/5.2 (WP03a): a light's colour sets the baked light the monster and the hide rules read, so every cold white is scaled to the linear luminance of the warm "was" colour it replaces (basement bulbs: layout (201, 203, 205), cast (181, 183, 184), not (206, 220, 232)), and the whites are barely cold (saturation about 0.01): at Potato, which drops the film's desaturation, 5.2's (206, 220, 232) casts and a blue ambient left every reference frame at 0.18 to 0.33 mean saturation. The rig's ambient fills turn near-neutral at the same luminance (Ambient (27, 27, 28), OutdoorAmbient (48, 49, 52)) and every haze colour drops to saturation <= 0.13 ((40, 44, 50) is 0.2) for the same reason.
- 5.2 (WP03a): the boiler's pilot flame keeps its blue (120, 170, 255) on the flame itself (the `Ember` part); the BoilerGlow light it throws is a near-white (155, 156, 157), as bright as the orange it replaces: a blue light of that reach floods the whole boiler room blue (0.33 saturation).
- 5.1 (WP03a): the palette rule's exemptions, besides the red accent, are named in `GrayLook.spec`: `HazardYellow` (the hazard plates at the fire doors and the gate), `Ember` (the pilot flame, a light) and `BusPaint` (the lobby's bus); the lobby, before the Bahamas, goes cold too.
- 5.1 (WP03a): the screenshot gate counts a pixel's saturation only from value 0.04 (about 10/255) up; below it the 8-bit channels cannot carry a hue (one count of blue in a 3/255 pixel reads as 33 %). Its three reference views per stage are walkways lit by the stage's own fixtures: a frame filled by an emergency lamp's red pool (the Basement's lit pipe gallery: 0.17 at Max, 0.22 at Potato) measures the red accent 5.1 keeps, not the grade. The palette keys 5.2 does not name are near-neutral grays (channels within 2 of each other): the ACES toe and the film's contrast multiply a gray's own tint several times over in the darks, so (56, 58, 60) walls read blue at 0.2.
- 5.2 (WP03a): the gray look keeps each view's brightness through the film's exposure: Basement 0.05 -> 0.15 EV, Hallways 0.08 -> 0.15, Auditorium 0.10 -> 0.26 (the cold tint and the lost white checker squares darkened the frames 5 to 13 %); the Roblox renders follow (0.70, 0.70, 0.81).
- 5.2 (WP03a): the textures keep their base-layer albedo (`reference`), so TextureAssets stays valid: a colour map keeps only its manifest `chroma` share (0.06 to 0.3) of its own hue around that base layer. Roblox's uploaded maps are the old ones until the Textures workflow re-uploads changed maps (it never does today).
- 4.1 (WP03b): the bins stand 10 studs nearer the facade than the table: Dumpster A (10, 324), the skip (34, 328), the wheelie bin (48, 326), Dumpster B (22, 330), the lamp (28, 320) and the DISCARD boxes with them. At the table's places every bin is 48 to 50 studs from the hatch, outside the 25 to 45 the prologue's walk asks for; now 37.7 to 40.3.
- 4.1 (WP03b): the set's box (`WorldConfig.Sets.BackLot`, what levelAt reads) is x -1..81, y 16..50, z 288..351 (from the facade's line). The staff doors' shutter is built down and the window cards dark (the prologue's state); the opening's scenes light the windows, the lamp and the strobe through their scripted groups (`Scripted:BL_Windows_1`, `_2`, `Scripted:BL_Lamp`, `Scripted:BL_Strobe`). The marks are `CutsceneMark` anchors `BL_Mark_Origin`, `_StaffDoors`, `_Danny`, `_Gate`, `_Lamp`, `_Hatch`, `_HatchInside` and the Basement's `L0_Mark_ChuteMouth`; the bins' `BinStart` anchors are `BL_BinStart_1..4` (attribute Slot).
- 4.3 (WP03b): two anchor kinds are added, `MopCart` and `JanitorCot` (the contracts named the props, not their anchors). A cart's key hook or flask spot names its cart in `ref`; the "Wake him" prompt, the snore (Attachment `Snore`) and the radio (Attachment `Radio`) ride the `JanitorCot` fixture.
- 4.3 (WP03b): the closet's door sign hangs on the corridor wall beside the door, not on the door: the leaf is a runtime fixture that swings.
- 3.2 / 4.2 (WP03b): `ExtraAnchors` also drops a planned BatteryCandidate that stands in a dead end or within 32 studs walked of one kept, so every pair of the 36 is at least 32 apart and the four placement rules hold on every seed, not only the 16 checked.
- 4.2 / 4.3 (WP03b): the tunnel niche shelves are shelves over the drum of a barrel hide niche, 6.1 high (every niche already holds a hide or an item; a lower shelf would cross the drum's lid); the boiler room's shelf is a wall shelf. `CleaningShelfBuilder` builds both.
- 4.3 (WP03b): the carts' WET FLOOR boards use `HazardYellow`, as the school's other WET FLOOR A-frames do.
- 4.6 (WP06): the belfry is the top of `L3_BellTower`, one Tower room over the tower's footprint x 4..40 × z 70..106 (its walls to the deck at 32, the room 52 high to the bell frame, open above): layout rooms cannot stack, so there is no `L3_Belfry` room. A runtime tells the belfry by height (deck 32, world 96); `meta.chaseCourse.tower` gives its rect, deck, marks and set pieces. The inside is 5.5..38.5 × 71.5..104.5 (the shell's walls and BellTowerBuilder's lining).
- 4.6 (WP06): the hatch is x 32.5..38.5 × z 95..104.5 (centre (35.5, 99.75), mark `L3_Mark_Hatch`), over the stair's top flight, not at (34, 100): the stair climbs the south, west, north and east walls (four flights of eight, a walkway and a corner landing between them) so the shutter's entrance in the east wall stays clear, and its last flight ends in the south-east corner.
- 4.5 (WP06): the pens' gates and the shutter are layout Doorways (8 wide; 11 wide and 9.7 high) whose leaves and curtain are fixtures (`Gate_<slot>`, `Shutter`): a layout Gate counts shut for the solvability proof, and the roof has no way round them. The jump gate is a gap in the belfry's west parapet (fixture `JumpGate`, its `Blocker` up to 9 over the deck until C); a railed jump ledge runs out from it past the facade so a jumper leaves clear of the roof below.
- 4.5 (WP06): each well is one Gap room 12 along the lane and 20 across (the well over the lane and its 8-wide alcove); its stair is nine 1.25 treads with the landing's edge as the tenth 1.0 riser (12 studs of alcove cannot hold ten 1.25 treads). The landing beside the pad is its own room (`L3_Landing1/2`).
- 4.5 (WP06): the deck off the course is Solid (no zone, nobody stands there): its 3.5 wall is the lane's curb and the 8-high chain-link or duct wall stands on it; the lane's rooms have no walls of their own. The roof has no patrol waypoints, batteries, corpses or parachute crate: the crate is the jump kit (ParachuteBuilder keeps the pack and the rigs).
- 3.1 (WP06): a built slide bar stands solid from 4.2 to 10.0 (at least 9.7 with room for the float-rounded top), the tower's shutter curtain from 4.2 into its hood.
- 4.8 (WP08): the apron rule counts as a refuge every hide and every way out of an apron cell (its container-row gaps, its openings onto the yards and the taxi lane, the doors of the buildings on it; never the shut big door), and the stage has 37 hides, not 28 (8 lockers, 16 cabinets, 13 barrels; 18 on the apron): with nine hides on the apron the rule cannot hold over six 100 x 88 cells (the worst point was 96 studs from a hide or gap).
- 4.8 (WP08): Hangar A has a wicket door (5 wide) in its east wall at z 112, beside the switch, besides its side door: with one way in the hangar is a dead end, and the radar's second battery must lie within 40 walked of the wing filler and in no dead end.
- 4.8 / 5.4 (WP08): every open-air land spot has a light fixture within 32 (the teleport warning): a grid of blue edge lamps over the apron cells and the yards (46 with the taxi lane's); the stage has 80 fixtures, the budget's limit, and the masts' red obstruction lamps are unlit emissive, not fixtures.
- 4.9 (WP08): on the Runway set s = 0 is the tail's line-up mark; the runway proper runs s -50 .. 1,450 (1,500 studs) and a blast pad paves s -150 .. -50, under his start 126 [118] behind the tail. The obstacle patterns and the plane are the set's fixtures (switchable groups Pattern_1..3).
- 2.7 / 5.3 (WP08): the Bahamas' sun and sky are data (WorldConfig.Sets.Bahamas.sky: the sun's direction and colour, the sky's two colours, the sea, dayAmount, saturation, exposure) plus a Sun mark far out along the sun; the sea is a flat unlit turquoise sheet (5.3's Potato form) with lighter shallows and a white shore line until a runtime dresses it. The landing mark is "Landing" ("Touchdown" is a removed name).
- 4.7 (WP07): the stage has 60 hides, not 40 (8 meter closets in the bulkheads, 18 AC housings, 17 tar drums and 17 rain butts on a 3 x 2 grid of each roof's cells): with five hides a roof the 30-walked rule cannot hold over 112 x 84 roofs cut by plant screens (the worst roof point was 41 from a hide).
- 4.7 / 5.4 (WP07): every land spot has a burning fixture within 32: besides the bulkhead lamps each roof carries a 3 x 2 grid of dim service bulbs on posts (0.28, range 9); 59 fixtures burn (60 the budget), and 16 dead lamp posts by the parapets keep the lit share at 79 %.
- 4.7 (WP07): the PVS rule (each zone sees at most 14, 10 on average) is measured inside the haze (sightRange 120, 5.4's distance fog closes there on every tier); the east and west roofs are three zones each (north, the middle bend, south) and the middle roofs carry dog-leg plant screens, boiler houses and roof hatches at their inner corners: with the façade band alone a roof saw up to 19 zones. Max 14, mean 9.67.
- 4.7 (WP07): the crossing (420..650) is measured at walking pace: gantries, planks and stairs, never a leap (a leap takes a sprint): 437 walked from the landing marks to the skybridge.
- 4.7 (WP07): the landing marks stand round (340, 140) on the east roof's middle zone `C1_Roof_E_M` (the stage's entry), at the corners of a 12 x 6 rectangle.
- 4.7 (WP07): the spawn hold's 70..140 walked (leaps counted) reaches only the north roof's east half out of the landing's sight (every other roof is 160 or more): two Creature starts stand by its east parapet, the others on the north and south roofs' west halves. "N, S, NW or SW" does not hold on a 400 x 288 ring.
- 4.7 (WP07): a deck's walk graph members are its stairs only: a walk that starts on a deck climbs out by a stair; dropping off a lip reaches the deck's stairs.
- 4.7 / 5.4 (WP07): the stage's far scenery (street, skyline, beacon) is not baked: the bake probes the whole box of a level, so every stud of scenery out to the canyon is lighting work. The façade band (30..44 high) is the canyon's near wall; the far skyline is WP14's runtime scenery.
- 3.6 / 2.2 (WP07): Gus's key ring is welded, not jointed (11 keys, two chain links, the ring), and adds exactly one attachment (`KeyJingle`) to the rig; his 38 added parts are all non-colliding, massless and unqueried. The host is a Creature attribute (`Host`), and `meta.creatureHosts` carries both hosts' dress relative to the rig part each rides.
- 4.7 (WP07): an open-air stage gets none of the school's signage (room plates, STAIRS, posters): its signs are RooftopBuilder's (the billboard, ROXY, the laundry, the feeder placards).
- 4.7 (WP07): the stage's ambience is `DroneRoof` (there is no `WindDrone` preset).
