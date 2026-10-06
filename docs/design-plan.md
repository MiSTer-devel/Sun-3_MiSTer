# Design plan: Sun-3/60C for MiSTer

Written 2026-10-04, with the hardware locked in [hardware.md](hardware.md).
Each phase ends with something visible on the board and a test that guards it.
Order of priority, from the owner:

1. a working SunOS machine;
2. **colour**;
3. Ethernet;
4. the rest of what the Sun-2 core does: keyboard, mouse, bell, clock, ID
   PROM from Main, disk and tape images, OSD;
5. speed.

## Where it stands (2026-10-05)

* On a MiSTer: the PROM on the colour console, the keyboard, the EEPROM kept
  in a file, and **SunOS 4.1.1_U1 with the Y2K patch and the later patches
  on a 1 GB disk image, booting multi-user** ([install-sunos.md](install-sunos.md)).
  The kernel finds `cgfour0`.
* Main_MiSTer `sun-family` knows the Sun-3: the disk write buffer, the ID
  PROM with machine type 0x17, and the `S3ETH001` mailbox. `releases/MiSTer`
  is `de5e963` on upstream `c97c052` (pushed), on the board since
  2026-10-06; Phases 1 to 6 were tested on `55fe6c8`.
* `releases/`: the core (`Sun-3_20261005.rbf`, built from `7bc4785`), that
  Main, and the patched 1.9 PROM as `boot0.rom`.
* The core on the board (`_Unstable/Sun-3_20261005-clk.rbf`) has the
  second disk (Phase 3, step 1), the packed SCSI DMA, the cg4's overlay
  gated by its enable plane, level 4 through the DSACK PAL, the LANCE, and
  the CPU clock from the OSD.

**Disk speed** (Phase 3, step 5) is done: the SCSI DMA moves a longword per
cycle, and raw reads went from 850 KB/s to 1.36 MB/s. Small-file work is
the kernel's CPU time now (Phase 6). **U1, the Y2K patch and the later
patches** (step 4) are installed. **Phase 3 is done**: the second disk,
SunView in mono with the mouse, and the 68881's digits. **Phase 4 is
done**: SunView (each plane group, and two desktops) and OpenWindows 2.0 run
in colour, the colour board costs the CPU nothing measurable, and the
benches drive the cg4 as SunOS does. In **Phase 5** the LANCE is in the
core and `le0` works on the LAN and comes up at boot: pings to 16,000
bytes, telnet, FTP and bulk TCP both ways, with equal sums. NFS is left
out (no server on the LAN). **Phase 6**'s CPU clock is done: 20, 25 or
33.33 MHz from the OSD, the main PLL's counter rewritten in a reset, timing
met at 33.33 MHz, and on the board Dhrystone 2.1 goes from 3,250 to 5,450
a second with the TOD keeping time. Next: Phase 7, the release.

## Ground rules (carried over from Sun-2_MiSTer, where each was learned)

* **A plain checkout builds** with Quartus 17.0.2 and nothing else:
  * no git submodules and no generation step at build time;
  * third-party RTL is copied unmodified into `rtl/vendor/<name>/`, its
    upstream commit and licence recorded in `rtl/vendor/README.md`;
  * a needed change lives in `rtl/patched/` with the reason written down;
  * `sys/` is Template_MiSTer `3ea1134`, verbatim.
* **One fixed machine.** The `.qsf`'s `VERILOG_MACRO` block is the single
  source of the configuration (`SUN3_*` macros, as `sun3_config.vh` names
  them). Runtime choices are OSD options, never build variants.
* **Builds, one at a time.**
  * A build is about 17-20 minutes. Kill it at 45 minutes and find out why.
  * Read "Global & Other Fast Signals" after every fit. The machine's clock
    must be on a GCLK.
  * Never take a new clock from the main PLL: it has no spare global line,
    and the Sun-2's network build sat 80 minutes in the fitter because of one.
* **Every piece of MiSTer glue has a Verilator bench and a mutation script**
  (`tb/verilator`, as in the Sun-2). A whole-machine bench (`tb_emu`) runs the
  PROM to its prompt.
* **Scripts are LF** (`.gitattributes`; this machine checks out CRLF). WSL
  runs the benches.
* Commit to `master`; ask before pushing. Push over HTTPS with `gh` as the
  credential helper, because SSH to GitHub is refused from this PC.

## Where the pieces come from

| piece | source | how |
|---|---|---|
| The machine: MMU, control space, OBIO glue, memory bridges, SCSI board, LANCE glue, bw2 scan-out | [Sun-3_FPGA](https://github.com/MelkhiorVintageComputing/Sun-3_FPGA) `rtl/sun3/` (Romain Dolbeau) | copied to `rtl/sun3/`. It is not vendored, because it will be edited for MiSTer. The commit is noted in each file's header and in `rtl/sun3/README.md` |
| RD68021 (68020) | MelkhiorVintageComputing/RD68021 | `rtl/vendor/rd68021/`, built with `COPROCESSOR=1` |
| RD68884 (68881) | MelkhiorVintageComputing/RD68884 | `rtl/vendor/rd68884/` |
| Wish7990 (LANCE) | MelkhiorVintageComputing/Wish7990 | `rtl/vendor/wish7990/` |
| Wish5380 (5380, SCSI targets, fabric) | MelkhiorVintageComputing/Wish5380 | `rtl/vendor/wish5380/` |
| z8530_scc | vz50938/z8530_scc | `rtl/vendor/z8530_scc/` |
| SDRAM controller + adapter | Sun-2_MiSTer `rtl/sdram.sv`, `sun2_mister_sdram.sv` | copied. It already speaks the 32-bit Wishbone plus 128-bit line of the cached FIFO bridge, and has the scan-out clients |
| Disk/tape block bridge | Sun-2_MiSTer `sun2_mister_block.sv` | copied to the Sun-3's Wish5380 block seam (the same seam) |
| MT-02 tape target | Sun-2_MiSTer `sun2_mt02.sv` | copied into the SCSI fabric as target 4 |
| Keyboard/mouse, bell | Sun-2_MiSTer `sun2_mister_kbd_mouse.sv`, `sun2_mister_bell.sv` | copied. Parameterised on a fixed clock, not the CPU's |
| Network mailbox | Sun-2_MiSTer `sun2_mister_enet.sv` | copied, with magic `S3ETH001`. The MII side is the same standard MII |
| Video timing, 1:1 at 1080p | Sun-2_MiSTer `video_timing.sv`, `pll.v` (83.333 MHz), `video_freak` use | copied |
| PROM tools | Sun-3_FPGA `tools/rompatch.c`, the patch lists, `tools/rom.c` | copied to `tools/` |
| Tape images | Sun-2_MiSTer `tools/mktape` | copied, taught the sun3arc `maketape` layout of 4.1.1 / 3.5 |
| Main_MiSTer | branch `sun-family` (`support/sun/`) | a `Sun-3` entry; see Phase 5 |

### Licences

The repository is GPL-3.0. Three things are open, and must be settled before
a public release:

1. **Sun-3_FPGA has no licence file.** Ask Romain Dolbeau what it is under,
   as for the Sun-2.
2. **RD68021 and RD68884 are CERN-OHL-S-2.0.** Their compatibility with
   GPL-3.0 is the same question the Sun-2 has for RD68011.
3. **Wish5380 and Wish7990** are MIT by SPDX header, with no LICENSE file
   upstream. z8530_scc is GPL-3.0.

## Clocks

| clock | MHz | from | runs |
|---|---|---|---|
| `clk_mem` | 100 | main PLL | SDRAM, the memory side of the bridge, `hps_io`, the cg4's register side, the network mailbox, the keyboard/mouse model |
| `clk_pix` | 83.333 | main PLL | 1152x900 in a 1472x937 raster (60.4 Hz), shown 1:1 at 1080p |
| `clk_mii` | 2.5 | main PLL | the LANCE's MII, 10 Mb/s |
| `clk_ser` | 4.9152 | its own fractional PLL | the SCCs' baud generators |
| `cpu_clk` | **20**, or 25 / 33.33 from the OSD | main PLL, `outclk_1` (C1) | RD68021, RD68884, `sun3_fpga` |
| `CLK_50M` | 50 | the framework's pin | `sun3_mister_cpuclk` and `pll_cfg`, which reconfigure the main PLL |

The main PLL has the Sun-2's four outputs in the Sun-2's order, so
`cpu_clk` gets the global line the Sun-2's does. **`cpu_clk` was meant to
have a PLL of its own, and cannot**: the first fit (2026-10-04) found the
DE10-Nano's 50 MHz pins reach only three fractional PLLs, and HDMI and the
serial clock hold two. So (Phase 6) its one output counter is reconfigured
instead: `rtl/pll/pll_0002.v` is ip-generate's reconfigurable form of the
same PLL, every output fixed to its counter over one 500 MHz, and
`rtl/sun3_mister_cpuclk.sv` rewrites C1 (/25, /20 or /15) through
`sys/pll_cfg` (`altera_pll_reconfig`, as sys_top does for HDMI). It does so
only while the machine is in reset, and holds it there until the clock has
settled; the other outputs keep their counters, and M and N never change,
so the PLL stays locked. `Sun-3.sdc` times `cpu_clk` at the fastest setting.

For that to be safe, nothing may count CPU clocks to keep real time:

* the ICM7170 takes a fixed 1 MHz tick made from `clk_mem`
  (`rtl/sun3_mister_tick.sv`, `SUN3_TOD_TICK_HZ`), not `cpu_clk`, so the
  time and SunOS's 100 Hz clock interrupt stay right;
* the keyboard/mouse model's 1200 baud comes from `clk_mem`;
* the SCCs already have `clk_ser`.

What changes with the CPU clock is what changes on a real overclocked 3/60:
the PROM's and SunOS's delay loops get shorter. So do the few delays the
machine counts in CPU clocks, set for 20 MHz: the SCSI board's 400 ns bus
settle, the tape's 5 ms of motion, and the LANCE's 1.6 ms ring poll.

## Memory (SDRAM board, 32 MiB minimum)

| SDRAM | size | |
|---|---|---|
| 0 - 24 MiB | 24 MiB | main memory, banks 0-2 |
| 24 MiB | 256 KiB | bw2 (the 3/60's architectural window; 1152x900 uses 126.6 KiB) |
| 25 MiB | 1 MiB | cg4 colour plane, a byte a pixel |
| 26 MiB | 128 KiB + 128 KiB | cg4 overlay and enable planes |

Everything visible on screen lives in bank 3, away from the CPU's banks.

The CPU reaches memory through Sun-3_FPGA's cached FIFO bridge (8 KiB read
cache, posted writes). Frame buffer cycles are never cached.

The SDRAM adapter has three clients:
* the CPU bridge;
* the bw2 scan-out, which is small and keeps its absolute priority;
* the cg4 scan-out, which takes turns with the CPU and gets priority only when
  its line buffer is about to run dry (the Sun-2's `cs_urgent` scheme).

The cg4 scan-out is about 78 MB/s at 60 Hz: 62 for the colour plane and 16
for overlay and enable. That is measured in Phase 4. **Fallback** if the CPU
starves: move the colour plane to DDR3. Sun-3_FPGA's scan-out already reads
DDR3 in 128-bit beats.

DDR3 holds only the network mailbox, at ARM physical 0x1FF00000, as on the
Sun-2.

## OSD (Sun-3.sv's CONF_STR, every phase's items in)

```
Sun-3;UART9600;
SC0,IMGVHD,SCSI disk ID 0 (sd0);
SC1,IMGVHD,SCSI disk ID 1 (sd2);
S2,QIC,Tape (st0);
O[4:3],Tape volume,1,2,3;
SC3,NVR,EEPROM;
-;
O[2:1],Aspect ratio,Original,Full Screen,4:3;
O[6:5],Scale,V-Integer,Normal,Narrower HV-Integer,Wider HV-Integer;
O[12],Colour board,On,Off;
O[14:13],CPU clock,20 MHz,25 MHz,33 MHz;
-;
O[8:7],Keyboard bell,Normal,Loud,Quiet,Off;
O[16],Clock,MiSTer's time,28 years back;
O[11:9],Network,eth0,Off,eth1,macvlan,tap0;
O[15],Diag switch,Normal,Diag;
-;
R0,Reset;
```

Three rules for the status bits:
* The Network bits are what Main's core table names, `[11:9]` as on the Sun-2.
* A value of 0 is always the default.
* What a board would only change powered off -- the colour board, the CPU
  clock, the diag switch -- is taken while the machine is in reset: a change
  made while it runs waits for the next reset.

## Phases

### Phase 0: repository, template, plan (this session)

The template is renamed to Sun-3. The hardware is locked, this plan is
written, and the sun3arc reference material is mirrored into
`docs/references/` (here, its text files only). The repository is pushed.

### Phase 1: the PROM prompt on the MiSTer's serial line

1. Vendor the cores.
   * Copy `rtl/sun3/` from Sun-3_FPGA, with its `sun3_config.vh`.
   * Remove the Wukong/DECA board layers, the Suska path and the debug-only
     modules. Keep `fault_log` and `bus_trace` behind a macro.
2. `Sun-3.sv`, modelled on `Sun-2.sv`:
   * the PLLs above;
   * the SDRAM adapter;
   * reset held until the SDRAM is initialised and the PROM has arrived.
3. **Boot PROM loader**: `games/Sun-3/boot0.rom`, 64 KiB, ioctl index 0, into
   a 16K x 32 block RAM. The machine stays in reset until the PROM is in.
4. `tools/`: `rompatch` and the patch lists for 1.9 and 3.0.1. Document how
   to make `boot0.rom` from a stock image: sun3arc's `ROMs/3_60/` or the
   qemu-sun3 archive. The stock images are not in the repository.
5. The EEPROM is preloaded with the console on ttya. ttya is MiSTer's UART.
6. Tests:
   * `tb_emu` (Verilator) runs the 1.9 + noparity + fastboot PROM to `>`;
   * the Sun-2's SDRAM bench, re-run against the new map.

**Done when** the board's UART (from the MiSTer's Linux) shows `Sun
Workstation, Model Sun-3/60M`, `24MB memory installed`, and the `>` prompt.

### Phase 2: a console on the screen

1. bw2 scan-out on HDMI.
2. Keyboard and mouse:
   * the Sun-2 model, identifying as Type 3, with Right Alt + F1..F10 for
     L1..L10;
   * try Type 4 under 1.9 and 3.0.1, and add an OSD choice if both work.
3. The bell.
4. The ICM7170 set from the MiSTer's RTC. Its NMI tick (level 7) and level 5
   must be right: Sun-3_FPGA fixed a double level-7 bug in RD68021 `e9d1618`.
   Main sends local time and SunOS keeps UTC in the chip, so an installed
   system has its zone linked to GMT (install-sunos.md, "The clock"). Real
   UTC would need an OSD offset or a Main change.
5. The ID PROM from Main (Phase 5 adds Main's half; until then the built-in
   default). **Done** with Main `sun-family` `55fe6c8`: on the board the
   banner shows an address made from the MiSTer's own
   (`8:0:20:2D:D0:A3`, serial 3002531).
6. EEPROM persistence: the OSD's `SC3,NVR,EEPROM` slot, a 2048-byte image
   that Main remembers and mounts again at every core load, as
   SunSparcStation keeps its NVRAM. No Main change is needed.
   `rtl/sun3_mister_eeprom.sv` (bench `tb_mister_eeprom`, `mutate_eeprom.sh`):
   * the image is read into the EEPROM while the machine is held in reset;
   * an all-zero file is a new one, and is given the built-in layout;
   * the EEPROM is written back half a second after the machine's last
     write to it.

   **Status (2026-10-04): done, checked on a MiSTer.** A new file took the
   built-in layout. A boot device of `st` typed with the PROM's `q` reached
   the file. At the next core load the PROM booted the tape from it to
   SunOS 4.1.1's installer.
7. Tests: the keyboard/mouse, bell and TOD benches from the Sun-2, adapted.

**Done when** the PROM's banner, `>`, and typing work on the screen and
keyboard. `k2` reboots. Self-tests pass with the diag switch on.

### Phase 3: SunOS from tape, with the FPU

1. SCSI: `sun3_si` + Wish5380 disk targets at ID 0 and ID 1 (SunOS's sd0 and
   sd2: it numbers devices by target × 8 + LUN), and the MT-02
   as st0 (ID 4), each on the Sun-2's block bridge.

   **Status (2026-10-04):** the second disk is built (`SUN3_SD1`, OSD
   `SC1`, the tape moved to `S2`) and checked in `tb_emu`. The Rev 1.9 PROM
   boots it as `sd(0,4,0)`: its disk unit is target × 4 + LUN (hardware.md).
   The fit is 23,746 ALMs (57%) and 313 M10K, with timing met.

   **Status (2026-10-05):** on the board. SunOS finds the disk at ID 1 as
   `sd2` with its label, and `format` lists it. A 1 GB image took `newfs`
   (84 s), a copy of `/usr/include` read back the same, and a clean `fsck`
   (install-sunos.md, "A second disk").
2. `tools/mktape`: build `.qic` images from the SunOS distributions.
   * SunOS 4.1.1 from the sun3arc set (tpboot, munix, munixfs, miniroot, the
     tar sets, `xdrtoc` for QIC-24).
   * SunOS 4.0 and 4.0.3 from their per-file tape dumps, the same layout as
     the Sun-2's.

   **Status (2026-10-04):** done, with the Sun-2's labelled disks
   (`--disk --size --root`) and its `format.dat` patching of MUNIX's RAM disk
   and the miniroot. Also built: `sunos-4.1.1u1-sun3.qic`, and
   `sunos-4.1.1-patches.qic`, the 532 patches in one tar file.
3. **RD68884** at CpID 1, `FPU_WAIT` as timing needs.
   **Acceptance for the FPU**: lbmactwo_MiSTer's `SingleStepTests/cpu_fpu`
   corpus.
   * It has 1,328 FPU tests plus 8 FSAVE/FRESTORE tests, and scored 1319/1320
     on a real Mac II, which is the same 68020 + 68881 pair.
   * Port its Verilator runner to RD68021 + RD68884.
   * Also run its 696 + 22 CPU tests (MAME oracle) against RD68021.
4. Install SunOS 4.1.1 with `suninstall` from tape onto a 1 GiB `sd0`. Then
   install 4.1.1_U1 with `install_unbundled`, and the patches.

   **Status (2026-10-05):** 4.1.1 is installed on a MiSTer, every package
   from both tapes, and boots multi-user; **4.1.1_U1** is installed over it
   (`uname`: `SunOS sun3 4.1.1_U1 1 sun3`), and so is sun3arc's
   **`y2kpatch-04`**, with its shared libcs as `libc.so.0.15.3` and
   `1.15.3` (docs/install-sunos.md, sections 5 to 7). `date`, `w`, `cc`
   and `ldd` work on the new libc. Of the patches tape's 174 patches, 78
   were not covered by those ([sunos-patches.md](sunos-patches.md)); 74 of
   them are installed (section 8, `tools/sunos/mkpatchkit.py`), with a
   GENERIC kernel rebuilt from the patched objects that boots as `/vmunix`
   (`#1: Mon Oct 5 07:34:40 GMT 2026`). The four left out are not needed
   here. The Y2K patch's files are unchanged.
5. **Disk speed.** The install took 2¼ hours,
   almost all of it waiting on the disk. Measured on the board with a stock
   Main:
   * `newfs` of the 973 MB `/usr`: about 20 minutes, around 50 KB/s of
     writes;
   * the `usr` set (11.6 MB compressed, about 10,000 files): 23 minutes.
     `Kvm` (2 MB) took 2;
   * `fsck` of `/usr` at every boot: about 3 minutes.

   A block's path: SunOS's `sd` driver, then `sun3_si` (the 5380 and the
   UDC's DMA, a byte per DVMA cycle), then Wish5380's `scsi_targ`, then
   `sun3_mister_block` (one 512-byte block per request, copied across in
   512 CPU clocks), then `hps_io`, then Main. Main serves one block per
   request, writes each with `O_SYNC` (about 4 ms on the Mac cores), and
   reads with a 16 KB read-ahead. Main `55fe6c8` adds a write buffer for the
   Sun-3's disks: runs of up to 64 KB, written out after 20 ms idle.

   **Measured (2026-10-04)** with Main `55fe6c8`, the CPU at 20 MHz and the
   colour board on, by bash's `time`, the results through ttya
   (`tools/sunos/dbench.sh`, `tools/sunos/membench.c`):

   | | time | rate | CPU |
   |---|---|---|---|
   | raw read, 64 KB × 160 | 12.3 s | 850 KB/s | 1.7 s sys |
   | raw read, 8 KB × 256 | 3.5 s | 585 KB/s | 1.1 s sys |
   | raw read, 512 B × 512 | 3.0 s | 85 KB/s | 2.0 s sys |
   | file write, 10 MB and `sync` | 19.3 s | 530 KB/s | 18.2 s sys |
   | `tar` copy of `/usr/include`, 3.1 MB in 958 files | 101 s | 31 KB/s | 39 s sys |
   | `rm -rf` of that copy | 40.5 s | | 25 s sys |
   | cold `tar` read of `/usr/lib`, 23 MB | 66 s | 350 KB/s | 50 s sys |
   | `fsck -n` of `/usr`, 10,741 files | 200 s | | 88 s user, 36 s sys |
   | 300 fork-and-execs of `expr` | 65 s | | 20 s user, 45 s sys |

   During the `tar` copy `vmstat` shows the CPU 65% system and 24% idle, and
   `iostat` 12 reads and 50 writes a second with the disk under 50% busy.
   fsck's phase 1 alone takes 164 s. From user space (`membench`): writes
   6.5 MB/s, reads 6.1 (7.1 from the cache), `bcopy` 3.3, `bzero` 4.9.

   In `tb_emu` (a tape boot with `+trace_vd`, the HPS model answering at
   once) a multi-block read moves a block every 548 µs: 935 KB/s, 21 CPU
   clocks a byte. The board's 600 µs a block is within 10% of that.

   What it shows:
   * **Large transfers are held by `sun3_si`'s DMA**, not by `hps_io` or
     Main. Each byte is a DVMA cycle of its own: BR/BG/BGACK, the bus cycle,
     then a 7-clock backoff. The target's two-bank read-ahead already hides
     Main's time. While a transfer runs the DMA has most of the bus, so the
     CPU's work slows with it (the 10 MB write is 94% system time).
   * **The small-file work that made the install slow is CPU-bound.** A
     command costs SunOS about 4 ms of kernel time; the disk is idle half
     the time. Main's write buffer took the `O_SYNC` writes out: `newfs` ran
     at 50 KB/s on the stock Main, a 10 MB file now writes at 530 KB/s.
   * **fsck is the inode count**: `/usr` was made with `newfs`'s default
     density, and phase 1 reads every inode.

   **Done (2026-10-05): the DMA moves a longword per DVMA cycle.** Received
   bytes are gathered and written together; sent bytes come from one
   longword read (rtl/sun3/README.md). `tb_si` runs 32 commands through the
   new engine and the old one (kept as `tb/verilator/sun3_si_ref.sv`) and
   requires the same memory, disk and registers after each; `mutate_si.sh`
   checks it. A DVMA cycle now carries 9.3 CPU clocks a byte reading and
   9.1 writing, where it was 21.1 and 24.1; in `tb_emu` a tape block every
   293 µs instead of 553. Fit: 23,834 ALMs (+88), timing met. On the board,
   the same disk (a copy, then the real one):

   | | before | after |
   |---|---|---|
   | raw read, 64 KB × 160 | 12.3 s, 850 KB/s | **7.7 s, 1.36 MB/s** |
   | raw read, 512 B × 512 | 3.0 s | 2.9 s |
   | file write, 10 MB and `sync` | 19.3 s | 16.5 s |
   | `tar` copy of `/usr/include` | 101 s | 91.5 s |
   | `rm -rf` of that copy | 40.5 s | 38.6 s |
   | cold `tar` read of `/usr/lib` | 66 s, 350 KB/s | 56.7 s, 405 KB/s |
   | `fsck -n` of `/usr` | 200 s | 170 s |
   | 300 fork-and-execs of `expr` | 65 s | 65.2 s |

   The copy of `/usr/include` matched the original file for file
   (`diff -r`, after reading `/usr/lib` to empty the cache), and `fsck -n`
   found both file systems clean.

   Raw reads now pass the 1 MB/s of a real 3/60. A block takes 376 µs on the
   board against about 240 µs on the bus, so the HPS round trip is the
   larger share again; multi-block requests (`sd_blk_cnt`) would help large
   transfers, which SunOS seldom makes. Everyday disk work is the kernel's
   CPU time. What is left, in order of expected gain:
   1. The CPU clock (Phase 6).
   2. ~~The colour scan-out's share of the SDRAM~~: measured in Phase 4
      (2026-10-05), it costs nothing.
   3. Fewer inodes: `newfs -i 8192` or more on new disks, in `mktape --disk`
      and docs/install-sunos.md (fsck's phase 1 is 138 s of the 170).
   4. Multi-block HPS requests, for large transfers.

   **Done when** the numbers are written down before and after, and a raw
   read is near a real 3/60's on-board SCSI (about 1 MB/s).

**Done when** SunOS 4.1.1 boots multi-user from the image, and SunView runs
on the mono screen. Floating-point programs built with `cc -f68881` give the
digits Sun-3_FPGA measured. Halt and reboot work. fsck is clean after a halt.

**Status (2026-10-05): done**, on the MiSTer:
* `sunview -overlay_only` (the cg4's mono plane) is up 9 s after the
  command. Keys reach its shelltool, the mouse moves the pointer, the root
  menu opens, and Exit SunView returns to the console.
* Sun-3_FPGA's floating-point program (`sqrt`, `sin`, `exp`, and 200,000
  terms of `sqrt(x)*sin(x)/x`):

  | build | `exp(1)`, `pow(2,0.5)` | `user` at 20 MHz | Sun-3_FPGA, 43.48 MHz |
  |---|---|---|---|
  | `cc -O -f68881` | 2.7182818284590451, 1.4142135623730951 | 156.0 s | 70.6 s, the same digits |
  | `cc -O -fsoft` | ...455, ...949 (the library's rounding) | 548.4 s | 243.2 s, the same digits |

  The 68881 is 3.5 times the software (Sun-3_FPGA: 3.45), and the times
  scale with the clock.
* Halt, reboot and `fsck` have been routine since the install.

The mono screen with the colour board Off (the on-board bw2 alone) works
too: the PROM's console and mono SunView (Phase 4, 2026-10-05).

### Phase 4: colour (the cg4)

**Status (2026-10-04, Verilator only):** built (docs/cg4.md, "In the core").
The Rev 1.9 PROM finds the board, calls the machine a Sun-3/60C/G and draws
its console in the overlay plane, black on white. Its console draws at about
half the bw2's speed, because it writes the enable plane as well as the
overlay for every character (`tb_emu`'s plane counts: 2 s of console is
126k overlay and 111k enable writes against the bw2's 171k), not because of
the scan-out. Still to do: SunOS's `cgfour0`, the colour programs, and the
cost to the CPU under SunView in colour.

On the MiSTer (2026-10-04) the installed SunOS 4.1.1's GENERIC kernel
reports `cgfour0 at obmem 0xff300000 pri 4` (and the overlay as `bwtwo1`).

**Status (2026-10-05):** `sunview -8bit_color_only` runs on the colour plane,
up 7 s after the command, with the mouse and the root menu. `spheresdemo`
draws its shaded colour spheres in a shelltool. It showed one fault, now
fixed: after `clear`, the console's cursor stayed on the colour desktop as
a cyan block. The scan-out showed an overlay bit even where the enable
plane is 0, and SunView clears the enable plane but not the overlay. Now
the overlay counts only where the enable plane is 1 (docs/cg4.md, "The
picture, per pixel"; `tb_cg4_scanout` and `mutate_cg4_scanout.sh` check
it), and the core `Sun-3_20261005-cg4gate` shows no cyan, with colour and
mono SunView both working. A disassembly of SunOS's cgfour driver,
libpixrect and SunView's window driver confirmed the gate, and found that
U1 and patch 100192-02 change nothing here. It also found an interrupt
storm: the bw2's vertical blank latched level 4 whenever the cgfour driver
turned it on during the blank, with no colour map to load (7,013 level-4
interrupts for 500 colour-map updates). On a real 3/60, level 4 comes
through the DSACK PAL, which takes the on-board pulse only until the P4
board first interrupts. `sun3_vint.v` now models it, and `tb_vint` checks
it (docs/cg4.md, "The level-4 interrupt"). On the board (core
`Sun-3_20261005-vint`) the 500 updates now take 501 interrupts.

**Status (2026-10-05, afternoon):** the rest runs on the same core
(docs/cg4.md, "What runs on it"):
* **OpenWindows 2.0** in colour: `/usr/openwin/bin/openwin` brings up olwm,
  a cmdtool and filemgr in about 2 minutes. NeWS's and X's colour demos
  run, and olwm's *Exit* returns to the console.
* **Plain `sunview`**, both plane groups: mono windows in the overlay, a
  colour program's window in the colour plane.
* **Two desktops** (sunview(1)'s `-toggle_enable` and `adjacentscreens`),
  with `/dev/bwtwo1` for the overlay: the pointer switches between them both
  ways, and each exits cleanly.
* **The colour board Off** (OSD, then reset): the PROM's console and mono
  SunView on the bw2 alone.

**The colour scan-out costs the CPU nothing measurable** at 20 MHz. Same
disk, same day, by `time` through ttya:

| | colour board On | Off |
|---|---|---|
| Dhrystone 2.1, `cc -O`, 100,000 runs (`tools/sunos/dhry`) | 3,252 and 3,253/s | 3,243 and 3,250/s |
| `membench`, MB/s: write, read, `bcopy`, `bzero` | 6.45, 6.06, 3.28, 5.00 | 6.45, 6.06, 3.23, 5.00 |
| mono SunView, 2,000 lines of `/etc/termcap` in a shelltool | 26.3, 26.7, 27.2 s (overlay) | 27.1, 27.0 s (bw2) |
| mono SunView, 3,000 lines of `/usr/dict/words` | 16.0, 16.2 s | 15.8, 16.3 s |
| `dbench.sh`: raw read, 64 KB × 160 / 512 B × 512 | 8.0 / 2.9 s | 7.8 / 3.0 s |
| `dbench.sh`: `bzero` 10 MB, 300 forks of `expr` | 5.7 s, 83.0 s | 5.7 s, 83.8 s |
| `dbench.sh`: 10 MB file write and `sync` | 22.3 s (15.1 s sys) | 16.8 s (16.2 s sys) |
| `dbench.sh`: `tar` copy of `/usr/include`, its `rm` | 92.9 s, 38.9 s | 94.6 s, 39.1 s |
| the boot's rc scripts | 42 s | 40 s |

The file write's real time varies with the MiSTer's own write-out (its
system time is the same). Colour SunView (`-8bit_color_only`) scrolls the
same text in 71.1 and 75.2 s, and the words in 55.1 and 53.3 s, 3.4 times
mono: the cg4 has no raster-op hardware, and the CPU moves 8 bits a pixel
instead of 1.

One more thing showed: **300 forks of `expr` take 83 s**, against 65 s on
plain 4.1.1 (Phase 3, step 5), and the user time rose from 20 to 32 s. U1
or the later patches cost each command about 40 ms of user time; ld.so's
jumbo patch 101783-02, which runs at every exec, was the first suspect.

**It is the Y2K patch's shared libc** (measured 2026-10-05 at 20 MHz, 300
starts each, by `time` through ttya; everything under `/tmp`, nothing
installed):
* not ld.so: `expr` copies whose start-up names `/tmp/ld.old.so` (the
  pre-101783-02 one) and `/tmp/ld.new.so` take 81.8/81.9 and 82.1/82.4 s;
* not the shell: the pre-100344-01 `sh` runs the loop in 82.9/82.8 s, the
  current one in 82.8/83.0 s;
* the libc: with `LD_LIBRARY_PATH`, U1's `libc.so.0.15.2` takes 73.7/73.4 s
  (20.6/21.1 user), `y2kpatch-04`'s `0.15.3` 85.6/85.6 s (33.1/33.2 user).
  The same for an empty `main` (15.6 against 27.7 s user), so the cost is
  ~40 ms a start, in every dynamically linked command;
* it is not in libc's code once loaded (Dhrystone 3,250 and 3,246, `membench`
  identical), not in its start-up code (an empty `main` linked statically
  against the Y2K `libc.a`: 2.1 s user), not in lazy binding (`LD_BIND_NOW`
  changes nothing), and not in the system calls (`trace` shows the same 36).
  It is ld.so's work on that library at load;
* and it is the patch's objects, not how they were linked: libcs rebuilt
  from its `/usr/lib/shlib.etc/libc_pic.a` with the shlib.etc kit are as
  slow -- by the current `ld`, 85.5/85.2 s in the `expr` loop (32.3/32.1
  user); by the pre-100170-10 `ld`, 27.5/27.6 s user for the empty `main`.

What in the jumbo patch's objects makes the load 40 ms longer is not
known. A faster libc with the Y2K fixes would need U1's `libc_pic.a` (not
on the disk; perhaps on the U1 media) with only the patch's Y2K objects in
it. At 33.33 MHz the cost is 24 ms a command.

**Done (2026-10-05).** Every "Done when" below holds on the board. The
benches now also drive the cg4 as SunOS's kernel does (docs/cg4.md):
`tb_cg4` runs `p4probe`'s inverted-ID write, the mono driver's
`*p4 = 0x24`, FBIOSVIDEO, and the retrace handler's byte-wise load followed
by `P4 &= ~2`, and `tb_mister_sdram` writes every mix of byte selects into
each of the three planes, as libpixrect's `mem_rop` does. `mutate_cg4.sh`
and `mutate_sdram.sh` have a mutation for each new check, and catch them
all. Not modelled, harmless for SunOS: P4 bit 0 (first half of retrace),
the pending bit latching with its enable off, and the Bt458's blink and
command bit 6.

1. **Read the PROMs first.** Disassemble 1.9's and 3.0.1's frame-buffer
   search (the Sun-2's `tools/promdis` method). The source tree in
   `MelkhiorVintageComputing/sun3-bootrom` (SunOS 3.2's PROM, GPL-2.0) helps.
   Three things to find:
   * what each revision does with a P4 cg4 present, and with the on-board bw2
     present or absent;
   * which revision gives a colour console;
   * what Sun-3_FPGA's 3.0.1 screen fault was. It had no keyboard and no P4
     board.

   This settles whether "Colour board On" means a 3/60C without on-board mono
   (501-1322 + cg4) or with it.
2. `rtl/sun3/sun3_cg4.sv`:
   * P4 register: ID 0x41, video enable, sync, vertical retrace (it must
     really toggle), interrupt enable/pending at level 4;
   * Brooktree DACs: the address register, the colour map 256 x 24 auto-
     incrementing in R,G,B order, read mask, blink, control, and the overlay
     colours;
   * the three planes in SDRAM.
3. The scan-out composites per pixel: the enable plane picks between the
   overlay (through the overlay colours) and the colour plane (through the
   colour map). The colour map is updated during vertical retrace. The output
   goes into the same 1:1 video path.
4. References for the register-level behaviour:
   * NetBSD `sys/arch/sun3/dev/cg4.c`, `cg4reg.h`, `btreg.h`, `p4reg.h`;
   * SunOS libpixrect's cg4 code, if a source turns up;
   * the cg4 PAL fuse maps (sun3arc.org's `PALs/CG4/`).
5. Tests:
   * a register bench (P4, DACs, planes);
   * a scan-out bench comparing every pixel of a composited frame with a C
     model;
   * `tb_emu` to the PROM's colour console.

**Done when**:
* the PROM console is on the colour screen;
* SunOS shows `cgfour0 at obmem 0xff300000`;
* `suntools -8bit_color_only` runs, and so do OpenWindows (from the 4.1.1 set)
  and the SunView colour demos;
* the CPU is not starved: SunView redraw and a Dhrystone run with the colour
  scan-out on and off show the cost.

### Phase 5: Ethernet

**Status (2026-10-05):** in the core. `SUN3_ETH_WISH7990` builds the LANCE
(Wish7990, in `sun3_fpga.v` as Sun-3_FPGA has it), and its MII goes to
`rtl/sun3_mister_enet.sv`: Sun-2_MiSTer's mailbox with the magic
`S3ETH001`, on `clk_mii` and `clk_mem`, with the DDRAM port. The OSD has
*Network* at `[11:9]`; the MAC comes from the ID PROM's bytes 2..7 as Main
sends them. `tb_mister_enet` (the Sun-2's bench, between Wish7990's own
`mii_tx` and `mii_rx`, wired as `wish7990.sv` wires them) passes its 48
checks, and `mutate_enet.sh` catches all 22 mutations. In `tb_emu` the
mailbox is published 2.6 ms after the machine leaves reset, and the PROM
passes its self-test with the LANCE present: the banner comes at 1.62 s
against 1.04 s without it. A run without the LANCE has a fourth bus error
at 691 ms that this one lacks; the extra time is most likely the PROM
testing the part it now finds (not traced). The fit: 25,570 ALMs (61%,
1,795 more than without the network) and 321 RAM blocks, timing met (worst
setup slack +0.387 ns), `cpu_clk` on GCLK11 and `clk_mii` on G10.

**On the board (2026-10-05, core `Sun-3_20261005-eth`, Network eth0):**
SunOS attaches `le0 at obio 0x120000 pri 3` with the MiSTer-made Ethernet
address 8:0:20:2d:d0:a3, and `ifconfig le0 192.168.99.236 ... up` puts it on
the LAN (the address the Sun-2 uses with the same MAC; the two cores never
run at once). From a PC on the LAN:
* ping at 56, 512, 1472, 1473, 4000, 8192 and 16,000 bytes, 20 each: 0%
  loss (16,000 bytes, eleven fragments each way, in 52 ms); the Sun pings
  the gateway;
* telnet in as root: a login in 2.5 s, and `/vmunix` (1,249,789 bytes)
  uuencoded out over it, decoded on the PC: the same MD5 as the disk's copy;
* inetd's TCP echo: 4 MB of random bytes in and back out, equal, at 187 KB/s
  each way at once; `discard` takes 315 KB/s in;
* after about 30,000 packets each way, `le0` has 0 input and 0 output errors
  and 0 collisions; IP took 440 fragments and dropped none; TCP
  retransmitted one segment, with no retransmit timeouts.

* FTP: SunOS's `ftpd` refuses accounts with no password, and root has
  none. With the owner's leave, the disk was copied, a temporary user given
  a password, 2 MB and 8 MB put and fetched back with equal MD5s (267 KB/s
  in, 289-307 KB/s out), and the disk then restored from the copy;
* `le0` now comes up at boot: `/etc/hostname.le0` (was `hostname.xx0`),
  `sun3` at 192.168.99.236 in `/etc/hosts`, and in `/etc/rc.local` the
  broadcast address 192.168.99.255 (SunOS 4's `broadcast +` picks the old
  all-zeros .0) and the default route via 192.168.99.1; each changed file
  kept as `<file>.pre-le0`. After a reboot the Sun answers pings and
  reaches 8.8.8.8 with nothing typed.

Not done: NFS (left out by the owner's choice: no server on the LAN), and
telnet and FTP out of the Sun (they need servers on the LAN). Typing data
in through a telnet session overruns the pty's input queue (the tty
answers with BEL and drops the excess), so bulk data in goes over TCP, not
a terminal.

1. Wish7990 behind the DVMA path Sun-3_FPGA already arbitrates (Ethernet
   before SCSI).
2. `sun3_mister_enet.sv`: the Sun-2's mailbox with magic `S3ETH001`, a TX ring
   of 8, an RX ring of 16, published when the machine leaves reset.
3. **Main_MiSTer `sun-family`**: done in `55fe6c8` (pushed and installed on
   the board, 2026-10-04). `support/sun/` has a model enum (`SUN_2`,
   `SUN_3`, `SUN_SPARCSTATION`), with one `switch` per behaviour:
   * the Network bits (`[11:9]`);
   * the ID PROM's machine type (0x17);
   * the disks whose writes are buffered (slots 0-1);
   * the CD slot (none: slot 2 is the tape).

   `S3ETH001` names a 16-slot RX ring. Build from a `git archive` copy in
   WSL, never in the checkout.
4. Tests: the Sun-2's enet bench and mutation script, with the new magic.

**Done when**:
* pings of 56 to 16,000 bytes get 0% loss;
* telnet and FTP work both ways, with sums equal;
* NFS mounts a host directory;
* `le0` reports no errors under load.

### Phase 6: speed

**Status (2026-10-05): steps 1 to 3 done, on the MiSTer** (core
`_Unstable/Sun-3_20261005-clk.rbf`):

* The OSD's *CPU clock* (`O[14:13]`: 20, 25, 33 MHz) rewrites the main PLL's
  C1 through `sys/pll_cfg` (`rtl/sun3_mister_cpuclk.sv`, see *Clocks*),
  in a machine reset, which it holds for 1.3 ms after the change. The
  bitstream's C1 is /25, so a core left at 20 MHz never reconfigures. A
  change made while SunOS runs takes effect at the next Reset; a setting
  saved with the OSD's *Save settings* is made as the core starts, before
  the PROM has arrived. Both were done on the board.
* The TOD chip counts a fixed 1 MHz from `clk_mem`
  (`rtl/sun3_mister_tick.sv`); at 25 and 33.33 MHz the Sun's clock kept to
  the PC's to the second (a 25 s Dhrystone run is 25 s by both).
* Benches: `tb_mister_cpuclk` (55 checks: the switch against
  `pll_stub.sv`'s PLL and a model of `pll_cfg`'s Avalon behaviour) and
  `mutate_cpuclk.sh` (18 of 18 caught); `tb_mister_tod` now changes the
  CPU's clock under the chip (22 checks; `mutate_tod.sh` 16 of 16).
  `tb_emu` at 33.33 MHz (`+status=4000`) runs the PROM 1.64 times as fast.
* The fit, with `Sun-3.sdc` timing `cpu_clk` at 30 ns: 26,663 ALMs (64%,
  1,093 more than Phase 5), every corner met, `cpu_clk` setup slack
  +2.162 ns, hold +0.273 ns, slow-corner Fmax 38.95 MHz, on GCLK11. The fit
  that only had to make 20 MHz had reached 29.4 MHz: its 400 worst paths
  were all one half-cycle path in the RD68021, from the bus unit's
  falling-edge `early_q` into the fetch unit (16.6 ns of a 25 ns half
  clock). Asked for 33.33 MHz, the fitter made it without any RTL change;
  the worst paths are then half-cycle ones into the bus unit's data latch
  (`d_latched`), from the MMU's page map RAM, 11.4 ns of a 15 ns half clock.

Measured on the board, same disk (`sd0-1g.img`), by `time` through ttya:

| | 20 MHz | 25 MHz | 33.33 MHz |
|---|---|---|---|
| Dhrystone 2.1, 100,000 runs (`tools/sunos/dhry`) | 3,248, 3,250/s | 4,076/s | 5,439, 5,454/s |
| `membench`, MB/s: write, read, `bcopy`, `bzero` | 6.45, 6.06, 3.28, 5.00 | 8.33, 7.41, 4.08, 6.25 | 11.11, 9.52, 5.26, 8.33 |
| `dbench.sh`: raw read, 64 KB × 160 / 512 B × 512 | 8.4 / 2.9 s | 7.5 / 2.4 s | 7.0 / 1.9 s |
| `dbench.sh`: `bzero` 10 MB | 5.7 s | 4.7 s | 3.4 s |
| `dbench.sh`: 300 forks of `expr` (user) | 83.0 s (32.7) | 66.8 s (26.1) | 51.0 s (19.9) |
| `dbench.sh`: 10 MB file write and `sync` (sys) | 16.6 s (15.9) | 15.0 s (12.3) | 22.1 s (8.4) |
| `dbench.sh`: `tar` copy of `/usr/include`, its `rm` | 92.8 s, 39.6 s | 78.6 s, 33.1 s | 65.6 s, 26.9 s |
| the boot's rc scripts | 43 s | 35 s | 30 s |
| the 68881 program (Phase 3), `user` | 156.0 s | | 93.0 s, the same digits |
| mono SunView, 2,000 lines of termcap / 3,000 words | 27 / 16 s (Phase 4) | | 16.5 / 10.0 s |
| ping of 16,000 bytes, round trip | 52 ms (Phase 5) | | 43 ms |

Dhrystone and the 68881 scale with the clock exactly (1.67 times at
33.33 MHz); memory bandwidth almost (1.47 to 1.67). The raw disk read is
the HPS's, not the CPU's. The file write's real time is the MiSTer's own
write-out (its system time falls with the clock). At 33.33 MHz, 20 pings
of each size from 56 to 16,000 bytes lost none, 4 MB through inetd's TCP
echo came back equal, `le0` had no errors, and `fsck -n` of `/` and `/usr`
was clean after the runs. Not measured: whether the PLL's lock ever drops
during a change (M and N never change, so it should not; if it did, the
whole core would reset and come up again).

1. The CPU clock from the OSD: 20 / 25 / 33.33 MHz by reconfiguring the
   main PLL's `cpu_clk` counter (C1, /25 /20 /15 of 500 MHz), applied in
   reset. **Done.**
2. Close timing at the highest choice offered. The RD68021 alone is 39.9 MHz
   on a Cyclone V. With the FPU, Sun-3_FPGA's critical paths were the
   bus-to-fetch and bus-to-FPU handovers. Offer only what closes. **Done:
   33.33 MHz closes with 2.2 ns to spare.**
3. Measure at each setting. **Done** (above), with Dhrystone 2.1 rather
   than 1.1, and without Whetstone.
4. Possibly a larger read cache. A 32 KiB cache gained little on the Artix.
   Not done.

### Phase 7: release

1. User documentation in README:
   * PROM preparation;
   * building tapes and installing;
   * the OSD;
   * the keyboard map;
   * the network;
   * the clock.
2. MGLs. A release RBF in `releases/`.
3. NetBSD/sun3: install from a miniroot written to the swap partition, or
   from a tape image. Not by netboot.

### Phase 8: later

* **GX (cg6)** on P4: an accelerated 8-bit frame buffer whose console needs
  PROM 3.0+. Like the Sun-2's cgtwo, its FBC/TEC engine has to be specified
  from the software that drives it, before any RTL:
  * a spec and C model checked against SunOS 4.1.1's cg6 pixrect;
  * then a model against X11's `Xsun` cg6 code.
* A **CD-ROM target** (sr0, ID 6) through Main's `sun_cdrom`. SunOS 4.1.1 for
  sun3 did ship on CD.
* **1600x1280 hi-res bw2** (the J800 jumper), scaled to 1080p.
* A **sun3x core** (3/80) would be a separate project. AP68030 is the
  candidate CPU (GPL, 68030 + MMU, 50 MHz, 17k ALMs; not OS-tested yet). Its
  tests would be MacIIvi_MiSTer's `SingleStepTests`, CPU + PMMU, hardware-
  verified on a Mac IIcx. MH030 is too slow for now (about a 7 MHz bus). The
  Macs' TG68K is excluded.

## Budget (DE10-Nano, 41,910 ALMs)

| | estimate |
|---|---|
| RD68021 (coprocessor interface) | 7.9k ALMs, 21 M10K, standalone 39.9 MHz (its README) |
| RD68884 | ~3-4k ALMs, ~20+ M10K (Artix: 3.9k LUTs, 19 RAMB36) |
| the rest of the machine (MMU maps, SCC x2, 5380 + UDC, LANCE, bridges, cache) | ~12-16k ALMs (DECA: the whole machine without FPU was 40.9k LE) |
| boot PROM 64 KiB | 52 M10K |
| `sys/` framework (ascal, OSD, hps_io) | ~6-8k ALMs |
| cg4 + its scan-out | ~1.5-2.5k ALMs |
| **total** | **~31-38k ALMs (75-90%)** |

It should fit, but not with room to spare. The levers, in order:
1. the debug ladders;
2. MLAB to M10K moves;
3. `fault_log` and `bus_trace` out of the release build;
4. the RD68021 instruction cache in M10K, if Quartus builds it in flip-flops,
   as it did on the MAX 10.

## Risks

* **Disk speed.** The install took 2¼ hours. Phase 3, step 5 packed the
  SCSI DMA; what is left is the kernel's CPU time (Phase 6).

* **Area.** See the budget. Measure after Phase 1, again with the FPU in
  Phase 3, and keep 10% for the cg4 and the network.
* **Timing with the FPU** closes at 33.33 MHz (Phase 6: +2.16 ns, Fmax
  38.95 MHz at the slow corner). What limits it there is half-cycle paths
  into the RD68021 bus unit's data latch (`d_latched`), from the MMU's page
  map RAM and the bus unit's own `cyc_addr`: 11.4 ns of a 15 ns half clock.
  Anything faster would start there.
* **The PROM and the cg4.** See Phase 4, step 1. If 1.9 cannot put its
  console on a cg4, the colour console needs 3.0.1, and 3.0.1's screen
  fault must be understood first.
* **SDRAM bandwidth** with the colour scan-out. The fallback is DDR3 for the
  colour plane.
* **A MiSTer shared with other cores** may be running one of them, with an
  OS on a disk image. Check `/tmp/CORENAME` before loading a core or
  installing a Main binary, and shut down what runs first.
