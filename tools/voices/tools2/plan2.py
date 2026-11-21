"""Compose the finishing list and the page plan.  usage: plan2.py PICKS.json OUT2DIR"""
import os, sys, json
picks = json.load(open(sys.argv[1])); O = sys.argv[2]
V = os.path.dirname(O.rstrip("/"))
sys.path.insert(0, os.path.join(V, "tools2"))
from cast2 import LINES
TXT = {l[0]: (l[2], l[3]) for l in LINES}
H = os.path.join(V, "dl", "higg")
fin, plan = [], {"sections": []}
def local(cid, label, grey, lids):
    items = []
    for lid in lids:
        k = f"{cid}_{lid}"
        if k not in picks: continue
        name = f"{cid}_{lid}"
        fin.append(dict(out=name, src=os.path.join(O, "takes", picks[k]["take"] + ".wav"), lufs=-20.0))
        items.append(dict(src=os.path.join(O, "final", name + ".mp3"), name=name, text=TXT[lid][0], dir=TXT[lid][1]))
    return dict(label=label, grey=grey, items=items)
def higg(label, grey, rows):
    items = []
    for f, lid in rows:
        name = "h_" + f
        fin.append(dict(out=name, src=os.path.join(H, f + ".mp3"), lufs=-20.0))
        items.append(dict(src=os.path.join(O, "final", name + ".mp3"), name=name, text=TXT[lid][0], dir=TXT[lid][1]))
    return dict(label=label, grey=grey, items=items)
D = ["d1", "d2", "d3", "d4", "d5", "d6"]
plan["sections"].append(dict(id="danny", title="Danny, 16", cands=[
    local("danny_t1", "Danny 1", "Made on our computer.", D),
    local("danny_f1", "Danny 2", "Same voice as Danny 1, made with a bigger engine.", D),
    local("danny_f2", "Danny 3", "Made on our computer with the bigger engine.", D),
    higg("Danny H1", "Made with Higgsfield (a stock voice called Kevin). Only two lines.",
         [("h1_danny_kevin_el_bro", "d5"), ("h3_danny_kevin_el_coin", "d1")]),
    higg("Danny H2", "Made with Higgsfield (a stock voice called Leo). Only one line.", [("h2_danny_leo_el_bro", "d5")])]))
plan["sections"].append(dict(id="kayla", title="Kayla, 16", cands=[
    local("kayla_t1", "Kayla 1", "Made on our computer.", ["k1", "k2"]),
    local("kayla_f1", "Kayla 2", "Same voice as Kayla 1, made with a bigger engine.", ["k1", "k2"]),
    local("kayla_f2", "Kayla 3", "Made on our computer with the bigger engine.", ["k1", "k2"]),
    higg("Kayla H1", "Made with Higgsfield (a stock voice called Sloane). Only one line.", [("h4_kayla_sloane_el_twelve", "k1")])]))
plan["sections"].append(dict(id="marcus", title="Marcus, 16", cands=[
    local("marcus_t1", "Marcus 1", "Made on our computer.", ["m1", "m2"]),
    local("marcus_f1", "Marcus 2", "Same voice as Marcus 1, made with a bigger engine.", ["m1", "m2"]),
    higg("Marcus H1", "Made with Higgsfield (a stock voice called Marcus). Only one line.", [("h5_marcus_marcus_el_studied", "m1")])]))
MON = [("w", "Wait up, you guys."), ("s", "Is it still on me?"), ("f", "You saw it first."), ("c", "So cute.")]
mons = []
for n, mode, grey, lufs in ((4, "late", "Danny's voice, too calm and a little slow, with a whisper of the same words just behind it.", -20.0),
                            (5, "close", "A dry whisper right next to your ear, with a breath first.", -22.0),
                            (6, "far", "From far down a dark corridor. The last word comes back on its own.", -20.0)):
    items = []
    for lid, t in MON:
        name = f"monster{n}_{lid}"
        src = os.path.join(O, "mon", "fx", name + ".wav")
        if not os.path.exists(src): continue
        fin.append(dict(out=name, src=src, lufs=lufs, trim=False))
        tt = t if mode != "far" else t + " ... " + t.rstrip(".?").split()[-1].lower() + "."
        items.append(dict(src=os.path.join(O, "final", name + ".mp3"), name=name, text=tt))
    mons.append(dict(label=f"Monster {n}", grey=grey, items=items))
plan["sections"].append(dict(id="monster", title="Monster, Danny's voice gone wrong",
                             note="Use headphones. Monster 1, 2 and 3 were on the first page.", cands=mons))
plan["footer"] = [
    "Every voice here is a computer voice. No real person's voice was copied, and nobody was recorded for this page.",
    "Made on our computer with Chatterbox and Chatterbox Turbo by Resemble AI (MIT licence). Their voices were designed by us "
    "from the built-in voices of Kokoro 82M by hexgrad (Apache-2.0; its training data includes Koniwa, CC BY 3.0, and SIWIS, CC BY 4.0). "
    "Pronunciation for Kokoro by eSpeak NG (GPL-3.0), used only on our computer; none of it is in these files.",
    "The H voices were made with Higgsfield's stock voices (text to speech, ElevenLabs engine) on the game owner's account.",
    "The monster versions are our own mixing of Danny's lines: a whisper made from the line itself, a synthetic corridor echo, "
    "and a repeat of the last word. Checked with Whisper (MIT) through faster-whisper (MIT)."]
json.dump(fin, open(os.path.join(O, "finish_list.json"), "w"), indent=1)
json.dump(plan, open(os.path.join(O, "plan2.json"), "w"), indent=1)
print(len(fin), "files")
