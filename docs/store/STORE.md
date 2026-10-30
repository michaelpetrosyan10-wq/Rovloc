# Rovloc: Roblox launch kit

Everything you need to publish Rovloc on Roblox. The images are in this folder. They are rendered from the real game
world, the same models, rooms and lighting as the Roblox build, with no HUD.

## 1. Name

**Rovloc 🔦 Co-op Horror**

Keep the name "Rovloc" first so people can search for it. Roblox caps names at 50 characters. Other options:
- Rovloc: School Escape [Co-op Horror]
- Rovloc 😱 Escape the School

When you ship a big update, you can add a short tag for a week or two, e.g. "Rovloc 🔦 Co-op Horror [NEW FLOORS]". Only
tag real updates: Roblox flags misleading tags.

## 2. Description (copy and paste)

```
🔦 The school was abandoned when the world ended. Something still walks its halls.

Rovloc is a 1-4 player co-op horror escape. Climb from the basement to the roof, one floor at a time — and every floor's exit stays locked until you finish its objective.

⚡ Restore the basement's power
🔑 Steal the janitor's master keys
🧪 Brew acid to burn through a chained door
🏀 Start the gym generator — then survive
🌊 Dive into the flooded pool for the valve wheel
🪂 Cut open the parachute crate and jump

It hears every footstep. Hide in lockers and hold your breath. Crawl through the vents. Throw chemicals to stun it. Revive your friends before they bleed out.

Item spots and exits change every run — no two escapes are the same.

👥 1-4 players • Standard & Nightmare
🎮 PC • Mobile • Controller

Can you make it to the roof?
```

That's about 800 characters, under Roblox's 1,000 limit.

## 3. Images

| File | Where it goes |
| --- | --- |
| `icon-a.png` (512×512) | **Experience icon**, upload this first. The Creature's face in a flashlight beam, no text. |
| `icon-b.png` (512×512) | The alternative icon: a side-lit three-quarter view with a small wordmark. Use it for an A/B test. |
| `thumb-1-keyart.png` | **Thumbnail 1** (the first one people see): the corridor, the Creature and the ROVLOC logo. |
| `thumb-2-hide.png` | Thumbnail 2: HIDE. The view from inside a locker. |
| `thumb-3-pool.png` | Thumbnail 3: DON'T SPLASH. The flooded pool. |
| `thumb-4-objective.png` | Thumbnail 4: 4-PLAYER CO-OP. The fume hood objective with the Creature in the doorway. |
| `thumb-5-roof.png` | Thumbnail 5: ESCAPE. The roof finale. |
| `logo.png` | A transparent ROVLOC wordmark for your group, Discord and videos. |
| `logo-on-dark.png` (1920×1080) | A banner for a Roblox group or YouTube. |

**Icon A/B test:** if Creator Hub offers an icon/thumbnail experiment for your experience, run icon-a against icon-b.
Otherwise use icon-a for a week, then icon-b for a week, and compare click-through rate in Analytics. Keep the winner.

## 4. Settings checklist (Creator Hub → your experience)

1. **Publish:** in Studio, File → Publish to Roblox (put it in a group if you make one, see section 6).
2. **Basic info:** paste the name and description, then upload the icon and the 5 thumbnails in order.
3. **Genre:** pick the horror or survival category. Roblox's list changes, so choose the closest horror option shown.
4. **Max players: 4.** The game is built for squads of 1–4.
5. **Devices:** Computer, Phone, Tablet. The game has touch controls. Console: the game supports a controller, but
   test it with one before ticking Console.
6. **Avatar type: R15.** The game resizes avatars to a standard body so everyone fits the vents. R15 is needed for
   that.
7. **Private servers: on.** Groups of friends love them. Free at launch removes friction; you can charge a few Robux
   later.
8. **Voice chat: on.** Spatial voice makes co-op horror much scarier, and only eligible players get it.
9. **Security:** "Enable Studio Access to API Services" on, so saved credits and perks work when you test in Studio.
   API services are on in the live game by default.
10. **Test with friends first:** in Studio use Test → Clients and Servers → 2 players, then a public test with
    friends. Compare a floor with rovloc.vercel.app to check the lighting.

## 5. Maturity & Compliance questionnaire (answer honestly)

Roblox requires this questionnaire before the game shows up for most players. Here is exactly what is in the game, so
you can answer accurately:

- **Violence:** a monster catches players. You see a jumpscare (it lunges at the camera, then a cut to black).
  - The first catch leaves you "downed", crawling, with a red bleeding-out screen effect.
  - A second catch kills you: you spectate. The body stays whole, with no dismemberment or gore.
  - Players cannot hurt each other. Players can stun the monster with thrown chemical flasks and floodlights.
- **Blood:** yes. Dried, dark red-brown blood pools under the dead bodies, and they can look clearly red in the
  flashlight. The "downed" screen has a red pulsing vignette, and the death screen reads "YOU DIDN'T MAKE IT" in red.
- **Dead bodies:** yes, 20 across the school. They are blocky, decayed bodies in tattered school clothes, slumped or
  lying down. Some show ribs through a torn shirt or a bony forearm. There is no dismemberment and no visible insides.
- **Fear / horror:** yes, intense:
  - jumpscares;
  - a scripted monster reveal on Floor 1;
  - ambient scares (bangs, a child's whisper and giggle);
  - being dragged underwater in the pool;
  - chase sequences.
- **Other categories:**
  - Drugs and alcohol: none. The syringe is a medical revive item.
  - Crude humour: none.
  - Romance: none.
  - Gambling: none.
  - Real-world money: none.
  - Profanity: none in the game's text.

With blood, dead bodies and intense horror, expect Roblox to give the game a **Moderate** label. Roblox shows the
resulting label, and which ages it allows, when you submit. To reach younger players, I can tone it down for a Mild
label: remove the blood pools and make the bodies less graphic.

## 6. Getting players

No one can promise numbers, but these are the things that actually move a new Roblox game:

1. **The first 48 hours:** play it with friends and get them to favourite it and leave a thumbs up. Co-op games spread
   by invites, so ask every squad to bring one more friend.
2. **Make a Roblox group,** e.g. "Rovloc Studios", with `logo.png` as its icon and `logo-on-dark.png` as the banner.
   Publish the game under it. Groups let players join a community and get your update shouts.
3. **Sponsored ads:** Creator Hub → Ads Manager. Start with a small daily budget, use icon-a and thumbnail 1, and
   watch click-through rate and cost per play for a few days before spending more.
4. **Short videos:** jumpscare clips and squad reactions do very well on TikTok and YouTube Shorts. Record a few runs
   with friends (screams included) and post 15–30 second clips with the game name. Roblox horror YouTubers who cover
   games like Doors are worth messaging with a link.
5. **Social links:** add a Discord or YouTube on the experience page so players can follow updates.
6. **Update regularly** and say so in the title tag and a group shout. Players return for new content.
7. **Watch Analytics:** retention (day 1 and day 7), session length, and the floor where most players quit. That tells
   you what to fix first.

Ideas for future updates, which I can build:
- badges (one per floor, a Nightmare escape, a no-deaths run);
- a fastest-escape leaderboard;
- daily challenges;
- cosmetic flashlights as game passes.
