"""Chatterbox-Turbo (Resemble AI, MIT) through its official ONNX export, on onnxruntime CPU.

The model speaks in the voice of a reference clip. ROVLOC rule: the reference is ALWAYS one of our own renders of a
built-in Kokoro voice (or a blend of them), never a recording of a person.
voice recipe: {"ref": "<path to our reference wav>", "temperature": 0.8, "top_p": 0.95, "top_k": 1000, "rep": 1.2}
"""
import os, sys, time, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from common import ort_session, load

SR = 24000
START, STOP, SIL = 6561, 6562, 4299


def punc_norm(t):
    t = " ".join(t.split())
    if t and t[0].islower():
        t = t[0].upper() + t[1:]
    if t and t[-1] not in ".!?-,…]":
        t += "."
    return t


class CBTurboEngine:
    def __init__(self, model_dir, lm="language_model_q4", emb="embed_tokens_quantized",
                 enc="speech_encoder_quantized", dec="conditional_decoder"):
        from tokenizers import Tokenizer
        d = os.path.join(model_dir, "onnx")
        self.enc = ort_session(os.path.join(d, enc + ".onnx"))
        self.emb = ort_session(os.path.join(d, emb + ".onnx"))
        self.lm = ort_session(os.path.join(d, lm + ".onnx"))
        self.dec = ort_session(os.path.join(d, dec + ".onnx"))
        self.tok = Tokenizer.from_file(os.path.join(model_dir, "tokenizer.json"))
        self.cache_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "out", "cache")
        os.makedirs(self.cache_dir, exist_ok=True)
        self.kv_names = [i.name for i in self.lm.get_inputs() if "past_key_values" in i.name]

    def cond(self, ref):
        h = hashlib.sha256(open(ref, "rb").read()).hexdigest()[:16]
        p = os.path.join(self.cache_dir, f"cb_cond_{h}.npz")
        if os.path.exists(p):
            z = np.load(p, allow_pickle=False)
            return z["cond_emb"], z["prompt_token"], z["spk_emb"], z["spk_feat"]
        a, _ = load(ref, SR)
        a = a[None, :].astype(np.float32)
        cond_emb, prompt_token, spk_emb, spk_feat = self.enc.run(None, {"audio_values": a})
        np.savez(p, cond_emb=cond_emb, prompt_token=prompt_token, spk_emb=spk_emb, spk_feat=spk_feat)
        return cond_emb, prompt_token, spk_emb, spk_feat

    def render(self, text, recipe, seed=0):
        rng = np.random.default_rng(seed)
        temp = float(recipe.get("temperature", 0.8))
        top_p = float(recipe.get("top_p", 0.95))
        top_k = int(recipe.get("top_k", 1000))
        rep = float(recipe.get("rep", 1.2))
        cond_emb, prompt_token, spk_emb, spk_feat = self.cond(recipe["ref"])
        ids = np.array([self.tok.encode(punc_norm(text)).ids], dtype=np.int64)
        gen = [START]
        x = self.emb.run(None, {"input_ids": ids})[0]
        x = np.concatenate([cond_emb, x], axis=1)
        L = x.shape[1]
        past = {n: np.zeros([1, 16, 0, 64], dtype=np.float32) for n in self.kv_names}
        mask = np.ones((1, L), dtype=np.int64)
        pos = np.arange(L, dtype=np.int64)[None, :]
        # as in the model card: conditioning + text, then one speech token per step (START is never fed)
        # speech tokens run at 25 per second; allow ~0.6 s per word + 1.5 s per tag + 2 s, then call it a runaway
        nw = len([w for w in text.split() if not w.startswith("[")])
        ntag = text.count("[")
        max_new = int(recipe.get("max_tokens", 25 * (2.0 + 0.6 * nw + 1.5 * ntag)))
        for i in range(max_new):
            out = self.lm.run(None, dict(inputs_embeds=x, attention_mask=mask, position_ids=pos, **past))
            logits = out[0][0, -1, :].astype(np.float64)
            # repetition penalty over generated speech tokens
            u = np.unique(np.array(gen))
            s = logits[u]
            logits[u] = np.where(s < 0, s * rep, s / rep)
            if temp <= 0:
                nxt = int(np.argmax(logits))
            else:
                logits = logits / temp
                if top_k and top_k < len(logits):
                    kth = np.partition(logits, -top_k)[-top_k]
                    logits[logits < kth] = -np.inf
                p = np.exp(logits - logits.max())
                p /= p.sum()
                order = np.argsort(-p)
                cs = np.cumsum(p[order])
                keep = order[: max(1, int(np.searchsorted(cs, top_p) + 1))]
                pk = p[keep] / p[keep].sum()
                nxt = int(rng.choice(keep, p=pk))
            gen.append(nxt)
            if nxt == STOP:
                break
            for j, n in enumerate(self.kv_names):
                past[n] = out[1 + j]
            x = self.emb.run(None, {"input_ids": np.array([[nxt]], dtype=np.int64)})[0]
            mask = np.concatenate([mask, np.ones((1, 1), dtype=np.int64)], axis=1)
            pos = pos[:, -1:] + 1
        self.last_runaway = gen[-1] != STOP
        self.last_tokens = len(gen) - 1
        speech = np.array([[t for t in gen[1:] if t < START]], dtype=np.int64)
        toks = np.concatenate([prompt_token, speech, np.full((1, 3), SIL, dtype=np.int64)], axis=1)
        wav = self.dec.run(None, dict(speech_tokens=toks, speaker_embeddings=spk_emb, speaker_features=spk_feat))[0]
        wav = wav.squeeze(0).astype(np.float32)
        return wav, SR


if __name__ == "__main__":
    from common import save
    eng = CBTurboEngine(sys.argv[1])
    t = time.time()
    a, sr = eng.render(sys.argv[4], {"ref": sys.argv[3]}, seed=int(sys.argv[5]) if len(sys.argv) > 5 else 0)
    el = time.time() - t
    save(sys.argv[2], a, sr)
    print(f"{len(a)/sr:.2f}s audio in {el:.2f}s: RTF {el/(len(a)/sr):.3f}")
