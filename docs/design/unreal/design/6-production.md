# Stay Behind: the build plan (document 6 of 6)

**Second edition, 21 November 2026: agrees with the game map and the canon sheet; where they differ from this document, they win.**

The technical director's and producer's document: how the game gets built, in what order, how long it may take, and
what only the owner can do. The first draft built on research reports 03, 04, 05 and 06 (report 05, the Unreal
production plan, unless stated). This edition applies the game map (`game-map.md`), the owner's twelve answers ("use
recomended": the recommended option for every one), the rulings in `drafts/CHANGES-NEEDED.md`, the canon sheet
(`canon.md`) and the readings from his PC (`pc.md`).

**Order of authority.** The owner's own words (requirements.md sections 7 to 10, owner-checklist.md) > the game map >
CHANGES-NEEDED.md > the canon sheet > this document. `cutscenes.md` is the authority on every cutscene and
`voices.md` on every voice; where this document mentions either, it only points at them.

**What this document owns, and what it cites.** It owns the build (canon 15): the PC as measured, the quality target,
the first slice, the order of work, the schedule and the cut list. Where it gives one of those it is the canon value;
only this document retunes them, and then the canon sheet is updated in the same change. Everything else is cited as
"canon n" and not copied: people and the speaking faces (canon 1), the aliens (canon 2), chapter minutes (canon 3),
places and heights (canon 4), Danny (canon 5), light and power (canon 6), the noise table (canon 7), the hunter (canon
8), the seven kinds (canon 9), items (canon 10), saving, restart points and presets (canon 11), the symbol language
(canon 12), the gun, the scanner, the flight, low gravity and the self-destruct (canon 13), sound and music (canon 14).

**Marks.** **[checked]** means a source backs it (report 05 unless another is named); **[from memory]** and
**[estimate]** mean it is not verified. The first draft's proposal marks and the lead's working proposals are gone:
every point they marked is settled by the map, the owner's answers or the rulings (see "Decided" at the end).
Nothing is built in Unreal until the owner has approved the written game map (CLAUDE.md); he approved its direction
and answered its twelve decisions on 21 November 2026.

**Three rules held everywhere.** Graphic horror is for the creatures and Danny's own deaths, the hunter's catch
included; nothing graphic ever happens on screen to a student or to anyone taken. Crafting is game logic only (named
objects snap together; no real recipe for anything dangerous). Patterns are taken from other games, never their
content: no creature, puzzle, scene, line or name of theirs.

---

## 1. The way of working

**Who does what.**
- **The builder** is a Claude Code session running on the owner's gaming PC, in the project folder. It writes all
  code, scripts and data, imports and places assets, builds, tests, renders pictures of its own work and packages
  playable builds.
- **The owner** play-tests, judges and decides. He talks to the work from any device; the building happens on the PC.
- **The repository is the shared memory.** A session can end at any moment (a usage limit, a crash, a restart). So
  nothing important lives only in a session. Every task leaves three things in git:
  - the change itself;
  - a line in `Docs/STATE.md` (what was done, what is half done, what is next);
  - for anything he will see, a short note in `Docs/builds/<date>.md`: what to look at and what is known to be wrong.

**The loop, for every piece of work.**
1. A small task with a written goal, its numbers taken from the canon sheet ("the hunter hears Danny walking at 4 m
   and not at 5 m, canon 7").
2. Build and test it alone (below) until every check passes.
3. Fresh-eyes review: a second agent judges pictures as the owner would, with a score out of ten, before anything is
   sent (the method that worked in the first game, `lessons-from-rovloc.md`).
4. A playable build, a few pictures, and the note: what changed, what to try, three questions.
5. He plays, records a short clip if he can, and answers. His answer goes into `Docs/feedback/` in his own words.
   It is never paraphrased away.
6. Small things the builder fixes on its own. Anything that changes the game goes back to him as a question with
   options and a recommendation, as he asked ("if you are tricky on anything ask me about it dont make guesses").

**A standing rule** (owner-checklist line 131). The old website and the Roblox game are left exactly as they are:
nothing is taken down, deleted, redeployed or changed, and no Roblox work starts without his word ("dont start roblox
game automatically"). The builder never touches `web/` or the Roblox place.

**What every update tells him** (map part 9; checklist lines 148 and 150): when the next build comes and what is
left before it. Pictures of each finished set are sent the day they are ready, and every note, picture set and
report can be read on a phone without the PC (checklist line 152).

**Every build carries a stamp** (the date and the commit, small in a corner of the pause menu), so each piece of
feedback ties to exact code.

**What the builder can check alone, and how.**

| Check | How |
|---|---|
| It builds | command-line C++ builds and packaging; logs read for warnings and errors |
| It works | automation tests for every system; one functional-test map per creature kind ("a Still One does not move while in view"); a scripted route through each chapter that fails on any error |
| The creatures behave as designed | simulated players (the profiles of `2-creatures.md` 4.4) run seeded encounters headless on the room-portal graph each Layout JSON exports (section 3) and must hit that section's numbers: how often noticed, chased, caught; a tell before every catch. The real navmesh and the rendered "watched" test are checked on a few seeded routes per creature, overnight |
| Puzzles are fair | a solver test runs 1,000 seeds for each puzzle (each seed picks among its authored value sets and item spots, `4-puzzles-world.md`) and solves each one; hints are checked on every tier (canon 11) |
| The level is playable | the level builder checks every room is reachable, every objective has a hiding place near it, every duct and crawlway meets canon 4 for the creatures that use it, and the hunter can pass every route at its height (canon 8) |
| It looks right in stills | fixed "photo spots" in every area render to PNG on every quality setting and as a path-traced reference; the builder looks at each picture and compares it with the last build |
| It looks right in motion | 10-second clips on fixed camera paths, checked frame by frame for flicker, noise, smearing and pop-in (stills hide these) |
| It runs fast enough | frame-time logs per quality setting on the same routes; memory (the editor's peak on 16 GB as well as the game's) and load times; hitch count |
| The sound is right technically | an event log of every sound played; recorded mixes measured for loudness and frequency; speech recognition on every voice line; caption timing; each creature reacts at the distance canon 7 predicts (`5-audio.md`) |
| The voices pass their gates | the checks of `voices.md` part 5, line by line; they never stand in for his ear |
| The licences are clean | every asset has a row in the manifest (section 5); a check before every commit blocks bought or Fab content from git |

**What only he can judge.** Feel (controls, speed, weight), fear (does the scare land, is the hunter frightening in
motion), fun and pacing, whether it is too hard, whether a sound is right or scary, whether a voice sounds like a real
person (`voices.md` part 9), whether the mix works on his headphones, whether Danny and Kayla look sixteen, whether a
scene is sad, whether a creature's look is right (each is a gate he signs), motion sickness. **The builder never marks
one of these as done on its own.** Each chapter's "done" includes his play (section 9).

---

## 2. Set-up on his PC

**The PC as measured** (canon 15; the readings, the commands that took them and what is installed are in `pc.md`):
an RTX 5070 with 12 GB, a Ryzen 5 7500X3D (6 cores), 16 GB of memory (one stick, three slots free), one 1 TB NVMe
drive with about 600 GB free, Windows 11 Pro, a 1440p screen at 270 Hz. Unreal Engine 5.8.4 from the Epic Games
Launcher, the game's folder `C:\StayBehind` (CLAUDE.md). Step 0 of the first draft, reading the machine, is done.

**What it means** [estimate; measured for real in the first slice]:

| Part | What it means |
|---|---|
| RTX 5070, 12 GB | The "upper-mid" rung of report 05's ladder: hardware ray-traced Lumen at High, MegaLights, DLSS at Quality. The look is designed and judged on **High at 1080p native or 1440p with DLSS, 60 frames a second**; Ultra holds nothing back and is for pictures (canon 15) |
| 16 GB of memory | Half what Epic recommends (32 GB). Report 05 expects, from memory, slow builds and stalls while shaders compile; with ordinary apps open only 1 to 1.5 GB was free, so other programs are closed while the editor runs. Epic's City Sample docs list 64 GB [checked: feasibility review], so City Sample is never opened whole (section 3). A 5.8 forum report shows MetaHuman skin-cache video memory overflowing on 8 GB with only a few people [checked: forum thread 2728166]. **The upgrade to 32 GB, before the slice, is recommended and his purchase (decision 11); work starts on 16 GB**, and on 16 GB the top end of every range in section 10 is the base estimate |
| About 600 GB free on NVMe | Meets the plan's need of about 500 GB: the engine 28 GB now and past 100 GB with templates and symbols, scanned assets and samples tens of GB each, the shader cache tens of GB, packaged builds 20 to 60 GB each [estimate]. 1 TB free would be comfortable; with about 600 GB, space is watched at every milestone |
| A second drive | **Required by this plan**, and his purchase (decision 11, with the memory): the home for backups and old builds, with at most two packaged builds kept (section 7). Until it is in, only git protects the work |
| MetaHuman Animator (faces from video) | Report 04 asks for 32 GB and 16 cores; this PC meets the card and is below on memory and cores (`pc.md`). What that costs has not been tried |

**Already done, with his OK** (`pc.md` section 2): Visual Studio Community 2026 (18.12) with "Desktop development
with C++", "Game development with C++" and ".NET desktop development"; MSVC Build Tools 14.50 with ATL; the Visual
Studio Tools for Unreal Engine; the .NET Framework 4.6.2 targeting pack; Windows 11 SDK 10.0.22621; Git 2.56 with Git
LFS 3.8.1. The engine's own file, `Engine\Config\Windows\Windows_SDK.json`, decided the list where sources disagreed.

**The compiler.** Three are on the disk. The build tool picks 14.50 by its own rules and ranks 14.52 last; 14.52 no
longer ships the `<hash_map>` header, and report 05 says that removal breaks 5.8 builds. The project pins 14.50 by
the folder's full name, `14.50.35717` (a bare `14.50` stops the build; `Latest` picks 14.52), so a missing 14.50 is
an error rather than a quiet move to 14.44. The project's compiler is never set to Visual Studio 2022, which is not
installed. Visual Studio is not updated in the middle of a milestone. The first build's log must show the line
"Using ... 14.50.35740 toolchain ... and Windows 10.0.22621.0 SDK" (`pc.md` section 4).

**Still to do, in order, each with his OK** (installers ask for administrator approval on screen, which only he can
give):
1. **Windows update.** Report 05 puts it first; whether Windows is up to date was not checked.
2. **The graphics driver.** 621.01 is installed; 621.24 is newer, and the known faults on each side are in `pc.md`
   section 3. Whether and when to update is his decision.
3. **The Launcher's extra parts** for 5.8.4: "Templates and Feature Packs" (the First Person template), "Starter
   Content" and "Editor symbols for debugging". The symbols are large, but without them a crash log cannot say where
   it crashed, and reading crash logs is how the builder fixes crashes. Engine Source only if stepping through the
   engine's own code is wanted.
4. **Blender** (the hunter's model pipeline runs in it), **7-Zip**, optionally **RenderDoc** for graphics captures,
   when the model work starts.
5. **Folder layout:** `C:\StayBehind\Game` (the Unreal project, its own private repository, section 7),
   `C:\StayBehind\Rovloc` (this repository: the design memory), the shader cache on the NVMe drive, builds and
   backups on the second drive. Short paths, because Unreal breaks on very long ones.
6. **Claude Code in the project folder.** Ask him once to allow the editor connection (below).
7. **Windows Defender exclusions** for the project, the shader cache and the engine folder [from memory: virus scans
   slow builds badly]. Only with his OK, because it is a security setting.
8. **Power settings:** the PC must not sleep during overnight shader compiles and renders.
9. **The project:** Epic's First Person template renamed StayBehind, with DirectX 12, SM6 and the section 4 graphics
   features on, and the plugins listed in report 05 (plus Audio Gameplay Volumes and Soundscape). The engine stays on
   5.8.x for the whole project: 5.8 is the last planned UE5 release [checked: feasibility review].
10. **Prove the tools.** A command-line build with a clean log and the compiler line above; one automation test; one
    rendered picture the builder opens and looks at; one packaged build he starts himself. Then test the editor
    connection.

**The editor connection (Unreal MCP).** 5.8 ships an Experimental server inside the editor that lets the builder
drive the open editor directly [checked]. It is useful, but it is Experimental, with reports of dropped connections
and one that the 5.8 release did not show its tools, and it gives the builder broad live control of the editor. **It
is an extra, never the foundation.** Everything must also work through C++, Python scripts and command lines, so a
broken plugin costs speed, not the project. The Remote Control API is the second fallback.

---

## 3. The project's architecture

### In plain words
- **The rules of the game are code, not drawings.** All behaviour is written in C++, which the builder can read,
  change and test. Unreal's visual scripting (Blueprints) is used only to hold references to models and sounds, for
  menus, and for small one-off scripted moments. The builder cannot read Blueprint wiring as text, so no game logic
  lives there.
- **Numbers and lists are text files.** Items, noise levels, creature senses, puzzle definitions, dialogue and
  captions, the sound list and the quality settings are CSV or JSON files in `Data/`, and every value in them that the
  canon sheet holds is the canon value. A command rebuilds the game's tables from them. Changing a creature's hearing
  is a one-line text change and needs no rebuild of code.
- **Levels are built by a script from a plan.** Each area has a layout file: rooms, doors, stairs, vents, hiding
  places, lights, puzzle spots, lantern rooms and restart points. A script deletes everything it made last time and
  builds it again. It also writes a top-down plan picture, a text summary and the area's **room-portal graph**, so a
  layout can be reviewed and its creatures tested without opening the editor.
- **Art placed by hand is kept apart.** Props, dressing ("the stuff on the floor"), hand-tuned lights and sound
  emitters live in their own sublevels that the script never touches. Rebuilding the walls never wipes the art.
- **Everything is tested.** Each system has tests; each creature has a test map; each chapter has a scripted route.

### Precisely

**The repository:**
```
StayBehind.uproject
Source/
  SBRules/        pure C++ rules, no levels: the hunter's director and clock, noise maths, the room-portal graph and
                  its simulation, puzzle generators and solvers, the quiet-choices ledger, the symbol language, the
                  seeded random numbers
  StayBehind/     the game: player, interaction, inventory, light, hearing, hiding, doors, saves, restart points,
                  creatures, survivors, radio, gun, scanner, flight, low gravity, cutscene hand-back, captions,
                  printed paper
  SBUI/           menus, the backpack, the binder, the options (thin C++ base classes; widget layout in UMG)
  SBEditor/       level builder, importers, validators, the photo-spot renderer, data import, manifest checks
  SBTests/        automation tests, functional tests, simulated players, route runs
Data/             CSV and JSON: items, loot, noise, creatures, puzzles, dialogue, captions, sounds, quality, chapters
Layouts/          one JSON per area and floor (rooms, doors, vents, hide spots, lights, anchors, ceiling heights),
                  each exporting its room-portal graph
Scripts/          editor Python: build_level, import_layout, import_sounds, import_creature, photo_spots, manifest
Tools/            the Blender creature pipeline and the voice pipeline, carried over
Content/StayBehind/  our own hand-made assets (Git LFS)
Content/Generated/   made by scripts; never in git, rebuilt on demand
Content/ThirdParty/  Fab, Megascans, Epic samples, MetaHumans; never in git
Docs/             STATE.md, pc.md, asset-manifest.csv, builds/, feedback/
```

**The room-portal graph.** The creature rules depend on path distance through doors, occlusion, light volumes, the
"watched" test and navigation, none of which exists without a level. So each Layout JSON also exports a graph of its
rooms and portals: path distances, the occlusion of each portal (canon 7), the light volumes and the hide spots
(`4-puzzles-world.md` 1.2). `SBRules` depends on nothing but the engine core and simulates on that graph, so its tests
run without a level, in minutes. This is how the first game proved its monster: the same seeded rules run in the game
and in a simulation of thousands of players. The real navmesh and the rendered "watched" test are checked on a few
seeded functional routes per creature, run overnight, and the graph's numbers are re-checked in the engine at each
milestone. A floor is not finished until its graph is exported and matches what is built.

**Systems, in build order:**
1. Seeded random numbers and the save format (versioned; it stores the chapter, the place, the backpack, the
   survivors, the choices ledger, the symbols learned, the hunter's learned habits, the puzzle seed and the puzzle
   tier (lowered at any time, raised only at a chapter start; canon 11).
2. The player: movement, the body and breath, the first-person arms (UE's first-person rendering), interaction,
   Enhanced Input (canon 5).
3. Light and noise, the two currencies: the torch and its battery (canon 6); one noise table that sets both the
   sound's level and what each creature hears (canon 7, owned by audio). Our own hearing subsystem, because a 5.8
   forum report says the engine's hearing event does not fire [checked: research 06]. The light registry and light
   volumes that the Dark Dwellers read.
4. Hiding places and doors, as Smart Objects that the player uses and the creatures search or tear.
5. The backpack, the binder, the items, the scarce supplies (canon 5 and 10).
6. The director and the hunter: the clock and the strain gauge ported from the earlier game, one configuration per
   chapter, State Tree brains, perception, portal sound (a creature behind a wall is heard through the nearest open
   door). Its rhythm is the owner's numbers and is the same on every preset (canon 8).
7. The puzzle framework: definition, state machine, values from the seed, hint rungs per tier (canon 11), and the
   **runtime printed-paper system** (section 5) for every note, sheet and map that carries a seeded value.
8. Survivors, dialogue, captions, the radio, the quiet-choices ledger.
9. Saving and dying: the logbook, the lantern rooms, the chapter autosave and "quit and keep my place", and the
   **restart points** at every encounter entrance, large-puzzle stage and solved step, puzzle state kept, on Story and
   Survivor only (canon 11; the owner's decision 2). They are not saves.
10. The cutscene hand-back (third person to first person by a matched cut, control back within 2 s; `cutscenes.md`),
    and the catch scenes as three templates (`2-creatures.md` 5.1): **taken** (the Patrol: a collar of light);
    **the hunter's catch** (its own scene: fingers into Danny's mouth and throat for his voice, the drag into the
    dark, about 6 s, skippable after the first, with the scream whispered back on the next attempt; canon 8); and
    **one first-person maul template** for the animals (canon 9: a 1 to 2 s close camera move of that kind, contact,
    blood on the screen and decals, cut to black, the sound carrying the gore), each with the cut-away option in the
    settings. The struggle Danny can win on the first hunter catch each chapter is part of the hunter's template
    (canon 11).
11. Each creature kind's own rule, in the order of `2-creatures.md` 5.3.
12. Later chapters' systems: the alien gun and the scanner, the flight, low gravity, the self-destruct sequence (canon
    13).

**Levels.** One persistent level per place (School, City, Mothership) with streaming sublevels per floor or section,
loaded at stairwells and doors. The city uses World Partition, and only the blocks Danny walks are loaded (map part
9). **City Sample is never opened whole:** a spike extracts only the buildings it needs into a small new level and
records the editor's peak memory on 16 GB. Each floor has four sublevels:
- `_Gen` (walls, floors, ceilings, doors, volumes, nav links; rebuilt by script);
- `_Logic` (triggers, puzzle anchors, lantern room, restart points; also generated);
- `_Dress` (hand dressing, never touched by the script);
- `_Light` (hand-tuned lights over the generated practical lights).

Scattered debris uses PCG with a fixed seed, so it is reproducible text plus a seed rather than thousands of hand
placements. Hero props are placed by hand in `_Dress`.

**Size rules the level script enforces:**
- the hunter's body and how it passes rooms are canon 8 (on all fours, about 1.6 m to the top of its back's spikes
  and about 2.5 m when it rises onto its hind legs; it squeezes through doors front limbs first); each room's ceiling
  height is in the layout data, and the heights are canon 4 (the tunnels 2.8 to 3.0 m);
- **one navmesh at crawl height**, with nav areas tagged by ceiling height; the tag says where the hunter can rise
  onto its hind legs and where it squeezes through a crawlway, and the level script fails a layout the hunter cannot pass;
- every duct and crawlway used by a creature meets canon 4;
- the Brute uses a navigation filter that leaves out narrow doors, so every Brute space has a loop through them
  (`2-creatures.md` 2.7);
- ducts, pipes, walls and ceilings use an authored surface graph, because the engine's navigation does not walk on
  walls [checked: research 03]: the hunter's ducts, climbing and hanging (it never walks on ceilings, canon 8), the
  Dark Dwellers' ceiling creep and the Swarm's routes.

**Saving in the layout data.** The shelter's logbook and one lantern room per area (canon 4 names each; canon 11
gives the counts) are rooms in the layout data. The save system refuses to save with a searching creature within the
distance canon 11 sets. Restart points are markers in `_Logic`; the chapter route test dies once at each and checks
that Danny is back in under the time canon 11 sets with puzzle state kept.

---

## 4. The look

### The graphics stack for a dark school at the highest quality
| Part | Setting | Why it matters here |
|---|---|---|
| **Lumen, hardware ray traced** | Top level on Ultra; reflections with hit lighting | Bounce light from a torch on painted walls, true reflections in wet floors, glass and lockers |
| **MegaLights** (production ready in 5.8 [checked]) | On everywhere | Dozens of shadowed lights at once: flickering tubes, exit signs, the torch, alien light strips. Before it, an interior game had to ration shadows |
| **Virtual Shadow Maps + Nanite** | On; every static mesh is Nanite | Dense scanned debris at full detail with sharp contact shadows |
| **Volumetric fog + local fog volumes** | Basement haze, dust in beams, ship mist | The strongest single "eerie" setting; the torch beam becomes a visible shape (checklist line 12: light you can see in the air) |
| **Substrate materials** | On (the default) | Layered surfaces: wet grime over paint over concrete, skin, alien slime |
| **Exposure** | Manual, or a narrow range per area | Automatic exposure brightens dark rooms and kills the fear |
| **Camera and grade** | A physical camera, subtle film grain, one grade per area kept in data, no heavy bloom | The owner's look rules (map part 7): gray-leaning with real faded colour in paint, lockers, wood and brick; no orange or copper wash; no black-and-white checkerboard floors; one dark look from the school through the city to the ship |
| **Torch** | A light profile (IES), slightly warm; dims and flickers with its battery (canon 6) | The survival system and the look become one thing |
| **Upscaling** | DLSS on his card; TSR otherwise | Spends the frame on light, not pixels |
| **Path tracer** | Reference pictures only | The ground truth that real-time pictures are judged against |

**The quality menu** (one menu, Low to Ultra; it picks a default from the detected card). **Ultra holds nothing
back, and the lower settings never change what Ultra shows** (map part 9; checklist lines 2 and 16):
- **Ultra:** every scalability group at its highest level (shadows, global illumination, reflections, fog, effects,
  post-processing; the largest texture pool the card holds; Nanite and every mesh at full detail). Ray-traced Lumen at
  its top level with hit-lighting reflections, MegaLights. Strand hair and top-detail MetaHumans on every speaking face
  in play as well as in cutscenes. No quality is cut on Ultra for frame rate; the 60 fps target applies to High. For
  pictures on his card, and for stronger cards.
- **High:** ray-traced Lumen High; strand hair only in close-ups. **This is the setting the look is designed and
  judged on**, at 1080p native or 1440p with DLSS, 60 frames a second (canon 15).
- **Medium:** Lumen Lite, MegaLights, medium shadows and fog, card hair. Lumen Lite is reported to flicker in dark
  tunnels [checked], so what Medium loses there is checked.
- **Low:** software Lumen Lite, fewer fog samples, lower texture pool.

Every setting is rendered from the same photo spots on every milestone, so a loss is seen, not guessed. The first
slice builds only High and the path-traced reference (section 8).

**References for the look** (owner-checklist line 13). The look is judged against stills from Counter-Strike 2 and
the realistic survival games named in the look research (`docs/design/look`), for four techniques this game uses:
scanned materials (Megascans on Nanite), light that bounces like baked light (ray-traced Lumen), surfaces sharp at
arm's length (Nanite, virtual textures, Substrate), and real props at real scale. Their stills are judging references
only, never assets.

**The rework list** (owner-checklist line 137: "if u needs rework anything do so"). `Docs/look-rework.md` lists every
system reworked for the look (for example the torch profile, fog, exposure, the grade, a material set), each with a
before and an after still from the same photo spot and the build stamp.

**Cutscenes** run in real time in the engine with a cinematic boost (strand hair in close-ups, depth of field, higher
shadow quality), in the same grade, grain and 16:9 frame as play, with no black bars (`cutscenes.md`). Pre-rendered
video would look richer, but it would be many gigabytes, could not show the torch and wounds as they are in play, and
could not change with the quiet choices.

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
   - twelve cutscenes, about 17 minutes in all (map part 12); **`cutscenes.md` is the authority on every one of them
     and wins over anything here**, including its ten rules of staging: faces close, brief and still; bodies far,
     from behind or in the dark; the hard part in a cut; at most three people lit in a shot; no touching but a hand on
     glass or on a sleeve; nobody hands anything to anybody on camera;
   - the scenes the reviews found breaking those rules are staged its way: the hunter's unfold on the field only
     behind a cut, in steam and the landing light's flashes, as held poses (cutscenes.md scene 2); the first night as a seated circle cut by face,
     one speaker at a time, eight people at low detail; the roof boarding as silhouettes stepping into the white,
     one per cut, the helicopter as light and rotor wind; and the two close-up exceptions to "no touching" are
     handled as it says (Mari's strumming hand filmed on a phone; Kayla clipping the parachute, played in first
     person);
   - bodies from UE 5.8's one-camera markerless capture, filmed on a phone with the owner and people he knows acting
     (his decision 8). It is **Experimental**, with a GPU crash report on 5.8.2 and depth errors off-axis [checked:
     feasibility review]; **its fallback, for every scene, is library walking and hand posing**;
   - walking from Epic's Game Animation Sample; hands and objects posed by hand with Control Rig;
   - the moments that would expose us are played in first person instead (the knock-out, the fall, the parachute,
     every catch; `cutscenes.md` part 3).
2. **Teenage faces.** MetaHuman has no age control and its bodies are built for adults [checked: research 04]. A
   16-year-old Danny and Kayla are the largest single art risk. The plan:
   - build a test Danny and Kayla in the first slice, before any other character work: shorter and slimmer bodies,
     softer jaw and brow, fuller cheeks, younger skin;
   - judge them under hard light in a cutscene camera, and show the owner (he judges them when he sees the tests);
   - **at most ten speaking faces in the whole game; `cutscenes.md` uses nine, the tenth in reserve** (canon 1 names
     them); everyone else is heard, seen from behind
     or far off; the rescue crew share one helmeted body; the taken are two posed static bodies under frosted lids,
     instanced with material variation;
   - **MetaHuman Collections are Experimental** in 5.8 [checked]: used only after a spike passes on the 5070, and the
     fallback is the instanced static bodies above;
   - if the faces read as twenty-plus, the fallbacks are a teen body pack on Fab (a purchase, his yes, the price shown
     first) and camera language that keeps faces half in torchlight.
3. **Faces talking.** Lip-sync from audio is good; the upper face from audio is generic [from memory]. About 35 key
   lines are acted on a phone, the face filmed while the voice is recorded (`cutscenes.md` lists them scene by scene);
   every other line drives the face from the audio.
4. **Danny's hands**, seen all game in first person. A dedicated arms model and hand-made poses for every held item;
   this gets real time in the slice.
5. **The crowd at the game.** Never shown moving: sound through walls, light round doors, abandoned coats and bags
   (`cutscenes.md`).

### What "as realistic as GTA six" can and cannot mean here
- **It can mean:** a frame of a dark corridor under the torch, a wet basement floor, the hunter squeezing through a
  doorway on all fours, the mothership filling the sky. These can stand next to the best-looking games of today in light, surfaces
  and air. We will show him exactly such frames, judged against path-traced references.
- **It cannot mean:** GTA's scale. That is a city with thousands of animated people and cars, built from years of
  motion capture and facial capture by a very large studio. Our city is a few dense blocks at night, and our people
  are few, in small careful scenes.
- **The honest promise:** the places, the light and the sound as real as the engine allows; the people as real as a
  team without a capture stage can make them, shown with care.

---

## 5. Assets: what comes from where

**One rule over every source** (the owner's decision 10, "maybe sold later"): every tool and asset is picked with
terms that allow a sale, so nothing has to be redone, and nothing is bought without his yes each time.

| Source | Used for | Licence | Allows a sale? | In git? |
|---|---|---|---|---|
| **Megascans on Fab** | Surfaces, debris, "the stuff on the floor", decals; the organic scans (bone, rock, wet membrane) of the alien kit | Fab Standard License; commercial use in any engine; no redistribution [checked]. The listings' licence text was reported as not yet updated after 5 November, so each listing is checked to show as free | yes | No |
| **Other free Fab listings** | Props named by the asset census | Standard or "UE-Only", read per listing | read per listing | No |
| **City Sample** (Epic) | The base of the few dense city blocks, re-dressed after the invasion; only the buildings needed, extracted into a small level | UE-Only: commercial use in Unreal games [checked] | yes, in Unreal | No |
| **Game Animation Sample** (Epic) | Walking, idles, the first-person body, survivors' movement; walking retargeted onto the creatures of the mannequin family | UE-Only, commercial use [checked] | yes, in Unreal | No |
| **MetaHuman** | The nine speaking faces and one in reserve (canon 1); the helmeted crew body; the two static bodies under the frosted lids | Unreal EULA, free under $1M revenue [checked] | yes | No |
| **CC0 sources** (Poly Haven, ambientCG; MakeHuman in the hunter pipeline) | Textures, sky light, models | CC0 | yes | Only if small and changed by us |
| **Our own scripts** | The school's modular kit (walls, frames, drop ceilings on a 50 cm grid), the hunter, procedural props, the alien kit's PCG modules, the symbol set (drawn as vectors so it stays consistent), the printed paper | Ours | yes | Yes (scripts) |
| **Recorded sounds** (the traced CC0 library; Sonniss GDC bundles after reading their licence text; the owner's phone recordings) | All effects | CC0 / royalty-free / ours | read per pack | WAVs yes (small) |
| **Higgsfield** | The jobs in the map (part 9): a design picture for every creature, person and place, which he approves before it is modelled; textures, decals, posters, alien symbol art, skies and backdrops; the menu and loading art; with more credits, 3D models for props and creatures and some cutscene shots | Commercial terms not yet read; **read before any picture ships** | not yet known | Yes, as source pictures |

**Higgsfield** (checklist line 134: the source for every asset it can make). It makes pictures, video, voices and 3D;
the live picture is drawn by Unreal. Where it is weaker than another source (an AI picture is colour only, tiles
badly and is not HDR, so a full scanned surface comes from Megascans; a hero creature in 3D is beyond its credits
today), the manifest row says which source was used and why. The account holds 1.57 credits (about 13 pictures);
every job is logged in the existing ledger. **Before any picture ships, its terms are read and a credit budget is set
with him.** **Modelling never waits for Higgsfield** (owner-checklist line 135: "do stuff u dont need higgsfield for
and once I connect u use that"): if Higgsfield has no credits, or its terms are still unread, when a design picture is
needed, the builder makes the design sheet another way (a render of the grey model with a paintover) and he approves
that. The Higgsfield picture replaces the sheet when it comes.

**Nothing is bought, rented or subscribed to without the owner's word.** That covers memory and drives, Fab paid
packs, Higgsfield credits, sound libraries, voice services, music services and storage.

### The creature production table
Only the hunter has a model pipeline, so every other kind gets a mesh source, a rig and a cost before its chapter is
built (`2-creatures.md` 5 is the creature side of the same plan and agrees with it). Every look starts from a
Higgsfield design picture, and **he signs off each creature's look as a gate** before it is modelled further.
Costs are builder-weeks of creature work inside the chapter ranges of section 10 [estimate; the Dark Dweller timed
alone in the slice is the first real measure, and the table is rewritten from it].

| Kind | Mesh source | Rig and movement | Catch | Cost |
|---|---|---|---|---|
| **The hunter** | the model on all fours he approved on 22 November (section 6) | its own skeleton (on all fours, a second pair of arms, the spikes along its back: canon 8); the animation plan in section 6 | its own template (section 3) | 6 to 10 weeks, across the slice and Chapter 1 |
| **Dark Dwellers** | procedural | a procedural Control Rig sheet on the surface graph | the maul template | 2 to 3 weeks (one is in the slice) |
| **Listeners** | the engine's mannequin family, our own surface (the smooth eyeless head) | walking retargeted from the Game Animation Sample with Motion Matching | the maul template | 2 to 3 weeks |
| **Still Ones** | the mannequin family | about 25 static poses and a catch; never seen moving | the maul template | 1 to 2 weeks |
| **Mimics** | the mannequin family (they must read as a person from behind) | human walking retargeted; the unfolding front | the maul template | 2 to 4 weeks |
| **The Swarm** | a few simple lead actors | Niagara, with no skeleton and no Mass | the maul template | 3 to 5 weeks, the spike included |
| **The Patrol** | the mannequin family in grown armour | human walking retargeted; the room search shared with the hunter | taken | 3 to 5 weeks |
| **The Brute** | the mannequin family at its own scale | retargeted walking; a tearing animation for each soft hiding place | the maul template | 3 to 4 weeks |
| **Ship forms** | material and scale variants of the same meshes | no new rigs, no new rules | as the kind | under a week each; on the cut list (section 10) |

### The alien kit
No ready-made alien assets exist, and every realism promise above rests on Earth surfaces. So the mothership is built
from what exists: **one modular hall and corridor kit** of organic Megascans scans (bone, rock, wet membrane),
Geometry Script and PCG modules and emissive glyph decals (the symbol set of canon 12), reused across the decks with
**four deck looks**: the Hangar; the Underdeck and the Garden deck; the Holds and the Nest; the Spine and the Core
(the decks are canon 4). A **two-week alien-kit spike** runs alongside Chapter 1, with a photo spot the owner judges.

### The asset census
The school has a theatre with a fly tower, bleachers, a library and about forty puzzles whose props carry values that
change with the seed. Megascans covers debris, not school furniture, and no prop source has been checked yet. So the
**first job of the whole-game grey pass** is an asset census per chapter that names a source for each hero prop: a
checked free Fab listing, a Blender script or Megascans. It needs his PC and his Fab login. **Any puzzle whose props
have no source is simplified then** (`4-puzzles-world.md` names its own props).

### The printed paper
One runtime system renders every note, sign-in sheet, invoice, cue list, contact sheet, map and binder page from text
templates in `Data/` to textures, so seeded values never need hand-made textures. The binder's self-marking map and
Kayla's blue ink use it too (canon 11).

### The weekly Fab list
Every Fab addition needs his own login, so he gets them as **one batched list a week** (map part 9), each with its
listing link and the licence it shows.

### The manifest
`Docs/asset-manifest.csv`: one row per asset or pack. The columns are:
- id and path in the project;
- source and page link, author;
- licence and the date it was read;
- whether its terms allow a sale (yes/no/not known);
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
| **The hunter's look** | picture A2 (`docs/design/art/higgsfield/picks/monster-favourite-A2.png`) for the body, the cape of skin, the limbs and the hands, with the new face and the body on all fours (canon 8); the model made on his PC with the local picture and 3D tools (the game repository's `Docs/hunter-look/hunter-quadruped-2026-11-22.md`), which he saw moving in Unreal and approved on 22 November ("This is good") | It is already in the game's Unreal project; its size and speeds are canon 8. B3 and the old game's Blender model (`archive/wip-2026-11/monster-model.bundle`) are no longer its source. Animate by the plan below. **The body, side view, hands and movement get as much care as the face**, the first game's lesson and the owner's (checklist lines 18 to 21) |
| **The hunter's rules** | `monster-behaviour-v3.bundle` (the clock, strain, backstage, chase tokens, near misses, the presence simulator); the numbers in `docs/design/monster` | Ported to `SBRules` as pure seeded C++. The values go into `Data/Creatures/Hunter.json` from canon 8. The old simulator becomes a test that must reproduce the old measured results before anything new is added |
| **The school's layout** | `web/build/world.json` (rooms, doors, stairs, vents, 955 lights, zones, patrol loops) | `Scripts/import_layout.py` cuts it into `Layouts/*.json` per floor, converts studs to centimetres at the world document's scale and builds a grey blockout. Expect heavy changes: it was built for a chase game, and slow survival play needs denser, looping spaces; `4-puzzles-world.md` 1.2 decides |
| **Recorded sounds** | 325 WAVs under `web/sounds/sources/` with `SOURCES.json` provenance (about 45 MB) | Batch import by script; the provenance becomes manifest rows; a CSV sets each sound's class, attenuation and concurrency |
| **The voice pipeline** | `tools/voices`, `docs/design/voices` (the voices he chose: Danny 3, Kayla 3, the dry whisper; LICENCES3.txt) | It makes the working track for every line now, so scenes can be timed and lip-synced before real voices exist (his decision 8: real recordings by him and people he knows replace the main cast when ready). Its main model is retired research, so its version is pinned. How voices are made, checked and judged is `voices.md`. The hunter's whisper is cut from lines the taken really said (canon 8), so those lines must exist, at least as working voices, before the whisper is built, and their real recordings are in the first batch (canon 14) |
| **Design pictures** | `docs/design/art/higgsfield/` | Reference boards and targets for the photo-spot reviews; the face and hand pictures for texture work on the hunter |
| **Lessons and research** | `lessons-from-rovloc.md`, `docs/design/research`, `docs/design/look` | Read before making anything he sees or hears |

**Not carried over:** the browser renderer, the Chromebook graphics tiers, the Supabase co-op layer, the Luau stage
builders (the roof and city stage maps are layout references only), and the MakeHuman people (replaced by MetaHuman).

### The hunter's animation plan
An AI builder cannot hand-key a body on all fours with a second pair of arms to the owner's "the body is not scary
tho" bar, so each move it is seen making has a method (`2-creatures.md` 5.1 agrees):
- **its walk on all fours, its rise onto its hind legs and its squeeze through doors and crawlways:** moves made for
  its own body, never retargeted human walking; the nav area's ceiling tag says where it can rise (section 3);
- **the crawl** (ducts and crawlways): a procedural leg solver;
- **climbing and hanging head-down:** the surface crawler rig on the authored surface graph;
- **the locker lean:** a few authored poses blended in place;
- **the city rooftops:** silhouettes moving on splines;
- **its catch and the struggle:** authored first-person sequences in its catch template (section 3).

**Gate in the first slice:** three 10-second clips of it moving (on all fours down a corridor, a door squeeze, a
locker lean) go to the owner first, and with them a close-up render of the hunter's hand beside A2's hand (the long
clawed fingers; owner-checklist line 21). The hunter is not built further until he has judged them. On 22 November he
saw five clips of the model on all fours at canon 8's speeds and said "This is good continue".

---

## 7. Saving the work

**In git:** `Source/`, `Data/`, `Layouts/`, `Scripts/`, `Tools/`, `Config/`, `Docs/`, the `.uproject`, the WAV
sources and their provenance, the voice recordings once made (a few GB at most). **In Git LFS:** only our own
hand-made `.uasset` and `.umap` files (thin Blueprints, data assets, the dressing and lighting sublevels, menus), with
`.gitattributes` and file locking set from the first day. **Never in git:**
- Fab, Megascans, City Sample, the animation sample and MetaHumans (re-downloadable, and not ours to redistribute);
- generated levels (rebuilt from data);
- `Binaries`, `Intermediate`, `Saved`, the shader cache, packaged builds.

**Git LFS on the free plan** (canon 15): 10 GiB stored and **10 GiB a month of bandwidth** [checked]. A clone on a new
PC counts against the bandwidth, so the LFS share is kept small and a fresh clone is planned for, not repeated. The
account's billing page must be checked: older accounts may still be on the old 1 GB quota [checked].

**Why this matters:** if the PC's drive died with only git saved, we would lose time, not work.
- Code, data, layouts and our own art come back from git.
- Packs are downloaded again; levels and the shader cache are rebuilt (hours, overnight).
- What would be lost: unpushed work, our own MetaHuman designs if they are not exported, and anything stored outside
  the plan.

**Backups.** The plan is **A**, the second drive he buys with the memory (decision 11). The others stay here as the
options, because each costs money and needs his yes:

| Option | Cost | Risk |
|---|---|---|
| **A. A second drive** (internal or USB) with a nightly versioned copy: 7 daily and 4 weekly copies, not a plain mirror, which would copy a deletion or a corruption too | a 2 TB drive is roughly $60 to $150 [estimate] | Same house: fire, theft, a power surge. Restores fast |
| **B. Backblaze Personal Backup** (unlimited, one computer) | $99 a year [checked: backblaze.com] | Off-site, set and forget. A full restore of hundreds of GB is a long download. Version history is limited. It is a third party holding unreleased files. Whether it covers his USB drive and the project's file types must be read before he pays [from memory] |
| **C. Object storage** (Backblaze B2) with a backup tool | $6.95 per TB per month [checked: backblaze.com]: about $3.50 a month for 500 GB | More set-up; he types its key into the tool himself (never into chat); the cost grows with the project |
| **D. More GitHub LFS** | $0.07 per GiB-month plus downloads [checked]: about $14 a month for 200 GiB | Not a whole-project backup, and the packs cannot go there anyway |
| **E. Git only** | Free | A dead drive costs days of re-downloading and rebuilding, plus any unpushed work. This is where the work stands until the drive is in |

**The game's repository:** a **new private repository** for the Unreal project. It keeps Rovloc's 661 MB history and
its old web game out of the new project, it makes the "never public" rule easy to keep, and the private setting
protects work in progress. Rovloc stays the design memory (the game map, the owner's words, the research) until the
slice is accepted. Then the design documents are copied into the new repository, and Rovloc's CLAUDE.md points there.

**The engine is pinned** to 5.8.x for the whole project (canon 15), and the compiler to 14.50 (section 2), so a
restore on a new PC builds the same game.

**Branches:** `main` is always buildable; each task is a short branch merged after its tests pass; every build he
plays is tagged. Git is pushed daily.

---

## 8. The first slice

**What it is** (canon 15): about 10 to 15 minutes of play that prove the look, the pipeline and the fear on his PC,
before any chapter is built, **in 6 to 8 weeks**. If it has not passed by the end of week 8, the options are reviewed
with him: a simpler look target, hardware, or scope. Builder-days are logged per item from the first day; they are the
schedule's measuring stick.

**Contents:**
1. **The shelter.** The generator and its hum (the sound of safety). Cots and lived-in clutter. Test MetaHumans of
   Danny and Kayla plus two survivors, to test the faces and the cost of people. A manual save at the logbook.
2. **60 to 80 m of tunnel, 2.8 to 3.0 m high** (canon 4), with two hiding places, one vent and one loop.
3. **The hunter:**
   - imported at its canon 8 size, on all fours in the tunnel and squeezing through one doorway front limbs first;
   - the carried-over clock and senses, with canon 8's values;
   - a patrol, an investigation and one chase;
   - its heavy steps, heard through two walls, and the whisper made from working-voice lines;
   - its catch (canon 8: the voice-pulling scene, about 6 s, skippable after the first) with the Survivor struggle,
     and the scream whispered back on the next attempt.
4. **One Dark Dweller,** with its light rule (canon 9) and its death scene (the maul template), **timed on its own**,
   to learn what each extra creature costs: the number the schedule most depends on.
5. **One real puzzle:** starting the dead generator, `4-puzzles-world.md`'s Gus's Ears (1.1, the owner's choice of 21
   November: the right relay, bleed, prime, choke, then the loud pulls the hunter answers; canon 6), seeded, with its 1,000-seed solver test and hints on each tier.
6. **The look:** Megascans dressing, the torch and its battery, MegaLights flicker, fog, manual exposure. **Only High
   and the path-traced reference**; the other settings wait.
7. **Sound:** footsteps on four surfaces with debris, the noise table (canon 7) driving the hunter's hearing, sound
   coming round corners, about 20 carried-over sounds, room reverb.
8. **The hand-back:** one short third-person shot in the shelter handing over to first person by a matched cut,
   sound carried across, control back within 2 s (`cutscenes.md`, its step 0). A 5.8 bug report says the engine's
   camera blend back to play is broken [checked: research 04], so the matched cut is the method, tested in the first
   week.

**The gate:** the three 10-second clips of the hunter moving and the close-up of its hand beside A2's hand (section
6) go to him first. The slice is not shown until he has judged them.

**How it is judged:**
- **By the numbers.** On High at 1080p native or 1440p with DLSS: 60 frames a second (canon 15). No hitch over
  50 ms after shaders are warmed. The editor's peak memory on 16 GB recorded. Zero errors on the scripted route. The
  simulated players hit canon 8's rhythm on the room-portal graph. The puzzle solves at every seed. A clean rebuild of
  the slice from git (plus downloaded packs) works.
- **By pictures.** Ten photo spots plus three short clips, scored by the fresh-eyes reviewer against path-traced
  references and his hunter picture A2 (with its new face: canon 8); nothing under 8 of 10 is sent. Each photo spot is also scored beside a
  reference board of stills from the most realistic games (Counter-Strike 2, the five horror games and his "GTA six"
  bar) by fresh viewers (the reviewer and at least one person new to the game). 7 of 10 or better counts as
  photographic (owner-checklist line 1), and any remaining gap is told to him plainly in the build note.
- **By him, and this decides.** He plays it two or three times, records a clip, and answers six questions:
  1. Does it look real enough?
  2. Was the hunter scary, and when?
  3. Did you understand what to do?
  4. Do Danny and Kayla look sixteen?
  5. Did any sound feel wrong?
  6. What would you change first?
  **The slice is done when he says it looks and feels right.** His first listening session (`5-audio.md`) is held on
  the same build.

**What is learned from it:**
- the real frame cost of light, people and fog on his card, which sets the top setting;
- what one more creature costs, from the Dweller;
- how many minutes one change takes, from edit to something he can play, and the builder-days per item (this sets the
  schedule);
- how the editor behaves on 16 GB;
- whether the editor connection works;
- whether the teen faces pass;
- whether one-camera capture is usable;
- how fast the project grows on disk;
- whether the hunter frightens in motion.

**After it, the schedule in section 10 is rewritten with measured numbers.**

---

## 9. Milestones after the slice

**The order of work is the owner's** (canon 15): the slice, then **Chapter 1 finished**, then **the whole game in
grey**, then **finishing chapter by chapter**. He plays the whole story early, and cuts are chosen with the game in
front of him.

**Three levels of "done":**
- **Grey:** every mechanic, creature and puzzle works start to end in a blockout. **He plays here**, because the
  layout and the pacing are cheap to change now.
- **Dressed:** art, light and sound pass; photo spots reviewed; frame rate met on every setting. **He plays here** for
  fear and look. Every cutscene's key frames are scored by fresh viewers beside live-play frames of the same place
  (owner-checklist line 4). Under 7 of 10, or any face that reads as a mannequin, the shot is restaged or played in
  first person by its fallback in `cutscenes.md`.
- **Final:** voices, cutscenes, captions, choices wired, no known bugs. **He plays here** for the story, and he signs
  it off.

Every level also needs, before he plays it: a scripted route through the chapter with zero errors; the simulated
players on each creature's numbers (`2-creatures.md` 4.4); the puzzle solver passing; and the room-portal graph
matching what is built.

**Order** (the creature order follows `2-creatures.md` 5.3):
- **M1 Chapter 1**, the basement, taken through all three levels: the Dark Dwellers when the power fails, the
  survivors and the shelter's first night, Flare Road, plus a grey prologue so that the game starts at its real
  beginning.
- **Technical spikes, run early and small alongside M1**, so the hardest unknowns show early rather than late:
  - the alien kit (two weeks, with a photo spot he judges; section 5);
  - the Swarm in Niagara with a few lead actors;
  - a city block extracted from City Sample into a small level, re-dressed at night, with the editor's peak memory
    on 16 GB recorded;
  - the flight on a set course;
  - low gravity;
  - MetaHuman Collections on the 5070 (used only if it passes).
- **M1.5 The whole game in grey.** Every chapter blocked out from the prologue to the epilogue; every creature as a
  grey stand-in on its real rule; every puzzle working with its value sets; the restart points and saves; the
  cutscenes as rough animatics (`cutscenes.md`). **Its first job is the asset census** (section 5). **He plays all
  nine hours grey, and the cuts are made then** (section 10), while changes are cheap. At its end the script is
  locked, and the real recordings follow in two batches: the cutscenes, Kayla's key radio lines and the whisper
  sources first (canon 14; `voices.md`).
- **Finishing, chapter by chapter, to Dressed and Final:**
  - **M2 Chapter 2**, the Listeners; this also proves the noise table end to end. Each of the milestones for
    Chapters 2 to 4 includes Danny's return to the shelter and its changed state (after Chapter 3 with no calm,
    `1-story.md`).
  - **M3 Chapter 3**, the Still Ones: the theatre floor, the Mark, the crossing home.
  - **M4 Chapter 4**, the Mimics. It needs the voice pipeline and the radio as a sound they walk to.
  - **M5 Chapter 5**, the Swarm and the roof: the breach, the floor run backwards, the roof chase as a built obstacle
    run, the helicopter, the lift, the missile, the parachute in first person.
  - **Whole-school pass:** the prologue to Chapter 5 played start to end by him. This is the halfway point and the
    honest moment to recalibrate the rest.
  - **M6 Chapter 6**, the city: the searchlight and the rooftop chase on landing, the Patrol, Takedown and the gun at
    the midpoint, the wreck, the ship.
  - **M7 Chapter 7**, the flight, lifting straight off the landing pad (canon 13: no canyon, no bridge; the city a
    far field of lights under cloud).
  - **M8 Chapter 8**, the mothership: the decks round the Well, the Brute, the Holds and the Nest, the Spine's low
    gravity, the self-destruct in canon 13's order, the hold and the endings.
  - **M9 Epilogue** as Kayla, and the **final prologue**: the game, the lot, the sneak back in. It is finished last
    because it needs the most mature tools.
- **M10 Finishing:**
  - final voices and songs;
  - every cutscene final;
  - the quiet choices checked across playthroughs;
  - three full run-throughs by him;
  - the full test of every wish on `owner-checklist.md`, the bug sweeps and every change he asks for run on the
    strongest model available, at maximum effort, with multi-agent workflows (his words, requirements.md, Nov 16
    17:40), repeated until two rounds find nothing new (map part 9; checklist line 141); then he is told it is done;
  - a packaged build friends can install.

---

## 10. An honest schedule

These are ranges, not promises [estimate]. The first game taught that a date given and then broken by a usage limit
does more harm than a wide range. The stages and their times are canon 15 (map part 9):

| Stage | Time |
|---|---|
| Set-up and the first slice | 1.5 to 2 months |
| Chapter 1 finished, then the whole game in grey | 4 to 6 months |
| The school finished | 3 to 5 months |
| The city and the flight | 2.5 to 4.5 months |
| The mothership | 2.5 to 4.5 months |
| Epilogue, final prologue, finishing | 2 to 3.5 months |
| **Whole game** | **about 15 to 25 months** |

The ranges assume his larger plan, so little time is lost to usage limits. On 16 GB of memory expect the top end.
After the slice the schedule is rewritten from measured speeds.

**How it is measured.** The slice gives builder-days per item and the cost of one more creature. The chapters are
then sized by their relative effort [estimate: the feasibility review, with Chapter 2 = 1.0]:

| Prologue | Ch1 | Ch2 | Ch3 | Ch4 | Ch5 | Ch6 city | Ch7 flight | Ch8 mothership | Epilogue |
|---|---|---|---|---|---|---|---|---|---|
| 1.0 | 1.8 | 1.0 | 1.2 | 1.0 | 1.5 | 2.5 | 1.2 | 3.5 | 0.5 |

Chapter 1 carries all the core systems and the eight-person shelter; Chapter 3 the theatre and the fly tower; the
city and the mothership are the largest, which is why they are met early in grey and their spikes run alongside
Chapter 1.

The range is wide because of what drives it:
1. **His usage limits.** Five-hour and weekly windows; a weekly limit has stopped work for days before. Long jobs
   (shader compiles, cooks, renders, simulations) run in the background and log to files, so they continue while the
   session waits. Runs are sized to the step, never several heavy agents at once.
2. **Iteration speed on his PC.** Minutes per change, cook times and shader compiles, measured in the slice. 32 GB
   of memory pulls toward the low end; 16 GB pushes toward the top.
3. **How often he plays.** No chapter passes "dressed" or "final" without him. A build about once a week keeps work
   moving; one a month stalls it.
4. **Voices and songs.** Recording with friends depends on their time and their parents' releases.
5. **Changes of mind.** Cheap at grey, expensive at final. That is why he plays the whole game at grey.
6. **Engine surprises:** experimental features and bugs in 5.8.

**If it runs long, cut in this order** (canon 15). Each step is put to him before it happens.
1. The joke ending (the drive-thru) and the extra secrets: the New Game+ extras, and secrets beyond one Easter egg a
   chapter (checklist line 100).
2. Photo mode.
3. Side rooms, keeping the best; never the city's side places he asked for.
4. The extra creature forms on the ship (the kinds still return; checklist line 42).
5. Fewer cutscenes: a scene that is cut is played in first person instead, by its fallback in `cutscenes.md`.

**Never cut: anything he asked for by name.** From `owner-checklist.md`, line by line:
- first-person play with third-person cutscenes (88), and control back within 2 s of every cutscene (94);
- the look: as realistic as can be made, an uncapped top setting, the look rules (1 to 12, 16);
- the hunter's look from picture A2 with its new face (a huge open mouth), the frightening body on all fours and the hands (18 to 22); the
  hunter all game, on every floor, in the tunnels, the city and the mothership (24); seen and heard often, within a
  radius, never teleporting (25 to 27); his rhythm, with few attacks (30, 31); it follows through vents (29); its
  heavy steps heard from far off (45);
- the whisper in the voices of the taken, with his name and mocking, rare and clear (55 to 60);
- the seven kinds he picked, each floor a different way to hide, and the others returning on the ship (34 to 42);
- five to eight survivors in the shelter, their requests, and not all of them make it (75);
- the story he set: the evening game, the walk out joking, the mothership, the small ship and the thing crawling out,
  the basement (70 to 73); the taken alive (74); Kayla on the radio and taken at the crash (76); Danny staying behind,
  the pods and the epilogue as Kayla (77); the quiet choices (78); the title (79);
- a sad, engaging story in chapters with a group you live with and lose (65 to 67);
- the helicopter, the crash and the parachute alone (110); spotted instantly (111); the city as one route through a
  few dense blocks with side places, about an hour and a half (112); its rooftop stretches (119); the knock-out, the
  gun and the ship (113); a flight he steers, dodging, boosting and shooting, 15 to 20 minutes (114); onto the
  mothership (115); the mothership for about two hours, with its decks, the halls of the taken and low gravity (116);
  the self-destruct in several steps (117); the run to the pods as the ship comes apart (118);
- the roof as a built set piece, his "door 100" (93);
- hide first, gun later (89); medium survival, scarce supplies, no hunger meter (105);
- puzzles that are complex, with their own difficulty setting, and codes and places that change each playthrough (98,
  104, 126); the symbol language with the self-destruct as its final exam (103);
- Easter eggs, the small mechanics and the stuff on the floor (100 to 102);
- saving by hand plus a chapter autosave (106);
- graphic gore for the creatures and Danny's own deaths, and nothing on screen for the students (14);
- real, scary sounds for everything, with no clicks or wooden knocks (44 to 51);
- human voices that sound real (52, 53);
- an eerie score and two or three original songs (62);
- eight to ten hours (86), and not too hard (124).

---

## 11. Risks, and what reduces each

| Risk | What reduces it |
|---|---|
| **The builder cannot feel the game** | Short play-test loops; his clips and answers; the builder never marks feel, fear, voices or sound as done alone |
| **16 GB of memory** | The upgrade recommended before the slice (his purchase); City Sample never opened whole; only the walked blocks loaded; card hair and capped detail for groups below Ultra; the editor's peak memory recorded in the slice and the city spike; on 16 GB the top end of every range |
| **Teen faces read as adults** | Tested first, in the slice; at most ten speaking faces; fallbacks prepared; he judges them when he sees the tests |
| **Cutscene bodies look stiff** | Twelve scenes staged by `cutscenes.md`'s rules; one-camera capture (Experimental) with library and hand-posed animation as the fallback for every scene; first person wherever a body would show the seams |
| **Seven more creature bodies with no source** | The creature production table (section 5): shared mannequin family, static poses, a procedural sheet, Niagara; ship forms as variants; one maul template; each look a gate he signs |
| **The mothership has no ready-made assets** | One alien kit with four deck looks, proven in a two-week spike alongside Chapter 1 |
| **The hunter's movement cannot be hand-keyed** | The animation plan (section 6): each seen move has a method; the three 10-second clips are a gate |
| **Puzzle props with no source** | The asset census at the start of the grey pass; the printed-paper system for every seeded value; a puzzle without props is simplified |
| **Scope against "Red Dead depth" and "GTA six graphics"** | Said plainly now (section 4); depth through the people and the shelter, not volume; the whole game in grey early; the cut order ready |
| **Usage limits break sessions** | STATE.md and commits after every task; background jobs with logs; work sized to the window |
| **Few play-tests** | A build about once a week with three questions; feedback written down in his words |
| **Experimental parts fail** (the editor connection, one-camera capture, MetaHuman Collections, the Sequencer blend, the engine's hearing event) | Every one has a fallback that does not depend on it: scripts and command lines; library and hand-posed animation; instanced static bodies; a matched cut; our own hearing subsystem |
| **Toolchain and shader compiles** (14.52 lacks a header 5.8 needs; first compiles take hours) | 14.50 pinned by its full folder name; Visual Studio not updated mid-milestone; the engine pinned to 5.8.x; shader cache on NVMe; compiles run overnight |
| **Losing work** | Git pushed daily; the second drive with versioned copies (decision 11); the manifest to rebuild |
| **Licence slips** | The manifest, its "allows a sale" column and the pre-commit check; Higgsfield's and Sonniss's terms read before use; nothing in a public repository |
| **LFS bandwidth** (10 GiB a month on the free plan) | Only our own hand-made assets in LFS; a fresh clone planned for, not repeated |
| **Minors' voices and faces** | A signed release from a parent for anyone under 18, covering the voice, face capture and the hunter's altered version; no one's voice cloned without consent (`voices.md`) |
| **The hunter's size against the rooms** | Ceiling heights are layout data (canon 4); one navmesh at crawl height with nav areas tagged by ceiling height; the level script fails a layout the hunter cannot pass |
| **Eight people in the shelter is the heaviest scene** | `cutscenes.md`'s staging (never more than three lit, the rest at low detail); card hair and capped detail below Ultra; measured in the slice with four people, then eight |
| **The headless creature tests need a level** | The room-portal graph exported by every Layout JSON; real-navmesh checks overnight; the graph re-checked in the engine at each milestone |
| **A vehicle chapter and low gravity are each a small game of their own** | Early spikes (section 9); kept on a set course; the city below the flight as a far field |
| **A 20 to 60 GB build for friends** | Texture limits, only used maps cooked, shader pre-compile on first start; Windows warns on an unsigned game |

---

## 12. Co-op comes later

**His answer (decision 12): single-player now, built tidy, co-op later as its own mode.** The story is Danny's alone:
Kayla on the radio, his choices, his stay. Real co-op in Unreal means every system shares its state over a network:
the player, the creatures, the director, the puzzles, the doors, the saves and the cutscenes. Adding that to a
finished single-player game is close to a rewrite [from memory]. So:
- **Built tidy now.** Game state is kept in a few clear places, with no network code, and no single-player-only
  choice that would block co-op later (checklist line 92). The earlier game's clock was already per player, and the
  director keeps it that way.
- **Co-op later is its own project:** a separate mode, for example nights in the school with the floors and creatures
  already built, not the story campaign. It would take months of rework, and it is honest to say it may not happen.
- Building every system ready for co-op now (about a quarter more systems work, and slower testing at every step
  [estimate]) was the other option, and he did not choose it.

How co-op would work is still his to say (below).

---

## 13. What the owner does himself

1. Approve the installers and settings on his PC, and log in to the Epic Launcher and Fab to add the free packs on
   the weekly list to his library. The builder never asks for a password.
2. Keep the PC on and awake for long jobs, and say when he needs it for himself.
3. Play each build, ideally once a week. Record a short clip (Windows has a built-in recorder: Win + Alt + R) and
   answer the three to six questions.
4. Decide any spending, each time: the memory and the drive (recommended, his to buy), Fab packs, Higgsfield credits,
   voice or music services, off-site backup.
5. Decide whether and when to update the graphics driver (`pc.md` section 3).
6. Voice and act the people with friends when they want to record (his decision 8), and collect their signed
   releases, signed by a parent for anyone under 18. His ear judges the voices (`voices.md` part 9).
7. If he wants the songs to be truly his, write the lyrics.
8. Approve the editor connection once; look at the test Danny and Kayla, the hunter's three clips and each creature's
   look when asked.

---

## Depends on other documents

- **Story (`1-story.md`):** the cast and the speaking faces (canon 1); the script's lines, locked at the end of
  the grey pass; the New Game+ extras that head the cut list.
- **Creatures (`2-creatures.md`):** the creature side of the production table and the animation plan (its section 5,
  which agrees with this one); the numbers the simulated players must hit (its 4.4); the creature build order (5.3).
- **Systems (`3-systems.md`):** what the save format stores, the restart points, the presets (canon 11); the
  printed-paper system it asks for; the struggle.
- **World (`4-puzzles-world.md`):** every Layout JSON and the room-portal graph it exports; the puzzles, their value
  sets and their props for the asset census; Gus's Ears for the slice; the glyph decals in the alien kit.
- **Audio (`5-audio.md`):** the noise table (canon 7) the hearing subsystem reads; the listening sessions held on the
  builds; the overnight engine checks of the noise table.
- **Voices (`voices.md`):** how every voice is made, checked and judged; it wins on voices.
- **Cutscenes (`cutscenes.md`):** the twelve scenes, their staging, their fallbacks and their build order; the
  hand-back; it wins on cutscenes.

---

## Decided

- **The order of work** (his answer): the slice, Chapter 1 finished, the whole game in grey, then finishing chapter
  by chapter (sections 8 and 9).
- **Memory and backups** (his answer, decision 11, which took in this draft's old backup question): 32 GB and a
  backup drive recommended, his to buy; work starts on 16 GB; the drive is backup option A (sections 2 and 7).
- **Co-op** (his answer, decision 12): single-player now, built tidy, co-op later as its own mode (section 12).
- **Who voices and acts the people** (his answer, decision 8, which took in this draft's old performer question): he
  and people he knows record the main cast and act for a phone; the voices chosen before are the working track until
  then; library animation is every scene's fallback (sections 4 and 6).
- **Spending and a sale** (his answer, decision 10): maybe sold later, so every asset and tool is picked with terms
  that allow a sale; nothing is bought without his yes each time (section 5).
- **Where Danny starts again** (his answer, decision 2): the restart points are built into the save system and the
  layout data, on Story and Survivor (section 3).
- **Graphic catches** (his own pick, checklist line 14): the hunter's catch and the animals' mauls are graphic, in
  first person, with a cut-away option (section 3).
- **The quality target** (settled by the map): designed and judged on High at 1080p native or 1440p with DLSS, 60
  frames a second; Ultra holds nothing back and is for pictures (section 4).
- **The game's repository** (settled by the designers): a new private repository; the design documents move in after
  the slice (section 7).
- **How often he plays** (settled by the map): a build about once a week with three questions (section 1).
- **The cut order** (settled by the map): canon 15's list, each step put to him first; never anything he asked for by
  name (section 10).

## Open, to be put to him later

- **The faces:** whether Danny, Kayla and the other speaking faces read as their ages and as real people, judged when
  he sees the first-slice tests; if not, whether to allow a teen body pack from Fab (the price shown first) or keep
  the free tools with more shadow and fewer close-ups.
- **The first slice's verdict,** and at the end of week 8, if it has not passed, which option to take: a simpler look
  target, hardware or scope.
- **A Higgsfield credit budget,** set with him once its terms are read and before any picture ships.
- **The basement's colour** (owner-checklist line 9, marked to confirm). In the first slice he sees the shelter as
  built (gray-leaning, real faded colour, no orange wash over the frame) beside a variant with the old copper warmth in
  the lamps only, and he picks. Until then, "no orange wash over the whole frame" is the rule, and the stricter "no
  copper at all" waits for his word.
- **An off-site backup** (option B or C), once voices and hand-made art that cannot be rebuilt exist.
- **How co-op would work** when it comes (checklist line 92).
