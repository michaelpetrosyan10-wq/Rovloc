# Horror sound, voices and the cutscene mix: research for ROVLOC

Desk research, 16 Nov 2026. Tags: [S] a named source states it; [I] my inference; [U] could not verify.
The line we do not cross: we take TECHNIQUES (how a bed is layered, how loud a stinger sits, how a voice is
processed), never content (no other game's sounds, music, lines, creature voices or recordings).

Current ROVLOC baseline (read for this report): docs/SOUND.md already sets beds <= -34 LUFS, jumpscare -9 LUFS,
chase stingers -10 to -12, true peak <= -1 dBTP, menus < -26; web/src/engine/audio/audio.js uses PannerNode with
panningModel 'equalpower' and a linear distance model; tts.js speaks lines with the browser's local
SpeechSynthesis voices (fallback: a murmur). web/sounds/ has an offline render/audit pipeline (BS.1770 loudness,
centroid, seams).

Note on the owner's latest request (more frequent monster interactions: ~15 s sprinting, ~20 s, ~30 s walking,
~60 s crouching): with a contact every 15-60 s, sound has to carry most of those contacts WITHOUT a full stinger
each time, or the scare budget is spent in a minute. See section 4 ("tells, not stingers").

---

Method note: WebSearch worked; WebFetch reached only github.com in this session. designingsound.org, pcgamer.com,
audiokinetic.com, gamedeveloper.com, wikipedia.org, huggingface.co and silenthillmemories.net all failed DNS
(outside the session's allowed network). Facts from those sites come from search-result summaries of the pages
named, so treat exact wording as [S, via summary]. Model licences were read from the GitHub READMEs directly.

## 1. How acclaimed horror games make and use sound

### Dead Space (EA Redwood Shores, 2008; audio director Don Veca)
- [S] "Fear emitters": invisible objects placed in the level or attached to enemies; each declares how much fear
  the player should hear, and the effects change as the player's distance to it changes. The music is driven by
  the same emitters: four stereo layers mixed in real time by the current fear level. (Game Informer "Noises in the
  Dark" 2009; Original Sound Version; killscreen on Dead Space 3's fear system; designingsound.org Lackey and Veca
  interviews, via summaries.)
- [S] Goal stated by Veca: create mood through overall sound design, blurring music and effects; sound designer
  Andrew Lackey: "it's actually hard to define where sound effects and music end and ambiences begin."
- [S] Source material was hands-on and everyday: a BART train's metallic screech became one of its scariest
  sounds (PC Gamer); for Dead Space 3, smashing produce made skull-impact squelches (Kill Screen).
- [S] Veca did NOT want the creatures to sound like lions, tigers and bears (animal roars avoided); DS2 audio
  director Andrew Boyd: creatures rooted in humanity must "articulate believably, which doesn't necessarily mean
  realistic" (Bloody Disgusting).
- [I] For ROVLOC: a fear-emitter is exactly a per-monster scalar (distance and line of sight) driving a few
  crossfaded tension layers. That is cheap in Web Audio (3-4 looping GainNodes) and works on the Chromebook tier.

### Alien: Isolation (Creative Assembly, 2014; Byron Bullock, Sam Cooper; music Haydn Payne)
- [S] The mix reacts to stealth: "our mix engine can react to how stealthy the player is being ... as the player
  moves slowly past the Alien the sound mix will change, and adapt, favouring Amanda's sounds - footsteps and
  clothing - and the alien." (Bullock, Kotaku AU, via summary.)
- [S] The creature hunts by sound, so the player must think about the noise they make (Bullock).
- [S] About 100 simultaneous voices (Bullock). [S] "a conscious decision not to have wall-to-wall music"; during
  encounters one of a set of suspense pieces plays (Payne). [S] The creature is not scripted, so "the player can
  never get comfortable" (Cooper and Bullock, MCV).
- [I] For ROVLOC: when the player crouches near the monster, duck the bed and music by ~6 dB and lift the player's
  own foley and the monster's steps: the player hears the danger more clearly exactly when they are being careful.

### Resident Evil 7 (2017) and Resident Evil 2 remake (2019), Capcom
- [S] RE7 audio director Wataru Hachisako put "tremendous emphasis on capturing the sounds of daily life" (VICE,
  "The scariest thing in Resident Evil 7 is the silence"). Over 700 props/gimmicks recorded, including ambiences
  recorded for the game (Native Instruments interview). Outside studio La Hacienda Creative recorded hundreds of
  elements with an omni-binaural microphone. Audiokinetic blog: the score is largely musique concrete, built from
  recorded objects so music and room tone merge.
- [S] RE2 remake used Capcom's real-time binaural system (audio director Kentaro Nakashima, Digital Trends).
  Nakashima compared it with RE7: "A larger field of vision brings with it a greater sense of security" (GamingBolt),
  i.e. the third-person camera needed sound to restore unease. [S] Mr. X's heavy footsteps were not drawn from a
  real person's footsteps (director Kazunori Kadoi, PC Gamer, via a VGR summary [U]); his thumping steps and door
  slams are the famous dread device (Bloody Disgusting editorial).
- [I] For ROVLOC: the monster's steps are the single most valuable gameplay sound. Make them unmistakable (low,
  heavy, slightly too slow, a porcelain tick on every second step: our own invention), audible through walls with
  a low-pass, and never shared with any other sound.

### Silent Hill (Konami; Akira Yamaoka)
- [S] Industrial noise was chosen to differ from other games; its "cold, rusty" quality fit (Spelmusik 2002).
- [S] The radio static warns of nearby enemies: Yamaoka chose a sound "to which players aren't instinctually
  attuned" (GDC 2010, GameSpot report). "Instead of predictable BGM, I tried to play only atmospheric sounds or
  to use noise when an enemy appears" (Konami interview 2014).
- [S] He brought sound in "three frames ahead" of the picture to induce anxiety (GameSpot GDC report).
- [I] For ROVLOC: an ORIGINAL warning device in the same spirit (not a radio): the torch's bulb buzzes and the
  battery whines when the monster is within ~30 studs, getting rougher with distance. It uses an object the player
  already holds, so it is a tell, not a stinger, and it suits a contact every 15-60 s.

### Amnesia: The Dark Descent (Frictional, 2010)
- [S, review] silence "retreats when danger is near or ... when your sanity is low, replaced with ... layering of
  truly unnerving sounds - human and otherwise." Credits for sound vary by source (Samuel Justice / Mikko Tarmia
  named) [U]. The in-game developer commentary is the primary source and was not reachable.

### Outlast (Red Barrels)
- [S] Francis Brus was the studio's only audio person for years (sound, voice design, systems, foley, music
  direction). [S] A hunting enemy "mutters to himself as he hunts for you, offering clues to his position" (Game
  Informer 2013). [S] Score and effects blur: hard to tell whether a scream is SFX or soundtrack (gamemusic.net).
- [I] Muttering as a position cue is directly useful for ROVLOC's talking monster: a quiet, intelligible mutter
  that is also the tell.

### Phasmophobia (Kinetic Games)
- [S] During a hunt the ghost hears player voices by microphone loudness and moves to search where it heard them;
  sensors' detection window raised from 2 to 3 s; speech recognition lets the ghost and items react to key words
  (GamesRadar, Twinfinite, GameSpot coverage, 2021+). Footstep hearing is unconfirmed [U].
- [I] ROVLOC is not doing voice chat yet; if it ever does, mic loudness as noise is the proven mechanic.

### Roblox: DOORS
- [S, DOORS wiki] Certain audio cues or visual imagery warn the player before an entity spawns. [S, Villains wiki]
  one rushing entity's audio grows louder approaching and quieter leaving: the main cue for when to hide; lights
  flicker before it (Destructoid guide). Claims about which source recordings were layered (jet engine, static,
  vacuum) come from fan pages and are [U].
- [I] Pattern worth taking: every threat has (1) a warning a few seconds ahead, (2) a loudness ramp that encodes
  distance, (3) a different timbre per behaviour. Never copy their sounds.

### Roblox: Pressure, The Mimic, THRESHOLD; and FNAF, P.T., Poppy Playtime
- [S, fan wiki/guides, details disagree] Pressure: before its rushing monsters arrive, nearby electronics/lights
  flicker, then a loud scream rises as it closes; one variant has NO light cue (sound is the only warning); one
  flickers twice with the roar ~4 s after the second flicker; one rebounds several passes. (urbanshade.org wiki,
  Dot Esports, Pro Game Guides.) [I] Technique: the warning channel itself is varied per threat, and the time from
  warning to arrival (~3-5 s) is the hide window.
- [S] The Mimic (Roblox) was nominated for Best Audio Design at the 2022 Roblox Innovation Awards; music by Ampient;
  credited voice actors (draft Wikipedia page). No first-hand breakdown found [U].
- [S] THRESHOLD (Reskioat): Chase Mode asks players to collect keys/papers "while staying silent"; no source
  describes its sound design [U]. (rotrends, allthings.how summaries.)
- [S] FNAF 4 dropped the cameras and made the player rely on audio cues (breathing at the doors) to track threats
  (Wikipedia FNAF 4). The original's scream was ~5 s from a 1990s sound library (TCRF). [I] Sound-only tells are a
  proven, cheap, scalable core loop; the scream itself must never be borrowed.
- [S] P.T.: the ghost's presence is carried by audio - heavy breathing behind the player and extra footsteps when
  she is close; she can be heard walking the hall from inside the bathroom (PlayStation LifeStyle, GameRant).
  [S] A dev-hack showed she is often just off-screen (Game Developer). [I] "Extra footsteps that are not yours"
  is a strong technique for ROVLOC's frequent, harmless contacts.
- [S] Poppy Playtime: creaking doors and groaning metal in the bed; no first-hand audio source found [U].

### General findings on dynamics and silence
- [S] Quiet precedes loud in horror; but "If everything suddenly gets quiet and the music drops out that is not
  necessarily scary. It can often pull the audience out" (Winifred Phillips GDC 2017, via Game Developer).
- [S] Player complaints about indie jumpscares far louder than the rest of the game; a suggested fix is to keep the
  ambience loud enough that players do not turn their volume up first (itch.io comment threads).
- [S] Alan Wake 2's team chose a wider dynamic range and said it paid off (A Sound Effect).
- [S] Sony ASWG-R001 (2013 deck): console -23 LUFS, PS Vita (handheld) -18 LUFS, true peak -1 dBTP, loudness range
  <= 20 LU; ITU-R BS.2434: games typically -24 +/-2 LKFS console, -18 +/-2 portable.
- [I] ROVLOC plays mostly on laptop and Chromebook speakers: an overall in-play loudness near -20 LUFS (between
  console and handheld) with a loudness range under ~18 LU is the right target. The current bed ceiling of -34 LUFS
  is fine as a bed, but measure the jumpscare against what the player actually hears in play (bed + steps + world,
  likely -26..-22 LUFS short-term), not against the bed alone: -9 LUFS over -34 is a 25 LU jump, which is exactly
  the "disproportionate jumpscare" complaint. Aim for a 12-16 LU jump over the preceding 10 s of play (owner: "I
  dont want the game to be too hard").

---

## 2. Voices: making rendered speech sound human

### 2.1 Writing lines that sound like real kids joking
- [S] Oxenfree (Night School Studio, GDC 2017 "Building Game Mechanics to Elevate Narrative"): walk-and-talk that
  never pauses the game; characters speak at length and can be interrupted; a selected reply is buffered to a
  natural lull, sometimes deliberately cutting in. Players named the naturalistic dialogue as one of the two things
  they latched onto (GamesRadar, Giant Bomb blog, thumbsticks GDC report). [S] "it can be difficult for adult writers
  to capture the way teenagers interact" (GamesRadar).
- [S] Natural cross-talk is hard to implement with voice acting or text (PC Gamer, "The future of dialogue").
- [I] Rules for ROVLOC's kid lines (technique, our own words):
  1. 2-9 words per line; one idea; contractions always ("did you", never "did you not").
  2. Kids interrupt: end a line with an em-dash and START the next speaker 150-350 ms BEFORE the first line ends
     (overlap built in the edit from separately rendered lines; never ask one model call to overlap).
  3. Reactions are separate tiny takes: "ha", "no way", "dude", "ew", a snort, a laugh. Two or three short reactions
     per scene make a group feel real more than any long line.
  4. Laughs ride on top: a 0.4-1.2 s laugh from another kid under the end of a joke line, 6-10 dB below it.
  5. Don't write jokes that need setup; write teasing about something on screen (the frog, the detention, the
     pizza): the current S2-S4 lines in game-spec-v2 already do this well.
  6. Direction through punctuation for models that respect it: "..." = trailing hesitation, "--"/em-dash = cut
     off, "?!" = rising shout, CAPITALS for one stressed word only ("Did you SEE"); commas add pauses (Parler-TTS
     README states commas add small pauses [S]).
  7. Render 3-6 takes per line (different seed/temperature) and pick by the automatic checks in section 4, then by
     ear once.
- Note: spec v2 makes Danny 16; the brief says fourteen-year-olds. [I] For voice targets treat the party as 14-16.

### 2.2 Open speech models: what they can do, and their licences (read from each README, 16 Nov 2026)
| Model | Licence (code / weights) | Laugh, whisper, shout | Runs on | Notes |
|---|---|---|---|---|
| Kokoro-82M | Apache-2.0 / Apache-2.0 ("can be deployed anywhere", README) [S] | No tags; only voice + speed [S] | CPU; browser via kokoro.js (Transformers.js, wasm or webgpu) [S] | 24 kHz. Voices graded: af_heart A, af_bella A-, male voices only C+ at best (am_fenrir, am_michael, am_puck); am_adam F+ [S]. No teen voices. Best as a cheap fallback / name bank. |
| Chatterbox (original, 500M) | MIT [S] | exaggeration + cfg_weight; defaults 0.5/0.5; dramatic: exaggeration >= 0.7, cfg ~0.3 [S] | GPU | Voice cloning from a reference clip (~10 s in examples). Every output carries Resemble's Perth imperceptible watermark [S]. "As of August 2026, Chatterbox is retired research and is no longer maintained" [S]: pin the version. |
| Chatterbox Turbo (350M) / Nano (110M) | MIT [S] | Native tags: [laugh] [chuckle] [cough] confirmed in README [S]; [sigh] [gasp] [groan] [sniff] [clear throat] [shush] per community reading of added_tokens.json [S, unverified file]; [whisper] [breath] only on Resemble's marketing page [U] | Turbo low VRAM; Nano on CPU ~3x realtime on 8 cores [S] | Recommended first choice for kid dialogue and the monster: tags + cloning + MIT. |
| Orpheus 3B (Canopy Labs) | Code Apache-2.0 [S]; weights listed Apache-2.0 by Featherless/Hackster, but the model is "built on the Llama-3b backbone" and a sibling checkpoint is tagged llama3.2 [S] -> weights licence AMBIGUOUS [U] | <laugh> <chuckle> <sigh> <cough> <sniffle> <groan> <yawn> <gasp> [S] | GPU (vLLM) or llama.cpp | 24 kHz; voices tara, leah, jess, leo, dan, mia, zac, zoe; repetition_penalty >= 1.1 required [S]. Use only if the HF card's licence field is confirmed. |
| Dia 1.6B (Nari Labs) | Apache-2.0 [S] | (laughs) (gasps) (screams) (sighs) (clears throat) (coughs) (inhales) (exhales) (mumbles) (groans) (chuckle) ... "use sparingly", some may misbehave [S] | GPU only, ~4.4 GB VRAM bf16 [S] | Writes two-speaker dialogue [S1]/[S2] in one pass (natural turn-taking); voice is random per run unless seeded or given a 5-10 s audio prompt; < 5 s output sounds unnatural, > 20 s too fast [S]. README says intended for research/education and forbids identity misuse [S]: read the full terms before shipping. |
| Parler-TTS Mini/Large v1 | Code Apache-2.0 [S]; Mini v1 weights Apache-2.0 per HF mirrors [S, via summary] | No tags; a text description sets gender, pitch, rate, noise, reverberation; 34 named speakers for consistency [S] | GPU/CPU | Good for "very close recording" vs "distant" variants; no laugh/whisper documented. |
| Pocket TTS (Kyutai) | Code MIT [S]; weights CC-BY-4.0 (attribution) [S, via card summaries]; voices: some CC0, some CC BY, Expresso/EARS-derived voices CC BY-NC (non-commercial) [S] | Not documented | CPU ~6x realtime on 2 cores [S] | Voice cloning by WAV; forbids impersonation without consent [S]. Avoid the NC voices. |
| CosyVoice 2 (0.5B) | Code Apache-2.0 [S]; CosyVoice2-0.5B weights apache-2.0 on HF [S, via summary] | Instruct mode (emotion, speed, volume, dialect) on the 300M-Instruct checkpoint [S]; inline [laughter]/[breath] tags not confirmed [U] | GPU | README: "for academic purposes only ... to demonstrate technical capabilities" [S]: a disclaimer, not a licence term, but note it. |
| (Fish Speech S2-Pro) | open weights, paid licence for commercial use [S] | [whisper] [laugh] [angry] | - | Avoid for ROVLOC. |

[I] Recommendation: Chatterbox Turbo (MIT) as the main renderer for all kid lines and the monster; Dia (Apache)
for one experiment: render whole two-kid exchanges in one pass for natural turn-taking, then keep whichever wins
the automatic checks. Kokoro (Apache, browser-capable) for the runtime name bank fallback (see 2.5).
Licence hygiene: reference voices for cloning must be our own consented recordings or CC0 voices; never clone a
real actor, streamer or a character from another game.

### 2.3 Adult-trained voices that must read as 14-16-year-olds
- [S] Lee, Potamianos and Narayanan (JASA 1999, 436 children 5-18 and 56 adults): male/female F0 and formant
  patterns separate from about age 11 and are established by about 15; male pitch drops fastest 12-15; teens show
  shorter segment durations; there is an "overshoot" in values between 13 and 15 before adult levels.
- [S] Pitch-only shifting sounds like a sped-up/slowed recording; formants must be handled separately to stay
  natural and intelligible (voice-design guides: iZotope VocalSynth article, Krotos, voxbooster; vendor blogs).
- [I] Practice for ROVLOC:
  1. Choose by voice first: pick the lightest, youngest-sounding reference/voice; process as little as possible.
  2. If processing: raise formants 4-8 % (a shorter vocal tract) and pitch +1 to +2 semitones, independently
     (e.g. WORLD vocoder or a PSOLA pitch + LPC formant warp offline). More than +3 semitones or +10 % formants
     reads as cartoon. Speed x1.03-1.08 (shorter segments, per Lee et al.).
  3. Boys 14-16: F0 median ~110-160 Hz (mid-change, varies a lot); girls ~200-240 Hz. These bands are my estimate,
     not values from the paper [U]; measure renders with a pitch tracker and keep each character in one band.
  4. Never apply the same shift to every kid: give each a different base voice so they separate without effects.

### 2.4 Recorded laughs, gasps and screams mixed with rendered lines
- [I] Get non-verbal takes from the model itself first (Chatterbox Turbo/Orpheus/Dia tags) so the timbre matches.
  Where a recorded CC0 take is used (Freesound with the CC0 filter, opengameart CC0, Kenney CC0): match (a) level:
  3-6 dB under the speaker's lines; (b) bandwidth: TTS output is 24 kHz (Kokoro, Orpheus [S]), so low-pass the
  recording at ~11 kHz; (c) room: put both through the same reverb send; (d) voice: same apparent age and sex, or
  bury it in a group laugh / off-screen. A scream from a different person than the speaker is the most obvious
  mismatch: render or record per character.
- [S] Nonverbal vocalisations remain a weak point of all TTS (arXiv benchmark of 15 systems: low-SNR oral cues and
  long affective NVVs are bottlenecks). [I] Keep rendered laughs short (< 1.2 s) and layered.

### 2.5 The monster's voice: frightening and still understood
- [S] Spec v2 already decides: it speaks in its host's voice (Danny's, later Gus's), slowed (web pitch 0.4, rate
  0.82), with a throat layer (breathy growl + whisper double, syllable-gated) on an HRTF panner; one line per ~45 s
  outside chases; says your name with rising probability per stage.
- [S] Outlast: a hunter mutters as he hunts, which gives his position (Game Informer 2013).
- [S] Creature voices: pitch and formants must move separately or the voice sounds like a slowed tape; large
  downward shifts smear consonants; suggested numbers vary: pitch -5 to -12 semitones with formants -10 % to -40 %;
  a sub layer very low in level adds weight without being heard as a second voice; multiband distortion adds grit
  only where wanted; start from the clearest possible performance (Krotos tutorial; iZotope; vendor blogs - numbers
  disagree, treat as starting points).
- [I] ROVLOC's recipe (our own; nothing copied):
  1. Render the line clean, in Danny's own cloned voice, calm and slightly too slow (rate 0.85), with an audible
     inhale before it and none after (wrong breathing reads as inhuman).
  2. Main layer: pitch -3 to -4 semitones, formants -8 to -12 % (bigger body, consonants intact). Keep 1-4 kHz
     untouched or +2 dB: that band carries intelligibility.
  3. Whisper double: the same line rendered as a whisper (or noise-vocoded from the clean take), 10-14 dB down,
     offset +25-40 ms: the "two voices at once" effect stays legible.
  4. Sub layer: one octave down, low-passed at 300 Hz, 16-20 dB down: felt, not heard.
  5. Porcelain: a short comb/resonator (2-3 kHz, < 15 ms) on the main layer at 15-25 % wet: a faint "inside a mask"
     ring that is ours.
  6. Gate: run Whisper on the FINISHED processed line; if WER > 10 % back off steps 2-5. The owner asked for
     "real words" and "good English": intelligibility is a hard gate, not a taste.
  7. Calling lines heard far away should be the clearest (he wants to be heard); "Behind" (Ear) lines dry and close,
     breathy, 2-4 dB quieter than Head lines.
- Names. [I] Offline rendering cannot know a player's name, and the spec's {name} slots need one. Option A (best
  sound): a pre-rendered NAME BANK - the ~500-1,000 most common first names/nicknames, each rendered by the same
  voice inside the same carrier sentence ("Come out, NAME. It's just me."), cut at word timestamps from forced
  alignment (Whisper word timestamps), ~0.5 s each, Opus ~24 kbps -> about 1-2 KB per name, fetched only for the
  names in the room; a name not in the bank uses the nameless twin (already in the spec). Carrier lines are
  rendered with a placeholder name of the same syllable count and spliced with 20-40 ms crossfades; the throat
  layer hides the seam. Option B: kokoro.js in a Worker at lobby time renders the 1-4 names on desktop tiers only
  (Kokoro voices do not match a cloned Danny, so B is a fallback) [U: Chromebook speed not measured]. Roblox keeps
  AudioTextToSpeech for names (spec RP04).

---

## 3. The dialogue mix of a cutscene

### 3.1 Levels and ducking
- [S] Netflix mix spec: dialogue around -27 LKFS dialogue-gated (+/-2 LU), true peak -2 dBTP (backlot help).
  EBU R128 s4 allows dialogue normalised up to -23 LUFS for cinematic content.
- [S] Ducking practice: music and ambience dip "a few dB" with quick attack and gentle release (bugnet); unofficial
  tables give -6 to -9 dB voice-triggered ducks and ambience sitting 12-18 dB under voice (aggregator pages, weak).
  Unity's Out of Circulation case study keeps background minimal and avoids SFX during conversation. Baldur's Gate 3
  (Audiokinetic blog) found plain volume ducking chaotic and moved to frequency-based sidechaining that carves only
  the conflicting band. Roblox's Beyond the Dark docs show a sidechain compressor on an ambience bed.
- [I] ROVLOC cutscene targets: dialogue short-term ~-20 LUFS on laptop speakers; bed 14-18 dB under dialogue;
  music 10-12 dB under; during each line duck music/ambience 6 dB (attack 40 ms, release 600 ms) AND dip 1.5-4 kHz
  in the non-dialogue buses by a further 3-4 dB (Web Audio: a peaking BiquadFilter whose gain is automated from the
  line's known start/end, no real sidechain needed because the timeline is authored). Effects may exceed speech
  only in gaps between lines.

### 3.2 Placing voices in the space
- [I] Car park / yard at dusk (outdoor, open): almost no tail. Use 2-3 early-reflection taps from the school wall
  (distance d studs -> delay 2d/343 m/s; ~10 m -> ~58 ms slap at -14 dB), a 0.3-0.5 s faint diffuse tail at -20 dB,
  and a light high-shelf cut (-2 dB at 8 kHz) for the cool air. Close dialogue (two-shot) almost dry.
- [I] Off-screen line from inside/near the steel dumpster: a short metallic IR (0.1-0.25 s) with strong resonances
  in the 300-1,500 Hz range (a steel box ~1.8 m wide resonates near c/2L ~ 95 Hz fundamental with dense modes
  above), and a low-pass ~1.5-2 kHz while the lid is closed.
- [I] Muffled under the mask ("Get it- GET IT OFF!"): low-pass ~1 kHz, +3 dB at 250 Hz, dry, close, plus cloth/
  plastic rustle foley.
- [I] IRs: generate them offline from the box geometry (exponentially decaying noise per octave band + image-source
  early reflections from the nearest walls). This avoids per-file licence checks: OpenAIR's IRs are Creative
  Commons but the licence varies per file [S]; check each before use.

### 3.3 Timing to picture, subtitles, lips
- [S] ITU-R BT.1359: detectability about +45 ms (sound early) to -125 ms (sound late); acceptability about +90 to
  -185 ms. [S] Yamaoka brought sound in "three frames ahead" (~50 ms at 60 fps) to make anxiety.
- [I] Start each line's audio 0-40 ms before the mouth opens; stingers 2-3 frames before the cut they mark.
- [S] Subtitles: 42 characters per line, two lines max (Netflix); reading speed 17 cps adult / 13 cps children in
  most Netflix languages (English may allow 20/17) [S, via summaries]; name the speaker on each change; captions
  for sounds describe the sound, not the action, and directional cues matter for horror (Xbox Accessibility
  Guidelines 104, Steamworks accessibility docs). [I] Use <= 15 cps for ROVLOC (young players, reading while scared).
- [S] Rhubarb Lip Sync: offline; WAV/OGG in, optional dialogue text improves results; outputs timed mouth shapes A-F
  (+ G, H, X) as TSV/XML/JSON; PocketSphinx recogniser for English (licence file not named on the page; believed MIT
  [U]). [I] Bake one JSON cue track per rendered line into the cutscene data; at runtime pick the blend shape per
  cue. Fallback (and for the monster): jaw open = smoothed RMS of the 300-3,000 Hz band, 30 ms attack, 80 ms release.

---

## 4. What ROVLOC should adopt (in order of payoff)

All of this is technique. ROVLOC's sounds come from CC0 recordings (opengameart.org, Kenney, Freesound CC0 only)
transformed in web/sounds/, and from our own renders; no other game's audio is sampled, imitated or re-created.

1. Real rendered voices for every line (HIGH). Replace browser SpeechSynthesis in cutscenes with offline renders
   (Chatterbox Turbo, MIT; tags [laugh] [chuckle] [gasp]...). Keep speechSynthesis only as the last fallback.
   Cost: offline GPU time; at runtime only Opus files (~10-20 KB per line at 24-32 kbps). Chromebook: same files.
2. Tells, not stingers, for the frequent contacts (HIGH; ties to the owner's 15/20/30/60 s request). With a contact
   every 15-60 s, at most ~1 in 6 contacts may use a loud stinger. The rest use a ladder of tells, chosen so the
   player hears more while being careful (Alien: Isolation's stealth mix [S]):
   - distant: an extra footstep that is not yours (P.T.-style technique [S]), a door easing shut, a vent knock;
   - near: his slow heavy steps with a porcelain tick, a breath, the torch bulb buzz (our own device);
   - very near / sees you: a mutter in Danny's voice (Outlast-style position cue [S]), then the chase cue.
   Loudness: distant tells -32 to -28 LUFS short-term, near tells -26 to -22, stinger -12 to -10, jumpscare <= 12-16 LU
   over the previous 10 s of play. Crouching players get the quiet tells; sprinting players get the obvious ones.
3. Fear-emitter tension layers (HIGH). A 0-1 "dread" value from distance, line of sight and state drives 3 looping
   stems (low drone, pulse, high texture) crossfaded with GainNodes (Dead Space's four layers [S]). No wall-to-wall
   music (Alien: Isolation [S]). Cost: 3 looping buffers; trivial on Chromebook.
4. Stealth-reactive mix (HIGH). Crouched and monster within ~25 studs: bed -6 dB, music -6 dB, player foley +2 dB,
   monster steps +3 dB, over 1.5 s. Cost: a few gain ramps.
5. The monster voice recipe and intelligibility gate (HIGH): section 2.5. Name bank for {name} lines.
6. Occlusion that also reverberates (MEDIUM-HIGH). Keep the spec's per-wall low-pass (2,400 / 1,100 / 600 Hz) and
   0.5 gain per wall; add: the wetter the more walls (send to the room reverb +3 dB per wall), so through-wall
   sounds are muffled AND roomy, which is how real occluded sound reads. Cost: one BiquadFilter + one send per
   positional voice (pool them); Chromebook: walls counted at 5 Hz as already specified.
7. Room reverb per area (MEDIUM). One ConvolverNode per area type with synthetic IRs: Basement concrete ~1.4-1.8 s,
   Hallways tile/lockers ~1.0-1.3 s with a flutter echo, Auditorium ~1.8-2.2 s, Roof/outdoors no tail + one slap.
   Crossfade sends at doorways. Chromebook: one shared convolver with a 0.8 s IR, or a cheap feedback-delay reverb.
   (Numbers are typical RT60s for such rooms, my estimate [U].)
8. HRTF where it counts (MEDIUM). Today the engine uses panningModel 'equalpower'. On desktop tiers switch the
   monster's steps, voice, teleport warning and the Ear channel (<= 4-8 sources) to 'HRTF'; keep equalpower for the
   rest and on the Chromebook tier. [S] HRTF costs memory for the HRIR set and more CPU; Chrome engineers noted the
   HRTF database loads as soon as a panner is created with the default model (W3C public-audio list, 2014); third-
   party claims of ~10x cost and 4-8 mobile sources are anecdotal [U]. Offer "Headphones (3D)" as a setting.
9. Master chain (MEDIUM). Buses -> master gain -> DynamicsCompressor as a safety limiter (threshold -3 dB, knee 0,
   ratio 20, attack 0.002 s, release 0.12 s) -> destination; keep the true-peak control offline (the pipeline already
   limits to -1 dBTP). No constant heavy compression on the mix (practitioner checklist [S]). Desktop "Max" tier
   may add an AudioWorklet look-ahead limiter.
10. Cutscene mix automation (MEDIUM): section 3. Authored ducks and band dips from the timeline; reverb per shot.
11. Lip cues from Rhubarb (LOW-MEDIUM): baked JSON per line; RMS jaw fallback.
12. Subtitles/captions with direction (LOW cost, required): already specified; add captions for the tells
    ("[slow footsteps - behind]") so deaf/hard-of-hearing players get the same warning.

### Things to avoid
- Copying or closely imitating any game's sounds: DOORS/Pressure entity roars, the FNAF scream, The Mimic's voices,
  Silent Hill's radio static device, Dead Space's or the Xenomorph's vocals. Take the techniques only.
- Cloning a real person's voice (actor, streamer, YouTuber) or a game character; using Kyutai voices marked
  CC BY-NC (Expresso/EARS-derived); Fish Speech S2-Pro (paid commercial licence); Orpheus until the weights licence
  is confirmed on the model card; freesound files that are not CC0; OpenAIR IRs without checking each file.
- A stinger on every contact (with contacts every 15-60 s the scare budget is gone in minutes; players go numb).
- Jumpscares 20+ LU over what the player is hearing (top complaint in player feedback [S]); silence drop-outs used
  as a scare by themselves (Phillips, GDC 2017 [S]).
- Pitch-only monster processing; formant/pitch shifts so deep that Whisper cannot transcribe the line.
- More than +3 semitones on a kid voice (chipmunk); the same processing on every kid.
- HRTF on every source on the Chromebook tier; IRs longer than ~1 s on Potato.
- Relying on browser SpeechSynthesis for cutscenes (voices differ per device; Chromebook voices are robotic).

---

## 5. Testing sound and speech WITHOUT a human listener

Most of this extends web/sounds/audit.mjs and test.mjs (they already measure BS.1770 loudness, centroid, seams).

Per file (every sound and every rendered line)
- [ ] Clipping: no sample at |x| >= 0.999; true peak (4x oversampled) <= -1 dBTP.
- [ ] DC: |mean| <= 0.0025; first/last sample >= 40 dB under peak (existing rules).
- [ ] Loudness per class (BS.1770 momentary max / short-term / gated integrated) inside the declared range;
      tells -32..-22, stingers -12..-10, jumpscare <= declared; loudness range of loops <= 6 LU (a bed must be even).
- [ ] Spectrum: centroid, 85 % roll-off, spectral flatness, share of energy under 250 Hz; "laptop loss" (loudness
      after a 250 Hz high-pass) < 9 dB for anything that must be heard on Chromebook speakers.
- [ ] Loop seams: render 3 periods; at each wrap, sample jump |x[0]-x[N-1]| < 0.01 x peak; short-time spectral flux
      across the seam <= 1.5x the loop's median flux; RMS in the 50 ms either side within 1 dB; no click (energy
      above 8 kHz in a 5 ms window at the seam <= 2x neighbouring windows).
- [ ] Tails: last 5 ms >= 50 dB down; no truncated reverb.

Per rendered line (speech)
- [ ] Transcribe with Whisper (MIT; large-v3 or a smaller model on CPU) with a fixed prompt; normalise text (case,
      punctuation, numbers); WER vs the script: <= 5 % for clean kid lines, <= 10 % for processed monster lines,
      0 errors on the player's name in name-bank clips.
- [ ] Hallucination checks: duration / syllable count within the take's expected range (+/-35 %); no repeated
      n-grams in the transcript that are not in the script; no speech in the last 300 ms after the script ends.
- [ ] Speaking rate 2.0-3.8 syllables/s for kids (faster when excited), 1.4-2.4 for the monster.
- [ ] Pitch: F0 median per character within its band (2.3) and every take of a character within +/-1.5 semitones
      of that character's median.
- [ ] Speaker consistency: speaker-embedding cosine similarity (e.g. an ECAPA model) >= 0.75 between takes of one
      character, <= 0.6 between different kids (thresholds are my estimate, calibrate on the first batch [U]).
- [ ] Naturalness proxy: predicted MOS (UTMOS) for each take; reject the bottom outliers per line rather than use an
      absolute threshold (UTMOS is a proxy, not a listener [S]).
- [ ] Slot fit: line length <= its cutscene slot (spec's words / (2.6 x rate) rule) and onset aligned to the mouth
      cue within +45/-125 ms (BT.1359).
- [ ] Subtitles: <= 42 chars per line, <= 2 lines, <= 15 cps; speaker label present.

Per mix (cutscenes and gameplay traces)
- [ ] Render each cutscene with the engine's real graph in an OfflineAudioContext; measure dialogue-to-bed ratio
      (short-term loudness during lines vs the same buses in gaps) >= 12 dB; ducks engaged at every line.
- [ ] Transcribe the FULL MIX with Whisper: WER on the mixed render <= clean WER + 5 points (the best single
      automatic intelligibility check).
- [ ] Master true peak <= -1 dBTP; nothing hits the safety limiter for more than 3 dB of gain reduction.
- [ ] Gameplay trace (a bot run): log short-term loudness every 100 ms; the jump at each scare <= 16 LU over the
      previous 10 s mean; count stingers per minute (<= 1 per ~90 s) and tells per minute (matches the 15/20/30/60 s
      design per movement mode).
- [ ] Spatial sanity: for a source at known bearings, interaural level difference sign matches left/right; with
      walls 0/1/2, the HF energy (> 2 kHz) drops by the specified filter steps.

---

## Sources (read directly = GitHub; the rest via search summaries)
Read directly: github.com/resemble-ai/chatterbox; github.com/hexgrad/kokoro (+ kokoro.js/README.md);
github.com/canopyai/Orpheus-TTS; github.com/nari-labs/dia; github.com/huggingface/parler-tts;
github.com/kyutai-labs/pocket-tts; github.com/FunAudioLLM/CosyVoice; github.com/DanielSWolf/rhubarb-lip-sync.
Via search summaries: gameinformer.com "Noises in the Dark" (Dead Space, 2009); designingsound.org Lackey and Veca
interviews; killscreen.com Dead Space 3 fear system; pcgamer.com BART train article; bloody-disgusting.com Dead Space 2
sound; kotaku.com.au and mcvuk.com Alien: Isolation audio; thesoundarchitect.co.uk/alienisolation; vice.com "The
scariest thing in Resident Evil 7 is the silence"; blog.native-instruments.com "engineering the sound of fear";
lahaciendacreative.com RE7; audiokinetic.com "Out of sight: musique concrete in Resident Evil 7"; digitaltrends.com
RE2 sound interview; gamingbolt.com Nakashima; pcgamer.com Kadoi Mr. X interview; silenthillmemories.net Yamaoka
interviews (2002, 2014); gamespot.com GDC 2010 Yamaoka session; gameinformer.com Outlast 2013 preview;
gamesradar.com / twinfinite.net Phasmophobia voice hearing; doors-game.fandom.com; villains.fandom.com;
urbanshade.org Pressure wiki; dotesports.com Pressure monsters; en.wikipedia.org FNAF 4; tcrf.net FNAF;
playstationlifestyle.net and gamerant.com P.T.; gamedeveloper.com P.T. camera hack; gamedeveloper.com Winifred
Phillips GDC 2017; asoundeffect.com Alan Wake 2; sambuz.com Garry Taylor (Sony) loudness deck; itu.int BS.2434,
BT.1359; backlothelp.netflix.com mix spec and timed-text guides; audiokinetic.com Baldur's Gate 3 audio; bugnet.io
ducking; learn.unity.com Out of Circulation; create.roblox.com Beyond the Dark sound design; gamesradar.com Oxenfree
interruptions; thumbsticks.com GDC 17 Oxenfree; pubmed 10089598 (Lee, Potamianos, Narayanan 1999); izotope.com
VocalSynth voices; krotosaudio.com monster voice; resemble.ai/chatterbox-turbo; huggingface.co Chatterbox Turbo
discussion 21; featherless.ai Orpheus listing; hackster.io Orpheus; huggingface.co Kyutai TTS / pocket-tts mirrors;
huggingface.co CosyVoice2-0.5B; huggingface.co parler-tts-mini-v1; emelia.io Fish Speech S2; arxiv.org TTS
evaluation papers (Whisper WER, UTMOS); lists.w3.org public-audio 2014 HRTF thread; codereview.chromium.org 652073003;
openair.hosted.york.ac.uk; devdocs.xbox.com XAG 104; partner.steamgames.com accessibility features.
