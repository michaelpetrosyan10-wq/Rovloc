"""Monster round 2: Danny's own (engine-rendered) voice gone wrong, using ONLY mixing, filtering, delay and a synthetic
room (convolution). No vocoder, no pitch or formant shift, no time-stretch.
usage: monster2.py SPEC.json OUTDIR
SPEC: [{"out", "mode": late|close|far, "main": wav, "whisper": wav (late/close), "breath": wav (close, optional),
        "words": [[word, start, end], ...] (far)}]"""
import os, sys, json
import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt, fftconvolve
T = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, T)
from finish import trim
SR = 24000

def ld(p):
    x, sr = sf.read(p, dtype="float32", always_2d=True); x = x.mean(axis=1)
    assert sr == SR, (p, sr)
    return x.astype(np.float64)
def rms(x): return float(np.sqrt(np.mean(x ** 2)) + 1e-12)
def active_rms(x):
    hop = 240; m = len(x) // hop; f = x[:m * hop].reshape(m, hop)
    e = np.sqrt((f ** 2).mean(axis=1)); return float(np.sqrt(np.mean(e[e > e.max() * 0.1] ** 2)) + 1e-12)
def db(v): return 10 ** (v / 20)
def lp(x, fc, o=4): return sosfilt(butter(o, fc, "low", fs=SR, output="sos"), x)
def hp(x, fc, o=2): return sosfilt(butter(o, fc, "high", fs=SR, output="sos"), x)
def shelf_low(x, fc, g_db):
    return x + (db(g_db) - 1) * lp(x, fc, 2)
def mix(*parts):
    n = max(off + len(s) for s, off in parts); y = np.zeros(n)
    for s, off in parts: y[off:off + len(s)] += s
    return y

def lpc_whisper(x, order=26, win=0.025, hop=0.00625, seed=5):
    """a whisper of the same take: each 25 ms frame's vocal-tract shape (LPC) driven by breath noise instead of the
    voice's buzz -- how a real whisper is made (no pitch at all, so nothing to sound robotic)."""
    from scipy.linalg import solve_toeplitz
    from scipy.signal import lfilter
    rng = np.random.default_rng(seed)
    xe = np.append(x[0], x[1:] - 0.92 * x[:-1])
    N = int(win * SR); H = int(hop * SR); w = np.hanning(N)
    y = np.zeros(len(x) + N); norm = np.zeros(len(x) + N)
    for i in range(0, len(xe) - N, H):
        f = xe[i:i + N] * w
        r = np.correlate(f, f, "full")[N - 1:N + order]
        if r[0] < 1e-9:
            continue
        r[0] *= 1.0001
        a = solve_toeplitz(r[:order], -r[1:order + 1])
        A = np.concatenate([[1.0], a])
        err = max(float(r[0] + np.dot(a, r[1:order + 1])), 1e-12)
        g = np.sqrt(err / np.sum(w ** 2))
        e = rng.standard_normal(N) * g
        y[i:i + N] += lfilter([1.0], A, e) * w
        norm[i:i + N] += w ** 2
    y = y[:len(x)] / np.maximum(norm[:len(x)], 1e-3)
    y = lfilter([1.0], [1.0, -0.92], y)
    return hp(y, 120) * (rms(x) / (rms(y) + 1e-12))

def room_ir(rt60=2.6, dark=1800, corridor_ms=13.0, end_ms=140, seed=7, length=None):
    """synthetic long dark corridor: flutter echo between near walls + a far-end reflection + a dark diffuse tail."""
    rng = np.random.default_rng(seed)
    n = int(SR * (length or rt60 * 1.1))
    t = np.arange(n) / SR
    tail = rng.standard_normal(n) * np.exp(-6.91 * t / rt60)
    # darker as it decays: blend a strongly low-passed copy in over time
    tail = lp(tail, dark) * (1 - np.exp(-t / 0.15)) + lp(tail, 4000) * np.exp(-t / 0.15)
    ir = tail * 0.35
    k = int(SR * corridor_ms / 1000)
    for i in range(1, 28):                       # flutter: regular, decaying, slightly smeared
        p = i * k + int(rng.integers(-3, 4))
        if p < n:
            ir[p] += 0.55 * (0.82 ** i)
    p = int(SR * end_ms / 1000)
    ir[p:p + 400] += lp(rng.standard_normal(400), 2500) * 0.25 * np.hanning(400)
    ir[0] = 0.0
    return ir / np.max(np.abs(ir))

def late(s):
    """slow calm take + the same words whispered underneath, a beat late; small dead room."""
    m = trim(ld(s["main"]).astype(np.float32), SR, 0.03, 0.3).astype(np.float64)
    w = ld(s["whisper"]) if s.get("whisper") else lpc_whisper(m)
    w = hp(w, 300)
    w *= active_rms(m) / active_rms(w) * db(s.get("whisper_db", -8))
    y = mix((m, 0), (w, int(SR * s.get("delay", 0.26))))
    ir = room_ir(rt60=0.7, dark=3000, corridor_ms=9, end_ms=60, seed=3)
    wet = fftconvolve(y, ir)[: len(y) + int(SR * 0.5)]
    wet *= rms(y) / rms(wet) * db(s.get("room_db", -16))
    return mix((y, 0), (wet, 0))

def close(s):
    """a close, dry whisper: breath, a short beat, the line; proximity warmth, no room at all."""
    src = trim(ld(s["main"]).astype(np.float32), SR, 0.02, 0.25).astype(np.float64)
    w = lpc_whisper(src)
    w = shelf_low(hp(w, 70), 250, s.get("prox_db", 5.0))
    parts = []
    off = 0
    if s.get("breath"):
        b = trim(ld(s["breath"]).astype(np.float32), SR, 0.01, 0.05, floor_db=45).astype(np.float64)
        b *= active_rms(w) / active_rms(b) * db(s.get("breath_db", -6))
        parts.append((b, 0)); off = len(b) + int(SR * s.get("beat", 0.18))
    parts.append((w, off))
    return mix(*parts)

def far(s):
    """the line from far down a corridor in a long dark room; the last word comes again, quieter, later."""
    raw = ld(s["main"])                       # word times are relative to the untrimmed take
    m = trim(raw.astype(np.float32), SR, 0.03, 0.2).astype(np.float64)
    words = s["words"]
    lw, a, b = words[-1]
    a = max(0, int((a + 0.01) * SR)); b = min(len(raw), int((b + s.get("tail", 0.12)) * SR))
    last = raw[a:b].copy(); f = int(0.015 * SR); last[:f] *= np.linspace(0, 1, f); last[-3 * f:] *= np.linspace(1, 0, 3 * f)
    rep = lp(last, 2600) * db(s.get("repeat_db", -9))
    dry = mix((m, 0), (rep, len(m) + int(SR * s.get("repeat_gap", 0.55))))
    direct = lp(dry, s.get("direct_lp", 3200)) * db(s.get("direct_db", -6))
    ir = room_ir(rt60=s.get("rt60", 2.6), dark=1700, corridor_ms=13, end_ms=150, seed=11)
    wet = fftconvolve(dry, ir)[: len(dry) + int(SR * s.get("rt60", 2.6))]
    wet *= rms(dry) / rms(wet) * db(s.get("wet_db", -2))
    pre = int(SR * 0.012)
    return mix((direct, pre), (wet, 0))

def main():
    spec = json.load(open(sys.argv[1])); out = sys.argv[2]; os.makedirs(out, exist_ok=True)
    for s in spec:
        y = {"late": late, "close": close, "far": far}[s["mode"]](s)
        y = y / (np.abs(y).max() + 1e-9) * 0.7
        sf.write(os.path.join(out, s["out"] + ".wav"), y.astype(np.float32), SR, subtype="FLOAT")
        print(s["out"], round(len(y) / SR, 2), flush=True)

if __name__ == "__main__":
    main()
