"""Voice processing for ROVLOC (our own DSP; WORLD vocoder via pyworld, MIT).

- world_shift: pitch (semitones) and formants (ratio) moved independently, optional time stretch, optional whisper
- monster:     the research/sound.md 2.5 recipe (main layer, whisper double, sub layer, porcelain comb) with a preset
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from scipy.signal import butter, sosfilt, lfilter

FP = 5.0  # WORLD frame period, ms


def analyse(x, sr):
    import pyworld as pw
    xd = x.astype(np.float64)
    f0, t = pw.harvest(xd, sr, f0_floor=60, f0_ceil=600, frame_period=FP)
    sp = pw.cheaptrick(xd, f0, t, sr)
    ap = pw.d4c(xd, f0, t, sr)
    return f0, sp, ap


def warp_sp(sp, ratio):
    """ratio > 1 moves formants up (shorter vocal tract), < 1 down."""
    if abs(ratio - 1) < 1e-4:
        return sp
    n = sp.shape[1]
    k = np.arange(n)
    src = np.clip(k / ratio, 0, n - 1)
    lo = np.floor(src).astype(int)
    hi = np.minimum(lo + 1, n - 1)
    fr = src - lo
    out = sp[:, lo] * (1 - fr) + sp[:, hi] * fr
    return np.maximum(out, 1e-16)


def stretch(arr, factor):
    """time-stretch frame tracks by factor (>1 = slower)."""
    if abs(factor - 1) < 1e-4:
        return arr
    n = arr.shape[0]
    m = int(round(n * factor))
    idx = np.clip(np.round(np.arange(m) / factor).astype(int), 0, n - 1)
    return arr[idx]


def world_shift(x, sr, pitch_st=0.0, formant=1.0, slow=1.0, whisper=False, f0_range=1.0, analysis=None,
                jitter=0.0, seed=0):
    import pyworld as pw
    f0, sp, ap = analysis if analysis is not None else analyse(x, sr)
    f0 = f0.copy()
    v = f0 > 0
    if v.any() and f0_range != 1.0:
        med = np.exp(np.median(np.log(f0[v])))
        f0[v] = med * np.exp((np.log(f0[v]) - np.log(med)) * f0_range)
    f0[v] *= 2 ** (pitch_st / 12)
    if jitter > 0 and v.any():
        rng = np.random.default_rng(seed)
        n = len(f0)
        wob = np.convolve(rng.standard_normal(n), np.ones(12) / 12, mode="same")
        f0[v] *= 2 ** (jitter * wob[v] / 12)
    sp = warp_sp(sp, formant)
    f0, sp, ap = stretch(f0, slow), stretch(sp, slow), stretch(ap, slow)
    if whisper:
        f0 = np.zeros_like(f0)
        ap = np.ones_like(ap)
    y = pw.synthesize(np.ascontiguousarray(f0), np.ascontiguousarray(sp), np.ascontiguousarray(ap), sr,
                      frame_period=FP)
    return y.astype(np.float32)


def bandshelf(x, sr, lo=1000, hi=4000, db=2.0):
    sos = butter(2, [lo, hi], btype="band", fs=sr, output="sos")
    return x + (10 ** (db / 20) - 1) * sosfilt(sos, x)


def comb(x, sr, delay_ms=0.4, fb=0.55, wet=0.2):
    """short resonator: a feedback comb (delay 0.33-0.5 ms -> 2-3 kHz ring), band-limited."""
    d = max(1, int(sr * delay_ms / 1000))
    a = np.zeros(d + 1)
    a[0] = 1
    a[d] = -fb
    y = lfilter([1 - fb], a, x)
    sos = butter(2, [1500, 4500], btype="band", fs=sr, output="sos")
    y = sosfilt(sos, y)
    return (1 - wet) * x + wet * y * 2.0


def lowpass(x, sr, fc):
    return sosfilt(butter(4, fc, btype="low", fs=sr, output="sos"), x)


def highpass(x, sr, fc):
    return sosfilt(butter(2, fc, btype="high", fs=sr, output="sos"), x)


def db(v):
    return 10 ** (v / 20)


PRESETS = {
    # mild: still clearly Danny, slightly too low and too slow, a faint whisper behind him
    "m1": dict(pitch=-2.0, formant=0.94, slow=1.10, f0_range=0.85, whisper_db=-15, whisper_ms=30, sub_db=None,
               comb_wet=0.10, jitter=0.0, presence_db=2.0),
    # the recipe in research/sound.md 2.5 at its middle values
    "m2": dict(pitch=-3.5, formant=0.90, slow=1.15, f0_range=0.7, whisper_db=-11, whisper_ms=35, sub_db=-18,
               comb_wet=0.18, jitter=0.25, presence_db=2.0),
    # extreme: big body, flat wobbling pitch, whisper close behind, sub felt; still meant to pass Whisper
    "m3": dict(pitch=-6.0, formant=0.84, slow=1.22, f0_range=0.45, whisper_db=-7, whisper_ms=40, sub_db=-14,
               comb_wet=0.25, jitter=0.6, presence_db=3.0),
}


def monster(x, sr, preset, seed=0):
    p = PRESETS[preset] if isinstance(preset, str) else preset
    an = analyse(x, sr)
    main = world_shift(x, sr, p["pitch"], p["formant"], p["slow"], f0_range=p["f0_range"], analysis=an,
                       jitter=p["jitter"], seed=seed)
    main = bandshelf(main, sr, 1000, 4000, p["presence_db"])
    if p["comb_wet"] > 0:
        main = comb(main, sr, 0.42, 0.55, p["comb_wet"])
    n = len(main) + int(sr * 0.06)
    out = np.zeros(n, dtype=np.float64)
    out[: len(main)] += main
    # whisper double: the same words, unvoiced, a touch higher formants so it sits apart; offset late
    wh = world_shift(x, sr, 0, p["formant"] * 1.04, p["slow"], whisper=True, analysis=an)
    wh = highpass(wh, sr, 400)
    rms_m = np.sqrt(np.mean(main ** 2)) + 1e-9
    rms_w = np.sqrt(np.mean(wh ** 2)) + 1e-9
    off = int(sr * p["whisper_ms"] / 1000)
    m = min(len(wh), n - off)
    out[off: off + m] += wh[:m] * (rms_m / rms_w) * db(p["whisper_db"])
    if p["sub_db"] is not None:
        sub = world_shift(x, sr, p["pitch"] - 12, p["formant"] * 0.8, p["slow"], f0_range=p["f0_range"], analysis=an)
        sub = lowpass(sub, sr, 300)
        rms_s = np.sqrt(np.mean(sub ** 2)) + 1e-9
        m = min(len(sub), n)
        out[:m] += sub[:m] * (rms_m / rms_s) * db(p["sub_db"])
    return out.astype(np.float32)


if __name__ == "__main__":
    from common import load, save
    x, sr = load(sys.argv[2])
    save(sys.argv[3], monster(x, sr, sys.argv[1]), sr)
