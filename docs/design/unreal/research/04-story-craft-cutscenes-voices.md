# Stay Behind: story craft, cutscenes, voices and songs

Research report 04, 21 November 2026. For the designer writing the game map. Built on requirements.md sections 7 and 8 and on voices/REPORT2.txt and REPORT3.txt. Tags: [checked: url] means a source found today backs the claim; [from memory] means it does not; [estimate] is my own arithmetic. The rule throughout: we take PATTERNS from the reference games, never their content.

---

## 1. Findings first

1. **The title gives the ending away.** "Stay Behind" names Danny's sacrifice before the game starts. Red Dead Redemption 2 shows how to live with that: it tells you early that the hero is dying, and the question becomes *what will he do with the time he has left*, not *will he die* [from memory]. We should do the same deliberately (see 4.1) and use the phrase in several meanings, so that its last meaning lands as a reveal and not as a spoiler.
2. **Red Dead 2's endings come from a fixed fate plus behaviour.** Arthur dies in every version. What changes is how he dies and who walks away, set by his honour level and one late choice, which gives four endings [checked: segmentnext.com/red-dead-redemption-2-endings]. That is exactly our agreed shape (Danny always stays behind; the last chapter, survivors and epilogue vary), so the pattern is proven.
3. **Silent Hill 2 scores behaviour, not menu choices.** Its main endings are steered by hidden points for things like how long you let your health stay low and which keepsakes you look at in the inventory, and how often. It never says it is counting [checked: powerpyx.com/silent-hill-2-remake-all-endings-guide; gamesradar.com/games/survival-horror/silent-hill-2-remake-endings]. Our "quiet choices" should count acts the player does for their own reasons (staying on the radio, sharing medicine), not only dialogue picks.
4. **The safe room is our camp.** Red Dead 2's camp works because it is a safe space, a workplace and a small society at once, and its upgrades follow the story rather than a power curve [checked: gamesbeat.com Red Dead deep dive; playstationlifestyle.net]. Our basement safe room should change every time Danny comes back, and it should get worse as the story does.
5. **MetaHuman is free for this game and can be sold commercially.** Since UE 5.6 it falls under the Unreal EULA: free under US$1M revenue, standard terms above that [checked: metahuman.com/license]. **There is no age slider and the bodies are built for adults** [checked: forums.unrealengine.com/t/createing-a-teen-metahuman; dev.epicgames.com body-params doc]. A 16-year-old Danny and Kayla need deliberate work. This is the biggest production risk to the agreed cast.
6. **UE 5.8 gives a one-camera motion-capture stage on his PC.** MetaHuman Animator Markerless Motion Capture is experimental and Windows-only. It captures the body, or body and face, from one ordinary video, using Meshcapade's technology [checked: digitalproduction.com/2026/06/23/metahuman-gets-markerless-mocap; dev.epicgames.com plugins overview]. Users report bugs [checked: forums.unrealengine.com/t/.../2729293]. Facial animation from audio alone, or from a phone or webcam video, is built in [checked: dev.epicgames.com audio-driven-animation; mono-video doc].
7. **Real recordings by the player and his friends would beat any model at the sad scenes**, but every minor needs a release signed by a parent or guardian [checked: legalzoom.com talent-release-for-minors]. That release must also cover the hunter's warped version of the voice.
8. **AI music is usable but legally thin.** Suno gives commercial use only for songs downloaded while on a paid plan, has capped downloads, and has rewritten its ownership wording [checked: suno.com/blog/suno-updates-tos; musicinafrica.net]. Udio closed downloads [checked: digitalmusicnews.com]. Eleven Music's self-serve plans exclude "Studio Games" and have an "Indie Game" revenue rule [checked secondhand: elevenlabs.io/eleven-music-model-specific-terms]. Wholly AI-made music has no copyright protection in the US, while human-written lyrics do [checked: wipo.int magazine; musicologize.com]. **So the player should write the lyrics, and a human should sing them if possible.**
9. **Steam requires disclosure of AI content that players see or hear**, which covers voices, music and Higgsfield pictures [checked: pcgamer.com; videogameschronicle.com].
10. **A UE 5.8 bug report says blending from a Sequencer camera back to gameplay is broken** [checked: forums.unrealengine.com/t/5-8-blending-back-to-gameplay-from-sequencer-does-not-work]. Test the cutscene-to-first-person handover in week one, and keep a fallback ready.

---

## 2. Part A: craft

### 2.1 What makes Red Dead 2's story work, and what fits 8 to 10 hours

**Chapters that each change the group's situation** [from memory]. Each chapter moves the group to a new place and a worse condition. The pattern: a chapter is defined by a change in the group, not by a level. For us, each school chapter ends with the safe room changed: someone gone, a rule broken, the power weaker, a secret out. The floors are the levels; the safe room is the story.

**The camp: living with people between missions.** The parts that work:
- small talk that changes by chapter;
- chores that are optional and unrewarded;
- arguments the player overhears rather than joins;
- songs around a fire;
- people visibly changing as things decay.

Our version: Danny returns to the basement after every floor. Each return has:
- **new idle talk** (2 to 4 short exchanges per survivor per chapter, overheard as you walk past);
- **one chore** (top up the generator, hand out food, fix a light, sit with someone who is hurt);
- **one argument** between two survivors, which you can walk away from;
- **one physical change** to the room: a cot left empty, a name written on the wall, the radio moved, the teacher's list of rations growing longer.

Chores give nothing but a line or a look. That is the point: Red Dead 2's camp rewards living, not a stat [checked: gamesbeat.com].

**A leader whose judgment decays.** The pattern: the person holding the group together is right at first, and the same quality (control, certainty) turns into the danger. Ours: **the teacher** in the safe room.
- Chapter 1: she organises rationing and watches, and she is good at it.
- Chapter 2: she starts deciding who "needs" medicine.
- Chapter 3: she hides a radio message (the rescue helicopter has fewer seats than people).
- Chapter 4: she locks someone out who might be a Mimic.
- Chapter 5: she chooses who goes up to the roof.

She is never a villain. She is a frightened adult protecting "her kids" by counting them. The player can find out the hidden message (a "shared" choice, see 2.2).

**A hero with a flaw and a past, who changes.** The flaw should be the opposite of the ending, so the ending reads as change and not as fate. Proposal: **Danny is the one who leaves.** He was leaving the evening event early when the mothership appeared, and that is his habit: he walks out when things get hard (a home situation, a team he quit, a friend he dropped). Every chapter tests it, because leaving is often the safe survival move. The arc ends with him choosing to stay behind. The title then names his change, not just his death. *Ask the player what Danny walked away from; do not invent it.*

**Mortality hanging over him.** The pattern: the hero learns mid-game that his body is failing, so every quiet moment becomes precious, and the player knows before he admits it [from memory]. Proposal: **the Mark**.
- In Chapter 2 or 3 the hunter touches or cuts Danny once and lets him go.
- The wound changes slowly: it is cold, and it shows in third-person scenes and in the first-person hand and arm view.
- This explains, inside the story, **why the hunter can find him on any floor, in the city and on the mothership** (agreed: it hunts all game).
- On the mothership Danny learns the Mark is a beacon: wherever he goes, they follow. So he cannot ride a pod home with Kayla.

Staying behind then has a reason the player understands, and it is still Danny's choice. It also feeds a quiet choice: painkillers can go to Danny or to a hurt survivor.

**An honour system that never lectures.** Red Dead 2 changes how the world and the music feel at low honour, and how people talk to you [checked: thegamer.com honor-changes-story]. There is no "good or evil" menu. Our version has no meter and no notices, only changes in what people say and do (2.2).

**The long quiet ride with a song.** The pattern: right after a big emotional turn, the game hands the player an uneventful stretch of travel they control, and lays a song with vocals over it. Grief needs time and hands on the controls. Placement for us is in 2.6.

**The epilogue as another character.** Why it lands [from memory]:
- the player keeps playing after the hero is gone, so the loss is felt as an absence in the controls;
- the familiar actions (walking, chores, talking) become a way to grieve;
- the person you now play carries the hero's change forward.

Ours: Kayla, later, in first person, using the same flashlight and radio with no creature left. The silence where the danger used to be is the last scare.

### 2.2 Turning behaviour into the ending (Silent Hill 2) and designing our quiet choices

What Silent Hill 2 does [checked: powerpyx; gamesradar]:
- it scores several hidden behaviours with weights;
- no single act decides the ending;
- it reads the player's care, such as how often they look at a keepsake and whether they heal or let themselves suffer;
- the remake adds extra endings only on New Game+.

**The design rules for Stay Behind:**
1. No meter, no notices, no "they will remember that."
2. Every tracked act must be something a player does for their own reasons (survival or feeling), so it never feels like a test.
3. At least one small, visible consequence lands within the same chapter (a line, a look, a returned favour), so the player senses that the world notices. The big consequences are saved for Chapter 8 and the epilogue.
4. No ending is a punishment. Each version is complete and sad in its own way.
5. Danny's fate is fixed.

**The ledger** (hidden variables; weights to tune in testing):

| Thread | What counts (examples) | Where it pays off |
|---|---|---|
| HELPED (per survivor, 0 to 3) | doing a survivor's optional request: batteries for Gus's hearing aid, finding Marcus's inhaler, walking the freshman to the toilet past the dark | whether they live to the roof, what they say to Danny at the helicopter, whether they are findable and able to help in the mothership's holding halls |
| SHARED, supplies | medicine, food and batteries handed in to the safe room versus kept in the backpack; painkillers used on the Mark versus given away | how the room looks in Chapter 5, the teacher's last decision, how many pods have a working occupant |
| SHARED, truth | telling the group about the helicopter seats, telling Kayla about the Mark, showing someone Danny's symbol notebook | who trusts Danny at the roof; in the epilogue Kayla can read the symbols only if he shared the notebook |
| LEFT | timed moments when someone calls for help while a creature closes in (always survivable for Danny either way); a seat given up on the helicopter | who the hunter speaks as later (2.5), who is in the halls, the names Kayla reads in the epilogue |
| STAYED ON THE LINE | how long the player keeps Kayla's radio calls on, in places where the radio's noise is a real risk (the Listeners' floor) | the length and warmth of Danny's last message, which Kayla plays in the epilogue |

**What varies, what is fixed.**
- Fixed: Danny dies on the mothership by his own hand; Kayla is taken at the crash and saved.
- Varies: which survivors appear in Chapter 8 (freed, helping, or lost); how many pods launch with people; the last minute with Kayla (in person, on the radio, or only a recording); and in the epilogue, where Kayla is, who is with her, what she carries and what she can read.

Optional Easter egg after the first completion: one extra epilogue scene unlocked on New Game+, as the Silent Hill 2 remake does [checked: powerpyx].

### 2.3 Telling story while the player stays in control (the horror references)

The patterns, from memory of all five games: the place tells you what happened before you arrived; recordings and notes give other people's last hours; the guiding voice on the radio may be failing, lying or missing; the hero's own notes show his state of mind; and the world bends towards the hero's guilt.

Our uses, with our own material:
- **The evening event, abandoned.** Decorations half down, a scoreboard or DJ booth still lit, coats on chairs, shoes in a line, a phone buzzing on the floor. The agreed rule is that what happened to the students stays off screen, so we show absence, never bodies.
- **Found phones as present-tense logs.** Lock screens fill up with texts from parents as the night goes on. A voicemail plays. This is our own twist on the audio log: the messages are still arriving.
- **Danny's notebook.** His glossary of the alien symbols fills in piece by piece (agreed: the self-destruct is the final exam). His handwriting gets worse as the Mark spreads.
- **Kayla on the radio as a failing ally.** She guides with blueprints from the safe room, but her batteries die, the signal drops, and in Chapter 4 the hunter speaks on the channel in her voice. Set up a code word early. If Danny SHARED it with someone who is later taken, the hunter can use it once: a payoff only an attentive player gets.
- **The school's PA system.** It belongs to whoever reaches it (the teacher, or later the hunter).
- **Keep logs short and physical**: under 40 seconds of audio, under 80 words of text. No exposition dumps.

### 2.4 Teenagers who sound real, a clown whose jokes are armour, and an earned sad ending

**Writing teenagers:**
- short lines;
- interruptions and half-finished sentences;
- mocking anything earnest;
- inside references to *their own* invented world (a teacher's catchphrase, a group chat name, Sal's, the place from the old opening);
- underplayed grief ("that's... yeah");
- no trend slang, which dates fast.

How strong the swearing is remains an open question for the player in the map; do not decide it. The best check is the 16-year-old player himself: a "would you actually say this?" pass on every scene. If his friends record lines, let them reword in their own speech.

**Marcus, the class clown (carried over from the old opening).** His jokes always point at someone else's fear, to take the spotlight off his own. The rules:
- the jokes get thinner and darker chapter by chapter;
- the first scene where he tries a joke and cannot finish it is a story beat;
- he is funniest just before the worst news;
- he must be genuinely funny once or twice, or the armour reads as a writer's device.

**Gus the janitor (carried over)** is a gift for the Listeners' floor: he wears a hearing aid, so he cannot tell how loud he is.

**Making the sadness earned, not cheap:**
- the loss must cost the player something they used: a voice they relied on, a helper whose jobs they did;
- the sacrifice is performed by the player, not watched. Danny holds the manual self-destruct by hand (agreed), so the player holds a button through the last minute while the pods launch, and letting go is not a way out;
- no fake-out survival afterwards.

**The pitfalls:**
1. **A sacrifice seen coming for hours.** Our title guarantees it, so embrace the Red Dead 2 move: let the player suspect early (the Mark) and make the open question *how*, *for whom*, and *what Danny says*. Also seed "stay behind" with other meanings: the teacher's order to the survivors, Kayla staying behind in the safe room, Danny refusing to stay behind at the roof.
2. **A companion who only gives quests.** At least half of Kayla's radio calls should not be about objectives. She asks him things, she is wrong once, she is scared for someone else. When she is taken, the radio's silence must be felt in play: no voice guiding you through the city.
3. **A villain with no reason.** The hunter and the aliens need a want, which the WHY options in 2.6 supply. The hunter's behaviour, collecting voices, should express that want.

### 2.5 The hunter's stolen voices

Agreed: it whispers in eerie versions of the voices of people it took. The rules:
1. **It only speaks as someone the player has heard alive.** You must have a voice to lose.
2. **It uses their real words in the wrong place.** It replays things that person said to Danny, now aimed at him, but never new lines. That is creepier, and it means the hunter's lines come from the cast's own recorded takes.
3. **It is told apart from the Mimics.** Mimics call aloud from ahead and ask for help. The hunter whispers close, from behind or from a vent, and never asks; it remembers. This keeps the game fair.
4. **It follows the LEFT ledger.** The person you left behind is the voice you hear most.

Schedule:
- Prologue and Chapter 1: strangers from the event (the announcer, a parent's voicemail).
- Chapters 2 and 3: the first survivor lost.
- Chapter 4: Kayla's voice once, on the radio (the code-word test).
- Chapter 6, the city: Kayla, taken.
- Chapter 8, the mothership: **Danny's own voice**, saying the Chapter 1 line where he promised to get everyone out. That is the hint that the Mark makes him theirs.
- Never in the epilogue.

### 2.6 A proposed structure

The playing times add up to about 9.5 hours [estimate].

| Part | Time | Content | Turns in the survivors' arcs | Songs and score |
|---|---|---|---|---|
| Prologue: the event | 0.4 h | Evening event (game or dance; the map leaves this open); Danny and Kayla leave early; the mothership; the small ship; the hunter crawls out; hide in the basement | meet the group in passing (Marcus, the teacher, Gus) | first, Kayla's motif heard diegetically: she hums it, or it plays from her phone |
| 1: The Basement | 1.0 h | Safe room founded, generator, the Dark Dwellers when the power fails | the teacher is at her best; Gus knows the tunnels | score only |
| 2: Floor 1, Listeners | 1.0 h | sound-hunting creatures; the radio's noise matters | the first optional requests; Gus's hearing aid | |
| 3: Floor 2, Still Ones | 1.0 h | the Mark; the first person lost | rationing begins; the teacher hides the seats message | |
| 4: Floor 3, Mimics | 1.0 h | known voices; the code word; the hunter speaks as Kayla | someone is locked out; Marcus's joke fails | **Song 1**: the walk back down through the quiet school to the safe room, guaranteed safe, under player control |
| 5: Floor 4, Swarm, and the roof | 1.0 h | the helicopter; who boards (ledger) | the teacher's last choice; goodbyes | the score's motif swells, cut to silence at the crash |
| 6: The City | 1.5 h | landing alone, the Patrol, the knock-out, the gun, the ship | Kayla taken: no radio, only the hunter | score only, sparse |
| 7: The Flight | 0.3 h | lift-off, then a short calm climb through cloud before the pursuit wakes | | **Song 2** over the calm climb, then the pursuit music takes over |
| 8: The Mothership | 2.0 h | decks, the holding halls (freed survivors per the ledger), low gravity, the Brute, a several-step self-destruct, the pods | Danny learns the Mark is a beacon; last minute with Kayla | **Song 3** begins as he holds the switch; the player holds it too |
| Epilogue: Kayla | 0.3 to 0.5 h | later; first person; chores and a visit back to the school's safe room (names on the wall, the group's traces); Danny's last message; a symbol she can read only if he shared the notebook | who is with her depends on the ledger | the motif as a solo instrument, then silence |

**Three answers to WHY THE ALIENS CAME** (the player chooses; each supports the agreed ending):
1. **The Harvest.** Humans are cargo, taken alive to supply the next leg of a very long journey. The self-destruct is manual because the ship's core answers only to touch, and someone has to keep holding it. Danny stays because of the Mark and the hold. Tone: cold and senseless; the sadness is that it meant nothing to them. Risk: the most familiar.
2. **The Voice Collectors.** A people who lost their own speech, which is why their language is written symbols only. They take the living so they can speak through them, and the hunter "wears" voices. The self-destruct is the final symbol exam, and the last command must be held by a living mind at the core. Tone: strange and tragic; it ties the voices, the symbol language and the ending into one idea. My recommendation.
3. **The Return.** They were here long ago and left something under the school, which is why the small ship lands there of all places and why the basement walls already carry symbols. The Mark makes Danny part of the signal that called the fleet. Staying behind is the only way to end the signal. Tone: the most personal and twist-shaped; it needs careful foreshadowing in Chapter 1.

---

## 3. Part B: making it without a studio

### 3.1 Realistic people: MetaHuman in UE 5.8

- **What it is now:** MetaHuman Creator runs inside the engine. Licensing follows the Unreal EULA from 5.6 on: free under US$1M revenue. MetaHumans may be used in any engine, and characters and clothing may be sold [checked: metahuman.com/license; cgchannel.com 2025/06].
- **New in 5.8** [checked: metahuman.com/news/metahuman-5-8-is-now-available; dev.epicgames.com 5.8 release notes]:
  - **MetaHuman Collections** (experimental) for crowds, which fits the mothership's holding halls full of the taken;
  - unbaked textures and materials for editing;
  - mono-video animation built in;
  - OpenRigLogic released under MIT.
- **Teenagers:** there is no age control and the bodies are designed around adult proportions [checked: forum thread; body-params doc]. The Body Params tool has a height slider and a *range multiplier* that widens the slider limits [checked: dev.epicgames.com body-params]. Paid teen and child body packs exist on Fab; check each licence. The plan:
  1. make a test Danny and Kayla first, before any other character work;
  2. shorter and slimmer bodies, softer jaw and brow, fuller cheeks, less facial hair and skin ageing;
  3. judge them under hard light in a cutscene camera;
  4. if they still read as 20-plus, fall back to a Fab teen body pack.
- **Varied looks for the adults** (teacher, janitor, rescue crew): fine with the stock tools [from memory].
- **Clothing and hair:** clothing fitting tools exist in-engine [from memory: details not checked]. Hair is the largest performance cost. Strands are the default at LOD 0 and cards at the others; forcing cards gives about 20 to 30 percent [checked: dev.epicgames.com controlling-metahuman-lods].
- **Performance plan:**
  - strands only in close-up cutscenes;
  - cards in play;
  - a cap on LOD for the full safe room (up to 8 MetaHumans at once, our heaviest people scene), and never forced LOD 0 on groups [checked: same doc];
  - measure on his GPU once the PC is connected.

### 3.2 Faces from audio alone, or from a phone or webcam

- **From audio:** MetaHuman Animator solves offline from a recorded line. It can add head movement, blinks and a mood setting, and 5.7 widened the mood choices. The real-time audio solver makes no head motion [checked: dev.epicgames.com audio-driven-animation; 5.7 release notes]. Expect good lip-sync and a generic upper face [from memory]. Use it for radio calls, background talk in the safe room, and the hunter.
- **From a mono camera (phone or webcam):** offline solve built into 5.8; tongue added in 5.7 [checked]. Lock exposure and focus, and use even, front-on light [checked: capture-device requirements].
- **Hardware recommended:** RTX 3070 or RX 6800 XT class, 8 GB VRAM, 32 GB RAM, a 16-core CPU [checked: dev.epicgames.com metahuman-hardware-requirements]. His PC is still unknown.
- **The plan:** for the roughly 30 to 40 key cutscene lines, film the performer's face on a phone while recording the voice, then solve from video. Everything else is audio-driven. If voices stay synthetic, a friend can act the face to the playback and the video can be solved [untested idea: verify the sync quality first].

### 3.3 Bodies without a mocap stage

| Source | What | Licence | Use for |
|---|---|---|---|
| Game Animation Sample (Epic) | 500+ animations, motion-matching locomotion | Unreal-only, commercial use allowed [checked: unrealengine.com blog game-animation-sample] | first-person body, survivors walking, idles |
| MetaHuman Markerless Mocap (5.8) | body, or body and face, from one camera | engine feature, experimental, Windows only [checked: digitalproduction.com; plugins doc] | two-person dialogue scenes, Danny's gestures, deaths' lead-ins |
| Mixamo | large free library | royalty-free in games; do not redistribute the raw files [checked secondhand: Adobe community FAQ threads] | filler actions; needs retargeting and clean-up |
| Move.ai / Rokoko / Plask | video-to-motion services | free tiers limited; check commercial terms per plan; Cascadeur's free tier is non-commercial [checked secondhand: filmthreat.com] | backup if the 5.8 plugin fails |
| Control Rig in Sequencer | hand-keyed poses | engine | hands on objects, held poses, corrections |
| Physics and procedural | ragdoll, look-at, breathing layers, foot IK | engine | Danny's death scenes, the taken floating in low gravity |

- **What a small team can stage well:** two people talking seated or standing; one person alone with an object; close-ups; people seen from behind or in silhouette; darkness, the flashlight and cutting on action.
- **What to avoid:** crowds moving, fights, hugs and touching, running groups, characters handing objects to each other.
  - The **prologue's full building** is a crowd, so cheat it with sound, light through door glass, idle Collections in wide shots, and cut-aways.
  - The **knock-out of the alien soldier** is a fight, so do it as a first-person struggle under player input, never as a third-person cutscene.

### 3.4 Sequencer and camera language

**Handover mechanics** [checked: dev.epicgames.com cinematic camera cut track; blend gameplay animation to cinematic]:
- enable *Can Blend* on the Camera Cut track and drag the section ease to blend out to the gameplay camera;
- give control back before the end by turning off cinematic mode and letting the sequence not affect movement and turning;
- end the camera at the first-person camera's position and rotation.

The 5.8 bug report means you should test this first. The fallback is a matched cut: the last cutscene frame is Danny's eye-line at the first-person field of view, then a hard cut to first person, with sound carrying over the cut.

**Camera language rules:**
- third person is for faces and feelings; first person is for fear;
- the hunter's best scares happen in first person, never in a cutscene where the player cannot act;
- open cutscenes by pulling back out of Danny's head;
- close them by pushing into his eye-line;
- use 35 to 85 mm lenses on faces, long takes, and room for silence;
- show Danny's face often, as Red Dead 2 does with its hero, because a first-person game otherwise never shows it; mirrors and dark windows help in play;
- Danny's graphic death scenes are short, cut away at the peak, and get the player back in quickly;
- every cutscene is skippable and has subtitles.

### 3.5 Voices: an honest comparison

The earlier game used Chatterbox (MIT) and Kokoro (Apache-2.0). The first round sounded "a little robotic" because of pitch and stretch processing. Round 2 dropped that, and the player said "Voices good" and chose Danny 3, Kayla 3, Marcus 2 and the whispering Monster 5 (requirements.md section 6; LICENCES3.txt).

| Option | Cost | Terms | Strength | Weakness for this story |
|---|---|---|---|---|
| Same open models | free | MIT / Apache: commercial use OK; disclose on Steam | already accepted; unlimited retakes; the pipeline exists | crying, breaking voices, shouted whispers and long emotional arcs over thousands of lines are where they fall short [from memory]; newer emotional open models are often non-commercial (IndexTTS-2), and Higgs Audio's licence varies by version [checked secondhand: findskill.ai; pinggy.io] |
| Commercial service (ElevenLabs) | Starter about $6 a month, Creator $22, Pro $99; the free tier has no commercial rights [checked secondhand: bigvu.tv; dev.to] | game use not spelled out in the sources found; read the ToS | wide emotional range | a script of 4,000 to 6,000 lines at 3 takes is about 1 to 1.5 million characters, roughly $300 to $1,000 over a few months [estimate]; how credits map to characters is unclear |
| Real recordings (player, friends, family) | about $60 to $150 for a USB microphone and pop filter, or a phone in a closet lined with blankets; free software | a signed release for each person, signed by a parent for any minor, covering: voice, any face capture, the hunter's altered version, worldwide use for the game's life, credit, and withdrawal before release [checked: legalzoom.com; Emerson minor talent release] | real breath, real breaks, real teen speech; the player may want to voice Danny himself | inconsistent rooms; scheduling; acting skill varies |

**How to direct amateurs** [from memory]:
- give the situation, not a line reading ("you've been awake two days, you're whispering so the thing in the hall can't hear");
- record pairs together where the scene has two people;
- let them reword lines;
- record each line three ways (normal, whispered, broken);
- have them physically crouch for the hiding lines;
- record breaths, efforts and screams separately;
- set the microphone 15 to 20 cm away, at 48 kHz and 24-bit.

**Recommendation:** real voices for the core cast if the player and his friends want it. Keep the open models for the minor characters and as the temporary track for all scenes now. Use a commercial service only if recordings are not possible. **No real person's voice is cloned without their consent.** The hunter's voices are made from each actor's own takes, which their release must name.

### 3.6 Original songs and score

| Route | Licence risk |
|---|---|
| Player writes the lyrics + a human sings + a self-made backing | **Lowest.** Fully ours; the lyrics are protectable [checked: musicologize.com; WIPO] |
| Human lyrics and vocal over an AI backing (Suno, paid plan) | **Medium.** Commercial use only for songs downloaded while subscribed; download caps; ownership wording revised [checked: suno.com/blog; musicinafrica.net]; the AI parts are not copyrightable |
| Fully AI song (Suno, or Eleven Music) | **Medium to high.** Eleven Music's self-serve plans exclude "Studio Games" (monetised and on more than one platform) and define Indie Games by revenue under $500,000; which plan covers indie games is unclear [checked secondhand: elevenlabs.io terms]. Anyone may copy an unprotected song |
| Udio | **Unusable.** Walled garden, downloads off [checked: digitalmusicnews.com; routenote.com] |
| Pixabay music | **Low to medium.** Free commercial use with no credit, but it may not go into Content ID, and claims on gameplay videos happen [checked: pixabay.com/service/faq; hellothematic.com]. Not unique to us |
| ccMixter / Free Music Archive | **Varies by track.** Credit is often required; non-commercial (NC) tracks are unusable [checked secondhand: 80.lv] |

**Score plan** [from memory; tool licences unverified]:
- a quiet palette: detuned piano, bowed metal, breath, low drones, and Kayla's motif on one human voice;
- record the real school's sounds (radiator pipes, lockers, PA hum) and stretch them into drones;
- free instruments: Surge XT, Vital's free tier, Spitfire LABS;
- a DAW: Reaper (cheap licence) or LMMS (free).

The two or three songs share the motif heard in the prologue.

---

## 4. Could not verify

- ElevenLabs' current terms for game voice lines, and which music plan covers indie games (elevenlabs.io was unreachable from this session; I saw only search excerpts).
- Whether Suno's licensed 2026 models have launched, and their exact download caps.
- Higgsfield's commercial terms for its audio and voices.
- MetaHuman clothing tools in 5.8, and the real frame cost of eight MetaHumans in one room.
- The quality of the 5.8 markerless capture on a consumer GPU (only early forum bug reports were found).
- Whether the 5.8 Sequencer blend-back bug was fixed in 5.8.1 or 5.8.2.
- The current licence wording of the Game Animation Sample after Epic's licence update.
- The specific in-game placement of Red Dead 2's songs (not needed: only the pattern is used).
- Whether "Stay Behind" is already a game title (outside this topic).

## 5. Sources

- https://www.metahuman.com/license
- https://www.cgchannel.com/2025/06/you-can-now-sell-metahumans-or-use-them-in-unity-or-godot/
- https://www.metahuman.com/news/metahuman-5-8-is-now-available
- https://dev.epicgames.com/documentation/metahuman/metahuman-5-8-release-notes-in-unreal-engine
- https://dev.epicgames.com/documentation/metahuman/metahuman-hardware-requirements-in-unreal-engine
- https://dev.epicgames.com/documentation/metahuman/capture-device-requirements
- https://dev.epicgames.com/documentation/metahuman/audio-driven-animation
- https://dev.epicgames.com/documentation/metahuman/metahuman-5-7-release-notes
- https://dev.epicgames.com/documentation/metahuman/metahuman-animation-from-mono-video-capture-in-unreal-engine
- https://digitalproduction.com/2026/06/23/metahuman-gets-markerless-mocap/
- https://dev.epicgames.com/documentation/metahuman/plugins-overview-in-unreal-engine
- https://forums.unrealengine.com/t/epic-games-metahuman-animator-markerless-motion-capture-plugin/2729293
- https://dev.epicgames.com/documentation/metahuman/metahuman-creator-body-params-tool-in-unreal-engine
- https://forums.unrealengine.com/t/createing-a-teen-metahuman/1265729
- https://dev.epicgames.com/documentation/metahuman/controlling-metahuman-levels-of-detail-lods-in-unreal-engine
- https://www.unrealengine.com/blog/game-animation-sample
- https://community.adobe.com/t5/mixamo-discussions/mixamo-faq-licensing-royalties-ownership-eula-and-tos/td-p/13234775
- https://filmthreat.com/features/best-ai-motion-capture-tools-for-independent-filmmakers/
- https://dev.epicgames.com/documentation/unreal-engine/cinematic-camera-cut-track-in-unreal-engine
- https://dev.epicgames.com/documentation/unreal-engine/blend-gameplay-animation-to-cinematic-animation-in-unreal-engine
- https://forums.unrealengine.com/t/5-8-blending-back-to-gameplay-from-sequencer-does-not-work/2741267
- https://bigvu.tv/blog/elevenlabs-pricing-2026-plans-credits-commercial-rights-api-costs/
- https://dev.to/techsifted/elevenlabs-pricing-2026-plans-credits-and-api-costs-explained-1549
- https://findskill.ai/blog/best-open-source-tts-2026/
- https://pinggy.io/blog/best_open_source_self_hosted_text_to_speech_models/
- https://www.legalzoom.com/templates/t/talent-release-for-minors
- https://emerson.edu/academics/schools-labs-and-centers/school-film-television-and-media-arts/student-production-safety/production-safety-resources/minor-talent-release-form
- https://suno.com/blog/suno-updates-tos
- https://www.musicinafrica.net/magazine/suno-adjusts-ai-music-ownership-terms-after-warner-music-partnership
- https://www.rollingstone.com/music/music-features/suno-warner-music-group-AI-music-settlement-lawsuit-1235472868/
- https://www.digitalmusicnews.com/2025/10/31/udio-umg-deal-downloads-resumed-48-hours/
- https://routenote.com/blog/?p=106458
- https://elevenlabs.io/eleven-music-model-specific-terms
- https://elevenlabs.io/music-terms
- https://www.wipo.int/en/web/wipo-magazine/articles/us-copyright-office-on-ai-human-creativity-still-matters-legally-73696
- https://www.musicologize.com/?p=49691
- https://pixabay.com/service/faq/
- https://hellothematic.com/thematic-vs-pixabay/
- https://80.lv/articles/80-level-digest-free-music-for-game-developers-3d-artists/
- https://www.pcgamer.com/software/ai/steam-updates-ai-disclosure-form-to-specify-that-its-focused-on-ai-generated-content-that-is-consumed-by-players-not-efficiency-tools-used-behind-the-scenes/
- https://www.videogameschronicle.com/news/valve-has-significantly-rewritten-steams-rules-for-how-developers-much-disclose-ai-use
- https://www.powerpyx.com/silent-hill-2-remake-all-endings-guide/
- https://gamesradar.com/games/survival-horror/silent-hill-2-remake-endings
- https://segmentnext.com/red-dead-redemption-2-endings/
- https://www.thegamer.com/red-dead-redemption-2-honor-changes-story/
- https://gamesbeat.com/red-dead-redemption-a-deep-dive-into-rockstars-game-design/3
- https://www.playstationlifestyle.net/?p=749139
- https://en.wikipedia.org/wiki/Music_of_Red_Dead_Redemption_2
