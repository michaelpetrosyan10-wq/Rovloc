"""items.py LINES.json WAV_DIR OUT.json : the measure.py list for a render list (one entry per take)."""
import sys, json, os
L = json.load(open(sys.argv[1]))
json.dump([{"id": l["id"], "wav": os.path.join(sys.argv[2], l["id"] + ".wav"), "text": l["text"]} for l in L],
          open(sys.argv[3], "w"), indent=1)
