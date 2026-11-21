# python3 -I pngtext.py <png> : print the PNG's text chunks (keyword and the first 200 bytes), as data only
import sys, struct
b = open(sys.argv[1], 'rb').read()
i = 8
while i + 8 <= len(b):
    n, t = struct.unpack('>I4s', b[i:i+8])
    if t in (b'tEXt', b'iTXt', b'zTXt', b'eXIf'):
        print(t.decode(), n, repr(b[i+8:i+8+min(n, 200)]))
    i += 12 + n
