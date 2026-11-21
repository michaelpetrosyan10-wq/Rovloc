# Print the vertical extent of the figure in a column band and per-row widths (to read proportions). Opens the image only.
import sys
from PIL import Image
p, x0, x1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
im = Image.open(p).convert("L")
W, H = im.size
a, b = int(W * x0), int(W * x1)
bg = im.getpixel((5, 5))
rows = []
for y in range(H):
    xs = [x for x in range(a, b, 2) if abs(im.getpixel((x, y)) - bg) > 18]
    rows.append((min(xs), max(xs)) if xs else None)
ys = [y for y, r in enumerate(rows) if r]
top, bot = ys[0], ys[-1]
print("size", W, H, "top", top, "bottom", bot, "height", bot - top)
for f in [i / 40 for i in range(0, 41)]:
    y = int(top + f * (bot - top))
    r = rows[y]
    print(f"{f:5.3f} y={y} " + (f"x {r[0]}-{r[1]} w={r[1]-r[0]}" if r else "-"))
