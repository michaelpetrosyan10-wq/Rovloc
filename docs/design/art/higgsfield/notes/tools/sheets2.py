# Round 2 contact sheets. Run: python3 -I sheets2.py  (downloads are opened as images only)
import sys
sys.path.insert(0, "/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/higg/tools")
from sheets import tile, sheet, DL, W, M

def two(a, b, h_a_ratio, h_b_ratio, wa):
    """two tiles in a row sharing one height: a's aspect w/h = h_a_ratio, b's = h_b_ratio."""
    wb = W - 3 * M - wa
    return wa, wb

def final():
    cw = (W - 5 * M) // 4
    ch = cw * 16 // 9
    r1 = [tile(DL + "/M-B3/M-B3-v1.png", cw, ch, "B3", "the player's pick"),
          tile(DL + "/R-P1/R-P1-v3.png", cw, ch, "P1", "corridor, far"),
          tile(DL + "/R-P2/R-P2-v2.png", cw, ch, "P2", "back lot, lamp"),
          tile(DL + "/R-P4/R-P4-v2.png", cw, ch, "P4", "round the door")]
    r2 = [tile(DL + "/R-P3/R-P3-v1.png", W - 2 * M, 760, "P3", "folding into the low wall vent, head turned back")]
    sheet("ROVLOC · the monster in play · round 2",
          "B3 is the face the player chose; P1-P4 are the same being in play (Higgsfield soul_cinematic, 17 Nov)",
          [r1, r2], "art-monster-final.jpg")

def model_sheet():
    wa = 1100; wb = W - 3 * M - wa
    r1 = [tile(DL + "/R-S1/R-S1-v1.png", wa, wa * 9 // 16, "HEAD", "front · profile · three-quarter"),
          tile(DL + "/R-S2/R-S2-v2.png", wb, wa * 9 // 16, "HAND", "back · palm")]
    r2 = [tile(DL + "/R-S3/R-S3-v2.png", wa, wa * 9 // 16, "BODY", "A-pose front · side · back (face wrong: use HEAD)"),
          tile(DL + "/R-S3/R-S3-v1.png", wb, wa * 9 // 16, "BODY v1", "clothes and face; back view wrong")]
    sheet("ROVLOC · the monster · design sheet for the 3D model",
          "plain grey, flat light. Head from HEAD, hand from HAND, proportions from BODY; B3 decides wherever they disagree",
          [r1, r2], "art-monster-sheet.jpg")

def danny_sheet():
    wa = 1100; wb = W - 3 * M - wa
    h = wa * 9 // 16
    r1 = [tile(DL + "/R-D/R-D-v2.png", wa, h, "DANNY", "A-pose front · 'side' (head turned only)"),
          tile(DL + "/R-T/R-T-v1.png", wb, h, "THE THING", "side (face too big: use T1's)")]
    r2 = [tile(DL + "/D/D2-v1.png", wa // 2, 640, "D2", "round 1: Danny's face"),
          tile(DL + "/T/T1-v1.png", W - 3 * M - wa // 2, 640, "T1", "round 1: the thing's face and size")]
    sheet("ROVLOC · Danny and the thing · design sheet",
          "grey studio views from round 2 above; round 1's pictures below decide the faces",
          [r1, r2], "art-danny-sheet.jpg")

if __name__ == "__main__":
    final(); model_sheet(); danny_sheet()
