#!/bin/bash
# batches.sh LOG <python script> <args...>: re-runs a time-boxed tool (exit 3 = more to do) as separate run-heavy
# cpu batches, so other jobs get the machine between batches.
V=/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/voices
H=/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/tools/run-heavy
log=$1; shift
export OMP_NUM_THREADS=2 PYTHONWARNINGS=ignore BATCH_SECONDS=${BATCH_SECONDS:-110}
cd /tmp
for i in $(seq 1 60); do
  $H cpu $V/venv/bin/python -I "$@" >> "$log" 2>&1
  rc=$?
  echo "== batch $i rc=$rc $(date -u +%H:%M:%S)" >> "$log"
  [ $rc = 3 ] || exit $rc
  sleep 2
done
