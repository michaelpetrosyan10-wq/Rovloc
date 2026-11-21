#!/bin/bash
# usage: fetch.sh <set> <name> <url>   -> higg/dl/<set>/<name>.<ext> and higg/view/<name>.jpg (640 wide)
S=/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad
set -u
setd="$S/higg/dl/$1"; name="$2"; url="$3"
mkdir -p "$setd"
ext="${url%%\?*}"; ext="${ext##*.}"
case "$ext" in png|jpg|jpeg|webp) ;; *) ext=png;; esac
out="$setd/$name.$ext"
code=$(curl -sS -m 90 -o "$out" -w '%{http_code}' "$url")
size=$(stat -c %s "$out" 2>/dev/null || echo 0)
ffmpeg -nostdin -loglevel error -y -i "$out" -vf "scale=640:-2" -q:v 4 "$S/higg/view/$name.jpg" && v=ok || v=FAIL
echo "$name http=$code size=$size preview=$v file=$out"
