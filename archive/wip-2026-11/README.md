# Unfinished work from the web version (16 to 18 November 2026)

The web version of the game was stopped on 19 November when the game moved to Unreal Engine. These files hold the
work that was in progress at that moment and had not been merged. None of it passed the full test run; treat it as
reference material and as a source of parts, not as finished code.

Each `.bundle` is a git bundle with one squashed commit on top of a commit that is already in this branch's history.
The `.log.txt` beside it lists the original commits it squashes.

| Bundle | What it holds |
| --- | --- |
| `monster-model` | The monster as a skinned model built by Blender scripts from one master (five levels of detail), its skin, hood and hands, the picture tool; the start of projecting the Higgsfield face and hand pictures onto it |
| `monster-behaviour-v3` | "The Lurker": a per-player interaction clock, strain and backstage, chase tokens and near misses, the presence simulator and its checks |
| `graphics-look2` | The film camera, lit air, wet reflections, scanned materials, the modelled hand and torch, modelled lockers, the start of the painted backdrops |
| `stage-auditorium`, `stage-roof-belltower`, `stage-city-rooftops`, `stage-airport` | The four later stage maps as Luau builders with their tests |
| `people-spike` | Realistic people built from the MakeHuman CC0 base with Blender scripts |
| `video-cutscene-player` | The start of a video cutscene player for the website |

To bring one back as a branch:

```
git fetch archive/wip-2026-11/monster-model.bundle archive/monster-model:restored-monster-model
```

Notes that explain this work are in `docs/design/monster`, `docs/design/look`, `docs/design/voices` and
`docs/design/art`.
