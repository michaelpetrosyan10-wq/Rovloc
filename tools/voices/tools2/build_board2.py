"""Build board2/index.html from PLAN.json; copies each MP3 into board2/a/. All paths relative; no outside request.
PLAN: {"sections":[{"id","title","note","cands":[{"label","grey","items":[{"src","name","text","dir"}]}]}]}"""
import os, sys, json, shutil, html
plan = json.load(open(sys.argv[1])); out = sys.argv[2]
os.makedirs(os.path.join(out, "a"), exist_ok=True)
for f in os.listdir(os.path.join(out, "a")):
    os.remove(os.path.join(out, "a", f))
E = html.escape
CSS = """:root{--bg:#0e0f12;--card:#17191e;--line:#262a31;--ink:#e9e7e2;--dim:#9a9890;--acc:#e0b35a}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:760px;margin:0 auto;padding:16px 16px 64px}
h1{font-size:1.6rem;margin:.6em 0 .3em} h2{font-size:1.3rem;margin:1.8em 0 .4em;color:var(--acc)}
h3{font-size:1.1rem;margin:0 0 .2em}
nav{position:sticky;top:0;background:var(--bg);padding:8px 0;border-bottom:1px solid var(--line);z-index:2;display:flex;flex-wrap:wrap;gap:6px 16px}
nav a{color:var(--acc);text-decoration:none;font-weight:600}
.intro p{margin:.3em 0;font-size:1.05rem}
.cand{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px;margin:12px 0}
.grey{color:var(--dim);font-size:.82rem;margin:0 0 6px}
.line{padding:8px 0;border-top:1px solid var(--line)} .line:first-of-type{border-top:0}
.txt{margin-bottom:4px;overflow-wrap:anywhere} .txt em{color:var(--dim);font-style:normal;font-size:.85rem}
audio{width:100%;height:36px;display:block}
footer{color:var(--dim);font-size:.82rem;margin-top:3em}"""
body = []
body.append('<h1>ROVLOC voices, round 2</h1>')
body.append('<div class="intro"><p>Round 2: you said the voices sounded a little robotic. These are made differently.</p>'
            '<p>Tell me which you like.</p></div>')
body.append('<nav>' + " ".join(f'<a href="#{s["id"]}">{E(s["title"].split(",")[0])}</a>' for s in plan["sections"]) + '</nav>')
n = 0
for s in plan["sections"]:
    body.append(f'<section id="{s["id"]}"><h2>{E(s["title"])}</h2>')
    if s.get("note"):
        body.append(f'<p class="grey">{E(s["note"])}</p>')
    for c in s["cands"]:
        body.append(f'<div class="cand"><h3>{E(c["label"])}</h3>')
        if c.get("grey"):
            body.append(f'<p class="grey">{E(c["grey"])}</p>')
        for it in c["items"]:
            name = it["name"] + ".mp3"
            shutil.copyfile(it["src"], os.path.join(out, "a", name)); n += 1
            d = f' <em>({E(it["dir"])})</em>' if it.get("dir") else ""
            body.append(f'<div class="line"><div class="txt">{E(it["text"])}{d}</div>'
                        f'<audio controls preload="none" src="a/{name}"></audio></div>')
        body.append('</div>')
    body.append('</section>')
body.append('<footer>' + "".join(f"<p>{E(p)}</p>" for p in plan["footer"]) + '</footer>')
doc = ('<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
       '<title>ROVLOC Voices Round 2</title><style>' + CSS + '</style></head><body><main>' + "\n".join(body) + '</main></body></html>\n')
open(os.path.join(out, "index.html"), "w").write(doc)
print(n, "files")
