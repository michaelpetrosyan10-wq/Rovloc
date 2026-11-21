# draw every landmark of one file back onto a copy: usage r3_check.py <pack3 dir> <file> <out.jpg>
import sys, json
from PIL import Image, ImageDraw, ImageFont
d0, fn, out = sys.argv[1:4]
L = json.load(open(d0 + '/landmarks.json'))[fn]
im = Image.open(d0 + '/' + fn).convert('RGB'); d = ImageDraw.Draw(im); f = ImageFont.load_default(size=22)
def walk(o, name=''):
    if isinstance(o, list) and len(o) == 2 and all(isinstance(v, int) for v in o): yield name, o
    elif isinstance(o, dict):
        for k, v in o.items(): yield from walk(v, (name + '.' + k).strip('.'))
for name, (x, y) in walk(L):
    if name in ('size',) or name.startswith('width_at'): continue
    d.ellipse([x-9, y-9, x+9, y+9], outline=(255, 0, 0), width=3); d.line([x-14, y, x+14, y], fill=(255, 0, 0)); d.line([x, y-14, x, y+14], fill=(255, 0, 0))
    d.text((x+12, y-10), name, fill=(0, 255, 0), font=f)
im.save(out, quality=85)
