"""Measure how 'alive' a speech file is.  usage: analyze.py OUT.json [--asr] id=path[=text] ...
f0 (pyworld harvest, 5 ms): median Hz, SD and 5-95 % range in semitones (melody), micro-jitter = median |step| between
consecutive voiced 5 ms frames in cents (natural voices wobble; vocoder/flat voices don't);
aperiodicity (D4C) mean in 1-4 kHz over voiced frames, dB (more negative = more strictly periodic = buzzier);
spectral flux: mean RMS change of the 10 ms log spectrum (dB) over speech frames (low = smeared / static);
hf_ratio: energy 4-8 kHz vs 0.1-4 kHz, dB (breath, consonant crispness);
asr: faster-whisper small.en text, avg_logprob, word error vs text."""
import os, sys, json
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))
import numpy as np
from common import load
import pyworld as pw
from scipy.signal import stft

def metrics(path):
    x, sr = load(path, 24000)
    x = x.astype(np.float64)
    f0, t = pw.harvest(x, sr, frame_period=5.0, f0_floor=60, f0_ceil=600)
    sp = pw.cheaptrick(x, f0, t, sr)
    ap = pw.d4c(x, f0, t, sr)
    v = f0 > 0
    r = {"dur": round(len(x) / sr, 2)}
    if v.sum() > 10:
        st = 12 * np.log2(f0[v] / np.median(f0[v]))
        r["f0_med"] = round(float(np.median(f0[v])), 1)
        r["f0_sd_st"] = round(float(st.std()), 2)
        r["f0_range_st"] = round(float(np.percentile(st, 95) - np.percentile(st, 5)), 2)
        # micro jitter: consecutive voiced frames only
        idx = np.where(v[1:] & v[:-1])[0]
        steps = 1200 * np.abs(np.log2(f0[idx + 1] / f0[idx]))
        # detrend: remove the slow contour (5-frame median) so this is wobble, not melody
        from scipy.ndimage import median_filter
        lf = np.log2(np.where(v, f0, np.nan))
        r["jitter_c"] = round(float(np.median(steps)), 1)
        nb = ap.shape[1]
        fr = np.linspace(0, sr / 2, nb)
        band = (fr >= 1000) & (fr <= 4000)
        r["aper_db"] = round(float(20 * np.log10(np.clip(ap[v][:, band], 1e-4, 1)).mean()), 1)
        r["voiced"] = round(float(v.mean()), 2)
    f, tt, Z = stft(x, sr, nperseg=1024, noverlap=1024 - 240)
    S = 20 * np.log10(np.abs(Z) + 1e-9)
    e = S.max(axis=0)
    top = S.max()
    S = np.maximum(S, top - 80)
    sp_fr = np.where(10 * np.log10((np.abs(Z) ** 2).sum(axis=0) + 1e-12) > 10 * np.log10((np.abs(Z) ** 2).sum(axis=0).max()) - 35)[0]
    sp_fr = sp_fr[sp_fr > 0]
    d = np.sqrt(((S[:, sp_fr] - S[:, sp_fr - 1]) ** 2).mean(axis=0))
    r["flux_db"] = round(float(d.mean()), 2)
    P = (np.abs(Z) ** 2)[:, sp_fr].sum(axis=1)
    hi = P[(f >= 4000) & (f <= 8000)].sum(); lo = P[(f >= 100) & (f < 4000)].sum()
    r["hf_db"] = round(float(10 * np.log10(hi / lo + 1e-12)), 1)
    hop = 240; m = len(x) // hop
    fd = 20 * np.log10(np.sqrt((x[: m * hop].reshape(m, hop) ** 2).mean(axis=1)) + 1e-9)
    on = np.where(fd > max(fd.max() - 40, -60))[0]
    r["span"] = round((on[-1] + 1 - on[0]) * 0.01, 2) if len(on) else 0.0
    r["peak_db"] = round(float(20 * np.log10(np.abs(x).max() + 1e-9)), 1)
    return r

def main():
    out = sys.argv[1]
    asr = "--asr" in sys.argv
    items = [a for a in sys.argv[2:] if not a.startswith("--")]
    import time
    budget = float(os.environ.get("BATCH_SECONDS", "1e9")); t0 = time.time(); left = 0
    if items and items[0].endswith(".json") and "=" not in items[0]:
        items = [f"{d['id']}={d['wav']}={d['text']}" for d in json.load(open(items[0]))]
    model = None
    if asr:
        from faster_whisper import WhisperModel
        model = WhisperModel(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "models", "whisper-small.en"), device="cpu", compute_type="int8", cpu_threads=2)
        from measure import norm, wer
    res = {}
    if os.path.exists(out):
        res = json.load(open(out))
    for it in items:
        parts = it.split("=", 2)
        k, p = parts[0], parts[1]
        if k in res and res[k].get("file") == p and res[k].get("mtime") == os.path.getmtime(p) and ("asr" in res[k] or not asr):
            continue
        if time.time() - t0 > budget:
            left += 1; continue
        txt = parts[2] if len(parts) > 2 else None
        r = metrics(p)
        r["file"] = p; r["mtime"] = os.path.getmtime(p)
        if model is not None:
            segs, _ = model.transcribe(load(p, 16000)[0], beam_size=5, language="en", condition_on_previous_text=False, word_timestamps=True)
            segs = list(segs)
            hyp = " ".join(s.text.strip() for s in segs)
            r["asr"] = hyp
            r["words"] = [[w.word.strip(), round(w.start, 3), round(w.end, 3)] for sg in segs for w in (sg.words or [])]
            r["logprob"] = round(float(np.mean([s.avg_logprob for s in segs])) if segs else -9, 3)
            if txt:
                r["wps"] = round(len(norm(txt)) / max(r["span"], 0.1), 2)
                r["wer"] = round(wer(norm(txt), norm(hyp.replace("%", " percent"))), 3)
        res[k] = r
        print(k, json.dumps({a: b for a, b in r.items() if a not in ("file", "words")}), flush=True)
        if len(res) % 5 == 0:
            json.dump(res, open(out, "w"), indent=1)
    json.dump(res, open(out, "w"), indent=1)
    print("left", left)
    sys.exit(3 if left else 0)

if __name__ == "__main__":
    main()
