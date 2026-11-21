# shared helpers for the world pack (numpy + PIL only)
import numpy as np
from PIL import Image, ImageFilter

def load(p):
    return np.asarray(Image.open(p).convert('RGB')).astype(np.float32) / 255.0

def save_jpg(a, p, q=88, maxside=2048):
    im = Image.fromarray(np.clip(a * 255 + 0.5, 0, 255).astype(np.uint8))
    if max(im.size) > maxside:
        s = maxside / max(im.size)
        im = im.resize((round(im.size[0] * s), round(im.size[1] * s)), Image.LANCZOS)
    im.save(p, quality=q, optimize=True, progressive=True)
    return im.size

def blur(a, r):
    return blurf(a, r)

def _box1(m, r, axis):
    r = max(1, int(r))
    pad = [(0, 0)] * m.ndim; pad[axis] = (r + 1, r)
    c = np.cumsum(np.pad(m, pad, mode='edge'), axis=axis, dtype=np.float64)
    n = m.shape[axis]
    hi = np.take(c, np.arange(2 * r + 1, 2 * r + 1 + n), axis=axis)
    lo = np.take(c, np.arange(0, n), axis=axis)
    return ((hi - lo) / (2 * r + 1)).astype(np.float32)

def blurf(m, r):
    """float gaussian-ish blur (3 box passes), works on 2D or HxWxC"""
    b = max(1, int(round(r * 0.8)))
    out = m.astype(np.float32)
    for _ in range(3):
        out = _box1(out, b, 0); out = _box1(out, b, 1)
    return out

def lum(a):
    return a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722

def grade(a, sat=0.55, tint=(0.94, 1.0, 0.98), keep_warm_above=None):
    """desaturate and tint toward green-grey; optionally keep bright warm lamps"""
    L = lum(a)[..., None]
    g = L + (a - L) * sat
    g = g * np.array(tint, np.float32)
    if keep_warm_above is not None:
        w = np.clip((L[..., 0] - keep_warm_above) / 0.15, 0, 1)[..., None]
        g = g * (1 - w) + a * w
    return np.clip(g, 0, 1)

def fill_dark_lines(a, region, thresh=0.025, r=9, grow=2):
    """inside region (y0,y1,x0,x1 fractions) replace pixels clearly darker than the local blur by the blur"""
    h, w, _ = a.shape
    y0, y1, x0, x1 = [int(v * s) for v, s in zip(region, (h, h, w, w))]
    sub = a[y0:y1, x0:x1]
    # median-ish background: blur twice with big radius after clamping dark pixels
    bg = blur(sub, r)
    d = lum(bg) - lum(sub)
    m = (d > thresh).astype(np.float32)
    m = blurf(m, grow); m = np.clip(m * 3, 0, 1)
    # recompute background without the line
    for _ in range(3):
        fillv = sub * (1 - m[..., None]) + bg * m[..., None]
        bg = blur(fillv, r)
    out = sub * (1 - m[..., None]) + bg * m[..., None]
    a = a.copy(); a[y0:y1, x0:x1] = out
    return a, float(m.mean())
