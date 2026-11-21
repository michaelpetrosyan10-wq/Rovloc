"""Name takes rendered K at a time (the engine's fixed cost per call is ~16 s, a name is ~0.6 s of audio), time-boxed
(BATCH_SECONDS; exit 3 while groups remain), resumable.
usage: namebatch4.py MODELS LINES.json OUT_DIR [K]
One call says "Aaron. Abby. Adam. Aiden." (shape d) or "Aaron? Abby? Adam? Aiden?" (shape q) with the same voice and
settings as a single take (Chatterbox full, Danny 3 reference, exag 0.25, the line's seed); the take is cut in its
pauses into K files OUT_DIR/<id>.wav + .json, one per name, exactly like a single render's output. Nothing is shifted,
stretched or vocoded: cut only. A group whose take does not split into exactly K parts at clear pauses is written to
OUT_DIR/batch_unsplit.json and its names are rendered one by one (render2.py) instead."""
import os, sys, json, time
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
sys.path.insert(0, os.path.join(V, "tools2")); sys.path.insert(0, os.path.join(V, "tools"))
import numpy as np
from common import save, read_json, write_json
SR = 24000
def split(a, k, hole=12, mingap=12):
    hop = 240; m = len(a) // hop
    e = 20 * np.log10(np.sqrt((a[:m * hop].reshape(m, hop) ** 2).mean(axis=1)) + 1e-9)
    top = np.percentile(e, 98)
    for thr in (35, 32, 38, 29, 41):
        on = e > top - thr
        # close short holes (< 60 ms) inside words; drop blips (< 80 ms)
        segs, i = [], 0
        while i < m:
            if on[i]:
                j = i
                while j < m and on[j]: j += 1
                segs.append([i, j]); i = j
            else: i += 1
        merged = []
        for s in segs:
            if merged and s[0] - merged[-1][1] < hole: merged[-1][1] = s[1]     # gap < 120 ms: same word
            else: merged.append(s)
        merged = [s for s in merged if s[1] - s[0] >= 8]
        if len(merged) == k:
            gaps = [merged[i + 1][0] - merged[i][1] for i in range(k - 1)]
            if min(gaps) >= mingap:
                cuts = []
                for i, (s0, s1) in enumerate(merged):
                    lo = 0 if i == 0 else (merged[i - 1][1] + s0) // 2
                    hi = m if i == k - 1 else (s1 + merged[i + 1][0]) // 2
                    a0 = max(lo, s0 - 10); a1 = min(hi, s1 + 15)
                    cuts.append((a0 * hop, a1 * hop))
                return cuts, thr, gaps
    return None, None, None
def main():
    models, lines, out = sys.argv[1], read_json(sys.argv[2]), sys.argv[3]
    k = int(sys.argv[4]) if len(sys.argv) > 4 else 4
    budget = float(os.environ.get("BATCH_SECONDS", "100")); t0 = time.time()
    os.makedirs(out, exist_ok=True)
    unp = os.path.join(out, "batch_unsplit.json"); unsplit = read_json(unp) if os.path.exists(unp) else []
    bad = {i for g in unsplit for i in g["ids"]}
    todo = [x for x in lines if not os.path.exists(os.path.join(out, x["id"] + ".json")) and x["id"] not in bad]
    groups = {}
    for x in todo: groups.setdefault((x["shape"], x["seed"], x["recipe"]["ref"], x["recipe"]["exag"]), []).append(x)
    G = [g[i:i + k] for g in groups.values() for i in range(0, len(g), k)]
    eng = None; left = 0
    for grp in G:
        if time.time() - t0 > budget: left += 1; continue
        if eng is None:
            from cbfull_engine import CBFullEngine; eng = CBFullEngine(os.path.join(models, "cbfull"))
        sep = "? " if grp[0]["shape"] == "q" else ". "
        text = sep.join(x["name"] for x in grp) + sep.strip()
        rec = dict(grp[0]["recipe"]); rec["max_tokens"] = int(25 * (1.5 + 1.1 * len(grp)))
        t = time.time(); a, sr = eng.render(text, rec, seed=grp[0]["seed"]); dt = time.time() - t
        cuts, thr, gaps = split(a, len(grp)) if not eng.last_runaway else (None, None, None)
        if not cuts and not eng.last_runaway:      # second tier: pauses of 60 ms and more (the recogniser gates each cut)
            cuts, thr, gaps = split(a, len(grp), hole=6, mingap=6)
        if not cuts:
            raw = os.path.join(out, "unsplit_" + grp[0]["id"] + ".wav"); save(raw, a, sr)
            unsplit.append(dict(ids=[x["id"] for x in grp], text=text, dur=round(len(a) / sr, 2), runaway=eng.last_runaway, raw=raw))
            write_json(unp, unsplit); print("UNSPLIT", text, round(len(a) / sr, 2), flush=True); continue
        for x, (c0, c1) in zip(grp, cuts):
            save(os.path.join(out, x["id"] + ".wav"), a[c0:c1], sr)
            write_json(os.path.join(out, x["id"] + ".json"), dict(x, batch_text=text, batch_cut=[round(c0 / sr, 3), round(c1 / sr, 3)],
                       batch_thr_db=thr, batch_gaps_s=[g / 100 for g in gaps], secs=round(dt / len(grp), 2),
                       dur=round((c1 - c0) / sr, 2), runaway=False))
        print(f"{text}: {len(a)/sr:.2f}s in {dt:.1f}s gaps {gaps}", flush=True)
    print(f"left {left}", flush=True)
    sys.exit(3 if left else 0)
if __name__ == "__main__":
    main()
