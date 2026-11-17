# ROVLOC opening v3: story continuity

Story editor's final, 16 Nov 2026. Every place in `docs/design/game-spec-v2.md`, `StoryConfig.luau` and
`CastConfig.luau` that the new opening changes, with the new text or value. Companion to opening-v3.md (shot ids V01a
to V20 and R1 to R4, line numbers L1 to L23) and monster-lines.md. Nothing in the repository was changed by this
task; this file is the change list for whoever lands it.

Second pass, 17 Nov: the engine staging is the base on both platforms (no video credits); the monster's face is the
one the player chose (B3, requirements 17 Nov); timing, light, lot, quiz and Ending A/B fixes from a fresh-eyes check.

The one-paragraph story, as it now stands: a small porcelain face that sleeps small, smooth and soft-looking crawls
out of Dumpster A at 3:14 PM. Danny thinks it is cute. While he is telling you so, it climbs him, lays its cheek on
his and grows over his face, drawing it out long, narrow and pointed. The Tall Man stands where Danny was, about four
metres tall, bare-headed and barefoot: his beanie, his sneakers, his backpack and his bike stay in the lot. You carry the beanie to the end.

## A. `docs/design/game-spec-v2.md`

### 0.3 What waits as P1

| Today | New |
|---|---|
| P1 item 6: "voice extras: lures in Danny's clean voice, Memory and Isolated lines, the PA scare, speaking extras (Kayla, Marcus, Mr. Kessler), facial expressions." | "voice extras: lures in Danny's clean voice, the PA scare, facial expressions in real time." **Moved to P0:** Kayla and Marcus as speaking classmates in the opening (voices; backs only in the video); the Isolated lines (monster-lines.md G9); the Memory lines are now the whole of 3.4. Mr. Kessler stays unseen: he is Danny's impression |
| "Cut from spec v1 for good: … Kokoro TTS" | add: "(superseded by requirements.md, 16 Nov: every line is a file rendered offline with an open speech model; Kokoro may serve as the name bank's fallback)" |

### 2.1 The spine

| Today | New |
|---|---|
| "Three weeks on, Walter found the mask in a steam tunnel, cold and still." | "Three weeks on, Walter found it in a steam tunnel, cold and still, **shrunk to the size of a hand and smooth again, as if it had never been worn.**" |
| "Facilities clears the prop room; the crate goes to the dumpsters behind the school." | "Facilities clears the prop room; the crate is tipped into Dumpster A behind the school and splits. **What was in it wakes in the dark of the bin.**" |
| "At 3:14 PM **Danny Reyes**, the players' friend, lifts out a pretty, broken mask. It is the parasite. It latches onto his face, and the Tall Man stands where Danny was." | "At 3:14 PM a small soft thing with a porcelain doll's face crawls out of Dumpster A and hops across the asphalt. **Danny Reyes**, the players' friend, bends down to it and tells you how cute it is. While he is looking at you it climbs onto his shoulder and lays its cheek on his. It is the parasite. It grows over his face, and the Tall Man stands where Danny was. His sneakers, his backpack, his bike and his red beanie stay in the lot." |
| "The party hides in the bins until midnight." | unchanged; add: "The squad carries the beanie from the lot to the end." |
| "**The rule that makes the twist fair: the mask rides one host at a time.** …" | add two sentences: "**Off a host it sleeps: it shrinks, its face goes small, round and smooth, and it folds its legs under a pale down that makes it look soft. On a host it grows to fit and stretches long and narrow with the body**; that is why the Tall Man's face is so long
and pointed. Given time it charms; in a hurry (the tower) it simply springs." |

### 2.2 Cast

| Row | Today | New |
|---|---|---|
| Danny Reyes | "grey hoodie, **red beanie**, white sneakers, backpack. Catchphrase: "Wait up, you guys!"" · voice "clean: 1.15 / 1.05; 1.0 / 1.05" · drawn by the avatar renderer | look: add "white drawstrings; his bike is in the rack by the dumpsters. In a generated video, if one is made, he is cast to read as 17 to 19." Voice: "a rendered voice (task 49), rate 1.05; his teacher voice is the same take 2 semitones down at 0.85 (rate 0.89)". Drawn by: "the opening (the people-v2 model in the engine staging; the video's own face if a video is made); the avatar renderer in the endings (costume `DannyAfter`: no beanie, no backpack, barefoot)" |
| The Tall Man (Danny) | "MONSTER-LOOK.md, unchanged" | "**The face is the one the player chose on 17 Nov (test picture B3):** very long, very narrow and pale, tapering to a point; a wrinkled brow; huge black slanted eye holes with a pinprick of light deep in each; two dark streaks under the eyes. **Big old veined hands with long fingers.** It replaces MONSTER-LOOK.md's oval mask. No beanie, no hat. The body is the rig as it is today until task 46 lands: Danny's body grown wrong, about four metres tall and as thin as the face is narrow, in what is left of the grey hoodie and jeans, bare feet. Voice: sound.md 2.5, rate 0.82" |
| The party | "Web: the co-op avatars in slot colours, the local player included" | add: "**In the opening the party is the camera and is never on screen;** the avatars first appear when the lids open. Other cutscenes unchanged." |
| The mask crawler | "the Tall Man's mask at 0.45 scale (about 0.6 tall) on eight pale two-segment finger-legs, 0.9 long · clicking, a music-box tick" | "**Asleep (the opening, "the little guy"):** a ball of pale down the size of a curled kitten (0.6 across) round its own small face, `SleepFace`: a glossy, uncracked porcelain doll's face, round, with two large oval eye holes and a painted smile curling up on the right (not the Tall Man's face scaled down); it hops like a frog; a two-note chirp built on the music-box tick. Its body is its eight finger-legs folded like a fist. On a host the round face grows into the long one. **Awake (the twist):** as today, 0.45 scale and up, bare legs, clicking; its face follows the Tall Man's (B3's once task 46 lands)." |
| new: **Kayla Brooks**, 16 | — | "mustard-yellow rain jacket, one long dark braid, a folded quiz paper. Seen from behind. Voice: rendered, dry and fast, rate 1.10. In the opening only; safe at Sal's" |
| new: **Marcus Pike**, 15 | — | "navy bomber jacket, big headphones round his neck, a skateboard under his arm. Seen from behind. Voice: rendered, loud, cracks on high words, rate 1.10. In the opening only; safe at Sal's" |
| below the table | "Actors have no facial animation (P1)." | "A video, if made, carries its own faces. Real-time actors (the endings; the engine staging of the opening on both platforms, which is the base) get a jaw flap from each line's audio; full facial animation stays P1." |

### 2.3 How cutscenes work

| Rule | Today | New |
|---|---|---|
| Data | camera keys, actor tracks, events | add: "A shot's `view` may be `Video`: the picture is a clip of the timeline's video file, played on the timeline's clock. Lines, sounds, cards, lights, props and fades stay timeline events over it; **the video file carries no audio.** A timeline with video names its files per cut (`video.Full`, `video.Short`) and a set of stills (`video.stills`, one per `Video` shot). **A `Video` shot also carries camera keys and actor tracks**, so the view falls back in this order: `Video` (the file exists and is ready), then `Cinematic` (the engine staging of the same shot), then the stills with slow push-ins only if the engine scene is not ready either. Roblox always plays `Cinematic`." |
| Sampling | "late pages fast-forward" | add: "A page corrects its video when it drifts more than 80 ms from the clock and, after a stall, seeks forward. The video is fetched whole during `Deploying`, from the game's own domain. Not ready within 4 s, or failed, or no video file at all (today): the view is `Cinematic`, the engine staging, with all audio unchanged; the stills only if the engine scene is not ready either." |
| Lines | "`story-test` asserts words ÷ (2.6 × the voice's rate) ≤ slot and that no two lines overlap." | add: "A line may be `sync = true` (its speaker's mouth is on screen in a `Video` shot). A `sync` line has no name slot, lies wholly inside one `Video` shot and has a slot of 3.0 s or less; a timeline has at most four. Characters ÷ slot ≤ 15." |
| Name slots | "`{P1}`..`{P4}` … `{you}` … Solo: lines that need P2 or more are skipped." | add: "**A name is only ever spoken by the monster's voice, from the pre-rendered name bank, never by a clean voice and never by a mouth on screen.** The opening uses only `{you}`; solo and co-op hear the same scene." |
| Full or Short | "Short plays when every member has seen the Full one…" | add: "The Short cut of a video timeline is its own encoded file." |
| Leaving and joining | "A joiner sees the timeline from its current time." | add: "During a `Video` shot the joiner's page seeks the file; after the video a joiner of the opening starts in the next free bin." |

### 2.4 The opening

The whole section is replaced by opening-v3.md sections 5, 6, 9 and 10.

| Item | Today | New |
|---|---|---|
| Heading | "The opening (Full 61.0 s; Short 24.0 s)" | "The opening (Full 65.0 s; Short 24.9 s; video to 54.4 s, then real time)" |
| Phases | "`Deploying` (the squad is placed at the bin marks; the composed lines are preloaded)" | "`Deploying` (the squad is placed **inside its bins**; the video file and each page's composed whispers are preloaded; the 3D scene is kept warm under the video)" |
| The shot table S1 to S16 | sixteen cinematic shots | V01a to V20 (view `Video`) and R1 to R4 (view `Own`) |
| S12 "one shared shot through the lid gap" and its amendment "through Dumpster A's gap" | shared | "each page's own bin and gap; the scripted Tall Man is staged per page" |
| S12's whisper "I know you're close, {you}." | (50.1, 2.5) | "So cute." (57.0, 1.2), no name |
| S16's whisper "{you}…" / "Still here…" | (59.2, 1.5) | "{you}." / "Still here." (63.5, 1.4): the dots are gone, a speech model cannot say them |
| "From the last lid slamming (46.95) to the hand-over is 14 s" | 14 s | "10.6 s with one player (54.4), 10.15 s with four (54.85)" |
| "never 3 s pass without a change" | kept | "from the lid slam (54.4) on, never 3 s without a change; before it, no `Video` shot is longer than 4.5 s" |
| Short cut | seven pieces | eight pieces (opening-v3.md section 9) |
| "The Creature in S9 to S13 is Scripted and uses only existing actions (FadeIn, Stare, ReachIn for the fingertips)." | — | "The Creature in V19, V20 and R1 is Scripted and uses only existing actions (Stare, Walk, ReachIn for the nails, Hunch). In V19 and V20 it is the engine staging (or, with a video, the same rig rendered offline): the Scripted pose, a head turn on the Neck, the Jaw parted 3 degrees so the point of the chin drops, one step." |

### 2.5 Ending A and the twist

| Shot | Today | New |
|---|---|---|
| A3 | "Danny lies there in his grey hoodie and red beanie, pale, whole, eyes half open" | "Danny lies there in what is left of his grey hoodie, **bare-headed and barefoot**, pale, whole, eyes half open" |
| A4, first line | DANNY (7.5, 2.4): "{shooter}…? Hey." | two lines: THE TALL MAN's voice for the last time, quiet (7.2, 0.7): "{shooter}?" twin "Hey." · then DANNY, clean, weak, rate 0.85 (7.9, 2.3): **"Is it still on me?"** The other three lines stay where they are (10.2, 13.3, 17.4) |
| A4, last line | "…wait up, you guys." | text for the model: "wait up, you guys." (no dots); it now echoes a line the audience heard him shout while happy |
| A5 | "The shooter takes the red beanie." | "The shooter takes the red beanie **out of a pocket** (the squad has carried it since the lot) and holds it." |
| J4 | finger-legs unfold from both halves | unchanged. Note: no down, full size: it has not slept |
| J5 | "It skitters up his sleeve and springs onto his face (0.25 s)." · GUS: "Get it— GET IT OFF—" | unchanged. It has no time to act cute. Gus's line no longer echoes a line of Danny's, which suits a different man (Danny was charmed; Gus fights). Text for the model: "get it. get it off!" |

### 2.6 Ending B

One change, to keep rule 2.3 (a name only in the monster's voice): the line spoken "both voices at once" splits by
layer. The clean layer says "You were always my best friend." and only the monster layer adds the name from the bank:
"You were always my best friend, {you}." (twin: the monster layer says the clean words too). The solo "a bin lid
creaking shut" still fits; the whisper "{you}…" is written "{you}." for the speech model, twin "Still here."

### 2.7 Sunrise

No change to the text. H3 ("the red beanie on the dash") and H6 ("the shooter hangs the red beanie on a driftwood
post") are now true because the squad picked it up in the lot. P2's "…Sal's is gonna be closed, huh." is set up by
L8 "Sal's at four!".

### 2.8 Lore in the world

| Item | Today | New |
|---|---|---|
| Basement "IT CAME OUT OF THE BINS", Hallways "NOT DANNY", "IT KNOWS NAMES", "WHEN IT LOOKS AWAY — GO" | — | unchanged, and truer: it did come out of a bin; "when it looks away" now also reads the other way round (he looked away) |
| add, Hallways (fixed dressing, cosmetic, not `Detail`) | — | a locker with a tape label "MARCUS" and, inside its vent slats, **last week's** quiz marked in red pen "16% — SEE ME. K." (4 of 25; Friday's quiz is in the lot, see 4.1) · a hand-drawn poster "KAYLA FOR TREASURER" · a classroom door plate "MR. KESSLER" |
| add, the Back Lot | — | a paper notice on the staff doors: "PROP ROOM CLEAR-OUT — FRIDAY — FACILITIES" |
| add, P1 only (the Basement's wall phone, Device channel) | — | Kayla's message from Sal's, once: "It's Kayla. We got a booth. Where are you guys?" |
| Walter's film | — | unchanged. Check its cards for the word "wear": in 1989 Michael put the mask on for the play, which still fits (it needs no charm when it is worn). Add nothing |

### 3.4 The talking monster

Replaced by monster-lines.md. In short:

| Item | Today | New |
|---|---|---|
| Principles | "Rare: about one line per 45 s outside chases." | "Rare: unprompted lines at most one per 120 s per listener and one per 45 s team-wide; prompted lines by chance per event; a mean of one per 60 to 100 s per listener outside chases." |
| "Earned: the run's first unscripted line waits for its first teleport warning or chase." | — | "The opening has given him a voice: the first line in play may be a far-away one." |
| The category table | ten categories and their lines | Calling, Sniff, Saw you hide and Chase get new lines; **new categories Wall, Grate, PassBy, Spotted, Lost, Caught**; the conditions Alone and Group; Ready, LookAway, Teleport, Heard, Behind and Stunned kept (monster-lines.md sections 1 and 5) |
| Rules | "≥ 8 s between lines … ≤ 4 per rolling 60 s"; "the same name … twice within 45 s"; "The mean rate … one per 35 s and one per 60 s" | 12 s; 3 per 60 s; 90 s; one per 60 to 100 s |
| Names | the sanitizer | add: "The name is spoken from a bank of pre-rendered first names in the monster's voice, in three shapes; a name not in the bank gets the twin." |
| Voices | "the web scores its voices per role …" | "Every line is a file rendered offline (task 49). The browser's own speech is the last fallback only. Roles: Danny, Kayla, Marcus, the Tall Man, Gus, the Tall Janitor, PA." |
| What each platform plays, Words (web) | "one `SpeechSynthesisUtterance` per line (≤ 12 words)" | "one rendered file per line and twin (≤ 7 words beside the name), the name joined from the bank at the line's pause" |
| Subtitles | "Label DANNY (struck through) for the monster" | add: "The opening teaches it: the strike draws itself through DANNY during L18 'Guys?'." |
| "In the city the voice is Gus's and the lines are a janitor's" | — | add: "plus exactly one of Danny's lines, once a run, on the Rooftops: 'Wait up, you guys.'" |

### 4.1 `BackLot`

| Piece | Today | New |
|---|---|---|
| Street gate | "chained ("Chained.")" | "open at 3:12 PM in the opening's video (Kayla and Marcus leave by it); it clangs shut with the lockdown (one sound, `GateClang`, at 61.3); chained at midnight as today" |
| Bins | "Dumpster A, slot 1 · …" | unchanged. Note: Dumpster A is the bin it came out of; nothing says so until the Basement's graffiti |
| DISCARD boxes and the torn crate | "beside Dumpster A" | unchanged; the crate is empty |
| Bike rack | among "Bike rack, basketball hoop, pallets, puddles (`Detail` 2–3)" | "**a fixed prop on every detail level**, at about (23, 321.5), under the yard lamp (28, 320), with one bike; the builder may shift it up to 2 studs to keep the walk to the hatch clear. From 44.1 (the cut into V16) the bike lies on its side" |
| add: where it happens | `BL_Mark_Danny` (15, 319) and `SPOT` (13.6, 320.6), in front of Dumpster A | **`BL_Mark_Danny` and `SPOT` move to (21, 320.5)**: Danny crouches between the party and the lamp, so the lamp is above and behind him; the party's mark is (16, 319.5), beside Dumpster A's east end, 5 studs (two steps) west of Danny. Dumpster A is then the bin at the party's back |
| add: what Danny left | — | fixed props on every detail level, shown from 54.4, at `SPOT`: two white sneakers side by side with the laces tied; a black backpack on its side; **the red beanie** 2.5 studs toward Dumpster A (where the party stood). Cosmetic (I3) |
| add: Friday's quiz | — | one fixed prop on every detail level, shown from 54.4: Marcus's quiz ("12% — SEE ME. K.", 3 of 25) lying in a puddle about 6 studs inside the gate. Kayla let it go when they ran; the opening never shows it falling. Cosmetic (I3) |
| Prologue step 2, "The lot at night" | — | add: "On the way to the hatch lie Danny's bike, backpack and sneakers, lit by the strobe, and near the gate Marcus's quiz in a puddle. **The beanie:** when any player comes within 4 studs of it, it is gone with a small cloth sound (no prompt, no text, no HUD); if nobody does, it is gone at the chute's cut. The authority owns the state; it changes nothing else." |
| "Prologue (after S16 …)" | S16 | R4 |

### 4.3, 4.6, 4.7, 4.10 and 5.5

| Where | Today | New |
|---|---|---|
| 4.3 Hallways | — | the three fixed dressings of 2.8; Gus unchanged (he slept through it) |
| 4.6 the standoff: "It's me. It's still me. Please… don't." · "You hid. You always hide." · "…do it." · "I knew you wouldn't." | — | unchanged. "You hid. You always hide." now also means the bins. Text for the model drops the dots |
| 4.6 "Ending A's staging" | "Danny's mark is the monster's position at T" | add: "Danny appears in costume `DannyAfter` (bare-headed, barefoot, no backpack); the beanie is the shooter's prop" |
| 4.7 the Tall Janitor table, row Body, column "Danny's Tall Man" | "bare shadow, tatters" | unchanged until task 46 lands; then "Danny's body grown wrong, about four metres tall and as thin as the face is narrow, in what is left of his grey hoodie; B3's long narrow pointed face; big old veined hands with long fingers; no hat; bare feet" |
| 4.7 same table, row Footfalls | "bare, heavy" | unchanged, and now explained: his sneakers are in the lot |
| 4.10 the Sunrise card "Danny Reyes · 2010–2026" | — | unchanged |
| 5.5 sounds, row "`CrawlerClick`, `MusicBoxTick` · cutscenes" | — | add presets for the opening: `ThingChirp` (two rising notes on the music-box tick), `ThingChirpCut` (the same, cut off mid-note), `ThingChirpBack` (the two notes reversed at half speed), `ThingPat`, `ThingRustle`, `FingerPads`, `LidCreak`, `LampBuzzOn`, `GlazeCrackle`, `KnuckleCrack`, `SeamTear`, `BikeClatter`, `BeanieDrop`, `BackpackThud`, `HeavyStep`, `GateClang`, `MonsterBreathIn` (Danny's breath in through the monster recipe). **Removed from the opening:** `WetBreath` (the word and the sound both read as gore beside a photoreal picture), `MaskCrack`, `Screech`, `CrawlerClick` |

### 7 and 8: work packages and tests

| Where | Today | New |
|---|---|---|
| WP11 tests | "`story-test.mjs` (hand-over at 61.0 s Full and 24.0 s Short; every line fits its slot and none overlaps…" | "hand-over at 65.0 s Full and 24.9 s Short" plus the fourteen rules of opening-v3.md section 12 |
| WP11 scope | the cutscene player on `CinematicTracks` | **first, the engine staging of opening v3 on `CinematicTracks` (the base; task 44's people, the asleep crawler, the Tall Man with B3's face when task 46 lands);** then task 51: the video-cutscene player (the `Video` view, the clock, the drift rule, the fallback order `Video`, `Cinematic`, stills, the black seam), used only if a video is made |
| WP12 | the talking monster | monster-lines.md; `VoiceConfig` gains the six categories, the two conditions, the word list of rule 4 and the callback bag of rule 6 |
| RP03 (Roblox) | "the crawler; the opening, the prologue and skip votes" | "Roblox cannot play the video: it plays the same engine staging as the web's base (shot ids, times, camera keys, actor tracks, line ids, audio files), the party behind the camera. `MaskCrawlerRigBuilder` gains the asleep form (the down shell, `SleepFace`, Hop, Tilt, Open, Climb)." |
| 5.3 Potato row "The mask's crack, drop and the crawler" | — | add: "the asleep form's down is a plain shell on Potato" (the engine staging, both platforms) |

## B. `src/ReplicatedStorage/Shared/Config/StoryConfig.luau`

### Types

```lua
export type Line = {
	-- ... as today, plus:
	sync: boolean?,   -- the speaker's mouth is on screen in a Video shot (lip-synced in the video file)
	from: string?,    -- the line id whose rendered take this line is built from
	label: string?,   -- a subtitle label that replaces the speaker's (L4)
	strike: boolean?, -- the subtitle's label is struck through during this line (L18)
}
export type Shot = { id: string, t0: number, t1: number, view: string } -- view: Cinematic | Own | Video
export type VideoFile = { file: string, length: number, pictureEnd: number }
-- Timeline gains:
--   video: { Full: VideoFile, Short: VideoFile, stills: string }?
```

### Speakers (add)

```lua
Kayla = { label = "KAYLA", struck = false, voice = CastConfig.Actors.Kayla.voice },
Marcus = { label = "MARCUS", struck = false, voice = CastConfig.Actors.Marcus.voice },
```

### The Opening timeline

| Key | Today | New |
|---|---|---|
| `length` | 61.0 | **65.0** |
| `cuts.Full` | `{ at = 0, from = 0, to = 61.0 }` | `{ at = 0, from = 0, to = 65.0 }` |
| `cuts.Short` | seven segments | `{0, 19.1, 21.6}`, `{2.5, 26.7, 32.3}`, `{8.1, 39.0, 41.4}`, `{10.5, 42.3, 44.1}`, `{12.3, 44.8, 46.7}`, `{14.2, 49.6, 54.9}`, `{19.5, 56.6, 59.2}`, `{22.1, 62.2, 65.0}` (each `{at, from, to}`) |
| `video` | — | `Full = { file = "opening-full", length = 55.0, pictureEnd = 54.4 }`, `Short = { file = "opening-short", length = 19.5, pictureEnd = 19.0 }`, `stills = "opening-stills"` |
| `shots` | S1 to S16 | below |
| `camera` | S1 to S15 keys | **re-authored, not removed:** from 0 to 54.4 one key pair per V shot at the framing opening-v3 section 5 gives (the party's eye for party views; the low and macro inserts at their own marks), so the view can be `Cinematic` (the base today) when there is no video. R1 to R3 use each page's own gap: eye = that bin's `Gap`, target = its `GapTarget`, fov 74 easing to 70 by 57.5 |
| `actors` | Danny, P1..P4, Crawler, TallMan, Sneakers | **kept and re-authored to the new marks** (they play whenever the view is `Cinematic`): **Danny** (the people-v2 model: walks out with the others, stops and turns for the teacher at 6.2, walks on, stops at the bike rack at 17.0, crouches at `SPOT` 24.9, looks back over his shoulder 26.6, the glaze as a material blend 39.0 to 42.3, the rise as the rig's unfold 44.1 to 46.7, `Hidden` from 46.7); **Kayla** and **Marcus** (new; backs and three-quarter backs only: walk, Kayla's paper held up, Marcus's grab, the jog to the gate from 15.2, `Hidden` from 18.9); **Crawler** in its asleep form (`Hidden` until 18.9; out over Dumpster A's rim, three hops 21.6 to 24.9 from the rim toward `SPOT`, Tilt 30.1, Open 31.2, Climb 32.3, on the shoulder 34.1, cheek 36.5, `Hidden` from 39.0); **Sneakers** (shown at `SPOT` from 46.7); **DannyBeanie** and the backpack as props (48.8, 49.0). P1..P4: `Hidden` throughout (each player is inside its bin). TallMan: below |
| `points.Bins[slot]` | Path1..3, Over, Inside | add `Approach` = (bin x + 2.4, bin z − 5.0), `Front` = (bin x, bin z − 4.0), `Leave` = `Front` plus 4 studs toward the staff doors, `Gap` and `GapTarget` (for Dumpster A today's S12 eye (10.0, 22.55, 322.6) and target (10.2, 23.2, 316.0); the other three measured from each bin's own lid in `BackLotBuilder.Set.bins`: the wheelie bin's gap is lower) |
| `day` | grey to 53.8, then the time-lapse | `{0, 0.65, (1, 1, 1)}`, `{38.6, 0.65, (1, 1, 1)}`, `{39.6, 0.5, (0.9, 0.94, 1)}`, `{59.2, 0.5, (0.9, 0.94, 1)}`, `{59.2, 0.46, (1, 0.93, 0.84)}`, `{61.8, 0.44, (1, 0.9, 0.8)}`, `{62.4, 0.32, (1, 0.62, 0.38)}`, `{63.0, 0.12, (0.42, 0.52, 0.9)}`, `{63.4, 0, (0.42, 0.52, 0.9)}`. **Second pass: kept as it is, and it is the reference for the picture.** At 38.6 the sky only dims (the cloud thickens, the yard lamp buzzes on and becomes the key light, the sky stays dark grey); it is never night before the time-lapse. A video, if made, is graded to this 0.5 at R1, not darker |

**Shots**

```lua
shots = { -- view "Video" falls back to "Cinematic" (the engine staging, the base today), then to the stills
	{ id = "V00", t0 = 0.0, t1 = 0.5, view = "Video" },   -- black
	{ id = "V01a", t0 = 0.5, t1 = 2.8, view = "Video" },
	{ id = "V01b", t0 = 2.8, t1 = 6.2, view = "Video" },
	{ id = "V02", t0 = 6.2, t1 = 8.9, view = "Video" },
	{ id = "V03", t0 = 8.9, t1 = 10.8, view = "Video" },
	{ id = "V04", t0 = 10.8, t1 = 15.2, view = "Video" },
	{ id = "V05", t0 = 15.2, t1 = 18.9, view = "Video" },
	{ id = "V06", t0 = 18.9, t1 = 21.6, view = "Video" },
	{ id = "V07a", t0 = 21.6, t1 = 22.7, view = "Video" },
	{ id = "V07b", t0 = 22.7, t1 = 23.8, view = "Video" },
	{ id = "V07c", t0 = 23.8, t1 = 24.9, view = "Video" },
	{ id = "V08", t0 = 24.9, t1 = 26.6, view = "Video" },
	{ id = "V09", t0 = 26.6, t1 = 30.1, view = "Video" },
	{ id = "V10a", t0 = 30.1, t1 = 31.2, view = "Video" },
	{ id = "V10b", t0 = 31.2, t1 = 32.3, view = "Video" },
	{ id = "V11", t0 = 32.3, t1 = 34.1, view = "Video" },
	{ id = "V12", t0 = 34.1, t1 = 36.5, view = "Video" },
	{ id = "V13", t0 = 36.5, t1 = 39.0, view = "Video" },
	{ id = "V14a", t0 = 39.0, t1 = 40.7, view = "Video" },
	{ id = "V14b", t0 = 40.7, t1 = 42.3, view = "Video" },
	{ id = "V15", t0 = 42.3, t1 = 44.1, view = "Video" },
	{ id = "V16", t0 = 44.1, t1 = 46.7, view = "Video" },
	{ id = "V17", t0 = 46.7, t1 = 47.8, view = "Video" },
	{ id = "V18a", t0 = 47.8, t1 = 48.7, view = "Video" },
	{ id = "V18b", t0 = 48.7, t1 = 49.6, view = "Video" },
	{ id = "V19", t0 = 49.6, t1 = 52.2, view = "Video" },
	{ id = "V20", t0 = 52.2, t1 = 54.4, view = "Video" },
	{ id = "R1", t0 = 54.4, t1 = 59.2, view = "Own" },
	{ id = "R2", t0 = 59.2, t1 = 61.8, view = "Own" },
	{ id = "R3", t0 = 61.8, t1 = 63.4, view = "Own" },
	{ id = "R4", t0 = 63.4, t1 = 65.0, view = "Own" },
},
```

**Lines** (the ten of today are all replaced; `Opening.Lockdown` and `Opening.You` keep their ids)

```lua
local openingLines: { Line } = {
	{ id = "Opening.Twelve", t = 0.6, slot = 2.2, speaker = "Kayla", channel = "Head", text = "Twelve percent. On true-or-false." },
	{ id = "Opening.Coin", t = 2.8, slot = 1.9, speaker = "Danny", channel = "Head", text = "Marcus. A coin gets fifty." },
	{ id = "Opening.Studied", t = 4.7, slot = 1.5, speaker = "Marcus", channel = "Head", text = "I studied for that!" },
	{ id = "Opening.FunnyTeacher", t = 6.4, slot = 2.3, speaker = "Danny", channel = "Head", text = "Mister Reyes. Is something funny?", rate = 0.89, style = "Teacher", sync = true, label = "DANNY (AS MR. KESSLER)" },
	{ id = "Opening.NotYet", t = 8.9, slot = 1.9, speaker = "Danny", channel = "Head", text = "I said: not yet, sir." },
	{ id = "Opening.Hat", t = 10.8, slot = 2.2, speaker = "Kayla", channel = "Head", text = "Does that hat even come off?" },
	{ id = "Opening.MoreHat", t = 13.0, slot = 2.2, speaker = "Marcus", channel = "Head", text = "It's just more hat under there." },
	{ id = "Opening.Sals", t = 15.2, slot = 1.1, speaker = "Marcus", channel = "Head", text = "Sal's at four!" },
	{ id = "Opening.LastOne", t = 16.3, slot = 1.1, speaker = "Kayla", channel = "Head", text = "Last one buys!" },
	{ id = "Opening.WaitUp", t = 17.4, slot = 1.5, speaker = "Danny", channel = "Head", text = "Wait up, you guys!" },
	{ id = "Opening.Whoa", t = 22.0, slot = 1.5, speaker = "Danny", channel = "Head", text = "Whoa. What is THAT?" },
	{ id = "Opening.LittleGuy", t = 25.1, slot = 1.2, speaker = "Danny", channel = "Head", text = "Hey, little guy." },
	{ id = "Opening.SoCute", t = 26.8, slot = 3.0, speaker = "Danny", channel = "Head", text = "Bro. Look at it. This is SO cute.", sync = true },
	{ id = "Opening.ThatFace", t = 32.4, slot = 1.6, speaker = "Danny", channel = "Head", text = "What? What's that face?" },
	{ id = "Opening.LikesMe", t = 34.4, slot = 1.6, speaker = "Danny", channel = "Head", text = "Hey. It likes me.", sync = true },
	{ id = "Opening.Cold", t = 36.8, slot = 1.3, speaker = "Danny", channel = "Head", text = "Ha. It's cold.", sync = true },
	{ id = "Opening.StillOnMe", t = 39.3, slot = 2.0, speaker = "Danny", channel = "Head", text = "Is it still on me?" },
	{ id = "Opening.Guys", t = 44.9, slot = 1.0, speaker = "Danny", channel = "Head", text = "Guys?", style = "Going", strike = true },
	{ id = "Opening.FunnyMonster", t = 50.7, slot = 1.5, speaker = "TallMan", channel = "Head", text = "Is something funny?", from = "Opening.FunnyTeacher" },
	{ id = "Opening.WaitUpBack", t = 52.5, slot = 1.9, speaker = "TallMan", channel = "Head", text = "Wait up, you guys.", from = "Opening.WaitUp" },
	{ id = "Opening.SoCuteBack", t = 57.0, slot = 1.2, speaker = "TallMan", channel = "Ear", text = "So cute.", from = "Opening.SoCute" },
	{ id = "Opening.Lockdown", t = 59.4, slot = 2.2, speaker = "PA", channel = "PA", text = "LOCKDOWN. LOCKDOWN." },
	{ id = "Opening.You", t = 63.5, slot = 1.4, speaker = "TallMan", channel = "Ear", text = "{you}.", twin = "Still here." },
}
```

Removed ids: `Opening.Frog`, `Opening.BackMeUp`, `Opening.Detention`, `Opening.Pizza`, `Opening.Paying`,
`Opening.LookAtThis`, `Opening.Phantom`, `Opening.GetItOff`, `Opening.Close`.

**The Tall Man's track** (kind `Monster`). The constants change with the marks: `DANNY = { 21, 320.5 }`,
`SPOT = { 21.0, 320.5 }`, `PARTY_AT = { 16, 319.5 }`, `STEP = { 18.6, 320.0 }` (one step from `SPOT` toward the
party); `CRATE` is no longer used by the opening. Before 54.4 the track is the same on every page and is seen only when
the view is `Cinematic` (V19, the first 0.5 s of V20); from 54.9 it is bound to that page's own bin. It is hidden from
54.4 to 54.9 and comes up already at `Approach`, so on no page does he cross the lot in view; at 59.0 he leaves toward
the staff doors.

```lua
keys = {
	key(0, SPOT[1], WALK, SPOT[2], facing(SPOT[1], SPOT[2], PARTY_AT[1], PARTY_AT[2])),
	key(52.2, SPOT[1], WALK, SPOT[2], facing(SPOT[1], SPOT[2], PARTY_AT[1], PARTY_AT[2])),
	key(52.7, STEP[1], WALK, STEP[2], facing(STEP[1], STEP[2], PARTY_AT[1], PARTY_AT[2])), -- V20: his one step
	{ t = 54.9, bin = "Approach" },
	{ t = 56.2, bin = "Front" },
	{ t = 58.8, bin = "Front" },
	{ t = 59.2, bin = "Leave" }, -- Front plus 4 studs toward the staff doors
},
clips = {
	{ t0 = 0, name = "Hidden" }, { t0 = 49.6, name = "Stare" }, -- V19: the Neck turns 50.0 to 50.6, the Jaw parts 3 degrees
	{ t0 = 52.2, name = "Walk" }, { t0 = 54.4, name = "Hidden" }, { t0 = 54.9, name = "Walk" },
	{ t0 = 56.2, name = "ReachIn" }, { t0 = 56.6, name = "Hunch" }, { t0 = 58.8, name = "Stare" },
	{ t0 = 59.0, name = "Walk" }, { t0 = 59.2, name = "Hidden" },
},
```

**Events** (every event of today's S1 to S11 is removed; the tail's events are retimed)

| t | Event |
|---|---|
| 0 | `Light BL_Lamp Off` · `Light BL_Strobe Off` · `Prop Shutter Up` · `Prop Windows1 Lit` · `Prop Windows2 Lit` · `Rain off` · `Prop DannyLeft Hidden` · `Prop DannyBeanie Hidden` · `Prop QuizPaper Hidden` (as today, plus the last three) |
| 0.0 | `Sound SchoolBell 0.9` |
| 0.2 | `Card "ROVLOC HIGH · FRIDAY · 3:12 PM"`, 2.8 s |
| 0.4 | `Sound DoorBang` at the staff doors |
| 0.5 | `Sound LotWalk` (three pairs of sneakers and the wind in the fence), 18.4 s, 0.5 |
| 1.8, 18.5 | `Sound ThingChirp` at Dumpster A, 0.25 and 0.6 |
| 5.9 | `Sound GroupLaugh` (three takes: Kayla 5.9, Marcus 6.15, Danny 5.9 ending by 6.2; nothing in Danny's voice under L4) · 10.2 `KaylaGroan` · 10.3 `MarcusLaugh` · 14.9 `DannyLaugh` · 24.5 `DannyNoseLaugh` (the non-verbal takes, as sounds) |
| 19.0 | `Sound LidCreak` · 19.4 `ThingRustle` · 20.4 `ThingChirp` · 21.5 `ThingPat` |
| 21.9, 23.0, 24.2 | `Sound ThingPat` then `ThingChirp` 0.15 s later (the three hops; the third without a chirp) |
| 26.4, 27.6, 28.9 | `Sound ThingChirp` (slowing) |
| 29.9 | `Sound ThingChirpCut` (it ends at 30.1, in the middle of its second note) |
| 30.7 | `Sound ThingChirpBack` · 31.3 `ThingRustle` · 32.4 `FingerPads`, 1.6 s · 35.9 `ThingChirp`, 1.0 |
| 38.3 | `Sound GlazeCrackle`, 3.9 s |
| 38.6 | `Light BL_Lamp On` · `Sound LampBuzzOn` |
| 43.2 | `Sound BreathIn` · 44.1 `BikeClatter` and `Prop Bike Fallen` (on the cut from V15 to V16; the bike lies on its side from V16's first frame) · 46.0, 46.5, 47.3 `KnuckleCrack` · 46.2 `SeamTear` · 48.8 `BeanieDrop` · 49.0 `BackpackThud`, 1.0 |
| 50.2 | `Sound MonsterBreathIn`, 0.5 s (L19's breath in, inside the head turn; `Opening.FunnyMonster`'s slot holds only its words) |
| 52.3 | `Sound HeavyStep`, 1.0 · `Shake { amplitude = 1.0, seconds = 0.5 }` · 52.6 `BreathingPanic`, 1.8 s |
| 54.4 | `Prop DannyLeft Shown` (bike fallen, backpack, sneakers) · `Prop DannyBeanie Lot` · `Prop QuizPaper Puddle` · `Prop Lid P1 Shut` · `Sound LidSlam P1` |
| 54.55, 54.7, 54.85 | `Prop Lid Shut` and `Sound LidSlam` for P2, P3, P4 (`minPlayers` 2, 3, 4) |
| 54.5 | `Sound Breathing`, 4.7 s, 0.8 |
| 56.3 | `Sound NailsOnMetal` at that page's bin |
| 58.8 | `Sound DistantScream` (40, 40, 270), 0.8 |
| 59.2 | `Card "3:31 PM"`, 1.6 s · 59.3 `Sound FireBell` · 59.7 `GlassBreak` |
| 60.2 | `Prop Windows2 Dark` · 60.3 `DistantScream` · 60.6 `Prop Windows1 Dark` · 60.8 `DistantScream` |
| 60.9 | `Prop Shutter Down` · 61.0 `Sound ShutterSlam` · `Light BL_Strobe Flicker` · 61.3 `Sound GateClang` |
| 61.9 + 0.28 × i, i = 0..11 | `Sound BellToll`, 0.8 (the last at 64.98). The spacing is 0.28 s (it was 0.3): `BellToll` holds **7** voices (1.8 s held ÷ 0.28 s), see the amendments |
| 62.2 | `Card "11:52 PM"`, 0.9 s · `Rain on` · `Sound RainOnLid`, 2.8 s |
| 63.2 | `Fade { to = 1, seconds = 0.2 }` · 64.2 `Fade { to = 0, seconds = 0.8 }` |

Removed from the opening: `CrawlerClick`, `MusicBoxTick` (as separate events), `MaskCrack`, `WetBreath`, `Screech`,
the 34.0 lamp `Stutter`, the 38.6 `Rig` swap, both `Shake`s of S8 and S10, the `Lid … Open` events.

### The other timelines

| Timeline | Key | Today | New |
|---|---|---|---|
| `OneBullet` | event at 4.0 | `Rig { actor = "TallMan", into = "Danny" }` | `Rig { actor = "TallMan", into = "DannyAfter" }` |
| `OneBullet` | line `OneBullet.Hey` | `t = 7.5, slot = 2.4, speaker = "Danny", text = "{shooter}…? Hey.", twin = "…Hey? Hey."` | two lines: `{ id = "OneBullet.Name", t = 7.2, slot = 0.7, speaker = "TallMan", channel = "Head", text = "{shooter}?", twin = "Hey.", style = "Fading" }` and `{ id = "OneBullet.StillOnMe", t = 7.9, slot = 2.3, speaker = "Danny", channel = "Head", text = "Is it still on me?", rate = 0.85, style = "Weak" }` |
| `OneBullet` | `OneBullet.WaitUp` text | "…wait up, you guys." | "Wait up, you guys." (the style `Weak` carries the trailing off) |
| `OneBullet` | event at 20.0 | `Prop { id = "Beanie", state = "Taken" }` | `Prop { id = "Beanie", state = "InHand" }` (it comes out of the shooter's pocket) |
| `Twist` | `Twist.GetItOff` | "Get it— GET IT OFF—" | subtitle unchanged; the model's text is "get it. get it off!" |
| `Fall` | `Fall.You` | `text = "{you}…", twin = "Still here…"` | `text = "{you}.", twin = "Still here."` |
| `Sunrise` | — | — | unchanged |
| `StoryConfig.Prologue` | — | — | add `BeanieReach = 4` (studs) |

Slot check for the two new Ending A lines: "{shooter}?" is one word, 1 ÷ (2.6 × 0.82) = 0.47 s in a 0.7 s slot;
"Is it still on me?" is five words, 5 ÷ (2.6 × 0.85) = 2.26 s in a 2.3 s slot, ending at 10.2 where the next line
starts.

## C. `src/ReplicatedStorage/Shared/Config/CastConfig.luau`

```lua
-- Actors: add
Kayla = {
	name = "Kayla Brooks",
	age = 16,
	costume = {
		body = {
			Head = { 150, 104, 78 },
			Torso = { 204, 164, 44 }, -- the mustard-yellow rain jacket
			Arms = { 204, 164, 44 },
			Legs = { 44, 48, 60 },
			Feet = { 60, 60, 64 },
		},
		wear = {
			{ kind = "Braid", color = { 30, 24, 22 } },
			{ kind = "Paper", color = { 236, 234, 226 } }, -- Marcus's quiz, blank side out
		},
	},
	voice = { web = { pitch = 1.3, rate = 1.1 }, roblox = { pitch = 1.15, speed = 1.1 } },
},
Marcus = {
	name = "Marcus Pike",
	age = 15,
	costume = {
		body = {
			Head = { 222, 184, 160 },
			Torso = { 34, 44, 78 }, -- the navy bomber
			Arms = { 34, 44, 78 },
			Legs = { 70, 72, 76 },
			Feet = { 40, 40, 44 },
		},
		wear = {
			{ kind = "Headphones", color = { 24, 24, 26 } },
			{ kind = "Skateboard", color = { 150, 112, 70 } }, -- carried, never ridden
			{ kind = "Backpack", color = { 72, 60, 48 } },
		},
	},
	voice = { web = { pitch = 1.05, rate = 1.1 }, roblox = { pitch = 0.95, speed = 1.1 } },
},
-- Danny after the mask comes off (Ending A): bare-headed, barefoot, no backpack
DannyAfter = {
	name = "Danny Reyes",
	age = 16,
	costume = {
		body = {
			Head = SKIN_DANNY,
			Torso = { 122, 124, 128 },
			Arms = { 122, 124, 128 },
			Legs = { 58, 64, 76 },
			Feet = SKIN_DANNY, -- barefoot: his sneakers are in the lot
		},
		wear = {},
	},
	voice = { web = { pitch = 1.15, rate = 1.05 }, roblox = { pitch = 1.0, speed = 1.05 } },
},
```

| Key | Today | New |
|---|---|---|
| `Actors.Danny.costume.wear` | Beanie, Backpack, Laces | add `{ kind = "Drawstrings", color = { 236, 236, 232 } }` |
| `Actors.Danny.voice`, `Monsters.TallMan.voice` | pitch and rate for browser speech | rates unchanged (1.05 and 0.82: the slot rule reads them); the pitch values stay only for the last fallback |
| `Crawler` comment | "The mask crawler (the opening's S5-S8)" | "The mask crawler: awake in the twist (J4, J5); asleep in the opening's engine staging (both platforms; the base until a video exists)" |
| `Crawler.LatchSeconds` | 0.25, "S8: it springs onto Danny's face this fast" | 0.25, "J5: it springs onto Gus's face this fast. Nothing latches in the opening" |
| `Crawler.Sleep` (new) | — | `{ Face = "SleepFace", FaceWidth = 0.25, BodyDiameter = 0.6, Height = 0.3, Down = true, DownColor = { 232, 226, 214 }, HopLength = 1.0, HopHeight = 0.5, ClimbSeconds = 1.8, ChirpPitch = 1.6 }`. `SleepFace` is its own small mesh, not the Tall Man's face scaled: round, glossy, uncracked, two large oval eye holes, a painted smile curling up on the right |
| header comment, the wear kinds | "Beanie, Backpack, Patch, KeyRing, HearingAid, Torch, Laces, Belt, Collar" | add "Drawstrings, Braid, Paper, Headphones, Skateboard" |

## D. Other files this touches (for the packages that land it)

| File or module | Change |
|---|---|
| `BackLotBuilder` | the bike rack and one bike as fixed props; `DannyLeft` (bike fallen, backpack, sneakers), `DannyBeanie` and `QuizPaper` as switchable props; each bin's `Approach`, `Front`, `Leave`, `Gap`, `GapTarget` points |
| `tests/Specs/Story.spec.luau`, `web/tools/story-test.mjs` | the numbers and rules of opening-v3.md section 12 |
| `web` cutscene player | the engine staging of V01a to V20 on `CinematicTracks` first (the base); then task 51: the `Video` view, one clock, the drift rule, the fallback order `Video`, `Cinematic`, stills, the black seam; each page's own gap in R1 to R3 |
| `web/sounds` | the seventeen new presets; the five non-verbal takes; the name bank in three shapes and two voices (full, whisper) |
| `docs/design/requirements.md` | record under section 6 that the opening v3 script is final, with the three questions put to the player and the defaults taken |

## E. Amendments to append to the spec ("Spec amendments", newest last)

- 2.1 / 2.2 (opening v3): the mask sleeps small, smooth and downy off a host, with a round doll's face, and on one
  grows long, narrow and pointed; in the opening it is "the little guy". The Tall Man's face is the player's pick of
  17 Nov (B3), with big old veined hands; it replaces MONSTER-LOOK.md's oval mask. Kayla Brooks and Marcus Pike are
  P0 speaking classmates, seen from behind.
- 2.3 (opening v3): a shot's view may be `Video`, and then it also carries camera keys and actor tracks: the view
  falls back `Video`, `Cinematic` (the engine staging, the base on both platforms today), stills; the video file
  carries no audio; a name is spoken only by the monster's voice from the name bank; at most four `sync` lines a
  timeline.
- 2.4 (opening v3): Full 65.0 s, Short 24.9 s; the video's picture ends at 54.4 on the lid slam with 0.6 s of black;
  R1 to R4 are real time in each page's own bin; the last lid to the hand-over is 10.6 s (10.15 s with four). The
  bell's twelve tolls are 0.28 s apart and `BellToll` holds 7 voices (1.8 s held ÷ 0.28 s).
- 2.4 (opening v3): the party is the camera until 54.4; the opening has no `{P1}`..`{P4}` lines.
- 2.5 (opening v3): Danny lies bare-headed and barefoot; Ending A's first line is the monster's voice saying the
  shooter's name, then Danny's own: "Is it still on me?"; the beanie comes out of the shooter's pocket.
- 2.6 (opening v3): in Ending B's line said by both voices at once, the clean layer says "You were always my best
  friend." and only the monster layer adds the name from the bank.
- 3.4 (opening v3): the monster's lines are monster-lines.md; six new categories; unprompted lines at most one per
  120 s per listener and one per 45 s team-wide; 12 s between lines; 3 per 60 s.
- 4.1 (opening v3): the bike rack is a fixed prop; Danny's bike, backpack, sneakers and beanie lie in the lot from
  54.4, and Friday's quiz in a puddle near the gate; the beanie is taken by the first player within 4 studs, or at the chute's cut.

## F. Checked, and not changed

- 2.7 Sunrise's text, 2.8's graffiti and Walter's film, 4.3 Gus, the standoff's four lines, 4.10's
  cards, the invariants (I12 and I13 are kept more strictly than before: no "wet" sound, nobody catchable until the
  Basement).
- The lot's map, the bins' places, the prologue's timers (`LidHold`, `ClimbOut`, `AutoClimbOut` 8, `ChuteWait`,
  `ChuteCut`, `MaxSeconds`), the skip vote, `StoryConfig.Names`, `StoryConfig.Sets.BackLot.day` (overcast: the picture
  is lit to match it, not the other way round; see B `day`).
- MONSTER-LOOK.md: its face is replaced by B3's (the lead's decision of 17 Nov, task 46); nothing else here changes
  it. The opening explains the long face and the bare feet.
- 2.6 Ending B: one change only (the clean layer drops the name; see 2.6).
