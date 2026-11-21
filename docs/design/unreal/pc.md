# The owner's PC: readings and what is installed for Unreal

Read from the PC itself on 21 November 2026 at about 01:50 UTC. This answers the "still open" line about his PC in
`docs/design/requirements.md`, section 8. The figures it is compared with come from
`docs/design/unreal/research/05-unreal-production-plan.md`, section 1 ("report 05" below).

Before this was committed, separate checks re-measured the PC's facts, looked up the driver independently, and read
the build tool's source a second time for the compiler conclusion in section 2. What they corrected is corrected
here.

## 1. The readings

| Part | What the PC has | Against report 05 |
| --- | --- | --- |
| Graphics card | NVIDIA GeForce RTX 5070, 12 GB of video memory | Good. Epic recommends 8 GB or more and a DirectX 12 card. Report 05 names RTX 20 series or later as the cards with ray-tracing hardware, and this is one. |
| Graphics driver | NVIDIA 621.01, released 21 October 2026 | A newer one exists (621.24, 12 November 2026). See section 3 before updating. |
| Memory | 16 GB (Windows shows 15.6 GB). One 16 GB DDR5 stick; the board has four slots, so three are empty | Below. Epic recommends 32 GB. Report 05's own estimate, from memory and not checked, is that 32 GB is the real minimum for this work. |
| Disk | One 1 TB NVMe SSD (WD Green SN3000), drive C:, 930 GB in size, about 600 GB free after the installs in section 2 | Good. Report 05 asks for 500 GB free on an NVMe drive. |
| Processor | AMD Ryzen 5 7500X3D, 6 cores, 12 threads | Good against report 05: Epic recommends four cores or more. Below for one later job: see the last point under this table. |
| Windows | Windows 11 Pro, version 26H2 | Good. Epic recommends Windows 11. |
| Screen | 2560 x 1440 at 270 Hz | Not part of the plan's list. |

What this means:

- **Graphics.** On report 05's hardware ladder the RTX 5070 is the "upper-mid" rung: 1440p with upscaling or 1080p
  native, hardware ray-traced Lumen at High, MegaLights, DLSS at Quality. The ladder is the report's estimate. The
  first slice measures it on this PC.
- **Memory is the weak part.** Epic recommends 32 GB and this PC has 16. Report 05 expects, from memory and not from
  a test, that builds will be slow and that the PC will run short of memory and stall while Unreal prepares its
  materials (shader compiling). How bad that is has not been tried: the editor has not been opened on this PC. When
  this was read, with ordinary apps open, only 1 to 1.5 GB was free, so expect to close other programs while the
  editor is open. Buying more memory is the owner's decision alone. Nothing here asks for it.
- **Disk.** About 600 GB free meets the plan. The engine takes 28 GB today. Report 05 expects it to pass 100 GB once
  templates and debug symbols are added, before the project's own content.
- **One later job asks for more.** For moving the characters' faces from a recorded voice or a video (MetaHuman
  Animator), report 04 gives a heavier recommendation: an RTX 3070-class card with 8 GB, 32 GB of memory and a
  16-core processor. This PC meets the graphics part and is below on memory and on cores. What that costs in
  practice has not been tried.

## 2. What is installed for Unreal C++ work

**Unreal Engine 5.8.4**, from the Epic Games Launcher, in `%USERPROFILE%\Epic Games\UE_5.8` (28 GB).

- Only the core is installed, plus the Fab plugin, which the Launcher put in with it. The Launcher's optional parts
  are not there: no "Templates and Feature Packs" (so no First Person template yet), no Starter Content and no
  editor symbols for debugging. Report 05 wants all three.
- The engine's headers, its build rules and the build tool's own source are there, which is what a C++ project
  compiles against. The engine's own C++ source files are not: `Engine\Source` holds no `.cpp` file. Report 05 lists
  Engine Source as an optional part.
- The Launcher's prerequisites step ran successfully.
- There is no sign that the 5.8 editor has been opened on this PC yet: there is no `5.8` folder under
  `%LOCALAPPDATA%\UnrealEngine`, no `Unreal Projects` folder in Documents, and Windows has no record of
  `UnrealEditor.exe` having run.

**Visual Studio Community 2026**, version 18.12, with the workloads "Desktop development with C++", "Game
development with C++" and ".NET desktop development". On 21 November 2026 (UTC), with the owner's OK, these were
added (about 4 minutes, 10 GB, no restart needed):

- MSVC Build Tools v14.50, and C++ ATL for v14.50
- Game development with C++
- Visual Studio Tools for Unreal Engine, and the debugger tools for Unreal Engine Blueprints
- .NET desktop development, and the .NET Framework 4.6.2 targeting pack
- Windows 11 SDK 10.0.22621

The list comes from the engine's own file, `Engine\Config\Windows\Windows_SDK.json`, as report 05 asks ("the file
decides"). One entry on the file's list was left out: the C++ Clang compiler. By the build tool's rules an ordinary
build uses the Microsoft compiler, and the Clang that Visual Studio 18.12 offers (22.1.3) is newer than the versions
the file prefers, which stop at 20. It can be added later with his OK.

Where the file and report 05 differ, the file was followed. The file asks for the .NET Framework 4.6.2 targeting
pack where the report said 4.8.1 (the report's figure was from memory). It also asks for the .NET desktop
development workload and for ATL, which the report did not list. On the Windows SDK the report found two sources
disagreeing (10.0.22621 or 10.0.26100) and left it to the file: the file names 10.0.22621 as its main version and
accepts anything from 10.0.19041 upward, so both are in range.

**Compilers.** The engine's file prefers MSVC 14.50 first and 14.44 second. It bans builds of 14.50 below 35723,
builds of 14.44 below 35211, and all of 14.39 to 14.43. Three compilers are on the disk:

| Folder under `VC\Tools\MSVC` | Compiler build | By the engine's rules |
| --- | --- | --- |
| `14.50.35717` | 14.50.35740 | First choice, and not a banned build. By the build tool's rules this is the one it picks. Has ATL. |
| `14.44.35207` | 14.44.35230 | Second choice, accepted. It was already there with Visual Studio. No ATL. |
| `14.52.37025` | 14.52.37029 | Not on the engine's list, so the build tool ranks it last. It is Visual Studio's newest and its own default. It no longer ships the `<hash_map>` header, and report 05 says that removal breaks 5.8 builds. |

Which compiler the build tool picks was worked out by reading its rules, twice and independently, not by running a
build. Epic built this engine's own modules with 14.44.35229. When it builds the packaged game, the build tool
refuses a compiler from an older family than that, so 14.50 passes.

**Other tools.**

- Windows SDK: 10.0.22621 (the engine's main version, and by the build tool's rules the one it uses when it is
  installed) and 10.0.26100 (inside the range the engine accepts).
- .NET: the engine brings its own .NET 10 and uses it. Also on the system are .NET SDK 6, 8 and 11; version 11 came
  with the .NET desktop workload.
- Git 2.56 with Git LFS 3.8.1.
- Not installed, and not needed for C++ builds: Blender, 7-Zip and RenderDoc. They are on report 05's install list
  (Blender for the creature models, RenderDoc as an optional graphics tool) and wait until the model work starts.

## 3. The graphics driver

Checked on 21 November 2026 (UTC) against NVIDIA's own driver list for this card on Windows 11, NVIDIA's driver notes
and NVIDIA's forum. Nothing was downloaded or installed.

- **Installed:** GeForce Game Ready Driver 621.01, which NVIDIA released on 21 October 2026. (The driver file itself
  is dated 19 October.)
- **A newer regular driver exists:** 621.24, released on 12 November 2026, as a Game Ready Driver and as a Studio
  Driver. Between the two came 621.14, on 4 November.
- **An optional "hotfix" driver is newer still:** 621.35, released on 20 November 2026 and built on 621.24. NVIDIA
  describes hotfix drivers as beta and optional, and says the safest choice is to wait for the next regular driver.

Two known faults bear on whether to update:

- The installed 621.01 can make video playback freeze or go black on some RTX 50 series cards. NVIDIA lists that as
  fixed from 621.14 onward.
- Users and the press report that 621.14 and 621.24 write to the disk constantly while the PC sits idle, through a
  log file named `nvlog.nvlgstg`, by up to about 30 GB an hour in the worst report, and that 621.01 does not. The
  fix is the one change in hotfix 621.35. An NVIDIA staff member wrote on NVIDIA's forum that RTX 50 series cards
  are not affected; a user with an RTX 5090 answered that his was. Neither claim could be checked.

On this PC, with 621.01, that disk fault is not happening: NVIDIA's display service had written about 6 MB in the
five and a half hours since it started, and the log file was 0.14 MB.

Whether and when to update is the owner's decision. This section goes out of date as soon as NVIDIA releases
another driver.

Sources:

- NVIDIA's driver list for this card:
  `https://www.nvidia.com/Download/processFind.aspx?psid=131&pfid=1070&osid=135&lid=1&whql=&lang=en-us&ctk=0&qnfslb=00&dtcid=1`
- NVIDIA's notes for 621.14, which list the video fault as fixed: `https://www.nvidia.com/en-us/drivers/details/283968/`
- NVIDIA's hotfix announcement and the replies under it:
  `https://www.nvidia.com/en-us/geforce/forums/game-ready-drivers/13/593169/announcing-geforce-hotfix-driver-62135-released-11/`
- A press report of the disk writes:
  `https://wccftech.com/nvidia-gpu-drivers-reportedly-writing-up-to-30gb-per-hour-to-ssds-echoing-amds-recent-driver-bug/`

## 4. Still to do on this PC, once the game map is approved

- In the Epic Games Launcher, tick three more parts of the engine's own install: "Templates and Feature Packs",
  "Starter Content" and "Editor symbols for debugging". Report 05 lists them as install options of the engine, not
  as things to buy. Their names, and that they cost nothing, were not checked in the Launcher on this PC. The
  symbols make crash reports readable. With all three, report 05 expects the engine to grow from 28 GB to more than
  100 GB. The owner ticks them, or gives his OK.
- Engine Source, only if reading or stepping through the engine's own code is wanted. Report 05 calls it optional.
- Blender, 7-Zip and, if wanted, RenderDoc when the model work starts, each with his OK.

For whoever sets up the first build:

- With no setting at all, the build tool already picks 14.50 and ranks 14.52 last. A Visual Studio update that adds
  a newer compiler does not change that.
- If the compiler is pinned, as report 05 advises, the value has to be the folder's full name, `14.50.35717`. A bare
  `14.50` is not accepted and stops the build, and the value `Latest` picks 14.52. Here the pin does one thing: it
  turns a missing 14.50 into an error instead of a quiet move to 14.44.
- Do not set the project's compiler to Visual Studio 2022. The 14.44 compiler is on the disk, but Visual Studio 2022
  itself is not, and the build tool then stops and asks for it.
- Report 05 advises against taking Visual Studio updates in the middle of a milestone.
- The first build's log should have a line of the form "Using ... 14.50.35740 toolchain ... and Windows
  10.0.22621.0 SDK". (The last number of the toolchain rises if Visual Studio services that compiler.) That line is
  the proof of the compiler part above.

## 5. Not checked

- No Unreal project exists and nothing has been built, so a C++ build is not yet proven on this PC. The first build
  of the first slice is the proof.
- Frame rates. Nothing has been measured.
- Whether hardware ray tracing works on this card. No test was run.
- Whether Windows itself is up to date. Report 05 puts "Windows updated" first in its install order.

## 6. How the readings were taken

So that a later reading can be compared with this one:

- Graphics card and driver: `nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv`. Windows' own
  `Win32_VideoController` gives the screen mode, but it reports the video memory wrongly for this card (it stops at
  4 GB) and shows the driver's date converted to local time, which can move it by a day.
  `pnputil /enum-drivers /class Display` gives the date as the driver states it.
- Memory: `Get-CimInstance Win32_ComputerSystem` for the total, `Win32_PhysicalMemory` for the sticks and
  `Win32_PhysicalMemoryArray` for the number of slots.
- Disk: `Get-CimInstance Win32_LogicalDisk` for size and free space, `Get-PhysicalDisk` for the model and type.
- Visual Studio: `vswhere.exe -all -products * -include packages -format json`, found under
  `Program Files (x86)\Microsoft Visual Studio\Installer`.
- Compiler builds: the product version of `cl.exe` in each folder under `VC\Tools\MSVC`. The build tool checks a
  compiler against the banned list by that number, not by the folder's name. That is why the folder named
  `14.44.35207` holds an accepted compiler: the build inside it is 14.44.35230.
- The engine's rules: `Engine\Config\Windows\Windows_SDK.json`, and the build tool's source under
  `Engine\Source\Programs\UnrealBuildTool` (`Platform\Windows\MicrosoftPlatformSDK.cs` for how a compiler and a
  Windows SDK are picked).
- The compiler Epic built the engine with: the `ToolChainVersion` line of any `.precompiled` file under
  `Engine\Intermediate\Build\Win64`.
- Whether the editor has run: the `5.8` folder under `%LOCALAPPDATA%\UnrealEngine`, the `Unreal Projects` folder in
  Documents, and Windows' prefetch records.
- Disk writes by NVIDIA's display service (section 3): the `WriteTransferCount` of `NVDisplay.Container.exe` from
  `Get-CimInstance Win32_Process`, read twice, and the size of
  `C:\ProgramData\NVIDIA Corporation\nvtopps\nct\nvlog.nvlgstg`.
