"""Measure rendered lines: Whisper transcript vs text (WER), median F0 and range, speaking rate, loudness, peak, silences.

usage: measure.py WHISPER_DIR OUT.json ITEMS.json        ITEMS: [{"id":..., "wav":..., "text":..., "kind"?}, ...]
Each result is cached by (wav path, mtime) so a re-run only measures changed files.
Rates: wps = words / energy speech span (first to last frame within 40 dB of the loudest); wps_eff = the same with
the non-word sound (a [laugh]) taken out of the span; wps_words = words / recogniser word span (first word start to
last word end, the reviewer's measure); wps_words_np = the same with every gap over 0.3 s between words taken out.
"""
import os, sys, re, json, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from common import load, read_json, write_json, THREADS

# spellings Whisper may legitimately choose for the same spoken word (compared after normalisation)
ALIASES = {
    "kesslers": "kessler's", "kesler's": "kessler's", "keslers": "kessler's",
    "ollie": "olly", "oly": "olly", "aw": "aww", "awww": "aww", "ah": "aww", "ohh": "oh",
    "booo": "boo", "boooo": "boo", "ha": "", "haha": "", "hahaha": "", "heh": "", "hehe": "",
    "uhh": "", "mmm": "", "ahh": "", "aah": "", "oh": "", "ooh": "", "sophia": "sofia", "40": "forty", "fourty": "forty", "50": "fifty", "12": "twelve", "4": "four",
    "okay": "ok", "o.k.": "ok", "gonna": "going to", "wanna": "want to", "gotta": "got to",
    "hmph": "", "heh": "", "hah": "", "phew": "", "whoa": "", "woah": "", "ugh": "", "uh": "", "um": "", "hmm": "", "mm": "", "huh": "",
    "mr": "mister", "mr.": "mister", "ugh": "", "argh": "", "ow": "", "oof": "",
}
FILLERS = {""}


def norm(text):
    t = text.lower()
    t = re.sub(r"\[[^\]]*\]", " ", t)            # engine tags like [laugh]
    t = t.replace("’", "'").replace("—", " ").replace("-", " ")
    t = re.sub(r"[^a-z0-9' ]", " ", t)
    t = re.sub(r"\block down\b", "lockdown", t)
    out = []
    for w in t.split():
        w = w.strip("'")
        w = ALIASES.get(w, w)
        w = w.replace("'", "")       # building's = buildings, I've = ive: spelling, not speech
        out.extend(x for x in w.split() if x)
    return out


def wer(ref, hyp):
    r, h = ref, hyp
    d = np.zeros((len(r) + 1, len(h) + 1), dtype=int)
    d[:, 0] = range(len(r) + 1)
    d[0, :] = range(len(h) + 1)
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            d[i, j] = min(d[i - 1, j] + 1, d[i, j - 1] + 1, d[i - 1, j - 1] + (r[i - 1] != h[j - 1]))
    return d[len(r), len(h)] / max(1, len(r))


def syllables(word):
    w = re.sub(r"[^a-z]", "", word.lower())
    if not w:
        return 0
    n = len(re.findall(r"[aeiouy]+", w))
    if w.endswith("e") and not w.endswith(("le", "ee")) and n > 1:
        n -= 1
    return max(1, n)


def frame_db(x, sr, hop=0.01):
    n = int(sr * hop)
    m = len(x) // n
    if m == 0:
        return np.array([-120.0])
    f = x[: m * n].reshape(m, n)
    return 20 * np.log10(np.sqrt((f ** 2).mean(axis=1)) + 1e-9)


def silences(x, sr):
    db = frame_db(x, sr)
    thr = max(db.max() - 40, -60)
    on = np.where(db > thr)[0]
    if len(on) == 0:
        return len(x) / sr, 0.0, 0.0
    lead = on[0] * 0.01
    trail = len(x) / sr - (on[-1] + 1) * 0.01
    return lead, max(0.0, trail), (on[-1] + 1 - on[0]) * 0.01


def pitch(x, sr):
    import pyworld as pw
    xd = x.astype(np.float64)
    f0, t = pw.dio(xd, sr, f0_floor=55, f0_ceil=500, frame_period=10)
    f0 = pw.stonemask(xd, f0, t, sr)
    v = f0[f0 > 0]
    if len(v) < 5:
        return None, None, None, 0.0
    med = float(np.median(v))
    p10, p90 = np.percentile(v, [10, 90])
    return med, float(p10), float(p90), float(len(v) / len(f0))


def loudness(x, sr):
    import pyloudnorm as pyln
    m = pyln.Meter(sr)
    try:
        integ = float(m.integrated_loudness(x.astype(np.float64))) if len(x) > 0.45 * sr else None
    except Exception:
        integ = None
    # loudest 400 ms block (SOUND.md's one-shot measure), 100 ms hop
    w, h = int(0.4 * sr), int(0.1 * sr)
    best = -120.0
    if len(x) >= w:
        for s in range(0, len(x) - w + 1, h):
            try:
                v = m.integrated_loudness(x[s:s + w].astype(np.float64))
                if np.isfinite(v):
                    best = max(best, v)
            except Exception:
                pass
    peak = float(20 * np.log10(np.abs(x).max() + 1e-9))
    from scipy.signal import resample_poly
    tp = float(20 * np.log10(np.abs(resample_poly(x, 4, 1)).max() + 1e-9))
    if integ is not None and not np.isfinite(integ):
        integ = None
    return integ, best, peak, tp


_model = None


def whisper(path):
    global _model
    if _model is None:
        from faster_whisper import WhisperModel
        _model = WhisperModel(sys.argv[1], device="cpu", compute_type="int8", cpu_threads=THREADS, num_workers=1)
    a16, _ = load(path, 16000)   # decode ourselves (PyAV 19 rejects faster-whisper's open() flags)
    segs, info = _model.transcribe(a16, language="en", beam_size=5, temperature=0.0, condition_on_previous_text=False,
                                   word_timestamps=True, vad_filter=False, without_timestamps=False)
    words, text = [], []
    for s in segs:
        text.append(s.text)
        for w in (s.words or []):
            words.append({"w": w.word.strip(), "s": round(w.start, 3), "e": round(w.end, 3), "p": round(w.probability, 3)})
    return " ".join(t.strip() for t in text).strip(), words


def derived(r):
    """rate fields computed from cached values (so old cache entries get them too)."""
    nw = len(norm(r["text"]))
    w = r.get("words") or []
    sp = r.get("speech") or 0
    r["wps_eff"] = round(nw / max(0.3, sp - r.get("nonword_s", 0)), 2) if sp else None
    if len(w) >= 1:
        span = w[-1]["e"] - w[0]["s"]
        gaps = sum(max(0.0, w[i + 1]["s"] - w[i]["e"] - 0.3) for i in range(len(w) - 1))
        r["wps_words"] = round(nw / max(0.2, span), 2)
        r["wps_words_np"] = round(nw / max(0.2, span - gaps), 2)
    else:
        r["wps_words"] = r["wps_words_np"] = None
    return r


def measure(item):
    x, sr = load(item["wav"])
    hyp, words = whisper(item["wav"])
    ref_n, hyp_n = norm(item["text"]), norm(hyp)
    e = wer(ref_n, hyp_n)
    lead, trail, speech = silences(x, sr)
    med, p10, p90, vfrac = pitch(x, 16000 if sr < 16000 else sr) if True else (None,) * 4
    integ, mom, peak, tp = loudness(x, sr)
    nw = len(ref_n)
    # non-word sound: frames within 30 dB of the loudest frame that lie outside every recognised word (+-60 ms):
    # this is where a [laugh]/[gasp]/breath tag shows up, since the recogniser skips them
    db_ = frame_db(x, sr)
    loud = db_ > db_.max() - 30
    cover = np.zeros_like(loud)
    for w in words:
        a_, b_ = int(max(0, w["s"] - 0.06) * 100), int((w["e"] + 0.06) * 100)
        cover[a_:b_] = True
    nv = float((loud & ~cover).sum()) * 0.01
    syl = sum(syllables(w) for w in ref_n)
    return {
        "id": item["id"], "wav": item["wav"], "text": item["text"], "heard": hyp, "wer": round(e, 3),
        "exact": hyp_n == ref_n, "words": words, "nonword_s": round(nv, 2),
        "dur": round(len(x) / sr, 3), "lead": round(lead, 3), "trail": round(trail, 3), "speech": round(speech, 3),
        "f0_med": med and round(med, 1), "f0_p10": p10 and round(p10, 1), "f0_p90": p90 and round(p90, 1),
        "f0_range_st": (p10 and round(12 * np.log2(p90 / p10), 2)), "voiced": round(vfrac, 2),
        "wps": round(nw / speech, 2) if speech > 0 else None, "sps": round(syl / speech, 2) if speech > 0 else None,
        "lufs": integ and round(integ, 2), "lufs_max400": round(mom, 2), "peak": round(peak, 2), "tp": round(tp, 2),
    }


def main():
    items = read_json(sys.argv[3])
    out_p = sys.argv[2]
    cache = {}
    if os.path.exists(out_p):
        for r in read_json(out_p):
            cache[r["id"]] = r
    budget = float(os.environ.get("BATCH_SECONDS", "110"))
    t0 = time.time()
    done = 0
    res = []
    left = 0
    for it in items:
        key = f'{it["wav"]}|{os.path.getmtime(it["wav"]):.3f}|{it["text"]}'
        c = cache.get(it["id"])
        if c and c.get("key") == key:
            # re-score with the current normalisation (aliases may have changed); the transcript is kept
            c["wer"] = round(wer(norm(c["text"]), norm(c["heard"])), 3)
            c["exact"] = norm(c["text"]) == norm(c["heard"])
            c["kind"] = it.get("kind", c.get("kind"))
            res.append(derived(c))
            continue
        if time.time() - t0 > budget:
            left += 1
            if c:
                res.append(c)
            continue
        r = measure(it)
        r["key"] = key
        r["kind"] = it.get("kind")
        derived(r)
        res.append(r)
        done += 1
        print(f'{r["id"]:40s} wer={r["wer"]:.2f} f0={r["f0_med"]} lufs={r["lufs"]} heard="{r["heard"]}"', flush=True)
    write_json(out_p, res)
    print(f"measured {done}, left {left}, {time.time()-t0:.0f}s")
    if left:
        sys.exit(3)


if __name__ == "__main__":
    main()
