"""Round 3 render lists.  usage: plan3.py probe|mon|prod|deepref|deep OUTDIR
probe  : Kokoro, each allowed male voice + candidate blends, one slow sentence (pick a naturally deep blend)
mon    : Danny 1 calm base takes for the monster (cbfull exag 0.25, ref danny1_g2), 5 lines x 3 seeds
prod   : the opening's 18 kid lines (opening-v3.md 6 / monster-lines.md 6), Turbo + chosen gen-2 refs, 3 seeds
deepref: the deep blend's gen-1 (Kokoro) and gen-2 (Chatterbox full) reference
deep   : the deep voice acting the 5 monster lines slowly (cbfull exag 0.25, ref deep_g2), 3 seeds"""
import os, sys, json
V = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BANNED = {"af_sky", "af_bella", "am_onyx", "af_sarah", "bm_george", "bm_lewis", "am_santa"}
REF = lambda r: os.path.join(V, "out2", "refs", f"{r}_g2.wav")
MON = [("w", "Wait up, you guys."), ("s", "Is it still on me?"), ("f", "You saw it first."), ("c", "So cute."),
       ("d", "It's me. It's Danny.")]
# the deep blend (chosen from the probe, see out3/probe_m.json); our own reference text, calm and slow
DEEP = {"am_michael": 0.6, "am_echo": 0.4}   # probe_deepF: f0 107.6 Hz, jitter 30 c (out3/probe_m.json)
DEEP_SPEED = 0.86
DEEP_TEXT = ("Hey. It's okay. Come here, come on. I'm not going anywhere. We can just wait right here, "
             "for as long as it takes. Nobody is in a hurry. Take your time.")
# opening-v3.md line table, kid lines only: L, id, speaker, model text (monster-lines.md 6, lower case), slot, words
PROD = [
 (1, "Opening.Twelve", "kayla", "twelve percent. on true-or-false.", 2.2, "Twelve percent. On true-or-false."),
 (2, "Opening.Coin", "danny", "marcus. a coin gets fifty.", 1.9, "Marcus. A coin gets fifty."),
 (3, "Opening.Studied", "marcus", "i studied for that!", 1.5, "I studied for that!"),
 (4, "Opening.FunnyTeacher", "teach", "mister reyes. is something funny?", 2.3, "Mister Reyes. Is something funny?"),
 (5, "Opening.NotYet", "danny", "i said: not yet, sir.", 1.9, "I said: not yet, sir."),
 (6, "Opening.Hat", "kayla", "does that hat even come off?", 2.2, "Does that hat even come off?"),
 (7, "Opening.MoreHat", "marcus", "it's just more hat under there.", 2.2, "It's just more hat under there."),
 (8, "Opening.Sals", "marcus", "sal's at four!", 1.1, "Sal's at four!"),
 (9, "Opening.LastOne", "kayla", "last one buys!", 1.1, "Last one buys!"),
 (10, "Opening.WaitUp", "danny", "wait up, you guys!", 1.5, "Wait up, you guys!"),
 (11, "Opening.Whoa", "danny", "whoa. what is that?", 1.5, "Whoa. What is THAT?"),
 (12, "Opening.LittleGuy", "danny", "hey, little guy.", 1.2, "Hey, little guy."),
 (13, "Opening.SoCute", "danny", "bro. look at it. this is so cute.", 3.0, "Bro. Look at it. This is SO cute."),
 (14, "Opening.ThatFace", "danny", "what? what's that face?", 1.6, "What? What's that face?"),
 (15, "Opening.LikesMe", "danny", "hey. it likes me.", 1.6, "Hey. It likes me."),
 (16, "Opening.Cold", "danny", "ha. it's cold.", 1.3, "Ha. It's cold."),
 (17, "Opening.StillOnMe", "danny", "is it still on me?", 2.0, "Is it still on me?"),
 (18, "Opening.Guys", "danny", "guys?", 1.0, "Guys?"),
]
SPK_REF = {"danny": "danny1", "teach": "teach1", "kayla": "kayla1", "marcus": "marcus1"}
TURBO = {"temperature": 0.8, "top_p": 0.95, "top_k": 1000, "rep": 1.2}   # round 2's Danny/Kayla/Marcus 1 settings

def main():
    mode, out = sys.argv[1], sys.argv[2]
    L = []
    if mode == "probe":
        vs = ["am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_puck", "bm_daniel", "bm_fable"]
        blends = {v: {v: 1.0} for v in vs}
        blends["deepA"] = {"am_michael": 0.5, "am_fenrir": 0.5}
        blends["deepB"] = {"am_michael": 0.5, "am_fenrir": 0.3, "am_eric": 0.2}
        blends["deepC"] = {"am_michael": 0.6, "bm_daniel": 0.4}
        blends["deepD"] = {"am_fenrir": 0.5, "bm_daniel": 0.3, "am_liam": 0.2}
        for k, b in blends.items():
            assert not (set(b) & BANNED), b
            L.append(dict(id=f"probe_{k}", text="It's me. It's Danny. You saw it first. Wait up, you guys.",
                          engine="kokoro", recipe={"blend": b, "speed": DEEP_SPEED}, seed=0))
    elif mode == "mon":
        for lid, t in MON:
            for sd in (1, 2, 3):
                L.append(dict(id=f"calm_{lid}_s{sd}", line=lid, text=t, engine="cbfull",
                              recipe={"ref": REF("danny1"), "exag": 0.25}, seed=sd))
    elif mode == "deepref":
        assert not (set(DEEP) & BANNED)
        L.append(dict(id="deep_g1", text=DEEP_TEXT, engine="kokoro", recipe={"blend": DEEP, "speed": DEEP_SPEED}, seed=0))
    elif mode == "deepref2":
        L.append(dict(id="deep_g2", text=DEEP_TEXT, engine="cbfull",
                      recipe={"ref": os.path.join(V, "out3", "deep", "deep_g1.wav"), "exag": 0.4, "max_tokens": 600}, seed=1))
    elif mode == "deep":
        for lid, t in MON:
            for sd in (1, 2, 3):
                L.append(dict(id=f"deep_{lid}_s{sd}", line=lid, text=t, engine="cbfull",
                              recipe={"ref": os.path.join(V, "out3", "deep", "deep_g2.wav"), "exag": 0.25}, seed=sd))
    elif mode == "deepmore":
        # Monster 9 "f" and "c" came out only ~1.5 st under Monster 4: four more takes each, same settings
        for lid, t in MON:
            if lid in ("f", "c"):
                for sd in (4, 5, 6, 7):
                    L.append(dict(id=f"deep_{lid}_s{sd}", line=lid, text=t, engine="cbfull",
                                  recipe={"ref": os.path.join(V, "out3", "deep", "deep_g2.wav"), "exag": 0.25}, seed=sd))
    elif mode == "prod":
        for (n, lid, spk, text, slot, words) in PROD:
            for sd in (1, 2, 3):
                L.append(dict(id=f"L{n:02d}_s{sd}", L=n, line_id=lid, speaker="danny" if spk == "teach" else spk,
                              ref_id=SPK_REF[spk], text=text, plain=words, slot=slot, engine="cbturbo",
                              recipe=dict(ref=REF(SPK_REF[spk]), **TURBO), seed=sd))
    elif mode == "prodre":
        # re-takes for lines whose first three takes failed (out3/prodtakes/measure.json): same words; punctuation only
        # where a full stop made a pause the slot cannot hold; L4 as opening-v3.md asks ("mister ray-ess"); L8 capitalised
        RE = {2: "marcus, a coin gets fifty.", 4: "mister ray-ess. is something funny?", 8: "Sal's at four!",
              9: "last one buys!", 11: "whoa, what is that?", 15: "hey, it likes me."}
        base = {x["L"]: x for x in json.load(open(os.path.join(out, "lines_prod.json")))}
        L = list(json.load(open(os.path.join(out, "lines_prod.json"))))
        for n, t in RE.items():
            for sd in (4, 5, 6):
                x = dict(base[n]); x.update(id=f"L{n:02d}_r{sd}", text=t, seed=sd, retake=True); L.append(x)
        mode = "prod_all"
    os.makedirs(out, exist_ok=True)
    json.dump(L, open(os.path.join(out, f"lines_{mode}.json"), "w"), indent=1)
    print(len(L), "lines")

if __name__ == "__main__":
    main()
