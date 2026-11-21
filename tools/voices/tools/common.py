"""Shared helpers for the ROVLOC voice tools. Paths always come in as arguments; nothing runs from a download dir."""
import os
os.environ.setdefault("OMP_NUM_THREADS", "2")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
import json
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

THREADS = 2
V = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def ort_session(path):
    import onnxruntime as rt
    so = rt.SessionOptions()
    so.intra_op_num_threads = THREADS
    so.inter_op_num_threads = 1
    so.execution_mode = rt.ExecutionMode.ORT_SEQUENTIAL
    so.graph_optimization_level = rt.GraphOptimizationLevel.ORT_ENABLE_ALL
    return rt.InferenceSession(path, sess_options=so, providers=["CPUExecutionProvider"])


def load(path, sr=None):
    x, r = sf.read(path, dtype="float32", always_2d=True)
    x = x.mean(axis=1)
    if sr and r != sr:
        from math import gcd
        g = gcd(sr, r)
        x = resample_poly(x, sr // g, r // g).astype(np.float32)
        r = sr
    return x, r


def save(path, x, sr):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sf.write(path, np.clip(x, -1, 1).astype(np.float32), sr, subtype="FLOAT")


def read_json(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def write_json(p, d):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=1, ensure_ascii=False)
