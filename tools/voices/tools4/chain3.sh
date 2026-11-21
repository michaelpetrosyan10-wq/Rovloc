#!/bin/bash
# round 4 chain 3 (chain 2 with the names rendered 4 to a call, then monster seed 2) (resumable: re-run it; every step skips finished work)
V=/tmp/claude-0/-home-user-Rovloc/44e475d9-c8d0-52a2-84e0-3ac758fed249/scratchpad/voices
P="$V/venv/bin/python -I -W ignore"; L=$V/tools2/loop.sh; R=$V/tools2/render2.py; M=$V/models; O=$V/out4; T=$V/tools4
export BATCH_SECONDS=100
cd /tmp
st() { echo "== $1 $(date -u +%H:%M)"; }
st kids;  $L $O/kids/render.log $P $R $M $O/kids/lines_kids.json $O/kids || exit 1
$P $T/kids4.py items $O/kids/lines_kids.json $O/kids
st kidsasr; $L $O/kids/measure.log $P $V/tools2/analyze.py $O/kids/measure.json --asr $O/kids/items.json || exit 1
$P $T/kids4.py pick $O/kids/lines_kids.json $O/kids $O/kids/measure.json $V/prod2/kids > $O/kids/pick.log 2>&1
$P $T/extra4.py plan $V/prod2/kids/kids_pick.json $O/extra
for d in nv extra mon; do st $d; f=$O/$d/lines_$d.json; $L $O/$d/render.log $P $R $M $f $O/$d || exit 1; done
st nvasr; $P $T/kids4.py items $O/nv/lines_nv.json $O/nv
$L $O/nv/measure.log $P $V/tools2/analyze.py $O/nv/measure.json --asr $O/nv/items.json || exit 1
$P $T/kids4.py nvpick $O/nv/lines_nv.json $O/nv $O/nv/measure.json $V/prod2/kids > $O/nv/pick.log 2>&1
st extraasr; $P $T/extra4.py cands $V/prod2/kids/kids_pick.json $O/kids $O/kids/measure.json $O/extra $O/extra/cand
$L $O/extra/asr.log $P $T/asr4.py $O/extra/cand/asr.json $O/extra/cand/items.json || exit 1
$P $T/extra4.py pick $O/extra/cand $O/extra/cand/asr.json > $O/extra/pick.log 2>&1
st monasr; $P $T/mon4.py cands $O/mon/lines_mon.json $O/mon $O/mon/cand
$L $O/mon/asr.log $P $T/asr4.py $O/mon/cand/asr.json $O/mon/cand/items.json || exit 1
$P $T/mon4.py retake $O/mon/lines_mon.json $O/mon/cand $O/mon/cand/asr.json 3,4 $O/mon/lines_mon_re.json
st monre; $L $O/mon/render.log $P $R $M $O/mon/lines_mon_re.json $O/mon || exit 1
$P $T/mon4.py cands $O/mon/lines_mon.json,$O/mon/lines_mon_re.json $O/mon $O/mon/cand
$L $O/mon/asr.log $P $T/asr4.py $O/mon/cand/asr.json $O/mon/cand/items.json || exit 1
$P $T/mon4.py pick $O/mon/lines_mon.json,$O/mon/lines_mon_re.json $O/mon/cand $O/mon/cand/asr.json > $O/mon/pick.log 2>&1
NB="$P $T/namebatch4.py"; NL=$O/names/lines_names_d.json,$O/names/lines_names_q.json
st namesd; $L $O/names/render.log $NB $M $O/names/lines_names_d.json $O/names 4 || exit 1
st namesq; $L $O/names/render.log $NB $M $O/names/lines_names_q.json $O/names 4 || exit 1
$P $T/namefall4.py $NL $O/names $O/names/lines_names_single.json
$L $O/names/render.log $P $R $M $O/names/lines_names_single.json $O/names || exit 1
st namesasr; $P $T/bank4.py cands $NL $O/names $O/names/cand
$L $O/names/asr.log $P $T/asr4.py $O/names/cand/asr.json $O/names/cand/items.json || exit 1
$P $T/bank4.py retake $NL $O/names/cand $O/names/cand/asr.json 2,3 $O/names/lines_names_re.json
st namesre; $L $O/names/render.log $NB $M $O/names/lines_names_re.json $O/names 4 || exit 1
$P $T/namefall4.py $O/names/lines_names_re.json $O/names $O/names/lines_names_re_single.json
$L $O/names/render.log $P $R $M $O/names/lines_names_re_single.json $O/names || exit 1
NL2=$NL,$O/names/lines_names_re.json
$P $T/bank4.py cands $NL2 $O/names $O/names/cand
$L $O/names/asr.log $P $T/asr4.py $O/names/cand/asr.json $O/names/cand/items.json || exit 1
$P $T/bank4.py pick $NL2 $O/names/cand $O/names/cand/asr.json > $O/names/pick.log 2>&1
st mons2; $L $O/mon/render.log $P $R $M $O/mon/lines_mon_s2.json $O/mon || exit 1
ML=$O/mon/lines_mon.json,$O/mon/lines_mon_re.json,$O/mon/lines_mon_s2.json
$P $T/mon4.py cands $ML $O/mon $O/mon/cand
$L $O/mon/asr.log $P $T/asr4.py $O/mon/cand/asr.json $O/mon/cand/items.json || exit 1
$P $T/mon4.py pick $ML $O/mon/cand $O/mon/cand/asr.json > $O/mon/pick.log 2>&1
st done
