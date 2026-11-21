"""The kids' opening lines (Danny 3, Kayla 3, Marcus 2): pick one take per line and finish it (trim + level ONLY).
usage: kids4.py items LINES.json TAKES_DIR                 -> TAKES_DIR/items.json (for tools2/analyze.py --asr)
       kids4.py pick LINES.json TAKES_DIR MEASURE.json OUTDIR
Rule (round 3): heard word for word by the recogniser (strict: interjections such as "ha" and "whoa" must be heard
too; spelling-only differences such as 12/twelve, Mr./mister, woah/whoa are allowed), not a runaway, inside the line's
slot (opening-v3.md 6: the finished file's length <= slot), then the liveliest melody (largest f0 SD).
Exceptions the script asks for: L4 (the teacher impression: slower and lower) takes the slowest (fewest words per
second), then the lower pitch; L11 takes the highest pitch on "that". L4 is also gated by the recogniser hearing
"Reyes" (the model is given "mister ray-ess").
Finish: trim (20 ms before the first sound, 80 ms after the last, 5/30 ms fades), gain to -20 LUFS integrated (peak
held at or under -1.5 dBFS), 24 kHz mono 16-bit WAV + MP3 (VBR q4)."""
import os, sys, json
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
sys.path.insert(0, H)
import numpy as np
import soundfile as sf
from common4 import norm4, wer, write_pair, SR
from finish import trim
from finish2 import level
sys.path.insert(0, os.path.join(V, "tools4")); from plan4 import VOICE
LEAD, TRAIL, LUFS = 0.02, 0.08, -20.0
REFDESC = {
 "danny2": "out2/refs/danny2_g2.wav (Danny 3) = Chatterbox-full re-speaking (exag 0.65, seed 1) of Kokoro am_puck 0.6 + am_eric 0.4 (speed 1.1)",
 "teach2": "out4/refs/teach2_g2.wav (Danny 3's teacher impression) = Chatterbox-full re-speaking (exag 0.65, seed 1) of Kokoro am_puck 0.4 + am_eric 0.35 + am_adam 0.25 (speed 0.82)",
 "kayla2": "out2/refs/kayla2_g2.wav (Kayla 3) = Chatterbox-full re-speaking (exag 0.65, seed 1) of Kokoro af_kore 0.5 + af_jessica 0.5 (speed 1.0)",
 "marcus1": "out2/refs/marcus1_g2.wav (Marcus 2) = Chatterbox-full re-speaking (exag 0.65, seed 1) of Kokoro am_fenrir 0.6 + am_echo 0.4 (speed 1.08)",
}
REFFILE = {"danny2": "out2/refs/danny2_g2.wav", "teach2": "out4/refs/teach2_g2.wav", "kayla2": "out2/refs/kayla2_g2.wav",
           "marcus1": "out2/refs/marcus1_g2.wav"}
def cut(path):
    x, sr = sf.read(path, dtype="float32", always_2d=True); x = x.mean(axis=1)
    return trim(x, sr, LEAD, TRAIL), sr
def items(lines, d):
    L = json.load(open(lines))
    out = [dict(id=x["id"], wav=os.path.join(d, x["id"] + ".wav"), text=x.get("plain", x["text"])) for x in L
           if os.path.exists(os.path.join(d, x["id"] + ".json"))]
    json.dump(out, open(os.path.join(d, "items.json"), "w"), indent=1); print(len(out), "items")
def word_f0(path, words, target):
    import pyworld as pw
    x, sr = sf.read(path, dtype="float64", always_2d=True); x = x.mean(axis=1)
    f0, t = pw.harvest(x, sr, frame_period=5.0, f0_floor=60, f0_ceil=700)
    for w, a, b in words:
        if norm4(w) == [target]:
            v = f0[(t >= a) & (t <= b) & (f0 > 0)]
            return round(float(np.percentile(v, 90)), 1) if len(v) else 0.0
    return 0.0
def pick(lines, d, measure, out):
    L = json.load(open(lines)); M = json.load(open(measure)); os.makedirs(out, exist_ok=True)
    by = {}
    for x in L: by.setdefault(x["L"], []).append(x)
    man, problems = [], []
    for n in sorted(by):
        rows = []
        for x in by[n]:
            m = M.get(x["id"]); jp = os.path.join(d, x["id"] + ".json")
            if not m or not os.path.exists(jp): continue
            meta = json.load(open(jp))
            y, sr = cut(os.path.join(d, x["id"] + ".wav")); secs = round(len(y) / sr, 2)
            heard_txt = m.get("asr") or ""
            heard = norm4(x["plain"]) == norm4(heard_txt)
            r = dict(x=x, m=m, meta=meta, secs=secs, heard=heard, fits=secs <= x["slot"], wps=round(len(norm4(x["plain"])) / secs, 2))
            if n == 11: r["f0_that"] = word_f0(os.path.join(d, x["id"] + ".wav"), m.get("words", []), "that")
            r["ok"] = r["heard"] and r["fits"] and not meta.get("runaway")
            rows.append(r)
        good = [r for r in rows if r["ok"]]; why = "heard word for word, inside the slot"
        if not good:
            good = [r for r in rows if r["heard"]]; why = "heard word for word but OVER THE SLOT"
        if not good:
            good = rows; why = "NOT heard word for word"
        if n == 4:
            best = min(good, key=lambda r: (r["wps"], r["m"].get("f0_med", 999))); why += "; slowest (teacher impression), then lower"
        elif n == 11:
            best = max(good, key=lambda r: r.get("f0_that", 0)); why += "; highest pitch on 'that' (script)"
        else:
            best = max(good, key=lambda r: r["m"].get("f0_sd_st", 0)); why += "; liveliest melody (largest f0 SD)"
        x, m = best["x"], best["m"]
        y, sr = cut(os.path.join(d, x["id"] + ".wav"))
        y2, lu, pk = level(y, sr, LUFS)
        base = x["line_id"]
        write_pair(os.path.join(out, base), y2, sr)
        nw = len(norm4(x["plain"]))
        spk = x["speaker"]
        rec = dict(id=base, L=n, speaker=spk.upper() + (" (as Mr. Kessler)" if n == 4 else ""), text=x["plain"],
                   model_text=x["text"], file="kids/" + base + ".wav", mp3="kids/" + base + ".mp3",
                   seconds=round(len(y2) / sr, 2), slot=x["slot"], fits_slot=best["fits"], words=nw,
                   words_per_second=round(nw / (len(y2) / sr), 2), recogniser=m.get("asr"), word_for_word=best["heard"],
                   recogniser_logprob=m.get("logprob"), voice=VOICE[spk] + (" (teacher impression)" if n == 4 else ""),
                   reference_voice=REFDESC[x["ref_id"]], ref_file=REFFILE[x["ref_id"]],
                   settings=dict(engine="Chatterbox full 0.5B (onnx-community export, q4 language model)", seed=x["seed"],
                                 exaggeration=x["recipe"]["exag"], temperature=0.8, min_p=0.05, repetition_penalty=1.2),
                   take=x["id"], why=why, takes_ok=f"{len([r for r in rows if r['ok']])}/{len(rows)}",
                   takes=[dict(take=r["x"]["id"], seconds=r["secs"], heard=r["m"].get("asr"), word_for_word=r["heard"],
                               fits=r["fits"], f0_sd_st=r["m"].get("f0_sd_st"), wps=r["wps"], **({"f0_that": r["f0_that"]} if "f0_that" in r else {}))
                          for r in rows],
                   f0_med=m.get("f0_med"), f0_sd_st=m.get("f0_sd_st"), lufs=lu, peak_db=pk, sample_rate=sr,
                   processing="trim (20 ms lead, 80 ms tail, 5/30 ms fades) + gain only", raw_words=m.get("words"))
        man.append(rec)
        if not (best["heard"] and best["fits"]): problems.append(f"L{n} {base}: {why}")
        print(f"L{n:02d} {base:22s} {rec['take']:18s} {rec['seconds']:.2f}/{x['slot']} heard={m.get('asr')!r} {rec['takes_ok']} {why}", flush=True)
    json.dump(dict(lines=man, problems=problems), open(os.path.join(out, "kids_pick.json"), "w"), indent=1)
    print("problems:", problems)
def nvpick(lines, d, measure, out):
    """non-verbal takes: not a runaway, the finished length closest to the script's length; level -24 LUFS (the
    script puts these 3 to 6 dB under the speaker's lines at -20). They are the engine SAYING the syllables."""
    from plan4 import NV
    L = json.load(open(lines)); M = json.load(open(measure)); os.makedirs(out, exist_ok=True); rec = []
    for nid, spk, text, target, where in NV:
        rows = []
        for x in [x for x in L if x["nv"] == nid]:
            jp = os.path.join(d, x["id"] + ".json")
            if not os.path.exists(jp): continue
            meta = json.load(open(jp)); y, sr = cut(os.path.join(d, x["id"] + ".wav"))
            rows.append(dict(x=x, meta=meta, secs=round(len(y) / sr, 2), m=M.get(x["id"], {})))
        rows = [r for r in rows if not r["meta"].get("runaway")] or rows
        if not rows: continue
        b = min(rows, key=lambda r: abs(r["secs"] - target)); x = b["x"]
        y, sr = cut(os.path.join(d, x["id"] + ".wav")); y2, lu, pk = level(y, sr, -24.0)
        write_pair(os.path.join(out, nid), y2, sr)
        rec.append(dict(id=nid, speaker=spk, what=where, model_text=text, target=target, file="kids/" + nid + ".wav",
                        mp3="kids/" + nid + ".mp3", seconds=round(len(y2) / sr, 2), lufs=lu, peak_db=pk, voice=VOICE[spk],
                        settings=dict(engine="Chatterbox full 0.5B", reference=REFDESC[x["ref_id"]], exaggeration=x["recipe"]["exag"],
                                      seed=x["seed"], take=x["id"]),
                        takes=[dict(take=r["x"]["id"], seconds=r["secs"], heard=r["m"].get("asr"), voiced=r["m"].get("voiced"),
                                    f0_range_st=r["m"].get("f0_range_st")) for r in rows],
                        flag="the engine SAYS the syllables (no laugh or breath sound of its own): ear check before use"))
        print(nid, x["id"], b["secs"], "target", target, repr(b["m"].get("asr")), flush=True)
    json.dump(rec, open(os.path.join(out, "nv_pick.json"), "w"), indent=1)
if __name__ == "__main__":
    if sys.argv[1] == "items": items(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "nvpick": nvpick(*sys.argv[2:6])
    else: pick(*sys.argv[2:6])
