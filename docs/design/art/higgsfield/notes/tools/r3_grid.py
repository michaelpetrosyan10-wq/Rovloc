# usage: r3_grid.py <in.png> <out.jpg> <step> [x0 y0 x1 y1]   draws a labelled grid (optionally on a crop, labels in full-image coords)
import sys
from PIL import Image, ImageDraw, ImageFont
src, out, step = sys.argv[1], sys.argv[2], int(sys.argv[3])
im = Image.open(src).convert('RGB')
ox = oy = 0
if len(sys.argv) > 4:
    x0, y0, x1, y1 = map(int, sys.argv[4:8]); im = im.crop((x0, y0, x1, y1)); ox, oy = x0, y0
d = ImageDraw.Draw(im); f = ImageFont.load_default(size=18)
w, h = im.size
for x in range(((ox // step) + 1) * step - ox, w, step):
    d.line([(x, 0), (x, h)], fill=(0, 255, 255), width=1)
    for yy in range(0, h, step*3): d.text((x+2, yy+2), str(x+ox), fill=(255, 255, 0), font=f)
for y in range(((oy // step) + 1) * step - oy, h, step):
    d.line([(0, y), (w, y)], fill=(0, 255, 255), width=1)
    for xx in range(0, w, step*3): d.text((xx+2, y+2), str(y+oy), fill=(255, 128, 255), font=f)
im.save(out, quality=88)
