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
