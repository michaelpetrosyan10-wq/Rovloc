#!/bin/bash
# Rebuild every file of the voice spike, in order. Idempotent: renders and measurements are cached by content, so a
# re-run only redoes what changed. Heavy steps go through run-heavy in batches of <= ~110 s (batches.sh).
#   usage: tools/rebuild.sh            (from anywhere)
# Fresh machine first:  python3.13 -m venv $V/venv && $V/venv/bin/pip install --no-cache-dir -r $V/tools/requirements.lock
#   (setuptools must stay < 81: pyworld 0.3.5 imports pkg_resources). Models: see REPORT.txt "LICENCES AND PROVENANCE"
#   for the repo ids, revisions and sha256 (out/sha256-downloads.txt), placed under $V/models/{kokoro,cbturbo,kitten,whisper-small.en}.
set -e
V=/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/voices
H=/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/tools/run-heavy
PY="$V/venv/bin/python -I -W ignore"
export OMP_NUM_THREADS=2 PYTHONWARNINGS=ignore
cd /tmp
A=$V/out/aud
# 1 the cast: render lists for the reference clips and the takes, and the board plan
$PY $V/tools/cast.py $A $V/out/refs
# 2 reference clips (Kokoro built-in voices / blends, our WORLD shift) for the Chatterbox candidates
$V/tools/batches.sh $V/out/refs/render.log $V/tools/render.py $V/models $V/out/refs/lines.json $V/out/refs
# 3 the synthesised inhale (no recording)
$PY $V/tools/breath.py $V/out/breath_synth.wav 11
# 4 every take
$V/tools/batches.sh $A/render.log $V/tools/render.py $V/models $A/lines.json $A/raw
# 5 measure the raw takes (Whisper small.en, pitch, rate, loudness)
$PY $V/tools/items.py $A/lines.json $A/raw $A/items_raw.json
$V/tools/batches.sh $A/measure_raw.log $V/tools/measure.py $V/models/whisper-small.en $A/measure_raw.json $A/items_raw.json
# 6 pick, process, normalise (dialogue pauses + rate, Gus, PA, monster M1-M3 + bed, whispers, name bank + joins)
$H cpu $PY $V/tools/finish.py $A/plan.json $A/raw $A/measure_raw.json $A/final $V/out/breath_synth.wav
# 7 measure the finished files
$V/tools/batches.sh $A/measure_final.log $V/tools/measure.py $V/models/whisper-small.en $A/measure_final.json $A/final/items.json
# 8 the name take per name whose clip and join both pass
$PY $V/tools/select_names.py $A/plan.json $A/measure_final.json $A/final/names.json
# 9 the board (refuses to build if a gate fails), the tables, the board checks
$PY $V/tools/build_board.py $A/plan.json $A/final $A/measure_final.json $V/board
$PY $V/tools/summarise.py $A/raw $A/measure_raw.json $A/measure_final.json $A/summary.md $A/plan.json
$H cpu $PY $V/tools/board_check.py $V/board $V/models $A/board_check.json
