# python3 -I meta.py <png>...  : look for provenance / AI markers in the raw bytes (no decoding)
import sys
for p in sys.argv[1:]:
    b = open(p, 'rb').read()
    hits = [k for k in (b'c2pa', b'C2PA', b'jumb', b'contentauth', b'tEXt', b'iTXt', b'eXIf', b'Higgsfield', b'higgsfield', b'watermark') if k in b]
    print(p.split('/')[-1], len(b), [h.decode() for h in hits])
