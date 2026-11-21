"""Pick the best take of every line, process it (character chain, monster treatments, name bank) and normalise.

usage: finish.py PLAN.json RAW_DIR MEASURE_RAW.json FINAL_DIR BREATH.wav
Writes FINAL_DIR/<id>.wav (mono float, 24 kHz), FINAL_DIR/items.json (for measure.py) and FINAL_DIR/picks.json
(per line: the take, its raw rate, the pause cuts and the tempo change applied).
BREATH.wav is tools/breath.py's synthesised inhale (no recording of a person).
FINAL_DIR/retake.json (written by tools/retake.py from the final measurements, optional): per dialogue file, takes
to exclude and takes to use without a tempo change, so a line the recogniser mishears after processing is redone.

Loudness: every spoken line is normalised to -20 LUFS integrated (BS.1770) with true peak <= -1.5 dBTP (0.5 dB of
room for the MP3 encoder, review m5); whispers -23 LUFS. SOUND.md has no dialogue class; -20 follows
research/sound.md 3.1 (dialogue short-term ~-20 LUFS on laptop speakers).
Dialogue lines (not the monster, not the PA): pauses inside a line longer than 0.40 s are cut to 0.34 s, and the
speaking rate is brought into 2.2-3.25 words/s (energy span; the board gate is 2.0-3.6 on two measures) with
ffmpeg's atempo (pitch kept) when the best take is outside it.
Monster files: a faint room-tone bed (36 dB under the line) runs under the whole file, inhale and beat included,
so no file holds digital silence (review M3). Name bank: NAME file = name + 0.25 s of bed fading out; REST file
(mon_x1_m2_rest) = the twin line with no inhale, bed fading in for 0.10 s; the game starts REST at
(NAME duration - NAME_OVERLAP) after NAME starts; join_*.wav is exactly that overlap-add.
"""
import os, sys, json, re, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from common import load, save, read_json, write_json
import voxfx as fx
from scipy.signal import butter, sosfilt, resample_poly

SR = 24000
LUFS_LINE, LUFS_WHISPER, TP_MAX = -20.0, -23.0, -1.5
GAP_MAX, GAP_KEEP = 0.40, 0.34            # pauses inside a dialogue line
RATE_LO, RATE_HI = 2.2, 3.3               # words/s target for dialogue on BOTH measures; board gate 2.0-3.6
BED_DB = -36.0                            # room-tone bed under monster files, relative to the line's RMS
NAME_TAIL, NAME_OVERLAP, REST_HEAD = 0.25, 0.25, 0.10


def frame_db(x, hop):
    m = len(x) // hop
    f = x[: m * hop].reshape(m, hop)
    return 20 * np.log10(np.sqrt((f ** 2).mean(axis=1)) + 1e-9)


def trim(x, sr, lead=0.06, trail=0.20, floor_db=40):
    hop = int(sr * 0.01)
    d = frame_db(x, hop)
    on = np.where(d > d.max() - floor_db)[0]
    if len(on) == 0:
        return x
    a = max(0, on[0] * hop - int(lead * sr))
    b = min(len(x), (on[-1] + 1) * hop + int(trail * sr))
    y = x[a:b].copy()
    return fades(y, sr)


def fades(y, sr, fi=0.005, fo=0.03):
    n1, n2 = int(fi * sr), int(fo * sr)
    if len(y) > n1 + n2:
        y[:n1] *= np.linspace(0, 1, n1)
        y[-n2:] *= np.linspace(1, 0, n2) ** 2
    return y


def true_peak_db(x):
    return 20 * np.log10(np.abs(resample_poly(x, 4, 1)).max() + 1e-12)


def limiter(x, sr, ceiling_db=TP_MAX - 0.3, attack=0.002, release=0.08):
    """feed-forward peak limiter on the 4x-oversampled envelope; only acts on the few peaks over the ceiling."""
    c = 10 ** (ceiling_db / 20)
    up = np.abs(resample_poly(x, 4, 1))
    env = up.reshape(-1, 4).max(axis=1)[: len(x)] if len(up) >= 4 * len(x) else np.abs(x)
    env = np.pad(env, (0, len(x) - len(env)), mode="edge")
    need = np.minimum(1.0, c / np.maximum(env, 1e-9))
    la = int(attack * sr)
    # look-ahead: the gain reaches its value before the peak
    g = np.array([need[i:i + la + 1].min() for i in range(len(need))]) if la > 0 else need
    rel = np.exp(-1 / (release * sr))
    out = np.empty_like(g)
    cur = 1.0
    for i, v in enumerate(g):
        cur = v if v < cur else rel * cur + (1 - rel) * v
        out[i] = cur
    return x * out


def normalise(x, sr, target):
    import pyloudnorm as pyln
    m = pyln.Meter(sr)
    xx = x.astype(np.float64)
    if len(xx) < int(0.45 * sr):
        xx = np.concatenate([xx, np.zeros(int(0.45 * sr) - len(xx) + 1)])
    l = m.integrated_loudness(xx)
    y = x * 10 ** ((target - l) / 20)
    for _ in range(3):
        if true_peak_db(y) <= TP_MAX:
            break
        y = limiter(y, sr)
        l2 = m.integrated_loudness(np.pad(y, (0, max(0, int(0.45 * sr) - len(y) + 1))).astype(np.float64))
        y = y * 10 ** ((target - l2) / 20)
    if true_peak_db(y) > TP_MAX:
        y = y * 10 ** ((TP_MAX - true_peak_db(y)) / 20)
    return y.astype(np.float32)


def quiet_runs(x, sr, floor_db=40):
    """(start, end) frame indices (10 ms) of quiet runs strictly inside the speech."""
    hop = int(sr * 0.01)
    d = frame_db(x, hop)
    thr = max(d.max() - floor_db, -60)
    on = np.where(d > thr)[0]
    if len(on) < 2:
        return [], on, hop
    q = d[on[0]:on[-1] + 1] <= thr
    runs, s0 = [], None
    for i, v in enumerate(q):
        if v and s0 is None:
            s0 = i
        if not v and s0 is not None:
            runs.append((on[0] + s0, on[0] + i))
            s0 = None
    return runs, on, hop


def shorten_pauses(x, sr, gap_max=GAP_MAX, keep=GAP_KEEP):
    """cut every pause inside the line longer than gap_max down to keep (10 ms cross-fade at the splice)."""
    runs, _, hop = quiet_runs(x, sr)
    cuts = []
    xf = int(0.01 * sr)
    for a, b in reversed(runs):
        if (b - a) * 0.01 <= gap_max:
            continue
        a_s, b_s = a * hop, b * hop
        half = int(keep * sr / 2)
        c1, c2 = a_s + half, b_s - half          # remove x[c1:c2], cross-fade over xf samples
        fade = np.linspace(0, 1, xf, dtype=np.float32)
        mid = x[c1 - xf:c1] * (1 - fade) + x[c2 - xf:c2] * fade
        x = np.concatenate([x[:c1 - xf], mid, x[c2:]]).astype(np.float32)
        cuts.append(round((b - a) * 0.01, 2))
    return x, cuts


def speech_span(x, sr):
    """the measure.py speech span: first to last 10 ms frame within 40 dB of the loudest (floor -60 dBFS)."""
    hop = int(sr * 0.01)
    d = frame_db(x, hop)
    on = np.where(d > max(d.max() - 40, -60))[0]
    return (on[-1] + 1 - on[0]) * 0.01 if len(on) else 0.0


def atempo(x, sr, factor):
    """ffmpeg atempo (WSOLA-type: pitch and timbre kept); factor < 1 slows down."""
    r = subprocess.run(["ffmpeg", "-v", "error", "-f", "f32le", "-ar", str(sr), "-ac", "1", "-i", "pipe:0",
                        "-filter:a", f"atempo={factor:.4f}", "-f", "f32le", "pipe:1"],
                       input=np.ascontiguousarray(x, dtype=np.float32).tobytes(), capture_output=True, check=True)
    return np.frombuffer(r.stdout, dtype=np.float32).copy()


def word_span(words, removed, tagged):
    """the recogniser's word span of the raw take, less the pause time cut out (gaps > 0.3 s too, if tagged)."""
    if not words:
        return None
    span = words[-1]["e"] - words[0]["s"] - removed
    if tagged:
        span -= sum(max(0.0, words[i + 1]["s"] - words[i]["e"] - 0.3) for i in range(len(words) - 1))
    return max(0.2, span)


def tempo_for(re_, rw):
    """the atempo factor that brings both rates into RATE_LO..RATE_HI (1.0 if they already are)."""
    hi, lo = max(re_, rw), min(re_, rw)
    if hi > RATE_HI:
        return (RATE_HI - 0.05) / hi
    if lo < RATE_LO:
        return min((RATE_LO + 0.1) / lo, (RATE_HI - 0.05) / hi)
    return 1.0


def bed(n, sr, rms_line, seed=3):
    """faint room tone: brown-ish noise under 700 Hz plus a little air, BED_DB under the line's RMS."""
    rng = np.random.default_rng(seed)
    w = rng.standard_normal(n + sr // 5)
    lo = sosfilt(butter(2, 700, btype="low", fs=sr, output="sos"), np.cumsum(w) * 0.02)
    lo = sosfilt(butter(2, 40, btype="high", fs=sr, output="sos"), lo)
    hi = sosfilt(butter(2, [2000, 5000], btype="band", fs=sr, output="sos"), w)
    lo, hi = lo[sr // 5:], hi[sr // 5:]
    b = lo / (np.sqrt(np.mean(lo ** 2)) + 1e-12) + 0.35 * hi / (np.sqrt(np.mean(hi ** 2)) + 1e-12)
    b = b / (np.sqrt(np.mean(b ** 2)) + 1e-12) * rms_line * 10 ** (BED_DB / 20)
    return b.astype(np.float32)


def ramp(n, sr, fade_in=0.03, fade_out=0.03):
    e = np.ones(n, np.float32)
    a, b = min(n, int(fade_in * sr)), min(n, int(fade_out * sr))
    if a:
        e[:a] = np.linspace(0, 1, a)
    if b:
        e[-b:] *= np.linspace(1, 0, b) ** 2
    return e


def rms(y):
    return float(np.sqrt(np.mean(np.asarray(y, np.float64) ** 2)) + 1e-9)


def pa_chain(x, sr):
    y = sosfilt(butter(4, [300, 3800], btype="band", fs=sr, output="sos"), x)
    y = y / (np.abs(y).max() + 1e-9)
    y = np.tanh(1.4 * y) / np.tanh(1.4)
    out = np.zeros(len(y) + int(1.2 * sr))
    out[: len(y)] += y
    for ms, dbv in ((140, -15), (330, -20), (560, -25)):   # hall slaps from far speakers
        o = int(sr * ms / 1000)
        out[o: o + len(y)] += y * 10 ** (dbv / 20)
    rng = np.random.default_rng(7)
    ir = rng.standard_normal(int(0.9 * sr)) * np.exp(-np.arange(int(0.9 * sr)) / (0.22 * sr))
    tail = np.convolve(y, ir)[: len(out)] * 0.012
    out[: len(tail)] += tail
    return trim(out.astype(np.float32), sr, lead=0.03, trail=0.4, floor_db=45)


def gus_chain(x, sr, deep=False):
    """Gus, 58: one WORLD pass. Chatterbox candidates: -1 st, formants -3 %; Kokoro candidate (deep): -3 st, -7 %."""
    return fx.world_shift(x, sr, pitch_st=-3.0 if deep else -1.0, formant=0.93 if deep else 0.97)


def pick_key(t, M, note):
    r = M.get(t)
    if r is None:
        return (9, 0, 0, 0)
    tag = bool(note) and any(k in note for k in ("laugh", "groan"))
    return (round(r["wer"], 3), -r.get("nonword_s", 0) if tag else 0, 0, 0 if not r.get("runaway") else 1)


def pick(takes, M, note):
    def score(t):
        r = M.get(t)
        if r is None:
            return (9, 0, 0)
        tag = bool(note) and any(k in note for k in ("laugh", "groan"))
        w = r.get("wps") or 0
        if tag:
            w = r.get("wps_eff") or w
        rate_pen = 0 if (RATE_LO <= w <= RATE_HI + 0.15) else round(min(abs(w - RATE_LO), abs(w - RATE_HI)), 1)
        return (round(r["wer"], 3), -r.get("nonword_s", 0) if tag else 0, rate_pen,
                0 if not r.get("runaway") else 1)
    return min(takes, key=score)


def main():
    plan_p, raw, mraw_p, final, breath_p = sys.argv[1:6]
    plan = read_json(plan_p)
    M = {r["id"]: r for r in read_json(mraw_p)}
    for r in M.values():
        j = os.path.join(raw, r["id"] + ".json")
        if os.path.exists(j):
            r["runaway"] = read_json(j).get("runaway", False)
    os.makedirs(final, exist_ok=True)
    items, picks = [], {}

    def raw_of(tid):
        x, sr = load(os.path.join(raw, tid + ".wav"), SR)
        return x, sr

    def emit(fid, y, text, target=LUFS_LINE, kind="line"):
        y = normalise(y, SR, target)
        p = os.path.join(final, fid + ".wav")
        old = load(p)[0] if os.path.exists(p) else None
        if old is None or len(old) != len(y) or np.abs(old - y).max() > 1e-6:   # keep mtime: measure cache
            save(p, y, SR)
        items.append({"id": fid, "wav": p, "text": text, "kind": kind})

    from measure import norm as word_norm

    def prepare(t, text, tag):
        """trim, cut long pauses, and work out the rate on both measures and the tempo change it needs."""
        x = trim(raw_of(t)[0], SR)
        x, cuts = shorten_pauses(x, SR)
        r = M.get(t) or {}
        nonword = r.get("nonword_s", 0.0) if tag else 0.0
        nw = len(word_norm(text))
        re_ = nw / max(0.3, speech_span(x, SR) - nonword)
        ws = word_span(r.get("words"), sum(c - GAP_KEEP for c in cuts), tag)
        rw = nw / ws if ws else re_
        return x, cuts, nonword, round(re_, 2), round(rw, 2), tempo_for(re_, rw)

    rt_p = os.path.join(final, "retake.json")
    RT = read_json(rt_p) if os.path.exists(rt_p) else {}

    def dialogue(fid, takes, text, note, fx_="dialogue"):
        tag = bool(note) and any(k in note for k in ("laugh", "groan"))
        ex = RT.get(fid, {}).get("exclude", [])
        no_tempo = RT.get(fid, {}).get("no_tempo", [])
        takes = [tk for tk in takes if tk not in ex] or takes
        best = pick(takes, M, note)
        if fx_ == "pa":     # the PA is a slow two-word announcement with an echo: not a dialogue rate
            t, x, cuts = best, trim(raw_of(best)[0], SR), []
            rates, f = None, 1.0
            x = pa_chain(x, SR)
        else:
            # among the takes as good as the best one on words and tags, the one that needs the least tempo change
            bk = pick_key(best, M, note)[:2]
            cands = [tk for tk in takes if pick_key(tk, M, note)[:2] == bk]
            prep = {tk: prepare(tk, text, tag) for tk in cands}
            for tk in cands:   # retake: this take misheard after the tempo change, and is inside the gate without it
                if tk in no_tempo:
                    prep[tk] = prep[tk][:5] + (1.0,)
            t = min(cands, key=lambda tk: (abs(np.log(prep[tk][5])), cands.index(tk)))
            x, cuts, nonword, re_, rw, f = prep[t]
            rates = [re_, rw]
            if fx_ in ("gus", "gus_deep"):
                x = trim(gus_chain(x, SR, deep=fx_ == "gus_deep"), SR)
            if f != 1.0:
                x = trim(atempo(x, SR, f), SR)
        picks[fid] = {"take": t, "pauses_cut_s": cuts, "rate_before_energy_words": rates, "tempo": round(f, 3)}
        emit(fid, x, text)

    for ch in plan["characters"]:
        for c in ch["candidates"]:
            for ln in c["lines"]:
                dialogue(ln["id"], ln["takes"], ln["text"], ln["note"], ln["fx"])
    for it in plan["engines"]["items"]:
        dialogue(it["id"], it["takes"], it["text"], None)

    # the monster
    br, _ = load(breath_p, SR)
    br = fades(br.copy(), SR, 0.02, 0.03)
    mon = plan["monster"]
    processed = {}
    for ln in mon["base"]:
        t = pick(ln["takes"], M, ln["note"])
        picks[ln["id"]] = {"take": t}
        x = trim(raw_of(t)[0], SR, lead=0.02, trail=0.1)
        emit(ln["id"] + "_clean", x, ln["text"], kind="clean")
        for p in ("m1", "m2", "m3"):
            y = trim(fx.monster(x, SR, p, seed=1), SR, lead=0.02, trail=0.35, floor_db=45)
            processed[(ln["id"], p)] = y
            # an inhale before the line (none after), 14 dB under the line; a 0.12 s beat; the bed under it all
            b = br * (rms(y) / rms(br)) * 10 ** (-14 / 20)
            z = np.concatenate([b, np.zeros(int(0.12 * SR), np.float32), y]).astype(np.float32)
            z = z + bed(len(z), SR, rms(y)) * ramp(len(z), SR, 0.03, 0.12)
            emit(f'{ln["id"]}_{p}', z, ln["text"], kind=p)
    for ln in mon["whispers"]:
        t = pick(ln["takes"], M, ln["note"])
        picks[ln["id"]] = {"take": t}
        x = trim(raw_of(t)[0], SR, lead=0.02, trail=0.1)
        y = fx.world_shift(x, SR, 0, 0.95, 1.12, whisper=True)
        y = fx.highpass(y, SR, 250)
        y = fx.comb(y, SR, 0.42, 0.5, 0.12)
        emit(ln["id"] + "_w", trim(y.astype(np.float32), SR, lead=0.02, trail=0.3, floor_db=45), ln["text"],
             LUFS_WHISPER, kind="whisper")

    # the name bank. REST = the twin line (x1 "I saw you.", M2) with no inhale, the bed fading in under its start
    y = processed[("mon_x1", "m2")]
    head = int(REST_HEAD * SR)
    z = np.concatenate([np.zeros(head, np.float32), y]).astype(np.float32)
    z = z + bed(len(z), SR, rms(y), seed=5) * ramp(len(z), SR, REST_HEAD, 0.12)
    emit("mon_x1_m2_rest", z, "I saw you.", kind="rest")
    tw, _ = load(os.path.join(final, "mon_x1_m2_rest.wav"), SR)
    # every take of every name: cut the name out of its carrier, process like the line, add the bed tail; then
    # join to REST exactly as the game plays it. select_names.py keeps, per name, the take whose clip AND join the
    # recogniser gets right (the gate is on the finished sound, not on the raw take)
    hop = int(SR * 0.01)
    for nm in mon["names"]:
        for t in nm["takes"]:
            x, _ = raw_of(t)
            w = M[t]["words"] if M.get(t) else []
            end = w[0]["e"] if w else 0.6
            nxt = w[1]["s"] - 0.03 if len(w) > 1 else end + 0.45
            # the recogniser's word end can sit early on a drawn-out name: extend until the energy is 40 dB under
            # the peak (review m6), but never into the next word of the carrier
            d = frame_db(x, hop)
            k = int(end * 100)
            while k < len(d) - 1 and k < int(min(end + 0.45, nxt) * 100) and d[k] > d.max() - 40:
                k += 1
            seg = x[: (k + 1) * hop].copy()
            seg = fades(trim(seg, SR, lead=0.02, trail=0.0, floor_db=60), SR, 0.005, 0.02)
            y = trim(fx.monster(seg, SR, "m2", seed=1), SR, lead=0.02, trail=0.20, floor_db=45)
            tail = int(NAME_TAIL * SR)
            z = np.concatenate([y, np.zeros(tail, np.float32)]).astype(np.float32)
            z = z + bed(len(z), SR, rms(y), seed=5) * ramp(len(z), SR, 0.03, NAME_TAIL)
            sfx = t.rsplit("_", 1)[-1]
            emit(f'{nm["id"]}_m2_{sfx}', z, nm["name"], kind="name")
            a_, _ = load(os.path.join(final, f'{nm["id"]}_m2_{sfx}.wav'), SR)
            off = len(a_) - int(NAME_OVERLAP * SR)
            j = np.zeros(off + len(tw), np.float32)
            j[: len(a_)] += a_
            j[off:] += tw
            emit(f'join_{nm["name"].lower()}_{sfx}', j, f'{nm["name"]}... I saw you.', kind="joined")
    write_json(os.path.join(final, "items.json"), items)
    write_json(os.path.join(final, "picks.json"), picks)
    print(len(items), "files")


def norm1(w):
    return re.sub(r"[^a-z]", "", w.lower())


if __name__ == "__main__":
    main()
