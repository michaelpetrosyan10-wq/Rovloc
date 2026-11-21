# world pack: backdrops + stains + title. usage: python -I w_pack.py <step|all>
import sys, json
sys.path.insert(0, '/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/higg/tools')
import numpy as np
from PIL import Image, ImageFilter
from w_common import load, save_jpg, blur, blurf, lum, grade, fill_dark_lines

H = '/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/higg'
DL, P, W = H + '/dl', H + '/pack3', H + '/work3w'
info = {}

def band_mean(a, y0, y1, x0=0.0, x1=1.0):
    h, w, _ = a.shape
    m = a[int(y0*h):int(y1*h), int(x0*w):int(x1*w)].reshape(-1, 3).mean(0)
    return [int(round(v*255)) for v in m]

def both(a, name):
    s = save_jpg(a, f'{P}/{name}.jpg')
    s1 = save_jpg(a, f'{P}/{name}-1k.jpg', maxside=1024)
    return s, s1

def window():
    a = load(f'{DL}/R3-window/R3-window-v1.png')
    h, w, _ = a.shape
    # 1 branch at the top-left (sky): dark thin lines on smooth cloud
    a, m1 = fill_dark_lines(a, (0.0, 0.16, 0.0, 0.6), thresh=0.02, r=14, grow=2)
    # 2 wire across the bottom-right
    a, m2 = fill_dark_lines(a, (0.78, 0.97, 0.62, 1.0), thresh=0.012, r=6, grow=1.5)
    # 3 dark roof corner bottom-right: copy the same rows from further left (street bands are horizontal)
    y0, x0 = int(0.86*h), int(0.85*w)
    src = a[y0:, x0 - int(0.22*w): w - int(0.22*w)].copy()
    mask = np.zeros((h, w), np.float32)
    yy, xx = np.mgrid[0:h, 0:w]
    mask[(yy > 0.885*h) & (xx > 0.875*w)] = 1
    mask = blurf(mask, 10)[y0:, x0:]
    a[y0:, x0:] = a[y0:, x0:]*(1-mask[..., None]) + src*mask[..., None]
    # grade: colder, green-grey, keep the sodium lamps warm
    a = grade(a, sat=0.3, tint=(0.9, 1.0, 1.0), keep_warm_above=0.5)
    info['window'] = dict(size=both(a, 'window-night'), fill_branch=m1, fill_wire=m2,
        haze_rgb=band_mean(a, 0.60, 0.70), sky_rgb=band_mean(a, 0.05, 0.25))
    return a

def skyline():
    a = load(f'{DL}/R3-skyline/R3-skyline-v2.png')
    h, w, _ = a.shape
    a = grade(a, sat=0.8, tint=(0.97, 1.0, 1.0), keep_warm_above=0.5)
    # bottom fades to black over the last 10 %
    yy = np.linspace(0, 1, h)[:, None, None]
    a = a * np.clip((1.0 - yy) / 0.10, 0, 1) ** 0.7
    # even out the brightness of the two ends (left top cloud is darker)
    both(a, 'skyline')
    o = int(round(0.08 * w))
    out = a[:, : w - o].copy()
    t = (np.arange(o, dtype=np.float32) / (o - 1))[None, :, None]
    t = t*t*(3 - 2*t)
    out[:, :o] = a[:, :o] * t + a[:, w - o:] * (1 - t)
    s = both(out, 'skyline-wrap')
    # tiling check: two copies side by side, seam marked below
    tile = np.concatenate([out, out], 1)
    save_jpg(tile, f'{W}/skyline-wrap-tiled.jpg', maxside=3000)
    seam = tile[:, out.shape[1]-300: out.shape[1]+300]
    save_jpg(seam, f'{W}/skyline-wrap-seam.jpg')
    info['skyline'] = dict(size=s, wrap_overlap_px=o, haze_rgb=band_mean(a, 0.62, 0.70),
        sky_rgb=band_mean(a, 0.05, 0.30))
    return a

def sky():
    a = load(f'{DL}/R3-sky/R3-sky-v1.png')
    a = grade(a, sat=0.4, tint=(0.95, 1.0, 1.02))
    info['sky'] = dict(size=both(a, 'sky'), bottom_rgb=band_mean(a, 0.9, 1.0), mean_rgb=band_mean(a, 0, 1))
    return a

def border_fade(h, w, top, bottom, left, right):
    y = np.linspace(0, 1, h)[:, None]; x = np.linspace(0, 1, w)[None, :]
    def ss(t):
        t = np.clip(t, 0, 1); return t*t*(3-2*t)
    return ss(y/top) * ss((1-y)/bottom) * ss(x/left) * ss((1-x)/right)

def stain(src, name, margins, gain, floor_q, floor_region, floor_min=0.0, line_supp=0.0, core=None):
    a = load(src)
    h, w, _ = a.shape
    L = lum(a)
    # the wall's own colour: median of the clean region
    fy0, fy1, fx0, fx1 = floor_region
    clean = a[int(fy0*h):int(fy1*h), int(fx0*w):int(fx1*w)].reshape(-1, 3)
    C = np.median(clean, 0)
    Lc = float(lum(C[None, None, :])[0, 0])
    d = np.clip((Lc - L) / Lc, 0, 1)
    # thin features of the clean wall (mortar, grain) set the floor
    dc = d[int(fy0*h):int(fy1*h), int(fx0*w):int(fx1*w)]
    fl = max(float(np.quantile(dc, floor_q)), floor_min)
    d2 = np.clip((d - fl) / (1 - fl), 0, 1)
    if line_supp > 0:
        # isolated thin lines (mortar joints) fall away; dense drip groups stay
        d2 = np.minimum(d2, line_supp * blurf(d2, 7))
    # soften speckle a little, keep the drip edges
    d2 = 0.6*d2 + 0.4*blurf(d2, 2)
    alpha = np.clip(d2 * gain, 0, 1)
    if core is not None:
        # break up a solid black core: blotchy alpha + dark green-black colour, softer toward the corner
        rng = np.random.default_rng(7)
        n = sum(blurf(rng.standard_normal((h, w)).astype(np.float32), r) * (r ** 0.5) for r in (8, 24, 64))
        n = (n - n.mean()) / (n.std() + 1e-6)
        solid = np.clip((alpha - 0.9) / 0.1, 0, 1) * np.clip((Lc - L) / Lc * 1.0 - 0.8, 0, 0.2) / 0.2
        solid = blurf(solid, 6)
        blot = np.clip(core['level'] + core['amp'] * n, 0.55, 1.0)
        alpha = alpha * (1 - solid) + alpha * blot * solid
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        r = np.sqrt((yy / h) ** 2 + (xx / w) ** 2)
        alpha = alpha * (core['corner'] + (1 - core['corner']) * np.clip(r / core['radius'], 0, 1))
    alpha = alpha * border_fade(h, w, *margins)
    # colour: unmix the stain from the wall colour so it reproduces the photo over its own wall
    a_s = np.maximum(alpha, 1e-3)[..., None]
    S = np.clip((a - (1 - a_s) * C) / a_s, 0, 1)
    lowS = blur(S * (alpha[..., None] > 0.05), 6)
    wS = blurf((alpha > 0.05).astype(np.float32), 6)[..., None]
    fillS = np.where(wS > 1e-3, lowS / np.maximum(wS, 1e-3), C*0.5)
    S = np.where(alpha[..., None] > 0.05, S, fillS)
    if core is not None:
        dark = np.array(core['rgb'], np.float32)
        k = np.clip((0.12 - lum(S)) / 0.12, 0, 1)[..., None]
        S = S * (1 - k) + dark * k
    rgba = np.concatenate([S, alpha[..., None]], 2)
    im = Image.fromarray(np.clip(rgba*255+0.5, 0, 255).astype(np.uint8), 'RGBA')
    if max(im.size) > 2048:
        im = im.resize((2048, 2048), Image.LANCZOS)
    im.save(f'{P}/{name}.png', optimize=True)
    im.resize((1024, 1024), Image.LANCZOS).save(f'{P}/{name}-1k.png', optimize=True)
    # checks: over mid grey and over a pale green card, plus the alpha itself
    cards = []
    for bg in ([0.5, 0.5, 0.5], [0.78, 0.85, 0.76]):
        comp = S*alpha[..., None] + np.array(bg, np.float32)*(1-alpha[..., None])
        cards.append(comp)
    cards.append(np.repeat(alpha[..., None], 3, 2))
    sheet = np.concatenate(cards, 1)
    save_jpg(sheet, f'{W}/{name}-check.jpg', maxside=2400)
    edge = max(alpha[0].max(), alpha[-1].max(), alpha[:, 0].max(), alpha[:, -1].max())
    info[name] = dict(size=im.size, wall_rgb=[int(round(v*255)) for v in C], floor=round(fl, 4),
                      alpha_mean=round(float(alpha.mean()), 4), alpha_max_at_border=float(edge))

def title():
    a = load(f'{DL}/R3-title/R3-title-v2.png')
    h, w, _ = a.shape
    a = grade(a, sat=0.75, tint=(0.97, 1.0, 0.99))
    # gentle vignette to sink the corners (and the dark board at the top right)
    y = np.linspace(-1, 1, h)[:, None]; x = np.linspace(-1, 1, w)[None, :]
    v = np.clip(1 - 0.35*((x*0.9)**2 + (y*1.1)**2), 0.45, 1)[..., None]
    a = a * v
    info['title'] = dict(size=both(a, 'title'))
    return a

steps = dict(window=window, skyline=skyline, sky=sky, title=title,
    water=lambda: stain(f'{DL}/R3-wall/R3-wall-water-v1.png', 'stain-water', (0.04, 0.12, 0.10, 0.10), 2.6, 0.985, (0.45, 0.95, 0.05, 0.95), line_supp=2.2),
    mould=lambda: stain(f'{DL}/R3-wall/R3-wall-mould-v1.png', 'stain-mould', (0.22, 0.12, 0.22, 0.12), 1.6, 0.99, (0.65, 0.95, 0.45, 0.95), floor_min=0.04,
        core=dict(level=0.86, amp=0.14, corner=0.5, radius=0.4, rgb=(0.05, 0.065, 0.035))))
which = sys.argv[1:] or ['all']
for k in (steps if which == ['all'] else which):
    steps[k]()
print(json.dumps(info, indent=1))
