# second pass: mend the two wall-stain decals by script (no new picture). usage: python -I p2_stains.py water|mould
import sys
sys.path.insert(0, '/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/higg/tools')
import numpy as np
from PIL import Image
from w_common import load, save_jpg, blurf, lum
H = '/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/higg'
DL, P, W = H + '/dl', H + '/pack3', H + '/work3p2'

def ss(t):
    t = np.clip(t, 0, 1); return t*t*(3-2*t)

def write(S, alpha, name):
    rgba = np.concatenate([S, alpha[..., None]], 2)
    im = Image.fromarray(np.clip(rgba*255+0.5, 0, 255).astype(np.uint8), 'RGBA')
    im.save(f'{P}/{name}.png', optimize=True)
    im.resize((1024, 1024), Image.LANCZOS).save(f'{P}/{name}-1k.png', optimize=True)
    cards = [S*alpha[..., None] + np.array(bg, np.float32)*(1-alpha[..., None]) for bg in ([0.5]*3, [0.78, 0.85, 0.76], [0.92, 0.91, 0.86])]
    cards.append(np.repeat(alpha[..., None], 3, 2))
    save_jpg(np.concatenate(cards, 1), f'{W}/{name}-check.jpg', maxside=3200)
    print(name, 'alpha mean %.4f' % alpha.mean(), 'border max top %.3f left %.3f bottom %.3f right %.3f' % (alpha[0].max(), alpha[:, 0].max(), alpha[-1].max(), alpha[:, -1].max()))

if sys.argv[1] == 'water':
    # start from the round-3 decal; its alpha border is clean
    a = np.asarray(Image.open(f'{H}/work3p2/stain-water-r3.png').convert('RGBA')).astype(np.float32) / 255
    S, al = a[..., :3], a[..., 3]
    h, w = al.shape
    # 1 horizontal mortar joints: rows whose mean alpha stands out as a narrow ridge over the rows +-14 px
    prof = al.mean(1)
    base = np.array([np.median(prof[max(0, y-14):y+15]) for y in range(h)])
    ridge = (prof - base) > 0.012
    rows = np.where(ridge)[0]
    print('mortar rows', len(rows), rows[:40])
    al2 = al.copy()
    for y in rows:
        y0, y1 = max(0, y-8), min(h-1, y+8)
        while y0 > 0 and ridge[y0]: y0 -= 1
        while y1 < h-1 and ridge[y1]: y1 += 1
        interp = 0.5*(al[y0] + al[y1])
        al2[y] = np.minimum(al[y], interp)
    # 2 vertical joints below the stain band and anything under y=0.30: gone (the stain lives in the top course)
    yy = np.linspace(0, 1, h)[:, None]
    al2 = al2 * (1 - ss((yy - 0.22) / 0.05))
    # 3 stretch the stain band (rows 0..0.30) down to 0..0.62 so the damp and drips cover the upper part of the wall
    top = int(0.30*h); new = int(0.62*h)
    def stretch(x):
        im = Image.fromarray(x[:top].astype(np.float32), 'F').resize((w, new), Image.BICUBIC)
        out = np.zeros_like(x); out[:new] = np.asarray(im); return out
    al3 = np.clip(stretch(al2), 0, 1)
    S3 = np.stack([np.clip(stretch(S[..., c]), 0, 1) for c in range(3)], -1)
    S3[new:] = S3[new-1]
    # 4 after the stretch: remove straight joint lines that remain in the dark band (rows over the whole width,
    #   columns over the band height) from colour AND alpha, by interpolating across them
    def unline(S3, al3, axis, lo, hi, thr):
        D = al3 * (1 - lum(S3))
        if axis == 0:   # horizontal lines: one value per row
            prof = D.mean(1)
        else:           # vertical lines: one value per column, measured inside the band rows lo..hi
            prof = D[lo:hi].mean(0)
        n = len(prof)
        base = np.array([np.median(prof[max(0, i-20):i+21]) for i in range(n)])
        ridge = (prof - base) > thr
        idx = np.where(ridge)[0]
        for i in idx:
            i0, i1 = max(0, i-3), min(n-1, i+3)
            while i0 > 0 and ridge[i0]: i0 -= 1
            while i1 < n-1 and ridge[i1]: i1 += 1
            t = (i - i0) / max(1, i1 - i0)
            if axis == 0:
                S3[i] = S3[i0]*(1-t) + S3[i1]*t; al3[i] = al3[i0]*(1-t) + al3[i1]*t
            else:
                S3[lo:hi, i] = S3[lo:hi, i0]*(1-t) + S3[lo:hi, i1]*t; al3[lo:hi, i] = al3[lo:hi, i0]*(1-t) + al3[lo:hi, i1]*t
        return idx
    print('rows fixed', unline(S3, al3, 0, 0, h, 0.004))
    print('cols fixed', unline(S3, al3, 1, 0, int(0.14*h), 0.006))
    # 5 the band's lower joint (rows ~215-265) is several px thick: smooth those rows vertically (radius 18)
    def vbox(x, r):
        c = np.cumsum(np.pad(x, [(r+1, r)] + [(0, 0)]*(x.ndim-1), mode='edge'), 0)
        return (c[2*r+1:] - c[:-2*r-1]) / (2*r+1)
    y0, y1 = 205, 275
    t = ss(np.minimum(np.arange(y0, y1) - y0, y1 - np.arange(y0, y1)) / 10.0)
    Sb = vbox(S3, 18); ab = vbox(al3, 18)
    S3[y0:y1] = S3[y0:y1]*(1-t[:, None, None]) + Sb[y0:y1]*t[:, None, None]
    al3[y0:y1] = al3[y0:y1]*(1-t[:, None]) + ab[y0:y1]*t[:, None]
    write(S3, al3, 'stain-water')

if sys.argv[1] == 'mould':
    a = load(f'{DL}/R3-wall/R3-wall-mould-v1.png')
    h, w, _ = a.shape
    L = lum(a)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    r = np.sqrt(yy**2 + xx**2) / w
    # the photo's core is pure black (no texture). Fill it with patches of the photo's own speckled rim (quilting),
    # then darken toward the very corner, so the mould is densest in the corner and thins out to the rim.
    core = blurf((L < 0.05).astype(np.float32), 4) > 0.5
    rim = (L > 0.12) & (L < 0.55) & (r < 0.8)          # the speckled transition zone: dark spots with wall between
    rng = np.random.default_rng(11)
    ys, xs = np.where(rim[64:-64, 64:-64]); ys += 64; xs += 64
    fill = np.zeros_like(a); wsum = np.zeros((h, w), np.float32)
    ps, step = 48, 36                                    # small patches of FINE detail only: no visible squares
    ahp = a - blurf(a, 4)                                # the photo's fine grain (spots, fibres), mean zero
    win = np.outer(np.hanning(ps), np.hanning(ps)).astype(np.float32) + 0.02
    for ty in range(-ps//2, h, step):
        for tx in range(-ps//2, w, step):
            y0, x0 = max(0, ty), max(0, tx); y1, x1 = min(h, ty+ps), min(w, tx+ps)
            if not core[y0:y1, x0:x1].any(): continue
            j = rng.integers(len(ys)); sy, sx = ys[j] - ps//2, xs[j] - ps//2
            if sy < 0 or sx < 0 or sy+ps > h or sx+ps > w: continue
            patch = ahp[sy:sy+ps, sx:sx+ps]
            if rng.random() < 0.5: patch = patch[::-1]
            if rng.random() < 0.5: patch = patch[:, ::-1]
            if rng.random() < 0.5: patch = patch.transpose(1, 0, 2)
            patch = patch - patch.reshape(-1, 3).mean(0)   # detail only: every patch has the same mean
            pp = patch[y0-ty:y1-ty, x0-tx:x1-tx]; ww = win[y0-ty:y1-ty, x0-tx:x1-tx]
            fill[y0:y1, x0:x1] += pp * ww[..., None]; wsum[y0:y1, x0:x1] += ww
    got = wsum > 0.05
    hf = np.where(got[..., None], fill / np.maximum(wsum, 1e-3)[..., None], 0)
    rim_mean = np.percentile(a[rim], 25, axis=0)          # a dark green-black from the photo's own mould
    k = (blurf(core.astype(np.float32), 24) * got)[..., None]
    dens = np.clip(1 - r / 0.45, 0, 1)[..., None] ** 1.5 * 0.85       # toward the very corner: up to 85 % toward black
    filled = np.clip((rim_mean + hf * 1.6) * (1 - dens), 0, 1)
    src = a * (1 - k) + filled * k
    save_jpg(src, f'{W}/mould-filled-photo.jpg', maxside=1024)
    # alpha from darkness against the clean wall colour (as round 3), NO fade on the top and left edges (they are the corner)
    clean = a[int(0.65*h):int(0.95*h), int(0.45*w):int(0.95*w)].reshape(-1, 3)
    C = np.median(clean, 0); Lc = float(lum(C[None, None, :])[0, 0])
    Ls = lum(src)
    d = np.clip((Lc - Ls) / Lc, 0, 1)
    fl = max(float(np.quantile(d[int(0.65*h):int(0.95*h), int(0.45*w):int(0.95*w)], 0.99)), 0.04)
    d2 = np.clip((d - fl) / (1 - fl), 0, 1)
    d2 = 0.6*d2 + 0.4*blurf(d2, 2)
    alpha = np.clip(d2 * 1.15, 0, 0.97)
    y = yy / h; x = xx / w
    alpha = alpha * ss((1 - y) / 0.12) * ss((1 - x) / 0.12)
    a_s = np.maximum(alpha, 1e-3)[..., None]
    S = np.clip((src - (1 - a_s) * C) / a_s, 0, 1)
    lowS = blurf(S * (alpha[..., None] > 0.05), 6); wS = blurf((alpha > 0.05).astype(np.float32), 6)[..., None]
    S = np.where(alpha[..., None] > 0.05, S, np.where(wS > 1e-3, lowS / np.maximum(wS, 1e-3), C*0.5))
    # tone down the painted-looking yellow rim: halve the saturation of warm (R>B) pixels
    Ll = lum(S)[..., None]; warm = np.clip((S[..., 0] - S[..., 2]) * 6, 0, 1)[..., None]
    S = S * (1 - 0.5*warm) + (Ll + (S - Ll) * 0.5) * 0.5*warm
    write(S, alpha, 'stain-mould')
