"""retake.py PLAN.json MEASURE_FINAL.json PICKS.json RETAKE.json : after a final measurement, mark every dialogue
line that fails the board gate (tools/gates.py) for a redo in finish.py: if its tempo was changed and its rates
before the change were already inside the gate (2.05-3.55), use the same take without the tempo change; otherwise
exclude the take. Merges into RETAKE.json; prints what it marked (nothing = the gate passes)."""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gates
plan, M = json.load(open(sys.argv[1])), {r["id"]: r for r in json.load(open(sys.argv[2]))}
P, out = json.load(open(sys.argv[3])), sys.argv[4]
RT = json.load(open(out)) if os.path.exists(out) else {}
marked = []
for fid, why in gates.check(plan, M):
    p = P.get(fid)
    if not p or "tempo" not in p:
        continue
    e = RT.setdefault(fid, {"exclude": [], "no_tempo": []})
    rates = p.get("rate_before_energy_words") or []
    if p["tempo"] != 1.0 and rates and all(2.05 <= r <= 3.55 for r in rates) and p["take"] not in e["no_tempo"]:
        e["no_tempo"].append(p["take"])
        marked.append((fid, p["take"], "no tempo change", why))
    elif p["take"] not in e["exclude"]:
        e["exclude"].append(p["take"])
        marked.append((fid, p["take"], "excluded", why))
json.dump(RT, open(out, "w"), indent=1)
for m in marked:
    print("RETAKE", *m)
print(len(marked), "marked")
