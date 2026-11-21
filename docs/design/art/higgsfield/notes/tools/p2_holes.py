# eye holes = dark (<30) region grown from a seed point inside each hole (numpy only).
# usage: p2_holes.py <face.png> lx ly rx ry
import sys, json, numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert('L')).astype(np.float32)
dark = a < 30
def grow(sx, sy):
    m = np.zeros_like(dark); m[sy, sx] = True
    while True:
        g = m.copy(); g[1:] |= m[:-1]; g[:-1] |= m[1:]; g[:, 1:] |= m[:, :-1]; g[:, :-1] |= m[:, 1:]
        g &= dark
        if (g == m).all(): return m
        m = g
res = {}
v = list(map(int, sys.argv[2:6]))
for side, (sx, sy) in (('left', v[0:2]), ('right', v[2:4])):
    m = grow(sx, sy); ys, xs = np.where(m)
    touches = bool(m[0].any() or m[-1].any() or m[:, 0].any() or m[:, -1].any())
    e = {'centre': [int(xs.mean()), int(ys.mean())], 'px': int(m.sum()), 'touches_border': touches,
         'top': [int(xs[ys == ys.min()].mean()), int(ys.min())], 'bottom': [int(xs[ys == ys.max()].mean()), int(ys.max())]}
    lo, hi = xs.min(), xs.max()
    e['outer' if side == 'left' else 'inner'] = [int(lo), int(ys[xs == lo].mean())]
    e['inner' if side == 'left' else 'outer'] = [int(hi), int(ys[xs == hi].mean())]
    res['eye_hole_' + side] = e
print(json.dumps(res))
