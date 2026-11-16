# Monster logic and pacing: research for ROVLOC

Desk research, 16 Nov 2026. Topic: how well-made horror games pace their monster, and a design for ROVLOC's
"lurker" that interacts every ~15-20 s sprinting, ~30 s walking, ~60 s crouching, mostly without attacking.

Method note: WebSearch worked; WebFetch could not reach most hosts in this session (DNS refused for
progameguides.com, allthings.how; others noted per section). Facts below therefore come mostly from search-result
summaries of the pages named. Each fact is tagged:
- [S] a source states it (named);
- [I] my inference;
- [U] could not verify.

The line we do not cross: we take TECHNIQUES (timers, gauges, tells, counterplay) and never content (no entity
designs, names, sounds, lines, levels).

Current ROVLOC baseline (docs/MONSTER.md, read for this report): one brain at 10 Hz; a tension director
(BuildUp / Peak / Relax); teleports at U(60,120) s after a first one at grace + 45 s; chases capped at 22 s; stalk
pace 7, chase 16.5, player sprint 19 / walk 11 / crouch 5.5. That cadence is the "4 minutes too much" the player is
reacting to: in practice the player meets the monster only when a teleport or a chase happens.

---

## 1. THRESHOLD (Roblox), the player's reference

### Which game
- [S] "THRESHOLD" (listed as "[UPD 2.1] THRESHOLD", place id 10665420648) by **Reskioat**, an episodic Roblox horror
  game with a story campaign and a separate **Chase Mode**; rated Moderate 13+; stats sites list ~97 % rating and a
  24 h peak near 13.8 K players; last update late Sept 2026. Sources: rotrends.com and bloxodes.com stats pages,
  progameguides.com and allthings.how walkthroughs (search summaries only).
- [S] Not to be confused with **"Backrooms Threshold"** (Kane Pixels, place 9120887607), nor itch.io games of the
  same name.
- Confidence that this is the player's game: **high** (tunnels + a hunting entity + torch + batteries + radar all
  match the player's words and ROVLOC's own feature list; earlier ROVLOC docs already cite "THRESHOLD's throw" and
  "THRESHOLD's jumpscare engine"). [I]
- Fan wikis exist: thresholdhorror.fandom.com, thresholdgame.wiki, threshold.wiki, thresholdhorror.com. None could be
  fetched in full from this session (DNS blocked); only search snippets were read.

### What is documented about its entity
- [S] The entity players call **Eli** (the game's files reportedly call it "Tommy"; thresholdhorror.fandom.com
  snippet) hunts the player in **maze-like tunnels** in Chase Mode. The goal: find **3 Maintenance Keys** at
  **randomized** spots (wall cabinets, metal panels, side passages) and exit. A second chaser, **Scrow**, has its own
  mall-like map and needs **4 Password Papers**; Scrow "follows you around and tries to bait you into making noise".
  (allthings.how, progameguides.com, thresholdgame.wiki snippets.)
- [S] **It answers noise.** Staying quiet is "essential"; the wiki says the entity **can hear your microphone and
  text chat**; "fast + loud still dies; fast + quiet clears"; hiding spots (closets, corners, barrels) "only work if
  you stop broadcasting"; "kill flashlight if the beam is painting your hiding spot". (thresholdgame.wiki snippets.)
- [S] **Warning device:** a **Radar** that warns when Eli is close, only while powered; **batteries are scarce** and
  run both the Torch and the Radar. "Radar helps locate threats; it does not forgive a scream." (allthings.how,
  thresholdgame.wiki.)
- [S] **Speed:** in Chase Mode "Eli will run you down the moment he has a clean line on you"; the advice is to cut
  corners and **break line of sight**, then hide. In Episode 2 (where the player plays a shadow monster) the guide
  says the monster is "much faster" than fleeing NPCs. No speed numbers anywhere.
- [S, weak] One fan wiki says Eli is "blinded by light"; not confirmed elsewhere. [U]
- **Teleporting:** no source found says THRESHOLD's entity teleports. [U] (ROVLOC's docs call its teleport
  "THRESHOLD's jumpscare engine"; I could not confirm that attribution.)
- **How often it shows itself / attacks:** **nothing documented.** No wiki, guide, DevForum post or video
  description found gives seconds or minutes between appearances. I found no developer post by Reskioat about
  pacing. The player's own "one every 20 s / 15 sprinting / 30 walking / 60 crouching" is therefore the best data we
  have on how THRESHOLD *feels* to him, and it is consistent with a **noise-driven hunter**: the louder you move, the
  sooner it finds you.

### What that tells us [I]
- THRESHOLD's loop as described = **scavenge under threat** (randomized keys) + **noise as the main input** + a
  **scarce-battery warning tool** + **break line of sight, then hide quietly**. The frequency the player wants is a
  natural result of noise-driven hearing, not a fixed timer.
- ROVLOC already has all of these parts (hearing radii by movement kind, radar and batteries, lockers/barrels/
  cabinets). What it lacks is an entity that **stays close and keeps making itself felt** between hunts.
- Name note: THRESHOLD has a human character called **Danny** (the player's colleague, and a voice impersonating
  him is used to mislead the player; thresholdhorror.fandom.com snippet). ROVLOC's Danny is the friend who becomes the
  monster. A shared common first name is not copying, and ROVLOC's monster speaking in his own (Danny's) voice is
  ROVLOC's own story. What to avoid is THRESHOLD's specific set piece: **a voice pretending to be a friend that
  leads the player somewhere** (its supermarket section). ROVLOC's lines should be in his own voice, about his own
  story, and should give his position away, not trick the player into a trap.

---

## 2. Monster systems of well-made games

### 2.1 Alien: Isolation (Creative Assembly, 2014): the two brains and the menace gauge
Sources: Tommy Thompson, "The Perfect Organism: The AI of Alien: Isolation" and "Revisiting the AI of Alien:
Isolation" (gamedeveloper.com; aiandgames.com), which draw on lead AI programmer **Andy Bray**'s nucl.ai 2016 talk;
MCV/Develop "18 things we learned" (designer Clive Lindop); Game Studies 20(2), J. Svelch "Should the Monster Play
Fair?"; OpenCAGE modding wiki (parameter names). Search summaries only; the articles themselves could not be fetched.
- [S] **Two layers.** A **director** ("macro") that always knows where the player is, and the alien's own
  **behaviour tree** ("micro", 100+ nodes, ~30 top-level behaviours) that must find the player with its own senses.
  The director never gives exact coordinates: it **sends the alien to the player's general area** and lets the
  senses do the rest. That is the "leash without cheating".
- [S] **Menace gauge**: measures pressure on the player. Rises with **proximity**, **line of sight** and **how easily
  the alien could reach the player**; rises **more slowly when the alien is close on the motion tracker but in another
  room**. When it **peaks**, the director **backs off**: sends the alien **backstage** (into the vents / neighbouring
  areas). While backstage the alien is still simulated (moving in the vents) but not rendered.
- [S] **Frontstage / backstage** = roaming the corridors vs. retreated into vents. Designers swapped between
  **several front/backstage configurations** over the campaign (so the leash tightens later).
- [S] Bray: players **cannot be kept scared all the time or they give up**. Lindop: the game is "risk management";
  the alien **finds a hider who stays put too long**; too much dynamic audio would give its position away, so they
  rationed it.
- [S] OpenCAGE lists tunable timers by name: *Menace Decrease Time* (delay before the gauge starts to fall), *Menace
  Cooldown Time*, *Seconds to Fill Menace Gauge*, backstage sweep min/max timeout, backstage idle min/max. **No default
  numbers found.** [U]
- [S, weak] "Behaviours unlock as the game progresses" (the alien learns: e.g. checks lockers more after you hide a
  lot): stated only by an editorial (Bloody Disgusting); developer sources did not confirm it in what I could read. [U]
- Take for ROVLOC: the **director/brain split**, a **gauge that measures pressure and forces a retreat**, a
  **backstage he still moves in (vents)**, and **configurations that tighten per floor**. Do not take the alien's
  look, sounds, vent-drop animation or motion-tracker beep.

### 2.2 Amnesia: The Bunker (Frictional Games, 2023): the noise stalker
Sources: Kotaku interview with Thomas Grip ("everything is a potential encounter section"); Frictional's
"pivotal point" / emergent-gameplay framing (Wikipedia summary); Amnesia fandom wiki (Beast, Hiding); Ludo guide;
Steam discussions. No developer write-up of the AI was found.
- [S] The Beast is **unscripted**; it **lives in the walls** (tunnels behind the bunker's walls) and comes out
  through **holes** in them. Noise (running, shooting, explosions, breaking things) draws it; **very loud actions
  almost certainly bring it out** of the walls to search. It moves to the nearest opening to a noise and waits there
  (fan wiki).
- [S] **Light drives frequency**: when the generator runs dry and the bunker goes dark, the Beast **scouts far more
  often**, more aggressively (fan wiki, Ludo guide). Fuel is a resource the player spends to buy calm.
- [S] Within **very close range** it can sense a silent player.
- [S, speculative] Players theorise escalating "anger stages"; not confirmed in files. [U]
- [S] Its states are told by **audio** (Steam players): you know what it is doing from what you hear.
- Take for ROVLOC: **noise as the dial for how often he comes** (exactly the player's sprint/walk/crouch ask); a
  **wall/vent network he lurks in and pops out of at known openings**; **audio tells per state**; **light (the
  torch/batteries, the fuse-powered lights) changes how bold he is**. Do not copy the Beast's design, its sounds or
  the bunker map.

### 2.3 Resident Evil 2 (2019): Mr. X
Sources: PC Gamer interview with director **Kazunori Kadoi**; gamingbolt retrospective; guides.
- [S] Kadoi: his heavy **footsteps are a designed mix of sounds**, not recorded steps, made to read as a very large
  man; the remake's Tyrant **roams freely between rooms** (the original only burst in at scripted moments); **when he
  loses you he is "technically still searching" but walks random routes**.
- [S] He is drawn by noise, above all **gunfire**; he tracks a player who **stays in one place too long**.
- [S] **Safe rooms** (save rooms with a typewriter/item box) he does not enter (guide; single source [U] for the
  exact rule). He may wait outside for a while.
- [S] Players say the dread comes from **hearing him through the building** before seeing him: "is that a zombie,
  or him?"
- Take: **footsteps audible through floors and walls as a constant, honest position cue**; **a walking-pace
  pursuer you can out-route but not out-wait**; **sanctuaries** he respects. Do not copy his look, coat, the
  footstep sound or the hat gag.

### 2.4 Outlast / Outlast 2 (Red Barrels) and Amnesia: patrol, chase, hide
Sources: Game Developer, "The art of the chase: level design and player orientation in Outlast 2"; Vice on Outlast
2's post-launch rebalance and story mode; GameSpot and PC Gamer reviews; Outlast fandom wiki; tips guides.
- [S] Hiding: lockers, under beds, behind things; **audio cues tell you an enemy has seen you**; hiding is **useless if
  the enemy saw you get in** (the pursuer checks it).
- [S] The Game Developer piece: the chase's power comes from the player **not knowing when the next one will be
  triggered**; **routes were designed for each chase** with lights and level funnelling guiding the player without a
  HUD; multiple paths that rejoin.
- [S] Criticism: too many **scripted chases down preset paths** felt like trial-and-error; Red Barrels shipped a
  **"global rebalancing of the game difficulty"** patch weeks after launch that **removed three chase sections**
  and a stealth section, and later a story mode (Vice: "expanded its audience by letting them live").
- **No chase-length numbers** found for Outlast or Amnesia: The Dark Descent. [U] (ROVLOC's own cap of 22 s is in
  line with Phasmophobia's 15-60 s hunts below.)
- Take: chases are **rarer than encounters** and must have **an escape route the level gives you**; **too many
  chases is the #1 thing players called unfair**. Do not take scripted chase corridors as the main loop.

### 2.5 Phasmophobia (Kinetic Games): hunt cadence and tells
Sources: Phasmophobia fandom wiki "Hunt" page (community, observable facts), guides.
- [S] **Hunts gated by a threshold** (team average sanity, default 50 %; varies per ghost type 35-75 %) and a
  **minimum 25 s cooldown** between hunts (20 s for one type); the ghost does not have to hunt once the cooldown ends.
- [S] **Hunt length by map size and difficulty**: Amateur 15 / 30 / 40 s (small/medium/large), Intermediate 20 / 40 /
  50 s, Professional+ 30 / 50 / 60 s. A **grace period** at the start (5 s on Amateur) lets players move first.
- [S] **Tells during a hunt**: footsteps and vocalizations heard from ~**20 m** (muffled by walls and floors),
  **lights and carried electronics flicker within ~10 m**, exit doors lock. The ghost blinks in and out of sight.
- [S] Players also learn per-type tells (e.g. one type's electronics flicker before its footsteps are audible).
- Take: **a clear threshold + a cooldown + a fixed max length**; **tells at two ranges** (hearing far, flicker near)
  so players can tell "close" from "very close"; **difficulty scales the hunt length**. Do not take its ghost types,
  evidence system or sounds.

### 2.6 DOORS (LSPLASH, Roblox): one tell per entity
Sources: DOORS fandom wiki (Halt, Hiding, Backdoor pages), speedrun.com entity guides, rblxguide, progameguides.
Spawn percentages differ between fan sources and are not reliable. [U]
- [S] **Rush**: lights **flicker ~1.5 s** with a **rumble**, then it rushes through once; hide in a wardrobe / under a
  bed. **Lights sometimes flicker with no Rush** (a fake tell keeps players honest). Fan estimates: ~6.7 % or
  10-15 % per door opened, from room 2. Rush breaks bulbs, making dark rooms where another entity (Screech) can
  appear; carrying a light lowers that chance.
- [S] **Ambush**: rarer; passes through **2-6 times** (rebounds), so you must judge when it is safe to come out.
- [S] **Hide**: **staying in a closet too long** gets you thrown out (a stay limit).
- [S] **Halt**: a rule-change room ("turn around" when told). **Eyes**: don't look at it. **Screech**: look at it
  when it whispers. Each entity = **one sense** to use: hear, look, look away, hide, wait.
- [S] Rush cannot open locked doors.
- Take: **every interaction type has one unmistakable tell and one counter**; **fake tells at a low rate**;
  **multi-pass threats** that punish leaving cover too early; **a stay limit** in hiding. ROVLOC already has fake-outs
  (1 in 12) and the stay limit. Do not copy any entity, its name, look, sound or its "rule" puzzles one-for-one.

### 2.7 Pressure, The Mimic, Apeirophobia (Roblox)
Sources: Pressure wiki on urbanshade.org (stub), Sportskeeda, fan pages (low reliability); The Mimic guides
(deltiasgaming, noleep, bloxodes); Apeirophobia guides (progameguides, touchtapplay).
- [S] Pressure: DOORS-like rush entities; **one rebounds several times through rooms** to catch players who leave
  lockers too early; some entities announced by a distinct sound rather than light. Little reliable detail. [U]
- [S] The Mimic: roaming monsters chase until you **break line of sight and hide**; hiding is **hold still and quiet**;
  advice "commit to a route you remember". Credited for **restricted vision, audio cues and restraint** (editorial).
- [S] Apeirophobia: wandering entities are **slow until they see you**, then pursue; **breaking line of sight behind
  solid walls makes some give up**; one entity's scream **alerts others**. Reliability low; an old walkthrough.
- Take: **slow wander, committed pursuit only on sight, give-up when line of sight breaks**; **rebound passes**.

### 2.8 Slender: The Eight Pages (Parsec Productions, 2012): escalation
Sources: gamedev.net "Taking Slender apart, an introduction to horror games"; Game Informer preview; fan pages
(weak).
- [S] Minutes of **nothing** at the start ("horror needs subtlety and time"); the level is built to **disorient**.
- [S] He **teleports**, appearing in view with a sting and **screen static**; static builds while you look; looking
  too long ends the run. **He appears closer and more often with each page** (several sources, details weak [U]).
- Take: **escalation tied to objective progress**, not only to time; **look-at-it meter as the punishment for
  staring** (ROVLOC already has a 1 s stare rule). Do not copy the faceless suit design, piano sting or static look.

### 2.9 Left 4 Dead's AI Director (Valve), the root of all of the above
Sources: Michael Booth, "The AI Systems of Left 4 Dead" (Valve, 2009, slides; not fetchable here); Valve developer
wiki "L4D2 Director Scripts"; TechRaptor retrospective.
- [S] Goal named in the slides: "generate dramatic game pacing". Cycle **Build Up → Sustain Peak → Peak Fade →
  Relax**, driven by each survivor's **emotional intensity** (rises with damage, being incapacitated, nearby kills;
  decays over time). In Relax the director **withholds threats** until intensity has fallen.
- [S] The L4D2 script docs expose SustainPeak min/max (5 / 10 s in an example) and Relax timing knobs.
- [U] I remember Booth's slides giving Sustain Peak 3-5 s and Relax 30-45 s (or until the survivors have travelled
  far enough). Could not confirm this session.
- Take: ROVLOC's director already copies this cycle (BuildUp / Peak / Relax). Keep it, but run it **per player** for
  "interactions", and a separate **team** gauge for chases (below).

### 2.10 What the references agree on [I, from 2.1-2.9]
1. **Two brains.** A director that knows where you are and only *steers*; a monster that must still find you with its
   senses (Alien). Players forgive a monster that is everywhere; they do not forgive one that knows things it could
   not.
2. **Noise is the dial** for how often it comes (THRESHOLD, Bunker, Mr. X, Phasmophobia's talk-near-it rule).
3. **A pressure gauge that forces a retreat** (Alien's menace, L4D's intensity, Phasmophobia's cooldown). Horror that
   never lets go stops being scary (Bray).
4. **Every threat has one tell and one answer** (DOORS); tells at **two ranges**, far (hearing) and near (flicker,
   breath) (Phasmophobia); an occasional **fake tell** (DOORS's empty flicker).
5. **Chases are rare, short, capped and escapable** (Phasmophobia 15-60 s; Outlast's patch removing chases; Mimic and
   Apeirophobia: break the line of sight and they give up).
6. **Escalate with progress**, not only time (Slender's pages, Alien's tightening configurations, Bunker's fuel).
7. **Sanctuary and breathing room** (Mr. X's save rooms, Alien's backstage, L4D's Relax).

---

## 3. Design for ROVLOC's monster: the Lurker

### 3.0 Where ROVLOC stands (read for this report)
- `docs/MONSTER.md` (main branch): teleport U(60,120) s, chases capped at 22 s; that is what the player calls "4
  minutes too much".
- The in-progress **presence layer** (worktree `.claude/worktrees/integ2/docs/MONSTER.md` sections 15-20, task #40):
  an Alien-style director with **Peek, Glimpse, Shadow, Pass-by** beats, search hints, an approach teleport, a leash
  of 35-90 walked, and a sim (`web/tools/presence-sim.mjs`) whose target is a **median 75 s / longest 150 s** gap
  between presence events, quiet spells of **40 s** after any encounter and beats no sooner than **35 s** apart.
- So the parts exist; the **numbers are 3-5x too slow** for what the player now asks, and every interaction is a
  costly "body" beat, which cannot honestly happen every 15 s. The fix is: **(a)** a per-player interaction clock
  driven by how the player moves, **(b)** many **cheap interactions** (heard, environmental, vent) that are true to
  where he really is, **(c)** a tighter leash, **(d)** quiet spells sized by how scary the last interaction was, and
  **(e)** chases on their own slow team budget.

### 3.1 The two gauges (per player)
Keep the director's existing "menace" (it rises while a player is left alone) and rename it for clarity, then add
Alien's real menace as a second gauge:

**A. The interaction clock `due` (0..)** — "how much he owes this player". Each second:
`due += rate`, where `rate` is the time-weighted mix of the player's movement over the last 5 s:

| Player is | Target gap | rate per s |
|---|---|---|
| sprinting (speed >= 15) | **17 s** (15-20) | 1/17 |
| walking (7.5..15) | **30 s** | 1/30 |
| standing / working an objective | **40 s** | 1/40 |
| crouch-walking (< 7.5 crouched) | **60 s** | 1/60 |
| crawling in a duct | **40 s** (vent interactions only) | 1/40 |
| hiding in a spot | **75 s** (pass-by / sniff only; the stay limit still applies) | 1/75 |

- Discrete loud noises add lumps: a door slam, a flask, a gasp **+0.25**; an objective clunk, a grate kick **+0.35**;
  the generator / breaker **+0.5**. (The hearing radii already in `MONSTER.md` 3.1 decide what he *physically*
  hears; the lumps only make the director turn up sooner.)
- An interaction fires when `due >= theta`, `theta` drawn **U(0.8, 1.2)** per interaction (seeded), so gaps vary
  +/-20 % and cannot be timed (Outlast lesson: unpredictable).
- After an interaction that *reached* the player: `due = 0`. A heard-only one reached a teammate too: theirs drops
  by **0.6**.
- **Floors:** first interaction (a heard one) at **20 s** after a floor's start; first *seen* one no sooner than
  **40 s**; never two on the same player within **10 s**; team-wide, never two within **6 s**.

**B. Strain `s` (0..1)** — Alien's menace: how much pressure this player has just had.
- Each interaction adds its **cost** (table 3.2). Continuous: player sees him **+0.04/s**; he is within 15 walked
  **+0.06/s**; chased **+0.05/s** on top of the chase's 0.5 entry cost.
- Decay **0.02/s** once nothing has raised it for **5 s** (OpenCAGE's "menace decrease time" idea).
- **Gates:** close interactions (tier 2) only while `s < 0.45`; seen ones (tier 1) while `s < 0.65`; heard (tier 0)
  always.
- **Back-off:** `s >= 0.8` → that player gets **backstage** for **U(25, 40) s** (until `s <= 0.35` as well): he
  withdraws to >= 60 walked or into the ducts, only tier-0 interactions reach that player and at **half** the clock
  rate. Any chase ends with `s >= 0.8` (0.5 + 15 s x 0.05 + seeing), so **every chase is followed by a breather**
  (as the integ2 quiet spell does now, but sized by what happened instead of a flat 40 s).
- Check of the numbers [I]: a walker gets ~0.12 per 30 s and sheds 0.5 in the gap, so steady play never trips the
  back-off; a sprinter gets ~0.15 per 17 s and sheds 0.24; only close calls, long looks and chases build strain.
  The sim must confirm this (3.8).

### 3.2 The catalogue of interactions
All of them are **honest**: every sound plays from where he really is, every sight is his real body; the only
"cheat" is the director knowing where to send him, and the warned teleport. Tiers: 0 heard, 1 seen at range,
2 close, 3 chase. Durations are the beat's length. "Body" = needs him physically placed (one at a time).

| # | Type | What the player sees / hears | Len | Range (walked) | Tier / cost | Body | Answer |
|---|---|---|---|---|---|---|---|
| H1 | Far steps | his heavy, slow footfalls through a wall or the floor above/below, moving | 3-5 s | 30-70 | 0 / 0.04 | no (he walks) | listen, pick another way |
| H2 | Behind the wall | breath, the mask's rattle, nails dragged along the other side of a wall | 2-3 s | 10-25, >= 1 wall | 0 / 0.07 | yes (stands) | keep still / quiet |
| H3 | In the vents | knocks and a scrape travelling along a duct over or beside them; dust from a grate | 3-6 s | 8-25 | 0 / 0.08 | yes (in duct) | don't enter that duct now |
| H4 | Environment | a door eased shut, a locker clicking, a bulb popping, a chair scraping, in the next room | 1-2 s | 12-30 | 0 / 0.06 | yes (at the prop) | go round |
| H5 | Spoken line | a whisper or a line in his voice (Danny's, wrong) from behind a wall or a grate; uses their name rarely | 1-3 s | 10-35 | 0 / 0.08 | yes | it tells you where he is |
| S1 | Glimpse | he crosses a junction ahead, not looking (integ2 16.2) | 1-2 s seen | 30-70 | 1 / 0.12 | yes | stop, wait, change route |
| S2 | Peek | the mask leans out of a doorway, holds, withdraws (16.1) | 1.5-3 s | 30-70 | 1 / 0.15 | yes | don't stare 1 s; back off |
| S3 | Vantage | he stands still at the dark end of a corridor; gone when the torch lands, or when they look away and back | 2-6 s | 35-60 | 1 / 0.15 | yes | torch on it, or retreat |
| S4 | Hole crawl | his legs folding into a low vent / crawl hole, or his long fingers through grate slats | 1.5-3 s | 15-35 | 1 / 0.12 | yes | that hole is his: mind it |
| C1 | Shadow | follows 30-50 back, steps in time with theirs, an extra step when they stop; freezes when looked at (16.3) | 10-20 s | 30-50 | 2 / 0.20 | yes | look back, hide, break the line |
| C2 | Pass-by | walks past their room / hiding spot slowly, sniffing (16.4) | 6-12 s | 18-28 | 2 / 0.25 | yes | hide or stay out of his cone in the dark |
| C3 | Warned teleport | 1.6 s flicker + hiss, he forms 12-24 (stalk) or 45-80 ahead (approach) | 1.6 s + 10 s | 12-80 | 2 / 0.30 | yes | turn, sidestep, hide |
| C4 | Sniff | checks a nearby hiding spot that isn't theirs, then theirs (8.1) | 4-8 s | 3-10 | 2 / 0.30 | yes | hold still (hold breath) |
| F | Fake tell | the teleport flicker and hiss with no arrival; or a far step that stops | 1.6 s | any | 0 / 0.05 | no | (keeps tells honest-ish) |
| X | Chase | wind-up screech then pursuit (integ2 section 18) | <= 12 s | — | 3 / 0.5 + 0.05/s | yes | outrun (sprint 19 > 16.5), break the line, hide |

Notes:
- Fake tells (F): **1 in 10** warnings, never two in a row, never as the first warning of a floor (DOORS does this).
- H5 lines: at most **one per 2 min** per player and **one per 45 s** team-wide; the spec already has lines
  ("I saw you, {name}." etc.). They are ROVLOC's own (Danny's voice gone wrong, his own memories from the opening).
- "Body" interactions take 5-20 s of walking to set up; the director plans the *next* body interaction while a
  heard one plays, so the clock is never starved.

### 3.3 How the director chooses (once per second, when a player's clock is due)
1. **Who:** of the players whose `due >= theta`, out of backstage: highest `due - theta`, x **1.5** if alone (no
   teammate within 25), x **1.3** if loud in the last 20 s, x **0.5** if `s > 0.5`; ties: longest since their last.
2. **What is feasible now:** each type's geometry rule (the integ2 placement bands for S1, S2, C1, C2; a duct within
   25 for H3/S4; a wall between for H2; a prop within 30 for H4), his current distance (he must reach the start in
   <= 8 s for heard ones, <= 20 s for body ones), the strain gates, and the per-type cooldown on that player:
   H1 20 s, H2 30 s, H3 40 s, H4 30 s, H5 120 s, S1 45 s, S2 60 s, S3 60 s, S4 60 s, C1 90 s, C2 90 s, C3 60 s, C4 60 s.
   Never the same type twice running on a player.
3. **Weights** = base x movement fit x floor progress:
   - base: H1 10, H2 8, H3 8, H4 8, H5 4, S1 8, S2 8, S3 6, S4 5, C1 5, C2 5, C3 5, C4 3, F 2.
   - movement fit (x2 on the fitting ones): sprinting → S1, S3, C3 (things *ahead* of a runner; a runner leaves a
     shadow behind); walking → C1, S2, H2; crouching / still → C2, H2, H3, C4 (the quiet player gets the creepiest
     *close but safe* ones: the reward for sneaking is fewer, eerier, near misses).
   - floor progress p = objectives done / total: tier-2 weights x (0.5 + p), tier-0 x (1.5 - p). Target mix per
     floor: first third ~60 % heard / 30 % seen / 10 % close; last third ~35 / 35 / 30 (Slender's escalation, Alien's
     tightening configs).
4. **Fallback:** if nothing body-based fits within 3 s, play H1 or H3 from where he is (both need only that he is
   within ~70 walked, which the leash guarantees). If he is farther than 90 walked, the warned approach teleport
   (integ2 15.3) is the move, and it is itself an interaction.

### 3.4 The leash (where he lurks)
- **Band:** keep him **25-55 walked** from the focus player on Standard (Easy 35-70, Nightmare 20-45), out of
  everyone's view, preferring dark side rooms, alcoves and **ducts** (his backstage). Today's integ2 band is 35-90;
  90 is too far to be heard often (walking noise is heard at 22, sprint at 60).
- **Moving honestly:** on foot 7-9 while lurking; in ducts **6** when no player is in that duct.
- A sprinter will out-run the leash (19 vs 9): that is when the warned teleport ahead (C3) fires, so **sprinting
  naturally earns more, scarier interactions**, exactly the player's "15 s if sprinting".
- Do not stand within **15 walked** of anyone except during a C-tier beat or a chase (sim target < 3 % of time).

### 3.5 Chases on their own budget (keeps it "not too hard")
- **Team token bucket.** One token per **150 s** on Standard (Easy 240 s, Nightmare 90 s), cap 1 (Nightmare 2); the
  first floor's first token at **90 s**. Co-op refill x (1 + 0.3 x (players - 1)), so four players see more chases
  in total but each player fewer.
- A chase needs **a token and a trigger**: the 1 s stare, being *noticed* (integ2 17.3) within 12 in the open, a
  sniff that finds them, or a loud noise within 15.
- **No token = a near miss**, not a chase: he screeches the wind-up (1.5 s), takes two steps toward them, then
  turns away / folds into the nearest hole / fades with the warning. Full scare, no run. This is where most "he saw
  me!" moments should land on Easy and Standard.
- Cap **12 s** (Easy 8 s, Nightmare 45 s as integ2 has it); lost after 4 s unseen; always followed by the strain
  back-off (3.1). Target **2-4 chases per 8-minute floor** solo on Standard (integ2's 2..5 is fine).
- Speed rule unchanged: never faster than a sprinting player.

### 3.6 Vents and crawlways (the player's "crawl under the little holes", task #45)
- **The ducts are his backstage** (Alien's vents, the Bunker's walls): he travels them at **6** when no player is
  inside, so the leash can follow players through the school's shortcuts.
- **Entering and leaving** is always shown or heard: the fold-in takes **1.2 s** (legs last; S4 when seen), the grate
  clangs (heard 40). He never leaves a duct at a grate within 12 of a player or in their view.
- **Sharing a duct with a player:** **3.8**, slower than their crawl (4.5): a moving crawler always gets out. He
  enters a duct a player is in only with a chase token and only if he saw them go in within the last 3 s. A vent
  chase lasts at most **10 s**; when they leave the duct he does not come out of that grate for **3 s**.
- **Catch in a duct:** only a crawler who has stopped for **2 s** within 3 of him (Standard; none on Easy). A
  player stopped at a junction hears him coming (H3 is the warning) first.
- **While a player is in a duct**, the only interactions for them are H3 (him in another duct), H5 through a grate,
  S4 (his fingers through a grate they pass). Ducts are tense but not a death trap.
- **Crawl-only holes** (under 9 clearance) are routes for him too; his hunched / folded pose rules (MONSTER.md 2)
  apply.

### 3.7 Co-op: splitting one monster four ways
- **One body**: at most one body interaction at a time. Heard ones (H1, H3, H5, F) are positioned at his real spot,
  so one sound can reach several players; it counts for each player within its audible range.
- **Grouped players share a clock**: players within 15 of each other run one clock at the **noisiest member's** rate
  (team play: "stop sprinting, he hears you").
- **Spread players**: the focus rule (3.3) picks; others get heard interactions from wherever he is, at x 0.6 rate,
  and **nobody goes 90 s without one** (integ2 already has "left alone 75 s goes first").
- **Per-player strain** means attention moves naturally: whoever just had a scare is backstage for a while and he
  visits someone else.
- **Team-wide floor**: never two interactions within 6 s; never two body interactions within 15 s.
- **Rescue windows**: when a player is downed, no new interactions or chases on the others for **20 s** (the
  revive is the scene).

### 3.8 What makes it fun rather than tiring [I, built on 2.10]
- **Counterplay for every type** (column "Answer" in 3.2), and the player can *see it work*: a peek withdraws when
  you back off; a shadow freezes when you look; a pass-by walks on when you hold still.
- **Near misses outnumber catches**: the no-token near miss (3.5), pass-bys over hiders, the shadow that freezes.
  Target >= 2 near misses per floor per player, < 1 down per floor for a careful player.
- **Variety**: 14 types, cooldowns, no repeats; each sound has >= 4 variants played round-robin with pitch +/-5 %.
- **Readable tells, two ranges**: far = footfalls (heard to 70), near = the mask's rattle and breath (within 25),
  the teleport's own flicker+hiss. Players learn him; learning is the fun.
- **Breathing room**: the strain back-off and Relax; the floor-start grace; the downed-teammate window.
- **Escalation over a floor**: from mostly heard to mostly seen and close as objectives get done; the last objective
  of a floor may spend the chase token on purpose (a set-piece the player earned).
- **Reward quiet play**: crouching halves how often he comes and turns what does come into eerie near misses; that
  is the THRESHOLD lesson ("fast + loud dies").
- **Don't make it tiring**: interactions are short (most under 3 s), they never block the objective, the HUD never
  counts them, and the strain gate stops close calls stacking.

### 3.9 What to measure in the simulation (extend `web/tools/presence-sim.mjs`)
Scripted players: Sprinter, Walker, Croucher, Hider, Mixed (sprint 30 % / walk 50 % / crouch 20 %); solo, pair,
four; Easy, Standard, Nightmare; 6 seeds; 8 min per floor.

| Measure | Target (Standard) |
|---|---|
| gap between interactions, sprinter | median **15-20 s**, p90 <= 28 s |
| gap, walker | median **26-34 s**, p90 <= 45 s |
| gap, croucher | median **50-70 s**, p90 <= 90 s |
| first interaction on a floor | <= 25 s (a heard one) |
| share by tier over a floor (all profiles) | heard 40-60 %, seen 25-40 %, close 10-25 % |
| share by tier, last third vs first third | close share at least 1.5x higher |
| any single type | <= 30 % of all; never the same type twice in a row on a player |
| chases per 8-min floor, solo | 2-4 (Easy 1-2, Nightmare 3-7) |
| downs per floor: careful player / sprinter | < 0.25 / 0.5-1.2 |
| near misses per floor per player | >= 2 |
| strain >= 0.8 | < 15 % of the time; no tier-1/2 interaction on a backstage player |
| leash: within 25-55 walked of the focus | >= 60 % of the time |
| within 15 walked, no beat or chase | < 3 % |
| heard interactions played from his real position | 100 % |
| teleports warned, none in view, none within 12 | 100 % |
| co-op: team gap between interactions | >= 6 s always; each player >= 70 % of their solo cadence; nobody alone > 90 s |
| ducts: a moving crawler caught | 0 |
| speed | never > 19 on foot, never > 4.5 in a duct a player is in |
| determinism | same seed, same events; 20 vs 144 fps identical |

Then play-test with the player himself and ask the one question that matters: "too much, too little, or right?" per
movement style; tune the three target gaps (17 / 30 / 60) and nothing else first.

---

## 4. Avoid
- Copying any entity (Eli, Scrow, the Xenomorph, the Beast, Mr. X, Rush/Ambush/Seek/Figure, Slender Man), its look,
  name, sounds, voice lines, music stings, maps or rule puzzles. Use the techniques (timers, gauges, tells,
  counters) only.
- THRESHOLD's "a voice pretending to be a friend leads you somewhere" set piece.
- Listening to the **microphone or voice chat** (THRESHOLD reportedly does): on school Chromebooks and with players
  under 13 it brings privacy and permission problems; game noise is enough.
- Raising the frequency with **more chases or more teleports**: the player asked for *interactions*; chases stay on
  their slow budget.
- Silent, unwarned teleports, or interactions played from a place he is not (players catch it, and it breaks the
  "always warned" rule).
- A flat timer that ignores how the player moves: the whole ask is "faster when I sprint, slower when I crouch".
- Repeating the same clip or the same type back to back; fake tells more often than 1 in 10.
- Ducts as death traps: no catching a moving crawler, no backstage travel through a duct a player is in.
- Scripted chases down one corridor (the Outlast complaint).

## 5. Unverified
- How often THRESHOLD's entity appears or attacks: nothing found; no wiki, guide or DevForum post gives seconds or
  minutes.
- Whether THRESHOLD's entity teleports: not found in any source.
- Eli being "blinded by light" (one fan wiki only).
- Alien: Isolation's menace and backstage default numbers (only parameter names found, OpenCAGE); the claim that its
  behaviour tree unlocks nodes over the game (one editorial).
- Booth's L4D numbers (Sustain Peak 3-5 s, Relax 30-45 s): from memory, not confirmed this session; the L4D2 script
  docs show SustainPeak 5-10 s as an example.
- Amnesia: The Bunker's "anger stages" (a player theory); the Beast's exact noise thresholds.
- RE2's "Mr. X won't enter a room with a typewriter and an item box" (one guide).
- DOORS spawn percentages (6.7 % vs 10-15 % per door); Pressure's entity details (stub wiki).
- No Outlast / Amnesia chase-length numbers found.
- WebFetch was blocked by this session's network for every site tried except github.com, so all facts come from
  search summaries; the full articles (gamedeveloper.com, the THRESHOLD wikis, Booth's PDF) should be read once
  those hosts are allowed.

## 6. Sources
- THRESHOLD: progameguides.com/roblox/complete-threshold-walkthrough/ ; allthings.how/threshold-episode-2-and-chase-mode-walkthrough/ ;
  thresholdgame.wiki/guides/eli/ , /guides/chase-mode/ , /guides/hearing-mic-chat/ , /guides/eli-keys/ ;
  thresholdhorror.fandom.com/wiki/THRESHOLD , /wiki/Eli , /wiki/Danny ; thresholdhorror.com/guides/threshold-characters-and-entities/ ;
  rotrends.com/game/10665420648 ; bloxodes.com/stats/games/threshold-10665420648 ; roblox.com/games/9120887607 (the other "Backrooms Threshold")
- Alien: Isolation: gamedeveloper.com/design/the-perfect-organism-the-ai-of-alien-isolation ;
  gamedeveloper.com/design/revisiting-the-ai-of-alien-isolation ; aiandgames.com/p/revisiting-alien-isolation ;
  gamestudies.org/2002/articles/jaroslav_svelch ; mcvuk.com/development-news/18-things-we-learned-about-alien-isolation-last-night/ ;
  avpgalaxy.net/website/interviews/alien-isolation-developers/ ; github.com/MattFiler/OpenCAGE/wiki/Editing-Alien-Configurations ;
  bloody-disgusting.com/editorials/3587886/alien-isolations-stalking-xenomorph-needs-horror-games/
- Amnesia: The Bunker: amnesia.fandom.com/wiki/Beast , /wiki/Hiding ; kotaku.com/amnesia-the-bunker-horror-release-date-steam-open-world-1850354518 ;
  ludo.guide/guide/amnesia-the-bunker/lore-easter-eggs/the-beasts-behavior-patterns ; steamcommunity.com/app/1944430/discussions/0/3818536989166262124
- RE2: pcgamer.com/resident-evil-2s-director-talks-mr-xs-ai-scary-footsteps-and-the-dmx-mod ; gamingbolt.com/seven-years-later-mr-x-is-still-resident-evils-scariest-stalker
- Outlast: gamedeveloper.com/audio/the-art-of-the-chase-level-design-and-player-orientation-in-i-outlast-2-i- ;
  vice.com/en/article/how-a-horror-game-about-death-expanded-its-audience-by-letting-them-live ; outlast.fandom.com/wiki/Outlast
- Phasmophobia: phasmophobia.fandom.com/wiki/Hunt ; ginx.tv/en/ghost-hunt-sanity-thresholds
- DOORS: doors-game.fandom.com/wiki/Halt , /wiki/Hiding , /wiki/The_Backdoor ; speedrun.com/roblox_doors/guide/l76ng ; rblxguide.com/games/doors/entities/rush
- Pressure / The Mimic / Apeirophobia: urbanshade.org/wiki/Pressure ; sportskeeda.com/roblox-news/roblox-pressure-all-monsters-counter ;
  bloxodes.com/wiki/the-mimic ; deltiasgaming.com/?p=390655 ; progameguides.com/roblox/roblox-apeirophobia-walkthrough-how-to-beat-levels-0-10/ ;
  touchtapplay.com/apeirophobia-how-to-survive-partygoers/
- Slender: gamedev.net/articles/game-design/game-design-and-theory/taking-slender-apart-an-introduction-to-horror-games-r3030/ ;
  gameinformer.com/games/slender/b/pc/archive/2012/08/10/things-go-bump-in-the-night.aspx
- Left 4 Dead: cdn.fastly.steamstatic.com/apps/valve/2009/ai_systems_of_l4d_mike_booth.pdf ; developer.valvesoftware.com/wiki/Left_4_Dead_2/Scripting/Director_Scripts ;
  techraptor.net/content/10-years-of-left-4-dead
- ROVLOC (read): docs/MONSTER.md ; .claude/worktrees/integ2/docs/MONSTER.md sections 14-20 ; web/src/game/config.js (VentCrawlSpeed 4.5)
