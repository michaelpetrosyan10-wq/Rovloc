"""Board 3 plan: a new FIRST section (Monster 7, 8, 9: five lines each), then Monster 4-6 for comparison, then the kids
(Danny 1, Kayla 1, Marcus 1 marked chosen).  usage: plan_board3.py PLAN2.json FINAL3_DIR OUT_PLAN.json"""
import os, sys, json
p2 = json.load(open(sys.argv[1])); F = sys.argv[2]
LINES = [("w", "Wait up, you guys."), ("s", "Is it still on me?"), ("f", "You saw it first."), ("c", "So cute."),
         ("d", "It's me. It's Danny.")]
GREY = {
 "7": "Danny's own line played slower, like a slowed-down tape: his pitch and his throat drop together, about 4 notes. The whisper of Monster 4 underneath.",
 "8": "Slower still, about 5 and a half notes down, with a quiet shadow of the same words an octave lower. A breath first. A small dark room.",
 "9": "A different, naturally deep voice says the words slowly, and Danny's own voice follows a moment behind it, very quietly: two voices, one mouth.",
}
deep = dict(id="deeper", nav="Monster 7-9", title="Monster, deeper: 7, 8, 9",
            note="Use headphones. Monster 4, 5 and 6 are below to compare.", cands=[])
for v in ("7", "8", "9"):
    deep["cands"].append(dict(label=f"Monster {v}", grey=GREY[v], items=[
        dict(src=os.path.join(F, f"monster{v}_{l}.mp3"), name=f"monster{v}_{l}", text=t) for l, t in LINES]))
secs = {s["id"]: s for s in p2["sections"]}
mon = dict(secs["monster"]); mon["nav"] = "Monster 4-6"; mon["title"] = "Monster 4, 5, 6 (last time's, to compare)"
mon["note"] = "Use headphones."
kids = []
for k in ("danny", "kayla", "marcus"):
    s = dict(secs[k])
    for c in s["cands"]:
        if c["label"].endswith(" 1"):
            c["chosen"] = True
    kids.append(s)
foot = list(p2["footer"])
foot[-1] = ("The monster versions are our own processing of Danny's lines: played slower (plain resampling, like a slowed "
            "tape), a whisper made from the line itself, a quiet copy an octave lower, a synthetic breath and synthetic rooms. "
            "Monster 9's deep voice is a mix of two of Kokoro's built-in voices, spoken by Chatterbox. "
            "Checked with Whisper (MIT) through faster-whisper (MIT).")
json.dump(dict(sections=[deep, mon] + kids, footer=foot), open(sys.argv[3], "w"), indent=1)
print("ok")
