"""Pick one take per (candidate, line): heard word for word, not a runaway, speaking rate inside the line's window;
then the most alive (largest f0 SD = the melody moves most), except the teacher impression (the slowest) .
usage: choose.py LINES.json TAKES_DIR MEASURE.json OUT.json"""
import os, sys, json
L = json.load(open(sys.argv[1])); D = sys.argv[2]; M = json.load(open(sys.argv[3]))
WIN = {"d1": (2.2, 4.3), "d2": (1.4, 3.3), "d3": (2.0, 4.6), "d4": (1.4, 3.6), "d5": (2.2, 4.6), "d6": (2.0, 4.6),
       "k1": (1.8, 3.9), "k2": (2.2, 4.3), "m1": (2.2, 4.9), "m2": (2.0, 4.3)}
groups = {}
for x in L:
    groups.setdefault((x["cand"], x["line"]), []).append(x)
picks = {}
for (c, l), xs in sorted(groups.items()):
    rows = []
    for x in xs:
        m = M.get(x["id"]); meta = json.load(open(os.path.join(D, x["id"] + ".json")))
        if not m:
            continue
        lo, hi = WIN[l]
        ok = m.get("wer", 1) == 0 and not meta.get("runaway") and lo <= m.get("wps", 0) <= hi
        rows.append((ok, x["id"], m))
    good = [r for r in rows if r[0]]
    why = "word for word, rate in window"
    if not good:
        good = [r for r in rows if r[2].get("wer", 1) == 0] ; why = "word for word, rate OUTSIDE window"
    if not good:
        good = rows; why = "NOT word for word"
    if l == "d2":
        best = min(good, key=lambda r: r[2]["wps"]); why += "; slowest"
    else:
        best = max(good, key=lambda r: r[2].get("f0_sd_st", 0)); why += "; liveliest melody"
    picks[f"{c}_{l}"] = dict(take=best[1], why=why, n_ok=sum(r[0] for r in rows), n=len(rows),
                             **{k: best[2].get(k) for k in ("asr", "wer", "wps", "f0_med", "f0_sd_st", "jitter_c", "aper_db", "dur")})
    print(c, l, best[1], why, picks[f"{c}_{l}"]["n_ok"], "/", len(rows), best[2].get("wps"), best[2].get("f0_sd_st"))
json.dump(picks, open(sys.argv[4], "w"), indent=1)
