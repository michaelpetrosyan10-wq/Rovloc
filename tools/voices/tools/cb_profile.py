import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import cbturbo_engine as cb
t=time.time(); e=cb.CBTurboEngine(sys.argv[1]); print('load',round(time.time()-t,1))
for n in ['enc','emb','lm','dec']:
    s=getattr(e,n); r=s.run
    def wrap(*a, _r=r, _n=n, **k):
        t=time.time(); o=_r(*a, **k); T[_n]=T.get(_n,0)+time.time()-t; C[_n]=C.get(_n,0)+1; return o
    s.run=wrap
T={};C={}
t=time.time(); a,sr=e.render(sys.argv[3], {"ref": sys.argv[2]}, seed=1); print('total',round(time.time()-t,1),'audio',len(a)/sr, {k:round(v,1) for k,v in T.items()}, C)
