"""The name bank in the Monster 5 whisper.
usage: bank4.py cands LINES.json[,..] TAKES_DIR CAND_DIR     whispered candidate per take (+ items.json, text = the name)
       bank4.py pick LINES.json[,..] CAND_DIR ASR.json        per name and shape, the passing take -> CAND_DIR/bank_choice.json
       bank4.py retake LINES.json[,..] CAND_DIR ASR.json SEEDS OUT.json
       bank4.py finals CAND_DIR OUTDIR TAKES_DIR                        four files per name (below) + OUTDIR/bank.json
Two takes per name: "Name?" (q, the rising shape) and "Name." (d, the falling shape), each Danny 3 calm (exag 0.25).
Pass: the recogniser hears the name exactly, or another spelling of the same-sounding name ('variant', flagged) that
is not itself a different name in the bank; then the most confident.
Files per name (all start and end on the same room tone as every monster line):
  Names/<Name>.First  breath in + beat + the q take + 0.20 s room tone   first word before a pause: "{name}? ...",
                      "{name}. ...", "{name}, ..."  (also "{shooter}?" standing alone)
  Names/<Name>.Alone  breath in + beat + the d take + 0.25 s room tone   standing alone: "{name}." (L23, Teleport, N12)
  Names/<Name>.Last   0.05 s room tone + the d take + 0.25 s             last word after a comma: "..., {name}."
  Names/<Name>.LastQ  0.05 s room tone + the q take + 0.25 s             last word after a comma: "..., {name}?"
If one shape has no passing take, the other shape's take is used for its files (noted in bank.json)."""
import os, sys, json
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
sys.path.insert(0, H)
import numpy as np
from common4 import SR, name_check, norm4, write_pair, jload, jsave, same_name
from whisper4 import whisper_of, assemble, stats
from names4 import bank
BANK = {n for n, _ in bank()}
def load_lines(arg):
    L = []
    for p in arg.split(","): L += json.load(open(p))
    return L
def cands(lines, takes, cd):
    import soundfile as sf
    os.makedirs(cd, exist_ok=True); its = []
    for x in load_lines(lines):
        wav = os.path.join(takes, x["id"] + ".wav")
        if not os.path.exists(os.path.join(takes, x["id"] + ".json")): continue
        o = os.path.join(cd, x["id"] + ".wav")
        if not (os.path.exists(o) and os.path.getmtime(o) > os.path.getmtime(wav)):
            y, m = assemble(whisper_of(wav), x["id"], tail=0.2 if x["shape"] == "q" else 0.25)
            sf.write(o, y.astype(np.float32), SR, subtype="FLOAT")
        its.append(dict(id=x["id"], wav=o, text=x["name"]))
    jsave(os.path.join(cd, "items.json"), its); print(len(its), "candidates")
def grade(name, heard):
    from common4 import VARIANTS
    g = name_check(name, heard)
    if g == "variant":
        w = norm4(heard)[0]
        other = [b for b in BANK if b.lower() == w and b != name]
        if other and not any(w in gg and name.lower() in gg for gg in VARIANTS): return "fail"
    return g
def choose(lines, cd, asr):
    A = jload(asr, {}); L = load_lines(lines)
    by = {}
    for x in L: by.setdefault((x["name"], x["shape"]), []).append(x)
    ch, fails = {}, []
    for (nm, sh), xs in sorted(by.items()):
        rows = [(x, A[x["id"]]) for x in xs if x["id"] in A]
        ok = [(x, a, grade(nm, a["asr"])) for x, a in rows]
        ok = [r for r in ok if r[2] != "fail"]
        if ok:
            ok.sort(key=lambda r: (r[2] == "exact", r[1]["logprob"]), reverse=True)
            x, a, g = ok[0]
            ch.setdefault(nm, {"gender": x["gender"]})[sh] = dict(take=x["id"], heard=a["asr"], grade=g, logprob=a["logprob"],
                                                               seed=x["seed"], passed=f"{len(ok)}/{len(rows)}",
                                                               heard_all=[r[1]["asr"] for r in rows])
        else:
            fails.append(dict(name=nm, shape=sh, heard=[a["asr"] for _, a in rows]))
            ch.setdefault(nm, {"gender": xs[0]["gender"]})[sh] = None
    jsave(os.path.join(cd, "bank_choice.json"), ch); jsave(os.path.join(cd, "bank_fails.json"), fails)
    nv = sum(1 for v in ch.values() for k in ("q", "d") if v.get(k) and v[k]["grade"] == "variant")
    print(len(ch), "names;", len(fails), "shape failures;", nv, "variants;", [(f["name"], f["shape"], f["heard"]) for f in fails][:60])
    return ch, fails
def retake(lines, cd, asr, seeds, out):
    _, fails = choose(lines, cd, asr)
    base = {(x["name"], x["shape"]): x for x in load_lines(lines)}; L = []
    for f in fails:
        for sd in [int(s) for s in seeds.split(",")]:
            x = dict(base[(f["name"], f["shape"])]); x["id"] = f"name_{f['name']}_{f['shape']}_s{sd}"; x["seed"] = sd; L.append(x)
    jsave(out, L); print(len(L), "retakes")
def finals(cd, out, takes):
    ch = jload(os.path.join(cd, "bank_choice.json")); rec = {}
    os.makedirs(out, exist_ok=True)
    for nm, c in ch.items():
        q, d = c.get("q"), c.get("d")
        if not q and not d:
            rec[nm] = dict(name=nm, gender=c["gender"], in_bank=False, why="no take heard as the name: the twin plays"); continue
        note = []
        if not q: q = d; note.append("no passing 'Name?' take: First and LastQ use the 'Name.' take")
        if not d: d = q; note.append("no passing 'Name.' take: Alone and Last use the 'Name?' take")
        wq = whisper_of(os.path.join(takes, q["take"] + ".wav")); wd = whisper_of(os.path.join(takes, d["take"] + ".wav"))
        files = {}
        for shape, w, wb, head, tail in (("First", wq, True, 0.05, 0.20), ("Alone", wd, True, 0.05, 0.25),
                                         ("Last", wd, False, 0.05, 0.25), ("LastQ", wq, False, 0.05, 0.25)):
            fid = f"Name.{nm}.{shape}"
            y, m = assemble(w, fid, with_breath=wb, head=head, tail=tail)
            write_pair(os.path.join(out, fid), y)
            files[shape] = dict(id=fid, file=f"names/{fid}.wav", mp3=f"names/{fid}.mp3", **m, **stats(y, m))
        rec[nm] = dict(name=nm, gender=c["gender"], in_bank=True, q=q, d=d, note=note, files=files,
                       flagged=[k for k in ("q", "d") if c.get(k) and c[k]["grade"] == "variant"])
    jsave(os.path.join(out, "bank.json"), rec)
    its = [dict(id=f["id"], wav=os.path.join(out, f["id"] + ".wav"), text=nm) for nm, r in rec.items() if r["in_bank"]
           for k, f in r["files"].items() if k in ("First", "Alone")]
    jsave(os.path.join(out, "items.json"), its)
    print(sum(r["in_bank"] for r in rec.values()), "of", len(rec), "names in the bank")
if __name__ == "__main__":
    a = sys.argv
    {"cands": lambda: cands(a[2], a[3], a[4]), "pick": lambda: choose(a[2], a[3], a[4]),
     "retake": lambda: retake(a[2], a[3], a[4], a[5], a[6]), "finals": lambda: finals(a[2], a[3], a[4])}[a[1]]()
