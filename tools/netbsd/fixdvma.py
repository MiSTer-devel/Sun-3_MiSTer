#!/usr/bin/env python3
#
# Mend the NetBSD/sun3 11.0 standalone programs' DVMA alias: tapeboot,
# ufsboot, netboot and the disk boot block, alone or wherever they sit in an
# image (the miniroot holds five, the boot tape's segment 0 is tapeboot).
#
# The 11.0 release's sun68k/stand/libsa/sun3.c (revision 1.11) aliases the
# program's 0x200000-0x2dffff into DVMA space at 0xfff00000 by sharing the
# seven PMEGs.  The 3/60's PROM (2.8.3 and 3.0.1 at least) keeps its own SCSI
# mappings at 0xfff00000 and up, so its tape and disk drivers rewrite PTEs of
# those PMEGs, and with them the program's own pages.  The kernel inherits
# the mapping: on the core, VA 0x212000 (radix.c's radix_initialized among
# its BSS) became PA 0x17e6000, a page pmap_bootstrap then hands to UVM as
# free, and the first allocation of it panics the kernel with "radix already
# initialized".  NetBSD fixed it on 2026-08-19 (sun3.c 1.12, pulled up to
# netbsd-11 as ticket #420): the alias starts at 0x240000/0xfff40000 and is
# 640 KB long.  The same three changes are made here, in the code the 11.0
# compiler made of it:
#
#   dvma3_init    moveq #$20,Dn; swap Dn   (start at 0x200000)  -> #$24
#   dvma3_mapin   addi.l #-$200000 / cmpi.l #$e0000             -> -$240000 / $a0000
#   dvma3_mapout  addi.l #$100000 / cmpi.l #$e0000 (-0xfff00000) -> $c0000 / $a0000
#
# Every copy found has all three or the file is left alone.
#
#     python3 tools/netbsd/fixdvma.py <in> <out>
#     python3 tools/netbsd/fixdvma.py --check <file>

import re, sys

INIT = re.compile(rb'\x74\x20\x48\x42\x47\xf9....\x45\xf9....'
                  rb'\x20\x02\x08\xc0\x00\x1d\x2f\x00\x4e\x93\x2e\x80'
                  rb'\x20\x02\x06\x80\xff\xd0\x00\x00\x02\x80\x0f\xff\xff\xfc'
                  rb'\x08\xc0\x00\x1d\x2f\x00\x4e\x92\x50\x8f'
                  rb'\x06\x82\x00\x02\x00\x00\x0c\x82\x00\x2e\x00\x00', re.S)
MAPIN_OLD  = bytes.fromhex('0680ffe000000c80000e0000')
MAPIN_NEW  = bytes.fromhex('0680ffdc00000c80000a0000')
MAPOUT_OLD = bytes.fromhex('0680001000000c80000e0000')
MAPOUT_NEW = bytes.fromhex('0680000c00000c80000a0000')

def find(d, pat):
    return [m.start() for m in re.finditer(re.escape(pat), d)]

def main():
    check = sys.argv[1] == '--check'
    d = bytearray(open(sys.argv[2] if check else sys.argv[1], 'rb').read())
    init = [m.start() for m in INIT.finditer(d)]
    mapin, mapout = find(d, MAPIN_OLD), find(d, MAPOUT_OLD)
    fixed = len(find(d, MAPIN_NEW))
    print(f'unmended copies: dvma3_init {len(init)}, dvma3_mapin {len(mapin)}, '
          f'dvma3_mapout {len(mapout)}; mended dvma3_mapin {fixed}')
    if not (len(init) == len(mapin) == len(mapout)):
        sys.exit('the three do not pair up: not patching')
    if check:
        sys.exit(1 if init else 0)
    for a in init:
        d[a + 1] = 0x24
    for a in mapin:
        d[a:a + 12] = MAPIN_NEW
    for a in mapout:
        d[a:a + 12] = MAPOUT_NEW
    open(sys.argv[2], 'wb').write(d)
    print(f'{sys.argv[2]}: {len(init)} copies mended')

main()
