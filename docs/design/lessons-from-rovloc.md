# Lessons from the first game (Rovloc)

What the owner rejected, what he accepted, and how work was checked when the builder could not see, hear or play it.
Read this before making anything he will look at or listen to. His exact words, with dates, are in
`requirements.md`.

## What he rejected, and what it means

| What was shown | His words | The lesson |
| --- | --- | --- |
| A monster with a big round mask on a thin body | "This is not scary the face is supposed to be slim like body" | The head and face are as narrow as the body. Scary comes before odd. |
| A scary face on an ordinary body | "the body is not scary tho" | The body has to frighten by itself: how it stands, how it moves, its hands. |
| A monster that appeared by teleporting behind him | "i never really see the monster unless he like tp's behind me ... when he tps i can js run" | He wants to see and hear it around him. Appearing from nowhere reads as cheap. |
| One real encounter every few minutes | "4 minutes too much maybe one every 20 sec or 15 if sprinting and 30 sec if walking and like 1 min if crouching" | Many small moments, few attacks. Loud movement brings it sooner. |
| Sounds made by synthesis | "this vibecoded high pitched sound"; "wooden thing like the clicks"; "its all lame sounds" | Recorded sounds only, with weight and room. Every sound counts, down to glass and doors. |
| The first voices | "a little robotic" | The cause was flat source voices, pitch shifting and time-stretching. Lively source voices and no such processing fixed it. |
| Simple, blocky people | "make them look like actual people"; "realistic realistic looking horror game" | People must look real, or be kept out of the picture. |
| An orange basement, checkerboard floors, then a look that was gray all over | "copper looking"; "By gray feel i didn't mean everything look gray" | Dark and ruined, gray-leaning, with real faded colour. |
| Waiting too long in the opening | "i can only get out of the bin until a long time" | Hand control to the player quickly. |
| An open, empty roof | "kinda boring" | Every part needs something to do and a moment to remember. |

Two more lessons came from reviewers asked to judge pictures as he would. Early passes of the monster model were
called a bird, a plague-doctor mask and a toy, and its hands paddles or a leaf, because the side view and the hands
had been neglected for the front view. Early graphics passes were called "the same as before": he reacts to large,
visible changes (light in the air, real materials, real props), not to small refinements.

## What he accepted

- The picture `art/higgsfield/picks/monster-favourite-B3.png` for the hunter: "this image is my favorite".
- The close, dry whisper for the monster's voice, and voice 3 for Danny and for Kayla.
- Recorded sounds from traced CC0 sources.
- Questions with a few options and a recommended one. He types his own answer when he cares about the point.
- Pictures and playable builds sent as progress, and a plain estimate of when the next one comes.

## How work was checked without eyes, ears or hands

- **Pictures:** render the same fixed views each time, look at them yourself, then have a reviewer with fresh eyes
  judge them as the owner would, with a score out of ten, before anything is sent. Send only what stands up, beside
  his reference picture, and say what is still wrong.
- **The monster's behaviour:** simulated players with different habits (one sprints, one walks, one crouches, one
  hides) ran thousands of floors against targets: how often it is noticed, how often it chases, how often it
  catches. Fairness rules were tested the same way: a warning before every catch, never faster than a sprinting
  player outside a scripted chase, a hiding place near every objective.
- **Sound:** loudness and spectrum measurements for every sound, and a page where he could play the sounds before
  they went into the game.
- **Voices:** speech recognition on every line to prove the words are clear, and audition pages where he picked by
  number.
- **Everything:** tests on every change, and one full run on a quiet machine before anything was called ready.

## Working inside his limits

- His plan has five-hour and weekly usage limits. Several long agent jobs at once have emptied a window in under an
  hour, and the weekly limit has stopped all work for days. A long job keeps a progress file so that it can continue
  after a cut.
- Higgsfield is on the free plan with 1.57 credits left. A picture costs about 0.12 credits, a spoken line 0.15, a
  five-second video clip 35, a 3D model 9 to 44, and a rented machine 71 to 98 an hour. The picture model that works
  on the free plan and the prompts that worked are in `art/higgsfield/notes`.

## Mistakes to avoid repeating

- Reporting a job as running when its agent had stopped. Check before reporting.
- Giving a date that a usage limit then broke. Give a range and say what it depends on.
- Sending a picture that was not good enough. Hold it, and say why.
- Working on the front view of a model and neglecting its side, its hands and its movement.
