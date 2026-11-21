# Stay Behind: the build plan (draft 6 of 6, technical director and producer)

How the game gets built, in what order, how long it may take, and what only the owner can do.

Marks used: **[PROPOSAL]** is my proposal and is collected under "Decisions for the owner" if it changes the game.
**[Lead Pn]** is one of the lead's shared working proposals, still to be put to the owner. **[checked]** means a source
backs it (research report 05 unless stated); **[from memory]** and **[estimate]** mean it is not verified.
Nothing here is built until the owner approves the game map (CLAUDE.md).

---

## 1. The way of working

**Who does what.**
- **The builder** is a Claude Code session running on the owner's gaming PC, in the project folder. It writes all
  code, scripts and data, imports and places assets, builds, tests, renders pictures of its own work and packages
  playable builds.
- **The owner** play-tests, judges and decides. He talks to the work from any device; the building happens on the PC.
- **The repository is the shared memory.** A session can end at any moment (a usage limit, a crash, a restart). So nothing important lives only in a session. Every task leaves three things in git:
  - the change itself;
  - a line in `Docs/STATE.md` (what was done, what is half done, what is next);
  - for anything he will see, a short note in `Docs/builds/<date>.md`: what to look at and what is known to be wrong.

**The loop, for every piece of work.**
1. A small task with a written goal ("the Listener hears a dropped bottle at 12 m and not at 25 m").
2. Build and test it alone (below) until every check passes.
3. Fresh-eyes review: a second agent judges pictures as the owner would, with a score out of ten, before anything is
   sent (the method that worked in the first game, `lessons-from-rovloc.md`).
4. A playable build, a few pictures, and the note: what changed, what to try, three questions.
5. He plays, records a short clip if he can, and answers. His answer goes into `Docs/feedback/` in his own words.
   It is never paraphrased away.
6. Small things the builder fixes on its own. Anything that changes the game goes back to him as a question with
   options and a recommendation, as he asked.

**Every build carries a stamp** (the date and the commit, small in a corner of the pause menu), so each piece of
feedback ties to exact code.

**What the builder can check alone, and how.**

| Check | How |
|---|---|
| It builds | command-line C++ builds and packaging; logs read for warnings and errors |
| It works | automation tests for every system; one functional-test map per creature kind ("a Still One does not move while in view"); a scripted route through each chapter that fails on any error |
| The creatures behave as designed | simulated players (sprinter, walker, croucher, hider, mixed) run thousands of seeded encounters and must hit the creature draft's numbers: how often noticed, chased, caught; a warning before every catch |
| Puzzles are fair | a solver test generates 1,000 seeds for each puzzle and solves each one; hints are checked for every difficulty level |
| The level is playable | the level builder checks every room is reachable, every objective has a hiding place near it, every duct is wide enough for the creatures that use it |
| It looks right in stills | fixed "photo spots" in every area render to PNG on every quality setting and as a path-traced reference; the builder looks at each picture and compares it with the last build |
| It looks right in motion | 10-second clips on fixed camera paths, checked frame by frame for flicker, noise, smearing and pop-in (stills hide these) |
| It runs fast enough | frame-time logs per quality setting on the same routes; memory and load times; hitch count |
| The sound is right technically | an event log of every sound played; recorded mixes measured for loudness and frequency; speech recognition on every voice line; caption timing |
| The licences are clean | every asset has a row in the manifest (section 5); a check before every commit blocks bought or Fab content from git |

**What only he can judge.** Feel (controls, speed, weight), fear (does the scare land, is the hunter frightening in
motion), fun and pacing, whether it is too hard, whether a sound is right or scary, whether the mix works on his
headphones, whether Danny and Kayla look sixteen, whether a scene is sad, motion sickness. **The builder never marks one
of these as done on its own.** Each chapter's "done" includes his play (section 9).

---

## 2. Set-up on his PC

What is known: Windows, Unreal Engine 5.8.4 installed through the Epic Games Launcher, the folder `C:\StayBehind`
(CLAUDE.md). A session on the PC has begun the set-up. Unknown: the graphics card, the memory and the disk.

**Step 0: read the machine (read only, nothing installed).** The builder runs, and records in `Docs/pc.md`:
- graphics card, its memory and driver: `Get-CimInstance Win32_VideoController`, `nvidia-smi` if NVIDIA, `dxdiag /t`;
- system memory: `Get-CimInstance Win32_PhysicalMemory`;
- processor: `Get-CimInstance Win32_Processor`;
- disks, their type and free space: `Get-PhysicalDisk`, `Get-Volume`;
- the monitor's resolution and refresh rate.

**What each result means for the top graphics setting** [estimate; measured for real in the first slice]:

| What is read | What it means |
|---|---|
| RTX 4080 / 5080 or better, RX 7900 XTX / 9070 XT; 16 GB or more video memory | "Ultra" is reachable at 1440p and 60 frames a second: hardware ray-traced lighting at its top level, ray-traced reflections on wet floors and glass, strand hair in cutscenes |
| RTX 4070 / 5070, RX 7800 XT; 12 GB | "High" at 1440p with upscaling, or 1080p without it. Ultra only for cutscenes and pictures |
| RTX 3060 / 4060, RX 6600 to 7600; 8 GB | "Medium" (the cheaper Lumen Lite lighting) at 1080p with upscaling. The look is still built for High; we check what Medium loses in the dark tunnels, where Lumen Lite is reported to flicker [checked] |
| No ray-tracing hardware (GTX 10 or 16 series) | Not a target. Building would be very slow and the game's look cannot be judged on it. That would be a hardware conversation with him, never a purchase made for him |
| System memory 16 GB | It works, but shader compiles and big imports will be slow and may run out of memory. 32 GB is the real minimum for this work, 64 GB is comfortable [from memory]. An upgrade is his decision |
| Free space on a fast NVMe drive below 300 GB | Not enough. The plan needs about 500 GB, and 1 TB is comfortable: engine 40 to 100 GB, scanned assets and samples tens of GB each, the shader cache tens of GB, packaged builds 20 to 60 GB each [estimate] |
| A second drive | Becomes the home for backups and old builds (section 7) |

**Then, in order, each with his OK** (installers ask for administrator approval on screen, which only he can give):
1. **Windows update and the current graphics driver.** For DirectX 12 and stable ray tracing.
2. **Visual Studio 2026 Community** (free) with "Game development with C++" (its Unreal parts ticked) and "Desktop
   development with C++". **Install the MSVC 14.50 compiler explicitly.** The newer 14.51 breaks 5.8 builds; Epic
   fixed it in its main line, and no 5.8 hotfix note found today says it reached 5.8.4 [checked: forum thread
   2743134; 5.8.4 hotfix post]. The project pins 14.50 in its build configuration, and Visual Studio is not updated
   in the middle of a milestone.
3. **The exact Windows SDK** the engine asks for, read from `Engine\Config\Windows\Windows_SDK.json`. Sources disagree,
   so the file decides.
4. **Editor debugging symbols** in the Launcher's options for 5.8.4. They are large, but without them a crash log
   cannot say where it crashed, and reading crash logs is how the builder fixes crashes.
5. **Git for Windows and Git LFS**, with long paths on. **Blender** (the hunter's model pipeline runs in it),
   **7-Zip**, optionally **RenderDoc** for graphics captures.
6. **Folder layout** [PROPOSAL]: `C:\StayBehind\Game` (the Unreal project, its own private repository; see decision 5),
   `C:\StayBehind\Rovloc` (this repository: the design memory), the shader cache on the fastest drive, builds and
   backups on the second drive. Short paths, because Unreal breaks on very long ones.
7. **Claude Code in the project folder.** Ask him once to allow the editor connection (below).
8. **Windows Defender exclusions** for the project, the shader cache and the engine folder [from memory: virus scans
   slow builds badly]. Only with his OK, because it is a security setting.
9. **Power settings:** the PC must not sleep during overnight shader compiles and renders.
10. **The project:** Epic's First Person template renamed StayBehind, with DirectX 12, SM6 and the section 4 graphics
    features on, and the plugins listed in research report 05 (plus Audio Gameplay Volumes and Soundscape).
11. **Prove the tools.** A command-line build with a clean log; one automation test; one rendered picture the builder
    opens and looks at; one packaged build he double-clicks. Then test the editor connection.

**The editor connection (Unreal MCP).** 5.8 ships an experimental server inside the editor that lets the builder drive
the open editor directly [checked]. It is useful, but it is experimental, one forum report says the 5.8 release did
not show its tools, and it gives the builder broad live control of the editor. **It is an extra, never the
foundation.** Everything must also work through C++, Python scripts and command lines, so a broken plugin costs speed,
not the project. The Remote Control API is the second fallback.

---

## 3. The project's architecture

### In plain words
- **The rules of the game are code, not drawings.** All behaviour is written in C++, which the builder can read,
  change and test. Unreal's visual scripting (Blueprints) is used only to hold references to models and sounds, for
  menus, and for small one-off scripted moments. The builder cannot read Blueprint wiring as text, so no game logic
  lives there.
- **Numbers and lists are text files.** Items, noise levels, creature senses, puzzle definitions, dialogue and
  captions, the sound list and the quality settings are CSV or JSON files in `Data/`. A command rebuilds the game's
  tables from them. Changing a creature's hearing range is a one-line text change and needs no rebuild of code.
- **Levels are built by a script from a plan.** Each area has a layout file: rooms, doors, stairs, vents, hiding
  places, lights, puzzle spots. A script deletes everything it made last time and builds it again. It also writes a
  top-down plan picture and a text summary, so a layout can be reviewed without opening the editor.
- **Art placed by hand is kept apart.** Props, dressing ("the stuff on the floor"), hand-tuned lights and sound
  emitters live in their own sublevels that the script never touches. Rebuilding the walls never wipes the art.
- **Everything is tested.** Each system has tests; each creature has a test map; each chapter has a scripted route.

### Precisely

**The repository** [PROPOSAL]:
```
StayBehind.uproject
Source/
  SBRules/        pure C++ rules, no levels: the hunter's director and clock, noise maths, puzzle generators and
                  solvers, the quiet-choices ledger, the symbol language, the seeded random numbers
  StayBehind/     the game: player, interaction, inventory, light, hearing, hiding, doors, saves, creatures,
                  survivors, radio, gun, flight, low gravity, cutscene handover, captions
  SBUI/           menus, the backpack, the binder, the options (thin C++ base classes; widget layout in UMG)
  SBEditor/       level builder, importers, validators, the photo-spot renderer, data import, manifest checks
  SBTests/        automation tests, functional tests, simulated players, route runs
Data/             CSV and JSON: items, loot, noise, creatures, puzzles, dialogue, captions, sounds, quality, chapters
Layouts/          one JSON per area and floor (rooms, doors, vents, hide spots, lights, anchors, ceiling heights)
Scripts/          editor Python: build_level, import_layout, import_sounds, import_creature, photo_spots, manifest
Tools/            the Blender creature pipeline and the voice pipeline, carried over
Content/StayBehind/  our own hand-made assets (Git LFS)
Content/Generated/   made by scripts; never in git, rebuilt on demand
Content/ThirdParty/  Fab, Megascans, Epic samples, MetaHumans; never in git
Docs/             STATE.md, pc.md, asset-manifest.csv, builds/, feedback/
```
`SBRules` depends on nothing but the engine core, so its tests run in seconds without a level. This is how the first
game proved its monster: the same seeded rules run in the game and in a simulation of thousands of players.

**Systems, in build order:**
1. Seeded random numbers and the save format (versioned; it stores the chapter, the place, the backpack, the
   survivors, the choices ledger, the symbols learned, the puzzle seed, and the puzzle difficulty, which can be lowered
   at a chapter start but never raised [Lead P5]).
2. The player: movement, the body and breath, the first-person arms (UE's first-person rendering), interaction,
   Enhanced Input.
3. Light and noise, the two currencies: the torch and its battery; one noise table that sets both the sound's level
   and what each creature hears. Our own hearing subsystem, because a 5.8 forum report says the engine's hearing
   event does not fire [checked: research 06]. The light registry and light volumes that the Dark Dwellers read.
4. Hiding places and doors, as Smart Objects that the player uses and the creatures search or tear.
5. The backpack, the items, the scarce supplies.
6. The director and the hunter: the clock and the strain gauge ported from the earlier game, one configuration per
   chapter, State Tree brains, perception, portal sound (a creature behind a wall is heard through the nearest open
   door).
7. The puzzle framework: definition, state machine, solution from the seed, hint stages.
8. Survivors, dialogue, captions, the radio, the quiet-choices ledger.
9. The cutscene handover (third person to first person), and the catch scenes as two templates: **taken**
   (dragged away, the screen cuts off) and **mauled** (graphic, short, skippable, fast reload) [Lead P2].
10. Each creature kind's own rule, in the order of section 9.
11. Later chapters' systems: the alien gun, the flight, low gravity, the self-destruct sequence.

**Levels** [PROPOSAL]. One persistent level per place (School, City, Mothership) with streaming sublevels per floor or
section, loaded at stairwells and doors. The city uses World Partition, as City Sample does. Each floor has four
sublevels:
- `_Gen` (walls, floors, ceilings, doors, volumes, nav links; rebuilt by script);
- `_Logic` (triggers, puzzle anchors, save point; also generated);
- `_Dress` (hand dressing, never touched by the script);
- `_Light` (hand-tuned lights over the generated practical lights).

Scattered debris uses PCG with a fixed seed, so it is reproducible text plus a seed rather than thousands of hand
placements. Hero props are placed by hand in `_Dress`.

**Size rules the level script enforces** (from the lead's and the creature draft's proposals):
- the hunter stands about 3 m and stoops or folds under the school's ceilings [Lead P7]; each room's ceiling height is
  in the layout data;
- the hunter's navigation uses three heights: upright, stooped and crawling;
- every duct used by a creature is at least 70 x 70 cm;
- the Brute has its own navigation mesh;
- vents and ceilings for the hunter and the Swarm use an authored route graph, because the engine's navigation does
  not walk on walls [checked: research 03].

**Each save point is a small room in the layout data** [Lead P3]: the safe room in the basement, one small save point in
every later area. The save system refuses to save with a creature searching nearby (systems draft).

---

## 4. The look

### The graphics stack for a dark school at the highest quality
| Part | Setting | Why it matters here |
|---|---|---|
| **Lumen, hardware ray traced** | Top level on Ultra; reflections with hit lighting | Bounce light from a torch on painted walls, true reflections in wet floors, glass and lockers |
| **MegaLights** (production ready in 5.8) | On everywhere | Dozens of shadowed lights at once: flickering tubes, exit signs, the torch, alien light strips. Before it, an interior game had to ration shadows |
| **Virtual Shadow Maps + Nanite** | On; every static mesh is Nanite | Dense scanned debris at full detail with sharp contact shadows |
| **Volumetric fog + local fog volumes** | Basement haze, dust in beams, ship mist | The strongest single "eerie" setting; the torch beam becomes a visible shape |
| **Substrate materials** | On (the default) | Layered surfaces: wet grime over paint over concrete, skin, alien slime |
| **Exposure** | Manual, or a narrow range per area | Automatic exposure brightens dark rooms and kills the fear |
| **Camera and grade** | A physical camera, subtle film grain, one grade per area kept in data, no heavy bloom, no orange wash | The owner's notes: gray-leaning with real faded colour, nothing copper |
| **Torch** | A light profile (IES), slightly warm; dims and flickers with its battery | The survival system and the look become one thing |
| **Upscaling** | TSR, or DLSS / FSR / XeSS for his card | Spends the frame on light, not pixels |
| **Path tracer** | Reference pictures only | The ground truth that real-time pictures are judged against |

**The ladder down** (one menu; it picks a default from the detected card):
- **Ultra:** ray-traced Lumen at its top level, hit-lighting reflections, MegaLights, high shadows and fog, strand hair
  in cutscenes.
- **High:** ray-traced Lumen High; strand hair only in close-ups. **This is the setting the look is designed and judged
  on** [PROPOSAL, decision 2].
- **Medium:** Lumen Lite, MegaLights, medium shadows and fog, card hair.
- **Low:** software Lumen Lite, fewer fog samples, lower texture pool.

Every setting is rendered from the same photo spots on every milestone, so a loss is seen, not guessed.

**Cutscenes** run in real time in the engine with a cinematic boost (strand hair, depth of field, higher shadow
quality) [PROPOSAL]. Pre-rendered video would look richer, but it would be many gigabytes, could not show the torch
and wounds as they are in play, and could not change with the quiet choices.

### Where realism will be strongest
- **Places and materials.** Free Megascans (free again on Fab since 5 November 2026) [checked], Nanite and Substrate
  let every square metre of a small, dark, cluttered school carry scan-quality wet concrete, tile, rust, paper and
  glass. This is the setting the technology does best, and darkness hides what we cannot afford.
- **Light.** Ray-traced bounce, many shadowed lights, light in the air: where a still frame can stand beside the
  best games released.
- **Sound.** Recorded sounds, real room reverb, sound round corners: no frame cost, half of the realism.
- **The hunter.** The largest share of art and animation time, seen mostly in the dark.

### Where it will be weakest, said plainly, and the plan for each
1. **People moving in third-person cutscenes.** Big studios record actors on motion-capture stages. We have no stage.
   The plan:
   - about twelve cutscenes, no more (the story draft's list), staged in the ways a small team does well: two people
     seated or standing, close-ups, people seen from behind, darkness, cutting on action;
   - no crowds moving, no fights, no hugs, no handing things over;
   - bodies from UE 5.8's one-camera markerless capture (experimental), filmed on a phone with the owner or friends
     acting [checked: research 04];
   - walking from Epic's Game Animation Sample;
   - hands and objects posed by hand with Control Rig;
   - the moments that would expose us are played in first person instead (the knock-out, the fall, every catch).
   Who performs is decision 3.
2. **Teenage faces.** MetaHuman has no age control and its bodies are built for adults [checked: research 04]. A
   16-year-old Danny and Kayla are the largest single art risk. The plan:
   - build a test Danny and Kayla in the first slice, before any other character work: shorter and slimmer bodies,
     softer jaw and brow, fuller cheeks, younger skin;
   - judge them under hard light in a cutscene camera, and show the owner;
   - if they read as twenty-plus, the fallbacks are a teen body pack on Fab (a purchase, his decision) and camera
     language that keeps faces half in torchlight.
   This is decision 4.
3. **Faces talking.** Lip-sync from audio is good; the upper face from audio is generic [from memory]. Film the
   performer's face on a phone for the 30 to 40 key lines, and use audio-driven animation for the rest.
4. **Danny's hands**, seen all game in first person. A dedicated arms model and hand-made poses for every held item;
   this gets real time in the slice.
5. **The crowd at the evening event.** Suggested, never shown moving: sound through walls, shadows on door glass,
   abandoned coats and bags, a few still figures far off (story draft).

### What "as realistic as GTA six" can and cannot mean here
- **It can mean:** a frame of a dark corridor under the torch, a wet basement floor, the hunter folding through a
  doorway, the mothership filling the sky. These can stand next to the best-looking games of today in light, surfaces
  and air. We will show him exactly such frames, judged against path-traced references.
- **It cannot mean:** GTA's scale. That is a city with thousands of animated people and cars, built from years of
  motion capture and facial capture by a very large studio. Our city is a few dense blocks at night, and our people
  are few, in small careful scenes.
- **The honest promise:** the places, the light and the sound as real as the engine allows; the people as real as a
  team without a capture stage can make them, shown with care.

---

## 5. Assets: what comes from where

| Source | Used for | Licence | In git? |
|---|---|---|---|
| **Megascans on Fab** | Surfaces, debris, "the stuff on the floor", decals | Fab Standard License; commercial use in any engine; no redistribution [checked]. Check each listing really shows as free | No |
| **Other free Fab listings** | Props as needed | Standard or "UE-Only", read per listing | No |
| **City Sample** (Epic) | The base of the few dense city blocks, re-dressed after the invasion | UE-Only: commercial use in Unreal games [checked] | No |
| **Game Animation Sample** (Epic) | Walking, idles, the first-person body, survivors' movement | UE-Only, commercial use [checked] | No |
| **MetaHuman** | Danny, Kayla, the six survivors, the rescue crew, the taken in the holding halls (5.8 Collections) | Unreal EULA, free under $1M revenue [checked] | No |
| **CC0 sources** (Poly Haven, ambientCG; MakeHuman in the hunter pipeline) | Textures, sky light, models | CC0 | Only if small and changed by us |
| **Our own scripts** | The school's modular kit (walls, frames, drop ceilings on a 50 cm grid), the hunter, procedural props, the alien symbol set (drawn as vectors so it stays consistent) | Ours | Yes (scripts) |
| **Recorded sounds** (the traced CC0 library; Sonniss GDC bundles after reading their licence text; the owner's phone recordings) | All effects | CC0 / royalty-free / ours | WAVs yes (small) |
| **Higgsfield pictures** | Concept art, mood boards, posters and flyers for the event, notes, graffiti, sky and backdrop cards for the mothership, weathering masks | Commercial terms not yet read; read before any picture ships | Yes, as source pictures |

- **Higgsfield is weak** for full surface textures (an AI picture is only colour, tiles badly and is not HDR) and for
  heroes or creatures as 3D; Megascans does surfaces better and for free.
- The account holds 1.57 credits; every job is logged in the existing ledger.
- **Nothing is bought, rented or subscribed to without the owner's word.** That covers Fab paid packs, sound
  libraries, voice services, music services and storage.

**The manifest** (`Docs/asset-manifest.csv`): one row per asset or pack. The columns are:
- id and path in the project;
- source and page link, author;
- licence and the date it was read;
- date added and version;
- sha256 for files we hold;
- changed by us (yes/no);
- may be redistributed (yes/no);
- AI-made (yes/no; Steam requires disclosure of AI content players see or hear [checked: research 04]);
- where it is used.

A check before every commit refuses any file under `Content/ThirdParty/`, and any file whose manifest row says it may
not be redistributed. A weekly report lists assets with no row. With the manifest, the project can be rebuilt from
nothing on a new PC.

---

## 6. What is carried over from the earlier game, and how

| What | Where it is | How it comes over |
|---|---|---|
| **The hunter's look** | `docs/design/art/higgsfield/picks/monster-favourite-B3.png`; the Blender pipeline in `archive/wip-2026-11/monster-model.bundle` (five levels of detail, skin, hood, hands) | 1. Restore the bundle on its own branch. 2. Export FBX with one root bone, Z up, centimetres. The old 11 studs is about 3.1 m, which matches the lead's 3 m [Lead P7]. 3. Import by script, flip the normal map's green channel, move the old flesh-thickness channel to a subsurface mask. 4. Retarget base walking, then add its own crawl, fold and stoop by hand. **Side view, hands and movement get as much care as the face**, the first game's lesson |
| **The hunter's rules** | `monster-behaviour-v3.bundle` (the clock, strain, backstage, chase tokens, near misses, the presence simulator); the numbers in `docs/design/monster` | Ported to `SBRules` as pure seeded C++. The numbers go into `Data/Creatures/Hunter.json`. The old simulator becomes a test that must reproduce the old measured results before anything new is added |
| **The school's layout** | `web/build/world.json` (rooms, doors, stairs, vents, 955 lights, zones, patrol loops) | `Scripts/import_layout.py` cuts it into `Layouts/*.json` per floor, converts studs to centimetres and builds a grey blockout. Expect heavy changes: it was built for a chase game, and slow survival play needs denser, looping spaces with safe rooms (the level and chapter draft decides) |
| **Recorded sounds** | 325 WAVs under `web/sounds/sources/` with `SOURCES.json` provenance (about 45 MB) | Batch import by script; the provenance becomes manifest rows; a CSV sets each sound's class, attenuation and concurrency |
| **The voice pipeline** | `tools/voices`, `docs/design/voices` (Danny 3, Kayla 3, the dry whisper; LICENCES3.txt) | It makes the temporary voice track for every line now, so scenes can be timed and lip-synced before real voices exist. Its main model is retired research (audio draft), so its version is pinned. The hunter's whisper bank is cut from lines the taken really said [Lead P1], so those lines must exist, at least as temporary voices, before the whisper is built |
| **Design pictures** | `docs/design/art/higgsfield/` | Reference boards and targets for the photo-spot reviews; the face and hand pictures for texture work on the hunter |
| **Lessons and research** | `lessons-from-rovloc.md`, `docs/design/research`, `docs/design/look` | Read before making anything he sees or hears |

**Not carried over:** the browser renderer, the Chromebook graphics tiers, the Supabase co-op layer, the Luau stage
builders (the roof and city stage maps are layout references only), and the MakeHuman people (replaced by MetaHuman).

---

## 7. Saving the work

**In git:** `Source/`, `Data/`, `Layouts/`, `Scripts/`, `Tools/`, `Config/`, `Docs/`, the `.uproject`, the WAV
sources and their provenance, the voice recordings once made (a few GB at most). **In Git LFS** (10 GiB free [checked]):
only our own hand-made `.uasset` and `.umap` files (thin Blueprints, data assets, the dressing and lighting sublevels,
menus), with `.gitattributes` and file locking set from the first day. **Never in git:**
- Fab, Megascans, City Sample, the animation sample and MetaHumans (re-downloadable, and not ours to redistribute);
- generated levels (rebuilt from data);
- `Binaries`, `Intermediate`, `Saved`, the shader cache, packaged builds.

**Why this matters:** if the PC's drive died with only git saved, we would lose time, not work.
- Code, data, layouts and our own art come back from git.
- Packs are downloaded again; levels and the shader cache are rebuilt (hours, overnight).
- What would be lost: unpushed work, our own MetaHuman designs if they are not exported, and anything stored outside
  the plan.

The account's billing page must be checked: older accounts may still be on the old 1 GB LFS quota [checked].

**Backup options for the big files** (decision 6):

| Option | Cost | Risk |
|---|---|---|
| **A. A second drive** (internal or USB) with a nightly versioned copy: 7 daily and 4 weekly copies, not a plain mirror, which would copy a deletion or a corruption too | Free if he has a spare drive; a 2 TB drive is roughly $60 to $150 [estimate] | Same house: fire, theft, a power surge. Restores fast |
| **B. Backblaze Personal Backup** (unlimited, one computer) | $99 a year [checked: backblaze.com] | Off-site, set and forget. A full restore of hundreds of GB is a long download. Version history is limited. It is a third party holding unreleased files. Whether it covers his USB drive and the project's file types must be read before he pays [from memory] |
| **C. Object storage** (Backblaze B2) with a backup tool | $6.95 per TB per month [checked: backblaze.com]: about $3.50 a month for 500 GB | More set-up; he types its key into the tool himself (never into chat); the cost grows with the project |
| **D. More GitHub LFS** | $0.07 per GiB-month plus downloads [checked]: about $14 a month for 200 GiB | Not a whole-project backup, and the packs cannot go there anyway |
| **E. Git only** | Free | A dead drive costs days of re-downloading and rebuilding, plus any unpushed work |

**The game's repository** (decision 5): a **new private repository** for the Unreal project [PROPOSAL]. It keeps
Rovloc's 661 MB history and its old web game out of the new project, it makes the "never public" rule easy to keep,
and the private setting protects work in progress. Rovloc stays the design memory (the game map, the owner's words,
the research) until the slice is accepted. Then the design documents are copied into the new repository, and Rovloc's
CLAUDE.md points there.

**Branches:** `main` is always buildable; each task is a short branch merged after its tests pass; every build he
plays is tagged.

---

## 8. The first slice

**What it is:** about 10 to 15 minutes of play that prove the look, the pipeline and the fear on his PC, before any
chapter is built.

**Contents:**
1. **The basement safe room.** The generator and its hum (the sound of safety). Cots and lived-in clutter. Test
   MetaHumans of Danny and Kayla plus two survivors, to test the faces and the cost of people. A manual save at the
   logbook.
2. **60 to 80 m of tunnel**, with two hiding places, one vent and one loop.
3. **The hunter:**
   - imported at 3 m, stooping under the tunnel ceiling and folding through one doorway;
   - the carried-over clock and senses;
   - a patrol, an investigation and one chase;
   - heavy far-heard steps, and the whisper made from temporary-voice lines;
   - one **taken** catch: dragged into the dark, the screen cuts off.
4. **One real puzzle:** restoring the generator (find a fuse, read a gauge, set breakers in an order taken from a
   clue), seeded, with its 1,000-seed solver test and hints at each difficulty level.
5. **The look:** Megascans dressing, the torch and its battery, MegaLights flicker, fog, manual exposure, the quality
   ladder.
6. **Sound:** footsteps on four surfaces with debris, the noise table driving the hunter's hearing, sound coming round
   corners, about 20 carried-over sounds, room reverb.
7. **One 20-second third-person shot** handing over to first person. A 5.8 bug report says the camera blend back to
   play is broken [checked: research 04], so this is tested in the first week, with a matched hard cut as the fallback.

**How it is judged:**
- **By the numbers.** Frame rate at his resolution on High: 60 frames a second, or the target he picks in decision 2.
  No hitch over 50 ms after shaders are warmed. Zero errors on the scripted route. The simulated players hit the old
  presence targets. The puzzle solves at every seed. A clean rebuild of the slice from git (plus downloaded packs)
  works.
- **By pictures.** Ten photo spots plus three short clips, scored by the fresh-eyes reviewer against path-traced
  references and his favourite hunter picture; nothing under 8 of 10 is sent.
- **By him, and this decides.** He plays it two or three times, records a clip, and answers six questions:
  1. Does it look real enough?
  2. Was the hunter scary, and when?
  3. Did you understand what to do?
  4. Do Danny and Kayla look sixteen?
  5. Did any sound feel wrong?
  6. What would you change first?
  **The slice is done when he says it looks and feels right.**

**What is learned from it:**
- the real frame cost of light, people and fog on his card, which sets the top setting;
- how many minutes one change takes, from edit to something he can play (this sets the schedule);
- whether the editor connection works;
- whether the teen faces pass;
- whether one-camera capture is usable;
- how fast the project grows on disk;
- whether the hunter frightens in motion.

**After it, the schedule in section 10 is rewritten with measured numbers.**

---

## 9. Milestones after the slice

**Three levels of "done" for every chapter:**
- **Grey:** every mechanic, creature and puzzle works start to end in a blockout. **He plays here**, because the
  layout and the pacing are cheap to change now.
- **Dressed:** art, light and sound pass; photo spots reviewed; frame rate met on every setting. **He plays here** for
  fear and look.
- **Final:** voices, cutscenes, captions, choices wired, no known bugs. **He plays here** for the story, and he signs
  it off.

Every level also needs, before he plays it: a scripted route through the chapter with zero errors; the simulated
players on the creature's targets; and the puzzle solver passing.

**Order** [PROPOSAL; the creature order follows the creature draft]:
- **M1 Chapter 1**, the basement: the Dark Dwellers when the power fails, the survivors and the safe room's first
  state, plus a grey prologue so that the game starts at its real beginning.
- **Technical spikes, run early and small alongside M1 and M2**, so the hardest unknowns show early rather than late:
  - the Swarm with Mass and Niagara;
  - a city block from City Sample re-dressed at night;
  - the flight on a set course;
  - low gravity.
- **M2 Chapter 2**, the Listeners; this also proves the noise table end to end. Every school milestone includes
  Danny's return to the safe room and its changed state.
- **M3 Chapter 3**, the Still Ones.
- **M4 Chapter 4**, the Mimics. It needs the voice pipeline and the radio.
- **M5 Chapter 5**, the Swarm and the roof: the helicopter, the fall, Kayla taken, the parachute.
- **Whole-school pass:** Chapters 1 to 5 played start to end by him. This is the halfway point and the honest moment
  to recalibrate the rest.
- **M6 Chapter 6**, the city: the Patrol, the gun, the knock-out in first person, the ship.
- **M7 Chapter 7**, the flight.
- **M8 Chapter 8**, the mothership: the Brute, the holding halls, low gravity, the self-destruct, the stay-behind
  ending and its variants.
- **M9 Epilogue** as Kayla, and the **final prologue**: the crowd, the mothership and the crawl-out. It is built last
  because it needs the most mature tools.
- **M10 Finishing:**
  - final voices and songs;
  - every cutscene final;
  - the quiet choices checked across playthroughs;
  - three full run-throughs by him;
  - a packaged build friends can install.

Final voices can be recorded at any point once a chapter's script is locked. Recording in batches per chapter keeps
actors' time small.

---

## 10. An honest schedule

These are ranges, not promises [estimate]. The first game taught that a date given and then broken by a usage limit
does more harm than a wide range.

| Stage | Calendar time |
|---|---|
| Set-up and proving the tools | 1 to 2 weeks |
| The first slice | 4 to 8 weeks |
| M1 Chapter 1 (plus the grey prologue) | 6 to 10 weeks |
| M2 to M4, each school floor | 5 to 9 weeks each |
| M5 the fourth floor and the roof | 7 to 11 weeks |
| M6 the city | 8 to 14 weeks |
| M7 the flight | 3 to 6 weeks |
| M8 the mothership | 10 to 18 weeks |
| M9 epilogue and final prologue | 3 to 6 weeks |
| M10 finishing (partly alongside) | 6 to 12 weeks |

**Totals:**
- a playable slice in about **1 to 2.5 months**;
- the whole school in about **8 to 14 months**;
- the full game in about **15 to 27 months**.

The range is wide because of what drives it:
1. **His usage limits.** Five-hour and weekly windows; a weekly limit has stopped work for days before. Long jobs (shader
   compiles, cooks, renders, simulations) run in the background and log to files, so they continue while the session
   waits. Runs are sized to the step, never several heavy agents at once.
2. **Iteration speed on his PC.** Minutes per change, cook times and shader compiles, measured in the slice. A fast
   card with 64 GB of memory and an NVMe drive could make the low end real; 16 GB of memory pushes toward the high end.
3. **How often he plays.** No chapter passes "dressed" or "final" without him. A build a week keeps work moving; one
   a month stalls it (decision 7).
4. **Voices and songs.** Recording with friends depends on their time and their parents' releases.
5. **Changes of mind.** Cheap at grey, expensive at final. That is why he plays at grey.
6. **Engine surprises:** experimental features and bugs in 5.8.

**If it runs long, cut or merge in this order** [PROPOSAL, decision 8]. Each step is put to him before it happens.
1. Twelve cutscenes down to eight; the rest become first-person scenes.
2. Fewer side rooms and Easter eggs, keeping the best.
3. The flight down to about 10 minutes.
4. The city from a few blocks to two blocks with interiors.
5. The Swarm made of a few hero creatures instead of a mass simulation.
6. The mothership from 120 minutes to about 90, with a shorter low-gravity stretch.
7. Last, and only with his yes because it changes the game's content: Chapters 3 and 4 merged, the Still Ones and the
   Mimics sharing one floor.

**Never cut:** the hunter's quality, the safe room and the survivors, the story's beats, the sound.

---

## 11. Risks, and what reduces each

| Risk | What reduces it |
|---|---|
| **The builder cannot feel the game** | Short play-test loops; his clips and answers; the builder never marks feel, fear or sound as done alone |
| **Teen faces read as adults** | Tested first, in the slice; fallbacks prepared (decision 4) |
| **Cutscene bodies look stiff** | Few scenes, staged simply; one-camera capture; first person wherever a body would show the seams (decision 3) |
| **Scope against "Red Dead depth" and "GTA six graphics"** | Said plainly now (section 4); depth through the people and the safe room, not volume; the cut order ready |
| **Usage limits break sessions** | STATE.md and commits after every task; background jobs with logs; work sized to the window |
| **Few play-tests** | A weekly build with three questions; feedback written down in his words |
| **Experimental parts fail** (editor connection, one-camera capture, the Sequencer blend, the engine's hearing event) | Every one has a fallback that does not depend on it: scripts and command lines; library and hand-keyed animation; a hard matched cut; our own hearing subsystem |
| **Toolchain and shader compiles** (MSVC 14.51 breaks builds; first compiles take hours) | 14.50 pinned; Visual Studio not updated mid-milestone; shader cache on NVMe; compiles run overnight |
| **Losing work** | Git pushed daily; versioned backups (decision 6); the manifest to rebuild |
| **Licence slips** | The manifest and the pre-commit check; Higgsfield's and Sonniss's terms read before use; nothing in a public repository |
| **Minors' voices and faces** | A signed release from a parent for anyone under 18, covering the voice, face capture and the hunter's altered version; no one's voice cloned without consent |
| **The hunter's size against the rooms** [Lead P7] | Ceiling heights are layout data; three navigation heights; the level script fails a layout the hunter cannot pass |
| **Eight people in the safe room is the heaviest scene** [Lead P6] | Card hair in play; capped detail levels; measured in the slice with four people, then eight |
| **A vehicle chapter and low gravity are each a small game of their own** | Early spikes (section 9); kept short and on a set course |
| **A 20 to 60 GB build for friends** | Texture limits, only used maps cooked, shader pre-compile on first start; Windows warns on an unsigned game |

---

## 12. The co-op choice [Lead P9]

The story is Danny's alone: Kayla on the radio, his choices, his death. Real co-op in Unreal means every system shares
its state over a network: the player, the creatures, the director, the puzzles, the doors, the saves and the
cutscenes. Adding that to a finished single-player game is close to a rewrite [from memory]. The options (decision 1):

- **(a) Build everything ready for co-op now.**
  - Every system written with network authority in mind, and tested with two players on one PC.
  - The director per player (the earlier game's clock was already per player).
  - Shared puzzles, host saves.
  - Cost: roughly **a quarter more time on systems work**, and slower testing at every step [estimate].
  - It still leaves the design questions open: who the second player is in a story about one boy, and what happens
    in the cutscenes.
- **(b) Single-player now, built tidy.** Game state is kept in a few clear places, with no network code. Co-op later
  becomes its own project: a separate mode, for example nights in the school with the floors and creatures already
  built, not the story campaign. It would take months of rework, and it is honest to say it may not happen.
- **(c) No co-op, said plainly now.** The cheapest option; everything goes into the story game.

**Recommendation: (b).** It protects the nine-hour story, which is what he asked for first, and keeps a real door
open.

---

## 13. What the owner does himself

1. Approve the installers and settings on his PC, and log in to the Epic Launcher and Fab to add the free packs to
   his library. The builder never asks for a password.
2. Keep the PC on and awake for long jobs, and say when he needs it for himself.
3. Play each build, ideally once a week. Record a short clip (Windows has a built-in recorder: Win + Alt + R) and
   answer the three to six questions.
4. Decide the questions below, and any spending: drives, backup, Fab packs, voice or music services.
5. Decide who voices the people (audio draft). If friends take part, collect their signed releases, signed by a
   parent for anyone under 18.
6. If he wants the songs to be truly his, write the lyrics (audio and story drafts).
7. Approve the editor connection once, and look at the test Danny and Kayla when asked.

---

## Decisions for the owner (most important first)

1. **Co-op: do we build for it now?** [Lead P9]
   - (a) Build every system ready for co-op now (about a quarter more systems work, slower testing).
   - (b) Single-player now, built tidy; co-op later as its own mode, which may not happen.
   - (c) No co-op ever.
   - **Recommend (b):** the story is about one boy, and building for co-op now would slow every step of it.
2. **What is the top graphics setting tuned for?**
   - (a) 60 frames a second on High at his monitor's resolution, with Ultra above it for stronger cards and for
     pictures.
   - (b) 30 frames a second, with everything turned up.
   - (c) Decide after the slice, with numbers measured on his card.
   - **Recommend (a), confirmed in (c):** horror needs fast, smooth looking-around, and the slice shows what his card
     can do.
3. **Who performs the bodies in the cutscenes?**
   - (a) He and friends act the scenes in front of a phone, for Unreal's one-camera capture (signed releases).
   - (b) Library and hand-posed animation only, with simpler, stiller scenes.
   - (c) A paid video-to-motion service.
   - **Recommend (a), with (b) as the fallback for every scene:** real people's movement is the cheapest real fix
     for the game's weakest point.
4. **If the free tools cannot make Danny and Kayla look sixteen, what then?**
   - (a) Keep the free tools and frame their faces with more shadow and fewer close-ups.
   - (b) Allow a teen body pack from Fab (price shown to him first).
   - (c) Decide when he sees the test pictures.
   - **Recommend (c), leaning (b):** it is tested first in the slice, and his eye is the judge.
5. **Where does the game's code live?**
   - (a) A new private repository for the Unreal project; Rovloc stays the design memory.
   - (b) Everything inside Rovloc.
   - (c) A new private repository with the design documents moved in now.
   - **Recommend (a), moving the documents after the slice:** it keeps the old game's history and the licensed packs
     apart from the new one.
6. **How are the big files backed up?**
   - (a) A second drive with nightly versioned copies (free if he has one, otherwise about $60 to $150).
   - (b) (a) plus Backblaze Personal Backup off-site ($99 a year).
   - (c) Git only (free; a dead drive costs days).
   - **Recommend (a) now, (b) once voices and hand-made art exist:** most of the project can be rebuilt; off-site
     matters when irreplaceable recordings appear.
7. **How often can he play-test?**
   - (a) A short build every week (20 to 40 minutes plus a clip).
   - (b) Every two weeks, longer.
   - (c) Only at milestones.
   - **Recommend (a):** his play is the only judge of fear and fun, and long gaps stall chapters.
8. **If the schedule runs long, may we cut in the order of section 10?**
   - (a) Yes, each step still put to him before it happens.
   - (b) No cuts; accept a longer schedule.
   - (c) He sets his own order.
   - **Recommend (a):** it cuts polish and volume first, and the story and the hunter last.
