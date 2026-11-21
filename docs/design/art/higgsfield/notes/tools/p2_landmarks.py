# second pass: update pack3/landmarks.json (new face, new palm, hand-back index MCP fix, alt hand) and draw every point back
import json, sys
from PIL import Image, ImageDraw, ImageFont
H = '/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/higg'
P = H + '/pack3'; W = H + '/work3p2'
lm = json.load(open(P + '/landmarks.json'))
lm['note'] = ("Pixel coordinates [x, y] in the game-ready files in this folder (origin top-left, y down). Left/right are IMAGE left/right "
  "(the viewer's). SECOND PASS (18 Nov): face-front.png and hand-palm.png are new pictures; face eye holes measured by script "
  "(tools/p2_holes.py: dark region grown from a seed), streaks traced row by row, the rest read off labelled grids; all drawn back "
  "in work3p2/*-lm.jpg. Hand 'mcp' knuckles and finger-base creases are approximate (+-40 px); fingertips, thumb tips, pip/ip "
  "joints and wrist +-15 px. Pairs named '*_x_pair' are two separate points, not one.")
lm['face-front.png'] = {
  "size": [736, 2023],
  "source": "job 6988465c-1664-4e7d-8d52-caeb1be96983, squeezed to 0.75 width so the face is about 2.6 times as long as it is wide (B3); the hood is part of the picture",
  "hood_top": [380, 24],
  "brow_top_under_hood": [375, 272],
  "brow_centre": [375, 560],
  "eye_hole_left":  {"centre": [199, 844], "outer": [50, 625], "inner": [349, 1073], "top": [50, 620], "bottom": [348, 1074]},
  "eye_hole_right": {"centre": [545, 838], "outer": [686, 609], "inner": [400, 1075], "top": [685, 604], "bottom": [400, 1076]},
  "streak_left":  {"top": [336, 1078], "lower_end": [325, 1345]},
  "streak_right": {"top": [410, 1078], "lower_end": [407, 1390]},
  "mouth_slit": {"left": [318, 1730], "right": [420, 1730], "centre": [368, 1732]},
  "face_tip": [372, 1938],
  "face_edge_at_eye_level_x_pair": [[44, 612], [694, 612]],
  "centre_line_x": 375
}
lm['alt/face-front-alt.png'] = {"size": [982, 2023], "note": "the same picture NOT squeezed (x * 1/0.75 of face-front.png points)"}
lm['hand-palm.png'] = {
  "size": [1536, 2021],
  "source": "job b95ce3bf-1777-4d7c-a1c5-23ac7d37dfe5 (no ink, nothing painted out)",
  "hand": "right hand, palm (volar) view, thumb on the image right, wrist at the bottom edge",
  "wrist_centre": [697, 2015],
  "fingertips": {"little": [242, 440], "ring": [455, 172], "middle": [740, 28], "index": [1028, 136], "thumb": [1404, 752]},
  "pip_creases": {"little": [303, 697], "ring": [515, 630], "middle": [747, 505], "index": [1000, 570]},
  "thumb_ip_crease": [1252, 909],
  "finger_base_creases_mcp": {"little": [400, 930], "ring": [555, 860], "middle": [755, 840], "index": [960, 850]},
  "thumb_mcp": [1121, 1162]
}
lm['hand-back.png']['mcp_knuckles']['index'] = [560, 900]
lm['alt/hand-back-alt.png'] = {
  "size": [1235, 1912],
  "source": "job df2bf6fc-ccc1-4796-8398-41a1c52f1480 (a LEFT hand back mirrored to a right hand); closest to B3: long knotted fingers",
  "hand": "right hand, back (dorsal) view, palm down, thumb on the image left, wrist at the bottom edge",
  "wrist_centre": [670, 1900],
  "fingertips": {"thumb": [28, 768], "index": [405, 115], "middle": [705, 28], "ring": [985, 170], "little": [1195, 478]},
  "dip_knuckles": {"index": [440, 290], "middle": [700, 225], "ring": [935, 345], "little": [1150, 620]},
  "pip_knuckles": {"index": [450, 470], "middle": [700, 455], "ring": [880, 570], "little": [1045, 770]},
  "thumb_ip_joint": [230, 850],
  "mcp_knuckles": {"index": [480, 850], "middle": [655, 830], "ring": [790, 860], "little": [920, 870]},
  "thumb_mcp": [300, 1080]
}
json.dump(lm, open(P + '/landmarks.json', 'w'), indent=1)
f = ImageFont.load_default(size=16)
def pts(d, pre=''):
    for k, v in d.items():
        if isinstance(v, dict): yield from pts(v, pre + k + '.')
        elif isinstance(v, list) and len(v) == 2 and all(isinstance(t, int) for t in v): yield pre + k, v
        elif isinstance(v, list) and v and isinstance(v[0], list):
            for i, p in enumerate(v): yield f'{pre}{k}[{i}]', p
for name in ('face-front.png', 'hand-palm.png', 'hand-back.png', 'alt/hand-back-alt.png'):
    im = Image.open(f'{P}/{name}').convert('RGB'); d = ImageDraw.Draw(im)
    for k, (x, y) in pts({k: v for k, v in lm[name].items() if k != 'size'}):
        d.ellipse([x-9, y-9, x+9, y+9], outline=(255, 40, 40), width=3); d.text((x+11, y-8), k, fill=(255, 255, 0), font=f)
    out = W + '/' + name.replace('/', '_').replace('.png', '-lm.jpg'); im.save(out, quality=85); print(out)
