#!/usr/bin/env python3
# usage: use_official_kernel.py <official boot.firm> <our boot.firm> <out boot.firm>
# Keeps our sysmodules (section 0) and arm9 (section 2); takes arm11 (0x18000000) and the
# kernel11 extension (0x1FF80000) from the official FIRM byte for byte.
import struct, sys, hashlib
off_f = open(sys.argv[1], 'rb').read(); our_f = open(sys.argv[2], 'rb').read()
def secs(f):
    r = []
    for i in range(4):
        o, a, s, c = struct.unpack_from('<IIII', f, 0x40 + i*0x30)
        if s: r.append((a, c, f[o:o+s]))
    return r
off = {a: (c, d) for a, c, d in secs(off_f)}
ours = secs(our_f)
new = []
for a, c, d in ours:
    if a in (0x18000000, 0x1FF80000):
        if a not in off: sys.exit('official lacks section %x' % a)
        c, d = off[a]; print('official section %x (%d bytes, ours %d)' % (a, len(d), len(d)))
    new.append((a, c, d))
hdr = bytearray(our_f[:0x200])
hdr[8:12] = off_f[8:12]            # arm11 entry from the official FIRM
for i in range(4): hdr[0x40+i*0x30:0x40+(i+1)*0x30] = b'\0'*0x30
body = b''; pos = 0x200
for i, (a, c, d) in enumerate(new):
    hdr[0x40+i*0x30:0x40+i*0x30+16] = struct.pack('<IIII', pos, a, len(d), c)
    hdr[0x50+i*0x30:0x50+i*0x30+32] = hashlib.sha256(d).digest()
    pad = (-len(d)) % 0x200
    body += d + b'\0'*pad; pos += len(d) + pad
open(sys.argv[3], 'wb').write(bytes(hdr) + body)
