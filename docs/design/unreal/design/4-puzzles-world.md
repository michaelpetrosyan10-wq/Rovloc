# Stay Behind: the world, the puzzles and the detail (second edition)

**Second edition, 21 November 2026: agrees with the game map and the canon sheet; where they differ from this document, they win.**

What this is: the places of the game, every puzzle chapter by chapter, the power story, the alien symbol language,
the city, the mothership, the pacing, the secrets and the dressing, written so a builder can block it out. Above it
stand, in order: the owner's own words (requirements.md sections 7 to 10, owner-checklist.md), the game map
(game-map.md), the editor's rulings (drafts/CHANGES-NEEDED.md) and the canon sheet (canon.md). **(canon N)** means
section N of the canon sheet. This document owns the places, the heights and the stairs (canon 4), the evening's clock
and the minutes of every part (canon 3), where the items lie (canon 10), the puzzle tiers (canon 11), the symbol
language (canon 12) and the self-destruct (canon 13): those values are written here and the canon sheet carries the
same ones. Every other shared name, number or rule is cited, never copied. **cutscenes.md is the authority on the
cutscenes**; this document only names the ones a puzzle leads into. Every puzzle has a *Seen in:* line naming the game
on his list whose pattern it uses, or "ours"; only the pattern is taken, never a creature, puzzle, scene, line or name.
Details that are in neither the map nor the canon sheet are this document's working choices and stand until a higher
document says otherwise.

---

## 1. The school as a place

### 1.1 Name, city, night
- **Rovloc High School**, in the river city of **Calloway** (a working name the owner may change: canon 4), built
  **1962**, renovated **1998**. The two eras disagree on the walls (old room names, new numbers), and that
  disagreement is a clue source the player learns to expect.
- **Friday 20 November 2026**, the first home basketball game of the season. The evening (this document's, canon 3):
  tip-off 7:00 pm; halftime 7:48, with a confetti-cannon and balloon routine by the cheer team; Danny and Kayla walk
  out 7:51; **the pulse 7:56** (the lithium pulse and the dead grid: canon 6; the scoreboard freezes on HALF, HOME 31
  GUEST 34); the small ship lands on the football field 8:01; the assistant principal presses LOCKDOWN 8:03; Danny,
  Kayla and Gus are behind the shelter door by 8:06; the building is silent by about 8:40.
- **Dark by day** (canon 3): from the pulse to Tuesday dawn the mothership's underside covers the city and the sun
  never reaches it; by day the sky is a low dark gray with a thin band of light at the horizon. At the 8:03 lockdown
  every classroom blind came down. So every school chapter, Saturday morning to Monday's last light, is as dark as
  night inside, lit only by the torch, the exit signs, the circuits Danny powers and gray slits at the window edges.
  No floor is lit by daylight through its windows.
- What still works after the pulse is canon 6. So the traces people left are mostly analog: notes, sign-in sheets,
  Polaroids and film, phone cases with photos tucked inside, the wired PA, the office answering machine (a tape
  machine on the mains), the band room's cassette deck, and from Chapter 1 the tape logger Priya sets up on the
  shelter's 1962 base station.

### 1.2 The building
- **One block, 112 by 81 m** (the earlier game's 400 by 288 stud footprint at 0.28 m a stud), a basement, four floors
  and a flat roof. The earlier game's layout data is reused for the blockout: its east and west stair towers become
  the **West and East stairs**, its Level 0 tunnel plan (seed 20261103: five regions, junction plates J-01 to J-18,
  crawlways, hide niches within 8 m of every point) becomes the steam tunnels.
- **Every Layout JSON also exports a room-portal graph**: path distances, the occlusion of each portal, the light
  volumes and the hide spots. The headless rules tests (creatures and production) run on it, so a floor is not
  finished until its graph is exported and matches what is built.
- **Heights** (canon 4), set for the hunter's body (canon 8: on all fours): corridors 2.7 m to the ceiling tiles;
  classrooms 3.0 m; doors 2.1 by 0.9 m (it squeezes through, front limbs first); the lobby 7.5 m; the gym 9 m clear
  (F1 to F2); the library 5 m; the theatre stage 16 m to the grid (F2 to the roof); the stair wells 20 m open (it can
  look down the well); **tunnels 2.8 to 3.0 m**, so it walks them (the owner's "monster walking around the tunnels");
  **ducts and crawlways about 110 cm wide and 120 cm high** (the owner's "Bigger crawlways", 22 November: it follows
  Danny through them, a tight squeeze, slower than him and always heard: canon 5 and 8; nothing is out of its reach).
  **Open, for him:** every duct and crawlway at that size, or only those it follows Danny through (canon 4)?
- **Ways between floors:** the West and East stairs (basement to F4); the roof only by the penthouse stair in the F4
  mechanical room (canon 4); the lobby's grand stair (F1 to F2 only; its fire shutter dropped at the lockdown); the
  kitchen **freight lift** (basement to F1 only; its load: canon 6); the **dumbwaiter** (one-way down to the shelter
  cabinet, hatches in the F1 kitchen, the F2 staff room, the F3 staff lounge and the F4 home-economics kitchen; its
  noise: canon 7); the dead passenger lift (its shaft is a hunter route); the theatre's fly tower ladders (F2 to F4);
  the 1962 **exterior fire escape** on the south face (F3 to F4 only; its lower flights were cut away in 1998).
- **The lockdown rule** (canon 4): at 8:03 every stair door locked **on its stair side** and the grand stair's fire
  shutter dropped. The locks are fail-secure: with no power they stay locked. From a floor Danny can always push out
  into a stair; from a stair he cannot get onto a floor. So he enters every floor its own way (the freight lift, the
  bleachers, the fly gallery, the fire escape), crosses it, and **props its stair door open from inside** with a
  wedge: that stair is then his fast way home, and no floor is ever a dead end. The basement's stair door is propped
  at the end of Chapter 1, so the stair reaches home. Only two floors add power to this (canon 4): on **F1** the
  electrical closet powers the PA that Halftime Draw needs (2.3); on **F4** the stair doors are the 1998 lab floor's,
  held shut both ways by powered locks that open only with the floor's riser live and closet 4's release turned, which
  in Chapter 5 must be done before the fleeing group reaches them (5.5). On F2 and F3 the closets feed circuits a
  puzzle needs (3.1, 3.4, 4.3, 4.5), and no door depends on them.
- **The riser key** (canon 4: a brass key on a red tag, ELEC 1 to 4). It opens the four electrical closets, stacked in
  the core on every floor, and turns F4's stair release. It lies in the office safe in Chapter 2 and has no loud way
  round it, so it is never missable.
- **Gus's key ring** (binder, no slot: canon 5) opens the custodial closets in the core, the boiler side, the PE office
  and the mower shed. Some keys are unlabelled; Gus labels one after each chapter if Danny has helped him, and each
  opens a closet on an earlier floor (supplies, a story note). One never opens anything (secret 14).
- **Lantern rooms** (canon 4 and 11): the shelter's logbook; F1 the nurse's rest room; F2 the theatre lighting booth;
  F3 the yearbook darkroom (red safelight); F4 the biology prep office beside the cold room; none on the roof.

### 1.3 Level by level (hub, spokes, locks; "loud" is the way round a lock, its noise from canon 7)

**Basement: the shelter and the tunnels (Chapter 1).** Hub: the **boiler cross**, outside the shelter door. Spokes:
the **shelter** (1962, two rooms of 14 by 8 m, yellow-and-black signs, water drums, the 1962 shortwave base and its
tape logger, the camera monitors; a steel door with wired glass, barred from inside); the **boiler room** with the
diesel generator; the **switch room** (main switchboard, open); **Gus's workshop** (blueprints, parts bins); the **PE
office and locker rooms** under the gym (the walkie cabinet, the coach's wind-up stopwatch; Gus's key); the **kitchen
undercroft** (dry storeroom: padlock, loud: pry bar; freight lift bottom); the **records room**, the **band storage
cage** and the **bus drivers' room**, the three doors with the Patrol's sprayed tallies (1.3); the **steam tunnels**
north-east to the **bus garage** (three buses: the visiting team's coach and two district buses; gate on Gus's key),
with the **flooded stretch** (sump pump) and the **fuel store** (chained drum, Gus's key); the **bricked arch**, a
short cut to the garage that only the sledgehammer opens (it brings the hunter); and south, the field-house tunnel the
hunter came in by (open, and the direction of dread).

**First floor: the game (Chapter 2, Listeners).** Hub: the **lobby** (terrazzo, trophy cases, the grand stair closed
at its top). West: the **main office** (glass door: Gus's key, loud: the pry bar through the glass), its **safe**
(dial, loud: the sledgehammer on the hinge, four blows), the **bell and PA rack**, the answering machine on the PA
line (secret 9), the **nurse's office** (medicine closet: key from the safe, loud: pry bar) and its rest room. North:
the **commons** (concession stand, booster bake sale, the halftime raffle table) and the **kitchen** (walk-in freezer,
freight lift top, dumbwaiter, loading dock). East: the **gym** (bleachers out, coats on them, scoreboard frozen, the
announcer's desk), the athletic director's office, the trainer's room, the locker corridor (Priya's locker). South
(1998 wing): the **band room**, the **tech workshop** (the crafting bench: game logic only), the **groundskeeper's
cage** (bolt cutters; Gus's key). Core: electrical closet 1, custodial closet 1. Way in: the freight lift. Way up: the
bleachers to F2's running track.

**Second floor: the arts (Chapter 3, Still Ones).** Hub: the **upper lobby** behind the fire shutter. East: the gym's
**running track** (the way in). North: the **theatre** (500 seats; stage, wings, fly rail; behind it the **scene
shop**, the **dimmer room** on the stage manager's key, the costume shop), the **lighting booth** at the back of the
house, and beside it the **AV room** (the camcorder). West: the **art studios** (ceramics and kilns; the sculpture
room of sheeted easels and casts). South: the **music suite** (choir room, practice rooms, the music office). Core:
electrical closet 2, the staff room. Way up: the theatre's fly gallery to F3. The Still Ones do not hear (canon 7), so
loud ways here cost nothing with them, only with the hunter, which makes the hunter's ears the whole question on this
floor.

**Third floor: the people (Chapter 4, Mimics).** Hub: the **humanities hall**. North: the **library** (reading room
under its broken clerestory, stacks, the card catalogue, the circulation desk with the late-room sign-in sheet). West:
the **yearbook room** and darkroom, the **language lab**. South: the **counselling suite**, the **lost-and-found**
closet (Gus's key after Chapter 3, loud: bolt cutters), and the windows onto the exterior
fire escape. East: classrooms with lockdown locks (a closed door locks itself), Danny's locker. Core: electrical closet
3, the **server room** and IT office (badge reader on its own lead-acid backup, loud: the pry bar on the strike), the
**IT storeroom** (secret 7), the staff lounge. Way in: the theatre's fly gallery door. Way up: the fire escape.

**Fourth floor: science (Chapter 5, Swarm).** Hub: the **science corridor**. Rooms: **chemistry** and Ms. Kessler's
**prep room** (balance lock, the dry-ice cooler, the CO2 extinguisher); **biology** with its **greenhouse room** (grow
lights, heat mats: the warmest place on the floor), its **cold room** and the biology prep office beside it (the
lantern room); **physics** (the thermal camera, the crank generator from the demo kit); the **home-economics kitchen**
(kettles, dumbwaiter); the **mechanical room** (air handlers, the heating valves, the penthouse stair, the only stair
to the roof); the theatre's loading gallery door (like every door onto a floor, it opens only from the floor side).
Core: electrical closet 4, custodial closet 4 (facilities binder). The stair doors are held by powered locks (1.2).
Way in: the fire escape into the chemistry lab window. Way up: the roof door at the top of the penthouse stair,
chained by the roofing contractor (bolt cutters: the story's "door chain cut").

**Roof.** Gravel (canon 7), rooftop air units and ducts, the fly tower box standing 4 m higher, skylights over the
two stair wells and the central light well (they do not hold weight), a parapet 1.1 m high, the penthouse with the
floodlights' own sealed can (canon 6). The hunter's one long chase (canon 8) runs here as a **built obstacle run**
over the ducts and air units and around the skylights, into the helicopter's light: the owner's "one final chase like
door 100". The mothership fills the sky to the north.

### 1.4 How earlier floors change when Danny comes back
Each chapter starts with a short re-crossing of the floor below, 3 to 5 minutes, through a space the player knows:
- **Chapter 3, the gym again:** the rain on the gym roof has stopped (no masking but the heating knocks); the
  Listeners have gone back to the gym; two coats on the bleacher route have slid off, so the soft path is broken.
- **Chapter 4, the theatre again:** the stage where the Mark happened; the Still Ones have moved into the wings and
  one stands on the fly gallery ladder; the board remembers the last cue, but a fuse has blown again (3.5).
- **Chapter 5, the counselling suite again:** a Mimic stands by the fire-escape window, facing away, in his route
  (canon 9).
- **The basement on every return:** Dweller trails over Danny's chalk marks; the tunnel lights only as the power
  choices left them; the generator reserve shown on the gauge and in the room.
- **Any floor left powered** keeps costing the reserve (canon 6). Turning old floors off is good housekeeping and the
  player learns it.

---

## 2. The puzzles, chapter by chapter

**Rules for every puzzle.**
- **Tiers** (the puzzle setting, separate from creatures; this document's, canon 11): **Light** puts the clue beside
  the lock, the notebook writes the fact down, glyph panels show overlays, and Kayla's hint rungs come at 2, 4 and 6
  minutes, then the answer if asked again (about a third less puzzle time). **Standard** puts the clue in another
  room, two steps away; rungs at 4, 8 and 12 minutes. **Hard** makes the clue oblique or adds a decoy, adds one story
  riddle object per school floor (below), shows no glyph overlays, uses Flare Road's 1962 breaker names, and gives
  only two rungs, at 6 and 12 minutes. The tier can be lowered at any time (a puzzle under way and not yet solved
  rolls new values) and raised only at a chapter start (the owner's rule of 21 November: canon 11).
- **Reshuffle:** one seed rolled at New Game and kept through every save (canon 11). Clue carriers never move; their
  values change. Item spots come from 3 to 5 hand-placed spots; story items never move (canon 10). Glow sticks are
  common, a light found in plenty; lures (bottles, cans) are scarce (the owner's choices: canon 10). **No voice line
  ever says a value.**
- **The hint ladder:** only in a quiet moment, Kayla on the radio gives H1 (where to look), H2 (what kind of thing),
  H3 (the action), at the rungs of the tier. An H3 or an answer that would need a value is **written into the binder
  map in her blue ink**, never spoken. In Chapter 1 Gus gives them in person. In Chapter 4 Kayla is beside Danny and
  gives them in a whisper, kept more than 3 m from any figure (a Mimic hears any voice within 3 m, a whisper included: canon 9). After Kayla is taken (Chapters 6 to 8) the hints
  come from Danny's own notebook, in his hand, headed "what would K say".
- **The loud way:** every school lock has one, except the electrical closets and story items (canon 11). Its cost is
  noise (canon 7) and the floor's creature answers it by its own rule (canon 9); on the Still Ones' floor only the
  hunter hears.
- **At most one paper-code lock a chapter** ("find the number on paper"): Chapter 1 the Pantry (1.2); Chapter 2 the
  safe (2.1); Chapter 3 Curtain's two cue numbers (3.4); Chapter 4 none; Chapter 5 the balance (5.1); Chapter 6
  none; Chapter 8 Kayla's seal (8.3), scratched rather than written, counted all the same.
- **One riddle object per school floor, Hard only** (the Silent Hill 2 remake's pattern: a story object whose written
  lines are the clue): the basement, Walter Hale's watch card (1.2); F1, the principal's framed verse (2.1); F2, the
  stage manager's prompt book (3.4); F3, the yearbook adviser's caption card (4.1); F4, Ms. Kessler's board verse
  (5.1). The script writes every verse; this document says what each must point to.
- **Restart points** (canon 11): a death on Story or Survivor restarts Danny at the start of that encounter,
  large-puzzle stage or solved step, with the puzzle's state kept. No puzzle carries a checkpoint of its own.
- Chapter 6's puzzles are in section 5 and Chapter 8's in section 6.
- **Never** a puzzle that needs a resource the player can run out of (where a puzzle needs batteries, a pair is always
  within the puzzle space); never a paused world; every step confirmed by a sound, a light or a notebook tick.

### Prologue: "Halftime" (one teaching beat)
**P0 The plan on the wall (1 min).** By the band-room door, the F1 fire-evacuation plan shows "SHELTER (B)". Danny
lifts it off its hooks and it becomes his first map. Teaches: maps come off walls; the binder holds them. *Seen in:*
Silent Hill 2 remake (maps found in the world, which mark themselves as you learn).

### Chapter 1: "The Shelter" (basement, Dark Dwellers)
**1.1 Gus's Ears (7 min).** The owner chose it over Dead Start as written: "Yes, Gus's Ears" (21 November).
*Situation:* the generator never took over at the pulse; Gus pulled its start relay on Tuesday to replace it. His
hearing aid is nearly flat (its cells are his Chapter 2 need), so he cannot hear her, or anything a few metres away:
he works with a hand flat on the engine and asks Danny what she sounded like. *Pieces:* the generator's nameplate
(relay part number, 12 V); six similar relays in the labelled bins of Gus's workshop; the start card on the wall
(prime, choke, pull) and Gus's logbook, which adds the one fact the card lacks ("bleed the filter screw first or she
dies on you"). *Steps:* the quiet work first: match the part number, fit the relay, open the tagged supply valve,
bleed, prime until the sight glass fills, choke. Then pull: once she is ready she catches on the first pull (systems
6.1). Every pull is 80 on the noise table, heard through the whole basement (canon 7), and a few seconds later heavy
steps answer in the pipes, a little nearer each time. Gus does not hear them; Danny does. **Every failed pull is a
clue** in the way she fails: she does not turn at all (the wrong relay, the one failure that is not loud); she turns
over and never fires (no fuel reaches her: the valve, or the glass is not full); she fires and dies (air in her: the
bleed screw); she fires and will not hold (the choke). Between pulls, a choice: pull again now, or kill the light and
wait for the steps to go back down the pipes (waiting costs time, and battery if the torch stays on). Gus shows the
cupped beam here ("cup it"): its red glow reads the glass and the log (systems 3.1). When she catches, the lights come
up, her hum hides Danny from everything down there (canon 7) and the answering steps stop. **What Danny tells Gus**
(the owner's choice, 22 November): on Standard and Hard the player listens and picks what Danny tells Gus, and every
failure sound is also written in the captions; on Light, Danny says it himself. *Creature:* the hunter, heard only,
answering each loud pull in the pipes (creatures 1.9). **On the 4th loud pull it comes right up to the boiler-room
door: a near miss, no chase** (it sniffs at the door and goes; the owner's choice, 22 November), **at most one near
miss in the puzzle** (the proposal he chose on 21 November: "at worst one near miss, no chase"). The pipes going
quiet is its tell; Gus, who cannot hear it, reads Danny's face. *Hints (Gus):* for the relay, "the plate tells you
what she eats"; "my bins say it the same way"; he points. For the failures: first, that she will say what is wrong and
he cannot hear her any more; then what kind of sound means what ("if she fires and dies, she's got air in her"); last,
he points at the thing to fix. No number is ever spoken. *L:* one relay fits; the card is whole, the bleed included.
*S:* as above. *H:* two relays share the number, one is 24 V; Gus's log is in his shorthand. *Moves:* the part number,
the bin, the prime count (shown by the glass). *Seen in:* Amnesia: The Bunker (noise as the dial for how often it
comes; a generator started by hand, whose fuel then runs the lights) and Alien: Isolation (every loud thing you do
draws it to you).

**1.2 The Pantry (7 min).** *Situation:* food for eight is in the undercroft dry store, through the near tunnels,
where the hunter is heard in the pipes only. *Pieces:* a three-number padlock; the kitchen manager's delivery
clipboard. *Steps:* read the code; open. *L:* on the clipboard's front. *S:* on the back of the last invoice. *H:* the
floor's riddle object: **Walter Hale's watch card**, a 1962 card nailed inside the store's door frame, a four-line
verse about counting what the trucks never brought; the clipboard's front lists ordered against delivered, and the
three cases that came short, in the verse's order, are the code. Gus knows the card if asked (secret 13).
*Creature:* the sounds in the pipes are the hunter's true position (an honest cue). *Moves:* the numbers and which invoice.
*Loud:* the pry bar on the hasp (canon 7): the hunter comes to check within a minute. *Seen in:* Amnesia: The Bunker
(a code that changes each playthrough, found on paper, with a loud way through the lock).

**1.3 FLARE ROAD (large, 20 min, the counting on its path included).** *Situation:* the first outage is scripted
(fuel); Gus's last can (canon 6) is enough to restart, and the fuel is far: the fuel-store drum or the buses (siphoning:
canon 6). The tunnels are dark. *Pieces:* (a) the tunnel sub-panel at J-01, six breakers, whose main holds only three
at once; on Light and Standard each breaker carries its 1998 stretch label, on Hard only its 1962 name (COAL RUN,
MILK DOCK, ORCHESTRA STORE...); (b) the 1962 tunnel blueprint in the records room, with the old names; (c) the
junction plates J-01 to J-18 and the 1998 tunnel map on the switch-room door, numbers only; (d) four road flares and
a box of the cheer team's glow sticks (their light: canon 6); (e) the flooded stretch on the short route, with its
sump pump (its load: canon 6); (f) the drum (Gus's key) and the buses.
*Steps:* match the breakers to the stretches on the plates (on Hard, read the old names onto the J stretches through
the blueprint); light the three sections that leave the fewest dark gaps; for the flood, run the pump (the shelter
heater goes off and someone says so), wade (every step splashes, for the hunter: canon 7), or take the long way (one
more gap); bridge each gap with a flare or a glow-stick pool, four flares for a route that needs five (the creature
set piece; the last stretch on glow sticks); fill the cans; come home; refuel at the tick line. On the way back Gus
radios that the switchboard can keep only two of the shelter, the corridor home and the infirmary fridge (the
creatures' "two of three", a quiet choice).
*On the path: Count the Empty.* Three doors (the records room, the band storage cage, the bus drivers' room) carry
the Patrol's sprayed tallies, the glyph for "taken" beside each. Inside each: chairs pushed back, coats, a lunch bag:
the people who were taken from there. Matching the tally to the count in all three confirms **Numbers I** (section
4). The records room also holds the blueprint, so the counting sits on the path. *L:* the notebook draws the count
beside the glyph. *S:* count yourself. *H:* one room holds Gus's own coat (he says so; it does not count). *Moves:*
the counts.
*Creature:* Dwellers own every dark stretch and cannot enter light; the hunter is in the tunnels for the first time,
walking, and light does not stop it (a flare drives it off: canon 6). *L:* Gus has pencilled the best three stretches
on the J map; the main holds four. *S:* as above. *H:* the 1962 names; Gus swapped two breakers in 2014 (his note);
one section is dead and must be found by testing (each test is half a minute of dark). *Moves:* the wiring (three
authored sets), which bus is dry, the glow-stick box. *Fixed:* blueprint, plates, drum. *Loud:* on the way back, the
bricked arch to the garage: three sledgehammer blows halve the walk home and bring the hunter. *Hints:* Light and
Standard: "the switch-room door has the tunnel plates"; "the main only takes three: light where the dark is longest";
H3 written: the three breakers marked on the map. Hard (two rungs): "the panel's names are older than the plates";
"the records room had the old plans". *Seen in:* Amnesia: The Bunker (generator fuel as the clock on your lights) and
Alien: Isolation (choosing which systems get the power).
*Chapter end:* the KITCHEN LIFT breaker (its load: canon 6) brings the freight lift down; it is the way up. Gus wedges
the basement's stair door open (1.2).

### Chapter 2: "Halftime Draw" (first floor, Listeners: blind, hear everything, go to where the sound was)
**2.1 Drill Log (6 min).** *Situation:* the office safe holds the **riser key** and the nurse's closet key.
*Pieces:* the emergency binder in the principal's office ("Safe: date of the last lockdown drill, MMDD"); the drill
log on the reception wall (fire, lockdown and shelter drills, dated); the wall calendar. *Steps:* read the rule, find
the date, dial it. *Creature:* a Listener in the attendance office; every number set and the handle make a sound it
can hear (levels for audio to add to canon 7), so each number is turned inside one heating knock (the mask: canon
7). Carpet is quiet; the spilled forms in reception rustle (paper: canon 7). *L:* the binder gives the code. *S:* rule
plus log. *H:* the floor's riddle object: in place of the binder's rule, **the principal's framed verse** on her desk,
"for the worst day", whose lines point to the last lockdown drill before the break; the log holds two lockdown drills,
and the calendar shows the break. *Moves:* the drill dates. *Loud:* four sledgehammer blows on the hinge; every
Listener on the floor rushes the office. *Hints:* "the office kept a binder for the worst day"; "drills get logged
where everyone walks past"; H3 written: the log's place. *Seen in:* Amnesia: The Bunker (a code pieced together from
notes, worked under a creature that hears).

**2.2 The Nurse's Closet: a silent search (4 min).** *Situation:* the story's needs from this room: Gus's
hearing-aid cells, Mari's inhaler, Ray's painkillers (canon 10). The medicine closet opens with the key from the safe
(loud: pry bar). A Listener waits in the waiting room. Prescription bins are labelled by **student ID, not name**
(privacy, as real schools do); Mari gave Danny her student card, Gus his battery case (the size is on it); the
painkillers are on the staff shelf. *Pieces:* the closet's shelves of plastic bins, whose lids and contents rattle;
the nurse's white-noise machine by the door (real: it is there for privacy), small enough to carry, which masks him
within its reach (canon 7) once given a battery pair; a spare pair is always in her desk. *Steps:* power the machine;
set it by the shelf he is working; search inside its reach, bin by bin; carry it to the next shelf; read the bins by
the card's ID and the cells by the case's size among four tab colours. A dropped bin is a dropped item (canon 7) and
brings the Listener. *L:* all three on one shelf, inside the machine's reach from the door. *S:* across two shelves,
the machine moved once. *H:* across three shelves, the third behind the cot where the machine cannot stand, searched
inside heating knocks; two IDs differ by one worn digit, and the class year on the card decides. *Moves:* the ID, the
shelves, the drawer. *Seen in:* ours (a sound mask you carry while you search).

**2.3 HALFTIME DRAW (large, 18 min).** *Situation:* three Listeners nest in the gym, which Danny must cross to the
bleachers (the way up), the band room (Marcus's drumstick) and the locker corridor (Priya's glasses). The maple floor
is carpeted in the cheer team's confetti, cups and balloons (their levels, the balloon pop's above all: canon 7).
The plan: walk the pack out and shut it in the kitchen. *Pieces:* (a) the bell and PA rack in the main office: nine
zone buttons and a chime; it needs electrical closet 1 (riser key) and the PA circuit found on the closet's directory
card (its load: canon 6): this is F1's power closet (1.2); (b) zone stickers on speaker grilles (Z1 to Z9) in the
rooms Danny passes; (c) the run sheet on the athletic director's clipboard in his office off the gym ("halftime: band
in gym; raffle in the commons; seniors to the lobby; after the game the kitchen opens for the booster dinner"), which
names the areas and shows the breezeway doors; (d) the kitchen's double doors (a closed door: canon 7). *Steps:* power
the PA; work out the zones; chime the gym, then the breezeway, then the commons, then the kitchen, each once the pack
has reached the last (listen: their hum stops when they arrive); close the kitchen doors, eased, inside a heating
knock; cross the gym in the waves of rain on its roof (canon 7). *Creature:* a chime walks the pack to its zone (canon
9); chime the next zone before they arrive and they rush. The scoreboard horn at the announcer's desk is the panic
button (audio sets it at the air horn's level): they scatter everywhere. *L:* zone names printed by the buttons. *S:*
numbers only. *H:* the 1998 rewire put the breezeway and the lobby on one zone (a custodian's note on the rack), so
the pack splits unless the lobby is chimed first. *Moves:* zone numbers per room, one dead speaker. *Loud:* the horn
or banged pans (canon 7), which leave the pack scattered, not shut away: harder, never blocked. *Hints:* "the office
ran the whole night over the speakers"; "the AD never put his clipboard down"; H3 written: arrows on the map. *Seen
in:* Alien: Isolation (a noise that sends the creature where you want it).

**2.4 The Coats (4 min).** The bleachers: twelve aluminium rows (metal: canon 7), the top 1.6 m below the
running-track rail. The coats, scarves and blankets the crowd left (coats: canon 7) make a soft path, not a straight
one; the torch shows it from the floor before he climbs. A coat with a thermos in its pocket clanks. *L:* one
unbroken path. *S:* one gap, crossed in a heating knock. *H:* two gaps and a balloon under a blanket. *Moves:* the
coat layout (three sets). *Loud:* the bleacher motor makes a ramp of the rows for 20 s (its level for audio; working
value 70). *Seen in:* ours (the stuff on the floor as the puzzle).

### Chapter 3: "Still Life" (second floor, Still Ones: eyes, light or a recording camera hold them; mirrors do not)
**3.1 The Camcorder (5 min).** *Situation:* electrical closet 2 is in the core corridor with two Still Ones, one in
an alcove; working the panel (20 s facing it) means looking away. *Pieces:* the AV room's tape camcorder, carried from
now on (its batteries and night vision: canon 6; a fresh pair in the AV room's tape drawer, so the puzzle never rests
on the player's stock), and its tripod; the corridor's convex mirror, which shows both and holds neither (mirrors
never count: canon 9). *Steps:* set the camcorder on the tripod where its flip-out screen shows both (only the
corridor's end takes in the alcove); record (red light on, it watches its cone); find the corridor and theatre
circuits on the closet's card; switch them on (the closet's limit: canon 6). No door depends on this closet (1.2).
*L:* one Still One. *S:* two. *H:* two, and the frame must also hold the art-room doorway a third comes from when the
lights change. *Moves:* start poses (three sets). *Hints:* "something here was always filming"; "the AV room's camera,
and it has to see both"; H3 written: the tripod spot. *Seen in:* Outlast 2 (the camcorder); that it holds them is
ours.

**3.2 Brownout (3 min).** With F2's circuits on, the generator is at the top of its load (canon 6): the voltage sags
and the floor's fluorescent tubes flicker, and every dark flicker is a step for them (the creatures' twist). The
closet's needle sits in the yellow; Kayla says the shelter lights dipped too. Choose one: Gus turns off the shelter
heater (the survivors are cold and say so once; remembered); or shed the F2 corridor circuit (the art and music wing
goes dark, and 3.3 is then done by torch); or turn off the boiler-side corridor lights (Dwellers on the walk home).
*H:* two circuits on the card share the name STUDIO and only one is the corridor. *Seen in:* Dead Space remake
(choosing which system loses its power).

**3.3 The Choir Folders (5 min).** *Situation:* Mari's guitar strings are in the music office's accessories cabinet,
shut with a lock of four colour tabs (red, green, gold, blue, white). The choir director's note on the cabinet:
"Cabinet: the folders as they stand on the set." *Pieces:* the choir folders on the choir-room chairs, one colour per
section, each stamped with its section; the December concert's set plan pinned in the choir room: the stage's risers
drawn in front of the painted winter trees, each riser block named for the section that stands there. *Steps:* match
each section's folder colour to its riser on the plan; read them left to right as the audience sees the stage; set
the tabs. *Creature:* Kayla holds the room's three Still Ones on the floor's cameras (canon 14) while he works;
mid-puzzle her camera dies (the creatures' set piece "Kayla's eyes") and he finishes with the torch on them, every
glance from the folders to the plan a moment unwatched while they close in. *L:* the plan is coloured in. *S:* the
plan names the sections; the folders give the colours. *H:* the plan is drawn from the stage side, so its left is
the audience's right (a note in its corner says so), and one folder on the chairs is last year's, in an old colour
(its date tells). *Moves:* the colour per section, the riser order (three sets). *Loud:* bolt cutters on the hasp
(canon 7; only the hunter hears). *Seen in:* ours.

**3.4 CURTAIN (large, 18 min).** *Situation:* the way to F3 is the fly gallery above stage right. The stage holds the
December choir concert's set (painted winter trees on flats) and five Still Ones among the trees; one more stands in
the house aisle. The stage lights are dead. *Pieces:* (a) the dimmer room behind stage left, two of four cartridge
fuses blown, spares in a tin in the scene shop (ratings stamped on caps and rack), its key on the stage manager's
lanyard at her desk in the stage-right wings, so one dark crossing of the wings comes first (the camcorder, recording,
can hold the corridor behind him); (b) the lighting console in the booth at the back of the house (the lantern
room); (c) her prompt book with the concert's cue list ("full stage, the snow song"; "work lights, for the set
change"); (d) the fly rail: a line holding the night-sky drop that hides the gallery ladder; (e) the theatre
dimmers' circuit, switched on at closet 2 (3.1). *Steps:* fuses; in the booth, fire the full-stage cue (it holds
every figure on stage) and park the work-lights cue on top (it lights the wings and the ladder); walk the house and
the stage edge keeping the lit figures in view; unlock the rope lock and haul the drop out (a 6 s hold on a heavy
line); climb (looking up is looking away: the work lights are what hold them); at the gallery door to F3, prop it:
the next chapter's way in. **Mari** (story) stays in the booth on the board as a second pair of eyes on the house.
*Twist:* the concert's haze cue sits next to the full-stage cue, and haze breaks every line of sight (the fog
canister's rule: canon 10). *L:* a sticky note marks the two cues; one fuse blown; the haze cue locked out. *S:* as
above. *H:* the floor's riddle object is **the prompt book** itself: its cue list is in stage directions only ("when
the snow falls, everyone is seen; when they move the trees, the work lights"), and the console holds two cue lists
with offset numbers. *Moves:* cue numbers, which fuses, the tin's spot. *Loud:* none clean; the fallback is the
booth's follow-spot, one figure held at a time, a slow and frightening crossing. *Hints:* "it's a show; shows have
scripts"; "the stage manager runs the lights from her book"; H3 written: the two cue numbers in blue. *Seen in:*
Silent Hill 2 remake (a story object whose written lines are the clue).
*Then the Mark* (story; first person, never a cutscene): back down on the stage, the hunter's whisper behind him
turns his head, the floor's trap. It lifts him, marks him and takes Mari instead (canon 1 and 2). He hears her call
his name once, far off.

**3.5 The Way Home (about 4 min; not a puzzle).** Danny wakes on the stage, hurt (the scene: cutscenes.md). There is
no calm return. Badly hurt, limping and leaving a trail the hunter can follow (canon 5), he must cross the live floor
to the stair door he propped, the Still Ones still on it. The work lights fail behind him as the fuse he replaced goes
again (the Chapter 4 return finds it blown, 1.4), so the corridor is lit only as the Brownout choice left it (3.2),
and the camcorder, recording behind him, is the one thing that holds a corridor while he limps away from it. Mari's
strings are still in his pack.

### Chapter 4: "Who's There" (third floor, Mimics: face away, call in voices he knows, walk to any voice)
Danny comes in by the fly gallery door and props the floor's stair door from inside; the cameras here are dead and
the radio would draw them, so he switches Kayla off and she limps up that stair to join him (story). From here to the
patch she is beside him.

**4.1 Proof Sheets (4 min).** The yearbook adviser's cabinet holds the club camera with flash (canon 6) and the
picture-day kit's hand mirror (canon 10). Her contact sheets on the wall include one candid frame of her dropping the
cabinet key into the hollow base of a journalism award (or a mug, or a plant pot: three versions). *L:* the frame is
circled. *S:* one in 36. *H:* the floor's riddle object: **the adviser's caption card** pinned over the sheets, a verse
about a prize that keeps nothing and a shelf that faces the weather; the matching frame is cropped to the shelf's
books and a window, so the book order is matched to the real shelf. *Loud:* the pry bar (canon 7): the floor's Mimics
come to look. Next door, the darkroom is the floor's lantern room. *Seen in:* ours.

**4.2 Reading Room (6 min).** Four figures stand facing away among the stacks; one is a real student hiding (a quiet
choice: Danny can leave her). The tells are the creatures' (canon 9): a thrown book (she flinches; a Mimic does not);
the hand mirror round a stack end, which shows a front without turning it; her breath, because the broken clerestory
has let the November cold in and under the torch a person's breath fogs; and last, because asking aloud draws them,
the question "What time?": a Mimic asks it back in the voice it wears, and she is too scared to answer. The Mimics
move only while out of the torch and end facing away in his route, so the figures stand somewhere new each time he
looks away. *L:* two figures, and she answers him (any frightened human reply, with breath); a Mimic only asks the question back. *S:* four, and she does not answer. *H:* four, she does not
answer, and two stand together where one thrown book cannot tell their flinches apart; the mirror or the breath
decides. *Moves:* which figure, which stacks. *No loud way:* a wrong guess inside a Mimic's reach is a maul (canon 9);
the restart point at the library door covers it (canon 11). *Seen in:* ours.

**4.3 The Language Lab (4 min).** A Mimic stands between the lab and the server-room corridor. The lab's console plays
any booth's recording through that booth's speaker, and a Mimic walks to any voice it hears (canon 9). *Pieces:* the
console (the lab circuit on: the F3 riser cannot carry the lab and the server room at once, canon 6), the booth map,
the recording lengths on the console screen (the corridor-to-far-booth walk is 25 s). *Steps:* play a recording over
40 s from the far booth; the Mimic walks in; pull the lab door shut from the hall (a closed classroom door locks
itself in lockdown); it thumps on the door now and then for the rest of the game. *L:* one long recording, its booth
marked. *S:* read the lengths. *H:* the longest is in a booth by the door, where the Mimic would pass within reach of
him, so the second longest is the answer. *Moves:* lengths and booths. *Seen in:* Alien: Isolation (sending a creature
to a sound and shutting the door behind it).

**4.4 ROLL CALL (large, 18 min).** *Situation:* the rescue needs the roof antenna: the shelter's shortwave hears on
its indoor wire but can be heard back only through the roof antenna, whose cable runs up the riser and through the
server room's patch panel (the story's antenna part). The server-room door's badge reader (on its own lead-acid
backup) takes the IT technician's badge, and she (Helen Marsh, a working name: story) is alive, hiding somewhere on
this floor among the Mimics, who from behind look like people. On the way in, in the humanities hall, Kayla meets her
own double (**Two Kaylas**, the creatures' set piece: a figure in her yellow rain jacket asks "What time?" back in her
voice while the real Kayla stands behind him). *Pieces:* (a) the library's sign-in sheet at the circulation desk: the
game-night late room for students waiting for rides, name, time in, time out, and the staff on duty at its foot
("H. Marsh, IT, until 9"); it is not Kessler's sheet (canon 10); (b) the darkroom's contact prints: the yearbook
club's roll shot in the halls that night for the "who stays late" page, its last frames taken at 8:03 as the lockdown
sounded, each showing someone going through a numbered door (only the frame numbers on the film's edge give the
order); (c) the Patrol's sprayed tallies on the F3 doors, read with Numbers II (section 4), each the count taken from
that room; (d) the figures standing facing away in the rooms, and the tells of 4.2. *Steps:* from the sheet, who never
signed out; from the prints, which door each of them went through at the lockdown; take each door's tally from the
people the prints sent through it: the rooms where someone must still be, and how many; go there; among the figures,
find the living with the tells (a thrown object, the mirror, the breath; the question only if he must); the IT
technician is among them, too frightened to answer, her badge on its lanyard. What becomes of her and of anyone else
found alive is the story's. *Creature:* the Mimics walk to voices, so Kayla whispers; they move only while out of the
torch and end facing away in his route, so a room he has checked must be kept in the beam as he leaves it. *L:* the
sheet has pencil ticks by the names still in; the prints are captioned with room numbers; one room. *S:* as above.
*H:* the prints are out of order; two rooms come out to the same remainder, and only the sheet's times part them; one
door carries a second squad's tally in another colour over the first. *Moves:* the names, the doors, the tallies,
which figure is real (three authored sets). *Loud:* none through the reasoning; the server-room door's loud way is in
4.5. *Hints (Kayla, in person):* "the library kept a list of who stayed"; "my club shot the late room that night"; H3
written: the rooms and their counts on the map in blue. *Seen in:* ours.

**4.5 The Antenna (3 min, two links).** *Pieces:* the badge from Roll Call; the server circuit on the F3 riser (the
lab off: canon 6); in the IT office, the laminated 2023 patch diagram and the ticket printouts of later changes; the
panel: 48 ports, cables coloured by system (cameras blue, radio white, intercom yellow). *Steps:* badge; power; patch
**the antenna line and F4's one camera** (canon 14); each right link lights its port, and Kayla, reading beside him,
says so in a whisper. *Creature:* one door, a dead end; Mimics in the corridor walk to any voice, so nothing is said
aloud. *L:* the diagram is current. *S:* diagram plus one ticket. *H:* one ticket is undone by a later one, and the
colours are faded under the room's blue night light (torch needed). *Moves:* ports per link (three sets). *Loud:* the
pry bar on the door strike (canon 7); no loud way through the patch. *Seen in:* Alien: Isolation (bringing a system
back at its panel). The secret CRT in the IT storeroom wakes on this circuit (secret 7).

### Chapter 5: "Five Seats" (fourth floor and roof, Swarm: warmth and movement; cold and stillness hide you)
Danny goes up first to clear the route, by the fire escape into the chemistry window (story); the group will come up
the stair to F4 (5.5), then through the science corridor and the mechanical room to the roof.

**5.1 The Balance (5 min).** Ms. Kessler's own prep room (she teaches chemistry): her joke lock for students, "Prove
you can measure". A two-pan balance trips the cabinet latch at the mass on her board. Jars of salt, sand and gravel
are labelled with their masses (game logic only). The balance needs 3 s of stillness to settle, which is what the
Swarm rule rewards. Inside: the dry-ice cooler and the CO2 extinguisher (canon 10). *L:* the board lists the jars.
*S:* target plus labels. *H:* the floor's riddle object: **Ms. Kessler's board verse**, her riddle for students, "half
a kilo less the beaker", the beaker's mass on its sticker. *Moves:* the target. *Loud:* the pry bar (canon 7; the
Swarm hears it as well as the hunter). Kessler can give H2 herself in the shelter, if asked. *Seen in:* ours.

**5.2 HEAT MAP (large, 20 min).** *Situation:* the floor's heating is stuck on full (the controller lost its settings
in the pulse and fell back to warm-up, every valve open), so the Swarm fills the corridor ceiling, and the group will
come this way to the roof. *Pieces:* (a) the facilities binder in custodial closet 4: the zone map, H1 to H6 by room;
(b) the valve manifold in the mechanical room at the far end, six tagged valves and a bypass; (c) the greenhouse
room's heat mats and grow lights (the F4 riser: canon 6) as the decoy; (d) windows that crank open (cold in 40 s,
frost on the glass), and duct tape. *Steps:* reach the mechanical room window to window with the dry ice ("the cold
line"); close the corridor and classroom zones, leave the greenhouse zone open and its mats on; the Swarm pours in;
shut the door and tape its return vent; the corridor cools in about a minute (the thermal camera shows it emptying).
*Twist:* one valve is seized; the pry bar as a lever (canon 7) is heard by the hunter. *L:* tags name rooms. *S:* tags
give zones, the map gives rooms. *H:* the map is 1962's; the 1998 wing was renumbered in pencil; valve H7 is
abandoned and does nothing. *Moves:* tag sets, which valve seizes. *Loud:* the pry bar through the corridor windows,
pane by pane (canon 7): cold floods in, the hunter comes, and the group later walks on broken glass. A warm corridor
makes Owen's freeze on the stair (story) harder. *Hints:* "it's an oven up there; why is the heat on?"; Gus: "heat is
valves in the plant room, one a zone"; H3 written: the greenhouse zone circled. *Seen in:* Dead Space remake (changing
how a space runs from its machinery) and Alien: Isolation (luring a creature with the thing it follows).

**5.3 Thermal (4 min).** The physics room's thermal camera is flat; the demo kit's crank generator charges it (canon
6), and cranking is movement. Done in a cold room or inside the dry-ice patch, usually before Heat Map's last step.
*H:* the cold room's window crank is missing (Gus's ring). *Seen in:* Outlast 2 (a camera kept alive by what you feed
it).

**5.4 The Landing Square (6 min, roof).** The pilot, on the shortwave through the antenna of 4.5, asks for a clear
square at least 20 paces a side, a light at each corner, and the signal fire (story). *Pieces:* the roof plan on the
mechanical-room wall; four service floodlights on their own sealed can in the penthouse (canon 6: the reserve only
adds time); flares and light sticks; a steel drum and pallets. *Steps:* cut the door chain (bolt cutters: canon 7);
pace the roof against the plan (skylights do not hold weight); set the lights; lay the drum ready to light when the
helicopter calls. *L:* the square is drawn on the plan. *S:* find it. *H:* the only square crosses a skylight's edge,
so one floodlight must be turned to mark the corner short. *Seen in:* ours.

**5.5 The Stair Door (8 min, the chapter run backwards).** *Situation:* the breach (story; the only one in the game):
"It's in. It's inside, Danny." The hunter followed the Mark, cut the generator, and the group flees up the stair in
the dark with Gus. F4's stair doors stay shut without power (1.2). Danny must cross the Swarm's floor back to closet
4, put the riser on the penthouse can's feed (canon 6), and turn the release with the riser key before the group
reaches the F4 landing. *Pieces:* closet 4's directory card (the release line, the feed's switch); the riser key;
Kayla's calls on the radio, landing by landing, which are the clock; the corridor as Heat Map left it. *Steps:* down
from the roof by the penthouse stair; across the corridor, cold and still where the Swarm still hangs; the closet:
feed, then release; the door opens; the group comes through toward the roof. On the stair below, Owen freezes under
the Swarm (story: a choice; the cold tools of canon 10 clear him). *Creature:* the Swarm, and the hunter climbing the
stair behind the group, heard through the walls. If the group reaches the door first, they wait there in the dark and
the hunter's steps climb behind them; it is never a dead end, and only if it reaches them does Danny restart at this
step (canon 11). *L:* the card marks the release, and Kayla's first call comes a landing earlier. *S:* as above.
*H:* the card names the stairs by their 1962 letters, and only the roof plan in the mechanical room says which is
the group's. *Seen in:* ours (a floor already cleared, crossed again backwards against a clock).
Then the hunter's one long chase across the roof (1.3; its timing: canon 8) and the boarding (story; the scenes:
cutscenes.md).

### Chapter 7: "The Climb"
**7.1 Danger Lanes (3 min over the flight).** At the three forks of the pack segment (the flight's segments: canon
13) the cockpit shows two lanes, each with an arrow glyph and a count of danger marks; he steers by reading them
(confirms **Flight**, section 4). *L:* the safer arrow glows. *S:* glyphs only. *H:* one fork where both lanes are
dangerous and one carries "not" (inferred in place). *Seen in:* ours.

### Epilogue: "June"
**9.1 The last key (2 min, optional).** Kayla uses the one key on Gus's ring that never opened anything (secret 14):
it opens the shelter's 1962 supply locker, where the group left what they could not carry. Whether she has the ring
from Gus's hand or from its hook "for Kayla" is the story's. *Seen in:* ours.

---

## 3. The power story: one system the player comes to understand

The school's power is four layers, met in this order, each taught once and then tested. Every number in it (ticks,
units, burn, the limits, the loads) is canon 6; this section says what the player meets where.

1. **The generator** (boiler room): fuel is time, load is burn rate. In Chapter 1 it is a clock; afterwards it is the
   shelter's reserve, spent by each chapter away and by any power Danny uses upstairs, which is warmth taken from the
   survivors. Nothing on the path ever fails for lack of fuel; the reserve only adds time on the roof (canon 6).
2. **The main switchboard** (switch room): one big breaker per load. Over the limit it trips with a bang and 5 s of
   dark (taught once). At the top of its load the voltage sags and fluorescent tubes flicker: harmless in the
   basement, deadly on the Still Ones' floor (3.2). Gus can work basement breakers when Danny radios; nobody can work
   the floors' closets but Danny.
3. **The electrical closets**, stacked in the core on every floor (the riser key): a main breaker, 8 to 12 circuits, a
   directory card on the inside of the door written in a different hand on each floor, a needle, and each closet's
   own limit (canon 6), so a floor's systems compete with each other (4.3 and 4.5). Only F1's closet carries a
   chapter's way through (the PA, 2.3) and only F4's opens doors (the stair release, 5.5); F2's and F3's feed the
   circuits their puzzles need (1.2).
4. **Things on their own batteries** (canon 6): the exit signs (lit through Chapter 2, dying in Chapter 3, dead from
   Chapter 4: the player notices), the server-room badge reader, the bell timer, the traffic cabinets in the city,
   the fire panel that held the lockdown at 8:03 and has since gone flat, and the roof floodlights' own sealed can in
   the penthouse, which in Chapter 5 also feeds closet 4 after the breach (5.5).

**Loads** are canon 6's table: the basement's circuits, F1's PA and bells, F2's corridor and theatre dimmers, F3's
server room **or** language lab (not both: the closet's limit), F4's greenhouse mats, and the roof floodlights on
their own can.

**What power means on each floor** (the reason the system stays interesting): in the basement it is **light** (the
Dwellers); on F1 it is **sound you control** (the PA), since light does nothing to the blind; on F2 it is **watching**
(lights hold the Still Ones, a sag frees them); on F3 it is **information** (the antenna, the camera, recordings); on
F4 it is **heat**, which the Swarm follows, so turning power on can call them, and then, after the breach, **a door**
that only power opens; on the roof it is **being seen** by the helicopter, and by everything else. On the mothership
the alien board twists it once more (section 6).

**The lesson curve:** Chapter 1 teaches the budget and its cost in comfort; Chapter 2 teaches a closet as a map of a
floor's systems; Chapter 3 tests the budget under a creature; Chapter 4 adds the closet's own limit; Chapter 5 turns
power into a lure and then into a race; the self-destruct asks for the whole idea backwards.

---

## 4. The alien symbol language (this document's, canon 12)

**How it looks and sounds.** Every glyph is three claw strokes, so it can be scratched, sprayed by the Patrol or lit
on a panel, and **every glyph has a tone** (the Voice Collectors, canon 2): the Patrol's calls are tones from scanners
and armour, so learning the symbols lets the player follow them, and on the ship the language is spoken in tones.
**Numbers** are a long curved stroke with short cross-ticks: 1 to 4 ticks; 5 is the stroke hooked shut; 6 to 9 are the
hook with 1 to 4 ticks; 0 is a lone short bar. They are **base ten, written left to right**, so a count can always be
checked against something in the room: the soldiers spray the count of the taken on every room they cleared. The
hunter scratches counts only on its own Nest wall (8.3).

**The notebook.** Every glyph Danny sees is drawn into it in his hand. Meanings come from a word list that grows only
when the context has been seen. A page is confirmed with a stamp and a sound only when every glyph on it is right, so
guessing gets nothing (the pattern of Chants of Sennaar and Return of the Obra Dinn, outside his five games). Light
shows overlays on panels and gives one glyph after two wrong tries; Hard shows no overlay on any panel. The Patrol
scanner reads glyph locks (canon 13), with fewer guesses the more he knows. Pages 1 to 7 are guaranteed on the
critical path; page 8 is optional. *Seen in:* ours.

| Page | Glyphs | Met | Confirmed by |
|---|---|---|---|
| 1 Numbers I | 1 to 5 | the Patrol's sprayed tallies on basement doors (Ch1) | counting the coats and chairs in three rooms on Flare Road's path (1.3) |
| 2 Numbers II | 0, 6 to 9 | the Patrol's tallies on F1 to F3 doors: the band room, a classroom, the theatre's "1 0", the library | five rooms matched, by Ch4; Roll Call reads them (4.4) |
| 3 People | person, taken, ship, alive | "taken" beside every tally since Ch1; the small ship's hull (Ch2, story); cradle tags on the Patrol's carriers in the camera footage | at the Ch4 return, when the footage can be replayed |
| 4 Doors | open, close, go, stop, danger | Patrol barricades and door marks in the city (Ch6) | the sweep marks (6.2) and the hatch (6.4) |
| 5 Energy | empty, full, energy | the gun's cells and the pylons (Ch6, from the midpoint) | lifting the gun after a shot and after a recharge |
| 6 Flight | left, right, up, down, home | the cockpit (Ch7) | the danger lanes (7.1) |
| 7 Grammar | not, all, end, hold, and the order: the thing first, then what is done, "not" last | the Underdeck doors (8.1) | the doors and the Spine's lock B |
| 8 Lore | name, remember, child, sleep, first | the knocked-out soldier's diary, the Nest | optional (secrets 12 and 15) |

Thirty-six glyphs in all. **Puzzles that rely on it:** Flare Road's counting (1.3), Roll Call (4.4), 6.2, 6.4, 7.1,
8.1 to 8.4 and every stage of the self-destruct.

---

## 5. The city (Chapter 6, about 85 minutes)

**The route** (this document's, canon 4), about four blocks and 900 m on foot, one way through with side places, at
night:
1. **The Tannery Building roof** (six storeys): the landing; a Patrol searchlight finds him in seconds (the owner's
   "instantly spotted"); a scripted chase of about 3 minutes over the roofs and down a fire escape to the first hide.
2. **Tannery Street:** the evacuation jam (cars with open doors, a city bus, shopping bags, a stroller). Teach: from a
   bus roof, a squad searching a shop and taking someone in front of him (a collar of light, a person lifted away,
   still calling out; never graphic: canon 9). Some of the older cars here still have working alarms (canon 6).
3. **Market Square:** the dead junction and its signal cabinet (6.1); side places **Sal's Pizza** (story) and the
   **laundromat** with the boy hiding (story; 6.2); lantern 1 in the laundromat's back room.
4. **Orchard Street** (side): Danny's building and his mother's note (story).
5. **The leash:** the street on to Courthouse Plaza, crossed past a stray Listener on a leash and its handlers (the
   creatures' set piece; the stray keeps its own rule).
6. **Courthouse Plaza, the midpoint:** the helicopter wreck, Kayla's film camera and her walkie (the scene:
   cutscenes.md), a recharge pylon, and **Takedown** (6.3). From here the city is hunted, with the gun's few shots
   (canon 13).
7. **Civic Center Plaza:** the Patrol's landing pad and the ship he steals (6.4); lantern 2 in the parking kiosk.
The hunter keeps pace along the rooftops above the whole route (canon 8). The radio is dead, and pressing to talk to
it is the story's mechanic: his voice carries the chapter and nobody answers.

**6.1 Flashing Red (8 min).** Two lamp drones hold the junction. The signal cabinet (its key on the dash of a city
works van) has a mode panel; flash mode runs on the cabinet's own battery and every head blinks red. Drones go to a
moving light: 20 s to cross. *L:* the switch is labelled. *S:* the switches are numbered only; each one tried changes
the heads where the drones can see it, so the heads are read from cover between tries. *H:* the label is wrong (a
works crew's tape over the old one), and only the heads tell the truth. *Loud:* an old car's alarm set off by a thrown
brick, which brings soldiers as well. *Seen in:* ours.

**6.2 Sweep Marks (10 min).** The Patrol sprays a count on every building it clears: the order of its sweep. Reading
the counts around the square shows which door is next: the laundromat. Danny can get the boy out by the back alley
first, or set off an old car's alarm across the square to send them to the wrong building, or leave him (a quiet
choice). *L:* counts of 1 to 5 only. *S:* full numerals. *H:* two squads' sweeps in two colours, interleaved. *Seen
in:* ours.

**6.3 TAKEDOWN (large, 20 min, at the midpoint).** *Situation:* in Courthouse Plaza one soldier guards a small carrier
loading the crash's cradles (the map's "one soldier guards the small ship"; canon 4); the squad's sprayed sweep counts,
read as in 6.2, tell how long the others are away. When the carrier is loaded it leaves; the ship Danny steals waits
at the pad. *Pieces:* the plaza's substation kiosk (the works van key): its isolator lever makes the line by the
carrier hum and blinds the guard's scanner (its length: canon 9; game logic only); a route of metal cover (cars, a
news van, steel planters) that hides heat; an old pickup whose lead-acid alarm still works, set off by a thrown brick;
the struggle from behind in first person, under the player's hands (story). *Steps:* wait out the sweep; blind the
scanner; brick the pickup to turn the guard; close along the metal; the struggle; take the gun, the scanner and its
**key shard** (canon 10 and 13). *L:* one guard, a long sweep. *S:* as above. *H:* a second soldier on the carrier's
ramp to be drawn away first. *Loud:* the pickup's alarm right beside the carrier: the squad comes back running, a
frantic version that still works. *Seen in:* Alien: Isolation (a noise to turn a guard, and cover read against sight
and scanners).

**6.4 The Hatch (8 min).** At the landing pad in Civic Center Plaza the key shard opens the hatch (canon 10). The panel
inside reads, in pages 4 and 5, the story's news: the ship goes up, and the mothership leaves full at Tuesday dawn
(canon 2). Starting it is three keys in the order the panel's prompt is written (door close, energy, go), the thing
first and the act last. *L:* overlay. *S:* known glyphs. *H:* "up" must be inferred in place. *Seen in:* ours.

---

## 6. The mothership (Chapter 8, about 120 minutes)

**Decks as a hub** (this document's, canon 4). All decks open off **the Well**, a vertical shaft about 80 m tall with
a slow lift disc and a glyph sign at every deck mouth; the player returns to it between decks, as he returned to the
stair landings. One kind per space (canon 9; the creatures' table of ship roles), all in one alien kit with four deck
looks (production):
- **Hangar** (arrival, the crash; Patrol crew).
- **Underdeck** (unlit service spaces; Dark Dwellers as cleaners). Lantern 1.
- **Garden deck** (Still Ones rooted in the walls, moving only along their roots).
- **The Holds**, three long halls of the taken (Listeners as wardens, Mimics as voice-keepers, the Brute as loader)
  and the trophy hall. Lantern 2 in their antechamber.
- **The Nest**, the hunter's own room off the Holds (Marcus and Mari, too far gone; Kayla, the newest: canon 2).
- **The Spine**, the low-gravity axis (the Swarm as a warm drifting cloud). Lantern 3 at its root; **the pod bay** at
  its end, reached from the Holds by a walkway.
- **The Core**, at the foot of the Well.
**Low gravity** (canon 13: about 15 minutes in all) is met on the way in, with the Swarm cloud, and again in the
self-destruct's three Spine locks: push off, drift, grab, and the gun as a thruster; down changes once, not more. The
Brute is heavy and slow to push off; the Swarm cloud drifts toward Danny's warmth. On Story and Survivor every self-destruct stage has
a checkpoint; Stay Behind has only the player's own saves (canon 11).

**The first hour:** the Hangar, 8.1, 8.2, the Holds seen from their galleries, the Spine on the way in, and the Nest,
where Danny puts the drumstick in Marcus's hand and finds Kayla, the newest (story). **The last hour, in order:**
Kayla and the talk (8.3: her waking is the scene "What Time?", where she tests him and he tells her "If I get in one, they follow it"), the Holds (8.4), then the self-destruct.

**8.1 Grammar Doors (8 min, Underdeck to the Well).** Four doors labelled with short glyph sentences ("door open",
"door open not", "all go"). Trying them teaches the order rule and "not". *H:* one door's sign is half burnt. *Seen
in:* ours.

**8.2 The Garden Roots (8 min).** The rooted Still Ones move only along their roots, which run in plain sight across
the deck's floor and walls. The deck's lamps dim on a cycle whose count runs down in alien numerals beside each lamp.
Danny reads which floor plates no root reaches and crosses from one rootless island to the next before the count hits
zero and the lamps go out. *L:* rootless plates are paler. *S:* read the roots. *H:* some roots run under floor
grilles and show only in the torch beam. *Seen in:* ours.

**8.3 Kayla (6 min, the Nest).** Her cradle is the hunter's kind, sealed with a number dial. The Nest's wall is
covered with the hunter's own counts, one for each catch, the last one freshly scratched: the seal opens to that last
number, because she is its newest. Reading the wall also shows how many it kept (Marcus and Mari among them). If the
hunter took Ray, Owen or Gus, he is here too, less than two days, and his seal opens to his own count on the same
wall (canon 2; each is a short waking step of the story's). Before working her seal, Danny sets her walkie and film camera on her cradle's rim (both hands are needed on the dial); she takes them herself once awake (canon 10). The hunter is away; its whisper places it truly (canon
8). *H:* the counts are written over each other and the newest is the one with no dust in its strokes. Her waking is
the scene "What Time?" (cutscenes.md). *Seen in:* ours.

**8.4 THE HOLDS (large, 25 min).** Rows of soft cradles under frosted lids. Nothing graphic: a shape, a hand flat
against the inside, murmuring, breath on a lid. Each cradle tag reads person, alive, a day count, and whose mark (the
Patrol's; the hunter's catches are not here). At each cradle's foot sits a tray of the person's things, which is how
Danny finds the people he knows (Ray's son Caleb by his team warm-up shirt, Owen's sister by her lanyard). The newest,
whoever boarded the helicopter, wake in under a minute; the first-night ones, Caleb and Owen's sister among them, need
a symbol sequence and time (canon 2). *Pieces:* the hall's power board (every cradle opened costs power somewhere
else: a hall's lights or a door); the wardens (a waking person gasps: canon 7); the Brute's loading round, heard from
the next hall. *Steps:* read the tags; plan an order that wakes the far rows first and darkens the hall being left;
let the woken walk to the pod bay on their own (never an escort). The ones who trust him help, as the ledger allows
(story: Priya reads panels, Ray finds Caleb, Owen keeps watch). *L:* tags overlaid, one warden. *S:* as above. *H:*
the board's limit is written in glyphs, two wardens. Who is there is the ledger's (story). *Seen in:* Dead Space
remake (scarce power spent where you choose).

**THE SELF-DESTRUCT** (about 40 minutes in stages, this document's, canon 13; every stage reuses something taught):
1. **Three locks across the Spine** (with the Brute in pursuit). *Lock A, the board:* three alien conduits, two can
   stay; the twist is that the alien board is drawn, not pushed (joining a conduit cuts its power). Cut the gravity
   (the Spine stays weightless: easier for Danny, harder for the Brute) or the lights (the Underdeck's Dwellers spread
   up the Well). The pod bay's conduit must stay. Chapter 1's "two of three", backwards. *Lock B, the order:* three
   clamp handles, pulled in the order a glyph sentence on the panel gives (the thing, the act, "not"). *Lock C, the
   drift:* a lock across open space, closed by pushing a drifted pod into its clamp. *Seen in:* Dead Space remake
   (work done in zero gravity, and power routed between systems).
2. **Route the pods:** the pod-bay board shows each pod's seats in glyphs; the woken board on their own legs. *Seen in:* ours.
3. **The final exam, at the core:** read the core's panel and compose **"ship all end"**. Each right glyph sounds its
   tone, and the phrase resolves into the Danny-and-Kayla melody. The countdown runs in alien numerals; wrong glyphs
   cost countdown time, never the game (if it reaches zero, Danny is back at the exam's checkpoint; on Stay Behind, at his own last save: canon 11). The panel answers
   with one more glyph the player now knows: **hold**. The ship starts to die. Light adds an overlay and time. *Seen in:* ours (the
   language's own final exam).
4. **The run to the pod bay** as the ship comes apart (lights failing, a deck tilting, catching Kayla's hand as it
   goes). Only Kayla runs this last stretch with him, a scripted set piece; the woken are already on their way.
5. **Kayla's pod** (the scene: cutscenes.md, "Right Behind You"). She already has her walkie and film camera (8.3;
   canon 10). In play, before the scene, Danny puts the camcorder with his tapes into her pod (story).
6. **The hold**, a fight in the bay (story): one hand holds the pod release, and the pods launch one at a time, a face
   at each window. The hunter comes with every habit it has learned (canon 8) and whispers his own Chapter 1 promise
   back; his other hand spends what is left in his pockets, the last flare, the last cell, the extinguisher, keeping
   its hand off him. Letting go is never punished: the pods wait, his hand slips, and Kayla says "Danny?". No music.
   The last words and the white are the story's.

---

## 7. The pacing table (minutes, recommended settings; this document's, canon 3)

Puzzle minutes are the minutes given in section 2, and they **include the stealth inside each puzzle's space**
(the map: almost every puzzle is played with the floor's creature near). The stealth column holds only what is played
under threat outside a puzzle: the prologue's sneak, Chapter 1's door and pipes, the hunter's walk on F1, the way home
on F2, the roof chase, Chapter 6's opening chase and streets, the flight. The shelter column is the canon split of
about 65 minutes; lantern rooms count as explore. Each chapter's total is the map's and canon 3's.

| Chapter | Story | Explore | Puzzle | Stealth and chase | Shelter | Total |
|---|---|---|---|---|---|---|
| Prologue | 11 | 5 | 1 | 5 | 0 | 22 |
| 1 The Shelter | 10 | 8 | 34 | 3 | 20 | 75 |
| 2 Halftime Draw | 6 | 5 | 32 | 2 | 15 | 60 |
| 3 Still Life | 6 | 4 | 31 | 4 | 15 | 60 |
| 4 Who's There | 6 | 4 | 35 | 0 | 15 | 60 |
| 5 Five Seats | 14 | 4 | 43 | 4 | 0 | 65 |
| 6 The City Alone | 10 | 20 | 46 | 9 | 0 | 85 |
| 7 The Climb | 4 | 0 | 3 | 11 | 0 | 18 |
| 8 Stay Behind | 16 | 14 | 87 | 3 | 0 | 120 |
| Epilogue | 10 | 4 | 1 | 0 | 0 | 15 |
| **Total** | **93** | **68** | **313** | **41** | **65** | **580 (about 9 h 40)** |

On Light puzzles the reasoning inside the puzzle minutes drops by about a third, about 55 minutes in all (about 8 h 45);
a first-time player on Standard who uses the hints stays inside nine to ten hours. Every chapter has one big puzzle and
three or four small ones (the map). Chapter 4 has no stealth outside its puzzles because the Mimics stand in every one
of its spaces. Chapter names are the story's. **The school's puzzle minutes were trimmed to fit the map's chapter
lengths** (Flare Road 28 to 20, Roll Call 22 to 18, Curtain 22 to 18, and the small ones by one or two minutes each);
every step of every puzzle is kept, and the grey game measures them again.

---

## 8. Easter eggs and secrets (the fifteen best)

The map's six (the heron, the first game, Danny's locker, the frozen score, Kaylium, Walter Hale) are among them.
Each names where its pattern was seen; the heron alone puts one in every chapter. Extra secrets are on the cut list
(canon 15).

**Line 100 of the owner's checklist** (Easter eggs that reference his games, each listed with the game it draws on)
is answered by the secrets drawn from his list: the heron (Dead Space remake) in every chapter, Danny's locker and the
darkroom (Silent Hill 2 remake), the overdue book (Amnesia: The Bunker), the answering machine (Alien: Isolation), the
soldier's diary (Dead Space remake) and the New Game Plus endings (Silent Hill 2 remake). The secrets marked "ours"
are extras, and they are cut first.

1. **The gold heron.** The ceramics class made heron centrepieces for the booster dinner; one, painted gold "for luck",
   is hidden once per chapter (in the city on Sal's counter; on the mothership in a specimen case). All nine: it
   hangs from Kayla's bag in the epilogue (canon 10). *Found:* by looking. *Seen in:* Dead Space remake (one small
   golden figure hidden to be found).
2. **Danny's locker** (F3): a drawing and a note to Kayla he wrote in class and never gave her. Reading it changes one
   line of hers in the epilogue. *Seen in:* Silent Hill 2 remake (a found thing that changes what is said at the end).
3. **Kayla's childhood code:** in her hoodie pocket on the bleachers, a page of symbols she made up at eight. A few
   match the aliens'. Never explained. *Seen in:* ours.
4. **The 1998 darkroom:** the 1998 and 2026 evacuation plans of F3 disagree by one room; a hollow wall behind the
   yearbook room holds the old photo club's films, developed in the darkroom: the school in old seasons, a young Gus.
   *Seen in:* Silent Hill 2 remake (a place's past found in its own rooms).
5. **The overdue book:** a library book due back in 1996, holding a letter from a student who "saw lights over the
   river". *Found:* the card catalogue's overdue drawer. *Seen in:* Amnesia: The Bunker (notes that tell more than the
   task needs).
6. **Kaylium:** an extra element pencilled onto the chemistry room's periodic table, a joke of theirs. *Seen in:* ours.
7. **The first game:** in the IT storeroom (F3), an old CRT computer, woken by the server circuit (4.5), shows the
   earlier game's title screen. *Seen in:* ours.
8. **The frozen score:** HOME 31 GUEST 34 at HALF on the scoreboard; on the mothership the same numbers on a trophy
   tag, in glyphs. *Seen in:* ours.
9. **The answering machine** in the main office, on the PA line: once F1's PA circuit is on, it plays the last minutes
   of the PA, the announcer's real halftime words whole, the same ones the hunter whispers in pieces. *Seen in:*
   Alien: Isolation (recordings that tell what happened in a place).
10. **Sal's order spike:** "Danny, Kayla, Marcus, Fri 4:00, paid". The fridge holds one cold slice that heals as a
    bandage does (canon 5). *Seen in:* ours.
11. **The cat** of Market Square follows Danny if fed and is in the epilogue if it lived. *Seen in:* ours.
12. **The soldier's diary** (Hard, page 8): the soldier Danny knocked out had a child. *Seen in:* Dead Space remake
    (logs that make an enemy a person).
13. **Walter Hale's mop bucket** (the old night watchman, story): his name stencilled on a 1962 bucket in the
    shelter's store; Gus tells his story if asked about it, and about his watch card (1.2). *Seen in:* ours.
14. **The key that opens nothing** on Gus's ring, used by Kayla in the epilogue (9.1). *Seen in:* ours.
15. **New Game Plus endings:** *the count*, the Nest wall's total entered at the core before "ship all end", and the
    hunter hesitates in the last scene; *the drive-thru*, the course panel set to "home" in Chapter 7, and Danny flies
    the alien ship to a burger drive-thru (a joke ending, only on New Game Plus, and first on the cut list). Neither
    touches the true ending. *Seen in:* Silent Hill 2 remake (extra endings on a replay, a joke ending among them).

---

## 9. The stuff on the floor

**The three beats in every room** (the "What happened here?" pattern): **normal life** (a Friday school day and the
game night), **the interruption** (7:56: lights out, phones hot and dead, everyone at the windows), **the flight**
(8:03 lockdown: doors shut, tables dragged, people hiding, then gone). The fourth layer is the creature's trace, and
once a chapter the creatures' authored gore tableau (never a student). The taken are shown only by absence: chairs all
pushed back one way, a coat still on a chair, shoes with the laces tied, drag marks in dust, the Patrol's sprayed
tallies. Never blood from the students.

**Room by room (base, then the evening, then the flight):**
- *Classroom:* desks, a grading stack, a mug, tomorrow's homework on the board / coats on chair backs, a ticket stub /
  desks shoved against the door, a window blind torn down, a chair on its side, the door's lockdown card in the glass.
- *Corridor:* lockers, posters for the game, the trophy case / a sports bag, popcorn, a dropped foam finger / one shoe,
  a fire alarm pulled, a mop cart rolled across, a backpack spilled in a run.
- *Gym:* bleachers out, the frozen scoreboard, the announcer's desk / the cheer team's confetti, burst balloons, cups,
  coats, the pep band's music stands / a dropped tuba, coats in a heap at the exit, a broken rail.
- *Commons and kitchen:* raffle table, bake-sale trays, the booster dinner half laid / a cake with the team's names,
  steam trays gone cold / overturned chairs toward the dock, a burnt pan.
- *Main office and nurse:* the sign-in sheet, the PA mike, a box of lost gloves / the lockdown button's cover up, a
  lanyard on the floor / the cot unmade, an ice pack melted on a chair.
- *Theatre and art:* the winter set, sheeted easels, kiln logs / programmes on the seats / a costume rail pulled
  over, a hiding place under the stage with a blanket and a wrapper.
- *Library:* the overdue drawer, reading lamps / homework from kids waiting for rides, the late-room sign-in sheet / a
  fort of chairs in the stacks.
- *Science:* safety posters (the only "chemistry" anyone reads), plants, a demo kit / a coat on a lab stool / a
  cupboard door open, a window cranked wide.
- *Stairwells:* scuffed treads, a painted floor number / a programme on every landing / a handrail wrapped in a scarf
  where someone tied a door; later, Danny's wedges in the doors he propped.
- *Tunnels:* pipes, valve tags, junction plates, old graffiti from 1970s seniors / Gus's mop and his radio / glow
  sticks someone dropped running.

**The shelter, chapter by chapter** (the story's table sets the talk and the activities; this is the dressing):
1. *First night:* dust sheets over 1962 cots, water drums as tables, the shortwave and Priya's tape logger, a battery
   lamp, coats as pillows, the first names on the wall from Kessler's sign-in sheet.
2. Gym mats, the medicine box, Kessler's ration list pinned up, Ray's card game paused on a drum, cords from the
   generator.
3. The heater on, or blankets and breath fog if it was turned off; Mari's empty cot and her guitar on its nail;
   locker photos taped up as a shrine; Marcus's drumstick on Danny's cot until he packs it; Priya's symbol board.
4. Camera monitors on Kayla's table, dark but for F4's one; her hand-drawn school map; the steel door braced from
   inside; a gap where Ray slept if he was left out.
5. Bags packed for the roof, the room stripped; what stays: the card game, the wall of names, the guitar on its nail.
   After the breach, the same room dark and the door open.
6. *Epilogue:* the same room in June dust, the stopped clock on the generator gauge, the names on the wall.

**Streets:** cars with doors open and their electrics dead, a jammed junction, police tape, shopping bags, a
stroller, "OPEN" signs dark, a looted pharmacy, a TV store window of black screens, Patrol counts sprayed on cleared
doors, debris lifted and dropped in neat patterns by the aliens, burn marks.

**Alien interiors:** worn handholds from long fingers, rest pods, a ration station, tools in racks, glyph signs
everywhere and always in the language's rules, the trophy hall of taken Earth things (a traffic cone, a vending
machine, a school trophy), cradle tags that can be read.

**Traces.** With phones dead (canon 6), the readable traces are paper and film: notes under 120 words, dated, one hook
each; Polaroids and printed photos; photos tucked inside clear phone cases (a real teen habit); the sign-in sheets;
whiteboards; the PA's last minutes on the office answering machine (secret 9); the CCTV's last minutes (people fleeing
as shadows; never a person hurt). A dropped bag always points the way its owner ran, a pattern players learn.

**What the debris does to noise** (canon 7 is the one table: paper, grit, cans, glass that glints in the beam so it can
always be seen and avoided, the balloon, and the quiet of carpet and coats). Placement rules: no needed item under
clutter; clutter hides only optional loot; each Listener-floor route has at least one quiet line the player can read
from the floor's look; glass and balloons cluster at doorways where people ran; every floor's debris is worse near the
stairs (the crush), better in rooms people never reached.

---

## Depends on the other documents

- **Story:** the IT technician's name (Helen Marsh is a working name) and what becomes of her and of the reading-room
  student; the wording of the five riddle verses and of Walter Hale's watch card; whose voices the Mimics wear; where
  Kayla's epilogue key ring comes from (9.1); the shelter's activities and talk on each return.
- **Creatures:** the Listeners' thresholds against Halftime Draw's chime rule (2.3); the Mimic tells used in 4.2 and
  Roll Call; the set pieces placed here (Kayla's eyes in 3.3, Two Kaylas on the way into Roll Call, the leash street
  in the city); the gore tableau of each chapter; the ship forms per deck.
- **Systems:** closet 4 taking the penthouse can's feed after the breach (5.5); a battery pair in reach of every
  puzzle that needs one (2.2, 3.1); restart points at every solved step
  with puzzle state kept; the circuits named here against canon 6's table.
- **Audio:** levels to add to canon 7 for the safe dial and handle, the bins, wading, the bleacher motor and the
  scoreboard horn; the PA chime; the heating-knock and rain-wave timing; every puzzle's confirming sound, none of it a
  click or a wooden knock (the owner's checklist, line 48).
- **Production:** the room-portal graph exported with each Layout JSON (1.2); the reshuffle seed and the three
  authored value sets per puzzle; the per-chapter asset census in the grey pass, which simplifies any puzzle whose
  props have no checked source; the glyph decals in the alien kit.
- **cutscenes.md:** every cutscene named here; it wins on all of them.

---

## Decided

- **The Voice Collectors:** every glyph has a tone, and the final exam's phrase resolves into the Danny-and-Kayla
  melody (sections 4 and 6).
- **Close by, progress kept:** restarts at every encounter entrance, large-puzzle stage and solved step, puzzle state
  kept; no puzzle has its own checkpoint (section 2, 4.2).
- **Hunter takes Kayla, voice twice:** a Mimic uses her voice once, in Two Kaylas on the way into Roll Call (4.4);
  nothing fakes her on the radio; the hints in her voice
  are always really her.
- **The Mark:** on the theatre stage after Curtain (3.4); it brings the no-calm way home (3.5), the breach and the
  stair door run (5.5).
- **Marcus taken at halftime:** his drumstick lies on the band-room floor (2.3) and goes into his hand in the Nest.
- **The basketball game:** the gym, the scoreboard, the cheer team's halftime leftovers and the announcer's words
  (2.3, 2.4, section 9, secret 9).
- **What gets finished first:** every puzzle works in the grey game with its three value sets; the grey pass's asset
  census may simplify a puzzle whose props have no source.
- **Maybe sold later:** every prop and texture the puzzles need comes from a source whose terms allow a sale.
- **Settled by the map he approved** (this draft's old questions): one big and three or four small puzzles a chapter;
  every floor entered its own way and its stair propped from inside; a loud way round every school lock but the
  closets and story items; the hunter's door counts and the gym door's number deleted; base-ten numbers; the final
  exam costs time, never the game; Calloway as the city's working name.

## Open, to be put to him later

- **The city's name:** Calloway stands until he gives his own (canon 4).
- **The New Game Plus endings and the extra secrets:** they stand, first on the cut list, and whether they stay is his
  call when cuts are made with the grey game in front of him (canon 15).
- **How hard the puzzles feel:** when he plays the grey game, the Light tier and the hint rungs are tuned from his
  play, never guessed ("I also don't want the game to be too hard").
