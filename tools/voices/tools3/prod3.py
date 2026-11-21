"""Opening lines for production: pick one take per line and finish it (trim + level ONLY).
usage: prod3.py items LINES.json TAKES_DIR            -> TAKES_DIR/items.json (for analyze.py --asr)
       prod3.py pick LINES.json TAKES_DIR MEASURE.json OUTDIR
Rule (round 2): heard word for word by the recogniser, not a runaway, inside the line's slot from opening-v3.md
(the trimmed file's length <= slot), then the liveliest melody (largest f0 SD); the teacher impression (L4) takes the
slowest instead, as in round 2. Finish: tight trim (20 ms before the first sound, 80 ms after the last), gain to
-20 LUFS integrated (peak held at or under -1.5 dBFS), 24 kHz mono 16-bit WAV + MP3 (VBR q4)."""
import os, sys, json
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
sys.path.insert(0, os.path.join(V, "tools2")); sys.path.insert(0, os.path.join(V, "tools"))
import numpy as np
import soundfile as sf
from finish import trim
from finish2 import level, mp3
from measure import norm, wer

LEAD, TRAIL, LUFS = 0.02, 0.08, -20.0
REFDESC = {  # out2/refs: gen-1 Kokoro blend (built-in voices only) -> gen-2 re-spoken by Chatterbox full (exag 0.65, seed 1)
 "danny1": "danny1_g2.wav = Chatterbox-full re-speaking of Kokoro am_eric 0.5 + am_liam 0.5 (speed 1.1)",
 "teach1": "teach1_g2.wav (Danny's teacher impression, slower) = Chatterbox-full re-speaking of Kokoro am_eric 0.35 + am_liam 0.35 + am_adam 0.3 (speed 0.82)",
 "kayla1": "kayla1_g2.wav = Chatterbox-full re-speaking of Kokoro af_river 0.6 + af_jessica 0.4 (speed 1.0)",
 "marcus1": "marcus1_g2.wav = Chatterbox-full re-speaking of Kokoro am_fenrir 0.6 + am_echo 0.4 (speed 1.08)",
}

def cut(path):
    x, sr = sf.read(path, dtype="float32", always_2d=True); x = x.mean(axis=1)
    return trim(x, sr, LEAD, TRAIL), sr

def items(lines, d):
    L = json.load(open(lines))
    out = [dict(id=x["id"], wav=os.path.join(d, x["id"] + ".wav"), text=x["plain"]) for x in L
           if os.path.exists(os.path.join(d, x["id"] + ".wav"))]
    json.dump(out, open(os.path.join(d, "items.json"), "w"), indent=1); print(len(out), "items")

def pick(lines, d, measure, out):
    L = json.load(open(lines)); M = json.load(open(measure)); os.makedirs(out, exist_ok=True)
    by = {}
    for x in L:
        by.setdefault(x["L"], []).append(x)
    man = []; problems = []
    for n in sorted(by):
        rows = []
        for x in by[n]:
            m = M.get(x["id"]); jp = os.path.join(d, x["id"] + ".json")
            if not m or not os.path.exists(jp):
                continue
            meta = json.load(open(jp))
            y, sr = cut(os.path.join(d, x["id"] + ".wav"))
            secs = round(len(y) / sr, 2)
            # recompute the word check from the recogniser's text (the normaliser may have gained aliases since)
            m["wer"] = round(wer(norm(x["plain"]), norm((m.get("asr") or "").replace("%", " percent"))), 3)
            heard = bool(m["wer"] == 0)
            fits = bool(secs <= x["slot"])
            rows.append(dict(x=x, m=m, meta=meta, secs=secs, heard=heard, fits=fits,
                             ok=heard and fits and not meta.get("runaway")))
        good = [r for r in rows if r["ok"]]; why = "heard word for word, inside the slot"
        if not good:
            good = [r for r in rows if r["heard"]]; why = "heard word for word but OVER THE SLOT"
        if not good:
            good = rows; why = "NOT heard word for word"
        if n == 4:
            best = min(good, key=lambda r: r["m"].get("wps", 9)); why += "; slowest (teacher impression, round-2 rule)"
        else:
            best = max(good, key=lambda r: r["m"].get("f0_sd_st", 0)); why += "; liveliest melody (largest f0 SD)"
        x, m = best["x"], best["m"]
        y, sr = cut(os.path.join(d, x["id"] + ".wav"))
        y2, lu, pk = level(y, sr, LUFS)
        base = x["line_id"]
        sf.write(os.path.join(out, base + ".wav"), y2, sr, subtype="PCM_16")
        mp3(os.path.join(out, base + ".mp3"), y2, sr)
        nw = len([w for w in x["plain"].replace("-", " ").split() if w.strip(".,!?:")])
        rec = dict(L=n, id=base, speaker=x["speaker"].upper() + (" (as Mr. Kessler)" if n == 4 else ""),
                   text=x["plain"], model_text=x["text"], file=base + ".wav", mp3=base + ".mp3",
                   seconds=round(len(y2) / sr, 2), slot=x["slot"], fits_slot=best["fits"],
                   words=nw, words_per_second=round(nw / (len(y2) / sr), 2),
                   recogniser=m.get("asr"), word_for_word=best["heard"], recogniser_logprob=m.get("logprob"),
                   reference_voice=REFDESC[x["ref_id"]], ref_file="out2/refs/" + x["ref_id"] + "_g2.wav",
                   settings=dict(engine="Chatterbox Turbo (onnx, q4 language model)", seed=x["seed"],
                                 **{k: v for k, v in x["recipe"].items() if k != "ref"}),
                   take=x["id"], why=why, takes_ok=f"{len([r for r in rows if r['ok']])}/{len(rows)}",
                   takes=[dict(take=r["x"]["id"], seconds=r["secs"], heard=r["m"].get("asr"), word_for_word=r["heard"],
                               fits=r["fits"], f0_sd_st=r["m"].get("f0_sd_st")) for r in rows],
                   f0_med=m.get("f0_med"), f0_sd_st=m.get("f0_sd_st"), jitter_c=m.get("jitter_c"),
                   lufs=lu, peak_db=pk, sample_rate=sr, processing="trim (20 ms lead, 80 ms tail, 5/30 ms fades) + gain only")
        man.append(rec)
        if not (best["heard"] and best["fits"]):
            problems.append(f"L{n} {base}: {why}")
        print(f"L{n:02d} {base:22s} {rec['take']:8s} {rec['seconds']:.2f}/{x['slot']} heard={m.get('asr')!r} {rec['takes_ok']} {why}", flush=True)
    json.dump(dict(made="2026-11-17, voices round 3", rule=__doc__.split("\n")[3:6], lines=man, problems=problems),
              open(os.path.join(out, "manifest.json"), "w"), indent=1)
    print("problems:", problems)

if __name__ == "__main__":
    if sys.argv[1] == "items":
        items(sys.argv[2], sys.argv[3])
    else:
        pick(*sys.argv[2:6])
