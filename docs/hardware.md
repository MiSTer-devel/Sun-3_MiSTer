# The machine: a Sun-3/60C, maxed out

Locked with the owner on 2026-10-04. This file is the hardware contract: the
RTL builds exactly this machine. A change here comes before any change to the
RTL. How it gets built is in [design-plan.md](design-plan.md).

## Why the 3/60

The Sun-3 line has two kernel architectures:

- **sun3**: 68020 with Sun's own MMU. The 3/50, 3/60, 3/1xx, 3/2xx and 3/E.
- **sun3x**: 68030 with its on-chip MMU. The 3/80 and 3/4xx.

The fastest sun3 is the 3/260/280 (25 MHz, 64 KiB virtual cache, VME). The
fastest of the whole line is the sun3x 3/470/480 (33 MHz 68030).
[references/sun3arc/text/general.phtml](references/sun3arc/text/general.phtml)
has the full model list.

The core is a **3/60 ("Ferrari") taken to the 3/60's own limits**:

- the most memory it takes, 24 MiB;
- the MC68881;
- the P4 colour board;
- a CPU clock that can go past 20 MHz.

Owners overclocked real 3/60s to 24-25 MHz
([sun3arc hardpatches](references/sun3arc/hardpatches/3.60-tuning/over.phtml)).

We chose it because:

* **It is the proven path.** MelkhiorVintageComputing's [Sun-3_FPGA](https://github.com/MelkhiorVintageComputing/Sun-3_FPGA) is a
  3/60 with these devices. It boots SunOS 4.1.1 multi-user and NetBSD/sun3 on
  real FPGAs: an Artix-7 up to 45 MHz, and a MAX 10.
* **Its colour board has no raster-op hardware.** The cg4 is a plain frame
  buffer. Unlike the Sun-2's cgtwo, there is no rop engine to specify or
  build.
* **The 3/260 was considered and declined.** It is the faster sun3, but it
  needs a VME bus, a virtual-address cache, ECC memory boards and a new PROM
  bring-up, with no FPGA reference.
* **The 3/80 (sun3x) was considered and declined.** It needs a 68030 with an
  MMU, an IOMMU, ESP SCSI and a 48T02. Sun-3x stays a possible separate core
  later (see the CPU section).

## The inventory

| | A real 3/60C | This core |
|---|---|---|
| ID PROM machine type | `0x17` (3/60) | `0x17`, from Main_MiSTer (`boot1.rom`, else built from the MiSTer's Ethernet address) |
| CPU | MC68020, 20 MHz (40 MHz oscillator U110 / 2) | **RD68021**, 20 MHz, or 25 / 33.33 MHz from the OSD (design-plan, Phase 6) |
| FPU | MC68881, 20 MHz, CpID 1 | **RD68884** at CpID 1, on the CPU's clock |
| MMU | Sun-3 MMU: 8 contexts, segment map, page map, 8 KiB pages | Sun-3_FPGA `sun3_mmu.v`, `smap.v`, `pmap.v` |
| Main memory | up to 24 MiB of 1Mx9 SIMMs, with parity | **24 MiB on the SDRAM board** (a 32 MiB or larger module), no parity |
| Boot PROM | 64 KiB, Rev 1.9 / 2.8.3 / 3.0.1 | the user's **patched "noparity" PROM**, `games/Sun-3/boot0.rom`, sent by Main on ioctl index 0 |
| EEPROM | 2 KiB X2816, OBIO 0x040000 | block RAM, preloaded with a working layout, and kept in a 2048-byte image file on the OSD's EEPROM slot |
| Time of day | Intersil ICM7170, OBIO 0x060000 | Sun-3_FPGA `icm7170.v`, set from the MiSTer's RTC and clocked from a fixed clock, never the CPU's |
| Keyboard, mouse | Z8530 at OBIO 0x000000: Type-3 keyboard (later boards Type-4), Sun-3 mouse | `z8530_scc`. The keyboard and mouse are MiSTer's, through the Sun-2's model (identifies as Type 3, with its bell) |
| Serial ttya/ttyb | Z8530 at OBIO 0x020000, 4.9152 MHz | `z8530_scc`. ttya on MiSTer's UART (`UART9600`) |
| Ethernet | AMD Am7990 LANCE, OBIO 0x120000, level 3 | **Wish7990**. Its MII goes to a DDR3 mailbox served by Main's `support/sun` (magic `S3ETH001`) |
| SCSI | NCR 5380 + Am9516 UDC + CSR, OBIO 0x140000, level 2 | Sun-3_FPGA `sun3_si.sv` + Wish5380. Targets: two disks, at ID 0 and ID 1, on MiSTer disk images, and **st0** (ID 4) an Emulex MT-02 QIC tape (from the Sun-2). SunOS numbers SCSI devices by target × 8 + LUN, so the disks are **sd0** and **sd2** (sd1 would be target 0's LUN 1), as sun3arc's install guide lists them ([references/sun3arc/install/install.phtml](references/sun3arc/install/install.phtml)). The PROM's unit number depends on its revision: Rev 1.9's disk driver takes target = unit >> 2 and LUN = unit & 3 (its tape driver shifts by 3), so it boots the second disk as `sd(0,4,0)`; Rev 3.0.1, and sun3arc's table, shift by 3: `sd(0,8,0)`. **sr0** (ID 6, `SUN3_CDROM`, `sun3_cdrom.sv`) is a CD-ROM drive on a flat `.iso` (OSD slot 4): a SONY CDU-8012 to INQUIRY (type 5, removable), the drive SunOS 4.1's sr(4S) names. It comes up in 512-byte blocks, as Sun's CD drives did: SunOS 4.1's sr driver is built `FIVETWELVE` ("default to 512 bytes/sector", `sundev/srreg.h` 1.2 and `scsi/targets/srdef.h` 1.11, read from a SunOS 4.1.3 system), and the PROM boots a CD with its disk driver, Sun label and all, as `sd(0,30,N)` on Rev 3.0.1 (sun3arc: `sd(0,30,4)` for the 4.1.1 CD's sun3 partition). MODE SELECT with a block descriptor changes it to 2048 and back; no other size (no mode 2). Without a disc it answers NOT READY / 3A; a disc put in while the machine runs is one UNIT ATTENTION / 28 |
| Mono video | bw2, 1152x900 (or 1600x1280 by jumper), obmem 0xFF000000, level 4 | bw2 at 1152x900, its memory on the SDRAM board. Shown 1:1 at 1080p, as on the Sun-2 |
| Colour video | P4 **cg4** (501-1210): 8-bit colour + 1-bit overlay + 1-bit enable, Brooktree DACs, 1152x900 | **cg4**, its planes on the SDRAM board, its own scan-out. OSD "Colour board On/Off" (Phase 4) |
| Accelerated colour | P4 **GX / cg6** (501-1374), console needs PROM ≥ 3.0 | **later** (Phase 8) |
| Diagnostics | 8 LEDs (System Diag register), NORM/DIAG switch | the LEDs to MiSTer's user LED and the OSD, the switch on the OSD |
| Interrupts | 1 soft, 2 SCSI, 3 Ethernet, 4 video, 5 clock, 6 SCC, 7 clock/parity NMI | as the 3/60 (Sun-3_FPGA `sun3_irq_priority.v`, from the PAL equations). Level 4's source is the DSACK PAL's choice between the on-board video and the P4 board (`sun3_vint.v`, docs/cg4.md) |
| Not on a 3/60 | VME, floppy, parallel port, audio, ECC, cache | not built |

## Address map

Physical, as the MMU's page types decode it. Sources:
- the Sun-3 Architecture Manual
  (listed in [references/](references/README.md); the PDF is not in this
  repository);
- Sun-3_FPGA `sun3_fpga.v`;
- MAME `src/mame/sun/sun3.cpp`;
- NetBSD `sys/arch/sun3/dev/p4reg.h`.

**Control space (FC 3)**

| address | |
|---|---|
| 0x00000000 | ID PROM (32 bytes) |
| 0x10000000 | page map |
| 0x20000000 | segment map |
| 0x30000000 | context register |
| 0x40000000 | System Enable: diag switch, FPA, copy, video, cache, SDVMA, FPP, boot |
| 0x60000000 | Bus Error register |
| 0x70000000 | System Diag (the LEDs) |

**Type 1, OBIO**

| address | |
|---|---|
| 0x000000 | Z8530 keyboard/mouse |
| 0x020000 | Z8530 ttya/ttyb |
| 0x040000 | EEPROM |
| 0x060000 | ICM7170 |
| 0x080000 | memory error / parity |
| 0x0A0000 | interrupt register |
| 0x100000 | boot PROM |
| 0x120000 | LANCE |
| 0x140000 | SCSI: 5380, UDC, CSR |

**Type 0, OBMEM**

| address | |
|---|---|
| 0x00000000 | main memory, to 24 MiB |
| 0xFF000000 | on-board bw2 |
| 0xFF200000 | cg4 DACs (P4 base - 1 MiB) |
| 0xFF300000 | P4 register: ID `0x4` (cg4) and size `1` (1152x900) in bits 30:24, plus the video, sync, vertical-retrace and interrupt bits |
| 0xFF400000 | cg4 overlay plane |
| 0xFF600000 | cg4 enable plane |
| 0xFF800000 | cg4 colour plane |

## Media

The software is not in this repository. What the core was brought up with:

* the operating systems:
  * SunOS 3.5, 4.0, 4.0.3, 4.1.1 and 4.1.1_U1;
  * the 4.1.1 patches;
  * the sun3arc SunOS 4.1.1 tape set: `tpboot.sun3`, `munix`, `munixfs`, `miniroot_sun3`, every `tar` set and the `maketape` scripts;
* third-party software for SunOS: gcc 2.7.2.2 / 2.8.1 / 3.2.3, binutils, perl 5.8.8, OpenSSH, Mosaic, VNC and others.

**Installation is from QIC tape** (`st0`), built by `tools/mktape` (from the
Sun-2). Netbooting is not part of bring-up. 4.1.1 also shipped on CD
(`SunOS411.sun3.CDROM.xdrtoc`), and there is a CD-ROM drive (sr0, above) for
an `.iso` of it, but no CD is at hand: the drive is tested with a CD made by
`tb/verilator/mk_cd_iso.py`, whose partition both PROMs boot in `tb_emu`:
Rev 3.0.1 as `sd(0,30,1)`, Rev 1.9 as `sd(0,18,1)` (its disk unit is
target × 4), though sun3arc lists 1.9 as unable to boot a CD.

## Open questions on the hardware

1. **Which frame buffer the PROM's console takes** with a cg4 fitted. Sun-3_FPGA found:
   * Rev 1.9 always probes the on-board bw2;
   * Rev 3.0.1 probes the P4 first. It showed a white or black screen there, with no keyboard and no P4 board.

   Settled for 3.0.1 (2026-10-22, by disassembly, tb_emu and the board):
   its bw2 path reads the on-board video's resolution at obmem 0xFF1C0000
   (bit 7 set: 1152x900) and sets the console's width and height only from
   it. Upstream let that read time out, so with no P4 board the console was
   zero wide: the white screen. The core answers it now (`MATCH_VIDSENSE`,
   0x80), and 3.0.1 runs with the colour board on and off. It is the
   default `boot0.rom` since; 1.9 is a *Load ROM* away.

   A 3/60C was often a "without mono" board (501-1322/1345) plus the cg4.
   Whether "Colour board On" should also remove the on-board bw2 is open.
2. **Type-3 or Type-4 keyboard** under Rev 1.9 (Phase 2).
3. ~~**The EEPROM's save file**~~: settled, a mounted image slot
   (`SC3,NVR`), as SunSparcStation keeps its NVRAM.
