"""Kitten TTS mini 0.8 (KittenML, Apache-2.0) on onnxruntime, re-implemented from kittentts 0.8.0's onnx_model.py
(Apache-2.0; the symbol table below is theirs) so that nothing from the wheel is imported.

voice recipe: {"kvoice": "expr-voice-5-m", "speed": 1.0}   (built-in voices only; blends of them allowed)
"""
import os, sys, re, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from common import ort_session

SR = 24000

_pad = "$"
_punctuation = ';:,.!?¡¿—…"«»"" '
_letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
_letters_ipa = "ɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘'̩'ᵻ"
SYMBOLS = {s: i for i, s in enumerate([_pad] + list(_punctuation) + list(_letters) + list(_letters_ipa))}


def _espeak():
    import espeakng_loader
    from phonemizer.backend.espeak.wrapper import EspeakWrapper
    EspeakWrapper.set_library(espeakng_loader.get_library_path())
    EspeakWrapper.set_data_path(espeakng_loader.get_data_path())
    from phonemizer.backend import EspeakBackend
    return EspeakBackend(language="en-us", preserve_punctuation=True, with_stress=True)


class KittenEngine:
    def __init__(self, model_dir):
        self.sess = ort_session(os.path.join(model_dir, "kitten_tts_mini_v0_8.onnx"))
        z = np.load(os.path.join(model_dir, "voices.npz"), allow_pickle=False)
        self.voices = {k: z[k] for k in z.files}
        self.ph = _espeak()

    def render(self, text, recipe, seed=0):
        text = " ".join(re.sub(r"\[[^\]]*\]", " ", text).split())  # TAGS: this engine has none; drop them
        t = text.strip()
        if t and t[-1] not in ".!?,;:":
            t += ","
        ph = self.ph.phonemize([t])[0]
        ph = " ".join(re.findall(r"\w+|[^\w\s]", ph))
        toks = [0] + [SYMBOLS[c] for c in ph if c in SYMBOLS] + [0]
        blend = recipe.get("kblend") or {recipe["kvoice"]: 1.0}
        tot = sum(blend.values())
        ref_id = min(len(t), 399)
        style = sum(self.voices[n][ref_id:ref_id + 1] * (w / tot) for n, w in blend.items()).astype(np.float32)
        out = self.sess.run(None, {"input_ids": np.array([toks], dtype=np.int64), "style": style,
                                   "speed": np.array([float(recipe.get("speed", 1.0))], dtype=np.float32)})
        a = np.asarray(out[0], dtype=np.float32).reshape(-1)[:-5000]
        return a, SR


if __name__ == "__main__":
    from common import save
    eng = KittenEngine(sys.argv[1])
    t = time.time()
    a, sr = eng.render(sys.argv[3], {"kvoice": sys.argv[4]})
    el = time.time() - t
    save(sys.argv[2], a, sr)
    print(f"{len(a)/sr:.2f}s audio in {el:.2f}s: RTF {el/(len(a)/sr):.3f}")
