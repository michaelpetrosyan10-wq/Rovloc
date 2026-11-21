"""Check the built board as the player gets it: decode every MP3 and measure it.

usage: board_check.py BOARD_DIR MODELS_DIR OUT.json
- page: every <audio> file exists, every file in a/ is used, no http/https/@import/url()/<script>/<link> in the page
- per MP3: true peak after decoding (must be <= -1.0 dBTP), any sample clipping, the longest run of digital silence
  (|x| < 1e-5) inside the file (must be < 50 ms), the level of the last 50 ms before the 30 ms fade relative to the
  loudest frame (for cut endings), duration
- voices: Chatterbox speaker-embedding cosine between candidates (centroid of each candidate's board files) and the
  median pitch of each candidate's dialogue files
"""
import os, sys, re, json, glob, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from scipy.signal import resample_poly
from common import ort_session, write_json


def decode(p, sr=24000):
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", p, "-f", "f32le", "-ac", "1", "-ar", str(sr), "pipe:1"],
                       capture_output=True, check=True)
    return np.frombuffer(r.stdout, dtype=np.float32).copy(), sr


def fdb(x, sr, hop=0.01):
    n = int(sr * hop)
    m = len(x) // n
    f = x[: m * n].reshape(m, n)
    return 20 * np.log10(np.sqrt((f ** 2).mean(1)) + 1e-12)


def zero_run(x, sr):
    z = np.abs(x) < 1e-5
    # ignore the file's own start and end (the encoder's padding and the fades)
    a, b = int(0.03 * sr), len(x) - int(0.06 * sr)
    best = cur = 0
    for v in z[a:b]:
        cur = cur + 1 if v else 0
        best = max(best, cur)
    return best / sr


def main():
    board, models, out = sys.argv[1:4]
    page = open(os.path.join(board, "index.html"), encoding="utf-8").read()
    srcs = re.findall(r'src="(a/[^"]+)"', page)
    files = sorted(os.listdir(os.path.join(board, "a")))
    res = {"page": {
        "audio_tags": len(srcs), "unique": len(set(srcs)),
        "missing": [s for s in set(srcs) if not os.path.exists(os.path.join(board, s))],
        "unused": [f for f in files if "a/" + f not in srcs],
        "external": re.findall(r'https?://|@import|url\(|<script|<link', page),
        "mb": round(sum(os.path.getsize(os.path.join(board, "a", f)) for f in files) / 1e6, 2)}}
    enc = ort_session(os.path.join(models, "cbturbo", "onnx", "speech_encoder_quantized.onnx"))
    import pyworld as pw
    rows, E, F = {}, {}, {}
    for f in files:
        x, sr = decode(os.path.join(board, "a", f))
        fid = f[:-4]
        d = fdb(x, sr)
        tp = 20 * np.log10(np.abs(resample_poly(x, 4, 1)).max() + 1e-12)
        end = float(fdb(x[-int(0.08 * sr):-int(0.03 * sr)], sr).max() - d.max())
        rows[fid] = {"dur": round(len(x) / sr, 2), "tp": round(float(tp), 2), "clip": int((np.abs(x) >= 0.999).sum()),
                     "zero_run_s": round(zero_run(x, sr), 3), "end_db": round(end, 1)}
        m = re.match(r"(danny|marcus|priya|gus)_([abc])_", fid)
        if m:
            e = enc.run(None, {"audio_values": x[None, :]})[2].reshape(-1)
            k = f"{m.group(1)}_{m.group(2)}"
            E.setdefault(k, []).append(e / np.linalg.norm(e))
            f0, _ = pw.harvest(x.astype(np.float64), sr, f0_floor=60, f0_ceil=500, frame_period=10)
            F.setdefault(k, []).append(float(np.median(f0[f0 > 0])) if (f0 > 0).any() else 0)
    res["files"] = rows
    C = {k: (np.mean(v, axis=0) / np.linalg.norm(np.mean(v, axis=0))) for k, v in E.items()}
    ks = sorted(C)
    res["cos"] = {a: {b: round(float(C[a] @ C[b]), 3) for b in ks} for a in ks}
    res["f0_median_of_medians"] = {k: round(float(np.median(v)), 1) for k, v in F.items()}
    res["f0_lines"] = {k: [round(v, 1) for v in vs] for k, vs in F.items()}
    write_json(out, res)
    print("page:", {k: v for k, v in res["page"].items()})
    bad_tp = {k: v["tp"] for k, v in rows.items() if v["tp"] > -1.0}
    # the monster, name and join files must never hold digital silence (review M3); dialogue lines may have a
    # silent pause between sentences (<= 0.34 s after finish.py), which is listed for information only
    bad_z = {k: v["zero_run_s"] for k, v in rows.items() if v["zero_run_s"] >= 0.05 and k.startswith(("mon_", "name_", "join_"))}
    info_z = {k: v["zero_run_s"] for k, v in rows.items() if v["zero_run_s"] >= 0.05 and k not in bad_z}
    res["dialogue_silent_pauses_s"] = info_z
    bad_c = {k: v["clip"] for k, v in rows.items() if v["clip"]}
    print(f"{len(rows)} mp3; max true peak {max(v['tp'] for v in rows.values()):.2f} dBTP; over -1.0: {bad_tp}; "
          f"clipped: {bad_c}; digital-silence runs >= 50 ms in monster/name/join files: {bad_z}")
    print("silent pauses in dialogue lines (information):", info_z)
    print("ends less than 35 dB under the peak:", {k: v["end_db"] for k, v in rows.items() if v["end_db"] > -35})
    print("median pitch (Hz):", res["f0_median_of_medians"])
    print(" " * 9 + " ".join(f"{k:>8s}" for k in ks))
    for a in ks:
        print(f"{a:9s}" + " ".join(f"{res['cos'][a][b]:8.2f}" for b in ks))


if __name__ == "__main__":
    main()
