#!/bin/bash
V=/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/voices
H=/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/tools/run-heavy
P="$V/venv/bin/python -I -W ignore"
cd /tmp
OMP_NUM_THREADS=2 $H cpu $P $V/tools3/monster3.py build $V/out3/mon3 || exit 1
$P $V/tools3/prod3.py items $V/out3/prodtakes/lines_prod.json $V/out3/prodtakes
BATCH_SECONDS=100 $V/tools2/loop.sh $V/out3/mon3/measure.log $P $V/tools2/analyze.py $V/out3/mon3/measure.json --asr $V/out3/mon3/items.json || exit 1
BATCH_SECONDS=100 $V/tools2/loop.sh $V/out3/prodtakes/measure.log $P $V/tools2/analyze.py $V/out3/prodtakes/measure.json --asr $V/out3/prodtakes/items.json || exit 1
echo CHAIN2 DONE
