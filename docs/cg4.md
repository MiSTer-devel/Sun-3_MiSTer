# The cg4 (Phase 4): what the software needs

The P4 colour board of a 3/60C (501-1210) is "cg4 type B": a dumb frame
buffer of three planes with Brooktree Bt458 DACs, and no raster-op hardware.
Everything here is read from the software that drives it:

* the 3/60's Rev 1.9 PROM, disassembled (`build/rom/sun3_60_v1.9.lst` from
  `m68k-linux-gnu-objdump -D -b binary -m m68k:68020
  --adjust-vma=0x0fef0000`);
* NetBSD's `sys/arch/sun3/dev/cg4.c`, `cg4reg.h`, `btreg.h` and `p4reg.h`.

Each fact names its source. SunOS 4.1.1's `cgfour` driver is still to be
checked against this: Phase 4, step 1.

## The address map (OBMEM)

| physical | size | what |
|---|---|---|
| 0xFF200000 | 16 bytes | Bt458 registers: `bt_addr`, `bt_cmap`, `bt_ctrl`, `bt_omap` at +0, +4, +8, +12 (btreg.h; cg4reg.h `CG4B_OFF_CMAP` = P4 − 1 MiB) |
| 0xFF300000 | 4 bytes | the P4 register (p4reg.h; the PROM maps it at VA 0x0FE7C000) |
| 0xFF400000 | 128 KiB | overlay plane, 1 bit a pixel (`CG4B_OFF_OVERLAY`, `CG4_OVERLAY_SIZE`) |
| 0xFF600000 | 128 KiB | enable plane, 1 bit a pixel (`CG4B_OFF_ENABLE`) |
| 0xFF800000 | 1 MiB | colour plane, a byte a pixel (`CG4B_OFF_PIXMAP`, `CG4_PIXMAP_SIZE`) |

The 1-bit planes have the bw2's layout: 1152 pixels a line, 144 bytes, the
most significant bit leftmost. The colour plane is 1152 bytes a line.

## The P4 register

Read: bits 30:24 are the type. `0x41` is the cg4's ID `0x40` with size `1`,
1152x900 (p4reg.h: `P4_ID_COLOR8P1`, `P4_SIZE_1152X900`). The low byte holds
status and control (p4reg.h):

| bit | read | write |
|---|---|---|
| 0x80 | diag | |
| 0x40 | | readback clear |
| 0x20 | video on | video on |
| 0x10 | sync | |
| 0x08 | vertical retrace | |
| 0x04 | interrupt pending | interrupt clear |
| 0x02 | interrupt enable | interrupt enable |
| 0x01 | first half | reset |

The PROM ORs in 0x20 to turn the video on (0xFEF6CE8).

## The level-4 interrupt

The P4 board's interrupt and the on-board video's share level 4, through a
PAL that chooses between them. On the 3/60 (501-1205 Rev 13; the PALs read
from a 501-1205-03 board) the interrupt PAL, INTERRUPT U307 (sheet 3, fuse
map 1581-01), latches its input `V.INT-` while the interrupt register's
level-4 enable is set, until software clears it; `sun3_irq_priority.v`
transcribes that. `V.INT-` is an output of the DSACK PAL, U805 (sheet 8A,
fuse map 1590-01), from:
* `V.INTX-`, the on-board video's interrupt (VIDEO4 U1004, sheet 10, fuse
  map 1588-01): one video clock as the line counter wraps, at the start of
  vertical blanking. It is not gated by the video enable;
* `V.INTY-`, the P4 connector's interrupt pin (P1/P2 pin 54, sheet 12,
  pulled up), which goes nowhere else;
* `INIT-`, the board reset.

Its equations make `V.INT-` follow the on-board pulse until the P4 board
first interrupts, and the P4 board alone from then until a reset. The P4
connector carries no video timing; the board makes its own.

SunOS depends on that choice. Its cgfour driver turns level 4 on at any
point in the frame (P4 `|= 6`, then the level-4 enable), and its handler
loads a colour map only if the P4 pending bit is set. The core first ORed
the bw2's whole vertical blank into level 4. On the MiSTer (2026-10-05), a
colour-map update made during the blank then latched level 4 with nothing
pending, and the CPU took the interrupt again and again until the next
retrace: 7,013 level-4 interrupts for 500 updates. `sun3_vint.v` now
models U805, and `tb_vint` runs the driver's sequence through it, the
interrupt PAL and the P4 register. On the board the same 500 updates now
take 501 level-4 interrupts.

Unmodelled, harmless for SunOS: per `p4reg.h`, the P4 pending bit may latch
at every retrace even with its enable off (SunOS clears and enables in one
write either way).

## What Rev 1.9 does with it

At 0xFEF6612 the PROM reads the EEPROM's console byte (offset 0x1F).
* `0x00` (bw2), `0x10` and `0x11` (ttya/ttyb): it checks for a colour board,
  then uses the on-board bw2.
* Any other value: it calls the display probe at 0xFEF69F4 with that byte.

The probe maps the P4 register and switches on its argument:
* **`0x20`, a P4 board**: the probe reads the P4 ID byte. A bus error, or an
  ID it does not know, means no board. Otherwise it switches on the ID:
  * `0x00`: a P4 bw2 at 1600x1280;
  * `0x01`: a P4 bw2 at 1152x900;
  * `0x05`: a 640x480 bw2;
  * **`0x41`: the cg4** (0xFEF6C04).
* `0x12` (`EED_CONS_COLOR`): the 3/110's on-board cg4, which has no P4
  register.

For `0x41` the PROM:
1. maps the DACs (VA 0x0FE0E000) and initialises them (0xFEF6CF0):
   * control registers 4..7 = read mask 0xFF, blink mask 0x00, command 0x73,
     test 0x00, each a byte written to `bt_ctrl` after its address;
   * then address 0 and twelve bytes into `bt_omap`: the four overlay colours
     yellow, white, cyan, black;
2. maps the colour plane (VA 0x0FD00000, 128 pages) and clears it, a
   longword at a time;
3. maps the enable plane (VA 0x0FEA0000) and fills it with ones;
4. maps the overlay plane (VA 0x0FE80000), clears it, and makes it the
   console's frame buffer;
5. turns the P4 video on and returns frame buffer type 8, `FBTYPE_SUN4COLOR`.

So **the console lives in the overlay plane**, with the enable plane showing
the overlay everywhere. **"Colour board On" sets the EEPROM's console byte to
0x20** and fits a cg4 that answers at 0xFF200000-0xFF8FFFFF.

## The Bt458 as the 3/60 wires it

* Each register is a longword. On a 3/60 the chip takes the **low byte**
  (cg4.c: "the 3/60 uses the low byte"). The 68020 copies a byte it writes onto
  every lane, so the PROM's byte writes land there too.
* **The colour map takes a longword as four bytes in a row**, most significant
  first (cg4.c: "Sun3/60 wants 32-bit access, packed"). It loads 256 x 3
  components with 192 longword writes to `bt_cmap` after `bt_addr = 0`, and
  reads them back the same way.
* As on any Bt458:
  * the address auto-increments after each blue;
  * control registers 4..7 are read mask, blink mask, command and test;
  * overlay colours 0..3 are written through `bt_omap`;
  * command bit 6 enables the palette, and bits 1:0 enable the overlay inputs
    OL1 and OL0 (NetBSD writes 0x43, the PROM 0x73).

## The picture, per pixel

The overlay input is `OL = {overlay plane bit AND enable plane bit, enable
plane bit}`, each gated by its command-register enable.
* If `OL` is not 0, the pixel is overlay colour `OL`.
* Otherwise it is colour-map entry `(colour byte & read mask)`.

So where the enable plane is 0 the colour plane shows, whatever the overlay
holds: the enable plane chooses between the overlay and the colour plane, as
cgfour(4S) says. Overlay colours 0 and 2 are never shown. The PROM loads
them with yellow and cyan, and SunOS leaves them that way.

The PROM's overlay colours fix which bit is which:
* the console background is enable = 1, overlay = 0, and must be **white**,
  which is entry 1;
* its text is enable = 1, overlay = 1, **black**, entry 3.

With the planes the other way round the screen would be cyan.

The first model fed the overlay bit to the Bt458 ungated, so an overlay bit
under a 0 in the enable plane showed as entry 2, cyan. On the MiSTer
(2026-10-05), `sunview -8bit_color_only` clears the enable plane and leaves
the overlay as the console left it, and the console's cursor showed as a
cyan block on the colour desktop. That model would also break SunView's two
desktops on one screen (sunview(1), `-toggle_enable`: one desktop in the
overlay, one in colour, the enable plane showing one at a time), because the
hidden overlay desktop would show through the colour one. SunOS's own code
(next section) relies on the gate in the same way. The board's PAL fuse
maps (sun3arc.org's `PALs/CG4/`, docs/references/README.md) have no pin names to confirm it
with directly.

## What SunOS 4.1.1 does with it

From a disassembly (2026-10-05) of the kernel's `cgfour.o` (cgfour.c 1.28),
libpixrect's cg4 members, libsunwindow, and the kernel's window driver
`windt.o`. The 4.1.1, U1 and patch 100192-02 copies of `windt.o` have the
same plane and cursor code. The listings were made with
`tools/sunos/aoutdis.py`.

* **Probe.** The driver tries type A's colour map (OBIO 0x0E0000) first;
  it must bus-error. Then it tries type B at 0xFF200000. `p4probe` writes
  the P4 register back with bits 30:24 inverted and bit 0 cleared, and
  requires the ID to read back unchanged.
* **Attach.** Bt458 registers 4..7 get 0xFF, 0x00, 0x73, 0x00, and the four
  overlay colours yellow, white, cyan, black: the PROM's values. Attach
  writes no plane and no P4 bit.
* **Colour maps.** Changes go to soft copies and are loaded in the
  level-4 retrace interrupt:
  * the ioctl writes P4 `|= 6` (clear pending, enable), then sets the
    interrupt register's level-4 enable;
  * the poll routine loads only if P4 bit 2 reads 1, then writes
    `&= ~2` (bit 2 written back as 1, clearing it) and clears the level-4
    enable.

  The load (`cgfourintr_b`) is all byte writes: the address register 1 and
  overlay entry 1's three components, address 3 and entry 3's, then the
  address rounded down to a multiple of four entries and the colour map's
  components, whole groups of four entries. Every P4 access in the driver
  is a longword (`or.l`, `and.l`, `move.l`).

  The overlay group's map has two entries: pixrect colour 0 goes to Bt458
  overlay entry 1, and colour 1 to entry 3. Entries 0 and 2 are written only
  at attach. The DACs are never read back.
* **Video on and off.** FBIOSVIDEO writes `(*p4 & ~0x24) | v` (v 0x20 or
  0), which leaves a pending interrupt pending; FBIOGVIDEO tests bit 5. The
  mono driver, `bwtwo.o`, which drives the overlay as `bwtwo1`, writes
  `*p4 = 0x24` outright: video on, the interrupt cleared and disabled.
* **mmap**: overlay at 0, enable at 0x20000, colour at 0x40000, 0x13E000 in
  all.
* **The enable plane decides what shows**; nothing hides the overlay any
  other way:
  * on the first mmap by a program that asked FBIOGATTR, as every pixrect
    program does, the kernel fills the enable plane with 0 and leaves the
    overlay as it was;
  * `sunview -8bit_color_only` keeps only the colour plane group and fills
    the enable plane with 0 (`dtop_set_enable`). Nothing clears the overlay,
    so the console's text and cursor stay in it for the whole session;
  * ordinary SunView sets the enable plane to 0 under each colour window,
    and clears the overlay there only in a "full" variant that the common
    call doesn't use;
  * `-toggle_enable` switches between desktops by rewriting the enable plane
    alone;
  * SunView's software pointer edits the enable plane under itself only
    during a grab, and never touches the overlay.
* **At exit** SunView clears the overlay and colour planes and fills the
  enable plane with 1, which brings the console back.

The P4 register's bit 0 reads as "first half of vertical retrace" and bit 4
is a RAMDAC sync strobe (`p4reg.h`). SunOS reads neither; in the core bit 0
reads 0 and bit 4 reads 1. The core doesn't model the Bt458's blink or
command bit 6; SunOS writes blink 0 and command 0x73.

## What runs on it

On the MiSTer (2026-10-05, core `Sun-3_20261005-vint`, SunOS 4.1.1_U1 with
the later patches):

* **The PROM console** in the overlay. With the OSD's *Colour board* Off the
  banner says `Model Sun-3/60M`, the console is the bw2's, and SunOS finds
  `bwtwo0` alone.
* **SunView**, in each way sunview(1) offers on a cg4:
  * `-8bit_color_only` (the colour plane) and `-overlay_only` (the overlay);
  * plain `sunview`: the desktop and text windows in the overlay. A colour
    program (`spheresdemo` in a shelltool) moves its window to the colour
    plane, with the enable plane cleared under it, while the rest stays
    mono;
  * two desktops: `sunview -8bit_color_only -toggle_enable`, then, in its
    shelltool, `sunview -d /dev/bwtwo1 -toggle_enable -s file &` and
    `adjacentscreens -c /dev/fb -l /dev/bwtwo1`. The pointer leaving the
    colour desktop's left edge brings up the overlay desktop, whole, and
    the keys follow it; leaving that one's right edge brings the colour
    one back. Exiting the overlay desktop hands the screen back to the
    colour one. sunview(1) names `/dev/bwtwo0`, which is the overlay on a
    3/110; on a 3/60C `bwtwo0` is the on-board bw2 and the overlay is
    `bwtwo1`, which MAKEDEV doesn't make (`mknod /dev/bwtwo1 c 27 1`).
* **OpenWindows 2.0** (xnews with patch 100176-15): `/usr/openwin/bin/openwin`
  shows xnews's splash after 40 s and olwm, a console cmdtool and filemgr
  after about 2 minutes. xnews has a cg4 driver of its own (`cg4Ras.c`):
  the screen is one 8-bit PseudoColor visual (`xdpyinfo` lists PseudoColor,
  StaticColor, GrayScale and StaticGray, all depth 8), and the pointer is
  drawn in the overlay with the enable plane as its mask. NeWS's colour
  wheel (36 hues) and Escher's fish, and X's `ico` and `plaid`, run.
  olwm's *Exit* returns to the console. The last pointer image stays in the
  overlay until the console clears or scrolls it away: xnews leaves the
  overlay as it was.

## Bandwidth

The scan-out reads, per 1152-pixel line:
* 1152 bytes of colour;
* 144 bytes each of overlay and enable;

90 bursts of 16 bytes in all, 1,440 bytes. At 60.4 Hz that is 78 MB/s, from
an SDRAM that delivers on the order of 110-120 MB/s in BL8 bursts at 100 MHz.
The bw2 alone reads 8 MB/s.

**Measured on the board (2026-10-05, CPU at 20 MHz): it costs the CPU
nothing.** With the colour board On and Off, Dhrystone, `membench`, mono
SunView's scrolling and `dbench.sh` give the same figures within 3%
(design-plan Phase 4 has the table). From user space the CPU streams about
6 MB/s, far below what the SDRAM has left. Measure again at the Phase 6
clocks.

## In the core

* **The OSD's "Colour board"** (`status[12]`, On by default) fits the board
  while the machine is in reset, as a board would be fitted. With it:
  * `sun3_fpga.v` answers the address map above; without it those addresses
    time out, which is how the PROM and SunOS find no board;
  * the EEPROM's console byte is made 0x20 at every reset (0x00 without the
    board), unless it names a serial port;
  * the screen is the cg4's, and the bw2's memory is not fetched.
* **`rtl/sun3/sun3_cg4.sv`**: the P4 register and the Bt458s, on the CPU's
  clock. The colour map is two block RAMs written together, one read back by
  the CPU and one read by the scan-out on the pixel clock.
* **The planes** are in the SDRAM above the bw2 (`rtl/sun3_mister_sdram.sv`):
  colour at 25 MiB, overlay at 26 MiB, enable 128 KiB after it. The bridge
  takes them uncached as `MATCH_CG` and puts them at Wishbone word
  `{6'h3F, PA[25:2]}`.
* **`rtl/sun3/sun3_cg4_scanout.sv`** fetches lines into a ring of four, up to
  three ahead of the screen. It takes turns with the CPU for the SDRAM, and
  demands it (`cs_urgent`) only when the next line to be shown is not yet
  complete. Its pixels are four clocks behind the raster's position, so
  `Sun-3.sv` delays the syncs and DE to match while it is shown.
* **Tests**: `tb_cg4` (the registers, as the PROM, NetBSD and SunOS drive
  them: SunOS's probe, its two drivers' P4 writes and its retrace handler's
  byte-wise load), `tb_cg4_scanout` (every pixel of full frames against a
  model, with the memory quick and slow), the cg4 window (every mix of byte
  selects in each plane, as libpixrect writes them) and port in
  `tb_mister_sdram`; a mutation script for each.
