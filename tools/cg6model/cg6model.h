/*
 * cg6model: the P4 GX (cg6) of a Sun-3/60 as its software sees it.
 * docs/cg6.md is the specification; this is that specification as code.
 *
 * Addresses are offsets in the board's 16 MiB P4 window (physical
 * 0xFF000000 + offset on a 3/60, `cgsix0 at obmem ? csr 0xff000000'):
 *
 *   0x200000  Bt458 DAC: address, colour map, control, overlay map (+0..+0xC),
 *             on data bits 31:24
 *   0x240000  DHC (not modelled: reads 0)
 *   0x280000  ALT (not modelled: reads 0)
 *   0x300000  FHC configuration register (and the P4 ID, bits 31:24)
 *   0x301000  THC: video timing, misc (vsync, interrupt), hardware cursor
 *   0x380000  the board's ROM (64 KiB; not modelled: reads 0)
 *   0x700000  FBC: the drawing engine's registers
 *   0x701000  TEC: the transform engine: data registers that convert by
 *             VDC's type, vertices through the MV matrix (and on to the FBC
 *             with autoload), COMMAND1's matrix product
 *   0x800000  the frame buffer, 1 MiB, a byte a pixel, 1152 a line
 *
 * The engine is instantaneous: a command does its whole work when it is
 * accepted.  `busy_polls' makes it look busy for that many reads of the
 * status registers afterwards, and refuse (FULL) new commands meanwhile,
 * so that software's wait loops are exercised.
 */
#ifndef CG6MODEL_H
#define CG6MODEL_H
#include <stdint.h>

#define CG6_W		1152
#define CG6_H		900
#define CG6_FBSIZE	0x100000

#define CG6_DAC		0x200000
#define CG6_DHC		0x240000
#define CG6_ALT		0x280000
#define CG6_FHC		0x300000
#define CG6_THC		0x301000
#define CG6_ROM		0x380000
#define CG6_FBC		0x700000
#define CG6_TEC		0x701000
#define CG6_FB		0x800000

/* FBC register offsets (Solaris <sys/cg6fbc.h>) */
#define FBC_CONFIG	0x000
#define FBC_MISC	0x004
#define FBC_CLIPCHECK	0x008
#define FBC_STATUS	0x010
#define FBC_DRAWSTATUS	0x014
#define FBC_BLITSTATUS	0x018
#define FBC_FONT	0x01c
#define FBC_X0		0x080		/* x0 y0 z0 color0 ... x3 y3 z3 color3 */
#define FBC_Y0		0x084
#define FBC_X1		0x090
#define FBC_OFFX	0x0c0
#define FBC_OFFY	0x0c4
#define FBC_INCX	0x0d0
#define FBC_INCY	0x0d4
#define FBC_CLIPMINX	0x0e0
#define FBC_CLIPMINY	0x0e4
#define FBC_CLIPMAXX	0x0f0
#define FBC_CLIPMAXY	0x0f4
#define FBC_FCOLOR	0x100
#define FBC_BCOLOR	0x104
#define FBC_RASTEROP	0x108
#define FBC_PLANEMASK	0x10c
#define FBC_PIXELMASK	0x110
#define FBC_PATTALIGN	0x11c
#define FBC_PATTERN	0x120		/* 8 words: 16 rows of 16 bits */
#define FBC_IPOINT	0x800		/* point line tri quad rect, 0x40 apart */

/* status bits (STATUS, DRAWSTATUS, BLITSTATUS) */
#define FBC_S_EXCEPTION	0x80000000u
#define FBC_S_FULL	0x20000000u
#define FBC_S_BUSY	0x10000000u

/* THC misc (Solaris <sys/cg6thc.h>) */
#define THC_MISC_REV_SHIFT 16
#define THC_MISC_RESET	0x1000
#define THC_MISC_VIDEO	0x0400
#define THC_MISC_SYNC	0x0200
#define THC_MISC_VSYNC	0x0100
#define THC_MISC_SYNCEN	0x0080
#define THC_MISC_CURRES	0x0040
#define THC_MISC_INTEN	0x0020
#define THC_MISC_INT	0x0010

enum { PRIM_POINT, PRIM_LINE, PRIM_TRI, PRIM_QUAD, PRIM_RECT, PRIM_NONE };

struct cg6 {
	uint8_t fb[CG6_FBSIZE];

	/* FHC */
	uint32_t fhc;			/* the writable bits 19:0 */
	int fhc_rev;			/* bits 23:20 */

	/* THC */
	uint32_t thc_timing[6];		/* hchs hchsdvs hchd hcvs hcvd hcr */
	uint32_t thc_misc;		/* bits written: video, syncen, curres, inten, cycles */
	int thc_int;			/* the retrace interrupt pending */
	int vsync;			/* the raster is in vertical sync */
	uint32_t cursxy, cursa[32], cursb[32];

	/* Bt458 */
	uint8_t dac_addr, dac_step;	/* address, and which of r g b is next */
	uint8_t cmap[256][3], omap[4][3], dac_ctrl[4];	/* ctrl: read mask, blink, command, test */
	uint8_t dac_rgb[3];		/* a colour entry being assembled */

	/* FBC */
	uint32_t misc, clipcheck, font;
	int32_t x[4], y[4], z[4];
	uint32_t color[4];
	int32_t offx, offy, incx, incy;
	int32_t clipminx, clipminy, clipmaxx, clipmaxy;
	uint32_t fcolor, bcolor, rasterop, planemask, pixelmask, pattalign, pattern[8];
	uint32_t vreg[0x140 / 4];	/* what was last written to each indexed register */

	/* the vertex queue the indexed registers fill */
	int prim, nv;
	int32_t vx[64], vy[64];
	int32_t pend_x, pend_y;		/* a vertex's coordinates so far */
	int pend;			/* which: 1 x, 2 y */

	/* TEC (docs/cg6.md, "The TEC"): tec[] what was written to each
	   register; the 64 data registers (0x100..0x1FC) are tec_data, IEEE
	   single, converted on access by VDC's type (15:13), and a second bank
	   tec_data1, raw, while the type is 5 (INTRNL1): the kernel's
	   cg6_cntxsave reads all 64 with VDC 0x8000 and again with 0xA000 */
	uint32_t tec[0x1000 / 4];
	uint32_t tec_data[64];
	uint32_t tec_data1[64];

	/* the model's own: busy emulation and statistics */
	int busy_polls, busy;
	unsigned long ndraw[PRIM_NONE], nblit, nfont, npix;
	unsigned long nfull;		/* commands refused while busy */
	unsigned long ntec_vertex, ntec_auto, ntec_cmd;
	/* a hook for the harness: every register access */
	void (*trace)(void *, int wr, uint32_t off, int size, uint32_t v);
	void *trace_arg;
};

void cg6_reset(struct cg6 *);
uint32_t cg6_read(struct cg6 *, uint32_t off, int size);	/* size 1, 2, 4 */
void cg6_write(struct cg6 *, uint32_t off, int size, uint32_t v);
/* the raster: vsync on or off; the THC's interrupt goes pending at its start */
void cg6_vsync(struct cg6 *, int on);
int cg6_irq(const struct cg6 *);		/* the P4 interrupt line, active high */
/* the picture: what the DAC puts out for pixel (x, y), with the cursor */
uint32_t cg6_rgb(const struct cg6 *, int x, int y);

/* the TEC's arithmetic (IEEE single, as cg6model.c says), for the harness */
uint32_t tec_fmul(uint32_t a, uint32_t b);
uint32_t tec_fadd(uint32_t a, uint32_t b);
uint32_t tec_i2f(uint32_t v, int fbits);	/* fbits 0 integer, 16 fixed */
uint32_t tec_f2i(uint32_t v, int fbits);	/* toward minus infinity */

/* the raster-op unit, for one byte: exposed for the harness's reference */
uint8_t cg6_rop8(uint32_t rasterop, uint8_t f, uint8_t b, uint8_t s, uint8_t d);

#endif
