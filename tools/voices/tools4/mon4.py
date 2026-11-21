"""The monster's lines as Monster 5 (whisper4.py).
usage: mon4.py cands LINES.json[,LINES2.json] TAKES_DIR CAND_DIR   build one whispered candidate per calm take (+items.json)
       mon4.py pick LINES.json[,..] CAND_DIR ASR.json               choose a take per text -> CAND_DIR/choice.json; list failures
       mon4.py retake LINES.json CAND_DIR ASR.json SEEDS OUT.json   re-render list (new seeds) for texts with no passing take
       mon4.py finals CAND_DIR OUTDIR KIDPICK.json                  every string -> OUTDIR/<id>.wav|mp3 + OUTDIR/mon_final.json
Pick rule: the whispered take (breath in, words, room tone) is heard word for word by the recogniser (strict, see
common4.norm4), then the most confident recognition (highest mean log-probability)."""
import os, sys, json
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
sys.path.insert(0, H)
import numpy as np
from common4 import SR, norm4, write_pair, jload, jsave, ld
from whisper4 import whisper_of, assemble, stats
import plan4
def load_lines(arg):
    L = []
    for p in arg.split(","): L += json.load(open(p))
    return L
def cands(lines, takes, cd):
    os.makedirs(cd, exist_ok=True); its = []
    for x in load_lines(lines):
        wav = os.path.join(takes, x["id"] + ".wav")
        if not os.path.exists(os.path.join(takes, x["id"] + ".json")): continue
        o = os.path.join(cd, x["id"] + ".wav")
        if not (os.path.exists(o) and os.path.getmtime(o) > os.path.getmtime(wav)):
            y, m = assemble(whisper_of(wav), x["id"])
            import soundfile as sf; sf.write(o, y.astype(np.float32), SR, subtype="FLOAT")
        its.append(dict(id=x["id"], wav=o, text=x["plain"], src=wav))
    jsave(os.path.join(cd, "items.json"), its); print(len(its), "candidates")
def choose(lines, cd, asr):
    A = jload(asr, {}); by = {}
    SRC = {i["id"]: i["src"] for i in jload(os.path.join(cd, "items.json"), [])}
    for x in load_lines(lines): by.setdefault(x["plain"], []).append(x)
    ch, fails = {}, []
    for t, xs in by.items():
        ok = [x for x in xs if A.get(x["id"], {}).get("exact")]
        if ok:
            b = max(ok, key=lambda x: A[x["id"]]["logprob"])
            ch[t] = dict(take=b["id"], src=SRC.get(b["id"]), asr=A[b["id"]]["asr"], logprob=A[b["id"]]["logprob"],
                         passed=f"{len(ok)}/{len(xs)}", seed=b["seed"], recipe={k: v for k, v in b["recipe"].items() if k != "ref"},
                         ref=b["recipe"]["ref"], heard_all=[A.get(x["id"], {}).get("asr") for x in xs])
        else:
            fails.append(dict(text=t, heard=[A.get(x["id"], {}).get("asr") for x in xs], takes=len(xs)))
    jsave(os.path.join(cd, "choice.json"), ch); jsave(os.path.join(cd, "fails.json"), fails)
    print(len(ch), "texts chosen;", len(fails), "fail:", [(f["text"], f["heard"]) for f in fails])
    return ch, fails
def retake(lines, cd, asr, seeds, out):
    _, fails = choose(lines, cd, asr)
    base = {x["plain"]: x for x in load_lines(lines)}
    L = []
    for f in fails:
        for sd in [int(s) for s in seeds.split(",")]:
            x = dict(base[f["text"]]); x["id"] = x["id"].rsplit("_s", 1)[0] + f"_s{sd}"; x["seed"] = sd; L.append(x)
    jsave(out, L); print(len(L), "retakes")
# layout per kind (see README): returns (with_breath, head, tail, beat)
def layout(s):
    if s["kind"] == "rest":
        if s["pos"] == "first": return False, 0.06, 0.25, None
        if s["pos"] in ("last", "lastq"): return True, 0.05, 0.12, 0.30
        return True, 0.05, 0.25, 0.30           # alone_after (N12): the line, then the name's own Alone file
    if s.get("id") == "Opening.FunnyMonster": return True, 0.05, 0.25, 0.08
    return True, 0.05, 0.25, 0.30
def finals(cd, out, kidpick):
    import soundfile as sf
    ch = jload(os.path.join(cd, "choice.json"), {}); extra = jload(os.path.join(cd, "choice_extra.json"), {})
    os.makedirs(out, exist_ok=True); rec = []
    for s in plan4.mon_strings():
        c = extra.get(s["id"]) if s["base"] in ("fromL4", "fromL13", "teach") else ch.get(s["text"])
        if s["base"] in ("fromL4", "fromL13", "teach") and not c: c = None
        if not c:
            rec.append(dict(s, made=False, why="no take passed the recogniser")); continue
        wb, head, tail, beat = layout(s)
        w = whisper_of(c["src"], c.get("cut"))
        y, m = assemble(w, s["id"], with_breath=wb, head=head, tail=tail, beat=beat or 0.3)
        write_pair(os.path.join(out, s["id"]), y)
        rec.append(dict(s, made=True, take=c["take"], source=os.path.relpath(c["src"], V), cut=c.get("cut"),
                        take_seed=c.get("seed"), take_recipe=c.get("recipe"), take_ref=os.path.relpath(c["ref"], V) if c.get("ref") else None,
                        candidate_heard=c.get("asr"), candidate_logprob=c.get("logprob"), takes_passed=c.get("passed"),
                        **m, **stats(y, m)))
    jsave(os.path.join(out, "mon_final.json"), rec)
    jsave(os.path.join(out, "items.json"), [dict(id=r["id"], wav=os.path.join(out, r["id"] + ".wav"), text=r["text"]) for r in rec if r["made"]])
    print(sum(r["made"] for r in rec), "of", len(rec), "made; missing:", [r["id"] for r in rec if not r["made"]])
if __name__ == "__main__":
    a = sys.argv
    {"cands": lambda: cands(a[2], a[3], a[4]), "pick": lambda: choose(a[2], a[3], a[4]),
     "retake": lambda: retake(a[2], a[3], a[4], a[5], a[6]), "finals": lambda: finals(a[2], a[3], a[4])}[a[1]]()
