# Stay Behind: survival and systems design (draft 3 of 6)

The systems designer's draft for the game map. It builds on research reports 01 (survival systems), 02 (puzzles,
sections 1, 2 and 5) and 06 (audio: the noise table and the listening devices). It works inside the owner's settled
answers (requirements.md sections 7 and 8) and the lead's shared frame and proposals P1 to P9.

**How to read the marks.** Plain text is the design inside his answers. **[PROPOSAL]** marks a point his answers do
not settle; each big one is collected under "Decisions for the owner" at the end. **[Pn]** names a lead's working
proposal that this draft uses; it stays a proposal until he agrees. All numbers are starting values for the
"Survivor" preset, to be tuned from playtest logs. "Units" of power, "ticks" of fuel and dB of noise are internal
and never shown to the player.

**Three rules held everywhere.** Nothing in the school can be killed: every tool lights, hides, distracts or scares
off. Crafting is game logic only (named objects snap together; no real recipe for anything dangerous). Graphic
horror is for the aliens and Danny's own deaths; what happens to the taken is never shown.

---

## 1. The core loop of a school chapter (Chapters 2 to 5, about 55 minutes each)

One floor, one creature rule, one way up. Every school chapter has the same five beats, so the player learns the
rhythm and the floors change what the rhythm costs.

| Beat | Minutes | What the player does | What it costs or gives |
|---|---|---|---|
| 1. The room | 4 to 6 | Hears the floor's goal (the way up) and one survivor's request; watches Kayla's CCTV view of the floor; packs from the cabinet; sets the stopwatch; saves at the lamp | Choosing what to carry is the first decision: 8 slots, and what he leaves the room keeps |
| 2. The climb | 2 to 4 | Up the service stair to the floor's landing (the hub). The hunter can be on any stair | A short, known route that changes each time he uses it (a door wedged, a light out) |
| 3. The floor | 35 to 40 | Learns the creature's rule in a safe first room, then the floor's main puzzle (two or three clue rooms around the landing), side rooms with supplies, the survivor's item, the floor's evacuation plan (its map), its one small save point [P3], a kitchen or dumbwaiter hatch to send things down | Every room is a trade of light against noise against time. The loud way through any lock is always there and always brings the floor's creature |
| 4. The return | 3 to 5 | Once the way up is open, Danny goes back down with what he found. The return route is never the way he came: a laundry chute, the freight-lift shaft, the outside fire escape | The floor's creature and the hunter both know he has been there; the return is short and tense, never a slog |
| 5. What changed | 5 to 8 | Gives the request item (or doesn't), hears who is worse or better, the night talk at the generator, rests to heal, writes in the logbook | The hidden ledger moves (section 7). A payback arrives (an oiled door, a fixed camera, a parcel in the dumbwaiter). A new key on the ring reopens a closet on an earlier floor |

**What changes between visits.** While Danny is away, a quiet director changes the floors he has finished: lights
he left on are off, a Still One stands somewhere new, vent covers are open, survivor chalk arrows appear. Going back
to an earlier floor for a closet his new key opens is always optional and always worth one or two supplies.

**The rhythm inside a floor** follows the owner's presence numbers for the hunter: something happens (heard close,
glimpsed, a near miss) about every 15 to 20 seconds while Danny sprints, 30 while he walks, 60 while he crouches.
Sneaking is slower but buys quiet. Each floor's own creature sits on top of that with its own rule.

**Chapter 1 (the basement, about 70 minutes)** is the loop's long first lesson, in this order: the safe room forms
(guided, 10 min); start the generator and learn the gauge, the stopwatch and the circuits (15); the tunnels and the
bus garage for fuel and the janitor's store for tools (20); the first power failure, scripted, which brings the Dark
Dwellers (10); free play to bring back the survivors' first needs and open the way up (15). The generator is a live
clock only here (section 6).

---

## 2. Movement and the body

### 2.1 Moving

| Move | Speed (m/s) | Noise base on lino (dB at 1 m) | Notes |
|---|---|---|---|
| Walk | 1.5 | 45 | Default. Hunter event about every 30 s |
| Crouch | 0.9 | 35 | Toggle or hold (option). Hunter event about every 60 s. Fits under desks and through low gaps |
| Crawl | 0.5 | 30 | From crouch. Under stage, vents, collapsed ceilings. Torch must be in the mouth or off (see 2.4) |
| Sprint | 4.5 | 60 | About 6 s of breath, 8 s to recover. Hunter event every 15 to 20 s. After a sprint his breathing is loud for 6 s |
| Lean | n/a | 0 | Q / E, about 30 cm. Works standing and crouched, and from inside a locker by its slats |
| Peek under a door | n/a | 0 | Crouch at a door: the view drops to the gap. Light and feet on the other side are visible |
| Listen at a door or vent | n/a | 0 | Hold: the world ducks 10 dB, the other side loses its wall muffle, a caption names what is heard ("[slow steps, moving left]"). Fixed camera, so he is exposed while he listens |
| Climb | 0.6 | 40 | Context only: shelves, a desk to a ceiling tile, a fence, ladders. No free jumping puzzles. Landing from 1 m or more is 60 dB |
| Vault and drop | n/a | 50 / 60 | Over a counter or a fallen locker; dropping from a ledge |

There is a jump (short, 50 dB on landing) because players expect one; nothing in the school needs it.

### 2.2 Breath

- Breath is a sound, not a bar. Calm, uneasy, frightened and winded each have their own loop.
- **Hold breath** (a held button, any time): cuts breath out of the noise table. Lasts 8 s calm, 4 s just after a
  sprint. As it runs out the edges of the view close in and his heartbeat rises; at the end a gasp of 50 dB unless he
  lets go early (a quiet exhale of 30 dB). Letting go early is the skill.
- In cold rooms (the walk-in freezer, the roof, the mothership's holding halls) his breath shows as fog in the torch
  beam. Fog can be seen by the hunter at short range: a small honest risk.

### 2.3 Doors

- Doors open by degrees with the mouse or stick. A slow open makes no creak; a fast one creaks (40 dB) or bangs (70).
- **Peek** through the wired glass panel that every classroom door has, or through a crack.
- **Hold a door shut** against a push: both hands on screen, the door judders, hold the button and push back with the
  mouse for about 4 s. Lose and he is knocked back a step (Fine to Hurt). Only the hunter, the Patrol and the Brute
  push doors; animals scratch.
- **Wedge** a door with a chair, a mop or a rubber wedge: one use; it creaks loudly when tested, which tells Danny
  something is on the other side.
- **Lock behind** with a key from the ring: the turn is 40 dB.

### 2.4 Hiding

Each kind of hiding place protects from some things and not others. The price of every one is the same idea: the
longer you stay, the louder you get and the more likely the hunter comes back to where it last heard you.

| Place | Where | Protects from | Does not protect from | Price of staying |
|---|---|---|---|---|
| Locker | Every corridor | Sight (hunter, Mimics, Patrol) | Hearing (Listeners hear breath through the door); the hunter checks lockers near the last noise it heard | Breath louder after 40 s; torch must be off (light leaks through the slats) |
| Under (desk, bed, stage, bus seat) | Classrooms, nurse, theatre, bus garage | Sight from standing height | The hunter, which folds down to look [P7]; the Swarm, which comes down from above | Dust: the cough comes after 30 s unless he holds breath |
| Behind (curtain, coat rack, shower stall) | Theatre, changing rooms | Sight from the front | Feet show under a curtain in torchlight | Cannot see out except by leaning |
| Cold (walk-in freezer, cold store) | Kitchens, science prep | The Swarm (warmth) | Everything else; the door is loud | After 45 s he shivers (noise 35); after 90 s he starts to be Hurt |
| Dark corner | Anywhere unlit | The hunter's sight beyond 6 m | Dark Dwellers, who live there; the Still Ones, who move when unseen | He must kill his light, so he cannot see either |
| Vent | Ceilings and walls | Sight, and things too big to fit | The hunter (it follows through vents and gaps: the owner's rule); the Swarm (vents are its home) | Sheet metal is loud (+12 dB); turning round takes 2 s |
| Bin, laundry cart, trophy cabinet room | Placed | Sight | Hearing at close range | Getting out is loud (50 dB) |
| Safe room or save point, door shut | Fixed | Everything except the one scripted breach | n/a | None, except the generator clock on the hardest preset |

**Rule the player learns once:** the hunter searches where it last heard you after 20 to 40 s. Hiding is how you
wait out a pass, not where you live.

### 2.5 Danny's body is the interface

- **Hands.** Left hand holds the light; right hand does everything else (doors, items, the radio button). When he
  uses both hands (bandaging, holding a door, carrying the sledgehammer, crawling with no strap clip) the light goes
  in his mouth (dimmer, wobbles with his breathing) or off. Hands shake with fear, and the torch beam shakes with
  them: a shaky beam is the readout of his fear. A blood-dark sleeve shows when he is Hurt.
- **Breath** says how winded and how frightened he is (above).
- **Pulse** is a heartbeat heard only above a fear threshold and while hidden. It is information for the player, not
  noise for the creatures.
- **What is drawn on screen:** nothing by default. A small dot appears only when something usable is in reach (it can
  be turned off). A two-second line names what he picked up ("Batteries, two"). Subtitles and sound captions. The
  backpack when he opens it. Prompts appear on first use only (always, on the Story preset).
- The research's fitness-band idea is dropped: under [P4] (section 3.3) a band would be dead, and the body already
  says what it said.

---

## 3. Light and noise: the two currencies

Every floor charges a different mix of the two. Light lets him see and keeps Dark Dwellers back and the Still Ones
frozen; it shows him to the hunter and the Patrol. Noise lets him go fast, force locks and lure; every creature but
the Still Ones and Dark Dwellers (while the generator runs) can hear it.

### 3.1 The torch and its battery

- **Danny's torch** is the janitor's old work torch (Gus gives it in Chapter 1). Two AA cells (one "pair").
- A fresh pair gives **6 minutes of on-time**. Off costs nothing, so the clicking on and off is the skill. Below 25%
  the beam yellows and narrows; below 10% it flickers. A shake brings 5 s of brightness back (a rattle, 30 dB).
- **Cupped beam** (hold the light button): his fingers cover the lens, a dim red glow, enough to read a note or find
  a step at 1 m, half the drain, and not seen beyond 4 m. Small, cheap, and the move players remember.
- Changing batteries: 2 s, both hands, the old pair goes into the pack (it can be thrown as a lure, 55 dB).
- **The free fallback: the crank torch** (a camping torch from the janitor's store, Chapter 1). Three cranks give
  20 s of weaker light; the crank whirrs at 40 dB. He is never stuck in the dark, only made louder.
- Who sees the beam: the hunter notices a beam pointed into its area from up to 20 m; the Patrol from 30 m;
  Listeners are blind; Mimics turn towards it; the Dark Dwellers recoil from its cone; the Still Ones are frozen only
  while lit and looked at.

### 3.2 Other light

| Light | Lasts | Note |
|---|---|---|
| Glow stick | 10 min glow; keeps a Dark Dweller off a doorway for 90 s | Snaps with a crack (35 dB). Thrown, it marks a route |
| Road flare | 60 s, very bright | One-use scare-off for the hunter (section 5); every creature sees it |
| Lighter | Endless, 2 m of light | One hand; the flame's warmth draws the Swarm. Lights candles and flares |
| Candles | 20 min, placed | Save points and the safe room |
| Wall switches | While the generator feeds that circuit | Basement and per-floor circuits (section 6) |
| Exit signs | Chapter 1 and 2 on their own batteries, then they die | Green islands that show the way back; their dying is a scare the player notices |
| Room things | Fixed | A vending machine's glow, a projector left on, the scoreboard, a fish tank's light |

### 3.3 Why phones are no help [P4] [PROPOSAL]

Recommended: **the arrival flash.** When the mothership takes position over the city (the prologue), a flash burns
out every device that can send a signal: phones, smart watches, the school's Wi-Fi, car electronics. Screens go black
and warm in pockets. Simple, old things survive: the diesel generator, plain torches, the stopwatch, the wired bell
system and PA, cassette players, and the school's old analogue walkie-talkies, which sat switched off in the PE
office's steel cabinet. The rule is one sentence a player can learn: **"if it could call someone, it's dead."** It
makes light, maps and calls things he earns, and it makes the walkie-talkie link with Kayla precious. A dead phone in
the pack is a keepsake, nothing more (its cracked lock-screen photo is a story note). The alternatives are in the
decisions list.

### 3.4 The noise table

One table drives three things: how loud the sound plays (so the ear learns the scale), what each creature hears,
and the optional noise ring. Received level = noise at 1 m - 20 log10(distance in metres) - occlusion (closed door
15 dB, wall 30 dB, floor 35 dB). A creature hears it when the received level beats its threshold.

**Surface and debris add to the base noise of each step** (base from 2.1):

| Surface | Add (dB) | | Debris (layered on top) | Add (dB) |
|---|---|---|---|---|
| Carpet, library strip, gym mat | -5 | | Paper, leaflets | +2 |
| Lino, tile, concrete | 0 | | Ceiling-tile grit | +4 |
| Gym hardwood (long echo) | +4 | | Cans, cups (kicked) | +10 |
| Wet floor, puddle | +6 | | Broken glass (glints in the beam, so it can be avoided) | +12 |
| Roof gravel, rubble | +6 | | A balloon underfoot (pops) | +30 |
| Metal stair, grate | +8 | | | |
| Vent sheet metal | +12 | | | |

**Actions:**

| Action | dB at 1 m | Action | dB at 1 m |
|---|---|---|---|
| Torch click | 20 | Locker in or out (slow / fast) | 38 / 50 |
| Cupped-beam fumble, page turn | 20 | Drop an item | 50 |
| Bandaging | 30 | Bottle or can thrown (at impact) | 60 / 75 |
| Breath, Badly hurt | 32 | Kitchen-timer rattle ringing (4 s) | 70 |
| Danny's whisper on the radio | 30 | Dumbwaiter running | 65 |
| Radio at low / mid / high | 35 / 45 / 55 | Kicking out a vent cover | 65 |
| Stopwatch beep | 45 | Door slam | 70 |
| Key turn, crank torch | 40 | Pry bar on a door | 80 |
| Unscrewing a vent (6 s) | 25 | Bolt cutters through a chain | 60 |
| Generator running (masks steps in the basement) | 55 | Sledgehammer blow | 90 |
| Generator start (pull cord) | 85 | Pans banged, air horn | 85 / 100 |
| Alien gun charged and raised (whine) | 35 | Alien gun shot | 95 |

**What it means in metres (hunter threshold 28 dB; Listener threshold 20 dB; open air):**

| Gait and floor | Hunter hears from | Listener hears from |
|---|---|---|
| Crouch on carpet (30) | 1.3 m | 3 m |
| Crouch on lino (35) | 2 m | 6 m |
| Walk on lino (45) | 7 m | 18 m |
| Walk over glass (57) | 28 m | far |
| Sprint on lino (60) | 40 m | far |

Other thresholds (the creature designer's to tune): Patrol 32, Mimics 30, Brute 40; Dark Dwellers hear at 30 only
when the generator is off; the Still Ones and the Swarm do not hunt by sound. While the generator runs, the basement's
hum raises every basement threshold by 15 dB: power off means silence, and his steps suddenly carry.

### 3.5 How the player reads his own noise

- **By ear first.** The mix favours his own steps and clothing when he sneaks; the room's echo tells him how big it is,
  and big rooms announce him. Within a chapter the ear knows glass from carpet.
- **By the world.** A Listener's ping turns his way; a Still One's grind stops; the hunter's whisper stops (its alert
  tell is silence).
- **The noise ring [PROPOSAL]**: an optional faint ring at the foot of the screen that swells with each sound he makes,
  using the table's numbers. Off by default on Survivor and Stay Behind, on by default on Story.

---

## 4. The backpack and the binder

- **The pack: 8 slots**, a real school backpack. Opening it swings it to his front; he looks down into it; items sit in
  it as real objects in a 4 x 2 grid. **The world never pauses** (an option on the Story preset only). Opening and
  closing take about half a second, and the zip is 30 dB if he opens it fast, silent if slow (hold).
- **Two pockets** on the chest strap, on quick buttons: **the light pocket** (torch, crank torch, lighter or glow
  stick) and **the throw pocket** (one throwable or one scare-off tool). A scare-off tool in the throw pocket is what
  saves him from a hunter catch on the gentler presets (section 9).
- **Also on the chest strap, taking no slot:** the walkie-talkie and the coach's stopwatch.
- **What takes space:** battery pairs stack 4 to a slot; glow sticks 3; bandages 2; parts (tape, wire) 5; food tins
  2; a fuel can 2 slots and sloshes when he runs (30 dB, silent when full); tools 1 or 2; the sledgehammer and the fire
  extinguisher are carried in both hands, never in the pack (he cannot hold a light, and dropping them is 60 dB).
- **One upgrade only:** the hiker's bag in the lost-and-found (Chapter 4) raises the pack to 12. Medium weight stays
  medium.
- **The binder** (never costs a slot): the janitor's key ring (every key he earns), notes and letters, the floor maps
  (each floor's fire-evacuation plan, taken off the wall), the symbol pages, the chalk, and Danny's own pocket
  notebook. The map marks itself in his pencil (an X on a locked door, a circle on a puzzle). Kayla's notes come in
  blue ink, added when she tells him something. Opening the binder is the same: no pause.
- **Notes can be turned over.** Some clues are on the back.
- **Stashes.** The safe-room cabinet holds anything, without limit. Each small save point has one shelf of 4 slots
  that stays there. **The dumbwaiter**: from a kitchen hatch on any school floor he can send items down to the
  survivors' cabinet (one way; 65 dB while it runs). Sending medicine down before the return is how he helps someone
  in time.

---

## 5. Every item

Scarcity: **common** (most searches of a few rooms), **scarce** (two or three per chapter), **rare** (one per chapter
or less), **unique**. Item spots are drawn per playthrough from a hand-placed list of 3 to 5 plausible spots; story
items never move. The **pity rule** (never shown): when he is at zero of batteries, fuel or bandages, the next two
containers he searches lean towards it. Where an item is found below is a proposal for the level designer.

| Item | Found | What it does | Scarcity | From |
|---|---|---|---|---|
| **Light and power** | | | | |
| Janitor's torch | Given by Gus | Main light, 2 AA, 6 min per pair | Unique | Ch1 |
| AA battery pair | Desks, drawers, smoke alarms, remotes | Refills the torch; spent pair is a lure | Common to scarce (scarcer each floor) | Ch1 |
| Crank torch | Janitor's store | Free light: 3 cranks = 20 s, 40 dB | Unique | Ch1 |
| Glow sticks | Dance-night leftovers on the floor | Quiet light, route marker, keeps a Dweller off a doorway 90 s | Common in Ch1 to 2, then scarce | Prologue |
| Lighter | Staff-room jacket | Small endless flame; warmth draws the Swarm | Unique | Ch2 |
| Candle | Staff room, music room | Placed light for 20 min | Scarce | Ch2 |
| Fuel can | Bus garage, mower shed, fuel store | Two ticks of generator fuel; 2 slots; sloshes | Scarce | Ch1 |
| **Healing** | | | | |
| Bandage | Teacher's first-aid box, nurse | 4 s; stops bleeding; Hurt to Fine | Scarce | Ch1 |
| First-aid kit | Nurse's office, PE office, bus | 8 s; Badly hurt to Fine | Rare | Ch1 |
| Painkillers | Nurse, staff bags | 3 min without the limp: he can sprint again; heals nothing | Scarce | Ch2 |
| Cold pack | Nurse, kitchen freezer | Squeezed: masks his warmth from the Swarm for 60 s | Scarce | Ch5 |
| **Distraction** (all nothing more than noise) | | | | |
| Bottle, can, tin | Everywhere | Thrown lure, 60 to 75 dB where it lands | Common | Ch1 |
| Kitchen-timer rattle | Built: kitchen timer + biscuit tin + tape | Wind it 5 to 30 s; it ticks, then rings 4 s at 70 dB. Best against Listeners | Built, 1 per timer found (scarce) | Ch2 |
| Wind-up toy | Lost-and-found, drama props | A chattering lure that walks in a line for 15 s: noise that moves | Rare | Ch2 |
| Cassette player | Music room | Plays a tape for 2 min on one battery pair; a long, placed lure | Unique | Ch2 |
| Party-popper tripwire | Built: popper + string, from dance leftovers | A bang when something walks through: an alarm that tells him where | Scarce | Ch2 |
| Pots and pans | Kitchens | Bang in place, 85 dB: calls everything to him. A sacrifice move to pull a creature off a survivor or a route | Common, fixed | Ch1 |
| Bell and PA panel | Main office (Ch2), floor panels | Rings bells or a tone in another wing | Fixed | Ch2 |
| **Scare-off** (drives a creature away for a time; never hurts) | | | | |
| Road flare | Janitor's store, buses, roof box | Hunter backs off 45 s; lights a room. The hunter remembers: a second flare in the same chapter buys half | Rare | Ch1 |
| Fire extinguisher | Fire points (fixed, 3 to 4 per floor) | One blast of cloud and cold: the hunter backs off 45 s, a Swarm cloud scatters. Carried in both hands; then empty | Scarce, fixed | Ch1 |
| Air horn | Sports-fan bag from the evening game | 100 dB: every Listener near flinches and flees for 15 s, and every creature on the floor hears it | Rare | Ch2 |
| Hand mirror | Drama dressing room | Held up, it lets him watch behind as he walks (if the creature designer agrees that a mirror counts as looking) | Unique | Ch3 |
| Fog canister | Theatre | Thick smoke for 40 s: breaks sight for the hunter and Mimics; on the Still Ones' floor it frees them, so it is a trap there | Rare | Ch3 |
| Camera with flash | Yearbook room | One flash per battery pair: blinds a Mimic 3 s and shows its real face | Unique | Ch4 |
| Dry ice cooler | Science prep | Placed: a cold patch the Swarm avoids for 3 min; carried: 2 slots | Rare | Ch5 |
| Thermal camera | Science prep | Shows warmth through ceilings and vents (the Swarm); uses batteries fast | Unique | Ch5 |
| **Keys and the loud way** | | | | |
| Key ring | Gus | Holds every key; keys open earlier closets too | Unique | Ch1 |
| Chalk | Any classroom | Marks doors; the marks stay (and get scratched) | Common | Ch1 |
| Screwdriver | Janitor's store | Opens vent covers quietly (6 s) instead of kicking them (65 dB) | Unique | Ch1 |
| Pry bar | Boiler room | Forces jammed doors, 80 dB | Unique | Ch1 |
| Sledgehammer | Bus garage | Breaks the bricked arch and later walls; 90 dB a blow; two hands, no light | Unique | Ch1 |
| Bolt cutters | Groundskeeper's cage | Cuts chains and padlocks, 60 dB | Unique | Ch2 |
| Coach's stopwatch | PE office | Set to the generator gauge; beeps at 60 s left (45 dB) unless silenced; also times bells and puzzles | Unique | Ch1 |
| Walkie-talkie | PE office steel cabinet | The link with Kayla (section 8) | Unique | Prologue |
| Survivors' need items | Each floor (section 7) | One named thing per person | Unique each | Ch1 to 5 |
| Food tins | Kitchens, vending machines, lockers | The room's food; shown on the shelf | Scarce | Ch1 |
| **Alien (from the city on)** | | | | |
| Alien gun | The knocked-out soldier | Six energy cells, shown glowing on the weapon (section 12) | Unique | Ch6 |
| Energy cartridge | Patrol soldiers, supply racks | Refills 2 cells; a quiet click | Scarce | Ch6 |
| Scanner | The same soldier's wrist | Reads glyph locks; a life-sign ping; shows a map once linked at a node | Unique | Ch6 |
| ID shard | Patrol officers | Opens Patrol doors and the ship's hatch | Rare | Ch6 |
| Lure beacon | Patrol belts | Thrown: Patrol soldiers go to check it for 20 s | Scarce | Ch6 |
| Mend gel | Patrol medic packs | Badly hurt to Fine in 3 s; it stings and he gasps (45 dB) | Rare | Ch6 |

---

## 6. The generator and the power budget

### 6.1 How it works (Chapter 1)

- **The machine** is the school's diesel standby set in the boiler room, through the wall from the safe room (the
  caretaker's workshop behind a steel door).
- **The gauge** is a needle over 8 ticks. A fuel can adds 2. Refuelling just before the needle crosses a tick saves
  a little (Gus's note hints at it).
- **Starting it** is physical: prime, choke, pull. One to three pulls, each 85 dB. A start in the dark with something
  near is the scene players remember.
- **Burn:** 0.25 ticks a minute at idle plus 0.1 for each power unit in use. **Capacity is 6 units at once**; switch on
  more and the breaker trips with a bang and a 5-second blackout (it teaches the limit once).

| Circuit | Units | What it gives |
|---|---|---|
| Safe-room lights | 1 | The room is lit; the survivors calm |
| Safe-room heater | 2 | Warmth; the sick get better |
| Radio base and CCTV | 1 | Kayla can see and talk |
| Boiler-side corridor lights | 1 | Keeps Dark Dwellers out of the near corridor |
| Tunnel lights | 1 | Keeps Dark Dwellers out of the tunnels |
| Kitchen undercroft lights | 1 | The way to the dumbwaiter |
| Sump pump | 2 | Drains the flooded section (a one-time job) |
| Freight lift | 2 | Opens the way up at the chapter's end |

With 4 units on, a full tank lasts about 12 minutes; with everything allowed (6) about 9; at idle with only the
room's lights, about 23. The Story preset burns at 0.65 of that (about 19 minutes a tank).

- **The stopwatch.** Danny sets the coach's stopwatch to the gauge (hold a button at the generator). Lifting his wrist
  shows the minutes left; it beeps at 60 s. The beep is a 45 dB noise he can silence, at the price of the warning.
- **When fuel runs out** the lights fade over 4 s, never snap. The hum winds down over 3 s and then there is real
  silence. The exit signs stay lit on their own batteries. The Dark Dwellers come out of every unlit space.
- **Fuel sources:** cans (4 to 6 in the chapter, with the pity rule); the fuel-store drum (10 ticks in all, then
  dry); and the free fallback, **siphoning from the school buses** in the bus garage: 40 s per tick, a gurgle at 40
  dB, far from home. He is never stuck, only made to take a risk.
- **The first failure is scripted** so that the Dark Dwellers' arrival is taught, not punished; the gauge is real after
  that.

### 6.2 What each choice costs

Every unit is someone's comfort. Lighting the tunnels for the trip out leaves the room cold. Running the pump drains
the flood but eats two units for as long as it runs. Keeping the radio base on means Kayla can warn him; switching it
off buys three minutes of fuel and silence on the radio. The survivors say what they lose, briefly, once ("Heater's
off again. Okay.").

**Not a chore:** the clock is frozen while Danny is in the safe room with the door shut (except on Stay Behind); no puzzle needs fuel he can run out of; the slow free source is always there.

### 6.3 After the basement [PROPOSAL]

From Chapter 2 the generator becomes **the room's reserve**, not a stopwatch:

- Gus sets it to the night setting. Each chapter Danny is away costs the room 4 ticks. When he comes back, the gauge
  shows what is left, and the room shows it too (lights low, the heater off, Dwellers' scratches on the outside of the
  steel door if it reached zero).
- **Each floor has a breaker panel fed from the basement.** Powering a floor circuit (lights on the Still Ones' floor,
  the freight lift, a maglock, the PA) draws from the same reserve. Every unit spent upstairs is heat taken from the
  survivors. That is the choice, stated in one line by Gus.
- Bringing a can home is visible care. Nothing in Chapters 2 to 5 fails because of fuel; only the room's comfort, its
  survivors' health and the ledger feel it.
- **The last test is the roof (Chapter 5):** the helipad lights and the roof door need the generator at full for one
  timed stretch (stopwatch back in use) while the helicopter comes in. Whatever is left in the reserve is the time he
  has.

---

## 7. The safe room and the survivors

### 7.1 The six [P6] (roles proposed here; names, ages and stories belong to the story draft)

| Who | Job in the room | Need (one named thing, fetched from a floor) | What Danny gets back |
|---|---|---|---|
| The teacher (leads) | First aid, keeps order, decides who goes where | Their heart pills from the staff room (Ch2) | A bandage pack in the dumbwaiter each chapter; a calm briefing |
| Gus, the night janitor (58) | Keys, repairs, the generator, the tunnels | His reading glasses, left in his cage (Ch1); later a spare part for the lift motor | Oils the door Danny uses most (it stops creaking); a new key each return; fuel tips |
| Marcus, the classmate | Scouts the near corridors, carries; restless | News of his brother (his brother's team jacket from the locker room, Ch3) | Clears and chalks a route on the stair; if neglected he goes out alone, and that is how he is lost |
| The tech student | Radio base, CCTV, the dumbwaiter motor | A soldering iron and a cable from the media room (Ch2) | One CCTV camera restored on the next floor; at the end of Ch3, a **radio earpiece** that makes Kayla silent to creatures |
| The hurt student | Counts and packs supplies, cannot walk far | Painkillers and a splint (Ch1 to 2) | Packs a "kit" for each trip: one free item of what Danny is short of |
| The youngest (14) | Lookout at the hatch; draws | An inhaler from a backpack in the gym (Ch2 or 3) | Draws a map of a floor from a window view: one extra mark on Danny's map |

Kayla is in the room too, at the radio base, but is not one of the six (the story draft decides her scenes).

### 7.2 How it runs

- **One request per chapter**, from whoever is worst off. It has a chapter-long deadline, never a real-time clock.
  Progress never stops for a missed request.
- **The room shows its state, never a meter:** tins on the shelf, the medicine box, the heater on or off, who is
  sleeping, who sits alone, a blanket over an empty chair.
- **What he brings back:** the need items, food, medicine, fuel. What he keeps for himself is a real choice: the last
  first-aid kit is for him or for the hurt student.
- **Neglect shows** in two steps: worse (sick, angry, quiet; their help stops), then gone (they leave, or are lost in
  the breach, off screen; an empty cot, a note).
- **Night talk:** on each return, one survivor can be talked to at the generator (two or three talks each across the
  game). Talking is optional and is how their stories are told.

### 7.3 The one breach [PROPOSAL: the story draft owns when]

Once in the school, after the Chapter 3 return, the hunter comes in through the boiler-room wall. Scripted, but
played: Danny gets people out through the hatch while the lights die. Who is lost is whoever the ledger has done least
for (never shown as a choice at the time). After it the steel door is welded, the room is never fully trusted, and
the survivors move their cots away from that wall.

### 7.4 The hidden ledger

Counted, never shown: for each survivor, needs met and in time, items given, talks had; for the group, food and fuel
brought, truths told (whether Danny tells them what he saw of the taken), whether he went back for someone. It decides:
who is lost in the breach; who makes the helicopter (Chapter 5); who of the lost and taken is found in the holding
halls and can be freed (Chapter 8, by pod power, section 12); and what the epilogue shows. A survivor who is lost
becomes a voice in the hunter's whisper from then on [P1].

---

## 8. Kayla on the radio

- **The device.** A school walkie-talkie on Danny's chest strap, push-to-talk on a button. A **volume knob** with four
  stops: off, low (35 dB at 1 m), mid (45), high (55, with the squelch). At low, words can be lost under the
  generator, the rain, a creature. The tech student's earpiece (end of Ch3, if helped) removes the noise entirely; this
  is the ledger's best payback.
- **What she can see.** The CCTV monitors at the radio base, and only while its circuit has power. Cameras per area:
  basement 6, first floor 4, second 3, third 2 (and on the Mimics' floor she sees "people", and cannot always tell),
  fourth 1 (the Swarm chews the cables). Her help fades as he climbs, which is the point.
- **What she says.** A creature's place by camera name ("It's in the east stair. Going down."); the floor's layout from
  the evacuation plan in the room; things she remembers about the school; her own fear. She can be wrong and says sorry.
  She never speaks a code's value. She never answers a Mimic's question for him.
- **When she speaks.** In calm moments, or when he calls. While a creature hunts him, only warnings of 6 s or less. She
  is silent when the radio is off, when the base has no power, in the Mimics' set pieces where silence is the scare,
  and from the moment she is taken at the end of Chapter 5. After that the radio is dead air; it is never faked [P1].
- **Hints, by a ladder** tied to the puzzle setting. When he is stuck on a puzzle step (no progress for the time
  below), she asks what he sees; then remembers something about the room; then gives a strong hint. Calling her (hold
  the radio button) brings the next rung early.

| Puzzle setting | Rung 1 | Rung 2 | Rung 3 | Full answer |
|---|---|---|---|---|
| Light | 2 min | 4 min | 6 min | Yes, if he asks again |
| Standard | 4 min | 8 min | 12 min | Never |
| Hard | 6 min | 12 min | none | Never |

- **The "what now" call** (hold the radio button with no puzzle near): she says the current goal in one line. Always
  available on Story; on Survivor once per floor before she says "You know this one".

---

## 9. Health, injury and death

- **Three states, no number: Fine, Hurt, Badly hurt.** Hurt: heavier breath, a dark sleeve, shakier hands. Badly hurt:
  a limp (1.1 m/s, no sprint), his hand on the wall as he goes, breath loud enough for a Listener at 2 m, and
  **bleeding**: fresh drips the hunter can follow for 30 s. A bandage stops the bleeding.
- **Hits** (an animal's swipe or sting, a door lost, a fall over 3 m) drop him one state. **Catches** end the attempt.
- **Who does what [P2].** The animals (Dark Dwellers, Listeners, the Swarm, the Brute) **maul**: a catch is a short
  graphic death scene of Danny, 4 to 8 s, skippable after the first time each is seen. The hunter and the Patrol
  **take**: Danny is dragged away and the screen cuts to black with sound; nothing more is shown.
- **Escaping a catch [PROPOSAL].** If a scare-off tool (flare, air horn, or from the city the charged gun) is in the
  throw pocket, a catch turns into a 1.5 s struggle; win it and the tool is spent, Danny is Hurt, and he is free. With
  the pocket empty, the catch is final. On Story, the first catch in each area is always a struggle he can win.
- **Healing:** bandage (4 s), first-aid kit (8 s), painkillers (no heal, no limp for 3 min), mend gel (city on). All
  take both hands on screen and can be interrupted. **Rest** on a cot in the safe room heals one state and costs the
  room one tick. Story adds slow self-healing from Hurt to Fine after 60 s without harm.
- **What dying costs:** the time since the last save. Retry loads in under 5 s, from the later of the last manual save
  and the chapter autosave. After two deaths in the same stretch (Survivor), the game offers once to restart from the
  last doorway he passed. The world keeps the same codes after a death (the seed is fixed at New Game).

## 10. Saving [P3]

- **The basement safe room: the logbook and the desk lamp.** Danny writes one line (3 s, the pen scratching); the
  line is a short diary beat that changes with what has happened. These lines, read back on the load screen, become a
  quiet record of the whole game.
- **Every later area has one small save point:** a room with a lock (a staff toilet, the book store, the projection
  booth, a laundromat back room in the city, a crew alcove on the mothership) where a survivor or Danny has left a
  lantern. He lights it and writes in his pocket notebook. One per school floor, two in the city (it is 80 minutes),
  three on the mothership plus a checkpoint at each self-destruct stage, automatic checkpoints in the flight. They sit
  15 to 25 minutes of play apart, deliberately uneven. Story adds one extra lantern per area.
- **Not while hunted:** within 25 m of a searching creature the lamp flickers and he stops writing.
- **Chapter autosave** at the start of each chapter, as he asked.
- **Quit safely:** "Quit and keep my place" from the pause menu, anywhere, writes a one-time save that is deleted when
  loaded: he can stop for dinner without losing progress or getting a free retry.
- Three manual slots plus the autosave and the quit save. A save never rolls new codes.

## 11. Difficulty

Three dials, set at New Game through three presets or Custom. Plain names, no "Easy". The start screen recommends
**Survivor**, tuned gentler than the reference games' normal settings so that the player feels the fear without being
stuck: a first-time player should die about once in every 20 to 30 minutes, and never be truly stuck for want of a
supply.

| Dial | Value | Story | Survivor (recommended) | Stay Behind |
|---|---|---|---|---|
| Creatures | Hunter events (seconds between, sprint / walk / crouch) | 25 / 45 / 90 | 15-20 / 30 / 60 (his numbers) | 12 / 22 / 45 |
| | Hearing (threshold offset) | +6 dB (hears at half the distance) | 0 | -4 dB |
| | Speed | 0.85 | 1.0 | 1.1 |
| | Catch struggle window | 2.0 s, and first catch per area always a struggle | 1.5 s, needs a pocket tool | 1.0 s, needs a pocket tool |
| | Scare-off length | 60 s | 45 s | 30 s |
| Survival | Supplies found | 1.5 x | 1.0 x | 0.6 x |
| | Generator burn | 0.65 x | 1.0 x | 1.25 x, and runs in the safe room |
| | Save lanterns | +1 per area | as section 10 | as section 10 |
| | Pity rule | next 3 searches | next 2 | off |
| | Self-healing, bleeding trail | on, off | off, on | off, on |
| | Pause while in the pack | option | no | no |
| Puzzles | Light / Standard / Hard, chosen apart from the preset | Light | Standard | Hard |

- **When they can change:** creatures and survival at any time from the pause menu. Puzzles can be **lowered at the
  start of a chapter, never raised mid-game [P5]** (the codes of that chapter are rolled again for the new tier).
- Stay Behind is open from the start, but marked as the hard one.

## 12. The city and the mothership: what changes

**The gun (Chapter 6 on) [PROPOSAL: what it can do is shared with the creature draft].**
- **Six energy cells** glow on its side; he checks them by lifting it (no HUD). Its charge whine rises with the stored
  energy, so the ear counts the last shots.
- **Quick bolt** (1 cell): staggers a Patrol soldier 4 s, scatters a Swarm group or a Dark Dweller, drives the hunter
  back 30 s. **Charged shot** (hold 1.5 s, 3 cells): kills a Patrol soldier, drives the hunter off 90 s, staggers the
  Brute 3 s. The hunter cannot be killed by it.
- Every shot is 95 dB: the block hears it. **Recharge** at alien pylons (20 s for 3 cells, a loud hum the Patrol
  notices within 30 m) or from cartridges taken from soldiers. **Takedown:** from behind an unaware lone soldier, a
  point-blank bolt to the neck plate drops him quietly (1 cell, 50 dB); this is how the first one is knocked out.
- The rule stays: **hiding is still the first answer.** Six cells do not win a street.

**The scanner.** Danny's phone has been dead since the prologue; the scanner is the first map and the first tracker
he earns, and like every information tool it costs. A **ping** shows warm life within 25 m for 4 s through walls
(the taken in their pods glow differently), recharges in 20 s, and is a 40 dB chirp the Patrol hears. It **reads
glyph locks** with the symbols he has learned (the more he knows, the fewer the guesses), and **shows the map** of a
deck once linked at a node.

**The city.** No generator and no safe room; two save points; the torch and the backpack as before; street fires and
dead traffic lights as light; car alarms as huge lures; the radio is dead air. The Patrol's room-by-room search makes
doors and lines of sight the new currency.

**The mothership.** The alien power budget returns as a twisted generator: the holding halls' pods, the doors and
the lights draw from one alien board, so every person freed costs power somewhere else (the ledger sets who is there).
The Brute tears hiding places open after a 2 to 3 s tap-and-sniff tell, so moving beats hiding. **Low gravity**
(one stretch, about 20 minutes): no walking; he pushes off surfaces (aimed with the view), drifts in a straight
line, grabs handholds, and can **fire the gun behind him as a thruster** (1 cell) when he has drifted wrong. Drift
slows itself on Story; down rarely changes; a sound and a soft vignette mark the moment he is out of reach of any
surface.

## 13. The flight (Chapter 7, about 20 minutes)

- **A set course** through eight segments of about 2.5 minutes, each a set piece: off the street, the tower canyon,
  under the bridge, the cloud layer, the swarm of alien craft, the debris of the helicopter's attackers, the mothership's
  outer fins, the hangar mouth. The ship keeps moving forward on its own; he steers inside a corridor about 80 m wide and
  40 m high around the course.
- **Controls:** steer (mouse or stick), **dodge** (a sidestep roll, 0.4 s of no hits, 1.2 s cooldown), **boost** (3 s,
  refills in 6 s; boosting shows a bright trail that pursuers lock on faster), **shoot** (unlimited, overheats after 3 s
  of fire and cools in 2 s).
- **Fair:** every missile sounds a lock tone 1.5 s before it fires (2.5 s on Story); scraping scenery costs a hit, never
  an instant death; the hull shows damage as cracks across the canopy glass and an alarm (4 hits, 6 on Story); a
  checkpoint at each segment; aim assist on by default.
- **Exciting:** speed and space change every segment (tight canyon, open cloud, a vast fin), pursuers grow from two to
  a pack, one quiet segment in the middle (the cloud layer, no enemies, the city burning below), and the last leg plays
  the song the audio plan puts there, with the player still flying.

## 14. Forty small mechanics

**Light:** (1) Cupped hand over the torch: a red glow to read by. (2) Shake a dying torch for 5 s of light. (3) Torch in
his mouth when both hands are busy; it wobbles with his breath. (4) Glow sticks crack, then light the floor green; a
thrown line of them is a path home. (5) Exit signs die between chapters; the player notices the green is gone. (6)
Glass glints in the beam, so careful feet avoid it. (7) The lighter's flame bends towards an open vent: it shows a draught
and a way through.

**Noise:** (8) A balloon from the dance pops underfoot like a shot. (9) Library carpet strips are silent; the gym
floor booms. (10) The fuel can sloshes unless full. (11) Spent batteries are free lures. (12) Wind the timer longer for
a later ring. (13) The wind-up toy is noise that walks away. (14) The bell system still rings on its timer; move under
its sound (times change each playthrough). (15) Zip the pack slowly to keep it quiet.

**Doors and hiding:** (16) A slow door makes no creak. (17) Peek through the wired glass first. (18) Crouch at the
gap: feet and light on the other side. (19) A wedged chair creaks when tested: something is there. (20) Hold a door
while it judders. (21) Lean out of a locker through its slats. (22) Let go of a held breath early to avoid the gasp.
(23) A curtain shows your feet in torchlight. (24) The freezer saves you from the Swarm and starts to hurt at 90 s.

**Body and health:** (25) The beam shakes with his fear. (26) Breath fogs in the cold and can give him away. (27)
Fresh blood drips that the hunter follows. (28) Badly hurt, his hand slides along the wall. (29) Bandaging can be
interrupted halfway.

**Map, binder, puzzles:** (30) The map marks itself in pencil; Kayla's notes are blue. (31) Chalk marks on doors; Dark
Dweller scratches over them on the way back. (32) Turn a note over. (33) Codes change each run; their places don't. (34)
The evacuation plan by the stairs is the floor's map.

**Generator and room:** (35) Refuel just before a tick to stretch a can. (36) Silence the stopwatch's beep, and lose the
warning. (37) The door Danny uses most stops creaking once Gus oils it. (38) A blanket on an empty cot. (39) The
logbook lines, read back on the load screen.

**Alien:** (40) The gun's charge whine tells you how many shots are left without looking.

## 15. Options and access

- **Subtitles:** on by default; size (4 steps), background box, speaker names, colours per speaker, and **sound
  captions** for every gameplay sound with a direction mark ("[whisper, behind left]", "[glass crunch, ahead]"); the
  hunter's whisper is captioned with its words.
- **Controls:** full rebinding for keyboard, mouse and controller; hold or toggle for crouch, lean, breath and
  sprint; a hold instead of mashing for every struggle; mouse and stick sensitivity; invert; aim assist (gun and flight).
- **Comfort:** field of view 70 to 110; head bob, camera shake and motion blur each 0 to 100%; flicker and strobe
  reduction (lights fade instead of flashing, the Mimics' flash is softened); a horizon lock in the flight and in low
  gravity; a "cut away" option for Danny's death scenes; a softened look for the Swarm for players who fear small
  crawling things.
- **Audio:** separate volumes for voices, radio, music, effects and ambience; dynamic range (headphones, speakers,
  night); headphone 3D sound on or off; mono.
- **Help:** the noise ring; the usable-thing dot; the "what now" radio call; prompts always on.
- **Photo mode:** from the pause menu when no creature is hunting him: a free camera within 3 m, focus and exposure,
  hide hands, a few film looks, no creature posing. Players will share the world, and the world is the selling point.

---

## Depends on other drafts

- **Story:** names and stories of the six; whether Kayla is counted among them; the breach's timing; the one-line
  reason for the arrival flash and why the rescue helicopter still flies; the logbook lines; the epilogue's systems
  (this draft assumes Kayla walks and looks, with no backpack and no creatures).
- **Creatures:** the hearing thresholds and the light rules in section 3; whether a mirror counts as looking for the
  Still Ones; what each catch is (maul or take); what the gun does to each kind; the hunter's memory of scare-offs.
- **Puzzles:** the hint lines and tiers, the seed and reshuffle, the floor breaker panels as puzzles, the bell times,
  the alien board on the mothership.
- **Levels:** where each item spot, save point, kitchen hatch, fire point and camera is; the return route of each
  floor.
- **Audio:** the noise table's numbers are shared with report 06's hearing subsystem and must stay one table.

---

## Decisions for the owner

Most important first. Each is a real choice; the recommendation is only a recommendation.

1. **Why don't phones work?** (This decides whether light, maps and calls are earned.) (a) The arrival flash burned out
   everything that could call someone; old, simple things still work. (b) Phones work as a light and camera but have no
   signal, and a lit phone screen draws the aliens. (c) Phones were collected at the door for the evening event and are
   locked in the office. **Recommend (a):** one simple rule the player learns at once, and it makes the walkie-talkie
   link with Kayla the only voice he has.
2. **What happens when something catches Danny?** (a) A catch ends the attempt, unless a scare-off tool is in his
   pocket, which lets him fight free once. (b) Every first catch in an area is a struggle he can win; the second is the
   end. (c) A catch only hurts him; he dies only when already badly hurt. **Recommend (a) on the recommended setting, (b)
   on Story:** it keeps the fear of being caught and makes carrying a flare a smart choice rather than luck.
3. **Does the generator keep ticking after the basement chapter?** (a) Only in the basement; on the upper floors it is
   the room's reserve, spent by each chapter away and by any floor power Danny uses, and it comes back as a clock once
   on the roof. (b) A live clock whenever he is in the school. (c) Only in Chapter 1, then gone. **Recommend (a):** the
   survivors' comfort stays tied to his choices without four more hours of timer pressure.
4. **How does saving work [P3]?** (a) The logbook in the basement room plus one small save point in every later area,
   free but slow (3 s) and never with a creature near. (b) The same, but each save burns a candle he must find. (c) Only
   the basement room and the chapter autosave. **Recommend (a):** a saving cost on top of a hunter on every floor would
   make the game harder than he wants.
5. **What can the alien gun do?** (a) Kill Patrol soldiers, scatter the small creatures, drive the hunter off for a
   while and stagger the Brute; the hunter can never be killed. (b) Only stun, never kill. (c) Kill everything with enough
   shots except the hunter. **Recommend (a):** it feels like a real weapon with six cells, and the hunter stays the
   fear to the last minute.
6. **Can the puzzle difficulty be changed in the middle of the game [P5]?** (a) It can be lowered at the start of any
   chapter, never raised. (b) Changed any time either way. (c) Fixed at New Game, as the Silent Hill 2 remake does.
   **Recommend (a):** a player who is stuck can get help without the codes changing under him mid-puzzle.
7. **Does opening the backpack pause the game?** (a) Never, except as an option on Story. (b) Always. (c) Never, on
   every setting. **Recommend (a):** the world going on while he digs in his bag is one of the cheapest scares there is.
8. **Should there be a noise ring on screen?** (a) Off by default, on by default on Story. (b) Never (nothing on screen).
   (c) On for everyone, can be turned off. **Recommend (a):** the ear does the work for most players; the ring helps a
   player who can't yet tell glass from carpet.
