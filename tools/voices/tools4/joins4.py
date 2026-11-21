"""Measure the name-bank joins: every name in the bank x every named line, joined end to start with no overlap
(the engine plays file B the sample after file A ends).
usage: joins4.py measure PROD2_DIR OUT.json            all joins, WAV; plus decoded-MP3 joins for a sample of names
       joins4.py samples PROD2_DIR OUTDIR N            write N names x 2 lines (one name-first, one name-last) as WAVs
                                                       + items.json for the recogniser
Per join: the pause between the last word of A and the first of B (s); the room tone's level and tone (spectral
centroid) in the last 40 ms of A and the first 40 ms of B; the quietest 10 ms frame between the words (dBFS; digital
silence would be below -90); the words' active level in A and in B (dB); the largest sample step at the join against
the room tone's own largest step."""
import os, sys, json, subprocess
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
sys.path.insert(0, H)
import numpy as np
from common4 import SR, ld, frame_db, active_rms, jload, jsave
import plan4
def pairs():
    P = []
    for nid, g, named, twin, rest, pos in plan4.NAMED:
        P.append((nid, named, f"Mon.{nid}.Rest", pos))
    for kid, cat, named, plain, rest, pos in plan4.KEPT:
        if rest: P.append((kid, named, f"Mon.{kid}.Rest", pos))
    return P
SHAPE = {"first": "First", "last": "Last", "lastq": "LastQ", "alone_after": "Alone"}
def order(pos, name_id, rest_id):
    return (name_id, rest_id) if pos == "first" else (rest_id, name_id)
def centroid(x):
    X = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2; f = np.fft.rfftfreq(len(x), 1 / SR)
    return float((X * f).sum() / (X.sum() + 1e-20))
def one(a, am, b, bm):
    n = int(0.04 * SR)
    ta, hb = a[-n:], b[:n]
    j = np.concatenate([a, b])
    lo, hi = int(am["speech_end"] * SR), len(a) + int(bm.get("breath_start", bm["speech_start"]) * SR)
    seg = j[lo:hi]
    step = abs(float(b[0] - a[-1])); bedstep = float(np.max(np.abs(np.diff(ta))))
    sa = a[int(am["speech_start"] * SR):int(am["speech_end"] * SR)]; sb = b[int(bm["speech_start"] * SR):int(bm["speech_end"] * SR)]
    return dict(pause_s=round(am["seconds"] - am["speech_end"] + bm["speech_start"], 3),
                pause_to_breath_s=round(am["seconds"] - am["speech_end"] + bm.get("breath_start", bm["speech_start"]), 3),
                tone_db_a=round(float(20 * np.log10(np.sqrt(np.mean(ta ** 2)))), 2), tone_db_b=round(float(20 * np.log10(np.sqrt(np.mean(hb ** 2)))), 2),
                centroid_a=round(centroid(ta)), centroid_b=round(centroid(hb)),
                min_frame_db=round(float(frame_db(seg).min()), 1) if len(seg) > 480 else None,
                words_db_a=round(float(20 * np.log10(active_rms(sa))), 2), words_db_b=round(float(20 * np.log10(active_rms(sb))), 2),
                join_step=round(step, 5), bed_max_step=round(bedstep, 5))
def dec(p):
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", p, "-f", "f32le", "-ac", "1", "-ar", str(SR), "pipe:1"], capture_output=True, check=True)
    return np.frombuffer(r.stdout, dtype=np.float32).astype(np.float64)
def measure(pd, out):
    bank = jload(os.path.join(pd, "names", "bank.json")); mon = {r["id"]: r for r in jload(os.path.join(pd, "monster", "mon_final.json")) if r["made"]}
    W = {}
    def get(fid, sub):
        if fid not in W: W[fid] = ld(os.path.join(pd, sub, fid + ".wav"))
        return W[fid]
    rows = []; mp3rows = []
    names = [n for n, r in bank.items() if r["in_bank"]]
    for k, (lid, named, rest, pos) in enumerate(pairs()):
        if rest not in mon: continue
        for i, nm in enumerate(names):
            f = bank[nm]["files"][SHAPE[pos]]; nf = f["id"]
            A, B = order(pos, nf, rest)
            ma = f if A == nf else mon[rest]; mb = f if B == nf else mon[rest]
            a = get(A, "names" if A == nf else "monster"); b = get(B, "names" if B == nf else "monster")
            r = one(a, ma, b, mb); r.update(line=lid, name=nm, a=A, b=B); rows.append(r)
            if i % 25 == 0:
                da = dec(os.path.join(pd, "names" if A == nf else "monster", A + ".mp3"))
                db_ = dec(os.path.join(pd, "names" if B == nf else "monster", B + ".mp3"))
                rm = one(da, ma, db_, mb)
                rm.update(line=lid, name=nm, a=A, b=B, mp3_len_a=len(da), wav_len_a=len(a), mp3_len_b=len(db_), wav_len_b=len(b))
                mp3rows.append(rm)
    def summ(R):
        if not R: return {}
        g = lambda k: np.array([r[k] for r in R if r[k] is not None], dtype=float)
        tone = g("tone_db_b") - g("tone_db_a"); cen = g("centroid_b") - g("centroid_a"); wd = g("words_db_b") - g("words_db_a")
        return dict(joins=len(R), pause_s=[round(float(g("pause_s").min()), 3), round(float(np.median(g("pause_s"))), 3), round(float(g("pause_s").max()), 3)],
                    tone_step_db=dict(median=round(float(np.median(tone)), 2), p95_abs=round(float(np.percentile(np.abs(tone), 95)), 2), max_abs=round(float(np.abs(tone).max()), 2)),
                    tone_db=round(float(np.median(g("tone_db_a"))), 2),
                    centroid_step_hz=dict(median=round(float(np.median(cen))), p95_abs=round(float(np.percentile(np.abs(cen), 95)))),
                    min_frame_db_between_words=round(float(g("min_frame_db").min()), 1),
                    words_level_step_db=dict(median=round(float(np.median(wd)), 2), p95_abs=round(float(np.percentile(np.abs(wd), 95)), 2), max_abs=round(float(np.abs(wd).max()), 2)),
                    join_step_over_bed_step=dict(median=round(float(np.median(g("join_step") / g("bed_max_step"))), 2), max=round(float((g("join_step") / g("bed_max_step")).max()), 2)))
    S = dict(wav=summ(rows), mp3=summ(mp3rows),
             mp3_length_minus_wav_samples=sorted({r["mp3_len_a"] - r["wav_len_a"] for r in mp3rows} | {r["mp3_len_b"] - r["wav_len_b"] for r in mp3rows}),
             by_line={lid: summ([r for r in rows if r["line"] == lid]) for lid, *_ in pairs()})
    jsave(out, dict(summary=S, rows=rows, mp3_rows=mp3rows)); print(json.dumps(S["wav"], indent=1)); print(json.dumps(S["mp3"], indent=1)); print(S["mp3_length_minus_wav_samples"])
def samples(pd, od, n):
    import soundfile as sf
    bank = jload(os.path.join(pd, "names", "bank.json")); mon = {r["id"]: r for r in jload(os.path.join(pd, "monster", "mon_final.json")) if r["made"]}
    names = [k for k, r in bank.items() if r["in_bank"]]
    step = max(1, len(names) // int(n)); pick = names[::step][:int(n)]
    P = pairs(); its = []; os.makedirs(od, exist_ok=True)
    for i, nm in enumerate(pick):
        firsts = [p for p in P if p[3] == "first"]; lasts = [p for p in P if p[3] != "first"]
        for lid, named, rest, pos in (firsts[i % len(firsts)], lasts[i % len(lasts)]):
            f = bank[nm]["files"][SHAPE[pos]]["id"]; A, B = order(pos, f, rest)
            a = ld(os.path.join(pd, "names" if A == f else "monster", A + ".wav")); b = ld(os.path.join(pd, "names" if B == f else "monster", B + ".wav"))
            o = os.path.join(od, f"Join.{nm}.{lid}.wav"); sf.write(o, np.concatenate([a, b]).astype(np.float32), SR, subtype="PCM_16")
            its.append(dict(id=f"Join.{nm}.{lid}", wav=o, text=named.replace("{name}", nm)))
    jsave(os.path.join(od, "items.json"), its); print(len(its), "joined samples")
if __name__ == "__main__":
    a = sys.argv
    if a[1] == "measure": measure(a[2], a[3])
    else: samples(a[2], a[3], a[4])
