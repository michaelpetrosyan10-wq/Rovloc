"""Rebuild one round-1 line stage by stage so each stage can be measured on its own.
usage: stages.py OUTDIR  -> OUTDIR/<line>_<stage>.wav"""
import os, sys
T = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, T)
import numpy as np
from common import load, save
import finish as F
import voxfx as X
V = os.path.dirname(T)
out = sys.argv[1]
SR = 24000
def st(name, y):
    save(os.path.join(out, name + ".wav"), y, SR)
# 1) Danny B d6: ref (Kokoro am_michael, WORLD +3 st, formants x1.08) -> raw take t4 -> pause cut -> atempo 0.899 -> final
x, _ = load(f"{V}/out/aud/raw/danny_b_d6_t4.wav", SR)
st("db6_1raw", x)
y, cuts = F.shorten_pauses(F.trim(x.copy(), SR), SR); print("cuts", cuts)
st("db6_2pause", y)
z = F.trim(F.atempo(y, SR, 0.899), SR)
st("db6_3tempo", z)
# isolate the vocoder: WORLD analysis + resynthesis with NO change, and the Gus-type -1 st
st("db6_4world0", X.world_shift(y, SR))
st("db6_4world_m1", X.world_shift(y, SR, -1.0, 0.97))
# 2) Danny A d1: raw t2 -> atempo 0.852
x, _ = load(f"{V}/out/aud/raw/danny_a_d1_t2.wav", SR)
st("da1_1raw", F.trim(x.copy(), SR))
st("da1_3tempo", F.trim(F.atempo(F.trim(x.copy(), SR), SR, 0.852), SR))
st("da1_4world0", X.world_shift(F.trim(x.copy(), SR), SR))
# 3) monster: clean take -> M1/M2/M3 main layer only and full preset
x, _ = load(f"{V}/out/aud/raw/mon_x1_t1.wav", SR)
x = F.trim(x, SR, 0.02, 0.1)
st("mon1_1clean", x)
for p in ("m1", "m2", "m3"):
    P = X.PRESETS[p]
    st(f"mon1_{p}_main", X.world_shift(x, SR, P["pitch"], P["formant"], P["slow"], f0_range=P["f0_range"], jitter=P["jitter"]))
    st(f"mon1_{p}_full", X.monster(x, SR, p))
# 4) the references themselves (Kokoro, and the WORLD-shifted one)
for r in ("danny_a", "danny_b"):
    a, _ = load(f"{V}/out/refs/ref_{r}.wav", SR)
    st(f"ref_{r}", a)
