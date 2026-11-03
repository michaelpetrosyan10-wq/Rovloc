#!/usr/bin/env bash
# The Luau gates: the Roblox game (runtime + shared world builder) and its specs. Exits non-zero if any gate fails.
# See tools/README.md.
#
#   tools/verify.sh             every gate (runs from the repo root, whatever the cwd)
#   tools/verify.sh --no-lune   skip the Lune checks (the quick project + lint + type gate)
#
# rojo, selene, stylua and lune come from PATH (`rokit install`). luau-lsp comes from $LUAU_LSP, else PATH; its Roblox
# type definitions from $LUAU_DEFS, else ./globalTypes.d.luau. capscan reads the Roblox API dump from $API_DUMP, else
# ./API-Dump.json; without one it is reported as skipped (CI always has one). RBXL_OUT=<path> keeps the built place.

set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$(pwd)
TARGETS=(src tests)
LUNE=1
[ "${1:-}" = "--no-lune" ] && LUNE=0

OUT=$(mktemp -d "${TMPDIR:-/tmp}/rovloc-verify.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
fail=0
skipped=()

LSP=${LUAU_LSP:-$(command -v luau-lsp || true)}
DEFS=${LUAU_DEFS:-$ROOT/globalTypes.d.luau}
DUMP=${API_DUMP:-$ROOT/API-Dump.json}

# default.project.json is the game (what ships); test.project.json is the same tree plus tests/ under
# ServerScriptService.Tests (Lune, luau-lsp and Studio spec runs); syncback.project.json maps only the script folders.
echo "== project files"
if python3 - <<'PY' >"$OUT/project.log" 2>&1; then
import json, os

def paths(node, out):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$path":
                out.add(value)
            else:
                paths(value, out)

problems = []
names = ("default.project.json", "test.project.json", "syncback.project.json")
projects = {name: json.load(open(name)) for name in names}
mapped = {}
for name, project in projects.items():
    mapped[name] = set()
    paths(project["tree"], mapped[name])
    problems += [f"{name}: $path {p} does not exist" for p in sorted(mapped[name]) if not os.path.exists(p)]
game = projects["default.project.json"]["tree"]
pins = [
    ("Workspace", "StreamingEnabled", False),
    ("Workspace", "SignalBehavior", "Deferred"),
    ("Players", "CharacterAutoLoads", False),
    ("StarterPlayer", "AvatarJointUpgrade", "Disabled"),
    ("StarterPlayer", "LuaCharacterController", "Legacy"),
    ("Lighting", "Technology", "Future"),
]
for service, prop, want in pins:
    got = game.get(service, {}).get("$properties", {}).get(prop)
    if got != want:
        problems.append(f"default.project.json: {service}.{prop} is {got!r}, pinned to {want!r}")
if "tests" in mapped["default.project.json"]:
    problems.append("default.project.json ships tests/: they belong in test.project.json only")
test = json.loads(json.dumps(projects["test.project.json"]["tree"]))
if test.get("ServerScriptService", {}).pop("Tests", None) != {"$path": "tests"}:
    problems.append("test.project.json: ServerScriptService.Tests must map tests/")
if test != game:
    problems.append("test.project.json: its tree must be default.project.json's plus ServerScriptService.Tests")
for p in sorted(mapped["syncback.project.json"] - mapped["default.project.json"]):
    problems.append(f"syncback.project.json maps {p}, which the game does not")
print("\n".join(problems))
raise SystemExit(1 if problems else 0)
PY
	echo "clean"
else
	cat "$OUT/project.log"
	fail=1
fi

echo "== rojo build + sourcemap"
if rojo build default.project.json -o "$OUT/Rovloc.rbxl" >/dev/null 2>"$OUT/rojo.log" \
	&& rojo build test.project.json -o "$OUT/Rovloc-Tests.rbxl" >/dev/null 2>>"$OUT/rojo.log" \
	&& rojo sourcemap test.project.json -o "$OUT/sourcemap.json" >/dev/null 2>>"$OUT/rojo.log"; then
	echo "clean ($(du -k "$OUT/Rovloc.rbxl" | cut -f1) KB place)"
	if [ -n "${RBXL_OUT:-}" ]; then cp "$OUT/Rovloc.rbxl" "$RBXL_OUT"; fi
else
	cat "$OUT/rojo.log"
	fail=1
fi

echo "== luau-lsp analyze (strict)"
if [ -z "$LSP" ] || [ ! -x "$LSP" ]; then
	echo "luau-lsp not found: set LUAU_LSP or put luau-lsp on PATH"
	fail=1
elif [ ! -f "$DEFS" ]; then
	echo "no type definitions at $DEFS: set LUAU_DEFS (see tools/README.md)"
	fail=1
elif [ ! -f "$OUT/sourcemap.json" ]; then
	echo "skipped: no sourcemap"
	fail=1
else
	"$LSP" analyze --platform=roblox --sourcemap="$OUT/sourcemap.json" --definitions="$DEFS" "${TARGETS[@]}" 2>&1 \
		| grep -v '^\[INFO\]' | grep -v 'client does not allow' >"$OUT/lsp.log"
	if [ -s "$OUT/lsp.log" ]; then
		sed "s#$ROOT/##" "$OUT/lsp.log" | head -"${MAXLINES:-80}"
		echo "luau-lsp: $(wc -l <"$OUT/lsp.log") line(s) of issues"
		fail=1
	else
		echo "clean"
	fi
fi

echo "== selene"
if selene "${TARGETS[@]}" >"$OUT/selene.log" 2>&1; then
	echo "clean"
else
	grep -E '^(error|warning)|┌─' "$OUT/selene.log" | head -60
	tail -4 "$OUT/selene.log"
	fail=1
fi

echo "== stylua"
if stylua --check "${TARGETS[@]}" >"$OUT/stylua.log" 2>&1; then
	echo "clean"
else
	grep -E '^Diff in' "$OUT/stylua.log" | head -30
	fail=1
fi

echo "== capscan (restricted engine property writes)"
if [ ! -f "$DUMP" ]; then
	echo "skipped: no API dump at $DUMP (set API_DUMP; see tools/README.md)"
	skipped+=(capscan)
elif python3 tools/capscan.py "$DUMP" src >"$OUT/capscan.log" 2>&1; then
	tail -1 "$OUT/capscan.log"
else
	cat "$OUT/capscan.log" | head -40
	fail=1
fi

if [ "$LUNE" -eq 1 ]; then
	echo "== Lune checks (layouts, world build, every spec, server lifecycle)"
	if TMPDIR="$OUT" lune run tools/lune/check.luau all >"$OUT/lune.log" 2>&1; then
		grep -E '^== |^  ok   [^/]*$|^  built|^  [0-9]+ passed|^all checks passed' "$OUT/lune.log"
	else
		grep -E '^== |FAIL|failure|^  [0-9]+ passed|error' "$OUT/lune.log" | head -60
		fail=1
	fi
else
	skipped+=(lune)
fi

if [ "$fail" -ne 0 ]; then
	echo "GATES FAILED"
elif [ "${#skipped[@]}" -gt 0 ]; then
	echo "ALL GATES GREEN (skipped: ${skipped[*]})"
else
	echo "ALL GATES GREEN"
fi
exit "$fail"
