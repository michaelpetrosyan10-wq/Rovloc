"""Write prod2/manifest.json from the pick/final records and the recogniser pass over the FINISHED files.
usage: manifest4.py PROD2_DIR FINAL_ASR.json"""
import os, sys, json, glob
H = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(H)
sys.path.insert(0, H)
from common4 import jload, jsave, norm4, name_check, BED_DB
import plan4
from bank4 import grade
from whisper4 import BREATH_DB, PROX_DB
MON_VOICE = "Monster 5 (round 2): close dry whisper made from Danny 3's own calm take, with a breath in before it"
def mon_settings(r):
    return dict(base_engine="Chatterbox full 0.5B (onnx-community export, q4 language model)",
                base_voice="Danny 3 (ref out2/refs/danny2_g2.wav)" if "teach2" not in (r.get("take_ref") or "") else "Danny 3 teacher impression (ref out4/refs/teach2_g2.wav)",
                base_take=r.get("take"), base_seed=r.get("take_seed"), base_recipe=r.get("take_recipe"), cut_from_take=r.get("cut"),
                whisper="LPC whisper of the same take (order 26, 25 ms frames, 6.25 ms hop), high-pass 70 Hz, +%g dB shelf under 250 Hz" % PROX_DB,
                breath=("synthetic inhale out/breath_synth.wav, %g dB under the words, beat %s s" % (BREATH_DB, r.get("beat"))) if r.get("breath") else "none",
                room_tone="seeded pink room tone %g dBFS RMS under the whole file" % BED_DB,
                no_shift_no_stretch=True)
def main():
    pd, fa = sys.argv[1], sys.argv[2]
    A = jload(fa, {})
    files = []
    def asr(fid):
        a = A.get(fid) or {}
        return a.get("asr"), a.get("exact")
    kids = jload(os.path.join(pd, "kids", "kids_pick.json"), {"lines": []})
    for r in kids["lines"]:
        h, ex = asr(r["id"])
        files.append(dict(id=r["id"], group="opening", speaker=r["speaker"], text=r["text"], model_text=r["model_text"],
                          file=r["file"], mp3=r["mp3"], seconds=r["seconds"], slot=r["slot"], fits_slot=r["fits_slot"],
                          words_per_second=r["words_per_second"], recogniser=h, word_for_word=ex, recogniser_take=r["recogniser"],
                          voice=r["voice"], settings=dict(r["settings"], reference=r["reference_voice"], take=r["take"],
                          pick=r["why"], takes_ok=r["takes_ok"]), lufs=r["lufs"], peak_db=r["peak_db"]))
    nv = jload(os.path.join(pd, "kids", "nv_pick.json"), [])
    for r in nv:
        h, ex = asr(r["id"])
        files.append(dict(id=r["id"], group="opening non-verbal", speaker=r["speaker"].upper(), text=r["what"], model_text=r["model_text"],
                          file=r["file"], mp3=r["mp3"], seconds=r["seconds"], slot=r.get("target"), words_per_second=None,
                          recogniser=h, voice=r["voice"], settings=r["settings"], lufs=r.get("lufs"), peak_db=r.get("peak_db"),
                          flag=r.get("flag")))
    mon = jload(os.path.join(pd, "monster", "mon_final.json"), [])
    for r in mon:
        if not r["made"]: continue
        h, ex = asr(r["id"])
        nw = len(norm4(r["text"]))
        files.append(dict(id=r["id"], group=r["group"], kind=r["kind"], speaker="THE TALL MAN (Danny's voice gone wrong)",
                          text=r["text"], named_form=r.get("named"), name_position=r.get("pos"),
                          file=f"monster/{r['id']}.wav", mp3=f"monster/{r['id']}.mp3", seconds=r["seconds"], slot=r.get("slot"),
                          fits_slot=(round(r["speech_end"] - r["speech_start"], 3) <= r["slot"]) if r.get("slot") else None,
                          speech_start=r["speech_start"], speech_end=r["speech_end"], breath_start=r.get("breath_start"),
                          breath_end=r.get("breath_end"), words_seconds=round(r["speech_end"] - r["speech_start"], 3),
                          words_per_second=round(nw / (r["speech_end"] - r["speech_start"]), 2),
                          recogniser=h, word_for_word=ex, voice=MON_VOICE, settings=mon_settings(r), lufs=r["lufs"], peak_db=r["peak_db"]))
    bank = jload(os.path.join(pd, "names", "bank.json"), {})
    for nm, b in bank.items():
        if not b["in_bank"]: continue
        for shape, f in b["files"].items():
            h, _ = asr(f["id"]); take = b["q"] if shape in ("First", "LastQ") else b["d"]
            files.append(dict(id=f["id"], group="name bank", kind="name:" + shape, speaker="THE TALL MAN (Danny's voice gone wrong)",
                              text=nm + ("?" if shape in ("First", "LastQ") else "."), name=nm, gender=b["gender"],
                              file=f["file"], mp3=f["mp3"], seconds=f["seconds"], slot=None,
                              speech_start=f["speech_start"], speech_end=f["speech_end"], breath_start=f.get("breath_start"),
                              words_seconds=round(f["speech_end"] - f["speech_start"], 3),
                              words_per_second=round(1 / (f["speech_end"] - f["speech_start"]), 2),
                              recogniser=h, heard_as=(grade(nm, h) if h is not None else None), flagged=bool(b["flagged"]),
                              voice=MON_VOICE, settings=dict(mon_settings(dict(take=take["take"], take_seed=take["seed"],
                                                       take_recipe={"exag": 0.25}, beat=f.get("beat"), breath=f.get("breath"))),
                                                       take_heard=take["heard"], note=b["note"]),
                              lufs=f.get("lufs"), peak_db=f["peak_db"]))
    named = []
    for nid, g, nf, twin, rest, pos in plan4.NAMED:
        named.append(dict(line=nid, named=nf, twin=f"Mon.{nid}.Twin", rest=f"Mon.{nid}.Rest", name_shape={"first": "First", "last": "Last", "lastq": "LastQ", "alone_after": "Alone"}[pos],
                          order="name, then rest" if pos == "first" else "rest, then name"))
    for kid, cat, nf, plain, rest, pos in plan4.KEPT:
        if nf: named.append(dict(line=kid, named=nf, twin=f"Mon.{kid}", rest=f"Mon.{kid}.Rest" if rest else None,
                                 name_shape={"alone": "Alone", "last": "Last"}[pos], order="name alone" if pos == "alone" else "rest, then name"))
    named.append(dict(line="Opening.You (L23)", named="{you}.", twin="Opening.You.Twin", rest=None, name_shape="Alone", order="name alone"))
    named.append(dict(line="Ending A", named="{shooter}?", twin="Ending.Shooter.Twin", rest=None, name_shape="First", order="name alone"))
    man = dict(made="2026-11-18, voices production 2 (round 4)", sample_rate=24000, channels=1, wav="PCM 16-bit", mp3="libmp3lame VBR q4 (LAME/Xing header)",
               voices={"DANNY": "Danny 3", "KAYLA": "Kayla 3", "MARCUS": "Marcus 2", "THE TALL MAN": MON_VOICE},
               name_rule=dict(bank=sorted(n for n, b in bank.items() if b["in_bank"]), not_in_bank=sorted(n for n, b in bank.items() if not b["in_bank"]),
                              never_named=["Danny", "Kayla", "Marcus"], fallback="the line's twin (monster-lines.md 3): when the name is not in the bank, is filtered by NameSanitizer, is empty, is Danny, Kayla or Marcus, or names are Off",
                              join="play B the sample after A ends (no overlap, no crossfade, no gap): A's tail and B's head are the same room tone",
                              named_lines=named),
               counts={}, files=files)
    from collections import Counter
    man["counts"] = dict(Counter(f["group"] if f["group"] in ("opening", "opening non-verbal", "name bank") else "monster lines" for f in files))
    jsave(os.path.join(pd, "manifest.json"), man); print(man["counts"], len(files))
if __name__ == "__main__":
    main()
