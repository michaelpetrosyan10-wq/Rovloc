"""Round 2 finishing: trim + gentle loudness ONLY (no limiter, no pitch, no stretch, no vocoder).
usage: finish2.py PICKS.json OUTDIR      PICKS: [{"out": name, "src": wav/mp3 path, "lufs": -20}]
Gain to the target integrated loudness (BS.1770, pyloudnorm); if that would put the sample peak above -1.5 dBFS the gain
is lowered instead (the file is then a little quieter than the target). Then MP3 (libmp3lame VBR q4, mono, source rate)."""
import os, sys, json, subprocess
T = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, T)
import numpy as np
import soundfile as sf
import pyloudnorm as pyln
from finish import trim

def level(y, sr, target, peak_max=-1.5):
    lu = pyln.Meter(sr).integrated_loudness(y.astype(np.float64))
    g = 10 ** ((target - lu) / 20)
    pk = np.abs(y).max() * g
    if pk > 10 ** (peak_max / 20):
        g *= 10 ** (peak_max / 20) / pk
    y2 = y * g
    return y2, round(float(pyln.Meter(sr).integrated_loudness(y2.astype(np.float64))), 2), round(float(20 * np.log10(np.abs(y2).max())), 2)

def mp3(path, y, sr):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(sr), "-ac", "1", "-i", "pipe:0",
                    "-c:a", "libmp3lame", "-q:a", "4", "-map_metadata", "-1", "-id3v2_version", "0", "-write_xing", "1", path],
                   input=np.ascontiguousarray(y, dtype=np.float32).tobytes(), check=True)

def main():
    picks = json.load(open(sys.argv[1])); out = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    rep = []
    for p in picks:
        x, sr = sf.read(p["src"], dtype="float32", always_2d=True); x = x.mean(axis=1)
        if p.get("trim", True):
            x = trim(x, sr, p.get("lead", 0.06), p.get("trail", 0.25))
        y, lu, pk = level(x, sr, p.get("lufs", -20.0))
        if p.get("wav"):
            sf.write(os.path.join(out, p["out"] + ".wav"), y, sr, subtype="FLOAT")
        mp3(os.path.join(out, p["out"] + ".mp3"), y, sr)
        rep.append(dict(p, lufs_out=lu, peak_db=pk, dur=round(len(y) / sr, 2), sr=sr))
        print(p["out"], lu, pk, round(len(y) / sr, 2), flush=True)
    json.dump(rep, open(os.path.join(out, "finish_report.json"), "w"), indent=1)

if __name__ == "__main__":
    main()
