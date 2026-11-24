#!/usr/bin/env python3
# Dead-eMMC fork: replace our Rosalina sysmodule with the one from an official Luma3DS release, byte for byte.
# CTGP-7 checksums Rosalina's code and only runs on official builds; our changes are in arm9 and loader only.
# usage: use_official_rosalina.py <official boot.firm> <sysmodules.bin to patch in place>
import struct, sys

def split_cxis(blob):
    out, p = [], 0
    while p < len(blob):
        if blob[p + 0x100:p + 0x104] != b'NCCH':
            raise SystemExit('bad NCCH at 0x%x' % p)
        size = struct.unpack_from('<I', blob, p + 0x104)[0] * 0x200
        name = blob[p + 0x200:p + 0x208].rstrip(b'\0').decode()
        out.append((name, blob[p:p + size]))
        p += size
    return out

def firm_sysmodules(firm):
    if firm[:4] != b'FIRM':
        raise SystemExit('not a FIRM')
    for i in range(4):
        off, addr, size, _ = struct.unpack_from('<IIII', firm, 0x40 + i * 0x30)
        if size and firm[off + 0x100:off + 0x104] == b'NCCH':
            return firm[off:off + size]
    raise SystemExit('no sysmodules section in official FIRM')

official = dict(split_cxis(firm_sysmodules(open(sys.argv[1], 'rb').read())))
ours = split_cxis(open(sys.argv[2], 'rb').read())
if 'rosalina' not in official or 'rosalina' not in [n for n, _ in ours]:
    raise SystemExit('rosalina not found')
new = b''.join(official['rosalina'] if n == 'rosalina' else c for n, c in ours)
open(sys.argv[2], 'wb').write(new)
print('replaced rosalina (%d -> %d bytes); modules: %s' % (dict(ours)['rosalina'].__len__(), len(official['rosalina']), [n for n, _ in ours]))
