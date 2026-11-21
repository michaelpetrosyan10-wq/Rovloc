"""Build the listening board: board/index.html + board/a/*.mp3 (mono, 24 kHz, LAME VBR q4). No external requests.

usage: build_board.py PLAN.json FINAL_DIR MEASURE_FINAL.json BOARD_DIR [--no-gate]
Refuses to build (exit 2) when a file on the board fails tools/gates.py (word for word; dialogue rate 2.0-3.6 w/s).
"""
import os, sys, json, html, re, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import read_json
import gates

PROCESSED = ("m1", "m2", "m3", "name", "joined", "rest", "whisper")   # pitch of a mixed file is not one voice


def mp3(src, dst):
    if os.path.exists(dst) and os.path.getmtime(dst) > os.path.getmtime(src):
        return
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-ac", "1", "-ar", "24000", "-c:a", "libmp3lame",
                    "-q:a", "4", "-map_metadata", "-1", "-id3v2_version", "0", "-write_xing", "1", dst], check=True)


def main():
    plan_p, final, meas_p, board = sys.argv[1:5]
    plan = read_json(plan_p)
    M = {r["id"]: r for r in read_json(meas_p)}
    NB = read_json(os.path.join(final, "names.json"))   # select_names.py: the take that passed the gate
    mon = plan["monster"]
    extra = [f'{ln["id"]}_{s}' for ln in mon["base"] for s in ("clean", "m1", "m2", "m3")]
    extra += [ln["id"] + "_w" for ln in mon["whispers"]] + ["pa_a_pa1", "pa_b_pa1"]
    extra += [NB[n["name"]]["clip"] for n in mon["names"]] + [NB[n["name"]]["join"] for n in mon["names"][:3]]
    bad = gates.check(plan, M, extra)
    for b in bad:
        print("GATE FAIL", *b)
    if bad and "--no-gate" not in sys.argv:
        sys.exit(2)
    tagged = {fid: t for fid, t, _ in gates.dialogue_lines(plan)}
    os.makedirs(os.path.join(board, "a"), exist_ok=True)
    used = set()

    def audio(fid):
        src = os.path.join(final, fid + ".wav")
        if not os.path.exists(src):
            return '<span class="miss">(missing)</span>'
        mp3(src, os.path.join(board, "a", fid + ".mp3"))
        used.add(fid + ".mp3")
        return f'<audio controls preload="none" src="a/{fid}.mp3"></audio>'

    def check(fid):
        r = M.get(fid)
        if not r:
            return ""
        ok = r["exact"] or r["wer"] == 0
        tag = "ok" if ok else ("near" if r["wer"] <= 0.15 else "bad")
        sym = "heard right" if ok else f'heard: "{html.escape(r["heard"])}"'
        f0 = f' · pitch {r["f0_med"]:.0f} Hz' if r.get("f0_med") and r.get("kind") not in PROCESSED else ""
        rt = ""
        if fid in tagged:
            a, b = gates.rates(r, tagged[fid])
            rt = f" · {b:.1f} words/s" if b else ""
        return f'<span class="chk {tag}">{sym}</span><span class="meta">{r["dur"]:.1f} s{f0}{rt}</span>'

    def row(fid, text, note=None):
        n = f' <em>({html.escape(note)})</em>' if note else ""
        return (f'<div class="line"><div class="txt">{html.escape(text)}{n}</div>{audio(fid)}'
                f'<div class="m">{check(fid)}</div></div>')

    S = []
    nav = []
    for ch in plan["characters"]:
        nav.append((ch["key"], ch["name"].split(",")[0]))
        S.append(f'<section id="{ch["key"]}"><h2>{html.escape(ch["name"])}</h2>')
        for c in ch["candidates"]:
            S.append(f'<div class="cand"><h3>{html.escape(c["label"])}</h3><p class="desc">{html.escape(c["desc"])}</p>')
            for ln in c["lines"]:
                if c["engine"] == "cbturbo":     # Chatterbox performs the tags
                    t = ln["text"].replace("[laugh]", "(laughs)").replace("[groan]", "(groans)")
                    note = ln["note"]
                else:                            # Kokoro and Kitten have no tags: show only what is said
                    t = " ".join(re.sub(r"\[[^\]]*\]", " ", ln["text"]).split())
                    note = ln["note"] if ln["note"] and not any(k in ln["note"] for k in ("laugh", "groan")) else None
                S.append(row(ln["id"], t, note))
            S.append("</div>")
        S.append("</section>")

    nav.append(("monster", "Monster"))
    S.append('<section id="monster"><h2>The monster: Danny\'s voice gone wrong</h2>'
             '<p>Every line starts as Danny A, said calmly. Then three treatments, from mild to extreme: '
             '<b>M1</b> a little lower and slower with a faint whisper behind; <b>M2</b> lower body, slower, a whisper '
             'double and a deep layer you feel more than hear; <b>M3</b> much lower, flat and wobbly, the whisper '
             'close behind. Pick the one you like (or say "between M2 and M3").</p>')
    for ln in mon["base"]:
        note = f' <em>({html.escape(ln["note"])})</em>' if ln["note"] else ""
        S.append(f'<div class="cand"><h3>"{html.escape(ln["text"])}"{note}</h3>')
        for suf, lab in (("clean", "Danny, clean"), ("m1", "M1 mild"), ("m2", "M2"), ("m3", "M3 extreme")):
            fid = f'{ln["id"]}_{suf}'
            S.append(f'<div class="line"><div class="txt"><b>{lab}</b></div>{audio(fid)}<div class="m">{check(fid)}</div></div>')
        S.append("</div>")
    S.append('<div class="cand"><h3>Whispers (heard right at your ear)</h3>')
    for ln in mon["whispers"]:
        S.append(row(ln["id"] + "_w", ln["text"]))
    S.append("</div>")
    S.append('<div class="cand"><h3>Saying your name</h3><p class="desc">The game cannot know your name in advance, '
             'so the monster says common first names from a bank (each its own small file) and the game plays the '
             'name, a short beat, then the rest of the line, overlapping the two files a little so there is no gap. '
             'If your name is not in the bank, it uses the line without a name. Here: the name and the rest joined '
             'the way the game will play them, then the line without the name.</p>')
    for nm in mon["names"][:3]:
        S.append(row(NB[nm["name"]]["join"], f'{nm["name"]}... I saw you.', "name + rest, joined"))
    S.append(row("mon_x1_m2", "I saw you.", "the twin without a name"))
    S.append('<h3>The bank: ten names, each its own file (M2)</h3><div class="names">')
    for nm in mon["names"]:
        fid = NB[nm["name"]]["clip"]
        S.append(f'<div class="line"><div class="txt">{nm["name"]}</div>{audio(fid)}<div class="m">{check(fid)}</div></div>')
    S.append("</div></div></section>")

    eng = plan["engines"]
    nav.append(("engines", "Engines"))
    S.append(f'<section id="engines"><h2>Same line, different speech engines</h2><p>For the curious: the line '
             f'"{html.escape(eng["line"])}" from each engine we tried.</p><div class="cand">')
    for it in eng["items"]:
        S.append(f'<div class="line"><div class="txt"><b>{html.escape(it["desc"])}</b></div>{audio(it["id"])}'
                 f'<div class="m">{check(it["id"])}</div></div>')
    S.append("</div></section>")

    navh = " ".join(f'<a href="#{k}">{html.escape(n)}</a>' for k, n in nav)
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ROVLOC Voice Auditions</title>
<style>
:root{{--bg:#0e0f12;--card:#17191e;--line:#262a31;--ink:#e9e7e2;--dim:#9a9890;--acc:#e0b35a;--ok:#7fc28a;--bad:#e57a6e}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}}
main{{max-width:760px;margin:0 auto;padding:16px 16px 64px}}
h1{{font-size:1.6rem;margin:.6em 0 .2em}} h2{{font-size:1.25rem;margin:1.8em 0 .5em;color:var(--acc)}}
h3{{font-size:1.05rem;margin:0 0 .3em}}
nav{{position:sticky;top:0;background:var(--bg);padding:8px 0;border-bottom:1px solid var(--line);z-index:2;
  display:flex;flex-wrap:wrap;gap:6px 14px}}
nav a{{color:var(--acc);text-decoration:none;font-weight:600}}
.intro{{color:var(--ink)}} .intro p{{margin:.5em 0}}
.cand{{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px;margin:12px 0}}
.desc{{color:var(--dim);font-size:.9rem;margin:0 0 8px}}
.line{{padding:8px 0;border-top:1px solid var(--line)}} .line:first-of-type{{border-top:0}}
.txt{{margin-bottom:4px}} .txt em{{color:var(--dim);font-style:normal;font-size:.85rem}}
audio{{width:100%;height:36px}}
.m{{font-size:.78rem;color:var(--dim);display:flex;gap:10px;flex-wrap:wrap}}
.chk.ok{{color:var(--ok)}} .chk.near{{color:var(--acc)}} .chk.bad{{color:var(--bad)}}
.names{{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:0 14px}}
footer{{color:var(--dim);font-size:.85rem;margin-top:3em}}
</style></head><body><main>
<h1>ROVLOC voice auditions</h1>
<div class="intro"><p><b>These are test voices: tell us which you like.</b> Every voice here is made by a computer
speech model: the models' own built-in voices, mixed and changed by us. No real person's voice was cloned, and no
one was recorded for this page. The lines are only tests, the real script comes later.</p>
<p>For each character there are 2 or 3 voices (A, B, C). Press play, listen, and tell us which one sounds right, for
example "Danny A, Marcus B, Priya A, Gus C, monster M2". If none fits, say what is wrong ("too old", "too slow",
"sounds like a robot").</p>
<p class="desc">Under each line: whether a speech recogniser understood every word, the length, the voice's
pitch and how fast it talks (words per second). Use headphones or a quiet room.</p></div>
<nav>{navh}</nav>
{''.join(S)}
<footer><p>Made offline with Chatterbox Turbo by Resemble AI (MIT), Kokoro 82M by hexgrad (Apache-2.0) and Kitten TTS
by KittenML (Apache-2.0). Kokoro's training data includes Koniwa (CC BY 3.0) and SIWIS (CC BY 4.0). Pronunciation
for Kokoro and Kitten by eSpeak NG (GPL-3.0), used only on our machine to turn text into sounds; none of it is in
these files.
Voice changes with the WORLD vocoder by M. Morise (modified BSD) through pyworld (MIT). Checked with Whisper (MIT)
through faster-whisper (MIT).</p>
<p>Our own work: the lines, the voice mixes and changes, the monster and PA processing, the name bank, and the breath
before the monster's lines (made from shaped noise, not a recording).</p></footer>
</main></body></html>
"""
    with open(os.path.join(board, "index.html"), "w", encoding="utf-8") as f:
        f.write(page)
    # drop stale mp3s
    for fn in os.listdir(os.path.join(board, "a")):
        if fn not in used:
            os.remove(os.path.join(board, "a", fn))
    tot = sum(os.path.getsize(os.path.join(board, "a", f)) for f in os.listdir(os.path.join(board, "a")))
    print(f"{len(used)} mp3, {tot/1e6:.2f} MB")


if __name__ == "__main__":
    main()
