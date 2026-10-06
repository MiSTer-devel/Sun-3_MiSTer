#!/usr/bin/env python3
"""
aoutdis.py -- annotated disassembly of SunOS 4 (68020) a.out objects.

  aoutdis.py FILE.o
  aoutdis.py LIB.a [MEMBER-REGEX]         members whose name matches
  aoutdis.py --list LIB.a                 member names, sizes, defined globals
  aoutdis.py --defines SYM LIB.a          which members define SYM

The a.out layout (after Sun-2_MiSTer tools/cg2model/aoutlink.py): a 32-byte
header (machine byte, magic, text, data, bss, syms, entry, trsize, drsize),
text, data, text relocations, data relocations, 12-byte nlists, strings.  A
relocation is 8 bytes: address, then 24 bits of symbol number, pcrel, 2-bit
length, extern (high bit first).  Not extern: the symbol number is the
segment (4 text, 6 data, 8 bss) and the field holds an address in the
object's frame (text at 0, data at a_text, bss after data).
"""
import re, struct, sys
from capstone import Cs, CS_ARCH_M68K, CS_MODE_M68K_020, CS_MODE_BIG_ENDIAN

N_TYPE = {0: 'U', 2: 'A', 4: 'T', 6: 'D', 8: 'B', 0x12: 'F'}
SEG = {4: 'text', 6: 'data', 8: 'bss'}


def parse_ar(data):
    assert data[:8] == b'!<arch>\n', 'not an ar archive'
    off, out = 8, []
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        name = hdr[:16].decode('latin-1').strip()
        size = int(hdr[48:58].decode().strip())
        body = data[off + 60:off + 60 + size]
        if name.endswith('/'):
            name = name[:-1]
        if name not in ('__.SYMDEF', '', '/', '//'):
            out.append((name, body))
        off += 60 + size + (size & 1)
    return out


class Aout:
    def __init__(self, name, b):
        self.name, self.b = name, b
        (mid, self.magic, self.text, self.data, self.bss, self.nsyms, self.entry,
         self.trsize, self.drsize) = struct.unpack('>HHIIIIIII', b[:32])
        self.toff = 32
        self.doff = self.toff + self.text
        self.troff = self.doff + self.data
        self.droff = self.troff + self.trsize
        self.symoff = self.droff + self.drsize
        self.stroff = self.symoff + self.nsyms
        self.syms = []
        for i in range(self.nsyms // 12):
            strx, typ, other, desc, val = struct.unpack('>IBBhI', b[self.symoff + 12 * i:self.symoff + 12 * i + 12])
            nm = ''
            if strx:
                e = b.index(b'\0', self.stroff + strx)
                nm = b[self.stroff + strx:e].decode('latin-1')
            self.syms.append((nm, typ, val))
        self.trel = self.relocs(self.troff, self.trsize)
        self.drel = self.relocs(self.droff, self.drsize)

    def relocs(self, off, size):
        out = {}
        for i in range(size // 8):
            addr, w = struct.unpack('>II', self.b[off + 8 * i:off + 8 * i + 8])
            num, pcrel, length, ext = w >> 8, (w >> 7) & 1, (w >> 5) & 3, (w >> 4) & 1
            if ext:
                tgt = self.syms[num][0] if num < len(self.syms) else '?sym%d' % num
            else:
                tgt = SEG.get(num, 'seg%d' % num)
            out[addr] = (tgt, ext, pcrel, length)
        return out

    def labels(self):
        lab = {}
        for nm, typ, val in self.syms:
            if typ & 0x1e == 4 and nm and not nm.startswith('L'):   # text
                lab.setdefault(val, nm)
        for nm, typ, val in self.syms:
            if typ & 0x1e == 4 and nm:
                lab.setdefault(val, nm)
        return lab

    def symname_at(self, addr):
        for nm, typ, val in self.syms:
            if val == addr and typ & 0x1e in (4, 6, 8) and nm:
                return nm
        return None

    def reloc_note(self, a, length, rels):
        notes = []
        for ra in range(a, a + length):
            if ra in rels:
                tgt, ext, pcrel, ln = rels[ra]
                size = {0: 1, 1: 2, 2: 4}.get(ln, 4)
                field = self.b[(self.toff if rels is self.trel else self.doff) + ra:
                               (self.toff if rels is self.trel else self.doff) + ra + size]
                val = int.from_bytes(field, 'big', signed=False)
                if ext:
                    notes.append('%s%s' % (tgt, '+0x%x' % val if val else ''))
                else:
                    nm = self.symname_at(val)
                    notes.append('%s:%s' % (tgt, nm if nm else '0x%x' % val))
        return notes

    def dump(self, out):
        out.write('==== %s  text %d data %d bss %d\n' % (self.name, self.text, self.data, self.bss))
        out.write('-- symbols\n')
        for nm, typ, val in self.syms:
            if typ & 0xe0:
                continue                                    # stabs
            t = N_TYPE.get(typ & 0x1e, '?%x' % typ)
            out.write('   %s%s %08x %s\n' % (t, 'g' if typ & 1 else ' ', val, nm))
        lab = self.labels()
        md = Cs(CS_ARCH_M68K, CS_MODE_M68K_020 + CS_MODE_BIG_ENDIAN)
        text = self.b[self.toff:self.toff + self.text]
        out.write('-- text\n')
        a = 0
        while a < self.text:
            if a in lab:
                out.write('\n%s:\n' % lab[a])
            ins = next(md.disasm(text[a:], a, 1), None)
            if ins is None:
                out.write('  %06x: .word 0x%04x\n' % (a, int.from_bytes(text[a:a + 2], 'big')))
                a += 2
                continue
            hexs = text[a:a + ins.size].hex()
            notes = self.reloc_note(a, ins.size, self.trel)
            ops = ins.op_str
            m = re.search(r'\$([0-9a-f]+)', ops) if ins.mnemonic.startswith(('b', 'db', 'fb')) else None
            if m and int(m.group(1), 16) in lab:
                notes.append('-> ' + lab[int(m.group(1), 16)])
            out.write('  %06x: %-20s %-8s %s%s\n' % (a, hexs, ins.mnemonic, ops,
                                                    ('   ; ' + ', '.join(notes)) if notes else ''))
            a += ins.size
        if self.data:
            out.write('-- data\n')
            d = self.b[self.doff:self.doff + self.data]
            for o in range(0, len(d), 16):
                chunk = d[o:o + 16]
                notes = self.reloc_note(o, 16, self.drel)
                nm = self.symname_at(self.text + o)
                asc = ''.join(chr(c) if 32 <= c < 127 else '.' for c in chunk)
                out.write('  %06x: %-32s %s%s%s\n' % (self.text + o, chunk.hex(), asc,
                                                      ('  <' + nm + '>') if nm else '',
                                                      ('  ; ' + ', '.join(notes)) if notes else ''))


def main():
    args = sys.argv[1:]
    if args[0] == '--list':
        for nm, body in parse_ar(open(args[1], 'rb').read()):
            o = Aout(nm, body)
            g = [s for s, t, v in o.syms if t & 1 and t & 0x1e in (4, 6, 8)]
            print('%-24s text %6d data %6d  %s' % (nm, o.text, o.data, ' '.join(g)))
        return
    if args[0] == '--defines':
        sym = args[1]
        for nm, body in parse_ar(open(args[2], 'rb').read()):
            o = Aout(nm, body)
            if any(s == sym and t & 1 and t & 0x1e in (4, 6, 8) for s, t, v in o.syms):
                print(nm)
        return
    path = args[0]
    data = open(path, 'rb').read()
    if data[:8] == b'!<arch>\n':
        rx = re.compile(args[1]) if len(args) > 1 else None
        for nm, body in parse_ar(data):
            if rx is None or rx.search(nm):
                Aout(nm, body).dump(sys.stdout)
    else:
        Aout(path, data).dump(sys.stdout)


if __name__ == '__main__':
    main()
