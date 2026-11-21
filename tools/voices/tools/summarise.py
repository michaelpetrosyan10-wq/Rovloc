"""Markdown tables for REPORT.md from the measurements and the render logs.

usage: summarise.py RAW_DIR MEASURE_RAW.json MEASURE_FINAL.json OUT.md [PLAN.json]
With PLAN.json it also prints the board gate (tools/gates.py). Pitch is left out ("mix") for processed monster,
name, join and whisper files: it is a mix of layers, not one voice (review m2).
"""
import os, sys, json, glob
from collections import defaultdict
import statistics as st


def main():
    raw, mr_p, mf_p, out = sys.argv[1:5]
    MR = json.load(open(mr_p))
    MF = json.load(open(mf_p))
    L = []
    # speed per engine
    sp = defaultdict(lambda: [0.0, 0.0, 0])
    run = 0
    for j in glob.glob(os.path.join(raw, "*.json")):
        d = json.load(open(j))
        e = sp[d["engine"]]
        e[0] += d["compute_s"]; e[1] += d["audio_s"]; e[2] += 1
        run += bool(d.get("runaway"))
    L.append("### Render speed on this machine (2 threads)\n")
    L.append("| engine | takes | audio s | compute s | s of compute per s of speech |")
    L.append("|---|---|---|---|---|")
    for k, (c, a, n) in sp.items():
        L.append(f"| {k} | {n} | {a:.1f} | {c:.1f} | {c/a:.2f} |")
    L.append(f"\nRunaway generations (no stop token before the cap): {run}.\n")
    # raw takes: recognition
    exact = sum(1 for r in MR if r["wer"] == 0)
    L.append(f"### Raw takes: {exact} of {len(MR)} recognised word for word\n")
    bad = [r for r in MR if r["wer"] > 0]
    if bad:
        L.append("| take | WER | heard |")
        L.append("|---|---|---|")
        for r in sorted(bad, key=lambda r: r["id"]):
            L.append(f'| {r["id"]} | {r["wer"]:.2f} | {r["heard"]} |')
    # finals, per file
    L.append(f"\n### Finished files: {sum(1 for r in MF if r['wer'] == 0)} of {len(MF)} recognised word for word\n")
    L.append("| file | WER | heard | F0 median Hz | F0 p10-p90 (st) | words/s energy | words/s word span | syll/s | LUFS | dBTP | lead s | trail s |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    mixed = ("m1", "m2", "m3", "name", "joined", "rest", "whisper")
    for r in MF:
        f0 = f'{r["f0_med"]:.0f}' if r.get("f0_med") else "-"
        rg = f'{r["f0_range_st"]:.1f}' if r.get("f0_range_st") else "-"
        if r.get("kind") in mixed:
            f0 = rg = "mix"
        lu = f'{r["lufs"]:.1f}' if r.get("lufs") is not None else "-"
        h = r["heard"].replace("|", "/")
        L.append(f'| {r["id"]} | {r["wer"]:.2f} | {h} | {f0} | {rg} | {r.get("wps") or "-"} | {r.get("wps_words") or "-"} | {r.get("sps") or "-"} | '
                 f'{lu} | {r["tp"]:.1f} | {r["lead"]:.2f} | {r["trail"]:.2f} |')
    # per candidate
    g = defaultdict(list)
    for r in MF:
        i = r["id"]
        key = "_".join(i.split("_")[:2]) if i.split("_")[0] in ("danny", "marcus", "priya", "gus", "pa") else None
        if i.startswith("mon_"):
            key = "monster " + i.rsplit("_", 1)[-1]
        if i.startswith("name_"):
            key = "name bank"
        if i.startswith("join_"):
            key = "joined name lines"
        if i.startswith("eng_"):
            key = i
        if key:
            g[key].append(r)
    L.append("\n### Per candidate (finished files)\n")
    L.append("| candidate | files | word for word | F0 median of medians Hz | F0 spread across lines (st) | syll/s median | LUFS median |")
    L.append("|---|---|---|---|---|---|---|")
    import math
    for k in sorted(g):
        rs = g[k]
        f0s = [r["f0_med"] for r in rs if r.get("f0_med") and r.get("kind") not in mixed]
        med = st.median(f0s) if f0s else None
        spread = (12 * math.log2(max(f0s) / min(f0s))) if len(f0s) > 1 else 0
        sps = [r["sps"] for r in rs if r.get("sps")]
        lu = [r["lufs"] for r in rs if r.get("lufs") is not None]
        L.append(f'| {k} | {len(rs)} | {sum(1 for r in rs if r["wer"] == 0)} | {med and round(med)} | {spread:.1f} | '
                 f'{st.median(sps) if sps else "-"} | {st.median(lu) if lu else "-"} |')
    if len(sys.argv) > 5:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import gates
        plan = json.load(open(sys.argv[5]))
        bad = gates.check(plan, {r["id"]: r for r in MF})
        L.append(f"\n### Board gate (word for word; dialogue {gates.RATE_MIN}-{gates.RATE_MAX} words/s on both measures)\n")
        L.append(f"{len(gates.dialogue_lines(plan))} dialogue lines checked; failures: {len(bad)}")
        for b in bad:
            L.append(f"- {b[0]}: {b[1]}")
    open(out, "w").write("\n".join(L) + "\n")
    print("\n".join(L[:12]))


if __name__ == "__main__":
    main()
