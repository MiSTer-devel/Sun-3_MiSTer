# Test corpora

| file | from | what |
|---|---|---|
| `cpu_fpu_full_corpus.json` | lbmactwo_MiSTer `SingleStepTests/cpu_fpu/cpu_fpu_full_corpus.json` at `6a51149` (2026-06-05) | 1,320 short 68020 programs exercising the MC68881 (FMOVE in every format, FADD/FSUB/FMUL/FDIV, FSQRT, FINT/FINTRZ, FABS/FNEG, FTST/FCMP with every FBcc/FScc/FDBcc/FTRAPcc condition, FMOVEM, FSAVE/FRESTORE), each with the data register its answer lands in. Run on a real Mac II, a 68020 with a 68881 -- the 3/60's own pair -- it scored 1319 of 1320 (lbmactwo_MiSTer `SingleStepTests/README.md`). |

`tb_cpu_fpu` runs it on the RD68021 and RD68884 (`make -C tb/verilator tb_cpu_fpu`);
`mk_fpu_corpus.py` turns it into the list the bench reads.
