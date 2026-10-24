# The GX (cg6) on the P4: what the software needs

The GX ("lego", `cgsix`) is Sun's accelerated 8-bit colour frame buffer.
On a 3/60 it is a P4 board, in the slot the cg4 uses. This is the spec for
building one into the core (Phase 8). It is specified from the software that
drives it, before any RTL, as the Sun-2's cgtwo was:
* this document;
* a C model of the board, `tools/cg6model/`, checked by running Sun's own
  libpixrect cg6 code against it (*The C model*, below).

Each fact names its source. **Verified** means read from Sun's code or
headers, or checked by running Sun's code against the model. **Inferred**
means the model needed it and nothing contradicts it, but no document or
board says so.

## The sources

* **The 3/60's Rev 3.0.1 PROM**, disassembled: its GX console,
  0xFEF6070-0xFEF6F3C.
* **SunOS 4.1.3 for SPARC**, read from the owner's installed disk image
  (`sunos413.7z`, a MAME CHD; `chdman extracthd`, then
  `../NewSunSparcStation20_MiSTer/tools/ufsread.py`, slice 6 = `/usr`).
  * `/usr/include/sundev/cg6reg.h` 1.11 91/06/28: the board's map, for
    sparc **and for the 68020**.
  * `/usr/share/man/man4/cgsix.4s`.
  * libpixrect's cg6 members (`/usr/lib/libpixrect.a`). These are what the
    model was checked against.
  * The sun4c kernel's `cgsix.o` (cgsix.c 1.38 93/06/02).
  * OpenWindows 3's `xnews`, which is unstripped (`cg6Ras.o` and others).

* **SunOS 4.1.1 for sun3, found since** (2026-10-23): the distribution tape
  on the board, `games/Sun-3/sunos-4.1.1-sun3.qic`, unpacked to
  `build/dist/sunos-4.1.1-sun3/usr/` (git-ignored). Its
  `incl/sundev/cg6reg.h` gives `CG6_P4BASE 0xFF000000` for the 68020 and the
  offsets above (CMAP +0x200000, FHC +0x300000, THC +0x301000, ROM
  +0x380000, FBC +0x700000, TEC +0x701000, colour +0x800000), confirming the
  map. It also has the 68020 `lib/libpixrect.a`, the sun3 kernel's
  `sys/sun3/OBJ/cgsix.o` and `cg6_colormap.o`, the `pixrect/cg6*.h`
  headers, sundiag's `cg6test`, and OpenWindows 2.0 (`openwin/bin/xnews`).
  Its cg6 members carry the same SCCS ids as 4.1.3's, member for member
  (cg6.c 1.11 90/07/27 ... cg6_stencil.c 1.9 89/12/15; **verified**), and
  the harness runs it on a 68020 (*The C model*, *The 68020 run*). Only
  mem_rop.c (4.27 89/07/26 here, 4.28 91/05/09 in 4.1.3) and
  pr_polypoint.c (1.17, 1.18) differ among the members the harness links.

  Before that, SunOS 4.1.1 for sun3 was not on this machine, so
  the 68020 libpixrect and the sun3 `cgsix.o` were not available. The
  4.1.3 library's cg6 members carry SCCS dates of 1988-90. The newest is
  cg6.c 1.11 90/07/27, and 4.1.1 was released in late 1990, so they are very
  probably the 4.1.1 sources compiled for SPARC (**inferred**; since
  verified, above).
* **Solaris 9's** `<sys/cg6fbc.h>`, `<sys/cg6tec.h>`, `<sys/cg6thc.h>`
  (`~/sol9-toolchain/sysroot`): Sun's register names and bit fields.
* **NetBSD** `sys/dev/sun/cgsix.c` and `cgsixreg.h`. Its own comment says
  its rasterop field names are guesses.
* **X.Org's** `hw/sun/sunGX.c` (Keith Packard's GX code for Xsun; NetBSD's
  xsrc mirror).
* **MAME** `src/devices/bus/sbus/cgsix.cpp`, the SBus TurboGX. Its draw and
  blit code says "basically untested, and probably full of bugs", and the
  model disagrees with it in three places (*MAME*, below).

## The address map

The board decodes a 16 MiB window. On a 3/60 the window is OBMEM
0xFF000000, and the P4 register's place, base + 0x300000, is the FHC.

| physical | size | what | evidence |
|---|---|---|---|
| 0xFF000000 | | the window's base | cg6reg.h: `CG6_P4BASE 0xFF000000` when not sparc. cgsix(4S): "`device cgsix0 at obmem ? csr 0xff000000 priority 4` ... for Sun-3/60 systems". NetBSD sun3 GENERIC: `# cgsix0 at obmem0 addr 0xff000000` |
| 0xFF200000 | 16 B | Bt458 DAC: address, colour map, control, overlay map at +0, +4, +8, +0xC | cg6reg.h `CG6_ADDR_CMAP`, `struct cg6_cmap`. PROM PTE 0xD007F900 (OBMEM page 0x7F900) at VA 0x0FE24000 |
| 0xFF240000 | 8 KiB | DHC | cg6reg.h `CG6_ADDR_DHC`. Nothing here touches it |
| 0xFF280000 | 8 KiB | ALT | cg6reg.h `CG6_ADDR_ALT`. Nothing here touches it |
| 0xFF300000 | 4 B | FHC: configuration, and the **P4 ID in bits 31:24** | cg6reg.h `CG6_ADDR_FHC = CG6_ADDR_P4REG = 0x300000`. PROM PTE 0xD007F980 at VA 0x0FE22000 |
| 0xFF301000 | 4 KiB | THC: video timing, misc (vsync, interrupt), cursor | cg6reg.h `CG6_ADDR_THC`. The PROM writes it at VA 0x0FE23800.. |
| 0xFF380000 | 64 KiB | the board's ROM | cg6reg.h: `CG6_ADDR_ROM 0x380000` unless sun4c. PROM PTEs 0xD007F9C0.. (8 pages) at VA 0x0FE30000 |
| 0xFF700000 | 4 KiB | FBC: the drawing engine | cg6reg.h `CG6_ADDR_FBC`. PROM PTE 0xD007FB80 at VA 0x0FE20000 |
| 0xFF701000 | 4 KiB | TEC: the transform engine | cg6reg.h `CG6_ADDR_TEC`. The PROM writes VA 0x0FE21000..8 |
| 0xFF800000 | 1 MiB | the frame buffer, a byte a pixel, 1152 a line | cg6reg.h `CG6_ADDR_COLOR`, `CG6_FB_SZ (1024*1024)` |

cg6reg.h also names 0x400000 ("overlay, FAKE") and 0x600000 ("enable").
Those are the cg4's planes; nothing in the GX code uses them.

All of these are **verified** (the header, and the PROM's page table entries:
valid, writable, no-cache, type 0). The PTEs come from the PROM's table at
0xFEFD678, which 0xFEF5874 loads. The PROM touches no other address of the
board.

The bw2 sits at 0xFF000000 too, but the GX decodes nothing below 0x200000.
The two coexist, as on a real 3/60.

## The P4 ID and the FHC

The P4 register's byte, FHC bits 31:24, reads **0x60** on a GX at 1152x900.
* PROM 3.0.1 at 0xFEF2552 sends `(id & 0xF8) == 0x60` to 0xFEF6070, which
  switches on `id - 0x60`:
  * 0x60, 0x61, 0x64: 1152x900, FHC 0x10BBB;
  * 0x62: 1600x1280, FHC 0x11BBB;
  * 0x63: 1280x1024, FHC 0x113BB;
  * 0x65: 1152x870;
  * 0x66: 1024x768;
  * 0x67: 640x480;
  * 0x6C: 1024x1024.
* MAME's `FBC_CONFIG_FBID 0x60000000` and Solaris's `FHC_CONFIG_FBID_SHIFT 24`
  agree.
* The core answers 0x60 (**verified**: the PROM's 1152x900 case).

FHC (Solaris `cg6fbc.h`, NetBSD `cgsixreg.h`):

| bits | read | write |
|---|---|---|
| 31:24 | ID 0x60 | ignored |
| 23:20 | revision | ignored |
| 19 / 18 / 17 / 16 | fast-rop / row / source / destination cache disable | stored |
| 15 | | reset |
| 13 | | little-endian |
| 12:11 | resolution: 0 1024, 1 1152, 2 1280, 3 1600 | stored |
| 10:9 | CPU: 0 SPARC, 1 68020, 2 386 | stored |
| 8, 7:4, 3:0 | test window enable, X, Y | stored |

The PROM writes 0x10BBB: destination cache off, 1152, 68020, test window
11x11. The sun4c kernel's `cg6_reset` (and NetBSD's) does the same for
revisions up to 4, keeping the resolution bits.

**The model stores bits 19:0 and acts on none of them.** The resolution is
fixed, and the caches and test window are hardware workarounds. FBC
offset 0 reads the same register: libpixrect's `cg6_make` reads the byte at
FBC + 1 and takes revision 0 to mean `cg6_vector0`, a workaround version of
vectors. **The model reports revision 1.**

## The FBC

Offsets from 0xFF700000, Solaris's names (NetBSD's in brackets). Every
register reads back what was written, except where the table says otherwise.

What uses each register:
* **P**: the PROM 3.0.1 console.
* **L**: libpixrect, as the harness saw it write (`-S`).
* **K**: the kernel. The sun4c `cg6_cntxsave` saves and restores every
  register marked K across processes.
* **X**: `sunGX.c`.

| off | register | users | behaviour |
|---|---|---|---|
| 0x000 | config | L | the FHC (above) |
| 0x004 | misc [mode] | P L K X | 2-bit fields: blit 21:20, data 18:17 (1 colour8, 2 colour1, 3 hrmono), draw 16:15, bwrite0 14:13, bwrite1 12:11, bread 10:9, bdisp 8:7; index-mod 6, index 5:4. **A field written 0 keeps its value** (Solaris names every 0 "IGNORE"). Only data matters to the model |
| 0x008 | clipcheck [clip] | P L K X | stored; software writes 0 |
| 0x010 | status [s] | P L K X | read: bit 28 BUSY while the engine works, 29 FULL. Write: bit 31 clears the pick accumulator; ignored otherwise |
| 0x014 | drawstatus [draw] | P L X | **read: starts the queued primitive**. Bit 31 EXCEPTION, 29 FULL, 28 BUSY |
| 0x018 | blitstatus [blit] | P L X | **read: starts the blit**, same bits |
| 0x01C | font | P L X | **write: draws a row of pixels** (*Font*) |
| 0x080-0x0BC | x0 y0 z0 color0 ... x3 y3 z3 color3 | P L K X | the vertex registers. Blits and the font register take their coordinates here |
| 0x0C0, 0x0C4 | rasteroffx, rasteroffy [offx, offy] | P L K X | added to every indexed (absolute) vertex |
| 0x0D0, 0x0D4 | autoincx, autoincy [incx, incy] | P L K X | added to x0/x1 and y0/y1 after each font write |
| 0x0E0-0x0F4 | clipminx, clipminy, clipmaxx, clipmaxy | P L K X | the clip window, inclusive, screen coordinates |
| 0x100, 0x104 | fcolor, bcolor [fg, bg] | P L K X | the raster op's f and b inputs |
| 0x108 | rasterop [alu] | P L K X | *Raster ops* |
| 0x10C, 0x110 | planemask, pixelmask | P L K X | *Raster ops* |
| 0x11C | pattalign | L K X | x in 31:16, y in 15:0, 4 bits each used |
| 0x120-0x13C | pattern0-7 | L K X | 16 rows of 16 bits, two rows a register, upper half first |
| 0x800-0x93C | indexed vertices | P L X | point 0x800, line 0x840, tri 0x880, quad 0x8C0, rect 0x900. Each group has abs x/y/z at +0/4/8, rel x/y/z at +0x10/14/18, colour r g b a at +0x30..0x3C (*Vertices*) |

### Raster ops

Every pixel the engine writes goes through one unit:

* **RASTEROP 15:0 is a truth table**, evaluated one bit plane at a time. Its
  index is `f*8 + b*4 + s*2 + d`, where:
  * f is the plane's bit of FCOLOR, b of BCOLOR;
  * s is the source's bit, d the destination's.

  Solaris names the nibbles rop11 (15:12), rop10, rop01 and rop00 (3:0) by
  f and b. Within a nibble, bit `s*2 + d` is the result.
  **Verified**: libpixrect's `cg6_rop_table` (cg6_util.o) puts pixrect op p
  in both f=1 nibbles and op p with s forced to 0 in both f=0 nibbles. With
  FCOLOR = the op's colour that gives pixrect's `src & colour`. NetBSD's
  copy 0xCCCC (s), fill 0xFF00 (f) and invert 0x5555 (~d) agree, and so does
  the PROM's text, 0x6C60 with f=0xFF, b=0 (black on white).
* **RASTEROP 31:16** (Solaris `l_fbc_rasterop`), 2-bit fields; **0 written
  keeps the field** (**verified**: libpixrect writes 0x0980xxxx, plane and
  pixel fields 0, and relies on the PLANE=mask that `cg6_reset_uregs` set):
  * plane 31:30: 1 none, 2 all, 3 PLANEMASK;
  * pixel 29:28: 1 none, 2 all, 3 PIXELMASK;
  * pattern 27:26: s for drawing is 1 zeros, 2 ones, 3 the pattern;
  * polygon 25:24 (overlap, non-overlap), attr 23:22, raster mode 17
    (boolean / "linear"), plot/unplot 16: **stored, not modelled**. Sun's
    code writes overlap or non-overlap, attr "supported", boolean, plot.
* **The plane mask**: planes whose bit is 0 keep their value.
* **The pixel mask**: pixel x is written only if PIXELMASK bit
  `31 - (x & 31)` is 1. That is screen-absolute alignment, the MSB leftmost
  in each 32-pixel-aligned group. **Verified**: `cg6_stencil` rotates its
  stencil words by the run's `x0 & 31` before writing them here. A model
  indexing relative to x0 fails 280 of 5,000 tests.
* **The clip window** limits every pixel the engine draws: drawing, blits
  (the destination) and the font register. **Verified**: with the font
  unclipped, 750 of 3,000 tests fail. libpixrect aligns its font runs to
  memory words and trims them with the clip window.
* **The pattern**: s at (x, y) is bit `15 - ((x + alignx) & 15)` of row
  `(y + aligny) & 15`. **PATTALIGN is added** (**verified**: replrop passes
  only so; MAME subtracts).

### Vertices

The indexed registers queue vertices for DRAWSTATUS:
* A **vertex is complete when both its x and its y have been written, in
  either order**. Sun's code writes y then x for lines and rectangles, x
  then y for points; sunGX.c writes y then x everywhere. **Verified**: points
  fail when x alone completes a vertex.
* An absolute coordinate has RASTEROFFX/Y added. A relative one is added to
  the previous vertex. libpixrect uses only absolute ones; sunGX.c uses
  relative lines, triangles and quadrilaterals for CoordModePrevious.
* The completed vertices also land in x0/y0 .. x3/y3, at the queue index
  modulo 4. MISC's index (5:4) reads that index for the next vertex
  (xnews reads the vertex before it back: *The TEC*).
* Writing a different primitive's register starts a new queue. The
  exception is a point followed by line, triangle or quadrilateral
  vertices: the point is their first vertex.
  * `cg6_polygon_2` draws a 2-4 point polygon as one point and 1-3 quad
    vertices (**verified**);
  * sunGX.c draws a triangle as a point and two tri vertices, and a
    quadrilateral as a point and three quad vertices;
  * OpenWindows 2.0's xnews strokes an outline as a TEC point, then TEC
    line vertices, reading DRAWSTATUS before each but the first
    (`_sh_lg_hol_2U` 0x5644a): its first line is from the point
    (**verified** by running it: with a new queue at the line, the first
    edge of 41 outlines in 50 is missing). libpixrect never writes a line
    vertex after a point, so its tests do not change.
* **DRAWSTATUS read** draws from the last vertices queued:

  | primitive | draws |
  |---|---|
  | point | the vertex |
  | line | from the second-last vertex to the last. **The end vertex stays queued**, so each further vertex draws on from it: `pr_polyline` writes one vertex and one DRAWSTATUS read per segment (**verified**) |
  | rect | the rectangle between two vertices, inclusive |
  | tri, quad | the polygon of the queued vertices (2 to 4). Two vertices draw nothing, as in memory |

  Every primitive's s is the pattern's (0, 1 or the pattern bit).
* **Lines** are Bresenham, both end points drawn (sunGX.c: "the GX does not
  allow CapNotLast"). They are **always stepped from the left end point**,
  with the error term starting at `-(major/2)` and the minor axis stepping
  when it goes above 0. With those two rules the board's lines are those of
  libpixrect's `mem_vector`, clipped lines included, in every test. Stepped
  from the first vertex they differ in a pixel for 1 line in 50. Pixel
  equality with `mem_vector` is the spec (**inferred**: Sun's code relies on
  it, since `cg6_vector` falls back to `mem_vector` on an exception).
* **Polygons** are scan-converted exactly as `pr_polygon_2` (pr_polygon2.c
  1.27) does it in memory: an edge table, each edge active on rows
  y0..y1-1, and on each row the pixels from one edge's x up to, not
  including, the next one's. Each edge's x is walked by Sun's integer DDA,
  transcribed in `cg6model.c` (`edge_setup`, `edge_step`) from the library's
  code at pr_polygon2.o +0x5C8-0x830 and +0xAD4-0xC80.
  * It starts half a step into a shallow edge;
  * its rounding is asymmetric for edges going left.

  A rounded-edge rule fails 59 of 1,500 tests; Sun's walk fails none.
  Whether the real GX rasterises exactly so is not known. Matching the
  library's own fallback is the spec (**inferred**). sunGX.c's polygons get
  the same pixels; X's own fill rule is not quite the same, and Xsun
  accepted the board's.

### Blits

A **BLITSTATUS read** copies:
* the rectangle (x0, y0)-(x1, y1), inclusive;
* to (x2, y2), inclusive to (x3, y3);
* through the raster-op unit, with s the source pixel;
* reading the source before it is overwritten when they overlap (the copy
  runs in whichever direction needs it);
* with the destination clipped by the clip window.

The coordinates are absolute; the raster offset is not added.

libpixrect writes x1 = x0 + w and x3 = x2 + w, one more than the width, and
sets the clip window to the destination. NetBSD's and Linux's drivers write
x0 + w - 1. Only "inclusive, destination clipped" serves both (**inferred**
from the two, **verified** for libpixrect). MAME treats x1 as exclusive and
does not clip, which is right for libpixrect and wrong for NetBSD.

MISC's blit field (Solaris: "blit src check") does not decide whether the
source is read: libpixrect blits with it at NOSRC. It is not modelled.

### Font

A **write to FONT** draws one row:
* at y0, from x0 to x1 inclusive, through the raster-op unit, clipped;
* MISC data = colour1: up to 32 pixels, the word's bit 31 leftmost, s = the
  bit on every plane;
* MISC data = colour8: up to 4 pixels, a byte each, bits 31:24 leftmost;
* then x0 += autoincx, x1 += autoincx, y0 += autoincy, y1 += autoincy.

Its users:
* the PROM's console: 12-pixel glyph rows, autoincy 1;
* libpixrect's every memory-to-screen path: rop from 1- and 8-bit memory,
  batchrop text, stencil, replrop;
* sunGX.c's glyphs and stipples.

### Status and timing

The engine is asynchronous on a real board. Software follows two rules:
* **It waits for STATUS bit 28 (BUSY) to clear** before changing state or
  touching the frame buffer directly. `cg6_get`, `cg6_put` and the kernel's
  `cg6_rop` wait, and then use `mem_rop` and friends on the frame buffer.
* **It starts a command by reading DRAWSTATUS or BLITSTATUS.** It repeats
  the read while the value is negative *and* has bit 29 (FULL), and **takes
  a negative value without FULL as an exception**. On an exception it does
  the operation in software (cg6_rop, cg6_vector, cg6_polypoint: `mem_*` on
  the frame buffer).

So a command refused because the engine is busy must read 0xA0000000
(EXCEPTION | FULL), plus BUSY. **Verified**: with FULL alone, 900 of 5,000
tests fail as libpixrect falls back to software. The model never raises an
exception without FULL: it can draw everything it is given.

The model's engine is instantaneous; `-b N` makes it report BUSY, and refuse
commands, for N status reads after each one. The tests pass at -b 0 to 3.

## The TEC

The TEC ("transform engine", 0xFF701000) is a matrix unit in front of the
FBC. Its users:
* The PROM and the kernel write MV, clip and VDC = 0 ("turn off frobs in
  transform engine (makes X11 work)", NetBSD).
* The kernel's `cg6_cntxsave` reads the 64 data registers twice, with VDC
  0x8000 and 0xA000, and `cg6_cntxrestore` writes both back (**verified**,
  cgsix.o 1.49).
* **libpixrect never touches the TEC** (`-S`), and neither does sunGX.c.
* **OpenWindows 2.0's sun3 xnews uses it on every GX, all the time**:
  matrices, point and path transforms, and as the vertex front end of its
  NeWS and X11 fills and strokes (*What xnews does with it*, below).
  OpenWindows 3's xnews too (`_lego_load_mv`, `_sh_lego_load_trans_2d`,
  `_sh_lg_tec_ex_abs` and `_rel`).

This section is the TEC as xnews 2.0 needs it, read from its 68020 code
(`openwin/bin/xnews` on the 4.1.1 tape, 1,335,296 bytes, SHA-256
e0c03ef4...5011bf3c6, not stripped; addresses are its text's) and from
`incl/pixrect/cg6tec.h` (1.2 88/10/07), and checked by running xnews's own
routines against the model (*The TEC's check*, below). The bit fields are
cg6tec.h's, which says its structures assume "the compiler assigns bit
fields left to right": on the 68020 the first field is bit 31.

### The registers

| offset | register | |
|---|---|---|
| 0x000 | MV | the vertex matrix's shape and switches |
| 0x004 | clipcheck | clip enables and results; stored |
| 0x008 | VDC | the data registers' type; the VDC multiply |
| 0x010..0x01C | COMMAND1..4 | a matrix product |
| 0x100..0x1FC | DATA00..63 | the data registers |
| 0x800, 0xA00, 0xC00 | I, B, F vertices | integer, 16.16 fixed ("B") and IEEE single; point, line, triangle, quadrilateral, rectangle 0x40 apart; ABS x y z w at +0..+0xC, REL x y z w at +0x10..+0x1C |

**MV** (`l_tec_mv_t`): 15 divide, 14 autoload, 13 h (the point has a w),
12 z (the point has a z), 10 i (the matrix's rows: 0 three, 1 four), 9:8 j
(its columns, 1 to 4), 5:0 the data register its first element is in. The
matrix is stored **column by column**: element (row k, column j) at index
+ j x rows + k (**verified**: `_sh_lego_load_trans_2d` 0xeb9b6 puts a
PostScript matrix [a b c d tx ty] at 0x22 as a c tx b d ty, `_lego_load_mv`
0x3bf70 a 4x4 at 0x12 as its columns). xnews's values:
* 0x112: 3 rows, 2 columns at 0x12 (`_sh_init_cg6` 0xeb93c, the 2D CTM);
* 0x122 with autoload, 0x4122: the identity at 0x22 that drawing goes
  through (`_sh_lg_Path_Raster` 0x4260c sets the index from the frame
  buffer's +0x5a, 0x22; `_sh_lg_vec_2U` 0xef676, `_sh_lg_area_2US`
  0x608f4, `_sh_lg_hol_2U` 0x5636c, `_xform_conic`/`cubic` 0xedc7a set bit
  14; `_sh_lg_area_2GS` 0xeea96 and the exception handlers clear it);
* 0x612 and 0x8712 (4x3, and 4x4 with divide) for a 3D canvas's CTM
  (`_lego_load_mv` 0x3c07a, `_sh_lego_load_trans_3d` 0xebb90). A 3D
  canvas's renderers are stubs in this build, so these are only loaded.

**VDC** (`l_tec_vdc_t`): 15:13 type, 12 multiply, 8 k (2D/3D), 5:0 the VDC
matrix's index. xnews sets 0x200C at start (fixed, the index 0x0C), clears
bit 12 every time it touches VDC (`_pipeline_context` 0xa644, `_val_nop`
0xebcbc), and from then on changes only the type, through a copy at the
frame buffer struct's +0x58 (0x0000, 0x2000, 0x4000). `_lego_load_vdc`
(0xebbaa), which would load a VDC matrix and set the multiply, is never
called (**verified**: no reference to it in text or data).

**COMMAND** (`l_tec_cmd_t`): 31:30 m - 1 (A's columns), 29:28 n - 1 (B's
columns), 27:24 the identity signs, 21:16 A's index, 13:8 B's, 5:0 C's.
xnews writes COMMAND1 only, three values:
* 0x90322236 (`_point_transform` 0x9e0a, 2D): A (x y w) at 0x32, B the 3x2
  at 0x22, C at 0x36;
* 0xF0322236 (the same, 3D): 1x4 times 4x4;
* 0x90321236 (`_upd_2d` 0xee54e, a path's relative and later elements):
  times the CTM at 0x12.

It writes the inputs, writes COMMAND1, and at once reads C (0x11d8..), with
nothing between: **C = A (1 x m) . B (m x n)**, B column by column as MV's
matrix is, C's j-th element at C + j (**verified** by the agreement below:
any other reading fails at once).

### The data registers

Inside, a data register is an IEEE single (**inferred**: xnews writes a
matrix and reads its products in the same type, fixed or float, and in
`_upd_2d_mv` 0xee394 writes vertices as fixed and reads the results as
float). Software sees it through VDC's type:

| type | a write | a read |
|---|---|---|
| 0 integer | converted, rounded to nearest | rounded toward minus infinity, saturated |
| 1 16.16 fixed | converted (value / 65536), rounded to nearest | x 65536, toward minus infinity, saturated |
| 2 IEEE single | as it is | as it is |
| 4 INTRNL0 | as it is | as it is |
| 5 INTRNL1 | a second bank of 64, raw | the second bank |
| 3, 6, 7 | as it is | as it is |

xnews uses all three of 0 to 2 for data: `_point_transform` writes integer
points at type 0 (0x9ef2), fixed at 1, float at 2, and reads the results at
the same type. Its fixed results are 16.16 (`_sh_lg_vec_2U` reads data 4
and 5 at type 1 as the current point, and puts `>> 16` of it in the FBC,
0xef68c). `_sh_lg_load_ident` (0x2370a) writes 1 as 0x3F800000 at type 2
and 0x10000 otherwise.

Rounding toward minus infinity is **inferred**, from xnews:
* `_sh_lg_hol_2U` closes an outline with an FBC line to the subpath's
  start (0x5673e), its x and y the integer halves (`move.w`) of data 4 and
  5 as read at its moveto, in 16.16. For that end to meet the TEC's own
  first vertex, autoloaded, the TEC's float-to-integer must be the floor
  of its float-to-fixed, which is the floor of the value.
* Its fan restarts and its own vertices use `asr.l #16` (0xef69c, 0x609ee),
  a floor, never `+ 0x8000`; xnews's software rasteriser rounds
  (`_sh_fb_Vect`), so the GX code was written for a TEC that does not.

The 64-bit TEC_DATA (`typedef double`) and the two banks the kernel saves
suggest a wider register inside; nothing xnews does needs it. The model
and the core keep bank 0 an IEEE single (types 4, 3, 6, 7 its raw bits)
and bank 1 a plain store.

### The vertex registers

A write to a vertex register's coordinate converts it by the register's
kind (integer, fixed, float: not by VDC) and puts it in **data register 0
to 3** (x y z w: `L_TEC_X` .. `L_TEC_W`, "used as index to store index
writes in tec_data array"). **x is the last written and transforms the
point** (**verified**: every vertex xnews writes is y then x, z or w first
when it has them: 0xef71a, 0x5643c, 0x60908, 0xedd76; it reads the result
at once after x):

* the point is (x y w) for a 3-row matrix, (x y z w) for 4; z is data 2
  with MV's z bit, else 0; w is data 3 with h, else **1 for ABS, 0 for
  REL**;
* for each of the matrix's columns j: the dot product, **into data register
  4 + j** (`L_TEC_X_MV` .., "used as index to store xform results"; xnews
  keeps pointers to data 4..7 at the frame buffer struct's +0x78..+0x84 and
  reads data 4 and 5 after each vertex: `_upd_2d_mv` 0xee3a0,
  `_sh_lg_vec_2U` 0xef7d4);
* a **REL** vertex adds its product to data 4 + j as it was: the TEC keeps
  the current point. xnews sets data 4 and 5 to the current point (16.16)
  before it draws (`_sh_lg_vec_2U` 0xef680, `_sh_lg_area_2US` 0x608ce), and
  then writes relative lines and quadrilateral vertices (0xa54, 0xc54,
  0xad0, 0xcd0) and nothing else.

With **autoload** (MV bit 14) the result, data 4 and 5 rounded toward
minus infinity, goes into the FBC's queue as an absolute vertex of the
same kind: a TEC line vertex as an FBC line vertex, with the FBC's raster
offset added (**verified** by xnews's use: it sets the raster offset to
the window's origin, 0xef658, and adds the origin to data 4 and 5 for its
device current point, 0xef7da; `_xform_conic` 0xedd0c reads the FBC's x0
and y0 back, `<< 16`, as the curve's control point; `_sh_lg_area_2US`
reads the vertex before MISC's index, 0x609b4). DRAWSTATUS then draws it:
xnews reads DRAWSTATUS after each line vertex and at each 0x43 element of
a fill. xnews draws, through the TEC:
* **lines**, fixed and float, absolute and relative (`_sh_lg_vec_2U`, the
  thin strokes, and `_sh_lg_hol_2U`, outlines: a TEC point, then TEC line
  vertices, each drawn from the one before, the point the first, and an
  FBC line back to it at 0x43);
* **fills** as fans of quadrilaterals: a TEC point, then up to three TEC
  quadrilateral vertices, then DRAWSTATUS; the next quadrilateral begins
  with an FBC point (not the TEC's) at the vertex before MISC's index, the
  fan's first (`_sh_lg_area_2US`);
* **curves**: `_xform_conic`, `_xform_cubic` autoload TEC points and read
  them back from the FBC;
* never triangles, rectangles, integer vertices or W.

**MISC's index** (5:4, `l_fbc_misc_index`) reads the slot the queue's next
vertex goes to, the number queued modulo 4 (**inferred**: `_sh_lg_L2Ds`
0xebe6a takes a failed line's ends from x/y[index - 2] and [index - 1]; the
fill's restart from [index] after point + 3 quadrilateral vertices, the
fan's first). The FBC model and the core now read it so; index_mod (6)
reads 0, and a written index is ignored.

### Clipcheck, exceptions, divide

xnews writes clipcheck 0 (no clip planes) and never enables them. It
clears TEC exceptions where it might meet one (`andi.l #$7f030303`: the
exception and every result bit, 0xef80a; `andi.l #$7fffffff`, 0xede1a)
when FBC STATUS bit 30 (`L_FBC_TEC_EXCEPTION`) or clipcheck bit 31 says
so, and goes on; `_sh_lg_tec_ex_abs`/`_rel`, which would turn autoload off
and redo the point, are not called. So the model and the core never raise
a TEC exception: STATUS bit 30 and clipcheck read as stored. MV's divide
and the VDC multiply are only set for 3D canvases, which this xnews does
not draw; neither is built.

### What the model and the core do, and leave out

Built: the data registers in every type and both banks; the vertex
registers of every kind and object, ABS and REL, x y z w, through MV's
every shape (3 or 4 rows, 1 to 4 columns, h and z); autoload into every
FBC primitive; COMMAND1 for every m and n. The arithmetic is IEEE single
as `cg6model.c` defines it: round to nearest even; a denormal operand or
result is zero; an exponent of 255 is infinity (no NaNs: inf - inf is the
first operand, inf x 0 is zero); overflow is infinity. Each product and
each sum is rounded, the dot product taken in order (x m0 + y m1) + w m2,
as xnews's own float code (`_sh_trans_mul_abs_f2d` 0xbd48e) does it.

Left out: MV's divide; the VDC multiply and its matrix; the clip planes,
clipcheck's results and TEC exceptions; COMMAND2..4 (stored); the
command's identity bits; NaN.

### The TEC's check

`tools/cg6model/xnews.c` (`make -C tools/cg6model xnews`) loads xnews whole
onto Musashi as a 68020, with its shared libc's floating point (Sun's
`V`/`F` routines through the PLT) done in C on the host's IEEE floats, and
calls its own routines with the structures they read (a canvas, its
matrix, its frame buffer's TEC/FBC pointer and type cache, a path):
* `_point_transform` (0x9e0a, COMMAND1) against the software's
  (0x3c06, `_sh_trans_mul_abs_*`), on random matrices (identity, scale and
  flip, rotation, shear; fixed and float) and points (fixed, float,
  integer, vectors);
* `_sh_cg6_Path_Transform` (the vertex registers, then COMMAND1 for relative
  elements, as a GX's pipelined canvas has it) against
  `_sh_fb_Path_Transform` (`_upd_pipe_xf_b2d`, `_xf_f2d`), on random paths;
* `_sh_lg_vec_2U`, `_sh_lg_area_2US` and `_sh_lg_hol_2U`, drawing with
  autoload: lines, fans of quadrilaterals and outlines. A second model
  draws the same from the exact vertices rounded down (for lines, given the
  same FBC cycles with each autoloaded vertex replaced; for fills and
  outlines, drawn from the shape itself), and the two frame buffers are
  compared.

Each result is compared with the exact one (doubles from the stored
inputs) and with the software's. `-T` first checks the TEC's arithmetic
against the host's IEEE single: 20 million operations on normal values, 0
differ.

**Results** (2026-10-23, `xnews68k XNEWS -n 20000 -s 1 -c`):

| compared | results | exact | the same pixel |
|---|---|---|---|
| point, TEC vs software, float matrices and points | 2,230 | **100%** | 100% |
| path, TEC vs software, float | 46,372 | **100%** | 100% |
| point, TEC vs software, fixed | 1,740 | 5.6% (worst 22,800/65536: the software's) | 99.08% |
| path, TEC vs software, fixed | 6,744 | 14.4% (worst 298/65536) | 99.99% |
| point, TEC vs exact, integer points | 1,718 | 99.94% | 99.94% |
| path, TEC vs exact, fixed | 52,512 | 6.9% (38% within 1/65536, worst 299/65536) | 99.98% |
| path, TEC vs exact, float | 46,372 | 5.7% (91% within an ulp) | 99.96% |
| drawing: autoloaded vertices vs the exact one rounded down | 82,900 | all but 3 | 2 tests of 12,008 differ, 1,166 pixels |

(9 million 68020 instructions, 1.06 million board accesses; 96,184 TEC
vertices, 82,900 of them autoloaded, and 41,323 commands.)
* **The float paths agree with xnews's software bit for bit**: the TEC
  computes what `_sh_trans_mul_abs_f2d` and `_upd_pipe_xf_f2d` do, in the
  same order. The software's float results are no nearer the exact ones
  than the TEC's (90.3% within an ulp, worst 65,400 ulps where a sum
  cancels).
* **In fixed** the software multiplies 16.16 by 16.16 exactly and the TEC
  has 24 bits: a few hundred 65536ths out at screen coordinates, another
  pixel in 1 result in 10,000 (paths). The software's point transform is
  the worse of the two at its worst (its vectors), another pixel than the
  exact one in 1%.
* An integer point lands on another pixel in 6 in 10,000: a value within
  float's precision of an integer. The three drawn vertices that differ
  are such values too (x.99997 in 16.16 is x+1 as a single; a relative
  line's sum, kept in 24 bits).
* 23,887 path elements the software makes float, xnews's TEC path leaves
  fixed: its own choice, not the TEC's. 1,593 results beyond 16.16's range
  are not counted (the TEC saturates, the software wraps).
* The drawing tests sometimes put a translation in the identity, as
  `_sh_lg_area_2GS` does (0xeea7c), so that relative vertices are seen to
  leave it out. The fills' reference is drawn from the polygon, not from
  xnews's cycles, so that the fan's restart at MISC's index is checked.

`make -C tools/cg6model mutatexn` breaks 14 of the model's TEC rules one at
a time (the rounding, the sticky bits, the fixed point, the matrix's and
the command's layouts, relative vertices, autoload's rounding and offset,
MISC's index), and `-T` or `-c` catches 14 of 14.

## The THC

THC registers (0xFF301000):

| off | register | use |
|---|---|---|
| 0x800-0x814 | hchs, hchsdvs, hchd, hcvs, hcvd, hcr: video timing | the PROM writes, for 0x60: 0x10009, 0x570000, 0x15005D, 0x10005, 0x2403A8, 0x16B. Stored; the core makes its own timing |
| 0x818 | hcmisc | revision 19:16; 12 reset; 10 video on; 9 sync and 8 **vsync**, both read-only status; 7 sync enable; 6 cursor resolution; 5 **interrupt enable**; 4 **interrupt pending**, written 1 to clear; 3:0 cycles |
| 0x8FC | cursor x (31:16), y (15:0) | the kernel writes 0xFFE0FFE0 to hide it |
| 0x900-0x97C, 0x980-0x9FC | cursor planes A and B, 32x32, one word a row, MSB leftmost | |

* **The PROM's set-up** (0xFEF62C8 on):
  1. misc = 0x1000 (reset), then 0x8F;
  2. the timing registers;
  3. it **waits for 15 vsyncs**: bit 8 set, then clear (0xFEF66E6). The bit
     must follow the raster, or the PROM hangs here;
  4. misc = 0x48F, video on.
* **The interrupt** goes pending at the start of vertical sync. The board's
  interrupt line is enable AND pending. Solaris's `thc_int_enable` sets
  bit 5; `thc_int_disable` writes bit 5 off and bit 4 as 1, which clears
  pending. The sun4c kernel loads colour maps in the retrace interrupt this
  way (`cg6_putcolormap`: misc & ~0x20 | 0x10, update the soft copy, misc
  |= 0x20). The 3/60's driver is not at hand; **inferred** to be the same
  driver source.
* **The cursor**: where a pixel's A or B bit is set, the cursor shows a
  Bt458 overlay colour, B*2 + A. The kernel's `cg6_reset` enables the
  DAC's overlay inputs (control register 6 |= 3) for it. The mapping of A
  and B onto OL0/OL1 is **inferred**. The kernel's FBIOSCURSOR uses it;
  SunView and the PROM do not.

## The DAC

A Bt458, its registers at +0, +4, +8, +0xC. On the GX its data is
**bits 31:24**:
* The PROM writes the colour map as longwords 0xFF000000 (white) and 0
  (black), and the control registers with the byte repeated on every lane
  (0x06060606).
* The kernel and NetBSD write `n << 24`.
* A 68020 byte write to the register's address is on those lanes too.

**Verified** by the PROM's colour-map writes. Unlike the 3/60's cg4, whose
DAC takes the low byte and packed colour-map longwords (cg4.md), the GX's
DAC takes **one component per access**.

The PROM sets:
* command 0x40, read mask 0xFF, blink mask 0;
* entry 0 white and **entry 255 black**: the console's background is pixel
  0 and its text pixel 0xFF.

The model has the Bt458's address auto-increment after blue, the four
control registers and four overlay colours, as cg4.md describes. Reading
the colour map back is modelled; nothing reads it.

## The board's ROM

At 0xFEF6AA8 the PROM reads the ROM's first longword. If its low byte is
0x64, the ROM holds a colour map and a colour logo, which the PROM loads
and draws with colour8 font writes. Otherwise it draws no logo. **The ROM can
read as 0**: no logo, and the PROM's monochrome logo path as on a bw2.
Nothing else reads it. Left out.

## The level-4 interrupt

The P4 connector's interrupt pin is `V.INTY-` (cg4.md, *The level-4
interrupt*). The GX drives it with the THC's enable AND pending. In the core:
* `sun3_vint.v` takes the colour board's interrupt as it takes the cg4's;
* the GX's comes from the THC instead of the P4 register;
* U805's rule holds: the on-board video's interrupt until the P4 board first
  interrupts, the P4 board's from then on.

## What each stage needs

**(a) The PROM 3.0.1 console** (0xFEF6070-0xFEF6F3C):
* the ID byte (0x60), the FHC, the TEC writes;
* the THC's misc with a live vsync bit;
* the DAC's control registers and colour map;
* the ROM reading as anything but 0x64;
* FBC registers that read back (0xFEF6C56 saves 16 of them around every
  character and restores them);
* STATUS BUSY, DRAWSTATUS and BLITSTATUS with FULL;
* rect fill (clear, cursor XOR), the font register in colour1 (text),
  blits (scrolling).

The harness's `test_prom` replays this sequence, register for register:
clear, two characters, the cursor, a scroll. The PROM sets FBTYPE 12,
`FBTYPE_SUNFAST_COLOR`, at 0xFEF6078.

**(b) SunOS's console and `cgsix0`.** SunOS on a sun3 writes its console
through the PROM's routines, so (a) carries it until a window system runs
(**inferred** from the cg4, cg4.md). The kernel driver needs:
* the P4 probe: FHC ID 0x60. SunOS's `p4probe` writes the register back
  with bits 30:24 inverted (cg4.md); on the GX that is an FHC write, which
  must not change the ID it reads;
* its reset: TEC, FHC, the cursor, DAC control register 6;
* the colour map: the THC interrupt, through level 4;
* `cg6_cntxsave` / `cntxrestore`: every FBC register marked K, the TEC's
  MV/clip/VDC and its data registers, read back exactly;
* mmap of the FBC/TEC page, the DAC, FHC/THC, the ROM and the frame buffer
  (cg6reg.h `CG6_VADDR_*`).

`cgsix0` "at obmem 0xff000000 pri 4" is the acceptance line.

**(c) SunView and pixrect**: everything in *The FBC* but the TEC:
* the raster-op unit with plane mask, pixel mask, pattern and clip;
* the font register in colour1 and colour8, with autoincrement;
* rectangles, lines with the line rule, points, 2-4 point polygons with
  the polygon rule;
* blits;
* the raster offset (libpixrect's region pixrects);
* EXCEPTION | FULL for a busy engine.

The harness checks all of it.

**(d) X11 / OpenWindows**:
* sunGX.c (Xsun) needs (c) plus relative vertices, triangles, BCOLOR in
  stipples, and the pattern. The model has all of these. They are checked
  only through the rules libpixrect shares, not by running Xsun.
* OpenWindows 3's xnews needs the TEC's transforms as well. OpenWindows 2.0's
  xnews for sun3 (on the 4.1.1 tape, below) has a GX driver too
  (`_sh_init_cg6`, `_sh_cg6_Area_Rect`, `_sh_Ops_Trans_cg6`, ...) and the
  same TEC transform loads (`_sh_lego_load_trans_2d`, `_3d`). Whether it
  calls them on the 3/60, or only for some operations, is still open.

**Can be left out**:
* the TEC's arithmetic (all but xnews);
* pick mode (MISC draw = 2) and the accumulators;
* z and the colour vertex registers (stored only);
* "linear" raster mode;
* the polygon overlap flag;
* the clipcheck register's meaning (TEC clip results);
* the THC's timing and cursor resolution;
* the FHC's cache, test and endian bits;
* the DHC, the ALT and the ROM.

## What the harness found in Sun's code

The definition of each operation, a pixel at a time, judges between the
model and the memory code when they disagree. The model is then right in
every case, and four are Sun's (the last only in the 68020 library):

* **mem_rop, mem_stencil and pr_replrop's memory path** are wrong for a few
  narrow rectangles at some bit offsets: 1 to 3 tests in 4,000. The cg2
  harness found the same of the 4.0 mem_rop. The harness counts these as
  "Sun's mem code is the one wrong".
* **cg6_stencil with an 8-bit source and a colour** sets FCOLOR to
  ~colour (cg6_stencil.o +0x470), so the board draws `src & ~colour`. Mem
  ignores the colour. The harness uses colour 0 there.
* **cg6_batchrop leaves the clip window** it set for a glyph that the
  destination clips, and a whole glyph after it, taken by the fast path,
  is clipped by the stale window (it vanishes). On a real GX this would
  show too (**inferred**). The harness counts such batches separately:
  about 1 in 4,000 tests.
* **The 68020 cg6_stencil runs away** with an 8-bit source narrower than
  one 32-pixel group, on one of its two alignment paths: it takes the
  group count from 0 to -1 (cg6_stencil.o +0x74c) and loops on it with
  PR_LOOP (+0x7c0..0x7f0). pr_impl_util.h's 68000 LOOP_DECR is
  `--n != -1`, a dbra, which goes round 65,536 times; SPARC's
  `--n >= 0` goes none. Each time round it writes the pixel mask and 8
  font words from past the source (**verified**: disassembly, header, and
  the harness's trace). A 3/60 would draw garbage or fault
  (**inferred**). The harness stops such a call at 100,000 font writes (a
  stencil makes at most ~16,000), does what the routine's exit does (pixel
  mask all ones), and counts it: 26 of the about 740 8-bit stencils in
  20,000 tests.

## MAME

Three places where MAME and the model disagree, the model by Sun's code:
* MAME's pattern subtracts PATTALIGN; Sun's adds;
* MAME's blit treats x1 as exclusive and does not clip;
* MAME's rectangle takes the destination pixel as s when the pattern field
  is 0; here a 0 field keeps its value, and s comes from the pattern.

MAME has no lines, points, polygons, pixel-mask alignment or busy and FULL
behaviour.

## The C model

`tools/cg6model/`:
* `cg6model.c`, `cg6model.h`: the board, as this document specifies it;
* `sparc.c`, `sparc.h`: a SPARC V8 integer interpreter;
* `aoutlink.py`: links SunOS SPARC or 68k a.out objects flat (the Sun-2's
  `tools/cg2model/aoutlink.py`, with SPARC relocations added);
* `harness.c`: runs libpixrect's cg6 code against the model, and the mem
  code against a mirror. Built plain it runs SPARC code in `sparc.c`; with
  `-DM68K` (`harness68k`) it runs 68020 code on Musashi (MIT licence,
  fetched by the Makefile at the Sun-2's pinned commit 313ebf1, or
  `MUSASHI=` a checkout). Only the CPU back-end differs: arguments
  (`%o0..` or the stack), the stubs' trap (`unimp` or `illegal`), and
  pr_makefromfd's view of its by-value `struct pr_size` and of
  `pr_devdata` (fd and va at +0xc/+0x10 on SPARC, +0xa/+0xe on the
  68020, where an int is 2-aligned after the short dev_t);
* `xnews.c` (`xnews68k`): OpenWindows 2.0's sun3 xnews, loaded whole on
  Musashi, its own TEC routines against the model's TEC (*The TEC's
  check*);
* `mutate.sh`.

```
make -C tools/cg6model [run] [N=20000 SEED=7 BUSY=3]   # LIBPIXRECT=... the library
make -C tools/cg6model mutate
make -C tools/cg6model run68k [N= SEED= BUSY=]        # LIBPIXRECT68K=, MUSASHI=
make -C tools/cg6model mutate68k
make -C tools/cg6model trace68k [B=dir TN=300 SEED=1] # $(B)/t_lp68k.{txt,ini,fin}
make -C tools/cg6model xnews [XN=2000 SEED=1]         # XNEWS=, MUSASHI=
make -C tools/cg6model tracexn [B=dir XTN=300 SEED=1] # $(B)/t_xn.{txt,ini,fin}
```

`XNEWS` defaults to `build/dist/sunos-4.1.1-sun3/usr/openwin/bin/xnews`
(SHA-256 e0c03ef4...5011bf3c6, from the 4.1.1 tape).

`LIBPIXRECT` defaults to `build/dist/sunos-4.1.3-sparc/libpixrect.a`
(SHA-256 d7703e9f...fdf50175, from the 4.1.3 image above);
`LIBPIXRECT68K` to `build/dist/sunos-4.1.1-sun3/usr/lib/libpixrect.a`
(SHA-256 41475a65...b33d0ade, from the 4.1.1 tape above).

**What one run does:**
1. `test_prom`: the PROM's console sequence, and the THC interrupt.
2. Library calls, at random, through Sun's cg6 code on the model and Sun's
   mem code on a mirror, comparing all 1,036,800 pixels after each:
   * cg6_make (the library's attach);
   * pr_rop: fill, screen to screen, from 8-bit memory, from 1-bit memory
     plain and reversed, screen to memory, get and put;
   * pr_vector;
   * pr_batchrop with random glyphs;
   * pr_stencil, with no, 1-bit and 8-bit sources;
   * pr_replrop (16x16 and odd sizes);
   * pr_polygon_2, pr_polyline, pr_polypoint.

   Each draws in random regions, colours, ops, clipping and plane masks.
3. A traced run (`-t trace -I initial -F final`) replayed on a fresh model
   (`-R`), to check the trace is complete. An RTL bench can replay the same
   three, as the Sun-2's `tb_cgtwo` replays cg2model's. It must poll each
   command read until it is not FULL rather than match its value.

**Results** (2026-10-22):
* 0 failures in 20,000 tests at -b 2 (`make run N=20000 BUSY=2`, 701
  million SPARC instructions, 15.7 million board accesses), and in 8 x 4,000
  tests at seeds 1, 6, 17-22 and -b 0 to 2;
* 1 to 3 tests in 4,000 are "mem is wrong" cases (5 in the 20,000);
* fewer than 1 in 4,000 is a stale-clip batchrop.

The engine work in 4,000 tests: about 9,000 points, 3,100 lines, 200 quads,
50,000 rectangles, 90 blits and 1,000,000 font writes. libpixrect never uses
triangles or relative vertices. `mutate.sh` breaks 17 of the model's rules
one at a time and the harness catches 17 of 17.

### The 68020 run

SunOS 4.1.1's own sun3 libpixrect, on Musashi as a 68020, with the same
tests, seeds and model (2026-10-23):
* 0 failures in 20,000 tests at -b 2 (`make run68k N=20000 BUSY=2`, 611
  million 68020 instructions, 18.6 million board accesses), and in 32 x
  4,000 tests at seeds 1, 6, 17-22 and -b 0 to 3;
* 26 runaway stencils in the 20,000 (*What the harness found*), 0
  stale-clip batchrops (SPARC: 0), and 39 "mem is wrong" cases (SPARC: 5).
  37 of the 39 are pr_replrop, nearly all with 16-pixel-wide 1-bit
  patterns, whose mem path draws rows that are no row of the pattern. The
  model matches the definition there. Its mem_rop is the older 4.27
  (**inferred** cause);
* the engine work is the SPARC run's, test for test: 43,791 points,
  15,182 lines, 0 triangles, 1,012 quads, 262,117 rectangles, 412 blits and
  104,860 refusals. Font writes are 8.1 million against 5.5 million: the
  26 stopped stencils' 100,000 each.

Besides the runaway, the 68020 code drives the board exactly as the SPARC
code does (**verified**, seed 3, 2,000 tests at -b 0, no runaway):
* the same 1,046,310 accesses, at the same offsets, sizes and order;
* `-S` is identical for every kind of test;
* 2,186 written values differ, all don't-cares: 709 FCOLORs under raster
  ops that ignore it (0, D, ~D, 1); 1,474 font words, in bits the clip
  window removes (pr_replrop's odd-sized tiles); 3 stencils' pixel masks,
  in bits outside the clip window or under the raster op D.

Neither library touches the TEC beyond cg6_make's `bzero` of TEC +4..+7
(four byte writes), nor writes the triangle (0x880) or any relative
vertex register.

One failure was found since, at seed 2 (`-n 150`): a batchrop of 19 glyphs
from x = -10, 16 pixels at x 1144..1146. The board's frame buffer ends
identical to the SPARC run's, the two traces differing only in don't-care
values, so it is the 68020 mem_batchrop (or Musashi) that differs, not the
model. It is not yet classified.

`mutate68k` catches 17 of 17. `trace68k` writes a 300-test trace of every
kind (303,592 accesses at seed 1, one of them a stopped stencil's 100,000
font writes), which `-R` replays to 0 differences.

## The RTL plan

### One P4 slot: cg4, GX or Off

A 3/60 has one P4 connector. The OSD's *Colour board* (`P1O[12]`,
On/Off) gains a second bit, `P1O[19]` (the first free one today), *Colour board
type*: cg4, GX. It is
shown only when the board is On, keeps 0 the default (cg4), and moves no
existing bit, so saved settings stay valid. Both are latched in reset into
`cfg`, as `status[12]` is today. With the GX:
* `sun3_fpga.v` answers the GX's map instead of the cg4's;
* the EEPROM's console byte is made 0x20, as for the cg4;
* the screen is the GX's.

### Where things live

* **The frame buffer** is at PA 0xFF800000, the cg4's colour plane address.
  The bridge's `MATCH_CG` window and the SDRAM's 1 MiB at 25 MiB serve it
  unchanged. The cg4's overlay and enable planes are simply not decoded.
* **The scan-out** is `sun3_cg4_scanout.sv` with the overlay and enable
  fetches off: 72 of its 90 bursts a line, 62 MB/s. The THC cursor joins it:
  * 32x32x2 bits in an M10K;
  * a comparator on the raster's x and y;
  * the overlay colour chosen in front of the DAC.
* **The DAC** is the cg4's Bt458 block, with its byte taken from bits 31:24
  and one component an access (a mode input).
* **FHC, THC, TEC and the FBC registers** are a new `sun3_cg6.sv` on the CPU's
  clock, as `sun3_cg4.sv` is. The TEC's 64 data and 0x800-0xD1C vertex
  words go in an M10K, stored only.

### The engine

`sun3_cg6_engine.sv`, on the SDRAM's clock (`clk_mem`, about 100 MHz),
is a third SDRAM client beside the CPU bridge and the scan-out. It has:

* **A command interface** from the register file. On DRAWSTATUS or
  BLITSTATUS:
  * it takes a snapshot of the registers it needs and goes busy;
  * a read while busy returns EXCEPTION | FULL | BUSY.

  FONT writes queue in a small FIFO (16 x 32 bits) and stall the CPU's bus
  only when it is full. While the engine is busy, register writes are held
  (DSACK delayed) until it is idle, so the snapshot can be small. The
  software waits for BUSY anyway.
* **A span unit**: every primitive becomes runs of pixels on one row,
  (y, x0, x1) plus a source:
  * pattern;
  * a font word;
  * the blit source line buffer.
* **A pixel datapath of 16 pixels (one 16-byte BL8 burst)** a step:
  * the destination burst read when the op needs d (rop nibbles differ in d,
    or the plane, pixel or clip masks leave pixels alone);
  * 128 truth-table lookups (each a 16:1 mux of RASTEROP bits by f, b, s, d);
  * the plane mask;
  * a byte mask from clip, pixel mask and run ends (the SDRAM's DQM);
  * the burst written.

  Fills that need no d are write-only: about 16 pixels per 10 clocks.
* **Rect**: a row loop over spans.
* **Line**: Bresenham, one pixel a step, with a one-burst write-combining
  buffer: consecutive pixels in the same 16 bytes become one
  read-modify-write.
* **Point**: one pixel.
* **Polygon**: Sun's edge DDA (`edge_setup`, `edge_step`) for up to four
  edges in parallel. It needs:
  * a 16-bit divider for `dx / dy`, iterative, 16 clocks a polygon edge;
  * a multiplier for `step * dy` (a DSP block);
  * a 4-entry sort of the active edges' x for each row's spans.
* **Blit**: per row, read the source span into a 1152-byte line buffer
  (M10K), then write the destination span through a byte funnel shifter
  (16 bytes, any byte offset). Rows run top-down or bottom-up, and the
  buffer makes left-right overlap free.
* **Font**: one row of up to 32 (colour1) or 4 (colour8) pixels as one or
  two bursts.

**Coherency.** The CPU's frame-buffer writes and the engine's must not
cross. Both reach the SDRAM through the core's adapter. The register writes
that start a command come through the same ordered bridge as the CPU's posted
frame-buffer writes, so the engine starts only after those writes drain.
The software waits for BUSY before reading or writing pixels.

### Area (DE10-Nano; the fit is 26,698 of 41,910 ALMs, 326 of 553 M10K, 41 of 112 DSP)

| block | ALMs | M10K | DSP |
|---|---|---|---|
| FBC register file and readback mux (about 45 registers) | 700-900 | | |
| FHC, THC (misc, vsync, interrupt), cursor registers | 150 | 1 | |
| TEC register store | 50 | 2 | |
| command control, font FIFO, span unit, row iterator | 500-700 | 1 | |
| raster-op datapath, 16 pixels (truth tables, plane mask, byte masks, clip) | 450-600 | | |
| pattern (256 bits) and pixel mask | 150 | | |
| line unit | 150 | | |
| polygon edge DDA x4, divider, sort | 600-900 | | 1-2 |
| blit line buffer and 16-byte funnel shifter | 300-400 | 2 | |
| SDRAM client (third port, DQM, priority below the scan-out) | 200-300 | | |
| scan-out changes (colour only, cursor overlay) | 100-150 | 1 | |
| DAC mode | 50 | | |
| **total** | **3,400-4,700** | **about 7** | **1-2** |

That makes 30-31.5k ALMs (72-75%). Both boards are built in and chosen in
reset; the cg4's own registers are a few hundred ALMs, and the scan-out and
DAC are shared. **It fits**, with room for the levers in design-plan.md's
*Budget* left unused.

The engine on `clk_mem` keeps the CPU's 30 ns path untouched. Its widest
path, the 16-byte funnel shifter into the rop, should be pipelined from the
start.

### Stages

Each stage has a Verilator bench and a mutation script, as all MiSTer glue
does.

1. **The PROM 3.0.1 console.** Build:
   * the register file, FHC ID, THC vsync, DAC mode;
   * rect fill, the font register (colour1) and blits in the engine;
   * the colour-only scan-out.

   Accept when:
   * `tb_cg6` replays `test_prom`'s sequence and the harness's traces
     (`-t -I -F`, fills, text and copies only) into the RTL, and the frame
     buffers match;
   * `tb_emu` with the colour board on and the type GX (`+status=` the new
     bit) shows the 3.0.1 banner in black on white at 1152x900, and the
     keyboard echoes at the `>` prompt;
   * on the board, the same, and `b` reaches the boot program.
2. **SunOS's console and `cgsix0`.** Build:
   * the THC interrupt into `sun3_vint.v`;
   * the cursor;
   * every register reading back;
   * the TEC store.

   Accept when:
   * `tb_vint` runs the THC's enable/pending/clear sequence;
   * on the board, SunOS 4.1.1 reports `cgsix0 at obmem 0xff000000 pri 4`,
     the console scrolls through the boot, and a colour-map change through
     FBIOPUTCMAP takes one level-4 interrupt (cg4.md's 7,013-for-500 check,
     repeated).
3. **pixrect acceleration.** Build lines, points, polygons, the pattern, the
   pixel and plane masks, the colour8 font, and the raster offset.

   Accept when:
   * `tb_cg6` replays full harness traces (`make -C tools/cg6model run`,
     every test kind) with the RTL's own BUSY timing;
   * on the board, `sunview` comes up on `/dev/cgsix0`, and `spheresdemo`,
     `jumpdemo` and a shelltool's scrolling run;
   * `mono SunView, 2,000 lines of termcap` (design-plan Phase 6) is faster
     than on the cg4.
4. **X11.** Build relative vertices and triangles (already in the model).

   Accept when:
   * MIT X11R5/R6 Xsun with `sunGX.c` runs `x11perf -rect10 -copywinwin10
     -seg10 -tr10 -fitext` with output equal to the unaccelerated server's;
   * OpenWindows 2.0's xnews on the 3/60 is tried. If it needs the TEC,
     that is a stage of its own (*Risks*).

### Risks

* **OpenWindows and the TEC.** Settled for OW 2.0 in *Stage 2: SunView*:
  its sun3 xnews needs the TEC's 2D arithmetic. OW3's xnews transforms paths in the TEC (IEEE
  single-precision 2x3 matrices, float vertex registers). A TEC is an FP
  multiply-add unit with a float-to-integer converter, perhaps 1.5-3k ALMs
  and several DSPs, and its exception semantics are unknown. Before
  stage 4, find out what OW 2.0's sun3 xnews does on a GX: run it on the
  model with a TEC that traps every access.
* **The exact pixels of lines and polygons on a real GX** are not known.
  The model matches libpixrect's software paths, which is what Sun's own
  code checks itself against. A real board could differ at edges; nothing
  here could show it.
* **SunOS 4.1.1's sun3 cgsix driver was not read.** The P4 probe's FHC
  write, the context switch, and the mmap layout are taken from the sun4c
  4.1.3 driver and cg6reg.h's 68020 branch. libpixrect is settled (*The
  68020 run*). Disassembling the sun3 `cgsix.o`, in build/dist/'s sun3
  4.1.1 set, settles the driver.
* **SDRAM bandwidth.** The scan-out takes 62 MB/s of about 110-120. The
  engine and the CPU share the rest, so fills run at roughly 20-40
  Mpixel/s. That is fine for SunView. If not, move the frame buffer to DDR3,
  as design-plan.md's cg4 fallback says.

## Stage 1: in the core

**Status (2026-10-23, on the board, 192.168.99.143, build of `a3966aa`):**
Rev 3.0.1's console on the GX, and SunOS 4.1.1_U1's: the kernel attaches
`cgsix0 at obmem 0xff000000 pri 4`, boots on the GX's console to login,
and scrolls it (the engine's blit). The fit meets timing (`cpu_clk`
+2.061 ns at 30 ns, `clk_mem` +1.099 ns) at 29,962 ALMs (71%) with the
CD-ROM. Not tried yet: SunView or anything through `/dev/cgsix0`. The OSD's *Colour board type*
(`P1O[19]`, shown while *Colour board* is On) is **GX**, and the banner
reads `Sun Workstation, Model Sun-3/60C/G`, drawn by the engine.

### What is built

* `SUN3_CG6` in `Sun-3.qsf` (`rtl/sun3/sun3_config.vh`). It needs
  `SUN3_CG4`, whose Bt458, colour plane and scan-out it shares, and
  `SUN3_WB_CACHE`.
* **`rtl/sun3/sun3_cg6.sv`**, on the CPU's clock:
  * the FHC: ID 0x60, revision 1, 19:0 stored (the P4 probe's inverted-ID
    write keeps the ID);
  * the THC's misc: vsync is the raster's vertical blank, the retrace
    interrupt pending from its start, enable AND pending onto the P4
    interrupt into `sun3_vint.v`, INT written 1 clears it, video on;
  * the FBC registers of *The FBC* that the PROM and libpixrect write,
    each reading back, MISC's and RASTEROP's fields kept when written 0;
  * the vertex queue as the model has it (both coordinates, the raster
    offset, relative vertices, the point-then-polygon rule, x0..x3 landing,
    a line's end kept);
  * DRAWSTATUS (a rectangle, or a point), BLITSTATUS and FONT start the
    engine. While it works, a command read is EXCEPTION | FULL | BUSY,
    STATUS is BUSY | FULL, and every other FBC cycle waits for it;
  * the TEC, the ROM, the DHC and the ALT read 0 (the ROM's 0 means no
    colour logo: the PROM draws its mono one).
* **`rtl/sun3/sun3_cg6_engine.sv`**, on `clk_mem`: rectangles, font rows
  (colour1 and colour8, with the autoincrement applied when it answers) and
  blits, through the whole raster-op unit but the pattern (the truth table,
  the plane mask, the pixel mask by screen x, the clip window, the 1 MiB).
  It works a burst (16 pixels) at a time: the bytes to write, their sources,
  the destination burst read only when the op or the plane mask needs it,
  then the words with something to write. A blit reads each source row's
  span into a 128-burst line buffer (an M10K) and takes each destination
  burst out of it through a two-step funnel, so a copy may overlap either
  way along a row; rows go bottom-up when it moves down.
* **`rtl/sun3_mister_sdram.sv`**: a fourth client port, `ge_*`: a burst
  read or a 32-bit word written with byte selects, at an SDRAM word.
* **`rtl/sun3/sun3_cg4_scanout.sv`**: `colour_only`, 72 bursts a line and no
  overlay.
* **`rtl/sun3/sun3_fpga.v`**: the GX's decode (*The address map*), its
  cycles out of the bus timeout, the Bt458 on D31:24, the THC's interrupt
  into `sun3_vint.v`, the EEPROM's console byte 0x20 for either board.
* **`Sun-3.sv`**: the OSD bit, latched in reset as the board is, the port
  into the adapter, the scan-out colour only.

### Where it differs from the plan above

* **Writes are 16 bits at a time.** The SDRAM controller is built with
  `NO_WRITE_BURST` (single-access writes), so a burst written is up to eight
  writes; only reads are bursts. A full-screen fill with no destination
  read, beside the colour scan-out, takes 75 ms (`tb_cg6`): 14 Mpixel/s,
  under the 20-40 of *Risks*. The PROM clears the screen once, but its
  scroll (a 960x726 blit) costs about as much again, so a line feed at the
  bottom of the console takes a tenth of a second or more. Burst writes in
  the controller (BL8 with DQM, eight times fewer commands) are the fix,
  for stage 2 or 3.
* **No font FIFO.** A FONT write waits while the engine draws the row
  before it, as every other FBC cycle does (the register file holds DSACK).
  A row is one or two word writes, about a microsecond, and the PROM's text
  is no slower than on the cg4. Stage 3, with libpixrect's text, may want
  the FIFO.
* **No snapshot.** The engine reads the register file's outputs directly:
  they cannot change while it works, since every cycle that could change
  them waits. Only the start toggle crosses clocks through flops.
* **Coherency through the bridge's idle flag.** The register cycles do not
  go through the memory bridge, so a command could start with the CPU's
  frame-buffer writes still in its queue. The engine waits for the bridge's
  `WB_IDLE` (nothing queued, nothing in flight) first.
* **Priority.** The engine is below even a polite scan-out (the adapter's
  `pick_cs` is as it was), and takes turns with the CPU.
* **More than stage 1 asked for, because it was cheap**: the plane and
  pixel masks, colour8, the raster offset, relative vertices and points
  (stage 3 in the plan), and the THC's interrupt into `sun3_vint.v` (stage
  2). The pattern (RASTEROP's field 3 draws ones), lines, triangles and
  quadrilaterals (queued, drawn as nothing), the THC's timing and cursor,
  the TEC, z, the colour vertex registers and the indexed registers' own
  values (read 0) are not.
* **The model had a bug**: `merge_fields` looked only at even bits, so of
  MISC's fields only the blit field was kept when written 0. Fixed
  (tools/cg6model), and libpixrect still passes.

### How it is checked

* **`tb_cg6`** (`make -C tb/verilator tb_cg6`, in the default list): the RTL,
  the Bt458, the adapter and controller on the chip model, and the
  colour-only scan-out, replaying the model's traces (harness `-G`:
  `test_prom`'s sequence and 400 direct tests; and, when libpixrect is in
  `build/dist/`, 150 of its fill, copy, text, stencil and point tests,
  `-K`). Every pixel of the frame buffer is compared at the end, and every
  register and frame-buffer read on the way. Then the THC, the FHC, the busy
  engine, the Bt458 and a whole frame of the scan-out, directed. `+lockstep`
  runs the model beside it through DPI and stops at the first command that
  differs. 1,025 checks pass.
* **`mutate_cg6.sh`**: 37 mutants of the two files, all caught.
* **`tb_mister_sdram`** drives the new port (byte selects, back to back,
  turns with a streaming CPU, below the scan-out); `tb_cg4_scanout` has two
  colour-only frames. Both mutation scripts have the new paths.
* **`tb_emu`** with `ROM=build/rom/sun3_60_v3.0.1_fast.bin` and
  `+status=80000`: the banner on the GX, its `Model Sun-3/60C/G` line
  whole in the frame at 1,175 ms simulated, the rest by about 1.35 s (the
  cg4's is up by about 1.1 s: the PROM waits 15 vsyncs on the THC first, a
  quarter of a second). With the cg4
  (`+status=0`) and with the board off (`+status=1000`) the banners are as
  they were.

### Area (a guess; no fit yet)

| block | ALMs | M10K |
|---|---|---|
| register file, read-back mux, vertex queue | 800-1,000 | |
| engine: control, masks, font shifter | 400-500 | |
| engine: burst registers, raster op, funnel | 600-800 | 4 (the line buffer) |
| adapter port, scan-out mode, decode | 100-150 | |
| **total** | **1,900-2,450** | **4** |

`sy * 1152` is a constant multiply, shifts and adds (perhaps a DSP).

### What stage 1 left

SunOS's `cgsix` driver needed the THC's timing and cursor, the cursor in the
scan-out, the TEC stored, and z, the colour vertex registers and the
indexed registers read back; SunView needed lines, polygons and the pattern.
Stage 2 below has them.

## Stage 2: SunView

**Status (2026-10-23, Verilator only; not yet on the board):** what SunView
and its kernel driver use of the GX, and the engine's writes as SDRAM
bursts. The board tests to run are at the end.

### What SunView uses, from the sun3 4.1.1 objects

Read from `sys/sun3/OBJ/cgsix.o` (cgsix.c 1.49 90/10/03) and `windt.o`, and
the 68020 `lib/libpixrect.a` (`tools/sunos/aoutdis.py`):

* **The kernel's attach** writes the Bt458's control registers (command
  0x43: both overlay inputs on; read mask 0xFF; blink 0), the THC's timing
  (the PROM's six values) and misc |= 0x8F, the cursor to (2000, 2000), the
  FHC (0x10BBB for revision 1), and TEC MV, clip and VDC = 0.
* **The colour map** (`cg6_putcolormap`, the FBIOPUTCMAP ioctl): THC misc
  &= ~0x1020, |= 0x10 (disabled, pending cleared), the soft copy, misc =
  misc & ~0x1000 | 0x20 (enabled), `setintrenable(1)`. On level 4,
  `cgsixpoll` calls `cgsixintr` when its soft flags say an update is
  waiting -- it does not read the THC's pending bit -- which loads the
  cursor's two colours (Bt458 overlay entries 1 and 3), then the colour
  map, then `setintrenable(0)` and misc &= ~0x1020, |= 0x10.
* **The cursor** (`cg6_setcurshape`): plane A (0x900..) is the mask, plane B
  (0x980..) the image AND the mask, so A alone shows overlay colour 1 (the
  cursor's background), A and B overlay colour 3; `cg6_setcurpos` writes
  (x - hot x) << 16 | (y - hot y), or 0xFFE0FFE0 to hide it. **SunView's
  desktop uses it**: `windt.o`'s `dtop_load_hw_cursor` calls FBIOSCURSOR
  whenever FBIOGCURMAX (32x32) allows the cursor's size, and moves it with
  FBIOSCURPOS. Without the cursor in the scan-out SunView's pointer would
  be invisible.
* **The context switch** (`cg6_cntxsave`/`restore`, when processes take the
  GX from each other, as SunView's tools do): STATUS, clipcheck, MISC, x0..y3
  (not z or colour), the raster offset .. PATTERN7 (0x0C0..0x13C), TEC MV,
  clip and VDC, and the 64 data registers in both banks. Restore writes
  them all back, STATUS last.
* **libpixrect** (68020, the same cg6 members and SCCS ids as SPARC 4.1.3):
  points (0x800), lines (0x840), quadrilaterals (0x8C0), rectangles (0x900),
  the pattern (0x11C, 0x120..), blits and the font register. Never the TEC
  (but `cg6_reset_uregs`' bzero of TEC +4..+7), triangles or relative
  vertices. SunView's binaries are dynamically linked to
  `libpixrect.so.2.11`, the same code.

### What is built

* **The engine** (`sun3_cg6_engine.sv`) draws, besides stage 1's rectangles,
  font rows and blits:
  * **lines**: Bresenham from the left end, the error from -(major/2), as
    runs of pixels a row (a pixel a row when steep), one pixel a clock;
  * **triangles and quadrilaterals** of 2..4 vertices: Sun's edge DDA
    (`cg6model.c`'s `edge_setup`, `edge_step`), each edge set up in turn
    (an 18-step divider for |dx| / dy; q * dy and (q >> 1) * dy from the
    remainder, so no multiplier), then each row: the active edges' x
    sorted (a 4-input network over three clocks), one or two spans, and
    every edge stepped in two clocks;
  * **the pattern**: RASTEROP's pattern field 3 takes s from PATTERN0..7
    by PATTALIGN, a row turned by the x alignment once a row.

  Lines and polygons are generators: each hands its spans to the row
  machinery the rectangle uses, which clips each as it takes it.
* **The register file** (`sun3_cg6.sv`):
  * the vertex queue keeps its last four vertices in a ring; DRAWSTATUS
    copies the ones the primitive draws (a polygon's last k, 2..4) for the
    engine, so a line's kept end vertex can move to the ring's slot 0 at
    once;
  * PATTERN0..7 in registers, read back;
  * **a register store**, an M10K of 1,024 words, for what is only stored:
    FBC z and colour, the indexed registers (0x800..0x93C, read back as
    written), the THC's timing and cursor planes, and the TEC's 0x000..0x1FC
    and 0x800..0xDFC, the data registers' second bank while VDC's type is 5.
    A read from it takes a clock more;
  * the cursor: its place in a register, its planes in the store and again
    in two 32x32 RAMs read on the pixel clock.
* **The scan-out** (`sun3_cg4_scanout.sv`): the cursor, in front of the
  colour. A row of both planes is asked for a line ahead; where a pixel's A
  or B bit is set it is overlay colour {B, A}, each bit gated by the
  command register's overlay enable, as the Bt458's OL inputs are. The cg4
  leaves it off the screen (`sun3_fpga.v`: 0xFFE0FFE0 unless the GX is in).
* **Burst writes**: the engine writes a whole burst, a select a byte,
  through the adapter's engine port, and `rtl/sdram.sv` has one new path,
  `wrb`: eight single-word WRITEs on consecutive clocks to the aligned
  group in the open row, each with its own DQM. The chip stays in
  single-write mode, so no other client's cycles change. A full-screen fill
  beside the colour scan-out takes 28.6 ms (36 Mpixel/s), against stage 1's
  75 ms.
* `sun3_top.v`, `sun3_fpga.v` and `Sun-3.sv` carry the cursor's four
  signals and the engine port's new widths, nothing else.

### Where it differs from the model

* **A line's or polygon's vertices are saturated to 16 bits** as the
  rectangle's are; the model computes in 32. Only a vertex beyond
  +-32,767 draws differently, and nothing Sun's code sends is that far out
  (libpixrect clips first). The `-G` generator keeps them inside.
* The TEC's arithmetic (built since: *The TEC in the core*), pick mode, z,
  "linear" raster mode, the polygon
  overlap flag and the clipcheck register's meaning are still not built.

### How it is checked

* **`tb_cg6`**: the traces now hold everything stage 2 draws:
  * `-G`'s generator has lines and polylines (every slope, horizontal,
    vertical, diagonal, off the screen), triangles and quadrilaterals (a
    point first or not, more vertices queued than drawn, horizontal edges),
    patterns and alignments in every drawing, and the stored registers
    written and read back (each read only after the run wrote it, since the
    store is a RAM a reset does not clear);
  * the SPARC libpixrect's tests of every kind (`-K` dropped: vectors,
    replrop, polygons and polylines join the fills, copies and text);
  * **the sun3 4.1.1 68020 libpixrect's** tests of every kind, through
    `harness68k` (*The 68020 run*), when that library is in `build/dist/`
    (`CG6_MUSASHI=` a Musashi checkout, else it is fetched);
  * every pixel compared at the end, and every register read on the way:
    all but the THC's misc now;
  * a whole frame with the cursor across a rectangle's corner (overlay
    colours 1, 2 and 3), one partly off the screen's top left with OL0
    alone enabled, and one hidden at (-32, -32).

  `-G` also ends with quadrilaterals random ones seldom are: bow ties and
  arrowheads (rows across four edges), edges at 45 degrees, and slivers
  whose edges' set-up error is exactly 0.
  7,851 checks pass: `t_gen` 11,670 accesses (97 lines, 36 triangles, 81
  quadrilaterals), the SPARC library's 75,207 and the 68020's 106,373.
* **`mutate_cg6.sh`**: 83 mutants of the register file, the engine and the
  scan-out's cursor (46 of them new: the pattern, lines, polygons, the
  store, the TEC's banks, the cursor, the burst's selects), all caught.
  Three that could not be (a 45-degree line is the same pixels x- or
  y-major; an edge stepped after its last row, or a horizontal edge kept,
  is never seen) were replaced. It runs mutants in parallel (`JOBS=n`),
  and tb_cg6 stops at its first failure under it (`+failfast`).
* **`tb_vint`** runs the cgsix driver's colour-map loads through the THC's
  interrupt: 55 updates begun all through the frame, each one level-4
  entry at a vertical blank's start, none spurious, and with the THC's
  enable off no level 4 though the retrace still sets pending.
  `mutate_vint.sh` builds with the GX.
* **`tb_mister_sdram`** writes whole engine bursts of random selects, reads
  them back through the engine and the CPU, and times 64 of them back to
  back: 779 clocks, 12 a burst. `mutate_sdram.sh` mutates the controller's
  new path as well as the adapter's: 29 mutants, all caught.
* **`tb_emu`** with the GX (`ROM=build/rom/sun3_60_v3.0.1_fast.bin`,
  `+status=80000`): the 3.0.1 banner, `Model Sun-3/60C/G`, whole by 1.36 s
  simulated, then `Auto-boot in progress...`, as in stage 1. A SunOS boot
  is too slow to simulate; what the kernel does with the board is checked
  in tb_vint (the colour map through the THC's interrupt) and tb_cg6 (the
  cursor as `cg6_setcurshape` loads it, and every register
  `cg6_cntxsave` reads, read back).

### OpenWindows 2.0 and the TEC

*Built since: The TEC (the spec, from xnews) and The TEC in the core.
What follows is the stage-2 finding that led there.*

OpenWindows 2.0's sun3 `xnews` (on the 4.1.1 tape) was disassembled
(capstone; scripts kept out of the tree). **It uses the TEC's arithmetic on
every GX, and nothing switches it off** (**verified**):

* `_sunfb_open` takes FBTYPE 12 to `_sh_init_cg6`, with no CPU, revision,
  option or environment check. That maps FBC+TEC, sets MV = 0x112 (a 3x2
  matrix at data register 0x12), VDC = 0x200C then type 1 (16.16 fixed),
  clipcheck 0, and identity matrices at data registers 0x12 and 0x22.
* **As a matrix coprocessor**: every PostScript `concat`, point and path
  transform: matrices into the data registers (`_sh_lego_load_trans_2d`,
  `_lego_load_mv`, 2x3 or 4x4, MV 0x612 / 0x8712 with divide), a command
  at +0x10 (0x90322236 and kin: a 1x3 row at 0x32 times the matrix at 0x22
  or 0x12, the result at 0x36), inputs written at VDC type fixed and the
  results read back at type float: **the data registers convert between
  integer, 16.16 and IEEE single on access**.
* **As the vertex front end** for `_sh_lg_Path_Raster`: X11 polygons, arcs,
  wide lines, and every NeWS fill and stroke write the fixed (0xA00..) and
  float (0xC00..) point, line and quad registers with MV's autoload on; the
  TEC is meant to transform them into the FBC's queue. Even at identity the
  vertices go through it. It never writes the integer vertex registers,
  triangles, rectangles or W, never uses the VDC multiply or the clip
  planes, and its 3D renderers are stubs (an `SH_SMALL` build).
* **Not through the TEC**: rectangle fills and window clears (FBC 0x900),
  thin lines (0x840), text and glyphs (the font register), blits. So xterm,
  olwm's frames and text would look right.
* **With the core's register-store TEC**, transforms read back stale or zero
  data registers, and vertices written to 0xA00/0xC00 never reach the FBC:
  NeWS graphics and X11 polygons, arcs and wide lines are missing or wrong.
  Clipcheck reads 0, so xnews never falls back to software; an exception on
  everything would not help either, since only `_mul_transform` has a clean
  software path.

**What a TEC would cost** (estimates, no fit):

| | does | ALMs | DSP | M10K |
|---|---|---|---|---|
| pass-through | fixed and float to integer, a translation, into the FBC queue | 400-700 | 0 | 0 |
| **2D affine** | one IEEE single multiply-add, converters on data-register access, the command sequencer (1x3 x 3x2, up to 1x4 x 4x4), autoload, clipcheck 31 on overflow | **1,800-2,800** | 1-2 | 0-1 |
| full | the above and divide, VDC multiply, clip planes and accumulators | 3,500-5,000 | 2-4 | 1-2 |

The pass-through is not enough: every non-identity matrix and every point
transform would still be wrong. **The 2D affine subset is what this xnews
needs**, and fits. It is not built here: it is a stage of its own, and its
details (relative vertices, rounding of float and fixed to integer, what
raises an exception) need a TEC trace of `openwin` on the board first, and a
C reference in `tools/cg6model` judged against xnews's own software
transforms (`_mul_transform` at 0x62dcc, `_sh_fb_Path_Transform` at
0x5cbe4). Until then OpenWindows 2.0 wants the cg4 in the P4 slot.

### Area (a guess; no fit yet)

| block | ALMs | M10K |
|---|---|---|
| vertex ring and DRAWSTATUS copy, pattern registers | 350-450 | |
| register store, cursor RAMs and read path | 100-150 | 4 + 2 (or MLABs) |
| line generator | 150-200 | |
| polygon generator: four edges' state and stepping, divider, sort | 900-1,300 | |
| pattern source | 80-120 | |
| burst write: engine, adapter, controller | 150-250 | |
| scan-out cursor | 60-100 | |
| **total, over stage 1** | **1,800-2,550** | **about 6** |

Stage 1's fit was 29,962 ALMs (71%); this makes 31.8-32.5k (76-78%).

### On the board

With *Colour board type* GX, SunOS 4.1.1_U1 installed:
1. The boot: `cgsix0 at obmem 0xff000000 pri 4`, the console as before.
2. `sunview` from the console login. The gray desktop (a replrop: the
   pattern), the console and a shelltool, and **the mouse pointer, a
   hardware cursor**: it must show, in black and white, and move smoothly.
3. In a shelltool: `cat /etc/termcap` (text and scrolling: the font
   register and blits), and the time of 2,000 lines of it against the cg4.
4. The demos in `/usr/demo` (SUNVIEW): `spheresdemo` (polygons and the
   colour map), `jumpdemo`, `bouncedemo`, `framedemo` (colour maps,
   blits), `suncube` (lines), and `gfxtool` running `shaded` or `rotobj`.
   `perfmeter`, `clock` (lines), `iconedit` (patterns, the pixel mask).
5. Open and close many tools, drag windows over each other, and change the
   colour map (a colour demo started and stopped): the context switch, and
   one level-4 interrupt per colour-map load.
6. `sunview -8bit_color_only`, and the plain colour desktop
   (`sunview` with `-background`/`-pattern` options from `sunview(1)`).
7. `/usr/diag/sundiag/cg6test` if it runs from the console.
8. OpenWindows 2.0 (`openwin`) only to see that xterm/olwm draw, and that
   NeWS graphics do not (above).

### What stage 3 and 4 need

* **Stage 3** (pixrect speed and the board's verdict): the tests above;
  the font FIFO (libpixrect's text is a FONT write a row); `mono SunView,
  2,000 lines of termcap` against the cg4; perhaps a destination-read
  burst buffer for line pixels (a line is a read-modify-write a pixel).
* **Stage 4** (X11): MIT Xsun's `sunGX.c` (relative vertices and triangles
  are built and in the `-G` traces, never yet driven by real code). The
  TEC for OpenWindows 2.0 is built since (*The TEC in the core*).

## The TEC in the core

**Status (2026-10-23, Verilator only; not yet on the board):** the TEC as
*The TEC* specifies it, for OpenWindows 2.0's xnews.

### What is built

* **`sun3_cg6_tec.sv`**, inside `sun3_cg6.sv`, **on the CPU's clock**. The
  register file is there, and the TEC's work is a few dozen clocks a
  vertex, which the CPU waits for anyway before its next FBC cycle (a
  DRAWSTATUS read): on `clk_mem` it would be three times faster but need
  a clock crossing for every data register access and for the autoloaded
  vertex into the queue, and the CPU's clock has the slack (every stage a
  register at 30 ns). Nothing of it crosses a clock: its outputs to the
  register file (busy, the read's value, the autoloaded vertex and its
  kind) are registers, and the queue the vertex goes into is copied by the
  engine on `clk_mem` when it takes a command, as every other vertex is.
  It has:
  * the 64 data registers, IEEE single, in one M10K, read and written
    converted by VDC's type (bank 1, type 5, stays in the register file's
    store);
  * MV and VDC's type; COMMAND1;
  * one multiply (24 x 24 bits: one DSP), one add (align, add or
    subtract), one normalise-and-round they share, and the conversions to
    and from integer and 16.16 (the normaliser for integers in, one
    floor-and-saturate for integers out);
  * a sequencer: a vertex's x converted, y z w read, then for each column
    each term multiplied, rounded, added, rounded, the relative vertex's
    last result added, the result written; with autoload data 4 and 5
    rounded down and handed to the register file (`av`). A command loads
    A, then the same columns.
* **`sun3_cg6.sv`**: every TEC write goes to the TEC (and the store, for
  reading back), and bank 0's reads come from it. While it is busy every
  TEC and FBC cycle waits (`tstall`): a read until its value is ready, a
  DRAWSTATUS until the autoloaded vertex is queued. A write is answered at
  once and the TEC works on (the CPU runs on until its next TEC or FBC
  cycle). TEC cycles also wait for the drawing engine, as FBC writes do,
  so an autoloaded vertex never lands while the engine reads the queue's
  copy. The autoloaded vertex goes into the queue as a CPU's would (a new
  queue but for a point before triangle or quadrilateral vertices), with
  the raster offset added. **MISC's index** (5:4) reads `nv mod 4`.
* A 2D vertex (3 x 2, with autoload) takes 70 CPU clocks from its x's
  write to the answer of the DRAWSTATUS read after it (`tb_cg6`'s directed
  test): 2.1 us at 33 MHz, 4.2 at 16.7. xnews's own loop between two
  vertices is of that order, so a line or fill vertex is perhaps half as
  fast again as with a TEC that took no time. If the board shows that it
  matters: the multiply of a term can run while the add before it does
  (a second normaliser, 150-200 ALMs), about 35 clocks.

### Where it differs from the model

Nowhere the bench can see: the model's TEC (`cg6model.c`, `tec_*`) is the
RTL's arithmetic, step for step, and the bench compares every TEC
register read and every pixel. Its denormals, infinities and rounding are
checked against the host's IEEE single for normal values (`xnews68k -T`).

### Left out

MV's divide (3D canvases), the VDC multiply and its matrix, the clip
planes, clipcheck's results and TEC exceptions (STATUS bit 30 reads 0),
COMMAND2..4 (stored), the command's identity bits, NaNs. All are unused by
xnews 2.0 on a 2D screen (*The TEC*). The data registers' type 4 is the
IEEE single as it is, not whatever wider form a real TEC has inside.

### How it is checked

* **`xnews68k`** (*The TEC's check*): xnews's own transforms and drawing
  routines against the model, and against xnews's software and the exact
  result.
* **`tb_cg6`** replays, besides the PROM's, the generator's and the two
  libpixrect traces:
  * **`t_xn`**, `xnews68k`'s trace (`tracexn`, 300 tests): every TEC and
  FBC access xnews's routines make, its TEC reads compared and its
  frame buffer at the end;
  * the generator's (`-G`) new **TEC tests**: data registers written and
  read in types 0, 1, 2 and 4, specials and saturation included; vertex
  registers of every kind and object, absolute and relative, through
  every MV shape (3 or 4 rows, 1..4 columns, h and z); autoload into
  every primitive, drawn; COMMAND1 for every m and n, anywhere in the 64
  (519 vertices, 272 autoloaded, 68 commands at the default 400 tests),
  and lines that begin with an FBC point;
  * a directed TEC line through a scaling matrix, drawn, its results read
  back in 16.16, and timed; the rounding random operands seldom reach (a
  product whose only sticky bit is in its low 12, one that rounds up to
  infinity, inf - inf); an FBC point then a line vertex; and the two
  banks' test, with type 0's conversion.
* **`mutate_cg6.sh`**: 36 mutants of the TEC and its place in the
  register file (rounding, saturation, the sticky bits, the alignment,
  infinities, MV's fields, relative vertices, autoload, the command's
  fields, the types' conversions, the second bank, the stall, MISC's
  index) and one of the point-then-line rule, all caught
  (`mutate_cg6.sh "TEC\|a point not"`). Four were caught only once the
  directed cases above were added: the low sticky bits, overflow at
  exactly 255, inf - inf, and a CPU's point before a line.

### Area (a guess; no fit yet)

| block | ALMs | DSP | M10K |
|---|---|---|---|
| the multiply's operands, exponents and specials | 60-90 | 1 | |
| the add: compare, align (27 bits), add/subtract | 180-250 | | |
| normalise (36-bit count and shift) and round | 160-220 | | |
| float to integer or 16.16 (one) | 100-150 | | |
| the operands and results (4 + 3 words), sequencer | 250-350 | | |
| data registers | | | 1 |
| the register file: stalls, the autoloaded vertex into the queue | 60-100 | | |
| **total** | **800-1,150** | **1** | **1** |

### On the board

With *Colour board type* GX and SunOS 4.1.1_U1, `openwin` from the
console login:
1. The desktop: olwm's frames and menus (FBC rectangles, lines and text,
   not the TEC), the workspace pattern, the pointer.
2. **NeWS through the TEC** (`/usr/openwin/demo`, run with `psh`): `lines`
   and `vectors` (thin strokes, `_sh_lg_vec_2U`), `poly`, `piechart`,
   `colorwheel` and `world` (fills: fans of quadrilaterals), `spiral`,
   `rubber`, `spin` and `flyinglogos` (rotated and scaled paths, matrices
   in the TEC), `widedemo` (wide lines, as fills), `roundclock` and
   `monaeyes` (arcs and curves, `_xform_conic`), `fish`, `scaledtext`.
   Each should look as it does on the cg4; a shape off by a pixel at its
   edges, or a fill that misses a sliver along a fan's diagonal, is the
   rounding.
3. **X11 through the TEC**: `ico` and `ico2` (polygons), `plaid`
   (rectangles: not the TEC), `maze`, `muncher` and `worm` (lines),
   `puzzle`, `xsol`, `gammon`, `xcalc`, `xlock`.
4. `xterm` and text (not the TEC), window moves and resizes (blits).
5. Against the cg4 in the same slot: the same demos side by side for
   exactness, and `xnews_uptime`-style timings of `lines` for speed.
