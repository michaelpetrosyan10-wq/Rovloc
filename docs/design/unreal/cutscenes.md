# STAY BEHIND: the cutscene bible

**For the people who build the twelve cutscenes.** The game map (`docs/design/unreal/game-map.md`) is the canon; where anything here disagrees with it, the map wins until the map is changed (the changes this bible needs are listed at the end). Working assumptions are the owner's answers of 21 November: the Voice Collectors, the Mark, Marcus taken at halftime, the hunter taking Kayla from the wreck, Danny's father as what he walked away from, the basketball game.

This is the final cut. Three directors wrote the scenes (dread, heart, spectacle) and two judges ruled on them: one asking "is it cool?", one asking "can we make it look real?". Every scene below is the version that passes both.

---

## Part 1. The overview (one page)

### The twelve

| # | Title | Chapter | Seconds | Built from |
|---|---|---|---|---|
| 1 | On the Hat | Prologue, the back doors | 95 | heart, with dread's PA line and spectacle's stadium lights |
| 2 | Last Lights | Prologue, the lot and the field | 110 | spectacle, with dread's strobe and heart's silence |
| 3 | The Board | Prologue end, the title | 50 | spectacle, with dread's key ring and turning wheel |
| 4 | First Night | Chapter 1, the shelter | 120 | spectacle's merge, staged the producer's way, with heart's and dread's best beats |
| 5 | Where's Mari | Chapter 3, home after the Mark | 70 | heart, with dread's silhouette and generator stutter |
| 6 | Knock | Chapter 4, Ray at the steel door | 85 | dread, with heart's Kessler and spectacle's Gus |
| 7 | Somebody Keeps the Lights On | Chapter 5, the roof | 110 | dread's ending, spectacle's staging, heart's sound |
| 8 | It's Me. Again. | Chapter 6, the wreck | 55 | heart, opened in first person as the producer asked |
| 9 | What Time? | Chapter 8, the nest | 95 | dread, with spectacle's and heart's lines |
| 10 | Right Behind You | Chapter 8, Kayla's pod | 100 | heart, with dread's palms and spectacle's reverse |
| 11 | Seeds | After the hold, dawn | 45 | spectacle, opened from Kayla's pod as dread wrote |
| 12 | We Waited | Epilogue, the gate in June | 75 | heart, shot far and backlit as the producer asked |
| | **Total** | | **1,010 s (16 min 50 s)** | about 3% of a 9 h 40 game |

The rhythm is deliberate: long, long, short (the prologue's three), long, short, middle, long, short, long, long, very short, middle. No two cutscenes run back to back without play between them. Chapters 2 and 7 have none: Chapter 2's turn ("They're breathing") and the whole flight are played.

### The ten rules of staging (why it will look real)

1. **Faces are close, brief and still. Bodies are far, from behind or in the dark.** Almost nothing in between: a whole body moving in full light is where a game without motion capture looks fake.
2. **The hard part happens in a cut.** Running, climbing, sitting down, unfolding, a fast exit: we cut as the move starts and pick it up after it ends ("cut on action"), or hide it in a blackout, a lens flare or a doorway. The sound tells you what happened.
3. **Objects carry the feeling.** A film camera, a drumstick, a skateboard, a guitar on a nail, a walkie's red light, a roll book. Objects are cheap to make beautiful.
4. **At most three people lit in a shot.** A group is one far, dark wide shot at low detail. The crowd at the game is sound through walls, light round doors and nothing else.
5. **No touching** except a hand on glass, or a hand closing on a sleeve: one hand, in close-up, under three seconds, posed by hand. Nobody hands anything to anybody on camera; objects reach people in play.
6. **The hunter only stands, stoops, turns its long face, reaches and waits.** It crawls, unfolds and runs only behind a cut, a blackout or a flare. Its whole face is held in a cutscene exactly once (twelve frames, scene 7); the favourite face lives in the first-person Mark and hold.
7. **Nothing graphic happens to a student or to anyone taken.** The taken look calm and whole: frost, closed eyes, nothing wet. Gore belongs to the creatures and to Danny's own deaths, and all of that is first person, never a cutscene.
8. **Nothing fakes Kayla on the radio.** Her voice on any radio in any cutscene is her.
9. **Every light is a real light in the place.** A trophy case, a caged bulb, a torch, a searchlight, a monitor, a pod's glow, the dawn. No invisible film lights on faces.
10. **One held beat per scene, three seconds at most.** Silence is allowed; dragging is not.

### The look

- **The same picture as the game.** Same colour grade, same grain, same 16:9 frame, **no black bars**: bars would make the hand-back jump. Gray-leaning with real faded colour; never an orange or copper wash; light you can see in the air (dust in beams, rain in the searchlight, steam in the landing light).
- **Three warm colours that mean people:** Danny's red beanie, Kayla's yellow rain jacket, and small red lights that mean someone is still there (the walkie's blink, Gus's flare). The hunter is always pale against black, lit by one hard light from above or from the side, the way the favourite picture shows it.
- **Lenses:** 35 to 85 mm on faces; a long lens (one that flattens distance, so far things look huge behind near ones) for scale: the stadium, the field, the roof.
- **Camera:** slow pushes and drifts, never shaky. Each scene opens by pulling back out of Danny's head and closes by pushing into his eye-line (exactly where he is looking).
- **Faces:** on High and below, strands hair only in close-ups, cards everywhere else, and groups at capped detail, so the shelter's eight fit in 16 GB; on Ultra, strands and top detail on every speaking face.

### Sound first

- **Every line is clear over everything.** Rain, rotors, alarms and engines dip under each line and come back after it ("ducking"). Lines are recorded close and dry, then given the real room's echo.
- **Every sound is a real recording**, one remembered sound per scene, chosen before the shots.
- **Music follows the game:** no music while the hunter is near; the songs only where the map puts them (Song 1 in the played lift, Song 2 in the played climb, Song 3 at the gate in scene 12). The only music inside cutscenes is Mari's guitar played in the room (scene 4), a guitar ringing by itself (scene 5) and Song 3's first chord (scene 12).
- **Faces from voices:** about 35 key lines are acted on a phone (face filmed while the voice is recorded) and the face is solved from that video; every other line drives the face from the audio. Each scene lists its phone-filmed lines.

### The hand-back (within two seconds, every time)

The last frame of every cutscene is Danny's (or, in June, Kayla's) own view: same position, same height, same field of view as first person. Then a hard cut to first person with the sound running on across the cut, and input live on the first frame. This is called a **matched cut**: because the two frames match, the cut is invisible. We do not rely on the engine's camera blend, which is reported broken in UE 5.8. Every cutscene is skippable at any time (skip lands on the same hand-back frame) and subtitled.

### The ten speaking faces

At most ten people in the whole game, first person included, have a face that speaks on camera. This set uses **nine**:

| Face | Speaks in cutscenes | Also speaks face to face in play |
|---|---|---|
| Danny | 1, 2, 4, 5, 6, 7, 8, 9, 10 | mirrors and dark glass only |
| Kayla | 1, 9, 10 (and laughs in 12) | prologue lot, Two Kaylas, the parachute |
| Marcus | 1 | none (asleep in the nest) |
| Kessler | 4, 6 | safe-room talks |
| Gus | 7 | "Away from the glass", the generator, the tunnels |
| Owen | 5, 12 (if he lived) | safe-room talks |
| Mari | 4 (laughs and hums, side-on) | Chapter 3 |
| Priya | 12 (if first at the gate) | "They're breathing", the notebook |
| Ray | none (a voice through steel) | the door in Chapter 1, "Say that again" |

The tenth slot is held in reserve. Never given a speaking face: the crowd, the helicopter crew (helmets and visors), the soldiers, Caleb, the laundromat boy, the taken. Only Danny and Kayla get long, well-lit close-ups; Marcus, Priya, Owen and Mari are always half-lit, side-on or brief.

### The order to build and test them (riskiest first)

0. **Before any scene: the hand-back.** One matched cut from a test sequence to first person, sound carried over, control inside two seconds.
1. **4 First Night.** It sits in the first slice's safe room: Danny's phone-filmed face, Kessler, the guitar hand, eight MetaHumans at low detail on 16 GB.
2. **10 Right Behind You.** Danny's and Kayla's faces held close for a minute: the teen-face test. A grey-box pod is enough.
3. **7 Somebody Keeps the Lights On**, in grey: rain on faces under caps, the searchlight in rain, the hunter's still pose, the flare.
4. **1 On the Hat.** Three teen faces in trophy-case light.
5. **2 Last Lights.** The mothership in cloud and the strobe poses; a memory test.
6. **11 Seeds.** The far break-up, the pods on their paths, the reused mothership; memory again.
7. **9 What Time?** Kayla's face waking behind frost.
8. **12 We Waited.** A backlit group behind chain-link in evening light.
9. **5 Where's Mari.** The failing grin; the silhouette fallback ready.
10. **8 It's Me. Again.** Rain, one face, one wreck.
11. **6 Knock.** A door, real knocks, two faces in torchlight.
12. **3 The Board.** Nearly free; build it once the corridor exists.

### The threads that run through all twelve

| Thread | Planted | Paid off |
|---|---|---|
| The film camera's flash | 1 (opens the game) | 8 (in the wreck), 9 and 10 (back with her), 12 (the same click closes it) |
| "Please remain in your seats" | 1 (the PA, clean) | 3 (whispered, torn, from behind the door) |
| The skateboard with the loud sticker | 1 (leaning on the trophy case) | 3 (rolling on its own) |
| The four stadium light banks | 1 (burning through the doors) | 2 (dying one by one) |
| "Swear on the hat" / "We'll be at the gate" | 1 | 12 ("We waited.") |
| The drumstick | 1 (held still, spun far off) | the nest, first person, in Marcus's hand |
| The Kessler impression | 4 | the hold, first person: his last joke |
| The promise, and the air grille | 4 | the hold: the hunter says it back |
| The guitar on the nail | 4 (Mari takes it down) | 5 (rings by itself), 12 (Owen's chord) |
| The generator's hum | 4 (home) | 5 (stutters once), the breach (dies) |
| A hand on glass | the hunter's hand, Chapter 1 (played) | Ray's hand on the monitor (played), 9 (Danny wipes the frost), 10 (palms that do not line up) |
| "What time?" | Two Kaylas, Chapter 4 (played) | 9 (Kayla tests him) |
| Kayla's yellow jacket | 1, 2 (the only colour) | the Mimic in Chapter 4, the fall in Chapter 5, 9 (under the frost) |
| Kayla's walkie | the whole school, her voice | 8 (his own voice out of it), 9, 10 (her voice moves from the glass to his ear), 11 (the hiss stops) |
| "Go. I'm right behind you." | the parachute (she says it, played) | 10 (he says it back, and he is lying too) |
| Gus's keys | Chapter 1 on | 7 (the keys jingle under his goodbye), June (tagged "for Kayla" if he died) |

**No image twice.** A motif may return (a hand on glass, a flash), but never the same picture: each return changes who, where and which side of the glass.

---
## Part 2. The twelve scenes

Words used: a **wide** shows the whole place; a **close-up** fills the frame with a face; an **insert** is a close shot of a hand or an object; a **long lens** flattens distance so far things look huge; **cut on action** cuts as a move starts and picks it up after it ends; **eye-line** is exactly where Danny is looking; a **matched cut** ends on Danny's own first-person view so the hand-back is invisible.

---

### 1. "On the Hat"

- **Where:** Prologue, about 6 minutes in. The player has walked the trophy corridor at halftime in first person (the cookie, the posters, his face in the trophy glass). Kayla raises her grandfather's film camera at him; her flash starts the scene.
- **Length:** 95 s.
- **On screen:** Danny, Kayla, Marcus. All three speak. The announcer is a voice only; the crowd is sound through a wall.

**The shots**
1. White: the flash, and the film shutter's real click. Out of the white the camera pulls back out of Danny's head to behind his shoulder. Over it, the PA, clean and booming in the gym's echo: "That's the half, folks. Please remain in your seats."
2. Close on Kayla lowering the camera, one eye still shut. (We never see the face Danny pulled; it is the last frame on her roll in June.)
3. Over Kayla's shoulder: Danny's red beanie in the warm glow of the trophy cases, half the ceiling tubes dead; Marcus leaning on the case, drumstick held still; his skateboard, one loud sticker, propped against the glass.
4. Kayla winds the film on, eyes on the camera, not on him: "My mom took the job. We move in June."
5. Close on Danny, half in the trophy glow. A beat too long. Then the grin: "So I'm the one who stays behind. Cool. Love that for me."
6. Insert: Kayla's thumb stopping on the wind-on lever.
7. Wide from the far end of the back corridor: the two from behind, walking to the glass back doors; beyond them, across the black lot, the stadium's four light banks burning white in the cold.
8. Outside, looking in: Danny hits the push bar; cold air, breath fog. Marcus has caught up and holds the door with his shoulder, gym light behind him: "You guys are leaving? It's halftime."
9. Same shot, Marcus already half turned: "Hang on, my board. You guys'll wait, right?"
10. Danny on the step: "We'll be at the gate." Marcus: "Swear on the hat." Danny taps the red beanie: "On the hat."
11. Through the wired glass of the closing door: Marcus runs back toward the trophy-case glow, small and blurred by the wire mesh, the drumstick spinning in his hand. The door's slow closer: the bar of light on the floor narrows to a line, and the crowd goes muffled.
12. Kayla steps out beside him; the camera drifts into Danny's eye-line: the dark lot, rows of cars, the four light banks far off.

- **The image:** Marcus through the wired glass of the closing door, running back toward the light. Every player who finishes the game will want that frame back.
- **The sound:** the film camera's mechanical shutter and wind-on ratchet, and the push bar clanking shut on the crowd. **The line:** "So I'm the one who stays behind. Cool. Love that for me."
- **Music:** none. The pep band through the wall stops when the door shuts.
- **The trick:** every line is spoken standing still, one face at a time. The walk is seen far off and from behind, where a library walk always looks right. Marcus speaks only while standing in the doorway; his run is far away and broken up by the wire mesh. The drumstick spins only in that far shot, never in a close-up. Kayla's camera hands are one hand-posed insert each, three seconds at most. Faces sit in the trophy cases' warm light, never under flat fluorescent tubes.
- **Phone-filmed lines:** Kayla's "We move in June", Danny's "Love that for me", Marcus's two lines, "Swear on the hat" / "On the hat".
- **The hand-back:** shot 12's view; first person in the doorway with Kayla at his right shoulder. The parking-lot walk and jokes are play.
- **Risk:** three teenage faces in the first two minutes; if they read as adults, the whole game is judged by it.
- **Fallback:** first person: the flash at the player, Kayla's lines to the player, Marcus in the doorway; keep shot 11 (Marcus through the glass) as the one cutscene shot. Danny's close-up becomes his reflection in the door glass.
- **Calls back to:** nothing yet. **Plants:** the flash (12), the PA line (3), the board (3), the four lights (2), the hat and the gate (12), the drumstick (the nest).

---

### 2. "Last Lights"

- **Where:** Prologue, about 12 minutes in. The player has walked the lot, got the laugh out of Kayla, and lived the pulse in first person: phones hot and dead, the streetlights dying street by street toward them. The scene starts when the dark reaches the school.
- **Length:** 110 s.
- **On screen:** Danny and Kayla (backs and silhouettes; one Danny close-up), the mothership, the small ship, the hunter in three still poses. Danny speaks once; Kayla whispers once, off screen.

**The shots**
1. Very wide and high over the town: every street dark; the stadium's four light banks the only light for miles; two tiny figures among dead cars.
2. Low behind the two: the clouds light up from above, as if dawn were coming from the wrong side. Kayla's yellow jacket is the only colour.
3. An endless underside slides through the cloud, crawling with slow lights like traffic seen from a plane; never a clean outline. It keeps coming until it is the whole sky. No sound.
4. Behind them, the gym: the confused noise of the crowd through the walls stops all at once. A thousand people going quiet.
5. Insert: Kayla's fingers find Danny's hoodie sleeve and close on it. They stay closed.
6. Close on Danny, chin up, lit cold from above: "Okay. That's... a lot of ceiling."
7. Wide on the stadium: the ship's shadow crosses the field and the light banks die one at a time, each with a heavy clunk. The fourth holds, buzzing.
8. Hold on the fourth bank. Off screen, Kayla, hardly a sound: "Danny." It dies. One full second of black.
9. A point of light falls from the belly and becomes a small ship slamming onto the 50-yard line. The turf jumps; steam rolls out, lit from inside by a landing light that ticks on and off.
10. Long lens through the chain-link. On: steam. Off. On: it is half out of the open hatch, a held pose: hood and shoulders out, both long veined hands flat on the turf at the steam's edge, legs still inside. Off. (This is the owner's "someone crawls out": the crawl is shown as this one held pose, the rest in the dark.)
11. In the dark, a run of joints opening one after another, like a ladder pulled to full height. On: the hatch is empty. Off.
12. On: it stands in the thinning steam, three metres tall, stooped, hooded, its back to us. Off. On: still there, the same pose.
13. Danny drops behind a car; the cut comes as he starts to drop.

- **The image:** shot 7, a ship the size of a district putting out a football field's lights one bank at a time. This is the poster.
- **The sound:** the four clunks, then the mothership's total silence (a pressure in the ears, felt more than heard), then the landing light ticking like a relay. **The line:** "Okay. That's... a lot of ceiling."
- **Music:** none from shot 9 on (the hunter is here), and none before it either: silence is the score.
- **The trick:** nobody moves but one hand on a sleeve and one drop hidden by the cut. The ship is one big low-detail model kept inside volumetric cloud as slow lights; the stadium is four lights switching off. The hunter's crawl and unfolding, the hardest animation in the game, are never shown: every change happens in the black between flashes, and each "on" is a held pose checked against the favourite picture (the stoop, the hood, the veined hand). The unfolding is a sound over darkness.
- **Phone-filmed lines:** Danny's "a lot of ceiling".
- **The hand-back:** shot 13 cuts to first person crouched between two bumpers, Kayla's breath beside him, the field to his left. In play the hunter is already standing and only turns its long face toward the school. Kayla: "Band-room door. Go." The sneak begins.
- **Risk:** the ship reading as a painting; the hand reading as a rubber glove.
- **Fallback:** keep the ship as lights moving across cloud only; if the hand fails, shot 10 becomes a wet slap on turf heard over black, and the first look is the standing pose.
- **Calls back to:** scene 1's four light banks and the crowd through the wall.

---

### 3. "The Board"

- **Where:** Prologue end. The player crept back in, Kayla fell on the basement stairs, and Gus said "You two. Down. Now." Gus swings the steel door shut.
- **Length:** 50 s, then the title.
- **On screen:** Gus's hands; Danny and Kayla only as reflections. No faces speak. One whisper.

**The shots**
1. Insert: Gus's hands drop the bar into its brackets. Clang. His key ring trembles on the bar; nothing else of him moves.
2. Through the door's small wired window: the long basement corridor, its tubes still lit.
3. The tubes die from the far end toward the door, one by one, a soft tick each: the pulse again, indoors.
4. In the last two tubes' light a skateboard rolls in from a side hall on its own, its wheels clicking over the tile joints.
5. Slower, the clicks further apart. It stops in the middle of the corridor. One wheel still turning. The loud sticker faces up.
6. The last tube dies. In the black glass, lit from behind by Gus's torch, two faint reflections: Danny, and Kayla, who knows that sticker. Neither speaks.
7. Black, two full seconds. The player thinks it is over.
8. From just behind the door, close, the announcer's own voice torn into pieces: "...remain... in your... seats."
9. STAY BEHIND, white on black, in silence.

- **The image:** the skateboard alone under the last tube, through wired glass, one wheel turning.
- **The sound:** the wheel clicks over the joints, further and further apart, from a real board on a real floor. **The line:** "...remain... in your... seats." It must sound like the PA voice torn up, not a monster voice. It teaches the game's first rule (a whisper means it is right here) in minute fifteen.
- **Music:** none. The title comes up in silence.
- **The trick:** almost nothing to animate: two hands, one physics object on a guided path that slows like a real board, a timed row of lights, two soft reflections instead of faces.
- **The hand-back:** after the title, first person facing the black window. Gus's torch clicks on behind: "Away from the glass." Chapter 1 begins.
- **Risk:** the roll looking pushed by a script.
- **Fallback:** hear it roll in the dark and show it already stopped in the last light.
- **Calls back to:** scene 1 (the board on the trophy case, "remain in your seats", "You guys'll wait, right?").

---

### 4. "First Night"

- **Where:** Chapter 1, the first night in the shelter, after the generator, the food run and Flare Road. Everyone who will arrive has arrived.
- **Length:** 120 s.
- **On screen:** all eight, never more than three lit at once. Faces that speak: Kessler, Danny. Owen laughs (seen from behind); Mari laughs and hums, side-on in the dark. Gus is seen, silent.

**The shots**
1. High and wide from the shelter stairs: eight small people on cots and crates in one caged bulb's pool, the yellow-and-black 1962 signs, black to every wall, the steel door at the light's edge. The generator hums.
2. Kessler standing with the sign-in sheet, the only face lit, her finger moving down the room: "Six. Seven. Eight." A pause. Lower: "Eight."
3. What she counts, low and close: knees, a pair of sneakers, Owen's shaking hands, a red beanie.
4. Danny on a cot, half-lit, unable to stand the silence: "Eight. Great number. Very... round."
5. Kessler, without turning: "Mr. Reyes. Is something funny?"
6. Danny, chin tucked, her voice exactly: "Is something funny?"
7. Owen from behind: a snort, then a real laugh behind his hand. Mari grins at the floor in the dark.
8. Kessler, after a beat, almost a smile: "...The chin's too low." Then, folding the sheet into her cardigan pocket, the smile gone: "We stay behind this door until help comes." Behind her, Gus looks at the door, then at the generator. He does not nod.
9. Over Mari's shoulder: she takes the cheap guitar off its nail above her cot. Insert: her strumming hand, one bad string, the first notes of the camp song; the fretting hand stays in shadow.
10. Mari side-on, eyes shut, humming more than singing.
11. Danny on the floor in the generator-room doorway, his back to the machine, feeling it shake. He hums one bar along, wrong. Mari laughs without stopping.
12. The song ends; Mari damps the strings with her palm. Only the diesel.
13. Close on Danny, not looking at anyone, held still, no cutaway: "I'm getting everyone out. All of you." A breath. "Which, historically, from me, means nothing." Another. "But."
14. Kayla, her strapped ankle up on a crate. She is the only one who knows what "historically" means. She looks down.
15. The camera leaves them and drifts up the wall to an air grille near the ceiling. Three seconds. Dust shivers in the slats; under the hum, one tick of metal in the duct.
16. Back down into Danny's eye-line: he is looking up at the grille.

- **The image:** shot 1, eight small people in one caged bulb's light under 1962 signs: this game's picture of home.
- **The sound:** Owen's laugh (a real recorded laugh, the first since halftime) over the generator's hum; then the camp song, live, one string flat. **The line:** the promise. The hunter says it back at the hold; the Kessler impression becomes Danny's last joke there.
- **Music:** only Mari's guitar, played in the room: the game's first music comes from a person.
- **The trick:** everyone sits or stands still on library idles and breathing. Only Kessler's face is lit during the count; the others are hands, shoes and a beanie, which hides five teenage faces and keeps eight people at low detail inside 16 GB. The impression is two close faces only. The guitar is one strumming hand filmed on a phone with its own audio (never matched by hand afterwards); the fretting hand stays in shadow; Mari's face is side-on and dark, so there is no singing to lip-sync. The promise is one still, phone-filmed face with real pauses. The grille needs no one.
- **Phone-filmed lines:** Kessler's count and "Is something funny?", Danny's impression, the promise.
- **The hand-back:** first person sitting against the generator, looking up at the grille; free to stand. Owen's request (to be walked past the dark tunnel) follows in play.
- **Risk:** eight MetaHumans in one room; guitar fingers out of time look fake faster than anything.
- **Fallback:** if the strum fails, the guitar goes out of focus and the song is heard over faces listening. If faces fail, shot 1 stays as the opening wide and the talk plays in first person from the cot (the impression still lands, coming out of the player's own mouth).
- **Calls back to:** scene 1's red beanie; the steel door of scene 3. **Plants:** the impression and the promise (the hold), the grille (the hold), the guitar on the nail (5, 12), the hum (5, the breach), Kayla's look (9).

---

### 5. "Where's Mari"

- **Where:** Chapter 3, the safe room, after the Mark, Mari taken, and the hurt crossing of the live floor home.
- **Length:** 70 s.
- **On screen:** Danny, Owen, Kayla; Kessler and Gus seen. Faces that speak: Danny, Owen.

**The shots**
1. The steel door from inside swings open on Danny: a silhouette against the tunnel's red exit sign. He does not step in yet.
2. The group turns: the backs of heads, one after another, in lamp light. Past them, Mari's made cot, her guitar on its nail above it.
3. Danny steps in, from behind, his sleeve pulled down over his left hand. The grin is on too fast: "So. Good news and bad—"
4. He stops. Close, half-lit: the grin stays two seconds after the joke has gone.
5. Owen, from a dim cot, half his face lit: "Where's Mari?"
6. Danny, flat: "...Yeah."
7. Floor-level wide: he bends to sit on the nearest cot (cut on the bend) and is sitting on it. It is hers. Nobody moves.
8. Insert: his pack at his feet, the paper packet of guitar strings sticking out of it.
9. Gus pushes the steel door shut. On the nail above Danny's head, the guitar's strings ring with the slam: a soft, out-of-tune chord nobody played.
10. Kayla, across the room, sees the sleeve pulled over his hand. She does not ask yet.
11. The generator's hum stutters once and recovers. Nobody but the player notices.
12. Push into Danny's eye-line: his own cuff, and under it the edge of black lines.

- **The image:** Danny on Mari's empty cot, the guitar on the nail above his head, the strings sticking out of his pack.
- **The sound:** the guitar ringing by itself when the steel door slams. **The line:** "Where's Mari?" / "...Yeah." It must be flat, never sad.
- **Music:** none but that chord.
- **The trick:** one walk in, seen from behind; then everyone is still. The sit-down hides in a cut. Objects carry the grief. The failing grin is the hardest face in the game: about two seconds, half-lit, phone-filmed. The Mark stays under a sleeve, saved for the player's own first-person look.
- **Phone-filmed lines:** "So. Good news and bad—", "Where's Mari?", "...Yeah."
- **The hand-back:** first person sitting on Mari's cot, his sleeve in view. The night's choices are played: show Kayla the Mark or hide it, tell the group about the seats, share the notebook. The strings stay in his pack, as the map says.
- **Risk:** the grin reading as acting; "...Yeah." played sad.
- **Fallback:** Danny stays a silhouette in the doorway for the whole scene; or first person, with Owen's question asked straight to the player. The guitar's ring survives any version.
- **Calls back to:** scene 4 (the guitar taken off this nail, the laugh, the hum).

---

### 6. "Knock"

- **Where:** Chapter 4, the safe room after dark. Ray went out alone for his son's letterman jacket. The player has just spent an hour on the Mimic floor, where a voice with the same timing twice is not a person.
- **Length:** 85 s.
- **On screen:** Kessler, Danny, Kayla speak; Gus is seen. Ray is a voice and knocks only, never on screen.

**The shots**
1. Wide from the far end of the shelter: the steel door, its bar, its black window. Three knocks.
2. Everyone still. Gus's hand on the bar. Cut: Kessler is already between him and the door. "Don't."
3. Through the steel, muffled and real: "It's Ray. Ruth, it's me. I got his jacket. Open the door."
4. Kessler, close, in torchlight: "The things up there sound like people."
5. Danny: "That's Coach. That's his voice." Kessler: "That's what I'm saying, Mr. Reyes."
6. The same wide. The camera has not moved. Three knocks: the same rhythm, the same spacing.
7. Kayla, by the dead monitors, barely a voice: "Those were the same."
8. Silence. Then one knock, tired, uneven, low on the door, as if a man had sat down against it. "...Please."
9. Insert: Kessler's thumb on the sign-in sheet, over DOBBS. She does not cross it out. She does not let go.
10. Kessler, very quietly, to the door, not to Danny: "I count my kids, Mr. Reyes. I can't count him."
11. Gus says nothing. He tilts his torch so its beam lands on the tunnel hatch in the floor, and looks at Danny.
12. Danny's eye-line: the hatch in Gus's beam.

- **The image:** the steel door, wide and still, everyone frozen in front of it while the same knock arrives twice.
- **The sound:** real knuckles on real steel. The doubled rhythm is the scare; the words, which never repeat (a Mimic says the same line with the same timing), and the tired low knock are the hope. A careful player can hear it is Ray, and still has to check. **The line:** "I count my kids, Mr. Reyes. I can't count him."
- **Music:** none.
- **The trick:** nobody moves; the door does the acting. Kessler steps between Gus and the door across a cut. Ray is never shown, because seeing his face would answer the question the player is meant to test through the hatch.
- **Phone-filmed lines:** Kessler's "sound like people" and "I can't count him"; Danny's "That's Coach."
- **The hand-back:** first person standing over the hatch, Gus's beam still on it. Go round through the tunnel and test him, or leave the door shut.
- **Risk:** Kessler playing as a villain. Shot 9 and her last line are there to stop it: she sounds frightened, never cold.
- **Fallback:** first person at the door with voices only; Kessler's face in front of the player.
- **Calls back to:** the hunter's hand on this door's window in Chapter 1 (played); scene 4's sign-in sheet; the Mimic rule from Chapter 4.

---
### 7. "Somebody Keeps the Lights On"

- **Where:** Chapter 5, the roof. The hunter's one long chase (played) ends as the player runs into the helicopter's searchlight.
- **Length:** 110 s.
- **On screen:** the hunter (far, then one face turn), the crew chief (a glove only), the survivors as silhouettes, Kessler (hands and voice), Gus, Danny. Faces that speak: Gus, Danny.

**The shots**
1. Very wide from the next roof: the school black in the rain; the helicopter is only a searchlight whose beam is a solid white column of rain, and a dark mass above the glare.
2. Long lens across the roof: at the beam's far edge, the hunter stands to its full height. Still.
3. Closer: the beam crosses it, and for twelve frames the long pale face turns into the light, two pins in two black eyes.
4. The beam flares white straight into the lens.
5. The flare clears: the parapet is empty. Below the edge, one heavy step on metal.
6. Insert: the crew chief's gloved hand in the beam, five fingers spread.
7. Insert: Kessler's hands on the soaked roll book, her voice reading names through the rotors. (If the group knows about the seats: no book; voices say each other's names.)
8. Silhouettes step one at a time into the white and are gone, one per cut. Kayla's yellow is one of them.
9. Danny at the edge of the cabin door, turning back: Gus has not moved. He stands at the edge of the light, cap low, keys on his belt.
10. The rotors drop away under his voice and his keys jingle. Close, under the cap: "I don't fly. Never have."
11. Danny: "Gus."
12. Gus: "Somebody keeps the lights on, son. Go on."
13. **If Danny brought his hearing-aid batteries in Chapter 2:** Gus touches his ear. He has heard it. He strikes a red flare (the rotors come back like a wave) and walks away from us toward the stair hut, the flare held high, keys swinging.
    **If not:** Gus lifts his torch and waves it up at them. Behind him, at the stair-hut door, at the very edge of the beam, the long pale face, lower than the doorway because it is stooping. Already there. Still. Gus does not turn. The rotors come back.
14. Cut on action: Danny is inside the door and the roof is dropping away; the searchlight slides off Gus (a small red flare at the stair hut, or a torch still waving in front of a dark doorway).
15. Danny's eye-line down at the dark roof.

- **The image:** the second version of shot 13: Gus waving his torch up at the helicopter while the long face waits stooped at the stair door behind him, half in the beam. The first version's picture, a red flare walking away into the rain, is the hopeful twin.
- **The sound:** Gus's keys under his lines, with the rotors dropped out, then returning like a wave on the flare strike or the wave of the torch. One heavy step on metal after the hunter vanishes. **The line:** "Somebody keeps the lights on, son. Go on."
- **Music:** none: the hunter is on this roof. Song 1 starts only once they are clear, in play.
- **The trick:** the helicopter is light, rotor wind on puddles and a dark shape above the glare, never a detailed hovering model. Boarding is silhouettes stepping into the white, one per cut, so no group ever moves on screen. Kessler's list is an insert of hands. Gus wears his cap and Kessler her hood, so no loose wet hair is in close-up; Gus's two close-ups are the only faces in rain. The hunter is a still pose; its exit is hidden by the flare; its approach to Gus is never shown. Danny boards across a cut. The twelve frames of the face are the only time the favourite face is held in any cutscene.
- **Phone-filmed lines:** Gus's three lines, Danny's "Gus."
- **The hand-back:** first person at the open cabin door, looking down at the roof; free to look round. Song 1 begins as they climb (the played lift). In the version where Gus was helped, one basement window comes on below as they rise; in the other, the school stays dark. Whether Gus lived is only told in June.
- **Risk:** the riskiest scene in the set: rain and wind on faces, a hovering light, several bodies, two endings and the board list.
- **Fallback:** split it. A far wide (shots 1 to 5), boarding in first person into the white, then a short cutscene of Gus's goodbye only (shots 9 to 13). If faces in rain fail, Gus speaks as a silhouette against the searchlight.
- **Calls back to:** Chapter 2's hearing-aid batteries (a quiet choice paid off with no meter); scene 4's "We stay behind this door"; Gus's keys from Chapter 1; the generator (the lit window).

---

### 8. "It's Me. Again."

- **Where:** Chapter 6, about forty minutes in, after the player has talked into a dead radio all chapter. **It opens in first person:** at the wreck, Danny's thumb comes into view on the talk button and he says, quietly, the line he has said all night: "Kayla. ...Hey. It's me. Again." Half a second later, from inside the wreck, small and tinny, his own voice says it back. The cutscene cuts in on that echo.
- **Length:** 55 s.
- **On screen:** Danny alone. Danny speaks.

**The shots**
1. Wide, rain, a dark street: the helicopter on its side across two cars, its rotor bent into a shopfront; Danny small beside it, frozen.
2. Close on Danny's face in his torch's spill: the city chapter's one look at him.
3. His torch finds a seat: Kayla's walkie lying in rainwater, its little red light blinking. Beside it, her grandfather's film camera, the strap tangled in a seatbelt.
4. Insert: his hand picks up the walkie and switches it off. The red light goes out.
5. Insert: his hand works the camera's strap free of the belt.
6. Close: the joke tries to come and doesn't quite: "...Cool. So I've been talking to a seat." Thrown away, never pitied.
7. Wide again: empty seats, rain drumming on metal. Far off, a Patrol scanner tone.
8. Push into his eye-line: the film camera in his hands, its frame counter.

- **The image:** a walkie blinking red on a wet seat in a dead helicopter, with Danny's own voice coming out of it.
- **The sound:** his own voice coming back to him from the wreck, half a second late. Then rain on metal. **The line:** "...Cool. So I've been talking to a seat."
- **Music:** none.
- **The trick:** the reveal is the player's own button press, which costs nothing and lands harder than any cut. After that: one man crouched in rain and torchlight, a static wreck, two hand inserts. Nothing fakes Kayla: the voice from the walkie is Danny's.
- **Phone-filmed lines:** "So I've been talking to a seat."
- **The hand-back:** first person looking down at the camera in his hands, her walkie on his belt. Talking still works; still nobody answers.
- **Risk:** the line turning into self-pity; his face in hard torchlight.
- **Fallback:** all first person: press talk, hear yourself in the seat, pick up both. It stays a cutscene only for his face.
- **Calls back to:** scene 1's film camera and its flash; every "Stay on the line" of the school. **Plants:** the walkie and camera reach Kayla in the nest (scene 9) and are with her in the pod (10, 11).

---

### 9. "What Time?"

- **Where:** Chapter 8, the nest. In first person the player has put the drumstick in Marcus's hand, then set Kayla's walkie and film camera down on the rim of her cradle to work the waking symbols with both hands.
- **Length:** 95 s.
- **On screen:** Kayla and Danny speak. Marcus and Mari are still figures, out of focus.

**The shots**
1. Wide and dim: a low chamber of wet membrane and frost, cradles in a curve like seed pods in blue light; Danny kneels at one, seen from behind.
2. Kayla beneath the frosted lid, only the shape of her face; under the frost, the yellow of her jacket.
3. Insert: Danny's palm wipes a patch of frost clear.
4. Her face through the handprint, still. Then her breath fogs the inside of the glass.
5. Out of focus behind them: Marcus in his cradle, frost in his eyebrows, headphones still round his neck, the drumstick in his hand, calm and whole; Mari beyond him. Both their lips move with a murmur whose words never quite land.
6. The lid lifts a hand's width by itself and stays; its frosted edge sits across the bottom of every shot of her face from now on. Kayla's eyes open and find him. She does not trust what she sees.
7. Kayla, hoarse: "What time?"
8. Danny. The joke doesn't come: "Four."
9. She breathes out: "...Danny." Insert: her hand finds her walkie on the rim and closes on it.
10. Her eyes go to his arm: the black lines have climbed past the elbow. If he showed her the Mark in Chapter 3: "It's higher." If not, a silence, then: "How long?"
11. Danny: "If I get in one, they follow it." A beat. "They follow you."
12. Kayla: "No." He starts a joke, and lets it go.
13. Kayla, the only time her face fills the screen: "You're not your dad, Danny."
14. Behind them, Marcus's and Mari's lips stop at the same moment. Silence.
15. Danny's eyes go to the nest's dark mouth.

- **The image:** Kayla's breath fogging the inside of the lid under Danny's handprint.
- **The sound:** the murmur of the sleepers, then all of it stopping at once. In this game, when the whispering stops, it has noticed you. **The line:** "What time?" The code word that kept him safe from the Mimics is turned round: she has slept among the hunter's voices, so she tests him.
- **Music:** none.
- **The trick:** Kayla lies still: eyes, breath, a few words. The lid moves itself. Danny kneels throughout; the only touch is his palm on glass, and her hand on her own walkie. The taken are held poses whose lips are driven by the murmur audio, out of focus. Frost on the lid's edge stays in the foreground and softens the second most important face in the game.
- **Phone-filmed lines:** "What time?", "Four.", "...Danny.", "It's higher" / "How long?", "If I get in one...", "You're not your dad, Danny."
- **The hand-back:** first person kneeling, Kayla behind him, the dark mouth of the nest ahead. Waking the others is played at once, while it comes. She takes her camera from the rim herself, in play.
- **Risk:** Kayla's waking face held close.
- **Fallback:** the lid stays shut and frosted; we see her only through the cleared handprint, and her lines come through the glass.
- **Calls back to:** Two Kaylas in Chapter 4 ("What time?" / "Four"); scene 4 (only Kayla knows what "historically" meant: the father, said aloud for the only time); the Mark from Chapter 3; scene 8's walkie and camera; the drumstick from scene 1.

---

### 10. "Right Behind You"

- **Where:** Chapter 8, the pod bay, after the core's final exam and the run to the pods (played, catching Kayla's hand as a deck tilts). The freed are already sealed in their pods; Kayla is already strapped into hers.
- **Length:** 100 s.
- **On screen:** Danny outside the pod, Kayla inside it, curved glass between them; still faces at other pod windows. Both speak.

**The shots**
1. Wide: the pod bay coming apart in slow pieces, sparks falling at the edges of the frame; a curved row of sealed pods, a still face at each small window.
2. Through the curved glass: Kayla strapped in, her walkie clipped to the harness, the film camera on its strap round her neck; Danny outside; both faces close, sparks running down the glass between them.
3. Danny, grinning: "Go. I'm right behind you."
4. Kayla, a long look at his mouth: "You're lying. You do the thing with your mouth."
5. Danny, the grin almost making it: "I don't have a thing."
6. Kayla: "You have a thing, Danny."
7. Insert: her palm flat on the inside of the glass. His goes flat on the outside, a little off from hers. They do not line up.
8. The seal closes with a hiss and cuts her voice mid-breath. Frost closes in from the edges until her face is gone.
9. A click on the radio on Danny's chest, and her voice, clear in his ear: "Stay on the line, okay?"
10. Danny: "Yeah."
11. From inside the pod: his hand flat on the frost, the black lines on his wrist, his face a blur behind. He takes it away; the print stays a moment, then fills in.
12. Through the floor, one heavy step. Then another, nearer than the first could be.
13. Push into his eye-line as he turns: the release panel, one glyph lit on it. Hold.

**By ending** (all four lines are recorded; only two face versions are animated, awake and asleep):
- *Everyone he could* and *The line:* as written; they talk to the white.
- *The recording:* she believes him. Shots 4 to 6 become her, dazed: "...Okay. Right behind me." Shot 9 is her breath on the radio, then nothing.
- *Only her:* she is asleep. Danny says shots 3 to 6 to her sleeping face, answering himself on 5. Shot 9 is silence.

- **The image:** two hands flat on either side of a pod window, not lined up, as the frost closes over her face.
- **The sound:** her voice moving from muffled behind the glass to clear in his ear. It is the best sound in the game and the reason it was built. **The line:** "You have a thing, Danny."
- **Music:** none: it is coming.
- **The trick:** she is already strapped in, so nobody climbs; two still faces through curved glass, softened by reflections, condensation and sparks; hands meet only through glass; the ship's destruction is sparks at the frame's edges. The walkie reached her in play, so nothing is handed over. Spend the best phone takes of the whole game here.
- **Phone-filmed lines:** all six lines and "Stay on the line, okay?", in both the awake and dazed readings.
- **The hand-back:** the first-person hold begins on the same frame, the player's hand going to the panel.
- **Risk:** the two most important faces, held close for a minute.
- **Fallback:** first person through the glass: Kayla's face close in the window, hands on the glass from Danny's side only; keep shot 11 (no face needed).
- **Calls back to:** the parachute in Chapter 5, where Kayla said "Go. I'm right behind you" and was lying (now he says it, and so is he); the hunter's hand on the wired glass in Chapter 1 and scene 9's handprint; scene 8's walkie; the Mark.

---

### 11. "Seeds"

- **Where:** straight after the hold: the Kessler voice, her laugh, the true thing, his hand closing, white.
- **Length:** 45 s, then June.
- **On screen:** Kayla in her pod (still, no line), the pods, the mothership. No one speaks.

**The shots**
1. The white thins into the view through Kayla's pod window: dawn blue, through frost.
2. Inside her pod: her face lit gold through the frost, the walkie in her hand, hissing. (In *Only her*, her eyes are closed.)
3. Very wide from far above: the city under thin cloud, the mothership small now against the size of the sky. From its flank pods drift out and fall in a long slow arc, each with a small light, like seeds blown off a dandelion. There are as many as the people Danny freed.
4. Far wide: the mothership breaks along its spine without a sound, light running through the cracks.
5. Seconds later the sound arrives: a long low roll, like thunder a long way off.
6. Insert: the walkie in her hand. The hiss stops.
7. The camera rises past the falling pods into empty sky. The sky holds, warms, and becomes June; it tilts down to a mended street outside the school at Kayla's eye height.

- **The image:** pods leaving a dying ship like seeds at dawn. Their number is the ending the player earned.
- **The sound:** the gap between the silent break and the thunder reaching us, then the walkie's hiss stopping. **The line:** none; Danny has said everything.
- **Music:** none. Song 3 waits for the gate.
- **The trick:** no person moves. Pods are small lit objects on set paths; the break-up is a few large pre-made pieces with light running through them, seen only from far off (no physics simulation); the mothership is the prologue's far model again; the city is lights under cloud. The four endings change only the number of pods and whether her eyes are open.
- **The hand-back:** first person as Kayla in that street in June. The epilogue is played.
- **Risk:** the break-up looking like a cheap explosion.
- **Fallback:** no break-up on screen: a flare of light where the ship was, then the thunder. The cheapest version is twenty seconds in first person at her pod window.
- **Calls back to:** scene 2 (the same ship, now small; the scale it opened, closed); scene 10's walkie.

---

### 12. "We Waited"

- **Where:** Epilogue, June, played as Kayla: the shelter wall, the chores, the developed film (the last frame is Danny pulling a face), his tape. She walks out to the field.
- **Length:** 75 s.
- **On screen:** Kayla; whoever lived, standing at the gate. One face speaks two words; Kayla only laughs.

**The shots**
1. Wide, June evening, low sun: the chain-link gate seen from the field where the small ship landed; new grass in the scar.
2. Kayla from behind, walking to the gate, the film camera round her neck.
3. Reverse, from far off: on the other side of the chain-link, backlit by the low sun, the people who lived, standing still; faces too small and too dark to read. (*Everyone he could:* Gus if he lived, Owen with Mari's old guitar, Priya, Ray and Caleb, Kessler. Fewer with fewer.)
4. Close on Kayla. She stops.
5. Close on the first of them, flat and tired, never acted: "We waited." (Owen if he lived; otherwise Gus, Priya, Ray or Kessler, in that order.)
6. Kayla's face: a laugh she didn't want, crying: the same laugh as on the radio at the hold.
7. She lifts the film camera, one eye shut. The click; the flash whites out the frame, the same click that opened the game.
8. Out of the white, back at the gate. If Owen is there, one chord on Mari's old guitar; Song 3 begins.
9. Push into her eye-line: the gate, open.

**Only her:** shot 3 is the empty gate; shot 5 is silence; in shot 7 she photographs the empty gate anyway; Song 3 begins on one voice, with no chord.

- **The image:** tired people standing still behind a chain-link gate in June light, and Kayla's flash going off at them.
- **The sound:** the shutter, the same click as scene 1; then the first chord of Song 3. **The line:** "We waited."
- **Music:** Song 3, from shot 8, as the map puts it.
- **The trick:** everyone at the gate stands still, far off, backlit and behind chain-link, so up to seven people in daylight never show a face; only the speaker and Kayla get close-ups. Kayla walks from behind. The photo replaces the hugs nobody could animate.
- **Phone-filmed lines:** "We waited.", Kayla's laugh.
- **The hand-back:** first person as Kayla at the open gate. The credits roll over play: she walks through and down the street, with them or alone, and the game ends with the song.
- **Risk:** a group in daylight is the most exposed picture in the game; "We waited" tipping into melodrama.
- **Fallback:** play shots 4 to 9 from Kayla's eyes; the flash and the chord survive any version.
- **Calls back to:** scene 1 ("You guys'll wait, right?" / "We'll be at the gate", sworn on the hat, and the flash); scene 4's guitar; scene 5's empty cot.

---
## Part 3. The story moments that stay in first person, and how each is directed

Fear belongs in the player's hands. These are not cutscenes, but each is directed: what the player is made to look at, what he hears, and what is never taken from him. Rules for all of them: the camera is never turned for the player (we make him want to look, with light and sound); movement may be slowed but control is never removed for more than a few seconds; lines are as clear as in a cutscene.

**Prologue**
- **The pulse.** Phones go hot in pockets; Kayla throws hers and it hisses on the asphalt; car alarms choke off; the streetlights die street by street toward the player. Hand to scene 2 the moment the dark reaches the school.
- **The sneak back in.** The hunter is already standing on the field and only turns its long face toward the school, in full view through the bleacher slats. It cannot fail the first time; the near miss is staged with its head turning past the player's hiding place.

**Chapter 1**
- **The hand on the glass.** Ray hammering, Gus at the bar, the player two metres behind. The one bulb is aimed at the door so the wired window is the grey square the eye goes to. As the door opens, the hunter's hand is flat on the glass behind Ray, fingers spread, the face above the light. Gus sees it (his face drops, his torch swings); nobody turns the player's head. The door shuts; the palm slides down the glass with one wet squeak.
- **The first outage.** Everyone counting aloud in the dark while Gus works; the voices are the light.

**Chapter 2**
- **The hunter walks onto the gym floor.** Its heavy steps through the maple; the Listeners rush it and it swats one into the lockers. The player is placed so the swat is in view at the edge of his torch; the gore is the creature's, never a person's.
- **"They're Breathing"** (the turn), at the monitor desk. A grainy, jerky security feed at a low frame rate: frosted cradles floating out to a small ship on a ribbon of light, a soldier walking beside each; nobody carries anything. Priya, flat: "They're bodies. They're just moving the bodies." Kayla zooms; the picture breaks into blocks; a soft oval clears in a lid's frost, fades, clears again. Priya: "They're breathing." Ray, from the dark behind: "Say that again." Priya: "They're *breathing*." Ray's big scraped hand comes into view and presses flat on the monitor glass over the cradle. Then one soldier on the feed stops and turns its lamp straight up into the lens; the picture whites out and the feed dies. In first person, it looked at you. One bowed-metal note rises on the breath and is cut dead with the feed.

**Chapter 3**
- **The Mark.** A whisper right behind him (Marcus's broken voice); the player turns, which is the floor's trap. The view rises as his feet leave the boards. The favourite picture at full size: the long face comes down out of the dark into one hard stage light, upside down into the frame, the seam, the black almond eyes with one pin of light each, the dark tear-lines, the slit at the tip, the grey hood hanging like a wet blanket, one big veined hand gripping the proscenium beside it the way it grips the lockers. His own forearm is lifted into view; one long finger is pressed to it; frost crackles. He is put down. Mari calls "Danny" once, far off. Black. No body is ever shown, only face, hand and the rising view.
- **Waking.** The first thing the player is given is his own arm, black frost-lines growing a few millimetres while he looks. Then he must look up: the Still Ones stand round the stage, faces turned away, one a step nearer than it should be. At the edge of the work light, Mari's hair clip on the boards. Getting home across a live floor in failing light is played.

**Chapter 4**
- **Two Kaylas.** The yellow rain jacket lit from the side so it is the only colour on the floor, facing away: "Danny, over here," three times, with no breath before it and the same timing. The player holds the whisper key: "What time?" It asks it back in her voice. The real "Four. Why are you asking me... oh." comes from behind, with breath and the room's real echo. To look at her the player must turn his back on it; when he looks again it is a step closer, in the same pose. "Something up here's wearing your jacket." "...Is it a good look?" Played face to face.

**Chapter 5**
- **The breach.** Heard, never seen. Over the radio, under Kayla's "It's in. It's inside, Danny," the generator's hum winds down to nothing. Five chapters of home, gone; the silence is the scene.
- **The roof chase.** The built obstacle run over ducts and skylights into the searchlight; hand to scene 7 on the light.
- **The lift.** Seated in the cabin, look round only. Song 1. Kayla's hand on the bench a finger's width from his. The city small below, the mothership's lit belly filling the top of the window; if Gus was helped, one basement window lit below. Danny: "Kayla—" She turns. The song is cut mid-word by the missile. A quarter-second of white.
- **The parachute.** The cabin spinning, red light, the crew chief down. Kayla's face fills the view; only her hands are seen, clipping the chute to his chest (in first person the two-body problem vanishes). "Go. I'm right behind you." The shove. Wind, the canopy's crack, the city swinging into place. The descent steadies for five seconds over the wreck three blocks away: among the Patrol lamps, something taller than the soldiers lifts a small figure in a yellow jacket. He can look away; it is still happening.

**Chapter 6**
- **The landing.** A Patrol searchlight finds him within seconds; the chase over roofs and down a fire escape is played.
- **His building.** His mother's note on the door; the player writes under it in Danny's hand. On the fridge, a clean rectangle where a photo used to be (set dressing only: the father is never named here).
- **The rooftop whisper.** From a rooftop the hunter whispers Kayla's "stay... on the... line" while the radio on his chest stays dead. The only time her voice is used against him, and never on a radio.
- **Takedown.** The struggle from behind is in his own hands, never a cutscene.

**Chapter 7**
- **The canopy hand and the climb.** Its hand flat on the canopy for a long minute until scraped off on a mast. In the cloud, Song 2 while he steers; hold talk and Danny tells Kayla what he never said.
- **The belly.** Out of the cloud the ship fills the sky in the flight's own view; Song 2 ends and in the gap comes a deep hum and, too far to make out, the murmur of thousands of sleeping voices. The crash into the hangar is a cut to black with the sound of metal folding, then a slow drip.

**Chapter 8**
- **The nest and the drumstick.** Marcus and Mari calm and clean in their cradles, frost in Marcus's eyebrows, headphones round his neck, their lips moving with the whispers. From deep in the nest, Marcus's own cracked voice: "you'll... wait..." The player lays the drumstick in Marcus's open hand with one held button. The fingers do not close. Nothing happens. That is the scene.
- **Waking the others; the run to the pods.** The woken walk on their own legs; the player is never asked to escort. As a deck tilts, Kayla's hand comes into view and he catches it (one hand, in first person).
- **The hold.** One button: his hand on the pod release. Pods launch one by one on a strip of lights, a face at each window. The Mark climbs his arm in view. The hunter stoops in over the panel, its long face coming down into his view upside down at the favourite picture's angle (no unfolding on screen: it arrives in the dark beyond his light), and whispers in Danny's own voice: "getting... everyone... out." Danny: "Yeah. That one I'm keeping." His free hand spends the last flare, cell and extinguisher. When the pockets are empty its hand closes over his mouth; the last words are already out on the radio: "Miss Brooks. Is something funny?" Her laugh, crying. Then, in his own voice, the true thing. White. No music: breath, pods, the hunter, the radio. Just before its whisper, one tick of metal in a duct: the sound that sat under scene 4's air grille.

**Epilogue**
- **June.** Gus at the basement door, or his keys on a hook tagged "for Kayla". She adds Danny's name to the shelter wall; the chores are grief (the generator log, the cots, the guitar back on its nail). The developed film: the last frame, Danny pulling a face. His tape at his cot, longer the more he stayed on the line. Then scene 12.

---

## Part 4. What changes if the owner answers a map question differently

Each is one line. Everything not named stays as written.

- **Decision 1, the Harvest or the Return instead of the Voice Collectors:** scene 9 loses the sleepers' moving lips and their stopping (the heavy steps start instead); the nest's murmur in Chapter 8 and the belly's thousand voices become a hum. Scenes 3 and 11 are unchanged.
- **Decision 3, (b) nothing ever uses Kayla's voice:** no cutscene changes; only the played Mimic and rooftop whisper go. **(c) the soldiers take her:** no cutscene changes; the played fall shows a Patrol collar of light instead of the hunter.
- **Decision 4, no Mark:** scene 5 loses the sleeve and the black lines (he is only hurt); scene 9's arm beat goes and "If I get in one" becomes "Someone has to hold it."; scene 10 loses the lines on his wrist. The hand on the glass still works.
- **Decision 5, Marcus a survivor or left out:** scene 1 loses Marcus's run (shots 8 to 11 shrink to the two walking out); scene 3 goes (the title follows the last tube dying on an empty corridor and the whisper); scene 12 gains Marcus at the gate if he survived; the nest loses the drumstick.
- **Decision 6, the basketball team or a bad year of Kayla's instead of his father:** scene 4's look from Kayla means something else and needs no reshoot; scene 9's line becomes "You didn't quit this one, Danny." or "You came back this time, Danny."
- **Decision 8, the old voices instead of real ones:** the phone-filmed faces are acted by a friend to the playback, or driven from audio with the scene's fallback framing.
- **Decision 7(c), fewer cutscenes:** cut in this order, each to its first-person fallback: 8 It's Me. Again., 12 We Waited, 6 Knock, 5 Where's Mari. Never cut 2, 3, 7 or 10.

---

## Part 5. Where these twelve differ from the earlier lists, and why

- **Played instead of filmed:** the hand on the glass (scarier when nobody turns your head), "They're breathing" (works at the monitor desk, and the lamp then looks at the player), waking with the Mark (the Still Ones need the player's own look), the lift (straight after the roof it would take three minutes of control away), the belly, the drumstick, the hit and the chute.
- **Merged:** the first count and the camp song are one scene (two seated safe-room scenes back to back drag).
- **Added from the story:** the skateboard title (the map's own "remembered" moment), the wreck (the city's only cutscene, opened by the player's own button press), the gate (the payoff of "We'll be at the gate").
- **Moved:** "If I get in one, they follow it" is said when Kayla wakes, straight before the others are woken in play (the map has it a little later in the same stretch).
- **Danny's father** is said aloud once, by Kayla, in scene 9; nowhere else on camera.
- **Kayla's radio** in the pod is her own walkie from the wreck (scene 8), set beside her before she wakes (scene 9).

---

## Part 6. Sentences the game map needs changed to agree with this bible

1. Prologue, **New:** "while the hunter unfolds on the field and turns its long face." becomes "while the hunter, already standing on the field (it unfolds in the dark of the cutscene before), turns its long face toward the school."
2. Prologue, **Remembered:** "...a skateboard rolls across the floor on its own and stops. Title." becomes "...a skateboard rolls across the floor on its own and stops. Then, from right behind the door, the announcer's words come back in pieces: "...remain... in your... seats." Title."
3. Chapter 1, **Safe room (first night):** "the first count. Mari plays the camp song. Owen asks to be walked past the dark tunnel. Danny's promise:" becomes "the first count and Danny's Kessler impression. Mari plays the camp song, and Danny makes his promise:" and "The hunter will say it back at the end." is followed by "Then Owen asks to be walked past the dark tunnel."
4. Chapter 2, **The turn:** "on a camera Priya sees soldiers loading frosted cradles into a small ship." becomes "on a camera Priya sees frosted cradles floating out to a small ship on a ribbon of light, a soldier walking beside each."
5. Chapter 6, **What you do:** "At the wreck, Kayla's film camera and her walkie." becomes "At the wreck, Kayla's film camera and her walkie: when he presses talk, his own voice comes out of it. He keeps both."
6. Chapter 8, **The last hour:** "wake Kayla, then everyone you can; the woken walk to the pod bay on their own. "If I get in one, they follow it."" becomes "wake Kayla (she tests him: "What time?"; he tells her: "If I get in one, they follow it."), then everyone you can; the woken walk to the pod bay on their own."
7. Epilogue: "Then the gate. Whoever lived is waiting; with few, she waits alone. Song 3 begins." becomes "Then the gate. Whoever lived is waiting, and the first of them says "We waited."; she takes their picture. With no one there, she photographs the empty gate anyway. Song 3 begins."
