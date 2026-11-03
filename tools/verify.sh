#!/usr/bin/env bash
# The map tool's gates: rojo build + sourcemap, luau-lsp strict, selene, stylua and the Lune world checks.
# Exits non-zero if any gate fails. See tools/README.md.
#
#   tools/verify.sh             every gate (runs from the repo root, whatever the cwd)
#   tools/verify.sh --no-lune   skip the Lune checks (the quick lint + type gate)
#
# rojo, selene, stylua and lune come from PATH (`rokit install`). luau-lsp comes from $LUAU_LSP, else PATH; its Roblox
# type definitions from $LUAU_DEFS, else ./globalTypes.d.luau.

set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$(pwd)
TARGETS=(src tests)
LUNE=1
[ "${1:-}" = "--no-lune" ] && LUNE=0

OUT=$(mktemp -d "${TMPDIR:-/tmp}/rovloc-verify.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
fail=0

LSP=${LUAU_LSP:-$(command -v luau-lsp || true)}
DEFS=${LUAU_DEFS:-$ROOT/globalTypes.d.luau}

echo "== rojo build + sourcemap"
if rojo build default.project.json -o "$OUT/Rovloc.rbxl" >/dev/null 2>"$OUT/rojo.log" \
	&& rojo sourcemap default.project.json -o "$OUT/sourcemap.json" >/dev/null 2>>"$OUT/rojo.log"; then
	echo "clean"
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

if [ "$LUNE" -eq 1 ]; then
	echo "== Lune world checks (layouts, world build, world specs)"
	if TMPDIR="$OUT" lune run tools/lune/check.luau all >"$OUT/lune.log" 2>&1; then
		grep -E '^== |^  ok   [A-Z][A-Za-z0-9_]+ \(|^  built|^  [0-9]+ passed|^all checks passed' "$OUT/lune.log"
	else
		grep -E '^== |FAIL|failure|^  [0-9]+ passed|error' "$OUT/lune.log" | head -60
		fail=1
	fi
fi

if [ "$fail" -eq 0 ]; then echo "ALL GATES GREEN"; else echo "GATES FAILED"; fi
exit "$fail"
