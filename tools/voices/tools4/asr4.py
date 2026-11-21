"""Recogniser pass (faster-whisper small.en, int8, 2 threads), time-boxed (BATCH_SECONDS, default 100; exit 3 while
items remain), resumable (an item is skipped when its file's mtime is unchanged).
usage: asr4.py OUT.json ITEMS.json      ITEMS: [{"id", "wav", "text"}]"""
import os, sys, json, time
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
sys.path.insert(0, H)
import numpy as np
from common4 import norm4, wer
def main():
    out, items = sys.argv[1], json.load(open(sys.argv[2]))
    budget = float(os.environ.get("BATCH_SECONDS", "100")); t0 = time.time()
    res = json.load(open(out)) if os.path.exists(out) else {}
    todo = [it for it in items if not (it["id"] in res and res[it["id"]].get("mtime") == os.path.getmtime(it["wav"]))]
    if not todo:
        print("left 0"); return 0
    from faster_whisper import WhisperModel
    sys.path.insert(0, os.path.join(V, "tools"))
    from common import load
    model = WhisperModel(os.path.join(V, "models", "whisper-small.en"), device="cpu", compute_type="int8", cpu_threads=2)
    left = 0
    for i, it in enumerate(todo):
        if time.time() - t0 > budget:
            left = len(todo) - i; break
        a = load(it["wav"], 16000)[0]
        segs, _ = model.transcribe(a, beam_size=5, language="en", condition_on_previous_text=False, word_timestamps=True)
        segs = list(segs)
        hyp = " ".join(s.text.strip() for s in segs)
        r = dict(file=it["wav"], mtime=os.path.getmtime(it["wav"]), text=it.get("text"), asr=hyp,
                 words=[[w.word.strip(), round(w.start, 3), round(w.end, 3), round(w.probability, 3)] for s in segs for w in (s.words or [])],
                 logprob=round(float(np.mean([s.avg_logprob for s in segs])) if segs else -9.0, 3),
                 no_speech=round(float(max([s.no_speech_prob for s in segs] or [1.0])), 3))
        if it.get("text") is not None:
            r["wer"] = round(wer(norm4(it["text"]), norm4(hyp)), 3); r["exact"] = norm4(it["text"]) == norm4(hyp)
        res[it["id"]] = r
        print(it["id"], repr(hyp), r.get("wer"), flush=True)
        if i % 10 == 9:
            json.dump(res, open(out, "w"), indent=1)
    json.dump(res, open(out, "w"), indent=1)
    print("left", left, flush=True)
    return 3 if left else 0
if __name__ == "__main__":
    sys.exit(main())
