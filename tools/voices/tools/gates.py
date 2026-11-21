"""The board's gates, shared by build_board.py and summarise.py.

Every dialogue line on the board (the characters' candidates except the PA, and the engine comparison) must be
recognised word for word AND speak at 2.0-3.6 words/s on BOTH rate measures (measure.py): the energy span (wps, or
wps_eff for a line with a [laugh]/[groan] tag) and the recogniser's word span (wps_words, or wps_words_np for a
tagged line). Every monster, whisper and name file on the board must be recognised word for word.
The PA ("Lockdown. Lockdown.", two words and a hall echo) is gated on recognition only.
"""
RATE_MIN, RATE_MAX = 2.0, 3.6


def dialogue_lines(plan):
    """(file id, tagged, engine) for every gated dialogue line."""
    out = []
    for ch in plan["characters"]:
        if ch["key"] == "pa":
            continue
        for c in ch["candidates"]:
            for ln in c["lines"]:
                out.append((ln["id"], bool(ln["note"]) and any(k in ln["note"] for k in ("laugh", "groan")),
                            c["engine"]))
    for it in plan["engines"]["items"]:
        out.append((it["id"], False, it["engine"]))
    return out


def rates(r, tagged):
    a = r.get("wps_eff") if tagged else r.get("wps")
    b = r.get("wps_words_np") if tagged else r.get("wps_words")
    return a, b


def check(plan, M, extra_ids=()):
    """list of (id, problem) for every gate failure."""
    bad = []
    for fid, tagged, _ in dialogue_lines(plan):
        r = M.get(fid)
        if r is None:
            bad.append((fid, "not measured"))
            continue
        if r["wer"] != 0:
            bad.append((fid, f'heard "{r["heard"]}"'))
        a, b = rates(r, tagged)
        if a is None or b is None or not (RATE_MIN <= a <= RATE_MAX and RATE_MIN <= b <= RATE_MAX):
            bad.append((fid, f"rate {a} / {b} words/s outside {RATE_MIN}-{RATE_MAX}"))
    for fid in extra_ids:
        r = M.get(fid)
        if r is None:
            bad.append((fid, "not measured"))
        elif r["wer"] != 0:
            bad.append((fid, f'heard "{r["heard"]}"'))
    return bad
