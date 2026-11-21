# build the round-3 monster skin sheet: usage r3_sheet.py <higg dir> <out.jpg>
import sys, os
from PIL import Image, ImageDraw, ImageFont
H, out = sys.argv[1], sys.argv[2]
PH = 1000; GAP = 24; TOP = 90; BOT = 20
f = ImageFont.load_default(size=30); fs = ImageFont.load_default(size=22)
def fit(p, h):
    im = Image.open(p).convert('RGB'); return im.resize((round(im.width*h/im.height), h), Image.LANCZOS)
cols = [
  ('The favourite (B3)', 'design reference', fit(H+'/dl/M-B3/M-B3-v1.png', PH)),
  ('Face, front', 'face-front.png (new, hood)', fit(H+'/pack3/face-front.png', PH)),
  ('Hand, back', 'hand-back.png', fit(H+'/pack3/hand-back.png', PH)),
  ('Hand, back (alt)', 'alt/hand-back-alt.png', fit(H+'/pack3/alt/hand-back-alt.png', PH)),
  ('Hand, palm', 'hand-palm.png (new, no ink)', fit(H+'/pack3/hand-palm.png', PH)),
]
half = (PH - GAP - 60) // 2
tiles = [('Skin tile', 'skin-tile-seamless.png', fit(H+'/pack3/skin-tile-seamless.png', half)),
         ('Hood cloth tile', 'cloth-tile-seamless.png', fit(H+'/pack3/cloth-tile-seamless.png', half))]
W = GAP + sum(c[2].width + GAP for c in cols) + half + GAP
Hh = TOP + PH + BOT
sheet = Image.new('RGB', (W, Hh), (22, 22, 24)); d = ImageDraw.Draw(sheet)
x = GAP
for title, sub, im in cols:
    sheet.paste(im, (x, TOP)); d.text((x, 14), title, fill=(235, 235, 235), font=f); d.text((x, 52), sub, fill=(160, 160, 160), font=fs)
    x += im.width + GAP
y = TOP
for title, sub, im in tiles:
    d.text((x, y - 4 if y == TOP else y), '', font=fs)
    if y == TOP:
        d.text((x, 14), 'Tiles (seamless)', fill=(235, 235, 235), font=f)
    d.text((x, y), title, fill=(235, 235, 235), font=fs); sheet.paste(im, (x, y + 30)); y += 30 + im.height + GAP
sheet = sheet.resize((2600, round(Hh * 2600 / W)), Image.LANCZOS)
for q in (85, 80, 75, 70, 65):
    sheet.save(out, quality=q, optimize=True)
    if os.path.getsize(out) < 700*1024: break
print(out, sheet.size, os.path.getsize(out), 'q', q)
