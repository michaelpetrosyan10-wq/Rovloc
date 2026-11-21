"""Chatterbox (full, 0.5B Llama, Resemble AI, MIT) through onnx-community/chatterbox-ONNX (rev 3cab09af), onnxruntime CPU.
Follows the model card's loop; adds sampling (temperature, min_p, top_p) and a runaway cap.
ROVLOC rule: the reference clip is ALWAYS our own render of built-in voices (Kokoro blends, or a Chatterbox take that
was itself made from one), never a recording of a person. The repo's default_voice.wav was deleted unused.
recipe: {"ref": path, "exag": 0.5, "temperature": 0.8, "min_p": 0.05, "top_p": 1.0, "rep": 1.2}"""
import os, sys, time, hashlib
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))
import numpy as np
from common import ort_session, load

SR = 24000
START, STOP = 6561, 6562


def punc_norm(t):
    t = " ".join(t.split())
    if t and t[0].islower():
        t = t[0].upper() + t[1:]
    if t and t[-1] not in ".!?-,…]":
        t += "."
    return t


class CBFullEngine:
    def __init__(self, model_dir, lm="language_model_q4"):
        from tokenizers import Tokenizer
        d = os.path.join(model_dir, "onnx")
        self.enc = ort_session(os.path.join(d, "speech_encoder.onnx"))
        self.emb = ort_session(os.path.join(d, "embed_tokens.onnx"))
        self.lm = ort_session(os.path.join(d, lm + ".onnx"))
        self.dec = ort_session(os.path.join(d, "conditional_decoder.onnx"))
        self.tok = Tokenizer.from_file(os.path.join(model_dir, "tokenizer.json"))
        self.cache_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "out2", "cache")
        os.makedirs(self.cache_dir, exist_ok=True)
        self.kv_names = [i.name for i in self.lm.get_inputs() if "past_key_values" in i.name]

    def cond(self, ref):
        h = hashlib.sha256(open(ref, "rb").read()).hexdigest()[:16]
        p = os.path.join(self.cache_dir, f"cbf_cond_{h}.npz")
        if os.path.exists(p):
            z = np.load(p, allow_pickle=False)
            return z["a"], z["b"], z["c"], z["d"]
        a, _ = load(ref, SR)
        out = self.enc.run(None, {"audio_values": a[None, :].astype(np.float32)})
        np.savez(p, a=out[0], b=out[1], c=out[2], d=out[3])
        return out

    def render(self, text, recipe, seed=0):
        rng = np.random.default_rng(seed)
        temp = float(recipe.get("temperature", 0.8))
        min_p = float(recipe.get("min_p", 0.05))
        top_p = float(recipe.get("top_p", 1.0))
        rep = float(recipe.get("rep", 1.2))
        exag = float(recipe.get("exag", 0.5))
        cond_emb, prompt_token, spk_emb, spk_feat = self.cond(recipe["ref"])
        ids = np.array([self.tok.encode(punc_norm(text)).ids], dtype=np.int64)
        pos = np.where(ids >= START, 0, np.arange(ids.shape[1])[None, :] - 1).astype(np.int64)
        ex = np.array([exag], dtype=np.float32)
        x = self.emb.run(None, {"input_ids": ids, "position_ids": pos, "exaggeration": ex})[0]
        x = np.concatenate([cond_emb, x], axis=1)
        past = {n: np.zeros([1, 16, 0, 64], dtype=np.float32) for n in self.kv_names}
        mask = np.ones((1, x.shape[1]), dtype=np.int64)
        nw = len([w for w in text.split() if not w.startswith("[")])
        ntag = text.count("[")
        max_new = int(recipe.get("max_tokens", 25 * (2.0 + 0.7 * nw + 1.5 * ntag)))
        gen = [START]
        for i in range(max_new):
            out = self.lm.run(None, dict(inputs_embeds=x, attention_mask=mask, **past))
            logits = out[0][0, -1, :].astype(np.float64)
            u = np.unique(np.array(gen))
            s = logits[u]
            logits[u] = np.where(s < 0, s * rep, s / rep)
            if temp <= 0:
                nxt = int(np.argmax(logits))
            else:
                logits = logits / temp
                p = np.exp(logits - logits.max()); p /= p.sum()
                if min_p > 0:
                    p[p < min_p * p.max()] = 0
                if top_p < 1.0:
                    o = np.argsort(-p); cs = np.cumsum(p[o])
                    p[o[np.searchsorted(cs, top_p) + 1:]] = 0
                p /= p.sum()
                nxt = int(rng.choice(len(p), p=p))
            gen.append(nxt)
            if nxt == STOP:
                break
            for j, n in enumerate(self.kv_names):
                past[n] = out[1 + j]
            x = self.emb.run(None, {"input_ids": np.array([[nxt]], dtype=np.int64),
                                    "position_ids": np.array([[i + 1]], dtype=np.int64), "exaggeration": ex})[0]
            mask = np.concatenate([mask, np.ones((1, 1), dtype=np.int64)], axis=1)
        self.last_runaway = gen[-1] != STOP
        self.last_tokens = len(gen) - 1
        speech = np.array([[t for t in gen[1:] if t < START]], dtype=np.int64)
        toks = np.concatenate([prompt_token, speech], axis=1)
        wav = self.dec.run(None, dict(speech_tokens=toks, speaker_embeddings=spk_emb, speaker_features=spk_feat))[0]
        return np.squeeze(wav, 0).astype(np.float32), SR


if __name__ == "__main__":
    from common import save
    eng = CBFullEngine(sys.argv[1])
    t = time.time()
    exag = float(sys.argv[5]) if len(sys.argv) > 5 else 0.5
    a, sr = eng.render(sys.argv[4], {"ref": sys.argv[3], "exag": exag}, seed=int(sys.argv[6]) if len(sys.argv) > 6 else 0)
    el = time.time() - t
    save(sys.argv[2], a, sr)
    print(f"{len(a)/sr:.2f}s audio in {el:.2f}s: RTF {el/(len(a)/sr):.3f} tokens {eng.last_tokens} runaway {eng.last_runaway}")
