"""Monster 5 for production: Danny 3's own calm take turned into a close, dry whisper with a breath in before it.
The recipe is round 2's Monster 5 (tools2/monster2.py close()): our LPC whisper of the same take (each 25 ms frame's
vocal-tract shape driven by noise instead of the voice's buzz), a 70 Hz high-pass and +5 dB proximity shelf under
250 Hz, our synthetic inhale (out/breath_synth.wav, tools/breath.py) 10 dB under the words, a beat, then the words.
No room, no pitch or formant shift, no time-stretch, no vocoder.
Production additions: a tight trim of the whispered words; ONE global gain (every file's words at the same active
level, so a name and a line match); a faint seeded room tone (common4.BED_DB) under the whole file from its first
sample to its last, so files start and end on the same room tone and never hold digital silence.
Layout of a file: [head room tone] [breath + beat]? [words] [tail room tone]."""
import os, sys, json
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
sys.path.insert(0, H)
import numpy as np
from common4 import SR, ld, bed, active_rms, frame_db, lufs, write_pair, jload
from monster2 import lpc_whisper, shelf_low, hp
from finish import trim, fades
BREATH = os.path.join(V, "out", "breath_synth.wav")
LEVEL = os.path.join(V, "out4", "level.json")
HEAD, TAIL, BEAT, BREATH_DB, PROX_DB = 0.05, 0.25, 0.30, -10.0, 5.0

def words_amp():
    return float((jload(LEVEL) or {}).get("A", 0.06))

def whisper_of(path, cut=None):
    x = ld(path)
    if cut:
        a, b = int(cut[0] * SR), int(cut[1] * SR) if cut[1] else len(x)
        x = x[a:b].copy(); f = int(0.01 * SR); x[:f] *= np.linspace(0, 1, f); x[-f:] *= np.linspace(1, 0, f)
    src = trim(x.astype(np.float32), SR, 0.02, 0.25).astype(np.float64)
    w = lpc_whisper(src)
    w = shelf_low(hp(w, 70), 250, PROX_DB)
    w = trim(w.astype(np.float32), SR, 0.01, 0.06, floor_db=42).astype(np.float64)
    w = fades(w, SR, 0.004, 0.03)
    return w / active_rms(w)

_B = None
def breath():
    global _B
    if _B is None:
        b = trim(ld(BREATH).astype(np.float32), SR, 0.01, 0.05, floor_db=45).astype(np.float64)
        _B = b / active_rms(b)
    return _B

def assemble(w, key, with_breath=True, beat=BEAT, head=HEAD, tail=TAIL, A=None):
    A = words_amp() if A is None else A
    w = w * A
    parts, t = [], int(head * SR); meta = {}
    if with_breath:
        b = breath() * A * 10 ** (BREATH_DB / 20)
        meta["breath_start"] = round(t / SR, 3); parts.append((b, t)); t += len(b)
        meta["breath_end"] = round(t / SR, 3); t += int(beat * SR)
    meta["speech_start"] = round(t / SR, 3); parts.append((w, t)); t += len(w)
    meta["speech_end"] = round(t / SR, 3); n = t + int(tail * SR)
    y = bed(n, key)
    for s, o in parts: y[o:o + len(s)] += s
    meta.update(seconds=round(n / SR, 3), head=head, tail=tail, beat=beat if with_breath else None, breath=with_breath,
                words_seconds=round(len(w) / SR, 3))
    return y, meta

def stats(y, meta):
    a, b = int(meta["speech_start"] * SR), int(meta["speech_end"] * SR)
    return dict(lufs=lufs(y), peak_db=round(float(20 * np.log10(np.abs(y).max() + 1e-12)), 2),
                words_active_db=round(float(20 * np.log10(active_rms(y[a:b]))), 2),
                min_frame_db=round(float(frame_db(y).min()), 1))
