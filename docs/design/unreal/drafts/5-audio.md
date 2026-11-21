# Stay Behind: sound, voice and music direction (draft 5, audio)

Builds on research 06 (audio and music plan) and 04 (voices, songs) and does not repeat their engine notes.
**[proposal]** marks anything not settled; the points that change the game are collected at the end. Patterns from
the model games only: no sound, line, melody or voice of theirs is copied or imitated.

## 1. The sound of the game

What the player should remember hearing:

1. **The generator.** A low steady hum, a fluorescent buzz, a ballast tick. It is home. When it coughs, the stomach
   drops; when it winds down over three seconds, the silence after is the loudest thing in the basement.
2. **Kayla on the radio.** A real, tired teenage voice through walkie-talkie static, the hum faintly behind her. The
   one warm sound outside the safe room. Nothing ever fakes it.
3. **The hunter's whisper.** Close and dry, in the voices of people Danny knew, saying their own real words in the
   wrong order, always from where it really is. When it stops, it has noticed you.
4. **Danny's body.** Breath, a heartbeat when hidden, a step on glass he did not see.
5. **One sound rule per floor, learned in a minute:** the Listeners' clicking pings, the creak of a Still One that
   moved while you looked away, a known voice calling plainly down the hall, the dry rush of the Swarm in a vent,
   the Patrol's call and answer, the Brute's floor-shaking steps.
6. **Three songs** at the end of long held breaths, the first cut off mid-line by a missile.

The game is mostly quiet. Music is rare and never plays when the hunter is close. The world, the creatures and
Danny carry the fear; the score carries the grief.

## 2. Mix states, threat, silence and the hum

### 2.1 One threat value
`Threat (0-1) = max over creatures of (Weight x Awareness x Closeness)`, ten times a second.
Awareness: 0 unaware, 0.3 heard something, 0.6 searching, 1.0 has seen Danny. Closeness: `1 - path distance /
Radius`, clamped. Path distance is the walking route through doors and vents, the same number used for hearing and
occlusion. Radius / weight: hunter 40 m / 1.0; Brute 35 / 0.9; Patrol 30 / 0.8; Listeners, Mimics, Dark Dwellers,
Swarm 25 / 0.7; Still Ones 15 / 0.7.

### 2.2 The states
A state holds at least 4 s; music changes on the next beat (at most 0.5 s), except that the hunter coming into view
cuts at once.

| State | Enters when | Music | Mix |
|---|---|---|---|
| Home | basement safe room, power on | camp song or group theme: the only warm harmony in the game | world -6 dB, voices forward, hum audible |
| Haven | a small save point (P3) | none; one warm diegetic sound (2.4) | world -4 dB |
| Explore | Threat < 0.2 for 60 s | silence; at most one sparse texture every 4-6 min | room tone, world full |
| Unease | Threat 0.2-0.4 | one low drone in the chapter key | ambience -3 dB |
| Near | Threat 0.4-0.7 | drone + slow pulse; **nothing if the source is the hunter** | ambience -6, Danny +2, creature +3 |
| Hidden | in a hiding place, creature within 15 m | music drains to 0 over 2 s | world low-passed to 4 kHz; breath, heartbeat up |
| Hunted | Danny seen | that creature's chase cue | ambience -10, radio muted |
| Release | 8 s clear after Hunted/Hidden | one low resolving tone, then 20-40 s of silence | back to Explore |
| Grief / Cutscene | scripted | written cue on the timeline | per scene |

### 2.3 Silence as a tool
Every planned silence is followed within 10 s by one piece of information (a step, a breath, a door). The sacred
silences, which no stinger may cover: the hunter's whisper stopping; the generator winding down; a watched Still
One; 4 s of nothing after the helicopter crash, then ringing ears, then the burning city fading in; the radio after
Kayla is taken (Chapters 6 to 8 it gives only static; Danny can still press the button; nobody answers); the hold at
the self-destruct (section 9).

### 2.4 The hum as safety
- The generator is a MetaSound with Load and Fuel inputs. Under 25 % fuel it coughs every 30 to 50 s; under 8 % it
  stutters and dips. The player hears the fuel level across the basement and needs no gauge.
- It carries 40 m into the tunnels through the pipes, so in Chapter 1 the hum fading behind you means leaving safety.
- It sits faintly behind Kayla on the radio. If the power fails while Danny is upstairs, her background goes silent
  before she says a word.
- **[proposal]** Each small save point (P3) has one friendly mechanical sound of its own: a wind-up clock, a vending
  machine's compressor, an emergency light's ballast in the city, an alien air pump on the mothership. The rule the
  player learns: a steady, friendly hum means you can save here.

## 3. The noise table

Every sound Danny makes has one number, **L, its level in dB at 1 m**. L sets how loud it plays, which creatures
hear it and what the screen may show. There are no other hearing values in the game.

**Steps: L = gait + surface + debris**

| Gait (linoleum) | L | Surface | add | Debris, that step | add |
|---|---|---|---|---|---|
| Crouch | 30 | carpet, books, acoustic tile, alien membrane | -6 / -8 | paper | +2 |
| Walk | 42 | gym wood, concrete, asphalt | 0 | grit, plaster | +5 |
| Sprint | 58 | ceramic tile, wet floor, hard alien deck | +3 / +4 | can (then rolls at 45) | +10 |
| Land from a drop | 62 | metal stair, grate, vent | +9 | broken glass | +14 |

A full backpack adds +2 to every step. Low-gravity push-off: 40.

**Actions**

| Action | L | Action | L |
|---|---|---|---|
| Door eased / normal / slammed | 35 / 45 / 68 | Breath while hiding, not held | 22 |
| Locker in or out, slow / fast | 40 / 55 | Gasp when a held breath runs out | 50 |
| Vent crawl, per move | 45 | Danny whispers / speaks / shouts | 30 / 50 / 75 |
| Item dropped | 50 | Radio knob 1 / 2 / 3, incoming voice | 35 / 45 / 55 |
| Thrown book / can / bottle, at impact | 55 / 60 / 72 | Push-to-talk click | 30 |
| Generator pull-start / running | 80 / 70 | Alien gun charged and raised / shot | 40 / 90 |
| School bell, at each speaker | 95 | Injured cough | 50 |

**What creatures hear:** `R = L - 20 log10(path distance) - occlusion` (distance at least 1 m). Occlusion: open
doorway 0, closed door 12, wall 20, floor or ceiling 25, Danny in a locker or under a desk 8. A creature reacts when
R reaches its threshold T.

| Creature | T | Walk on lino heard at | Sprint heard at | Note |
|---|---|---|---|---|
| Listeners | 18 | 16 m | 100 m (walls stop it) | crouch on carpet: 2 m |
| Dark Dwellers | 28 | 5 m | 32 m | only in darkness |
| Hunter | 30 | 4 m | 25 m | also sets its presence clock |
| Mimics, Swarm | 34 | 2.5 m | 16 m | Swarm also senses warmth and movement |
| Patrol | 36 | 2 m | 13 m | |
| Brute | 44 | under 1 m | 5 m | hunts by smell and sight |
| Still Ones | none | | | ignore sound |

**What the player hears:** Danny's sounds play at `L - 58` dB relative to the reference (a sprint step on
linoleum), so 6 dB in the table is 6 dB in the ear and the ear learns the scale. Creature sounds use the same
distance law and occlusion and play from the opening the path comes through (portal occlusion, research 06 3.4).

**What the screen may show:** captions always, with direction ("[slow clicking, left, behind the wall]").
**[proposal, decision 8]** An optional noise ring: for 1 s, a faint ring on the floor whose radius is where the most
sensitive creature on the floor would hear that sound, `10^((L - T - occlusion)/20)`. It never shows creatures.

**The hunter's presence clock** keeps the owner's numbers: a beat (heard close, glimpsed, a near miss) every 15 to
20 s sprinting, 30 s walking, 60 s crouching. At most one beat in four is a whisper; the rest are body sounds.

## 4. The creatures' sound worlds

Each kind has a far tell (through walls, muffled), a near tell (clear, placed), an alert tell and a catch, never
shared between kinds, all designed fresh.

**The hunter (everywhere).** Far: heavy, slow steps heard from far off and through floors, as the owner asked,
whenever it walks upright in a tall space. Where the ceiling is lower than it (P7) it stoops and folds: long joints
creaking, cloth dragging on ceiling tiles, knuckles knocking between slow steps. In vents: a many-point patter and
flexing sheet metal. Near: a slow breath in through something narrow; the whisper clear. Alert: the whisper stops
mid-word; two seconds of nothing; then its steps turn toward you. Catch (it TAKES, P2): no stinger; one long breath
in right at Danny's ear, his breath muffled, his heels dragging, then the sound cuts with the picture to 2 s of black
silence. Nothing graphic.

**The whisper chain (P1).**
1. *Capture:* every line a character speaks is aligned word by word when made. When a line plays in a save, its
   words enter that save's "heard" bank.
2. *Steal:* when a person is taken, their heard words become the hunter's. Each whisper is a short sentence (two to
   six words), written in advance from words that person really said, with its source lines listed; it can play only
   if all of them are in the bank. A survivor who said "Don't go down there alone, Danny" and "I'll wait for you"
   becomes "Danny... wait... alone... down there."
3. *Process:* the close dry whisper with a breath before it that the owner chose, applied to each victim's own voice:
   their voice character kept so the player knows who it was; uneven timing; one breath where nobody would breathe;
   a faint second copy 12 dB down and 40 ms late; a short frozen tail on the last word.
4. *Place:* from the hunter's real position, through portal occlusion. Its direction is always honest.
5. *Rules:* only whispers, never a full voice; never asks for help or calls from ahead; never Kayla while she is safe;
   never the radio; no sentence repeated within a chapter; at most one every 2 to 3 minutes; the person Danny left
   behind is heard most; never in the epilogue.
6. *Whose voices:* in the prologue and Chapter 1, strangers from the evening event and voicemails on dropped phones;
   then each survivor lost; Kayla from Chapter 6, after she is taken; once on the mothership, Danny's own Chapter 1
   promise to get everyone out **[proposal, for the story draft]**.

**Dark Dwellers (basement, power out).** Far: wet clicking and a scrape on concrete. Near: the clicks speed up and
spread. Alert: in the torch beam they freeze silent; a faint hiss rises if the beam holds. Clicks mean dark; silence
in the beam means it is right there. Catch: MAUL.

**Listeners (first floor, blind).** A dampened floor where every sound you make stands out. Far: a soft tongue click
sweeping the room. Near: the pings aim at your last noise. Alert: a sharp double click and a run to it. A thrown
bottle (72) beats your steps. Catch: MAUL.

**Still Ones (second floor).** Their moves must be heard or the rule is unfair: plaster and ceramic grinding, a joint
crack, a weight shift, precisely placed (headphone 3D sound matters most here). Watched: true silence. A creak behind
you means one moved. Catch: MAUL.

**Mimics (third floor).** A full, plain voice, from ahead, asking: "Danny? Over here, it's safe." Tells: the same line
with exactly the same timing each time, a breath in the wrong place, steps slightly too even. The test is the radio:
Kayla can say who is really alive. They use voices the player has heard. Catch: MAUL.

**The Swarm (fourth floor).** A granular texture whose density is the count and whose pitch rises when agitated,
placed above you. Alert: the mass moves as one, a dry rush along the vent. Catch: MAUL.

**The Patrol (city).** Speech built from the symbol syllables (section 8); cadence tells state: slow call and answer
searching, one sharp word suspicious, fast overlapping calls engaged. Armour creak, weapon hum. Catch (TAKES): a
stun crackle, Danny's breath under a hood, the drag, the cut.

**The Brute (mothership).** Steps with energy under 60 Hz plus controller rumble, heard from far off; breath like a
bellows. Before tearing a hiding place open it taps and sniffs it for 2 to 3 s: its fairness window. Catch: MAUL,
the loudest moment in the game, capped by "reduce sudden loud sounds".

MAUL catches are graphic, wet and fast (kitchen foley), cut at the peak, then silence and a quick return to the save.

## 5. Danny's body

- **Breath** in four intensities from exertion and fear; **heartbeat** only above Fear 0.6 and when hidden.
- **Breath-hold** while hidden removes the 22 dB breath; at 10 s his chest strains audibly; at 14 s he gasps (50 dB).
  Injured or winded: 7 s.
- **Lines follow his state:** calm, winded and scared takes; crouched, the whispered take (and a 30 dB noise, not 50).
- **Injury:** a catch in the breath each step, an occasional cough (50 dB). Medicine audibly settles his breath over
  20 s, which is how the player knows it worked.
- **Low gravity [proposal, decision 6]:** thin air: sounds above 5 kHz thin out, steps soften, and his breath and
  heartbeat, heard through his body, come forward.

## 6. The devices

- **The radio.** Gus's old analogue walkie-talkies. Knob 1 to 3 trades information for noise (35 / 45 / 55 dB);
  holding push-to-talk mutes the speaker. When Danny transmits, Kayla hears his side, so a creature near him makes her
  go quiet: a second warning. Static grows with height and nearness to the mothership. It never tracks creatures.
- **Phones (P4) [proposal, for the story draft]:** the mothership's field floods digital signals. Phones show no
  signal, their screens drop out every few seconds, and a phone left on picks up the field as a rhythmic buzz through
  its own speaker (38 dB). A dropped phone on the floor is a sound tell and a noise risk; one in Danny's pocket would
  give him away. Analogue radios get through with static.
- **Listening at a door, vent or ceiling tile.** Hold a button: the world ducks 10 dB, the other side loses its wall
  filter, and the caption names what is there. The cost is time and a fixed view.
- **The alien gun.** Its charge whine rises with stored energy, so the last shot is heard, not read; empty, a dry
  click and a dying sigh.
- **The school bell.** **[proposal]** It runs on its battery timer after the fall, ringing through every floor at
  in-game times that change each playthrough. Its 95 dB, 6 s ring covers Danny's noise and draws Listeners to the
  nearest speaker: a timing puzzle. A printed schedule in the office tells careful players when.

## 7. Voices

### 7.1 Who speaks the people [decision 1]

| Option | Cost | Quality | Rights | Effort |
|---|---|---|---|---|
| A. The voices chosen for the earlier game (Danny 3, Kayla 3, Marcus 2, the Monster 5 whisper), open models on his PC | free | accepted as "good"; weakest at crying, breaking and screaming | MIT and Apache licences allow commercial use; built from stock voices, no real person; Steam asks for AI voices to be stated; the main model is no longer maintained, so its version is pinned | lowest: the pipeline exists |
| B. A paid voice service | roughly $300 to $1,000 for the script over a few months; free tiers give no commercial rights | wider emotion, still synthetic at the hardest moments | game use to be checked in its terms first; Steam statement | medium |
| C. Real recordings by the owner and people he knows | $60 to $150 for a USB microphone, or a phone in a blanket-lined closet | best at the sad scenes: real breath, real teenage speech | cleanest; each person signs a release (a parent signs for anyone under 18) covering the voice, the hunter's altered version and use for the game's life | highest: scheduling, a quiet room, directing |

**Recommendation:** A now as the working track for every scene; then real recordings (C) for the core cast if he and
people he knows want to, keeping A for small parts; B only if recordings cannot happen. No real person's voice is
copied without signed consent. With real voices, the hunter's whispers and Mimic calls come from each actor's own
takes, recorded for that purpose.

### 7.2 How many lines, roughly (final counts come from the story and chapter drafts)
Danny 900 (about 2,200 takes with state variants); Kayla 800 (radio through Chapters 1 to 5, key scenes, the
epilogue); the teacher 250; Gus 250; Marcus, if one of the six, 200; three other survivors 130 each; Mimic calls 100;
strangers, the announcer, voicemails and the rescue crew 190. **About 3,100 lines, 2 to 2.5 hours of finished
speech**, plus breaths, efforts and screams. The hunter needs no new lines (about 150 whisper sentences cut from
these); the Patrol and the ship's countdown are about 300 short calls built from symbol syllables. Strong language
(still open for the owner) is recorded as a separate swappable take.

## 8. The score

- **Instruments:** for people, things a school has: a slightly detuned upright piano, a cheap acoustic guitar, one
  voice humming. For dread: bowed metal, stretched recordings of the school (radiator pipes, lockers, the PA hum),
  breath. For the aliens: deep drones and slowed recordings of their machines.
- **Themes:** Danny-and-Kayla, a two-note rising figure, first heard warm at the evening event before the ship. The
  group: a hymn-like progression from the camp song. Each survivor: a three or four note tag (Gus whistles his, the
  teacher hums hers); after someone is taken, the hunter sometimes hums their tag wrongly. The hunter has no theme;
  its sound is silence.
- **The symbol language has a sound:** each symbol a pitch and a syllable. Panels chime them, the Patrol speaks them,
  and the self-destruct confirms each correct symbol with its tone, so the last puzzle plays a phrase that resolves
  into the Danny-and-Kayla figure: an Easter egg for the ear.
- **One key and tempo family per chapter,** so its layers never clash.
- **When there is none:** in Explore (most of the game), whenever the hunter is near, while hidden, after a release,
  and in the sacred silences. Chase cues only when Danny is seen.

## 9. The three songs [decision 2]

All three grow from one **camp song**, a short original tune a survivor plays on a guitar in the safe room at night
(which survivor is the story draft's choice). If that survivor is lost, the safe room is quiet at night.

1. **"The lift," Chapter 5.** The helicopter lifts off; Danny and Kayla sit side by side; the player can only look
   round at the burning city. The song plays from a survivor's phone (a downloaded song still plays with no signal)
   and reaches its first chorus. The missile cuts it mid-line.
2. **"The climb," Chapter 7.** After the pursuers are lost, 2 to 3 minutes of easy steering up through cloud into the
   mothership's shadow, alone. The full song, while the player still flies.
3. **"Stay Behind," Chapter 8 into the epilogue.** It begins as Danny holds the self-destruct (the player holds the
   button too) and, unlike the first, does not stop for the explosion; it carries Kayla's pod down and ends as she
   lands. The credits reprise it: more voices in the chorus if more of the group lived, one if few did.

| How it is made | Rights |
|---|---|
| a. The owner writes the lyrics; a person sings (himself, someone he knows on a signed release, or a hired singer) over a backing we make from our recordings and free instruments | lowest risk; fully ours; human lyrics and melody are protected |
| b. His lyrics over an AI backing from a paid music plan | medium: commercial use only for songs downloaded while subscribed and within the allowance; the AI parts have no copyright; Steam statement |
| c. A fully AI song | medium to high: cheaper plans of some services exclude games sold on several stores; an unprotected song can be copied by anyone |

Udio is not usable (downloads are off). No real artist's song or melody is copied. Recommendation: a, with b or an
open model on his PC only for drafts that fix the melody before a person sings it.

## 10. Sources for effects

- **Carried over:** the traced CC0 recording store and its rule that every file is traced to its CC0 page
  (docs/SOUND.md); the voice pipeline and chosen voices (pinned); the Monster 5 whisper process; the speech
  recogniser for checks. Dropped: the web game's laptop-speaker rules.
- **Added:** the Sonniss GDC bundles (royalty-free for games; licence read before any import); Freesound CC0 only;
  Fab packs after reading each licence. Nothing non-commercial.
- **Recorded by the owner at home [decision 7]:** a phone set to uncompressed, airplane mode, 20 to 30 cm away:
  kitchen foley for creature gore (celery, cabbage, wet cloth, raw chicken), his breathing at four intensities,
  backpack and cloth, doors, keys, a bin lid, footsteps, room echoes (a balloon pop). A list is supplied.
- **Made fresh:** everything alien (the landing and hatch, the fighter's engine, the mothership's hull and the
  holding halls' sleeping breath under a membrane, the self-destruct), every creature, the generator, the bell and
  PA. Every generated file is logged with tool, prompt and date.

## 11. How audio is checked when the builder cannot hear

1. **Event log:** every sound and noise event to CSV (time, asset, position, path distance, occlusion, volume, state,
   Threat, who heard it). Tests: no creature sound without a caption; no state change within 4 s; at most one loud
   stinger per 10 minutes outside chases; the hunter never repeats a sentence in a chapter, never whispers without its
   source lines in the heard bank, never plays from anywhere but its own position; the radio never carries a creature.
2. **Captured mixes,** measured: about -23 LUFS over 30 minutes, true peak under -1 dB, scares 12 to 16 LU above the
   previous 10 s, dialogue 14 to 18 dB above beds; spectra (the Brute's energy under 60 Hz; treble lost through a
   closed door).
3. **Speech recognition** on every line and cutscene mix: clean under 5 % word error, hunter whispers under 10 %.
4. **Direction:** test tones from known bearings, captured, checked left against right and front against behind.
5. **The noise table:** each creature in a test room reacts at the predicted distance, within 10 %.

**Four listening sessions** for the owner, 10 to 15 minutes each, on his PC with headphones, each with five
questions (what scared you; what sounded fake or robotic; what was too loud or quiet; could you tell where it came
from; what would you change): (1) the first slice: safe room, tunnel, the hunter, the generator failing; (2) voices
and the first song draft: the chosen voices, real ones if recorded, the camp song's melody; (3) Chapter 1 end to end;
(4) the final mix with all three songs.

## Decisions for the owner

1. **Who voices the people?** (a) the voices chosen for the earlier game, for everything; (b) real recordings by you
   and people you know for the main cast, the chosen voices for small parts; (c) a paid voice service.
   **Recommend (b), with (a) as the working track now and the fallback:** real voices make the sad scenes land, and
   starting with (a) loses nothing.
2. **How are the three songs made?** (a) your lyrics, sung by a person over our own backing; (b) your lyrics over an
   AI backing on a paid plan; (c) fully AI. **Recommend (a):** the only route that is fully yours and sounds most human.
3. **Will the game ever be sold or put on a store, and is any spending allowed (a microphone, a plan, a singer)?**
   (a) free, nothing bought; (b) maybe sold later, small spending with your okay; (c) sold. **Recommend answering
   before voices and songs are made:** every tool's terms depend on it.
4. **May a Mimic ever use Kayla's voice in person (never on the radio)?** (a) never; (b) once, on the third floor,
   while the real Kayla on the radio says she is in the safe room; (c) often. **Recommend (b):** one scare where the
   radio is the proof makes the radio matter more.
5. **Does the hunter speak only in stolen words (P1), or also in a voice of its own?** (a) only stolen words, in the
   whisper you chose; (b) plus a few lines of its own (your name, mocking). **Recommend (a):** the name and the
   mocking come from what people really said, which is creepier and keeps its whisper an honest warning.
6. **In the low-gravity stretch, is there air?** (a) thin air; (b) none, only sounds through Danny's body.
   **Recommend (a):** the creatures stay audible, which keeps it fair.
7. **May you record some sounds at home with your phone (a list is supplied)?** (a) yes; (b) no, library sounds only.
   **Recommend (a):** your breathing and kitchen sounds make the gore and Danny's body sound real and ours.
8. **The on-screen noise ring:** (a) off by default, on in the Assist preset; (b) on by default; (c) never.
   **Recommend (a):** the ears do the work, and anyone finding it too hard can turn it on.
