# Stay Behind (working title): read this first

## Where the project stands

- This repository held **Rovloc**, a browser and Roblox horror game. On 19 November 2026 the owner replaced it with
  a new game, built in **Unreal Engine 5.8** on his own Windows gaming PC. The web and Roblox versions are frozen:
  no more work on them, nothing deleted, the website stays online. `web/`, `src/`, `site/` and `tests/` are that old
  game.
- The new game is mapped with the owner. His words are in `docs/design/requirements.md` **sections 7 to 10**:
  section 7 is his brief, section 8 every question he was asked and his answer, sections 9 and 10 what he said
  after the map (the voices, the cutscenes, his decisions).
- Order of work: research → the written game map → setting up his PC → one finished slice (the shelter, a stretch of
  tunnel, the hunter, the generator puzzle, one Dark Dweller) → Chapter 1 polished → the whole game playable in grey →
  finishing chapter by chapter.
- **Where it stands (21 November 2026):** the game map is written and he has answered its twelve decisions (the
  recommended option for each; `docs/design/requirements.md` section 10). The detailed design agrees with it. The
  session on his PC starts the first slice when he tells it to; nothing else in Unreal is built before the slice.

## The owner's standing rules

- **Ask, do not guess.** His words: "if you are tricky on anything ask me about it dont make guesses". A proposal
  that is clearly marked as a proposal is fine; a silent assumption is not.
- **Never buy, rent, subscribe to or publish anything.** Higgsfield credits: spend only what is already on the
  account, check the price first, and log every job in `docs/design/art/higgsfield/notes/ledger.md`. Renting a
  machine or topping up credits is his decision alone.
- **Secrets and privacy.** Never ask him to paste a password, token or key into chat, never print one, never commit
  one. His email, name and other personal details stay out of every request to an outside service.
- **Other games are models, not sources.** Take patterns (how a system or a scare works), never content (no
  character, creature, name, line, puzzle solution, layout, music or image from another game).
- **Assets** come from our own scripts or from sources whose licence allows a commercial game, with the origin
  recorded (page, author, licence, sha256). Never clone a real person's voice.
- **Top tier, his words first, the old game only remade.** His words (21 November): "Also try not to use stuff from
  the old game and if you do make it to how i want right now. Remember, i want the graphics sound everything top
  tier, comparable and even better then the games i listed, dont be lazy and make sure everything is perfect remake
  it iff you have too. I need the storyu and everything to match exactly as how i said." The bar is the games he
  named (Silent Hill 2 and Dead Space remakes, Alien: Isolation, Outlast 2, Amnesia: The Bunker; Red Dead Redemption
  2 for story; Counter-Strike 2 and GTA 6 for graphics): judge work against them and remake what falls short. Nothing
  from the old game goes in as it was. Where a design document and his own words differ, his words win; when unclear,
  ask him.
- **Horror:** graphic for the aliens and for Danny's own death scenes; what happened to the other students stays off
  screen.
- **Voices must sound like real people.** His words: "thhe voices gotta be really realisitc tell it to reallyt work
  on thaht". He already found one set of voices "a little robotic". No voice goes into the game until it passes the
  voice plan's checks and, for every main character, his own ear. The plan is `docs/design/unreal/voices.md`: read
  its short version before touching any voice.
- **Honest reporting.** Look at a picture before sending it to him. Say plainly what failed or was not checked. No
  placeholders in anything called finished. Write to him in plain words.
- **Git:** work on the branch `claude/coop-horror-game-arch-i9b7ko` unless told otherwise, and open a pull request
  only if he asks. No model names in commits or code.
- **Usage limits:** his plan has five-hour and weekly limits, and heavy multi-agent runs have used them up before.
  Keep runs sized to what the step needs and tell him when a limit stops work.

## Where things are

| Path | What it holds |
| --- | --- |
| `docs/design/requirements.md` | The owner's words and decisions, oldest to newest. Sections 7 and 8 are the new game. |
| `docs/design/project-summary.md` | One page: how the project began, which of his ideas carry over, and the new game as decided. |
| `docs/design/lessons-from-rovloc.md` | What he rejected and accepted in the first game and why, and how work was checked without eyes or ears. |
| `docs/design/unreal/owner-checklist.md` | Every wish he has stated, small ones included, numbered, each with a check. The game map and every build are checked against it. |
| `docs/design/unreal/voices.md` | The voice plan: the bar, the routes on his PC, the checks, where his ear decides, and the first proof. It wins on anything about voices. |
| `docs/design/unreal/cutscenes.md` | The twelve cutscenes shot by shot, how each is staged to look real, and the build order. It wins on anything about cutscenes. |
| `docs/design/unreal/game-map.md` | THE GAME MAP: story, creatures, play, puzzles, build plan and the twelve decisions put to him. Not approved until he says so; it wins over the drafts beside it. |
| `docs/design/unreal/design/` | THE DETAILED DESIGN, second edition: `canon.md` (one owner for every shared name and number: read it first), then `1-story`, `2-creatures`, `3-systems`, `4-puzzles-world`, `5-audio`, `6-production` (set-up, the first slice, milestones). `checklist-trace.txt` shows where each of his wishes is answered. |
| `docs/design/unreal/` | Also here: the research reports, the readings from his PC (`pc.md`), and `drafts/` (first drafts, reviews and the directors' cutscene takes, kept as history: never build from them). |
| `docs/design/art/higgsfield/` | His favourite monster picture (`picks/monster-favourite-B3.png`), the other design pictures, the art pack and the credit ledger. |
| `docs/design/monster/` | The hunter's earlier behaviour design with its measured numbers, and notes on its model. |
| `docs/design/voices/`, `tools/voices/` | The voice pipeline and the voices he chose (Danny 3, Kayla 3, a close dry whisper for the monster). |
| `docs/design/research/` | Earlier research on stalker AI and horror sound that still applies. |
| `web/sounds/` | A library of recorded CC0 sounds with their origins in `SOURCES.json`. |
| `archive/wip-2026-11/` | Restorable bundles of the unfinished web work, including the Blender scripts that build the monster. |

## His PC

- Unreal Engine 5.8.4 is installed through the Epic Games Launcher, and the game's folder is `C:\StayBehind`.
- A session that runs on that PC should: clone this repository into that folder, read the graphics card, memory and
  free disk, and install what Unreal C++ projects need (the list is in the Unreal production report under
  `docs/design/unreal/research/`), each with his OK. Then stop until the game map is approved.
