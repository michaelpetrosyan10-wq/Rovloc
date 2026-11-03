#!/bin/bash
# Gate a subset of files: luau-lsp strict analysis + selene + stylua --check on just the given paths.
# Usage: tools/verify-files.sh <file or dir>...   (env LUAU_LSP, LUAU_DEFS, SOURCEMAP may override tool paths)
set -u
cd "$(dirname "$0")/.." || exit 2
LSP=${LUAU_LSP:-luau-lsp}
DEFS=${LUAU_DEFS:-globalTypes.d.luau}
SM=${SOURCEMAP:-$(mktemp -t rovloc-sourcemap.XXXXXX.json)}
fail=0
PROJECT=default.project.json
[ -f test.project.json ] && PROJECT=test.project.json
rojo sourcemap "$PROJECT" -o "$SM" >/dev/null 2>&1 || { echo "rojo sourcemap failed"; exit 2; }
out=$("$LSP" analyze --platform=roblox --sourcemap="$SM" --definitions="$DEFS" "$@" 2>&1 | grep -v '^\[INFO\]' | grep -v 'client does not allow')
if [ -n "$out" ]; then echo "$out" | sed "s#$(pwd)/##"; fail=1; else echo "luau-lsp: clean"; fi
selene "$@" >/tmp/rovloc-selene.$$ 2>&1 && echo "selene: clean" || { cat /tmp/rovloc-selene.$$ | tail -40; fail=1; }
stylua --check "$@" >/dev/null 2>&1 && echo "stylua: clean" || { echo "stylua: needs formatting (run: stylua $*)"; fail=1; }
rm -f /tmp/rovloc-selene.$$
exit $fail
