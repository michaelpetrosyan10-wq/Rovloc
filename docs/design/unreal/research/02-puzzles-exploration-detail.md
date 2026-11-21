# Stay Behind: puzzles, exploration structure, Easter eggs and environmental detail

Research report 02, 21 November 2026. For the designer writing the game map. We take PATTERNS from the reference games and never CONTENT: every "Ours" example below is original to Stay Behind.
Tags: [checked: url] = confirmed against the source; [from memory] = not confirmed this session.

---

## 1. Findings that matter most

**F1. The references treat puzzle difficulty as its own setting, and the answers change with the tier, not just the hints.** The Silent Hill 2 remake has Light, Standard and Hard puzzle settings, separate from combat. Light makes the clues easy to find, Standard makes them subtler, and Hard makes them "extremely difficult" and hard to find [checked: pushsquare.com guide; gfinityesports.com]. The tier is locked when a new game starts [checked: gfinityesports.com]. Codes differ between tiers, for example the music box and the hospital padlock, while some codes stay the same on every tier [checked: noobfeed.com; gamingbolt.com]. The remake reworked returning puzzles and added new ones "that tie into the game's story" [checked: gamesradar.com]. On the higher tiers it rewrites the riddle text itself to be more oblique, not only the number [from memory].
*Why it matters:* our map already makes puzzle difficulty its own setting. Each puzzle therefore has to be AUTHORED three times (clue text, clue placement, how many steps), not just given a harder number. Unlike the SH2 remake, we should let the player LOWER the puzzle tier mid-game, because he said "i also dont want the game to be too hard". This is a decision to put to him.

**F2. Amnesia: The Bunker shows that reshuffled codes work when the place of a clue stays fixed and its content changes.** Four-digit locker and door codes are generated anew for each playthrough. Dog-tag spots stay fixed, but the name and code on each tag are random. A few story tags keep their names but still get new codes [checked: gameranx.com; progameguides.com]. Because the codes are rolled when a save begins, players note them down and reload an earlier save [checked: progameguides.com].
*Why it matters:* this is the template for our reshuffle. Fixed clue CARRIERS (a whiteboard, a locker tag, a phone) show rolled VALUES. We roll the seed once at New Game and keep it through every manual save and chapter autosave, so reloading never changes a code the player has written down.

**F3. In The Bunker, every lock has a physical way round it, and the price is noise.** Padlocks give way to two throws of a brick, a grenade, a gunshot, or bolt cutters on the chain. Wooden doors give way to a brick, a grenade, a barrel shot from a distance, or a weapon [checked: primagames.com]. Smashing a door with a brick is loud [checked: primagames.com]. The generator powers the whole bunker and is a main source of its tension [checked: store.epicgames.com]. The lead says the aim was to "avoid linearity and predictability" [checked: gamingbolt.com], and Frictional's Thomas Grip says the sandbox design makes "everything a potential encounter section" [checked via search summary: dualshockers.com interview].
*Why it matters:* this is the answer to "complex but not too hard". The code is the quiet, clever route. The crowbar, the bolt cutters or the fire axe is the loud route, and it brings the floor's creature. In the school nothing can be killed, so our alternatives are tools and noise, never weapons.

**F4. Power as a budget creates puzzles that are also choices.** Dead Space remake circuit breakers often offer three systems but can power only two; the classic trade is lights against oxygen [checked: gamerguides.com; game8.co]. Alien: Isolation rewire panels switch lights, cameras, door access, alarms and air purification; turning the air purification on makes a smoke screen; turning the lights off helps you hide but also blinds you [checked: gamepressure.com; feralinteractive.com].
*Why it matters:* our generator, the Dark Dwellers (which live only in darkness) and the safe room's power needs make this the spine of the school. Every power decision costs something: the survivors' heater, the lights that keep the Dwellers back, or a door.

**F5. Noise from puzzle work is what makes a puzzle also a scare.** In Alien: Isolation, hacking and saving make noise the creature can home in on [checked: nme.com]. The hacking tool is a pattern-matching device used in real time [checked: gameinformer.com]. The lead designer says manual saves create "the tension and stress of looking for a save point in the dark" [checked: gamedeveloper.com save-system deep dive]. The creature is not scripted, because "if you can predict what it's going to do... the tension evaporates" [checked: pcgamesn.com].
*Why it matters:* never pause the world for a puzzle screen. Every puzzle in a creature zone runs in real time, in the world, with a sound the creature can hear.

**F6. A remake's backtracking works because revisited places change.** The Dead Space remake opens locked boxes as security clearance rises, which encourages return trips [checked: sportskeeda.com]. Its "Intensity Director" changes rooms the player has already cleared, from the lights to where enemies are [checked: destructoid.com].
*Why it matters:* our janitor's key ring is our clearance system. Each new key reopens a closet on an earlier floor, and our version of a director changes the earlier floor while the player is away (lights out, a Still One moved, vent covers off).

**F7. The strongest exploration structure in the genre is a hub with locked spokes where you see the lock before you have the key.** The Resident Evil 2 remake's police station is praised for "puzzles built into the architecture" and "hub-based level design" [checked: en.wikipedia.org/wiki/Raccoon_Police_Station]. It refines the principle of showing the lock before handing over the key [checked: bloody-disgusting.com].

**F8. Learnable languages work when a notebook records what you saw and confirms meanings only in groups.** In Chants of Sennaar, every glyph the player sees is written into a journal and the player enters a guess. The guesses are confirmed only when every drawing on a two-page spread is matched correctly [checked: thelanguagecloset.com]. Return of the Obra Dinn confirms fates three at a time so that guessing gets you nothing [checked: en.wikipedia.org/wiki/Return_of_the_Obra_Dinn]. Tunic's in-game manual has 28 double-sided pages found out of order, and some pages only make sense together [checked: wikipedia.com/wiki/Tunic_(video_game)].

**F9. Secret endings and recurring objects are what players hunt for longest.** The Silent Hill 2 remake keeps joke endings (Dog, UFO) and a Rebirth ending for New Game Plus and adds two new ones, Bliss and Stillness [checked: playstation.com replay guide; gamesradar.com]. The Dead Space remake has a new-game-plus ending that needs 12 Marker Fragments and a final ritual step [checked: pcgamer.com; game8.co]. It also keeps its recurring hidden treasure, moves it so returning players look in the wrong place, and hints at it in a text log [checked: pcgamesn.com]. Outlast 2's distorted school recordings reveal hidden messages when played backwards [checked: gameranx.com].

**F10. Environmental storytelling is a chain of events the player puts together.** Harvey Smith and Matthias Worch's GDC 2010 talk "What Happened Here?" frames a space as staged objects the player interprets, with subtext and a discernible chain of events [checked: gdcvault.com/play/1012647]. Alien: Isolation makes an empty station feel lived in through photos on walls, graffiti and signs of panic [checked: pcgamer.com Perfect Organism excerpt; videogamer.com].

**F11. Guide the eye with things that belong in the world, not with yellow paint.** The Silent Hill 2 remake chose to avoid yellow-paint signposting [checked: gamesradar.com]. Resident Evil Requiem reportedly marks interactable things with in-world props such as shipping seals and cable ties [checked: gfinityesports.com].

---

## 2. How the best survival-horror puzzles are built, and what this means for Stay Behind

**2.1 The lock-and-key web.** Each floor is a mini-hub, the stairwell landing, with four to six spoke rooms. Two of the spokes are locked when the player arrives. At least one key or clue on each floor comes from a different floor, so the web crosses floors, but never more than one such link per floor, so the player is not crossing creature territories blind. Show the lock first: the theatre's chained double doors are visible from the first floor's landing in Chapter 2 but open only in Chapter 4.

**2.2 Information from two or three places.** A good complex puzzle has two to three clue sources, each partial and each found in a different room, and the player knows WHICH kind of information is missing. An example sentence on the board: "Freezer code = the date on the cake order (kitchen) + the table count from the dance seating plan (gym)".

**2.3 Physical logic.** Prefer machines the player already understands: breakers, valves, counterweights, thermostats, a camera's timer, a scoreboard. The difficulty comes from combining these, not from arbitrary rules. Alien machines are the one exception, and the glyph language explains them.

**2.4 Puzzles as tension.** Each floor's creature rule should change HOW the floor's puzzles are done (section 3 gives examples). This is what makes the puzzles ours rather than generic.

**2.5 Difficulty tiers.** Each puzzle carries three authored variants:
- **Light:** the clue sits next to the lock; the notebook writes the fact down; one step.
- **Standard:** the clue is in another room; the player connects it; two steps.
- **Hard:** the clue is oblique (a riddle, a photo, a reference); one extra step or a decoy that has to be ruled out.

The physical alternative stays on every tier. Puzzle difficulty never changes the creatures.

**2.6 Reshuffle rules.**
- Roll the values at New Game from one stored seed.
- Clue carriers stay fixed in place; their values change.
- Item spots are drawn from a hand-placed list of three to five plausible spots, never anywhere at random.
- Recorded voice lines NEVER speak a value (see Risks).
- Story-critical items (Kayla's radio, the key ring) never move.

**2.7 Power routing.** The generator is a budget of power units. The circuits are the safe room's lights and heater, the basement corridor lights (which keep the Dark Dwellers back), the freight lift, the server room, and per-floor door locks. Rewire panels on each floor switch local systems (lights, sprinklers, PA, fire doors, vending machines as noise lures).

**2.8 Hacking and access tuners.** In the school, a borrowed teacher's laptop and the server room's patch panel are the only "hacking". On the alien side, the knocked-out soldier's gun can read glyph locks. This is our tuner, and its pattern-match uses glyphs the player has learned, so hacking gets easier as the language grows.

**2.9 Low gravity.** Puzzles follow momentum, a few anchors and changing "down": push off, drift, grab; move masses to balance a spinning ring; shut a valve to stop a drift. Seeing the whole space from a vantage is part of the solution, as the Dead Space remake's zero-g rooms suggest [checked: progameguides.com; techradar.com]. Keep orientation changes rare: players report getting lost when they flip often [checked: progameguides.com].

### What makes a puzzle feel "well thought out" instead of annoying
1. **Clue fairness:** every fact the solution needs is in the world on the current tier; nothing needs outside knowledge (no real chemistry beyond what a poster in the lab says).
2. **One unknown at a time:** the player knows the rule and lacks a value, or knows the values and lacks the rule, never both at once on first sight [from memory: common puzzle-design teaching].
3. **Teach, test, twist:** first meet a mechanic safely (the basement breaker), then test it under a creature (the Listener floor's breaker), then twist it (the mothership's power is alien and reversed) [from memory].
4. **Optional depth:** the critical path asks for the minimum; full solutions open extra supplies, story notes or a survivor's errand.
5. **Hint ladder:** the notebook offers three hints per puzzle. Hint 1 says where to look, hint 2 says what kind of thing to find, hint 3 says the action. This mirrors Return to Monkey Island (three or more hints, the last one exact) and the Universal Hint System style of "vague first" [checked: buymeacoffee.com/jrutila; gamedeveloper.com low-spoiler hints]. In the fiction, the hints come as Kayla on the radio thinking aloud, but only when Danny is in a safe room or the floor is quiet, because the radio makes noise.
6. **No pixel hunting:** every clue object is lit and placed where the eye goes. Items you can use get a small in-world marker (fresh masking tape, a zip tie, a chalk mark, a tag), not paint (F11). Clues in dark areas are lit by Danny's torch or emit light themselves (a glowing phone, an exit sign).
7. **The game confirms progress:** a click, a light, or the notebook ticking off a line, so the player is never unsure whether a step counted.

---

## 3. Puzzle pattern library (34 patterns)

Each entry: **Form** (general form), **Asks** (what it asks of the player), **Tiers** (L / S / H), **Reshuffle**, **Ours** (one original example).

1. **Lock shown before key.** *Form:* a visible locked door or shutter weeks before you can open it. *Asks:* remember it and return. *Tiers:* L the key's room is marked on the map; S unmarked; H the key must be assembled. *Reshuffle:* which of two locked spokes gets the key first. *Ours:* the gym's roller shutter seen from the stairwell; its crank handle is in the workshop.

2. **Split code from scattered pieces.** *Form:* a code in two or three fragments. *Asks:* collect and order them. *Tiers:* L the fragments are numbered; S ordered by a rule; H one fragment is a decoy. *Reshuffle:* digits rolled; carriers fixed. *Ours:* the main-office safe; the digits are on three detention slips, ordered by bell period.

3. **Schedule or order document.** *Form:* a printed timetable gives the order of actions. *Asks:* read the document and act in sequence. *Tiers:* L the order is printed; S worked out from times; H with a mid-year change to the schedule. *Reshuffle:* which rooms are in the sequence. *Ours:* the PA's zone buttons; the evening event's run sheet ("halftime: gym, then cafeteria, then lobby") gives the order that drives a Listener away along the corridor.

4. **Power budget (two of three).** *Form:* limited power across systems. *Asks:* choose and accept the cost. *Tiers:* L two circuits; S three; H three with one already drawing power. *Reshuffle:* which circuit is damaged. *Ours:* the generator board. Powering the freight lift means turning off either the safe room heater (a survivor gets sick) or the corridor lights (Dark Dwellers come).

5. **Stealth rewire.** *Form:* panels switch local systems. *Asks:* plan the systems for a route. *Tiers:* L the panel labels show their effect; S labels show room numbers only; H labels are wrong and the right ones are in the custodian's log. *Reshuffle:* which room numbers map to which switches. *Ours:* on the Swarm floor, turning off the heating (Swarm drawn to warmth) also unlocks the fire doors.

6. **Missing-fuse hunt.** *Form:* a fuse box with gaps, fuses of different ratings around the floor. *Asks:* match the rating. *Tiers:* L only one fits; S two fit, one blows; H wrong ratings trip the whole floor's lights. *Reshuffle:* fuse locations from a spot list. *Ours:* the stage lighting box behind the theatre.

7. **Fuel as time.** *Form:* the generator's fuel drains while it runs. *Asks:* plan trips and when to run it. *Tiers:* L big tank; S medium; H with leaks. *Reshuffle:* where the fuel cans are. *Ours:* the school bus in the lot holds a siphonable tank, but the lot is in the hunter's sight line.

8. **Physical alternative (the loud way).** *Form:* every lock has a tool route that costs noise or time. *Asks:* weigh code versus noise. *Tiers:* the same on all tiers. *Reshuffle:* where the tools are. *Ours:* bolt cutters for chained doors, the fire axe for wood, a fire extinguisher for glass. Each makes a noise event the floor's creature hears.

9. **Item chain.** *Form:* an item becomes another item through a process. *Asks:* see the use of each step. *Tiers:* L two steps; S three; H four with a fork. *Reshuffle:* which room does each step. *Ours:* a cracked car key fob plus the workshop's soldering iron plus a battery from the drama prop store makes a working fob that sets off a car alarm as a lure.

10. **Balance or weight.** *Form:* a scale or counterweight needs a target mass. *Asks:* add up masses. *Tiers:* L the masses are labelled; S worked out from labels (kg of salt); H mixed units. *Reshuffle:* the target mass. *Ours:* a balance-triggered lock on the chemistry prep room. The teacher rigged it as a joke for her students, and her note tells the story.

11. **Mixing by reference chart.** *Form:* a wall chart gives a mixing rule. *Asks:* apply the rule to the stock on hand. *Tiers:* L a direct recipe; S one substitution; H two substitutions, one of them unsafe (it fails loudly). *Reshuffle:* which bottles have labels. *Ours:* make a strong-smelling lure for the Swarm, or a smoke pot. Safety posters in the lab hold the rules (game-only chemistry).

12. **Plan or map deduction.** *Form:* a floor plan with gaps or errors. *Asks:* find the room that isn't on the plan. *Tiers:* L the gap is marked; S measured by counting doors; H two plans from different years. *Reshuffle:* which wall hides the room. *Ours:* the fire evacuation plan of 1998 against today's shows a sealed darkroom (secret, see E1).

13. **Catalogue lookup.** *Form:* an index points to a place. *Asks:* use the index. *Tiers:* L the call number is given; S found from a subject; H from a quotation. *Reshuffle:* the book and the shelf. *Ours:* the library catalogue terminal is dead; the card catalogue drawers still work. A quote on the librarian's desk leads to a hollowed reference book holding the server room key.

14. **Cue sheet.** *Form:* a technical script gives settings. *Asks:* set the controls to match. *Tiers:* L one cue; S three cues in order; H the cue is written as a stage direction. *Reshuffle:* the fader values. *Ours:* the theatre lighting board. The right cue lights the catwalk so the player can cross a Still One's stage with the light on it.

15. **Counterweight rig.** *Form:* move a heavy thing by moving its counterweight. *Asks:* understand cause and effect at a distance. *Tiers:* L one line; S two lines; H the wrong line drops a noisy set piece. *Reshuffle:* which line is labelled. *Ours:* the theatre fly system lowers a painted backdrop to bridge a gap in the collapsed stage.

16. **Display controller.** *Form:* a scoreboard or sign shows what is typed in. *Asks:* find the value and enter it; also used as a light or noise lure. *Tiers:* L the value is on the board; S from the roster; H from a photo. *Reshuffle:* the jersey numbers. *Ours:* the gym's equipment cage opens to the jersey number of the player who scored last tonight (the stats sheet on the bench).

17. **Thermostat or process setting.** *Form:* set a machine to a value worked out from a document. *Asks:* convert or scale. *Tiers:* L a direct value; S scale a recipe; H with a unit change. *Reshuffle:* the batch size. *Ours:* the walk-in freezer's lock code comes from scaling the lunch lady's recipe for the dance (for 200 instead of 50).

18. **Blueprint build.** *Form:* combine parts at a bench from a diagram. *Asks:* gather parts; follow the plan. *Tiers:* L parts glow in the notebook; S the parts list is a shopping note; H one part must be substituted. *Reshuffle:* where the parts are. *Ours:* the workshop builds distraction devices (a timed rattle, a thrown noisemaker, a light flare from a bike lamp).

19. **Password from a life.** *Form:* the login answer is in someone's things. *Asks:* read the person. *Tiers:* L a sticky note; S the security question answered by a desk photo; H by two items together. *Reshuffle:* which answer is the password. *Ours:* the vice-principal's laptop; the pet's name is on a mug, the year on a framed certificate.

20. **Patch panel.** *Form:* connect ports according to a diagram. *Asks:* trace lines. *Tiers:* L two cables; S four; H a diagram with errors and a fix log. *Reshuffle:* the port numbers. *Ours:* the server room restores the school's security cameras, so Danny can watch the Still Ones' floor from a monitor.

21. **Sound lure placement.** *Form:* make a noise source draw a creature away. *Asks:* plan timing and where the creature will walk. *Tiers:* L the lure lasts long; S short; H a second creature hears it too. *Reshuffle:* where the speakers are. *Ours:* a bell timer or a phone alarm set to go off in another room on the Listener floor.

22. **Sight line through a mirror or camera.** *Form:* watch a target without facing it. *Asks:* use reflections or screens. *Tiers:* L one mirror; S two; H only a phone camera with a weak battery. *Reshuffle:* which mirror is broken. *Ours:* on the Still Ones' floor, Danny reads a board behind him through a trophy case's glass while watching the statues in front.

23. **Quiet sequence.** *Form:* repeat a sequence where loudness is a fail state. *Asks:* precise, gentle input. *Tiers:* L four notes; S six; H with a pitch change. *Reshuffle:* the sequence. *Ours:* in the music room, an electronic piano with the volume at minimum opens the instrument locker; pressing too hard alerts a Listener.

24. **Light pools on timers.** *Form:* the route is lit by timed lights. *Asks:* timing and choosing a route. *Tiers:* L long timers; S short; H some lamps fail. *Reshuffle:* which lamps work. *Ours:* the basement after the generator fails; motion-sensor tunnel lights hold the Dark Dwellers back only while Danny keeps moving.

25. **Photo location.** *Form:* a photo shows where something is. *Asks:* recognise the place from details. *Tiers:* L a wide shot; S close-up; H a cropped corner. *Reshuffle:* which photo. *Ours:* a yearbook club photo shows a loose ceiling tile above the chem lab; the medicine stash is there.

26. **Verification question.** *Form:* tell a true person from a copy by knowledge only the real one has. *Asks:* remember personal facts. *Tiers:* L one question; S two; H the copy knows the obvious fact. *Reshuffle:* which survivor's voice it uses. *Ours:* a Mimic calls through the floor's intercom in a survivor's voice. Danny asks what the survivor told him in the safe room, a fact the player heard in an optional talk. Players who skipped those talks fall back to the loud way (opening the door with a creature on the other side), never a dead end.

27. **Pressure network.** *Form:* valves and pipes direct flow. *Asks:* trace the network to send flow to the target. *Tiers:* L three valves; S five; H a burst pipe makes noise. *Reshuffle:* which valve is stuck. *Ours:* the boiler room floods a corridor to drown the Swarm's heat trail (cold water).

28. **Dumbwaiter or lift.** *Form:* send items between floors. *Asks:* plan what goes where. *Tiers:* L the lift runs freely; S it needs power (pattern 4); H weight limits. *Reshuffle:* which floors it stops at. *Ours:* the cafeteria's service lift carries medicine down to the safe room without Danny walking through two creature floors.

29. **Safe from a biography.** *Form:* a dial code from a date in someone's life. *Asks:* work out the date. *Tiers:* L a birthday card; S an anniversary from a calendar; H an age plus the year on a diploma. *Reshuffle:* the date. *Ours:* the janitor's (a survivor) locker; he tells Danny his late wife's birthday if Danny has helped him. Otherwise the player has to read it from a photo's back.

30. **City utility box.** *Form:* a city control box opens a gate or changes the traffic lights. *Asks:* read the plate, choose a mode. *Tiers:* L the mode is labelled; S a manual; H a broken label. *Reshuffle:* which junction. *Ours:* switching the traffic lights to flashing red makes the Patrol's drones check the junction, a lure in the city.

31. **Radio triangulation.** *Form:* find a signal source from readings at several places. *Asks:* read the strength and narrow the area. *Tiers:* L two readings; S three; H with an echo. *Reshuffle:* where the source is. *Ours:* Kayla's crashed helicopter beacon in the blocks, found with a handheld scanner from a police car.

32. **Glyph console.** *Form:* operate an alien control by reading its symbols. *Asks:* apply the learned language. *Tiers:* L the notebook overlays a translation; S known glyphs only; H the meaning of a new glyph is inferred in place. *Reshuffle:* the panel layout. *Ours:* the first alien ship's door uses "open" with the number "two".

33. **Momentum in low gravity.** *Form:* push masses and yourself to reach and line things up. *Asks:* plan force and direction. *Tiers:* L the drift slows itself; S no slowing; H a turning room. *Reshuffle:* the start rotation. *Ours:* a holding hall's pods have drifted; Danny pushes them into the docking clamps to free the people inside.

34. **Release logic.** *Form:* free a set of things under a constraint. *Asks:* plan which, and in what order. *Tiers:* L no alarms; S one alarm rule; H two rules and a capacity limit. *Reshuffle:* which pods hold the people Danny knows. *Ours:* releasing pods without letting the Brute sense the opened cells. The choice of who goes first echoes the quiet choices system.

---

## 4. The alien symbol language: plan

**Pattern from the references.** Glyphs are recorded automatically; the player assigns meanings; meanings are confirmed only as a group (a page or a set of three), so guessing gets you nothing (F8). Pages found out of order cross-reference each other (Tunic). Numbers before words is a sound teaching order because numbers can be checked against counts [from memory].

**Our language.** About 30 to 40 glyphs in total, roughly 10 numerals and 25 words. Each glyph is a sign the hunter's species draws with three claw strokes, so it is easy to read on a gun display or scratched into a wall.

- **Chapter 1 (school):** the hunter scratches tally glyphs on the doors of rooms it has cleared ("taken: 4"). The player counts the empty desks inside and confirms numerals 1 to 5.
- **The school's server room:** shows the alien broadcast on the security monitors. It teaches "person", "taken", "ship" through repeated images.
- **The city:** Patrol signs on barricades, drone labels, and the gun's energy display (numerals to 10, "empty", "full").
- **The ship and the flight:** the HUD (left, right, danger, home).
- **The mothership:** grammar. "Not", "all", the order of a verb and its object, then two new words found in context.

**Notebook.** A page fills in as glyphs are seen. The player drags a meaning onto each glyph. A page is confirmed with a sound and a stamp only when all its glyphs are right. On the Light tier, after two wrong attempts a page offers one free glyph. Hard gives no overlay on consoles.

**Final exam: the self-destruct.** It needs READING the panel, COMPOSING a command, and READING the countdown. All glyphs the exam requires are guaranteed on the critical path; optional pages only add lore and Easter eggs.

---

## 5. Multi-stage finale under time pressure

**Pattern.** Alien: Isolation's reactor purge spreads one goal over several consoles in sequence (two support consoles per core, then a central commit) [checked: primagames.com]. Players complained that the ending lacked payoff [checked: steamcommunity.com discussion]. The lesson: every stage must change the place and the story, not only tick a box.

**Rules for ours.**
1. Each stage reuses a skill the game has already taught; no new rule under the timer.
2. The pressure comes from the ship coming apart (lights failing, decks tilting, the Brute and the hunter) more than from a tight clock.
3. Checkpoint at every stage.
4. The timer is shown in alien numerals, so reading it is part of the exam; the Light tier adds time and an overlay.

**The sequence (proposed).**
1. **Isolate the core:** a power budget on an alien board (pattern 4, twisted).
2. **Authorise:** compose a three-glyph command ("all / ship / end") on a panel (pattern 32 at full grammar).
3. **Arm the three clamps by hand** in a low-gravity shaft (pattern 33) while the Brute tears up the cover.
4. **The pods:** release the people Danny freed (pattern 34); who is there depends on the quiet choices.
5. **The last clamp has to be held:** the mechanism will not lock without a hand on it. This is why Danny stays behind, and the player does it.

---

## 6. Easter eggs and secrets

**What players love (checked patterns):** secret endings on replay (F9); a recurring hidden object, moved between versions and hinted at in a note (Peng, F9); hidden audio played backwards (Outlast 2, F9); joke endings that do not break the tone of the main story because they sit behind replays (F9).

**20 original ideas for Stay Behind.**
- **E1.** A sealed 1998 darkroom (pattern 12) holds the old photo club's undeveloped films. Developing them shows the school in old seasons, including a younger version of the janitor.
- **E2.** A recurring object: a rubber duck in a tiny graduation cap, hidden once per chapter (including the mothership, where the aliens have "taken" one into a specimen jar). Finding them all unlocks the duck as Kayla's keyring in the epilogue.
- **E3.** Danny's own locker, with his things: a drawing, a note from his mother, his old phone with an unsent text to Kayla. Reading it changes one line of hers in the epilogue.
- **E4.** Kayla's homework under the bleachers: a page of her own made-up symbols. She invented a code as a kid; it partly matches the alien one, a small mystery never explained.
- **E5.** A voicemail on the office phone, played backwards, is the hunter's whisper saying a survivor's name before it happened.
- **E6.** In the library, a book returned in 2026 that is 30 years overdue holds a letter from a former student who also "saw lights" over the city.
- **E7.** A developer room behind the theatre's trap door: concept pictures, the old web game playable on a dusty school computer (a nod to the browser game he made first).
- **E8.** Each Still One shifts one pose step each time the player saves. The poses spell a numeral in the alien language.
- **E9.** In the chem lab, the periodic table poster has one extra handwritten element, "Kaylium", from a joke between Kayla and Danny.
- **E10.** The gym's scoreboard can be set to Danny's birthday, and the school's old fight song plays softly through the PA (an original tune).
- **E11.** City: a pizza place with a sign "open during the apocalypse", with a working fridge and one cold slice that heals a little.
- **E12.** A cat in the city that follows Danny if fed and appears in the epilogue with Kayla, if it survived.
- **E13.** On the mothership, a hall of things the aliens took from Earth (a traffic cone, a trophy, a vending machine), including one item from the school Danny will recognise.
- **E14.** Alien graffiti: one soldier's private glyph diary, which can only be read on Hard with the full notebook; the soldier Danny knocked out had a family.
- **E15.** The radio: tuning it to a hidden frequency in the safe room plays a late-night DJ still broadcasting from across the city.
- **E16.** Secret ending (New Game Plus): find all of the hunter's scratch tallies and give the final count at the self-destruct panel. The hunter hesitates in the last scene.
- **E17.** Joke ending (New Game Plus): set the ship's course panel to "home" in the language, and Danny flies the alien ship to a fast-food drive-through.
- **E18.** The janitor's key ring has one key that never opens anything in the game. On the last screen of the epilogue, Kayla uses it.
- **E19.** A survivor's sketchbook in the safe room adds a new drawing after each chapter, of what happened while Danny was away.
- **E20.** Photo mode in the epilogue: Kayla's phone camera, with the Easter eggs she has "remembered" shown as photos in her gallery.

---

## 7. Environmental storytelling and set dressing

**Principles.**
1. Every room answers "what happened here?" as a chain of three beats: before (normal life), the moment (the interruption), and after (flight, a struggle, or someone hiding) [checked: gdcvault.com].
2. Dress in layers: the base use of the room; the event of that evening; the panic; then the creature's trace.
3. Personal traces: photos, phones, handwriting [checked: pcgamer.com excerpt].
4. Clue objects are lit, central and in-world marked. Dressing near them is quieter, so the clue stands out without paint (F11).
5. Never hide a needed item under clutter; clutter hides optional loot only.
6. Repeat patterns the player learns: e.g. a dropped bag points the way the owner ran.
7. Notes are short (under 120 words), in voice, dated, and each has one hook.
8. Phones: a lock screen with notifications as story. Its messages are the cheapest strong storytelling in a modern setting.

**Checklist: US high school during an interrupted evening event (game or dance).**
- Desks: open laptops with half-finished work, a teacher's grading stack, a mug, sticky notes, a forgotten hoodie.
- Floors: programmes for the event, ticket stubs, a dropped corsage or face paint, spilled popcorn, a single shoe, a phone face down still buzzing, scattered papers from a dropped binder.
- Walls and boards: "Homecoming" or "Spring Formal" banners, club posters, a lost-pet flyer, a bell schedule, fire evacuation plans, a whiteboard with tomorrow's homework.
- Hallways: open lockers, a fallen trophy, an abandoned mop cart, a fire alarm pulled with its glass broken.
- Gym: a tilted scoreboard, half-eaten concession food, spilled sports drink, coats on the bleachers.
- Cafeteria and kitchen: catering trays for the event, a cake with names on it, a burnt pan.
- Signs of the taking: chairs pushed back all one way, doors open towards the exits, the hunter's scratch tallies, no blood from the students.

**Checklist: safe room lived in by eight people for days.**
- Sleeping: mats from the gym, coats as pillows, a sleeping spot that has been empty since someone was taken.
- Food: rationed vending-machine snacks counted on a whiteboard; empty cans used as cups.
- Medical: a first-aid corner with the school nurse's supplies and a notebook of who took what.
- Power: extension cords running from the generator; a schedule of who sleeps by the heater.
- Social: a card game paused on a box; drawings on the walls; a list of the missing; a shrine of school photos; a radio on the table.
- Change over time: dressing is swapped between chapters; it gets dirtier, emptier, sadder.

**Checklist: city blocks after an evacuation.**
- Streets: abandoned cars with open doors, a jammed traffic intersection, evacuation route signs, police tape, a stroller, scattered shopping bags.
- Shops: windows with "OPEN" lights still on, a looted pharmacy, a half-pulled shutter.
- Homes: a TV left on, a note on a door saying where the family went.
- Alien presence: burn marks, glyph markers spray-painted by the Patrol on cleared buildings, abandoned debris lifted and dropped in strange patterns.

**Checklist: alien interiors.**
- Make the ship lived in, too: alien rest pods, a meal or ration station, maintenance tools, wear on handholds from three-fingered grips.
- Glyph signage everywhere, consistent with the language.
- A trophy-like display of taken human things (E13).
- Holding halls: pods with readable "count" displays.
- Worn bits that show an alien daily routine, so the place feels like a home, not only a threat.

---

## 8. Risks to the agreed map

- **R1. Reshuffled codes versus voiced lines.** If a survivor or Kayla speaks a code aloud, every value would have to be recorded. Rule: voice lines point at the carrier ("it's on the board in the gym office"), never say a value.
- **R2. Puzzle tier locked at New Game (as in SH2) versus "not too hard".** Recommend allowing the tier to be lowered mid-game. This is to be asked, not guessed.
- **R3. Mimic verification (pattern 26) needs facts from optional talks.** It must have a fallback so it never blocks progress.
- **R4. The language exam must not fail a player who skipped optional pages.** Guarantee the required glyphs on the critical path.
- **R5. The Still Ones' floor** makes puzzle reading (looking away) dangerous by design. Keep its puzzles short, add a mirror or camera route, and test it hard for fairness.
- **R6. Physical alternatives in the school** must stay non-violent: tools and noise, never weapons. This matches "nothing can be killed in the school".
- **R7. Easter eggs** must not reference the five games' content (characters, creatures, treasures). E7's old web game is his own work, so it is safe.

---

## 9. What I could not verify

- The exact rewriting of riddle text per tier in the Silent Hill 2 remake, beyond codes and clue placement.
- Whether Alien: Isolation's hacking screens pause the game, and its "three beeps" save cue.
- The exact verification rule in Chants of Sennaar beyond guide descriptions.
- Thomas Grip's exact wording, which came through a search summary.
- Whether the Dead Space remake's zero-g puzzles were rebuilt for free movement beyond what reviewers report.
- Tunic's number glyphs and any designer statement on teaching numbers first.

---

## Sources

- https://www.pushsquare.com/guides/silent-hill-2-combat-and-puzzle-difficulty-options-explained-what-settings-should-you-choose
- https://www.gfinityesports.com/article/silent-hill-2-remake-all-difficulty-settings-best-settings-to-pick
- https://noobfeed.com/articles/silent-hill-2-all-puzzle-code-compilation
- https://gamingbolt.com/silent-hill-2-remake-guide-all-puzzle-solutions-at-all-difficulty-levels
- https://gamesradar.com/games/silent-hill/silent-hill-2-remake-dev-says-it-infused-the-iconic-horror-games-puzzles-with-fresh-ideas-and-added-new-challenges-that-tie-into-the-games-story
- https://www.playstation.com/en-ca/games/silent-hill-2/silent-hill-2-replay-guide/
- https://gamesradar.com/games/survival-horror/silent-hill-2-remake-endings
- https://www.gamesradar.com/games/horror/following-resident-evil-4-and-final-fantasy-7-rebirth-fallout-the-silent-hill-2-remake-is-avoiding-yellow-paint-trend
- https://gameranx.com/features/id/467948/article/amnesia-the-bunker-all-dog-tag-locations/
- https://progameguides.com/amnesia/what-are-the-locker-code-combinations-in-amnesia-the-bunker/
- https://primagames.com/tips/how-to-break-open-wooden-doors-and-padlocks-in-amnesia-the-bunker
- https://store.epicgames.com/news/amnesia-the-bunker-is-a-chilling-underground-obstacle-course-of-horror
- https://gamingbolt.com/amnesia-the-bunker-will-avoid-linearity-and-evolve-differently-with-each-playthrough
- https://www.dualshockers.com/amnesia-the-bunker-interview-need-to-know/
- https://gamerguides.com/dead-space-remake/guide/walkthrough/chapter-4-obliteration-imminent/how-to-reroute-power-from-electrical-systems
- https://game8.co/games/Dead-Space-Remake/archives/402014
- https://www.sportskeeda.com/esports/5-major-differences-dead-space-2008-the-remake
- https://www.destructoid.com/dead-space-remakes-intensity-director-explained/
- https://progameguides.com/dead-space/how-to-fix-the-comms-array-puzzle-in-dead-space-remake
- https://techradar.com/features/i-wasnt-expecting-dead-spaces-worst-mission-to-get-fixed-like-this
- https://pcgamer.com/dead-space-marker-fragment-locations-secret-ending
- https://www.pcgamesn.com/dead-space-remake/peng-treasure
- https://www.gamepressure.com/alien/restore-access-to-distribution/ze6a25
- https://feralinteractive.com/br/switch-games/alienisolation/how-to-survive
- https://gameinformer.com/games/alien_isolation/b/ps3/archive/2014/08/13/one-merciless-alien-countless-bloody-deaths-alien-isolation.aspx
- https://www.nme.com/features/alien-isolation-is-a-too-perfect-organism-3337829
- https://gamedeveloper.com/design/game-design-deep-dive-the-save-system-of-i-alien-isolation-i-
- https://www.pcgamesn.com/interview-creative-assembly-alien-isolations-terrifying-alien-ai
- https://www.pcgamer.com/gaming-industry/alien-isolation-under-the-microscope-an-excerpt-from-new-companion-book-perfect-organism
- https://primagames.com/news/alien-isolation-mission-14-descent-boltgun-reactor-destroy-nest
- https://gameranx.com/features/id/104397/article/outlast-2-play-recordings-backwards-for-secret-audio-easter-egg-guide/
- https://thelanguagecloset.com/2024/12/07/playing-chants-of-sennaar/
- https://en.wikipedia.org/wiki/Return_of_the_Obra_Dinn
- https://Wikipedia.com/wiki/Tunic_(video_game)
- https://en.wikipedia.org/wiki/Raccoon_Police_Station
- https://bloody-disgusting.com/video-games/3655219/horror-resident-evil-baked-right-level-design-resident-evil-25/
- https://www.gdcvault.com/play/1012647
- https://www.buymeacoffee.com/jrutila/the-hint-system-return-monkey-island-almost-perfect
- https://gamedeveloper.com/design/how-and-why-to-write-low-spoiler-hints-for-adventure-games-
- https://www.gfinityesports.com/article/how-resident-evil-requiem-solves-the-yellow-paint-discourse
