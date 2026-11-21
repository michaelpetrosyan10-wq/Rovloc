"""Monster lines the script builds from the kids' opening takes (monster-lines.md 4 and 6):
  Opening.FunnyMonster (L19) and Mon.L11 "Is something funny?" = the last three words of the chosen L4 take (teacher voice)
  Mon.L47 "Is something funny, you guys?" = a take in the same teacher manner (L4's chosen reference and settings);
          the script's rule is "built from the teacher-voice take", and L4 has no "you guys", so this is the closest
  Opening.SoCuteBack (L21) "So cute." = the last two words of the chosen L13 take (NOT slowed: no time-stretch);
          a calm "So cute." take is rendered as the fallback
usage: extra4.py plan KIDPICK.json OUTDIR                               -> OUTDIR/lines_extra.json
       extra4.py cands KIDPICK.json KIDS_TAKES KIDS_MEASURE.json EXTRA_DIR CAND_DIR
       extra4.py pick CAND_DIR ASR.json                                -> CAND_DIR/choice_extra.json"""
import os, sys, json
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
sys.path.insert(0, H)
import numpy as np
import soundfile as sf
from common4 import SR, norm4, ld, frame_db, jload, jsave
from whisper4 import whisper_of, assemble
import plan4
def chosen(kp, n):
    return next(r for r in jload(kp)["lines"] if r["L"] == n)
def plan(kp, out):
    l4 = chosen(kp, 4); ref = os.path.join(V, l4["ref_file"]); ex = l4["settings"]["exaggeration"]
    L = [dict(id=f"teach47_s{sd}", text="is something funny, you guys?", plain="Is something funny, you guys?", engine="cbfull",
              recipe={"ref": ref, "exag": ex}, seed=sd) for sd in (1, 2, 3)]
    L += [dict(id=f"socute_s{sd}", text="So cute.", plain="So cute.", engine="cbfull",
               recipe={"ref": plan4.REF("danny2"), "exag": 0.25}, seed=sd) for sd in (1, 2)]
    jsave(os.path.join(out, "lines_extra.json"), L); print(len(L), "extra lines")
def cut_at(path, words, first_word_index):
    x = ld(path); hop = int(0.005 * SR)
    a = words[first_word_index - 1][2]; b = words[first_word_index][1]
    lo, hi = min(a, b) - 0.04, max(a, b) + 0.03
    i0, i1 = max(0, int(lo * SR)), int(hi * SR)
    seg = x[i0:i1]; m = len(seg) // hop
    e = (seg[:m * hop].reshape(m, hop) ** 2).mean(axis=1)
    t = (i0 + int(np.argmin(e)) * hop + hop // 2) / SR
    return [round(t, 3), None]
def find(words, seq):
    w = [norm4(x[0]) for x in words]
    for i in range(len(w) - len(seq) + 1):
        if all(w[i + k] == [seq[k]] for k in range(len(seq))): return i
    return None
def cands(kp, kt, km, ed, cd):
    M = jload(km); P = jload(kp)["lines"]; os.makedirs(cd, exist_ok=True); its = []
    for n, seq, text, tag in ((4, ["is", "something", "funny"], "Is something funny?", "cutL4"),
                              (13, ["so", "cute"], "So cute.", "cutL13")):
        r = chosen(kp, n)
        order = [r["take"]] + [t["take"] for t in r["takes"] if t["word_for_word"] and t["take"] != r["take"]]
        for tk in order:
            words = M[tk]["words"]; i = find(words, seq)
            if not i: continue
            c = cut_at(os.path.join(kt, tk + ".wav"), words, i)
            o = os.path.join(cd, f"{tag}_{tk}.wav")
            y, m = assemble(whisper_of(os.path.join(kt, tk + ".wav"), c), f"{tag}_{tk}")
            sf.write(o, y.astype(np.float32), SR, subtype="FLOAT")
            its.append(dict(id=f"{tag}_{tk}", wav=o, text=text, src=os.path.join(kt, tk + ".wav"), cut=c, chosen=tk == r["take"]))
    for x in jload(os.path.join(ed, "lines_extra.json")):
        wav = os.path.join(ed, x["id"] + ".wav")
        if not os.path.exists(wav): continue
        o = os.path.join(cd, x["id"] + ".wav"); y, m = assemble(whisper_of(wav), x["id"])
        sf.write(o, y.astype(np.float32), SR, subtype="FLOAT")
        its.append(dict(id=x["id"], wav=o, text=x["plain"], src=wav, cut=None, seed=x["seed"],
                        recipe={k: v for k, v in x["recipe"].items() if k != "ref"}, ref=x["recipe"]["ref"]))
    jsave(os.path.join(cd, "items.json"), its); print(len(its), "extra candidates")
def pick(cd, asr):
    A = jload(asr, {}); its = jload(os.path.join(cd, "items.json")); ch = {}
    def best(pref, prefer_chosen=True):
        ok = [i for i in its if i["id"].startswith(pref) and A.get(i["id"], {}).get("exact")]
        if not ok: return None
        ok.sort(key=lambda i: ((i.get("chosen", False) if prefer_chosen else 0), A[i["id"]]["logprob"]), reverse=True)
        i = ok[0]
        return dict(take=i["id"], src=i["src"], cut=i.get("cut"), asr=A[i["id"]]["asr"], logprob=A[i["id"]]["logprob"],
                    seed=i.get("seed"), recipe=i.get("recipe"), ref=i.get("ref"), from_chosen_take=i.get("chosen"),
                    passed=f"{len(ok)}/{len([j for j in its if j['id'].startswith(pref)])}")
    l4 = best("cutL4_"); l13 = best("cutL13_") or best("socute_"); t47 = best("teach47_")
    for k, v in (("Opening.FunnyMonster", l4), ("Mon.L11", l4), ("Mon.L47", t47), ("Opening.SoCuteBack", l13)):
        if v: ch[k] = v
    jsave(os.path.join(cd, "choice_extra.json"), ch)
    print({k: (v["take"], v["asr"], v.get("from_chosen_take")) for k, v in ch.items()})
    print("heard:", {i["id"]: A.get(i["id"], {}).get("asr") for i in its})
if __name__ == "__main__":
    a = sys.argv
    if a[1] == "plan": plan(a[2], a[3])
    elif a[1] == "cands": cands(*a[2:7])
    else: pick(a[2], a[3])
