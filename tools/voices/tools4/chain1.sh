#!/bin/bash
# round 4 render chain (resumable: re-run; finished takes are skipped)
V=/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/voices
P="$V/venv/bin/python -I -W ignore"; L=$V/tools2/loop.sh; R=$V/tools2/render2.py; M=$V/models
cd /tmp
$L $V/out4/refs/render.log $P $R $M $V/out4/refs/lines_teachref.json $V/out4/refs || exit 1
cp -n $V/out4/refs/teach2_g1.wav $V/out4/refs/teach2_g1.wav 2>/dev/null
$L $V/out4/refs/render.log $P $R $M $V/out4/refs/lines_teachref2.json $V/out4/refs || exit 1
[ -f $V/out4/refs/teach2_g2.wav ] || cp $V/out4/refs/teach2_g2s1.wav $V/out4/refs/teach2_g2.wav 2>/dev/null
for d in kids nv mon names; do
  echo "== $d $(date -u +%H:%M)"
  $L $V/out4/$d/render.log $P $R $M $V/out4/$d/lines_$d.json $V/out4/$d || exit 1
done
echo "chain1 done $(date -u +%H:%M)"
