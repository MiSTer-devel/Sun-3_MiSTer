#!/usr/bin/env python3
"""
Link SunOS SPARC or 68020 a.out objects into one flat image for the cg6model
harness.

The harness runs Sun's own libpixrect object code in a SPARC interpreter
(sparc.c), so that the board model is driven by exactly the register writes
Sun's cg6 code makes.  This is the linker for that: it resolves the members
a set of root symbols needs out of an ar archive, lays text, data, bss and
commons out from a base address, relocates them, and turns every symbol
still undefined into a stub the harness serves in C (malloc, bzero, .mul,
pr_makefromfd, ...).  The Sun-2 core's tools/cg2model/aoutlink.py is the
68010 original of this; a 68k object (machine 1 or 2) is linked as it does.

  aoutlink.py -o OUT --base 0x10000 --lib libpixrect.a --root _cg6_rop ...
      [--stub _gp1_sync ...]

writes OUT.bin (the image, loaded at --base) and OUT.sym, one line per
global: `ADDR NAME' for definitions and `ADDR NAME stub' for stubs.  A stub
is `unimp 0; nop' on SPARC, `illegal; rts' on a 68k; the harness's unimp or
illegal-instruction hook knows its address.

The format.  A SunOS 4 SPARC object is a.out: a 32-byte header (dynamic
and toolversion byte, machine 3, magic 0407, then text, data, bss, syms,
entry, trsize, drsize), text, data, text relocations, data relocations, a
symbol table of 12-byte nlists and a string table.  A relocation is 12 bytes
(struct reloc_info_sparc): the address, then 24 bits of symbol number,
extern, two unused bits and a 5-bit type, then a signed addend.  The field
itself holds nothing: the value is the symbol (or, not extern, the segment
4 text / 6 data / 8 bss, in the object's own frame where text starts at 0,
data at a_text and bss at a_text + a_data) plus the addend.  For the
PC-relative types the addend is already less the field's offset in its
segment, so the displacement is value - (the segment's new base).

A 68k object's header has machine 1 (68010) or 2 (68020), and its
relocations are 8 bytes: the address, then 24 bits of symbol number, pcrel,
a 2-bit length (0 byte, 1 word, 2 long) and extern, high bit first.  The
field holds the addend: an address in the object's frame for a segment
relocation, an offset for an extern one.
"""
import argparse, struct, sys

N_UNDF, N_ABS, N_TEXT, N_DATA, N_BSS = 0, 2, 4, 6, 8
N_EXT = 1
R_8, R_16, R_32, R_DISP8, R_DISP16, R_DISP32, R_WDISP30, R_WDISP22, \
    R_HI22, R_22, R_13, R_LO10 = range(12)


def parse_ar(data):
    if data[:8] != b'!<arch>\n':
        raise SystemExit('not an ar archive')
    off, out = 8, []
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        name = hdr[:16].decode().rstrip().rstrip('/')
        size = int(hdr[48:58].decode())
        out.append((name, data[off + 60:off + 60 + size]))
        off += 60 + size + (size & 1)
    return [(n, b) for n, b in out if not n.startswith('__.SYMDEF')]


class Obj:
    def __init__(self, name, d):
        self.name = name
        mid, magic = d[1], struct.unpack('>H', d[2:4])[0]
        if mid not in (1, 2, 3) or magic != 0o407:
            raise SystemExit(f'{name}: not a SPARC or 68k OMAGIC object')
        self.m68k = mid != 3
        text, dat, bss, syms, entry, trsize, drsize = struct.unpack('>7I', d[4:32])
        p = 32
        self.text = bytearray(d[p:p + text]); p += text
        self.data = bytearray(d[p:p + dat]); p += dat
        self.bss = bss
        rel = self._rel68k if self.m68k else self._rel
        self.trel = rel(d[p:p + trsize]); p += trsize
        self.drel = rel(d[p:p + drsize]); p += drsize
        stroff = p + syms
        self.syms = []
        for i in range(syms // 12):
            strx, typ, other, desc, value = struct.unpack('>IBBhI', d[p + 12 * i:p + 12 * i + 12])
            n = d[stroff + strx:d.index(b'\0', stroff + strx)].decode() if strx else ''
            self.syms.append((n, typ, value))
        self.defs = {n for n, t, v in self.syms
                     if t & N_EXT and not t & 0xe0 and t & 0x1e}
        self.undefs = {n for n, t, v in self.syms
                       if t == N_UNDF | N_EXT and v == 0}
        self.commons = {n: v for n, t, v in self.syms
                        if t == N_UNDF | N_EXT and v != 0}

    @staticmethod
    def _rel(b):
        out = []
        for i in range(len(b) // 12):
            addr, info, addend = struct.unpack('>IIi', b[12 * i:12 * i + 12])
            out.append((addr, info >> 8, info >> 7 & 1, info & 31, addend))
        return out

    @staticmethod
    def _rel68k(b):
        out = []
        for i in range(len(b) // 8):
            addr, w = struct.unpack('>II', b[8 * i:8 * i + 8])
            out.append((addr, w >> 8, w >> 4 & 1, (w >> 7 & 1, w >> 5 & 3), 0))
        return out

    def frame(self, a):
        """an address in the object's own frame, moved to where it lands"""
        if a < len(self.text):
            return self.tbase + a
        if a < len(self.text) + len(self.data):
            return self.dbase + a - len(self.text)
        return self.bbase + a - len(self.text) - len(self.data)


def relocate68k(o, body, raddr, sym, ext, typ, gsym):
    pcrel, length = typ
    if pcrel:
        # Sun's cc emits none for these libraries; refuse rather than
        # guess at the convention
        raise SystemExit(f'{o.name}: pc-relative relocation')
    fmt = {0: '>b', 1: '>h', 2: '>i'}[length]
    size = 1 << length
    old = struct.unpack(fmt, body[raddr:raddr + size])[0]
    if ext:
        new = old + gsym[o.syms[sym][0]]
    elif sym == N_TEXT:
        new = old + o.tbase
    elif sym == N_DATA:
        new = old - len(o.text) + o.dbase
    elif sym == N_BSS:
        new = old - len(o.text) - len(o.data) + o.bbase
    elif sym == N_ABS:
        new = old
    else:
        raise SystemExit(f'{o.name}: relocation to segment {sym}')
    body[raddr:raddr + size] = (new & ((1 << (8 * size)) - 1)).to_bytes(size, 'big')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-o', required=True)
    ap.add_argument('--base', type=lambda s: int(s, 0), default=0x10000)
    ap.add_argument('--lib', action='append', default=[])
    ap.add_argument('--obj', action='append', default=[])
    ap.add_argument('--root', action='append', default=[])
    ap.add_argument('--stub', action='append', default=[],
                    help='serve this symbol as a stub even if the library defines it')
    a = ap.parse_args()

    stubbed = set(a.stub)
    objs = [Obj(f, open(f, 'rb').read()) for f in a.obj]
    lib = []
    for path in a.lib:
        lib += [Obj(n, b) for n, b in parse_ar(open(path, 'rb').read())]
    provider = {}
    kinds = {o.m68k for o in objs + lib}
    if len(kinds) != 1:
        raise SystemExit('SPARC and 68k objects mixed')
    m68k = kinds.pop()
    for o in lib:
        for s in o.defs:
            provider.setdefault(s, o)

    chosen = list(objs)
    defined = set().union(*(o.defs for o in chosen)) if chosen else set()
    want = set(a.root)
    for o in chosen:
        want |= o.undefs
    while True:
        missing = {s for s in want - defined - stubbed if s in provider}
        if not missing:
            break
        for s in sorted(missing):
            o = provider[s]
            if o not in chosen:
                chosen.append(o)
                defined |= o.defs
                want |= o.undefs
    for r in a.root:
        if r not in defined:
            raise SystemExit(f'root {r} is not defined anywhere')

    addr = a.base
    for o in chosen:
        o.tbase = addr
        addr += (len(o.text) + 7) & ~7
    for o in chosen:
        o.dbase = addr
        addr += (len(o.data) + 7) & ~7
    for o in chosen:
        o.bbase = addr
        addr += (o.bss + 7) & ~7
    gsym = {}
    for o in chosen:
        for n, t, v in o.syms:
            if not (t & N_EXT) or t & 0xe0 or n in stubbed:
                continue
            seg = t & 0x1e
            if seg in (N_TEXT, N_DATA, N_BSS):
                gsym[n] = o.frame(v)
            elif seg == N_ABS:
                gsym[n] = v
    commons = {}
    for o in chosen:
        for n, size in o.commons.items():
            if n not in gsym:
                commons[n] = max(commons.get(n, 0), size)
    for n, size in sorted(commons.items()):
        gsym[n] = addr
        addr += (size + 7) & ~7
    undefined = sorted({s for o in chosen for s in o.undefs} - set(gsym))
    stubs = {}
    for n in undefined:
        stubs[n] = gsym[n] = addr
        addr += 8
    end = addr

    image = bytearray(end - a.base)
    for o in chosen:
        for base, body, rels in ((o.tbase, o.text, o.trel), (o.dbase, o.data, o.drel)):
            body = bytearray(body)
            for raddr, sym, ext, typ, addend in rels:
                if m68k:
                    relocate68k(o, body, raddr, sym, ext, typ, gsym)
                    continue
                if ext:
                    v = gsym[o.syms[sym][0]] + addend
                elif sym in (N_TEXT, N_DATA, N_BSS):
                    v = o.frame(addend)
                elif sym == N_ABS:
                    v = addend
                else:
                    raise SystemExit(f'{o.name}: relocation to segment {sym}')
                w = struct.unpack('>I', body[raddr:raddr + 4])[0] if typ != R_8 and typ != R_16 else 0
                if typ == R_32:
                    w = v & 0xffffffff
                elif typ == R_HI22:
                    w |= (v >> 10) & 0x3fffff
                elif typ == R_22:
                    w |= v & 0x3fffff
                elif typ == R_LO10:
                    w |= v & 0x3ff
                elif typ == R_13:
                    w |= v & 0x1fff
                elif typ in (R_WDISP30, R_WDISP22):
                    if ext:
                        d = v - base
                    else:
                        # a local pc-relative reference: the addend is the
                        # target's frame offset less the field's
                        d = o.frame(addend + raddr + (0 if base == o.tbase else len(o.text))) - (base + raddr)
                    if typ == R_WDISP30:
                        w |= (d >> 2) & 0x3fffffff
                    else:
                        w |= (d >> 2) & 0x3fffff
                else:
                    raise SystemExit(f'{o.name}: relocation type {typ}')
                body[raddr:raddr + 4] = struct.pack('>I', w & 0xffffffff)
            image[base - a.base:base - a.base + len(body)] = body
    for n, ad in stubs.items():
        image[ad - a.base:ad - a.base + 8] = \
            b'\x4a\xfc\x4e\x75\0\0\0\0' if m68k else b'\0\0\0\0\x01\0\0\0'

    open(a.o + '.bin', 'wb').write(image)
    with open(a.o + '.sym', 'w', newline='\n') as f:
        for n, ad in sorted(gsym.items(), key=lambda x: x[1]):
            f.write(f'{ad:08x} {n}{" stub" if n in stubs else ""}\n')
        f.write(f'{end:08x} _end\n')
    print(f'{a.o}: {len(chosen)} objects, {len(stubs)} stubs ({" ".join(sorted(stubs))}), '
          f'{a.base:#x}..{end:#x}', file=sys.stderr)


if __name__ == '__main__':
    main()
