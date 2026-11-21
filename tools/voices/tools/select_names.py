"""select_names.py PLAN.json MEASURE_FINAL.json OUT.json : per name, the take whose processed clip and joined line
are both recognised word for word (ties: the higher recogniser word probability on the clip). Flags names with none."""
import sys, json
plan = json.load(open(sys.argv[1]))
M = {r["id"]: r for r in json.load(open(sys.argv[2]))}
out = {}
for nm in plan["monster"]["names"]:
    best = None
    for t in nm["takes"]:
        s = t.rsplit("_", 1)[-1]
        c, j = M.get(f'{nm["id"]}_m2_{s}'), M.get(f'join_{nm["name"].lower()}_{s}')
        if not c or not j:
            continue
        p = max([w["p"] for w in c["words"]] or [0])
        key = ((c["wer"] == 0) + (j["wer"] == 0), p)
        if best is None or key > best[0]:
            best = (key, s, c, j)
    out[nm["name"]] = {"take": best[1], "clip": f'{nm["id"]}_m2_{best[1]}', "join": f'join_{nm["name"].lower()}_{best[1]}',
                       "clip_heard": best[2]["heard"], "join_heard": best[3]["heard"], "passes": best[0][0] == 2}
json.dump(out, open(sys.argv[3], "w"), indent=1)
print(sum(v["passes"] for v in out.values()), "of", len(out), "names pass both;",
      [k for k, v in out.items() if not v["passes"]])
