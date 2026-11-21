#!/bin/bash
V=/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/voices
P="$V/venv/bin/python -I -W ignore"; cd /tmp
$V/tools2/loop.sh $V/out3/prodtakes/render.log $P $V/tools2/render2.py $V/models $V/out3/prodtakes/lines_prod_all.json $V/out3/prodtakes || exit 1
$P $V/tools3/prod3.py items $V/out3/prodtakes/lines_prod_all.json $V/out3/prodtakes
BATCH_SECONDS=100 $V/tools2/loop.sh $V/out3/prodtakes/measure.log $P $V/tools2/analyze.py $V/out3/prodtakes/measure.json --asr $V/out3/prodtakes/items.json || exit 1
echo CHAIN3 DONE
