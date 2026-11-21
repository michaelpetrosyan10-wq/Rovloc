import numpy as np
from PIL import Image, ImageDraw, ImageFont
P='/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/higg/pack3'
OUT='/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/send/art-world-paintings.jpg'
def card(name, bg):
    im = Image.open(f'{P}/{name}').convert('RGBA')
    c = Image.new('RGBA', im.size, bg); c.alpha_composite(im); return c.convert('RGB')
items = [
 ('window-night.jpg', None, 'Behind the classroom windows (upper floor, rain, sodium lamps)'),
 ('skyline-wrap.jpg', None, 'Back lot skyline, wraps left to right'),
 ('sky.jpg', None, 'Night sky, moon behind cloud'),
 ('title.jpg', None, 'Title plate: empty corridor (figure painted out)'),
 ('stain-water.png', (128,128,128,255), 'Water stain decal, shown over mid-grey'),
 ('stain-mould.png', (199,217,194,255), 'Black mould decal, shown over pale green'),
]
CW, pad, lab = 880, 24, 44
font = ImageFont.load_default(size=26)
cells = []
for f, bg, text in items:
    im = card(f, bg) if bg else Image.open(f'{P}/{f}').convert('RGB')
    if f.startswith('stain'):
        s = 430 / im.size[1]
    else:
        s = CW / im.size[0]
    im = im.resize((round(im.size[0]*s), round(im.size[1]*s)), Image.LANCZOS)
    cells.append((im, text))
rows = [cells[0:2], cells[2:4], cells[4:6]]
H = pad + sum(max(c[0].size[1] for c in r) + lab + pad for r in rows) + 60
W = pad*3 + CW*2
sheet = Image.new('RGB', (W, H), (18, 20, 20)); d = ImageDraw.Draw(sheet)
d.text((pad, 14), 'ROVLOC - world paintings, round 3 second pass (Higgsfield, used in the game)', fill=(225,228,225), font=ImageFont.load_default(size=32))
y = 60
for r in rows:
    x = pad
    for im, text in r:
        d.text((x, y + 6), text, fill=(210,214,210), font=font)
        sheet.paste(im, (x + (CW - im.size[0])//2, y + lab))
        x += CW + pad
    y += max(c[0].size[1] for c in r) + lab + pad
sheet.save(OUT, quality=82, optimize=True, progressive=True)
import os; print(sheet.size, os.path.getsize(OUT))
