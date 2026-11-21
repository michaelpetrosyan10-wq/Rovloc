"""The audition: who speaks, with which voice recipe, which lines. Writes the render list and the board plan.

usage: cast.py OUT_DIR REFS_DIR
  OUT_DIR/lines.json    every take to render (render.py input)
  OUT_DIR/plan.json     the board: characters -> candidates -> lines (each with its takes and its processing)
  REFS_DIR/lines.json   the reference clips to render first (render.py input; Kokoro built-in voices only)
All lines are our own, provisional, written for this audition (the opening's lines are spec v2 2.4's; the PA line is
spec v2 S14's "LOCKDOWN. LOCKDOWN." and nothing more).
Voice rule: Kokoro built-in voices, blends of them and our own WORLD processing of them. Never af_sky, af_bella or
am_onyx (review M5: names that match commercial voices, one of them in a public likeness dispute).
"""
import os, sys, json

TAKE_SEEDS = [1, 2]          # Chatterbox is sampled: two takes per line, the checks pick one
# lines whose first two takes both failed word for word get two more (closing pass: Danny B d4 "frogs get class",
# Gus A g2 "I'd claimed" / "and never")
EXTRA_TAKES = {"danny_b_d4": [3, 4], "gus_a_g2": [3, 4]}
NAMES = ["Sam", "Alex", "Jordan", "Emma", "Liam", "Maya", "Noah", "Olivia", "Ethan", "Sofia"]

# Kokoro blends that define each voice (the Chatterbox candidates speak in the voice of a ~10 s render of that blend)
# shift = [pitch semitones, formant ratio] applied to the Kokoro render with WORLD (voxfx.world_shift), our processing
REFS = {
    "danny_a": {"blend": {"am_puck": .6, "af_heart": .4}, "speed": 1.05},
    "danny_b": {"blend": {"am_michael": 1.0}, "speed": 1.05, "shift": [3.0, 1.08]},
    "marcus_a": {"blend": {"am_puck": .5, "am_michael": .5}, "speed": 1.0},
    "marcus_c": {"blend": {"bm_george": .6, "bm_lewis": .4}, "speed": 1.0},
    "priya_a": {"blend": {"af_sarah": 1.0}, "speed": 1.05},
    "priya_b": {"blend": {"af_aoede": 1.0}, "speed": 1.05, "shift": [2.0, 1.03]},
    "gus_a": {"blend": {"am_michael": 1.0}, "speed": 0.92, "shift": [-2.5, 0.94]},
    "gus_b": {"blend": {"bm_lewis": 1.0}, "speed": 0.92},
}
BANNED = {"af_sky", "af_bella", "am_onyx"}
# Kokoro alone talks fast (review M1: 4.4 words/s at speed 1.0), most of all on short lines; at 0.85 it was still
# 3.6-5.1 words/s by the recogniser's word span. Per-line speed = 0.85 x 3.2 / (word-span rate measured at 0.85).
KOKORO_SPEED = {"d1": 0.66, "d2": 0.78, "d3": 0.56, "d4": 0.85, "d5": 0.64, "d6": 0.56}
REF_TEXT = ("Okay, so no joke, I was right there when it happened. Everybody just froze, and then the whole room "
            "cracked up. Honestly? Best day of the whole year, and we barely even got in trouble.")

DANNY = [
    ("d1", "Did you see Kessler's face when the frog got loose?", None),
    ("d2", "Worth the detention.", None),
    ("d3", "Wait up, you guys!", None),
    ("d4", "Why'd the frog skip class? Too busy hopping. [laugh] Get it?", "joke with a laugh"),
    ("d5", "Aw, look at this little guy. This is so cute.", None),
    ("d6", "Get it off! Get it off!", "frightened"),
]
MARCUS = [
    ("m1", "Dude, you screamed louder than the frog.", None),
    ("m2", "Worth it? You got detention for a week.", None),
    ("m3", "[groan] Not the frog joke again.", "groan"),
    ("m4", "Danny, nobody's paying for your pizza.", None),
]
PRIYA = [
    ("p1", "You literally tripped over the frog, Danny.", None),
    ("p2", "Kessler's never letting you back in that lab.", None),
    ("p3", "That's your plan? [laugh] Okay, genius.", "laugh"),
    ("p4", "Slow down, we're not racing to detention.", None),
]
GUS = [
    ("g1", "Hey! Building's closed. What are you kids still doing here?", None),
    ("g2", "Forty years I've cleaned these halls. Never heard it this quiet.", None),
    ("g3", "Stay behind me, and keep your voices down.", None),
]
PA = [("pa1", "Lockdown. Lockdown.", None)]   # spec v2 S14 only (review M6)
# the monster: Danny A's voice, calm, then processed (voxfx presets m1 mild, m2 recipe, m3 extreme; w = whisper)
MONSTER = [
    ("x1", "I saw you.", None), ("x2", "So cute.", None), ("x3", "Wait up, you guys.", "slow, wrong"),
    ("x4", "Come out. I won't tell.", None), ("x5", "Worth the detention.", None),
]
WHISPERS = [("w1", "I can hear you breathing.", "whisper"), ("w2", "Don't turn around.", "whisper")]


def main():
    out, refs = sys.argv[1], sys.argv[2]
    lines, plan = [], {"characters": []}

    def ref(n):
        return os.path.join(refs, f"ref_{n}.wav")

    def add(lid, text, engine, recipe, takes):
        ids = []
        for s in takes:
            i = f"{lid}_t{s}"
            lines.append({"id": i, "text": text, "engine": engine, "recipe": recipe, "seed": s})
            ids.append(i)
        return ids

    def cand(char, key, label, engine, recipe, script, desc, fx="dialogue", speeds=None):
        c = {"key": key, "label": label, "engine": engine, "recipe": recipe, "desc": desc, "lines": []}
        for lid, text, note in script:
            rec = dict(recipe, speed=speeds[lid]) if speeds else recipe
            # the frightened line failed word-for-word on both first takes (v1 had CAPS): four takes
            takes = ([1, 2, 3, 4] if lid == "d6" else TAKE_SEEDS + EXTRA_TAKES.get(f"{key}_{lid}", [])) \
                if engine == "cbturbo" else [0]
            c["lines"].append({"id": f"{key}_{lid}", "text": text, "note": note, "fx": fx,
                               "takes": add(f"{key}_{lid}", text, engine, rec, takes)})
        char["candidates"].append(c)

    danny = {"name": "Danny Reyes, 16", "key": "danny", "candidates": []}
    cand(danny, "danny_a", "Danny A", "cbturbo", {"ref": ref("danny_a")}, DANNY,
         "Chatterbox Turbo speaking in the voice of a Kokoro blend: am_puck 60 % + af_heart 40 % (speed 1.05)")
    cand(danny, "danny_b", "Danny B", "cbturbo", {"ref": ref("danny_b")}, DANNY,
         "Chatterbox Turbo speaking in the voice of Kokoro am_michael (speed 1.05) made younger by us: "
         "pitch +3 semitones, formants +8 %")
    cand(danny, "danny_c", "Danny C", "kokoro", {"blend": REFS["danny_a"]["blend"]}, DANNY,
         "Kokoro alone, the same blend as Danny A (am_puck 60 % + af_heart 40 %), slowed per line (speed 0.56-0.85): "
         "no laugh", speeds=KOKORO_SPEED)
    marcus = {"name": "Marcus, 16 (provisional)", "key": "marcus", "candidates": []}
    cand(marcus, "marcus_a", "Marcus A", "cbturbo", {"ref": ref("marcus_a")}, MARCUS,
         "Chatterbox Turbo, voice of Kokoro am_puck 50 % + am_michael 50 %: lower, flatter, deadpan")
    cand(marcus, "marcus_b", "Marcus B", "cbturbo", {"ref": ref("marcus_c")}, MARCUS,
         "Chatterbox Turbo, voice of Kokoro bm_george 60 % + bm_lewis 40 %: low, a British lilt")
    priya = {"name": "Priya, 16 (provisional)", "key": "priya", "candidates": []}
    cand(priya, "priya_a", "Priya A", "cbturbo", {"ref": ref("priya_a")}, PRIYA,
         "Chatterbox Turbo, voice of Kokoro af_sarah: bright, quick")
    cand(priya, "priya_b", "Priya B", "cbturbo", {"ref": ref("priya_b")}, PRIYA,
         "Chatterbox Turbo, voice of Kokoro af_aoede (speed 1.05) made a little younger by us: pitch +2 semitones, "
         "formants +3 %")
    gus = {"name": "Gus Pruitt, 58, the night janitor", "key": "gus", "candidates": []}
    cand(gus, "gus_a", "Gus A", "cbturbo", {"ref": ref("gus_a")}, GUS,
         "Chatterbox Turbo, voice of Kokoro am_michael (speed 0.92) made older by us (pitch -2.5 st, formants -6 %), "
         "then aged: formants -3 %, pitch -1 st", fx="gus")
    cand(gus, "gus_b", "Gus B", "cbturbo", {"ref": ref("gus_b")}, GUS,
         "Chatterbox Turbo, voice of Kokoro bm_lewis (speed 0.92), then aged: formants -3 %, pitch -1 st", fx="gus")
    cand(gus, "gus_c", "Gus C", "kokoro", {"blend": {"am_michael": .6, "am_fenrir": .4}, "speed": 0.9}, GUS,
         "Kokoro alone: am_michael 60 % + am_fenrir 40 %, speed 0.9, then aged more: formants -7 %, pitch -3 st",
         fx="gus_deep")   # with the -1 st chain it measured 109-118 Hz and 0.86 to Marcus A: too young
    pa = {"name": "The PA", "key": "pa", "candidates": []}
    cand(pa, "pa_a", "PA A", "kokoro", {"blend": {"af_heart": 1.0}, "speed": 0.9}, PA,
         "Kokoro af_heart, speed 0.9, through the PA chain (band 300-3,800 Hz, light drive, hall echo)", fx="pa")
    cand(pa, "pa_b", "PA B", "kokoro", {"blend": {"am_michael": 1.0}, "speed": 0.9}, PA,
         "Kokoro am_michael, speed 0.9, through the PA chain", fx="pa")

    # the monster: base takes in Danny A's voice; processing happens after the pick
    mon = {"name": "The monster (Danny's voice gone wrong)", "key": "monster", "base": [], "names": [], "whispers": []}
    dref = {"ref": ref("danny_a")}
    for lid, text, note in MONSTER:
        mon["base"].append({"id": f"mon_{lid}", "text": text, "note": note,
                            "takes": add(f"mon_{lid}", text, "cbturbo", dref, TAKE_SEEDS)})
    for lid, text, note in WHISPERS:
        mon["whispers"].append({"id": f"mon_{lid}", "text": text, "note": note,
                                "takes": add(f"mon_{lid}", text, "cbturbo", dref, TAKE_SEEDS)})
    for n in NAMES:   # each name said inside the same carrier; the name is cut out at its word timestamps
        mon["names"].append({"id": f"name_{n.lower()}", "name": n, "text": f"{n}... I saw you.",
                             # Alex: both first takes failed the joined-line gate ("Alec"), so two more takes
                             "takes": add(f"name_{n.lower()}", f"{n}... I saw you.", "cbturbo", dref,
                                          TAKE_SEEDS + ([3, 4] if n == "Alex" else []))})

    # the same line in each engine, same voice family, for the engine comparison
    eng = {"id": "engines", "line": DANNY[0][1], "items": []}
    for key, engine, recipe, desc in [
        ("eng_cb", "cbturbo", dref, "Chatterbox Turbo (Danny A)"),
        ("eng_kokoro", "kokoro", {"blend": REFS["danny_a"]["blend"], "speed": KOKORO_SPEED["d1"]},
         "Kokoro 82M (the same blend, speed 0.66)"),
        ("eng_kitten", "kitten", {"kvoice": "expr-voice-4-m", "speed": 0.9},
         "Kitten TTS mini 0.8 (built-in voice expr-voice-4-m, speed 0.9)"),
        ("eng_kitten2", "kitten", {"kvoice": "expr-voice-3-m", "speed": 0.9},
         "Kitten TTS mini 0.8 (built-in voice expr-voice-3-m, speed 0.9)"),
    ]:
        takes = TAKE_SEEDS if engine == "cbturbo" else [0]
        eng["items"].append({"id": key, "text": DANNY[0][1], "desc": desc, "engine": engine,
                             "takes": add(key, DANNY[0][1], engine, recipe, takes)})

    plan["characters"] = [danny, marcus, priya, gus, pa]
    plan["monster"] = mon
    plan["engines"] = eng
    plan["refs"] = {k: dict(r, text=REF_TEXT, wav=ref(k)) for k, r in REFS.items()}
    # no banned voice anywhere (refs, Kokoro candidates, engine items)
    used = set()
    for r in REFS.values():
        used |= set(r["blend"])
    for l in lines:
        used |= set(l["recipe"].get("blend", {}))
    assert not (used & BANNED), used & BANNED
    plan["voices_used"] = sorted(used)
    os.makedirs(refs, exist_ok=True)
    rl = [{"id": f"ref_{k}", "text": REF_TEXT, "engine": "kokoro",
           "recipe": {"blend": r["blend"], "speed": r["speed"], **({"shift": r["shift"]} if r.get("shift") else {})},
           "seed": 0} for k, r in REFS.items()]
    json.dump(rl, open(os.path.join(refs, "lines.json"), "w"), indent=1)
    os.makedirs(out, exist_ok=True)
    json.dump(lines, open(os.path.join(out, "lines.json"), "w"), indent=1)
    json.dump(plan, open(os.path.join(out, "plan.json"), "w"), indent=1)
    print(len(lines), "takes;", sum(1 for l in lines if l["engine"] == "cbturbo"), "Chatterbox")


if __name__ == "__main__":
    main()
