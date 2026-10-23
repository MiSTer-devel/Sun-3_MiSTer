/*
 * xnews.c -- OpenWindows 2.0's own GX code against cg6model's TEC.
 *
 *   xnews68k XNEWS [-n N] [-s seed] [-t trace -I initial -F final] [-v] [-c]
 *   xnews68k -T                the TEC's arithmetic against the host's floats
 *
 * -c: exit 1 unless the TEC agrees with xnews's float software bit for bit,
 * its fixed and integer results land on the exact one's pixel at least
 * 99.5% of the time, its autoloaded vertices are the exact ones rounded
 * down at least 99.9% of the time, and what it draws the exact vertices'
 * drawing in 99.5% of the tests (mutatexn.sh's test).
 *
 * XNEWS is the sun3 /usr/openwin/bin/xnews of OpenWindows 2.0 (SunOS 4.1.1's
 * tape: 1,335,296 bytes, SHA-256 e0c03ef4...5011bf3c6), an unstripped 68020
 * a.out that is loaded whole (text at 0x2000, data at the next 128 KiB) and
 * run on Musashi as the libpixrect harness runs its library.  Its calls into
 * the shared libc (the PLT: Sun's floating-point routines, bcopy, ...) are
 * illegal instructions done here in C; anything else it calls out to stops
 * the run.  docs/cg6.md, "The TEC", is what this checks.
 *
 * Each test sets up the structures xnews's routines read (a canvas with its
 * matrix at +0x10 and its frame buffer's state at +0x50, the frame buffer's
 * TEC/FBC pointer at +0x60 and its cached VDC type at +0x58, a path of
 * 12-byte elements) and calls:
 *
 *   point   _point_transform (0x9e0a, the TEC's: a 1x3 . 3x2 COMMAND1) and
 *           the software one (0x3c06: _sh_trans_mul_abs_*), on fixed, float
 *           and integer points, through fixed and float matrices;
 *   path    _sh_cg6_Path_Transform (vertex registers, MV, results read from
 *           data registers 4 and 5, then COMMAND1 for relative elements)
 *           and the software _sh_fb_Path_Transform, on the same path;
 *   vec     _sh_lg_vec_2U: polylines through the TEC's fixed and float line
 *           registers, absolute and relative, autoloaded into the FBC;
 *   area    _sh_lg_area_2US: polygons as fans of quadrilaterals, a TEC point
 *           and TEC quad vertices autoloaded, the fan's restart read back
 *           from the FBC's MISC index and x/y registers.
 *
 * and compares the results with an exact reference (doubles), and with
 * xnews's software where it has one.  For the drawing tests a second model
 * is given the same FBC cycles with each TEC vertex replaced by the exact
 * one, rounded down, and the two frame buffers are compared.
 */
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "m68k.h"
#include "cg6model.h"

#define RAM_SIZE	0x2000000
#define HEAP_BASE	0x400000
#define HEAP_END	0x1e00000
#define STACK_TOP	0x1ff0000
#define RET_ADDR	0x0f00
#define CRASH_ADDR	0x0f10
#define VBASE		0x70000000u	/* FBC, then the TEC at +0x1000 */
#define V_END		(VBASE + 0x2000)

/* xnews 2.0 (the SHA-256 above): its two _point_transform share a name */
#define A_POINT_TEC	0x9e0a
#define A_POINT_SW	0x3c06

static uint8_t *ram;
static struct cg6 G, R;		/* the board; the reference */
static FILE *trace;
static int verbose, check, kinds = 15;	/* -k: 1 point, 2 path, 4 vec, 8 area */
static unsigned long icount, nboard;
static volatile int returned;

static uint32_t cpu_pc(void) { return m68k_get_reg(NULL, M68K_REG_PPC); }

static void die(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, " (pc %08x)\n", cpu_pc());
	exit(2);
}

static uint32_t rd16(uint32_t a) { return ram[a] << 8 | ram[a + 1]; }
static uint32_t rd32(uint32_t a) { return rd16(a) << 16 | rd16(a + 2); }
static void wr8(uint32_t a, uint32_t v) { ram[a] = v; }
static void wr16(uint32_t a, uint32_t v) { ram[a] = v >> 8; ram[a + 1] = v; }
static void wr32(uint32_t a, uint32_t v) { wr16(a, v >> 16); wr16(a + 2, v); }

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static uint64_t d2u(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
static double u2d(uint64_t u) { double d; memcpy(&d, &u, 8); return d; }

/* ---- the reference's mirror of the board's cycles (the drawing tests) ---- */
static int mirror;			/* the drawing tests: 1 R follows G's FBC cycles, its
					   TEC vertices exact; 2 the vertices checked only */
static int tec_x_kind, tec_y_kind;	/* the last Y written: its kind */
static double tec_y, cur_x, cur_y;	/* the exact point, the exact last result */
static unsigned long nvert, nvert_bad;

static double tec_value(uint32_t v, int kind)
{
	return kind == 0 ? (double)(int32_t)v : kind == 1 ? (int32_t)v / 65536.0 : (double)u2f(v);
}

/* the drawing routines run under the identity at MV's index (a 3x2 matrix:
   x' = x m0 + y m1 + m2, y' = x m3 + y m4 + m5), translated or not */
static void check_identity(void)
{
	int idx = G.tec[0] & 63;
	static const int at[4] = { 0, 1, 3, 4 };
	static const uint32_t id[4] = { 0x3f800000, 0, 0, 0x3f800000 };

	if ((G.tec[0] & 0x7c0) != 0x100)
		die("MV %08x: not 3x2", G.tec[0]);
	for (int i = 0; i < 4; i++)
		if (G.tec_data[(idx + at[i]) & 63] != id[i])
			die("the matrix at %02x is not the identity", idx);
}

static void mirror_tec_write(uint32_t o, uint32_t v)
{
	int vdc = G.tec[2] >> 13 & 7;

	if ((o == 0x110 || o == 0x114) && vdc <= 2) {	/* the current point */
		double d = tec_value(v, vdc);
		if (o == 0x110) cur_x = d; else cur_y = d;
		return;
	}
	if (o >= 0x800 && o < 0xe00 && (o & 0x20) == 0 && (o >> 6 & 7) <= 4) {
		int kind = o >> 9 & 3, coord = o >> 2 & 3, rel = o >> 4 & 1, obj = o >> 6 & 7;
		if (coord == 1) { tec_y = tec_value(v, kind); tec_y_kind = kind; }
		if (coord != 0)
			return;
		tec_x_kind = kind;
		check_identity();
		{
			int idx = G.tec[0] & 63;
			double x = tec_value(v, kind), tx = u2f(G.tec_data[(idx + 2) & 63]),
			       ty = u2f(G.tec_data[(idx + 5) & 63]);
			if (rel) { cur_x += x; cur_y += tec_y; }
			else { cur_x = x + tx; cur_y = tec_y + ty; }
		}
		if (G.tec[0] >> 14 & 1) {
			int32_t ex = (int32_t)floor(cur_x), ey = (int32_t)floor(cur_y);
			uint32_t r = 0x800 + 0x40 * obj;
			if (mirror == 1) {
				cg6_write(&R, CG6_FBC + r + 4, 4, ey);
				cg6_write(&R, CG6_FBC + r, 4, ex);
			}
			nvert++;
			/* the board's vertex, as it was queued */
			if (G.x[(G.nv - 1) & 3] - G.offx != ex || G.y[(G.nv - 1) & 3] - G.offy != ey) {
				nvert_bad++;
				if (verbose)
					printf("  vertex %.6f %.6f -> %d %d, the TEC %d %d\n", cur_x, cur_y, ex, ey,
					       G.x[(G.nv - 1) & 3] - G.offx, G.y[(G.nv - 1) & 3] - G.offy);
			}
		}
	}
}

/* ---- the board ---- */
static int board(uint32_t a) { return a >= VBASE && a < V_END; }

static void tracefn(void *arg, int wr, uint32_t off, int size, uint32_t v)
{
	(void)arg;
	nboard++;
	if (trace)
		fprintf(trace, "%c%d %06x %08x\n", wr ? 'w' : 'r', size, off, v);
}

static uint32_t mem_rd(uint32_t a, int size)
{
	if (board(a)) {
		uint32_t off = CG6_FBC + (a - VBASE), v = cg6_read(&G, off, size);
		if (mirror == 1 && off < CG6_TEC)
			cg6_read(&R, off, size);
		return v;
	}
	if (a + size > RAM_SIZE)
		die("read of %08x", a);
	return size == 4 ? rd32(a) : size == 2 ? rd16(a) : ram[a];
}

static void mem_wr(uint32_t a, int size, uint32_t v)
{
	if (board(a)) {
		uint32_t off = CG6_FBC + (a - VBASE);
		cg6_write(&G, off, size, v);
		if (mirror) {
			if (off < CG6_TEC) {
				if (mirror == 1)
					cg6_write(&R, off, size, v);
			}
			else if (size == 4)
				mirror_tec_write(off - CG6_TEC, v);
		}
		return;
	}
	if (a + size > RAM_SIZE || a < 0x1000)
		die("write of %08x", a);
	if (size == 4) wr32(a, v); else if (size == 2) wr16(a, v); else wr8(a, v);
}

unsigned int m68k_read_memory_8(unsigned int a) { return mem_rd(a, 1); }
unsigned int m68k_read_memory_16(unsigned int a) { return mem_rd(a, 2); }
unsigned int m68k_read_memory_32(unsigned int a) { return mem_rd(a, 4); }
void m68k_write_memory_8(unsigned int a, unsigned int v) { mem_wr(a, 1, v); }
void m68k_write_memory_16(unsigned int a, unsigned int v) { mem_wr(a, 2, v); }
void m68k_write_memory_32(unsigned int a, unsigned int v) { mem_wr(a, 4, v); }
unsigned int m68k_read_disassembler_16(unsigned int a) { return rd16(a % RAM_SIZE); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return rd32(a % RAM_SIZE); }

/* ---- the a.out ---- */
#define NSYM 32768
struct sym { uint32_t addr; char name[48]; };
static struct sym syms[NSYM];
static int nsyms;
static uint32_t text_base = 0x2000, data_base, bss_end;

struct plt { uint32_t addr; char name[24]; };
static struct plt plts[512];
static int nplt;

static uint32_t sym(const char *name)
{
	for (int i = 0; i < nsyms; i++)
		if (!strcmp(syms[i].name, name))
			return syms[i].addr;
	die("no symbol %s", name);
	return 0;
}

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

static void load_aout(const char *path)
{
	FILE *f = fopen(path, "rb");
	static uint8_t img[0x200000];
	size_t n;
	uint32_t text, data, bss, nsym, trs, drs, symoff, stroff;

	if (!f)
		die("can't open %s", path);
	n = fread(img, 1, sizeof img, f);
	fclose(f);
	if (n < 32 || be32(img) != 0x8002010bu)	/* dynamic, sun3 (2), ZMAGIC */
		die("%s: not a sun3 ZMAGIC a.out (%08x)", path, be32(img));
	text = be32(img + 4); data = be32(img + 8); bss = be32(img + 12);
	nsym = be32(img + 16); trs = be32(img + 24); drs = be32(img + 28);
	data_base = (text_base + text + 0x1ffff) & ~0x1ffffu;
	bss_end = data_base + data + bss;
	memcpy(ram + text_base, img, text);
	memcpy(ram + data_base, img + text, data);
	memset(ram + data_base + data, 0, bss);
	symoff = text + data + trs + drs;
	stroff = symoff + nsym;
	for (uint32_t i = 0; i < nsym / 12 && nsyms < NSYM; i++) {
		const uint8_t *e = img + symoff + 12 * i;
		uint32_t strx = be32(e), val = be32(e + 8);
		int type = e[4] & 0x1e;
		if (!strx || (type != 4 && type != 6 && type != 8))
			continue;
		snprintf(syms[nsyms].name, sizeof syms[0].name, "%s", (const char *)img + stroff + strx);
		syms[nsyms].addr = val;
		nsyms++;
	}
	/* the PLT: __DYNAMIC's link_dynamic_2, its relocations against the
	   symbols it names (offsets from the text's start) */
	{
		uint32_t ld2 = rd32(data_base + 8), rel = rd32(ld2 + 20), hash = rd32(ld2 + 24),
			 stab = rd32(ld2 + 28), str = rd32(ld2 + 40), plt = rd32(ld2 + 16);
		for (uint32_t r = rel; r < hash && nplt < 512; r += 8) {
			uint32_t a = rd32(text_base + r), info = rd32(text_base + r + 4);
			uint32_t strx = rd32(text_base + stab + 12 * (info >> 8));
			if (a < plt || a >= plt + 0x1000)
				continue;
			plts[nplt].addr = a - 2;
			snprintf(plts[nplt].name, sizeof plts[0].name, "%s", (const char *)ram + text_base + str + strx);
			wr16(a - 2, 0x4afc);		/* illegal, then rts */
			wr16(a, 0x4e75);
			nplt++;
		}
	}
	printf("xnews: text %06x..%06x, data %06x..%06x, %d symbols, %d PLT entries\n", text_base,
	       text_base + text, data_base, bss_end, nsyms, nplt);
}

/* ---- the shared libc, in C: Sun's floating point (V... and F..., both with
   singles in d0 (d1), doubles in d0:d1, a second double at (a0)) ---- */
static uint32_t heap = HEAP_BASE;

static uint32_t alloc(uint32_t n)
{
	uint32_t a = heap;
	heap = (heap + n + 15) & ~15u;
	if (heap > HEAP_END)
		die("out of heap");
	memset(ram + a, 0, n);
	return a;
}

static uint32_t D(int r) { return m68k_get_reg(NULL, M68K_REG_D0 + r); }
static void setD(int r, uint32_t v) { m68k_set_reg(M68K_REG_D0 + r, v); }
static double dreg(void) { return u2d((uint64_t)D(0) << 32 | D(1)); }
static void setdreg(double d) { uint64_t u = d2u(d); setD(0, u >> 32); setD(1, (uint32_t)u); }
static double da0(void) { uint32_t a = m68k_get_reg(NULL, M68K_REG_A0); return u2d((uint64_t)rd32(a) << 32 | rd32(a + 4)); }
static uint32_t sarg(int i) { return rd32(m68k_get_reg(NULL, M68K_REG_SP) + 4 + 4 * i); }

static void ccr_cmp(double a, double b)
{
	uint32_t sr = m68k_get_reg(NULL, M68K_REG_SR) & ~0x1fu;
	if (a == b) sr |= 4;
	else if (a < b) sr |= 8 | 1;		/* N, and C for the unsigned tests */
	m68k_set_reg(M68K_REG_SR, sr);
}

static unsigned long nplt_calls;

static void libc(const char *n)
{
	nplt_calls++;
	if (!strcmp(n, "Vstod") || !strcmp(n, "Fstod")) setdreg(u2f(D(0)));
	else if (!strcmp(n, "Vdtos") || !strcmp(n, "Fdtos")) setD(0, f2u((float)dreg()));
	else if (!strcmp(n, "Vmuls") || !strcmp(n, "Fmuls")) setD(0, f2u(u2f(D(0)) * u2f(D(1))));
	else if (!strcmp(n, "Vdivs") || !strcmp(n, "Fdivs")) setD(0, f2u(u2f(D(0)) / u2f(D(1))));
	else if (!strcmp(n, "Vadds") || !strcmp(n, "Fadds")) setD(0, f2u(u2f(D(0)) + u2f(D(1))));
	else if (!strcmp(n, "Vsubs") || !strcmp(n, "Fsubs")) setD(0, f2u(u2f(D(0)) - u2f(D(1))));
	else if (!strcmp(n, "Vints") || !strcmp(n, "Fints")) setD(0, (uint32_t)(int32_t)u2f(D(0)));
	else if (!strcmp(n, "Vflts") || !strcmp(n, "Fflts")) setD(0, f2u((float)(int32_t)D(0)));
	else if (!strcmp(n, "Vcmps") || !strcmp(n, "Fcmps")) ccr_cmp(u2f(D(0)), u2f(D(1)));
	else if (!strcmp(n, "Vmuld") || !strcmp(n, "Fmuld")) setdreg(dreg() * da0());
	else if (!strcmp(n, "Vdivd") || !strcmp(n, "Fdivd")) setdreg(dreg() / da0());
	else if (!strcmp(n, "Vaddd") || !strcmp(n, "Faddd")) setdreg(dreg() + da0());
	else if (!strcmp(n, "Fsubd")) setdreg(dreg() - da0());
	else if (!strcmp(n, "Vcmpd") || !strcmp(n, "Fcmpd")) ccr_cmp(dreg(), da0());
	else if (!strcmp(n, "Vintd") || !strcmp(n, "Fintd")) setD(0, (uint32_t)(int32_t)dreg());
	else if (!strcmp(n, "Vfltd") || !strcmp(n, "Ffltd")) setdreg((double)(int32_t)D(0));
	else if (!strcmp(n, "_bcopy")) memmove(ram + sarg(1), ram + sarg(0), sarg(2));
	else if (!strcmp(n, "_bzero")) memset(ram + sarg(0), 0, sarg(1));
	else if (!strcmp(n, "_memcpy")) { memmove(ram + sarg(0), ram + sarg(1), sarg(2)); setD(0, sarg(0)); }
	else
		die("xnews calls %s", n);
}

/* ---- the CPU ---- */
static uint32_t pcring[64];
static void insn_hook(unsigned int pc) { pcring[icount & 63] = pc; icount++; }

static int illegal(int opcode)
{
	uint32_t pc = cpu_pc();

	(void)opcode;
	if (pc == RET_ADDR) {
		returned = 1;
		m68k_end_timeslice();
		return 1;
	}
	if (pc == CRASH_ADDR) {
		uint32_t sp = m68k_get_reg(NULL, M68K_REG_SP);
		for (int i = 24; i > 0; i--)
			fprintf(stderr, " %06x", pcring[(icount - i) & 63]);
		fprintf(stderr, "\n");
		die("exception (vector %03x) at %08x", rd16(sp + 6) & 0xfff, rd32(sp + 2));
	}
	for (int i = 0; i < nplt; i++)
		if (plts[i].addr == pc) {
			libc(plts[i].name);
			return 1;
		}
	for (int i = 0; i < nsyms; i++)
		if (syms[i].addr == pc)
			die("xnews calls %s (%08x, %08x)", syms[i].name, sarg(0), sarg(1));
	return 0;
}

/* stop the run if xnews reaches one of these: its own error reports, the
   curve flattener, the software fill a polygon falls back to */
static void trap(const char *name)
{
	uint32_t a = sym(name);
	wr16(a, 0x4afc);
}

static uint32_t call(uint32_t fn, int n, ...)
{
	uint32_t a[8], sp = STACK_TOP - 0x200;
	va_list ap;

	va_start(ap, n);
	for (int i = 0; i < n; i++)
		a[i] = va_arg(ap, uint32_t);
	va_end(ap);
	for (int i = n - 1; i >= 0; i--)
		wr32(sp -= 4, a[i]);
	wr32(sp -= 4, RET_ADDR);
	m68k_set_reg(M68K_REG_SR, 0x2700);
	m68k_set_reg(M68K_REG_A7, sp);
	m68k_set_reg(M68K_REG_PC, fn);
	returned = 0;
	for (long i = 0; !returned; i++) {
		if (i > 4000)
			die("%06x does not return", fn);
		m68k_execute(100000);
	}
	return D(0);
}

static void cpu_init(void)
{
	wr32(0, STACK_TOP);
	wr32(4, RET_ADDR);
	for (uint32_t v = 8; v < 0x400; v += 4)
		wr32(v, CRASH_ADDR);
	wr16(RET_ADDR, 0x4afc);
	wr16(CRASH_ADDR, 0x4afc);
	m68k_init();
	m68k_set_cpu_type(M68K_CPU_TYPE_68020);
	m68k_set_illg_instr_callback(illegal);
	m68k_set_instr_hook_callback(insn_hook);
	m68k_pulse_reset();
}

/* ---- random numbers ---- */
static uint64_t rs = 88172645463325252ull;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static int rn(int n) { return n > 0 ? (int)(rnd() % (unsigned)n) : 0; }
static double rf(double lo, double hi) { return lo + (hi - lo) * (rnd() / 4294967296.0); }

/* ---- the structures xnews's routines read ---- */
#define FB_TEC		0x60	/* the FBC/TEC page */
#define FB_FLAGS	0x54	/* bit 5: the canvas's matrix must be reloaded */
#define FB_VDC		0x58	/* VDC's type as last set: 0, 0x2000, 0x4000 */
#define FB_RASTER	0x5a	/* the matrix index drawing uses: 0x22 */
#define FB_CANVAS	0x70	/* whose matrix is loaded */
#define FB_MV		0x74
#define FB_XMV		0x78	/* &data register 4 .. 7 */
#define CV_FLAGS	0x04	/* bit 3 float, bit 2 3D, 1:0 translate, scale, general */
#define CV_MAT		0x10	/* 4 x 4, row by row: x' = x m0 + y m4 + m12 */
#define CV_FB		0x50

static uint32_t FBS, CANVAS, FLTMAT, PIPE;

static void tec_w(uint32_t o, uint32_t v) { mem_wr(VBASE + 0x1000 + o, 4, v); }
static uint32_t tec_r(uint32_t o) { return mem_rd(VBASE + 0x1000 + o, 4); }
static void fbc_w(uint32_t o, uint32_t v) { mem_wr(VBASE + o, 4, v); }

/* _sh_init_cg6's TEC set-up (0xeb93c..0xeb9a6), its frame-buffer struct */
static void init_cg6(void)
{
	/* the data registers as cg6_cntxrestore leaves them (an RTL's RAM is not
	   cleared by a reset): both banks, 0 */
	for (int b = 0; b < 2; b++) {
		tec_w(0x008, b ? 0xa000 : 0x8000);
		for (int i = 0; i < 64; i++)
			tec_w(0x100 + 4 * i, 0);
	}
	FBS = alloc(0x100);
	wr32(FBS + FB_TEC, VBASE);
	tec_w(0x000, 0x112);
	tec_w(0x008, 0x200c);
	tec_w(0x004, 0);
	tec_w(0x008, tec_r(0x008) & ~0x1000u);
	fbc_w(0x008, 0);
	for (int i = 0; i < 4; i++)
		wr32(FBS + FB_XMV + 4 * i, VBASE + 0x1110 + 4 * i);
	wr8(FBS + FB_RASTER, 0x22);
	tec_w(0x000, 0x112);
	call(sym("_sh_lg_load_ident"), 2, VBASE, 0x12);
	call(sym("_sh_lg_load_ident"), 2, VBASE, 0x22);
	wr32(FBS + FB_CANVAS, 0);
	wr16(FBS + FB_VDC, 0x2000);
	/* a canvas is an object: its class at -4, whose method +8 gives its
	   matrix as floats (the software's float path asks a fixed canvas) */
	CANVAS = alloc(0x110) + 0x10;
	wr32(CANVAS + CV_FB, FBS);
	PIPE = alloc(0x100);		/* the canvas's pipeline: 2D ($98), valid ($9a) */
	wr32(CANVAS + 8, PIPE);
	{
		uint32_t cls = alloc(0x20), code = alloc(0x10);
		FLTMAT = alloc(0x40);
		wr32(CANVAS - 4, cls);
		wr32(cls + 8, code);
		wr16(code, 0x203c);		/* move.l #FLTMAT, d0; rts */
		wr32(code + 2, FLTMAT);
		wr16(code + 6, 0x4e75);
	}
}

/* a 2D matrix: a b c d tx ty (x' = x a + y c + tx, y' = x b + y d + ty) */
struct mat { double m[6]; int flt; };

static double fx(double v) { return floor(v * 65536.0 + 0.5) / 65536.0; }

static void random_mat(struct mat *M, int flt)
{
	double s = rn(4) ? rf(0.2, 4.0) : rf(0.005, 40.0), t = rf(0, 2 * M_PI);
	double sx = s * (rn(4) ? 1 : rf(0.3, 3.0)), sy = s;

	M->flt = flt;
	switch (rn(6)) {
	case 0:	/* identity, translated */
		M->m[0] = 1; M->m[1] = 0; M->m[2] = 0; M->m[3] = 1; break;
	case 1:	/* scaled, flipped (PostScript's default on a screen) */
		M->m[0] = sx; M->m[1] = 0; M->m[2] = 0; M->m[3] = -sy; break;
	default:
		M->m[0] = sx * cos(t); M->m[1] = sx * sin(t);
		M->m[2] = -sy * sin(t); M->m[3] = sy * cos(t);
		if (rn(4) == 0) M->m[2] += rf(-1, 1);	/* sheared */
		break;
	}
	M->m[4] = rn(4) ? rf(-200, 1400) : rf(-30000, 30000);
	M->m[5] = rn(4) ? rf(-200, 1100) : rf(-30000, 30000);
	/* what the matrix is in its format, exactly */
	for (int i = 0; i < 6; i++)
		M->m[i] = flt ? (double)(float)M->m[i] : fx(M->m[i]);
}

static uint32_t enc(double v, int flt) { return flt ? f2u((float)v) : (uint32_t)(int32_t)floor(v * 65536.0 + 0.5); }
static double dec(uint32_t v, int flt) { return flt ? (double)u2f(v) : (int32_t)v / 65536.0; }

static void put_canvas(const struct mat *M, int kind)
{
	static const int at[6] = { 0, 1, 4, 5, 12, 13 };
	uint32_t one = M->flt ? 0x3f800000u : 0x10000u;

	for (int i = 0; i < 16; i++)
		wr32(CANVAS + CV_MAT + 4 * i, 0);
	wr32(CANVAS + CV_MAT + 4 * 10, one);
	wr32(CANVAS + CV_MAT + 4 * 15, one);
	for (int i = 0; i < 16; i++)
		wr32(FLTMAT + 4 * i, i == 10 || i == 15 ? 0x3f800000u : 0);
	for (int i = 0; i < 6; i++) {
		wr32(CANVAS + CV_MAT + 4 * at[i], enc(M->m[i], M->flt));
		wr32(FLTMAT + 4 * at[i], f2u((float)M->m[i]));
	}
	wr32(CANVAS, rnd());			/* the canvas's identity, for the cache */
	wr8(CANVAS + CV_FLAGS, (M->flt ? 8 : 0) | kind);
	wr8(CANVAS + 5, 0);
	wr8(CANVAS + 6, 0);
	wr8(FBS + FB_FLAGS, ram[FBS + FB_FLAGS] | 0x20);
}

/* ---- statistics: a result against the exact one ---- */
struct agree {
	const char *what;
	unsigned long n, exact, near, pix, worst_pix;
	double worst;			/* in units of the result's last place */
};

static void agree_add(struct agree *a, double got, double want, int flt)
{
	double ulp, e;

	a->n++;
	if (flt) {
		int ex;
		frexp(want, &ex);
		ulp = ldexp(1.0, ex - 24);
	} else
		ulp = 1.0 / 65536.0;
	if (want == 0) ulp = flt ? 1e-38 : ulp;
	e = fabs(got - want) / ulp;
	if (got == want) a->exact++;
	if (e <= 1.0) a->near++;
	if (e > a->worst) a->worst = e;
	if (floor(got) == floor(want)) a->pix++;
}

static void agree_print(const struct agree *a)
{
	if (!a->n)
		return;
	printf("  %-34s %7lu: %6.2f%% exact, %6.2f%% within 1 ulp, worst %.3g ulp; %6.2f%% the same pixel\n",
	       a->what, a->n, 100.0 * a->exact / a->n, 100.0 * a->near / a->n, a->worst, 100.0 * a->pix / a->n);
}

/* ---- point: _point_transform, the TEC's and the software's ---- */
static unsigned long pa_types_bad, pa_elems, pa_fixfloat, pa_range;

static struct agree pt_tec_ex[3] = { { "point, TEC vs exact: fixed", 0, 0, 0, 0, 0, 0 },
	{ "point, TEC vs exact: float", 0, 0, 0, 0, 0, 0 }, { "point, TEC vs exact: integer", 0, 0, 0, 0, 0, 0 } };
static struct agree pt_sw_ex[2] = { { "point, software vs exact: fixed", 0, 0, 0, 0, 0, 0 },
	{ "point, software vs exact: float", 0, 0, 0, 0, 0, 0 } };
static struct agree pt_tec_sw[2] = { { "point, TEC vs software: fixed", 0, 0, 0, 0, 0, 0 },
	{ "point, TEC vs software: float", 0, 0, 0, 0, 0, 0 } };

static void test_point(void)
{
	struct mat M;
	uint32_t P = alloc(0x20), Q = alloc(0x20);
	int ptype = rn(3);		/* 0 fixed, 1 float, 2 integer */
	int vec = rn(5) == 0;
	double x = rn(4) ? rf(-100, 1300) : rf(-20000, 20000), y = rn(4) ? rf(-100, 1000) : rf(-20000, 20000);
	double wx, wy, gx, gy;
	uint32_t flags;

	random_mat(&M, rn(2));
	put_canvas(&M, 2);
	if (vec)			/* a vector is taken in the matrix's format */
		ptype = M.flt;
	if (ptype == 2) { x = floor(x); y = floor(y); }
	flags = ptype == 1 ? 4 : ptype == 2 ? 0x80 : 0;
	if (vec) flags |= 0x20;
	wr32(P, flags);
	if (ptype == 0) { x = fx(x); y = fx(y); wr32(P + 4, enc(x, 0)); wr32(P + 8, enc(y, 0)); }
	else if (ptype == 1) { x = (float)x; y = (float)y; wr32(P + 4, f2u(x)); wr32(P + 8, f2u(y)); }
	else { wr32(P + 4, (uint32_t)(int32_t)x); wr32(P + 8, (uint32_t)(int32_t)y); }
	memcpy(ram + Q, ram + P, 0x20);
	call(A_POINT_TEC, 2, CANVAS, P);
	wx = x * M.m[0] + y * M.m[2] + (vec ? 0 : M.m[4]);
	wy = x * M.m[1] + y * M.m[3] + (vec ? 0 : M.m[5]);
	if (ptype != 1 && (fabs(wx) >= 32767 || fabs(wy) >= 32767)) {
		pa_range++;		/* beyond 16.16 (and the integers xnews keeps to it) */
		return;
	}
	if (ptype == 2) {
		gx = (int32_t)rd32(P + 4); gy = (int32_t)rd32(P + 8);
		agree_add(&pt_tec_ex[2], gx, floor(wx), 0);
		agree_add(&pt_tec_ex[2], gy, floor(wy), 0);
		return;
	}
	gx = dec(rd32(P + 4), ptype); gy = dec(rd32(P + 8), ptype);
	agree_add(&pt_tec_ex[ptype], gx, wx, ptype);
	agree_add(&pt_tec_ex[ptype], gy, wy, ptype);
	if (!vec) {
		double sx, sy;
		call(A_POINT_SW, 2, CANVAS, Q);
		sx = dec(rd32(Q + 4), ptype); sy = dec(rd32(Q + 8), ptype);
		agree_add(&pt_sw_ex[ptype], sx, wx, ptype);
		agree_add(&pt_sw_ex[ptype], sy, wy, ptype);
		agree_add(&pt_tec_sw[ptype], gx, sx, ptype);
		agree_add(&pt_tec_sw[ptype], gy, sy, ptype);
		if (verbose && (gx != sx || gy != sy))
			printf("  point %s %s (%.6f %.6f): TEC %.6f %.6f, software %.6f %.6f, exact %.6f %.6f\n",
			       M.flt ? "float" : "fixed", ptype ? "float" : "fixed", x, y, gx, gy, sx, sy, wx, wy);
	}
}

/* ---- path: _sh_cg6_Path_Transform against _sh_fb_Path_Transform ---- */
static struct agree pa_tec_ex[2] = { { "path, TEC vs exact: fixed", 0, 0, 0, 0, 0, 0 },
	{ "path, TEC vs exact: float", 0, 0, 0, 0, 0, 0 } };
static struct agree pa_sw_ex[2] = { { "path, software vs exact: fixed", 0, 0, 0, 0, 0, 0 },
	{ "path, software vs exact: float", 0, 0, 0, 0, 0, 0 } };
static struct agree pa_tec_sw[2] = { { "path, TEC vs software: fixed", 0, 0, 0, 0, 0, 0 },
	{ "path, TEC vs software: float", 0, 0, 0, 0, 0, 0 } };

#define EL	12
#define T_FLT	4
#define T_LINE	8
#define T_REL	0x20
#define T_END	0x48

static void test_path(void)
{
	struct mat M;
	int n = 2 + rn(rn(4) ? 10 : 60), flt = rn(2);
	uint32_t E1 = alloc(EL * (n + 1)), E2 = alloc(EL * (n + 1)), P1 = alloc(16), P2 = alloc(16);
	int type[64];
	double ex[64], ey[64];

	random_mat(&M, flt);
	put_canvas(&M, 2);
	/* the pipelined canvas a GX's are (0x3bafa): its matrix at 0x12, as its
	   validation leaves it (_val_v: _lego_load_mv) */
	wr8(CANVAS + 6, 0x80);
	wr32(FBS + 0x5c, PIPE);
	call(sym("_lego_load_mv"), 2, CANVAS, FBS);
	for (int i = 0; i < n; i++) {
		int t = (i ? T_LINE : 0) | (rn(3) == 0 ? T_FLT : 0) | (i && rn(4) == 0 ? T_REL : 0);
		double x, y;
		if (t & T_REL) { x = rf(-200, 200); y = rf(-200, 200); }
		else { x = rf(-100, 1300); y = rf(-100, 1000); }
		if (rn(16) == 0) { x = rf(-15000, 15000); y = rf(-15000, 15000); }
		if (t & T_FLT) { x = (float)x; y = (float)y; } else { x = fx(x); y = fx(y); }
		wr16(E1 + EL * i, 0);
		wr16(E1 + EL * i + 2, t);
		wr32(E1 + EL * i + 4, enc(x, t & T_FLT));
		wr32(E1 + EL * i + 8, enc(y, t & T_FLT));
		type[i] = t;
		ex[i] = x * M.m[0] + y * M.m[2] + (t & T_REL ? 0 : M.m[4]);
		ey[i] = x * M.m[1] + y * M.m[3] + (t & T_REL ? 0 : M.m[5]);
	}
	wr16(E1 + EL * n + 2, T_END);
	memcpy(ram + E2, ram + E1, EL * (n + 1));
	wr32(P1 + 4, E1); wr32(P1 + 8, n);
	wr32(P2 + 4, E2); wr32(P2 + 8, n);
	call(sym("_sh_cg6_Path_Transform"), 3, CANVAS, P1, 0);
	wr8(CANVAS + 6, 0);
	call(sym("_sh_fb_Path_Transform"), 3, CANVAS, P2, 0);
	for (int i = 0; i < n; i++) {
		int t1 = rd16(E1 + EL * i + 2), t2 = rd16(E2 + EL * i + 2), f1 = t1 & T_FLT, f2 = t2 & T_FLT;
		double x1 = dec(rd32(E1 + EL * i + 4), f1), y1 = dec(rd32(E1 + EL * i + 8), f1);
		double x2 = dec(rd32(E2 + EL * i + 4), f2), y2 = dec(rd32(E2 + EL * i + 8), f2);
		pa_elems++;
		if (t1 != t2 && (t1 & ~T_FLT) == (t2 & ~T_FLT))
			pa_fixfloat++;	/* xnews's TEC path keeps fixed what its software makes float */
		if ((t1 & ~T_FLT) != (type[i] & ~T_FLT) || (t2 & ~T_FLT) != (type[i] & ~T_FLT)) {
			pa_types_bad++;
			if (verbose)
				printf("  path element %d: type %02x, the TEC's %02x, software's %02x\n", i, type[i], t1, t2);
		}
		if (verbose)
			printf("  path %s el %d type %02x: exact %.5f %.5f TEC(%02x) %.5f %.5f sw(%02x) %.5f %.5f\n",
			       M.flt ? "float" : "fixed", i, type[i], ex[i], ey[i], t1, x1, y1, t2, x2, y2);
		if (!f1 && (fabs(ex[i]) >= 32767 || fabs(ey[i]) >= 32767)) {
			pa_range++;		/* beyond 16.16 */
			continue;
		}
		agree_add(&pa_tec_ex[!!f1], x1, ex[i], f1);
		agree_add(&pa_tec_ex[!!f1], y1, ey[i], f1);
		agree_add(&pa_sw_ex[!!f2], x2, ex[i], f2);
		agree_add(&pa_sw_ex[!!f2], y2, ey[i], f2);
		if (f1 == f2) {
			agree_add(&pa_tec_sw[!!f1], x1, x2, f1);
			agree_add(&pa_tec_sw[!!f1], y1, y2, f1);
		}
	}
}

/* ---- drawing: _sh_lg_vec_2U and _sh_lg_area_2US with autoload ---- */
#define G_ORIGX		0x1398f8	/* the window's origin, 16.16 */
#define G_ORIGY		0x1398fc
#define G_CURVE		0x139944	/* the curve flattener */
#define GS_CANVAS	0x00
#define GS_CPX		0x6a
#define GS_CPY		0x6e
#define K_FB		0x3c
#define K_CLIPKIND	0x51
#define K_CLIP		0x52

static uint32_t GS, KV;
static unsigned long ndraw_tests, ndraw_bad, ndraw_pix;

static void draw_setup(int *ox, int *oy, int clip[4])
{
	int fcol = rn(256);

	mirror = 1;			/* the reference's FBC is set up as the board's */
	*ox = rn(4) ? rn(400) : 0;
	*oy = rn(4) ? rn(300) : 0;
	clip[0] = rn(4) ? 0 : rn(500);			/* min x, min y, max x, max y */
	clip[1] = rn(4) ? 0 : rn(400);
	clip[2] = rn(4) ? CG6_W - 1 : clip[0] + rn(CG6_W - clip[0]);
	clip[3] = rn(4) ? CG6_H - 1 : clip[1] + rn(CG6_H - clip[1]);
	wr32(G_ORIGX, (uint32_t)*ox << 16);
	wr32(G_ORIGY, (uint32_t)*oy << 16);
	wr32(G_CURVE, sym("_sh_lg_curve_vec_disp"));
	wr32(GS + GS_CANVAS, KV);
	wr32(KV + K_FB, FBS);
	wr8(KV + K_CLIPKIND, 0);
	wr16(KV + K_CLIP + 0, clip[1]);
	wr16(KV + K_CLIP + 2, clip[3] + 1);
	wr16(KV + K_CLIP + 4, clip[0]);
	wr16(KV + K_CLIP + 6, clip[2] + 1);
	wr16(KV + K_CLIP + 8, 0x8001);
	wr16(KV + K_CLIP + 10, 0x8000);
	/* the raster as _sh_lg_Path_Raster leaves it (0x42006..0x42636): the
	   identity at 0x22 again if a transform used it (FB_FLAGS bit 5 clear),
	   MV's index 0x22, VDC fixed; then the FBC's colour and clip */
	wr16(FBS + FB_VDC, 0x2000);
	tec_w(0x008, (tec_r(0x008) & ~0xe000u) | 0x2000);
	if (!(ram[FBS + FB_FLAGS] & 0x20)) {
		call(sym("_sh_lg_load_ident"), 2, VBASE, 0x22);
		wr32(FBS + FB_CANVAS, 0);
		wr8(FBS + FB_FLAGS, ram[FBS + FB_FLAGS] | 0x20);
	}
	tec_w(0x000, (tec_r(0x000) & ~0x3fu) | 0x22);
	/* sometimes a translation in it, as _sh_lg_area_2GS puts the origin
	   there (0xeea7c): relative vertices must not have it */
	if (rn(4) == 0) {
		tec_w(0x190, (uint32_t)(rn(200) << 16 | rn(65536)));
		tec_w(0x19c, (uint32_t)(rn(200) << 16 | rn(65536)));
		wr8(FBS + FB_FLAGS, ram[FBS + FB_FLAGS] & ~0x20);	/* the identity, again, next */
	}
	fbc_w(0x108, 0xa980ff00);			/* the foreground colour */
	fbc_w(0x100, fcol);
	fbc_w(0x10c, 0xff);
	fbc_w(0x110, 0xffffffff);
	fbc_w(0x0e0, clip[0]); fbc_w(0x0e4, clip[1]);
	fbc_w(0x0f0, clip[2]); fbc_w(0x0f4, clip[3]);
}

static void draw_check(const char *what)
{
	unsigned long bad = 0;

	ndraw_tests++;
	for (int i = 0; i < CG6_W * CG6_H; i++)
		bad += G.fb[i] != R.fb[i];
	if (bad) {
		ndraw_bad++;
		ndraw_pix += bad;
		if (verbose)
			printf("  %s: %lu pixels differ from the exact vertices'\n", what, bad);
		memcpy(R.fb, G.fb, sizeof R.fb);	/* the next test starts level */
	}
}

static double coord(int flt, double lo, double hi)
{
	double v = rf(lo, hi);
	if (rn(6) == 0) v = floor(v) + (rn(2) ? 0.5 : 0.0);
	return flt ? (double)(float)v : fx(v);
}

static void put_el(uint32_t E, int i, int t, double x, double y)
{
	wr16(E + EL * i, 0);
	wr16(E + EL * i + 2, t);
	wr32(E + EL * i + 4, enc(x, t & T_FLT));
	wr32(E + EL * i + 8, enc(y, t & T_FLT));
}

static void test_vec(void)
{
	int ox, oy, clip[4], n = 2 + rn(rn(4) ? 6 : 30);
	uint32_t E = alloc(EL * (n + 2));
	double cx = rf(0, 1000), cy = rf(0, 800);

	draw_setup(&ox, &oy, clip);
	cx = fx(cx); cy = fx(cy);
	wr32(GS + GS_CPX, enc(cx, 0));
	wr32(GS + GS_CPY, enc(cy, 0));
	for (int i = 0; i < n; i++) {
		int flt = rn(3) == 0, rel = i && rn(3) == 0;
		int t = (i && rn(8) ? T_LINE : 0) | (flt ? T_FLT : 0) | (rel ? T_REL : 0);
		double x, y;
		if (rel) { x = coord(flt, -150, 150); y = coord(flt, -150, 150); }
		else { x = coord(flt, -200, 1300); y = coord(flt, -200, 1000); }
		put_el(E, i, t, x, y);
	}
	wr16(E + EL * n + 2, T_END);
	mirror = 1;
	call(sym("_sh_lg_vec_2U"), 3, GS, E, 0);
	mirror = 0;
	draw_check("vec_2U");
}

/* a polygon as xnews's fill gets it: a fan of quadrilaterals, a draw (0x43)
   after each, each after the first given the last one's last vertex again
   (xnews begins it at the FBC's vertex at MISC's index: the fan's first);
   or one quadrilateral of relative vertices */
static void test_area(void)
{
	int ox, oy, clip[4], k = 3 + rn(rn(3) ? 6 : 16), flt = rn(3) == 0, rel = rn(4) == 0;
	uint32_t E;
	double cx = rf(100, 1000), cy = rf(100, 800), r = rn(4) ? rf(5, 150) : rf(100, 600);
	double px[32], py[32], sq = rn(2) ? 1 : 0.4;
	int ne = 0, t = T_LINE | (flt ? T_FLT : 0);

	if (rel)
		k = 3 + rn(2);
	E = alloc(EL * (2 * k + 8));
	draw_setup(&ox, &oy, clip);
	wr32(GS + GS_CPX, 0);
	wr32(GS + GS_CPY, 0);
	for (int i = 0; i < k; i++) {
		double a = 2 * M_PI * i / k + rf(0, 0.5 / k);
		px[i] = cx + r * cos(a);
		py[i] = cy + r * sin(a) * sq;
		px[i] = flt ? (double)(float)px[i] : fx(px[i]);
		py[i] = flt ? (double)(float)py[i] : fx(py[i]);
	}
	put_el(E, ne++, flt ? T_FLT : 0, px[0], py[0]);
	if (rel) {
		for (int i = 1; i < k; i++) {
			double dx = px[i] - px[i - 1], dy = py[i] - py[i - 1];
			put_el(E, ne++, t | T_REL, flt ? (double)(float)dx : fx(dx), flt ? (double)(float)dy : fx(dy));
		}
		wr16(E + EL * ne++ + 2, 0x43);
	} else {
		int last = 0;
		for (int i = 1; i < 4 && i < k; i++)
			put_el(E, ne++, t, px[i], py[i]), last = i;
		wr16(E + EL * ne++ + 2, 0x43);
		while (last < k - 1) {
			put_el(E, ne++, t, px[last], py[last]);
			for (int j = 0; j < 2 && last < k - 1; j++)
				last++, put_el(E, ne++, t, px[last], py[last]);
			wr16(E + EL * ne++ + 2, 0x43);
		}
	}
	wr16(E + EL * ne + 2, T_END);
	/* the reference draws the fan itself, from the exact vertices rounded
	   down (and through the translation, if any): a point at the first,
	   then each quadrilateral's own, as xnews's restart should begin it */
	{
		double tx = u2f(G.tec_data[0x24]), ty = u2f(G.tec_data[0x27]);
		int32_t qx[32], qy[32];
		for (int i = 0; i < k; i++) {
			qx[i] = (int32_t)floor(px[i] + tx);
			qy[i] = (int32_t)floor(py[i] + ty);
		}
		cg6_write(&R, CG6_FBC + 0x0c0, 4, ox);
		cg6_write(&R, CG6_FBC + 0x0c4, 4, oy);
		for (int last = 0, first = 1; last < k - 1; first = 0) {
			int n = first ? 3 : 2;
			cg6_write(&R, CG6_FBC + 0x804, 4, qy[0]);
			cg6_write(&R, CG6_FBC + 0x800, 4, qx[0]);
			if (!first) {
				cg6_write(&R, CG6_FBC + 0x8c4, 4, qy[last]);
				cg6_write(&R, CG6_FBC + 0x8c0, 4, qx[last]);
			}
			for (int j = 0; j < n && last < k - 1; j++) {
				last++;
				cg6_write(&R, CG6_FBC + 0x8c4, 4, qy[last]);
				cg6_write(&R, CG6_FBC + 0x8c0, 4, qx[last]);
			}
			cg6_read(&R, CG6_FBC + FBC_DRAWSTATUS, 4);
		}
	}
	mirror = 2;
	call(sym("_sh_lg_area_2US"), 3, GS, E, 0);
	mirror = 0;
	draw_check("area_2US");
}

/* ---- -T: the TEC's arithmetic against the host's (IEEE single) ---- */
static int tec_selftest(void)
{
	unsigned long bad = 0, n = 0;

	for (int i = 0; i < 4000000; i++) {
		/* normal operands whose results are normal: there the TEC is IEEE */
		float a = (float)(rf(-1, 1) * ldexp(1.0, rn(60) - 30)), b = (float)(rf(-1, 1) * ldexp(1.0, rn(60) - 30));
		int32_t iv = (int32_t)rnd() >> rn(31);
		float p, s;
		uint32_t q;
		if (rn(8) == 0) b = -a * (float)ldexp(1.0, rn(3) - 1);	/* cancellation */
		else if (rn(8) == 0) b = -a + (float)ldexp(a, -rn(26));
		p = a * b;
		s = a + b;
		n += 5;
		if (f2u(p) != tec_fmul(f2u(a), f2u(b))) { if (bad++ < 5) printf("mul %a %a\n", a, b); }
		if (f2u(s) != tec_fadd(f2u(a), f2u(b))) { if (bad++ < 5) printf("add %a %a: %08x %08x\n", a, b, f2u(s), tec_fadd(f2u(a), f2u(b))); }
		if (f2u((float)iv) != tec_i2f(iv, 0)) { if (bad++ < 5) printf("i2f %d\n", iv); }
		if (f2u((float)(iv / 65536.0)) != tec_i2f(iv, 16)) { if (bad++ < 5) printf("x2f %d\n", iv); }
		q = tec_f2i(f2u(a * 70000.0f), 0);
		{
			double d = floor((double)(a * 70000.0f));
			int32_t want = d >= 2147483647.0 ? 0x7fffffff : d <= -2147483648.0 ? (int32_t)0x80000000 : (int32_t)d;
			if ((int32_t)q != want) { if (bad++ < 5) printf("f2i %a\n", a * 70000.0f); }
		}
	}
	printf("-T: %lu operations, %lu differ from the host's IEEE single\n", n, bad);
	return bad != 0;
}

int main(int argc, char **argv)
{
	long n = 200;
	const char *ini = NULL, *fin = NULL;
	FILE *f;

	if (argc >= 2 && !strcmp(argv[1], "-T"))
		return tec_selftest();
	if (argc < 2) {
		fprintf(stderr, "usage: xnews68k XNEWS [-n N] [-s seed] [-t trace -I initial -F final] [-v]\n");
		return 2;
	}
	for (int i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "-n") && i + 1 < argc) n = atol(argv[++i]);
		else if (!strcmp(argv[i], "-s") && i + 1 < argc) { rs += 0x9E3779B97F4A7C15ull * strtoull(argv[++i], 0, 0); for (int k = 0; k < 20; k++) rnd(); }
		else if (!strcmp(argv[i], "-t") && i + 1 < argc) { if (!(trace = fopen(argv[++i], "w"))) die("can't write %s", argv[i]); }
		else if (!strcmp(argv[i], "-I") && i + 1 < argc) ini = argv[++i];
		else if (!strcmp(argv[i], "-F") && i + 1 < argc) fin = argv[++i];
		else if (!strcmp(argv[i], "-v")) verbose = 1;
		else if (!strcmp(argv[i], "-c")) check = 1;
		else if (!strcmp(argv[i], "-k") && i + 1 < argc) kinds = atoi(argv[++i]);
		else die("unknown argument %s", argv[i]);
	}
	ram = calloc(1, RAM_SIZE);
	load_aout(argv[1]);
	cpu_init();
	trap("_sh_error_int");
	trap("_sh_fatal_int");
	trap("_sh_lg_curve_vec_disp");
	trap("_sh_lg_curve_area_disp");
	trap("_sh_lg_area_2GS");
	trap("_sh_lg_L2Ds");
	cg6_reset(&G);
	for (int i = 0; i < CG6_W * CG6_H; i++)
		G.fb[i] = rnd() >> 24;
	memset(G.fb + CG6_W * CG6_H, 0, CG6_FBSIZE - CG6_W * CG6_H);
	if (ini && (!(f = fopen(ini, "wb")) || fwrite(G.fb, 1, CG6_W * CG6_H, f) != CG6_W * CG6_H || fclose(f)))
		die("can't write %s", ini);
	G.trace = tracefn;
	cg6_reset(&R);
	memcpy(R.fb, G.fb, sizeof R.fb);
	GS = alloc(0x100);
	KV = alloc(0x100);
	init_cg6();
	for (long i = 0; i < n; i++) {
		int k = rn(8) >> 1;
		if (!(kinds >> k & 1)) { i--; continue; }
		switch (k) {
		case 0: test_point(); break;
		case 1: test_path(); break;
		case 2: test_vec(); break;
		default: test_area(); break;
		}
		heap = HEAP_BASE + 0x1000;	/* GS, KV, FBS, CANVAS stay */
	}
	if (trace)
		fclose(trace);
	if (fin && (!(f = fopen(fin, "wb")) || fwrite(G.fb, 1, CG6_W * CG6_H, f) != CG6_W * CG6_H || fclose(f)))
		die("can't write %s", fin);
	printf("xnews: %ld tests, %lu million 68020 instructions, %lu board accesses, %lu libc calls\n",
	       n, icount / 1000000, nboard, nplt_calls);
	printf("  the TEC: %lu vertices (%lu autoloaded), %lu commands\n", G.ntec_vertex, G.ntec_auto, G.ntec_cmd);
	for (int i = 0; i < 3; i++) agree_print(&pt_tec_ex[i]);
	for (int i = 0; i < 2; i++) agree_print(&pt_sw_ex[i]);
	for (int i = 0; i < 2; i++) agree_print(&pt_tec_sw[i]);
	for (int i = 0; i < 2; i++) agree_print(&pa_tec_ex[i]);
	for (int i = 0; i < 2; i++) agree_print(&pa_sw_ex[i]);
	for (int i = 0; i < 2; i++) agree_print(&pa_tec_sw[i]);
	printf("  path elements %lu: %lu of another kind; %lu left fixed by xnews's TEC path where its software "
	       "makes them float; %lu points and elements beyond 16.16's range, not counted\n", pa_elems, pa_types_bad, pa_fixfloat, pa_range);
	printf("  drawing: %lu autoloaded vertices, %lu not the exact one rounded down; "
	       "%lu tests, %lu with pixels that differ (%lu pixels)\n",
	       nvert, nvert_bad, ndraw_tests, ndraw_bad, ndraw_pix);
	if (check) {
		int bad = 0;
		for (int i = 0; i < 2; i++) {
			if (i == 1 && (pt_tec_sw[i].exact != pt_tec_sw[i].n || pa_tec_sw[i].exact != pa_tec_sw[i].n))
				bad++, printf("-c: float results not the software's\n");
			if (pa_tec_ex[i].pix < pa_tec_ex[i].n * 0.995 || pt_tec_ex[i].pix < pt_tec_ex[i].n * 0.995)
				bad++, printf("-c: %s results off the exact pixel\n", i ? "float" : "fixed");
		}
		if (pt_tec_ex[2].exact < pt_tec_ex[2].n * 0.995)
			bad++, printf("-c: integer results not the exact ones\n");
		if (nvert_bad > nvert / 1000 || !nvert)
			bad++, printf("-c: autoloaded vertices not the exact ones\n");
		if (pa_types_bad)
			bad++, printf("-c: path elements of another kind\n");
		if (ndraw_bad > ndraw_tests / 200 || !ndraw_tests)
			bad++, printf("-c: drawn otherwise than the exact vertices draw\n");
		printf("-c: %s\n", bad ? "FAIL" : "ok");
		return bad != 0;
	}
	return 0;
}
