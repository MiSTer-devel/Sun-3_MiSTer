# References

Outside material the design depends on. None of it is ours.
* The Sun documents are Sun Microsystems'.
* The sun3arc.org pages belong to their authors: Heiko Krupp, Peter Koch,
  James W. Birdsall's FAQ, and others.

**Only the text files are in this repository**: the sun3arc.org pages
(HTML), the FAQs, the part list, `format.dat` and the boot tapes' README
and `maketape` scripts. The PDFs, the schematic and board images, the PAL
fuse maps, the papers and the tapes' tables of contents are not; each entry
below says where to find them (*not here*). Each entry gives where it came
from and what it is used for. Fetched on 2026-10-04.

## `manuals/` (*not here*: binary files)

| file | source | used for |
|---|---|---|
| `Sun-3_Architecture_Manual_Ver_2.0_May85.pdf` | a private archive (a different scan from the one in Sun-3_FPGA `Inputs/doc/`) | control space, MMU, System Enable, interrupts, bus errors: the architecture |
| `Sun-3_Architecture_Manual_Ver_1.0_Jan85.pdf` | a private archive | the earlier edition, for cross-checks |
| `Sun-3_Customer_Maintenance_Training_Sep88.pdf` | a private archive | board-level views of the 3/60 and its options, diagnostics, LED codes |
| `Sun-3_60_Schematic_Jul87.pdf` | Sun-3_FPGA `Inputs/doc/` | the 3/60 production schematic (rev 13): reset nets, PALs, video, P4 connector |
| `Sun-3_60_Schematic_FERRARI_early.pdf` | Sun-3_FPGA `Inputs/doc/f.pdf` | an earlier "FERRARI" revision of the same |
| `REN_icm7170_DST_20170525_1.pdf` | Sun-3_FPGA `Inputs/doc/` | the time-of-day chip |

## `sun3arc/` (a partial mirror of https://www.sun3arc.org/, paths kept)

The pages are the site's `.phtml` sources as served: HTML with server-side
includes. Open them as HTML. Their images (`.gif`), the PALs' `.gz` fuse
maps, the papers' `.ps.gz` and the `xdrtoc` files are *not here*: they are
at the same paths under https://www.sun3arc.org/.

| path | what | used for |
|---|---|---|
| `text/general.phtml`, `text/partlist` | every Sun-3/3x model and Sun part number | choosing the machine (docs/hardware.md) |
| `FAQ/sun.hardware.FAQ` | the comp.sys.sun.hardware FAQ: boards, jumpers, compatibility (P4 cg4/cg6 vs PROM revisions) | hardware facts. Search it for `501-1205`, `cg4`, `P4` |
| `FAQ/bootrom.phtml`, `FAQ/eeprom-nvram.FAQ`, `FAQ/sun-nvram-hostid.faq.phtml`, `FAQ/nvram.phtml` | PROM monitor, EEPROM layout, ID PROM / hostid | the EEPROM preload and the ID PROM Main sends |
| `FEH/CPU/3_60.phtml` + `3_60.gif`, `3_60j.gif` | Field Engineer Handbook: the 3/60 board and its jumpers | board options (J800: memory size, AUI, hi-res video) |
| `FEH/CPU/prommon.phtml`, `idromnvram.phtml` | PROM monitor commands, ID PROM / NVRAM | testing at the `>` prompt |
| `FEH/Graphics/3_60cg4.phtml` + gif, `cg4.phtml` + gif, `cg6.phtml` + gif | the 3/60 cg4 (501-1210), the generic P4 cg4 (501-1248), the P4 GX (501-1374) | colour, Phase 4 and Phase 8 |
| `FEH/Memory/simms.phtml` + gif | 3/60 SIMM rules | the 24 MiB maximum |
| `FEH/CPU/3_60LE.phtml`, `3_80.phtml`, `3200.phtml`, the `FEH/*/index.phtml` pages | other boards | context |
| `schematics/3_60/s1..s15.gif` | the 3/60 (Rev 58) schematics, page by page: CPU/clock, MMU/diag, EPROM/EEPROM, serial, Ethernet, SCSI x2, memory, SIMMs x3, video x2, connectors, misc | the machine's glue, next to the PDF |
| `PALs/Sun3_60/*.gz`, `PALs/CG4/*.gz` | JEDEC fuse maps of the 3/60's PALs and the cg4's (1612-01 missing) | decoding the cg4's register and plane logic if the drivers leave a question open |
| `ROMs/eprom.phtml`, `ROMs/3_60/eprom.phtml` | the list of 3/60 boot PROM images (1.0-3.0.1) | where a stock PROM comes from; **the images are not copied here** |
| `Errormsg/3_60error.phtml`, `gif/leds/` | 3/60 self-test LED codes | reading the diag LEDs during bring-up |
| `hardpatches/3.60-tuning/` | overclocking a 3/60 (40 MHz oscillator to 48-50 MHz), a 68030 in 020 mode, 68881 to 68882 | the clock options (Phase 6) |
| `install/install.phtml`, `install/4.1_install.phtml`, `BootTapes/` (README, `maketape1/2`, `xdrtoc` files) | SunOS 4.1.1 install media and how the boot tapes are laid out | `tools/mktape` (Phase 3). The tapes' contents are SunOS itself, not in this repository |
| `harddisk/format.dat` | the master `format.dat` | disk labels for the images |
| `tune/adb-kernel.phtml` | kernel tunables, including the 5380's SCSI ID | SunOS settings |
| `papers/Hardware/*.ps.gz` | Sun papers: virtual memory architecture, Sun systems and their caches, cached I/O | background |

## Elsewhere, not copied

* MAME `src/mame/sun/sun3.cpp`, `sun3x.cpp`: model
  notes, the 3/60's OBIO map, the parity and ECC registers.
* NetBSD `sys/arch/sun3/dev/`:
  * `cg4.c`, `cg4reg.h`, `btreg.h` (cg4 and its Brooktree DACs);
  * `p4reg.h` (P4 IDs);
  * `bw2.c`, `if_le.c`, `si*.c`;
  * `sys/arch/sun3/conf/GENERIC`.
* MelkhiorVintageComputing:
  * `sun3-bootrom` (a GPL-2.0 build of the SunOS 3.2 boot PROM sources, targeting the 3/160);
  * `Sun3_BootDir` (netbooting a Sun-3; not used for bring-up);
  * `sun3_60` (54weasels' homebrew 3/60 board: KiCad schematics, decoded PALs).
* lbmactwo_MiSTer `SingleStepTests/`: the 68020 CPU corpus and the
  68020+68881 FPU corpus (hardware-verified on a Mac II), Phase 3's
  acceptance tests.
