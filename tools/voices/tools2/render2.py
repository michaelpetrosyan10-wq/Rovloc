"""Round 2 renderer, time-boxed (BATCH_SECONDS, default 100): exits 3 while lines remain.
usage: render2.py MODELS_DIR LINES.json OUT_DIR
LINES: [{"id","text","engine": kokoro|cbturbo|cbfull,"recipe":{...},"seed"}]   -> OUT_DIR/<id>.wav + .json
Nothing is shifted, stretched or vocoded here: the engines' own output, saved as float WAV."""
import os, sys, json, time, hashlib
R = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, R); sys.path.insert(0, os.path.join(os.path.dirname(R), "tools"))
from common import read_json, write_json, save
E = {}
def engine(name, models):
    if name not in E:
        if name == "kokoro":
            from kokoro_engine import KokoroEngine; E[name] = KokoroEngine(os.path.join(models, "kokoro"))
        elif name == "cbturbo":
            from cbturbo_engine import CBTurboEngine; E[name] = CBTurboEngine(os.path.join(models, "cbturbo"))
        elif name == "cbfull":
            from cbfull_engine import CBFullEngine; E[name] = CBFullEngine(os.path.join(models, "cbfull"))
    return E[name]
def key(it):
    s = json.dumps({k: it.get(k) for k in ("text", "engine", "recipe", "seed")}, sort_keys=True)
    if "ref" in it.get("recipe", {}):
        s += hashlib.sha256(open(it["recipe"]["ref"], "rb").read()).hexdigest()
    return hashlib.sha256(s.encode()).hexdigest()[:20]
def main():
    models, lines, out = sys.argv[1], read_json(sys.argv[2]), sys.argv[3]
    budget = float(os.environ.get("BATCH_SECONDS", "100"))
    t0 = time.time(); left = 0
    for it in lines:
        j = os.path.join(out, it["id"] + ".json"); k = key(it)
        if os.path.exists(j) and read_json(j).get("key") == k:
            continue
        if time.time() - t0 > budget:
            left += 1; continue
        eng = engine(it["engine"], models)
        t = time.time()
        a, sr = eng.render(it["text"], it["recipe"], seed=it.get("seed", 0))
        dt = time.time() - t
        save(os.path.join(out, it["id"] + ".wav"), a, sr)
        meta = dict(it, key=k, secs=round(dt, 2), dur=round(len(a) / sr, 2), runaway=bool(getattr(eng, "last_runaway", False)))
        write_json(j, meta)
        print(f"{it['id']}: {meta['dur']}s in {dt:.1f}s runaway={meta['runaway']}", flush=True)
    print(f"left {left}", flush=True)
    sys.exit(3 if left else 0)
if __name__ == "__main__":
    main()
