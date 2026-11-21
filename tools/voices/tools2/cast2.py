"""Round 2 cast.  usage: cast2.py refs|takes OUTDIR
refs : Kokoro gen-1 references (built-in voices and blends ONLY, no WORLD shift) and Chatterbox-full gen-2 references
       (the same text re-spoken by Chatterbox from the gen-1 clip: a Chatterbox voice, still made only from Kokoro voices)
takes: every audition line x engine x reference x seed."""
import os, sys, json
V = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BANNED = {"af_sky", "af_bella", "am_onyx", "af_sarah", "bm_george", "bm_lewis"}
# our own reference texts, written to be said with life (questions, exclamations, a turn in the middle)
RT = {
 "danny": "Okay, wait, wait. You have to hear this! So Marcus walks in, totally serious, right? And the whole class just loses it. I couldn't even breathe!",
 "teacher": "Settle down, everyone. Settle down. Is something funny? No? Then we will begin. Page forty, please. Quietly.",
 "kayla": "Sure. Great plan. Really. No, I mean it, it's fine. I just think we shouldn't poke the weird thing in the hallway. Call me crazy.",
 "marcus": "Dude, no way! I swear I knew that one! Come on, that's so not fair, man. I actually studied this time! Ha! Seriously!",
}
REFS = {   # id: (text key, kokoro blend, speed)
 "danny1":  ("danny",  {"am_eric": 0.5, "am_liam": 0.5}, 1.1),
 "danny2":  ("danny",  {"am_puck": 0.6, "am_eric": 0.4}, 1.1),
 "teach1":  ("teacher", {"am_eric": 0.35, "am_liam": 0.35, "am_adam": 0.3}, 0.82),
 "kayla1":  ("kayla",  {"af_river": 0.6, "af_jessica": 0.4}, 1.0),
 "kayla2":  ("kayla",  {"af_kore": 0.5, "af_jessica": 0.5}, 1.0),
 "marcus1": ("marcus", {"am_fenrir": 0.6, "am_echo": 0.4}, 1.08),
}
for _, b, _s in REFS.values():
    assert not (set(b) & BANNED), b
# line: id, speaker, text, direction, exaggeration (full), turbo text (tags Turbo knows), ref override
LINES = [
 ("d1", "danny", "Marcus. A coin gets fifty.", "quick, warm", 0.55, None, None),
 ("d2", "danny", "Mister Reyes. Is something funny?", "doing a teacher's voice, low and slow", 0.3, None, "teach"),
 ("d3", "danny", "Wait up, you guys!", "calling", 0.85, None, None),
 ("d4", "danny", "Hey, little guy.", "soft", 0.35, None, None),
 ("d5", "danny", "Bro. Look at it. This is so cute.", "delighted", 0.75, None, None),
 ("d6", "danny", "Is it still on me?", "afraid, quiet", 0.6, None, None),
 ("k1", "kayla", "Twelve percent. On true-or-false.", "dry", 0.35, None, None),
 ("k2", "kayla", "Does that hat even come off?", "dry, sharp", 0.45, None, None),
 ("m1", "marcus", "I studied for that!", "protesting", 0.85, None, None),
 ("m2", "marcus", "It's just more hat under there.", "laughing", 0.7, "[laugh] It's just more hat under there.", None),
]
# acted variants tried on the full model with its own sound tags (kept only if the recogniser still hears every word)
TAGGED = {"m2": "[laughter] It's just more hat under there.", "d6": "[inhale] Is it still on me?",
          "d5": "Bro. [giggle] Look at it. This is so cute."}
# candidates: label -> (engine, speaker, ref id per speaker)
CANDS = {
 "danny_f1": ("cbfull", "danny", "danny1"), "danny_f2": ("cbfull", "danny", "danny2"), "danny_t1": ("cbturbo", "danny", "danny1"),
 "kayla_f1": ("cbfull", "kayla", "kayla1"), "kayla_f2": ("cbfull", "kayla", "kayla2"), "kayla_t1": ("cbturbo", "kayla", "kayla1"),
 "marcus_f1": ("cbfull", "marcus", "marcus1"), "marcus_t1": ("cbturbo", "marcus", "marcus1"),
}
SEEDS = [1, 2, 3]

def ref_path(rid, gen):
    return os.path.join(V, "out2", "refs", f"{rid}_g{gen}.wav")

def main():
    mode, out = sys.argv[1], sys.argv[2]
    L = []
    if mode == "refs":
        for rid, (tk, blend, sp) in REFS.items():
            L.append(dict(id=f"{rid}_g1", text=RT[tk], engine="kokoro", recipe={"blend": blend, "speed": sp}, seed=0))
    elif mode == "refs2":
        for rid, (tk, blend, sp) in REFS.items():
            for s in (1, 2):
                L.append(dict(id=f"{rid}_g2s{s}", text=RT[tk], engine="cbfull",
                              recipe={"ref": ref_path(rid, 1), "exag": 0.65, "max_tokens": 600}, seed=s))
    elif mode == "takes":
        gen = int(sys.argv[3]) if len(sys.argv) > 3 else 2
        for cid, (eng, spk, rid) in CANDS.items():
            for (lid, s2, text, dirn, ex, ttext, rover) in LINES:
                if s2 != spk:
                    continue
                r = rid if rover is None else rid.replace(spk, rover)
                if not os.path.exists(ref_path(r, gen)):
                    r = rid
                for sd in SEEDS:
                    if eng == "cbfull":
                        L.append(dict(id=f"{cid}_{lid}_s{sd}", line=lid, cand=cid, text=text, engine=eng,
                                      recipe={"ref": ref_path(r, gen), "exag": ex}, seed=sd))
                        if lid in TAGGED and sd <= 2:
                            L.append(dict(id=f"{cid}_{lid}_tag_s{sd}", line=lid, cand=cid, text=TAGGED[lid], plain=text,
                                          engine=eng, recipe={"ref": ref_path(r, gen), "exag": ex}, seed=sd))
                    else:
                        L.append(dict(id=f"{cid}_{lid}_s{sd}", line=lid, cand=cid, text=ttext or text, plain=text,
                                      engine=eng, recipe={"ref": ref_path(r, gen), "temperature": 0.8, "top_p": 0.95,
                                                          "top_k": 1000, "rep": 1.2}, seed=sd))
    os.makedirs(out, exist_ok=True)
    json.dump(L, open(os.path.join(out, f"lines_{mode}.json"), "w"), indent=1)
    print(len(L), "lines")

if __name__ == "__main__":
    main()
