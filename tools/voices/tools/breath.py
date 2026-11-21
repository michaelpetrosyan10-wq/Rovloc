"""A synthesised inhale (shaped noise), so that no recording of a real person is inside any monster line.

usage: breath.py OUT.wav [SEED]
Deterministic: seeded white noise -> three broad vocal-tract-like resonances whose centres rise as the "mouth" opens,
a 6 kHz low-pass and a crescendo envelope (0.42 s: slow rise, quick stop). Float WAV, 24 kHz, peak -12 dBFS
(finish.py sets its level against each line anyway).
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from scipy.signal import butter, sosfilt
from common import save

SR = 24000
DUR = 0.42


def band(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, hi], btype="band", fs=SR, output="sos"), x)


def main():
    out = sys.argv[1]
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 11
    rng = np.random.default_rng(seed)
    n = int(DUR * SR)
    t = np.arange(n) / n
    w = rng.standard_normal(n + SR // 10)
    # two spectral states (closed-ish -> open), cross-faded over the breath: the resonances rise a little
    dark = band(w, 500, 1300) * 1.0 + band(w, 1500, 2600) * 0.45 + band(w, 3000, 4800) * 0.20
    bright = band(w, 700, 1700) * 0.8 + band(w, 1900, 3200) * 0.60 + band(w, 3600, 5600) * 0.30
    dark, bright = dark[SR // 10:], bright[SR // 10:]   # drop the filters' start-up
    y = dark * (1 - t) + bright * t
    y = sosfilt(butter(4, 6000, btype="low", fs=SR, output="sos"), y)
    # slow amplitude flutter (turbulence is not steady), then the crescendo envelope
    fl = np.convolve(rng.standard_normal(n), np.ones(600) / 600, mode="same")
    y *= 1 + 0.25 * fl / (np.abs(fl).max() + 1e-9)
    env = np.where(t < 0.82, (t / 0.82) ** 1.6, np.cos((t - 0.82) / 0.18 * np.pi / 2) ** 2)
    y = y * env
    y = y / (np.abs(y).max() + 1e-9) * 10 ** (-12 / 20)
    save(out, y.astype(np.float32), SR)
    print(f"{out}: {DUR:.2f} s synthesised inhale, seed {seed}")


if __name__ == "__main__":
    main()
