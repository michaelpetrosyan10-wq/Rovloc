"""usage: namefall4.py LINES.json[,..] TAKES_DIR OUT.json : the names namebatch4.py could not split -> a one-by-one list"""
import os, sys, json
L = []
for p in sys.argv[1].split(","): L += json.load(open(p))
u = os.path.join(sys.argv[2], "batch_unsplit.json")
bad = {i for g in (json.load(open(u)) if os.path.exists(u) else []) for i in g["ids"]}
S = [x for x in L if x["id"] in bad]
json.dump(S, open(sys.argv[3], "w"), indent=1); print(len(S), "names to render one by one")
