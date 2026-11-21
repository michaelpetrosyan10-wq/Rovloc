"""Round 4 (production 2) render lists.  usage: plan4.py teachref|teachref2|kids|nv|mon|names|all OUT4DIR
Voices (the player's choice): Danny 3 = Chatterbox full + out2/refs/danny2_g2.wav; Kayla 3 = Chatterbox full + kayla2_g2;
Marcus 2 = Chatterbox full + marcus1_g2. Danny's teacher impression: Chatterbox full with a teacher reference made the
way round 2 made teach1 for Danny 1, but from Danny 3's own Kokoro blend (teach2), plus Danny 3's own reference at a
low exaggeration (as on the round-2 page). The monster (Monster 5) is built from Danny 3's calm takes (exag 0.25).
Only Kokoro built-in voices feed any reference; nothing is shifted, stretched or vocoded."""
import os, sys, json
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
sys.path.insert(0, H)
from names4 import bank
BANNED = {"af_sky", "af_bella", "am_onyx", "af_sarah", "bm_george", "bm_lewis", "am_santa"}
REF = lambda r: os.path.join(V, "out2", "refs", f"{r}_g2.wav")
TEACH2_G1 = os.path.join(V, "out4", "refs", "teach2_g1.wav")
TEACH2_G2 = os.path.join(V, "out4", "refs", "teach2_g2.wav")
TEACH_TEXT = "Settle down, everyone. Settle down. Is something funny? No? Then we will begin. Page forty, please. Quietly."
TEACH2_BLEND = {"am_puck": 0.4, "am_eric": 0.35, "am_adam": 0.25}   # Danny 3 = am_puck .6 + am_eric .4; teach1 added am_adam .3
SPK = {"danny": "danny2", "kayla": "kayla2", "marcus": "marcus1"}
VOICE = {"danny": "Danny 3", "kayla": "Kayla 3", "marcus": "Marcus 2"}
# opening-v3.md 6 line table (kid lines), model text = monster-lines.md 6 (lower case); exag = Chatterbox exaggeration
KIDS = [
 (1, "Opening.Twelve", "kayla", "twelve percent. on true-or-false.", 2.2, "Twelve percent. On true-or-false.", 0.45),
 (2, "Opening.Coin", "danny", "marcus. a coin gets fifty.", 1.9, "Marcus. A coin gets fifty.", 0.55),
 (3, "Opening.Studied", "marcus", "i studied for that!", 1.5, "I studied for that!", 0.85),
 (4, "Opening.FunnyTeacher", "teach", "mister ray-ess. is something funny?", 2.3, "Mister Reyes. Is something funny?", 0.3),
 (5, "Opening.NotYet", "danny", "i said: not yet, sir.", 1.9, "I said: not yet, sir.", 0.7),
 (6, "Opening.Hat", "kayla", "does that hat even come off?", 2.2, "Does that hat even come off?", 0.45),
 (7, "Opening.MoreHat", "marcus", "it's just more hat under there.", 2.2, "It's just more hat under there.", 0.45),
 (8, "Opening.Sals", "marcus", "sal's at four!", 1.1, "Sal's at four!", 0.85),
 (9, "Opening.LastOne", "kayla", "last one buys!", 1.1, "Last one buys!", 0.85),
 (10, "Opening.WaitUp", "danny", "wait up, you guys!", 1.5, "Wait up, you guys!", 0.85),
 (11, "Opening.Whoa", "danny", "whoa. what is that?", 1.5, "Whoa. What is THAT?", 0.6),
 (12, "Opening.LittleGuy", "danny", "hey, little guy.", 1.2, "Hey, little guy.", 0.35),
 (13, "Opening.SoCute", "danny", "bro. look at it. this is so cute.", 3.0, "Bro. Look at it. This is SO cute.", 0.75),
 (14, "Opening.ThatFace", "danny", "what? what's that face?", 1.6, "What? What's that face?", 0.55),
 (15, "Opening.LikesMe", "danny", "hey. it likes me.", 1.6, "Hey. It likes me.", 0.55),
 (16, "Opening.Cold", "danny", "ha. it's cold.", 1.3, "Ha. It's cold.", 0.5),
 (17, "Opening.StillOnMe", "danny", "is it still on me?", 2.0, "Is it still on me?", 0.45),
 (18, "Opening.Guys", "danny", "guys?", 1.0, "Guys?", 0.4),
]
# non-verbal sounds the script asks for: (id, speaker, model text, target seconds, where)
NV = [
 ("NV.Danny.GroupLaugh", "danny", "ha!", 0.3, "his part of the group laugh, 5.9 to 6.2"),
 ("NV.Danny.Laugh", "danny", "ha ha ha ha!", 1.0, "his laugh over his back, 14.9"),
 ("NV.Danny.NoseLaugh", "danny", "hm hm.", 0.4, "a breath of a laugh through the nose, 24.5"),
 ("NV.Kayla.GroupLaugh", "kayla", "ha ha ha!", 0.8, "her part of the group laugh, from 5.9"),
 ("NV.Kayla.Groan", "kayla", "ohh.", 0.5, "her groan, 10.2"),
 ("NV.Marcus.GroupLaugh", "marcus", "ha ha ha!", 0.6, "his part of the group laugh, from 6.15"),
 ("NV.Marcus.Laugh", "marcus", "ha ha!", 0.6, "his short laugh, 10.3"),
]
NV_EXAG = 0.7
# THE MONSTER (monster-lines.md 1), every string he speaks. kind: line | twin | rest (a named line without its name;
# 'first' = the name goes in front, 'last' = after it) ; base: calm = a fresh calm take of Danny 3 (exag 0.25);
# teach = a take in the L4 teacher manner (same reference and settings as the chosen L4); fromL4 / fromL13 = cut from
# the chosen opening take (the script's rule).
G = {1: "G1 far away", 2: "G2 behind a wall", 3: "G3 vent grate", 4: "G4 hiding spot", 5: "G5 seen you", 6: "G6 near miss",
     7: "G7 chase start", 8: "G8 after a catch", 9: "G9 alone", 10: "G10 group"}
LINES = [
 (1, "Wait up, you guys."), (1, "Guys? Where did everybody go?"), (1, "Is anybody still here?"),
 (1, "It's Danny. It's only Danny."), (1, "You can come out. It's just me."),
 (2, "Is it still on me?"), (2, "It's cold. It's really cold."), (2, "It doesn't come off. I tried."),
 (2, "I'm right here. Other side."), (2, "Knock once if you can hear me."), (2, "Is something funny?"),
 (3, "Hey, little guy."), (3, "So small in there. So cute."), (3, "I fit. Do you fit?"), (3, "Make room. I'm coming in."),
 (3, "Don't crawl off without me."),
 (4, "So quiet. So cute."), (4, "Still in there? Go on."), (4, "I can wait. I'm good at waiting."), (4, "Hi."),
 (4, "Quiet. It can hear you."),
 (5, "What's that face?"), (5, "Why are you making that face?"), (5, "Don't move. This is so cute."),
 (5, "Don't look at me like that."), (5, "You just stood there and watched."),
 (6, "You were right there."), (6, "Close. So close."), (6, "Fine. Go on. I'll catch up."), (6, "Not yet, then."),
 (7, "Wait up!"), (7, "Wait up, you guys! Wait up!"), (7, "Don't leave without me!"), (7, "Why does everybody run?"),
 (7, "I said wait!"),
 (8, "See? It doesn't hurt. It's just cold."), (8, "So cute. I'm keeping this one."), (8, "Don't cry. It likes you."),
 (8, "You stopped. Finally. Thank you."),
 (9, "They left you too."), (9, "Nobody waited for you either."), (9, "It's quiet when they leave. I know."),
 (9, "Just us now. I waited."),
 (10, "All together. So cute."), (10, "You guys never wait."), (10, "You all saw. Nobody said anything."),
 (10, "Is something funny, you guys?"),
]
# N#: group, named form, twin, remainder text (what is rendered besides the name), where the name goes
NAMED = [
 ("N1", 1, "{name}? It's me. It's Danny.", "Hello? It's me. It's Danny.", "It's me. It's Danny.", "first"),
 ("N2", 1, "{name}, wait up.", "Hey. Wait up.", "Wait up.", "first"),
 ("N3", 2, "{name}. Are you on the other side?", "Are you on the other side?", None, "first"),
 ("N4", 2, "You saw it first, {name}.", "You saw it first.", "You saw it first,", "last"),
 ("N5", 3, "Is that you in there, {name}?", "Who is that in there?", "Is that you in there,", "lastq"),
 ("N6", 4, "I know that breathing, {name}.", "I know that breathing.", "I know that breathing,", "last"),
 ("N7", 5, "Is that your real face, {name}?", "Is that your real face?", "Is that your real face,", "lastq"),
 ("N8", 5, "I was looking right at you, {name}.", "I was looking right at you.", "I was looking right at you,", "last"),
 ("N9", 6, "Next time, {name}.", "Next time.", "Next time,", "last"),
 ("N10", 6, "You didn't wait, {name}.", "You didn't wait.", "You didn't wait,", "last"),
 ("N11", 7, "{name}. Stop. It's just me.", "Stop. It's just me.", None, "first"),
 ("N12", 8, "This one is staying with me. {name}.", "This one is staying with me.", None, "alone_after"),
 ("N13", 8, "It's bedtime, {name}.", "It's bedtime.", "It's bedtime,", "last"),
 ("N14", 9, "Why didn't you say something, {name}?", "Why didn't you say something?", "Why didn't you say something,", "lastq"),
 ("N15", 9, "Tell them I was funny, {name}.", "Tell them I was funny.", "Tell them I was funny,", "last"),
 ("N16", 10, "I can see you too, {name}.", "I can see all of you.", "I can see you too,", "last"),
]
# kept from spec 3.4 (monster-lines.md 1, "Kept"): id, category, named form or None, twin/plain, remainder, position
KEPT = [
 ("K.Ready.1", "Ready", None, "Ready or not.", None, None), ("K.Ready.2", "Ready", None, "Here I come.", None, None),
 ("K.LookAway.1", "LookAway", None, "I'm not looking.", None, None),
 ("K.LookAway.2", "LookAway", None, "Go on. I won't look.", None, None),
 ("K.Teleport.1", "Teleport", None, "Behind you.", None, None), ("K.Teleport.2", "Teleport", None, "Boo.", None, None),
 ("K.Teleport.3", "Teleport", "{name}.", "Hey.", None, "alone"),
 ("K.Heard.1", "Heard", None, "I heard that.", None, None),
 ("K.Behind.1", "Behind", "Don't turn around, {name}.", "Don't turn around.", "Don't turn around,", "last"),
 ("K.Behind.2", "Behind", None, "I'm right behind you.", None, None),
 ("K.Stunned.1", "Stunned", "Ow. That hurts, {name}.", "Ow. That hurts.", "Ow. That hurts,", "last"),
]
OPENING_MON = [  # L, id, words, slot, base
 (19, "Opening.FunnyMonster", "Is something funny?", 1.5, "fromL4"),
 (20, "Opening.WaitUpBack", "Wait up, you guys.", 1.9, "calm"),
 (21, "Opening.SoCuteBack", "So cute.", 1.2, "fromL13"),
 (23, "Opening.You.Twin", "Still here.", 1.4, "calm"),
]
MON_SEEDS = (1, 2)

def mon_strings():
    """every distinct string the monster speaks -> list of dicts (id, text, group, kind, base)"""
    S = []
    for i, (g, t) in enumerate(LINES, 1):
        base = "fromL4" if t == "Is something funny?" else ("teach" if t == "Is something funny, you guys?" else "calm")
        S.append(dict(id=f"Mon.L{i:02d}", text=t, group=G[g], kind="line", n=i, base=base))
    for nid, g, named, twin, rest, pos in NAMED:
        S.append(dict(id=f"Mon.{nid}.Twin", text=twin, group=G[g], kind="twin", named=named, base="calm", pos=pos))
        S.append(dict(id=f"Mon.{nid}.Rest", text=rest or twin, group=G[g], kind="rest", named=named, base="calm",
                      pos=pos, same_as_twin=rest is None))
    for kid, cat, named, plain, rest, pos in KEPT:
        S.append(dict(id=f"Mon.{kid}", text=plain, group="kept: " + cat, kind="twin" if named else "line", named=named,
                      base="calm", pos=pos))
        if rest:
            S.append(dict(id=f"Mon.{kid}.Rest", text=rest, group="kept: " + cat, kind="rest", named=named, base="calm", pos=pos))
    for n, oid, t, slot, base in OPENING_MON:
        S.append(dict(id=oid, text=t, group="opening", kind="opening", L=n, slot=slot, base=base))
    S.append(dict(id="Ending.Shooter.Twin", text="Hey.", group="ending A", kind="twin", named="{shooter}?", base="calm",
                  pos="aloneq"))
    return S

def main():
    mode, out = sys.argv[1], sys.argv[2]
    L = []
    if mode == "teachref":
        assert not (set(TEACH2_BLEND) & BANNED)
        L.append(dict(id="teach2_g1", text=TEACH_TEXT, engine="kokoro", recipe={"blend": TEACH2_BLEND, "speed": 0.82}, seed=0))
    elif mode == "teachref2":
        L.append(dict(id="teach2_g2", text=TEACH_TEXT, engine="cbfull",
                      recipe={"ref": TEACH2_G1, "exag": 0.65, "max_tokens": 600}, seed=1))
    elif mode == "kids":
        for (n, lid, spk, text, slot, words, ex) in KIDS:
            if spk == "teach":
                opts = [("teach2", TEACH2_G2, 0.3, s) for s in (1, 2, 3, 4)] + [("danny2", REF("danny2"), 0.3, s) for s in (1, 2)]
            else:
                seeds = (1, 2, 3, 4, 5, 6) if n == 13 else (1, 2, 3, 4)
                opts = [(SPK[spk], REF(SPK[spk]), ex, s) for s in seeds]
            for rid, ref, e, sd in opts:
                L.append(dict(id=f"L{n:02d}_{rid}_s{sd}", L=n, line_id=lid, speaker="danny" if spk == "teach" else spk,
                              ref_id=rid, text=text, plain=words, slot=slot, engine="cbfull",
                              recipe={"ref": ref, "exag": e}, seed=sd))
    elif mode == "nv":
        for nid, spk, text, secs, where in NV:
            for sd in (1, 2, 3):
                L.append(dict(id=f"{nid}_s{sd}", nv=nid, speaker=spk, ref_id=SPK[spk], text=text, target=secs, where=where,
                              engine="cbfull", recipe={"ref": REF(SPK[spk]), "exag": NV_EXAG}, seed=sd))
    elif mode == "mon":
        done = {}
        for s in mon_strings():
            if s["base"] not in ("calm",):
                continue
            t = s["text"]
            if t in done:
                continue
            done[t] = 1
            for sd in MON_SEEDS:
                L.append(dict(id=f"calm{len(done):03d}_s{sd}", text=t, plain=t, engine="cbfull",
                              recipe={"ref": REF("danny2"), "exag": 0.25}, seed=sd))
    elif mode == "names":
        for nm, g in bank():
            for shape, t in (("q", nm + "?"), ("d", nm + ".")):
                L.append(dict(id=f"name_{nm}_{shape}_s1", name=nm, gender=g, shape=shape, text=t, plain=nm, engine="cbfull",
                              recipe={"ref": REF("danny2"), "exag": 0.25}, seed=1))
    os.makedirs(out, exist_ok=True)
    json.dump(L, open(os.path.join(out, f"lines_{mode}.json"), "w"), indent=1)
    print(mode, len(L), "lines")

if __name__ == "__main__":
    main()
