# Stay Behind: audio and music plan (Unreal Engine 5.8)

Research report, 21 Nov 2026. Builds on docs/design/research/sound.md (horror sound, voices, the cutscene mix, testing
without a listener) and docs/SOUND.md (the traced CC0 library and its audit). It does not repeat them. It moves them into
a native engine and the agreed map (requirements.md sections 7 and 8).

Tags: [checked: url] means a source found today states it. Most sources were read through search summaries because
WebFetch could not reach dev.epicgames.com or cdm.link from this session, so take exact wording as summary-level.
[from memory] means my own knowledge, not checked today. [I] means my inference or recommendation.
The rule throughout: we take PATTERNS, never CONTENT. No other game's sound, music, voice, line or melody is sampled,
imitated or re-created.

---

## 0. Findings first (each: what is true, then what to do)

Details and sources for every line are in the sections named.

1. UE 5.8 has the whole toolset built in: MetaSounds, Audio Modulation, submixes with convolution reverb, Audio
   Gameplay Volumes, Soundscape, Quartz, Harmonix. 5.8 adds Audio Insights loudness metering and event monitoring,
   Sequencer tracks for control buses, MetaSound output to any layout including ambisonics, and Tape Stop/Distortion
   nodes. **Do:** native audio only, no Wwise/FMOD (section 3).
2. Epic's March 2026 layoffs cut deep into its audio and music teams. **Do:** build on the stable core and test the
   risky pieces (hearing, HRTF plugin, sidechain) in the first test scene (3.5, 3.7).
3. A forum report says AI hearing (ReportNoiseEvent) does not fire in 5.8. **Do:** our own hearing subsystem fed by
   one noise table that also sets each sound's volume and the optional HUD ring (3.7).
4. Every horror reference turns sound into information and makes the player's own noise a risk (tracker, radio,
   camcorder microphone, generator tone, the Beast hearing a sprint). **Do:** three devices of our own: Kayla's
   radio (noisy, never a tracker), ear-to-the-door listening, the alien gun's charge whine; plus floor debris as a noise
   rule (1.3, 1.4).
5. Dead Space's remake makes the hero's body a sound system (heart, breath, delivery of lines). **Do:** Danny's
   BodyState drives breath, heartbeat, breath-hold and which take of a line plays (3.9).
6. RDR2's songs land on long, easy rides right after a heavy beat, with the player in control; its story score kept
   one key and tempo per piece so layers never clash. **Do:** songs on the helicopter lift (cut off by the missile),
   the last leg of the flight and the epilogue, all grown from one diegetic camp song (5).
7. The map has two voice-stealing threats (the hunter and the Mimics) and a radio voice. **Do:** hunter always
   whispers, Mimics always speak plainly, the radio is never faked, and the hunter only re-cuts words its victims said
   on screen (4.3).
8. Each creature needs a sound world the ear can name in a second. **Do:** far, near and alert tells per creature,
   nothing shared; silence as the hunter's worst sound (4.2).
9. Every AI music route has terms that bite a sold game (Suno download caps and weakened ownership, ElevenLabs
   self-serve excluding "Studio Games", Udio downloads off). **Do:** ask the player whether the game will be sold and
   whether he writes the lyrics before choosing a route (5.3, 8).
10. Sonniss GDC bundles are royalty-free for commercial use with no attribution (secondary sources; licence text still
    to read). **Do:** Sonniss + the traced CC0 store + the player's phone recordings; design all alien sound fresh (6).
11. No PC loudness standard exists. **Do:** about -23 LUFS integrated over a 30-minute session, -1 dBTP, and a
    Dynamic Range option for headphones, speakers and night (6.4).
12. An agent that cannot hear can still check almost everything. **Do:** a sound event log, captured submix renders
    measured for loudness and spectrum, speech recognition on lines and mixes, and four short listening sessions with
    the player (6.4).

---

## 1. What the references do that players feel (patterns -> Stay Behind)

### 1.1 Silence and dynamic range
- Pattern: a long quiet floor makes small sounds big. Alien: Isolation chose not to run music wall to wall
  (sound.md, Payne). Amnesia: The Bunker keeps a near-subliminal tone under the "safe" state so that its loss is a
  sound event in itself [checked: https://gamesradar.com/amnesia-the-bunker-uses-a-sound-illusion-from-scary-movies-and-mario-64-to-quietly-stress-you-out].
- Stay Behind: the **generator hum is the sound of safety**. While the basement has power, a low hum plays with a faint
  60 Hz-family buzz from the fluorescent tubes and an occasional ballast tick. When the power fails (the Dark Dwellers'
  rule), the hum winds down over about 3 s (the Harmonix Tape Stop node does this to the music bus at the same moment)
  and then there is real silence: room tone only. Our sound, the same idea. [I]
- Explore state: room tone plus world events, and score at most every few minutes. Silence alone is not a scare
  (sound.md, Phillips), so a silence must always be followed by information: a step, a breath, a door.

### 1.2 The creature heard before it is seen
- Pattern: vent scuttles and distant sounds send players to their tracker [checked: https://mcvuk.com/?p=70758]; the
  enemy is placed by sound first, by sight second.
- Stay Behind: every creature gets a **far tell** (audible through walls, low-passed), a **near tell** (clear,
  directional) and an **alert tell** (it has noticed you). They are fixed per creature and never shared (section 4.2).
  The hunter is the exception: its far tell is a whisper with no clear direction, so the player can never be sure.

### 1.3 Sound as information the player must use
- Pattern: Silent Hill 2's radio (proximity and awareness), Outlast 2's microphone (direction through walls, a level
  meter), Alien: Isolation's tracker (distance by beep rate, blind to a still creature or to height)
  [checked: https://videogameschronicle.com/review/silent-hill-2 (static near monsters, more once noticed, a visual
  option); https://digitaltrends.com/gaming/outlast-2-review (microphone through walls);
  https://pcgamer.com/the-audio-of-alien-isolation and https://www.wikiwand.com/en/articles/Alien_Isolation
  (beeps speed up; the creature is drawn to the tracker's sound)].
- Stay Behind, three devices of our own:
  1. **Kayla's walkie-talkie.** Kayla talks you through floors from the safe room (the map makes her a radio voice).
     Rule: incoming calls make noise. Holding the push-to-talk button mutes the speaker, and the speaker volume knob
     trades information against risk (squelch at full volume is a noise event at 2 to 4 m). It never tracks
     creatures. It is the human line.
  2. **Ear to the door / vent grille.** Hold a button at a door, vent or ceiling tile: the world ducks 10 dB, the
     sounds on the other side lose their wall low-pass for as long as you hold, and the subtitle line names what you
     hear ("[slow steps, moving left]"). The cost is time and a fixed camera, so you are exposed. This is the
     microphone pattern made physical, with no electronics. [I]
  3. **The alien gun (city and mothership).** Its charge whine rises with stored energy, so the player hears the last
     shots without looking at the HUD. The whine is also a noise event when the gun is charged and held up. [I]
- The school **bell system** still runs on its timer after the fall: at fixed in-game times it rings through every
  floor. It is a known, plannable noise event that creatures react to (Listeners rush to the nearest speaker), so it
  makes a timing puzzle: move during the bell. The ring times change each playthrough (the map's reshuffle rule). [I]

### 1.4 The sound the player makes is a risk
- Pattern: The Bunker's Beast comes to running, gunfire and traps [checked: https://pcgamer.com/amnesia-the-bunker-review, via summary];
  Alien: Isolation's mix favours the hero's own steps and clothing when sneaking (sound.md, Bullock).
- Stay Behind: one **noise table** for every player action (walk, crouch, sprint, land, door slow/fast, locker,
  drop, throw, radio, gun) multiplied by the floor surface and by **floor debris** (glass, cans, papers, ceiling-tile
  grit). The floor debris answers the player's request for detail "like the stuff on the floor": it is dressing and a
  rule. Glass glints in the torch beam so careful players can step around it. The same number drives the sound's
  volume, the creature's hearing and an optional HUD noise ring (section 3.7).

### 1.5 The room as an instrument
- Pattern: the space carries the fear: reverb and early reflections tell you how big and how empty a place is
  [from memory; general practice].
- Stay Behind: each space gets its own acoustic recipe. Tiled corridors: a short flutter echo between lockers. Gym and
  auditorium: a long tail that makes your own steps announce you. Stairwells: a vertical slap. Vents: a tight metallic
  box. Basement concrete: a long, dark tail. City canyon between towers: discrete slaps off facades. Mothership halls:
  enormous, low and slow, with no flutter (soft walls). Your footsteps are the first thing that tells you a room is
  big, which makes big rooms frightening to cross. [I]

### 1.6 Red Dead Redemption 2's music, for the story
- Story score held to one tempo and key per piece so layers stay clean; open-world score in 11 stems
  [checked: https://en.wikipedia.org/wiki/Music_of_Red_Dead_Redemption_2]; vocal songs on long rides at turning points
  ("Unshaken" on a ride back to camp, "That's the Way It Is" on the final ride)
  [checked: https://www.thegamer.com/red-dead-redemption-two-ten-best-songs-soundtrack/]; camp members sing around the
  fire and the camp's mood follows the gang [from memory].
- Stay Behind takes four patterns: themes for people (4.5), a diegetic camp song (5.2), the song over a long, easy
  ride with the player in control (5.1), and music that stops, used once, by a world event cutting a song mid-line.

---

## 2. Audio build order (first test scene first)

1. One corridor, one classroom, one vent, one stairwell, a safe-room stub: footsteps on four surfaces with debris, the
   noise table, our hearing subsystem, one Listener, portal occlusion, the event logger and submix capture.
2. In the same scene: Steam Audio HRTF A/B on three sources, the Dialogue-keyed sidechain, the Hidden mix state.
3. Then the Tension Director with two music stems on a Quartz clock, the radio, ear-to-the-door.
4. Then each creature's sound world, floor by floor, with captions from day one.

---

## 3. Unreal Engine 5.8 audio: what to use and how

### 3.1 MetaSounds (procedural and layered sound)
- MetaSound Sources are node graphs that generate or play sound with sample-accurate control. Standard interfaces give
  the graph the listener-relative azimuth, elevation and distance (UE.Spatialization, UE.Attenuation)
  [checked: https://dev.epicgames.com/documentation/en-us/unreal-engine/metasounds-reference-guide-in-unreal-engine].
  5.8 adds output to any channel layout (ambisonics, quad, surround, Atmos), an experimental expansion of Node
  Configuration, and Harmonix Tape Stop/Start and Distortion nodes [checked: https://cdm.link/unreal-engine-5-8-and-audio/].
- Use for: every footstep (one MetaSound per character with inputs Surface, Speed, Weight, Wet, Debris; random takes
  with no-repeat; pitch and level jitter of a few percent); creature voices built from layers, with a granular Swarm
  whose density input equals the swarm count; the generator (hum + harmonics driven by a Load parameter); the alien
  ship engines (Thrust, Damage); the music system (stems in one MetaSound with crossfades read from control buses).
  [I]
- Keep MetaSound graphs small and reusable (MetaSound Patches as shared sub-graphs) [from memory].

### 3.2 Audio Modulation: control buses and bus mixes (the dynamic mix)
- Control Buses carry a value; Control Bus Mixes set several buses at once and can be activated and deactivated at
  runtime; several different mixes can be active together, but only one instance of each; Audio Insights has a
  Modulation dashboard showing all live values [checked: https://dev.epicgames.com/documentation/en-us/unreal-engine/audio-modulation-quick-start-guide;
  https://dev.epicgames.com/documentation/unreal-engine/modulation-in-audio-insights-in-unreal-engine]. 5.8 adds
  Sequencer tracks for buses and bus mixes, so cutscenes can automate the mix on the timeline [checked: cdm.link].
- Stay Behind buses: Vol_Dialogue, Vol_Music, Vol_SFX, Vol_Radio, Vol_UI (user sliders); Mix_World, Mix_PlayerFoley,
  Mix_Creature, Mix_Ambience; Threat (0-1, from the Tension Director); LPF_World (for the "ear to the door" and the
  hidden state).
- Bus mixes (states): see section 4.1 for values. The Cutscene mix lives on the Sequencer track. [I]

### 3.3 Submixes and reverb
- Submixes form the effect and routing tree; sends can be manual, by distance or by attenuation, with custom curves
  [checked: https://dev.epicgames.com/documentation/en-us/unreal-engine/overview-of-submixes-in-unreal-engine].
- Convolution reverb is a Submix Effect Preset. Any sound wave can be turned into an impulse response (asset suffix
  _IR) with a per-IR gain to match loudness, and the effect can be the master reverb submix or a send target
  [checked: https://dev.epicgames.com/documentation/unreal-engine/convolution-reverb-in-unreal-engine].
- Tree (recommended) [I]:
  `Master <- [Dialogue] [Music] [Radio] [UI] [SFX <- (Player, Creatures, World, Ambience)] [Reverb_Small] [Reverb_Room] [Reverb_Large] [Reverb_Vent]`
  with a Dynamics Processor on Music and Ambience keyed from Dialogue (sidechain ducking, as sound.md section 3.1
  asks) [from memory: the UE submix Dynamics Processor accepts an external key submix; verify in 5.8], and a final
  limiter at -1 dBTP on Master.
- Use convolution for the few signature spaces (gym, auditorium, basement, mothership hall, the steel vents) and the
  cheaper algorithmic reverb for everything else. IRs: generate synthetic ones from room size (sound.md 3.2), or
  record our own (section 6.2: a balloon pop or sine sweep on the player's phone, with permission). OpenAIR IRs only
  file by file after reading each licence (sound.md).

### 3.4 Audio Gameplay Volumes, occlusion and obstruction
- Audio Gameplay Volumes (a plugin, off by default) are modular: a Reverb component (applies when the listener enters)
  and a Submix Send component (applies to sounds inside or outside); the Sound Class must enable "Apply Ambient
  Volumes"; parity with the old Audio Volumes but finer control [checked: https://dev.epicgames.com/documentation/en-us/unreal-engine/audio-gameplay-volumes-overview].
  A known bug: a sound that went virtual loses its submix send [checked: https://issues.unrealengine.com/issue/UE-197019].
  Workaround: set creature tells to "Play when silent" / keep them non-virtual [from memory; verify].
- Built-in occlusion is a cheap async trace with filter settings in the attenuation asset; advanced occlusion is left
  to plugins through the occlusion API [checked: https://dev.epicgames.com/documentation/en-us/unreal-engine/sound-attenuation-in-unreal-engine].
- Stay Behind: use the built-in trace for most sounds. For creatures, write a **portal occlusion** component: if the
  straight line is blocked, find the nearest open door or vent on the navigation path and play the sound from that
  opening with distance = path length (the sound comes round the corner, as in life). The same path length is the
  hearing distance in R3, so what the player hears and what the creature hears use the same number. Closed doors: a
  low-pass at about 1 kHz and -12 dB; walls: low-pass at 600 Hz and -20 dB plus a larger reverb send (sound.md
  "muffled and roomy"). [I]

### 3.5 Spatialisation and binaural for headphones
- Built-in: panning plus an ITD spatialiser node in MetaSounds [checked: https://dev.epicgames.com/documentation/en-us/unreal-engine/metasound-function-nodes-reference-guide-in-unreal-engine].
  Built-in binaural/HRTF plugins in UE5 have changed over versions (Resonance Audio's status in 5.8 not checked)
  [from memory].
- Steam Audio: the SDK is open source under Apache-2.0; 4.8.x is the current line; whether its UE plugin supports
  5.8 is NOT confirmed (a Dec 2025 thread asks about 5.7) [checked: https://valvesoftware.github.io/steam-audio;
  https://steamcommunity.com/app/596420/discussions/]. Microsoft Project Acoustics (baked wave acoustics) also exists
  [checked: https://developer.microsoft.com/en-us/games/articles/2022/08/project-acoustics-30-is-now-available/].
  atmoky trueSpatial is a commercial spatialiser usable inside MetaSounds [checked: https://developer.atmoky.com/true-spatial-unreal-engine/docs/workflows].
- Verdict [I]: a third-party plugin is worth it only for **headphone HRTF on a handful of sources** (the hunter's
  whisper, the Still Ones behind you, the Swarm above you, where front/back and height decide survival). Plan:
  build with the built-in spatialiser first; in the first test scene, A/B Steam Audio HRTF on those sources only. Adopt it
  if it builds on 5.8 and the player can hear "behind" and "above" better. Skip baked reflections (big levels, long
  bakes, risk). Ship a setting: Headphones (3D) / Speakers / Mono.

### 3.6 Ambience: Soundscape and beds
- Soundscape (a plugin, off by default) spawns ambient sounds around the listener from "colors" whose rules can read
  the density of tagged color points placed in the world; palettes must be registered in Project Settings
  [checked: https://dev.epicgames.com/documentation/unreal-engine/soundscape-quick-start;
  https://dev.epicgames.com/documentation/unreal-engine/API/Plugins/SoundScape/FSoundscapeColorSpawnSettings?lang=en-US].
- Use: tag points (Tag.Amb.Pipe, Tag.Amb.Vent, Tag.Amb.Glass, Tag.Amb.AlienDrone, Tag.Amb.Siren) and let Soundscape
  scatter one-shots (pipe ticks, distant sirens, a car alarm dying, glass settling, ship hull groans) near the
  listener by density. Beds (room tone, wind, city hum, ship hum) as looping ambisonic or quad files, which 5.8
  MetaSounds can now render to any layout [checked: cdm.link]. Rule from sound.md: beds measured as beds, one-shots
  never on a timer the player can learn.

### 3.7 Player noise drives the creatures' hearing (same numbers)
- Engine facts: ReportNoiseEvent takes Loudness and MaxRange; with MaxRange set, loudness multiplies the range; with
  MaxRange 0, the listener's hearing range is scaled by loudness [checked: https://docs.unrealengine.com/4.26/en-US/API/Runtime/AIModule/Perception/UAISense_Hearing/ReportNoiseEvent/index.html;
  https://forums.unrealengine.com/t/reportnoiseevent-maxrange-is-multiplying-by-loudness-problem/2651606]; plus the
  5.8 bug report [checked: https://forums.unrealengine.com/t/aisense-hearing-reportnoiseevent-never-triggers-ontargetperceptionupdated-ue-5-8/2734411].
- Recommendation [I]: a `NoiseEvent` data table: row = action x surface x debris, fields `Loudness_dB` (the event's
  level at 1 m), `SoundCue/MetaSound`, `Caption`. On every event: (1) the sound plays at that level (so the ear
  learns the scale); (2) a `UStayBehindHearing` subsystem computes, for each creature, received level =
  Loudness_dB - 20 log10(path distance) - occlusion loss (doors/walls, same values as 3.4), then compares it with that
  creature's threshold (Listeners low, Patrol medium, Brute high, Still Ones and Dark Dwellers ignore sound or use it
  differently); (3) the HUD noise ring (optional) shows the same number; (4) the event is logged (section 6.4). If the
  engine sense works in testing, it can be the delivery layer; the numbers stay ours.
- Starting values (to tune): crouch on carpet 30 dB, walk on tile 45, sprint on tile 60, glass under foot +12, can
  kicked 55, door slammed 70, locker 50, thrown bottle 75 at impact point, radio squelch at full 55, gun shot 95,
  generator start 85.

### 3.8 Footsteps and surfaces
- Standard wiring: Physical Material assets each tied to a Surface Type, assigned in materials; an anim notify on the
  footplant; a downward trace reads the physical material; a data asset maps surface to sound with a default
  [checked: https://dev.epicgames.com/documentation/unreal-engine/artist-11-add-footstep-sounds-to-a-character].
- Stay Behind [I]: in first person there may be no foot animation, so drive steps from distance travelled (stride
  length by gait) plus landing events; pass Surface (enum index), Speed, Weight and Wet to one footstep MetaSound;
  add a second trace or overlap for **debris actors** (glass, cans, paper, grit) that layers on top and adds to the
  noise table. Surfaces for the map: linoleum, ceramic tile, gym hardwood, carpet, concrete, metal stair, steel grate,
  vent sheet metal, roof gravel, asphalt, wet asphalt, broken glass, rubble, car metal, alien deck (hard), alien
  membrane (soft, wet), low-gravity alien deck. Variants per surface: 6 to 10 takes from different recordings (the
  sound.md rule "never the same twice").

### 3.9 Danny's body (pattern: Dead Space's A.L.I.V.E.)
- A `BodyState` component tracks Exertion (sprint time), Fear (Threat bus + recent scares), Injury and Breath-held.
  It drives: breathing loops in 4 intensities with crossfades (separate from exertion grunts); a heartbeat heard only
  above Fear 0.6 and in the Hidden state; the delivery of Danny's own lines (calm / winded / scared takes of the same
  line, picked by state; the voice pipeline renders three takes per line anyway). Breath-hold while hidden (a
  button) cuts the breath noise from the noise table and ends in a loud gasp if held too long. [I]

### 3.10 Music timing: Quartz and Harmonix
- Quartz is a sample-accurate scheduler: clocks on the audio render thread, PlayQuantized on Bar/Beat/smaller
  boundaries down to a 1/32 note, and events the game can subscribe to on each beat or bar
  [checked: https://dev.epicgames.com/documentation/unreal-engine/overview-of-quartz-in-unreal-engine]. The Harmonix
  plugin adds a Music Clock component with its own quantize and MIDI-driven MetaSounds
  [checked: https://dev.epicgames.com/documentation/unreal-engine/API/Plugins/HarmonixMetasound/UMusicClockComponent/Quantize;
  https://dev.epicgames.com/documentation/unreal-engine/harmonix-plugin-in-unreal-engine?lang=en-US].
- Use: one clock per score cue; state changes (Near -> Hunted) wait for the next beat (max 0.5 s) except when the
  hunter appears in view, which cuts in at once; stingers are quantized so they land musically (section 4.4).

### 3.11 Voice lines, subtitles, lip-sync
- Lip-sync: MetaHuman Animator's Audio Driven Animation turns any SoundWave into facial animation offline (UE 5.6+),
  with optional head motion; the "realtime" solver has no head motion [checked: https://dev.epicgames.com/documentation/en-us/metahuman/audio-driven-animation].
  Bake it for every third-person cutscene line; radio lines need no face. Third-party runtime lip-sync plugins exist
  (UE 5.0 to 5.7 listed) [checked: https://forums.unrealengine.com/t/runtime-metahuman-lip-sync-real-time-offline-lip-sync-with-audio-tts-cc4-genesis-arkit-and-more/2383289]
  but are not needed.
- Subtitles: build our own data-table system rather than rely on per-SoundWave subtitle entries
  [from memory: UE sound waves carry subtitle cues; a custom system gives speaker, colour and direction]. Each row:
  LineID, Speaker, Text, Audio, Takes(calm/winded/scared), Direction source (actor), Caption class. Timing rules from
  sound.md (42 characters, 2 lines, <= 15 cps, audio 0-40 ms before the mouth).
- Still open on the map: who voices the people and how strong the language is. Note: Chatterbox, the renderer chosen
  for the web voices, is "retired research" since August 2026 (sound.md); pin its version or plan a replacement.

### 3.12 Memory and streaming
- Stream caching: compressed audio moves to the end of the pak at cook time; per-wave Loading Behavior: Retain on Load
  (first chunk stays cached forever), Prime on Load (first chunk loaded, can be evicted), Force Inline (whole sound in
  memory, counts against the cache budget); a forum report of corrupted very short sounds with Force Inline + PCM/ADPCM,
  fixed with Bink Audio [checked: https://dev.epicgames.com/documentation/unreal-engine/an-overview-of-audio-stream-caching-in-unreal-engine;
  https://forums.unrealengine.com/t/first-time-sound-play-delayed/257204?page=2].
- Plan [I]: Retain on Load for footsteps, creature tells, stingers and the radio squelch (latency matters); stream
  music stems, beds and all dialogue; Prime the lines of the next cutscene when its trigger volume is entered; Bink
  Audio for long files, ADPCM for short gameplay sounds; cache budget sized after the PC's memory is known (open on
  the map).

---

## 4. The adaptive score and the creatures' sound worlds

### 4.1 States (Control Bus Mixes) and what plays
A `TensionDirector` subsystem reads every creature's awareness and distance, writes `Threat` (0-1) and picks one
state. Values are starting points [I].

| State | Enters when | Music | Mix |
|---|---|---|---|
| SafeRoom | inside the generator room, power on | the camp song (diegetic) or the group theme, warm, the only consonant harmony in the game | world -6 dB, voices forward |
| Explore | no creature tell for 60 s | none, or one sparse texture at most every 3-5 min | room tone, world full |
| Unease | a far tell heard, Threat 0.2-0.4 | a low drone stem in the chapter key | ambience -3 dB |
| Near | near tell, Threat 0.4-0.7 | drone + a slow pulse stem; no melody | ambience -6, player foley +2, creature +3 (Alien: Isolation pattern, sound.md) |
| Hidden | player in a hiding place with a creature inside 15 m | all music stems drain to 0 over 2 s; only the creature, Danny's breath and heartbeat | LPF_World 4 kHz, breath audible |
| Hunted | a creature has seen you / chases | the chase cue (quantized entry) | ambience -10, dialogue/radio muted |
| Release | the creature lost you for 8 s | one low resolving tone, then 20-40 s of silence | back to Explore |
| Grief | scripted, after a loss | the lost person's motif on one instrument | no tension stems; creatures quiet by design for that scene |

Rules: no state change more often than every 4 s (hysteresis); the score never plays when the hunter is close;
the hunter's presence is carried by its whispers alone, and music drops away when it comes. [I]

### 4.2 Eight creature sound worlds (each with far / near / alert tells; nothing shared)
All [I], built from our own recordings and synthesis; the hunter's look stays as agreed.
1. **The hunter** (anywhere). Far: a whisper with no clear direction, two decorrelated sources a few metres apart.
   Near: cloth dragging, long-joint creaks, a slow intake breath through something narrow; its crawl on hard floors is
   a soft multi-point patter, never footsteps. Alert: the whispering stops. Silence from the hunter is its worst
   sound.
2. **Dark Dwellers** (basement, power out). Only in darkness. Far: wet clicking and a scrape on concrete. Near: the
   clicking speeds up. Alert: in the torch beam they freeze; their sound stops and a faint hiss rises if the beam
   holds. Rule the ear learns: clicks = dark, silence in the beam = it is right there.
3. **Listeners** (blind, hunt by sound). A dampened floor (carpet, books, acoustic tiles) where every sound you make is
   clear. Far: a soft repeated tongue click that sweeps the room (they "ping" for you). Near: the pings point at your
   last noise. Alert: a sharp double click and a run toward the noise source. Distractions are thrown objects whose
   noise-table value beats yours.
4. **Still Ones** (move only when not looked at). Their movement must be audible, or the rule is unfair: plaster and
   ceramic grind, a joint crack, a shift of weight, always placed precisely (headphone HRTF matters here). While you
   look: true silence. A creak you hear behind you means one moved.
5. **Mimics** (look like a person from behind, call in a known voice). Speak in plain, full voice, never whisper
   (section 4.3). The tell is in the delivery: the same line repeated with identical timing each time (a recording,
   not a person) and a breath in the wrong place. Near: their steps are slightly too even.
6. **The Swarm** (vents and ceilings, warmth and movement). A granular MetaSound whose density = count and whose
   pitch rises when agitated; it is placed above (ceiling-tile occlusion filter + elevation). Alert: the mass moves as
   one, a dry rush along the vent toward you.
7. **The Patrol** (alien soldiers, room by room). They talk. Their speech is built from the alien symbol language
   (each symbol has a syllable; section 4.5), and the cadence tells their state: slow call-and-answer while
   searching, a sharp single word when suspicious, fast overlapping calls when engaged. Armour foley and a weapon hum.
   Their ship's idle tells you where landing pads are.
8. **The Brute** (mothership). Weight you feel: footfalls with energy under 60 Hz plus controller rumble, audible from
   far away; breath like a bellows. Before it tears a hiding place open, a 2-3 s tell: it taps and sniffs the
   container. That window is the fairness of its rule.

### 4.3 Stolen voices: a strict grammar (the map's biggest audio risk)
The map gives voices of the taken to the hunter (whisper, eerie) and known voices to the Mimics (calling). Rules [I]:
- **Hunter = whisper, Mimic = full voice. Always.** The player tells them apart in a second.
- **The radio is never faked.** Kayla's radio is the human line; if a creature can use it, the player stops trusting the
  one warm sound in the game. If the story wants one exception, it should be a single planned beat on the mothership,
  agreed with the player (a question to ask).
- **The hunter only says words those people said on screen.** It cuts new sentences out of lines the player heard
  them speak alive (concatenation at word boundaries from forced alignment). This is uncanny because the words and the
  voice are real while the sentence is wrong. It also ties to the quiet choices: a survivor you could not save becomes
  a voice in the hunter's mouth from then on. What happened to them stays off screen; only the voice returns.
- **Processing that sounds uncanny and stays intelligible** (extends sound.md 2.5): keep the speaker's formants
  (identity); remove the voicing by whisper resynthesis (LPC or noise-excited from the same spectral envelope, so
  vowels and consonants survive); re-time the words unevenly (stretch one word to 1.3x, shorten the next, flatten the
  pitch contour); remove the breaths, or put one inhale where no one would breathe; a second take of the same words
  10-14 dB down and 30-60 ms late; on the last word a short spectral freeze tail. Intelligibility is a hard gate:
  speech recognition on the processed line, word error <= 10 % (sound.md).
- Budget: with 8-10 hours, the hunter speaks at most every 2-3 minutes when present and never repeats a sentence
  within a chapter. [I]

### 4.4 Stingers that are not cheap
- A stinger must have a cause in the world (a locker door that really banged, a body that really dropped), arrive
  with a short pre-swell quantized to the music grid, and stay 12-16 LU above the previous 10 s (sound.md). At most
  one loud stinger per 10 minutes of play outside chases; the rest are tells. [I]
- The best scare is a sound with no stinger: the hunter's whispering stopping, the generator hum winding down, a
  Still One's creak behind you. Keep these sacred. [I]

### 4.5 Themes and the alien language in the score
- Danny-and-Kayla: a two-note rising figure, first heard warm (the evening event, before the ship). The group: a
  simple hymn-like chord progression played on a cheap instrument in the safe room. Each survivor: a three-to-four-note
  tag (the janitor whistles it, the teacher hums it); after one is taken, the hunter hums or whistles that tag wrongly
  (stolen tunes as well as stolen voices). [I]
- The alien symbol language gets a sound: each symbol a pitch class and a syllable. Panels chime the symbols, the
  Patrol speaks them, and the self-destruct (the "final exam") confirms each correct symbol with its tone, so the last
  puzzle plays a phrase that resolves into the Danny-and-Kayla figure. That is a melodic Easter egg the player can
  notice. [I]
- Instruments [I]: a detuned upright piano and a cheap acoustic guitar for the human world (things a school has),
  bowed metal, waterphone-style textures and processed choir from our own recordings for dread; deep synthetic drones
  and slowed recordings of the alien ship for the aliens. Hold each chapter's score to one key and tempo family so its
  stems can be layered freely (RDR2 pattern).

---

## 5. Original songs: placement and production

### 5.1 Where they sit [I]
1. **"The lift" (end of the school act).** The rescue helicopter lifts the survivors from the roof; Danny and Kayla sit
   side by side; the player can only look around; the city burns below. The song plays in the cabin (a survivor's phone
   speaker or simply the score) and gets to its first chorus. **A missile cuts it off mid-line** (music that stops).
   This is the hope beat that breaks.
2. **"The climb" (last leg of the flight).** After the pursuers are lost, the set course rises through cloud into the
   mothership's shadow, 2-3 minutes of easy steering. Danny has lost Kayla to the crash, and this is where he decides.
   Full song with vocals while the player still flies (the RDR2 ride pattern).
3. **"Stay Behind" (epilogue as Kayla / credits).** Sung softly, in a version that changes with the quiet choices:
   more voices in the chorus if more of the group lived; a solo voice if few did. The melody is the camp song's.

### 5.2 The camp song (diegetic, seeds all three)
One survivor plays a short original song on a guitar in the safe room, or it plays from a phone (never a real
artist's song). It returns as the hook of all three songs. If that survivor is lost, the safe room goes quiet at
night, and the epilogue version is sung without them. The game "remembers" through music. [I]

### 5.3 Production routes and their terms (checked today)
- **Suno:** free plan = Suno owns the songs, non-commercial only; songs made while on Pro or Premier carry commercial
  rights that survive cancellation; since 3 Sep 2026 commercial use covers only songs downloaded through Suno within
  the plan's monthly allowance; the earlier "you own it" wording was revised after the Warner deal
  [checked: https://help.suno.com/en/articles/2416769; https://about.suno.com/blog/suno-updates-tos;
  https://www.musicinafrica.net/magazine/suno-adjusts-ai-music-ownership-terms-after-warner-music-partnership].
  Allowance 20 (Pro) / 60 (Premier) per month per a secondary source [checked: https://dev.to/autonainews/suno-upgrades-ai-music-models-shifts-commercial-rights-2ka3].
- **ElevenLabs Music:** self-serve plans permit commercial use except film, TV, radio and "Studio Games" (games
  monetised and available on more than one platform), which need Enterprise; an "Indie Games" section (4.7) exists in
  the October 2026 terms but its content was not visible [checked: https://elevenlabs.io/music-terms;
  https://elevenlabs.io/eleven-music-model-specific-terms].
- **Udio:** downloads disabled on all plans since 29 Oct 2025 [checked: https://routenote.com/blog/udio-stops-user-downloads-after-umg-deal-heres-why/].
  Not usable.
- **Higgsfield:** its help centre says it claims no ownership of outputs, including audio, and does not restrict
  commercial use; outputs may not be used to train AI; a third-party report describes a broader licence to
  Higgsfield; no audio-specific terms were found [checked: https://higgsfield.ai/creator-hub/help-center/account-and-privacy/who-owns-my-generations-and-can-i-use-them-commercially;
  https://mindstudio.ai/blog/higgsfield-terms-of-service-backlash]. If its audio tool runs a third-party model,
  that model's terms may also apply [I].
- **Open models run on his PC** (ACE-Step, YuE: Apache-2.0; Stable Audio Open: Stability community licence)
  [from memory, not checked today]: no per-song fees, lower vocal quality, licences to read before use.
- **A human performer** (a singer or guitarist hired on a simple written agreement that assigns the recording to the
  project) [I]: cleanest rights and the most human sound; costs money; any purchase,
  subscription or contract is the owner's own decision.
- **Copyright note:** in the US, purely AI-generated music may not be protected by copyright at all
  [from memory: US Copyright Office guidance, 2023-2025]. Human-written lyrics and melody keep a human claim.
- **Recommended route [I]:** the lyrics written by the player (or with him; it is his story), the melody fixed as
  the camp song first, then one of: (a) a hired singer over our own arrangement (best); (b) Suno Pro with his lyrics,
  downloads inside the allowance, kept with their generation records; (c) an open model on his PC for drafts. Decide
  only after asking him: will the game be sold or published, and where; does he want to write lyrics; is any
  spending allowed.

---

## 6. Sources, foley, mix, accessibility and verification

### 6.1 Sound-effect sources and licences
- **The traced CC0 store** (docs/SOUND.md: opengameart and Kenney packs, each recording hashed and traced to a CC0
  page). Carry over the recordings and the provenance discipline; rebuild the import as UE assets with a source manifest.
  The web game's rules (laptop-speaker weight, no shrill treble) are relaxed for a PC with headphones; the provenance
  rules stay.
- **Sonniss GDC bundles** (2015-2026): royalty-free for commercial use, no attribution, unlimited projects per secondary
  sources; a possible "no AI training" clause is unverified [checked: https://bedroomproducersblog.com/2026/03/16/sonniss-gdc-2026-bundle/;
  https://licenseorg.com/guide/music-audio/sonniss]. Read sonniss.com/gdc-bundle-license before importing.
- **Freesound:** CC0 files only, as before. **BBC Sound Effects:** its RemArc licence is non-commercial
  [from memory]; avoid. **Fab:** free and paid audio packs under Fab's licence for Unreal projects [from memory; check
  each listing].
- **Generated (Higgsfield or others):** acceptable for textures and alien material under the terms in 5.3; log the
  prompt, model and date for every file used.
- **The player's phone:** see 6.2.

### 6.2 What must be recorded or designed fresh
- **Field recording by the player** (a phone in a voice-memo app set to uncompressed WAV, airplane mode, 20-30 cm
  from the source, 10 s of silence per place): kitchen foley for creature gore (celery and cabbage snaps, wet cloth,
  raw chicken slaps; the Dead Space practice of everyday objects, sound.md), cloth and backpack rustle, his own
  breathing at four intensities, footsteps on his home's surfaces, doors, a metal bin lid, keys, a cheap guitar or
  piano for the camp song. Never record people without consent, nor inside the school without permission.
- **Designed from scratch:** alien technology (UI chirps from the symbol tones; hum and power-up from processed
  electrical and resonant metal), the small ship's landing (heat ticks, venting, a hatch seal breaking, then the
  crawl out), the alien fighter (engine with Thrust and Damage inputs, cockpit alarms in alien syllables), the
  mothership (a vast low hull drone, distant mechanisms, the halls of the taken: many sleeping people's breathing
  under a membrane, slowed and spread), every creature (4.2), the self-destruct sequence (alien countdown voice + symbol
  tones + a hull coming apart).
- **Low gravity:** the map does not say whether there is air there. If there is thin air: high frequencies thinned
  (low-pass about 5 kHz), footfalls slow and soft, Danny's breath and heartbeat louder (sound through the body), long
  falls with cloth flutter. If vacuum: almost only body-conducted sound. This is a question for the player.

### 6.3 Foley lists
- **School:** locker doors (open/close/slam, a dented one that sticks), locker latch, classroom door with a closer,
  push-bar fire door, desks and chairs dragged and tipped, chalk/whiteboard marker, papers underfoot, books dropped,
  trophy-case glass, fluorescent tube flicker and ballast buzz, PA crackle, bell, water fountain, toilet flush and
  pipes, radiator knocks, vent grille unscrewed, ceiling tile lifted, janitor's cart wheels, mop bucket, keys on a
  ring, padlocks and combination dials (puzzles), fuse box and breakers, generator pull-start/run/choke/fail, fuel can
  slosh and pour, battery click into torch, torch switch, backpack zip, medicine bottle and pills, food wrappers,
  vending machine hum and drop, gym floor squeaks, basketball bounce (the evening event), crowd and band from the
  event (before the fall), auditorium seats folding, stage rigging, chemistry glass, sink taps, shattered windows,
  rain on skylights, roof gravel and hatch, helicopter rotor (approach, cabin interior, damage, crash).
- **City street:** parachute deploy, canopy flap, harness, landing on a car roof, car alarms (starting and dying),
  burning car crackle, broken glass sweep, shop shutters, traffic lights clicking with no traffic, abandoned car doors
  and engines ticking, dog in the distance, sirens far off and stopping, fire hydrant spray, rain gutters, manhole
  cover, fire escape ladders, distant alien ship flybys, Patrol armour and voices, the stun/knock-out struggle, the
  alien gun pickup and charge, the alien ship hatch and cockpit.
- **Alien ship and mothership:** deck footsteps (hard, membrane, grate), doors (iris, slide, membrane peel), panels and
  symbol keys, pods (seal, release, launch), restraints holding the taken, organic pipes, steam and fluid, low-gravity
  push-offs and landings, lifts, alarms, the Brute's den, self-destruct stages, the hull failing, the escape pod.

### 6.4 Mix plan, accessibility and verification without ears
- **Loudness targets:** no PC standard exists; Sony's ASWG-R001 practice is -24 LUFS integrated (+/-2) for console,
  -18 for portable, -1 dBTP, loudness range up to 20 LU; Meta asks -18 LUFS for PC VR
  [checked: https://audiokinetic.com/en/mastering-a-game-with-wwise-part1; https://developers.meta.com/horizon/documentation/unreal/audio-loudness-meter-overview/].
  Recommendation [I]: -23 LUFS integrated over a 30-minute captured session at the "Headphones/Home" setting,
  -1 dBTP, dialogue about -23 to -20 LUFS short-term in cutscenes, beds 14-18 dB under dialogue, scares 12-16 LU over
  the previous 10 s (sound.md).
- **Headphones vs speakers:** a Dynamic Range option. "Wide" (headphones/home: full range, HRTF on key sources),
  "Standard" (desk speakers: gentle master compression, beds +3 dB), "Narrow" (TV or night: stronger compression, no
  scare above 10 LU over the previous 10 s). Each option is a Control Bus Mix plus master dynamics settings.
- **Accessibility:** separate sliders (Dialogue, Music, Effects, Radio, UI); subtitles with speaker name, colour and a
  direction arrow for off-screen speakers; captions for every creature tell and stinger in the "[slow steps, behind]"
  form (sound.md, Xbox guideline 104); an optional visual sound indicator around the crosshair for creature tells
  (as the Silent Hill 2 remake lets players swap the radio for a visual cue [checked: https://videogameschronicle.com/review/silent-hill-2]); mono
  output; a "reduce sudden loud sounds" setting; vibration cues for the Brute and for hunter proximity.
- **How the agent verifies audio it cannot hear** [I]:
  1. **Event log:** a `SoundEventLogger` subsystem writes every sound start (time, asset, class, world position,
     distance, occlusion, volume after modulation, current state, Threat) and every NoiseEvent (dB, who heard it, at
     what level) to CSV. Tests read it: no creature tell without a caption; at most one stinger per 10 min outside
     chases; the hunter never repeats a sentence in a chapter; state changes no more often than every 4 s.
  2. **Captured renders:** record the Master submix to WAV during automated playthroughs (UE has Blueprint nodes to
     start and finish submix output recording [from memory]); measure with ffmpeg's ebur128 filter or pyloudnorm:
     integrated, short-term, loudness range, true peak; spectra (energy under 60 Hz for the Brute, over 8 kHz for
     glass); check the 5.8 Audio Insights loudness meter agrees [checked: cdm.link].
  3. **Speech:** speech recognition on every rendered line (clean <= 5 % word error, processed hunter lines <= 10 %) and
     on the full cutscene mix (<= clean + 5 points), as sound.md section 5 specifies.
  4. **Spatial checks:** play a test tone from known bearings in a test map, capture, check left/right level and that
     a closed door removes the expected high-frequency energy.
  5. **The player as the ear, four times:** a 10-minute listening session on his PC with headphones at the first
     creature slice, the first song draft, the first full chapter, and the mix before release. He said earlier "just
     test it yourself", but taste and fear cannot be measured; a few short sessions guard the "best sounds" goal.

---

## 7. What I could not verify
- The full UE 5.8 audio release notes (dev.epicgames.com unreachable; 5.8 items come from CDM's article via search).
- Whether the 5.8 AI-hearing bug is real or still open.
- Whether the Steam Audio UE plugin builds on 5.8; the state of Resonance Audio and other bundled HRTF plugins in 5.8.
- Whether the submix Dynamics Processor's external key input works as expected in 5.8; the "play when silent"
  workaround for the virtual-voice send bug.
- Sonniss's 2026 licence text and the reported "no AI training" clause.
- ElevenLabs' "Indie Games" terms (section 4.7); which model Higgsfield's audio tool uses and that model's terms.
- Licences of open music models (ACE-Step, YuE, Stable Audio Open) and the US copyright position on AI music today.
- How Alien: Isolation's or The Bunker's creatures model hearing internally (only reviews were found).
- Which RDR2 mission uses "Mountain Hymn"; the camp-song details are from memory.

## 8. Questions for the player (do not guess)
1. Will Stay Behind be sold or published, and where (Steam only, several stores, free on itch.io)? This decides the
   music route and every AI tool's terms.
2. Does he want to write the song lyrics himself (or with us)? Is any spending allowed (a Suno plan, a hired singer),
   with a parent's okay?
3. Can the hunter or a Mimic ever fake Kayla's radio, or is the radio always safe?
4. Low gravity on the mothership: is there air there?
5. May he record sounds at home with his phone (a short list will be supplied), and may he record room echoes in his
   school with permission?

## Sources
- https://cdm.link/unreal-engine-5-8-and-audio/
- https://dev.epicgames.com/documentation/en-us/unreal-engine/unreal-engine-5-8-release-notes
- https://www.unrealengine.com/news/unreal-engine-5-8-is-now-available
- https://dev.epicgames.com/documentation/en-us/unreal-engine/metasounds-reference-guide-in-unreal-engine
- https://dev.epicgames.com/documentation/en-us/unreal-engine/metasound-function-nodes-reference-guide-in-unreal-engine
- https://dev.epicgames.com/documentation/en-us/unreal-engine/audio-modulation-quick-start-guide
- https://dev.epicgames.com/documentation/en-us/unreal-engine/audio-modulation-reference-guide-in-unreal-engine
- https://dev.epicgames.com/documentation/unreal-engine/modulation-in-audio-insights-in-unreal-engine
- https://dev.epicgames.com/documentation/en-us/unreal-engine/overview-of-submixes-in-unreal-engine
- https://dev.epicgames.com/documentation/unreal-engine/convolution-reverb-in-unreal-engine
- https://dev.epicgames.com/documentation/en-us/unreal-engine/audio-gameplay-volumes-overview
- https://issues.unrealengine.com/issue/UE-197019
- https://dev.epicgames.com/documentation/en-us/unreal-engine/sound-attenuation-in-unreal-engine
- https://dev.epicgames.com/documentation/unreal-engine/soundscape-quick-start
- https://dev.epicgames.com/documentation/unreal-engine/API/Plugins/SoundScape/FSoundscapeColorSpawnSettings?lang=en-US
- https://dev.epicgames.com/documentation/unreal-engine/overview-of-quartz-in-unreal-engine
- https://dev.epicgames.com/documentation/unreal-engine/harmonix-plugin-in-unreal-engine?lang=en-US
- https://dev.epicgames.com/documentation/unreal-engine/API/Plugins/HarmonixMetasound/UMusicClockComponent/Quantize
- https://docs.unrealengine.com/4.26/en-US/API/Runtime/AIModule/Perception/UAISense_Hearing/ReportNoiseEvent/index.html
- https://forums.unrealengine.com/t/aisense-hearing-reportnoiseevent-never-triggers-ontargetperceptionupdated-ue-5-8/2734411
- https://forums.unrealengine.com/t/reportnoiseevent-maxrange-is-multiplying-by-loudness-problem/2651606
- https://dev.epicgames.com/documentation/unreal-engine/artist-11-add-footstep-sounds-to-a-character
- https://dev.epicgames.com/documentation/en-us/metahuman/audio-driven-animation
- https://forums.unrealengine.com/t/runtime-metahuman-lip-sync-real-time-offline-lip-sync-with-audio-tts-cc4-genesis-arkit-and-more/2383289
- https://dev.epicgames.com/documentation/unreal-engine/an-overview-of-audio-stream-caching-in-unreal-engine
- https://forums.unrealengine.com/t/first-time-sound-play-delayed/257204?page=2
- https://valvesoftware.github.io/steam-audio
- https://steamcommunity.com/app/596420/discussions/
- https://developer.microsoft.com/en-us/games/articles/2022/08/project-acoustics-30-is-now-available/
- https://developer.atmoky.com/true-spatial-unreal-engine/docs/workflows
- https://pcgamer.com/the-audio-of-alien-isolation
- https://www.wikiwand.com/en/articles/Alien_Isolation
- https://mcvuk.com/?p=70758
- https://www.ea.com/ea-studios/motive/news/focus-on-deadspace-audio-design
- https://cogconnected.com/2022/03/alive-system-dead-space-remake/
- https://videogameschronicle.com/review/silent-hill-2
- https://gamingbolt.com/what-made-silent-hill-2-remake-our-game-of-the-year-2024/amp
- https://gamesradar.com/amnesia-the-bunker-uses-a-sound-illusion-from-scary-movies-and-mario-64-to-quietly-stress-you-out
- https://pcgamer.com/amnesia-the-bunker-review
- https://digitaltrends.com/gaming/outlast-2-review
- https://www.gameinformer.com/games/outlast_ii/b/playstation4/archive/2017/04/04/five-ways-outlast-2-captures-mind-bending-horror.aspx
- https://www.thesoundarchitect.co.uk/outlast-2-game-audio-review/
- https://en.wikipedia.org/wiki/Music_of_Red_Dead_Redemption_2
- https://www.thegamer.com/red-dead-redemption-two-ten-best-songs-soundtrack/
- https://en.Wikipedia.com/wiki/Unshaken
- https://help.suno.com/en/articles/2416769
- https://about.suno.com/blog/suno-updates-tos
- https://www.musicinafrica.net/magazine/suno-adjusts-ai-music-ownership-terms-after-warner-music-partnership
- https://dev.to/autonainews/suno-upgrades-ai-music-models-shifts-commercial-rights-2ka3
- https://elevenlabs.io/music-terms
- https://elevenlabs.io/eleven-music-model-specific-terms
- https://routenote.com/blog/udio-stops-user-downloads-after-umg-deal-heres-why/
- https://higgsfield.ai/creator-hub/help-center/account-and-privacy/who-owns-my-generations-and-can-i-use-them-commercially
- https://mindstudio.ai/blog/higgsfield-terms-of-service-backlash
- https://bedroomproducersblog.com/2026/03/16/sonniss-gdc-2026-bundle/
- https://licenseorg.com/guide/music-audio/sonniss
- https://audiokinetic.com/en/mastering-a-game-with-wwise-part1
- https://developers.meta.com/horizon/documentation/unreal/audio-loudness-meter-overview/
