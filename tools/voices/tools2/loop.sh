#!/bin/bash
# loop.sh LOG cmd... : run cmd as run-heavy cpu batches until it exits 0 (exit 3 = more to do)
H=/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/tools/run-heavy
log=$1; shift
cd /tmp
for i in $(seq 1 60); do
  OMP_NUM_THREADS=2 $H cpu "$@" >> "$log" 2>&1; rc=$?
  [ $rc -eq 3 ] || { echo "rc=$rc" >> "$log"; exit $rc; }
done
