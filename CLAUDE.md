# Stay Behind (working title): read this first

## Where the project stands

- This repository held **Rovloc**, a browser and Roblox horror game. On 19 November 2026 the owner replaced it with
  a new game, built in **Unreal Engine 5.8** on his own Windows gaming PC. The web and Roblox versions are frozen:
  no more work on them, nothing deleted, the website stays online. `web/`, `src/`, `site/` and `tests/` are that old
  game.
- The new game is mapped with the owner. Before anything else read `docs/design/requirements.md` **sections 7 and
  8**: section 7 is his brief in his own words, section 8 is every question he was asked and his answer.
- Order of work: research (`docs/design/unreal/research/`) → a written game map he approves → setting up his PC →
  one finished slice (a basement safe room, a stretch of tunnel, the hunter, one puzzle) → the chapters.
- **Nothing is built in Unreal until he has approved the written game map.**

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
- **Horror:** graphic for the aliens and for Danny's own death scenes; what happened to the other students stays off
  screen.
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
| `docs/design/unreal/` | The new game's research, and the game map once it is written. |
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
