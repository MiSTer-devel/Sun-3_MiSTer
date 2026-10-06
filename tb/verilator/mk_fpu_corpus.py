#!/usr/bin/env python3
#
# The CPU+FPU corpus (tb/verilator/corpus/cpu_fpu_full_corpus.json, from
# lbmactwo_MiSTer's SingleStepTests/cpu_fpu) as a plain list tb_cpu_fpu.sv can
# read with $fscanf.  Each test is a 68020 program that ends in STOP, the data
# register its result lands in, and that register's expected value -- as a
# real Mac II (68020 + 68881) gave it.  Per test, three lines:
#
#     <result reg> <expected, 8 hex digits> <program length>
#     <program bytes, 2 hex digits each, space-separated>
#     <name>
#
# The first STOP #$2700 at an even offset (the end of the code; some programs
# keep PC-relative data after it) is found here and its offset written after
# the length, so the bench can send it to its epilogue instead.

import json
import sys

src, dst = sys.argv[1], sys.argv[2]
tests = json.load(open(src))
with open(dst, "w", newline="\n") as f:
    n = 0
    for t in tests:
        p = t["program"]
        stop = next((i for i in range(0, len(p) - 3, 2) if p[i:i + 4] == [0x4E, 0x72, 0x27, 0x00]), None)
        if stop is None:
            sys.exit(f"mk_fpu_corpus: no STOP in {t['name']}")
        f.write(f"{t['result_reg']} {t['expected'] & 0xFFFFFFFF:08x} {len(p)} {stop}\n")
        f.write(" ".join(f"{b:02x}" for b in p) + "\n")
        f.write(t["name"] + "\n")
        n += 1
print(f"{dst}: {n} tests")
