# ROVLOC: the Higgsfield pack for opening v3

> **Status, 17 Nov. Higgsfield is connected, with only a few free credits.** A picture costs **0.12 credits**; one
> **5-second video clip costs 35**. So **the opening is built in the game engine** (opening-v3.md 10.9: the same
> shots, lines and sounds, with the new realistic people) **unless the player adds credits**; this pack is what runs if
> he does. Until then the free credits go on design pictures only. The monster's face is settled: B3, the player's
> favourite test picture (requirements, 17 Nov).

Story editor's final, 16 Nov 2026; second pass 17 Nov. Companion to opening-v3.md (shot ids, times, lines). Nothing
was generated and no credit was spent in writing this.

## 0. Read this first

### 0.1 What is known about the tool (facts from higgsfield-live.md and requirements.md, 16 Nov)

- **Two connectors.** One is read-only: workspaces (the selection persists across sessions: do not change it without
  asking), the balance, the model catalogue, finished generations. The other ("Higg") generates: `generate_image`,
  `generate_video`, uploads (`media_upload`, then a PUT, then `media_confirm`), presets (`get_presets`,
  `get_preset_instructions`; the `/3d-jutsu` preset's instructions come first for new views of one location),
  `get_workflow_instructions` (first, with no argument, before any multi-step video; with
  `{ workflow: "character-sheet" }` before a character sheet), `jobs_wait` (15 s at most per wait), a `max_credits`
  limit.
- **The account:** the free plan, a few credits (10 at the start; the lead's ledger, scratchpad `higg/ledger.md`,
  holds the live balance). Nothing is bought.
- **Prices read by preflight (16 Nov):** a cinematic 2k still **0.12**; one 5 s 720p video clip **35**; a spoken
  line 0.2 and a 3D model 9 (rigged 44), neither used here. **Still unknown: lip-sync (`sync_so`, `intone`) and
  upscaling (`topaz_video`)**; read their preflight quotes before the first use. Until then this pack counts a
  lip-sync pass or a final as one 5 s clip (35).
- **Plans:** the default picture model (`gpt_image_2_6`) needs the Basic plan; the cinematic one (`soul_cinematic`)
  works on free. `seedance_2_0`'s std mode needs Plus.
- **Start and end frames** are taken by `kling4_0` (3 to 30 s, plus ordered middle frames), `kling3_0` (3 to 15 s;
  sound off costs less), `wan2_7` (2 to 15 s), the Seedance models (`seedance_2_0`; `seedance_2_5` in omni_reference
  mode) and `veo3_1_lite` (4, 6 or 8 s). `veo3_1` takes a start frame only.
- **Lip-sync to our own audio exists:** `sync_so` (a clip plus our audio file) and `intone` (one or two stills of a
  readable face plus one to six voice files; output 4 to 30 s).
- `generate_audio` and `create_voice` are **not** used: our voices are rendered offline with an open speech model
  (requirements, 16 Nov), and no real person's voice is ever cloned.

### 0.2 Rules for every generation

1. **Content, kept honestly.** The video cast reads as **17 to 19**, in ordinary full-coverage school clothes.
   Prompts say "student in his late teens (about 18)"; never an age under 18, never "child", "kid", "boy" or "girl"
   as an age word. Every face is generated and fictional; no photo of a real person is ever uploaded as a reference.
   No picture shows harm being done to a young person: the change is porcelain, length and light. A refused picture
   is restaged with the fallback written beside it, never re-submitted in disguise. Keep a refusal log per model
   (prompt, picture, reason given).
2. **No readable text in any picture.** Cards, subtitles and all lettering on posters and signs are set by us.
3. **No sound from the tool.** Turn generated audio off wherever the model allows. The video file is silent.
4. **Stills first, video second.** Every clip starts from a still. Every still with Danny in it is made from his
   reference set. Every still of the lot is an edit of a set plate, and every set plate is an edit of a screenshot of
   the game's real Back Lot, so the video's lot is the lot the player then walks through.
5. **A state is in the start frame.** Lid open or shut, the thing there or not, its face upside down, the bike
   standing or fallen: never ask a clip to change a state behind an actor. One action per clip.
6. **Format.** 16:9. Clips of 5 s at 720p; for shots of 1.1 s or less (V07a, V07b, V07c, V10a, V10b, V18a, V18b) ask
   for the model's shortest length (3 s on Kling, 2 s on `wan2_7`) if its quote is cheaper. Only kept takes are
   upscaled or regenerated at 1080p. The website draws 12 % letterbox bars, so keep the action inside the middle three
   quarters of the height.
7. **Trace every keeper:** prompt, model, date, job id, saved with the file.
8. **Every clip has a Use line:** which part of the clip is used and at what speed. A retime is **at most 1.5 times**.
   Clips with an end frame are worded so the action is finished early and then held ("within the first second and a
   half ..., then nothing moves"), because the model spreads the action over the whole clip.

### 0.3 The look: three full sentences

Each sentence is a **look clause** with a **camera clause** inside it. Every prompt below has its sentence written out
in full: paste each prompt whole. A prompt that needs another camera (V06 at the rim, V11 and V15 in macro, the plates
at the screenshot's own camera) writes its own camera clause in the same place.

**DAY-EYE** (Act 1 and Act 2, people at eye height):

> Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high
> school, the light falling toward dusk, natural light only. Handheld at eye height, 35mm prime lens at f/2.8 on a
> full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour,
> cool shadows. No text, no logos, no watermark.

**DAY-LOW** (inserts on the ground before 38.6):

> Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high
> school, the light falling toward dusk, natural light only. Camera resting on the ground, 35mm prime lens at f/2.8 on
> a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour,
> cool shadows. No text, no logos, no watermark.

**DUSK** (from V14a on: the cloud has thickened and the yard lamp is on; it is still afternoon, never night). Camera
clause EYE "Handheld at eye height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus." or LOW
"Camera resting on the ground, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus.":

> Photoreal live-action film frame. A dark late-autumn afternoon behind a tired American public high school, a heavy
> dark overcast sky, one cold-white yard lamp on a tall pole as the key light. [camera clause] 35mm colour negative film
> look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.

The grade matches the game's own day value (0.5 from 39.6, story-continuity B `day`): dark grey, not night.

### 0.4 The people and things, as the prompts name them

- **DANNY:** a high-school student in his late teens (about 18), light build, warm light-brown skin, dark brown eyes,
  short dark hair under a deep red knit beanie pulled low over his ears, a plain mid-grey pullover hoodie with white
  drawstrings, dark blue-grey jeans, clean white low-top sneakers with white laces, a black backpack on both
  shoulders.
- **KAYLA:** a student in her late teens, always seen from behind: a mustard-yellow rain jacket, one long dark braid
  down the middle of her back, dark jeans, grey sneakers.
- **MARCUS:** a tall student in his late teens, always seen from behind: a navy-blue bomber jacket, large black
  headphones resting round his neck, close-cropped hair, grey trousers, a brown backpack, a wooden skateboard carried
  under his left arm.
- **THE LITTLE GUY:** a small original creature the size of a curled-up kitten: a round ball of pale cream down like a
  duckling's, and set into the front of it a tiny glossy ivory porcelain doll's face no wider than a jam-jar lid,
  smooth and uncracked, with two large dark oval eye holes, no pupils, and a tiny painted smile whose right corner
  curls up. No ears, no tail, no visible legs.
- **THE LOT:** an asphalt service lot behind a three-storey brown-brick school: grey steel double doors, two rows of
  six windows, a tall chain-link fence, a wide gate standing open to a street, one yard lamp on a tall steel pole
  with a bike rack and one bicycle beneath it, puddles, pallets; four waste containers: a large dark-green steel
  dumpster with a dented side (Dumpster A) with flattened cardboard boxes and a splintered wooden crate beside it, a
  rust-brown builder's skip with a steel lid, a black wheelie bin, a second green dumpster.
- **THE FACE** (the player's pick of 17 Nov, test picture B3; for the monster sheet only, and always with B3 attached
  as the reference: `higg/dl/M-B3/M-B3-v1.png`): a very long, very narrow pale face, pale as old porcelain, tapering
  to a point below; a wrinkled brow; huge black slanted eye holes, each with a tiny pinprick of light deep inside; two
  dark streaks running down under the eyes. The face is no wider than the thin neck. No hat.
- **THE HANDS:** big and old, veined, with very long fingers and pale knuckles.

### 0.5 The kinds of model the lists below ask for

| Kind | What it must do | Model (catalogue id) |
|---|---|---|
| IMG-REF | a still from a prompt plus reference images, keeping one face the same | `soul_cinematic` (works on the free plan; one image reference and a Soul Cinema character id) or `nano_banana_pro` (up to 14 references) |
| IMG-EDIT | change a given picture and keep everything else (plates from screenshots, end frames from start frames) | `nano_banana_2_1` (references and a mask) or `flux_kontext` |
| ANGLES | new camera views of one supplied location (the set plates from SM0) | `3d_jutsu_angles`, after reading the `/3d-jutsu` preset's instructions |
| VID-FACE | image-to-video from a start frame (and an end frame where given) that holds a realistic face; 5 s, 720p, sound off | `kling4_0` (Danny kept as a Kling element) or `kling3_0`; `wan2_7` second |
| VID-PLAIN | the same with no face in frame | `kling3_0` with sound off; `wan2_7` second |
| LIPSYNC | make a mouth speak **our** audio file | `sync_so` on the kept clip; `intone` from a still if a clip will not take it |
| FINAL | 1080p finals of the kept takes | `topaz_video` |
| RIG | not Higgsfield: the game's own Creature rig rendered offline at Max | — |
| EDIT | not Higgsfield: made in the edit | — |

---

## (a) CONCEPT SHEETS (after the pipeline test)

| Sheet | Ratio | Variants | Who picks |
|---|---|---|---|
| A1 Danny, the face | 4:5 | 8 | **the player picks one** |
| A2 Danny, the turnaround | 16:9 | 3 tries | the lead |
| A3 Danny, four expressions | 16:9 | 2 tries | the lead |
| A4 Kayla and Marcus, from behind | 3:4 | 4 each | the lead (the player may veto) |
| A5 The little guy, the look | 1:1 | 8 | **the player picks one** |
| A6 The little guy, its five states | 16:9 | 3 tries | the lead |
| A7 The change, five key pictures | 16:9 | 3 tries each | shown to the player as a storyboard; they are also the frames of V13 to V16 (counted there) |
| A8 The monster's whole body, around B3's face | 9:16 | 6, then 3 of the pick | **the player picks one** (the face is already his pick) |

**A1 · Danny, the face** (IMG-REF, no reference yet)
```
Photoreal portrait photograph, chest up, of a high-school student in his late teens (about 18): light build, warm
light-brown skin, dark brown eyes, short dark hair under a deep red knit beanie pulled low over his ears, a plain
mid-grey pullover hoodie with white drawstrings, black backpack straps on both shoulders. He is grinning with his
whole face at a friend just beside the camera, mid-laugh, warm and a little goofy. Outdoors behind a brown-brick
school, his face in soft even shade. A fictional person. Photoreal live-action film frame. Overcast Friday afternoon
in late autumn behind a tired American public high school, the light falling toward dusk, natural light only.
Handheld at eye height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative
film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.
```

**A2 · Danny, the turnaround** (IMG-REF from the picked A1; follow the connector's own character-sheet workflow)
```
Character reference sheet of the same person as the reference image, in the same clothes. Five views side by side on
a plain mid-grey background in soft even light: full body from the front, full body three-quarter, full body in
profile, full body from behind (the black backpack and the deep red knit beanie clearly visible), and one
head-and-shoulders close-up with a calm face. Mid-grey pullover hoodie with white drawstrings, dark blue-grey jeans,
clean white low-top sneakers with white laces. The same face, hair, build and clothes in every view. Photoreal.
No text, no labels, no logos.
```

**A3 · Danny, four expressions** (IMG-REF from A2)
```
The same person as the reference sheet, same clothes and red beanie, four head-and-shoulders photographs side by side
on a plain mid-grey background, soft even light: 1. a wide, delighted grin, eyes wide; 2. a deadpan impression of a
stern teacher: chin pulled in, eyelids heavy, mouth flat; 3. looking up and back over his right shoulder into the
camera, thrilled; 4. a puzzled half-smile, eyebrows raised. The same face in all four. Photoreal. No text, no labels.
```

**A4 · Kayla, from behind** (IMG-REF)
```
Full-body photograph from behind of a student in her late teens walking away from the camera across wet asphalt: a
mustard-yellow rain jacket, one long dark braid down the middle of her back, dark jeans, grey sneakers, a folded
sheet of white paper in her right hand. Her face is not visible. A second, smaller view of her from three-quarter
behind, face still turned away. Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a
tired American public high school, the light falling toward dusk, natural light only. Handheld at eye height, 35mm
prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft
highlights, muted colour, cool shadows. No text, no logos, no watermark.
```

**A4 · Marcus, from behind** (IMG-REF)
```
Full-body photograph from behind of a tall student in his late teens walking away from the camera across wet asphalt:
a navy-blue bomber jacket, large black headphones resting round his neck, close-cropped hair, grey trousers, a brown
backpack, a wooden skateboard carried under his left arm. His face is not visible. A second, smaller view of him from
three-quarter behind, face still turned away. Photoreal live-action film frame. Overcast Friday afternoon in late
autumn behind a tired American public high school, the light falling toward dusk, natural light only. Handheld at eye
height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine
grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.
```

**A5 · The little guy, the look** (IMG-REF, no reference). It has to be cute at first glance. If any variant is
creepy from the first second, it is the wrong variant.
```
Close photograph at ground level of a small original creature sitting on wet asphalt, the size of a curled-up kitten:
a round ball of pale cream down like a duckling's, and set into the front of it a tiny glossy ivory porcelain doll's
face no wider than a jam-jar lid, smooth and uncracked, with two large dark oval eye holes, no pupils, and a tiny
painted smile whose right corner curls up. No ears, no tail, no visible legs. Its face is tipped a little to one side,
like a puppy listening. It looks like a toy that is alive: soft, harmless, adorable. A white sneaker toe, out of
focus, at the edge of the frame for scale. Photoreal live-action film frame. Overcast Friday afternoon in late autumn
behind a tired American public high school, the light falling toward dusk, natural light only. Camera resting on the
ground, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine
grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.
```

**A6 · The little guy, its five states** (IMG-REF from the picked A5)
```
Reference sheet of the same small creature as the reference image, five views side by side on a plain mid-grey
background, soft even light: 1. sitting, from the front; 2. three-quarter view with its porcelain face tipped to one
side; 3. squashed flat at the start of a frog-hop; 4. the round body unchanged but the porcelain face rotated fully
upside down, so the painted smile reads as a frown; 5. opened: standing on the tips of eight long, pale, slender,
two-jointed finger-like legs that were folded under the down, twice as tall as when it sat, the down now only a fuzz
on the knuckles, the face still upside down. The same face and down in every view. Photoreal. No text, no labels.
```

**A7 · The change, five key pictures.** These are the frames listed under V13, V14a, V14b, V15 and V16 in section
(b): K0 = V13's start frame, K1 = V14a's end frame, K2 = V14b's start frame, K3 = V15's end frame, K4 = V16's end
frame. Make them in that order, before any clip of the change. **K1 is the moderation probe: one plain try, made in
the pipeline test (picture 4).** If it is refused, use V14a's fallback and log it.

**A8 · The monster's whole body** (IMG-REF; attach B3, `higg/dl/M-B3/M-B3-v1.png`, as the face and hand reference).
The face is settled: the player chose B3 on 17 Nov. The lead's round 2 of design pictures on B3 (requirements, 17 Nov,
cap 2.0) may already have made some of these: skip whatever it has made. Three ideas for the body, two variants each.
The beanie is not on him (it falls in the lot); in each idea the second variant keeps a few red wool threads snagged
in the torn hood as its only trace, for the player to take or leave. Common part of all six prompts:
```
Full-body photograph of an original horror figure: a human figure grown wrong. About four metres tall, more than
twice the height of a person, and as thin as its face is narrow; bony shoulders; arms so long that the fingertips hang
below the knees; big old veined hands with very long fingers and pale knuckles; a long neck leaning forward with the
chin tucked, so the face hangs ahead of the chest; knees slightly bent; long bare feet. It wears what is left of a
mid-grey pullover hoodie it has grown through: the stretched grey hoodie still covers the chest, the ribs show only
as ridges under the cloth; cuffs at mid-forearm, the shoulder seams split open, a torn hood hanging behind, one white
drawstring; dark jeans split along the seams, ending at mid-shin. No hat. Its face is exactly the face in the
reference image: very long and very narrow, pale as old porcelain, tapering to a point below; a wrinkled brow; huge
black slanted eye holes, each with a tiny pinprick of light deep inside; two dark streaks running down under the
eyes. The mask is narrow and long, no wider than the thin neck, in proportion to the thin body. It stands perfectly
still on wet asphalt under one cold-white yard lamp behind a brick school, the sky dark; a steel dumpster beside it
shows its height. No blood, no wounds, nothing wet: the horror is proportion and stillness. Photoreal, 35mm prime lens
at f/2.8 on a full-frame cinema camera, 35mm colour negative film look, fine grain, muted colour, cool shadows. No
text, no logos.
```
Add one of these sentences after "long bare feet.":
- **Idea 1, the shadow** (nearest to the game today): `Its skin is matte and near-black like soot, so the body is a dark shape; only the pale face and the big pale hands catch the light.`
- **Idea 2, the chalk:** `Its skin is dry and pale grey-white like unglazed porcelain, faintly mottled, the knuckles, the wrists and the long shins standing out in relief.`
- **Idea 3, the stretched one:** `Its skin is still a person's but drained and ashen, and the joints sit slightly wrong: elbows a little too low, an extra length in the neck. The most human and the most wrong.`

Judge the six on: the face matches B3; **the face is narrow and long, no wider than the neck, in proportion to the
thin body** (the player's note of 16 Nov: "the face is supposed to be slim like body"); scary before odd (no friendly
smile, darkness and backlight); skin over bone, never bare bones; nothing wet. Then three more of the picked idea:
from the front, from behind, and beside a plain grey 1.7 m silhouette for scale.
The pick goes to task 46 (the 3D body). It changes no gameplay number.

---

## (b) THE SHOT LIST

### Set plates (make these before any start frame)

Each is IMG-EDIT on a screenshot of the game's real Back Lot at Max, by day, taken at the camera given (world
coordinates; the ground is y 18). 16:9. Master: 6 tries. The others: 3 tries each. `3d_jutsu_angles` makes new views
of one supplied location: read the `/3d-jutsu` preset's instructions first, and if it holds the lot, SM1 to SM8 may
come from SM0 that way. The real lot: Dumpster A (10, 324), Dumpster B (22, 330), the skip (34, 328), the wheelie bin
(48, 326), the yard lamp (28, 320), the bike rack (23, 321.5), the gate on z 350; Danny's mark (21, 320.5), the
party's (16, 319.5), 5 studs (two steps) apart.

| Plate | Screenshot camera (eye → target) | Used by |
|---|---|---|
| SM0 master, from the staff doors | (58, 23.5, 294) → (20, 20, 330) | reference for all |
| SM1 the walk | (50, 23.5, 302) → (22, 21, 322) | V01a, V01b, V04 |
| SM2 the stop, Dumpster A behind | (27, 23.5, 312) → (12, 21, 323) | V02, V03 |
| SM3 Dumpster A's rim | (12.5, 23, 319.6) → (10.5, 22.6, 322.4) | V06 |
| SM4 asphalt level, from where it drops, toward Danny's mark | (12.5, 18.5, 321.5) → (21, 18.6, 320.5): the bike rack's legs and the lamp pole's foot behind the mark | V07a, b, c, V10a, b; V18a (at dusk) |
| SM5 the crouch, the lamp behind him | (16.5, 23, 320) → (21, 20.5, 320.5) | V08, V09, V12, V13; V14a, V14b, V20, U1 (at dusk) |
| SM6 low, up at the lamp | (17, 18.9, 319.6) → (21, 27.5, 320.5) | V16, V19 (at dusk) |
| SM7 down at our feet | (16.5, 23, 320) → (18, 18, 320.3) | V17, V18b (at dusk) |
| SM8 the gate, past the bike rack | (15, 23.5, 316) → (25, 21, 336): the rack left of centre, the open gate far right | V05 |
| SM4d, SM5d, SM6d, SM7d the same four after 38.6 | IMG-EDIT on SM4 to SM7 (below) | as marked "at dusk" above |

Plate prompt (IMG-EDIT on each screenshot):
```
Turn this game screenshot into a photoreal photograph of the same place from exactly the same camera position, with
every object where it is: an asphalt service lot behind a three-storey brown-brick school, grey steel double doors,
two rows of windows, a tall chain-link fence, a wide gate standing open, one unlit yard lamp on a tall steel pole
with a bike rack and one bicycle beneath it, a large dented dark-green steel dumpster with flattened cardboard boxes
and a splintered wooden crate beside it, a rust-brown builder's skip with a steel lid, a black wheelie bin, a second
green dumpster, puddles, cracked asphalt, pallets. Nobody in the picture. Photoreal live-action film frame. Overcast
Friday afternoon in late autumn behind a tired American public high school, the light falling toward dusk, natural
light only. Camera exactly where the screenshot's camera is, 35mm prime lens at f/2.8 on a full-frame cinema camera,
shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no
logos, no watermark.
```

Dusk plate prompt (IMG-EDIT on SM4, SM5, SM6 and SM7; 3 tries each):
```
The same picture later the same afternoon under a heavy dark overcast sky, the cold-white yard lamp on the tall pole
now lit and the main light, nothing else changed. No text, no logos, no watermark.
```

### The clips

Every start-frame prompt carries its look sentence in full (0.3); paste each prompt whole. "Refs" are the pictures
attached to keep things the same. Tries are video takes; each start or end still gets up to 3 tries. Every clip has
a **Use** line (rule 0.2.8).

**V01a · 0.5–2.8 · 2.3 s used of 5 s · VID-FACE · 6 tries**
- Start frame (IMG-EDIT on SM1; refs A2, A4): `Point of view walking out behind a school. Three students in their late teens a step ahead, all seen from behind, walking away from the camera across the asphalt lot. On the right, a student in a mustard-yellow rain jacket with one long dark braid holds a sheet of plain white paper up at arm's length, its blank side toward the camera. In the middle, a tall student in a navy-blue bomber jacket, large black headphones round his neck, a wooden skateboard under his left arm, reaches up for the paper. On the left, half hidden by him, a student in a mid-grey hoodie, a deep red knit beanie and a black backpack. Ahead: a large dark-green dumpster, a chain-link fence, an open gate, a tall unlit yard lamp. Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high school, the light falling toward dusk, natural light only. Handheld at eye height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- Motion: `Handheld camera walking forward at their pace. All three keep walking away. The one in yellow waves the paper overhead; the tall one in navy grabs for it and misses. Nobody turns toward the camera.`
- Use: 0.5 to 2.8 s of the clip, at normal speed.
- Camera: party view, walking. In frame: Kayla, Marcus, Danny, all from behind.
- Lines: L1 KAYLA, OFF. No lips.
- Fallback: two people instead of three (Danny out of frame left; his voice comes from there).

**V01b · 2.8–6.2 · 3.4 s used · VID-FACE · 6 tries**
- Start frame (IMG-EDIT on SM1; refs A2, A4): `The same three students walking, seen from half a step to the left and a little behind. The student in the mid-grey hoodie, deep red knit beanie and black backpack has turned his head to his right toward the tall student in the navy-blue bomber jacket beside him, but not far enough to show his face: the camera sees him three-quarter from behind, only the curve of his cheek and the red beanie against the grey sky, his mouth hidden. The tall student in navy is seen from three-quarter behind, his head thrown back. At the right edge of the frame, a mustard-yellow shoulder and a hand holding a sheet of white paper. Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high school, the light falling toward dusk, natural light only. Handheld at eye height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- Motion: `Handheld, walking with them. The one in the red beanie tips his head toward his friend as if saying a few words; his face stays turned away. The tall one throws his head back and shakes it. Nobody's face turns toward the camera.`
- Use: 0.5 to 3.9 s, at normal speed.
- Lines: L2 DANNY, OFF (his mouth is not in frame); L3 MARCUS, OFF.
- Fallback: a second, longer take of V01a at the model's 8 s length (it must cover 0.5 to 6.2, 5.7 s): about 56
  credits if the model prices by the second (10 s: about 70); read the quote first. Both lines play over it; the cut
  is lost.

**V02 · 6.2–8.9 · 2.7 s used · VID-FACE, then LIPSYNC · 6 tries + 3 passes · SYNC 2**
- Start frame (IMG-REF; refs A2, A3 view 2, SM2): `Chest-up of the student from the reference sheet standing still, turned three-quarter to the camera: mid-grey hoodie with white drawstrings, deep red knit beanie, black backpack straps. He is doing a deadpan impression of a stern teacher: chin pulled in, eyelids heavy, mouth flat. Behind him at frame right, about three metres away and in soft focus, a large dark-green dumpster whose lid is propped open about fifteen centimetres; in the dark gap sits a small pale round face-like shape with two dark dots, clearly visible though soft. Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high school, the light falling toward dusk, natural light only. Handheld at eye height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- Motion: `He holds perfectly still and speaks slowly with a flat face, only his mouth and eyebrows moving. A very slow push-in. Nothing in the background moves.`
- Use: 1.0 to 3.7 s, at normal speed; the lip-sync pass runs on that span.
- Lines: **L4 "Mister Reyes. Is something funny?"**, lips must match: `sync_so` with the rendered file (2.2 s).
- Fallback: `intone` from the start still with the same file; else the OFF version: a start frame from behind the
  yellow and navy shoulders with Danny four metres away, small, and the dumpster with the pale shape between them.

**V03 · 8.9–10.8 · 1.9 s used · VID-FACE · 4 tries**
- Start frame (IMG-EDIT on SM2; refs A2, A4): `From just behind two students whose backs fill the frame edges: mustard-yellow rain jacket and long dark braid on the right, navy-blue bomber jacket and black headphones on the left. Between and beyond them, three metres away, the student in the mid-grey hoodie and deep red beanie is caught mid-turn away from the camera, arms spread wide, his face in profile, grinning. Behind him the large dark-green dumpster with its lid fully shut. Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high school, the light falling toward dusk, natural light only. Handheld at eye height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- Motion: `He finishes spinning away from the camera and walks on with a bounce. The two in front shake with laughter and follow him. Handheld.`
- Use: 0.3 to 2.2 s, at normal speed.
- Lines: L5 DANNY, OFF (turning away).
- Fallback: a second, longer take of V04 at the model's 8 s length (it must cover 8.9 to 15.2, 6.3 s): about 56
  credits if priced by the second; read the quote first. L5 plays over its first 1.9 s.

**V04 · 10.8–15.2 · 4.4 s used · VID-FACE · 6 tries**
- Start frame (IMG-EDIT on SM1; refs A2, A4): `Three students walking away from the camera across the asphalt lot, seen from behind at two paces: mustard-yellow rain jacket and long dark braid on the left; mid-grey hoodie, deep red knit beanie and black backpack in the middle; navy-blue bomber jacket, black headphones and a skateboard under the arm on the right. The one in navy leans back toward the camera with his face turned away toward his friends. Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high school, the light falling toward dusk, natural light only. Handheld at eye height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- Motion: `Walking. The one in yellow nods sideways at the red beanie. The one in navy leans back as if sharing a secret, his face still turned away. The one in the middle's shoulders shake with a laugh and he tugs his beanie lower with one hand.`
- Use: 0.3 to 4.7 s, at normal speed.
- Lines: L6 KAYLA, L7 MARCUS, both OFF.
- Fallback: drop the hand on the beanie; if three backs fail, Kayla's line plays over a close view of the back of the red beanie.

**V05 · 15.2–18.9 · 3.7 s used · VID-FACE · 3 tries**
- Start frame (IMG-EDIT on SM8; refs A2, A4): `Wide view of the lot. Left of centre, two steps away, the student in the mid-grey hoodie, deep red beanie and black backpack stands three-quarter from behind at a steel bike rack beneath a tall unlit yard lamp, one hand on the seat of a bicycle, his head turned toward the far gate. Right of frame and much farther away, two students jog toward the open chain-link gate, seen from behind: a mustard-yellow rain jacket with a long braid, and a navy-blue bomber jacket with a skateboard under one arm. A large empty asphalt lot, puddles. Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high school, the light falling toward dusk, natural light only. Handheld at eye height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- Motion: `The camera slows to a stop. The two far figures jog away through the gate and grow smaller. The one at the bike rack lifts his free arm and calls after them, his face turned away from the camera.`
- Use: 0.8 to 4.5 s, at normal speed.
- Lines: L8 MARCUS, L9 KAYLA, L10 DANNY, all OFF.
- Fallback: Danny alone at the bike rack calling toward the gate, the other two already out of frame, their feet as
  sound (one more start still, 3 tries); else the start still with a slow push-in.

**V06 · 18.9–21.6 · 2.7 s used · VID-PLAIN, start and end frame · 4 tries · it crawls out of the bin**
- Start frame (IMG-EDIT on SM3; ref A6): `Close shot at the rim of a large dark-green steel dumpster, nobody in frame. The heavy lid is lifted about a hand's width from inside. Over the dented steel rim peek two small bumps of pale cream down and, between them, a tiny glossy ivory porcelain doll's face with two large dark oval eye holes and a tiny painted smile, looking out. Darkness inside the bin behind it. Sharp focus on the little face. Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high school, the light falling toward dusk, natural light only. Camera held still at the height of the dumpster's rim, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- End frame (IMG-EDIT on the start frame): `Same picture, same camera. Now the creature's whole round downy body is draped over the steel rim on its belly, its little porcelain face toward the camera, about to tip forward off the edge; the lid rests on its back.`
- Motion: `Static camera. Within the first three and a half seconds the small downy creature hauls itself up over the steel rim with a wiggle, belly on the edge, teeters, and tips forward out of the bottom of the frame; then the lid drops shut behind it and nothing moves.`
- Use: 0.0 to 3.6 s at 1.33 times speed (2.7 s on screen).
- Lines: none.
- Fallback: the motion prompt alone, without the end frame. If it will not climb: two cuts, the peek (1.2 s) and the
  draped body tipping off (1.5 s), each from its own still.

**V07a · 21.6–22.7 · 1.1 s used · VID-PLAIN · 3 tries · shortest length if cheaper**
- Start frame (IMG-EDIT on SM4; ref A6): `Camera resting on wet asphalt beside a dumpster. In focus, close to the lens, the small downy creature with the tiny porcelain doll's face sits on the ground, its face toward the camera. In the middle distance, small and out of focus, two clean white sneakers side by side. Behind them, soft, the legs of a bike rack and the foot of a lamp pole. Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high school, the light falling toward dusk, natural light only. Camera resting on the ground, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- Motion: `Within the first second and a half it shakes itself like a wet kitten, squashes flat, and makes one short crooked frog-hop away from the camera toward the sneakers, landing softly; then it sits still. One hop only.`
- Use: 0.0 to 1.4 s at 1.3 times speed (1.1 s).
- Lines: L11 DANNY, OFF.

**V07b · 22.7–23.8 · 1.1 s used · VID-PLAIN · 3 tries · shortest length if cheaper**
- Start frame (IMG-EDIT on V07a's start frame): `Same picture: the creature is now halfway to the white sneakers, seen from behind and a little to the side, smaller in the frame.`
- Motion: `Within the first second and a half it squashes flat and makes one bigger frog-hop toward the sneakers, the down flattening and springing back as it lands; then it sits still. One hop only.`
- Use: 0.0 to 1.4 s at 1.3 times speed.

**V07c · 23.8–24.9 · 1.1 s used · VID-PLAIN · 4 tries · shortest length if cheaper**
- Start frame (IMG-EDIT on V07a's start frame): `Same picture: the creature is now a hand's length from the toe of the nearer white sneaker, in focus; the sneakers are sharp now.`
- Motion: `Within the first second and a half: one clumsy hop, it overshoots, bumps into the toe of the white sneaker, rolls onto its back showing a clean pale belly, and rights itself; then it sits still.`
- Use: 0.0 to 1.6 s at 1.45 times speed.
- Fallback for V07a, b and c: if the hops turn to mush, animate the thing in the game's own renderer (the crawler rig
  with its down shell and `SleepFace`) over plate SM4.

**V08 · 24.9–26.6 · 1.7 s used · VID-FACE · 3 tries · he bends down**
- Start frame (IMG-EDIT on SM5; refs A2, A6): `From behind and to the side of the student in the mid-grey hoodie, deep red beanie and black backpack (three-quarter back view, his face not visible): he is lowering into a crouch beside a bike rack, forearms going to his knees. On the asphalt by his white sneaker the small downy creature looks up at him, its porcelain face tipped to one side like a puppy. A tall yard lamp pole beyond him. Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high school, the light falling toward dusk, natural light only. Handheld at eye height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- Motion: `Within the first two seconds he sinks the rest of the way into the crouch and leans toward it; it tips its face a little further to one side. The camera sinks with him. Then he stays crouched.`
- Use: 0.0 to 2.2 s at 1.3 times speed.
- Lines: L12 DANNY, OFF.
- Fallback: two stills cut on the action (standing over it; crouched), a slow sink on the second (2 more stills,
  3 tries each).

**V09 · 26.6–30.1 · 3.5 s used · VID-FACE, then LIPSYNC · 6 tries + 3 passes · SYNC 1 · THE MUST-HAVE SHOT, MADE FIRST**
- Start frame (IMG-REF; refs A2, A3 view 3, SM5): `Close shot. The student from the reference sheet is crouched with his body turned away, his head turned back and up over his right shoulder to look straight into the lens: eyes wide, a huge delighted grin, lips just parted as if about to speak. Mid-grey hoodie with white drawstrings, deep red knit beanie, black backpack. Soft even light on his face, a faint bright edge on the beanie and shoulder from behind. Low in the frame beyond him, out of focus, a small pale round shape on the asphalt. Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high school, the light falling toward dusk, natural light only. Handheld at eye height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- Motion: `He holds the camera's eye and talks to it, delighted, with small natural head movements only. He does not look away. The pale shape behind him does not move.`
- Use: 0.5 to 4.0 s, at normal speed; the lip-sync pass runs on that span.
- Lines: **L13 "Bro. Look at it. This is so cute."**, lips must match: `sync_so` with the rendered file (2.9 s).
- Fallback: `intone` from the start still with the same file; last, and only after telling the player: the line over
  V08's angle with his head turning to us at the end.

**V10a · 30.1–31.2 · 1.1 s used · VID-PLAIN, start and end frame · 4 tries · shortest length if cheaper**
- Start frame (IMG-EDIT on SM4; ref A6 view 2): `Camera resting on wet asphalt, nobody else in frame. The small downy creature sits facing the camera, its tiny porcelain doll's face tipped far over to one side. Sharp focus. Behind, soft, the legs of a bike rack. Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high school, the light falling toward dusk, natural light only. Camera resting on the ground, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- End frame (IMG-EDIT on the start frame; ref A6 view 4): `Same picture. The round downy body has not moved at all, but the porcelain face has rotated fully upside down: the chin at the top, the painted smile now reading as a frown, the two dark eye holes beneath it.`
- Motion: `The body stays perfectly still. Within the first second and a half the face turns smoothly upside down, like a dial; then nothing moves.`
- Use: 0.0 to 1.65 s at 1.5 times speed (1.1 s).

**V10b · 31.2–32.3 · 1.1 s used · VID-PLAIN, start and end frame · 4 tries · shortest length if cheaper**
- Start frame: V10a's end frame.
- End frame (IMG-EDIT; ref A6 view 5): `Same picture, the face still upside down. The round body has opened like a hand: eight long, pale, slender, two-jointed finger-like legs have unfolded from under the down and it stands on their tips, twice as tall. The down is now only a fuzz on the knuckles.`
- Motion: `Within the first second and a half the round body opens like a hand uncurling: long pale finger-like legs unfold and lift it until it stands on their tips; then nothing moves. The face does not move.`
- Use: 0.0 to 1.65 s at 1.5 times speed.
- Fallback for V10a and b: cut on the states: the tilted still (0.5 s), the upside-down still (0.6 s), the standing still (1.1 s, a slow push-in). Three stills carry it.
- If V10a and V10b still read as a snap on the storyboard: they get 1.5 s each by taking 0.4 s from V04 and 0.4 s
  from V05. V05 to V09 and L11 to L13 then move earlier (V05 by 0.4, V06 to V09 by 0.8); L8 to L10 stay where they
  are, so L10 ends over the first 0.8 s of V06. Re-run opening-v3 section 12 before taking it.

**V11 · 32.3–34.1 · 1.8 s used · VID-PLAIN · 3 tries**
- Start frame (IMG-REF; ref A6 view 5): `Macro shot of cloth only: the mid-grey cotton cuff and forearm of a hoodie sleeve and a black nylon backpack strap fill the frame. No skin, no face. At the bottom edge, four pale slender fingertips rest on the cuff, a tuft of pale cream down just behind them. Photoreal live-action film frame. Overcast Friday afternoon in late autumn behind a tired American public high school, the light falling toward dusk, natural light only. Macro lens, very shallow focus, the camera travelling slowly upward. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- Motion: `The pale fingertips walk quickly and softly up the sleeve and onto the strap, the tuft of down riding behind them. The camera travels up with them.`
- Use: 0.3 to 2.1 s, at normal speed.
- Lines: L14 DANNY, OFF.
- Fallback: two stills (fingertips at the cuff; fingertips on the strap) with a travelling push (one more still,
  3 tries); or the crawler rig's legs rendered over a generated macro plate of the cloth.

**V12 · 34.1–36.5 · 2.4 s used · VID-FACE, then LIPSYNC · 6 tries + 3 passes · SYNC 4**
- Start frame (IMG-EDIT on V09's start frame; ref A6 view 1): `Same picture. Now the small downy creature sits on his right shoulder like a kitten, round and soft, its tiny porcelain face the right way up beside his cheek and facing the camera too. He has glanced sideways at it and is grinning wider.`
- Motion: `He glances at it, then back to the camera, and speaks, pleased. The small creature stays where it is, perfectly calm.`
- Use: 0.5 to 2.9 s, at normal speed; the lip-sync pass runs on that span.
- Lines: **L15 "Hey. It likes me."**, lips must match (1.5 s).
- Fallback, and the plan if credits are short: the OFF version: from three-quarter behind his right shoulder, the back of the beanie, his ear, and the creature on the shoulder facing the camera; the line plays over it. 3 tries, no pass.

**V13 · 36.5–39.0 · 2.5 s used · VID-FACE, then LIPSYNC · 6 tries + 3 passes · SYNC 3 · K0**
- Start frame (IMG-EDIT on V12's start frame): `Same picture. The small downy creature on his shoulder now leans its porcelain cheek against his cheek, like a cat nuzzling. He is looking into the lens again, amused, eyebrows up. His face is ordinary and unmarked.`
- Motion: `It stays resting cheek to cheek. He huffs a small laugh and says three short words to the camera. Nothing else moves.`
- Use: 0.5 to 3.0 s, at normal speed; the lip-sync pass runs on that span.
- Lines: **L16 "Ha. It's cold."**, lips must match (1.1 s). The sky darkening and the lamp coming on at 38.6 are a grade in the edit.
- Fallback: the line over the last 1.3 s of V12's OFF version.

**V14a · 39.0–40.7 · 1.7 s used · VID-FACE, start and end frame · 6 tries · K1 is the end frame**
- Start frame (IMG-REF; refs A2 back view, SM5d): `Close, from three-quarter behind a student in a mid-grey hoodie and a deep red knit beanie: the camera sees the back of the beanie, his right ear, and the line of his cheek and jaw; his face is turned away and cannot be seen. His shoulder is empty. Along the very edge of his jaw runs a thin rim of smooth ivory porcelain glaze, like frost at the edge of a window pane. Photoreal live-action film frame. A dark late-autumn afternoon behind a tired American public high school, a heavy dark overcast sky, one cold-white yard lamp on a tall pole as the key light. Handheld at eye height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- End frame (IMG-EDIT on the start frame): `Same picture. The ivory glaze has spread like frost crossing glass: up over the cheek to the cheekbone and along the whole jaw line to below the ear. Smooth and dry, like a glazed cup. No cracks.`
- Motion: `Within the first two and a half seconds the ivory glaze creeps across the jaw and cheek the way frost spreads across a window; then nothing moves. He does not move.`
- Use: 0.0 to 2.5 s at 1.5 times speed (1.7 s).
- Lines: L17 DANNY, OFF.
- Fallback if the end frame is refused or ugly: his crouched shadow on the asphalt in front of him, the shadow of his head growing a smooth, too-long outline drawn down to a point (EDIT over SM7d), with the crackle. Log the refusal; do not rephrase and resubmit.

**V14b · 40.7–42.3 · 1.6 s used · VID-FACE · 4 tries · K2**
- Start frame (IMG-REF; refs A2 profile, SM5d): `Medium-close. The same student, crouched, his head turned so the camera sees him in profile as a dark shape against the bright yard lamp behind him: the beanie, the forehead, and then a profile that is too smooth and too long: no dip at the eye, one long even curve from the brow drawn down to a pointed chin. His right hand is raised halfway toward his face, fingers open, the hoodie cuff slid back along a forearm that is slightly too long. Photoreal live-action film frame. A dark late-autumn afternoon behind a tired American public high school, a heavy dark overcast sky, one cold-white yard lamp on a tall pole as the key light. Handheld at eye height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- Motion: `In the first second his hand rises toward his face and stops a few centimetres short, trembling slightly, and stays there. He does not touch it.`
- Use: 0.2 to 1.8 s, at normal speed.
- Fallback: the hand alone: a macro of the raised hand against the lamp, stopping.

**V15 · 42.3–44.1 · 1.8 s used · VID-PLAIN, start and end frame · 3 tries · K3 is the end frame**
- Start frame (IMG-REF): `Extreme close-up of one human eye, brown, wide, puzzled, not afraid, looking straight into the lens, ordinary skin around it, cold soft light. At the four edges of the frame the first smooth ivory porcelain is creeping in. Macro, very shallow focus, 35mm colour negative film look, fine grain. No text.`
- End frame (IMG-EDIT on the start frame): `Same eye, same framing. Smooth pale aged-ivory porcelain now fills the whole frame except a long, narrow, slanted opening round the eye, with a thick glazed edge; the eye, in shadow inside the hole, still looks at the lens.`
- Motion: `Within the first two seconds the porcelain closes in from every side until the eye sits in a long slanted hole; then the eye blinks once, slowly.`
- Use: 0.0 to 2.7 s at 1.5 times speed (1.8 s).
- In the edit, after the blink: the hole goes to black over 8 frames and one pale pinprick appears deep inside.
- Fallback: a dissolve between the two stills plus the same edit.

**V16 · 44.1–46.7 · 2.6 s used · VID-FACE or VID-PLAIN, start and end frame · 6 tries · K4 is the end frame**
- Start frame (IMG-EDIT on SM6d; ref A2): `Wide, low angle from the asphalt looking up. A crouched figure in pure silhouette against one bright cold-white yard lamp on a tall pole behind him: the outline of a knit beanie, a hoodie, a backpack. A bicycle lies on its side on the asphalt beside him, fallen out of the rack. Wet asphalt reflecting the lamp. No detail inside the silhouette. Photoreal live-action film frame. A dark late-autumn afternoon behind a tired American public high school, a heavy dark overcast sky, one cold-white yard lamp on a tall pole as the key light. Camera resting on the ground, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- End frame (IMG-EDIT on the start frame): `Same picture. The figure now stands upright and is too tall and too thin for a person, his head near the top of the frame, a long narrow head drawn down to a point, arms hanging straight down too far, big long-fingered hands, the hoodie's hem and cuffs riding high in the outline. His heels are lifted clear of two white sneakers that stay on the asphalt. The bicycle still lies on its side.`
- Motion: `Within the first three and a half seconds the silhouette rises smoothly as if lifted by the crown of its head, heels last, arms hanging, and keeps rising; then it holds still. The camera tilts up to follow.`
- Use: 0.0 to 3.9 s at 1.5 times speed (2.6 s).
- Lines: L18 DANNY, OFF.
- Fallback: the motion prompt alone, without the end frame; the height is then told by V17 and V18a. Or RIG: the engine's unfold, slowed, rendered as a black silhouette over SM6d (exact and free).

**V17 · 46.7–47.8 · EDIT over plate SM7d** (no video generation). A 2D shadow, its shape taken from the rig, slides
toward the lens and under it.

**V18a · 47.8–48.7 · 0.9 s used · VID-PLAIN · 3 tries · shortest length if cheaper**
- Start frame (IMG-EDIT on SM4d): `Camera resting on wet asphalt. Two clean white low-top sneakers stand side by side, the white laces still tied in bows, empty, lit from behind by a cold lamp. A long dark shadow lies across them and toward the camera. Photoreal live-action film frame. A dark late-autumn afternoon behind a tired American public high school, a heavy dark overcast sky, one cold-white yard lamp on a tall pole as the key light. Camera resting on the ground, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- Motion: `Nothing moves except the shadow lying across the sneakers, which slowly lengthens.`
- Use: any 0.9 s, at normal speed.
- Fallback: the still with a slow push-in.

**V18b · 48.7–49.6 · 0.9 s used · VID-PLAIN, start and end frame · 3 tries · shortest length if cheaper**
- Start frame: plate SM7d (empty wet asphalt at our feet, lit from ahead).
- End frame (IMG-EDIT): `Same picture. A deep red knit beanie lies crumpled on the asphalt in the centre.`
- Motion: `Within the first second a deep red knit beanie drops into frame from above, lands softly in the centre and settles; then nothing moves.`
- Use: 0.0 to 1.2 s at 1.33 times speed.
- Fallback: the end still, with a 4-frame drop made in the edit.

**V19 · 49.6–52.2 · RIG over a plate** (no video generation). Plate: SM6d with the bicycle on its side and nobody in
frame; if any ground is in frame, the two white sneakers and the black backpack lie on the asphalt at the crouch mark.
The rig: the game's Creature (with B3's face once task 46 lands), Scripted, standing at the crouch mark in profile,
head pitched down, the big veined hands hanging at the knees; at 0.4 s the Neck alone turns to the camera over 0.6 s;
the head cocks 20 degrees; the Jaw parts 3 degrees, so the point of the chin drops. Rendered at Max with alpha,
graded and grained to the plate. Lines: L19 THE TALL MAN; no mouth moves, no lip-sync. Use: the whole 2.6 s.

**V20 · 52.2–54.4 · RIG for 0.5 s, then VID-PLAIN · 3 tries**
- First 0.5 s: V19's set-up continues; he takes one step toward the camera.
- Start frame for the whip: plate SM5d, nobody in frame.
- Motion: `Within the first two and a half seconds a violent handheld whip-pan to the right across the fence and the lot with heavy motion blur, the camera dropping low at the end into darkness.`
- Use: 0.0 to 2.5 s at 1.5 times speed (1.7 s).
- In the edit: a dark steel edge wipes down over the lens; black from 54.4; 0.6 s of black to the end of the file.
- Lines: L20 THE TALL MAN, behind us.
- Fallback: blur plate SM5d sideways in the edit.

**U1 · an upgrade, only if the tool's rules accept it on one plain try** (replaces the first 1.0 s of V14b)
- Start frame (IMG-REF; refs A2, SM5d): `Three-quarter front close shot of the same student against the bright yard lamp. The far half of his face is smooth pale porcelain, drawn a little too long toward a point, with one huge black slanted eye hole; the near half is his own: calm, puzzled, unhurt. Half his smile is painted on. Photoreal live-action film frame. A dark late-autumn afternoon behind a tired American public high school, a heavy dark overcast sky, one cold-white yard lamp on a tall pole as the key light. Handheld at eye height, 35mm prime lens at f/2.8 on a full-frame cinema camera, shallow focus. 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No text, no logos, no watermark.`
- One try at the still. Refused: log it, drop it, tell the lead. Accepted: 3 video takes, motion `He holds still. Only the near eye moves, looking at the camera.` Use: 0.5 to 1.5 s, at normal speed.

**R1 to R4 · 54.4–65.0 · real-time 3D.** Nothing to generate.

### Counts

| | Number |
|---|---|
| Shots in the video | 26: 24 generated clips (V20 opens with half a second of the rig), V17 (edit), V19 (rig) |
| Shots in the whole cut | 30 with R1 to R4 |
| Video takes planned | 9 hard × 6 + 6 medium × 4 + 9 easy × 3 = **105** |
| Lip-sync passes planned | 4 lines × 3 = **12** |
| Readable Danny face | V02, V09, V12, V13 |
| Three people in frame | V01a, V01b, V03, V04 (all from behind); two far backs in V05 |

---

## (c) FLAT ART for the walls and the menus

Rules: the tool makes the picture, the paper, the paint and the dirt; **we set every letter** on top in our own
layout, so nothing is misspelt. One or two tries each. All are cosmetic (I3). Sizes are the generated size; each ships
at half that as a compressed texture. Flat art uses its own look, not the film look:

> A flat, evenly lit, straight-on scan of [the thing] on a plain neutral background, no perspective, no shadow, no
> hands, no text, no letters, no numbers, no logos.

| Id | What | Prompt (after the sentence above) | Size | Our lettering |
|---|---|---|---|---|
| F01 | campaign poster, Hallways | `a hand-made school election poster on yellow sugar paper: marker doodles of stars and a jar of coins round a wide empty band in the middle, tape at the corners, one corner curling` | 1024 × 1536 | KAYLA FOR TREASURER |
| F02 | the 1989 play poster, Auditorium | `a faded 1980s school theatre poster printed in two colours on cream paper: a heavy stage curtain and an empty pool of spotlight on bare boards, large empty areas above and below, foxing, a water ring, pin holes` | 1024 × 1536 | THE MASQUE · ROVLOC HIGH DRAMA CLUB · NOVEMBER 1989 |
| F03 | Sal's flyer, lockers and boards | `a cheap photocopied pizza-place flyer on white paper: a slice of pizza on a paper plate photographed from above, a red and white checked border, an empty band at the top and a row of tear-off tabs at the bottom, two tabs missing` | 1024 × 1366 | SAL'S · SLICES AFTER 3 |
| F04a | science fair poster | `a school science fair poster on blue card: cut-out paper planets and a baking-soda volcano drawn in marker round an empty middle` | 1024 × 1536 | SCIENCE FAIR · NOV 20 |
| F04b | band tryouts poster | `a photocopied school notice on green paper: a clip-art trumpet and drum kit drawn in black line round an empty middle, a staple in each corner` | 1024 × 1536 | BAND TRYOUTS · ROOM 12 |
| F05 | facilities notice, the staff doors | `a sheet of white office paper in a clear plastic sleeve taped to grey steel: a printed form with empty ruled lines and a tick-box grid, slightly rain-spotted` | 1024 × 1366 | PROP ROOM CLEAR-OUT — FRIDAY — FACILITIES |
| F06 | lockdown procedure sheet | `a laminated school safety sheet on white card with a thick red border: four empty panels with simple line pictograms of a door, a light switch, a window blind and a figure sitting low` | 1024 × 1366 | LOCKDOWN · four steps |
| F07 | the quizzes, Marcus's locker and the lot | `a sheet of lined school paper with twenty-five short ruled answer lines and small empty tick boxes, most crossed through in red pen, a red circle at the top right with nothing in it, creased from being folded twice` | 1024 × 1366 | two letterings: 16% — SEE ME. K. (last week's, Marcus's locker; 4 of 25) and 12% — SEE ME. K. (Friday's, wet, in a puddle in the lot; 3 of 25), red pen, by hand |
| F08 | bus times, by the gate | `a weathered printed timetable behind scratched plastic in a steel frame: a grid of empty rows and columns, sun-faded at one side` | 1024 × 1366 | LAST BUS 3:15 |
| F09 | yearbook page | `one page of a modern school yearbook: a grid of twelve small studio portraits on a mottled blue backdrop of twelve different students in their late teens, all fictional, smiling, an empty strip under each portrait, a clean white page` | 1536 × 2048 | names; Danny's square replaced by F11 |
| F10 | the 1989 photograph | `a faded 1980s colour snapshot with rounded white borders: a school drama club posing on a small stage in costume, faces small and soft, the figure at the centre blurred by movement, a curtain behind, heavy grain` | 1536 × 1152 | none |
| F11 | Danny's school portrait (IMG-REF from A2) | `studio school portrait, head and shoulders, of the person in the reference sheet, without the beanie in one version and with it in another, a mottled blue backdrop, an awkward real smile` (photograph, not a scan) | 1024 × 1280 | none |
| F12 | the MISSING sheet (title screen after "Sunrise" only) | `a sheet of white paper stapled to a wooden pole, rain-wrinkled, with a large empty square near the top and empty space below` | 1024 × 1366 | MISSING · DANNY REYES; F11 in the square |
| F13 | blank room plate | `a blank engraved plastic door sign, off-white with a brown edge, two screw heads, scuffed` | 1024 × 256 | MR. KESSLER; room names |
| F14 | wet-floor board face | `the face of a yellow plastic wet-floor A-frame sign with a black pictogram of a slipping figure, scuffed, an empty band at the top` | 1024 × 1536 | WET FLOOR |
| F15a | discard box side | `the side of a brown corrugated cardboard box with a strip of clear packing tape and a plain white sticker, dented at one corner` | 1024 × 1024 | DRAMA — PROP ROOM — DISCARD |
| F15b | crate plank | `three splintered pine planks of an old packing crate, rusty nail heads, straw caught in a crack, one plank broken` | 2048 × 1024 | MASQUE — DO NOT REMOVE — W.H. (stencil) |
| F16 | strobe sign plate | `a red enamelled steel sign plate with a white border, chipped at the bolts, blank` | 1024 × 512 | LOCKDOWN |
| F17 | fresh marker strokes (transparent background) | `twenty separate thick black permanent-marker strokes, dashes, arrows and dots on white tile, each with a slightly dry end` | 2048 × 2048 | our hand font is cut from these |
| F18 | faded spray strokes (transparent) | `twenty separate strokes and drips of old, sun-faded dark red spray paint on painted cinder block, flaking` | 2048 × 2048 | 1989 graffiti |
| F19 | white brush strokes (transparent) | `twenty separate strokes of thick white house paint put on with a wide brush on dark brick, with runs` | 2048 × 2048 | Walter's paint |
| F20 | ceiling stains (transparent) | `four different brown water stains with dark tide lines on white mineral-fibre ceiling tile` | 2048 × 2048 | — |
| F21 | wall damp (transparent) | `a bloom of damp and peeling cream paint on a plaster wall, grey mould freckles at its edge` | 2048 × 2048 | — |
| F22 | rust runs (transparent) | `long orange-brown rust streaks running down pale painted steel from a row of bolt heads` | 1024 × 2048 | — |
| F23 | scuffs (transparent) | `a long strip of black shoe scuffs, trolley knocks and mop marks along the bottom of a painted corridor wall` | 4096 × 1024 | — |
| F24 | dust handprints (transparent) | `handprints and finger drags wiped through thick grey dust on a dark steel surface, dry, no stains` | 2048 × 2048 | — |
| F25 | vent soot (transparent) | `a soft halo of black soot round a rectangular wall vent grille on pale paint` | 2048 × 2048 | — |
| F26 | his fingertips (transparent) | `four long, parallel, pale chalky drag lines along a dark painted wall, as if four dry fingertips were drawn slowly along it at head height, a little white dust beneath` | 2048 × 1024 | — |
| F27 | the lot's day sky (photograph) | `a seamless panoramic photograph of a flat overcast late-autumn afternoon sky, layered grey cloud, a brighter band low on one side, no ground, no sun disc` | 4096 × 2048 | — |
| F28 | the skyline (transparent) | `a long low hazy skyline of a small American city at dusk seen across rooftops: water towers, a few mid-rise blocks, aerials, no lit signs, soft with distance` | 4096 × 1024 | — |
| F29 | the night storm sky (photograph) | `a seamless panoramic photograph of a night sky full of heavy storm cloud lit faintly from below by a city with its lights out, no moon, no lightning` | 4096 × 2048 | — |
| F30 | beanie knit (tiling) | `a seamless close-up of deep red rib-knit wool` | 1024 × 1024 | — |
| F31 | hoodie fleece (tiling) | `a seamless close-up of mid-grey cotton sweatshirt fleece with faint pilling` | 1024 × 1024 | — |
| F32 | the little guy's down and face (from the picked A5) | `a seamless close-up of pale cream duckling down` and `a flat front view of the tiny glossy ivory porcelain doll's face from the reference, evenly lit` | 1024 × 1024 each | — |

**The title screen and the loading art** (film look; 16:9; 3840 × 2160 where the model allows, else upscaled). Each
prompt ends with: `Photoreal live-action film frame, night, rain, 35mm prime lens at f/2.8 on a full-frame cinema
camera, shallow focus, 35mm colour negative film look: fine grain, soft highlights, muted colour, cool shadows. No
people, no text, no logos, no watermark.`

| Id | What | Prompt | Tries |
|---|---|---|---|
| M1 | title screen | `The back lot of a brown-brick school at midnight in the rain. Four waste containers under one cold-white yard lamp; the steel staff doors shuttered, a red warning light throwing a red wash across wet asphalt. In the foreground, small in the frame, two white sneakers side by side with the laces tied, and a red knit beanie in a puddle. The left third of the picture is dark empty sky and wall.` (the logo goes in the left third) | 6 |
| M2 | loading: the bin | `Close on the rim of a dark-green steel dumpster at night in the rain, its lid lifted a hand's width, pure darkness inside.` | 3 |
| M3 | loading: the hallway | `A long school corridor of dented lockers at night, one ceiling light working far away, one locker door standing open, wet footprints of bare feet that are too long.` | 3 |
| M4 | loading: the vent | `A low wall vent in a school basement at night, its grille hanging by one screw, pale chalky dust on the floor in front of it, a torch beam just reaching it.` | 3 |
| M5 | loading: the tower | `A square brick bell tower with a lit clock face above a school roofline, seen from below against storm cloud, rain in the lamp light.` | 3 |
| M6 | loading: the bike | `A bicycle lying on its side beneath a yard lamp on wet asphalt at night, its front wheel still turning slowly, a black backpack beside it.` | 3 |
| M7 | Roblox icon, 1:1, 1024 × 1024 | `Two white sneakers side by side with tied laces on wet asphalt under a cold lamp, and behind them, out of focus and very tall, a thin dark shape with a long, narrow pale face tapering to a point, two black slanted eye holes.` (the final icon uses a render of the task-46 head, B3's face, for the face) | 4 |
| M8 | Roblox thumbnails, 16:9, two | M1's prompt from a lower angle; M3's prompt with a torch beam from the camera | 3 each |

---

## (d) THE CREDIT PLAN

Prices are the ones measured by preflight on 16 Nov (0.1): a still **0.12**, a 5 s 720p clip **35**. **Lip-sync and
upscaling are the only unknowns**; until their quotes are read, a pass or a final is counted here as one clip (35).
Longer fallback takes (8 or 10 s) are not in the plan; they are priced where they are written.

### Generations per item, with retries

| Group | Items | Generations | Credits |
|---|---|---|---|
| Concept sheets A1 to A6, A8 | 8 + 3 + 2 + 8 + 8 + 3 + 9 | 41 stills | 5 |
| Set plates SM0 to SM8 and the dusk plates SM4d to SM7d | 6 + 8 × 3 + 4 × 3 | 42 stills | 5 |
| Start frames (25) and end frames (7), 3 tries each; 2 OFF-version frames, 2 tries each | 75 + 21 + 4 | 100 stills | 12 |
| Video takes | 105 | 105 clips | 3,675 |
| Lip-sync passes | 12 | 12 | about 420 (unknown price) |
| Upscaling or 1080p finals of the 24 keepers | 24 | 24 | about 840 (unknown price) |
| **The opening** | | **324** | **about 4,960** |
| Flat art F01 to F32 (34 pictures), 2 tries each | 68 | 68 stills | 8 |
| Title, loading art, icon, thumbnails | 6 + 15 + 4 + 6 | 31 stills | 4 |
| **Everything in this pack** | | **423 generations: 105 video takes, 12 lip-sync passes, 24 finals, 282 stills** | **about 5,000** |

All 282 stills together cost about 34 credits; **the stills of the opening alone (183, with every retry) about 22**.
The video is what costs: at three takes for every clip (72 takes, 6 passes, no finals) the opening is about 2,750
credits instead of 5,000.

### The pipeline test: the first six generations

Its purpose is narrow, because the catalogue and the measured prices already answer the rest: **the lip-sync price
and quality, the upscale price, and whether moderation passes a generated late-teen face and K1** (the change on
his jaw). Test pictures are kept only if the player picks that face; otherwise they are test spend.

| # | Generation | What it tells us | Credits |
|---|---|---|---|
| 1 | one Danny face (A1's prompt, one picture, `soul_cinematic`) | does a generated late-teen face pass | 0.12 |
| 2 | Danny's turnaround sheet from it (A2, through the character-sheet workflow) | does the reference hold the face | 0.12 |
| 3 | V09's start frame from it (he looks up over his shoulder into the lens) | the first still of the must-have shot | 0.12 |
| 4 | K1, V14a's end frame, made straight from picture 2 (no plate yet), one plain try | does the change pass moderation on his jaw (rule 0.2.1) | 0.12 |
| — | **with no cap from the player, the test stops here** | | **about 0.5** |
| 5 | one 5 s clip of V09 from picture 3 (`kling4_0` or `kling3_0`, 720p, sound off) | V09's first take; does a realistic face pass image-to-video | 35 |
| 6 | L13's rendered audio on clip 5 with `sync_so` (or on picture 3 with `intone`) | the lip-sync price and quality; V09's first pass | the quote |

Before picture 1, free of charge: read the generating connector's tool list and parameter schemas; read the balance;
read the workflow instructions for a multi-step video and for a character sheet; read the `/3d-jutsu` preset's
instructions; find out how our files go in (the upload route: our audio, the screenshots, B3) and whether results can
be downloaded from the session; read the preflight quotes for `sync_so`, `intone` and `topaz_video`.

### Order of work, and where to stop

Running totals are at the measured prices, with each lip-sync pass and final counted at 35 until quoted.

| Step | Work | Running total | If we stop here |
|---|---|---|---|
| 0 | free checks; voices rendered and the sound board played to the player (our own pipeline, no credits) | 0 | nothing spent |
| 1 | **the credit cap from the player. No answer: stills only, inside the credits he already has; no video and no lip-sync; the pipeline test stops after its four stills** | 0 | — |
| 2 | the pipeline test (with a cap: all six) | about 71 (0.5 without a cap) | nothing lost |
| 3 | concept sheets; **the player picks Danny, the little guy and the monster's body** | about 75 | the picks exist for the 3D work (tasks 44 and 46) |
| 4 | set plates, and the 25 start stills (one try each) | about 83 | the engine staging (the base) has its storyboard and its plates; with every still retry this and step 3 cost about 22 |
| 5 | **V09 with its lip-sync** (5 more takes, 2 more passes: the test's take and pass are the first); show the player. If he calls it bad, restage before anything else | **about 330** | the engine opening plus the one shot that decides it |
| 6 | the little guy: V06, V07a, b, c, V08, V10a, V10b, V11 (28 takes) | about 1,310 | what he asked for by name is video up to the climb |
| 7 | the change: K-pictures (K1 already probed), V13, V12, V14a, V14b, V15, V16, V18a, V18b (37 takes, 6 passes); V17 and V19 at no credit cost | about 2,820 | every beat he asked for is video; the walk-out is the engine staging |
| 8 | the walk: V02 with its lip-sync, V03, V01a, V01b, V04, V05; V20 (34 takes, 3 passes) | about 4,115 | the whole opening at 720p |
| 9 | the cut, watched by the player with sound; fixes (keep a tenth of the cap for these) | — | — |
| 10 | upscale or re-run the 24 keepers at 1080p | about 4,955 | 720p ships if this is skipped |
| 11 | flat art and menus (stills; may run in any idle moment once the cap allows) | about 4,970 | the game keeps today's walls |

Never start a step the remaining credits cannot finish at three takes a clip. Three sensible sizes to offer him:
**small** (steps 2 to 5: about 330): the picks, the plates, and the must-have shot as video inside the engine opening;
**middle** (through step 7 at three takes a clip: about 2,000): everything he asked for by name is video, the walk-out
is the engine staging; **full** (this whole pack: about 5,000).

**With the free credits only** (a few credits, about 80 stills for every 10): pictures only, in the order of steps 2
(its four stills), 3 and 4, until they run out. No video and no lip-sync are planned until the player sets a cap and
adds credits; the opening is the engine staging.

---

## (e) WHAT TO ASK THE PLAYER BEFORE ANY CREDIT IS SPENT

The same three questions as player-summary.md (Q1, Q2, Q3), with the same defaults.

1. **Q1, the cap:** the most credits we may spend. **No answer: stills only, inside the credits he already has; no
   video and no lip-sync; the pipeline test stops after its four stills.** The opening is built in the game.
2. **Q2, his three picks**, as soon as step 3's pictures exist and before any video credit: **Danny** (one of 8),
   **the little guy** (one of 8), **the monster's body** around the face he chose (one of 6). If he does not pick
   within a day, the lead takes the one the fresh-eyes judges score highest and goes on.
3. **Q3, the beanie:** it falls in the lot and the monster wears no hat (the default), or it stays on him.

Tell him (no answer needed):
- **The voices first:** he hears the jokes and Danny's lines on the sound board (free) before any video credit, and
  says which stay.
- **The casting note:** in a video the three would read as about 18, because the tools' rules about young people leave
  no honest way round it; only Danny's face is seen close, Kayla and Marcus from behind. In the story Danny is still 16.

For the lead, not the player: which Higgsfield workspace the credits come from (do not change the selection without
asking him); read Higgsfield's terms for commercial use of outputs before anything ships, and for pictures made on
the free plan; confirm which of the two connectors a helper session gets; allow the asset host in the session's
network settings or nothing can be downloaded and committed.
