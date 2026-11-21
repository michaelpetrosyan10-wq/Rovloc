# STAY BEHIND: the voice plan (second pass, after the sceptical listener's review)

Written 21 November 2026 for the builder on the owner's PC (RTX 5070 12 GB, Ryzen 5 7500X3D, 16 GB memory) and for the owner. The first version and the review are kept in `drafts/voices/`; part 16 answers every finding.

**If nobody can record yet.** Proof zero's blind page needs a few real clips from people other than the owner. Until he has them, proof zero still runs in a simpler form: he hears each machine clip alone and presses "sounds like a real person" or "sounds fake". Every kind of line he marks fake is held as a temporary voice (its subtitle says so) until someone records it, and the blind page is run as soon as real clips exist. Work on the voices never waits for a recording session.

Marks: **[checked: source]** = read today at the source (or, where it says "via search", in search results that quote it); **[from memory]** = not re-checked today; **[estimate]** = worked out here. huggingface.co could not be opened from the machine this plan was written on, so every Hugging Face model card is read again on the PC before its model is used (part 15 lists which). "Real" in this plan always means a recording of a person who agreed in writing to record for this game (a parent or guardian too for anyone under 18).

```
THE SHORT VERSION FOR THE BUILDER
| BAR     Blind, he gets 16 or fewer of 24 real/machine clips right (17+ is 3 % by chance; pooled later: 30 of 48),
|         and every character passes "same person?" 6 of 6 with both decoys called "different".
| MIX     One route and one engine per character, changed all at once. Working track: Danny 3 / Kayla 3 / Marcus 2
|         (Chatterbox) against the audition winners. Finished: Danny and Kayla real; whispers, screams, crying,
|         impressions, humming, whistling, laugh-crying real only; route B for adults only, behind its gates.
| CHECKS  Words, names (phonemes) and identity against the anchor OF THE SAME KIND are gates only. Rank by 35 % pitch,
|         25 % loudness and pauses, 25 % emotion, 15 % UTMOSv2. A gate stays only if it fails the clips he called
|         "machine" more often than those he called "real" and passes 9 in 10 real takes. The detector is logged only.
| OWNER   Proof-zero blind page (5 min) and same-person pages (4 min); audition 4 min a character; hunter "who / creepy"
|         3 min; each cutscene once; 25 lines plus the short lines a chapter. Age, emotion, creepiness: his ear only.
| FIRST   PROOF ZERO: 2 days, 12 lines (Danny 6, Kayla 3, Owen 3), best machine take beside a consenting real person.
```

```
FOR YOU (the owner)
|
| What you will listen to, always on your PC with headphones, on a page with buttons (no typing):
|  1. Proof zero, first of all: 24 short clips, one at a time; for each you press "real person" or
|     "machine". About 5 minutes. Then 24 pairs of lines: "same person" or "different person". About
|     4 minutes. This decides which kinds of line machines may voice at all.
|  2. Auditions: one page per character, 16 short clips, you pick one voice or "none of these". About 4
|     minutes a character, spread over the weeks the characters are made.
|  3. The hunter: 6 whispers; name whose voice it is and press "creepy enough? yes / more / too much",
|     plus one side-by-side of your Monster 5 whisper and the new version. About 3 minutes.
|  4. Each finished cutscene, once: "fine", "a voice sounded fake" (tap the moment), "too quiet / loud".
|  5. Each chapter: 25 lines plus its very short lines, "fine" or "fake". About 3 to 4 minutes.
|
| What only you decide:
|  - Who records (you and the people you ask), and when. Each person signs the release first; a parent
|    or guardian signs too for anyone under 18. Proof zero needs two or three of them for half an hour.
|    You do not record the proof-zero test clips yourself, because you are the listener.
|  - Whether anything is ever bought (a microphone, a paid voice plan). Nothing is bought without your yes.
|  - What your ear says: the voice picks, the blind result, how creepy the hunter is. No check overrides it.
|
| Parts 5 to 7 are for the builder. Words you may not know are explained in the glossary at the end.
```

---

## 1. The bar

**A listener who is not told must take every human line for a recorded person, and every character for one person.** Not "good for AI": if the owner, listening blind, picks out the machine take more often than guessing would, it fails (part 9 gives the numbers).

What that means, kind by kind, and how hard each is for machines today:

| Kind of line | What a real person does | Machines today | Route from the start |
|---|---|---|---|
| Ordinary talk | uneven rhythm, stresses the word that matters, swallows small words ("gonna", "c'mon"), pitch that wanders and wobbles, breath at thought breaks | **Mostly solved** by the best engines when the reference voice is itself lively (round 2 proved this) | machine allowed; proof zero confirms |
| Very short, thrown away ("...Yeah.", "Four.", "...oh.") | said without weight, often half-swallowed | **Hard:** engines over-pronounce single words; recognisers invent words on them | machine allowed only through the carrier method (5.6); every one heard by the owner in the chapter sample |
| Jokes, teasing | the beat before the punchline, a smile you can hear, a half-laugh on a word | **Medium** | tested in proof zero |
| Whispering | no voice buzz at all, consonants loud, breathy, close | **Medium to hard:** whispers often come out as quiet talking | **real only** (part 2, route B is no help either) unless proof zero shows he cannot tell |
| Frightened | short phrases, breath in the wrong places, pitch up, voice tight | **Medium to hard:** "fear" usually comes out as fast talking | tested in proof zero |
| Shouting | the voice strains and cracks, not just gets louder | **Hard** | **real only** unless proof zero shows he cannot tell |
| Crying | the voice breaks mid-word, wet breath, words fight through | **Hardest** | **real only** |
| Laughing for real; laughing while crying (Kayla at the hold and at the gate) | the laugh grows out of the speech | **Hard** | real laughs: tested; **laugh-while-crying: real only** |
| Scream cut off mid-breath (Danny's catch; the hunter whispers it back) | the scream stops inside the breath | **Hard**, and a cut-off must not sound edited | **real only** |
| Impressions (Danny's Ms. Kessler, the game's last line before his own) | his voice doing another voice | no engine "does an impression"; an identity gate rejects it either way | **real only** (machine track: a separate anchor, 4.3) |
| Humming, whistling (Mari between lines, Danny humming along wrong, the teacher's hum, the janitor's whistle, the hunter humming a tag wrongly) | tune, breath, lips | **Not possible** with text-to-speech | **real only** |
| Talking over each other | overlap, cut in, trail off | **Hard** for engines (one speaker at a time); built by placing two lines (7.3) | either |
| Out of breath | gasps between word groups, words pushed out on the out-breath | **Hard** to generate; easy to perform | tested in the first proof |
| On a walkie-talkie | narrow band, clipped, static, the press click | **Easiest:** the radio sound hides small faults (7.5 sets the fair limit) | Kayla's own route |

The hard rows are the sad and frightening scenes, the ones that make the story land. So the plan tests them first (proof zero, part 10), sends the ones machines cannot do to real performers, and keeps each character on one route so no one changes voice mid-scene.

---

## 2. The routes, and the mix

### Route A: real recordings by consenting people (most real)

**The release (no release, no recording).** Each person signs before the first recording; a parent or guardian also signs for anyone under 18, **for every use below, each one ticked separately**:
1. their voice in the game, which may be sold, worldwide, for the life of the game, with the credit wording they choose;
2. any face video, for animating a character's face;
3. the processed versions: the hunter's whisper made from their own words, and the Mimic lines they record themselves;
4. conversion of their performance into a designed character voice (route B), if they play a character other than one in their own voice;
5. their breaths, gasps, efforts and laughs placed under **a different character's** voice (part 7.1);
6. their clips used in the owner's listening tests (part 9), including the blind test, where nothing they say reaches the game unless use 1 is also ticked;
7. uploading their recordings to an outside company (for example ElevenLabs' Voice Changer), only if that paid route is ever chosen, named by company;
8. the right to withdraw before release: their lines are re-made or re-recorded, and the hunter's word bank and every Mimic line are rebuilt without them (the build does this from vo_manifest.json, part 5.8).

The build refuses any file (line, breath, effort, test clip) whose vo_manifest.json entry has no release number with the right use ticked.

**Equipment that is enough** [from memory]: a recent phone for a first pass; a USB microphone with a pop filter (about $60 to $150) is better, and only if the owner says yes. The room matters more: a small room full of soft things (a closet of clothes, a duvet hung behind the speaker). Record WAV at 48 kHz, 24-bit, mono, the mouth 15 to 20 cm from the microphone and slightly off to the side; peaks around -10 dBFS so shouts don't clip. Record 30 seconds of silence (room tone) at the start of every session.

**For faces:** Epic asks for at least 16 kHz and as little background noise as possible, because a cleaner signal gives cleaner face animation [checked: dev.epicgames.com/documentation/metahuman/audio-capture-recommendations]. For the 30 to 40 key cutscene lines, film the speaker's face on a second phone at the same time, front-lit, focus and exposure locked, for MetaHuman's video solve (report 04, 3.2). One line per file, a clap or tap at the start of each take for sync.

**Directing people who are not actors** [from memory, standard practice]:
- Tell them the situation, never how to say it: "You've been awake two days. The thing is in the hall. Kayla has to hear you but it mustn't."
- Let them change words to how they would say it. The script sheet marks which lines must stay word for word (codes, names, lines the hunter re-uses).
- Make the body do it: crouch for hiding lines, run on the spot for winded lines, hold something heavy for strain, whisper with the mouth close to the microphone.
- Record two people in the same room for dialogue when possible, each on their own phone or microphone close to them, so they can interrupt.
- Three takes of each line: as written, a bit bigger, a bit smaller. Then one free take.
- End every session with the short list: breaths, gasps, efforts, laughs, cries, screams (Danny's cut-off scream among them), humming and whistling, when people are warmed up and less shy.
- Sessions of 45 minutes; shouting and crying last.

**Limits:** scheduling, rooms, acting. Fixed by retakes, not processing.

### Route B: a real performance, converted to a designed voice (speech-to-speech)

A consenting person acts the lines; a conversion model keeps their timing, breath and phrasing and swaps the sound of the voice for a **designed** character voice (made from a description by route C, so no one is copied). It lets one willing adult carry an adult character they cannot sound like.

| Tool | Licence | What it does | On 12 GB |
|---|---|---|---|
| **Seed-VC** (v1 and v2) | GPL-3.0 for code and weights (changed from MIT) [checked: github.com/Plachtaa/seed-vc LICENSE; confirmed by the review via search] | conversion from a short target clip; can be fine-tuned on a target voice; v2 can keep the source's accent and emotion [checked: README] | yes: real-time on an RTX 3060 laptop per its README [checked] |
| **Chatterbox VC** | MIT; the README says "As of August 2026, Chatterbox is retired research and is no longer maintained" [checked today: github.com/resemble-ai/chatterbox] | conversion to a target clip | yes [from memory] |
| **RVC** | MIT; base models trained on the VCTK set [checked: RVC-Project README and LICENSE] | high fidelity once trained on 10 to 30 minutes of the target voice | yes [from memory] |
| OpenVoice V2 | MIT [checked: huggingface.co/myshell-ai/OpenVoiceV2, earlier pass] | tone-colour converter | weaker; backup only |
| Vevo, Vevo 1.5 | CC-BY-NC / NC-ND [checked: cards, earlier pass] | not usable (non-commercial) | |

The GPL covers the program, not the sound it makes, and the program is never shipped [from memory: GPL FAQ]; if that is ever questioned, use RVC or Chatterbox VC.

**Route B rebuilds the sound through a neural vocoder**, which rule 1 (part 6) otherwise forbids. So it is allowed **only** under the written exception in rule 1: the converted line must keep its wobble (at least 85 % of the performer's original, i.e. a loss of 15 % or less), change buzz by 1.5 dB or less from the original, and pass the same-person check (part 9.2) against the character's other lines. **Never for whispers, screams, crying, humming, laughing while crying, or big jumps of age or sex**: there is nothing voiced to convert in a whisper, and screams and cries are where converters smear [from memory; the Seed-VC authors report slightly lower audio quality than per-speaker RVC: checked secondhand, seed-vc EVAL.md]. In practice route B is for the three adults (Kessler 52, Gus 58, Ray 44) if a consenting adult of roughly the right age and sex wants to perform but does not want their own voice in the game.

### Route C: text-to-speech on the 12 GB card, under a licence that allows a sale

| Engine | Licence | Why it is here | Fit and limits |
|---|---|---|---|
| **Chatterbox full (and Turbo)** | MIT; retired research since August 2026, no updates; every output carries an inaudible Perth watermark [checked today: GitHub README] | **the engine of the voices the owner chose: Danny 3, Kayla 3, Marcus 2** (requirements.md, 17 Nov: "Do voice 3 for all") | 0.35 to 0.5B; pinned and hashed. Copies the delivery of its reference clip, so every kind of line needs its own acted reference (part 4.3) |
| **Qwen3-TTS 1.7B: VoiceDesign, Base, CustomVoice** | Apache-2.0 [checked: Hugging Face card, earlier pass; the README read today has no licence line, so the card and LICENSE file are read again on the PC] | **VoiceDesign** makes a voice from a written description and takes an `instruct` (delivery) text; **Base** copies a reference clip; the README's "Voice Design then Clone" workflow turns a designed clip into a reusable speaker [checked today: raw.githubusercontent.com/QwenLM/Qwen3-TTS/main/README.md] | **Base takes no instruction**: the README's model table leaves "Instruction Control" unticked for both Base models and its clone examples pass only text, language and the reference [checked today: README]. So on Base, emotion comes only from the reference clip. Released 22 January 2026; no newer version found [checked via search] |
| **Ming-3.0-tts-0.5b** (new candidate) | repository MIT [checked today: github.com/inclusionAI/Ming-3.0-tts]; the weights' card is read on the PC before use | released October 2026; voice design from a style description, an `EMOTION` task (happy, sad, angry, fear, disgust, surprise, neutral) that needs a reference clip, 14 inline tags such as `[Laughter] [Sigh] [Breathing]`, a free `instruction`; English WER 1.6 % on seed-tts-eval [checked today: same page] | 0.5B dense, so it should fit [estimate]; tested only on 80 to 96 GB data-centre cards; no whisper or crying tag listed |
| **VoxCPM2 2B** (new candidate) | Apache-2.0 for weights and code per its card [checked via search: huggingface.co/openbmb/VoxCPM2]; whether its backbone carries another licence is checked on the PC (as for Maya1) | voice design from a description that can name emotion and pace; 48 kHz output [checked via search] | about 5 GB checkpoint [checked secondhand: betterstack guide]; no memory figure published |
| **Maya1** | card says Apache-2.0, **but the model is a ~3.3B `LlamaForCausalLM`** [checked secondhand: friendli.ai listing], the size of Meta's Llama 3.2 3B; whether it was trained from Llama weights is not stated [checked by the review: marktechpost, osai-index] | description plus inline `<whisper> <cry> <gasp> <laugh> <scream>` tags | **out of every audition** until its config.json and tokenizer are read on the PC. If they name a Llama base or use the Llama 3 tokenizer, it comes under Meta's Llama licence [from memory: commercial use allowed below 700 million monthly users, "Built with Llama" notice, acceptable-use policy]; it then returns only with that text in LICENCES4 and the lead's yes. Its place in the auditions goes to Ming-3.0-tts or a second Qwen3 VoiceDesign description |
| **Step-Audio-EditX** | code Apache-2.0 [checked today: GitHub README]; the README states no licence for the weights, so the card is read on the PC | **edits an existing take**: emotion (fear, sad...), style (whisper, shout...), and adds breaths, sighs, laughs [checked today: README] | 12 GB is "a critical value", 16 GB "safer", Linux-tested; the AWQ 4-bit checkpoint is estimated by its makers at about 8 to 10 GB [checked today: README]. **Absent from the plan until the test in 11.1 passes**; no figure here depends on it |
| **Dia2 2B** | Apache-2.0 [checked: Hugging Face card, earlier pass] | two speakers in one pass | one mixed track, voices vary without a prefix clip [checked by the review via search]: **used only to find natural overlap timing, never for a shipped line** |
| Kokoro 82M | Apache-2.0 [checked: card, earlier pass] | the stock voices behind the references of Danny 3, Kayla 3, Marcus 2 | tiny |

**Usable only with conditions** (not first choices): IndexTTS2 (bilibili licence: royalty-free, separate licence above 100 million monthly users or RMB 1 billion revenue, pass-down and indemnity clauses [checked: index-tts LICENSE, earlier pass]); Higgs Audio v2 (built on Meta's Llama 3 licence, free under 100,000 annual active users [checked: bosonai LICENSE, earlier pass]); NVIDIA Magpie (NVIDIA Open Model Licence; one stock voice is named after a real volunteer reader, so that voice is never used).

**Not usable** for a game that may be sold: Fish Audio S2 Pro and Fish Audio Drama 3 (research or non-commercial) [checked secondhand: search, October 2026 leaderboard]; Voxtral 4B TTS (CC-BY-NC-4.0) [checked: card, earlier pass]; Breeze TTS 2 (non-commercial) [checked secondhand]; XTTS-v2 (non-commercial) [from memory].

**Limits of route C:** crying, shouting, real laughter, breathlessness, humming, impressions (part 1). No published listening test of English whispers or crying was found for any open model: proof zero measures them against real people.

### Route D: a paid service (described only; nothing is bought)

**ElevenLabs** is the reference. Eleven v4 launched 28 September 2026 [checked by the review: techcrunch.com, 28 Sep 2026] and takes bracketed directions such as `[whisper]`, `[shouting]`, `[terrified]` [checked: elevenlabs.io/blog/eleven-v4]. It also offers Voice Design from a description and a Voice Changer (route B as a service), 1,000 credits a minute or $0.12 a minute through the API [checked via search, earlier pass]. Prices: API $80 per million characters for v4 ($0.08 per 1,000), Turbo $0.04 per 1,000 [checked via search: glbgpt.com, ElevenLabs API pricing page]; plans Creator $22 a month, Pro $99 a month with 600,000 credits [checked via search: elevenlabs.io/pricing/api]; a launch offer that spared v4 credits ended around 12 October 2026 [checked secondhand: smartscope.blog]. **Terms:** content made while on a paid plan keeps its commercial licence after the plan ends; content made on the free plan never has one [checked by the review: elevenlabs.io help centre, "what happens to my content after my subscription ends"]. Not read: anything game-specific. The earlier game's Higgsfield voices also ran on ElevenLabs and those terms were never read (LICENCES2.txt). Route D obeys rule 5 like any engine: a character voiced there is voiced there entirely. **Price: part 12.**

### The recommended mix

| Who / what | Working track (now) | Finished game |
|---|---|---|
| **Danny, Kayla** | route C: Danny 3 / Kayla 3 (Chatterbox) unless a new design beats them blind at the audition | **route A, all their lines**, cast first because they carry most of the hard lines (whispers, crying, the impression, the cut-off scream, laugh-crying). If no performer signs, they stay on one machine engine and every line proof zero marked "real only" is rewritten with the writer into a kind the machine passed (breath and face instead of sobbed words), never left as a failed take |
| **Owen, Priya, Mari, Marcus, Caleb** (14 to 17) | route C, one engine each, chosen at the audition (Marcus 2 is the candidate to beat) | route A for any character with a "real only" line (Mari's humming and singing, Owen's whispers) if a consenting performer and parent sign; else as for Danny |
| **Kessler, Gus, Ray** (adults) | route C, designed voices | route A if a consenting adult wants the part in their own voice; else route B (never for their whispers, shouts or crying: those lines need route A or a rewrite) |
| **Small parts** (announcer, IT technician, laundromat boy, rescue crew, voicemails) | route C | route C, one engine each, or A if someone wants a part |
| **Cutscenes (faces)** | the character's route; the lines must pass the face checks (5.7) | same |
| **Kayla on the radio** | her route, through the radio chain (7.5) | her route |
| **Hunter's whisper, Mimics** | built only from that person's own lines, with the Monster 5 process as the base (part 8) | rebuilt automatically when real lines arrive or a person withdraws |
| **Soldiers (the Patrol), ship's countdown** | not human voices: built from the symbol syllables (audio draft 5, section 4) | same |

**Rule 5 in one sentence:** in the finished game each character has one route and one engine, and changes route all at once.

---

## 3. The voice sheets

Ages are the characters' ages. Every description is written for a voice-design engine and names **no** real person, actor or character from another work. "Real only" lists the lines each character's performer must record whatever route the rest takes.

| Who | Voice | Pace and habits | Afraid | Real only |
|---|---|---|---|---|
| **Danny Reyes, 16** | boy, voice settled but light, warm and a little hoarse; American, local | quick, rides over pauses, jokes land half a beat early; "dude", trailing "...but." | the jokes get faster and smaller, then stop; whispers come out cracked; breath held then let go | his Ms. Kessler impression (slower, clipped, schoolteacher pitch, his own voice underneath), whispers, shouts, crying lines, the scream cut off mid-breath, humming along wrong |
| **Kayla Brooks, 16** | girl, clear mid voice, dry, slightly low for her age | fast, precise, finishes his sentences; short questions; "Stay on the line, okay?" | flat and controlled, then one crack; counts things under her breath | laughing while crying (the hold, the gate), crying, whispers |
| **Ms. Ruth Kessler, 52** | woman, firm, clipped consonants, a classroom voice that carries | measured; counts aloud; "my kids"; full sentences even in panic | gets more formal and slower; the pitch climbs at sentence ends | shouting the count, her hum |
| **Gus Pruitt, 58** | man, low, grainy, unhurried, a smoker's edge without the cough | slow, short sentences, calls Danny "son"; little stories | quieter, not louder; the only calm one, which is the scare when he isn't | his whistle |
| **Ray Dobbs, 44** | man, coach's chest voice, rough from shouting | short orders, cuts people off | anger: loud, cracking on his son's name | shouting, the crack on "Caleb" |
| **Priya Nair, 17** | girl, quick and bright, technical | lists, corrects people, talks to herself | flat certainty ("they're dead") turns to fast hope ("they're breathing") | none expected; proof results decide |
| **Mari Vega, 15** | girl, warm, smiling voice, a little husky; she sings | easy laugh, hums between lines | stays kind for others; her own fear shows in a smaller voice | humming, singing (the camp song, song decision 2), real laughs |
| **Owen Tate, 14** | boy, voice not yet broken, soft | hesitant, asks questions, apologises | whispering, short breaths, asks to be walked past the dark | whispers, his bad version of Mari's song |
| **Marcus Bell, 15** | boy, bright, cheeky | fast, drumstick rhythm in his speech | heard alive only briefly ("You guys'll wait, right?"); later only as the hunter uses him | none |
| **Caleb Dobbs, 17** | young man, lower than Danny, sleepy-rough when woken | few words | dazed, slow | none |
| **The halftime announcer** (adult man, prologue) | a booming, friendly gym PA voice, a small-town sports announcer, slightly over-pronounced | reads the halftime notices and "please remain in your seats"; his words are the hunter's first whispers ("...remain... in your... seats.") | not afraid: cut off mid-notice when the lights die | none; his lines must be must-be-exact (the hunter re-uses them) |
| **The IT technician** (adult, Chapter 4) | adult, tired, careful voice, speaks low to avoid the Mimics | short, practical, technical words ("badge", "antenna", "patch") | whispered panic, controlled | whispers |
| **The laundromat boy** (about 10 to 12, Chapter 6) | a child's unbroken voice, small | barely talks, one-word answers | silent tears, a whisper | whispers; the performer's age and a parent's signature are needed, else his lines are written as near-silent |
| **The rescue crew** (adult, Chapter 5) | clipped radio and shouted voices over rotor noise | call-outs | shouts over noise | shouts (the noise bed hides less than it seems) |
| **Voicemail strangers** (prologue and Chapter 1, dropped phones) | three or four adults and teens, ordinary voices | everyday messages | none | none; each one's words feed the hunter's early whispers |

The soldiers (the Patrol) are not human voices: their calls are built from the symbol syllables (audio draft 5, section 4), so they have no voice sheet.

A **pronunciation list** goes with the script into every engine run and every recording session: "Reyes" = RAY-ess, "Pruitt" = PROO-it, "Nair" = NIRE (rhymes with "fire"), "Rovloc" = ROV-lock, "Kessler" = KESS-ler [the respellings for Pruitt, Nair and Rovloc are this plan's proposals; the writer confirms them]. Each name also gets its expected phoneme string (from espeak-ng, part 5.4) for the name check.

---

## 4. Making voices without copying anyone, and choosing them

### 4.1 Allowed sources

Only: (1) a written description in a voice-design engine (Qwen3 VoiceDesign, Ming-3.0-tts, VoxCPM2); (2) an engine's own stock voices or a blend of them (the Kokoro blends behind Danny 3, Kayla 3, Marcus 2); (3) a designed or stock clip used as the reference for a cloning engine (Chatterbox, Qwen3 Base); (4) the real recording of a consenting person, or that person's own recording processed. Never: a clip of anyone else, a "sounds like" request, a voice from any film, game or show, or a description that names a person. The builder's script refuses a reference file that is not in the voice register with its recipe (as tools3/plan3.py already asserts for unused Kokoro voices).

### 4.2 The chosen voices to beat

The latest record of the owner's choice is 17 November: "Do voice 3 for all and do the whispering one for the monster" (requirements.md). So the working-track voices are **Danny 3** (Chatterbox full, reference out2/refs/danny2_g2.wav), **Kayla 3** (Chatterbox full, kayla2_g2), **Marcus 2** (Chatterbox full, marcus1_g2), and the hunter's base is **Monster 5** (tools2/monster2.py `close()`: an LPC whisper of the calm take, a breath before it, dry) [checked: docs/design/voices/production-progress.txt, requirements.md, audio draft 5 section 7.1]. *The first version of this plan named Danny 1 / Kayla 1 / Marcus 1 from REPORT3.txt; round 4 (production-progress.txt, 18 November) is the later record, and it agrees with report 04 and audio draft 5.*

### 4.3 One reference and one anchor per kind

The biggest cause of "robotic" last time was a flat read-aloud reference (part 6). A cloning engine (Chatterbox, Qwen3 Base) copies the delivery of the clip it is given, and Qwen3 Base takes no instruction, so **every kind of line needs its own acted reference of the same voice**: calm, joking, frightened, whisper, shout, crying, winded (seven per voice). The script sheet's State, Fear and Loudness columns choose which reference a line uses.

How they are made: from the same description (or, for Danny 3 / Kayla 3 / Marcus 2, from the same stock blend), the builder renders each kind with whatever direction the engine takes (Qwen3 VoiceDesign `instruct`, Ming-3.0-tts `EMOTION` and tags, Chatterbox's `exaggeration` and an acted earlier reference), many seeds, and keeps the take of each kind that (a) passes every gate of part 5 itself and (b) is closest in identity to the calm reference. These seven clips are both the **references** and the **anchors** for that voice.

**Identity is checked kind against kind.** Emotion lowers speaker-match scores against the same person's calm speech [checked by the review: isca-archive.org/interspeech_2025/goebiowska25_interspeech.pdf], so a crying take is compared with the crying anchor, never with the calm one. The anchors themselves must stay one person: each kind's anchor must be at least as close to the calm anchor as **real people's** own kind-to-calm closeness, measured on the proof-zero real recordings, minus 0.05 [starting guess until those are measured: 0.60]. Whisper anchors are checked by ear only (part 9.2), because speaker embeddings are unreliable on unvoiced speech [from memory].

**The impression.** "Danny doing Kessler" gets its own anchor, made from Danny's voice with the Kessler direction. It is checked only loosely against Danny's calm anchor (similarity reported, no gate) and the owner's ear decides. It is real only in the finished game (part 1).

**Instruct takes.** "Instruct" takes (a written delivery direction) are made only on Qwen3 VoiceDesign, where the instruction works, and go through the identity gate like any take. Before the proof, the builder runs the README's design-then-clone example once with an instruction added on the Base model and records whether the output changes (expected: it does not, or it errors). That result goes in LICENCES4's engine notes.

### 4.4 The audition page

One page per character, before any of that character's lines are made in bulk. **Four candidates** per character, all from **one engine each** (the engine a candidate wins on is the engine that character keeps: rule 5). For Danny, Kayla and Marcus one of the four is the voice he chose (Danny 3, Kayla 3, Marcus 2). Each candidate says the same **four test lines**, in the character's words from the script:
1. **calm** (Gus: "Generator wants three things. Fuel, air, and patience.");
2. **joking** (Danny: "So I'm the one who stays behind. Cool. Love that for me.");
3. **frightened** (Kayla: "It's in. It's inside, Danny.");
4. **the hardest kind that character has which machines passed in proof zero** (if none passed, a second frightened line).

16 clips, names hidden and shuffled, all through the same finishing (7.4), about 4 minutes. He picks one or "none of these" (four new candidates follow). Only candidates that pass every automatic gate reach the page.

---

## 5. The pipeline, line by line (for the builder)

### 5.1 The script sheet

One row per line (a CSV the build reads), with a direction for every line:

`LineID, Chapter, Scene, Speaker, ToWhom, Text, CarrierText, MustBeExact(y/n), WhatJustHappened, Place, Distance(close/room/far/radio), Kind(calm/joke/frightened/whisper/shout/crying/winded/laugh/laugh-crying/impression/hum/whistle/scream-cut), Loudness(1 whisper .. 5 shout), Fear(0-3), State(calm/winded/scared), BreathBefore, BreathAfter, Pace(slow/normal/fast), Overlap(LineID, cut-at-word), Face(cutscene/play/radio/offscreen), Route(A/B/C/D), RealOnly(y/n), Strong(y/n)`

Example: `C01_S07_DAN_0112 | Danny | to everyone | "I'm getting everyone out. All of you. Which, historically, from me, means nothing. But." | MustBeExact y (the hunter re-uses it) | first night, Mari just played the song, Owen is asleep against him | shelter | room | calm | 2 | 1 | calm | small breath before "But" | none | slow, the "But." left hanging | cutscene | C | n`.

`Kind` chooses the reference (4.3), the anchor, and which gates apply. `RealOnly` is set from part 1 and from the proof-zero results; the build refuses a RealOnly line from any route but A in a release build. Strong-language lines (about eight) are made twice: with and without the word.

### 5.2 Takes

- Route C: **8 takes per line on the character's one engine**: 4 seeds × 2 directions (e.g. two references of the same kind, or two instruct wordings on Qwen3 VoiceDesign, or exaggeration 0.3 and 0.5 on Chatterbox). No second engine in the finished game (rule 5).
- Route B: 2 to 3 performances × 2 conversion settings.
- Route A: 3 takes + 1 free take.

### 5.3 The gates (pass or fail; one failure and the take is out)

The old checker (tools/voices/tools2/analyze.py: pitch movement, pitch wobble, buzz, smear, recogniser) is the starting point. Gates are **per character and per kind**, set from that character's own acted anchors (4.3), never from Danny's numbers for everyone. Every gate is also run over the real proof-zero recordings: **a gate that fails more than 1 in 10 real takes of a kind is wrong** and is loosened for that kind before it is used.

| Check | Tool (licence) | Gate (starting value; then per character and kind) | Not used on |
|---|---|---|---|
| **Right words** | Whisper large-v3 (code MIT [from memory]; the weights' card is tagged Apache-2.0 [checked via search]) **and** NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0 [checked: card, earlier pass]) run through **onnx-asr** (MIT, v0.12.0, works on Windows with CUDA or DirectML [checked today: pypi.org/project/onnx-asr]). Both must agree. Neither is ever given the names or the script as a hint | every must-be-exact word right; others ≤ 5 % word error (whispers ≤ 10 %, crying ≤ 15 %); no extra words (hallucinated tails are a known fault) | the hunter's chain gets its own check (part 8) |
| **Names said right** | phoneme recogniser facebook/wav2vec2-lv-60-espeak-cv-ft (Apache-2.0 [checked via search: card metadata]) on the name cut out at WhisperX's word times; expected phonemes from espeak-ng (GPL-3.0 [from memory], a tool on the PC that outputs text only) | phoneme distance ≤ 1 from the expected string for the respelling (5.4) [starting guess, checked on the real recordings] | |
| **Same person** | SpeechBrain ECAPA speaker embedding (Apache-2.0 [checked via search: spkrec-ecapa-voxceleb card]) | similarity to **the anchor of the same kind** ≥ 0.75 and ≥ 0.10 higher than to any other character's anchor of that kind [starting guess, calibrated in proof zero] | whispers (ear only, 9.2); lines under 1 second (checked on the carrier take, 5.6); the impression (reported only) |
| **Flat pitch** | pyworld, analysis only | pitch movement ≥ 80 % of the character's own anchor of that kind; before anchors exist, talk ≥ **5.0** semitones SD (flat Kokoro reads measured 3.6 to 4.7, acted takes 6.6 [checked: out2/A1_causes.txt]) | whispers; lines under 4 words |
| **Too-smooth pitch** | pitch wobble between 5 ms frames | ≥ 80 % of the anchor's wobble (start: ≥ 24 cents; acted ~33, flat synthetic 15 to 22 [same source]) | whispers; lines under 4 words |
| **Buzz / metallic** | aperiodicity 1 to 4 kHz | ≥ -16.5 dB (vocoder buzz measured -19.4; acted -13.4 [same source]) | whispers (they are all noise) |
| **Real whisper** | voiced-frame share | ≤ 10 % of speech frames voiced, so a whisper is not quiet talking [starting guess] | everything but whispers |
| **Smear** | spectral flux | ≥ 6.0 dB per 10 ms (stretched takes fell to 5.6 to 5.8 [same source]) | |
| **Pacing** | words per second from the recogniser's word times | inside the character's own band for that pace, from its anchors (start: talk 2.2 to 3.6, scared up to 4.2, slow 1.6 to 2.6) | lines under 4 words |
| **Pauses where asked** | gaps between words | a "..." or "beat" in the direction has a pause ≥ 0.35 s there | |
| **Clipping** | sample and true-peak scan | no run of 3+ samples at full scale; true peak ≤ -1 dBTP after gain | |
| **Noise** | speech-to-silence level; DNSMOS background score (CC-BY-4.0 [checked: microsoft/DNS-Challenge LICENSE, earlier pass]) | ≥ 35 dB between speech and the quiet parts before room tone is added | route A takes use the session's room tone as the floor |
| **Clicks and joins** | jumps between samples; flux spikes away from word starts | none above threshold; any join sits in silence or at a cross-fade ≥ 10 ms (overlap cuts: 5 to 10 ms, 7.3) | |
| **Breath** | energy 1 to 6 kHz with no pitch, 150 to 600 ms | where the direction asks for a breath, one is there; Mimic lines have none | |

### 5.4 Names

A recogniser writes "Reyes" when it guesses the word, so spelling right is not saying right. The name check cuts the name out of the take at its word times, runs the phoneme recogniser on it with no hint, and compares the result with espeak-ng's phonemes for the respelling ("ray ess", not "rays"). It is run on the real recordings first; if real people fail it, the threshold is wrong, not the people.

### 5.5 Ranking the takes that pass

The recognisers are **only** a gate: they never add to the score, because a recogniser is most confident on clear, evenly paced, fully pronounced words, the reading voice the owner rejected. The synthetic-speech detector is **not** in the score either: 2026 papers report that such detectors miss modern engines, Maya1 and Dia2 among them [checked by the review: arxiv.org/html/2601.20510; arxiv.org/pdf/2607.11706]; it is run and logged beside the owner's answers only, to see whether it ever predicts them.

Score, compared **only between takes of the same line**:
- **35 %** pitch movement and wobble, as a share of the character's anchor of that kind (on whispers this share moves to the next item);
- **25 %** loudness movement and pause pattern against the direction (short-term loudness spread, pauses where the direction puts them, no pause where it says "rushed");
- **25 %** emotion fit: emotion2vec+ large (FunASR model licence, read today: §2.1 "free to use, copy, modify, and share", §2.2 credit the source and keep the model names, §3 "provided for reference and learning purposes only" as a disclaimer, §4.2 forfeits the licence for "denigration", §6 may be revised [checked today: raw.githubusercontent.com/modelscope/FunASR/main/MODEL_LICENSE]). It runs on the PC only and nothing it makes ships; the text and date go in LICENCES4. If the lead reads §3 as ruling out work on a game for sale, this 25 % moves to pitch;
- **15 %** UTMOSv2 (MIT [checked by the review: model card]). It was built to score clean read speech [checked by the review: arxiv.org/abs/2409.09305], so it is a small share and never a gate.

The top two go forward, the best is used. Audiobox Aesthetics (CC-BY-4.0) is logged only.

### 5.6 Short lines (under four words)

Engines over-pronounce single words and recognisers invent words on them. So a short line is made **inside a carrier**: the line before it if the same character says it, otherwise a written carrier sentence in the same mood (`CarrierText`, e.g. "I don't know. ...Yeah."), rendered as one take, then **cut out at the silence** before it (a trim, which rule 1 allows; the silence must be ≥ 150 ms, else the take is redone). Gates: words, name, buzz, clipping, clicks; the identity check runs on the whole carrier take; the rhythm gates (pitch spread, pacing, pause spread) are skipped. **Every short line in a chapter goes into that chapter's listening sample** (9.5), played as a quick list.

### 5.7 Faces

MetaHuman audio-driven animation on every cutscene line. The lines must be clean enough (the noise gate above) and the solve is checked by frame inspection of its curves against the recogniser's word times: no mouthing in silence, closed lips on m, b and p. In 5.8 the audio solve outputs at a fixed 30 fps [checked: MetaHuman 5.8 known issues via search, earlier pass]. Hunter whispers and radio lines drive no face.

### 5.8 Names of files, storage and the manifest

Masters 48 kHz, 24-bit mono WAV, named `VO_<Chapter>_<Scene>_<Speaker>_<Line>_<State>_T<take>.wav` (e.g. `VO_C01_S07_DAN_0112_CALM_T3.wav`). All takes in `Source/VO/<Speaker>/` outside the Unreal project; the chosen take imported to `Content/Audio/VO/<Speaker>/`. A `vo_manifest.json` entry per file: route, engine, model and file hash, seed, description or reference, performer and release number with the uses ticked, gate numbers, rung of the ladder, and whether it is a temporary voice. LICENCES4 holds each model's licence text, where and when it was read.

### 5.9 A line that fails

Every line goes down this ladder until a take passes; the sheet records which rung:
1. **More takes** (8 new seeds) on the same engine.
2. **Re-direct:** another reference of the same kind, the instruction, the exaggeration, the punctuation (a comma or "..." fixed four slot failures last round), the description of the moment.
3. **Re-write** with the writer, same meaning, easier mouth ("Sales at 4" became "Sal's at four!"). Never for must-be-exact lines.
4. **Working build only:** another engine, converted to the character's anchor voice and passing the identity gate. Tagged "temporary voice"; the release build refuses it.
5. **Edit the best take** with Step-Audio-EditX, only once 11.1 shows it runs and its weights' licence is read; until then this rung does not exist.
6. **Mark REAL-ONLY.** The line goes on the recording list of that character's performer. In every build the owner plays, its subtitle shows **"[temporary voice]"**, so he does not judge a scene by a failed take. If a character has REAL-ONLY lines and no performer, the writer reworks those lines (5.9 rung 3 rules apply).

### 5.10 What the checks cannot tell, and who checks it instead

The builder cannot hear. The checks above measure things that went wrong before (flat melody, buzz, smear, missing pauses, wrong words) and things that can be counted. They **cannot** tell:
- whether a voice sounds its age (a 14-year-old against a 25-year-old) → the audition, his ear;
- whether the emotion is the right one for the moment, or only the right label (the emotion model was trained on acted corpora) → cutscene checks and chapter samples;
- whether two lines sound like one person to a person (an embedding score is not a listener) → the same-person pairs, 9.2;
- whether a joke lands, a pause feels right, a whisper is creepy → his ear, 9.3 and 9.4;
- whether the radio chain hides a fault it should not → the recogniser re-check after the chain (7.5), and his ear on the radio lines in the chapter sample;
- anything about a line type no real recording has calibrated yet → such a gate is marked "uncalibrated" in the manifest and its line goes into the chapter sample.

Every claim in this plan that something "sounds real" means: it passed these gates **and** the owner's ear at the named point. Neither alone.

---

## 6. What made voices robotic before, and the rules (for the builder)

Measured last round (out2/A1_causes.txt): **(1) the reference:** cloning engines copy the melody of the clip they are given, and every reference was a flat read-aloud paragraph; **(2) the vocoder** (WORLD pitch and formant shifting): it made the voice 3.7 dB buzzier and halved the natural wobble even with no change; **(3) time-stretching** (WSOLA): it stretches every sound evenly and smooths the wobble; **(4)** a cap on every pause removed natural hesitations. After all four were removed, he said "Voices good".

**The rules (the build refuses to break them):**
1. **No pitch shifting, formant shifting, vocoder resynthesis or time-stretching on any human line.** Finishing is trim, gain, fades and room tone. **Two written exceptions:** (a) the hunter's chain (part 8), which is meant to sound unnatural; (b) route B conversion, and only when the converted line keeps at least 85 % of the performer's original wobble, changes buzz by 1.5 dB or less from the original, and passes the same-person check (9.2); never for whispers, screams, crying, humming or laughing while crying.
2. Every reference clip is acted, matches the line's kind, and passes the gates of its kind itself.
3. Pauses are never capped; a pause is shortened only by cutting silence at a breath, never inside a word.
4. A line that is too long or short is re-taken or re-written, never stretched.
5. **One character, one person.** In the finished game every character's lines come from **one route and one engine**. A character changes route all at once (for example, Danny goes fully real), never line by line. A second engine, or rung 4 of the ladder, is allowed only in working builds, only after the take is converted to the character's anchor voice and passes the identity gate, and always tagged "temporary voice". A character mixing routes in the finished game (for example a real performer who could record only part of the script) is allowed only if that character passes the same-person check (9.2: 6 of 6, both decoys called "different") **and** the owner says yes to that mix, recorded in the decision log.

**Other tells of machine speech, and the fix for each:**

| Tell | Fix |
|---|---|
| Every sentence ends with the same falling tune ("reading cadence") | pitch gates per kind; directions that say what the line *does* ("asks without wanting the answer") |
| Too perfect: every word fully pronounced | write as people talk ("gonna", "c'mon", "I— no."); allow rewording; recognisers never in the ranking (5.5) |
| No breaths, or the same breath every time | breaths from real recordings (7.1), never one sample twice in a scene |
| Same loudness all line long | loudness movement is 25 % of the ranking; reject emotional lines whose short-term loudness spread is under 3 LU [starting guess] |
| Dead-dry "studio" voice in a concrete basement | room tone and Unreal's place reverb (7.4) |
| Voice drifts from line to line, or changes person | rule 5; identity per kind; the same-person pairs |
| Teenagers sounding 25 (engines lean towards adult narrators) | age in every description; the audition; his ear |
| Wrong stress on names | the pronunciation list; the phoneme check (5.4) |
| Extra words, repeats, mumbled endings | the two-recogniser gate |
| Hiss or metal on "s" and "sh" | buzz and noise gates; another seed (never an EQ that hides it) |
| Pasted-on laughs | real laughs placed by hand, or inline tags only where the take passes the emotion check; laugh-while-crying is real only |
| A one-word line said like a dictionary entry | the carrier method (5.6) |
| A cut-off line that finishes its tune | the overlap method (7.3) |
| Same take heard twice | never the same take of a line twice in a scene; repeated barks get 3 to 5 takes |

---

## 7. Performance editing (for the builder)

### 7.1 Breaths, laughs, cries, efforts

A library recorded by consenting people (route A sessions): at least 20 breaths per character type (calm, winded, scared, crying) and 10 efforts, placed by hand at the direction's marks, matched to the line's level and filtered to match its tone. For a machine voice, breaths come from a consenting person of similar age and sex, **which for most of the cast means a teenager, so a parent or guardian signs too**; the release ticks use 5 (part 2). The build refuses a breath without a release number in vo_manifest.json. Placing a real breath under a machine voice is a mix of two people, so those lines are in the same-person pairs (9.2).

### 7.2 Hesitations

Written into the text ("I— I didn't...") so the engine performs them, or made by inserting room tone between words at a natural break. Never by stretching.

### 7.3 Talking over each other

Each speaker is a separate file, so each can drive its own face and be mixed on its own. An engine finishes a written cut-off ("I was gonna—") with a complete, falling tune. So the interrupted line is **made with its continuation** ("I was gonna say we should check the—") and **cut mid-word, with a 5 to 10 ms fade, exactly where the other speaker starts**; the cutscene places the second line at that point. Dia2 may be used to find natural overlap timings (where a cut-in lands, how long both voices sound together), never for a shipped line. Real recordings of two people in one room are best.

### 7.4 Room tone, place and loudness

Every finished file carries a quiet noise floor (about -60 dBFS, never digital silence). Voices are stored close and dry; the place (shelter, gym, tunnel, stairwell, roof) comes from Unreal's reverb and impulse responses, so one take works anywhere. Normal talk at -23 LUFS integrated; whispers, raised voices and shouts keep their performed level relative to that (start: whisper about -32, shout about -16); true peak ≤ -1 dBTP; cutscene dialogue lands -23 to -20 LUFS short-term over beds 14 to 18 dB lower (report 06, 6.4).

### 7.5 Kayla's walkie-talkie

Band-pass 300 to 3,400 Hz, light saturation, fast compression, press click and squelch tail, static that grows with height. **Fair rule:** a take must pass every gate before the chain; the chain may hide a faint top-end sizzle, never a wrong word, a flat melody or a change of person; the recogniser re-checks after the chain (word error no more than 5 points above the clean take). Clean versions are kept for when she is in the room. Radio lines are in each chapter sample, so his ear checks what the chain hides.

### 7.6 Danny in three states

Every playable Danny line is made **calm, winded and scared** as three performances, never three effects: winded with breaths between word groups and words on the out-breath; scared faster, higher, smaller. Each state uses the reference and anchor of its kind. The game picks the state from his stamina and threat. On route A, the performer records all three.

---

## 8. The hunter's whisper and the Mimics

**Where the words come from:** only words that person said on screen, alive, earlier (report 04, 2.5; report 06, 4.3; audio draft 5, section 4). The heard bank is built from the finished takes: forced alignment (WhisperX, BSD-2 [checked: LICENSE, earlier pass]) cuts each word at its boundaries; each whisper is a written sentence of 2 to 6 of that person's words, with its source lines listed. It never says a new word in someone's voice. When a real recording replaces a machine line, or a person withdraws, the bank rebuilds from vo_manifest.json.

**The chain starts from the owner's pick, Monster 5** (tools/voices/tools2/monster2.py `close()`: an LPC whisper of the person's own take, so their vowel shapes, which carry who they are, survive; high-pass 70 Hz; a +5 dB low shelf at 250 Hz like lips at the ear; a breath 6 dB under the whisper, then a 0.18 s beat, then the line; no room at all). **"An eerie creepy version"** adds, as separate switchable steps on top of Monster 5 (the steps audio draft 5 section 4 already lists):
1. uneven timing by moving the word fragments, never stretching them: one word late, the next too soon, a gap where no one would pause;
2. a second, fainter copy from another take of the same words, 12 dB down and 40 ms late (range 10 to 14 dB, 30 to 60 ms);
3. one extra inhale where nobody would breathe, as well as Monster 5's breath before;
4. on the last word a short frozen tail.
Strength grows towards the mothership, never so far that a word is lost. Only this chain may resynthesise (rule 1a).

**Checks the builder can run:** both recognisers on the processed line, word error ≤ 10 %, every name right; the voiced-frame share stays a whisper (≤ 10 %); speaker similarity of the whisper to the same person's **whisper anchor** above a floor set in the first proof; no sentence repeated in a chapter (audio draft 5, section 11). Last round the recogniser caught a whisper double misheard as "on on"; the fix was another base take, so the check stays. **Whether it is creepy cannot be measured**: that is his ear (9.3).

**The Mimics:** a plain copy of a known voice, deliberately a little *too* clean: no breath, the same line with the same timing every time. Here the machine tells are the design. For a machine-voiced character, the line is made in that character's voice and engine, breaths removed, one take reused exactly. For a real-recorded character, the person **records the Mimic lines themselves** ("say it like a recording"), use 3 ticked on the release; no one's voice is cloned. Kayla's copy is used once ("What time?") and never on the radio. Checks: words; identity as high as her real lines (it has to fool you); zero breaths detected.

---

## 9. The owner's ear

Every listening page runs on his PC with headphones, plays each clip once (replay allowed), and has buttons only. Every clip on a page goes through the **same finishing**: the same loudness (-23 LUFS, whispers and shouts at their kind's level), the same room tone, the same game room reverb, the same file format and sample rate (all resampled to 24 kHz, the lowest any source has, so a microphone's wider top end gives nothing away), and real and machine clips trimmed the same way. Before a blind page is shown, the builder measures each clip's noise floor, top-end roll-off frequency and reverb level; if real and machine clips differ on any of them more than the clips within each group do, the page is not shown until the finishing is fixed.

### 9.1 The blind pairs (sets the bar)

**24 clips: 12 lines, each once real and once machine.** The real clips are recorded by consenting people **other than the listener** (release use 6 ticked; a parent too for anyone under 18). The machine clip is the best take of that line from the character's one engine. The lines cover whisper, frightened, shout, crying, joke and short thrown-away lines, not only ordinary talk (the proof-zero list, part 10). Clips are played one at a time, shuffled, with the two clips of a pair in different halves of the session; for each he presses **"real person" or "machine"** (no "not sure").

**Pass rule: 16 or fewer of 24 right.** Guessing alone gets 17 or more about 3 % of the time [checked here: binomial, 24 tries at one half], so 17 or more means he can hear the difference. **Honest limits:** (a) because each line appears twice, he may answer the pairs together; then guessing reaches 17 or more about 7 % of the time, and that error only sends more lines to real recording, the safe direction; (b) 24 clips catch a clear difference but not a slight one: if he is right 7 times in 10, he still scores 16 or less about 43 % of the time [checked here: binomial]. So the test is **repeated at the end of the first proof with 24 new clips, and the two are pooled: 48 clips, pass is 30 or fewer right** (31 or more by guessing about 3 %; this catches the 7-in-10 listener about 84 % of the time). If fewer pairs can be made (no performer for one character), the pass rule scales: 20 clips, 14 or fewer; 16 clips, 11 or fewer.

**Reported per kind.** A kind whose machine clips he called "machine" every time goes to real recording (route A), whatever the total.

### 9.2 Same person? (one character, one voice)

For each character: **6 pairs** of two different lines, played back to back: calm beside hard (frightened, shout, crying, winded), main reference beside another reference, a line with a real breath placed in it beside one without, and, wherever a character is mixed (rule 5) or a working build used rung 4, the main route beside the other. Plus **2 decoy pairs per page** that really are two different voices (two audition candidates), so the page shows whether "same" is being pressed by habit. Buttons: "same person" / "different person". **Pass: 6 of 6 "same" and both decoys "different".** About 1.5 minutes a character. A character that fails is fixed (another reference, another engine for the whole character, or route A) before more of its lines are made.

### 9.3 The hunter: who is it, and is it creepy?

6 whispers from 3 or more taken people; for each he names whose voice it is and presses **"creepy enough? yes / more / too much"**. Then one side-by-side: Monster 5 alone against the full chain (part 8) on the same two lines; he picks. **Pass: 5 of 6 named right and at least 4 of 6 "yes".** "More" from most answers turns up one step of the chain; "too much" turns one down; the steps he hears are logged so the next page changes one thing at a time. About 3 minutes.

### 9.4 The auditions

Part 4.4: 4 minutes per character.

### 9.5 Each cutscene and each chapter

- **Each cutscene's mix**, once, finished: "fine", "a voice sounded fake" (tap the moment), "too quiet / loud".
- **A sample of each chapter:** 20 lines at random, plus the 5 lowest-ranked that passed, plus every short line (5.6) and every line whose gate is "uncalibrated" (5.10), as a quick list with "fine" / "fake". About 3 to 4 minutes.

Anything marked fake goes back down the ladder (5.9), and **the checker is changed until it would have caught it**; a gate that did not separate his "fake" from his "fine" is loosened or dropped (the calibration rule, 10.4).

---

## 10. Proof zero: two days, twelve lines (before anything else)

The one question that decides the routes is whether a machine can pass his ear on whisper, fear, shout, crying and the throwaway lines. Proof zero answers it first, with the hardest age (Owen, 14) included.

### 10.1 The twelve lines

| # | Who | Kind | Line (from the map and cutscene outline; the writer may swap in the final script's wording) |
|---|---|---|---|
| 1 | Danny | joke | "So I'm the one who stays behind. Cool. Love that for me." |
| 2 | Danny | thrown away | "...Yeah." (carrier method, 5.6) |
| 3 | Danny | whisper | a hiding line from Chapter 1, e.g. "Kayla. It's right outside. Don't talk." |
| 4 | Danny | shout | a Chapter 1 or 5 shout, e.g. "Gus! Shut it! Shut the door!" |
| 5 | Danny | crying | his last true line at the hold (the line the script gives) |
| 6 | Danny | impression | the Kessler voice: "Miss Brooks. Is something funny?" |
| 7 | Kayla | radio | "Stay on the line, okay?" (through the radio chain) |
| 8 | Kayla | frightened | "It's in. It's inside, Danny." |
| 9 | Kayla | laugh-crying | her laugh-while-crying after the impression |
| 10 | Owen | whisper | a whisper asking to be walked past the dark |
| 11 | Owen | question | a hesitant question to Danny |
| 12 | Owen | scared | a short scared line |

Lines marked "e.g." are placeholders for the scripted lines of that kind; the kind is what matters.

### 10.2 Day 1: the machine side

1. Set up on Windows, one Python 3.12 environment per engine, PyTorch built for CUDA 12.8 or later (which the RTX 50 series needs [from memory]); one model in memory at a time, the Unreal editor closed. Engines: Chatterbox full (already pinned), Qwen3-TTS VoiceDesign and Base, Ming-3.0-tts-0.5b once its weights' card is read. Read and save every licence and card into LICENCES4 with the date.
2. Run the Qwen3 Base instruction test (4.3) and record the result.
3. Voices: Danny 3 and Kayla 3 as chosen; Owen gets two designed candidates (Qwen3 VoiceDesign and Ming-3.0-tts). For each voice, make the per-kind references and anchors (4.3) for the kinds in 10.1.
4. 8 takes of each line on each engine tried for that character; gates (5.3, with starting values); ranking (5.5). For each character, keep **the one engine whose takes rank best across that character's lines** (rule 5 applies even here), and its best take per line. The old Danny 3 / Kayla 3 takes are made exactly the same way.
5. Also make the same-person pairs (9.2) for Danny, Kayla and Owen from extra calm lines and the hard lines above.

### 10.3 Day 2: the real side and the listening

1. Two or three consenting people **other than the owner**, chosen by him, release signed (uses 6, and 1 to 3 if they may later be cast; a parent or guardian for anyone under 18), record the same 12 lines, 3 takes each, as route A says (part 2). For Owen's lines the closest consenting performer in age; if there is none, Owen's pairs are left out and the pass rule scales (9.1). About 30 minutes of recording.
2. Pick the real take of each line by the same gates (with words loosened as 5.3 says); the builder never picks a real take for sounding "worse".
3. Run every gate over the real takes: a gate failing more than 1 in 10 real takes of a kind is fixed before the results are read.
4. Finish all 24 clips identically and run the finishing check (9 intro).
5. **He listens:** the blind page (24 clips, about 5 minutes), then the same-person pages (Danny, Kayla, Owen, about 4 minutes).

### 10.4 What the result decides

- **Per kind:** a kind whose machine clips he always picked out → that kind is **REAL-ONLY** for every character (part 1's table and 5.1's `RealOnly` are updated). Whispers, crying, laugh-crying, impressions, humming, whistling and cut-off screams are real only already; proof zero can only confirm that or, if he could not tell at all, let the lead ask him whether machines may try them.
- **Overall 17 or more of 24 right** → the machine track cannot meet the bar on the tested kinds; route A is brought forward for Danny and Kayla, and he is asked which scenes matter most to record first.
- **16 or fewer** → machines may carry the kinds he could not tell, on the working track and, for characters without a performer, in the finished game, subject to the pooled re-test (9.1) at the end of part 11.
- **Same person** fails for a character → that character's references or engine change before the first proof.
- **Calibration:** every gate is checked against his answers. A gate stays only if the clips he called "machine" fail it more often than the clips he called "real". The old rounds 1 to 3 are not used to calibrate, because the gates were built from those same files (out2/A1_causes.txt); they are only a sanity check.
- **The detector** (W2V2-AASIST or XLSR-SLS) is run on all 24 and logged beside his answers; it enters no decision.

Only after this does part 11 run, and only for the kinds machines passed.

---

## 11. The first proof (the rest of the slice)

**The slice:** Danny, Kayla, Gus and Ms. Kessler, about 60 lines from the prologue and Chapter 1 (Danny 25, Kayla 15 with 10 on the radio, Gus 10, Kessler 10), **only in the kinds proof zero let machines carry**, plus 4 winded Danny lines and 2 overlaps. The REAL-ONLY lines of the slice go on the recording list and play with "[temporary voice]" in their subtitles.

1. **Step-Audio-EditX test (11.1).** In WSL2 with `.wslconfig` set to `memory=12GB` and `swap=16GB` (WSL2 otherwise takes about half the PC's memory, 8 GB of 16 [checked by the review: Microsoft-based guides and NVIDIA's WSL2 notes]), load the **AWQ 4-bit** checkpoint first (its makers estimate about 8 to 10 GB of video memory [checked today: README]) and log peak video and system memory on 5 lines. It joins the ladder as rung 5 only if it runs without running out of memory, its weights' licence is read and recorded, and its edited takes pass the same gates as any take. If the owner adds memory (map decision 11), the test is run again.
2. **Design candidates** for Gus and Kessler (four each, one engine each) and the audition pages (4.4) → he picks. Danny and Kayla keep the proof-zero winner.
3. **Per-kind references and anchors** for all four (4.3).
4. **60 lines × 8 takes**, gates, ranking, ladder; record each rung.
5. **Finish:** breaths (7.1), room tone, Kayla's radio chain (7.5), Danny's three states on 5 lines (7.6), the two overlaps (7.3).
6. **Faces:** MetaHuman audio-driven animation on 6 cutscene lines per character, checked as 5.7.
7. **Hunter:** 6 whispers built from Danny, the announcer and a voicemail stranger (the prologue's taken voices), with the Monster 5 base and the chain steps (part 8) → the hunter page (9.3).
8. **He listens:** same-person pages for Gus and Kessler (9.2); the second blind page with 24 new clips, pooled with proof zero's (9.1); one cutscene check (9.5).

**What is measured:** first-time pass rate per kind; rungs needed; REAL-ONLY count by kind; blind results per kind; same-person results; identity spread per character and kind; machine time per finished line; face-solve faults; Step-Audio-EditX memory.

**What would make us change route:**
- Pooled blind result 31 or more of 48 right → the machine track does not meet the bar for those kinds: route A for the main cast before more lines are made, and he is asked which lines matter most.
- More than a third of a kind's lines end REAL-ONLY → that kind is made by performance from the start.
- A new design does not beat Danny 3 / Kayla 3 at the audition → keep them; Chatterbox stays despite being retired (pinned and hashed).
- A character's identity drifts on more than 1 line in 10, or fails the same-person page → fine-tune that voice (Qwen3 Base fine-tuning [checked: README, finetuning folder]) or move the whole character to another engine; never patch single lines from another engine.
- The checker passes lines he calls fake → fix the checker before going on.

---

## 12. What it would cost if he ever chose a paid route

Stated once; nothing here is bought without his yes. Two line counts, because the map keeps the script to **about 1,200 lines** while audio draft 5 (7.2) counted **about 3,100**, and Danny's three states turn those into about 4,400 performances [estimate from draft 5's "900 lines, about 2,200 takes"]. About 55 characters a line [estimate, earlier pass]; four takes plus auditions and retakes is about five passes.

| | 1,200 lines | 3,100 lines (4,400 with Danny's states) |
|---|---|---|
| Characters for five passes | about 330,000 | about 1,200,000 |
| ElevenLabs v4 through the API at $80 per million characters [checked via search] | about **$26** of use | about **$97** of use |
| or on plans at about 1 credit a character [checked secondhand] | one month of Pro ($99), or three of Creator ($66) | two months of Pro ($198) |
| Voice Changer for real performances (route B as a service), 3 takes, $0.12 a minute through the API [checked via search] | about 60 minutes of speech: **about $22** | 2 to 2.5 hours: **about $54** |
| **Roughly, all in** | **$50 to $150** | **$100 to $300** |

Whether API use needs a plan as well, and any game-specific terms, were not read. Content made on a paid plan keeps its commercial licence after the plan ends; free-plan content never has one [checked by the review: ElevenLabs help centre]. Uploading a person's recordings needs release use 7. Real recordings cost nothing with phones; a USB microphone and pop filter about $60 to $150 [from memory].

---

## 13. The store notice

If the game goes on a store, **its AI-voice notice lists which characters are machine-voiced** (and any converted by route B, and that the hunter's whispers are made from those voices). Steam's rules, rewritten in January 2026, ask for AI-made content that players see or hear and AI used in marketing to be stated, and exempt tools used behind the scenes [checked via search: pcgamer.com, videogameschronicle.com, January 2026], so the recognisers and checkers in part 5 need no mention. The list comes straight from vo_manifest.json's route field.

---

## 14. What could not be verified today

- Every Hugging Face card (huggingface.co could not be opened from here): read again on the PC for Qwen3-TTS, Ming-3.0-tts weights, VoxCPM2, Maya1's config.json and tokenizer, Step-Audio-EditX weights, Parakeet, Whisper large-v3, SpeechBrain ECAPA, wav2vec2-lv-60-espeak-cv-ft, emotion2vec+, UTMOSv2, Dia2, Seed-VC.
- Whether Maya1 and VoxCPM2 were trained from a base model under another licence.
- How any open engine performs English whispers, crying and shouting; Ming-3.0-tts and VoxCPM2 memory use on 12 GB; PyTorch and FlashAttention on the RTX 5070 under Windows. Proof zero measures the first; part 10.2 logs the rest.
- Seed-VC on frightened performances; whether the GPL-3.0 weights raise any question for sound made with them.
- The starting thresholds marked "starting guess": calibrated in proof zero (10.4).
- Whether Chatterbox's GitHub repository is formally archived: today's page shows no archive banner, and its README says it has been retired research since August 2026 [checked today]; a mirror's "5 January 2026" (review finding 8d) is the mirror's own date [from the review: gitverse.ru].
- ElevenLabs' game-specific terms and whether API use needs a plan; Higgsfield's terms (never read).
- Whether the pronunciation respellings for Pruitt, Nair and Rovloc match the writer's intent.
- Whether 24 kHz machine voices beside 48 kHz real voices sound different in the mix (machine engines output nothing above 12 kHz); checked at the first cutscene check, and a gentle 12 kHz low-pass on real takes is allowed only if he hears the difference.

---

## 15. Tools and licences (what goes into LICENCES4)

| Tool | Use | Licence | Where read | In the game? |
|---|---|---|---|---|
| Chatterbox full / Turbo / VC | voices of Danny 3, Kayla 3, Marcus 2; route B | MIT; retired research since Aug 2026 | github.com/resemble-ai/chatterbox, 21 Nov 2026 | its output |
| Kokoro 82M (stock voices) | references | Apache-2.0 | card, LICENCES2/3 | no (reference only) |
| Qwen3-TTS 1.7B VoiceDesign / Base / CustomVoice | voice design, cloning | Apache-2.0 | card (earlier pass); README 21 Nov 2026 | its output |
| Ming-3.0-tts-0.5b | audition candidate | MIT (repository) | github.com/inclusionAI/Ming-3.0-tts, 21 Nov 2026; weights card on the PC | its output, if chosen |
| VoxCPM2 | audition candidate | Apache-2.0 (card, via search) | card on the PC | its output, if chosen |
| Maya1 | **out** until config read | Apache-2.0 on card; Llama question open | config.json on the PC | no |
| Step-Audio-EditX (AWQ 4-bit) | rung 5, if it runs | code Apache-2.0; weights unstated | README 21 Nov 2026; card on the PC | edited output, if used |
| Dia2 2B | overlap timing only | Apache-2.0 | card, earlier pass | no |
| Seed-VC / RVC / OpenVoice V2 | route B | GPL-3.0 / MIT / MIT | GitHub LICENSE files, earlier pass | converted output |
| Whisper large-v3 | words gate | code MIT [from memory]; weights card tagged Apache-2.0 | search, 21 Nov 2026 | no |
| Parakeet TDT 0.6B v3 via onnx-asr | words gate | CC-BY-4.0 / MIT | card (earlier); pypi.org/project/onnx-asr, 21 Nov 2026 | no |
| WhisperX | word times, hunter bank | BSD-2 | LICENSE, earlier pass | no |
| wav2vec2-lv-60-espeak-cv-ft + espeak-ng | name check | Apache-2.0 / GPL-3.0 [from memory] | card via search, 21 Nov 2026 | no |
| SpeechBrain ECAPA | identity gate | Apache-2.0 | card via search, 21 Nov 2026 | no |
| emotion2vec+ large | 25 % of ranking | FunASR model licence (§2.1 use, §2.2 credit, §3 "reference and learning purposes only", §4.2, §6) | github.com/modelscope/FunASR MODEL_LICENSE, 21 Nov 2026 | no |
| UTMOSv2; Audiobox Aesthetics; DNSMOS | ranking / logs | MIT; CC-BY-4.0; CC-BY-4.0 | cards and LICENSE, earlier pass and review | no |
| W2V2-AASIST / XLSR-SLS | logged only | MIT on cards (via search) | earlier pass | no |
| pyworld | analysis only, never resynthesis | MIT [from memory] | to read on the PC | no |
| MetaHuman audio-driven animation | faces | Epic's terms for Unreal | Epic documentation | animation output |

---

## 16. The review, answered

| # | Finding | Answer | Where now |
|---|---|---|---|
| 1 | One character, two or three people | **Fixed.** Rule 5 (one route, one engine, change all at once); backup engine only in working builds, converted and tagged; same-person pages with 6 pairs plus 2 decoys, pass 6 of 6 and both decoys "different"; a mixed character only if it passes and he agrees | 6 rule 5; 9.2; 2 mix; 5.2; 5.9 rung 4 |
| 2 | The score picks the robotic take | **Fixed.** Recognisers are a gate only; anchors per kind; pitch gates skipped on whispers and set from each character's own anchors, starting talk gate 5.0; detector out of the ranking, logged only; weights 35/25/25/15; gates calibrated on his blind answers, and also must pass 9 in 10 real takes; old rounds only a sanity check | 4.3; 5.3; 5.5; 10.4 |
| 3 | The blind test is not blind | **Fixed,** with two honesty notes added: 12 pairs of the same line, real clips from people other than the listener, identical finishing plus a measured check that the finishing gives nothing away, all hard kinds, forced choice, pass 16 or fewer of 24; the pairing can lift chance to about 7 % (safe direction), and 24 clips miss a slight difference, so a second set of 24 is pooled (48, pass 30 or fewer) | 9 intro; 9.1 |
| 4 | First proof too big, decider last, no Owen | **Fixed.** Proof zero, two days, the 12 lines asked for, one engine per character, the 12 blind pairs; part 11 runs only for kinds machines passed | 10; 11 |
| 5 | Hardest lines sent to the weakest route | **Fixed.** Rule 1 exception for route B with the 15 % wobble and 1.5 dB buzz limits and the same-person check; whispers, screams, crying to route A only; Danny and Kayla cast first; "[temporary voice]" subtitles on REAL-ONLY lines | 6 rule 1; 2 route B and mix; 5.9 rung 6 |
| 6 | Qwen3 Base takes no emotion direction | **Confirmed and fixed.** Today's README: "Instruction Control" unticked for both Base models; clone examples pass no instruction. Seven references per voice (calm, joking, frightened, whisper, shout, crying, winded) chosen by the sheet's columns; instruct takes on VoiceDesign only, identity-checked; the instruction test runs once and is recorded | 2 route C; 4.3 |
| 7 | Kinds never routed | **Fixed.** Rows for impressions, humming, whistling, laugh-while-crying, cut-off screams and short lines; real only from the start, in each performer's session list; "Danny doing Kessler" anchor, loose check, his ear decides; voice sheets for the announcer, IT technician, laundromat boy, rescue crew and voicemails; the soldiers need none (symbol syllables) | 1; 3; 4.3 |
| 8 | Tools with open licence or Windows questions | **Fixed, one part kept.** (a) Maya1 out until config and tokenizer are read; it is a ~3.3B LlamaForCausalLM, which makes a Llama base likely; replacements Ming-3.0-tts (MIT, Oct 2026) and VoxCPM2 (Apache-2.0) or a second Qwen3 design. (b) FunASR's MODEL_LICENSE read today and quoted; kept as a PC-only checker, with the fallback to pitch if the lead reads §3 as excluding it. (c) Parakeet through onnx-asr (MIT, Windows, CUDA or DirectML). (d) **Kept:** the plan's "August 2026" is what Chatterbox's own GitHub README says today ("As of August 2026, Chatterbox is retired research and is no longer maintained"); no archive banner is shown, so the word "archived" became "retired, no longer maintained"; the mirror's January date is the mirror's | 2 route C; 5.3; 5.5; 14; 15 |
| 9 | Step-Audio-EditX will not fit as described | **Fixed.** AWQ 4-bit first, `.wslconfig` 12 GB and 16 GB swap, peak memory logged, rung 5 absent until it passes; also found today: its README states no licence for the weights, so that is read first too | 2 route C; 5.9 rung 5; 11 step 1 |
| 10 | Nothing checks the hunter is creepy; Monster 5 dropped | **Fixed.** The chain starts from Monster 5's exact process (read from tools2/monster2.py); the added steps are switchable; "creepy enough? yes / more / too much" on each clip, a Monster 5 against full-chain side-by-side; pass 5 of 6 named and at least 4 of 6 "yes" | 8; 9.3 |
| 11 | Names and short lines slip through | **Fixed.** Phoneme check with wav2vec2-lv-60-espeak-cv-ft (Apache-2.0, card via search) against espeak-ng's phonemes, no name hints to any recogniser; carrier method for lines under four words, cut at the silence, rhythm gates skipped, every short line in the chapter sample | 5.3; 5.4; 5.6; 9.5 |
| 12 | Overlaps will sound staged | **Fixed.** Interrupted lines made with their continuation and cut mid-word with a 5 to 10 ms fade where the other speaker starts; Dia2 for timing only | 7.3; 2 route C |
| 13 | Consent gaps | **Fixed.** Release uses 5 (breaths under another character), 6 (listening tests), 7 (upload to a named company), 8 (withdrawal rebuilds the hunter's bank and Mimics), each ticked separately with the parent's signature; the build refuses any file without a release number | 2 route A; 7.1; 9.1 |
| 14 | Paid-route facts out of date; store notice | **Fixed.** Both line counts, $80 per million, v4 launch date, the after-the-plan answer moved out of the unverified list; store notice line added | 2 route D; 12; 13 |
| 15 | He cannot read most of it | **Fixed.** "For you" box at the top; parts 5 to 7 marked for the builder; glossary at the end | top; 17 |
| — | Found in this pass | **Fixed.** The first version named Danny 1 / Kayla 1 / Marcus 1 as his choice; the later record (17 Nov, "Do voice 3 for all"; round 4) is Danny 3 / Kayla 3 / Marcus 2 and Monster 5 | 4.2 |

---

## 17. Glossary

- **Anchor:** the clip a voice's takes are compared with to check they are the same person; one per kind of line.
- **Aperiodicity ("buzz"):** how much of the voice is noise rather than tone; machine vocoders leave a tell-tale buzz.
- **AWQ 4-bit:** a smaller, compressed copy of a model that needs less video memory.
- **bf16:** a number format that halves a model's memory use.
- **Carrier:** a longer line a very short line is made inside, then cut out of.
- **Cents / semitones:** small and larger steps of pitch (100 cents make a semitone).
- **CV (spread):** how uneven a set of numbers is, here the gaps between words.
- **dBFS, dBTP, LUFS, LU:** loudness and peak measures; -23 LUFS is the normal talk level here, peaks stay under -1 dBTP.
- **ECAPA / speaker embedding:** a numeric fingerprint of a voice; two clips of one person score close.
- **Elo:** a ranking score from many people's side-by-side votes.
- **Fine-tune:** train a model a little more on one voice.
- **Forced alignment:** finding where each word starts and ends in a recording.
- **Gate:** a pass/fail check; a take that fails one is thrown out.
- **LPC whisper:** turning a voiced line into a whisper while keeping the mouth shapes of the speaker.
- **Phoneme:** a single speech sound; the name check listens for sounds, not spellings.
- **Recogniser:** a speech-to-text program, used to check the words.
- **Reference:** the clip a cloning engine copies the voice and delivery from.
- **Room tone:** the quiet sound of a room with nobody talking.
- **Seed:** the number that makes each take of the same line come out differently.
- **Spectral flux ("smear"):** how fast the sound changes; stretched or smeared speech changes too slowly.
- **Take:** one version of a line.
- **Vocoder:** the part that rebuilds a sound wave from a description of it; rebuilding causes buzz.
- **WER (word error):** the share of words the recogniser got wrong.
- **WSL2:** a Linux system that runs inside Windows.
- **WSOLA:** a time-stretching method; it made voices sound smeared.
- **Zero-shot:** copying a voice from a short clip without any training.
