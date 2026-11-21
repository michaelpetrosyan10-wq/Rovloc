# Contact sheets for the art director's round 1. Run: python3 -I sheets.py
# Reads the downloaded PNGs (untrusted data: opened as images only), writes JPEGs <= 1800 px wide into send/.
import os
from PIL import Image, ImageDraw, ImageFont

S = "/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad"
DL = S + "/higg/dl"
OUT = S + "/send"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_R = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
BG = (14, 14, 16)
BAND = (30, 30, 34)
INK = (240, 236, 224)
DIM = (170, 166, 156)
W = 1800
M = 10          # gap
LAB = 44        # label band height


def font(size, bold=True):
    return ImageFont.truetype(FONT if bold else FONT_R, size)


def tile(path, w, h, label, sub=""):
    """A w x (h+LAB) tile: a label band, then the picture fitted into w x h on black."""
    t = Image.new("RGB", (w, h + LAB), (0, 0, 0))
    d = ImageDraw.Draw(t)
    d.rectangle([0, 0, w, LAB], fill=BAND)
    d.text((10, 8), label, font=font(24), fill=INK)
    if sub:
        lw = d.textlength(label, font=font(24))
        d.text((10 + lw + 12, 14), sub, font=font(16, False), fill=DIM)
    im = Image.open(path).convert("RGB")
    im.thumbnail((w, h), Image.LANCZOS)
    t.paste(im, ((w - im.width) // 2, LAB + (h - im.height) // 2))
    return t


def sheet(title, note, rows, name):
    """rows: list of lists of tiles (already built). Rows are left-aligned and stacked."""
    head = 78
    height = head + sum(max(t.height for t in r) + M for r in rows) + M
    img = Image.new("RGB", (W, height), BG)
    d = ImageDraw.Draw(img)
    d.text((M, 10), title, font=font(30), fill=INK)
    d.text((M, 48), note, font=font(16, False), fill=DIM)
    y = head
    for r in rows:
        x = M
        for t in r:
            img.paste(t, (x, y))
            x += t.width + M
        y += max(t.height for t in r) + M
    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, name)
    img.save(out, "JPEG", quality=88, optimize=True)
    print(out, img.size, os.path.getsize(out))


def monsters():
    cw = (W - 4 * M) // 3
    ch = cw * 3 // 2
    grid = [
        [("M-A1/M-A1-v4.png", "A1", "stretched boy · corridor"),
         ("M-B1/M-B1-v1.png", "B1", "hunched one · corridor, vent"),
         ("M-C1/M-C1-v1.png", "C1", "porcelain spreads · corridor")],
        [("M-A2/M-A2-v1.png", "A2", "stretched boy · back lot, dusk"),
         ("M-B2/M-B2-v1.png", "B2", "hunched one · back lot, dusk"),
         ("M-C2/M-C2-v1.png", "C2", "porcelain spreads · back lot")],
        [("M-A3/M-A3-v2.png", "A3", "stretched boy · close, torch beam"),
         ("M-B3/M-B3-v1.png", "B3", "hunched one · close, eye level"),
         ("M-C3/M-C3-v2.png", "C3", "porcelain spreads · knees up")],
    ]
    rows = [[tile(os.path.join(DL, p), cw, ch, a, b) for p, a, b in r] for r in grid]
    sheet("ROVLOC · the monster's body · three directions",
          "A the stretched boy   |   B the hunched one   |   C the porcelain spreads      (Higgsfield design tests, round 1)",
          rows, "art-monster-directions.jpg")


def tries():
    cw = (W - 5 * M) // 4
    ch = cw * 16 // 9
    items = [
        ("monster01/monster-01.png", "T0", "first test (the player saw it)"),
        ("M-A1/M-A1-v1.png", "A1 v1", "giant long head"),
        ("M-A1/M-A1-v2.png", "A1 v2", "big head, glowing eyes"),
        ("M-A1/M-A1-v3.png", "A1 v3", "stick figure"),
        ("M-A3/M-A3-v1.png", "A3 v1", "tube neck"),
        ("M-B1/M-B1-v2.png", "B1 v2", "soul_2: real body, wrong mask"),
        ("M-C3/M-C3-v1.png", "C3 v1", "egg head"),
    ]
    ts = [tile(os.path.join(DL, p), cw, ch, a, b) for p, a, b in items]
    sheet("ROVLOC · monster tries that were rejected (for the lead, not for the player)",
          "kept so that round 2 does not repeat them", [ts[:4], ts[4:]], "art-monster-rejected-tries.jpg")


def danny_thing():
    h1 = 800
    w_d = h1 * 2 // 3
    w_k = W - 3 * M - w_d
    r1 = [tile(DL + "/D/D2-v1.png", w_d, h1, "D2", "Danny as he was"),
          tile(DL + "/K/K-v1.png", w_k, h1, "K", "Kayla (left) and Marcus (right)")]
    cw = (W - 4 * M) // 3
    ch = cw * 2 // 3
    r2 = [tile(DL + "/T/T1-v1.png", cw, ch, "T1", "the thing · sitting by the bin"),
          tile(DL + "/T/T2-v1.png", cw, ch, "T2", "the thing · mid-hop"),
          tile(DL + "/T/T3-v1.png", cw, ch, "T3", "the thing · beside a sneaker")]
    sheet("ROVLOC · Danny, his classmates and the thing",
          "Higgsfield design tests, round 1  (not made, the cap was reached: Danny's portrait, Danny from behind, the thing T4)",
          [r1, r2], "art-danny-thing.jpg")


def change():
    cw = (W - 5 * M) // 4
    ch = cw * 3 // 2
    items = [("X/X1-v1.png", "X1", "it sits on him"),
             ("X/X2-v1.png", "X2", "the frost"),
             ("X/X3-v1.png", "X3", "the rise"),
             ("X/X4-v1.png", "X4", "almost the monster")]
    ts = [tile(os.path.join(DL, p), cw, ch, a, b) for p, a, b in items]
    sheet("ROVLOC · the change, in the back lot as the light fails",
          "Higgsfield design tests, round 1, in the order of the script's stages", [ts], "art-change.jpg")


if __name__ == "__main__":
    monsters()
    tries()
    danny_thing()
    change()
