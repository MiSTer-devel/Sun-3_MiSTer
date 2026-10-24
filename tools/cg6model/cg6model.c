/*
 * cg6model: the P4 GX as its software sees it (cg6model.h, docs/cg6.md).
 *
 * The rules each piece follows, and where each one comes from, are in
 * docs/cg6.md; the comments here only point at them.
 */
#include <stdint.h>
#include <string.h>
#include "cg6model.h"

/* ---- the raster-op unit (docs/cg6.md, "Raster ops") ---- */

/*
 * RASTEROP bits 15:0 are a truth table over four inputs, one bit plane at
 * a time: the foreground colour's bit f, the background colour's bit b, the
 * source's bit s and the destination's bit d, indexed f*8 + b*4 + s*2 + d.
 * (Solaris names the four nibbles rop11 rop10 rop01 rop00 by f and b.)
 */
uint8_t cg6_rop8(uint32_t rop, uint8_t f, uint8_t b, uint8_t s, uint8_t d)
{
	uint8_t r = 0;

	for (int i = 0; i < 8; i++) {
		int k = (f >> i & 1) << 3 | (b >> i & 1) << 2 | (s >> i & 1) << 1 | (d >> i & 1);

		r |= (rop >> k & 1) << i;
	}
	return r;
}

/*
 * a 2-bit field of MISC or RASTEROP: 0 written means "leave it as it is".
 * `fields' has each field's low bit; MISC's are at odd bits, RASTEROP's at
 * even ones, so every bit is looked at (stepping by two from 0 once missed
 * all of MISC's but the blit field).
 */
static uint32_t merge_fields(uint32_t old, uint32_t v, uint32_t fields)
{
	for (int sh = 0; sh < 31; sh++)
		if (fields >> sh & 1 && (v >> sh & 3) == 0)
			v = (v & ~(3u << sh)) | (old & 3u << sh);
	return v;
}

/* MISC's 2-bit fields: blit 21:20, data 18:17, draw 16:15, bwrite0 14:13,
   bwrite1 12:11, bread 10:9, bdisp 8:7 (the low bit of each, as a mask) */
#define MISC_FIELDS	(1u << 20 | 1u << 17 | 1u << 15 | 1u << 13 | 1u << 11 | 1u << 9 | 1u << 7)
/* RASTEROP's: plane 31:30, pixel 29:28, pattern 27:26, polygon 25:24, attr 23:22 */
#define ROP_FIELDS	(1u << 30 | 1u << 28 | 1u << 26 | 1u << 24 | 1u << 22)

#define MISC_DATA(g)	((g)->misc >> 17 & 3)	/* 1 colour8, 2 colour1, 3 hrmono */
/* MISC 19: a vertical blank has begun since 1 was last written to it
   (docs/cg6.md, "Status and timing"); xnews's _install_cmap waits on it */
#define MISC_VBLANK	0x80000u
#define ROP_PLANE(g)	((g)->rasterop >> 30 & 3)
#define ROP_PIXEL(g)	((g)->rasterop >> 28 & 3)
#define ROP_PATT(g)	((g)->rasterop >> 26 & 3)

static uint8_t planes(const struct cg6 *g)
{
	switch (ROP_PLANE(g)) {
	case 1: return 0;
	case 3: return g->planemask;
	default: return 0xff;
	}
}

static int inclip(const struct cg6 *g, int32_t x, int32_t y)
{
	return x >= g->clipminx && x <= g->clipmaxx && y >= g->clipminy && y <= g->clipmaxy &&
	       x >= 0 && y >= 0 && (uint32_t)(y * CG6_W + x) < CG6_FBSIZE && x < CG6_W;
}

/* the pixel mask: bit 31 - i enables pixel i of the 32 it covers */
static int pixel_enabled(const struct cg6 *g, int i)
{
	switch (ROP_PIXEL(g)) {
	case 1: return 0;
	case 3: return g->pixelmask >> (31 - (i & 31)) & 1;
	default: return 1;
	}
}

/*
 * The pattern's bit at (x, y): 16 rows of 16, two rows a register (the
 * upper half first), bit 15 leftmost.  PATTALIGN's x (bits 31:16) and y
 * (15:0) are added to the pixel's: the pattern's (0, 0) is at
 * (-alignx, -aligny) modulo 16 (docs/cg6.md, "Patterns").
 */
static int pattern_bit(const struct cg6 *g, int32_t x, int32_t y)
{
	int ax = g->pattalign >> 16 & 15, ay = g->pattalign & 15;
	int row = (y + ay) & 15, col = (x + ax) & 15;
	uint32_t w = g->pattern[row >> 1];

	w = row & 1 ? w & 0xffff : w >> 16;
	return w >> (15 - col) & 1;
}

static uint8_t pattern_src(const struct cg6 *g, int32_t x, int32_t y)
{
	switch (ROP_PATT(g)) {
	case 1: return 0;
	case 3: return pattern_bit(g, x, y) ? 0xff : 0;
	default: return 0xff;
	}
}

/*
 * One pixel through the raster-op unit, with the clip, pixel and plane
 * masks.  pmi is the pixel's place in the pixel mask: for drawing and blits
 * its column within a 32-pixel-aligned group, for the font register its
 * place in the run of pixels since PIXELMASK was written (docs/cg6.md).
 */
static void plot_m(struct cg6 *g, int32_t x, int32_t y, uint8_t s, int pmi)
{
	uint8_t *p, pm;

	if (!inclip(g, x, y) || !pixel_enabled(g, pmi))
		return;
	p = &g->fb[y * CG6_W + x];
	pm = planes(g);
	*p = (cg6_rop8(g->rasterop, g->fcolor, g->bcolor, s, *p) & pm) | (*p & ~pm);
	g->npix++;
}

static void plot(struct cg6 *g, int32_t x, int32_t y, uint8_t s)
{
	plot_m(g, x, y, s, x & 31);
}

/* ---- drawing (docs/cg6.md, "Drawing") ---- */

static void draw_rect(struct cg6 *g, int32_t x0, int32_t y0, int32_t x1, int32_t y1)
{
	if (x1 < x0 || y1 < y0)
		return;
	if (x0 < g->clipminx) x0 = g->clipminx;
	if (y0 < g->clipminy) y0 = g->clipminy;
	if (x1 > g->clipmaxx) x1 = g->clipmaxx;
	if (y1 > g->clipmaxy) y1 = g->clipmaxy;
	for (int32_t y = y0; y <= y1; y++)
		for (int32_t x = x0; x <= x1; x++)
			plot(g, x, y, pattern_src(g, x, y));
}

/*
 * A line: Bresenham, both end points drawn, stepping along the major axis
 * from the first vertex.  docs/cg6.md, "Lines", on how this was matched
 * against mem_vector.
 */
static void draw_line(struct cg6 *g, int32_t x0, int32_t y0, int32_t x1, int32_t y1)
{
	if (x1 < x0) {			/* drawn left to right */
		int32_t t = x0; x0 = x1; x1 = t;
		t = y0; y0 = y1; y1 = t;
	}
	int32_t dx = x1 - x0, dy = y1 - y0, sx = dx < 0 ? -1 : 1, sy = dy < 0 ? -1 : 1;
	int32_t adx = dx < 0 ? -dx : dx, ady = dy < 0 ? -dy : dy;

	if (adx >= ady) {
		int32_t e = -(adx >> 1);
		for (int32_t i = 0, x = x0, y = y0; i <= adx; i++, x += sx) {
			plot(g, x, y, pattern_src(g, x, y));
			e += ady;
			if (e > 0 && i < adx) {
				y += sy;
				e -= adx;
			}
		}
	} else {
		int32_t e = -(ady >> 1);
		for (int32_t i = 0, x = x0, y = y0; i <= ady; i++, y += sy) {
			plot(g, x, y, pattern_src(g, x, y));
			e += adx;
			if (e > 0 && i < ady) {
				x += sx;
				e -= ady;
			}
		}
	}
}

/*
 * A filled triangle or quadrilateral, scan-converted as libpixrect's own
 * pr_polygon_2 (pr_polygon2.c 1.27) does it in memory, so that the board
 * and the library's software fallback draw the same pixels: an edge table,
 * each edge active on rows y0 .. y1-1 with its x walked by an integer DDA,
 * and on each row the pixels from one edge's x up to, not including, the
 * next one's, pairing edges in x order.  docs/cg6.md, "Polygons", has the
 * walk written out and where it came from.
 */
struct edge { int32_t y0, y1, x, step, dx, dy, err; };

static void edge_setup(struct edge *e, int32_t xa, int32_t ya, int32_t xb, int32_t yb)
{
	if (ya > yb) {
		int32_t t = xa; xa = xb; xb = t;
		t = ya; ya = yb; yb = t;
	}
	e->y0 = ya;
	e->y1 = yb;
	e->x = xa;
	e->dy = yb - ya;
	e->dx = xb - xa;
	if (e->dx >= 0) {
		e->step = e->dx / e->dy;
		if (e->dy >= e->dx)
			e->err = -(e->dy >> 1);
		else {
			e->err = (e->step >> 1) * e->dy - (e->dx >> 1);
			if (e->err <= 0) {
				e->err += e->dy;
				e->x += 1;
			}
			e->err -= e->dx;
			e->x += e->step >> 1;
		}
	} else {
		e->step = -((-e->dx) / e->dy);
		if (e->dy >= -e->dx)
			e->err = -(e->dy >> 1);
		else {
			e->err = ((-e->step) >> 1) * e->dy - ((-e->dx) >> 1);
			if (e->err <= 0) {
				e->err += e->dy;
				e->x -= 1;
			}
			e->err += e->dx;
			e->x += ((e->step + 1) >> 1) + 1;
			e->err = e->dx + e->step * e->dy - e->err;
			if (e->dy & 1)
				e->err += 1;
		}
	}
}

static void edge_step(struct edge *e)
{
	if (e->dx >= 0) {
		if (e->dy < e->dx) {
			e->x += e->step;
			e->err += e->dy * e->step;
			if (e->err <= 0) {
				e->err += e->dy - e->dx;
				e->x += 1;
			} else
				e->err -= e->dx;
		} else {
			e->err += e->dx;
			if (e->err > 0) {
				e->err -= e->dy;
				e->x += 1;
			}
		}
	} else {
		if (e->dy < -e->dx) {
			e->x += e->step;
			e->err -= e->dx;
			if (e->err > 0) {
				e->x -= 1;
				e->err -= e->dy;
			}
			e->err += e->dy * e->step;
		} else {
			e->err += e->dx;
			if (e->err <= -e->dy) {
				e->err += e->dy;
				e->x -= 1;
			}
		}
	}
}

static void draw_poly(struct cg6 *g, const int32_t *vx, const int32_t *vy, int n)
{
	struct edge e[4];
	int ne = 0;
	int32_t ymin = INT32_MAX, ymax = INT32_MIN;

	for (int i = 0; i < n; i++) {
		int j = (i + 1) % n;
		if (vy[i] == vy[j])
			continue;		/* horizontal: no edge */
		edge_setup(&e[ne], vx[i], vy[i], vx[j], vy[j]);
		if (e[ne].y0 < ymin) ymin = e[ne].y0;
		if (e[ne].y1 > ymax) ymax = e[ne].y1;
		ne++;
	}
	for (int32_t y = ymin; y < ymax; y++) {
		int32_t xs[4];
		int na = 0;

		for (int i = 0; i < ne; i++)
			if (y >= e[i].y0 && y < e[i].y1)
				xs[na++] = e[i].x;
		for (int i = 1; i < na; i++)		/* in x order */
			for (int j = i; j > 0 && xs[j - 1] > xs[j]; j--) {
				int32_t t = xs[j]; xs[j] = xs[j - 1]; xs[j - 1] = t;
			}
		for (int i = 0; i + 1 < na; i += 2)
			for (int32_t x = xs[i]; x < xs[i + 1]; x++)
				plot(g, x, y, pattern_src(g, x, y));
		for (int i = 0; i < ne; i++)
			if (y >= e[i].y0 && y + 1 < e[i].y1)
				edge_step(&e[i]);
	}
}

static int need(int prim)
{
	static const int n[] = { 1, 2, 3, 4, 2 };
	return n[prim];
}

/*
 * DRAWSTATUS read: draw the primitive the queued vertices make, from the
 * last ones queued.  A line leaves its end point queued, so the next
 * vertex draws on from it (docs/cg6.md, "Vertices").
 */
static void draw(struct cg6 *g)
{
	int n = g->nv, k, keep = 0;
	int32_t *vx, *vy;

	if (g->prim == PRIM_NONE)
		goto done;
	k = need(g->prim);
	if ((g->prim == PRIM_TRI || g->prim == PRIM_QUAD) && n >= 2 && n < k)
		k = n;			/* a polygon of fewer vertices */
	if (n < k)
		goto done;
	vx = &g->vx[n - k];
	vy = &g->vy[n - k];
	g->ndraw[g->prim]++;
	switch (g->prim) {
	case PRIM_POINT:
		plot(g, vx[0], vy[0], pattern_src(g, vx[0], vy[0]));
		break;
	case PRIM_LINE:
		draw_line(g, vx[0], vy[0], vx[1], vy[1]);
		keep = 1;
		break;
	case PRIM_RECT:
		draw_rect(g, vx[0], vy[0], vx[1], vy[1]);
		break;
	default:
		draw_poly(g, vx, vy, k);	/* two vertices draw nothing */
		break;
	}
done:
	if (keep) {
		g->vx[0] = g->vx[n - 1];
		g->vy[0] = g->vy[n - 1];
		g->nv = 1;
	} else {
		g->nv = 0;
		g->prim = PRIM_NONE;
	}
	g->pend = 0;
}

/*
 * A vertex from an indexed register: offset 0x800 + prim * 0x40 + reg.  A
 * vertex is complete when both of its coordinates have been written, in
 * either order: Sun's code writes y then x for lines and rectangles, and x
 * then y for points (docs/cg6.md, "Vertices").  An absolute coordinate has
 * the raster offset added; a relative one is added to the last vertex's.
 */
static void queue_prim(struct cg6 *g, int prim)
{
	if (g->prim != prim) {
		/*
		 * A new kind of primitive starts afresh, but for a point
		 * followed by line, triangle or quadrilateral vertices: the
		 * point is their first vertex.  cg6_polygon_2 draws a polygon of
		 * 2 to 4 vertices as one point and 1 to 3 quad vertices; xnews's
		 * outlines (_sh_lg_hol_2U) are a point, then line vertices, each
		 * line drawn before the next vertex: the first from the point.
		 */
		if (!(g->prim == PRIM_POINT && (prim == PRIM_LINE || prim == PRIM_TRI || prim == PRIM_QUAD)))
			g->nv = 0;
		g->prim = prim;
		g->pend = 0;
	}
}

/* a whole vertex onto the queue, in the raster's coordinates */
static void queue_push(struct cg6 *g, int32_t x, int32_t y)
{
	if (g->nv < 64) {
		g->vx[g->nv] = x;
		g->vy[g->nv] = y;
		g->x[g->nv & 3] = x;
		g->y[g->nv & 3] = y;
		g->nv++;
	}
	g->pend = 0;
}

static void vertex(struct cg6 *g, uint32_t o, uint32_t v)
{
	int prim = (o - FBC_IPOINT) >> 6, reg = o & 0x3f;
	int32_t sv = (int32_t)v, lx, ly;

	g->vreg[(o - FBC_IPOINT) >> 2] = v;
	if (prim > PRIM_RECT)
		return;
	queue_prim(g, prim);
	lx = g->nv ? g->vx[g->nv - 1] : g->x[0];
	ly = g->nv ? g->vy[g->nv - 1] : g->y[0];
	switch (reg) {
	case 0x00: g->pend_x = sv + g->offx; g->pend |= 1; break;
	case 0x04: g->pend_y = sv + g->offy; g->pend |= 2; break;
	case 0x10: g->pend_x = lx + sv; g->pend |= 1; break;
	case 0x14: g->pend_y = ly + sv; g->pend |= 2; break;
	default: return;		/* z and colour: stored, not used */
	}
	if (g->pend != 3)
		return;
	queue_push(g, g->pend_x, g->pend_y);
}

/* ---- the blitter (docs/cg6.md, "Blits") ---- */

static void blit(struct cg6 *g)
{
	int32_t w = g->x[1] - g->x[0] + 1, h = g->y[1] - g->y[0] + 1;
	int32_t sx = g->x[0], sy = g->y[0], dx = g->x[2], dy = g->y[2];
	int xdir, ydir;

	g->nblit++;
	if (w <= 0 || h <= 0)
		return;
	/* copy so that an overlapping source is read before it is written */
	ydir = dy > sy ? -1 : 1;
	xdir = dx > sx ? -1 : 1;
	for (int32_t jj = 0; jj < h; jj++) {
		int32_t j = ydir > 0 ? jj : h - 1 - jj;
		for (int32_t ii = 0; ii < w; ii++) {
			int32_t i = xdir > 0 ? ii : w - 1 - ii;
			int32_t x = sx + i, y = sy + j;
			uint8_t s = 0;

			if (x >= 0 && y >= 0 && (uint32_t)(y * CG6_W + x) < CG6_FBSIZE)
				s = g->fb[y * CG6_W + x];
			plot(g, dx + i, dy + j, s);
		}
	}
}

/* ---- the font register: a row of pixels from the CPU ---- */

static void font(struct cg6 *g, uint32_t v)
{
	int32_t n = g->x[1] - g->x[0] + 1, y = g->y[0];

	g->nfont++;
	g->font = v;
	if (n < 0) n = 0;
	if (MISC_DATA(g) == 1) {		/* colour8: four bytes */
		if (n > 4) n = 4;
		for (int32_t i = 0; i < n; i++)
			plot(g, g->x[0] + i, y, v >> (24 - 8 * i));
	} else {				/* colour1: 32 bits, MSB leftmost */
		if (n > 32) n = 32;
		for (int32_t i = 0; i < n; i++)
			plot(g, g->x[0] + i, y, v >> (31 - i) & 1 ? 0xff : 0);
	}
	g->x[0] += g->incx;
	g->x[1] += g->incx;
	g->y[0] += g->incy;
	g->y[1] += g->incy;
}

/* ---- the register file ---- */

static uint32_t status(struct cg6 *g)
{
	uint32_t s = 0;

	if (g->busy) {
		g->busy--;
		s |= FBC_S_BUSY | FBC_S_FULL;
	}
	return s;
}

/*
 * A command: refused while busy, else done at once.  A refusal reads as
 * EXCEPTION and FULL together, which is what Sun's code retries on; an
 * exception without FULL would send it to its software fallback.
 */
static uint32_t command(struct cg6 *g, int is_blit)
{
	if (g->busy) {
		g->busy--;
		g->nfull++;
		return FBC_S_EXCEPTION | FBC_S_FULL | FBC_S_BUSY;
	}
	if (is_blit)
		blit(g);
	else
		draw(g);
	g->busy = g->busy_polls;
	return 0;
}

static uint32_t fbc_read(struct cg6 *g, uint32_t o)
{
	if (o >= FBC_IPOINT && o < FBC_IPOINT + 0x140)
		return g->vreg[(o - FBC_IPOINT) >> 2];
	if (o >= FBC_X0 && o < FBC_X0 + 0x40) {
		int i = (o - FBC_X0) >> 4;
		switch (o & 15) {
		case 0: return g->x[i];
		case 4: return g->y[i];
		case 8: return g->z[i];
		default: return g->color[i];
		}
	}
	if (o >= FBC_PATTERN && o < FBC_PATTERN + 32)
		return g->pattern[(o - FBC_PATTERN) >> 2];
	switch (o) {
	case FBC_CONFIG: return 0x60000000u | (uint32_t)g->fhc_rev << 20 | g->fhc;
	/* MISC's index (5:4) is the queue's: the slot the next vertex goes to
	   (docs/cg6.md, "The TEC"); index_mod (6) reads 0 */
	case FBC_MISC: return (g->misc & ~0x80070u) | (uint32_t)(g->nv & 3) << 4 |
			      (g->misc_vblank ? MISC_VBLANK : 0);
	case FBC_CLIPCHECK: return g->clipcheck;
	case FBC_STATUS: return status(g);
	case FBC_DRAWSTATUS: return command(g, 0);
	case FBC_BLITSTATUS: return command(g, 1);
	case FBC_FONT: return g->font;
	case FBC_OFFX: return g->offx;
	case FBC_OFFY: return g->offy;
	case FBC_INCX: return g->incx;
	case FBC_INCY: return g->incy;
	case FBC_CLIPMINX: return g->clipminx;
	case FBC_CLIPMINY: return g->clipminy;
	case FBC_CLIPMAXX: return g->clipmaxx;
	case FBC_CLIPMAXY: return g->clipmaxy;
	case FBC_FCOLOR: return g->fcolor;
	case FBC_BCOLOR: return g->bcolor;
	case FBC_RASTEROP: return g->rasterop;
	case FBC_PLANEMASK: return g->planemask;
	case FBC_PIXELMASK: return g->pixelmask;
	case FBC_PATTALIGN: return g->pattalign;
	}
	return 0;
}

static void fbc_write(struct cg6 *g, uint32_t o, uint32_t v)
{
	if (o >= FBC_IPOINT && o < FBC_IPOINT + 0x140) {
		vertex(g, o, v);
		return;
	}
	if (o >= FBC_X0 && o < FBC_X0 + 0x40) {
		int i = (o - FBC_X0) >> 4;
		switch (o & 15) {
		case 0: g->x[i] = v; break;
		case 4: g->y[i] = v; break;
		case 8: g->z[i] = v; break;
		default: g->color[i] = v; break;
		}
		return;
	}
	if (o >= FBC_PATTERN && o < FBC_PATTERN + 32) {
		g->pattern[(o - FBC_PATTERN) >> 2] = v;
		return;
	}
	switch (o) {
	case FBC_CONFIG: g->fhc = v & 0xfffff; break;
	case FBC_MISC:
		g->misc = merge_fields(g->misc, v, MISC_FIELDS) & 0x3fffff;
		if (v & MISC_VBLANK)		/* 1 written clears it */
			g->misc_vblank = 0;
		break;
	case FBC_CLIPCHECK: g->clipcheck = v; break;
	case FBC_STATUS: break;		/* bit 31 clears the pick accumulator */
	case FBC_FONT: font(g, v); break;
	case FBC_OFFX: g->offx = v; break;
	case FBC_OFFY: g->offy = v; break;
	case FBC_INCX: g->incx = v; break;
	case FBC_INCY: g->incy = v; break;
	case FBC_CLIPMINX: g->clipminx = v; break;
	case FBC_CLIPMINY: g->clipminy = v; break;
	case FBC_CLIPMAXX: g->clipmaxx = v; break;
	case FBC_CLIPMAXY: g->clipmaxy = v; break;
	case FBC_FCOLOR: g->fcolor = v; break;
	case FBC_BCOLOR: g->bcolor = v; break;
	case FBC_RASTEROP: g->rasterop = merge_fields(g->rasterop, v, ROP_FIELDS); break;
	case FBC_PLANEMASK: g->planemask = v; break;
	case FBC_PIXELMASK: g->pixelmask = v; break;
	case FBC_PATTALIGN: g->pattalign = v; break;
	}
}

/* ---- the THC ---- */

static uint32_t thc_read(struct cg6 *g, uint32_t o)
{
	if (o >= 0x800 && o < 0x818)
		return g->thc_timing[(o - 0x800) >> 2];
	if (o == 0x818)
		return (g->thc_misc & ~(THC_MISC_VSYNC | THC_MISC_INT)) |
		       1u << THC_MISC_REV_SHIFT |
		       (g->vsync ? THC_MISC_VSYNC : 0) | (g->thc_int ? THC_MISC_INT : 0);
	if (o == 0x8fc)
		return g->cursxy;
	if (o >= 0x900 && o < 0x980)
		return g->cursa[(o - 0x900) >> 2];
	if (o >= 0x980 && o < 0xa00)
		return g->cursb[(o - 0x980) >> 2];
	return 0;
}

static void thc_write(struct cg6 *g, uint32_t o, uint32_t v)
{
	if (o >= 0x800 && o < 0x818)
		g->thc_timing[(o - 0x800) >> 2] = v;
	else if (o == 0x818) {
		/* INT written as 1 clears a pending interrupt */
		if (v & THC_MISC_INT)
			g->thc_int = 0;
		g->thc_misc = v & 0x14ef;
	} else if (o == 0x8fc)
		g->cursxy = v;
	else if (o >= 0x900 && o < 0x980)
		g->cursa[(o - 0x900) >> 2] = v;
	else if (o >= 0x980 && o < 0xa00)
		g->cursb[(o - 0x980) >> 2] = v;
}

void cg6_vsync(struct cg6 *g, int on)
{
	if (on && !g->vsync) {
		g->thc_int = 1;
		g->misc_vblank = 1;
	}
	g->vsync = on;
}

int cg6_irq(const struct cg6 *g)
{
	return g->thc_int && (g->thc_misc & THC_MISC_INTEN);
}

/*
 * ---- the TEC (docs/cg6.md, "The TEC") ----
 *
 * Its arithmetic is IEEE single, as the RTL does it (and so not quite
 * IEEE): round to nearest even; a denormal operand is zero and a result
 * too small for a normal is zero, its sign kept; an exponent of 255 is
 * infinity whatever its fraction (there are no NaNs: inf - inf is the first
 * operand, inf * 0 is zero); a result too large is infinity.  Conversions
 * to integer and 16.16 fixed round toward minus infinity and saturate.
 */
#define F_SIGN(v)	((v) & 0x80000000u)
#define F_EXP(v)	((int)((v) >> 23 & 0xff))
#define F_ONE		0x3f800000u

/* sign, exponent and 24-bit significand to a float, the significand
   holding `extra' bits below its 24 (guard and sticky folded in): rounded */
static uint32_t f_pack(uint32_t s, int e, uint64_t m, int extra)
{
	uint64_t half, rest;

	if (m == 0)
		return s;
	/* normalise to bit 23 + extra */
	while (m >> (24 + extra)) {
		m = m >> 1 | (m & 1);
		e++;
	}
	while (!(m >> (23 + extra))) {
		m <<= 1;
		e--;
	}
	half = 1ull << (extra - 1);
	rest = m & ((1ull << extra) - 1);
	m >>= extra;
	if (rest > half || (rest == half && (m & 1)))
		m++;
	if (m >> 24) {
		m >>= 1;
		e++;
	}
	if (e >= 255)
		return s | 0x7f800000u;
	if (e <= 0)
		return s;
	return s | (uint32_t)e << 23 | (uint32_t)(m & 0x7fffff);
}

uint32_t tec_fmul(uint32_t a, uint32_t b)
{
	uint32_t s = F_SIGN(a ^ b);
	int ea = F_EXP(a), eb = F_EXP(b);

	if (ea == 0 || eb == 0)
		return s;
	if (ea == 255 || eb == 255)
		return s | 0x7f800000u;
	/* 24 x 24 bits: the product's 48, 23 of them below the result's 24..25 */
	return f_pack(s, ea + eb - 127,
		      (uint64_t)((a & 0x7fffff) | 0x800000) * ((b & 0x7fffff) | 0x800000), 23);
}

uint32_t tec_fadd(uint32_t a, uint32_t b)
{
	int ea = F_EXP(a), eb = F_EXP(b), d;
	uint64_t ma, mb, m;
	uint32_t s;

	if (ea == 255)
		return F_SIGN(a) | 0x7f800000u;
	if (eb == 255)
		return F_SIGN(b) | 0x7f800000u;
	if (eb == 0)			/* b zero: a, or a zero signed as IEEE's */
		return ea ? a : F_SIGN(a) & F_SIGN(b);
	if (ea == 0)
		return b;
	/* a the larger in magnitude */
	if ((b & 0x7fffffff) > (a & 0x7fffffff)) {
		uint32_t t = a; a = b; b = t;
		ea = F_EXP(a); eb = F_EXP(b);
	}
	/* 3 bits below the significand: guard, round, sticky */
	ma = (uint64_t)((a & 0x7fffff) | 0x800000) << 3;
	mb = (uint64_t)((b & 0x7fffff) | 0x800000) << 3;
	d = ea - eb;
	if (d > 27)
		mb = 1;			/* only the sticky bit */
	else if (d)
		mb = mb >> d | ((mb & ((1ull << d) - 1)) != 0);
	s = F_SIGN(a);
	m = F_SIGN(a ^ b) ? ma - mb : ma + mb;
	if (m == 0)
		return 0;
	return f_pack(s, ea, m, 3);
}

/* integer to float: exact up to 24 bits, rounded beyond */
uint32_t tec_i2f(uint32_t v, int fbits)
{
	uint32_t s = v & 0x80000000u;
	uint64_t m = s ? (uint64_t)(~v + 1u) : v;
	int e = 127 + 23 + 8 - fbits;		/* the significand's point after bit 31 */

	if (m == 0)
		return 0;
	/* m as 24 + 8 bits: f_pack normalises and rounds */
	return f_pack(s, e, m, 8);
}

/* float to integer (fbits 0) or 16.16 (fbits 16), toward minus infinity */
uint32_t tec_f2i(uint32_t v, int fbits)
{
	int e = F_EXP(v) + fbits, sh;
	uint32_t s = F_SIGN(v);
	uint64_t m, ip;
	int frac;

	if (F_EXP(v) == 0)
		return 0;
	if (F_EXP(v) == 255 || e >= 127 + 31)
		return s ? 0x80000000u : 0x7fffffffu;
	if (e < 127)			/* |v| < 1 unit */
		return s ? 0xffffffffu : 0;
	m = (v & 0x7fffff) | 0x800000;
	sh = 150 - e;			/* bits of m below the unit */
	if (sh > 0) {
		ip = m >> sh;
		frac = (m & ((1ull << sh) - 1)) != 0;
	} else {
		ip = m << -sh;
		frac = 0;
	}
	if (s)
		return (uint32_t)-(int64_t)(ip + frac);
	return (uint32_t)ip;
}

/* the data registers as software sees them: VDC's type (15:13) converts */
#define TEC_TYPE(g)	((g)->tec[2] >> 13 & 7)

static uint32_t tec_in(uint32_t v, int type)
{
	switch (type) {
	case 0: return tec_i2f(v, 0);
	case 1: return tec_i2f(v, 16);
	default: return v;		/* 2 IEEE single; 3, 4, 6, 7 the register as it is */
	}
}

static uint32_t tec_out(uint32_t f, int type)
{
	switch (type) {
	case 0: return tec_f2i(f, 0);
	case 1: return tec_f2i(f, 16);
	default: return f;
	}
}

/*
 * A vertex register's X: the point through the MV matrix.  The matrix has
 * rows 3 (x y w) or 4 (x y z w) and 1..4 columns, column by column from its
 * index; w is 1 for an absolute vertex (data register 3 with MV's h bit),
 * 0 for a relative one, which adds to the last result instead.  The results
 * go to data registers 4.., and with autoload to the FBC as the same kind of
 * vertex, rounded down, through its raster offset.
 */
static void tec_vertex(struct cg6 *g, int obj, int rel)
{
	uint32_t mv = g->tec[0], *d = g->tec_data, in[4], acc;
	int idx = mv & 63, rows = mv >> 10 & 1 ? 4 : 3, cols = (mv >> 8 & 3) + 1;
	uint32_t w = rel ? 0 : mv >> 13 & 1 ? d[3] : F_ONE;

	in[0] = d[0];
	in[1] = d[1];
	if (rows == 4) {
		in[2] = mv >> 12 & 1 ? d[2] : 0;
		in[3] = w;
	} else
		in[2] = w;
	for (int j = 0; j < cols; j++) {
		int base = idx + j * rows;
		acc = tec_fmul(in[0], d[base & 63]);
		for (int k = 1; k < rows; k++)
			acc = tec_fadd(acc, tec_fmul(in[k], d[(base + k) & 63]));
		if (rel)
			acc = tec_fadd(d[4 + j], acc);
		d[4 + j] = acc;
	}
	g->ntec_vertex++;
	if (mv >> 14 & 1) {		/* autoload */
		queue_prim(g, obj);
		queue_push(g, (int32_t)tec_f2i(d[4], 0) + g->offx, (int32_t)tec_f2i(d[5], 0) + g->offy);
		g->ntec_auto++;
	}
}

/* COMMAND1: C (1 x n) = A (1 x m) B (m x n), B column by column */
static void tec_command(struct cg6 *g, uint32_t c)
{
	uint32_t *d = g->tec_data, a[4], acc;
	int m = (c >> 30 & 3) + 1, n = (c >> 28 & 3) + 1;
	int ai = c >> 16 & 63, bi = c >> 8 & 63, ci = c & 63;

	for (int k = 0; k < m; k++)
		a[k] = d[(ai + k) & 63];
	for (int j = 0; j < n; j++) {
		int base = bi + j * m;
		acc = tec_fmul(a[0], d[base & 63]);
		for (int k = 1; k < m; k++)
			acc = tec_fadd(acc, tec_fmul(a[k], d[(base + k) & 63]));
		d[(ci + j) & 63] = acc;
	}
	g->ntec_cmd++;
}

static uint32_t tec_read(struct cg6 *g, uint32_t o)
{
	if (o >= 0x100 && o < 0x200) {
		if (TEC_TYPE(g) == 5)
			return g->tec_data1[(o - 0x100) >> 2];
		return tec_out(g->tec_data[(o - 0x100) >> 2], TEC_TYPE(g));
	}
	return g->tec[o >> 2];
}

static void tec_write(struct cg6 *g, uint32_t o, uint32_t v)
{
	if (o >= 0x100 && o < 0x200) {
		if (TEC_TYPE(g) == 5)
			g->tec_data1[(o - 0x100) >> 2] = v;
		else
			g->tec_data[(o - 0x100) >> 2] = tec_in(v, TEC_TYPE(g));
		return;
	}
	g->tec[o >> 2] = v;
	if (o == 0x010)
		tec_command(g, v);
	/* the vertex registers: integer 0x800, fixed 0xA00, float 0xC00; point,
	   line, triangle, quadrilateral, rectangle 0x40 apart; abs x y z w,
	   then rel x y z w */
	if (o >= 0x800 && o < 0xe00 && (o & 0x20) == 0 && (o >> 6 & 7) <= PRIM_RECT) {
		int kind = o >> 9 & 3, coord = o >> 2 & 3;

		g->tec_data[coord] = kind == 2 ? v : tec_i2f(v, kind ? 16 : 0);
		if (coord == 0)
			tec_vertex(g, o >> 6 & 7, o >> 4 & 1);
	}
}

/* ---- the Bt458 (docs/cg6.md, "The DAC"): one byte, on bits 31:24 ---- */

static uint8_t dac_read(struct cg6 *g, int reg)
{
	uint8_t v = 0;

	switch (reg) {
	case 0: return g->dac_addr;
	case 1:
		v = g->cmap[g->dac_addr][g->dac_step];
		if (++g->dac_step == 3) { g->dac_step = 0; g->dac_addr++; }
		return v;
	case 2: return g->dac_addr >= 4 && g->dac_addr <= 7 ? g->dac_ctrl[g->dac_addr - 4] : 0;
	default:
		v = g->omap[g->dac_addr & 3][g->dac_step];
		if (++g->dac_step == 3) { g->dac_step = 0; g->dac_addr++; }
		return v;
	}
}

static void dac_write(struct cg6 *g, int reg, uint8_t v)
{
	switch (reg) {
	case 0: g->dac_addr = v; g->dac_step = 0; break;
	case 1:
		g->dac_rgb[g->dac_step] = v;
		if (++g->dac_step == 3) {
			memcpy(g->cmap[g->dac_addr], g->dac_rgb, 3);
			g->dac_step = 0;
			g->dac_addr++;
		}
		break;
	case 2:
		if (g->dac_addr >= 4 && g->dac_addr <= 7)
			g->dac_ctrl[g->dac_addr - 4] = v;
		break;
	default:
		g->dac_rgb[g->dac_step] = v;
		if (++g->dac_step == 3) {
			memcpy(g->omap[g->dac_addr & 3], g->dac_rgb, 3);
			g->dac_step = 0;
			g->dac_addr++;
		}
		break;
	}
}

uint32_t cg6_rgb(const struct cg6 *g, int x, int y)
{
	const uint8_t *c;
	int cx = (int16_t)(g->cursxy >> 16), cy = (int16_t)g->cursxy;

	if (x >= cx && x < cx + 32 && y >= cy && y < cy + 32) {
		int bit = 31 - (x - cx), row = y - cy;
		int a = g->cursa[row] >> bit & 1, b = g->cursb[row] >> bit & 1;
		if (a || b) {
			/* cursor colours: Bt458 overlay entries */
			c = g->omap[b << 1 | a];
			return (uint32_t)c[0] << 16 | c[1] << 8 | c[2];
		}
	}
	c = g->cmap[g->fb[y * CG6_W + x] & g->dac_ctrl[0]];
	return (uint32_t)c[0] << 16 | c[1] << 8 | c[2];
}

/* ---- the bus ---- */

void cg6_reset(struct cg6 *g)
{
	static uint8_t keep[CG6_FBSIZE];

	memcpy(keep, g->fb, sizeof keep);
	void (*tr)(void *, int, uint32_t, int, uint32_t) = g->trace;
	void *ta = g->trace_arg;
	int bp = g->busy_polls;
	memset(g, 0, sizeof *g);
	memcpy(g->fb, keep, sizeof keep);
	g->trace = tr;
	g->trace_arg = ta;
	g->busy_polls = bp;
	g->fhc_rev = 1;
	g->prim = PRIM_NONE;
	g->dac_ctrl[0] = 0xff;
	g->planemask = 0xff;
	g->pixelmask = 0xffffffff;
	g->clipmaxx = CG6_W - 1;
	g->clipmaxy = CG6_H - 1;
}

/* a register's byte lanes: a narrow access reads or writes its share */
static uint32_t lane_read(uint32_t w, uint32_t off, int size)
{
	int sh = (4 - size - (off & 3)) * 8;
	return size == 4 ? w : w >> sh & ((1u << (8 * size)) - 1);
}

uint32_t cg6_read(struct cg6 *g, uint32_t off, int size)
{
	uint32_t w = 0, a = off & ~3u;

	if (off >= CG6_FB && off < CG6_FB + CG6_FBSIZE) {
		uint32_t p = off - CG6_FB;
		w = 0;
		for (int i = 0; i < size; i++)
			w = w << 8 | g->fb[(p + i) & (CG6_FBSIZE - 1)];
		goto out;
	}
	if (a >= CG6_FBC && a < CG6_FBC + 0x1000)
		w = fbc_read(g, a - CG6_FBC);
	else if (a >= CG6_TEC && a < CG6_TEC + 0x1000)
		w = tec_read(g, a - CG6_TEC);
	else if (a == CG6_FHC)
		w = 0x60000000u | (uint32_t)g->fhc_rev << 20 | g->fhc;
	else if (a >= CG6_THC && a < CG6_THC + 0x1000)
		w = thc_read(g, a - CG6_THC);
	else if (a >= CG6_DAC && a < CG6_DAC + 16)
		w = (uint32_t)dac_read(g, (a - CG6_DAC) >> 2) << 24;
	w = lane_read(w, off, size);
out:
	if (g->trace)
		g->trace(g->trace_arg, 0, off, size, w);
	return w;
}

void cg6_write(struct cg6 *g, uint32_t off, int size, uint32_t v)
{
	uint32_t a = off & ~3u, w;

	if (g->trace)
		g->trace(g->trace_arg, 1, off, size, v);
	if (off >= CG6_FB && off < CG6_FB + CG6_FBSIZE) {
		uint32_t p = off - CG6_FB;
		for (int i = size - 1; i >= 0; i--, v >>= 8)
			g->fb[(p + i) & (CG6_FBSIZE - 1)] = v;
		return;
	}
	/*
	 * A narrow write to a register: the 68020 puts a byte on every lane
	 * and a word on both halves, so the register sees the value repeated.
	 * The DAC takes bits 31:24; the other registers are only ever written
	 * as longwords by the software in docs/cg6.md.
	 */
	w = size == 4 ? v : size == 2 ? (v & 0xffff) * 0x10001u : (v & 0xff) * 0x01010101u;
	if (a >= CG6_FBC && a < CG6_FBC + 0x1000)
		fbc_write(g, a - CG6_FBC, w);
	else if (a >= CG6_TEC && a < CG6_TEC + 0x1000)
		tec_write(g, a - CG6_TEC, w);
	else if (a == CG6_FHC)
		g->fhc = w & 0xfffff;
	else if (a >= CG6_THC && a < CG6_THC + 0x1000)
		thc_write(g, a - CG6_THC, w);
	else if (a >= CG6_DAC && a < CG6_DAC + 16)
		dac_write(g, (a - CG6_DAC) >> 2, w >> 24);
}
