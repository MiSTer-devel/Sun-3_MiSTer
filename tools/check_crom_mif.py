#!/usr/bin/env python3
#
# Check that the block RAM Quartus inferred for the RD68884's constant ROM
# holds the table rtl/vendor/rd68884/gen/rd68884_crom.sv describes.
#
#     python3 check_crom_mif.py [--sv FILE] [--mif FILE] [--fit-rpt FILE]
#
# The `case` in the .sv is expanded to all 2048 addresses (an address with no
# label takes the `default`), and compared word for word with the .mif Quartus
# wrote for the inferred altsyncram (db/<rev>.rom0_rd68884_crom_<hash>.hdl.mif).
# With --fit-rpt (default output_files/Sun-3.fit.rpt, if it is there) the
# "Fitter RAM Summary" row naming that .mif is checked too: a 2048 x 92 ROM
# with registered inputs and no output register, which is the one-clock read
# the registered `case` had.
#
# Exit status 0 only if everything matches.

import argparse
import glob
import hashlib
import os
import re
import sys

DEPTH, WIDTH = 2048, 92
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RADIX = {'HEX': 16, 'BIN': 2, 'OCT': 8, 'DEC': 10, 'UNS': 10}


def read(path):
    with open(path, newline='') as f:
        return f.read().replace('\r\n', '\n')


def sv_table(path):
    src = read(path)
    if not re.search(r'input\s+logic\s*\[10:0\]\s*addr', src) or \
       not re.search(r'logic\s*\[91:0\]\s*rom_q', src):
        sys.exit('%s: not the 2048 x 92 rd68884_crom this script knows' % path)
    labelled = {}
    for a, h in re.findall(r"11'd(\d+)\s*:\s*rom_q\s*<=\s*92'h([0-9A-Fa-f]+)\s*;", src):
        a = int(a)
        if a in labelled or a >= DEPTH:
            sys.exit('%s: address %d labelled twice or out of range' % (path, a))
        labelled[a] = int(h, 16)
    d = re.findall(r"default\s*:\s*rom_q\s*<=\s*92'h([0-9A-Fa-f]+)\s*;", src)
    if len(d) != 1 or not labelled:
        sys.exit('%s: no case table found' % path)
    if src.count('rom_q <=') != len(labelled) + 1:
        sys.exit('%s: an assignment to rom_q this script did not parse' % path)
    dflt = int(d[0], 16)
    return [labelled.get(a, dflt) for a in range(DEPTH)], len(labelled), dflt


def mif_table(path):
    src = re.sub(r'--[^\n]*', '', read(path))
    src = re.sub(r'%.*?%', '', src, flags=re.S)
    hdr = dict((k.upper(), v.upper()) for k, v in
               re.findall(r'(\w+)\s*=\s*(\w+)\s*;', src))
    if int(hdr['WIDTH']) != WIDTH or int(hdr['DEPTH']) != DEPTH:
        sys.exit('%s: WIDTH=%s DEPTH=%s, expected %d x %d'
                 % (path, hdr['WIDTH'], hdr['DEPTH'], DEPTH, WIDTH))
    ar, dr = RADIX[hdr['ADDRESS_RADIX']], RADIX[hdr['DATA_RADIX']]
    body = re.search(r'CONTENT\s+BEGIN(.*)END\s*;', src, flags=re.S).group(1)
    words = [None] * DEPTH
    for stmt in body.split(';'):
        if not stmt.strip():
            continue
        lhs, rhs = stmt.split(':')
        vals = [int(v, dr) for v in rhs.split()]
        m = re.match(r'\s*\[\s*(\w+)\s*\.\.\s*(\w+)\s*\]\s*$', lhs)
        if m:                                   # [a..b] : v [v ...], repeated
            lo, hi = int(m.group(1), ar), int(m.group(2), ar)
            addrs = range(lo, hi + 1)
            vals = [vals[i % len(vals)] for i in range(len(addrs))]
        else:                                   # a : v [v ...], consecutive
            lo = int(lhs.strip(), ar)
            addrs = range(lo, lo + len(vals))
        for a, v in zip(addrs, vals):
            if words[a] is not None:
                sys.exit('%s: address %d given twice' % (path, a))
            words[a] = v
    return words


def fit_row(path, mif_name):
    cols = None
    for line in read(path).split('\n'):
        cells = [c.strip() for c in line.strip().strip(';').split(';')]
        if cells[:2] == ['Name', 'Type'] and 'MIF' in cells:
            cols = cells
        elif cols and len(cells) == len(cols) and \
                os.path.basename(cells[cols.index('MIF')]) == mif_name:
            return dict(zip(cols, cells))
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sv', default=os.path.join(
        ROOT, 'rtl', 'vendor', 'rd68884', 'gen', 'rd68884_crom.sv'))
    ap.add_argument('--mif')
    ap.add_argument('--fit-rpt')
    args = ap.parse_args()

    mif = args.mif
    if not mif:
        found = sorted(glob.glob(os.path.join(ROOT, 'db', '*rd68884_crom*.mif')))
        if len(found) != 1:
            sys.exit('expected one db/*rd68884_crom*.mif, found %d: %s (Quartus '
                     'did not infer the ROM, or pass --mif)' % (len(found), found))
        mif = found[0]
    fit = args.fit_rpt
    if not fit and os.path.exists(os.path.join(ROOT, 'output_files', 'Sun-3.fit.rpt')):
        fit = os.path.join(ROOT, 'output_files', 'Sun-3.fit.rpt')

    want, n, dflt = sv_table(args.sv)
    got = mif_table(mif)
    print('sv : %s' % args.sv)
    print('     %d labelled addresses, %d on the default %023X' % (n, DEPTH - n, dflt))
    print('mif: %s' % mif)
    bad = [a for a in range(DEPTH) if got[a] != want[a]]
    for a in bad[:10]:
        print('  DIFF at %4d: mif %s, sv %023X'
              % (a, 'missing' if got[a] is None else '%023X' % got[a], want[a]))
    sha = hashlib.sha256(b''.join(w.to_bytes(12, 'big') for w in want)).hexdigest()
    print('     %d of %d words equal; table sha256 %s' % (DEPTH - len(bad), DEPTH, sha))
    ok = not bad

    if fit:
        row = fit_row(fit, os.path.basename(mif))
        print('fit: %s' % fit)
        if not row:
            print('     no Fitter RAM Summary row names this .mif')
            ok = False
        else:
            want_row = {'Mode': 'ROM', 'Port A Depth': '2048', 'Port A Width': '92',
                        'Port A Input Registers': 'yes',
                        'Port A Output Registers': 'no'}
            for k, v in want_row.items():
                flag = '' if row[k] == v else '   <-- expected %s' % v
                ok = ok and not flag
                print('     %-24s %s%s' % (k, row[k], flag))
            print('     %-24s %s' % ('M10K blocks', row['M10K blocks']))

    print('PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
