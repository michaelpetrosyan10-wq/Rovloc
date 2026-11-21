"""Pick monster base takes and write the treatment spec. usage: monspec.py MONDIR"""
import os, sys, json
D = sys.argv[1]; M = json.load(open(os.path.join(D, "measure.json")))
spec = []
for lid in ("w", "s", "f", "c"):
    calm = [k for k in M if k.startswith(f"calm_{lid}_") and M[k].get("wer") == 0]
    norm = [k for k in M if k.startswith(f"norm_{lid}_") and M[k].get("wer") == 0]
    c = max(calm, key=lambda k: M[k]["span"]) if calm else None          # the slowest calm take
    n = max(norm, key=lambda k: M[k]["f0_sd_st"]) if norm else None      # the liveliest normal take
    print(lid, "calm", c, M[c]["span"] if c else None, "norm", n)
    if c:
        spec.append(dict(out=f"monster4_{lid}", mode="late", main=os.path.join(D, c + ".wav"), delay=0.24, whisper_db=-8))
        spec.append(dict(out=f"monster5_{lid}", mode="close", main=os.path.join(D, c + ".wav"),
                         breath=os.path.join(os.path.dirname(os.path.dirname(D)), "out", "breath_synth.wav"), breath_db=-10, beat=0.3))
    if n:
        spec.append(dict(out=f"monster6_{lid}", mode="far", main=os.path.join(D, n + ".wav"), words=M[n]["words"],
                         rt60=2.2, wet_db=-6, direct_db=-3, direct_lp=4500, repeat_db=-9, repeat_gap=0.6))
json.dump(spec, open(os.path.join(D, "spec.json"), "w"), indent=1)
