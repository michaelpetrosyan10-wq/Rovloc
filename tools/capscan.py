#!/usr/bin/env python3
"""Flags writes to engine properties that game scripts are not allowed to write.

Some properties look ordinary but are gated: plugin/Open Cloud only (e.g. Lighting.LightingStyle), Roblox-script
security, read-only or not scriptable. Writing one throws at run time on a live server, and neither luau-lsp nor
the Lune harness catches it. This scans src/ for `.Property = value` and reports every property whose every
declaration (across the classes the code creates, gets or checks) is write-restricted, using the Roblox API dump.

usage: tools/capscan.py <API-Dump.json> [src_dir]
CI fetches the dump from the Roblox client tracker; exits 1 when anything is flagged.
"""
import glob
import json
import re
import sys

RESTRICTED_CAPABILITIES = {"PluginOrOpenCloud", "Plugin", "LocalUser", "RobloxScript", "Unassigned", "CapabilityControl"}


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    dump = json.load(open(sys.argv[1], encoding="utf-8"))
    src = sys.argv[2] if len(sys.argv) > 2 else "src"
    classes = {c["Name"]: c for c in dump["Classes"]}
    files = sorted(glob.glob(f"{src}/**/*.luau", recursive=True))
    code = "".join(open(f, encoding="utf-8").read() for f in files)

    used = set(re.findall(r'Instance\.new\("([A-Za-z]+)"\)', code))
    used |= set(re.findall(r'GetService\("([A-Za-z]+)"\)', code))
    used |= set(re.findall(r':IsA\("([A-Za-z]+)"\)', code))
    used |= set(re.findall(r'FindFirstChildOfClass\("([A-Za-z]+)"\)', code))
    used |= {"Lighting", "Workspace", "Terrain", "Camera", "Player", "Humanoid", "Model", "Part", "Clouds", "Atmosphere"}

    def chain(name: str) -> list[str]:
        out = []
        while name and name in classes:
            out.append(name)
            name = classes[name]["Superclass"]
        return out

    reachable = set()
    for name in used:
        reachable |= set(chain(name))

    verdict: dict[str, list[tuple[str, bool, str]]] = {}
    for class_name in reachable:
        for member in classes[class_name]["Members"]:
            if member["MemberType"] != "Property":
                continue
            caps = member.get("Capabilities")
            write_caps = caps.get("Write") if isinstance(caps, dict) else None
            security = member.get("Security", {})
            write_security = security.get("Write") if isinstance(security, dict) else security
            tags = member.get("Tags") or []
            reasons = []
            if write_caps and RESTRICTED_CAPABILITIES & set(write_caps):
                reasons.append("capability " + ",".join(write_caps))
            if write_security and write_security != "None":
                reasons.append("security " + write_security)
            if "ReadOnly" in tags:
                reasons.append("read-only")
            if "NotScriptable" in tags:
                reasons.append("not scriptable")
            verdict.setdefault(member["Name"], []).append((class_name, bool(reasons), "; ".join(reasons)))

    flagged = 0
    for path in files:
        for number, line in enumerate(open(path, encoding="utf-8"), 1):
            stripped = line.strip()
            if stripped.startswith("--"):
                continue
            for match in re.finditer(r"\.([A-Z][A-Za-z0-9]+)\s*=[^=]", line):
                name = match.group(1)
                entries = verdict.get(name)
                if entries and all(restricted for _, restricted, _ in entries):
                    flagged += 1
                    where = ", ".join(f"{c} ({why})" for c, _, why in entries[:3])
                    print(f"{path}:{number}: writes {name}: {where}\n    {stripped[:120]}")
    if flagged:
        print(f"{flagged} restricted property write(s)")
        return 1
    print("capscan: no restricted property writes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
