"""Recogniser items over the FINISHED files in prod2 (kids and monster: WAV and MP3; names: the MP3 of all four shapes
and the WAV of First and Alone). usage: final4.py PROD2_DIR OUT_ITEMS.json
ids: <file id> for the WAV, <file id>.mp3 for the MP3. MP3s are decoded to out4/final_dec/<id>.wav (ffmpeg) first."""
import os, sys, json, subprocess
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
sys.path.insert(0, H)
from common4 import jload, jsave
def dec(mp3, out):
    if not (os.path.exists(out) and os.path.getmtime(out) > os.path.getmtime(mp3)):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", mp3, "-ac", "1", "-ar", "24000", "-c:a", "pcm_s16le", out], check=True)
    return out
def main():
    pd, out = sys.argv[1], sys.argv[2]; dd = os.path.join(V, "out4", "final_dec"); os.makedirs(dd, exist_ok=True)
    its = []
    def add(fid, wavp, text, mp3=True, wav=True):
        if wav: its.append(dict(id=fid, wav=wavp, text=text))
        if mp3: its.append(dict(id=fid + ".mp3", wav=dec(wavp[:-4] + ".mp3", os.path.join(dd, fid + ".wav")), text=text))
    for r in jload(os.path.join(pd, "kids", "kids_pick.json"), {"lines": []})["lines"]:
        add(r["id"], os.path.join(pd, r["file"]), r["text"])
    for r in jload(os.path.join(pd, "kids", "nv_pick.json"), []):
        add(r["id"], os.path.join(pd, r["file"]), None)
    for r in jload(os.path.join(pd, "monster", "mon_final.json"), []):
        if r["made"]: add(r["id"], os.path.join(pd, "monster", r["id"] + ".wav"), r["text"])
    for nm, b in (jload(os.path.join(pd, "names", "bank.json"), {}) or {}).items():
        if not b["in_bank"]: continue
        for shape, f in b["files"].items():
            add(f["id"], os.path.join(pd, f["file"]), nm, wav=shape in ("First", "Alone"))
    jsave(out, its); print(len(its), "items")
if __name__ == "__main__":
    main()
