# Round 3 second pass: game-ready files from the new pictures + script mends. usage: python -I p2_pack.py <higg dir> <p2step>
import sys, json
sys.path.insert(0, '/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/higg/tools')
import numpy as np
from PIL import Image
from r3_pack import load, save, lum, blur, dilate, subject_crop, fit2048, seamless
H = '/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/higg'
DL, P, W = H + '/dl', H + '/pack3', H + '/work3p2'
step = sys.argv[2]   # argv[1] = higg dir (read by r3_pack at import); step names start with p2

if step == 'p2face':
    a = load(f'{DL}/R3-face/R3-face-p2-v2.png')
    c, off = subject_crop(a, 18, 24)
    save(c, f'{P}/alt/face-front-alt.png'); print('alt (unsqueezed)', c.shape, off)
    h, w = c.shape[:2]; nw = round(w * 0.75)
    sq = np.asarray(Image.fromarray(c.astype(np.uint8)).resize((nw, h), Image.LANCZOS)).astype(np.float32)
    sq, s = fit2048(sq); save(sq, f'{P}/face-front.png'); print('face-front (x 0.75)', sq.shape, s)
elif step == 'p2palm':
    a = load(f'{DL}/R3-hand/R3-palm-p2-v1.png')
    c, off = subject_crop(a, 18, 24, keep_bottom=True); c, s = fit2048(c)
    save(c, f'{P}/hand-palm.png'); print('hand-palm', c.shape, off, s)
elif step == 'p2skin':
    # mend the skin tile without a new picture: the round-3 tile reads as paper because its fine creases are LIGHT
    # fibres on a flat ground. Real crepey old skin has DARK creases. Flip the polarity of the fine detail only,
    # strengthen it, damp the mid-scale vein cluster that repeats when tiled, then re-make it seamless.
    a = load(f'{W}/r3-replaced/skin-tile-r3.png')
    fine = a - blur(a, 3, 2)              # pores, creases, fibres (about 1-6 px)
    mid = blur(a, 3, 2) - blur(a, 40, 3)  # veins, blotches (6-80 px)
    low = blur(a, 40, 3)
    Lf = lum(fine)[..., None]
    # light fine lines -> dark creases (luminance flipped, colour kept), x2.2; mid scale damped to 0.55
    fine2 = (fine - Lf) * 1.0 - Lf * 2.2
    # a second, coarser crease layer: the same flipped detail taken from a half-size copy and scaled back up,
    # so the creases read at two sizes (fine pores + crepe wrinkles visible from further away)
    hh, ww = a.shape[:2]
    half = np.asarray(Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).resize((ww//2, hh//2), Image.LANCZOS)).astype(np.float32)
    fh = half - blur(half, 3, 2); Lh = lum(fh)[..., None]; fh = (fh - Lh) - Lh * 2.0
    coarse = np.stack([np.asarray(Image.fromarray(fh[..., c].astype(np.float32), 'F').resize((ww, hh), Image.BICUBIC)) for c in range(3)], -1)
    out = low + mid * 0.55 + fine2 * 0.8 + coarse * 1.2
    # a slightly greyer, cooler skin to sit with the hand photos
    L = lum(out)[..., None]; out = L + (out - L) * 0.85
    save(out, f'{P}/src/skin-tile-source.png')
    sm = seamless(out); save(sm, f'{P}/skin-tile-seamless.png')
    t = np.concatenate([np.concatenate([sm]*3, 1)]*3, 0)
    Image.fromarray(np.clip(t, 0, 255).astype(np.uint8)).resize((1536, 1536), Image.LANCZOS).save(f'{W}/skin-tile-seamless-3x3.jpg', quality=88)
    Image.fromarray(np.clip(sm[640:1408, 640:1408], 0, 255).astype(np.uint8)).save(f'{W}/skin-crop-after.jpg', quality=90)
    for nm, img in (('flat', out), ('seamless', sm)):
        dx = np.abs(img[:, -1] - img[:, 0]).mean(); dy = np.abs(img[-1] - img[0]).mean(); inner = np.abs(img[:, 1:] - img[:, :-1]).mean()
        print(nm, 'wrap diff x %.2f y %.2f (neighbour %.2f)  std %.1f  mean %s' % (dx, dy, inner, lum(img).std(), img.reshape(-1, 3).mean(0).round(1)))
elif step == 'p2title':
    # the round-3 title figure is a stiff puppet (judge: 3/10) and the second-pass picture (p4) failed worse.
    # Mend: paint the figure out of t2 (mirror the far corridor about its vanishing line) -> an EMPTY corridor plate;
    # the game puts its own monster model in front of it.
    a = load(f'{DL}/R3-title/R3-title-v2.png')
    h, w = a.shape[:2]; print('t2 size', w, h)
    vx = int(sys.argv[3]); x0, x1, y0, y1 = map(int, sys.argv[4:8])   # vx: mirror line; then the figure box
    # mirror the corridor about its vanishing line x = vx (the far end is dark and nearly symmetric), narrow feather
    src = np.roll(a[:, ::-1], 2*vx - (w-1), 1)
    m = np.zeros((h, w), np.float32); m[y0:y1, x0:x1] = 1
    m = blur(m, 5, 2)[..., None]
    out = a*(1-m) + src*m
    # same grade and vignette as round 3 (w_pack.title)
    o = out/255.0
    Lo = (o[..., 0]*0.2126 + o[..., 1]*0.7152 + o[..., 2]*0.0722)[..., None]
    o = np.clip((Lo + (o - Lo)*0.75) * np.array([0.97, 1.0, 0.99], np.float32), 0, 1)
    yy = np.linspace(-1, 1, h)[:, None]; xx = np.linspace(-1, 1, w)[None, :]
    o = o * np.clip(1 - 0.35*((xx*0.9)**2 + (yy*1.1)**2), 0.45, 1)[..., None]
    im = Image.fromarray(np.clip(o*255+0.5, 0, 255).astype(np.uint8))
    im.save(f'{P}/title.jpg', quality=88, optimize=True, progressive=True)
    im.resize((1024, round(h*1024/w)), Image.LANCZOS).save(f'{P}/title-1k.jpg', quality=88, optimize=True, progressive=True)
    im.crop((x0-200, max(0, y0-120), x1+200, min(h, y1+120))).save(f'{W}/title-fix-zoom.jpg', quality=90)
    print('title plate', im.size)
