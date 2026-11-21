"""Monster round 3: deeper, still a voice.  No vocoder, no time-stretch, no formant tool: plain resampling ("slowed
tape": pitch, throat and tempo drop together, exactly like a record played slow), mixing, filtering, delay, our LPC
whisper of the same take (round 2, Monster 4), our synthetic breath and a synthetic small room.
usage: monster3.py build OUTDIR      -> OUTDIR/<cand>.wav for every candidate + OUTDIR/items.json (for analyze.py --asr)
       monster3.py pick OUTDIR MEASURE.json FINISH_LIST.json
M7  slowed tape ST7 semitones + Monster 4's whisper layer (LPC whisper of the slowed take, -8 dB, 0.24 s late) + small room
M8  slowed tape ST8 semitones + an octave-below layer (each word resampled a further octave, started on its own word,
    low-passed, quiet) + a breath before (our synthetic inhale, slowed the same way) + a small dark room
M9  a naturally deep stock blend (Kokoro am_michael .6 + am_echo .4 -> Chatterbox full, calm) saying the line, with
    Danny 1's own calm take of the same words very quietly underneath, a beat late; the same small room as M4."""
import os, sys, json
from fractions import Fraction
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly, fftconvolve
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
sys.path.insert(0, os.path.join(V, "tools2")); sys.path.insert(0, os.path.join(V, "tools"))
from monster2 import ld, rms, active_rms, db, lp, hp, mix, lpc_whisper, room_ir, SR
from finish import trim

ST7 = 4.0
ST8 = 5.5
LINES = {"w": "Wait up, you guys.", "s": "Is it still on me?", "f": "You saw it first.", "c": "So cute.",
         "d": "It's me. It's Danny."}
M4_BASE = {"w": 1, "s": 2, "f": 1, "c": 1}          # the calm seed Monster 4 used (out2/mon/spec.json)
# the base take used for M7/M8 (and Danny's underlay in M9): Monster 4's own where it is still heard word for word
# after slowing; "c": M4's b1 slowed 4 st was heard "So come here." -> b2; "d" (new line): b3, heard in both, and the
# livelier of the two that pass (jitter 27.6 c vs 12.4 c for b2, which is also the most strictly periodic, -17.8 dB)
BASE_FOR = {"w": 1, "s": 2, "f": 1, "c": 2, "d": 3}
# per-version exception: M7 "s" from base 2 is heard word for word as WAV but "Is it still on ON me?" as the finished
# MP3 (the whisper double lands as a repeated word); base 3 passes as MP3 (out3/test7s, out3/mon3/measure.json t_m7_s_b3)
BASE_OVR = {("m7", "s"): 3}
MON = os.path.join(V, "out3", "mon"); DEEP = os.path.join(V, "out3", "deep")
BREATH = os.path.join(V, "out", "breath_synth.wav")
_asr = None

def tape(x, st):
    """play the take slower so it sounds st semitones lower: resample by 2^(st/12) and keep the sample rate."""
    f = Fraction(2 ** (st / 12)).limit_denominator(500)
    return resample_poly(x, f.numerator, f.denominator)

def base(path):
    return trim(ld(path).astype(np.float32), SR, 0.03, 0.3).astype(np.float64)

def words(x):
    """word start/end times (s) from the recogniser (faster-whisper small.en)."""
    global _asr
    if _asr is None:
        from faster_whisper import WhisperModel
        _asr = WhisperModel(os.path.join(V, "models", "whisper-small.en"), device="cpu", compute_type="int8", cpu_threads=2)
    y = resample_poly(x, 2, 3).astype(np.float32)
    segs, _ = _asr.transcribe(y, beam_size=5, language="en", condition_on_previous_text=False, word_timestamps=True)
    return [(w.word.strip(), w.start, w.end) for s in segs for w in (s.words or [])]

def small_room(y, rt60=0.7, dark=3000, corr=9, end=60, seed=3, wet_db=-16):
    ir = room_ir(rt60=rt60, dark=dark, corridor_ms=corr, end_ms=end, seed=seed)
    wet = fftconvolve(y, ir)[: len(y) + int(SR * 0.5)]
    wet *= rms(y) / rms(wet) * db(wet_db)
    return mix((y, 0), (wet, 0))

def m7(bpath, st=ST7):
    m = tape(base(bpath), st)
    w = hp(lpc_whisper(m), 300)
    w *= active_rms(m) / active_rms(w) * db(-8)
    y = mix((m, 0), (w, int(SR * 0.24)))
    return small_room(y)

def m8(bpath, st=ST8, oct_db=-12, oct_lp=320):
    m = tape(base(bpath), st)
    ws = words(m)
    sub = np.zeros(len(m) + SR)
    starts = [max(0, int(a * SR) - int(0.02 * SR)) for _, a, _ in ws]
    for i, (_, a, b) in enumerate(ws):
        a0 = starts[i]
        b0 = min(len(m), int((b + 0.05) * SR))
        if b0 - a0 < int(0.04 * SR):
            continue
        seg = m[a0:b0].copy()
        o = tape(seg, 12.0)                                   # the same word, a further octave down
        stop = (starts[i + 1] if i + 1 < len(ws) else len(m)) - a0 + int(0.12 * SR)
        o = o[:max(int(0.06 * SR), min(len(o), stop))]
        fo = min(len(o) // 3, int(0.08 * SR)); fi = int(0.01 * SR)
        o[:fi] *= np.linspace(0, 1, fi); o[-fo:] *= np.linspace(1, 0, fo)
        sub[a0:a0 + len(o)] += o
    sub = lp(sub[:len(m) + int(0.3 * SR)], oct_lp, 4)
    sub *= active_rms(m) / active_rms(sub) * db(oct_db)
    b = tape(trim(ld(BREATH).astype(np.float32), SR, 0.01, 0.05, floor_db=45).astype(np.float64), st)
    b *= active_rms(m) / active_rms(b) * db(-12)
    off = len(b) + int(SR * 0.22)
    y = mix((b, 0), (m, off), (sub, off))
    return small_room(y, rt60=0.45, dark=1500, corr=6, end=35, seed=21, wet_db=-13), ws

def m9(dpath, bpath, delay=0.09, dan_db=-14):
    d = base(dpath); k = base(bpath)
    k *= active_rms(d) / active_rms(k) * db(dan_db)
    y = mix((d, 0), (k, int(SR * delay)))
    return small_room(y)

def save(path, y):
    y = y / (np.abs(y).max() + 1e-9) * 0.7
    sf.write(path, y.astype(np.float32), SR, subtype="FLOAT")

def build(out, only=None):
    os.makedirs(out, exist_ok=True); items = []; meta = {}
    for lid, text in LINES.items():
        if only and lid not in only:
            continue
        for sd in (1, 2, 3):
            bp = os.path.join(MON, f"calm_{lid}_s{sd}.wav")
            if not os.path.exists(bp):
                continue
            n = f"m7_{lid}_b{sd}"; save(os.path.join(out, n + ".wav"), m7(bp)); items.append((n, text))
            n = f"m8_{lid}_b{sd}"; y, ws = m8(bp); save(os.path.join(out, n + ".wav"), y); items.append((n, text))
            meta[n] = {"octave_layer_words": ws}
        kb = M4_BASE.get(lid, 1)
        for ds in range(1, 8):
            dp = os.path.join(DEEP, f"deep_{lid}_s{ds}.wav")
            if not os.path.exists(dp):
                continue
            for b in (1, 2, 3):
                bp = os.path.join(MON, f"calm_{lid}_s{b}.wav")
                if os.path.exists(bp):
                    n = f"m9_{lid}_d{ds}_b{b}"; save(os.path.join(out, n + ".wav"), m9(dp, bp)); items.append((n, text))
        # the parts alone, for measuring (main layers without whisper/sub/room)
        for sd in (1, 2, 3):
            bp = os.path.join(MON, f"calm_{lid}_s{sd}.wav")
            if os.path.exists(bp):
                save(os.path.join(out, f"part_base_{lid}_b{sd}.wav"), base(bp)); items.append((f"part_base_{lid}_b{sd}", text))
                save(os.path.join(out, f"part_m7main_{lid}_b{sd}.wav"), tape(base(bp), ST7)); items.append((f"part_m7main_{lid}_b{sd}", text))
                save(os.path.join(out, f"part_m8main_{lid}_b{sd}.wav"), tape(base(bp), ST8)); items.append((f"part_m8main_{lid}_b{sd}", text))
        for sd in range(1, 8):
            dp = os.path.join(DEEP, f"deep_{lid}_s{sd}.wav")
            if os.path.exists(dp):
                save(os.path.join(out, f"part_deep_{lid}_d{sd}.wav"), base(dp)); items.append((f"part_deep_{lid}_d{sd}", text))
        print(lid, "built", flush=True)
    json.dump([dict(id=n, wav=os.path.join(out, n + ".wav"), text=t) for n, t in items], open(os.path.join(out, "items.json"), "w"), indent=1)
    mp = os.path.join(out, "build_meta.json")
    old = json.load(open(mp)) if (only and os.path.exists(mp)) else {}
    old.update(meta); json.dump(old, open(mp, "w"), indent=1)

def onsets(m):
    return [w[1] for w in m.get("words", [])]

def rhythm_cost(a, b):
    """mean |difference| of word onsets (s) after aligning the first word; a and b = measures with word times."""
    oa, ob = onsets(a), onsets(b)
    if not oa or not ob or len(oa) != len(ob):
        return 9.0
    return float(np.mean([abs((x - oa[0]) - (y - ob[0])) for x, y in zip(oa, ob)]))

def pick(out, measure, flist):
    M = json.load(open(measure)); picks = {}; fl = []
    ok = lambda n: n in M and M[n].get("wer", 1) == 0
    for lid in LINES:
        for ver in ("m7", "m8"):
            pref = [BASE_OVR.get((ver, lid), BASE_FOR[lid])]
            cands = [f"{ver}_{lid}_b{b}" for b in (1, 2, 3) if f"{ver}_{lid}_b{b}" in M]
            good = [c for c in cands if ok(c)]
            pr = [c for c in good if int(c[-1]) in pref]
            ch = pr[0] if pr else (max(good, key=lambda c: M[c]["logprob"]) if good else None)
            picks[f"{ver}_{lid}"] = dict(take=ch, why="the chosen base take (BASE_FOR)" if pr else
                                         ("clearest of the takes heard word for word" if good else "NONE heard word for word"),
                                         ok=[c for c in good])
        kb = BASE_FOR[lid]
        cands = [n for n in M if n.startswith(f"m9_{lid}_") and n.endswith(f"_b{kb}")]
        good = [c for c in cands if ok(c)]
        dpart = lambda c: M.get(f"part_deep_{lid}_d{c.split('_')[2][1:]}", {})
        bpart = M.get(f"part_base_{lid}_b{kb}", {})
        ch = min(good, key=lambda c: rhythm_cost(dpart(c), bpart)) if good else None
        if ch:   # the brief is "deeper": among takes within 80 ms of the best rhythm, the deepest (if >= 0.5 st lower)
            best = rhythm_cost(dpart(ch), bpart)
            near = [c for c in good if rhythm_cost(dpart(c), bpart) <= best + 0.08]
            low = min(near, key=lambda c: dpart(c).get("f0_med", 999))
            if 12 * np.log2(dpart(ch)["f0_med"] / dpart(low)["f0_med"]) >= 0.5:
                ch = low
        picks[f"m9_{lid}"] = dict(take=ch, why="heard word for word; deep take whose word rhythm is closest to Danny's"
                                  if good else "NONE heard word for word", ok=good,
                                  rhythm_cost={c: round(rhythm_cost(dpart(c), bpart), 3) for c in cands})
    for k, p in picks.items():
        ver, lid = k.split("_")
        if p["take"]:
            fl.append(dict(out=f"monster{ver[1]}_{lid}", src=os.path.join(out, p["take"] + ".wav"), lufs=-20.0, trim=False, wav=True))
        print(k, p["take"], p["why"], flush=True)
    json.dump(picks, open(os.path.join(out, "picks.json"), "w"), indent=1)
    json.dump(fl, open(flist, "w"), indent=1)

if __name__ == "__main__":
    if sys.argv[1] == "build":
        build(sys.argv[2], sys.argv[3].split(",") if len(sys.argv) > 3 else None)
    else:
        pick(sys.argv[2], sys.argv[3], sys.argv[4])
