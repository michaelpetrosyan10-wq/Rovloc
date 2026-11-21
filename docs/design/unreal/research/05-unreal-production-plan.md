# Stay Behind: the Unreal Engine 5.8 production plan

Research report 05, 21 Nov 2026. Scope: how an AI coding agent (Claude Code), working through the command line in a project folder on the player's Windows gaming PC, can build this game in UE 5.8, with the player play-testing. Nothing under /home/user/Rovloc was changed.

How to read the marks: **[checked: S#]** means a source found today supports the claim (the numbered list is at the end). **[from memory]** means the claim is my own knowledge and was not re-checked; verify before relying on it. Two limits on the checking: Epic's documentation site (dev.epicgames.com) and pugetsystems.com could not be opened from this session (the network blocks them), so Epic's own pages were seen only through search-result summaries. Several 5.8 facts below therefore rest on forum posts and press coverage, and say so.

---

## 0. The findings that matter most

1. **UE 5.8 is out, 5.8.1 is its hotfix, and Epic calls 5.8 the last planned major UE5 release while it works on UE6** [checked: S1, S3]. Why it matters: it is a stable target for the whole project. Build on 5.8.x, take its hotfixes, and do not plan to move to UE6 partway through. Note for the lead: requirements.md section 7 mentions "Unreal Editor 5.9" on Higgsfield's rented machines. That does not fit Epic's roadmap. Whatever that is, the PC install should be the Launcher's 5.8.x.
2. **5.8 ships an experimental official MCP server inside the editor (the "open standard plugin for LLM systems")** [checked: S4, S5, S6]. Turn on the **Unreal MCP** and **All Toolsets** plugins, run `ModelContextProtocol.StartServer` in the editor console, then run `ModelContextProtocol.GenerateClientConfig ClaudeCode`. That writes a `.mcp.json` pointing at `http://127.0.0.1:8000/mcp`. Epic also publishes an "Unreal Engine Skills" plugin for Claude Code, with "hundreds of tools across 30+ toolsets". Why it matters: the agent can drive a running editor directly. The catches: it is Experimental, the editor must be open, the server is reachable only on the PC itself (localhost), and one 5.8 forum thread reports that the stable release did not expose its tools [checked: S7]. Treat it as a useful extra, not the foundation. The foundation is C++, Python and command-line builds, which do not depend on it.
3. **The compiler toolchain has a trap.** For 5.8, Epic's docs point to Visual Studio 2026 for general development [checked: S8]. The engine's preferred MSVC toolsets are 14.50 (VS 2026) or 14.44 (VS 2022), and the newer **MSVC 14.51 breaks 5.8 builds** (`hash_map` was removed). Epic's fix is in mainline but not in a 5.8 hotfix [checked: S9, S10]. Why it matters: a default VS 2026 install may bring in 14.51, and then the first C++ build fails. Install the 14.50 component explicitly.
4. **Lumen Lite is the new "Medium" Lumen.** It is a cheaper GI and reflection path that Epic says is "twice as fast" for those passes. In one independent test the whole frame ran about 25% faster, with "heavy flickering across almost all objects" [checked: S11, S12, S13]. Why it matters: it is the mid-card rung of our quality ladder, not the look we design for. Dark interiors with one moving flashlight are exactly where GI flicker shows, so test it in our own tunnels before trusting it.
5. **MegaLights is Production Ready in 5.8** [checked: S1, S11]. Why it matters: it is the biggest single win for this game. It lets many shadow-casting lights run at once: flickering tubes, emergency strobes, the flashlight, alien ship lights. Before MegaLights, an interior horror game had to ration shadowed lights.
6. **Megascans became free again on Fab on 5 Nov 2026,** under Fab's Standard License, usable in any engine and in commercial projects [checked: S14, S15]. Why it matters: photoreal concrete, grime, debris and "the stuff on the floor" are now free at scan quality. That closes most of the gap between "as real as can be made" and one agent with no art team.
7. **Epic's own samples come under a "UE-Only" licence: commercial use is allowed, but only in Unreal-based products.** This covers City Sample and the Game Animation Sample (500+ animations) [checked: S16, S17, S18]. City Sample got a major update in August 2026 with PCG rebuilds of the city made with LLM help through Unreal MCP [checked: S19, S20]. Why it matters: it is a ready, licensed starting kit for "a few dense city blocks", and the update shows the exact agent workflow we want.
8. **GitHub's free plan gives 10 GiB of LFS storage and 10 GiB of LFS bandwidth a month,** for personal accounts on the metered model (those created after 13 Feb 2025). Beyond that it costs $0.07 per GiB-month of storage and $0.0875 per GiB of bandwidth [checked: S21]. Why it matters: a photoreal UE project grows far past 10 GiB. Also, Fab and Epic content may not be redistributed, so it must never go in a public repo. The repo holds source, config, scripts and data; the heavy content lives on the PC with backups (section 7).
9. **Substrate materials are production-ready and on by default for new projects since 5.7** [checked: S22]. Why it matters: layered materials such as wet grime over paint over concrete, skin, and slime are first-class. Keep Substrate on.
10. **MetaHumans (5.6 and later) come under the Unreal Engine EULA.** They are free below $1M revenue and usable in any engine [checked: S23, S24]. Why it matters: the 5 to 8 survivors, Kayla and Danny in third-person cutscenes can be MetaHumans with no licence problem. Distributing MetaHuman Animator runtime models in a game is an open question on Epic's forum [checked: S25]; we do not need to.

---

## 1. The install list for his PC, in order

His PC's graphics card, memory and disk are still unknown (section 8 of requirements.md, "still open"). Read them first: `dxdiag /t`, `wmic`/`Get-CimInstance` for CPU, RAM and disks, `nvidia-smi` if it is an NVIDIA card.

**Hardware floor.** Epic recommends Windows 11, a quad-core CPU at 2.5 GHz or faster, 32 GB RAM, 8 GB or more of video memory and a DirectX 12 card [checked: S26]. Hardware-ray-traced Lumen needs the project set to SM6 [checked: S26] and a card with ray-tracing hardware: NVIDIA RTX 20 series or later, AMD RX 6000 or later, Intel Arc [from memory; a secondary source agrees: S27]. An NVMe SSD is strongly preferred [checked: S28]. If he has 16 GB of RAM, building will be slow and shader compiles will thrash; 32 GB is the real minimum for this work, and 64 GB is comfortable [from memory].

**Disk budget.** A minimal engine install is about 30 to 40 GB; with templates, feature packs and debug symbols it passes 100 GB [checked: S28; secondary sources]. Add the project (Megascans, MetaHumans and City Sample are each tens of GB in source form [from memory]), the derived-data cache (tens of GB) and packaged builds. **Plan on 500 GB free on an NVMe drive; 1 TB is comfortable.**

**Order:**
1. **Windows updated**, GPU driver current (DX12).
2. **Visual Studio 2026 Community** (free for an individual) [checked: S8]. Workloads: *Game development with C++* (tick its *Unreal Engine installer* and *Unreal Engine debugger and IDE tools* parts) and *Desktop development with C++*. Under *Individual components*, add **MSVC v14.50 x64/x86** explicitly; if 14.51 is installed, make sure 14.50 is present as well [checked: S9, S10]. Add a **Windows SDK**: see step 4. Add the **.NET Framework 4.8.1 targeting pack/SDK** [from memory; it appears in JetBrains' UE 5.6 prerequisites: S29]. UnrealBuildTool runs on the .NET runtime bundled with the engine, so no separate .NET 8 install is needed [from memory].
3. **Unreal Engine 5.8 (latest 5.8.x) from the Epic Games Launcher.** Install options: Core Components (required); **Starter Content** and **Templates and Feature Packs** (yes: they give the First Person template); **Editor symbols for debugging** (yes, though large: without them, crash call stacks in the logs are unreadable, and reading crash logs is how the agent diagnoses crashes) [from memory]; Engine Source (optional, useful for reading engine code); target platforms: leave Android, iOS and Linux unticked [from memory].
4. **Settle the Windows SDK by reading the engine.** After install, the agent reads `Engine\Config\Windows\Windows_SDK.json` and installs exactly the SDK and MSVC versions listed there. Sources disagree: an Epic forum reply says 10.0.22621.0 is right for 5.8.0, while the release notes are reported to list 10.0.26100.0 [checked: S9]. Do not guess; the file decides.
5. **Git for Windows** and **Git LFS** (`git lfs install`) [from memory].
6. **Blender** (for the creature pipeline and fixing models; it already runs as a Python module in the old pipeline), **7-Zip**, and optionally **RenderDoc** (GPU frame captures) [from memory].
7. **Claude Code** in the project folder. `GenerateClientConfig ClaudeCode` writes the `.mcp.json` into the project root [checked: S5].
8. **Plugins in the project:** Unreal MCP + All Toolsets (Experimental), Python Editor Script Plugin, Editor Scripting Utilities, Remote Control API, Movie Render Pipeline / Movie Render Graph, Functional Testing Editor, MetaHuman, Fab, and the upscaler plugins (NVIDIA DLSS / AMD FSR / Intel XeSS, according to his card) [from memory except MCP].

**Hardware ladder at 1080p and 1440p.** These are estimates [from memory]. No 5.8-specific GPU table could be opened. Measure on his PC with the first slice.
| Card class (examples) | Target | Settings |
|---|---|---|
| High: RTX 4080/5080 and up, RX 7900 XTX/9070 XT | 1440p, 60 fps | Hardware-RT Lumen (Epic/Cinematic GI), hit-lighting reflections, MegaLights, VSM high, volumetric fog high, TSR or DLSS Quality |
| Upper-mid: RTX 4070/5070, RX 7800 XT | 1440p with upscaling, or 1080p native | Hardware-RT Lumen High, MegaLights, VSM medium-high, DLSS/FSR Quality |
| Mid: RTX 3060/4060, RX 6600-7600, 8 GB | 1080p with upscaling, 60 fps | **Lumen Lite (Medium GI/reflections)**, MegaLights, VSM medium, fog medium, DLSS/FSR Balanced |
| Below that (GTX 10/16 series, no RT hardware) | Not a target | Software Lumen Lite might run, but the game's look is not designed for it |

---

## 2. What the agent can drive without clicking

**C++ builds (no editor needed).** `Engine\Build\BatchFiles\Build.bat StayBehindEditor Win64 Development -Project="...\StayBehind.uproject" -WaitMutex` builds the editor target. `RunUAT.bat BuildCookRun -project=... -platform=Win64 -clientconfig=Development|Shipping -build -cook -stage -pak -archive -archivedirectory=...` makes a playable build. `GenerateProjectFiles` is not needed for command-line builds [from memory]. One catch: when the editor is open with Live Coding on, an outside build of the same module is refused. The agent either closes the editor, or triggers Live Coding from inside (console `LiveCoding.Compile`) for function-body changes. Any change to a class layout (new UPROPERTY, new UCLASS) needs an editor restart [from memory].

**Editor Python, headless or in the editor.** `UnrealEditor-Cmd.exe StayBehind.uproject -run=pythonscript -script="Scripts/build_level.py"` runs with no window. `UnrealEditor.exe ... -ExecutePythonScript="..."` runs in a full editor, which is needed for anything that renders [from memory; S30 confirms `-ExecutePythonScript` is the working route for Movie Render Graph]. The Python API covers:
- levels: create and load maps, spawn, move, tag and delete actors (`EditorActorSubsystem`, `LevelEditorSubsystem`); add streaming sublevels [from memory];
- import: `AssetImportTask` and the **Interchange** API, with `is_automated` set on the import parameters so no dialog appears, a pipeline that can force skeletal meshes, and options for animation-only imports [checked: S31]; FBX, glTF and USD all come in through Interchange [from memory];
- materials: create Material Instances and set their parameters (`MaterialEditingLibrary`); building full material graphs node by node is possible but clumsy [from memory];
- data: create Data Assets, fill DataTables from CSV or JSON, save packages [from memory];
- Sequencer: create Level Sequences, bind actors, add tracks and keys and camera cuts, which is enough to rough out cutscene blocking [from memory];
- Blueprints: create a Blueprint asset that subclasses a C++ class and set its defaults and components. **Editing Blueprint graphs (nodes and wires) from Python is not practical** [from memory]. This is why logic lives in C++ (section 3).

**Unreal MCP (5.8, Experimental).** Setup is in finding 2. Tools come from the Toolset Registry: actors, Blueprints, Niagara, PCG and others, most written in Python [checked: S5, S6]. A third-party note says a few toolsets, screenshots among them, have no Python path [checked: S6, weak]. Puget Systems' July 2026 hands-on test found it helpful but "showed its limitations" by the third of four tests [checked: S32]; the details could not be opened. Epic's README warns that the plugin gives Claude "broad, live access to the running Unreal Editor" [checked: S6]. Two practical points:
(a) The server is at 127.0.0.1 on the PC. Commands the agent runs on the PC reach it, but a Claude client that is not on the PC does not. Test this once the PC is connected.
(b) **Fallback without MCP:** the **Remote Control API** plugin serves HTTP on port 30010 in the running editor. It can call any Blueprint-callable function, including running a Python command, so `curl`/Python from the shell can drive an open editor [from memory].

**Tests.** Automation tests written in C++ (`IMPLEMENT_SIMPLE_AUTOMATION_TEST`, or the Spec style) and **Functional Tests** placed in test maps run headless: `UnrealEditor-Cmd.exe StayBehind.uproject -ExecCmds="Automation RunTests StayBehind.; Quit" -unattended -nullrhi -nosplash -log`. Results go to the log and to a JSON/HTML report folder with `-ReportExportPath` [from memory]. **Gauntlet** (`RunUAT RunUnreal ...`) starts a packaged build, runs a scripted session (for example "walk the tunnel route and log frame times") and collects results [from memory].

**Pictures, so the agent can look at its own work.** This is the most important loop in the whole plan.
- In-game stills: start the level with `-game -windowed -ResX=1920 -ResY=1080 -ExecCmds="..."` and use `HighResShot 1` (or `2`), or a test that moves the camera to named "photo spots" and calls the screenshot function. Files land in `Saved/Screenshots/WindowsEditor/` [from memory]. The agent can open the PNGs and look at them.
- Screenshot comparison tests (Functional Testing) store golden images and flag changes [from memory].
- **Movie Render Graph / Queue for stills and clips:** pass `-LevelSequence=` and `-MoviePipelineConfig=` on the command line, or drive a queue from Python with `-ExecutePythonScript` in the full editor. MRG does **not** run in `-game` mode, and unattended renders have shown on-screen debug text in frames, so hide it [checked: S30].
- **Path tracer** reference stills (same sequence, path-traced render pass): ground truth to judge Lumen against [from memory].
- Performance numbers as text: `-csvprofile` / `csvprofile start|stop` produce CSV frame timings, and `-trace=default,gpu` writes Unreal Insights traces. The agent compares CSVs between builds [from memory].

**Logs.** `Saved/Logs/StayBehind.log` (editor and game), `Saved/Crashes/*` (call stacks, readable when editor symbols are installed), and UBT logs in `%LOCALAPPDATA%\UnrealBuildTool\Log.txt` [from memory].

**What still needs a human hand.** Logging into the Epic Launcher and Fab, and adding assets to the vault/library: Fab downloads go through the Launcher or the in-editor Fab panel [from memory]. Making MetaHumans in MetaHuman Creator: it is an interactive sculpt-and-blend tool [from memory]. The first approval of the MCP server in Claude Code [checked: S5]. Windows installers (UAC prompts). And above all, **playing**: feel, fear, timing, motion sickness, and whether a scare lands. No screenshot answers those.

---

## 3. Project architecture that suits an agent

**Principle: everything that decides behaviour or layout is text the agent can read, diff and regenerate; binary .uasset and .umap files are build products wherever possible.**

- **One C++ game module (`StayBehind`) plus an editor module (`StayBehindEditor`)** for the builders, validators and commandlets. Systems in C++: player character (first-person, with UE's First Person Rendering for arms and held items, production-ready since 5.7 [checked: S22]); Enhanced Input; interaction; inventory (a small backpack grid); battery/fuel/medicine economy; the noise system (every action emits a loudness at a place); hiding spots (Smart Objects); doors and locks; the puzzle framework; saves; the survivors' state; the quiet-choices ledger; the alien symbol learning [from memory for the UE systems named].
- **Creature AI:** StateTree for each creature kind, plus AI Perception (sight and hearing) and our own senses written as components, all reading one creature data asset each: speeds, hearing radius, "moves only when unseen" rule, light tolerance [from memory]. Carry over the THRESHOLD and presence numbers from docs/design/monster as data, not code.
- **Data in text.** DataTables imported from CSV/JSON in `Data/` (items, loot tables, puzzle definitions, dialogue lines and captions, sound cues map, quality ladder); Primary Data Assets for creature kinds and chapters; `Config/DefaultGame.ini` plus `UDeveloperSettings` classes for tuning. A commandlet `-run=ImportData` rebuilds every table from text, so text is the source of truth [from memory].
- **Blueprints only where they pay:** thin subclasses that hold mesh, sound and effect references for a C++ class; UI widgets (UMG) where visual layout is easier; one-off level scripting for scripted scares. No game logic in Blueprint graphs, because the agent cannot read or edit them as text.
- **Levels built by scripts from layout data.** `Layouts/*.json` (rooms, doors, stairs, vents, hide spots, lights, puzzle anchors) feed `Scripts/build_level.py`, which deletes every actor tagged `Generated` and rebuilds them. Hand-placed set dressing and lighting go in a **separate sublevel** that the builder never touches, so a rebuild does not wipe art. The builder also writes a **plan image** (top-down PNG) and a text summary, so the layout can be reviewed without the editor.
- **Streaming.** The school is a stack of interiors. World Partition's grid streaming is built for wide open land and gains little in a vertical building [from memory]. Use a persistent level per area (School, City, Mothership) with **streaming sublevels per floor/section**, loaded and unloaded at stairwells and doors. That keeps memory flat and gives clean seams for chapter autosaves. The city blocks can use World Partition (City Sample is built that way) [from memory].
- **Saves:** a `USaveGame` with an explicit version number; it records chapter, room, inventory, survivors' state, the choices ledger, the symbols learned and **the playthrough's puzzle seed** (codes and item places reshuffle per playthrough, so the seed must be saved). Slots on disk under `Saved/SaveGames` [from memory].
- **Puzzles as data plus small C++ pieces:** each puzzle is a definition (inputs, state machine, solution generator from the seed, hint stages for each puzzle-difficulty level). Every generated solution gets an automated check that it can be solved: a test generates 1,000 seeds and solves each with a scripted solver.
- **Testability:** each system has unit-level automation tests; each creature kind has a functional-test map (for example, "Listener hears a dropped bottle at 12 m, not at 25 m"; "Still One does not move while in view"); each chapter has a Gauntlet route run that logs frame times and checks no errors.
- **Co-op later: decide now.** Retrofitting network replication onto a finished single-player game is close to a rewrite in Unreal [from memory]. Two honest options: write the systems replication-aware from day one (authority checks, state in GameState/PlayerState; a modest extra cost), or tell the player plainly that co-op may never come. This needs his answer (see the final notes).

---

## 4. Graphics for dark interiors at the highest quality

| Feature | Recommendation for Stay Behind | Cost / note |
|---|---|---|
| **Lumen GI + reflections, hardware RT** | Default on capable cards; Lumen reflections with hit lighting on High/Epic, for wet floors and glass | Highest quality; needs SM6 + an RT card [checked: S26] |
| **Lumen Lite (Medium)** | Mid-card rung only | About 2x faster GI/reflection passes, about 25% frame gain in one test, visible flicker [checked: S12, S13] |
| **Software Lumen** | Fallback for cards without RT hardware | Weaker on thin walls; leaks light in dark rooms if walls are thin (keep walls 20 cm or more) [from memory] |
| **MegaLights** | On: flashlights, flicker groups, emergency lights, ship strips | Production Ready in 5.8 [checked: S1]; its noise reduction needs checking in very dark scenes |
| **Virtual Shadow Maps** | On; they pair with Nanite | Cost scales with lights moving and geometry changing; keep shadowed moving lights few outside MegaLights [from memory] |
| **Nanite** | Every static mesh (Megascans, the school kit, City Sample) | Lets dense scanned debris be used freely; the creature stays a regular skeletal mesh with LODs [from memory] |
| **Volumetric fog + local fog volumes** | Basement haze, ship mist; flashlight beams through fog | Medium cost; the strongest single "eerie" lever [from memory] |
| **Substrate** | On (default) | Layered grime, wet surfaces, skin [checked: S22] |
| **Path tracer** | Reference stills only | Offline [from memory] |
| **TSR / DLSS / FSR / XeSS** | Upscaling by card; frame generation optional | Plugins per vendor [from memory] |

**Horror-specific settings** [from memory, design advice]:
- **Fix the exposure.** Auto exposure "eats" darkness by brightening dark rooms. Use manual exposure, or a narrow auto range per area set in post-process volumes.
- The flashlight is the key light. Give it a light profile (IES) and a slight warm cast. Its battery level should dim and flicker it, which ties survival to the look.
- Film look: subtle film grain (UE 5.x has a physically based grain), mild vignette, a little chromatic aberration only during panic, and no heavy bloom. Pick one tonemapper and one colour grade per area and keep them in data.
- Darkness must still read: keep 2 to 5% fill in black areas (moonlight through windows, exit signs) so the player sees shapes and imagines the rest.
- **Hair and skin:** MetaHuman grooms (strand hair) are expensive. Use strands in cutscenes and cards/LODs in play [from memory]. The creature's old maps already carry thickness for light bleeding through ears and fingers; map that to Substrate subsurface or thin translucency.
- Gore (aliens, Danny's death scenes): skeletal mesh swaps plus Niagara blood and decals. Canned death animations are far cheaper than procedural dismemberment [from memory].

**Quality ladder (data in `Config/DefaultScalability.ini` overrides plus an in-game menu):** Ultra = HWRT Lumen Epic + hit-lighting reflections + MegaLights + VSM high + fog high + strand hair; High = HWRT Lumen High; Medium = **Lumen Lite** + MegaLights + VSM medium; Low = software Lumen Lite + fewer fog samples + card hair. Every rung is captured from the same photo spots, and the agent compares the stills.

---

## 5. Assets and their licences

- **Megascans (free again since 5 Nov 2026):** Fab Standard License, commercial use, any engine; the terms now also allow AI training [checked: S14, S15]. Listings were being updated up to 12 Nov; check that each asset actually shows as free before relying on it. **No redistribution** of the source assets, so they stay out of any public repo [from memory, the standard Fab licence pattern].
- **Other Fab content:** free and paid listings carry the Standard License or the "UE-Only" label. Read each listing [checked: S16].
- **City Sample:** UE-Only, commercial use in Unreal products allowed [checked: S16, S17]. The August 2026 update adds two PCG-built city levels (one full, one simplified), the PCG graphs as a plugin (`CitySamplePCG_demo`), building and road shape grammars, and five megaplant vegetation kinds. The original Mass traffic and crowds are not in the PCG level [checked: S19, S20]. Use it as the base for the few dense blocks, re-dressed as our city after the invasion (wrecks, fires, alien structures). **Check that its style fits the city in our story.**
- **Game Animation Sample:** 500+ animations with motion matching, updated for 5.7, UE-Only, commercial use allowed, retargetable [checked: S18]. Use it for the first-person body and the NPCs' locomotion. Redistributing it in source form is unresolved, so keep it private [checked: S18].
- **Lyra:** an "example project" under the licensed technology; usable as a base or for reference, not resellable as assets [checked: S33, weak]. It is a multiplayer shooter framework, heavier than we need, so take patterns only.
- **Paragon:** old posts say it is licensed for UE4 projects; its UE5 status is unclear [checked: S34, weak]. Its fantasy style does not fit. **Avoid.**
- **Valley of the Ancient and other Epic demos:** UE-Only Epic content [from memory]; not useful for this setting.
- **CC0 sources:** Poly Haven (textures, HDRIs, models), ambientCG (materials), Kenney (UI and simple sounds), the MakeHuman assets already in the creature pipeline [from memory, except MakeHuman CC0, which is recorded in model-notes.txt].
- **MetaHuman:** UE EULA from 5.6 on; free under $1M revenue; any engine [checked: S23, S24].
- **The engine itself:** 5% royalty on lifetime gross revenue above $1M; Epic Games Store sales are royalty-free [checked: S35]. Irrelevant for a game shared with friends.
- **Generated pictures (Higgsfield) as material.** Good uses: concept art and mood boards; **decals and printed matter** (posters for the evening event, flyers, notes, graffiti, alien symbol panels, which need our own symbol set drawn consistently); **sky and backdrop cards** (the mothership filling the sky as a matte card or a far mesh with a painted texture); hand-painted detail masks. Weak uses: full PBR textures. A generated picture is only an albedo and needs derived normal and roughness maps; it also tiles badly. Megascans does this job better and for free. Generated pictures are not HDR, so they cannot serve as lighting skies. [from memory] **Check Higgsfield's terms on commercial use of outputs** (not verified here).
- **Image-to-3D (Higgsfield has a 3D tool; Tripo, Meshy and Rodin are the common ones):** independent reviews agree it suits greybox, background and static props, and concept work. Characters need heavy cleanup, and the meshes often run to 500K+ triangles with poor UVs [checked: S36]. Nanite tolerates dense static meshes [from memory], so **a background prop is a fair use, but heroes and creatures are not.** Note: Higgsfield credits are almost zero (1.57 held), and renting or buying needs the player's yes.

---

## 6. Bringing over the old work

**Where it is.** The creature pipeline (`tools/art/creature/`) is **not on main**; it lives in `archive/wip-2026-11/monster-model.bundle` (checked in the repo). The layout export is `web/build/world.json` (4.2 MB, format 3). It holds `rooms` (rect x/z/w/d, floorY, height, wall/floor/ceiling material, acoustic, ambience), `doors`/`layoutDoors`, `stairwells`, `vents`, `lights` (955, with kind, colour, range, shadows, flicker groups), `anchors`, `zones`, `patrolLoops`, `levels` (origin and elevation per floor), plus every config table. The sound library is 325 WAV files, about 23 MB, under `web/sounds/sources/`, with traced CC0 provenance (checked in the repo).

**The creature.**
1. Restore the bundle into its own worktree, and extend `export.py` to write **FBX** (the most proven path for skeletal meshes into UE) and glTF as a second option. Interchange handles both [from memory].
2. Fix the skeleton for UE: a single root bone at the origin (add `root` above HumanoidRootPart), Z-up, X-forward, scale converted from studs to centimetres, "Add Leaf Bones" off [from memory]. **Scale needs a decision:** at Roblox's usual 1 stud ≈ 0.28 m [from memory], the hunter at 11 studs is about 3.1 m (2.5 m hunched). Confirm that against the design.
3. Import LOD0 (the Max master at about 425k triangles) through Interchange with `is_automated`, then attach High/Medium/Low/Potato as LOD1 to LOD4 by script [checked: S31 for automated Interchange; LOD attach from memory].
4. Maps: albedo, normal and roughness at 4k. **Flip the normal map's green channel:** Blender bakes OpenGL-style normals and UE expects DirectX-style [from memory]. The old albedo's alpha (flesh thickness) goes to a separate mask texture for Substrate subsurface/thin translucency.
5. Build an IK Rig and an IK Retargeter, so Game Animation Sample motion can drive the creature's crawl and walk as a base before hand-keyed and procedural layers [from memory].
6. Re-check the licence trail: MakeHuman/MPFB assets are CC0, and the tools are not shipped (model-notes.txt). That still holds.

**The floor plans.** `Scripts/import_layout.py` reads world.json (or a cleaned `Layouts/*.json` cut from it), converts studs to centimetres, and for each room builds floor, walls with door gaps, and a ceiling. Stage 1 uses cubes or Geometry Script meshes, tagged `Generated`. It places doors, stair volumes, vent entries, hide-spot markers, patrol splines and light actors (kind, colour, range, flicker group). Stage 2 swaps the cubes for a modular kit (wall, door frame, tile floor, drop ceiling at a 50 cm grid) without changing the data. **Expect the layouts to change:** they were built for a run-and-chase game, and slow survival play needs smaller, denser, more interconnected spaces with safe rooms and loops. Treat them as a starting blockout.

**The sounds.** A Python batch `AssetImportTask` turns each WAV into a SoundWave in a folder mirror. A CSV maps each sound to sound class, attenuation and concurrency settings. The creature's voice processing and the "whisper in taken people's voices" effect are built as MetaSounds. Room acoustics use Audio Gameplay Volumes / submix reverb per room, using the `acoustic` field the layout already carries [from memory]. Keep the WAVs and provenance files in git; they are small.

---

## 7. Version control

- **Facts:** GitHub Free gives 10 GiB of LFS storage and 10 GiB of LFS bandwidth a month, for personal accounts created after 13 Feb 2025; overage costs $0.07 per GiB-month of storage and $0.0875 per GiB of bandwidth, and uploads do not count toward bandwidth [checked: S21]. Older accounts may still be on the legacy 1 GB quota [checked: S21]. The account's billing page decides which applies. Today's Rovloc `.git` is already 661 MB (checked).
- **Plan:**
  - **A new repository for the Unreal project** (private), not the Rovloc repo.
  - **In plain git:** `Source/`, `Config/`, `Scripts/`, `Data/`, `Layouts/`, `Docs/`, `.uproject`, the creature pipeline scripts, the WAV sources and their provenance.
  - **In Git LFS, under a 10 GiB budget:** only our own hand-made `.uasset`/`.umap` files (thin Blueprints, data assets, the hand-dressed sublevels, UI), with `.gitattributes` set from day one.
  - **Never in git:** Megascans, Fab, City Sample, Game Animation Sample and MetaHuman content (re-downloadable, and the licences forbid redistribution); generated levels (rebuilt from data); `Binaries/`, `Intermediate/`, `Saved/`, `DerivedDataCache/`.
  - **Backups:** a nightly `robocopy /MIR` of the whole project to a second drive, plus a weekly off-site copy of the `Content/` that is not in git. Record the asset list (`Docs/asset-manifest.csv`: name, source, licence, version) so the project can be rebuilt from scratch.
- **Alternatives if LFS gets tight:** Perforce/P4 has a free tier for small teams and suits Unreal well; Anchorpoint and Diversion are game-oriented [from memory]. For one developer plus an agent, git for text plus backups is simpler.

---

## 8. Packaging a Windows build

`RunUAT BuildCookRun -project=... -platform=Win64 -clientconfig=Shipping -build -cook -stage -pak -iostore -compressed -prereqs -archive -archivedirectory=D:\Builds\StayBehind_<date>` [from memory]. `-prereqs` puts the prerequisites installer in the build so friends' PCs get the runtimes. **Size estimate:** a photoreal 8 to 10 hour game with Megascans and MetaHumans plausibly lands at **20 to 60 GB** after Oodle compression. Keep it down with texture LOD bias for 4k scans, virtual textures, and cooking only the maps that are used [estimate, from memory]. Sharing: a zip on cloud storage or a private itch.io page. Unsigned executables trigger Windows SmartScreen warnings [from memory]. Friends need a DX12 card that supports SM6; the quality ladder must default by detected hardware. Add a PSO pre-compile step on first launch with a progress screen, to avoid shader hitches [from memory].

---

## 9. The first slice (proves the look and the pipeline)

**Contents:** the basement safe room (generator, cots, the survivors as placeholder MetaHumans), a 60 to 80 m stretch of tunnel with two hide spots and a vent, the hunter walking a patrol spline and seeing and hearing the player, one real puzzle (for example, restoring the generator: find a fuse, read a gauge, set breakers in an order derived from a clue, with a seeded solution), Megascans dressing, the flashlight with battery, MegaLights flicker, volumetric fog, 20 of the carried-over sounds, one MetaSound creature voice, a manual save at the safe room.

**Steps (each ends with something the player can run or look at):**
1. Read his PC's specs; install per section 1; first C++ build of the First Person template, renamed StayBehind. *Proof: it builds from the command line and the log is clean.*
2. Project settings: DX12, SM6, HWRT Lumen, MegaLights, VSM, Substrate, Nanite; the plugins. Enable Unreal MCP and test it once (and the Remote Control fallback). *Proof: a list of the tools the agent can see.*
3. Photo pipeline: a `PhotoSpot` actor plus a command line that renders every photo spot to PNG, and an MRG and path-tracer reference render. *Proof: the agent shows stills.*
4. Blockout from layout data (basement section of world.json); regenerate twice to prove idempotence.
5. Core systems in C++ with tests: movement, interaction, inventory, flashlight/battery, noise, hide spots, save.
6. Creature import (section 6), StateTree patrol/investigate/chase, perception; functional tests.
7. The puzzle with its solver test; captions.
8. Art pass: Megascans and kit; lighting and exposure; fog; sound import and room acoustics.
9. Shipping package; the player plays it, **records a short video** and writes notes; the agent captures a CSV profile on each quality rung.

**Exit criteria:** the player says it looks and feels right; 60 fps at his target resolution on the High rung; a command-line rebuild of the whole slice from a clean checkout (plus restored Content) works.

---

## 10. Risks, stated plainly

| Risk | What happens | How to reduce it |
|---|---|---|
| **The agent cannot feel the game** | It can see stills and read numbers, but not fear, pacing, controls, audio mix or motion | Short play-test loops with the player; he records clips; a written feedback form per build (scariest moment, confusion, bugs); the agent never marks "feel" items done on its own |
| **Pictures mislead** | A good still can hide flicker, noise, LOD pops and temporal smear | Short MRG clips and in-game video captures from fixed camera paths, reviewed frame by frame; compare against path-traced references |
| **Iteration speed** | Editor restarts, C++ builds, cooks; a full cook of a photoreal project takes tens of minutes or more | Small modules; data-driven tuning (no rebuild); Live Coding for function bodies; iterative cooks; test maps per system |
| **Shader compile times** | The first open after importing Megascans or changing material features can take an hour or more [from memory] | Keep a local DDC on NVMe (Zen) [from memory]; batch material changes; warm the cache overnight ("I'll keep it on all day") |
| **Engine crashes and experimental features** | MCP and Nanite Foliage are Experimental [checked: S4, S22]; the editor can crash mid-script | Scripts idempotent and resumable; save often; the MCP path never the only path; editor symbols installed; crash logs parsed automatically |
| **Toolchain drift** | Visual Studio updates silently bring MSVC 14.51, and builds break [checked: S9, S10] | Pin 14.50 in `BuildConfiguration.xml`; do not take VS updates mid-milestone |
| **Usage limits and session breaks** | Long tasks stop partway; context is lost | Every task leaves a written state (a plan file, a checklist, commits); long jobs (cooks, renders) run as background processes that log to files |
| **Scope against the promise of "GTA 6 graphics" and Red Dead depth** | One agent and one play-tester cannot match the art and animation output of studios of hundreds | Say so to the player now; reach "as real as can be made" through scans, lighting and sound rather than through volume; the third-person cutscenes need body animation, which is the hardest gap (no motion capture); plan for fewer, better cutscenes |
| **Licence slips** | Fab/Epic content pushed to a public repo; unclear terms for generated media | The asset manifest; a pre-commit check that blocks Fab/Megascans paths; read Higgsfield's terms |
| **Disk and memory** | Tens of GB per pack; DDC growth | Disk budget per section 1; prune unused packs; a project-size report each week |

---

## What I could not verify

- Epic's own 5.8 pages (release notes, hardware table, MCP page): seen only through search summaries, because dev.epicgames.com is blocked from this session.
- The **exact list of tools** in All Toolsets, and whether it includes a viewport screenshot tool and a Python-execution tool.
- Whether the "5.8 stable MCP does not expose tools" bug [S7] is fixed in 5.8.1.
- The exact Windows SDK version for 5.8 (sources conflict; read `Windows_SDK.json`).
- How Lumen Lite is switched on beyond "Medium GI and reflections" [S13], and whether it needs RT hardware.
- Card-by-card frame rates for 5.8 (the ladder is an estimate).
- The licence pages of Lyra, Paragon (for UE5) and the Game Animation Sample in their current wording.
- Higgsfield's commercial-use terms for generated pictures and 3D.
- The release date: the brief says 23 June 2026, one news article says 17 June, and other coverage is dated 18 June. This does not matter for the plan.

## Sources

- S1 https://forums.unrealengine.com/t/unreal-engine-5-8-released/2729274 and https://www.unrealengine.com/news/unreal-engine-5-8-is-now-available
- S2 https://dev.epicgames.com/documentation/en-us/unreal-engine/unreal-engine-5-8-release-notes
- S3 https://forums.unrealengine.com/t/5-8-1-hotfix-released/2738864 ; https://wccftech.com/unreal-engine-5-8-lumen-lite-60-fps-switch-2/
- S4 https://dev.epicgames.com/documentation/en-us/unreal-engine/unreal-mcp-in-unreal-editor ; https://cryptobriefing.com/unreal-engine-5-8-mcp-server-support/
- S5 https://indieforgames.com/claude-unreal-engine-mcp/ ; https://github.com/cemdenizexe/ue58-claude-mcp-vibeue ; https://www.pixelsdesign.it/blog/unreal-engine-mcp-claude-code-explained.html
- S6 https://github.com/EpicGames/unreal-engine-skills-for-claude-code-plugin ; https://claude.com/plugins/unreal-engine-skills-for-claude-code ; https://deepwiki.com/EpicGames/unreal-engine-skills-for-claude-code-plugin
- S7 https://forums.unrealengine.com/t/5-8-stable-mcp-is-not-initializing-exposing-tools-was-no-an-issue-in-5-8-preview/2729455
- S8 https://box.co.uk/blog/unreal-engine-development-pc-specs ; https://dev.epicgames.com/documentation/ja-jp/unreal-engine/setting-up-visual-studio-development-environment-for-cplusplus-projects-in-unreal-engine
- S9 https://forums.unrealengine.com/t/ue-5-8-fails-to-compile-with-visual-studio-2026-hash-map-missing-source-fix/2732357 ; https://forums.unrealengine.com/t/ue-5-8-doc-mismatch-recommended-msvc-version-in-documentation-vs-engine-source-code/2734076 ; https://forums.unrealengine.com/t/ue5-8-0-windowssdk/2739689
- S10 https://forums.unrealengine.com/t/msvc-removes-hash-map-in-14-51/2743134 ; https://cesium.com/learn/cesium-unreal/ref-doc/developer-setup-windows-gotchas.html
- S11 https://www.guru3d.com/story/unreal-engine-58-debuts-lumen-lite-and-productionready-megalights/ ; https://overclock3d.net/news/software/unreal-engine-5-8-delivers-megalights-and-lumen-lite-with-60-fps-performance-targets/
- S12 https://pcgamer.com/software/unreal-engine-5-8-launches-with-improved-terrain-and-vegetation-tools-a-lumen-lite-option-for-faster-global-illumination-and-for-the-times-we-now-live-in-an-open-standard-plugin-for-llm-systems/
- S13 https://www.pcgamer.com/hardware/my-quick-test-of-lumen-lite-shows-that-its-probably-good-news-for-ray-traced-gaming-on-handheld-pcs-but-i-suspect-that-it-will-be-used-everywhere-because-of-the-pressure-developers-are-now-under/
- S14 https://digitalproduction.com/2026/11/13/quixel-megascans-free-again/
- S15 https://www.3dart.it/en/megascans-free-fab-2026/ ; https://blendedboris.com/our-blog/tpost/megascans-free
- S16 https://www.unrealengine.com/de/eula-reference/content-de ; https://forums.unrealengine.com/t/can-i-redistribute-epics-city-sample-buildings-in-my-commercial-package/2280146
- S17 https://forums.unrealengine.com/t/city-sample-in-eu-license-details/777090 ; https://www.cgchannel.com/?p=135314
- S18 https://www.unrealengine.com/blog/game-animation-sample ; https://www.cgchannel.com/2024/06/get-500-free-game-ready-animations-for-use-in-unreal-engine ; https://www.unrealengine.com/en-US/tech-blog/explore-the-updates-to-the-game-animation-sample-project-in-ue-5-7 ; https://forums.unrealengine.com/t/github-project-distribution-and-free-fab-assets/2665655
- S19 https://www.unrealengine.com/learning/city-sample-gets-a-major-update-with-pcg-and-unreal-mcp-workflows
- S20 https://dev.epicgames.com/documentation/unreal-engine/city-sample-pcg-and-mcp-server-interaction-in-unreal-engine ; https://automaton-media.com/articles/newsjp/20260828-463849/
- S21 https://docs.github.com/en/billing/concepts/product-billing/git-lfs ; https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-storage-and-bandwidth-usage
- S22 https://www.unrealengine.com/news/unreal-engine-5-7-is-now-available ; https://digitalproduction.com/2025/11/12/unreal-engine-5-7-foliage-pcg-and-in-editor-ai/ ; https://alternativeto.net/news/2025/11/unreal-engine-5-7-adds-procedural-content-generation-nanite-foliage-and-metahuman-updates
- S23 https://www.metahuman.com/en-US/license ; https://www.unrealengine.com/eula/mhc
- S24 https://unrealengine.com/ue-devs-can-now-choose-to-train-ai-models-on-their-projects
- S25 https://forums.unrealengine.com/t/licensing-question-shipping-metahuman-animator-markerless-motion-capture-runtime-models-in-a-steam-game/2839692
- S26 https://dev.epicgames.com/documentation/unreal-engine/hardware-and-software-specifications-for-unreal-engine?application_version=5.8
- S27 https://www.packtpub.com/en-at/product/unreal-engine-5-shaders-and-effects-cookbook-second-edition-4-9781837633081/chapter/chapter-4-playing-with-nanite-lumen-and-other-ue5-goodies/technical-requirements
- S28 https://unreal-engine.org/download.html ; https://www.techspot.com/downloads/6697-unreal-engine.html
- S29 https://www.jetbrains.com/help/rider/Unreal_Engine__Before_You_Start.html
- S30 https://forums.unrealengine.com/t/movie-graph-editor-python-from-cmd-line/2506983 ; https://forums.unrealengine.com/t/ue5-rendering-from-command-line-not-working-anymore/538400
- S31 https://forums.unrealengine.com/t/convert-static-to-skeletal-mesh-via-python-api/2153182 ; https://forums.unrealengine.com/t/interchange-framework-missing-references-on-animation-import-with-python-pipelines/2641326 ; https://forums.unrealengine.com/t/community-tutorial-automating-skeletal-mesh-imports-with-unreal-engines-python-api/2069661
- S32 https://www.pugetsystems.com/blog/2026/07/09/unreal-engine-mcp-hands-on-testing-ai-inside-the-editor/
- S33 https://forums.unrealengine.com/t/market-asset-with-lyra-game-as-base/639165
- S34 https://forums.unrealengine.com/t/can-you-use-the-paragon-assets-for-your-own-commercial-game/2077124
- S35 https://www.unrealengine.com/license ; https://developers.meta.com/horizon/documentation/unreal/unreal-oculus-license/
- S36 https://ziva.sh/blogs/best-ai-3d-asset-generators ; https://wavect.io/blog/ai-3d-model-generators-game-development-2026/ ; https://www.3daistudio.com/3d-generator-ai-comparison-alternatives-guide/can-ai-generate-game-ready-3d-models
