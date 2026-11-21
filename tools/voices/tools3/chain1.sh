#!/bin/bash
# round 3 render chain (resumable: re-run; finished items are skipped)
V=/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/voices
P="$V/venv/bin/python -I -W ignore"; R="$V/tools2/render2.py $V/models"
$V/tools2/loop.sh $V/out3/mon/render.log $P $R $V/out3/mon/lines_mon.json $V/out3/mon || exit 1
$V/tools2/loop.sh $V/out3/deep/render.log $P $R $V/out3/deep/lines_deepref.json $V/out3/deep || exit 1
$V/tools2/loop.sh $V/out3/deep/render.log $P $R $V/out3/deep/lines_deepref2.json $V/out3/deep || exit 1
$V/tools2/loop.sh $V/out3/deep/render.log $P $R $V/out3/deep/lines_deep.json $V/out3/deep || exit 1
$V/tools2/loop.sh $V/out3/prodtakes/render.log $P $R $V/out3/prodtakes/lines_prod.json $V/out3/prodtakes || exit 1
echo CHAIN1 DONE
