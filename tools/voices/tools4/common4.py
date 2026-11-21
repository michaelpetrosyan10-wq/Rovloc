"""Round 4 shared helpers: strict word check, name sound keys, room tone, levels, file writing."""
import os, sys, re, json, hashlib, subprocess
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
for p in (os.path.join(V, "tools2"), os.path.join(V, "tools")):
    if p not in sys.path: sys.path.insert(0, p)
import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt
SR = 24000
# spelling-only aliases: the same spoken word written another way. Interjections are KEPT (not dropped), so
# "Ha. It's cold." must be heard with its "ha" (unlike tools/measure.py, which drops fillers).
AL = {"woah": "whoa", "wo": "whoa", "hah": "ha", "mr": "mister", "okay": "ok", "12": "twelve", "50": "fifty", "4": "four",
      "40": "forty", "percent": "percent", "ohh": "oh", "ooh": "oh", "hm": "hmm", "mm": "hmm", "hmm": "hmm", "owe": "ow",
      "ouch": "ouch", "boo": "boo", "booo": "boo", "hiya": "hi"}
def norm4(t):
    t = t.lower().replace("’", "'").replace("%", " percent ").replace("-", " ").replace("—", " ")
    t = re.sub(r"[^a-z0-9' ]", " ", t)
    out = []
    for w in t.split():
        w = w.strip("'"); w = AL.get(w, w); w = w.replace("'", "")
        if w: out.extend(w.split())
    # "haha", "hahaha" -> ha ha (ha ...)
    o2 = []
    for w in out:
        if re.fullmatch(r"(ha){2,}h?", w): o2.extend(["ha"] * (len(w) // 2))
        else: o2.append(w)
    return o2
def wer(r, h):
    d = np.zeros((len(r) + 1, len(h) + 1), dtype=int); d[:, 0] = range(len(r) + 1); d[0, :] = range(len(h) + 1)
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            d[i, j] = min(d[i - 1, j] + 1, d[i, j - 1] + 1, d[i - 1, j - 1] + (r[i - 1] != h[j - 1]))
    return d[len(r), len(h)] / max(1, len(r))
def word_for_word(text, heard):
    return norm4(text) == norm4(heard or "")
VARIANTS = [s.split() for s in """zoe zoey|aidan aiden ayden|jaden jayden jaiden|sean shawn shaun|isabel isabelle|sophia sofia
haley hailey hayley haylee|brian bryan|mark marc|katherine catherine kathryn|jasmine jazmin jasmin|steven stephen
eric erik|nicholas nicolas|mohammed muhammad mohammad mohamed|ahmed ahmad|lindsay lindsey|kelsey kelsie|courtney kourtney
ashley ashleigh|mackenzie mckenzie|jada jayda|aisha ayesha|yasmin yasmine|mei may mae|priya pria|kiara kierra chiara
layla leila laila|aria arya|nora norah|ellie elly|lily lilly lillie|sydney sidney|rachel rachael|sarah sara|megan meghan
lauren loren|hannah hanna|emily emilie|jade jayde|eli ely|kai ky|finn fin|levi levy|cole kohl|jesse jessie|luis louis
jon john|tommy tommie|bobby bobbie|joey joie|charlie charley|frank franc|colin collin|tessa tesa|kylie kiley kylee
katie katy kaitie|brianna breanna|camila camilla|julian julien|andre andrei|malik malick|raj rodge
kenji kenzie|hassan hasan|omar omer|ivan ivon|jamal jamaal|darius darrius|tristan tristen|bryce brice|spencer spenser
gavin gaven|grant grants|isla isler|gianna jianna|imani amani|ian ean
""".replace("\n", "|").split("|") if s.strip()]
def sound_key(n):
    """crude English sound key for first names: consonant skeleton + the final vowel sound."""
    s = n.lower()
    for a, b in (("ph", "f"), ("ck", "k"), ("sch", "sk"), ("ch", "c"), ("sh", "s"), ("th", "t"), ("wh", "w"), ("gh", ""),
                 ("q", "k"), ("x", "ks"), ("z", "s"), ("c", "k"), ("y", "i"), ("ee", "i"), ("ea", "i"), ("ie", "i"),
                 ("ei", "i"), ("ey", "i"), ("ai", "a"), ("ay", "a"), ("ae", "a"), ("ou", "u"), ("oo", "u"), ("aw", "a"),
                 ("au", "a"), ("ah", "a"), ("eh", "e"), ("oh", "o")):
        s = s.replace(a, b)
    s = re.sub(r"(.)\1+", r"\1", s)
    s = re.sub(r"(?<=[^aeiou])h", "", s)
    if len(s) > 2 and s.endswith("e") and s[-2] not in "aeiou": s = s[:-1]
    fin = s[-1] if s and s[-1] in "aeiou" else ""
    return (s[0] + re.sub(r"[aeiou]", "", s[1:]) + fin) if s else s
def same_name(a, b):
    a, b = a.lower(), b.lower()
    if a == b: return True
    for g in VARIANTS:
        if a in g and b in g: return True
    return sound_key(a) == sound_key(b)
def name_check(name, heard):
    """'exact' | 'variant' (another spelling that sounds the same) | 'fail'"""
    w = norm4(heard or "")
    if w == [name.lower()]: return "exact"
    if len(w) == 1 and same_name(w[0], name): return "variant"
    return "fail"
# ---- room tone: one fixed, seeded, faint bed under every monster file (never digital silence) ----
BED_DB = -60.0          # RMS dBFS of the bed (about 38 dB under the whisper lines at -22 LUFS)
_BED = None
def bed_buffer():
    global _BED
    if _BED is None:
        rng = np.random.default_rng(20261118)
        n = SR * 60
        X = np.fft.rfft(rng.standard_normal(n)); f = np.fft.rfftfreq(n, 1 / SR)
        X *= 1 / np.sqrt(np.maximum(f, 40.0))          # pink
        y = np.fft.irfft(X, n)
        y = sosfilt(butter(2, 80, "high", fs=SR, output="sos"), y)
        y = sosfilt(butter(4, 6500, "low", fs=SR, output="sos"), y)
        y = y[SR:]                                      # drop filter start
        _BED = y / np.sqrt(np.mean(y ** 2)) * 10 ** (BED_DB / 20)
    return _BED
def bed(n, key):
    b = bed_buffer(); off = int(hashlib.sha256(key.encode()).hexdigest(), 16) % (len(b) - n - 1)
    return b[off:off + n].copy()
def frame_db(x, hop=240):
    m = len(x) // hop; f = x[:m * hop].reshape(m, hop)
    return 20 * np.log10(np.sqrt((f ** 2).mean(axis=1)) + 1e-12)
def active_rms(x, hop=240, rel=0.1):
    m = len(x) // hop; f = x[:m * hop].reshape(m, hop); e = np.sqrt((f ** 2).mean(axis=1))
    return float(np.sqrt(np.mean(e[e > e.max() * rel] ** 2)) + 1e-12)
def lufs(y):
    import pyloudnorm as pyln
    try:
        v = pyln.Meter(SR).integrated_loudness(np.asarray(y, dtype=np.float64))
        return round(float(v), 2) if np.isfinite(v) else None
    except Exception:
        return None
def write_pair(base, y, sr=SR):
    """24 kHz mono 16-bit WAV + MP3 (libmp3lame VBR q4, LAME/Xing header so decoders can drop the encoder delay)."""
    os.makedirs(os.path.dirname(base), exist_ok=True)
    sf.write(base + ".wav", np.clip(y, -1, 1).astype(np.float32), sr, subtype="PCM_16")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(sr), "-ac", "1", "-i", "pipe:0",
                    "-c:a", "libmp3lame", "-q:a", "4", "-map_metadata", "-1", "-id3v2_version", "0", "-write_xing", "1",
                    base + ".mp3"], input=np.ascontiguousarray(y, dtype=np.float32).tobytes(), check=True)
def ld(p):
    x, sr = sf.read(p, dtype="float32", always_2d=True); x = x.mean(axis=1)
    assert sr == SR, (p, sr)
    return x.astype(np.float64)
def jload(p, default=None):
    return json.load(open(p)) if os.path.exists(p) else default
def jsave(p, d):
    os.makedirs(os.path.dirname(p), exist_ok=True); json.dump(d, open(p, "w"), indent=1)
