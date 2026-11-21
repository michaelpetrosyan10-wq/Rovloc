"""Speaker distance: cosine of Chatterbox's own speaker embeddings (speech encoder output 2) and median F0.

usage: spk_check.py MODELS_DIR OUT.json WAV [WAV ...]
       spk_check.py MODELS_DIR OUT.json --probe PROBE.json REF_OUT_DIR
PROBE: {"name": {"blend": {...}, "speed": 1.05, "shift": [pitch_st, formant]?}, ...}: renders each candidate
reference (Kokoro, our REF_TEXT) to REF_OUT_DIR/<name>.wav first, then compares everything given.
Prints a cosine table; writes {"f0": {...}, "cos": {a: {b: c}}}.
"""
import os, sys, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from common import ort_session, load, save, write_json

SR = 24000


def f0_median(x, sr):
    import pyworld as pw
    f0, _ = pw.harvest(x.astype(np.float64), sr, f0_floor=60, f0_ceil=500, frame_period=10)
    v = f0[f0 > 0]
    return float(np.median(v)) if len(v) else 0.0


def main():
    models, out = sys.argv[1], sys.argv[2]
    wavs = []
    if sys.argv[3] == "--probe":
        from kokoro_engine import KokoroEngine
        from cast import REF_TEXT
        import voxfx as fx
        probe = json.load(open(sys.argv[4]))
        rdir = sys.argv[5]
        k = KokoroEngine(os.path.join(models, "kokoro"))
        for name, r in probe.items():
            p = os.path.join(rdir, name + ".wav")
            if not os.path.exists(p):
                a, sr = k.render(REF_TEXT, {"blend": r["blend"], "speed": r.get("speed", 1.0)})
                if r.get("shift"):
                    a = fx.world_shift(a, sr, r["shift"][0], r["shift"][1])
                save(p, a, sr)
            wavs.append(p)
        wavs += sys.argv[6:]
    else:
        wavs = sys.argv[3:]
    enc = ort_session(os.path.join(models, "cbturbo", "onnx", "speech_encoder_quantized.onnx"))
    E, F = {}, {}
    for p in wavs:
        x, _ = load(p, SR)
        e = enc.run(None, {"audio_values": x[None, :].astype(np.float32)})[2].reshape(-1)
        n = os.path.basename(p)[:-4]
        E[n] = e / np.linalg.norm(e)
        F[n] = round(f0_median(x, SR), 1)
    ks = list(E)
    C = {a: {b: round(float(E[a] @ E[b]), 3) for b in ks} for a in ks}
    print(" " * 16 + " ".join(f"{k[:9]:>9s}" for k in ks))
    for a in ks:
        print(f"{a[:12]:12s}{F[a]:4.0f}" + " ".join(f"{C[a][b]:9.2f}" for b in ks))
    write_json(out, {"f0": F, "cos": C})


if __name__ == "__main__":
    main()
