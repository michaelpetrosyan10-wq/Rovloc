"""Kokoro-82M v1.0 (onnx-community export) through kokoro-onnx, with voice blends.

voice recipe: {"blend": {"am_puck": 0.7, "af_nicole": 0.3}, "speed": 1.05}
"""
import os, sys, re, glob, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from common import ort_session

SR = 24000


class KokoroEngine:
    def __init__(self, model_dir):
        from kokoro_onnx import Kokoro
        self.voice_dir = os.path.join(model_dir, "voices")
        npz = os.path.join(model_dir, "voices.npz")
        if not os.path.exists(npz):
            arrs = {}
            for p in sorted(glob.glob(os.path.join(self.voice_dir, "*.bin"))):
                a = np.fromfile(p, dtype=np.float32)
                arrs[os.path.basename(p)[:-4]] = a.reshape(-1, 1, 256)
            np.savez(npz, **arrs)
        sess = ort_session(os.path.join(model_dir, "onnx", "model.onnx"))
        self.k = Kokoro.from_session(sess, npz)

    def style(self, blend):
        tot = sum(blend.values())
        return sum(self.k.voices[n] * (w / tot) for n, w in blend.items()).astype(np.float32)

    def render(self, text, recipe, seed=0):
        text = " ".join(re.sub(r"\[[^\]]*\]", " ", text).split())  # TAGS: this engine has none; drop them
        st = self.style(recipe["blend"])
        audio, sr = self.k.create(text, voice=st, speed=float(recipe.get("speed", 1.0)), lang=recipe.get("lang", "en-us"))
        audio = np.asarray(audio, dtype=np.float32)
        if recipe.get("shift"):   # our own WORLD processing of the built-in voice: [pitch semitones, formant ratio]
            import voxfx
            audio = voxfx.world_shift(audio, sr, float(recipe["shift"][0]), float(recipe["shift"][1]))
        return audio, sr


if __name__ == "__main__":
    from common import save
    eng = KokoroEngine(sys.argv[1])
    t = time.time()
    a, sr = eng.render(sys.argv[3], {"blend": {sys.argv[4]: 1.0}})
    el = time.time() - t
    save(sys.argv[2], a, sr)
    print(f"{len(a)/sr:.2f}s audio in {el:.2f}s: RTF {el/(len(a)/sr):.3f}")
