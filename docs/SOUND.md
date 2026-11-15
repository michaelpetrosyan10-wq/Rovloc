# Sound

How ROVLOC's sounds are made, measured and shipped. The code is `web/sounds/`; the output is `web/build/audio/`
(git-ignored) and the sound board `web/build/soundboard/`.

```
npm run sounds            render every voice (or: npm run sounds -- --only <family|Name>[,...]   --force   --jobs 1|2)
npm run sounds:audit      measure every render against its class's rules (-- --group reference|world|air, --only, --no-sheets)
npm run sounds:format     decode every shipped file in headless Chromium and compare it with its render
npm run sounds:board      build the sound board and check it in headless Chromium (-- --no-check)
npm run sounds:test       the kit's and the measurements' tests
```

## 1. Why

The player: *"i want the sounds to actually be scary. Rn its like this vibecoded high pitched sound. I also want his
footsteps to be louder so people know when hes around ... Make the sounds of the monster be scary and his footsteps be
scary and other sounds be scary too like the glass its all lame sounds"*.

Until now every sound was a preset that re-pitched, sliced and filtered stand-ins of eleven Roblox sound files at run
time (`SynthPresets.luau` -> `web/src/engine/audio/`): a few milliseconds of a UI tick looped into a "tone", a plastic
footstep sped up into a "click". Thin, tonal, high. Worse, the creature's view code played the PLAYERS' footstep
presets for him (`creature/view.js` `_onFootstep`), so he walked like a kid.

The decision: every sound is still made only by our own code (no recording, no third-party sample, ever), but by a real
synthesis kit, rendered offline at build time into files that ship with the site. At run time the game only plays
files (nearly free on a Chromebook); the Roblox port uploads the same renders.

## 2. The cast

`web/sounds/cast.json` lists every sound the game needs (169 when written): the 82 SynthPresets, every inline recipe
in `web/src` (creature 12, objectives 9, parkour 3, radar 2), the in-flight work of other engineers (the ambient
dressing's 8 `Dread*` presets and the story's 18 presets in `integ-story`; the monster worktree's cue table), spec 5.5's
coming stages (31 new names), and the redesign's own (his footsteps, his arrival, the voice beds). Each entry has its
sources, an owner group and a status:

| Group | Who | What |
|---|---|---|
| reference | the foundation | him (throat, body, mask, keys), his footsteps, the players' footsteps and parkour, the glass, the creature code's 2D scares |
| world | the world engineer | what a player or a machine does at a place: doors, lockers, metal, objects, pickups, traps, machines, power, the radar, the players' bodies, the parachute, vehicles, the revolver, menus |
| air | the air engineer | atmosphere, weather, distant events, scares and stingers, anything musical, story and cutscene sounds, the phone and the PA, children |

Status is `pending`, `voiced` (rendered and audited) or `dropped` (with a note saying why). Notes in the cast flag
what a voice must respect (`BoneCrunch` and `NeckSnap`: spec I12, no gore; `DreadThumpAbove` and `CeilingDrag`: must not
imitate his gait, spec I1; `FakeoutShriek`: he is not there, so none of his signatures).

## 3. The design law, made concrete

Nobody on this job can hear, so every point of the law is something built and measured (section 4).

1. **Nothing is a bare oscillator.** Every sound is an exciter (`kit/impact.mjs` burst, `kit/friction.mjs` stick-slip,
   `kit/voice.mjs` glottal pulses, `kit/grains.mjs` Poisson showers) driving a resonant body (`kit/modal.mjs` banks of
   4-40 inharmonic modes, formant banks, `kit/delay.mjs` combs and waveguides) heard in a space. The only pure tones are
   the sub thumps under 110 Hz (`kit/thump.mjs`). *Measured:* tonal purity (the share of the sustain's energy in its
   strongest twelfth-octave band above 110 Hz) at most 0.45, unless the class is a declared inharmonic resonance
   (glass, porcelain, keys) with at least 5 strong peaks.
2. **Weight that survives a laptop speaker.** A heavy sound has real sub (35-90 Hz: the thump), a low-mid body
   (150-600 Hz: the floor's modes) and the sub's harmonics made by oversampled saturation (`kit/shape.mjs`;
   `kit/dynamics.mjs` `densify()` drives a whole impact into a soft curve until its body fills in under its peak).
   *Measured:* the "laptop" filter (12 dB/octave high-pass at 220 Hz): a heavy impact keeps 30 % of its energy under
   250 Hz and loses under 9 dB of loudness through the filter.
3. **Dark and rough.** Centroid at most 3 kHz for everything but glass, porcelain, sparks and keys (those are short
   and many). Anything alive has roughness (30-150 Hz amplitude modulation: `roughen()`), period doubling, pitch breaks
   and noise bursting in (`glottal()`). *Measured:* centroid, roughness (vocal at least 0.12).
4. **Transients and tails.** Impacts attack in under 5 ms (the first strong transient's 10-90 % rise); breaths and
   swells rise over at least 40 / 80 ms; every one-shot starts and ends at silence (first and last sample at least
   40 dB under the peak), its tail decays (the last 5 ms at least 50 dB down), no DC, no clipping, true peak at most
   -1 dBTP.
5. **Never the same twice.** Repeating sounds have 3-6 variants that differ in their physics (strike position, mode
   detuning, grain timing, after-sounds). *Measured:* the closest two variants differ by at least 2 dB (mean absolute
   difference of their onset-aligned third-octave x 20 ms level maps).
6. **Quiet is part of it.** Beds integrate at most -34 LUFS; the loudest things are the jumpscare (-9 LUFS) and the
   chase stingers (-10 to -12), all peak-limited at -1 dBTP; menus under -26.
7. **He has a signature.** PORCELAIN (`kit/porcelain.mjs`: short dry high-Q ticks at 1.2-5 kHz, clustered like
   chattering teeth), the THROAT (formants at 0.55 of a man's; a 20-35 Hz soft-palate rattle `flutter()` in the
   exhale) and the GAIT (his footsteps). Every one of his sounds declares the signatures it carries and the audit
   measures at least one (porcelain ticks counted at 1.2-5 kHz at least 2; the rattle index at least 0.2; the gait:
   heavy-class weight). A family file that renders porcelain may hold only his sounds, and no breath or vocal that is
   not his may carry the rattle (spec I1). The 2D scares that play at the player (`scares.mjs`) carry none.

Content limit (spec I12): the catch is a dull, dry knock (`NeckSnap`: a slam, a muffled snap through cloth), never wet.

## 4. The audit

`audit.mjs` measures every render's raw samples (`web/build/audio/raw/`) with `lib/measure.mjs` and holds it to the
universal rules, the one-shot or loop rules, its class's rules and the defaults (`lib/classes.mjs`, which this table
copies). It fails on any breach, on any cast sound of the audited group without a render (the other groups are listed
as pending), on a voice missing from the cast, on shipped audio over the budget, and on the distance rule.

**Every sound:** no clipped samples; true peak at most -0.9 dBTP (the pipeline limits at -1); |mean| at most 0.0025;
first and last sample at least 40 dB under the peak; loudness within 1.5 LU of its declared reference; centroid at
most 3 kHz unless its class is bright; purity at most 0.45 unless its class is a resonance (then at least 5 peaks);
variants at least 2 dB apart. **One-shots:** under 12 ms of silence before; the last 5 ms at least 50 dB down; at most
2.5 s (stingers 6 s; baked sounds 5 s). **Loops:** 8-24 s; the seam's sample jump at most 1.5 x the 99.9th percentile
of the steps inside; the level step across the seam (50 ms either side) at most 1.5 dB beyond the loop's own 95th
percentile 50 ms step.

| Class | Rules | What its picture looks like |
|---|---|---|
| heavy | low (< 250 Hz) >= 30 %; laptop loss < 9 dB; attack <= 5 ms; centroid <= 1.5 kHz | a vertical broadband wall at the onset whose low end smears and decays; most of it under 600 Hz |
| body | low >= 15 %; laptop loss < 12 dB; attack <= 5 ms | a short broadband onset over a low-mid body that decays fast |
| light | attack <= 5 ms; <= 0.9 s; loudness <= -24 LUFS; centroid <= 2.5 kHz | a small, short, dry smudge low in the picture; no ringing lines |
| glass (bright, resonance) | high (> 2.5 kHz) >= 20 %; peaks >= 5; attack <= 5 ms | a spray of many short high lines over a low thump, thinning out over a few hundred ms |
| crunch (bright) | purity <= 0.2; attack <= 5 ms; <= 1.2 s | a dense cloud of tiny clicks, no lines |
| porcelain (bright, resonance) | porcelain ticks >= 2; attack <= 5 ms | a few short dots between 1.2 and 5 kHz, irregular in time |
| keys (bright, resonance) | attack <= 5 ms; <= 0.6 s; peaks >= 5 | a handful of short high lines, scattered |
| spark (bright) | attack <= 5 ms | scattered vertical ticks over a broken buzz |
| liquid | purity <= 0.3; peaks >= 5 | a cloud of tiny rising strokes, denser where it splashes |
| breath | rise >= 40 ms; purity <= 0.25; centroid <= 2.5 kHz | a moving cloud with formant bands; no lines, no hard edges |
| vocal | roughness >= 0.12; centroid <= 2.5 kHz | formant bands smeared by roughness, breaking in pitch; noise bursting through |
| friction | centroid <= 2.5 kHz | a band of fine vertical striations (the slips) over the body's modes |
| swell | rise >= 80 ms; centroid <= 2.5 kHz | a cloud that grows (or shrinks) smoothly; no onset wall |
| stinger (<= 6 s) | low >= 15 %; laptop loss < 9 dB; roughness >= 0.1; loudness <= -8 LUFS; attack <= 20 ms | a sudden dense wall: low drop, rough formant bands, an inharmonic shriek; decays fast |
| music (loop) | low >= 20 %; laptop loss < 9 dB; loudness <= -14 LUFS | regular vertical hits over a low rough band; no seam |
| bed (loop) | loudness <= -34 LUFS; centroid <= 1.5 kHz | a low even cloud; nothing stands out; no seam |
| far (<= 5 s) | centroid <= 1.5 kHz | a dark, smeared event inside a long reverberant tail |
| menu (<= 0.3 s) | centroid <= 2 kHz; loudness <= -26 LUFS | one tiny low dot |

Loudness is ITU BS.1770 (K-weighted): a one-shot's loudest 400 ms block, a loop's gated integrated loudness.
"Laptop loss" is that loudness minus the same through the laptop filter. "Attack" is the 10-90 % rise of the first
local maximum of the 1 ms envelope that reaches 20 % of its peak (a heel before the weight is its own transient);
"rise" is 10-90 % of the loudest 10 ms. Roughness is the 30-150 Hz modulation depth of the envelope; the rattle index
the 18-38 Hz modulation depth of the 100-1,200 Hz band's envelope; porcelain ticks are sharp local rises (3 x the 30 ms
background) of the 1.2-5 kHz band.

**The distance rule (his footsteps):** heard through the distance model (section 6) in the Basement's space with no
walls, his quietest variant at 80 studs is at least 6 dB over the Basement bed (until the bed is rendered, the bed
class's ceiling of -34 LUFS stands in), and at 10, 40 and 80 studs at least 10 dB over the loudest variant of a
player's footstep on the matching surface (a player's step is silent past 60). Today: 6.5-8.1 dB over the bed at 80
studs; 16-20 dB over a player's step at 10 and 40 studs.

**Pictures:** `web/build/audio/audit/<family>-<n>.png`, eight sounds a sheet: a log-frequency spectrogram (20 Hz to
20 kHz, 70 dB range; under 500 Hz from an 8,192-sample window for its frequency resolution, above it from 1,024 for its
time resolution, so a faint seam shows at 500 Hz) over the waveform, with the name and the key numbers (a name in red
failed a rule). A bare tone is one horizontal line. Look at them.

## 5. The kit (`web/sounds/kit/`)

Plain JavaScript DSP over Float32Arrays, run in Node, deterministic (every random number comes from `rng.mjs`, seeded
from the sound's name and variant and forked per layer; `Math.random` is banned and a test checks).

| Module | What |
|---|---|
| rng | sfc32 seeded through splitmix32; forks per layer; normal, ranges, picks |
| noise | Gaussian white, pink (Kellet), brown, velvet |
| env | T60 decays, breakpoint segments, smooth random modulators (and a periodic one for loops), bumps |
| filters | RBJ biquads, Butterworth cascades, Simper's state-variable filter (stable under sweeps), one-poles, DC blocker, the laptop filter |
| mix | allocate, add at an offset (and wrapped), envelopes, fades, pan, crossfaded loops, trim |
| modal | resonator banks; bar, membrane, glass and plate ratios; strike-position gains; scattered modes |
| delay | delay lines, feedback comb, Schroeder all-pass, Karplus-Strong with dispersion |
| friction | stick-slip pulse trains; a bowed body (the friction locked onto its modes: squeals, shrieks of steel) |
| voice | glottal pulses (jitter, shimmer, period doubling, pitch breaks, chaos, creak, aspiration), formant banks, vowel paths, roughness, the soft-palate flutter; breath, growl, scream, whisper, babble, child |
| grains | Poisson event times (non-homogeneous, by thinning), showers, pings, grit clicks, bubbles |
| thump | the pitch-dropping saturated sub burst |
| shape | 4x oversampled saturation (Kaiser sinc up / down; aliases under -60 dB) |
| impact | noise bursts, grit, the whole footfall (heel, thump, body, contact, texture, after-sound) |
| porcelain | his mask: a porcelain tick, chatter |
| reverb | early reflections + an 8-line Hadamard FDN; the game's spaces; impulse responses; FFT convolution; baking into a space |
| dynamics | the look-ahead true-peak limiter (iterates until under the ceiling); densify() |
| loudness | K-weighting, momentary maximum, gated integrated loudness, true peak |
| fft | radix-2 FFT, windows, Welch, STFT, convolution |
| distance | the one distance model (section 6) |

## 6. The distance model (`kit/distance.mjs`)

One pure function for every positional sound: `heard(distance, walls, carry)` -> `{gain, cutoff, reverb, direct, send}`.

- **gain**: 1 inside `carry.ref`; then `(ref / d) ^ rolloff`; fading linearly to 0 between `fade x max` and `max`;
  x 0.5 per wall.
- **cutoff**: a 12 dB/octave low-pass at the lower of the air's (18 kHz at 8 studs, falling to 900 Hz at about 250)
  and the walls' 2,400 / 1,100 / 600 Hz (spec 3.4).
- **reverb**: the reverberant share `d / (d + 12)` + 0.12 per wall, at most 0.92. The game sends `sqrt(share)` of the
  gain to the one shared convolver and keeps `sqrt(1 - share)` direct; without a convolver it plays the direct path at
  the full gain, so it sounds right either way.

Each positional voice declares its carry (in the manifest). His steps and body: ref 10, max 140, rolloff 0.9 (the
monster worktree's `docs/MONSTER.md` 19 says his footfalls are heard to 70 today: the switch raises it). His voice:
the spec's Head channel (ref 8, max 90, rolloff 1, fade from 60). The screech: max 420. A player's steps: ref 4, max 60.

## 7. Adding a sound

1. Find it in `cast.json` (or add it, with its sources and group). Pick its family file
   `web/sounds/voices/<family>.mjs` (yours alone; one manifest per family, so two engineers can render at once).
2. Export it in the family's `voices` array (`lib/voices.mjs` documents every field): `name` (the game's name),
   `title` and `description` in plain words (the sound board shows them to the player), `class`, `him` (only his),
   `repeats` and `variants`, `channels`, `loop` (`{seconds, crossfade}`: the render is that much longer and the
   pipeline folds the crossfade over the start), `space` (`dry` positional / `baked`), `loudness` (LUFS), `carry`,
   `board` (the heading), and `render({sr, rng, variant, name, seconds})` returning a Float32Array (or `[left, right]`).
   Every random number comes from `rng` (fork it per layer).
3. `npm run sounds -- --only <family>`, then `npm run sounds:audit -- --only <family>`. Look at
   `web/build/audio/audit/<family>-*.png` with the table in section 4 in mind. Iterate until the numbers pass and the
   pictures look like the real thing. Set the cast status to `voiced`.
4. Never loosen a rule to pass; a rule that is wrong for a whole class is fixed for the class, with the reason here.

The pipeline (`lib/pipeline.mjs`) finishes every render: an 18 Hz high-pass; a one-shot's leading silence and dead tail
(under -72 dB of the peak) trimmed with a 20 ms fade; a 0.3 ms fade-in; scaled to its reference loudness; limited to
-1 dBTP (a loop is limited over three periods and the middle one kept). A loop ships with 100 ms of its own signal on
either side of its loop points. A content-hash cache (the kit, the pipeline, the family file, the name and variant)
skips what has not changed; at most two worker threads, under `nice -n 10`.

## 8. The shipped format: MP3

MP3 (LAME VBR `-q:a 4`, 48 kHz, mono unless the sound is 2D), because every browser's `decodeAudioData` decodes it
(Chromium, Firefox, Safari) and Roblox accepts it; Opus would need an MP3 twin for Safari's older versions and is not
needed (below). The encoder's priming and padding are written in the LAME/Xing header; every flag that could make the
bytes depend on the machine is pinned (`bitexact`, no metadata, no ID3), so the same render gives the same file.

`npm run sounds:format` decodes every shipped file in headless Chromium (`OfflineAudioContext` at 48 kHz, as the game
will) and compares it with its render. With the reference set (235 files):

- offset: 0 samples on all 235 (Chromium trims the priming from the LAME header);
- length: exact on 232; three one-shots decode 12-31 samples longer (padding not trimmed to the sample; silence at
  the end of a one-shot, harmless; loops play by their loop points);
- spectrum: third-octave bands within 20 dB of the loudest move at most 0.78 dB (median 0.10); bands 20-30 dB down at
  most 1.74 dB;
- transients: 1 ms envelopes correlate at least 0.9976 (median 1.0000); the first 10 ms residual median -34.6 dB;
- loops: the decoded loop windows' seams measure ratio <= 0.21 and no level step (7 loops);
- waveform SNR 14-60 dB (median 33.6): low only for bright noise (crunching glass, keys), which a perceptual codec
  keeps as spectrum, not waveform; reported, not judged.

Only Chromium is installed here: Firefox and Safari decoding is the documented MP3 behaviour, not measured. If a
decoder kept the priming, the loops would still loop seamlessly (their margins are their own signal), and one-shots
would start about 24 ms late.

## 9. Budgets

All shipped audio at most 8 MB (the audit checks); one-shots at most 2.5 s (stingers 6 s, baked far events 5 s);
loops 8-24 s; mono unless the sound is heard all around you (2D stingers, the chase music, a bed, a baked far event:
8 stereo sounds in the reference set, 647 KB); byte-identical renders from the same code and seed. The reference set:
64 sounds, 235 files, 2.72 MB (with the six spaces' impulse responses, 144 KB). The other two groups share the rest.

## 10. The sound board

`npm run sounds:board` builds `web/build/soundboard/` (a static page plus the audio; opened over http it fetches the
MP3s, opened by double-click it loads the same bytes from `data/<family>.js`). Headings: Him, His footsteps, Your
footsteps, Glass, Doors and lockers, Power and machines, The building, Scares, Story, Menus (the empty ones are hidden).
A big play button per sound cycles its variants; "Play the group"; Near / Mid / Far (10 / 40 / 80 studs through the
distance model and the corridor's impulse response); a volume slider; audio only after a click. It checks itself in
headless Chromium over http and from the file: it loads, every file decodes, a click plays, the console is clean, no
external request, no horizontal scroll at 380 px.

## 11. What the run-time switch needs (the next job)

- The game only plays files: load `web/build/audio/manifest.json` (per sound: files, durations, loop points, true
  peak, loudness, family, title, description, baked or dry, tail length, carry). A play picks a variant (never the
  same twice in a row), plays it at volume 1 x the bus x `heard()` for dry sounds; baked sounds play 2D as they are.
- Retire the run-time synthesis (`engine/audio/effects.js`, `samples.js`, the preset layers) once every cast sound is
  voiced; until then fall back to the old preset for a pending name.
- At most one shared ConvolverNode, its buffer the level's space (`web/build/audio/space/<space>.mp3`: corridor,
  basement, hall, room, stairwell, outdoor; normalized to unit energy); every dry voice sends `h.send` to it. The game
  must sound right without it (Potato): then play the direct path at the full gain.
- Loops: `loop = true`, `loopStart` / `loopEnd` from the manifest (each file has 100 ms of margin either side).
- His footsteps: `creature/view.js` `_onFootstep` plays `CreatureStepWalk<Surface>` / `CreatureStepChase<Surface>`
  (Concrete, Carpet -> Concrete; Tile, Glass, Water -> Tile; Wood -> Wood; Metal -> Metal; Grass -> Gravel) and
  `CreatureStepDuct` on all fours in a duct, never `Footstep*` (spec I1). Raise `CreatureConfig.Presence` footfall
  carry from 70 to the manifest's 140.
- New names to wire: `CreatureArrive` at every FadeIn's spot; `VoiceThroat` / `VoiceWhisper` under the talking
  monster's lines (gated by `VoiceRules.syllables`); `KeyJingle` with the Tall Janitor's footfalls.
- Levels: the files carry their loudness (his steps -17 / -18 LUFS at 10 studs, the jumpscare -9, a player's step -30 /
  -28). Set the buses to unity and keep the old per-call volume constants out (`HEAVY_VOLUME` and the like): the
  balance is in the files.
- The Roblox port uploads the same MP3s and keeps the same carry numbers in `RollOffMinDistance` / `MaxDistance`.

## 12. Open points

- No old-recipe-versus-new table: rendering the old presets offline needs the game's WebAudio effect chain and the
  eleven stand-ins in a browser, more than an hour's work; the bar moved is shown by the audit's numbers alone.
- Only a human ear can settle: whether his footsteps read as "him" from down a corridor on a Chromebook speaker; the
  jumpscare's balance of voices against the steel shriek; whether the chase pulse is frightening or merely busy;
  whether the sniff and the vent breathing sound alive or mechanical; the board's loudness of the scares on earbuds.
