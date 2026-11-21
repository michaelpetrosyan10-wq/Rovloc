# Stay Behind: creature and encounter bible (draft 2 of 6)

Creature designer's draft, 21 Nov 2026. Builds on research reports 03 (creatures), 06 (audio, section 4.2 to 4.3),
01 (survival, section 8) and the earlier hunter spec (`docs/design/monster/monster-v3-spec.md`, its numbers carried
over by name). Every number is a starting value for tuning, not a measured fact.

**How things are marked.** **[P]** = my proposal, not settled by the owner's answers; every [P] that truly changes
the game is collected in "Decisions for the owner" at the end. **[Lead Pn]** = the lead's working proposal n, used so
the six drafts agree, still to be put to the owner. Anything unmarked follows from the owner's own answers
(requirements.md sections 7 and 8).

**Units.** Metres and seconds. Danny's speeds [P]: crouch 1.3 m/s, walk 2.0 m/s, sprint 5.2 m/s for up to 7 s, then
3 s of slowed recovery. Noise uses the table in research 06 section 3.7 (level at 1 m, minus 20 log10 of walked path
distance, minus occlusion: closed door 15 dB, wall 30 dB). Each kind has a hearing threshold in that same scale.

**Three things that hold for every creature.**
1. **Tell before touch.** Nothing reaches Danny unless the player could have heard or seen it within the previous 2 s
   (5 s for the hunter). The builder tests this with simulated players (section 4.4).
2. **One rule per kind, said in one sentence**, never changed, only combined with other rules. A twist adds pressure; it
   never rewrites a rule.
3. **Patterns, never content.** No creature, look, sound, name or set piece below is taken from the model games. Where a
   pattern came from one, it is named only to say where it was seen.

---

## 1. The hunter

### 1.1 What it is
The thing that crawled out of the small ship. It is the ship's collector: it finds people and takes them alive. It
hunts Danny on every floor, in the city and on the mothership. Why the aliens came, and so what the hunter is for in the
end, is the owner's choice [Lead P8]; nothing below depends on which version he picks.

### 1.2 The body, from the favourite picture
The picture shows it leaning over a locker row from above, head hanging down, one hand gripping the locker edge. That
pose is its signature and its most-used "seen" beat. The design stays exactly; this turns it into a real-scale body.

- **Height about 3.0 m upright [Lead P7]**, only in tall spaces (gym, stairwells, the entrance hall, the tunnels' boiler
  vault, outdoors, the mothership). Shoulders only 40 cm wide; chest deep and narrow; legs long and thin, knees high.
- **Face:** about 55 cm long, 18 cm wide at the brow, tapering to a point; pale, slightly translucent skin; a deep
  wrinkled brow; huge black slanted almond eye holes, each with one pinprick of light; two dark streaks running down
  from the eyes; a fine vertical seam from the brow ridge to the tip; a small horizontal slit near the tip (the mouth,
  used only to whisper). The face is rigid like a mask of bone under skin: it never makes expressions. Only the tilt of
  the head and the pinpricks (which narrow when it focuses) show what it is doing.
- **Hood:** reads as heavy grey worn cloth; up close it is a loose fold of its own felted hide [P]. It sits low over the
  brow. In bright light the hood draws forward.
- **Hands:** the picture's hands exactly: big, old, veined, a black web of veins over the back, very long fingers (the
  middle finger about 22 cm). The arms reach below the knees. The hands are its most animated part: they touch
  everything (door frames, locker edges, ceiling grids) before the body follows.
- **The fold [P].** Its ribs are hinged and its shoulders unlock. It can fold to pass a 70 x 70 cm opening, which is
  the size of every crawlway and maintenance duct in the school. Folding makes a run of dry joint clicks (a tell) and
  takes 2 s each way, so it is never instant.

**Moving through a school built for people.** Corridor drop-ceilings are about 2.7 m and doors 2.1 m by 0.9 m.
- **Stoop walk** (corridors, classrooms): bent at the hips, neck forward, head carried at about 2.2 m, hands
  sometimes sliding along the ceiling grid. Ceiling tiles lift and drop back as its fingers pass: a line of tiles
  rattling at walking pace is a hunter tell (the Swarm's tile tell on floor 4 is different: bulging and dust, with
  chitter).
- **Doors:** hand first on the frame, head turned sideways under the lintel, then the body. About 1.5 s; it cannot do
  this silently.
- **Upright walk** (tall spaces): slow, long strides. **Its footsteps here are heavy and heard from far away**, as the
  owner asked: about 65 dB at 1 m on hard floors, heard through two walls.
- **Crawl** (under stages, crawlways, ducts, the mothership's channels): all four limbs, a soft multi-point patter,
  never footsteps.
- **Climb and hang:** it climbs lockers, shelving, pipes and stair rails, and hangs head-down from above. It does not
  walk on ceilings (the Dark Dwellers do; that keeps the two apart).
- **Speeds [P]:** creep 1.4 m/s, walk 2.4, chase 4.7 (under Danny's sprint, over his walk), crawl 1.1 (under Danny's
  crawl of 1.2: in a duct he can always stay ahead if he keeps moving).
- **It never teleports.** When it must be moved to a new area unseen, it travels only through spaces with no line to
  Danny, and the move takes the real walking time (carried over from the earlier spec).

### 1.3 Senses [P]
| Sense | Value (Survivor setting) |
|---|---|
| Sight, focus cone | 60 degrees, 25 m on a moving Danny in the dark, 40 m if he is lit or his torch is on; a torch beam crossing its eyes is seen at 50 m |
| Sight, side vision | 150 degrees, motion only, 10 m |
| Hidden Danny | never seen inside a closed hiding place it did not watch him enter |
| Hearing | threshold 25 dB received: a walk on tile is heard at about 10 m, a sprint at about 55 m, a crouch on carpet at under 2 m |
| Blood | follows fresh drips from a badly hurt Danny for 90 s |
| Light | does not fear it; a lit room helps only against the Dark Dwellers |

Continuous noise does not pull it straight to Danny. The interaction clock (1.5) is its answer to how loudly he
moves; only a single loud noise above the threshold earns a direct "reply" (a few heavy steps toward the sound), and
only a chase token turns noise into pursuit. This is carried over from the earlier spec, where hearing that counted
twice made it unfair.

### 1.4 Its rules, the same for the whole game
1. **You always hear it before it can reach you.** Every arrival is warned.
2. **It never enters a lit safe room whose door is barred.** (The one scripted breach, 1.9, breaks the light first,
   not the rule.)
3. **It cannot see into a closed hiding place it did not watch you enter.** It can search one if it heard you there.
4. **Fire and sudden very loud noise drive it off for a while; nothing kills it** (in the school; for the gun, see
   Decisions 6).
5. **It takes; it does not kill.** [Lead P2]
6. **Its whisper is always where it is.** [Lead P1]
7. **It remembers what you keep doing** (1.7).

### 1.5 What carries over from the earlier design, with its numbers
The two brains (a director steers it to an area; the creature finds Danny with its own senses), the interaction
clock, strain and backstage, the catalogue, chase tokens and the near miss, all keep their names so the old simulation
targets can be reused as tests.

**The interaction clock** (the owner's cadence: "noticed often, attacks rarely"). Mean gaps, the same on every
difficulty (difficulty changes danger, not how often it makes itself felt):

| How Danny moves | Gap (s) | Notes |
|---|---|---|
| Sprint | 14 | a stamina-limited sprinter measures 15 to 20 s |
| Walk | 30 | |
| Working (a puzzle, a valve, a lock) | 40 | |
| Crouch | 60 | |
| Still, upright and quiet | 75 | |
| Hiding | 75 | pass-bys and sniffs first |
| In a duct or crawlway | 40 | duct beats only |

Kept as they were: the threshold drawn between 0.6 and 1.4 of a gap; a lull (gap doubled) every 5 to 7 interactions
so it never feels like a timer; Danny's own loud noises add a lump to the clock (door slam 0.25, debris underfoot 0.35,
generator start 0.5); the first heard beat no sooner than 20 s and the first seen beat no sooner than 40 s after a
stretch starts.

**Strain** (how much pressure Danny has just had, 0 to 1): rises 0.04/s while he sees it, 0.06/s while it is within
5 m walked [P: the earlier 15 studs re-set in metres], 0.05/s in a chase; falls 0.02/s after 5 s of nothing. Close
beats only below 0.45, seen beats only below 0.65; at 0.8 it goes **backstage** for 25 to 40 s (its clock at half
rate, kept at least 25 m walked away) until strain is 0.35 or less.

**The catalogue, as beats in a 3D school** (tier 0 heard, 1 seen, 2 close):
H1 heavy steps somewhere near; H1b running steps; H2 a door or locker it touches in the next room; H3 in the ducts or
pipes; H4 a slow breath through a wall; H5 the whisper (at most one per 2 minutes); S1 it crosses ahead at a corridor
end; S2 it leans out of a doorway or over a locker row (the picture's pose); S3 it stands watching at the dark end of
a corridor; S4 its face at a vent grate; C1 it walks past close while Danny keeps still; C2 it passes his hiding place;
C3 a warned arrival; C4 it sniffs at his hiding place and leaves; F a sound the building makes that only might be it;
Reply; NearMiss.

**The leash [P, re-set in metres]:** it keeps 12 to 30 m walked from Danny (Story 18 to 40, Stay Behind 10 to 25),
never closer than 5 m outside a close beat or a chase.

**Chases** run on a token. For this long game [P]: one token per 6 minutes of hunter-active play on
Survivor (Story 10, Stay Behind 4), at most one held, none in a teach phase. A chase trigger without a token becomes
the **near miss**: it screeches, takes two steps at him, and backs away; no sooner than 45 s after the last one.
Chase rules: it gives up after losing sight for 8 s if Danny is hidden or two rooms away; every chase route the
level offers has at least one exit it did not watch (a door he can bar, a crawlway, a hiding place); it can catch only
within 1.5 m. After a chase or near miss: 25 to 40 s of nothing.

**Hiding pays:** hide within 20 s of a beat and a pass-by is owed 12 to 20 s later. A sniff it was not led to by Danny
never ends in a catch.

### 1.6 The whisper [Lead P1]
- **Only words those people really said on screen**, cut into new broken fragments ("Danny ... you said ... the
  door"). Processing as research 06 section 4.3 (whisper re-synthesis keeping the speaker's identity, uneven timing,
  a second take 40 ms late, a frozen tail). Intelligibility is a hard gate.
- **Always from its true position, with true occlusion. It is a warning, never a lure.** The Mimics are the liars
  (2.4). **Nothing ever fakes Kayla on the radio.**
- **Where the voices come from:** the first bank is the people Danny and Kayla talk to in the prologue's first ten
  minutes (the friend at the ticket table, the announcer on the PA, the couple on the steps): they are taken that
  night, so the player has heard each voice alive. Each survivor who is lost later joins the bank; a survivor Danny
  left behind (a quiet choice) is the voice it uses most on the mothership.
- **Budget:** at most one whisper every 2 minutes while it is active, never the same fragment twice in a chapter,
  never during a cutscene or a Grief scene. It whispers Danny's name at most once per chapter.
- **Kayla's voice** after she is taken: see Decisions 2.
- **Its silence is its worst sound:** when it focuses on Danny, the whispering stops.

### 1.7 Habits it learns [P, pattern: the stalker that unlocks behaviours in Alien: Isolation]
The game keeps a ledger per save. When a count passes its threshold, one habit unlocks:

| Danny keeps doing | Threshold | It learns to |
|---|---|---|
| hiding in lockers | 6 hides | open lockers first when it searches |
| hiding under desks and beds | 6 | sweep low with a hand when it searches |
| using one duct or crawlway | 4 uses | wait at that duct's far end (its face at the grate is shown) |
| throwing distractions | 6 throws | ignore the first throw and look back toward the thrower |
| slamming or barring doors | 5 | test barred doors; a wedged door holds 4 s less |
| scaring it with flares | 2 flares | wait at the edge of the flare light instead of leaving |
| using the torch a lot | 10 minutes lit per chapter | come toward a beam from farther away (60 m) |

Rules: never learned from a death; at most one new habit per chapter; each shown once, clearly, the first time (it
opens the locker next to Danny's, slowly, and walks on); a habit fades if Danny stops the behaviour for two whole
chapters, so the player can answer it; Story learns none of the punishing ones (lockers, desks, ducts); at most four
active at once. On the mothership all learned habits are active up to that cap: the final exam.

### 1.8 A catch by the hunter (taken) [Lead P2]
Never gore. The long hand comes over Danny's shoulder or from above; the view is lifted off the floor; the face fills
the screen with the two pinpricks narrowing; one whispered fragment; Danny is dragged backwards on his back, his
fingers scraping the floor in view, into the dark; the picture cuts to black while the drag sound continues for one
second, then silence; reload. About 5 s; skippable after the first time.

### 1.9 Chapter by chapter
Active share is the part of the chapter's play time it is simulated near Danny.

| Chapter | Active | Its configuration |
|---|---|---|
| Prologue, the evening event | 0 | Scripted only: seen far, crawling out of the small ship; once in the stairwell down, its hand curls round the door frame above Danny while Kayla pulls him on. No failure. |
| 1, the basement | about 40% | First 20 min heard only (H1, H3 in the pipes, H5 once). **Absent** while the Dark Dwellers are taught. Returns for the tunnel and fuel runs: seen beats, its first near miss, one chase in the tunnels at the chapter's end. The Dwellers go silent and pull into the cracks when it comes: a cross-tell. |
| Between chapters, the safe room | 0 | Off stage. The pipes stop knocking; Kayla's radio is clear. The player feels "gone for now". |
| 2, first floor, Listeners | about 45% | Absent in TEACH. In TEST heard and seen. In TWIST it comes onto the Listener floor: its heavy steps make Danny want to run, and running is what the Listeners hear. **New:** the Listeners hear its steps too and rush them; it swats one away: Danny can use its walk as cover. |
| 3, second floor, Still Ones | about 45% | Absent in TEACH. In TWIST its whisper behind Danny makes him turn his head, used twice at most. It is not slowed by the Still Ones, so watching them never protects Danny from it. |
| 4, third floor, Mimics | about 35% | Quieter on purpose: only heard beats near the Mimics so its whisper and their voices are never in the same minute. Hearing both on one floor, never in the same minute (its broken whisper from where it is, their whole sentences from the wrong place), is how the floor teaches the difference. |
| 5, fourth floor, Swarm, then the roof | about 55% | TEST: hiding stops it, but the Swarm finds a still warm body. Set piece: the Swarm covers the hunter in a duct; Danny hears the fight. Then **the safe-room breach** [P]: something drains the generator, the room goes dark, the bar no longer protects it (rule 2 kept: the light failed first); the group must move to the roof. **The roof:** its one long, built chase (about 90 s, a funnelled route, no token needed), ending at the helicopter. |
| 6, the city | about 25% | **New:** outdoors it stands its full 3 m and runs on all fours across roofs and awnings (6 m/s, so in the city Danny never outruns it in the open; he breaks line of sight). Mostly a silhouette on rooftops; three close beats in the whole chapter. The Patrol owns the streets. It reaches the landing pad as Danny takes the ship. |
| 7, the flight | 1 beat | Optional set piece: its hand on the canopy; Danny scrapes it off against a spire (Decisions 7). |
| 8, the mothership | about 60% | **Full return with every learned habit.** **New:** the ship is built for its body: its own channels in the walls (crawl speed 1.8 m/s inside them, faster than Danny), membrane doors that open for it and not for him; in low gravity it is at home, pulling itself along surfaces while the Brute flounders. Its final scene at the self-destruct is the story draft's to write. |
| Epilogue, as Kayla | 0 | Never seen. One sound at most, if the story wants it. |

---

## 2. The seven kinds

Difficulty names follow research 01 (Story, Survivor as the recommended one, Stay Behind unlocked after finishing); the
creature dial can change at any time. Every catch by a local kind is a **maul** [Lead P2]: a graphic first-person
death of 3 to 5 s, skippable after the first time, with a setting to cut away early. Gore is on the creature and on
Danny only. All looks and sounds are [P] and original.

### 2.1 The Dark Dwellers (basement, Chapter 1, when the power fails)
- **Rule:** "They can't go into light. Keep the generator running, and when it dies, stay in light."
- **Look and sound:** flat grey bodies like wet leather sheets about 1.6 m long, hanging in ceiling corners and over
  pipes, edged with 12 to 16 thin finger-limbs; the only face is a vertical slit of small teeth. In light they blister,
  smoke and shrink back into cracks. Far: wet clicking and a scrape on concrete; near: the clicking speeds up and a
  chorus of small inhalations; caught in a beam they fall silent and a hiss rises.
- **Senses:** feel footsteps within 8 m in darkness (above 40 dB at 1 m); smell blood at 15 m; notice any light
  switched off within 20 m. They cannot enter a lit volume (authored light volumes plus the torch cone, 9 m long,
  30 degrees). Ceiling creep 1.0 m/s; a lunge from darkness covers 3 m at 6 m/s.
- **Tells:** far: the lights flicker and the generator note sags a minute before the fuel runs out (the coach's
  stopwatch beeps at 60 s); near: clicking just outside the beam.
- **Counters and tools:** fuel (the currency); the breaker panel (which rooms are lit); the torch (batteries; the
  wind-up torch as the free, noisy fallback); glow sticks (a 2.5 m pool for 90 s), road flares (6 m for 60 s, which
  also drive the hunter off); the battery EXIT signs. This chapter introduces the torch, the stopwatch and the flare.
- **Teach:** the first outage happens inside the safe room, with the survivors there: Gus gets a battery lamp on and
  one shrivels back into a crack. **Test:** a fuel run through dark storage, laying flares as a trail home. **Twist:**
  the breaker can light two of three circuits (the infirmary fridge, the corridor to the fuel, the survivors' room): a
  quiet choice.
- **Set pieces:** (1) *The lamp count*: the first outage, the survivors counting aloud as Gus works. (2) *Flare road*:
  the bus-garage fuel run with four flares for a route that needs five; the last stretch is crossed on glow sticks.
  (3) *Two of three*: Dwellers pressing at the glass of the circuit Danny left dark while he works the panel.
- **Catch (maul):** pulled up from the edge of a light pool into the ceiling; the fingers close over his face; blood
  falls past the torch beam. Graphic.
- **With the hunter:** it does not fear light, so "safe" is per creature. When it passes, the Dwellers go silent and
  pull into the cracks: silence in the dark means the hunter, not safety.
- **Difficulty:** Story: a tank lasts 18 min, lunge 2 m, the torch flinches them at 9 m. Survivor: 12 min, 3 m, 9 m.
  Stay Behind: 9 min, 3.5 m, 5 m; the clock runs in the safe room too.
- **Unfair, and how not:** a screen too dark to read (players raise the brightness and the horror dies): keep a
  floor of readable darkness, wet highlights on their bodies, and exit signs; light-pool edges must look exactly like
  their gameplay edges (dust in the light). They never lunge from behind without 2 s of clicking first.

### 2.2 The Listeners (first floor, Chapter 2)
- **Rule:** "They're blind and they hear everything. Move when the building is loud; freeze when it's quiet."
- **Look and sound:** about 2.3 m, eyeless, the skin pulled tight as if the body grew round a skeleton too small; the
  head a fan of thin folded membranes that spread open toward a sound. A soft breathy hum through the fan while they
  search. They do not click (a known signature of other games' blind creatures).
- **Senses:** hearing only, threshold **15 dB received** (walking on tile is heard at about 30 m, walking on carpet
  at 14 m, crouching on carpet at 5 m). One sound above threshold: the head turns toward it (1.5 s). A second within
  6 s, or one above 35 dB received: they walk to the source at 1.6 m/s. Above 50 dB: they rush the source at 5.5 m/s.
  They go to **where the sound was**, not to Danny, and they grab only if he is within 1.5 m and makes a sound there.
- **Tells:** far: the hum; **the hum stopping means one has locked on**. Near: the fan opens; membranes rustle.
- **Counters and tools:** the floor's surfaces (the "stuff on the floor" is the mechanic: carpet, tile, the dance's
  cups, balloons, glitter, broken glass, water); masking (the heating knocks every 40 to 70 s for 4 s and masks up to
  20 dB; rain on the gym roof comes in waves; a stuck PA hum); throwables; shutting doors; holding breath within 3 m.
  This floor introduces the **kitchen-timer rattle** (crafted, thrown, ticks then rings) and the office **bell panel**
  that rings bells in another wing. The real microphone is never used.
- **Teach:** a Listener behind the glass of a trophy case; glass cracks under Danny's foot and it slams the case.
  **Test:** a debris corridor with two of them and timed heating knocks. **Twist:** the hunter comes onto the floor.
- **Set pieces:** (1) *The trophy case.* (2) *The gym in the rain*: the dance floor still covered in the evening's
  leftovers, crossed only in the waves of rain on the roof. (3) *The bell panel*: ring the far wing to pull three of
  them away, then work the office safe while they walk back.
- **Catch (maul):** the fan closes over Danny's head. Graphic.
- **With the hunter:** they hear its heavy steps and rush them; it swats one into the lockers. Its walk is cover,
  its arrival a temptation to run.
- **Difficulty:** threshold Story 20 dB, Survivor 15, Stay Behind 12; rush speed 4.5 / 5.5 / 6.
- **Unfair, and how not:** instant death from one noise (the criticism made of other blind-creature games): never;
  a heard noise turns them and brings them, it never kills by itself. Feedback is consistent: every sound Danny makes
  plays at its true level, so the ear learns the scale; Story adds an optional noise ring that shows the same number.

### 2.3 The Still Ones (second floor, Chapter 3)
- **Rule:** "They only move when nothing is watching them. Your eyes, your light, or a camera keeps them still."
- **Look and sound:** long folded figures of dark bark-like chitin, about 2 m when they stand, faces hidden in their
  own long hands. Each time Danny looks back, the hands are a little more open. Watched: true silence, a little dust
  drifting off them. Unwatched: a dry wood-bend creak and a joint tick, placed exactly where the body is.
- **Senses:** they know whether they are **watched**: at least a quarter of the body's sample points on screen, within
  30 m, not hidden behind anything, **and** lit (room light or Danny's torch). On screen but in darkness is not
  watched. A powered camera with its red light on watches its own cone. Mirrors and phone screens do not count (taught
  once, by a changing-room mirror that fails to hold one) [P]. Unwatched they move toward Danny at
  3.0 m/s and kill if within 1.2 m after 0.4 s unwatched.
- **Tells:** far: the creak and tick from out of view, always positioned; near: a creak behind you within 5 m means
  turn now.
- **Counters and tools:** keep them lit and in view; walk backwards along walls; close doors (they cannot turn
  handles). This floor introduces the **AV-room camcorder on a tripod** (one battery holds a corridor for 4 minutes)
  and **Kayla's eyes**: through the school's CCTV, a camera Kayla is watching holds the Still Ones in its view.
- **Teach:** one in a lit classroom; Danny leaves and comes back and it has moved two desks. **Test:** a corridor of
  them under a failing fluorescent light. **Twist:** the floor's power strobes, and each dark frame is a step.
- **Set pieces:** (1) *Two desks closer.* (2) *Kayla's eyes*: she holds the west corridor on CCTV while Danny works
  the music-room puzzle; mid-puzzle her camera goes dark (the hunter tore it down) and she has to say so. (3) *The art
  room*: a room of sheeted easels and sculptures where only some shapes are Still Ones; the camcorder can hold one wall.
- **Catch (maul):** Danny turns and it is there; the hands open (the only time the face is seen) and fold him in.
  Fast and graphic.
- **With the hunter:** its whisper from behind makes you turn your head (twice at most); watching the Still Ones
  never slows the hunter.
- **Difficulty:** Story: they freeze while Danny opens a door, need 0.8 s unwatched, kill range 1.0 m. Survivor:
  0.4 s, 1.2 m. Stay Behind: 0.25 s, 1.4 m, and opening a door is unwatched time.
- **Unfair, and how not:** "it got me while I was looking" (so watching is generous: a quarter of the body is
  enough); walking backwards forever (answered by doors whose handle must be looked at, the strobe, and pairs on
  opposite sides); deaths without warning (none spawn unseen within 6 m; every kill needs a creak in the 3 s before).

### 2.4 The Mimics (third floor, Chapter 4)
- **Rule:** "From behind they look like people and they call in voices you know. They never answer you."
- **Look and sound:** from behind, a person-shaped growth: a hood and "hair" of their own fibrous skin, the head held
  a little too still. From the front there is no face: the whole front is a ribbed hollow like the inside of a shell,
  lined with folds that make the voice. They speak in a **plain, full voice** [Lead P1]: whole sentences, perfectly
  clean, no breath between words, a faint second voice underneath, the same line with exactly the same timing each
  time. Their steps are slightly too even.
- **Where the voices come from [P]:** they learn what they hear. On this floor they learn from Danny's radio: a line
  Kayla said over the radio here can come back to him minutes later from a doorway. So **they only ever say things
  already said**, and radio volume on this floor is a real choice. They never use the radio (nothing fakes Kayla on
  the radio).
- **Senses:** sight and hearing like a person, forward only; they need Danny within 3 m to strike. They turn in 1 s
  (the front unfolding) and lunge 2 m. Out of his sight they move to block a route and call again.
- **Tells:** they always stand facing away; they never answer a question; the room tone drops around them; no breath
  between words; the repeated line.
- **Counters and tools:** Kayla sets a **code word** at the safe room: real people answer it, Mimics say it back
  exactly. A thrown object: a person flinches, a Mimic does not. This floor introduces the **yearbook club's camera
  with flash** (the flash shows the front and stuns a Mimic for 3 s; one flash per battery).
- **Teach:** Kayla's voice calls from the end of the corridor while she is talking to Danny on the radio at the same
  moment. **Test:** the dark library with several figures and one real student hiding (a quiet choice). **Twist:** a
  real survivor too frightened to answer the code word; Danny needs the second tell.
- **Set pieces:** (1) *Two Kaylas.* (2) *The library*: four figures among the stacks, one real. (3) *The answer*: a
  voice behind a locked classroom door repeats the code word perfectly, and the student who is really there says
  nothing; Danny has to throw something and listen for the flinch.
- **Catch (maul):** it turns, the front opens, and Danny is drawn in. Graphic.
- **With the hunter:** kept apart in sound (1.9): whisper and whole voice are never in the same minute.
- **Difficulty:** Story: Kayla repeats the code word on request, strike range 2 m. Survivor: 3 m. Stay Behind: 3.5 m,
  and one Mimic per floor repeats a code word with a small delay (the timing tell still holds).
- **Unfair, and how not:** a mimic with no consistent tell is a coin toss (players of other games settle on "it does
  not respond to you" as the fair tell): ours have three. They never wear the body of a taken student: they grow a
  shape, which keeps the students off screen.

### 2.5 The Swarm (fourth floor, Chapter 5)
- **Rule:** "They follow warmth and movement. Go cold and keep still and they pass you by."
- **Look and sound:** finger-length segmented things, translucent, the heat they have taken in showing as a pale glow
  inside them, whiter as they warm; a mass of them brightens as it nears warmth. A granular chitter like rice in a pan, moving through the
  ducts overhead; a dry rush when the mass moves as one.
- **Senses:** body heat within 4 m; movement faster than 0.5 m/s within 6 m; strong heat sources draw them from 15 m.
  They come through vents and ceiling tiles.
- **Tells:** far: the chitter overhead; near: ceiling tiles bulge and dust trickles; the glow rising.
- **Counters and tools:** cold (the cafeteria's walk-in freezer, the CO2 extinguisher, open windows, the cooler of
  dry ice, cold packs); heat decoys (a kettle, a space heater); tape over vents; standing still. This floor introduces
  the **science room's thermal camera** (shows them in the ducts; costs battery). Crafting stays game logic only.
- **Damage:** contact stings stack: three contacts and Danny is slowed for 20 s; a mass on him starts a struggle; a
  mass on him for 6 s kills.
- **Teach:** a space heater on in a classroom; they pour onto it and ignore Danny. **Test:** a vent corridor crossed
  between cold spots. **Twist:** Danny is wounded and bleeding, so he is warmer; then the building's heating comes on.
- **Set pieces:** (1) *The heater.* (2) *The cold line*: a corridor where the only path is from window to window.
  (3) *The duct fight*: the Swarm covers the hunter in the duct above Danny; the ceiling sags and splits.
- **Catch (maul):** covered, stung, dragged down. Graphic.
- **With the hunter:** stillness hides Danny from one and not the other; the heater that draws the Swarm also lights
  him for the hunter.
- **Difficulty:** Story: heat range 3 m, 9 s to kill. Survivor: 4 m, 6 s. Stay Behind: 5 m, 4 s.
- **Unfair, and how not:** swarms are hard to read: run them as one mass with a few lead bodies (the pattern that made
  big rat swarms work), so the player reads one shape, not hundreds.

### 2.6 The Patrol (the city, Chapter 6)
- **Rule:** "They search with lamps and scanners, room by room. Stay out of the beams and hide your heat behind
  metal."
- **Look and sound:** about 2.2 m, armour that looks grown rather than made, a cluster of lamps on one shoulder like
  eyes. They talk in the alien language (each symbol a syllable), so learning the symbols lets the player follow
  them: slow call and answer while searching, a sharp single word when suspicious, fast overlapping calls when they
  have him. What they are to the hunter (masters, keepers, the same people) is the story draft's [Lead P8].
- **Senses:** lamp cone 50 degrees, 25 m; a scanner pulse every 8 s, 18 m round, that sees heat through walls under
  20 cm thick unless metal is between; hearing threshold 25 dB. They search in pairs, room by room, and check the
  places a person would hide.
- **Tells:** far: the pulse's sound and the language; their ship's idle hum marks landing pads. Near: lamp light
  sweeping across the gap under a door.
- **Counters and tools:** metal hides heat (cars, dumpsters, vending machines); interference (car alarms, live power
  lines) blinds the scanner for 10 s; cold water; the takedown from behind (once scripted, then systemic). This
  chapter introduces **the alien gun** (very little energy) and a stolen **scanner** that shows them through walls
  but whose pulse they hear.
- **Teach:** from a roof, Danny watches them take a person (heard, not seen). **Test:** cross a block. **Twist:** he
  carries the scanner.
- **Set pieces:** (1) *The laundromat*: two of them search it room by room while Danny moves dryer to dryer. (2) *The
  takedown* that gets him the gun. (3) *The landing pad*: the ship, the Patrol and the hunter converge.
- **Catch:** **taken** [Lead P2]: a collar of light, dragged into the lamp glare, cut to black. With the gun, a fight
  is short; what the gun does to them is Decisions 6.
- **With the hunter:** they own the streets, it owns the roofs.
- **Difficulty:** Story: cone 40 degrees and 18 m, pulse every 12 s. Survivor: as above. Stay Behind: 60 degrees and
  30 m, pulse every 6 s.
- **Unfair, and how not:** unclear vision cones: the lamps are the cones, visible in the air; few and audible beats
  many and silent.

### 2.7 The Brute (the mothership, Chapter 8)
- **Rule:** "It's slow and it tears open anything soft. Hide behind metal or in small spaces, or keep moving."
- **Look and sound:** about 3.5 m and very broad, hull plating grown into its flesh, veins glowing through the seams.
  Footfalls with energy under 60 Hz that shake the deck, felt in the controller; breath like a bellows; vocal fry; the
  scrape of plates; a tearing sound of its own.
- **Senses:** smell 12 m and a scent trail up to 30 s old; hearing threshold 35 dB; sight 10 m. Walk 1.6 m/s, charge
  4 m/s in a straight line, turns slowly (90 degrees a second).
- **Tells:** the deck shakes from far away; **before it tears a hiding place open it taps and sniffs it for 2.5 s**:
  that window is the fairness of its rule. Soft hiding places (membrane pods, cargo nets, resin) look soft; hard ones
  (metal lockers, conduits, spaces under 60 cm) look hard.
- **Counters:** hard or small hiding places; loops round big rooms (it cannot turn quickly); the low-gravity stretch
  (it is heavy and slow to push off, Danny is light); the gun staggers it for 3 s.
- **Teach:** from a safe vent, watch it tear a pod open. **Test:** a hold with soft and hard hiding places. **Twist:**
  the low-gravity stretch.
- **Set pieces:** (1) *The pod hall*: it tears pods while Danny crosses on the hard ones. (2) *The loop*: a round
  engine room Danny circles while a door cycles open. (3) *Zero-weight*: it loses its footing in low gravity and
  tumbles past, still reaching.
- **Catch (maul):** torn out of the hiding place. Graphic.
- **With the hunter:** the Brute takes hiding away and the hunter takes running away; they are never both active in
  the same room.
- **Difficulty:** tear window Story 3.5 s, Survivor 2.5 s, Stay Behind 1.8 s; smell 9 / 12 / 15 m.
- **Unfair, and how not:** it denies the main verb (hiding), so every Brute space has a clear loop and a readable
  hard spot within 10 m (the old lesson: a slow pursuer works when you can out-route it, not wait it out).

---

## 3. The kinds on the mothership, in their natural roles [P]
The school's kinds were stray: things that came down with the small ship and fell into the building's dark. On the
mothership each is shown doing what it is for, in a more complete form. One kind per space, never two local kinds
pressing at once, and no new rules: only the old ones in a new place.

| Kind | Its role on the ship | Natural form | Where (minutes) |
|---|---|---|---|
| Dark Dwellers | the ship's cleaners in its unlit service spaces | larger, sheet-like, lining whole walls | the maintenance underdeck (10) |
| Listeners | the wardens of the halls where the taken are held: they hear any captive waking | taller, the fan grown into a hood of membranes | the holding halls (15) |
| Still Ones | growers, rooted in the walls of a garden deck, moving only along their roots | half wall, half body | the garden deck (10) |
| Mimics | the voice-keepers beside the taken, learning their voices | the front hollow open and humming | inside the holding halls, in the quiet choice of whom to free (10) |
| The Swarm | the ship's living heating, in the warm core | a drifting cloud in low gravity | the low-gravity stretch (10) |
| The Patrol | its crew on the decks | unchanged | the decks (15) |
| The Brute | its loader and guard | unchanged | the holds (20) |

The hunter moves through all of it, at home (1.9).

---

## 4. The director: menace across nine hours [P]

### 4.1 One director, one menace budget
One director (a C++ world subsystem with a pure, seeded rules library, as research 03 recommends) runs every creature.
Each chapter loads a configuration asset: which hunter beats are unlocked, the leash, the chase-token period, the
hunter's active share, which local kind is in which phase (teach, test, twist), and the habits learned so far.
**The hunter and the local kind spend from one strain gauge.** When a local kind has just pressed Danny (one passed
within 3 m, or a lock-on), the hunter's clock runs at half rate for 30 s. That is how the two never stack.

Every authored beat carries an intensity from 1 to 10 (pattern from the Dead Space remake's graded events). Rules:
- no two beats of 8 or more within 6 minutes; after each, at least 2 minutes at 4 or less;
- each floor's arc is **teach (intensity 3 to 5, hunter absent) -> test (5 to 7) -> twist (7 to 9)**, about 15, 20 and
  15 minutes of a 55-minute floor, with the floor's puzzles laid through all three;
- one loud stinger at most per 10 minutes outside chases; the best scares are sounds stopping;
- the peak of the whole school is the roof chase; the city drops back to a lower, wider menace; the mothership
  climbs to the game's highest sustained level and ends in the run to the pods.

### 4.2 Quiet stretches, guaranteed
- **The safe room** between chapters: at least 8 minutes with no creature tell of any kind (the pipes silent, Kayla
  clear), except the single scripted breach.
- **After every chapter climax:** 3 to 5 minutes of release before the next pressure.
- **Grief scenes** (a survivor lost): creatures silent by design.
- **Puzzle rooms the player has sealed** (a barred door, a lit room on the Dwellers' map) put the hunter off stage.
- Across the game the hunter is active in about 45% of play time; at least a quarter of every chapter has no hunter
  and no pressing local kind.

### 4.3 The "not too hard" guarantee (Survivor setting)
The owner said "i also dont want the game to be too hard". On Survivor, the director promises:
- a careful player (crouches near creatures, uses the floor's tool, hides after a tell) is caught **no more than
  once per chapter on average**, and finishes each chapter within 25% of its target minutes;
- no stretch between saves needs more than **3 attempts** for 90% of simulated careless players;
- after two catches in the same stretch, the director lowers that stretch's danger quietly (leash +5 m, chase tokens
  paused, local thresholds eased by one Story step) until the stretch is passed; never shown, never on Stay Behind;
- a catch never costs more than the restart rule allows (Decisions 4);
- the cadence is never lowered (the owner asked for it by name); only danger moves.

### 4.4 When a creature is "done": numbers a simulated player must hit
The rules run headless in Unreal's automation tests with seeded simulated players (old profiles: Sprinter, Walker,
Croucher, Hider, Mixed; new: Careful, Careless, Backpedaller, Answerer, Statue). Over 200 seeded runs per stretch:

| Creature | Must hold on Survivor |
|---|---|
| All | 100% of catches had a tell in the previous 2 s (hunter 5 s); 0 catches while hidden in a place it did not see Danny enter; Careful caught at most 1 per chapter on average |
| Hunter | measured gaps 15 to 20 s (Sprinter), 27 to 33 s (Walker), 54 to 66 s (Croucher); at most one chase per 6 minutes of active play; near misses at least 45 s apart; no catch from a sniff not led by Danny; never seen to teleport (no move with a line to Danny that is not walked) |
| Dark Dwellers | Careful with fuel never caught while in a lit volume; a fuel run done with half its flares succeeds 80% of the time |
| Listeners | Careful (carpet, masks) caught under 10% per corridor; Walker caught 40 to 70%; Sprinter over 90%; every catch preceded by a hum-stop at least 1.5 s before |
| Still Ones | Backpedaller cannot clear the strobe corridor without the camcorder or a door (proves the exploit is closed); every kill preceded by a creak within 3 s; no kill while 25% of the body is on screen and lit |
| Mimics | an Answerer (walks to every voice) caught 60%+; a player who uses the code word never caught by a Mimic it questioned |
| Swarm | Statue in a cold spot never killed; a mover through warm rooms killed 50%+ |
| Patrol | a player who keeps metal between himself and the pulse is never scanned |
| Brute | the tap-and-sniff window is always at least 2.5 s; every Brute space has a loop the sim can circle for 60 s |

A creature is done when these hold, the owner has played its chapter, and its look has passed his eye.

---

## 5. Scope: building eight creatures

### 5.1 What can be shared
| Shared piece | Used by | Notes |
|---|---|---|
| **Humanoid skeleton family** (the engine's standard mannequin bones plus extra neck, finger and spine bones), retargeted with the IK retargeter | Listeners, Mimics, Patrol, Still Ones | Mimics must read as a person from behind, so they need human locomotion; Motion Matching from the Game Animation Sample covers Patrol, Mimic and Listener walking |
| **The hunter's own skeleton** (3 m, long arms, hinged ribs, extra spine) | the hunter only | humanoid walking can be retargeted for the stoop walk; the crawl, the fold, the hang and the door pass are its own (the largest custom set in the game: it is the star) |
| **Surface crawler rig** (Control Rig procedural legs on any surface) | Dark Dwellers; the hunter's climbing and hanging | one authored surface graph for vents, ceilings and pipes, also used by the Swarm's routes |
| **Mass plus Niagara** | the Swarm | no skeleton; a few lead bodies as simple actors |
| **Senses kit** (the noise table, the "watched" query, light and heat volumes, scent trails) | all | one C++ module; each kind reads only what its rule needs |
| **State Tree base** (idle, investigate, search, pursue, catch, flinch, retreat) | all | Listeners and Brute share the "go to the sound or scent" core; Patrol shares the hunter's room search |
| **Smart Objects for hiding places** | player, hunter, Patrol, Brute | search and tear are uses of the same object |
| **Catch-scene framework** (camera rig, cut-to-black, skip) | all | taken and mauled are two templates |

### 5.2 What cannot be shared
The hunter's whisper pipeline and habits ledger; the Dwellers' light-edge behaviour; the Still Ones' pose library (cheap:
about 25 poses and a catch, because they are never seen moving); the Mimics' voice-learning from the radio and their
unfolding front; the Brute's own navigation mesh for its size and its tearing animations on each soft hiding place; the
Patrol's language-built speech; each kind's catch scene.

### 5.3 Build order
1. **The hunter** with the senses kit, the director and the clock (it is in the first slice: safe room, tunnel, hunter,
   one puzzle). Prove the old cadence numbers in the new engine first.
2. **Dark Dwellers** (same basement, completes Chapter 1; brings the surface rig).
3. **Still Ones** (cheapest body; proves the "watched" query).
4. **Listeners** (proves the noise table end to end).
5. **Mimics** (needs the voice pipeline and the radio).
6. **The Swarm** (Mass and Niagara: a separate technical risk, started in parallel as a spike once 1 works).
7. **The Patrol** (needs the city and the gun).
8. **The Brute** (needs the mothership and its own navigation mesh).

---

## Dependencies on other drafts
- **Story:** who takes Kayla (Decisions 3); who the prologue's first taken voices belong to (1.6); the six survivors'
  recorded lines (20 to 40 each) as the whisper bank; the safe-room breach in Chapter 5 as the reason to go to the roof
  [P]; the hunter's last scene; what the Patrol are to the hunter [Lead P8].
- **Systems and survival:** Danny's speeds, the noise table, the backpack, the difficulty preset names, saving and the
  restart rule (Decisions 4), the save point on each floor [Lead P3] (no saving with a creature hunting within 25 m).
- **Phones [Lead P4]:** the Still Ones' tool is a camcorder, not a phone, so it works whatever is chosen; if the
  mothership's field makes dead electronics wake and chirp now and then, that is a good Listener-floor twist (a dead
  phone in the backpack suddenly sounding).
- **Audio:** the Listeners do not click (research 06 proposed a click; research 03 warns it is another game's
  signature); the hunter's upright steps are heavy and far-heard as the owner asked, its crawl is a patter.
- **Levels:** every crawlway and duct at 70 x 70 cm or more; light volumes matching what is seen; every Brute space
  with a loop.

---

## Decisions for the owner

1. **When a creature catches Danny, do some take him and some kill him?** [Lead P2]
   (a) The hunter and the alien soldiers take him (dragged away, screen cuts off); the animal-like kinds kill him in
   graphic death scenes. (b) Every creature kills him graphically. (c) Every creature takes him.
   **Recommend (a):** it keeps the story's rule that people are taken alive and still gives the graphic deaths he asked for.
2. **After Kayla is taken, does the hunter ever whisper in her voice?** [Lead P1 extended]
   (a) Never. (b) Rarely, in person (at most once a chapter, from where it really is; never on the radio). (c) Once
   only, on the mothership.
   **Recommend (b):** it is the saddest use of the stolen voices, and it stays a fair warning.
3. **Who takes Kayla when the helicopter goes down?**
   (a) The hunter itself, seen by Danny as he falls. (b) The alien soldiers. (c) Not seen.
   **Recommend (a):** it makes the hunter personal for the rest of the game and explains how it has her voice.
4. **When Danny dies, where does he start again?** (shared with the survival draft)
   (a) A quiet retry point at the start of the encounter on Story and Survivor; the last written save on Stay Behind.
   (b) Always the last written save. (c) Retry points on Story only.
   **Recommend (a):** losing 20 minutes to one death is what makes a horror game feel "too hard".
5. **Can Danny break free once from the hunter's grab?**
   (a) Yes, if he holds a flare or the extinguisher, which is spent. (b) Never: every grab ends it. (c) Only on Story.
   **Recommend (a):** a scarce item becomes a life, and the near escape is a scene people remember.
6. **What does the alien gun do to the creatures?**
   (a) Kills the soldiers in three shots (graphic); only drives off the hunter; only staggers the Brute and the local
   kinds on the ship. (b) Only stuns everything. (c) Kills everything except the hunter.
   **Recommend (a):** the gun feels real against the soldiers but never solves the hunter, which must stay unbeatable.
7. **Does the hunter come after Danny during the flight?**
   (a) Yes, once: its hand on the canopy for about a minute, scraped off against a tower. (b) No, the flight is
   soldiers' ships only.
   **Recommend (a):** it proves the hunter followed him out of the school and gives the flight one horror beat.
8. **Is the hunter about three metres tall?** [Lead P7]
   (a) About 3 m: it stoops and folds indoors and stands up in tall rooms. (b) About 2.4 m: it fits the school's
   corridors upright. (c) Taller still, about 3.5 m.
   **Recommend (a):** stooping under ceilings and folding through doors makes it more frightening than walking upright.
