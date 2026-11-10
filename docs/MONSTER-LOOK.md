# The Tall Man: the monster's look, for both platforms

The rig is one Luau source for the website and Roblox:
`src/ReplicatedStorage/Shared/World/ProceduralWorldBuilder/CreatureRigBuilder.luau` (with its numbers in
`CreatureConfig.Rig / Hitbox / EyeHeightAboveRoot`, its contract in `tests/Specs/CreatureRig.spec.luau`). It is plain
Roblox: Parts, WedgeParts, WeldConstraints, Motor6Ds, Attachments, Attributes and one SurfaceGui of Frames and
UIGradients (the mask's grime); no MeshParts, SpecialMeshes, decals, textures or asset ids. The website gets it through
the Lune export and the bake (`web/DATA.md`, "Creature"); the website's animator is `web/src/creature/profile.js` (on
`animator.js`), its look `web/src/creature/look.js` and `mask.js` (the sculpted mask), `smoke.js`, `shards.js`,
`view.js` and `jumpscareView.js` (the catch's camera and screen; the catch's staging is `jumpscare.js`). This page is
what a Roblox animator and controller need to match the website exactly.

## Body

- **Size.** 11 studs to the crown standing, 9 hunched. HumanoidRootPart 2.6 x 2.6 x 1.4, its centre 4.7 over the
  floor (Humanoid.HipHeight 3.4). Eyes 10.34 over the floor standing (5.64 over the root), 8.3 hunched (3.6). Catch
  reach 4. Arms 6.3 from shoulder to the middle fingertip: the fingertips hang about 2.2 over the floor, below the
  knees (2.98).
- **Hitboxes** (CreatureHitbox, resized by `CreatureRigBuilder.setHitbox(model, poseMode)`): Biped 2.6 x 11 x 2.7,
  pushed 0.35 forward; Hunched 2.6 x 9 x 4.2, 1.3 forward (both standing on the floor); Quadruped 2.8 x 2.8 x 6; Swim
  3 x 3 x 10, 0.5 forward (centred on the root). `CreatureRigBuilder.Metrics` holds all of these; the export puts them
  in `meta.creature` (`height`, `hunchedHeight`, `eyeHeight(s)`, `eyeHeightAboveRoot`, `reach`, `hitboxes`).
- **Build.** Gaunt but not a stick: a ribcage about 0.9 wide with a breastbone, bony shoulders at +-0.63 (pale bone
  knobs), upper arms 0.3 thick; long fingers (FingerLength 1.3, knuckles a shade lighter so they read in the torch).
- **Materials.** Body SmoothPlastic, RGB 12, 12, 15, Reflectance 0.04: matte near-black with a faint sheen. Mask
  Marble, RGB 205, 194, 166 (ivory, not white), Reflectance 0.1: Roblox's faint marble veining reads as aged porcelain.
  Pupils Neon RGB 255, 244, 214, the right one 1.45 x the left. The mask's drawn detail is Fabric (below). On the
  website, whatever lights the body it stays a dark shape (its lit colour saturates at 0.035 linear before the rim).
- **Tatters.** Seven clumps (`Hair<N>_1`, `Hair<N>_2`) of narrow strips (0.16-0.1 wide, tapering 0.6 per segment),
  each twisted about its length so none turns a flat face to the light (hanks of hair, not planks), with a stray strand
  peeling off every segment.

## Joints (Motor6D names; each Motor6D is named after its Part1 and lives in it)

Walk `CreatureRigBuilder.Joints` in order (parent before child). Every joint frame (Part0.CFrame * C0) is axis-aligned
with the rig at rest, so on every joint a Transform rotation about X pitches, about Y yaws and about Z rolls, relative
to the Creature's own facing (-Z forward, +X its right).

| Joint | Part0 -> Part1 | Pivot |
| --- | --- | --- |
| `Root` | HumanoidRootPart -> LowerTorso | the pelvis centre (0, 5.84, 0.14) |
| `Waist` | LowerTorso -> UpperTorso | (0, 6.2, 0.16); the chest leans 12 degrees forward at rest |
| `Neck` | UpperTorso -> Head | **the top of the long neck** (the skull base): the skull turns on it. The neck column and its tendons ride the UpperTorso. |
| `Jaw` | Head -> Jaw | the mask's hinge, behind the mouth slit inside the skull (face frame 0, SlitY + 0.02, MaskAxisZ + 0.3) |
| `Left/RightShoulder`, `Elbow`, `Wrist` | UpperTorso -> UpperArm -> LowerArm -> Hand | shoulders at +-0.63, 2.26 up the chest |
| `Left/RightHip`, `Knee`, `Ankle` | LowerTorso -> UpperLeg -> LowerLeg -> Foot | hips +-0.26 at 5.62; knees bent slightly forward |
| `Left/Right` + `Index`, `Middle`, `Ring`, `Pinky`, `Thumb` | Hand -> finger | each finger's knuckle; the finger's middle and distal segments and its point are welded to it |
| `Hair<N>_1`, `Hair<N>_2` (N 1..7) | Head -> Hair<N>_1 -> Hair<N>_2 | the tatters' roots on the skull, then their middle |

`PartNames.Fingers[side]`, `PartNames.Hair`, `PartNames.SmokeAnchors` list them. The rest pose: chest pitched forward
12 degrees, the neck leaning 22 degrees further, the head pitched 8 degrees down (chin tucked), so the face hangs about
1.6 studs ahead of the root; arms hanging; knees slightly bent.

**Finger curl** (profile.js `fingers`): per finger, curl = a rotation about `along x inward` (along = the finger's rest
direction from its knuckle, inward = toward the body's midline, -X on the right hand, +X on the left); spread = a
rotation about `along x curlAxis`. Rest curl 8 degrees; trailing opens them back to -12 as the arm swings forward.

## States (profile.js; the AI state picks one, PoseMode first)

- **Patrol / Stalk**: long, slow, bent-kneed strides (stance up to about 5 studs at 7 studs/s), the swinging foot
  hovers before it plants; the head rolls slowly 17 degrees over to one side and back (6.5 s period) on a saccade
  gaze; arms hang to below the knees, fingers trailing.
- **Hunched** (PoseMode Hunched, any upright state): the pelvis drops 0.55, the chest pitches 20 degrees more, the head
  hangs 12 degrees lower: crown about 9.2 standing, 8.3 walking.
- **Chase**: the lope: a flight phase (duty 0.40 to 0.32), lean 14 to 26 degrees, arms swinging 34 degrees low and
  long, fingers splayed; the head level on its target.
- **Investigate / Search**: lower, neck craned, sniffing pecks, one hand feeling the air.
- **Stunned**: both hands raking at the mask, staggering on buckling knees. **Swim**: an eel's wave, the neck 3.6
  ahead of the root. **Scripted**: neutral, staring. **Dormant**: hunched deep, the head hanging.
- Footsteps at the plants: heavy and slow (playback 0.52, sprint 0.6, volume x 1.9).

## Actions and timings (seconds)

| Action | Length | What happens |
| --- | --- | --- |
| `Stare` (held) | until released; in 0.22, out 0.4 | frozen, chest leaning 5 degrees in; the head cocks over 31 x (1 - e^(-1.4 t)) degrees plus a 9 degree jolt at the start; fingers flex slowly |
| `LookAway` (held) | until released; in 0.45, out 0.32 | the head turns 112 degrees down the tunnel (the waist helps 28), a slow 6 degree drift; it snaps back on release |
| `ReachIn` (held) | until released; out 0.6 | lean in 0-0.7; the right arm slides into the gap toward the target 0.45-1.7 with the fingers splayed; they curl shut 1.6-2.2; a small search wiggle; the head tips toward the gap |
| `FadeOut` | 0.6 (+0.1) | it rises as it goes: chest lifts, head tips back, arms drift up and out, fingers splay, a little glitch; dissolve 1 -> 0 over 0.6; a smoke burst at the start; the CreatureVanish sound |
| `FadeIn` | 0.8 (+0.1) | it forms folded (knees bent 0.22 leg, chest down 40 degrees, head hanging), unfolds; the head snaps onto its target at 82-92 % of the time; dissolve 0 -> 1 over 0.8; a smaller burst at the start |
| `Lunge` = `Jumpscare` | 0.45 strike + 1.4 hold + 0.5 release | a 0.05 flinch, then in 0.2 s it **bows** to the victim: the knees fold, the chest bends far forward (up to about 95 degrees) and the long neck reaches down, the body stepping back off its root as needed (up to 2.6), until the mask, aimed into the victim's eye, hangs **level with it about 1.3 studs off** (profile.js `loomSolve`: distance 1.6 solved, elevation 2 degrees), cocked over 24 degrees, settling to 13; a jolt at 0.36 (the tear); a shudder 0.85-1.25; the elbows rise over the head like a mantis and the hands come down beside the mask, fingers spread and curling; the Jaw parts only 1.2 degrees (the tear is the mask's, below) |
| `NeckSnap` | 0.12 turn, 0.45 settle, 2.4 hold, 1.3 release | the head (and waist 75 degrees) whips round 180, shudders, holds, comes back in three steps |
| `LockerRip` / `DoorSmash` | 1.35 / 0.95 | as before, on the longer arms |
| `Vanish` | 0.41 | a glitch while it dissolves to nothing |
| `Reveal` | 0.75 | it forms out of static over the first 0.22 while the glitch settles, then cocks its head at 0.34 |

**The mask hinge.** `Jaw` Transform `CFrame.Angles(-a, 0, 0)` drops the chin by `a`. It only ever parts a few degrees:
1.2 in the Lunge, 2-5 in the stun flail, 1.5-7.5 in the locker rip and the door smash, 3 in the neck snap, 2.5-9.5 in
the duct crawl. The hinge drives the tear: past about 2.5 degrees the slit starts to tear into the maw (60 % at 6
degrees) outside the jumpscare; the jumpscare's own maw runs on its timeline (below). When it parts, the gap shows black:
on the website the sculpt's inside is unlit black; on Roblox the Fabric cap `MouthVoidUpper` (under the upper mask), the
black sleeve `MouthVoidLower` and the black `Throat` do it. **No porcelain shows inside the split**: the Jaw ball's cap
above the seam hides inside the upper mask while shut and inside the sleeve (radius 0.32, on the Jaw, reaching over the
cap's top) when it opens; that was the white crescent of chin Roblox showed before.

## The mask

One shape, defined once in the rig and drawn by each platform as well as it can. The Mask part carries the numbers
(face frame: the FaceFrontAttachment, x right, y up, z back, origin between the pupils, studs):

- `MaskAttributes`: `EyeX` 0.15, `EyeHoleWidth` 0.106, `EyeHoleHeight` 0.062 (half sizes of a drooping almond),
  `EyeHoleDepth` 0.3, `PupilGlowRadius` 0.009 (the right pinprick x `PupilScaleRight` 1.45), `SlitY` -0.34,
  `SlitHalfWidth` 0.15, `SlitUpturn` 0.036 (the right corner curls up: a wrong half-smile), `MaskTop` 0.53, `ChinY`
  -0.79, `MaskDepth` 0.24 (how far the rim recedes), `ChipAngle`, and Roblox's shell sizes `MaskRadius`, `MaskAxisZ`,
  `ChinRadius`.
- `MaskShape`: `MaskOutline` "y:left:right;..." (the front outline's half-widths, top down: an elongated oval a little
  too long, a touch lopsided, tapering from the cheekbones to a pointed chin), `MaskProfile` "y:z;..." (the
  centreline's depth), `MaskRelief` "Name:x:y:rx:ry:height:tilt;..." (19 anisotropic bumps, studs toward the viewer,
  negative hollowed: a heavy brow ridge, deep sockets (-0.085 / -0.09), a thin nose ridge and tip, cheekbones over sunken
  cheeks, faint lips, the philtrum, a pointed chin, hollow temples), `ChipCentre` / `ChipRadius` (with `ChipAngle`:
  the piece broken off the right temple's rim).
- The detail parts' attributes: `MaskCrack<N>` (`CrackFrom` / `CrackTo` / `CrackWidth`: the major crack 0.008 wide
  from the brow through the left socket down to the jaw; hairlines 0.0035-0.0045 branching off it, across the right
  temple and the forehead, down from the slit's upturned corner, across the chin), `MaskStreak<N>` (`StreakFrom` /
  `StreakTo` / `StreakWidth`: the weeping, two dark streaks down from each eye hole).

**Roblox** (all built by the rig, nothing for a controller to add):

- **Shell:** `Mask` (a vertical cylinder from the slit up to the brow, radius 0.345, the eye-hole centres on its
  surface) capped by `MaskBrow` (a ball); the `Jaw` ball (radius 0.3) under the slit with the pointed `Chin` ball under
  it. Roblox builds no MeshParts from code, so the outline is these primitives' envelope.
- **Relief:** detailed Parts sunk into the shell, all porcelain: `ReliefBrowLeft/Right`, `ReliefNose`,
  `ReliefLipUpper/Lower` (cylinder ridges along their tilt, their middles standing the bump's height proud),
  `ReliefGlabella`, `ReliefNoseTip`, `ReliefCheekLeft/Right`, `ReliefChin` (balls whose caps stand the height proud with
  the bump's footprint). The hollows (sockets, sunken cheeks, temples) cannot be carved from Parts: the grime darkens
  them.
- **Grime:** a SurfaceGui decal: `MaskGrimeLeft/Right`, invisible cards tangent to the face over each eye, each with a
  SurfaceGui of Frames (UICorner ovals, UIGradient fades: soot pooled in the socket, a weeping run under it, yellowed
  grime toward the edge) at 400 pixels per stud, so the canvas (about 104 x 176) stays far inside Roblox's 1024-pixel
  texture cap, LightInfluence 1 (it sits in the scene's light).
- **Drawn detail** (Fabric, near-black): `Left/RightEyeHole` + `EyeHoleCorner` (the almond), the Neon pinpricks just in
  front, `MouthSlit1..4` (the slit, the last two curling up into the half-smile), the cracks and streaks as strips on
  the shell carrying their face-frame ends (segments split at the seam ride the half they lie on), `MaskChip1/2`
  (black over the rim where the piece broke away: the void behind), `MouthVoidUpper` / `MouthVoidLower` / `Throat`.
- **The maw** (Roblox's tear): `MawShard1..5`, jagged porcelain WedgeParts (attribute `MawSide` Upper / Lower) hanging
  from the upper mask's edge into the jaw ball and rising from the jaw into the upper mask: hidden inside the shell
  while it is shut, bared as jagged teeth round the black when the hinge parts, so the hinge drives it.

**Website** (look.js, mask.js): it hides the Roblox shell, relief, detail and pinpricks (the Marble, Fabric and Neon
chunks) and draws a dense sculpt of the same numbers instead: two pieces split at the slit (the upper mask on the Head
bone, the chin on the Jaw bone), about 6,500 vertices, the outline as a monotone cubic through the knots, the rim
receding on an ellipse into the skull and rolling back with a little thickness, the relief pushed out of it as real
geometry (both tiers). Painted on it: ivory albedo (sRGB about 0.71, 0.64, 0.5), ambient occlusion and grime from the
sculpt's cavity (sockets very dark, creases dirty), yellowing toward the rim, the round the mouth and the chin, dirt
blotches, the cracks (a dark gap with a stained halo; at Max grooved into the normal), the streaks, the slit, faint
nostrils, the chipped edge (a real hole onto the black behind, a chalky broken edge), the eye holes (pure black, bored
0.3 deep with parallax at Max, a tiny pale pinprick on the back wall). The room's light comes from above and the
cavities hold it back; the torch and the point lights saturate, so the relief reads inches from the lens. At Max a
256 x 256 detail normal map (glaze crazing and pitting) and a glaze roughness map. **Pinpricks** glow only within
11-15 studs of the camera (view.js `glowReach`), dim (no halos: no cute glowing dots).

## Dissolve, smoke and rim on Roblox

- **Dissolve** (the website: a per-pixel noise threshold rising from the feet, an emissive cold edge RGB 0.42, 0.66,
  1.0, static, embers): on Roblox step `Transparency` per part by a seeded per-part threshold mixed with height (feet
  first on FadeOut, the mask last; the mask first on FadeIn), set each part briefly Neon in the edge colour as it
  crosses, and burst particles: a ParticleEmitter at every smoke anchor plus one at the chest, `:Emit(n)` at the start
  (34 puffs on FadeOut, 24 on FadeIn) with sparks (`rbxasset://textures/particles/sparkles_main.dds`, cold white). Hide
  the body's cast shadow while it dissolves (`CastShadow = false`), as the website does.
- **Smoke wisps**: a ParticleEmitter on each `Smoke*` Attachment (`SmokeWeight` scales its share): rate
  (3 + 1.7 x speed) x weight, lifetime 1.1-1.9, size 0.16-0.3 growing to 0.9-1.5, transparency 0.58 -> 1, colour
  near-black, LightInfluence 1 (the torch lights it), drag 1.4, a slow rise; texture
  `rbxasset://textures/particles/smoke_main.dds` (built in, not an asset id). Max: the full rate (x 2.2, up to 300
  puffs with the shroud); Potato: x 0.3, at most 14.
- **The shroud**: the anchors with `SmokeShroud` (`SmokeChest`, `Smoke<Side>Flank`, `Smoke<Side>Hip`,
  `Smoke<Side>Thigh`) shed a tattered dark shroud from the shoulders down: a second ParticleEmitter on each, 11 puffs a
  second shared by weight at Max (x 0.15 on Potato), 1.7 x the wisps' size, 1.5 x their opacity, sinking 0.1-0.35
  studs a second and keeping only 13 % of the body's velocity, so it drags behind it.
- **Rim and edge haze**: no shaders on Roblox; at Max a `Highlight` on the model (OutlineColor RGB 140, 173, 255,
  OutlineTransparency about 0.85, FillTransparency 1) stands in for the cold rim; the haze is the wisps.

## Graphics tiers (look.js `LookTiers`)

Tiers only toggle visual layers; the skeleton, animation, timings, hitboxes and metrics never change.

| Layer | Max (the Max, High and Medium graphics tiers) | Potato (the Low and Potato tiers: weak GPUs, school Chromebooks) |
| --- | --- | --- |
| shadow body | rim, saturating torch sheen, smoke crawling over the skin, dithered edge haze | rim and sheen only |
| mask | the sculpt (geometric relief), occlusion, grime, cracks, streaks, chip, detail normal map (crazing, pitting), glaze roughness, grooved cracks, parallax eye holes | the same sculpt, silhouette and painted layout; flat eye holes, no detail map |
| jumpscare on the mask | racing cracks, the maw, strands, the dilating pupil, 20 shards | the same, 8 shards |
| dissolve | three noise octaves, static, cold edge, embers | one octave, static, cold edge |
| smoke | up to 300 dense puffs, the full shroud | up to 14 plain puffs, a thin shroud |
| pinprick halos | off (no cute glowing dots) | off |
| torch shadow | it casts one (where the engine draws the torch shadow) | none |
| fixture shadows | the nearest lamps cast its shadow on the walls and floor (Max 4, High 3, Medium 2) | none |

## The jumpscare and the reveal (jumpscareView.js, jumpscare.js, view.js, mask.js)

- **Staging** (jumpscare.js `SPACING`, root to root): Hallway 4.2 (eased out to at least 3.4), Locker 4.4 (3.6): far
  enough back for the bow to bring the mask level with the victim's eye; Vent and Underwater lunge straight in (2.8,
  2.6). The bow is a visual pose: the root, the hitbox and the metrics do not move with it.
- **Framing**: the camera starts at the victim's eye looking at the mask as it swoops down and blends into a lock on
  the FaceFrontAttachment by 0.23 s: level (the look's pitch clamped to about 6 degrees), `HOLD_DISTANCE` 1.35 studs off
  (Locker 1.22, Vent 1.25, Underwater 1.45), FOV 55, so the mask fills about 80 % of the frame; upright but for a
  quarter of the head's roll, so the mask's cock shows.
- **The sequence**, about 1.6 s (`SEQUENCE`, seconds after startAt):
  1. 0-0.15 the snap-in: from up to 2.6 studs on an overshooting ease past 1.35, the mask cocked 24 degrees, a
     cold-white flash; the room's light on the mask falls away (`focus`) and a cold light low and to one side of the
     camera (camera space 0.85, -0.55, -0.55) rakes across it; the victim's torch gutters to 30 %;
  2. 0.12-0.5 the cracks race across the mask: branches grown from the rig's cracks and the slit by a seeded random walk
     out to the rim (mask.js `raceCracks`, seed 8517), each segment growing from its start in turn;
  3. 0.36-0.78 the slit tears open into the maw: a jolt (camera lurch, shake, light spike, tear burst); a jagged,
     vertical, leaning black hole growing from the slit (to about 0.16 wide and 0.56 tall), a chalky broken lip round
     it; porcelain shards (20 at Max, 8 on Potato) break off at 0.4 and tumble out toward the victim; 0.46-1.35 thin,
     dark, wet strands stretch across it, thinning, snapping one by one;
  4. 0.62-0.9 the right pupil dilates: the pinprick swells into a dim milky iris with a black pupil opening in it;
  5. 0.84-1.26 the violent shake (about 1.55 x the jumpscare amplitude, 4 degrees);
  6. 1.02 a white flash, then red (a multiplied blood red, 1.05-1.28) and a last lurch in;
  7. 1.18-1.47 the static tear grows (bands slipping, a chromatic split, static flooding);
  8. 1.47 static fills the frame for 0.13 s, then the cut to black at 1.6; the black holds through the outcome
     (resolveAt, 1.85) and the 0.6 s beat, then fades back over 0.7 s.
  No round mouths and no white crescents: the hinge parts 1.2 degrees, the shape is the maw.
- **Roblox**: the JumpscareController follows the same timeline: the camera from the victim's head to a lock on the
  FaceFrontAttachment (level, 1.35, FOV 55); a SpotLight on a part low and to one side of the camera for the raking
  light; the torch's brightness down to 30 %; the race as the crack strips' lengths growing out (or crack strokes on
  the grime cards' SurfaceGuis); the maw: Parts cannot be painted with a hole, so Roblox's controller parts the hinge
  further through the tear (up to about 14 degrees by 0.78 s): the black cap, sleeve and throat show through the split
  and the `MawShard` teeth stand jagged and uneven in it; the dilation as the `RightPupil` Neon part growing 3 x with
  its Color dimmed; the shards as a ParticleEmitter of small ivory triangles (`Emit(20)`, gravity 14); a
  ColorCorrection Brightness spike then TintColor red for the flash, its flicker for the tear, a ScreenGui of noise
  frames for the static and a black Frame for the cut.
- **Variants**: Hallway as above; Locker closer (1.22) and darker edges; Vent dim and tight; Underwater murky
  green-blue, the tear rolling slower and the static softer.
- **Reveal** (`reveal(kind)`, no catch): a phantom of the head, mask, tatters, chest and arms snaps into view 3.4
  studs ahead of the camera (the hiding-spot kinds `Fakeout`, `Locker`, `Barrel`, `Cabinet`, any case: 0.75, inside
  the spot), the mask cocked 26 degrees and half in shadow (the room's light falls away from it and a cold light from
  one side and a little above lights the other half), the torch stuttering on it (dropping to 12 % in flickers: the
  flashlight's `stutter` hook), glitching, for 0.36 s (in 0.05, out 0.09), with a sting (`Teleport`), a shriek
  (`Locker`, `Barrel`, `Cabinet`; a `Fakeout` leaves its shriek to the game), a 5.5 degree camera jolt and a burst of
  tear and static. On Roblox: the same pose on a cloned head, a PointLight to one side, the torch's light flickered.

## The contract with the behaviour

The view reads `{state, speed, poseMode, action, actionStartedAt, fade}` every frame through `readContract` (view.js):
`action` one of Stare, ReachIn, LookAway, FadeOut, FadeIn, Jumpscare (held actions run until it changes or clears),
`actionStartedAt` on the service clock, `fade` 0..1 (when the service publishes it, it wins over `hidden`), and an
optional `actionTarget` (a world point the ReachIn / Jumpscare aim at; else the player's eye).
