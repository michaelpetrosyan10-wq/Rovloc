# Monster v3 spec: review as the player and as a horror designer

Reviewed: `/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/mv3/monster-v3-spec.md` ("the spec").
Read with it: `docs/design/research/monster.md` (2.10, 3, 4), `docs/design/requirements.md` (6), `docs/MONSTER.md`
(2, 3, 4, 8, 9, 11, 14 to 20), and, to check single claims, `src/ReplicatedStorage/Shared/Config/GameConfig.luau`,
`src/ReplicatedStorage/Shared/Config/CreatureConfig.luau`, `web/src/creature/index.js`, `web/src/engine/player.js`,
`web/tools/presence-sim.mjs`, `web/sounds/cast.json`.

Nothing was run. Every timeline below is arithmetic on the spec's numbers. Where I estimate what the geometry will
allow, I say "estimate"; the simulation has to confirm it. A number marked **[mine]** is my proposal, not a fact.

Source marks: **[spec x]** = that section of the spec; **[M x]** = `docs/MONSTER.md`; **[R x]** =
`docs/design/research/monster.md`; **[Q]** = `docs/design/requirements.md` section 6; **[G]** = `GameConfig.luau`.

---

## 0. Verdict

The frame is right: a clock driven by how the player moves, a leash, strain, chases on a token. The walker and the
croucher get what the player asked for. Four things would make the player say "this is not what I meant":

1. **The sprinter, which is how he most likely plays, gets the weakest version.** Stage 1 has two things that can
   reach a running player: his far footsteps and the teleport warning. The sprinter's three minutes are "steps,
   flicker, steps, flicker". On Nov 15 he complained about exactly this: "i never really see the monster unless he
   like tp's behind me ... when he tps i can js run its not really that good" [Q]. And with stamina in the sum the
   measured gap is about 20 to 23 s, not his "15 if sprinting" (finding P1, P2, P3).
2. **He is never quiet.** The heartbeat and breathing switch on within 45 studs straight of him [M 11;
   `web/src/creature/index.js` `nearFloor`; `CreatureConfig.Presence.Audio.NearRadius` 45] and the spec keeps that
   unchanged [spec 2.4] while it moves him to 25..55 studs walked for good [spec 2.2 `Leash`]. The player's own
   heart will beat for the whole floor. The spec removed the rattle for drowning the cadence and left in the louder
   offender (P4).
3. **Once a player understands the token, the fear is gone for two and a half minutes at a time.** After any chase
   nothing can down him for 150 s [spec 5.6, `Chase.Refill`], and in that time the monster is also deaf to him
   [spec 5.3]. He can burn the token on purpose from a safe spot and then sprint the objectives (P6, P7).
4. **Careful play is punished in three places**: the director may send a lethal sniff to a player who is hiding
   (P8), hiding from a peek in his sight spends the token on a hiding watch (P9), and an unspent token makes the
   director push teleports at the quiet player (P10).

The things he asked for by name and does not get in stage 1: the holes (stage 2), the voice (off until files
exist), and louder footsteps "so people know when hes around" [Q, Nov 15], which the creeping gait works against
(P16, P17, P18).

---

## 1. The first three minutes, on paper

Shared timeline, Standard, the first floor of a run, from the spec:

| t | What the rules allow | Source |
|---|---|---|
| 0 | floor active; spawn hold; every clock starts at rate 1/30, `due` 0; bucket at 0.4 token | [spec 3.1, 5.6]; `FloorGrace` 20 [spec 2.4] |
| 20 s | the first interaction is owed to everyone (`due = max(due, theta)`); it must be heard only | `Clock.FirstHeard` 20 [spec 2.2, 3.2] |
| 40 s | seen and close interactions allowed | `Clock.FirstSeen` 40 |
| 65 s | first C3 (warned teleport) allowed | grace + 45 s [M 14 rule 4; spec 4.12] |
| 90 s | first chase token, solo | `Chase.First` 90 [spec 5.6] |
| 240 s | second token, solo | `Chase.Refill` 150 |

Stage 1 types [spec 9]: H1 far steps, H2 behind the wall, H4 locker nudge, S1 glimpse, S2 peek, C1 shadow, C2
pass-by, C3 warned teleport, C4 sniff, plus the Approach teleport and the near miss. H3, S4 (holes) are stage 2; S3
(vantage), F (fake), H5 (voice hook) are stage 3.

### 1.1 Solo sprinter

**How often.** Nobody sprints without stopping. A full meter lasts 100 / 7 = 14.3 s; it comes back at 14 a second
after 1.2 s [G `StaminaSprintDrain` 7, `StaminaRegen` 14, `StaminaRegenDelay` 1.2], so 8.3 s of walking refills
it. A person who empties and refills: 63 % sprint, 37 % walk. Clock rate = 0.63 / 17 + 0.37 / 30 = 0.0494 a
second: **one interaction every 20.2 s**. The simulation's own Sprinter is worse: after its first empty meter it
sprints again from 25 (`presence-sim.mjs` `STAMINA_RECOVERED` 25), which is 3.6 s of sprint to 3.0 s of walk, 54.5 %
sprint: 0.545 / 17 + 0.455 / 30 = 0.0473: **21.2 s**, before any stop at an objective (class Stand, 40 s). So the
spec's own gate "Sprinter median 15..20 s" [spec 8.3] is missed by its own bot, and the builder will have to change
`Gap.Sprint` anyway. His words were "one every 20 sec or 15 if sprinting" [Q]: 15 while he is actually sprinting.

**What.** Timeline with a 20 s mean gap: about t = 20, 40, 60, 80, 100, 120, 140, 160, 180: **8 to 9 interactions**.
By weight at the start of a floor (progress 0, [spec 5.2]): H1 15, H2 12, H4 12, S1 16, S2 8, C3 5 (after 65 s);
shadow needs a player moving 3..14 [M 16.3] and pass-by one at 6 or less [M 16.4], so neither fits a runner. But the
weights are not what he gets, because of where the player is when the plan is ready:

- H2, H4, S1, S2 are planned against where the player is now and give him 8 or 20 s to walk there at 7 or 9
  [spec 2.2 `Setup`, `Leash.CreepPace`, `StepPace`]. A sprinter covers 19 x 8 = 152 studs in 8 s. `PlanAhead` is 6 s
  [spec 2.2]: 114 studs. The glimpse's crossing is 30..70 ahead [M 16.2]: the runner is past it in 1.6 to 3.7 s.
  Estimate: against a player who is sprinting, these four reach nobody most of the time; each failure costs 6 s
  (`Clock.Retry`).
- H1 "from where he is" works if the ear is within 80 straight [spec 4.1]. But H1 has a 20 s cooldown and no type
  may play twice running on a player [spec 5.2 timers], while a sprinter's gap is 13.6 to 20.4 s (17 x 0.8..1.2). So
  H1 can be at most every other interaction, and the spec does not say whether the fallback H1 [spec 3.4 step 5] is
  exempt from "not twice running"; section 8.3 says "never".
- That leaves, for the slots between two H1s: the Approach teleport (only when he is more than 90 walked away,
  cooldown 25 s [spec 2.4, 3.4]) and C3 (cooldown 60 s, after 65 s).

So one of two things happens. If the leash holds (he is within 55 walked), the Approach is not allowed and every
second slot fails: the real gap is near 34 s. If the leash breaks, the cadence is kept with teleports. And the leash
does break: a sprinter averages 0.63 x 19 + 0.37 x 11 = 16 studs a second; he creeps at 7 and hurries at 9
[spec 2.2 `Leash`]. From 55 walked to 90 walked takes about 5 s of running away from him.

**Most likely log (estimate):** 20 far steps; 40 teleport flicker and hiss (Approach); 60 far steps; 80 flicker and
hiss; about 92 his ears switch on with the first token, he hears the sprint (heard at 60 [M 3.1]) and a chase
starts: screech, 12 s at most [spec 5.6, 4.15]; then about 35 s backstage with one far-steps moment
[spec 3.3]; 145 far steps; 165 C3 or flicker again.

**How it feels.** Busy, but thin: two sounds carry about three quarters of it. The chase at a minute and a half is
good. What is missing is him, seen, without a teleport. This is the player's Nov 15 complaint with a shorter timer.
Also each Approach and C3 stutters the target's torch and the lights [spec 4.12; M 7.3, 15.3]: a runner in a dark
maze gets his torch flickered every 25 to 40 s.

**Does it match "15 if sprinting"?** No: 20 to 23 s measured, and only if teleports fill the gaps.

### 1.2 Solo walker (11 studs a second, torch on)

**How often.** 30 s: t = 20, 50, 80, 110, 140, 170: **6 interactions** (5 to 7 with the plus or minus 20 % draw).

**What.** Weights at progress 0 [spec 5.2, `FitOf.Walk` = C1, S2, H2]: H2 24, S2 16, H1 15, H4 12, S1 8, C1 5,
C3 2.5: heard 62 %, seen 29 %, close 9 %. Everything can be set up against a walker. A likely log: 20 rattle and
wet breath through a wall (H2); 50 the mask at a doorway (S2, the first seen one, allowed from 40); 80 far steps;
110 a locker door in the next room (H4); 140 he crosses ahead (S1) or follows behind (C1); 170 rattle again.

**How it feels.** This is the profile the spec serves best, and it is what the player described: about every half
minute, mostly not attacks, five different things in three minutes. "30 sec if walking": **yes**.

Three notes:
- The peek at about 50 s stands 30..70 away facing him [M 16.1]. With the torch on, looking at him for 1.0 s within
  45 is the stare [M 3.3]. Before 90 s there is no token, so the first peek a new player looks at ends in a screech
  and a six-stud lunge [spec 4.16, 5.6]. Harmless, and a fair lesson. After 90 s the same look is a real chase. Good.
- A walker who never stares and makes no loud noise has strain near zero for ever (the spec's own check: "never
  backstage" [spec 3.3]). His floor is a flat rhythm, one thing every 24 to 36 s, with no lull at all until the
  director forces a token spend (P5).
- A walker going one way down a tunnel also outpaces him: 11 against 7 creeping, 9 hurrying. About 16 s of straight
  walking takes him from mid-band (40) past 90 walked: Approach teleport (P3).

### 1.3 Solo croucher (5.5, torch off)

**How often.** 60 s, but the first is forced at 20 s for everyone: t = 20, about 80, about 140: **3 interactions**.

**What.** `FitOf.Crouch` = C2, H2, H3, C4 [spec 2.2]. At progress 0: H2 24, H1 15, H4 12, S1 8, S2 8, C2 5, C4 3,
C1 2.5, C3 2.5: 64 % heard. Likely: 20 rattle and breath behind a wall 15..25 walked away; 80 far steps or a peek;
140 the pass-by with the sniff.

**How it feels.** Right, and the eeriest of the five: a minute of nothing, then his breath through a wall. "1 min if
crouching": **yes**. "Sneaking has a point" [Q, 15:30]: yes for frequency.

Two things spoil it:
- The heartbeat (P4): he holds 25..55 walked away, so the croucher's quiet minute has a heartbeat under all of it.
- **The quiet player is pushed toward a chase.** He never stares, is not heard (CrouchWalk 5 [M 3.1]), so the token
  that arrives at 90 s is not spent. From 120 s (`Chase.SpendAfter` 30) C3 and C1 weigh three times as much for him
  [spec 2.2, 5.2]. C3 puts him 12..24 walked from the croucher and then stares; in the stalk a sighting of a noticed
  player within 40 starts the chase [M 18.4; spec 4.12]. So the reward for sneaking perfectly is that the director
  raises the odds of the one interaction that leads to a chase (P10).

### 1.4 A player hiding in a locker

Take the walker of 1.2, who hears the rattle at 50 s and gets into a locker at about 55 s.

- His class becomes Hiding: gap 75 s, and only C2, C4, H1, H2 may play [spec 2.2 `Only.Hiding`].
- His `due` was just paid by the rattle, so the next is owed 60 to 90 s later (75 x 0.8..1.2).
- The locker knocks at 35 s and shoves him out at 45 s [M 8.2]: at about t = 100.
- **So nothing happens while he is in there.** He sits in the dark for 45 s with a heartbeat and is pushed out.

A player who hides again and again (the sim's Hider: 30 to 40 s in, a short crouch to the next spot [spec 8.1])
gets about one interaction per two hides, and at progress 0 the weights among the four allowed types are H1 15,
H2 12, C2 2.5, C4 1.5: 87 % far steps or rattle, 13 % pass-by or sniff. In three minutes: 2 or 3 interactions, and
about a one in three chance that even one of them is him walking past the slits. `FitOf` has no Hiding row, so the
locker types get no boost.

**How it feels.** The locker is where a horror game pays the player for being scared: you hide, he walks past, you
hold your breath, he leaves. Under the spec the locker is mostly dead air. That is the least fun three minutes of
the five (P11).

**And it can kill the careful player.** If a token is in the bucket, a director-issued C4 that ends `Caught` spends
it and goes to the ReachIn and the catch [spec 5.6 "a breath check's Caught verdict outside an encounter"]. C4 is
choreographed "the neighbour first, then theirs" [spec 4.13]. Breath lasts 7 s at most and running out is `Caught`
[M 8.1]. From the first sniffing sound at the neighbour to the end of the window at his own door: 1.3 s (empty
spot) + about 1 s (3..10 studs at Search pace 8 [M 2]) + 0.9 s (warning) + 3.5..6 s (window) = 6.7 to 9.2 s. A
player who does the natural thing, holds his breath the moment he hears sniffing, runs out inside the window
whenever the window is longer than 3.8 s: (6 - 3.8) / 2.5 = 88 % of draws. So the neighbour-first staging turns a
reasonable reaction into a down, for a player who did nothing to bring him there (P8).

### 1.5 Four players, split two and two

A1 and A2 walk together; B1 and B2 sprint together, 150 studs or more from A. He has one body.

- 20 s: all four are owed. Nobody is "alone" (a teammate is within 25). Ties go to the lowest user id [spec 5.1]:
  say A1. Far steps near A. A2 hears them: his `due` drops by 0.6. Focus = A1's group; B's clock now runs at 0.6
  [spec 3.2 `share`, `Coop.SpreadRate`].
- 26 s (`Clock.Team` 6): B1 is owed and has waited longest. He is not within 80 straight of B, cannot walk 150 studs
  in the 8 or 20 s of setup; after `Fallback` 3 s the Approach teleport goes to B (more than 90 walked). B hears the
  hiss at about 30 s. Focus = B. A's clock now runs at 0.6.
- About 36 s: B2's remainder comes due: far steps near B.
- About 50 s: A2 is owed (he needed 0.6 more: about 0.2 came at 1/30 while A was the focus, the rest at 1/50) and
  so is B1; the longer wait wins: A2. He is at B. The Approach
  (cooldown 25 s, last used at 27) takes him back to A.
- And so on: he changes group by teleport about every 25 s.

**What each player gets (estimate):** one teleport hiss, perhaps one set of far steps, then he is gone to the other
pair; about one interaction every 25 to 50 s whatever they do. The sprinters do not get 17 s and the walkers do not
get 30 s. Nobody reaches the 75 s starve rule, so nobody is starved by the spec's definition; but nobody gets a
peek, a glimpse, a shadow or a pass-by either, because he never stays the 20 s those need. Half of everything is
the same flicker and hiss.

**How it feels.** Like a ghost that blinks between two rooms. The spec's co-op gate ("each player's median gap at
most solo / 0.7; nobody over 90 s") [spec 8.3] cannot hold for two separated pairs with one body: two pairs of
sprinters would need a start every 12 s, alternating between places a teleport apart, and the Approach alone has a
25 s cooldown. The gate may still pass, because the plan has no split squad in it: its pair and its four are "Mixed"
bots that all follow the floor's objective targets [spec 8.1, 8.4]; no profile keeps two groups apart (P12).

**Together instead of split** (the other common case), by the clock's own arithmetic: each interaction takes 1.0
from the target's `due` and 0.6 from each teammate who perceived it. Two sprinters together: supply 2 / 17 a second,
1.6 removed per interaction: one every 13.6 s for both. Four together: 4 / 17 against 2.8: one every 11.9 s. Walkers:
24 s and 21 s. So a tight group gets it faster than a solo player, down to one every 12 s. `Clock.SamePlayer` 10
("never two interactions reaching one player within this") would be the floor, but no rule in sections 3.4, 5.1 or
5.2 applies it: it exists only in the config table (P13).

### 1.6 Does the cadence match his words?

| He said | Spec's number | What a player gets (arithmetic above) | Match |
|---|---|---|---|
| "15 if sprinting" (and "one every 20 sec") | 17 while sprinting | 20 to 23 s with stamina; kept only by teleports, else nearer 34 s | **no** |
| "30 sec if walking" | 30 | 30, with good variety | yes |
| "like 1 min if crouching" | 60 | 60 after a forced first one at 20 s | yes |
| (lead, same message: "Standing still or hidden: slower still") [Q, 15:30] | Stand 40, Hiding 75 | a player who stops upright to listen gets it faster (40) than one who keeps crouch-walking (60) | **no** for standing still |

The Stand row matters for play: "stop and listen" is the counterplay the spec gives for far steps [spec 4.1], and
standing silent is the quietest thing a player can do. The research put standing and working an objective in one
class at 40 [R 3.1]; working is noisy (ObjectiveWork, radius 34 [M 3.1]), standing is not (P14).

---

## 2. Variety with today's sounds and rig (stage 1)

Everything a player can perceive from him in stage 1, by sound key (all `voiced` in `web/sounds/cast.json`):

| # | What the player perceives | Keys | Comes with |
|---|---|---|---|
| 1 | heavy footsteps somewhere | `CreatureStepWalk<Surface>` (5 surfaces) | H1; also under S1, C1, C2 |
| 2 | lights stutter, a hiss, the torch stutters | `TeleportHiss`, `TorchStutter` | Approach, C3 (the same cue for both) |
| 3 | he is there, staring, with a sting | `RevealSting` | C3 |
| 4 | a screech and a lunge (then chase music, or he turns away) | `Screech`, `ChaseSting`, `ChasePulse`, `GiveUpSwell` | near miss, chase |
| 5 | a rattle and a wet breath through a wall | `CreatureRattle`, `WetBreath` | H2 |
| 6 | a locker door moving | `LockerDoor` | H4 |
| 7 | him, silent, at a doorway or crossing | (none, or his steps) | S2, S1 |
| 8 | sniffing | `CreatureSniff` | C2, C4 |
| 9 | him following, stopping when you stop | steps, one rattle | C1 |

**Counted for a sprinter in three minutes (8 to 9 interactions, estimate from 1.1):** footsteps 4 or 5 times;
flicker and hiss 2 or 3 times; the screech once; the C3 reveal 0 or 1; rattle, locker, glimpse or peek 0 or 1 each,
only in the seconds he walks off an empty meter. **Four things are certain, seven are possible, and two of them
are about three quarters of everything he gets.** Sniffing, the pass-by and the shadow do not exist for him. The
honest answer to the question is: for a sprinter in stage 1, an interaction every 17 to 20 s **does** turn into the
same two noises.

For a walker it does not: 6 interactions, five or six different things. For a croucher: 3 interactions, 3 things.

The spec's own gate would not catch the sprinter's problem: "any single type at most 35 % in stage 1" [spec 8.3]
does not say per profile. Pooled with walkers and crouchers it passes while the sprinter alone sits near 50 % H1.
And two "types" (Approach and C3) are one experience to the player: the same flicker and hiss.

Inside one sound, the engine already avoids the same recording twice running (`web/src/engine/audio/bank.js`), but
the spec never says how many recordings each key needs. The research asks for four or more per sound with a pitch
change [R 3.8]. At nine uses in three minutes this decides whether the footsteps sound alive (P15).

The two cheapest additions are held back to stage 3: F (the steps that stop; a `lurkMove` that ends early
[spec 4.14]) and S3 (the still figure at the dark end; a peek with another hold rule, about 25 lines [spec 4.8]). S3
is also the only seen type that needs no walk timed against a runner and no teleport, and it is the eeriest thing in
the catalogue. Both belong in stage 1 (P2).

---

## 3. Fairness

### 3.1 Can an interaction, or a chain of them, down a careful player with no counterplay?

"No counterplay at all": I found none. Every down sits inside a token-paid encounter [spec 5.6] and every encounter
keeps today's escapes. That part of the spec is sound. But three chains down a player **for doing the careful
thing**, which reads as unfair even where an answer exists on paper:

1. **The sniff sent to a hider (P8).** Section 1.4. The player hid; nothing saw him; the director chose C4; the
   staging baits an early breath; with a token it is a down.
2. **Hiding from a peek (P9).** S2 stands him 30..70 away facing the player [M 16.1]. The game's own first-time hint
   near him says to hide ("switch the torch off, crouch, hide" [M 11]), and every beat guarantees a hiding spot
   within 25 walked [M 16]. So the player climbs in, in his sight. With a token that is "saw them hide":
   HidingResponse, the token spent [spec 5.6], then the watch, and the ReachIn at 30 s unless the hider slips out
   during a LookAway [M 14 rule 6]. The director staged a pose; the player defended himself; the result is the most
   dangerous encounter in the game. The spec does not say that "saw them hide" is off while a director-staged
   interaction plays.
3. **The forced spend on the quiet player (P10).** Section 1.3.

A fourth is geometric and exists today, but the leash makes it permanent: hold points are picked "ahead of their way
first" [spec 5.5]. A walker at 11 walks toward a monster that can back away at 7. He closes at 4 studs a second,
breaks the 15-stud clearance and sees him from behind. With a token, his senses then start a chase the player did
nothing to cause (P3).

### 3.2 Can the chase budget be farmed or dodged?

**Farmed: yes, and it is the best strategy in the game.** Stare at him from 40 studs with a full meter and a way
out. The chase winds up 1.5 s, is capped at 12 s and lost after 4 s unseen; a sprint is 19 against 16.5 for 14 s
[M 18; G]. The escape is close to certain. Then for up to 150 s solo on Standard (240 on Easy): no token, so no
chase, no hiding watch, no lethal sniff [spec 5.6]; and no hearing either, because without a token "he does not
walk over" [spec 5.3]. Sprinting, slamming doors and working objectives cost nothing but harmless interactions.
The player cannot see the bucket, but he does not need to: real chase music means "safe for two and a half minutes
now". In co-op one player burns the token while three work. The rule "sprint and he is on you constantly; crouch
and he mostly leaves you alone" [Q] stops being true for danger the moment this is understood: after a chase,
crouching buys nothing (P6).

**Dodged: partly.** A player in a crawlway is never seen [M 3.2], gets only H3, H5, S4 [spec 2.2 `Only.Duct`], none
of which can start a chase, and is followed only out of a chase already running [spec 5.4]. A culvert is a
perfectly safe room for as long as he stays. That is fine (no objective is in there), and the spec names it as a
risk. No change asked.

**Clockwork.** For a sprinter the token is spent seconds after it arrives, because the sprint is heard at 60 the
moment his ears switch on. Chases come at 90, 240, 390 s, on the dot [spec 5.6]. A fixed period is learnable (P6).

### 3.3 Is a near miss ever a real loss?

- **Health:** never. No catch is possible in the state and he stays 6 studs off [spec 4.16].
- **Position:** no.
- **Time:** a little. A scared player sprints away and burns stamina he may want when the next token arrives; a
  near miss during an objective hold breaks the hold (holds are 0.6 to 4 s, `ObjectiveConfig.luau`): seconds.
- **The real loss is the opposite one: it stops being a scare.** The near miss plays `Screech` with no `ChaseSting`
  and no `ChasePulse` [spec 4.16; M 11]. After two of them the player knows: screech without music means nothing
  will happen. From then on it is a bark, up to once every 45 s per player (`NearMissEvery`) (P7).
- **The promised rest does not always follow.** "After a big scare he leaves you alone for about half a minute"
  [spec 1 item 7]. A near miss adds 0.35 plus about 2 s of seeing at 0.04 = 0.43. Backstage starts at 0.8
  [spec 2.2]. A player whose strain was under 0.37, which is the normal case for a walker or a sprinter (section
  1), is not sent backstage; a sprinter can have far steps 17 s later and a glimpse soon after (tier 1 allowed under
  0.65). The spec says "one usually sends the player backstage"; its own numbers say usually not (P7).
- **Co-op:** the screech is heard to 120 [spec 2.2 `Audible.Screech`]. Each of four players may get a near miss
  every 45 s: up to one screech every 11 s for the squad. And every player the screech "reached" is charged the full
  0.35 of strain [spec 3.2 settle: "every player it reached: strain += Cost"], also one who only heard it from 100
  studs. Their close and seen interactions get switched off by a scare that was not theirs (P13).

---

## 4. Co-op: starved, or picked on?

**Starved, by the spec's own measure: no.** The 75 s starve rule and the teleport keep everyone under 90 s.

**Starved of the good ones: yes, when the squad splits.** Section 1.5: he ping-pongs by teleport, never stays long
enough for a body interaction, and both pairs get the same flicker and one set of steps. The fix is not more
frequency (one body cannot give it) but **stints**: he stays with one group long enough to do two or three proper
things, then moves, and the away group's quiet is true quiet ("he is with them"), which is good co-op horror if it
lasts under a minute (P12).

**Picked on: possible, for the player who is alone.** A lone player's score is multiplied by 1.5, by 1.3 more when
loud [spec 5.1]. That decides who he stands near, and the chase token is spent on whoever triggers first, so it is
spent near him. With four players a token comes every 150 / 1.9 = 79 s [spec 5.6]. Strain sends him away from the
loner for 25 to 40 s after each chase, but nothing stops the next token from landing on the same child, and he is
the one whose teammates are too far to revive him. No rule spreads the chases (P12).

**Grouped players get more than a solo player** (one every 12 to 14 s when sprinting together, section 1.5), and
the 10 s per-player floor is not applied by any rule (P13).

**One player decides the pace for a pair** ("at the noisiest member's rate" [spec 3.2]). That is a good rule: it
gives the team something to say to each other. Keep it.

**The rescue window** (20 s with no interaction and no chase start after a down [spec 5.6]) is right.

**Section 1 of the spec tells the player something untrue in co-op:** "about one [chase] every two and a half
minutes for the whole squad". With four players it is one every 79 s (P13).

---

## 5. Easy and Nightmare

**Easy.** Same cadence, softer danger: token every 240 s, chase capped at 8 s, leash 35..70, close interactions
weighted 0.7, never caught in a hole [spec 2.5]. As a set of numbers it is a good easy mode. Two remarks:
- Nobody can choose it [spec 2.1, 11 question 1]. The player said "i also dont want the game to be too hard". The
  spec answers that with Standard's downs gate (no more than today plus 0.05), which is the right first answer. But
  a difficulty that is designed, simulated and then not offered is wasted work, and after a token is burned Easy is
  four minutes of nothing to fear (P6 applies more strongly).
- Whether v3 "feels harder" is not only downs. A careful player now meets a tell five to nine times in three
  minutes; if he crouches, hides or waits at each one, the floor takes longer. Nothing in section 8.3 measures the
  time a careful player needs to finish a floor against today (P19).

**Nightmare.**
- Cap 2 tokens, 90 s each [spec 2.5]. After the first chase the second token is already there, his ears are on
  [spec 5.3], and backstage only limits what the *director* sends; it does not stop him hearing a sprint and
  walking over. So two 45 s chases at 18.5 can come 15 s apart (the Breather [spec 2.4]). The line "after a big
  scare he leaves you alone for about half a minute" is false on Nightmare whenever a second token is held. If that
  is wanted, say so; if not, a backstage player must also be safe from his ears (P20).
- He lurks only from Patrol [spec 3.4 step 2]. On Nightmare a chase may run 45 s and its search follows, and a token
  comes every 90 s: for much of a floor the director is blocked. The gate "Nightmare cadence in the same bands as
  Standard" [spec 8.3] can only pass if a chase counts as an interaction in the gap measure. Section 8.2 does not
  say that it does; a chase is not in `Types` (P20).
- Leash 20..45 with the 15-stud clearance leaves a 5-stud margin on the near side, and H1 demands 30 or more walked
  [spec 4.1]. Each far-steps moment pushes him to the outer third of his own band. Not a fairness problem; the sim
  will show whether H1 becomes rare on Nightmare.

---

## 6. Honesty, and whether each counterplay visibly works

### 6.1 Sounds from where he is, no teleport in view

Held, as rules: every cue is played at his eye, his feet or the door he touches; the hiss at the planned spot is the
one allowance; no teleport lands in view or within 12 [spec 6]. Four places where the player will still feel
cheated:

1. **The heartbeat tells his distance all the time** (P4). It is honest, but it is a second radar that never
   switches off, and it makes "between these moments he is quiet on purpose" [spec 1 item 4] untrue to the ear.
2. **Perceptions the clock does not count.** His creeping steps are audible within 22 straight [spec 2.2
   `Audible.StepCreep`]; a hold point 25 *walked* away can be 10 studs away through a wall. A hold point with a clear
   line to a player is kept for up to 1 s before he leaves it [spec 5.5 `LineSeconds`]: an unplanned sighting of him
   walking almost silently. The Approach stutters the target's torch even when the hiss (audible to 40) is out of
   earshot at its 45..80 walked. None of these settle the clock [spec 8.2: "neither do his footfalls between
   interactions"]. So the player perceives more than the spec measures, and an unplanned sighting can be followed 3 s
   later by the planned one (P4, P18).
3. **A tell does not have to stay true.** Nothing stops far steps on the left at t and a teleport ahead at t + 6
   (`Clock.Team`). To the player that is a monster in two places. The player's Nov 15 words were about a monster
   that only ever teleports (P3).
4. **He vanishes in view.** The near miss ends in the dissolve when no walk out of sight takes under 3 s
   [spec 4.16, 11 question 5]; S3 ends in the dissolve when the torch lands [spec 4.8]. The rule only forbids
   appearing in view, and today's give-up dissolve already exists. But v3 adds up to one near miss per 45 s per
   player. A body that crawls through holes and a ghost that dissolves are two different monsters; the player asked
   for the first (P7, P21).

### 6.2 Does each counterplay visibly work?

| Type | The spec's answer | Does the player see it work? |
|---|---|---|
| H1 far steps | "take the other way and the next interaction comes from behind, not ahead" [spec 4.1] | **No rule makes this true.** The hold point is picked ahead of the player's way first [spec 5.5]. After he turns, he will be ahead again. |
| H2 behind the wall | "keep still and quiet: he moves on"; a loud noise with a token brings him round | He moves on after 2 to 3 s whatever the player does. Without a token a loud noise changes nothing the player can perceive. The choice matters only when a token is held. |
| H4 locker | "looking in later shows the door he moved ajar" [spec 4.4] | **Contradicted two lines up:** the nudge "opens to 0.3 and shuts over 1.2 s". A shut door is no evidence. |
| S2 peek | back off and he withdraws | Yes. |
| S3 vantage | "put the torch on him and he is gone" | **Collides with the stare.** He stands 35..60 walked away [spec 4.8]. The torch's lit spot reaches 30 [M 17.1]; the stare counts to 45 with the torch on, within 7 degrees, 1.0 s [M 3.3]. Between 30 and 45 studs, aiming the torch at him does not dispel him and does start a chase or a near miss. The taught answer is the trigger. |
| C1 shadow | look back and he freezes | Yes, but a look of 1 s straight at him is the stare. The hint says "look back" [M 11]. The freeze cone is 25 degrees and the stare cone 7 [M 16.3, 3.3], so it works for a player who looks near him; nobody is told that. |
| C2 pass-by | hide, or stay out of his cone in the dark | Yes. |
| C3 teleport | turn, sidestep, hide | Yes (today's rule and test). |
| C4 sniff | hold your breath through the window | Yes, but see P8: the staging baits the breath early. |
| near miss | nothing to do | Nothing to see work either; see P7. |
| noise as a lure (a thrown flask, a slammed door) | named by the lead as part of "more fun" [Q, 15:20: "luring him with noise"] | **Works only while a token is held** [spec 5.3], which the player cannot know; and the flask's shatter adds 0.25 to the thrower's own clock [spec 2.2 `Lumps`]. Most of the time the lure does nothing. |
| crouching | fewer interactions | True over a minute; nothing shows it in the moment. Acceptable. |
| the flask stun | 6 s stun, the chase stays spent | Yes, and it feels good: one flask buys a long safe spell. |

---

## 7. What the player said that the spec forgot or put last

1. **"bro why cant he go thru the small little holes"** (Nov 16, 02:00) and **"make it be able to crawl under the
   little holes"** (15:20) [Q]. Asked twice in one day. In the spec it is stage 2, and its acceptance is "H3 and S4
   each at least 3 % of interactions" [spec 9]. A walker has about 16 interactions in an 8-minute floor: at 3 % he
   sees the fold-in once every two floors. And by rule he never comes *out* of a hole in a player's view
   [spec 5.4]. The player will not notice that the feature exists (P16).
2. **"I want the monster to talk too real words"**, **"Make sure he talks good English"** [Q]. H5 is off until
   recorded files exist, and the hook itself is stage 3 [spec 7, 9]. The spec's reasons for not faking a voice are
   right. But the lead decided at 19:45 that "every line spoken (the kids and the monster)" is built now [Q], and the
   spec plans as if the voice were far away. Also the best moments for a line are the ones v3 creates (the near miss,
   the peek, the pass-by at a locker), and the spec gives the voice system no event for any of them [spec 7 lists
   the event categories; none is new] (P17).
3. **"i want his footsteps to be louder so people know when hes around"** (Nov 15) [Q]. v3 makes him walk at a
   quarter volume for most of the time he is within 55 studs [spec 3.6]. I accept the spec's reason (a constant tell
   drowns the cadence), but the player's sentence is about trust: if he sees the monster move and hears nothing, or
   learns it was 25 studs away in silence, "footsteps tell me he is around" is broken (P18).
4. **"i never really see the monster unless he like tp's behind me ... when he tps i can js run"** (Nov 15) [Q].
   Section 1.1: for a sprinter, stage 1 is mostly this (P1, P2, P3).
5. **"make it eerie"** [Q]. The two eeriest entries (S3, the still figure; F, the steps that stop) are in stage 3;
   stage 1 is the loud half of the catalogue (P2).
6. **"only ideas"** [Q, 15:30]. His numbers are starting values and the research ends with "ask the one question
   that matters: too much, too little, or right?" [R 3.9]. The spec has no way for him to answer except by another
   build (P22).
7. **"make it stay in a radius"** [Q]. Done for walkers and crouchers. For a runner the radius holds only by
   teleport (P3).
8. **"not too hard"** [Q]. Guarded for downs. Not guarded for the careful player's time, nor against the three
   chains of section 3.1 (P8, P9, P10, P19).

---

## 8. Findings, each with the change to make in the spec

Severity: **blocker** = the player would say it is not what he asked for, or a careful player is downed unfairly;
**major** = clearly less fun, tiring, or a promise in the spec's section 1 is false; **minor** = polish or a gap in
the text.

### P1 (blocker) A real sprinter gets 20 to 23 s, not "15 if sprinting"
- **Where:** [spec 2.2] `Clock.Gap.Sprint` 17; [spec 8.3] "gap, Sprinter median 15..20 s".
- **Problem:** stamina. 63 % sprint for a person, 54.5 % for the sim's bot (section 1.1): 20.2 s and 21.2 s before
  objective stops. The spec's own gate fails on its own bot.
- **Change:** set `Gap.Sprint = 14` **[mine]** (person: 0.63 / 14 + 0.37 / 30 gives 17.4 s; bot: 18.5 s; a stretch of
  pure sprint: 14 s, his "15"). State in 2.3 that the sprint number is tuned so that a stamina-limited sprinter
  measures 15..20. Keep the gate as written.

### P2 (blocker) Stage 1 has almost nothing that reaches a running player except steps and the teleport
- **Where:** [spec 4.1 to 4.12, 5.2, 9 stage 1].
- **Problem:** section 1.1 and section 2. Body types are planned against where the runner is now; he is 114 to 150
  studs on by the time the monster is in place. H1 cannot play twice running. So: steps, flicker, steps, flicker.
- **Change (four parts):**
  1. Plan for a runner at where he will be: for a target of class Sprint, every placement (S1's crossing, S2's and
     S3's stand point, H2's point, the leash's hold point) is measured from the point `Leash.Lead = 5` s **[mine]**
     along his travel, the way the teleport already leads its target [M 7.2, 18.4].
  2. Move **S3 (vantage)** and **F (fake tell)** from stage 3 to stage 1. Both are a few dozen lines on today's rig
     [spec 4.8, 4.14], S3 needs no timing against the runner, and they are the eerie ones.
  3. Add a second heard type on today's sounds so far steps have a partner: **H1b "running steps"**: he moves at 13
     **[mine]** (between the glimpse's 12 and the chase's 16.5, paces he already has [M 2]) for 2 to 3 s, unseen, with
     `CreatureStepChase<Surface>` (voiced in `cast.json`), ending 30 or more walked from everyone. It is also how
     he keeps up without a teleport (P3).
  4. Say whether the fallback H1 is exempt from "not twice running" (it must not be), and make the gate per
     profile: "no single type over 35 % **for each profile**", and count Approach and C3 as one item, "teleport
     warnings", capped at 25 % of a profile's interactions **[mine]**.

### P3 (major) The leash is slower than a walking player, so it is held by teleports and by standing in the player's path
- **Where:** [spec 2.2] `Leash.CreepPace` 7, `StepPace` 9; [spec 5.5] hold point "ahead of their way first".
- **Problem:** walk 11, sprint 19 [G]. A walker going one way leaves the band in about 4 s and reaches the Approach's
  90 walked in about 16 s; a sprinter in 5 s. And a hold point ahead of a walker cannot be kept: he backs off at 7,
  the player comes on at 11, the 15-stud clearance breaks, and with a token his own senses start a chase the player
  did not cause. Also a tell does not stay true: far steps left, teleport ahead 6 s later.
- **Change:** (a) repositioning to keep the band uses the running steps of P2 (13, heard, counted as an interaction
  when two footfalls are within earshot), with the Approach only beyond 90 walked **and** when no route under 12 s
  exists **[mine]**; (b) hold points for a moving focus are **off** his route: at least 10 studs **[mine]** from the
  straight line of his travel over the next 5 s, side rooms first (the research says "dark side rooms, alcoves"
  [R 3.4]); "ahead" is used only by a plan that needs it; (c) add `Clock.TellHolds = 12` s **[mine]**: no teleport
  (C3, Approach) aimed at a player within 12 s after a heard interaction reached him; (d) add to 8.3: teleport
  warnings per player per 3 minutes, at most 2 **[mine]** on Standard.

### P4 (blocker) The heartbeat never stops
- **Where:** [spec 2.4] "`Audio.NearRadius` 45: reused unchanged"; [spec 3.6].
- **Problem:** the panic floor is on whenever his eye is within 45 straight and he is not hidden
  (`web/src/creature/index.js` `nearFloor`, `NEAR_FLOOR_FAR` 0.27; the heartbeat starts at 0.25 [M 11]). The leash
  is 25..55 *walked*, so straight distance is under 45 nearly always (always on Nightmare, 20..45). Tiring, it kills
  the heartbeat as a signal, it reveals his distance, and it contradicts "he is quiet on purpose".
- **Change:** in the quiet lurk the heartbeat's radius is `Leash.Clear` (15) **[mine]**; during an interaction that
  reached the player, a chase, a search or a hiding watch it is 45 as today, with a tail of 8 s **[mine]** after it
  ends. So the heart rises with each interaction and falls between them. Add to 8.3: "panic floor on" under 35 % of
  a walker's time **[mine]**. Do the same for the first-time hint that keys off this radius
  (`web/src/game/ui/hints.js`).

### P5 (major) A steady player gets a metronome
- **Where:** [spec 2.2] `ThetaMin` 0.8, `ThetaMax` 1.2; [spec 3.3] check "never backstage".
- **Problem:** a walker who does not stare gets one thing every 24 to 36 s for the whole floor, no cluster, no lull.
  Horror needs the lull ("Horror that never lets go stops being scary" [R 2.10]). The only lull in the spec follows
  a chase.
- **Change:** keep the mean, widen the shape. `ThetaMin = 0.6`, `ThetaMax = 1.4` **[mine]**; and a **lull**: after
  every 5 to 7 interactions (drawn per player from the theta stream) the next theta is doubled, and the interaction
  that ends the lull is drawn from tiers 1 and 2 only when strain allows **[mine]**: silence, then him. Divide every
  `Gap` by 1.17 **[mine]** so the long-run mean is unchanged (one doubled gap in six: the mean theta is 7 / 6).
  Loosen p90 in 8.3 accordingly (Sprinter 28 to 36 s, Walker 45 to 62 s **[mine]**); the medians stay.

### P6 (major) The token is a visible safe window and can be burned on purpose
- **Where:** [spec 5.3, 5.6] `Chase.Refill` 150, fixed; no hearing without a token.
- **Problem:** section 3.2. After any chase: 150 s (Easy 240) with no possible down and a deaf monster; chases for a
  sprinter at 90, 240, 390 s exactly.
- **Change:** (a) each refill lasts `Refill x U(0.6, 1.4)` from a seeded stream `Lurk|Refill` **[mine]** (same
  mean); (b) a chase that ends by losing him in under 6 s with him never within 20 studs returns 0.5 token
  **[mine]**: a cheap burn buys half the window; (c) without a token he still **answers** noise (P9b below), so the
  player cannot tell an empty bucket by his behaviour. Add to 8.3: chases per floor still 2..5 solo on Standard
  (today's band [M 20]), downs unchanged.

### P7 (major) The near miss turns into a bark, is not followed by the promised rest, and ends in a vanish
- **Where:** [spec 4.16, 5.6, 1 item 7].
- **Problem:** section 3.3. No chase sting, so it is told apart from a chase at once; +0.43 strain rarely reaches
  0.8; the exit may be a dissolve in view.
- **Change:** (a) the near miss plays `ChaseSting` at the screech and `GiveUpSwell` as he turns (it is a chase he
  breaks off; both are the player's own music, not his sounds); (b) a near miss sets the target's strain to
  `max(strain + 0.35, Strain.BackOff)`: always backstage, so section 1's item 7 is true; (c) the exit order is: walk
  out of sight; else back away facing them at 9 until out of sight (up to 6 s **[mine]**); from stage 2, fold into a
  hole within 20 walked; the dissolve last; (d) squad-wide: no two near misses within 25 s **[mine]**; the second
  trigger in that time gets the silent slip-away.

### P8 (blocker) A director-issued sniff can down a hider who did nothing wrong
- **Where:** [spec 4.13, 5.6] "a breath check's `Caught` verdict outside an encounter" spends a token: ReachIn.
- **Problem:** section 1.4. Neighbour-first staging plus a 7 s breath: holding at the first sniff fails in 88 % of
  window draws. Hiding is the careful player's answer [M 20: "its fairness is the careful player's and the hider's"].
- **Change:** a C4 that the director issued never spends a token: its `Caught` is always the locker near miss
  (screech at the slits, the door rattles, he leaves). A hider is caught by a breath check only inside an encounter
  he caused (seen getting in during a chase, or the search that follows a chase). And in C4 the breath meter is
  refilled when the warning at the player's own door starts **[mine]**, so listening to the neighbour's check costs
  nothing. Add to 8.3: "downs of the Hider profile: 0 outside a chase's encounter".

### P9 (blocker) Defending yourself during a staged interaction can start an encounter; and noise does nothing without a token
- **Where:** [spec 5.6] "seeing someone climb into a spot: HidingResponse" with a token; [spec 5.3].
- **Problem:** (a) hiding from a peek, a glimpse, a shadow or a pass-by, in his sight, spends the token on a hiding
  watch (section 3.1 chain 2). The game's own hint tells the player to hide. (b) Without a token a slammed door or a
  thrown flask produces nothing the player perceives; the lure named in the requirements fails most of the time.
- **Change:** (a) one rule in 5.6: **"A defence never starts an encounter; a provocation does."** While a
  director-issued interaction plays and for 5 s after **[mine]**, getting into a hiding spot, backing away,
  switching the torch off or crouching never triggers HidingResponse or a chase; he ends the interaction and leaves,
  and the hider's next interaction is the non-lethal C4 of P8. Provocations keep today's rule: a 1 s stare, coming
  within 12, a loud noise. (b) **The answer:** a High or Critical noise that he hears with no token gives a heard
  reply inside 4 s **[mine]**: three or four heavy steps toward the noise, then silence (it is F's move [spec 4.14]),
  ending 15 or more walked from everyone; it settles the clock like any interaction. A noise made away from the
  player (a flask that lands 12 or more studs from the thrower **[mine]**) also moves the leash's hold point to the
  noise's side for 15 s **[mine]**: the lure works, token or not.

### P10 (major) An unspent token pushes teleports at the quiet player
- **Where:** [spec 2.2] `Chase.SpendAfter` 30, `SpendWeight` 3; [spec 5.2].
- **Problem:** section 1.3. The croucher's reward for making no trigger is three times the weight on the two types
  that lead to one.
- **Change:** `SpendWeight` applies only to a player who was `loud` in the last 60 s or whose class is Sprint or
  Walk **[mine]**. For a player in Crouch, Stand-still or Hiding the token waits. In 8.3: "chases per floor 2..4"
  is asserted for Sprinter, Walker and Mixed; for the Croucher the band is 0..2 **[mine]**.

### P11 (major) The locker is dead air
- **Where:** [spec 2.2] `Gap.Hiding` 75, `Only.Hiding`, no `FitOf.Hiding`; stay limit 45 s [M 8.2].
- **Problem:** section 1.4: most hides get nothing; 13 % of what a hider gets is the pass-by or the sniff.
- **Change:** (a) add `FitOf.Hiding = { "C2", "C4" }`; (b) add `Clock.HideOwed = 12` s **[mine]**: a player who gets
  into a spot within 20 s after an interaction reached him, and is not backstage, is owed one interaction 12 to
  20 s after getting in, drawn from C2 and (non-lethal) C4 first, then H2; later ones in the same hide at the 75 s
  gap; (c) in 8.3: "Hider: at least one hide in three gets a pass-by or a sniff" **[mine]**.

### P12 (major) A split squad gets a blinking ghost; a lone player can get every chase
- **Where:** [spec 3.2, 5.1, 5.5, 8.3 co-op row].
- **Problem:** sections 1.5 and 4. The focus flips on every order; each flip is an Approach; the gate has no split
  squad in it; nothing spreads the token.
- **Change:** (a) **stints:** once he gives an interaction to a group (players within `GroupRange` of each other),
  the focus stays in that group for `Coop.Stint = 45` s **[mine]** or three interactions, whichever is first, unless
  another player passes `Coop.Starve`; lower `Coop.Starve` to 60 **[mine]** so a stint and the trip fit under 90 s;
  (b) the Approach that starts a stint is aimed so that the arriving group hears the hiss (within
  `Audible.TeleportHiss` 40 of an ear), so the move itself is their first interaction; (c) **spread the chases:** the
  player who was the target of the last token-paid encounter cannot be the next one's target unless 2 x the refill
  time has passed or he is the only counting player; his triggers give the near miss meanwhile **[mine]**; (d) add a
  sim profile "split" (two pairs with different objective orders, kept 100 studs or more apart) and assert for it:
  each player's median gap at most 2 x solo, nobody over 90 s, teleport warnings at most one third of interactions,
  no player the target of more than half the floor's chases **[mine]**. Say in section 1 of the spec that a split
  squad shares him in turns.

### P13 (minor) Co-op bookkeeping
- **Where:** [spec 2.2 `Clock.SamePlayer`; 3.2 settle; 1 item 5].
- **Problem:** `SamePlayer` 10 is in the config and in no rule; a tight group gets one every 12 to 14 s; a player who
  only heard a far screech or hiss is charged the full strain cost (0.35, 0.30); section 1 says one chase per two
  and a half minutes "for the whole squad", which is 79 s with four.
- **Change:** add to 5.2: "not feasible for a target, and not allowed to start, when it would reach any player
  within `SamePlayer` of that player's `lastReachAt`" (heard-only types are held, not dropped); in `settle`, a player
  reached by hearing only pays `min(Cost, 0.08)` **[mine]**; correct the sentence in section 1.

### P14 (major) Standing still and silent is paid faster than crouch-walking
- **Where:** [spec 2.2] `Gap.Stand` 40; [spec 3.5].
- **Problem:** the lead's decision on the player's message: "Standing still or hidden: slower still" [Q, 15:30].
  "Stop and listen" is the spec's answer to far steps, and it costs more than moving on in a crouch.
- **Change:** split the class. `Work` (an ObjectiveWork pulse from that player within 2 s): 40. `Still` (speed under
  1, no noise of theirs for 2 s): 75 **[mine]**, the same as Hiding. Upright and moving slower than 7.5 but not
  still: 40 as now. `FitOf.Still` = `FitOf.Crouch`.

### P15 (minor) Nothing says how many recordings each sound needs
- **Where:** [spec 4.0, 4.1 to 4.4].
- **Problem:** a sprinter hears his steps four or five times in three minutes and about 14 times a floor.
- **Change:** add to 4.0: each key the director issues has at least 4 recordings **[R 3.8]** (the engine already
  avoids the same one twice running, `web/src/engine/audio/bank.js`), and the sounds test fails a director key with
  fewer. For H2, alternate the order (rattle then breath; breath alone; rattle alone) by the `Lurk|Place` stream.

### P16 (major) The holes come second and would be too rare to notice
- **Where:** [spec 9 stage 2: "each at least 3 %"; 5.4 exit rule].
- **Problem:** section 7 item 1.
- **Change:** (a) in stage 2's acceptance: on a floor with crawlways, hole interactions (H3 + S4) are at least 10 %
  of a walker's and a croucher's interactions **[mine]**, and each player sees one S4 fold-in within the first 4
  minutes of the first such floor **[mine]** (the director raises S4's weight by 3 until it has happened once per
  player per run); (b) allow one seen **exit**: he may come out of a mouth that is in a player's view when that mouth
  is 30 or more walked from everyone **[mine]** (it is a seen interaction at range, tier 1, the mirror of S4); the
  12-stud rule stays; (c) build order: if stage 1 is on the beta more than a few days before stage 2, tell the
  player in the beta note that the holes are next, because he has asked twice.

### P17 (major) He does not speak in any stage, and v3's best moments have no line
- **Where:** [spec 7, 9].
- **Problem:** section 7 item 2.
- **Change:** (a) move the H5 hook and its stub to stage 1 (it is an interface and a config switch), so the day
  task #49's files land the lines play with no monster work; (b) add three event offers from the lurk director to
  the voice director, rationed by the same `Voice.PerPlayer` and `PerTeam`: `NearMiss` (as he turns away), `PassBy`
  (at point P beside a hider), `Peek` (as he withdraws); they ride inside those interactions and are not counted as
  extra ones; (c) keep "no browser voice, no subtitle over a growl"; (d) add to stage 3's acceptance: with the stub
  on, a walker hears a line in 8 to 15 % of his interactions and never two within 45 s **[mine]** ("dont overdo it"
  [Q, Nov 15]).

### P18 (major) Silent walking breaks "footsteps tell me he is around", and stray perceptions are not counted
- **Where:** [spec 3.6, 5.5, 8.2].
- **Problem:** sections 6.1 and 7 item 3.
- **Change:** (a) he creeps only when no player has a clear line to him; the moment one has, his gait is Heavy;
  (b) in the quiet lurk he mostly **stands**: a move of more than 10 studs **[mine]** between hold points is made
  as far steps or running steps (P2) in the next free interaction slot, not as a creep, unless a player is inside
  `Leash.Clear`; (c) anything unplanned that meets the reach rule (two creeping footfalls within 22; him seen for
  0.3 s; the torch stutter of a warning aimed at the player) is logged as type `Stray`, takes `HeardShare` (0.6)
  from that player's `due`, and the sim reports strays: at most one per player per 2 minutes **[mine]**; (d) the
  Approach does not stutter the target's torch (C3 does): it is a move, not an attack.

### P19 (major) "Not harder" is measured in downs only
- **Where:** [spec 8.3].
- **Problem:** section 5: five to nine tells in three minutes slow a careful player who answers each one.
- **Change:** add to 8.3 and to stage 1's acceptance: the careful bot's and the Croucher's time to finish a floor
  (or objectives done in 8 minutes) is within 15 % of the v2 baseline **[mine]**, measured in the same baseline run
  the spec already plans [spec 8.4].

### P20 (minor) Nightmare: two chases back to back, and the cadence gate
- **Where:** [spec 2.5, 3.3, 5.3, 8.2, 8.3].
- **Change:** (a) `Summary.token` is false for a player who is backstage (his noise does not pull him in; his stare
  and coming within 12 still do); (b) a chase's start and a near miss are interaction records (type `X`,
  `NearMiss`) and count in the gap measure; say so in 8.2.

### P21 (minor) Three counterplay texts that the rules contradict
- **Where:** [spec 4.1, 4.4, 4.8].
- **Change:** H1: delete "the next interaction comes from behind", or make it true with P3 (c) and "for 12 s after
  far steps the next hold point lies on the same side of the player as the steps were" **[mine]**. H4: the nudged
  door stays ajar (open 0.15 **[mine]**) until a player uses that spot or 120 s pass; it is the evidence the text
  promises. S3: while a vantage plays, that player's stare does not count; looking at him within 7 degrees for 0.5 s
  with the torch on, at any range to 80, is what ends it **[mine]**, and he steps back to his corner; the dissolve
  only if he has no corner.

### P22 (minor) No way for the player to say "too much" or "too little"
- **Where:** [spec 11]; [R 3.9] "ask the one question that matters".
- **Change:** on the beta only, a setting "Monster activity: Less / Normal / More" that multiplies every `Clock.Gap`
  by 1.4 / 1 / 0.75 **[mine]** and nothing else (danger untouched). The player answers by feel in one session; the
  chosen column becomes the shipped numbers and the setting is removed or kept as he prefers. Add as open question 6.

---

## 9. What I would not change

- The clock driven by movement class, with the carry instead of a reset [spec 3.2].
- Strain and backstage sized by what happened, after a chase or a catch [spec 3.3].
- "Every down happens inside a token-paid encounter" as the difficulty guarantee, with the downs gate tied to
  today's baseline [spec 5.6, 8.3, 11 question 4].
- The same cadence on every difficulty; difficulty changes danger only [spec 2.1].
- No fake teleport warning; no browser voice [spec 2.2 `Fake`, 7].
- The pair rule "the noisiest member sets the pace", the rescue window, the hole rules (slower than a crawler, a
  moving crawler never caught, the exit hold).
