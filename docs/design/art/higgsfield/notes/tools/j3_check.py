import sys, json, numpy as np
from PIL import Image, ImageDraw
H=sys.argv[1]; P=H+'/pack3/'; J=H+'/judge3/'
def L(n): return Image.open(P+n)
# 3x3 tiles
for n in ['skin-tile.png','skin-tile-seamless.png','cloth-tile.png','cloth-tile-seamless.png']:
    im=L(n).convert('RGB'); a=np.asarray(im).astype(float)
    g=a.mean(2); h,w=g.shape
    q=[g[:h//2,:w//2].mean(),g[:h//2,w//2:].mean(),g[h//2:,:w//2].mean(),g[h//2:,w//2:].mean(),g[h//4:3*h//4,w//4:3*w//4].mean()]
    wrapx=np.abs(a[:,0]-a[:,-1]).mean(); wrapy=np.abs(a[0]-a[-1]).mean(); nb=np.abs(a[:,1]-a[:,0]).mean()
    print(n,im.size,'quadrants+centre',[round(x,1) for x in q],'wrapx',round(wrapx,1),'wrapy',round(wrapy,1),'neigh',round(nb,1))
    s=im.resize((683,683),Image.LANCZOS); t=Image.new('RGB',(2049,2049))
    for i in range(3):
        for j in range(3): t.paste(s,(i*683,j*683))
    t.save(J+n.replace('.png','-3x3.jpg'),quality=88)
    # crop at seam center full res, 2x2 of tile, center crop 800
    t2=Image.new('RGB',(w*2,h*2))
    for i in range(2):
        for j in range(2): t2.paste(im,(i*w,j*h))
    t2.crop((w-400,h-400,w+400,h+400)).save(J+n.replace('.png','-seamzoom.jpg'),quality=90)
# stains over colours
for n in ['stain-water.png','stain-mould.png']:
    im=L(n); print(n,im.mode,im.size)
    a=np.asarray(im).astype(float); al=a[...,3]
    print(' alpha border max',al[0].max(),al[-1].max(),al[:,0].max(),al[:,-1].max(),'alpha>0 frac',(al>0).mean().round(3),'mean',al.mean().round(1))
    outs=[]
    for c in [(200,200,190),(120,140,120),(60,60,70),(255,255,255)]:
        bg=Image.new('RGBA',im.size,c+(255,)); bg.alpha_composite(im); outs.append(bg.convert('RGB').resize((600,600)))
    al_im=Image.fromarray(al.astype('uint8')).convert('RGB').resize((600,600))
    sh=Image.new('RGB',(3000,600));
    for i,o in enumerate(outs+[al_im]): sh.paste(o,(i*600,0))
    sh.save(J+n.replace('.png','-over.jpg'),quality=88)
# skyline wrap
im=L('skyline-wrap.jpg'); w,h=im.size; t=Image.new('RGB',(w*2,h)); t.paste(im,(0,0)); t.paste(im,(w,0))
t.resize((w,h//2)).save(J+'skyline-wrap-2x.jpg',quality=88)
t.crop((w-400,0,w+400,h)).save(J+'skyline-wrap-seam.jpg',quality=90)
a=np.asarray(im).astype(float); print('skyline wrap edge diff',np.abs(a[:,0]-a[:,-1]).mean().round(2),'neigh',np.abs(a[:,1]-a[:,0]).mean().round(2))
# landmarks
lm=json.load(open(P+'landmarks.json'))
for n in ['face-front.png','hand-back.png','hand-palm.png']:
    im=L(n).convert('RGB'); d=ImageDraw.Draw(im)
    def walk(o,k=''):
        if isinstance(o,dict):
            for kk,v in o.items(): walk(v,k+'.'+kk)
        elif isinstance(o,list) and len(o)==2 and all(isinstance(x,(int,float)) for x in o) and 'size' not in k:
            x,y=o; d.ellipse((x-12,y-12,x+12,y+12),outline=(255,0,0),width=5); d.line((x-20,y,x+20,y),fill=(0,255,0),width=3)
    walk(lm[n]); im.save(J+n.replace('.png','-lm.jpg'),quality=85)
# face symmetry
im=np.asarray(L('face-front.png').convert('L')).astype(float)
cx=398; w=min(cx,im.shape[1]-cx-1)
Lh=im[:,cx-w:cx][:,::-1]; R=im[:,cx+1:cx+1+w]
print('face mirror absdiff',np.abs(Lh-R).mean().round(2))
mask=im>40; rows=np.where(mask.any(1))[0]; print('face rows',rows.min(),rows.max())
for y in [100,381,620,900,1200,1369,1600,1800]:
    xs=np.where(mask[y])[0]; print(' y',y,'width',xs.max()-xs.min() if len(xs) else 0, xs.min() if len(xs) else None)
# brightness across face center column band
print('face lum by band', [round(im[y0:y0+200, 300:500][im[y0:y0+200,300:500]>40].mean(),1) for y0 in range(0,1800,200)])
