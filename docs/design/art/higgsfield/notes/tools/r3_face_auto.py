# measure the face silhouette and the eye holes automatically (holes = dark regions not connected to the outside)
import sys, json, numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert('L')).astype(np.float32)
h, w = a.shape
dark = a < 30
# flood fill the outside dark region from the border (4-connected, iterative)
out = np.zeros_like(dark); out[0, :] = dark[0, :]; out[-1, :] = dark[-1, :]; out[:, 0] = dark[:, 0]; out[:, -1] = dark[:, -1]
while True:
    g = out.copy()
    g[1:] |= out[:-1]; g[:-1] |= out[1:]; g[:, 1:] |= out[:, :-1]; g[:, :-1] |= out[:, 1:]
    g &= dark
    if (g == out).all(): break
    out = g
face = ~out
holes = dark & ~out
yy = np.arange(h)[:, None]; holes &= (yy > int(sys.argv[2])) & (yy < int(sys.argv[3]))
ys, xs = np.where(face)
res = {'image_size': [w, h]}
res['crown'] = [int(np.round(xs[ys == ys.min()].mean())), int(ys.min())]
res['chin_tip'] = [int(np.round(xs[ys == ys.max()].mean())), int(ys.max())]
widths = face.sum(1); r = int(np.argmax(widths)); row = np.where(face[r])[0]
res['widest_row_y'] = r; res['widest_left'] = [int(row.min()), r]; res['widest_right'] = [int(row.max()), r]
# split holes into left and right of the centre line
cx = w / 2
for side, sel in (('left', lambda X: X < cx), ('right', lambda X: X >= cx)):
    hy, hx = np.where(holes); m = sel(hx); hy, hx = hy[m], hx[m]
    # keep the biggest blob only by taking rows/cols of the bulk (ignore stray specks under 50 px total)
    res[f'eye_{side}'] = {
        'centre': [int(round(hx.mean())), int(round(hy.mean()))],
        'top': [int(round(hx[hy == hy.min()].mean())), int(hy.min())],
        'bottom': [int(round(hx[hy == hy.max()].mean())), int(hy.max())],
        'inner': None, 'outer': None, 'px': int(m.sum())}
    if side == 'left':
        res[f'eye_{side}']['outer'] = [int(hx.min()), int(round(hy[hx == hx.min()].mean()))]
        res[f'eye_{side}']['inner'] = [int(hx.max()), int(round(hy[hx == hx.max()].mean()))]
    else:
        res[f'eye_{side}']['inner'] = [int(hx.min()), int(round(hy[hx == hx.min()].mean()))]
        res[f'eye_{side}']['outer'] = [int(hx.max()), int(round(hy[hx == hx.max()].mean()))]
print(json.dumps(res, indent=1))
