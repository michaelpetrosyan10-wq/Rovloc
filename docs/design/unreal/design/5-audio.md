# Stay Behind: sound, voice and music direction (document 5 of 6)

**Second edition, 21 November 2026: agrees with the game map and the canon sheet; where they differ from this document, they win.**

Sound designer's document. The first draft (21 Nov 2026) built on research 06 (audio and music plan) and 04 (voices,
songs) and does not repeat their engine notes. This edition applies the game map (`game-map.md`), the owner's twelve
answers ("use recomended": the recommended option for every one), the rulings in `drafts/CHANGES-NEEDED.md` and the
canon sheet (`canon.md`). Every number is a starting value for tuning on **Survivor** unless a preset is named.

**Order of authority.** The owner's own words (requirements.md sections 7 to 10, owner-checklist.md) > the game map >
CHANGES-NEEDED.md > the canon sheet > this document. `cutscenes.md` is the authority on every cutscene, its sound and
its music; where this document mentions one, it only points at it. The voice plan (`voices.md`) holds how the voices
are made, checked and judged by his ear; this document says what they must do in the game.

**What this document owns, and what it cites.** It owns the noise table (canon 7) and sound and music (canon 14).
Where it gives one of those numbers it is the canon value; only this document retunes them, and then the canon sheet is
updated in the same change. Everything else is cited as "canon n" and not copied: people and fates (canon 1), the
aliens (canon 2), chapter minutes and times (canon 3), places and heights (canon 4), Danny's moves and speeds (canon 5,
systems), light and power (canon 6, systems), the hunter (canon 8, creatures), the seven kinds (canon 9, creatures),
items (canon 10), saving, restart points and presets (canon 11), the symbol language (canon 12, world), the gun,
scanner, flight and self-destruct (canon 13) and the build (canon 15, production).

**Patterns, never content.** Patterns from the model games only: no sound, line, melody or voice of theirs is copied
or imitated. **Every sound is a real recording**, processed where needed (map part 8; owner-checklist lines 44 to 51):
no thin synthetic tones and no wooden knocks or clicks anywhere in the game. **Ticks and taps are never clicks.** The
generator's ballast is a low electrical buzz with no tick. The kitchen timer's run is a soft mechanical whirr muffled
in its biscuit tin. The Brute's tap is a heavy, bodied knock of flesh on metal. Any sound with a sharp, thin transient
and no body fails the click check in 11.2.

---

## 1. The sound of the game

What the player should remember hearing:

1. **The generator.** A low steady hum, a fluorescent buzz, a ballast buzz. It is home. When it coughs, the stomach
   drops; when it winds down over three seconds, the silence after is the loudest thing in the basement.
2. **Kayla on the radio.** A real, tired teenage voice through walkie-talkie static, the hum faintly behind her. The
   one warm sound outside the shelter. Nothing ever fakes it.
3. **The hunter.** Heavy steps heard from far off and through two walls, whenever it walks. And its whisper: close and
   dry, in broken pieces of the voices of people it took, always from where it really is. When it stops, it has
   noticed you.
4. **Danny's body.** Breath, a heartbeat when hidden, a step on glass he did not see.
5. **One sound rule per floor, learned in a minute:** the Dark Dwellers' wet rustle and slow breathing, and their
   silence in your beam; the Listeners' breathy hum, and the hum stopping; the creak of a Still One that moved while
   you looked away; a known voice calling plainly from a figure facing away; the Swarm's chitter like rice in a pan,
   overhead; the Patrol's tones from scanners and armour; the Brute's deck-shaking steps.
6. **Three songs** at the end of long held breaths, the first cut off mid-line by a missile.

The game is mostly quiet. Music is rare and never plays when the hunter is near. The world, the creatures and Danny
carry the fear; the score carries the grief. Every action and object has its own sound, and glass, doors and lockers
get the same care as the creatures (owner-checklist lines 47 and 51).

---

## 2. Mix states, threat, silence and the hum

### 2.1 One threat value
`Threat (0-1) = max over creatures of (Weight x Awareness x Closeness)`, ten times a second (canon 14).
Awareness: 0 unaware, 0.3 heard something, 0.6 searching, 1.0 has seen Danny. Closeness: `1 - path distance /
Radius`, clamped. Path distance is the walking route through doors and ducts, the same number used for hearing and
occlusion. Radius and weight per kind: canon 14 (hunter 40 m and 1.0 is the largest; Still Ones 15 m the smallest).

### 2.2 The states
A state holds at least 4 s; music changes on the next beat (at most 0.5 s), except that the hunter coming into view
cuts at once.

| State | Enters when | Music | Mix |
|---|---|---|---|
| Home | the shelter, power on | the camp song or the group theme: the only warm harmony in the game | world -6 dB, voices forward, hum audible |
| Haven | a lantern room (canon 11) | none; one friendly hum of its own (2.4) | world -4 dB |
| Explore | Threat under 0.2 for 60 s | silence; at most one sparse texture every 4 to 6 min | room tone, world full |
| Unease | Threat 0.2 to 0.4 | one low drone in the chapter key | ambience -3 dB |
| Near | Threat 0.4 to 0.7 | drone and slow pulse; **nothing if the source is the hunter** | ambience -6, Danny +2, creature +3 |
| Hidden | in a hiding place, creature within 15 m | music drains to 0 over 2 s | world low-passed to 4 kHz; breath, heartbeat up |
| Hunted | Danny seen | that creature's chase cue; **none when it is the hunter** (map part 8: no music while the hunter is near); its steps and Danny's breath carry the chase | ambience -10; the radio muted but for Kayla's warnings of 6 s or less (canon 14) |
| Release | 8 s clear after Hunted or Hidden | one low resolving tone, then 20 to 40 s of silence | back to Explore |
| Grief and cutscene | scripted | written cue on the timeline (`cutscenes.md` wins) | per scene; every line clear over everything |

### 2.3 Silence as a tool
Every planned silence is followed within 10 s by one piece of information (a step, a breath, a door). The sacred
silences, which no stinger may cover:
- the hunter's whisper stopping;
- the generator winding down, above all at the Chapter 5 breach, heard over the radio under Kayla's "It's in. It's
  inside, Danny." (`cutscenes.md`, part 3, stages it);
- a watched Still One;
- the missile: 4 s of nothing after it hits the helicopter, then ringing ears, then the burning city fading in;
- the radio after Kayla is taken: from the crash until she is woken in Chapter 8 it gives only static; Danny can still
  press to talk, and nobody answers (6);
- the Nest, when the murmur of Marcus's and Mari's lips stops at the same moment (`cutscenes.md`, scene 9);
- **the hold**, which has no music: only breath, the pods, the hunter and the radio (9).

### 2.4 The hum as safety
- The generator is a MetaSound with Load and Fuel inputs (its ticks, burn and units: canon 6). Under 25 % fuel it
  coughs every 30 to 50 s; in its last minute before the tank runs dry its note sags, stutters and dips (the Dark
  Dwellers' tell, canon 9). The player hears the fuel level across the basement and needs no gauge.
- It carries 40 m into the tunnels through the pipes, so in Chapter 1 the hum fading behind you means leaving safety.
  While it runs it masks the basement (canon 7); when it stops, Danny's steps suddenly carry.
- **Its start, Gus's Ears** (world 1.1, the owner's choice). A pull is 80 (canon 7) and the hunter answers it in the
  pipes. Each way she fails is **a sound of its own**, because the player tells them apart for Gus: she does not turn
  at all (the wrong relay, the one failure that is not loud); she turns over and never fires (no fuel reaches her); she
  fires and dies (air in her); she fires and will not hold (the choke). Designed from real recordings of a diesel
  starter, never a click. Every failure sound is also written in the captions (the owner's choice, 22 November: on
  Standard and Hard the player listens and picks what Danny tells Gus).
- It sits faintly behind Kayla on the radio. When the hunter cuts it at the Chapter 5 breach, her background winds down
  under her words.
- Each lantern room has one friendly sound of its own (canon 14): a wind-up clock, a vending machine's compressor, an
  emergency light's ballast in the city, an alien air pump on the mothership. The rule the player feels: a steady,
  friendly hum means you can save here.

---

## 3. The noise table (canon 7: this document owns it)

Every sound Danny makes has one number, **L, its level in dB at 1 m**. L sets how loud it plays, which creatures
hear it and what the screen may show. **There are no other hearing values in the game.** The real microphone is never
used.

**Steps: L = gait + surface + debris.** Gaits on linoleum (canon 5): crouch 30, crawl 30 (a vent move 45), walk 42,
sprint 58, a drop landing 62. A full backpack adds +2 to every step. Low-gravity push-off: 40.

| Surface | add | Debris, that step | add |
|---|---|---|---|
| carpet, books, coats | -6 | paper | +2 |
| acoustic tile, alien membrane | -8 | grit, plaster, gravel | +5 |
| gym wood, concrete, asphalt | 0 | can (then it rolls at 45) | +10 |
| ceramic tile, wet floor | +3 | broken glass (it glints in the beam) | +14 |
| hard alien deck | +4 | balloon pop | +30 |
| metal stair, grate, vent | +9 | | |

**Actions**

| Action | L | Action | L |
|---|---|---|---|
| Door eased / normal / slammed | 35 / 45 / 68 | Breath while hiding, not held | 22 |
| Locker in or out, slow / fast | 40 / 55 | Gasp when a held breath runs out; injured cough | 50; 50 |
| Item dropped | 50 | Danny whispers / speaks / shouts | 30 / 50 / 75 |
| Thrown book / can / bottle, at impact | 55 / 60 / 72 | Radio knob 1 / 2 / 3, incoming voice | 35 / 45 / 55 |
| Generator pull-start / running | 80 / 70 | Push-to-talk (key-up and squelch tail) | 30 |
| Alien gun charged and raised / shot | 40 / 90 | School bell, at each speaker (6 s) | 95 |
| Torch switched on or off | 20 | Crank, key turn, siphon | 40 |
| Stopwatch ring | 45 | Kitchen-timer rattle ringing (4 s) | 70 |
| Dumbwaiter; kicked vent cover | 65 | Pry bar; bolt cutters | 80; 60 |
| Sledgehammer | 90 | Pans; air horn | 85; 100 |

**Added from systems' list** (systems' starting values, adopted here; the canon sheet takes them in its next update):
the torch shake rattle 30; a glow stick snapped 35; the cupped-beam fumble and a page turned 20; bandaging 30; Badly
hurt breathing 32; unscrewing a vent cover (6 s) 25; the quiet exhale after a held breath 30; shivering in the cold 35;
getting out of a bin, cart or cabinet 50; a fast zip 30; the fuel can's slosh 30 (canon 10); dropping the sledgehammer
or the extinguisher 60; a vault 50; a jump landing 50. The loud creak of a tested wedge and an energy cartridge being
seated get their levels in the grey pass; the cartridge is a seated thud and a rising hum, never a click.

**What creatures hear:** `R = L - 20 log10(path distance) - occlusion` (distance at least 1 m). Occlusion: open
doorway 0, **closed door 12, wall 20, floor or ceiling 25**, Danny in a locker or under a desk 8. A creature reacts when
R reaches its threshold T.

| Creature | T | Walk on lino heard at | Sprint heard at | Note |
|---|---|---|---|---|
| Listeners | 18 | 16 m | 100 m (walls stop it) | crouch on carpet: 2 m |
| Dark Dwellers | 28 | 5 m | 32 m | only in darkness |
| Hunter | 30 | 4 m | 25 m | its interaction clock answers how loudly he moves (canon 8) |
| Mimics, Swarm | 34 | 2.5 m | 16 m | the Swarm also senses warmth and movement |
| Patrol | 36 | 2 m | 13 m | |
| Brute | 44 | under 1 m | 5 m | hunts by smell and sight |
| Still Ones | none | | | ignore sound |

**Presets** shift every threshold by one offset (Story and Stay Behind: canon 11). **Masks** raise thresholds while
they last (canon 7: the F1 heating knocks, the waves of rain on the gym roof, the nurse's white-noise machine, the
running generator in the basement), and each mask is a real sound the player can hear and time.

**What the player hears:** Danny's sounds play at `L - 58` dB relative to the reference (a sprint step on
linoleum), so 6 dB in the table is 6 dB in the ear and the ear learns the scale: carpet is quiet, glass is loud, a
balloon pops like a shot. Creature sounds use the same distance law and occlusion and play from the opening the path
comes through (portal occlusion, research 06 3.4). Path distance and occlusion come from the room-portal graph each
Layout JSON exports (world, production), so the headless rules tests and the game hear the same building.

**What the screen may show:** captions always, with direction ("[breathy hum, left, behind the wall]"); the hunter's
whisper is captioned with its words (systems 15). No caption, note or tip ever states a hunter rule (canon 8).
**The noise ring** is optional, on by default on Story only (canon 7): for 1 s, a faint ring on the floor whose
radius is where the most sensitive creature on the floor would hear that sound, `10^((L - T - occlusion)/20)`. It
never shows creatures.

**The hunter's interaction clock** keeps the owner's numbers ("one every 20 sec or 15 if sprinting and 30 sec if
walking and like 1 min if crouching"), the same on every preset; the gaps, the lulls and the whisper budget are canon
8's. Most beats are heard, not seen: its steps, a door or locker it touches in the next room, the pipes, a slow breath
through a wall (creatures' catalogue); the whisper is the rarest of them.

---

## 4. The creatures' sound worlds

Each kind has a far tell (through walls, muffled), a near tell (clear, placed), an alert tell and a catch, never
shared between kinds, all designed fresh from real recordings. Rules, numbers and looks are canon 8 and 9 and the
creature document's; this section is how each one sounds.

**The hunter (everywhere).**
- *Far:* **heavy, slow steps**, on all fours or standing on its hind legs, as the owner asked ("I also want his
  footsteps to be louder so people know when hes around"): **louder than any sound Danny can make** (his rule of 21
  November; the level: canon 14; creatures 1.2; owner-checklist line 45), heard through two walls, with long joints
  creaking. The tunnels are tall enough for it to walk (canon 4), so in Chapter 1 it is heard walking in the pipes and
  tunnels.
- *The squeeze* into a crawlway (about 110 x 120 cm, canon 4): always heard, as joint creak and its hide scraping,
  never clicks.
- *In ducts and crawlways only:* a soft many-point patter and flexing sheet metal, never footsteps. The patter is
  heard nowhere else.
- *Near:* a slow breath in through something narrow; the whisper, every word clear.
- *Alert:* the whisper stops mid-word; two seconds of nothing; then its steps turn toward you.
- *Catch* (it takes, canon 8; the voice-pulling scene, about 6 s, skippable after the first): no stinger. One long
  breath in right at Danny's ear; the long fingers into his mouth and throat, the jaw forced, **his scream cut off
  inside the breath** (a real performance, never an edit: voices.md); his fingers scraping the floor as he is dragged
  backwards; the picture cuts to black while the drag carries on for one second; then silence. Its wet, close sounds
  are kitchen foley (10). On the next attempt it whispers that scream back to him, once.

**The whisper chain.** Whose words is the story's; how often and how near is canon 8; how it sounds is this
document's. Its rules are **hidden tuning, never stated to the player** in dialogue, notes, captions, hints or loading
text.
1. *Capture:* every line a character speaks is aligned word by word when made. When a line plays in a save, its
   words enter that save's "heard" bank.
2. *Steal:* when the hunter takes a person, their heard words become its own. Each whisper is a short sentence (two to
   six words), written in advance from words that person really said on screen or on the radio, with its source lines
   listed; it can play only if all of them are in the bank. A person who said "Don't go down there alone, Danny" and
   "I'll wait for you" becomes "Danny... wait... alone... down there." It never says a new word in anyone's voice.
3. *Process:* the close dry whisper with a breath before it that the owner chose (Monster 5), applied to each
   person's own voice: their voice character kept so the player knows who it was; uneven timing; one breath where
   nobody would breathe; a faint second copy 12 dB down and 40 ms late; a short frozen tail on the last word. Its
   strength grows towards the mothership, never so far that a word is lost (voices.md part 8 holds the chain).
4. *Place:* from the hunter's real position, through portal occlusion, and only within about 10 m of walked path
   (canon 8), often from right behind Danny's head. Its direction is always honest: a whisper means "it is right
   here", never "it is over there". It is a warning, never a lure.
5. *Rules:* only whispers, never a full voice; it never asks for help and never calls from ahead; never on the radio;
   no fragment twice in a chapter; at most one every 2 to 3 minutes; his name at most once a chapter; whoever the
   LEFT list adds is heard most; never in a cutscene (except once, in cutscene 3, The Board, where the announcer's
   words through the steel door are its first whisper), a grief scene, the shelter or the epilogue; outside chases,
   silent once it has noticed him; in a chase, one whisper as it closes to within about 3 m, from right behind
   Danny's head, counted in the budget (all canon 8). It never shares a minute with a Mimic's voice (creatures 1.9).
6. *Whose voices, in order* (canon 8): at the prologue's end (cutscene 3), the announcer's "...remain... in your...
   seats."; in Chapter 1, the announcer's halftime words ("remain... in your... seats")
   and the prologue's strangers, people the player heard alive; from the end of Chapter 1, Marcus ("you'll... wait...
   right"); from Chapter 3, Mari; from Chapter 4, whoever the LEFT list adds; the scream-back after a catch; **Kayla
   once, in Chapter 6**, from a rooftop ("stay... on the... line") while the radio on Danny's chest stays dead; last,
   in the hold, **Danny's own Chapter 1 promise**, through the Mark ("getting... everyone... out").

**Dark Dwellers (basement, power out).** *Far:* a wet rustle and a scrape on concrete. *Near:* the rustle quickens and
spreads, and a chorus of slow breaths sits just outside the beam. *Alert:* caught in the torch beam they fall silent:
**silence in your beam means it is right there**; the rustle and breathing come in the 2 s before any lunge (canon 9).
They never click. *Catch:* pulled up into the ceiling; a maul.

**Listeners (first floor, blind).** A dampened floor where every sound you make stands out. *Far:* a soft, breathy
hum while they search. *Near:* the hum, placed, and the smooth eyeless head whose skin ripples toward a sound. *Alert:*
**the hum stops: one has locked on**; then the rush to where the sound was. They never click. A thrown bottle (72)
beats your steps. In Halftime Draw the pack's hum stopping at each chime is how the player knows it has arrived
(world). *Catch:* pinned to the floor, a held breath on Danny's neck; a maul.

**Still Ones (second floor).** Their moves must be heard or the rule is unfair: a dry creak of strained material and a
weight shift, precisely placed (headphone 3D sound matters most here), built so it never has a wooden-knock character
(owner-checklist line 48). *Watched:* true silence, a little dust drifting. A creak behind you within 5 m means one
moved: turn now. *Catch:* folded in; a maul.

**Mimics (third floor).** A full, plain voice, from a figure standing ahead and facing away in his route, calling:
"Danny, over here." *Tells:* no breath between words, the same line with exactly the same timing each time, a faint
second voice underneath, steps slightly too even, the room tone dropping around them. They use voices the player has
heard. **Voices draw them, the radio's included**, which is why Danny switches Kayla off on this floor (canon 9, 14).
They echo "What time?" and never say "Four"; at "Two Kaylas" a Mimic answers his whispered question with the question
back, in her voice: the one time a Mimic uses her voice (owner's decision 3; never on the radio). *Catch:* the hollow
front opens and draws him in; a maul.

**The Swarm (fourth floor).** A granular chitter like rice in a pan, overhead, whose density is the count and whose
pitch rises as they warm and agitate, placed above you; ceiling tiles bulge and dust trickles. *Alert:* the mass moves
as one, a dry rush along the duct. *Catch:* covered, stung, dragged down; a maul.

**The Patrol (city, and the ship's decks).** **They do not speak.** Their calls are tones from their scanners and armour,
and each glyph has a tone (canon 12), so learning the symbols lets the player follow them: a slow call and answer of
tones while searching, one sharp tone when suspicious, fast overlapping tones when they have him. The tones are built
from real recordings (bowed metal, struck and bowed glass, processed), never a bare synthetic tone (owner-checklist
line 44). Armour creak, weapon hum, the scanner's pulse every 8 s (canon 9); their craft's idle hum marks landing
pads. When they take someone in front of Danny: the collar of light, a person lifted away still calling out. For one
street they lead a stray Listener on a leash, and its hum walks with them. *Catch* (taken): the collar of light closing,
Danny's breath under it, the lift, the cut.

**The Brute (mothership).** Footfalls with energy under 60 Hz that shake the deck, plus controller rumble, heard from
far off; breath like a bellows; vocal fry; the scrape of the plates grown into its flesh. It has no charge. Before
tearing a hiding place open it **taps and sniffs it for 2.5 s** (canon 9): its fairness window. *Catch:* torn out of
hiding; a maul, the loudest moment in the game, held in check by the dynamic-range setting (systems 15).

**The mauls.** Every animal's catch is a graphic first-person maul of 3 to 5 s (canon 9), skippable after the first,
with a cut-away option; the sound carries the gore: wet and fast (kitchen foley), cut at the peak, then silence and a
quick return (a restart close by in under 5 s on Story and Survivor, canon 11). What happened to the students and the
taken is never heard as gore.

---

## 5. Danny's body

- **Breath** in four intensities from exertion and fear; the sprint's breath limit is canon 5's, and the player hears
  it run out before he reads it. **Heartbeat** only above Fear 0.6 and when hidden.
- **Breath-hold** while hidden removes the 22 dB breath; his chest strains audibly from 10 s; he gasps (50 dB) at 14 s,
  7 s winded or hurt, unless he lets go early (canon 5). Letting go early is the quiet exhale (30).
- **Lines follow his state:** calm, winded and scared, as three performances (voices.md 7.6); crouched, the whispered
  take (and a 30 dB noise, not 50).
- **Injury:** a catch in the breath each step, the Badly hurt breathing (32) and an occasional cough (50 dB). Medicine
  audibly settles his breath over 20 s, which is how the player knows it worked. Health has no number (canon 5): his
  body is the display.
- **Low gravity** (the Spine, canon 13: thin air, settled by the designers): sounds above 5 kHz thin out, steps
  soften, and his breath and heartbeat, heard through his body, come forward. The creatures stay audible, which keeps
  it fair.

---

## 6. The devices

- **The radio.** The school's analogue walkie-talkies (canon 10), on Danny's chest strap. The knob (off, 1, 2, 3)
  trades information for noise (35 / 45 / 55 dB); holding push-to-talk mutes the speaker. When Danny transmits, Kayla
  hears his side, so a creature near him makes her go quiet: a second warning. Static grows with height and nearness to
  the mothership. It never tracks creatures and never carries one. **On the third floor the Mimics walk to the radio's
  voice too**, so he switches her off and she comes up in person (canon 9, 14). **Priya's earpiece** (the Chapter 4
  return, canon 10) takes the radio's sound out of the noise sum entirely. Turning her down or off never counts against
  him (canon 14).
- **After the crash.** From the moment Kayla is taken, the radio gives only static; it is never faked. In Chapter 6 he
  can still press to talk, quietly (his whisper 30 and speech 50 are in the table, and the Patrol hears them), so his
  voice and his jokes carry the city and nobody answers. At the wreck his own voice comes out of Kayla's walkie lying
  in rainwater (`cutscenes.md`, scene 8). In the flight, holding the talk button is the climb monologue. In Chapter 8,
  once she is woken, he gives her walkie back so she can talk from her pod (canon 10), and the radio carries her again
  through the hold.
- **The tape logger.** Priya's tape logger on the 1962 base station records the channel whenever it is open; the
  walkie itself records nothing. In June Kayla plays its tape of his last words and his camcorder clips, longer the
  more he stayed on the line (story, epilogue).
- **Listening at a door, duct or ceiling tile.** Hold a button: the world ducks 10 dB, the other side loses its wall
  filter, and the caption names what is there (canon 5). The cost is time and a fixed view.
- **The alien gun** (canon 13). Its charge whine rises with stored energy, so the last shot is heard, not read; empty,
  a dying sigh and no shot. The shot (90 dB) is heard a block away; a bolt to a neck plate in a later takedown is 50.
  At a pylon, the recharge hum is one the Patrol notices within 30 m (canon 13).
- **The scanner** (canon 13): a 40 dB chirp the Patrol hears.
- **The school bell.** Its timer runs on its own lead-acid battery (canon 6) and still rings through every floor at
  in-game times that change each playthrough (systems, small mechanic 14). Its 95 dB, 6 s ring covers Danny's noise and
  draws Listeners to the nearest speaker: a timing puzzle. A printed schedule in the office tells careful players when.
  The PA chimes of Halftime Draw are a separate use of the same rack and need electrical closet 1's power (world).

---

## 7. Voices

### 7.1 Who speaks the people (the owner's decision 8: real recordings with friends)

| Route | What it is | Notes |
|---|---|---|
| The working track, now | the voices chosen for the earlier game (Danny 3, Kayla 3, Marcus 2, the Monster 5 whisper), open models on his PC, every scene voiced from the start | the pipeline exists; MIT and Apache licences allow a sale; built from stock voices, no real person; the main model is no longer maintained, so its version is pinned; Steam asks for AI voices to be stated |
| The finished game | real recordings by the owner and people he knows replace the main cast when they are ready | best at the sad scenes: real breath, real teenage speech. Each person signs a release first (a parent signs too for anyone under 18) covering the voice, the hunter's altered version and use for the game's life. A USB microphone costs about $60 to $150, or a phone in a blanket-lined closet costs nothing; nothing is bought without his yes |
| A paid voice service | described only | roughly $300 to $1,000 for the script over a few months; free tiers give no commercial rights; never used without his yes |

**What is recorded first,** if time is short (canon 14): the cutscenes, Kayla's key radio lines and the whisper
sources, in two batches after the grey pass. The voice plan (voices.md) sets the bar, the routes, the checks and the
pages his ear judges; every human voice is meant to pass for a recorded person ("thhe voices gotta be really
realisitc"). No real person's voice is copied without signed consent. With real voices, the hunter's whispers and the
Mimics' calls come from each actor's own takes, recorded for that purpose (a Mimic line is said "like a recording").
The Patrol and the ship are not voices: they are tones (4, 8).

### 7.2 How many lines, roughly

**The script holds about 1,200 lines** (canon 14), so recording stays possible. A rough split, scaled from the first
edition's to that cap (the story document's script sets the real counts): Danny about 350 (about 850 takes with his
three states); Kayla about 300 (the radio through Chapters 1 to 5, Chapter 4 in person, Chapter 8, the epilogue);
Kessler and Gus about 80 each; Priya, Mari, Owen and Ray about 50 each; Marcus and Caleb about 25 between them; Mimic
calls about 30; the announcer, the IT technician, the laundromat boy and the rescue crew about 50. That is **about an
hour of finished speech**, plus breaths, efforts and screams. The hunter needs no new lines (about 150 whisper
sentences cut from these). The Patrol and the ship's countdown (in alien numerals) are about 300 short tone calls
built from the glyph tones (8), not voices.

**Language** (the owner's decision 9): real but rationed, strong words at about eight peaks, never slurs (canon 14).
Each strong line is also recorded as a separate swappable take.

---

## 8. The score

- **Instruments:** for people, things a school has: a slightly detuned upright piano, a cheap acoustic guitar, one
  voice humming. For dread: bowed metal, stretched recordings of the school (radiator pipes, lockers, the PA hum),
  breath. For the aliens: deep drones and slowed recordings of their machines. All of it real recordings (map part 8).
- **Themes:** Danny-and-Kayla, a two-note rising figure, first heard warm in the prologue's walk with Kayla, before
  the ship. The group: a hymn-like progression from Mari's camp song. Each survivor: a three or four note tag (Gus
  whistles his, Kessler hums hers, Mari's is the camp song's hook). The hunter has no theme and never hums: its sound is
  its steps, its whisper and its silence.
- **The symbol language has a sound:** every glyph has a tone (canon 2, 12). Panels chime them, the Patrol's scanners
  and armour call in them, and at the core the self-destruct sounds each right symbol's tone, so "ship all end" plays a
  phrase that resolves into the Danny-and-Kayla figure (canon 12): an Easter egg for the ear. The countdown runs in
  alien numerals, its tones the number glyphs'.
- **One key and tempo family per chapter,** so its layers never clash.
- **When there is none:** in Explore (most of the game), whenever the hunter is near (chases by it included), while
  hidden, after a release, in the sacred silences and in the hold. Chase cues only when Danny is seen, and only by the
  other kinds. Inside cutscenes the only music is what `cutscenes.md` puts there (Mari's guitar in the room, a guitar
  ringing by itself, Song 3's first chord).

---

## 9. The three songs

All three grow from one **camp song**, a short original tune Mari plays on a cheap guitar in the shelter at night
(Chapter 1); she teaches Danny its three chords after Chapter 2. Mari is taken in Chapter 3, every time, and after
that the shelter is quiet at night, until Owen plays it, badly (story). Its hook returns in every song below. The
lyrics are written fresh; no line or melody from any existing song.

1. **"The Lift," Chapter 5.** The helicopter lifts off from the roof; Danny and Kayla sit side by side; the player can
   only look round at the city below. The song is the score's voice, or Owen humming if he boarded (canon 14), and
   reaches its first chorus. **The missile cuts it mid-line**, then the 4 s silence of 2.3.
2. **"The Climb," Chapter 7.** After the pursuers fall away, the cloud segment of the flight (canon 13): easy steering
   up through cloud into the mothership's shadow, alone. The full song, while the player still steers. Holding the
   talk button is Danny's monologue to Kayla, who cannot hear; the talking stays clear over the song. Out of the cloud
   the song ends, and in the gap come a deep hum and the far murmur of thousands of sleeping voices (`cutscenes.md`,
   part 3).
3. **"Stay Behind," the epilogue.** **The hold has no music.** The song begins at the gate in June (scene 12: on one
   chord of Mari's old guitar if Owen is there; on one voice, with no chord, in "Only her"; `cutscenes.md` wins), and
   the credits roll over play as Kayla walks through. Written from Kayla's side and sung softly: more voices join the
   chorus the more of the group lived; it is sung alone in "Only her".

**How they are made** (the owner's decision 8: he and people he knows sing the songs; decision 10: maybe sold later):

| Route | Rights | Use |
|---|---|---|
| a. Lyrics written fresh (by him, if he wants them truly his); a person sings (himself, or someone he knows on a signed release) over a backing we make from our recordings and free instruments | lowest risk; fully ours; human lyrics and melody are protected | **the finished songs** |
| b. An AI backing from a paid music plan | commercial use only for songs downloaded while subscribed and within the allowance; the AI parts have no copyright; Steam statement; a plan is bought only with his yes | drafts only, to fix a melody before a person sings it |
| c. A fully AI song | some services' cheaper plans exclude games sold on several stores; an unprotected song can be copied by anyone | not used |

An open music model on his PC may also make drafts that fix a melody. Udio is not usable (downloads are off). No real
artist's song or melody is copied.

---

## 10. Sources for effects

**Every sound in the game is a real recording, processed if needed, and every file is traced to its source and
licence** (map part 8; owner-checklist line 50). Every source is picked with terms that allow a sale (the owner's
decision 10).
- **Carried over:** the 325 recorded sounds of the earlier game, in the traced CC0 recording store, with its rule that
  every file is traced to its CC0 page (docs/SOUND.md); the voice pipeline and chosen voices (pinned); the Monster 5
  whisper process; the speech recogniser for checks. Dropped: the web game's laptop-speaker rules.
- **Added:** the Sonniss GDC bundles (royalty-free for games; licence read before any import); Freesound CC0 only;
  Fab packs after reading each licence. Nothing non-commercial.
- **Recorded by the owner at home** (map part 8): a phone set to uncompressed, airplane mode, 20 to 30 cm away:
  kitchen foley for the creature gore and the hunter's catch (celery, cabbage, wet cloth, raw chicken), his breathing
  at four intensities, backpack and cloth, doors, keys, a bin lid, footsteps, room echoes (a balloon pop). A list is
  supplied.
- **Designed here, from real recordings:** everything alien (the landing and hatch, the fighter's engine, the
  mothership's hull, the Holds' sleeping breath and murmur under a membrane, the self-destruct), every creature, the
  Patrol's tones, the generator, the bell and PA. Every designed file lists the recordings it was built from and the
  processing, with the date.
- **Studied, never copied** (owner-checklist line 49): what the key sounds of the five named games do (footsteps,
  breath, the scare, glass, doors) is studied and rebuilt from licensed recordings; the sound list cites the game
  studied for each, and no file of theirs is used.

---

## 11. How audio is checked when the builder cannot hear

1. **Event log:** every sound and noise event to CSV (time, asset, position, path distance, occlusion, volume, state,
   Threat, who heard it). Tests: no creature sound without a caption; no state change within 4 s; at most one loud
   stinger per 10 minutes outside chases; no music while the hunter is within its Threat radius; the hunter never
   repeats a fragment in a chapter, never whispers without its source lines in the heard bank, never plays from
   anywhere but its own position, never beyond about 10 m of walked path, never in a cutscene except scene 3 (The
   Board), never in a grief scene, the shelter or the epilogue, at most one whisper in each chase, and never in the same minute as a Mimic's voice; Kayla's voice used by something else exactly
   twice in a playthrough and never on the radio; the radio never carries a creature; every sound file has a traced
   source.
2. **Captured mixes,** measured: about -23 LUFS over 30 minutes, true peak under -1 dB, scares 12 to 16 LU above the
   previous 10 s, dialogue 14 to 18 dB above beds (in cutscenes too); spectra (the Brute's energy under 60 Hz; treble
   lost through a closed door; no sound that is a bare tone or sits mostly in the high pitches without body,
   owner-checklist line 44; the click check, owner-checklist line 48: no sound with a sharp, thin transient and no
   body, the generator's ballast, the kitchen timer's run and the Brute's tap included).
3. **Speech recognition** on every line and cutscene mix: clean under 5 % word error, hunter whispers under 10 %, every
   name right (the voice gates: voices.md 5.3).
4. **Direction:** test tones from known bearings, captured, checked left against right and front against behind.
5. **The noise table:** each creature in a test room reacts at the predicted distance, within 10 %: headless on the
   room-portal graph, and in the engine overnight (production).

**Four listening sessions** for the owner, 10 to 15 minutes each, on his PC with headphones, each with five
questions (what scared you; what sounded fake or robotic; what was too loud or quiet; could you tell where it came
from; what would you change): (1) the first slice: the shelter, the tunnel, the hunter's steps, whisper and catch, the
generator failing, one Dark Dweller; (2) voices and the first song draft: the voice pages of voices.md part 9 (the
blind pairs, the auditions, the hunter's "who is it, and is it creepy?") and the camp song's melody; (3) Chapter 1 end
to end; (4) the final mix with all three songs. Alongside them, **the sound board** (owner-checklist lines 44 to 51):
each key sound (the hunter's footsteps, breath and cries, the scare, glass, doors, lockers) beside a reference clip of
the studied game's sound of the same kind; he is the final judge.

---

## Decided

- **Voices** (decision 8): the voices chosen for the earlier game are the working track; real recordings by him and
  people he knows replace the main cast when ready, the songs included (7.1, 9).
- **Language** (decision 9): real but rationed, strong words at about eight peaks, never slurs (7.2).
- **Sold or not** (decision 10): maybe sold later; every voice, music and sound source is picked with terms that allow
  a sale, and nothing is bought without his yes each time (7.1, 9, 10).
- **The aliens** (decision 1): the Voice Collectors; every glyph has a tone, the Patrol speak only in tones, the
  whisper is stolen voices, the Holds murmur (4, 8, 10).
- **Kayla** (decision 3): her voice is used twice, a Mimic in Chapter 4 and the hunter in Chapter 6, never on the
  radio (4).
- **The Mark** (decision 4): the hunter's last whisper, in the hold, is Danny's own promise, through the Mark (4).
- **Marcus** (decision 5): taken at halftime; the first familiar whisper after the announcer and the strangers (4).
- **Restarts** (decision 2): after a catch or a maul, silence, then Danny is back close by in under 5 s (4).
- **What gets finished first** (decision 7): the listening sessions follow the slice, Chapter 1, the whole game in
  grey, then chapter by chapter (11).
- **Co-op** (decision 12): the mix is single-player; nothing in it blocks co-op later as its own mode.
- **The evening event:** the first home basketball game; the announcer's halftime words are the first whispers (4).
- **The hunter says his name and mocks him** only with the stolen voices; no voice of its own (settled by his words).
- **Settled by the designers:** thin air in low gravity (5); the noise ring on by default on Story only (3); home
  recordings and kitchen foley (10); the hunter's catch is the voice-pulling scene (4).

## Open, to be put to him later

- **His ear:** each listening session and the sound board (11), and the voice pages of voices.md: whether the voices
  pass for real people, whether the hunter's whisper is creepy enough, whether anything sounds fake or robotic.
- **The song lyrics:** whether he writes them himself, and who sings.
- **Who records, and when:** he and the people he asks, each with a signed release; until then the working track
  stands.
- **Any purchase** (a microphone, a music plan for drafts, a singer): put to him each time it is needed.
- **The whisper in a chase:** his checklist (line 57) asks for some lines "if he is chasing you"; his words rank above
  the map, so canon 8 now has one whisper per chase, at the close, and silence once it has noticed him outside chases.
  Put to him with this as the recommendation.
