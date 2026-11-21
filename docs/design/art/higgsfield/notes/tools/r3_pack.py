# Round 3: make game-ready files from the kept downloads. usage: python -I r3_pack.py <higg dir> <step>
import sys, numpy as np
from PIL import Image
H = sys.argv[1]; step = sys.argv[2]
DL = H + '/dl'; OUT = H + '/pack3'; W = H + '/work3'

def load(p): return np.asarray(Image.open(p).convert('RGB')).astype(np.float32)
def save(a, p): Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).save(p, optimize=True)
def lum(a): return a[..., 0]*0.299 + a[..., 1]*0.587 + a[..., 2]*0.114

def boxblur(x, r):
    # separable box blur via cumulative sums, edge-padded
    def b1(x, axis):
        pad = [(0, 0)]*x.ndim; pad[axis] = (r+1, r)
        xp = np.pad(x, pad, mode='edge')
        c = np.cumsum(xp, axis=axis)
        n = x.shape[axis]
        hi = np.take(c, np.arange(2*r+1, 2*r+1+n), axis=axis)
        lo = np.take(c, np.arange(0, n), axis=axis)
        return (hi - lo) / (2*r+1)
    return b1(b1(x, 0), 1)

def blur(x, r, n=3):
    for _ in range(n): x = boxblur(x, r)
    return x

def dilate(m, r):
    out = m.copy()
    for dy in range(-r, r+1):
        for dx in range(-r, r+1):
            if dx*dx + dy*dy <= r*r:
                out |= np.roll(np.roll(m, dy, 0), dx, 1)
    return out

def bbox(mask):
    ys, xs = np.where(mask)
    return xs.min(), ys.min(), xs.max(), ys.max()

def subject_crop(a, thr, margin, keep_bottom=False):
    L = lum(a); m = blur(L, 2, 1) > thr
    # keep only rows/cols with a meaningful amount of subject (ignore specks)
    cols = np.where(m.sum(0) > 8)[0]; rows = np.where(m.sum(1) > 8)[0]
    x0, x1, y0, y1 = cols.min(), cols.max(), rows.min(), rows.max()
    h, w = L.shape
    x0 = max(0, x0-margin); y0 = max(0, y0-margin); x1 = min(w-1, x1+margin); y1 = min(h-1, y1+margin)
    if keep_bottom: y1 = h-1
    return a[y0:y1+1, x0:x1+1], (int(x0), int(y0))

def fit2048(a):
    h, w = a.shape[:2]; s = 2048/max(h, w)
    if s >= 1: return a, 1.0
    im = Image.fromarray(a.astype(np.uint8)).resize((round(w*s), round(h*s)), Image.LANCZOS)
    return np.asarray(im).astype(np.float32), s

def seamless(a, feather=None):
    # offset by half, then blend the cross-shaped seam with a mirrored-feather mix of the original
    h, w = a.shape[:2]
    f = feather or w//6
    sh = np.roll(np.roll(a, h//2, 0), w//2, 1)
    # weight: 1 near the seam lines (centre row/col of sh) -> use original a there (a is continuous at its centre)
    yy = np.abs(np.arange(h) - h//2)[:, None]; xx = np.abs(np.arange(w) - w//2)[None, :]
    wy = np.clip(1 - yy/f, 0, 1); wx = np.clip(1 - xx/f, 0, 1)
    wgt = np.maximum(wy, wx)
    wgt = (wgt*wgt*(3-2*wgt))[..., None]
    # source for the seam areas: the original shifted by a quarter so its middle (seam-free) covers the seams
    src = np.roll(np.roll(a, h//4, 0), w//4, 1)
    return sh*(1-wgt) + src*wgt

if step == 'face':
    for src, dst in (('R3-face/R3-face-v2.png', 'face-front.png'), ('R3-face/R3-face-v3.png', 'alt/face-front-alt.png')):
        a = load(f'{DL}/{src}')
        c, off = subject_crop(a, 18, 24)
        c, s = fit2048(c); save(c, f'{OUT}/{dst}'); print(dst, c.shape, 'offset', off, 'scale', s)
elif step == 'hands':
    a = load(f'{DL}/R3-hand/R3-hand-v1.png')
    c, off = subject_crop(a, 18, 24, keep_bottom=True); c, s = fit2048(c)
    save(c, f'{OUT}/hand-back.png'); print('hand-back', c.shape, off, s)
    a = load(f'{DL}/R3-hand/R3-palm-v1.png')[:, ::-1]   # left-hand back mirrored to a right hand
    c, off = subject_crop(a, 18, 24, keep_bottom=True); c, s = fit2048(c)
    save(c, f'{OUT}/alt/hand-back-alt.png'); print('hand-back-alt', c.shape, off, s)
elif step == 'tiles':
    for src, name in (('R3-skin/R3-skin-v1.png', 'skin-tile'), ('R3-cloth/R3-cloth-v1.png', 'cloth-tile')):
        a = load(f'{DL}/{src}')
        # remove the low-frequency light falloff: divide by a very wide blur, keep the mean colour
        low = blur(a, 96, 3); mean = a.reshape(-1, 3).mean(0)
        flat = a / np.maximum(low, 1) * mean
        save(flat, f'{OUT}/{name}.png')
        L0 = lum(a); L1 = lum(flat)
        q = lambda L: [round(float(L[:256, :256].mean()),1), round(float(L[:256, -256:].mean()),1), round(float(L[-256:, :256].mean()),1), round(float(L[-256:, -256:].mean()),1), round(float(L[896:1152, 896:1152].mean()),1)]
        print(name, 'corners+centre before', q(L0), 'after', q(L1))
        sm = seamless(flat); save(sm, f'{OUT}/{name}-seamless.png')
        # 2x2 preview at half size
        t = np.concatenate([np.concatenate([sm, sm], 1)]*2, 0)
        im = Image.fromarray(np.clip(t, 0, 255).astype(np.uint8)).resize((2048, 2048), Image.LANCZOS); im.save(f'{W}/{name}-2x2.jpg', quality=88)
        t = np.concatenate([np.concatenate([flat, flat], 1)]*2, 0)
        im = Image.fromarray(np.clip(t, 0, 255).astype(np.uint8)).resize((1024, 1024), Image.LANCZOS); im.save(f'{W}/{name}-raw-2x2.jpg', quality=85)
        # edge check: mean abs difference across the wrap seams (right vs left column, bottom vs top row)
        for nm, img in (('raw', flat), ('seamless', sm)):
            dx = np.abs(img[:, -1] - img[:, 0]).mean(); dy = np.abs(img[-1] - img[0]).mean()
            inner = np.abs(img[:, 1:] - img[:, :-1]).mean()
            print(' ', nm, 'wrap diff x %.2f y %.2f  (normal neighbour diff %.2f)' % (dx, dy, inner))

if step == 'palm':
    a = load(f'{DL}/R3-hand/R3-palm-v3.png')
    L = lum(a); h, w = L.shape
    hand = blur(L, 2, 1) > 40
    # erode the hand mask so the dark silhouette edge is never taken for ink
    edge = dilate(~hand, 10); inside = hand & ~edge
    bg = blur(L, 20, 3)
    sat = a.max(-1) - a.min(-1)
    # ink: much darker than the local skin; the blue ballpoint: bluish (B > R)
    dark = (L < bg - 28)
    blue = (a[..., 2] > a[..., 0] + 6) & (L < bg - 8)
    ink = (dark | blue) & inside
    # keep only the drawing region (the palm and wrist); the fingers' creases and fingerprints stay
    yy, xx = np.mgrid[0:h, 0:w]
    region = (yy > 880) & (xx > 180) & (xx < 1150)
    ink &= region
    mask = dilate(ink, 5) & hand
    print('ink px', int(ink.sum()), 'mask px', int(mask.sum()))
    # low frequency: coarse-to-fine normalised blur of the known skin (inside the hand only)
    known = (~mask) & inside
    low = None
    for r in (64, 32, 16, 8, 4):
        num = blur(a*known[..., None], r, 2); den = blur(known.astype(np.float32), r, 2)[..., None]
        fill = num/np.maximum(den, 1e-4)
        if low is None: low = fill
        else: low = np.where(den > 0.35, fill, low)
    low = np.where(mask[..., None], low, a)
    # high frequency detail borrowed from clean donor patches (offset), so the skin texture continues
    hf = a - blur(a, 3, 2)
    fullmask = mask.copy(); todo = mask.copy(); out = low.copy()
    for (dy, dx) in ((0, 150), (0, -150), (150, 0), (-150, 0), (110, 110), (-110, 110), (110, -110), (-110, -110), (0, 300), (0, -300)):
        bad = np.roll(np.roll(fullmask | ~inside, dy, 0), dx, 1)
        don = np.roll(np.roll(hf, dy, 0), dx, 1)
        use = todo & ~bad
        out = np.where(use[..., None], low + don, out)
        todo = todo & ~use
    print('unfilled detail px', int(todo.sum()))
    # soften the hole border
    m2 = blur((dilate(ink, 5)).astype(np.float32), 2, 2)[..., None]
    out = a*(1-m2) + out*m2
    save(out, f'{W}/palm-clean-full.png')
    c, off = subject_crop(out, 18, 24, keep_bottom=True); c, s = fit2048(c)
    save(c, f'{OUT}/hand-palm.png'); print('hand-palm', c.shape, off, s)
