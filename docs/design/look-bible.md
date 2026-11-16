# ROVLOC look bible v1 (16 Nov)

## The player's words (verbatim, newest last)
- "the cutscene has bad graphics make them look like actual people"
- "the cutscene still really bad i want it to look realistic realistic looking horror game bro"
- "i want the game to actually be realistic like look like human yk then its scary, make thhe monster also look
  creepier you changed the face the body is not scary tho"
- "i want the game to look realistic as realsitic as possible and to have a scary eerie feel."

## Where we are (the first test, judged by fresh eyes on 16 Nov: people 4 of 10, scene 4 of 10)
"He would say bad graphics again, though less angrily." What held: real proportions, a motion-captured walk, a low
warm sun with long shadows; the wide walking shot passes for two seconds. What failed, worst first:
1. The horror beat itself (shot S9): arms thrown over the head like dancing, bodies through each other and through a bin.
2. Four friends are one cloned model.
3. Faces: plastic poreless skin, drawn-on brows, eyes with no shine, mouths shut while they speak; on Potato a
   faceted low-detail head in close-up.
4. Clothes are painted-on shells with no folds; backpacks are rounded boxes; shoes are blobs.
5. The lot is flat: windows are grey slabs, the sky is a beige wash, far buildings are white cut-outs, the asphalt has
   no material, the grade has no mood. In the Basement a teammate stands in a crouched lurch with splayed palms.
Also: the realistic people put Potato over its 16.7 ms frame budget (cause not found yet).

## The law
1. LIGHT AND MATERIAL FIRST. Realism is one light with a real shadow, a surface that answers it (roughness, normal,
   occlusion), air with depth (haze, dust in a beam) and a camera with a film response (tone curve, exposure that
   adapts, grain, a vignette, bloom on what is bright). Models come second.
2. HORROR HIDES. Show less than we could: darkness that is really dark, backlight and silhouettes, haze, shallow
   focus in close shots. Nothing is evenly lit except by the player's torch. A face is shown close only where it
   holds up; otherwise the shot is wider, from behind, or against the light.
3. HUMANS ARE HUMAN. Different faces and builds; skin from photographs; eyes that are alive (a catchlight, blinks,
   looking at who speaks); mouths that move with their lines; cloth with folds and weave; weight on the feet;
   motion from motion capture, retargeted correctly (a relaxed stand is a relaxed stand).
4. THE MONSTER IS A HUMAN BODY GONE WRONG, not a costume and not a cartoon: far too tall and thin, arms to the knees,
   long fingers, ribs and spine under the skin, joints that sit and bend slightly wrong, a head that turns first;
   too still, then too fast. The cracked porcelain mask stays as the player accepted it. No blood, no gore.
5. THE TIERS. Max and High carry the look. Medium, Low and Potato show the same picture made cheaper. Tiers are
   visual only: nothing gameplay reads may change (hitboxes, heights, speeds, sight lines, what is dark enough to
   hide in). Potato holds 60 FPS on a school Chromebook: the frame-time gate (npm run check) decides.
6. SOURCES. CC0 or public domain only, traced (page, author, licence, sha256), never from another game:
   MakeHuman's CC0 asset packs (https://static.makehumancommunity.org/assets/assetpacks.html lists them; each pack
   page names every asset's author and licence; the zip is
   https://files.makehumancommunity.org/asset_packs/<pack>/<pack>_cc0.zip : skins01-03, hair01-03, shirts01-03,
   pants01-03, shoes01-03, suits01-03, eyebrows01, eyelashes01, faceunits01, equipment01-03, glasses, hats, masks,
   makehuman_system_assets), Poly Haven (https://api.polyhaven.com , files on dl.polyhaven.org : photo-scanned PBR
   materials, HDRI skies, some models; everything there is CC0), CMU motion capture (free for any use), Kenney and
   opengameart.org CC0 items, and what we generate ourselves. Blender (as the Python module bpy) and MPFB2 are tools.
7. BOTH PLATFORMS. Every asset is rebuilt by scripts in the repo from its sources, so the Roblox port can upload the
   same meshes, skeletons, clips and texture sets later. Shared texture sets go through tools/textures (Palette.luau
   keys stay stable).
8. PROOF IS A PICTURE. Every package ends with frames shot from the real game on Max and Potato, read by a
   fresh-eyes judge who answers as the player: a score out of 10 and "would he call it realistic, and is it eerie?".
   Under 7: fix the judge's worst defects and shoot again. The lead looks at the frames too before anything lands.

## Packages
L1 PEOPLE v2 (worktree wf_ed6bdb12-f0e-1, the spike's): Step 0 first: find and fix Potato's frame-time loss
   (profile BEFORE against AFTER on a quiet machine: skinning in software WebGL, the per-pixel people shader, the
   texture path), compress textures (KTX2/Basis). Then five DISTINCT kids from the cast (CastConfig.luau) with CC0
   photographic skins, eyes with a cornea highlight, brows, lashes, teeth, real hair meshes, real clothes (hoodie or
   jacket, T-shirt, jeans, trainers) with baked fold normals, a modelled backpack; blinks, eye look-at and a jaw and
   lip flap driven by the lines' timing; correct retargets (relaxed idle, walk, run, talk, startle, cower, crouch,
   crawl, downed, getting up, a hand holding the torch); the full-detail head in every close-up on every tier, or no
   close-up there. Co-op teammates are these kids.
L2 THE OPENING RESTAGED (same worktree, after L1's kids exist): golden hour falling to dusk and night (a sky with a
   sun, clouds and a horizon; Poly Haven HDRI or a generated sky; the light track of the time-lapse), the lot's
   materials (asphalt with cracks and puddles, pavement, brick, painted steel bins, a see-through chain-link fence,
   glass with a reflection and a dark room behind), a hazy skyline instead of white cut-outs, a film camera (handheld
   sway, focal lengths, shallow focus in close shots, grain, vignette, bloom on the sun), and shot S9 staged again
   with real startle and cower motion, bodies apart, nothing through a bin. Fewer face close-ups, more backlight.
L3 THE MONSTER'S BODY (task 46; its own worktree from the spike's snapshot): three silhouettes as quick renders ->
   a judge picks the most frightening -> the body built on the people pipeline (MakeHuman base pushed far out of
   human range, bones rescaled, sculpted ribs, spine and tendons baked to normals, pale mottled skin, remnants of
   cloth), the accepted mask on the head bone, authored and distorted-mocap clips (stand too still, the head turning
   first, the stalk, the chase lope, the reach and catch, a crawl and a fold for vents), a 3-5k triangle Potato
   version. Height 11 studs, hitbox, speeds, sight: untouched.
L4 THE SCHOOL'S LOOK (materials, light, air, camera in play; every floor): audit the renderer and the post chain
   first; photo-scanned PBR sets from Poly Haven behind the same palette keys (brick, concrete, plaster, floor
   tile, linoleum, ceiling tile, painted and rusted steel, wood, glass); the torch (a real shadow, an uneven beam,
   dust in it), failing fixtures with bloom, moonlight through windows; haze with depth; the film camera in play
   (tone curve, exposure that adapts when the torch dies, grain, vignette, a little motion blur). Eerie: light that
   fails, far ends of corridors that are never fully seen.
Order: L1 and L3 start together; L2 follows L1 in the same worktree; L4 starts when a slot is free. Every later
stage of the game (Auditorium, roof, city, airport) is built to this law from the start.
