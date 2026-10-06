# Vendored third-party RTL

A MiSTer core has to build from a plain checkout with nothing but Quartus, so
the files the build needs are copied in here, at the commits below, unmodified
but for the local changes listed at the end.
They are the commits MelkhiorVintageComputing/Sun-3_FPGA pins as submodules
(`Inputs/`, at its `f435268`), the combination that boots SunOS 4.1.1 and
NetBSD there. Change them upstream and re-copy; do not edit them in place,
beyond those changes.

| directory | upstream | commit | licence | files taken |
|---|---|---|---|---|
| `rd68021/` | https://github.com/MelkhiorVintageComputing/RD68021 | `1b57478` | CERN-OHL-S-2.0 (`rd68021/LICENSE`) | `rtl/*.sv`, `rtl/gen/*.sv`, `rtl/rd68021.vlt` |
| `rd68884/` | https://github.com/MelkhiorVintageComputing/RD68884 | `557e806` | CERN-OHL-S-2.0 (`rd68884/LICENSE`) | `rtl/*.sv`, `rtl/gen/*.sv`, `rtl/rd68884.vlt` |
| `wish5380/` | https://github.com/MelkhiorVintageComputing/Wish5380 | `bde4ef3` | MIT (SPDX header in each file) | `src/wish5380_pkg.sv`, `sci_regs.sv`, `sci_bus.sv`, `wish5380.sv`, `scsi_fabric.sv`, `scsi_targ.sv` |
| `wish7990/` | https://github.com/MelkhiorVintageComputing/Wish7990 | `8610ef5` | MIT (SPDX header in each file) | `src/` minus the board-only `wb_mdio`, `mdio_prog`, `wb_le`, `wish7990_wb` |
| `z8530_scc/` | https://github.com/vz50938/z8530_scc | `b9bcd67` | GPL-3.0 (`z8530_scc/LICENSE`) | `z8530_scc.sv` |

Notes:

* **RD68021** at `1b57478` carries the two fixes Sun-3_FPGA found on its
  boards: the RTE rerun of a format $B frame (`33d9289`) and the level-7
  interrupt taken twice out of STOP (`e9d1618`). It is built with
  `COPROCESSOR=1` (`SUN3_FPU`), which the RD68884 needs.
* **RD68884** is used with its same-clock bus front end (`BUS_SYNC=1`), on the
  CPU's clock, at CpID 1.
* **Wish7990** is the LANCE (`SUN3_ETH_WISH7990`, Phase 5), in
  `sun3_fpga.v` with its MII on `rtl/sun3_mister_enet.sv`, the DDR3
  mailbox Main_MiSTer bridges to the host's network.
* **Wish5380** contributes the 5380, the SCSI target and the bus fabric used
  by `rtl/sun3/sun3_si.sv`. Its SD-card back end (`blk_sd`, `sd_spi`) is
  replaced on MiSTer by `rtl/sun3_mister_block.sv`. Sun-2_MiSTer vendors the
  same commit.
* **z8530_scc** is the same commit Sun-2_MiSTer vendors.

## Local changes

Both are for Quartus on the Cyclone V, found in the first fits (2026-10-04),
where a memory was built from logic. Neither changes the logic or the
simulation.

* **`wish5380/scsi_targ.sv`**: `(* ramstyle = "M10K, no_rw_check" *)` on the
  sector buffer `mem`. Without it Quartus 17 declines the two-process true
  dual-port RAM ("uninferred due to unsupported read-during-write behavior",
  276009) and builds 1 KiB from 9,336 registers: 10,310 ALMs, a quarter of
  the chip. The two ports never address the same byte at once, as the file's
  own comment explains, so the read-during-write check guards nothing.
  Sun-2_MiSTer vendors the same commit and has the same problem. A patch to
  send upstream, then drop.

* **`rd68884/gen/rd68884_crom.sv`**, the FPU's constant ROM (2048 x 92), is
  regenerated here by `tools/crom_dense.py` with a case label for every
  address. Upstream's generator labels 812 and leaves the other 1,236 to the
  `default`, and Quartus builds a case with fewer than half its entries
  labelled from logic, without a message, whatever attribute it carries
  (`romstyle = "M10K"` alone changed nothing): 2,973 ALMs. Written out in
  full, the same table is a ROM in 19 M10K and no logic. The fit went from
  25,988 ALMs (62%) and 291 M10K to 22,985 (55%) and 310. The attribute is
  now Quartus's `romstyle`; Vivado's `rom_style` gave warning 10335.

  This is this repository's own file, not a patch waiting on upstream.
  Upstream's `tools/ucode/asm.py` could emit the dense case itself, as its
  RD68021 microcode ROM already does for the same reason; the script would
  then have nothing to do.

  To regenerate, from upstream's file (`gen/rd68884_crom.sv` at `557e806`,
  which is this repository's `e4c343b` copy), and to check the result
  against it (all 2048 words, and every line that is not a comment, the
  attribute or a case label):

      git show e4c343b:rtl/vendor/rd68884/gen/rd68884_crom.sv > /tmp/crom.sv
      python3 tools/crom_dense.py /tmp/crom.sv -o rtl/vendor/rd68884/gen/rd68884_crom.sv
      python3 tools/crom_dense.py /tmp/crom.sv --verify rtl/vendor/rd68884/gen/rd68884_crom.sv

  After a Quartus build, `python3 tools/check_crom_mif.py` compares the
  `.mif` Quartus inferred (`db/Sun-3.rom0_rd68884_crom_*.hdl.mif`) with the
  case, word for word, and checks the fit report's row for it: a 2048 x 92
  ROM with registered inputs and no output register, so a read is still
  one clock (`cr_re` is the address register's clock enable). Both scripts
  print the table's SHA-256,
  `5997c98ee7ed5c755c9280705734be8bbf423ad2ce2c67c2348fcf6327bbe1a6`. The
  CPU+FPU corpus never reads this ROM (it has no `FMOVECR` and no
  packed-decimal moves), so these two checks are what stand behind it.
