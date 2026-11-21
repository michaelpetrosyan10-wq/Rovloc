"""Render a list of lines with their voice recipes, in time-boxed batches.

usage: render.py MODELS_DIR LINES.json OUT_DIR [--only PREFIX,...]
LINES: [{"id", "text", "engine": "kokoro"|"cbturbo"|"kitten", "recipe": {...}, "seed": int}, ...]
Writes OUT_DIR/<id>.wav (float, engine rate) and OUT_DIR/<id>.json (what made it + compute seconds).
A file whose recipe/text/seed are unchanged is skipped. Stops after BATCH_SECONDS (default 110) and exits 3 when
lines remain, so the caller re-runs it as a new run-heavy batch.
"""
import os, sys, json, time, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from common import read_json, write_json, save

ENGINES = {}


def engine(name, models):
    if name not in ENGINES:
        t = time.time()
        if name == "kokoro":
            from kokoro_engine import KokoroEngine
            ENGINES[name] = KokoroEngine(os.path.join(models, "kokoro"))
        elif name == "cbturbo":
            from cbturbo_engine import CBTurboEngine
            ENGINES[name] = CBTurboEngine(os.path.join(models, "cbturbo"))
        elif name == "kitten":
            from kitten_engine import KittenEngine
            ENGINES[name] = KittenEngine(os.path.join(models, "kitten"))
        print(f"loaded {name} in {time.time()-t:.1f}s", flush=True)
    return ENGINES[name]


def key(it):
    s = json.dumps({k: it.get(k) for k in ("text", "engine", "recipe", "seed")}, sort_keys=True)
    if it["engine"] == "cbturbo":
        s += hashlib.sha256(open(it["recipe"]["ref"], "rb").read()).hexdigest()
    return hashlib.sha256(s.encode()).hexdigest()[:20]


def main():
    models, lines_p, out = sys.argv[1], sys.argv[2], sys.argv[3]
    only = None
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1].split(",")
    items = read_json(lines_p)
    budget = float(os.environ.get("BATCH_SECONDS", "110"))
    t0 = time.time()
    left = done = 0
    for it in items:
        if only and not any(it["id"].startswith(o) for o in only):
            continue
        k = key(it)
        mp = os.path.join(out, it["id"] + ".json")
        if os.path.exists(mp) and os.path.exists(os.path.join(out, it["id"] + ".wav")):
            try:
                if read_json(mp).get("key") == k:
                    continue
            except Exception:
                pass
        if time.time() - t0 > budget:
            left += 1
            continue
        eng = engine(it["engine"], models)
        t = time.time()
        a, sr = eng.render(it["text"], it["recipe"], seed=int(it.get("seed", 0)))
        el = time.time() - t
        a = np.asarray(a, dtype=np.float32).reshape(-1)
        save(os.path.join(out, it["id"] + ".wav"), a, sr)
        dur = len(a) / sr
        write_json(mp, {"id": it["id"], "key": k, "text": it["text"], "engine": it["engine"], "recipe": it["recipe"],
                        "seed": it.get("seed", 0), "compute_s": round(el, 2), "audio_s": round(dur, 3),
                        "rtf": round(el / max(dur, 1e-3), 3),
                        "runaway": bool(getattr(eng, "last_runaway", False))})
        done += 1
        print(f'{it["id"]:34s} {dur:5.2f}s audio {el:6.1f}s compute rtf {el/max(dur,1e-3):.2f}', flush=True)
    print(f"rendered {done}, left {left}, {time.time()-t0:.0f}s", flush=True)
    sys.exit(3 if left else 0)


if __name__ == "__main__":
    main()
