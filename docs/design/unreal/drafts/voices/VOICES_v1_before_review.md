# STAY BEHIND: the voice plan

Written 21 November 2026 for the builder on the owner's PC (RTX 5070 12 GB, 16 GB memory) and for the owner to read. The first proof (part 9) tests it.

Marks: **[checked: source]** means read today from the source; **[from memory]** means not re-checked today; **[estimate]** is a number worked out here. "Real" in this plan always means a recording of a person who agreed in writing to record for this game.

---

## 1. The bar

**A listener who is not told must take every human line for a recorded person.** Not "good for AI": if the owner, listening blind, picks out the machine take, it fails.

What that means, kind by kind, and how hard each is for machines today:

| Kind of line | What a real person does | Machines today |
|---|---|---|
| Ordinary talk | uneven rhythm, stresses the word that matters, swallows small words ("gonna", "c'mon"), pitch that wanders and wobbles, breath at thought breaks | **Mostly solved** by the best engines, when the reference voice is itself lively (round 2 proved this) |
| Jokes, teasing | timing: the beat before the punchline, a smile you can hear, a half-laugh on a word | **Medium.** Laugh tags exist; a laugh *inside* a word is still rare |
| Whispering | no voice buzz at all, consonants loud, breathy, close | **Medium.** Tags and instructions exist; whispers often come out as quiet talking, or the words smear |
| Frightened | short phrases, breath in the wrong places, pitch up, voice tight | **Medium to hard.** "Fear" usually comes out as fast talking |
| Shouting | the voice strains and cracks, not just gets louder | **Hard.** Engines make loud reading; real strain is rare |
| Crying | the voice breaks mid-word, wet breath, words fight through | **Hardest.** The best tags give a sob before or after, rarely words *while* crying |
| Laughing for real | a laugh that grows out of the speech | **Hard** |
| Talking over each other | two people overlap, cut in, trail off | **Hard for engines** (they make one speaker at a time); easy to build by placing two real-sounding lines over each other |
| Out of breath | gasps between word groups, words pushed out on the out-breath | **Hard** to generate; easy to perform |
| On a walkie-talkie | narrow band, clipped, static, the press click | **Easiest:** the radio sound hides small faults (part 6 sets the fair limit) |

The hard rows are the sad and frightening scenes, the ones that make the story land. So the plan ends in real performances for the main cast and tests every hard kind early.

---

## 2. The routes, ranked by how real they sound

### Route A: real recordings by consenting people (most real)

**Rights:** each person signs a release before recording; a parent or guardian signs too for anyone under 18. It names: the voice, any face video, the processed versions (the hunter's whisper and the Mimic calls), use in a game that may be sold, worldwide, for the life of the game, credit wording, and the right to withdraw before release. No release, no recording.

**Equipment that is enough** [from memory]: a recent phone for a first pass; a USB microphone with a pop filter (about $60 to $150) is better. The room matters more: a small room full of soft things (a closet of clothes, a duvet hung behind the speaker). Record WAV at 48 kHz, 24-bit, mono, the mouth 15 to 20 cm from the microphone and slightly off to the side; peaks around -10 dBFS so shouts don't clip. Record 30 seconds of silence (room tone) at the start of every session.

**For faces:** Epic asks for at least 16 kHz and as little background noise as possible, because a cleaner signal gives cleaner face animation [checked: dev.epicgames.com/documentation/metahuman/audio-capture-recommendations]. For the 30 to 40 key cutscene lines, film the speaker's face on a second phone at the same time, front-lit, focus and exposure locked, for MetaHuman's video solve (report 04, 3.2). One line per file, a clap or tap at the start of each take for sync.

**Directing people who are not actors** [from memory, standard practice]:
- Tell them the situation, never how to say it: "You've been awake two days. The thing is in the hall. Kayla has to hear you but it mustn't."
- Let them change words to how they would say it. The script sheet marks which lines must stay word-for-word (codes, names, lines the hunter re-uses).
- Make the body do it: crouch for hiding lines, run on the spot for winded lines, hold something heavy for strain.
- Record two people in the same room for dialogue when possible, each on their own phone or microphone close to them, so they can interrupt.
- Three takes of each line: as written, a bit bigger, a bit smaller. Then one free take.
- Record breaths, gasps, efforts, laughs, cries and screams as their own short list at the end, when people are warmed up and less shy.
- Sessions of 45 minutes; shouting and crying last.

**Limits:** scheduling, rooms, acting. Fixed by retakes, not processing.

### Route B: a real performance, converted to a designed voice (speech-to-speech)

A consenting person acts every line; a conversion model keeps their timing, breath, cracks and sobs and swaps the sound of the voice for a **designed** character voice (made from a description by route C, so no one is copied). One or two willing performers can then carry characters they can't sound like.

| Tool | Licence (read today) | What it does | On 12 GB |
|---|---|---|---|
| **Seed-VC** (v1 and v2) | GPL-3.0 for code and weights [checked: github.com/Plachtaa/seed-vc LICENSE; huggingface.co/Plachta/Seed-VC card] | zero-shot conversion from a short target clip; can be fine-tuned on a target voice; v2 has a switch to *keep* the source's accent and emotion (`--convert-style false`) [checked: README] | yes: real-time on an RTX 3060 laptop per its README [checked] |
| **Chatterbox VC** | MIT; archived August 2026, no updates [checked: github.com/resemble-ai/chatterbox README, example_vc.py] | zero-shot conversion to a target clip | yes [from memory] |
| **RVC** | MIT; its base models were trained on the VCTK set [checked: RVC-Project README and LICENSE] | high fidelity once a model is trained on 10 to 30 minutes of the target voice | yes [from memory] |
| OpenVoice V2 | MIT [checked: huggingface.co/myshell-ai/OpenVoiceV2] | tone-colour converter | weaker; backup only |
| Vevo, Vevo 1.5 | CC-BY-NC / NC-ND [checked: cards] | not usable (non-commercial) | |

The GPL covers the program, not the sound it makes, and the program is never shipped [from memory: GPL FAQ]; if that is ever questioned, use RVC or Chatterbox VC.

**How good:** the Seed-VC authors report better speaker similarity than per-speaker RVC models but slightly lower audio quality [checked secondhand: seed-vc EVAL.md]; one hands-on review found it keeps breaths and phrase endings, with breaths sometimes too loud [checked secondhand: techno-edge.net]. Weak points [from memory]: whispers (nothing voiced to convert), screams, and big jumps of age or sex, so match performers roughly to the role. **Method:** render 20 to 30 minutes of the designed voice (route C), fine-tune Seed-VC or train RVC on it, then convert the performance.

**Rights:** the performer's release must name conversion. The target voice is designed, so it copies no one.

### Route C: the best text-to-speech a 12 GB card can run under a usable licence

| Engine | Licence (read today) | Why it is here | Size |
|---|---|---|---|
| **Qwen3-TTS 1.7B: VoiceDesign, Base, CustomVoice** | Apache-2.0 [checked: huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign card; QwenLM/Qwen3-TTS README] | **designs a voice from a written description** (age, timbre, pace, delivery); the README gives a "Voice Design then Clone" workflow that turns the designed clip into a reusable speaker [checked]; CustomVoice takes spoken instructions for emotion and pace [checked] | 1.7B; about 6 to 8 GB [checked secondhand: dev.to guide] |
| **Maya1** | Apache-2.0 on the card [checked: huggingface.co/maya-research/maya1] | voice from a description **plus** inline tags: `<whisper> <cry> <gasp> <sigh> <laugh> <laugh_harder> <chuckle> <gulp> <scream> <angry>` and more [checked: card] | 3B; fits in 12 GB in bf16 [estimate] |
| **Chatterbox (full and Turbo)** | MIT; **retired research since August 2026, no updates** [checked: README] | the engine behind the voices the owner already called "good"; `exaggeration` control; Turbo tags `[laugh] [chuckle] [cough]` [checked]. Every output carries an inaudible Perth watermark [checked] | 0.35 to 0.5B |
| **Step-Audio-EditX** | Apache-2.0 [checked: github.com/stepfun-ai/Step-Audio-EditX LICENSE] | **edits an existing take**: emotion (fearful, sad, angry...), style (whisper...), and adds breathing, laughter, sighs, inhale, exhale [checked: README]. Among the top open models in the Speech Arena in spring 2026 (about 1108 Elo) [checked secondhand: artificialanalysis.ai open-weights board via search] | 3B; **12 GB is "a critical value", 16 GB safer; tested on Linux** [checked: README] → run it in WSL2, alone, as a fixer |
| **Dia2 2B** | Apache-2.0 [checked: huggingface.co/nari-labs/Dia2-2B] | two speakers in one pass (`[S1]`/`[S2]`) with non-speech sounds; for back-and-forth banter tests | 2B |
| Kokoro 82M | Apache-2.0 [checked: card] | the stock voices the old references were blended from; fast fallback | tiny |

**Usable only with conditions** (read today, not first choices): IndexTTS2 (bilibili licence: royalty-free, separate licence needed above 100 million monthly users or RMB 1 billion revenue, plus pass-down and indemnity clauses [checked: index-tts LICENSE]); Higgs Audio v2 (Boson licence built on Meta's Llama 3 licence: free under 100,000 annual active users, notices required [checked: bosonai LICENSE]); NVIDIA Magpie (NVIDIA Open Model Licence [checked], but one of its stock voices is named after a real volunteer reader, so that voice is never used).

**Not usable** for a game that may be sold: Fish Audio S2 Pro (research licence) [checked secondhand: free-voice-clone list]; Voxtral 4B TTS (CC-BY-NC-4.0) [checked: card]; Breeze TTS 2 (non-commercial) [checked secondhand: orcarouter.ai]; XTTS-v2 (non-commercial) [from memory].

**Limits of route C:** crying, shouting, real laughter, breathlessness (part 1). No published listening test of English whispers or crying was found for any open model: the first proof measures them.

### Route D: a paid service (described only; nothing is bought)

**ElevenLabs** is the reference. Eleven v4, its newest model, takes bracketed direction such as `[whisper]`, `[shouting]`, `[terrified]` [checked: elevenlabs.io/blog/eleven-v4]. It also offers Voice Design from a description and a Voice Changer (speech-to-speech: route B as a service) at 1,000 credits a minute, or $0.12 a minute through the API [checked: elevenlabs help centre and pricing via search]. Plans: Creator $22 a month with 121,000 credits, Pro $99 with 600,000 [checked: elevenlabs.io/pricing via search, the page itself was blocked here]; about 1 credit per character for v4 [checked secondhand: glbgpt.com]. **Terms:** free accounts may not use the output commercially; paid accounts may [checked: elevenlabs.io/terms-of-use via search]. **Not verified:** what happens to rights in lines made before a subscription ends, and anything game-specific. The earlier game's Higgsfield voices also ran on ElevenLabs, and those terms were never read (LICENCES2.txt). **Price: see part 10.**

### The recommended mix

| Who / what | Now (working track) | Later |
|---|---|---|
| Danny, Kayla, Marcus | C: the voice that wins each audition (the old Danny 1 / Kayla 1 / Marcus 1 are the candidates to beat) | **A**: the owner and people he knows, as he chose |
| Gus, Kessler, Ray (adults) | C, designed voices | A if a consenting adult wants the part; otherwise **B**: a consenting adult performs, converted to the designed voice |
| Priya, Mari, Owen, Caleb, small parts | C | A or B where someone wants to; C stays for small parts |
| Cutscenes (faces) | C, best take, plus Step-Audio-EditX on lines that fail | A first; B second |
| Kayla on the radio | C through the radio chain | A |
| Crying, screaming, strain, real laughs | C attempted, measured; failures marked **REAL-ONLY** | A or B performed; never left as a failed machine take in the finished game |
| Hunter whisper, Mimics | built only from that character's own lines, whichever route made them (part 7) | rebuilt automatically when real lines arrive |

---

## 3. Casting

### The voice sheets

Ages are the characters' ages. Every description below is written for a voice-design engine and names **no** real person, actor or character from another work.

| Who | Voice | Pace and habits | Afraid |
|---|---|---|---|
| **Danny Reyes, 16** | boy, voice settled but light, warm and a little hoarse; American, local | quick, rides over pauses, jokes land half a beat early; drops into impressions (his Ms. Kessler: slower, clipped, schoolteacher pitch); "dude", trailing "...but." | the jokes get faster and smaller, then stop; whispers come out cracked; breath held then let go |
| **Kayla Brooks, 16** | girl, clear mid voice, dry, slightly low for her age | fast, precise, finishes his sentences; short questions; "Stay on the line, okay?" | flat and controlled, then one crack; counts things under her breath |
| **Ms. Ruth Kessler, 52** | woman, firm, clipped consonants, a classroom voice that carries | measured; counts aloud; "my kids"; full sentences even in panic | gets *more* formal and slower; the pitch climbs at sentence ends |
| **Gus Pruitt, 58** | man, low, grainy, unhurried, a smoker's edge without the cough | slow, short sentences, calls Danny "son"; little stories | quieter, not louder; the only one who sounds calm, which is the scare when he isn't |
| **Ray Dobbs, 44** | man, coach's chest voice, rough from shouting | short orders, cuts people off | anger: loud, cracking on his son's name |
| **Priya Nair, 17** | girl, quick and bright, technical | lists, corrects people, talks to herself | flat certainty ("they're dead") turns to fast hope ("they're breathing") |
| **Mari Vega, 15** | girl, warm, smiling voice, a little husky; she sings | easy laugh, hums between lines | stays kind for others; her own fear shows in a smaller voice |
| **Owen Tate, 14** | boy, voice not yet broken, soft | hesitant, asks questions, apologises | whispering, short breaths, asks to be walked past the dark |
| **Marcus Bell, 15** | boy, bright, cheeky | fast, drumstick rhythm in his speech | heard alive only briefly; later only as the hunter uses him |
| **Caleb Dobbs, 17** | young man, lower than Danny, sleepy-rough when woken | few words | dazed, slow |

A pronunciation list ("Reyes" = RAY-ess, "Pruitt", "Nair", "Rovloc") goes with the script into every engine run.

### How candidates are made without copying anyone

Allowed sources only: (1) a written description in a voice-design engine (Qwen3 VoiceDesign, Maya1); (2) an engine's own stock voices or a blend of them (the Kokoro blends behind Danny 1, Kayla 1, Marcus 1); (3) a designed or stock clip used as the reference for a cloning engine (Qwen3 Base, Chatterbox). Never: a clip of a real person, a "sounds like" request, a voice from any film, game or show. The builder's script refuses a reference file that is not in the voice register with its recipe (as tools3/plan3.py already asserts for unused Kokoro voices).

**The reference must be acted.** The biggest cause of "robotic" last time was a flat read-aloud reference (part 5). So each candidate gets three designed reference clips of the same voice in our own words: calm, frightened, and whispered. All three must measure as the same speaker (part 4, identity check).

### The audition page

One page per character, before any of that character's lines are made in bulk. **Four candidates** per character (for Danny, Kayla and Marcus one of the four is the voice he already chose). Each candidate says the same **four test lines**, in the character's words from the script, chosen per character:
1. **calm** (e.g. Gus: "Generator wants three things. Fuel, air, and patience.")
2. **joking** (Danny: "So I'm the one who stays behind. Cool. Love that for me.")
3. **frightened** (Kayla: "It's in. It's inside, Danny.")
4. **crying or shouting** (Kessler shouting the count; Danny's last true line, crying).

16 clips, names hidden and shuffled, about 4 minutes. He picks one or "none of these" (four new candidates follow). Only candidates that pass every automatic gate reach the page.

---

## 4. The pipeline, line by line

### 4.1 The script sheet

One row per line (a CSV the build reads), with a direction for every line:

`LineID, Chapter, Scene, Speaker, ToWhom, Text, MustBeExact(y/n), WhatJustHappened, Place, Distance(close/room/far/radio), Loudness(1 whisper .. 5 shout), Fear(0-3), State(calm/winded/scared), BreathBefore, BreathAfter, Pace(slow/normal/fast), Overlap(LineID, offset), Face(cutscene/play/radio/offscreen), Route(A/B/C), Strong(y/n)`

Example: `C01_S07_DAN_0112 | Danny | to everyone | "I'm getting everyone out. All of you. Which, historically, from me, means nothing. But." | MustBeExact y (the hunter re-uses it) | first night, Mari just played the song, Owen is asleep against him | shelter | room | 2 | 1 | calm | small breath before "But" | none | slow, the "But." left hanging | cutscene`.

Strong-language lines (about eight) are made twice: with and without the word.

### 4.2 Takes

- Route C: **8 takes** per line: 2 engines × 4 seeds, or one engine with two directions (e.g. Qwen instruct "frightened, whispering" and Maya1 `<whisper>`) × 4 seeds. Auditions decide the main engine per character; the second is the backup.
- Route B: 2 to 3 performances × 2 conversion settings.
- Route A: 3 takes + 1 free take.

### 4.3 Automatic ranking (runs on the PC; no ears needed)

The old checker (tools/voices/tools2/analyze.py: pitch movement, pitch wobble, buzz, smear, recogniser) is the starting point, extended. **Step 1: hard gates** (fail one, the take is out). **Step 2: ranking** of survivors by a weighted score; the top two go forward, the best is used.

| Check | Tool (licence) | Gate to start from |
|---|---|---|
| Right words | Whisper large-v3 [MIT, from memory] **and** NVIDIA Parakeet TDT 0.6B v3 [CC-BY-4.0, checked: card]: two recognisers, both must agree | every must-be-exact word right; others ≤ 5 % word error (whisper lines ≤ 10 %); names right; no extra words (hallucinated tails are a known fault of these engines) |
| Length | words per second from the recogniser's word times | inside the character's band for that pace (start: talk 2.2 to 3.6, scared up to 4.2, slow 1.6 to 2.6) |
| Same person | speaker embedding (SpeechBrain ECAPA [Apache-2.0, from memory]) against the character's anchor clip | similarity ≥ 0.75 to the anchor and ≥ 0.10 higher than to any other character [starting guess, calibrated in part 9] |
| Flat pitch | pyworld, as before | talk: pitch movement ≥ 4.5 semitones SD; emotional lines ≥ 5.5 (yardstick: acted takes 6.6, flat Kokoro reads 3.6 to 4.7) [checked: our out2/A1_causes.txt] |
| Too-smooth pitch | pitch wobble between 5 ms frames | ≥ 24 cents (acted ~33; flat synthetic 15 to 22) [same source] |
| Buzz / metallic | aperiodicity 1 to 4 kHz | ≥ -16.5 dB (vocoder buzz measured -19.4; acted -13.4) [same source] |
| Smear | spectral flux | ≥ 6.0 dB per 10 ms (stretched takes fell to 5.6 to 5.8) [same source] |
| Even pacing | spread of gaps between words and of syllable rate across phrases | gap spread (CV) ≥ 0.4 on lines of 6+ words [starting guess]; lines with a "..." in the direction must have a pause ≥ 0.35 s there |
| Clipping | sample and true-peak scan | no run of 3+ samples at full scale; true peak ≤ -1 dBTP after gain |
| Noise | speech-to-silence level; DNSMOS background score [CC-BY-4.0, checked: microsoft/DNS-Challenge LICENSE] | ≥ 35 dB between speech and the quiet parts (before room tone is added) |
| Clicks and joins | jumps between samples; flux spikes away from word starts | none above threshold; any join must sit in silence or at a cross-fade ≥ 10 ms |
| Breath | breath detector (energy 1 to 6 kHz with no pitch, 150 to 600 ms) | where the direction asks for a breath, one is there; Mimic lines must have none |
| Emotion fits | emotion2vec+ [FunASR model licence, used only on the PC, never shipped; checked: card] | soft: a "fear" line that classifies as "happy" loses rank |
| Sounds like a person (soft) | UTMOSv2 [MIT, checked], Audiobox Aesthetics [CC-BY-4.0, checked] | **ranking only**: these predictors are reported to saturate, even to mislead, on expressive speech [checked secondhand: natscore / arXiv 2603.01467 via search] |
| Machine tell (soft) | a synthetic-speech detector, W2V2-AASIST or XLSR-SLS (MIT on their cards) [checked secondhand: Hugging Face cards via search] | **ranking only** until calibrated on real recordings (part 9); then a gate if it separates real from machine |

Score for ranking (start): 30 % recogniser confidence, 20 % pitch movement and wobble, 15 % detector "human" score, 15 % emotion fit, 10 % UTMOSv2, 10 % closeness to the direction's pace. Scores are compared **inside one line's takes**, never across lines.

### 4.4 A line that fails

Every line goes down this ladder until a take passes; the sheet records which rung:
1. **More takes** (8 new seeds).
2. **Re-direct:** change the instruction or tag, the exaggeration, the punctuation (a comma or "..." fixed four slot failures last round), the description of the moment.
3. **Re-write** with the writer, same meaning, easier mouth ("Sales at 4" became "Sal's at four!"). Never for must-be-exact lines.
4. **Another engine.**
5. **Edit the best take** with Step-Audio-EditX (add fear, a breath, a whisper style) and re-check it.
6. **Mark REAL-ONLY.** The best failing take stays in the working build with a red debug tag, and the line goes on the recording list for route A or B. Expected: most crying, screaming and strained lines.

---

## 5. What made voices robotic before, and the rules

Measured last round (out2/A1_causes.txt): **(1) the reference:** cloning engines copy the melody of the clip they are given, and every reference was a flat read-aloud paragraph; **(2) the vocoder** (WORLD pitch and formant shifting): it made the voice 3.7 dB buzzier and halved the natural wobble even with no change; **(3) time-stretching** (WSOLA): it stretches every sound evenly and smooths the wobble; **(4)** a cap on every pause removed natural hesitations.

**The rules (the build refuses to break them):**
1. No pitch shifting, formant shifting, vocoder resynthesis or time-stretching on any human line. Finishing is trim, gain, fades and room tone. Only the hunter's chain may resynthesise.
2. Every reference clip is acted, matches the line's emotion, and passes the pitch-movement gate itself.
3. Pauses are never capped; a pause is shortened only by cutting silence at a breath, never inside a word.
4. A line that is too long or short is re-taken or re-written, never stretched.

**Other tells of machine speech, and the fix for each:**

| Tell | Fix |
|---|---|
| Every sentence ends with the same falling tune ("reading cadence") | the even-pacing and pitch gates; directions that say what the line *does* ("asks without wanting the answer") |
| Too perfect: every word fully pronounced | write the script as people talk ("gonna", "c'mon", "I— no."); allow rewording |
| No breaths, or the same breath every time | breaths from real recordings (part 6), never one sample reused in a scene |
| Same loudness all line long | the loudness column; reject takes whose level barely moves (short-term loudness spread < 3 LU on emotional lines [starting guess]) |
| Dead-dry "studio" voice in a concrete basement | room tone and the engine's place reverb (part 6) |
| Voice drifts from line to line | the identity gate; one anchor clip per character |
| Teenagers sounding 25 (engines lean towards adult narrators) | age in every description; the audition; the owner's ear |
| Wrong stress on names | the pronunciation list; must-be-exact checks |
| Extra words, repeats, mumbled endings | two-recogniser gate |
| Hiss or metal on "s" and "sh" | buzz and noise gates; a different seed (never an EQ that hides it) |
| Pasted-on laughs | laughs inside lines come from tags that pass the emotion check, or a real laugh placed by hand |
| Same take heard twice | the game never plays the same take of a line twice in a scene; repeated barks get 3 to 5 takes |

---

## 6. Performance editing

- **Breaths, laughs, cries, efforts:** a library recorded by consenting people (route A sessions), at least 20 breaths per character type (calm, winded, scared, crying) and 10 efforts, placed by hand at the direction's marks, matched to the line's level and filtered to match its tone. For machine voices, breaths come from a consenting person of similar age and sex; the release names it.
- **Hesitations:** written into the text ("I— I didn't...") so the engine performs them; or made by inserting room tone between words at a natural break. Never by stretching.
- **Overlaps:** each speaker is a separate file; the cutscene places the second line 100 to 400 ms before the first ends, and the first line ends on a real cut-off (written "I was gonna—"). Real recordings in one room are best.
- **Room tone:** every finished file carries a quiet noise floor (about -60 dBFS, never digital silence). Voices are stored **close and dry**; the place (shelter, gym, tunnel, stairwell, roof) comes from Unreal's reverb and impulse responses, so one take works anywhere.
- **Kayla's walkie chain:** band-pass 300 to 3,400 Hz, light saturation, fast compression, press click and squelch tail, static that grows with height. **Fair rule:** a take must pass every gate *before* the chain; the chain may hide a faint top-end sizzle, never a wrong word, flat melody or drift; the recogniser re-checks after the chain (≤ clean + 5 points). Clean versions are kept for when she is in the room.
- **Danny in three states:** every playable Danny line is made **calm, winded and scared** as three performances (not three effects). Winded: breaths between word groups, words on the out-breath. Scared: faster, higher, smaller. The game picks the state from his stamina and threat.
- **Loudness:** masters 48 kHz, 24-bit mono WAV. Normal talk at -23 LUFS integrated; whispers, raised voices and shouts keep their performed level relative to that (start: whisper about -32, shout about -16); true peak ≤ -1 dBTP; cutscene dialogue lands -23 to -20 LUFS short-term over beds 14 to 18 dB lower (report 06, 6.4).
- **Names and storage:** `VO_<Chapter>_<Scene>_<Speaker>_<Line>_<State>_T<take>.wav` (e.g. `VO_C01_S07_DAN_0112_CALM_T3.wav`). All takes in `Source/VO/<Speaker>/` outside the Unreal project, the chosen take imported to `Content/Audio/VO/<Speaker>/`. A `vo_manifest.json` per line: engine, model and file hash, seed, description or reference, performer and release number, gate numbers, rung of the ladder. The licence file (LICENCES4) holds each model's licence text and where it was read.

---

## 7. The hunter's whisper and the Mimics

**Where the words come from:** only words that person said **on screen, alive, earlier** (report 04, 2.5; report 06, 4.3). The heard bank is built from the finished takes: forced alignment (WhisperX [BSD-2, checked: LICENSE]) cuts each word with its boundaries; the hunter's lines are assembled from 1 to 6 word fragments. It never says a new word in someone's voice. When a real recording replaces a machine line, the hunter's fragments rebuild from it automatically.

**The eerie chain** (the owner chose a close, dry whisper, "an eerie creepy version"):
1. Whisper resynthesis from the speaker's own spectral envelope (noise in place of voice, so their vowel shapes, which carry who they are, survive).
2. Uneven timing by moving the fragments, not stretching them: one word late, the next too soon, a gap where no one would pause.
3. Close and dry: a slight bass lift like lips at the ear, no room.
4. A second, fainter copy from another take, 10 to 14 dB down and 30 to 60 ms late.
5. One inhale where no one would breathe; on the last word a short frozen tail.
Strength grows towards the mothership, never so far that a word is lost.

**The proof it is understood:** both recognisers on the processed line, word error ≤ 10 %, every name right; identity kept (speaker similarity to the source person above a floor set in the first proof); and the owner's **"who is it?" test** (part 8). Last round, the recogniser caught two whisper doubles misheard ("on on"); the fix was another base take, so this check stays.

**The Mimics:** a plain copy of a known voice, deliberately a little *too* clean: no breath, the same line with the same timing every time. Here the machine tells are the design. For a machine-voiced character, the line is made in that character's voice, breaths removed, one take reused exactly. For a real-recorded character, the person **records the Mimic lines themselves** ("say it like a recording"), and their release names it; no one's real voice is cloned. Kayla's copy is used once ("What time?") and never on the radio. Checks: words; identity as high as her real lines (it has to fool you); zero breaths detected.

---

## 8. The owner's ear

Five kinds of listening, each 10 minutes or less, on his PC with headphones, on a simple page with buttons (no typing needed):

1. **The blind page (calibrates the bar).** 16 clips: 4 real recordings and 12 machine takes, shuffled, each marked **"real person" / "machine" / "not sure"**. The real clips are lines he and anyone who agrees record on a phone for this purpose (release signed). Run once at the first proof and again whenever the main engine changes. **The bar is met** when he calls machine takes "real" about as often as the real ones.
2. **Each audition** (part 3): 4 minutes per character.
3. **The hunter's "who is it?"** 6 whispers; he names whose voice. Pass: 5 of 6.
4. **Each cutscene's mix**, once, finished: three buttons per scene: "fine", "a voice sounded fake" (tap the moment), "too quiet / loud".
5. **A sample of each chapter:** 20 lines at random plus the 5 lowest-ranked that passed, with "fake" and "fine" buttons.

Anything marked fake goes back down the ladder (4.4), and the checker is tightened until it would have caught it.

---

## 9. The first proof (the test of this whole plan)

The first slice: **Danny, Kayla, Gus and Ms. Kessler, about 60 lines** (Danny 25, Kayla 15 with 10 on the radio, Gus 10, Kessler 10), from the prologue and Chapter 1 scripts, picked to cover every kind in part 1: at least 6 whispers, 6 frightened, 4 shouts, 3 crying, 3 laughing, 2 overlaps, 4 winded.

1. **Set up:** one Python 3.12 environment per engine, in Windows or WSL2 (Step-Audio-EditX is Linux-tested); PyTorch for CUDA 12.8 or later, which the RTX 50 series needs [from memory]. Licence texts and file hashes into LICENCES4. One model at a time, the Unreal editor closed (16 GB). About 40 to 60 GB of disk [estimate].
2. **Calibrate the checker first.** Run it over takes the owner has already judged: round 1 ("a little robotic") and round 2/3 ("Voices good"). Each gate must separate them. Gates that don't are fixed before anything new is made.
3. **Design candidates:** Danny and Kayla: the chosen Danny 1 / Kayla 1 (Chatterbox) against three new designs (Qwen3 design→clone, Maya1, Qwen3 with acted references). Gus and Kessler: four new designs each. Three acted reference clips per candidate; the identity gate must hold across them.
4. **Audition page** → he picks.
5. **Make 60 lines × 8 takes**, run gates and ranking, take the ladder, record each rung.
6. **Finish:** breaths, room tone, Kayla's radio chain, Danny's three states for 5 lines.
7. **Faces:** MetaHuman audio-driven animation on 6 cutscene lines per character; check that mouth shapes follow (no mouthing in silence, closed lips on m/b/p) by frame inspection of the solved curves against the recogniser's word times. Note: in 5.8 the audio solve outputs at a fixed 30 fps [checked: MetaHuman 5.8 known issues via search].
8. **Blind page and "who is it?"** (part 8), with 4 real phone lines if he wants to record them.

**What is measured:** first-time pass rate per kind of line; rungs needed; REAL-ONLY count by kind; blind-page results; identity spread per character; machine time per finished line; face-solve faults.

**What would make us change route:**
- He picks out the machine takes on the blind page clearly more often than chance → the working track cannot meet the bar; bring route A or B forward for the main cast and ask which lines matter most.
- More than a third of whisper, frightened, crying or shouting lines end REAL-ONLY → those kinds are made by performance (A or B) from the start, not by text-to-speech.
- A new design does not beat the old Danny 1 / Kayla 1 blind → keep them; Chatterbox stays despite being archived (pinned and hashed).
- A character's identity drifts on more than 1 line in 10 → fine-tune that voice (Qwen3 Base fine-tuning [checked: README] or RVC on its designed clips).
- Step-Audio-EditX runs out of memory on 12 GB → drop it; the ladder skips rung 5.
- The checker passes lines he calls fake → its gates are wrong; fix the checker before going on.

---

## 10. What it would cost if he ever chose a paid route

Stated once. **Real recordings:** nothing with phones; about $60 to $150 for a microphone and pop filter if he wants one [from memory]. **ElevenLabs** for the whole script [estimate from the checked prices]: about 1,200 lines of about 55 characters is 66,000 characters a pass; with 4 takes, auditions and retakes about 300,000 to 350,000 characters: **one month of Pro ($99) or three months of Creator ($66)**. Converting real performances with its Voice Changer: about 60 minutes of finished speech × 3 takes = 180 minutes = 180,000 credits, **about $22 through the API or two months of Creator ($44)**. Overall **roughly $50 to $150**, and only on a paid plan (the free plan gives no commercial rights). Nothing is bought without his yes.

---

## 11. What could not be verified

- ElevenLabs' full terms (its site was blocked here): what happens to rights in lines made before a subscription ends, game-specific terms, the exact v4 credit rate. Higgsfield's terms, never read.
- Maya1's card points to "component-license notes" that were not found; whether its weights come from a Llama base (whose licence would then apply) is not confirmed.
- How any open engine performs English whispers, crying and shouting: no published listening test was found. The first proof measures it.
- Seed-VC's quality on frightened, whispered and screamed performances; whether the GPL-3.0 weights raise any question for sound we make with them.
- The starting thresholds marked "starting guess", and how well the synthetic-speech detector separates our voices from real recordings: both are calibrated in part 9.
- Memory use and speed of every engine on the RTX 5070 under Windows; PyTorch and FlashAttention support for this card on Windows.
- Whisper's and SpeechBrain's licences were not re-read today.
- The line count: the map says about 1,200 lines; audio draft 5 estimated about 3,100. This plan uses the map's figure. Older notes disagree on which round-2 voices were chosen (Danny 3 / Kayla 3 in report 04; Danny 1 / Kayla 1 / Marcus 1 in REPORT3.txt, the later record); this plan follows REPORT3.txt.
