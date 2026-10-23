/*
 * cg6model harness: run SunOS's own libpixrect against the GX model.
 *
 * The image is Sun's libpixrect object code, linked flat by aoutlink.py and
 * run in sparc.c (SunOS 4.1.3's SPARC library), or, built with -DM68K as
 * harness68k, on Musashi as a 68020 (SunOS 4.1.1's sun3 library).  RAM is
 * 0..32 MiB; the board appears where pr_makefromfd would have mapped it
 * (cg6reg.h's CG6_VADDR layout from 0x70000000, the same in both of its
 * branches), and every load or store libpixrect makes there becomes a bus
 * cycle on the model, in the board's own offsets.  libc and Sun's runtime
 * (.mul, .div, malloc ...) are served in C: an undefined symbol is `unimp 0;
 * nop' on SPARC, `illegal; rts' on the 68020.  Only the CPU back-end
 * (below, "the CPU") differs between the two; the tests are the same.
 *
 * Each test does one operation twice: through the cg6 routines on the model,
 * and through libpixrect's memory-pixrect routines (mem_rop, mem_vector,
 * the generic polygon, line and text code) on a 1152x900x8 mirror in RAM,
 * and compares every pixel.  So the reference is Sun's own definition of
 * what the operation means, and the thing under test is the board model as
 * Sun's cg6 code drives it.  Sun's cg6 code falls back to the mem routines
 * on the frame buffer when the board reports an exception; the harness
 * counts those (`fallback') and the model raises none.
 *
 * usage: harness IMAGE.bin IMAGE.sym [-n iterations] [-s seed] [-v] [-S]
 *                [-b polls] [-t trace -I initial -F final] [-k test]
 *                [-L x0,y0,x1,y1,op,colour] [-P x,y,x,y,...]
 *
 * -b makes the engine report busy (and refuse commands) for that many
 * status reads after each command, to exercise the software's wait loops.
 * -S prints, per test kind, which FBC registers Sun's code wrote.
 * -t writes every board access from the starting image on, as
 * "r<size> <offset> <data>" or "w..." (offsets in the P4 window); -I and -F
 * write the 1152x900 frame buffer before the first and after the last, so
 * that an RTL bench can replay the three (the Sun-2's tb_cgtwo does this
 * with tools/cg2model's).  -k N traces test N alone to stdout; -L draws one
 * vector, traced; -P prints the spans pr_polygon_2 draws in memory.
 *
 * harness -R trace initial final [polls] replays a trace on a fresh model and
 * checks it ends at the final image: the trace is complete.
 *
 * -K kind,kind,... runs only those kinds of test (fill copy mem8 mem1 mem1rv
 * readback putget vector batchrop stencil replrop polygon polyline
 * polypoint), so that a trace holds only what an RTL stage draws.
 *
 * harness -G prefix [-n N] [-s seed] needs no library: it writes test_prom's
 * sequence and N tests that drive the engine directly as traces, each with
 * its frame buffer before and after (gen_run, below), for tb/verilator's
 * tb_cg6.
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef M68K
#include "m68k.h"
#else
#include "sparc.h"
#endif
#include "cg6model.h"

#define RAM_SIZE	0x2000000
#define IMAGE_BASE	0x10000
#define HEAP_END	0x1e00000
#define STACK_TOP	0x1ff0000
#define RET_ADDR	0x0f00		/* `unimp 1' (illegal): a call has returned */
#define CRASH_ADDR	0x0f10		/* 68020: illegal; an exception was taken */

/* where pr_makefromfd maps the board (cg6reg.h: CG6_VBASE, CG6_VADDR) */
#define VBASE		0x70000000u
#define V_FBC		(VBASE + 0x0000)	/* FBC, then TEC at +0x1000 */
#define V_CMAP		(VBASE + 0x2000)
#define V_FHC		(VBASE + 0x4000)	/* FHC, then THC at +0x1000 */
#define V_ROM		(VBASE + 0x6000)
#define V_COLOR		(VBASE + 0x16000)
#define V_END		(V_COLOR + CG6_FBSIZE)

#define PIX_SRC		(0xC << 1)
#define PIX_DST		(0xA << 1)
#define PIX_DONTCLIP	1
#define PIX_COLOR(c)	((c) << 5)
#define MP_REVERSEVIDEO	1

static uint8_t *ram;
static struct cg6 G;
#ifndef M68K
static struct sparc C;
#endif
static FILE *trace;
static int verbose, stats;
static const char *one_vector, *one_poly, *initial_path, *final_path;
static unsigned long nboard;

static uint32_t cpu_pc(void);
#ifdef M68K
#define ICOUNT	icount
#else
#define ICOUNT	C.icount
#endif

static void die(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, " (pc %08x)\n", cpu_pc());
	exit(2);
}

/* ---- RAM, big-endian ---- */
static uint32_t rd8(uint32_t a) { return ram[a]; }
static uint32_t rd16(uint32_t a) { return ram[a] << 8 | ram[a + 1]; }
static uint32_t rd32(uint32_t a) { return rd16(a) << 16 | rd16(a + 2); }
static void wr8(uint32_t a, uint32_t v) { ram[a] = v; }
static void wr16(uint32_t a, uint32_t v) { ram[a] = v >> 8; ram[a + 1] = v; }
static void wr32(uint32_t a, uint32_t v) { wr16(a, v >> 16); wr16(a + 2, v); }

/* ---- the board ---- */
static uint32_t board_off(uint32_t a)
{
	if (a < V_FBC + 0x2000) return CG6_FBC + (a - V_FBC);	/* FBC, TEC */
	if (a < V_CMAP + 0x2000) return CG6_DAC + (a - V_CMAP);
	if (a < V_FHC + 0x2000) return CG6_FHC + (a - V_FHC);	/* FHC, THC */
	if (a < V_COLOR) return CG6_ROM + (a - V_ROM);
	return CG6_FB + (a - V_COLOR);
}

/* -S: which FBC registers each kind of test writes */
#define NCAT 24
static char cats[NCAT][24], cat[24];
static uint32_t reguse[NCAT][0x1000 / 4 / 32];
static unsigned long fbuse[NCAT][2];

/*
 * A call that writes the font register more than font_limit times is
 * stopped there (test_stencil): cg6_stencil's dbra loop on the 68020.
 */
static unsigned long nfontw, font_limit;
static int stopped;
static void cpu_stop(void);

static int catno(void)
{
	for (int i = 0; i < NCAT; i++) {
		if (!cats[i][0])
			strcpy(cats[i], cat);
		if (!strcmp(cats[i], cat))
			return i;
	}
	return NCAT - 1;
}

static void tracefn(void *arg, int wr, uint32_t off, int size, uint32_t v)
{
	(void)arg;
	nboard++;
	if (wr && off == CG6_FBC + FBC_FONT && font_limit && ++nfontw > font_limit && !stopped) {
		stopped = 1;
		cpu_stop();
	}
	if (trace)
		fprintf(trace, "%c%d %06x %08x\n", wr ? 'w' : 'r', size, off, v);
	if (stats && cat[0]) {
		int c = catno();
		if (off >= CG6_FB)
			fbuse[c][wr]++;
		else if (wr && off >= CG6_FBC && off < CG6_FBC + 0x1000) {
			uint32_t r = (off - CG6_FBC) >> 2;
			reguse[c][r >> 5] |= 1u << (r & 31);
		}
	}
}

static int board(uint32_t a) { return a >= VBASE && a < V_END; }

static uint32_t mem_rd(uint32_t a, int size)
{
	if (board(a))
		return cg6_read(&G, board_off(a), size);
	if (a + size > RAM_SIZE)
		die("read of %08x", a);
	return size == 4 ? rd32(a) : size == 2 ? rd16(a) : rd8(a);
}

static void mem_wr(uint32_t a, int size, uint32_t v)
{
	if (board(a)) {
		cg6_write(&G, board_off(a), size, v);
		return;
	}
	if (a + size > RAM_SIZE || a < 0x1000)
		die("write of %08x", a);
	if (size == 4) wr32(a, v); else if (size == 2) wr16(a, v); else wr8(a, v);
}

/* ---- symbols ---- */
struct sym { char name[64]; uint32_t addr; int stub; };
static struct sym syms[1024];
static int nsyms;
static uint32_t image_end;

static void load_syms(const char *path)
{
	FILE *f = fopen(path, "r");
	char line[160], name[64], kind[16];
	unsigned addr;

	if (!f)
		die("can't open %s", path);
	while (fgets(line, sizeof line, f)) {
		kind[0] = 0;
		if (sscanf(line, "%x %63s %15s", &addr, name, kind) < 2)
			continue;
		if (nsyms == 1024)
			die("too many symbols");
		snprintf(syms[nsyms].name, sizeof syms[0].name, "%s", name);
		syms[nsyms].addr = addr;
		syms[nsyms].stub = !strcmp(kind, "stub");
		if (!strcmp(name, "_end"))
			image_end = addr;
		nsyms++;
	}
	fclose(f);
}

static uint32_t sym(const char *name)
{
	for (int i = 0; i < nsyms; i++)
		if (!strcmp(syms[i].name, name))
			return syms[i].addr;
	die("no symbol %s", name);
	return 0;
}

/* ---- a heap in RAM ---- */
struct blk { uint32_t addr, size; int used; };
static struct blk heap[8192];
static int nheap;

static void heap_init(void)
{
	uint32_t base = (image_end + 0xffff) & ~0xffffu;

	heap[0] = (struct blk){ base, HEAP_END - base, 0 };
	nheap = 1;
}

static uint32_t h_alloc(uint32_t n)
{
	n = (n + 15) & ~15u;
	if (!n)
		n = 16;
	for (int i = 0; i < nheap; i++) {
		if (heap[i].used || heap[i].size < n)
			continue;
		if (heap[i].size > n) {
			if (nheap == 8192)
				die("heap fragmented");
			memmove(&heap[i + 2], &heap[i + 1], (nheap - i - 1) * sizeof heap[0]);
			heap[i + 1] = (struct blk){ heap[i].addr + n, heap[i].size - n, 0 };
			heap[i].size = n;
			nheap++;
		}
		heap[i].used = 1;
		return heap[i].addr;
	}
	die("out of heap (%u)", n);
	return 0;
}

static uint32_t h_size(uint32_t a)
{
	for (int i = 0; i < nheap; i++)
		if (heap[i].addr == a && heap[i].used)
			return heap[i].size;
	return 0;
}

static void h_free(uint32_t a)
{
	for (int i = 0; i < nheap; i++) {
		if (heap[i].addr != a)
			continue;
		if (!heap[i].used)
			die("double free %08x", a);
		heap[i].used = 0;
		if (i + 1 < nheap && !heap[i + 1].used) {
			heap[i].size += heap[i + 1].size;
			memmove(&heap[i + 1], &heap[i + 2], (nheap - i - 2) * sizeof heap[0]);
			nheap--;
		}
		if (i > 0 && !heap[i - 1].used) {
			heap[i - 1].size += heap[i].size;
			memmove(&heap[i], &heap[i + 1], (nheap - i - 1) * sizeof heap[0]);
			nheap--;
		}
		return;
	}
	if (a)
		die("free of %08x, never allocated", a);
}

/* ---- the CPU: arguments and results of a stub, a call into the image ---- */
#ifdef M68K
/* the 68020's: arguments on the stack above the return address, the
   result in d0 (d0, d1, a0, a1 scratch) */
static unsigned long icount;
static volatile int returned;

static uint32_t cpu_pc(void) { return m68k_get_reg(NULL, M68K_REG_PPC); }
static uint32_t oarg(int i) { return rd32(m68k_get_reg(NULL, M68K_REG_SP) + 4 + 4 * i); }
static void ret(uint32_t v) { m68k_set_reg(M68K_REG_D0, v); }
static void ret2(uint32_t v) { m68k_set_reg(M68K_REG_D1, v); }
#else
/* SPARC's: arguments in %o0.., the result in %o0 */
static uint32_t cpu_pc(void) { return C.pc; }

static uint32_t oarg(int i)
{
	if (i < 6)
		return sparc_get(&C, R_O(i));
	return rd32(sparc_get(&C, R_SP) + 0x5c + 4 * (i - 6));
}

static void ret(uint32_t v) { sparc_set(&C, R_O(0), v); }
static void ret2(uint32_t v) { sparc_set(&C, R_O(1), v); }
#endif

static void fbmake(void);

static void stub(const char *name)
{
	int32_t a = oarg(0), b = oarg(1);

	if (!strcmp(name, "_malloc") || !strcmp(name, "_valloc"))
		ret(h_alloc(a));
	else if (!strcmp(name, "_calloc")) {
		uint32_t p = h_alloc((uint32_t)a * b);
		memset(&ram[p], 0, (uint32_t)a * b);
		ret(p);
	} else if (!strcmp(name, "_realloc")) {
		uint32_t p = h_alloc(b), old = h_size(a);
		if (a)
			memcpy(&ram[p], &ram[a], old < (uint32_t)b ? old : (uint32_t)b);
		h_free(a);
		ret(p);
	} else if (!strcmp(name, "_free"))
		h_free(a);
	else if (!strcmp(name, "_bzero")) {
		if (board(a) || board(a + b - 1))	/* cg6_reset_uregs: the TEC */
			for (int32_t i = 0; i < b; i++)
				mem_wr(a + i, 1, 0);
		else
			memset(&ram[a], 0, b);
	}
	else if (!strcmp(name, "_abs"))
		ret(a < 0 ? -a : a);
	else if (!strcmp(name, "_getpagesize"))
		ret(8192);
	else if (!strcmp(name, "_getenv"))
		ret(0);
	else if (!strcmp(name, ".mul")) {
		int64_t p = (int64_t)a * b;
		ret((uint32_t)p);
		ret2((uint64_t)p >> 32);
	} else if (!strcmp(name, ".umul")) {
		uint64_t p = (uint64_t)(uint32_t)a * (uint32_t)b;
		ret((uint32_t)p);
		ret2(p >> 32);
	} else if (!strcmp(name, ".div")) {
		if (!b) die(".div by zero");
		ret(a / b);
	} else if (!strcmp(name, ".rem")) {
		if (!b) die(".rem by zero");
		ret(a % b);
	} else if (!strcmp(name, ".udiv")) {
		if (!b) die(".udiv by zero");
		ret((uint32_t)a / (uint32_t)b);
	} else if (!strcmp(name, ".urem")) {
		if (!b) die(".urem by zero");
		ret((uint32_t)a % (uint32_t)b);
	} else if (!strcmp(name, "_pr_makefromfd"))
		fbmake();
	else if (!strcmp(name, "_pr_unmakefromfd"))
		ret(0);
	else if (!strcmp(name, "_ioctl"))
		ret(0);
	else
		die("unexpected call to %s", name);
}

#ifdef M68K
unsigned int m68k_read_memory_8(unsigned int a) { return mem_rd(a, 1); }
unsigned int m68k_read_memory_16(unsigned int a) { return mem_rd(a, 2); }
unsigned int m68k_read_memory_32(unsigned int a) { return mem_rd(a, 4); }
void m68k_write_memory_8(unsigned int a, unsigned int v) { mem_wr(a, 1, v); }
void m68k_write_memory_16(unsigned int a, unsigned int v) { mem_wr(a, 2, v); }
void m68k_write_memory_32(unsigned int a, unsigned int v) { mem_wr(a, 4, v); }
unsigned int m68k_read_disassembler_16(unsigned int a) { return rd16(a % RAM_SIZE); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return rd32(a % RAM_SIZE); }

static void insn_hook(unsigned int pc) { (void)pc; icount++; }

/* end the call now: it returns, its result undefined */
static void cpu_stop(void)
{
	returned = 1;
	m68k_end_timeslice();
}

/* ILLEGAL at RET_ADDR (returned), CRASH_ADDR (every exception vector) or a
   stub; a stub's RTS follows it */
static int illegal(int opcode)
{
	uint32_t pc = cpu_pc();

	(void)opcode;
	if (pc == RET_ADDR) {
		returned = 1;
		m68k_end_timeslice();
		return 1;
	}
	if (pc == CRASH_ADDR)
		die("exception taken");
	for (int i = 0; i < nsyms; i++)
		if (syms[i].stub && syms[i].addr == pc) {
			stub(syms[i].name);
			return 1;
		}
	return 0;
}

static uint32_t call(const char *fn, int n, ...)
{
	uint32_t a[16], sp = STACK_TOP - 0x200;
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
	m68k_set_reg(M68K_REG_PC, sym(fn));
	returned = 0;
	for (long i = 0; !returned; i++) {
		if (i > 40000)
			die("%s does not return", fn);
		m68k_execute(100000);
	}
	return m68k_get_reg(NULL, M68K_REG_D0);
}

static void cpu_init(void)
{
	/* vectors: every exception lands on CRASH_ADDR */
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
#else
static int unimp(struct sparc *s, uint32_t insn)
{
	if (s->pc == RET_ADDR && insn == 1) {
		s->stop = 1;
		return 1;
	}
	for (int i = 0; i < nsyms; i++)
		if (syms[i].stub && syms[i].addr == s->pc) {
			stub(syms[i].name);
			s->pc = sparc_get(s, R_O7) + 8;
			s->npc = s->pc + 4;
			return 1;
		}
	return 0;
}

static uint32_t call(const char *fn, int n, ...)
{
	uint32_t a[16], sp = STACK_TOP - 0x200;
	va_list ap;

	va_start(ap, n);
	for (int i = 0; i < n; i++)
		a[i] = va_arg(ap, uint32_t);
	va_end(ap);
	for (int i = 0; i < n; i++) {
		if (i < 6)
			sparc_set(&C, R_O(i), a[i]);
		else
			wr32(sp + 0x5c + 4 * (i - 6), a[i]);
	}
	sparc_set(&C, R_SP, sp);
	sparc_set(&C, R_O7, RET_ADDR - 8);
	C.pc = sym(fn);
	C.npc = C.pc + 4;
	C.stop = 0;
	if (sparc_run(&C, 4000000000ul))
		die("%s: %s", fn, sparc_fault);
	if (!C.stop)
		die("%s does not return", fn);
	return sparc_get(&C, R_O(0));
}

static void cpu_stop(void) { C.stop = 1; }

static void cpu_init(void)
{
	wr32(RET_ADDR, 1);			/* unimp 1 */
	sparc_init(&C);
	C.rd = mem_rd;
	C.wr = mem_wr;
	C.unimp = unimp;
}
#endif

/* ---- pixrects in RAM ---- */
#define PR_OPS	0
#define PR_W	4
#define PR_H	8
#define PR_DEPTH 12
#define PR_DATA	16
/* struct mpr_data; struct cg6pr begins with one */
#define MD_LINEBYTES 0
#define MD_IMAGE 4
#define MD_OFFX	8
#define MD_OFFY	12
#define MD_FLAGS 18
#define CG6_PLANES 0x14

/*
 * pr_makefromfd(fd, size, depth, devdata, curdd, mmapsize, privsize, mmapoffset):
 * a pixrect with privsize bytes of private data, and *curdd pointing at a
 * device record (struct pr_devdata) whose va is where the board is mapped.
 * The struct pr_size goes by value: on SPARC as a pointer to a copy, on the
 * 68020 as its two words on the stack.  pr_devdata's dev_t is a short, so
 * fd and va are at +0xc and +0x10 on SPARC, +0xa and +0xe on the 68020
 * (where an int is 2-aligned; the sun3 cg6.o's cg6_make reads them there).
 */
#ifdef M68K
#define SZ_ARGS		2		/* a struct pr_size: two stack words */
#define DD_FD		0xa
#define DD_VA		0xe
#else
#define SZ_ARGS		1		/* a pointer to the copy */
#define DD_FD		0xc
#define DD_VA		0x10
#endif

static void fbmake(void)
{
	uint32_t curdd = oarg(3 + SZ_ARGS), privsize = oarg(5 + SZ_ARGS);
	uint32_t pr = h_alloc(20), d = h_alloc(privsize), dd = h_alloc(0x20);

	memset(&ram[d], 0, privsize);
	memset(&ram[dd], 0, 0x20);
	wr32(pr + PR_OPS, 0);
#ifdef M68K
	wr32(pr + PR_W, oarg(1));
	wr32(pr + PR_H, oarg(2));
#else
	wr32(pr + PR_W, rd32(oarg(1)));
	wr32(pr + PR_H, rd32(oarg(1) + 4));
#endif
	wr32(pr + PR_DEPTH, oarg(1 + SZ_ARGS));
	wr32(pr + PR_DATA, d);
	wr32(dd + DD_FD, oarg(0));
	wr32(dd + DD_VA, VBASE);
	wr32(curdd, dd);
	ret(pr);
}

static uint32_t mem_create(int w, int h, int depth)
{
	uint32_t pr = call("_mem_create", 3, w, h, depth);

	if (!pr)
		die("mem_create(%d, %d, %d) failed", w, h, depth);
	return pr;
}

static uint32_t md(uint32_t pr) { return rd32(pr + PR_DATA); }
static uint8_t *image(uint32_t pr) { return &ram[rd32(md(pr) + MD_IMAGE)]; }
static int linebytes(uint32_t pr) { return rd32(md(pr) + MD_LINEBYTES); }

/* ---- randomness ---- */
static uint64_t rs = 88172645463325252ull;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static int rn(int n) { return n > 0 ? (int)(rnd() % (unsigned)n) : 0; }

static void fill_random(uint8_t *p, size_t n)
{
	for (size_t i = 0; i < n; i++)
		p[i] = rnd();
}

/* ---- the comparison ---- */
static uint32_t FB;		/* the cg6 pixrect */
static uint32_t M;		/* the 1152x900x8 memory mirror */
static unsigned long ntests, nfail, nfallback, nmemdis, nsunbug, nrunaway;
static uint8_t before[CG6_W * CG6_H], ref[CG6_W * CG6_H];
static int have_ref;
static unsigned long fallback_mark;
static long testno, trace_test = -1;
static FILE *trace_file;

static void sync_mirror(void)
{
	memcpy(image(M), G.fb, CG6_W * CG6_H);
}

/*
 * The model against the mirror, which Sun's mem code drew.  Memory pixrects
 * have no plane mask, so it is applied here: the mirror's pixel where the
 * plane is enabled, the old pixel where it is not.
 */
static int compare(const char *what, uint8_t pm)
{
	uint8_t *m = image(M);
	int bad = 0;

	ntests++;
	if (have_ref) {
		int mbad = 0;
		have_ref = 0;
		if (!memcmp(G.fb, ref, CG6_W * CG6_H)) {
			for (int i = 0; i < CG6_W * CG6_H; i++)
				mbad += ((m[i] & pm) | (before[i] & ~pm)) != ref[i];
			if (mbad) {
				nmemdis++;
				if (verbose)
					fprintf(stderr, "note %s: the model is right by the definition, "
						"Sun's mem code differs in %d pixels\n", what, mbad);
			}
			sync_mirror();
			return 0;
		}
	}
	for (int i = 0; i < CG6_W * CG6_H; i++) {
		uint8_t want = (m[i] & pm) | (before[i] & ~pm);
		if (G.fb[i] != want && bad++ < 8)
			fprintf(stderr, "  %s: (%d,%d) model %02x, want %02x, was %02x\n",
				what, i % CG6_W, i / CG6_W, G.fb[i], want, before[i]);
	}
	if (bad) {
		nfail++;
		fprintf(stderr, "FAIL %s: %d pixels differ\n", what, bad);
	} else if (verbose)
		fprintf(stderr, "ok   %s\n", what);
	if (bad && verbose)
		fprintf(stderr, "     (test %ld)\n", testno);
	sync_mirror();
	return bad;
}

static void result_prom(const char *what, int bad)
{
	ntests++;
	if (bad) {
		nfail++;
		fprintf(stderr, "FAIL %s: %d checks\n", what, bad);
	} else if (verbose)
		fprintf(stderr, "ok   %s\n", what);
}

static void start(const char *what)
{
	int n = 0;

	testno++;
	if (trace_test >= 0)
		trace = testno == trace_test ? stdout : trace_file;
	if (testno == trace_test)
		printf("-- test %ld: %s\n", testno, what);

	while (what[n] && what[n] != ' ' && what[n] != '(' && n < 23)
		n++;
	memcpy(cat, what, n);
	cat[n] = 0;
	memcpy(before, G.fb, sizeof before);
	fallback_mark = 0;
}

/* ---- the frame buffer pixrect, and regions of it ---- */
static int planes = 0xff;

static void set_planes(uint32_t pr, int pm)
{
	wr32(md(pr) + CG6_PLANES, pm);
	planes = pm;
}

struct region { int ox, oy, w, h; };
static const struct region SCREEN = { 0, 0, CG6_W, CG6_H };

static struct region random_region(void)
{
	struct region r = SCREEN;

	if (rn(4) == 0) {
		r.ox = rn(CG6_W - 1);
		r.oy = rn(CG6_H - 1);
		r.w = 1 + rn(CG6_W - r.ox);
		r.h = 1 + rn(CG6_H - r.oy);
	}
	return r;
}

/* the region on both sides: cg6_region on the board, mem_region on the mirror */
static void regions(const struct region *r, uint32_t *d, uint32_t *m)
{
	if (r->ox == 0 && r->oy == 0 && r->w == CG6_W && r->h == CG6_H) {
		*d = FB;
		*m = M;
		return;
	}
	*d = call("_cg6_region", 5, FB, r->ox, r->oy, r->w, r->h);
	*m = call("_mem_region", 5, M, r->ox, r->oy, r->w, r->h);
}

static void regions_free(uint32_t d, uint32_t m)
{
	if (d != FB)
		call("_cg6_destroy", 1, d);
	if (m != M)
		call("_mem_destroy", 1, m);
}

static void rect(int bw, int bh, int *x, int *y, int *w, int *h)
{
	int big = rn(8) == 0;

	*w = 1 + rn(big ? bw : rn(4) ? 40 : 200);
	*h = 1 + rn(big ? bh : rn(4) ? 20 : 100);
	*x = rn(bw + 40) - 20;
	*y = rn(bh + 40) - 20;
}

static int random_op(void)
{
	return rn(16) << 1 | PIX_COLOR(rn(4) ? rn(256) : 0) | (rn(8) == 0 ? PIX_DONTCLIP : 0);
}

static uint32_t random_mpr(int w, int h, int depth, int rv)
{
	uint32_t pr = mem_create(w, h, depth);

	fill_random(image(pr), linebytes(pr) * h);
	if (rv)
		wr16(md(pr) + MD_FLAGS, MP_REVERSEVIDEO);
	return pr;
}

/* PIX_DONTCLIP: Sun's code then trusts the caller; keep such ops inside */
static void keep_inside(int op, const struct region *r, int *x, int *y, int *w, int *h)
{
	if (!(op & PIX_DONTCLIP))
		return;
	if (*x < 0) *x = 0;
	if (*y < 0) *y = 0;
	if (*x >= r->w) *x = r->w - 1;
	if (*y >= r->h) *y = r->h - 1;
	if (*x + *w > r->w) *w = r->w - *x;
	if (*y + *h > r->h) *h = r->h - *y;
}

/* ---- the tests ---- */

static void rop_ref(const struct region *, int, int, int, int, int, uint32_t, int, int, uint8_t);

/*
 * -K: the kinds of test that run, by name, for a trace that an RTL stage can
 * replay (docs/cg6.md, "Stages": stage 1 takes fills, text and copies).  The
 * first seven are test_rop's own kinds, in its order.
 */
static const char *const kind_names[] = {
	"fill", "copy", "mem8", "mem1", "mem1rv", "readback", "putget",
	"vector", "batchrop", "stencil", "replrop", "polygon", "polyline", "polypoint",
};
enum { K_ROP_KINDS = 7, K_VECTOR = 7, K_BATCH, K_STENCIL, K_REPLROP, K_POLYGON, K_POLYLINE, K_POLYPOINT, K_N };
static unsigned kinds = (1u << K_N) - 1;

static int rop_kind(void)
{
	int k;

	do k = rn(K_ROP_KINDS); while (!(kinds >> k & 1));
	return k;
}

static void parse_kinds(const char *s)
{
	char buf[256], *t;

	snprintf(buf, sizeof buf, "%s", s);
	kinds = 0;
	for (t = strtok(buf, ","); t; t = strtok(NULL, ",")) {
		int k;
		for (k = 0; k < K_N && strcmp(t, kind_names[k]); k++)
			;
		if (k == K_N)
			die("-K: no test kind %s", t);
		kinds |= 1u << k;
	}
	if (!kinds)
		die("-K: no test kinds");
}

static void test_rop(void)
{
	struct region r = random_region();
	int x, y, w, h, sx = 0, sy = 0, op = random_op(), kind = rop_kind();
	uint32_t d, m, spr = 0;
	char what[160];

	regions(&r, &d, &m);
	set_planes(d, rn(4) ? 0xff : rn(256));
	rect(r.w, r.h, &x, &y, &w, &h);
	keep_inside(op, &r, &x, &y, &w, &h);
	switch (kind) {
	case 0:
		snprintf(what, sizeof what, "fill op %02x at %d,%d %dx%d", op, x, y, w, h);
		start(what);
		call("_cg6_rop", 9, d, x, y, w, h, op, 0, 0, 0);
		call("_mem_rop", 9, m, x, y, w, h, op, 0, 0, 0);
		break;
	case 1:
		sx = rn(2) ? x + rn(41) - 20 : rn(r.w);
		sy = rn(2) ? y + rn(21) - 10 : rn(r.h);
		if (op & PIX_DONTCLIP) {
			if (sx < 0) sx = 0;
			if (sy < 0) sy = 0;
			if (sx + w > r.w) sx = r.w - w;
			if (sy + h > r.h) sy = r.h - h;
		}
		snprintf(what, sizeof what, "copy op %02x %d,%d to %d,%d %dx%d", op, sx, sy, x, y, w, h);
		start(what);
		call("_cg6_rop", 9, d, x, y, w, h, op, d, sx, sy);
		call("_mem_rop", 9, m, x, y, w, h, op, m, sx, sy);
		break;
	case 2: case 3: case 4: {
		int depth = kind == 2 ? 8 : 1;
		int sw = w + rn(40), shh = h + rn(20);

		spr = random_mpr(sw, shh, depth, kind == 4);
		sx = rn(sw - w + 1);
		sy = rn(shh - h + 1);
		snprintf(what, sizeof what, "%s op %02x to %d,%d %dx%d", kind == 2 ? "mem8" :
			 kind == 4 ? "mem1rv" : "mem1", op, x, y, w, h);
		start(what);
		call("_cg6_rop", 9, d, x, y, w, h, op, spr, sx, sy);
		call("_mem_rop", 9, m, x, y, w, h, op, spr, sx, sy);
		rop_ref(&r, x, y, w, h, op, spr, sx, sy, planes);
		break;
	}
	case 5: {	/* screen to memory */
		int dw = w + rn(40), dh = h + rn(20);
		uint32_t a = random_mpr(dw, dh, 8, 0), b = mem_create(dw, dh, 8);
		int bad = 0;

		memcpy(image(b), image(a), linebytes(a) * dh);
		snprintf(what, sizeof what, "readback op %02x %dx%d", op, w, h);
		start(what);
		op &= ~PIX_DONTCLIP;
		call("_cg6_rop", 9, a, 0, 0, w, h, op, d, x, y);
		call("_mem_rop", 9, b, 0, 0, w, h, op, m, x, y);
		ntests++;
		for (int i = 0; i < linebytes(a) * dh; i++)
			if (image(a)[i] != image(b)[i] && bad++ < 4)
				fprintf(stderr, "  %s: byte %d is %02x, want %02x\n", what, i,
					image(a)[i], image(b)[i]);
		if (bad) {
			nfail++;
			fprintf(stderr, "FAIL %s\n", what);
		} else if (verbose)
			fprintf(stderr, "ok   %s\n", what);
		call("_mem_destroy", 1, a);
		call("_mem_destroy", 1, b);
		regions_free(d, m);
		set_planes(FB, 0xff);
		return;
	}
	default: {	/* get and put */
		int px = rn(r.w), py = rn(r.h), v = rn(256);

		set_planes(d, 0xff);	/* mem_get and mem_put mask with it */

		snprintf(what, sizeof what, "put/get %d,%d", px, py);
		start(what);
		call("_cg6_put", 4, d, px, py, v);
		call("_mem_put", 4, m, px, py, v);
		if (call("_cg6_get", 3, d, px, py) != call("_mem_get", 3, m, px, py)) {
			nfail++;
			fprintf(stderr, "FAIL %s: get differs\n", what);
		}
		break;
	}
	}
	compare(what, planes);
	if (spr)
		call("_mem_destroy", 1, spr);
	regions_free(d, m);
	set_planes(FB, 0xff);
}

static void test_vector(void)
{
	struct region r = random_region();
	uint32_t d, m;
	int op = random_op(), color = rn(256), x0, y0, x1, y1;
	char what[160];

	regions(&r, &d, &m);
	x0 = rn(r.w + 60) - 30; y0 = rn(r.h + 60) - 30;
	if (rn(2)) {
		x1 = x0 + rn(81) - 40; y1 = y0 + rn(81) - 40;
	} else {
		x1 = rn(r.w + 60) - 30; y1 = rn(r.h + 60) - 30;
	}
	if (rn(6) == 0) y1 = y0;
	if (rn(6) == 0) x1 = x0;
	if (op & PIX_DONTCLIP) {
		x0 = x0 < 0 ? 0 : x0 >= r.w ? r.w - 1 : x0;
		x1 = x1 < 0 ? 0 : x1 >= r.w ? r.w - 1 : x1;
		y0 = y0 < 0 ? 0 : y0 >= r.h ? r.h - 1 : y0;
		y1 = y1 < 0 ? 0 : y1 >= r.h ? r.h - 1 : y1;
	}
	snprintf(what, sizeof what, "vector op %02x c %d %d,%d-%d,%d in %d,%d %dx%d",
		 op, color, x0, y0, x1, y1, r.ox, r.oy, r.w, r.h);
	start(what);
	call("_cg6_vector", 7, d, x0, y0, x1, y1, op, color);
	call("_mem_vector", 7, m, x0, y0, x1, y1, op, color);
	compare(what, 0xff);
	regions_free(d, m);
}

/* a font of random glyphs: struct pr_prpos { pr; pos.x, pos.y } x n */
static void test_batch(void)
{
	struct region r = random_region();
	uint32_t d, m, items, glyphs[8];
	int n = 1 + rn(20), op = random_op() & ~PIX_DONTCLIP, x = rn(r.w) - 10, y = rn(r.h);
	char what[160];

	regions(&r, &d, &m);
	for (int i = 0; i < 8; i++)
		glyphs[i] = random_mpr(1 + rn(24), 1 + rn(24), 1, 0);
	items = h_alloc(12 * n);
	for (int i = 0; i < n; i++) {
		wr32(items + 12 * i, rn(10) ? glyphs[rn(8)] : 0);
		wr32(items + 12 * i + 4, rn(20) - 2);
		wr32(items + 12 * i + 8, rn(5) ? 0 : rn(9) - 4);
	}
	/*
	 * Sun's cg6_batchrop sets the clip window for a glyph that the
	 * destination clips and leaves it there: a whole glyph after it, which
	 * takes the fast path and sets no clip, is clipped by the stale window
	 * (cg6_batch.o; docs/cg6.md).  Note such batches.
	 */
	int stale = 0, clipped = 0;
	{
		int gx = x, gy = y;
		for (int i = 0; i < n; i++) {
			uint32_t gp = rd32(items + 12 * i);
			gx += (int32_t)rd32(items + 12 * i + 4);
			gy += (int32_t)rd32(items + 12 * i + 8);
			if (!gp)
				continue;
			int gw = rd32(gp + PR_W), gh = rd32(gp + PR_H);
			int out = gx < 0 || gy < 0 || gx + gw > r.w || gy + gh > r.h;
			int gone = gx + gw <= 0 || gy + gh <= 0 || gx >= r.w || gy >= r.h;
			if (clipped && !out)
				stale = 1;
			if (out && !gone)
				clipped = 1;
		}
	}
	snprintf(what, sizeof what, "batchrop op %02x %d glyphs at %d,%d", op, n, x, y);
	start(what);
	call("_cg6_batchrop", 6, d, x, y, op, items, n);
	call("_mem_batchrop", 6, m, x, y, op, items, n);
	if (stale && memcmp(G.fb, image(M), CG6_W * CG6_H)) {
		nsunbug++;
		if (verbose)
			fprintf(stderr, "note %s: Sun's stale clip window after a clipped glyph\n", what);
		ntests++;
		sync_mirror();
	} else
		compare(what, 0xff);
	h_free(items);
	for (int i = 0; i < 8; i++)
		call("_mem_destroy", 1, glyphs[i]);
	regions_free(d, m);
}

/*
 * A colour fill through a stencil, a pixel at a time: the definition
 * (pixrect's pr_stencil) to judge between the model and mem_stencil when
 * they disagree.  The stencil rectangle lies inside the stencil; only the
 * destination clips.
 */
static uint8_t pixop(int op4, uint8_t s, uint8_t d)
{
	return (op4 & 8 ? s & d : 0) | (op4 & 4 ? s & ~d : 0) |
	       (op4 & 2 ? ~s & d : 0) | (op4 & 1 ? ~s & ~d : 0);
}

static void stencil_ref(const struct region *r, int x, int y, int w, int h, int op,
			uint32_t st, int stx, int sty, uint32_t spr, int sx, int sy)
{
	const uint8_t *sb = image(st), *src = spr ? image(spr) : NULL;
	int lb = linebytes(st), c = op >> 5, slb = spr ? linebytes(spr) : 0;
	int sdepth = spr ? (int)rd32(spr + PR_DEPTH) : 0;
	int rv = spr ? rd16(md(spr) + MD_FLAGS) & MP_REVERSEVIDEO : 0;
	uint8_t s = c;			/* no source: the colour itself */

	memcpy(ref, before, sizeof ref);
	for (int j = 0; j < h; j++)
		for (int i = 0; i < w; i++) {
			int px = x + i, py = y + j, bx = stx + i, by = sty + j;
			if (px < 0 || py < 0 || px >= r->w || py >= r->h)
				continue;
			if (!(sb[by * lb + (bx >> 3)] >> (7 - (bx & 7)) & 1))
				continue;
			if (sdepth == 8)
				s = src[(sy + j) * slb + sx + i];
			else if (sdepth == 1) {
				int b = src[(sy + j) * slb + ((sx + i) >> 3)] >> (7 - ((sx + i) & 7)) & 1;
				s = b ? (c ? c : 0xff) : 0;
				if (rv)
					s = ~s;
			}
			uint8_t *p = &ref[(r->oy + py) * CG6_W + r->ox + px];
			*p = pixop(op >> 1 & 15, s, *p);
		}
	have_ref = 1;
}

/* pr_rop from a memory pixrect, a pixel at a time, with the plane mask */
static void rop_ref(const struct region *r, int x, int y, int w, int h, int op,
		    uint32_t spr, int sx, int sy, uint8_t pm)
{
	const uint8_t *src = image(spr);
	int slb = linebytes(spr), sw = rd32(spr + PR_W), sh = rd32(spr + PR_H);
	int sdepth = rd32(spr + PR_DEPTH), c = op >> 5;
	int rv = rd16(md(spr) + MD_FLAGS) & MP_REVERSEVIDEO;

	memcpy(ref, before, sizeof ref);
	for (int j = 0; j < h; j++)
		for (int i = 0; i < w; i++) {
			int px = x + i, py = y + j, bx = sx + i, by = sy + j;
			uint8_t sv;

			if (px < 0 || py < 0 || px >= r->w || py >= r->h ||
			    bx < 0 || by < 0 || bx >= sw || by >= sh)
				continue;
			if (sdepth == 8)
				sv = src[by * slb + bx];
			else {
				int b = src[by * slb + (bx >> 3)] >> (7 - (bx & 7)) & 1;
				sv = b ? (c ? c : 0xff) : 0;
				if (rv)
					sv = ~sv;
			}
			uint8_t *p = &ref[(r->oy + py) * CG6_W + r->ox + px];
			*p = (pixop(op >> 1 & 15, sv, *p) & pm) | (*p & ~pm);
		}
	have_ref = 1;
}

static void test_stencil(void)
{
	struct region r = random_region();
	uint32_t d, m, st, spr = 0;
	int x, y, w, h, op = random_op() & ~PIX_DONTCLIP, kind = rn(3), sx = 0, sy = 0;
	int stw, sth, stx, sty;
	char what[160];

	regions(&r, &d, &m);
	rect(r.w, r.h, &x, &y, &w, &h);
	if (w > 300) w = 300;
	if (h > 200) h = 200;
	stw = w + rn(40); sth = h + rn(20);
	st = random_mpr(stw, sth, 1, 0);
	stx = rn(stw - w + 1); sty = rn(sth - h + 1);
	if (kind == 1) {
		spr = random_mpr(w + 10, h + 10, 1, rn(2));
		sx = rn(10); sy = rn(10);
	} else if (kind == 2) {
		spr = random_mpr(w + 10, h + 10, 8, 0);
		sx = rn(10); sy = rn(10);
		/*
		 * Sun's cg6_stencil gives an 8-bit source the foreground colour
		 * ~colour (cg6_stencil.o +0x470), so the board draws src & ~colour
		 * where mem_stencil ignores the colour: a difference in Sun's
		 * code, not the board's (docs/cg6.md).  Colour 0 only.
		 */
		op &= 0x1f;
	}
	snprintf(what, sizeof what, "stencil op %02x src %d at %d,%d %dx%d in %d,%d %dx%d stencil at %d,%d",
		 op, kind, x, y, w, h, r.ox, r.oy, r.w, r.h, stx, sty);
	start(what);
	/*
	 * The 68020 cg6_stencil, with an 8-bit source narrower than a 32-pixel
	 * group on one of its two alignment paths, decrements the group count
	 * from 0 to -1 (cg6_stencil.o +0x74c) and runs PR_LOOP on it: its
	 * 68000 form, a dbra (pr_impl_util.h's LOOP_DECR, --n != -1), goes
	 * round 65,536 times where SPARC's (--n >= 0) goes none (docs/cg6.md).
	 * A stencil writes the font register at most ~16,000 times (300x200
	 * at 4 pixels a write); the harness stops one at 100,000, does what
	 * the routine's exit does (the pixel mask back to all ones) and counts
	 * it instead of comparing.
	 */
	nfontw = 0;
	stopped = 0;
	font_limit = 100000;
	call("_cg6_stencil", 12, d, x, y, w, h, op, st, stx, sty, spr, sx, sy);
	font_limit = 0;
	if (stopped) {
		nrunaway++;
		ntests++;
		if (verbose)
			fprintf(stderr, "note %s: Sun's 68020 dbra loop ran away\n", what);
		cg6_write(&G, CG6_FBC + FBC_PIXELMASK, 4, 0xffffffff);
		sync_mirror();
	} else {
		call("_mem_stencil", 12, m, x, y, w, h, op, st, stx, sty, spr, sx, sy);
		stencil_ref(&r, x, y, w, h, op, st, stx, sty, spr, sx, sy);
		compare(what, 0xff);
	}
	call("_mem_destroy", 1, st);
	if (spr)
		call("_mem_destroy", 1, spr);
	regions_free(d, m);
}

/*
 * pr_replrop's definition, a pixel at a time: the source tiled from
 * (sx, sy) at the rectangle's origin, a 1-bit source as the colour (or all
 * ones) or zero, then the op; the destination clips.
 */
static void replrop_ref(const struct region *r, int x, int y, int w, int h, int op,
			uint32_t spr, int sx, int sy)
{
	const uint8_t *sb = image(spr);
	int lb = linebytes(spr), pw = rd32(spr + PR_W), ph = rd32(spr + PR_H);
	int depth = rd32(spr + PR_DEPTH), c = op >> 5;

	memcpy(ref, before, sizeof ref);
	for (int j = 0; j < h; j++)
		for (int i = 0; i < w; i++) {
			int px = x + i, py = y + j;
			int bx = (sx + i) % pw, by = (sy + j) % ph;
			uint8_t sv;

			if (px < 0 || py < 0 || px >= r->w || py >= r->h)
				continue;
			if (depth == 8)
				sv = sb[by * lb + bx];
			else
				sv = sb[by * lb + (bx >> 3)] >> (7 - (bx & 7)) & 1 ? (c ? c : 0xff) : 0;
			uint8_t *p = &ref[(r->oy + py) * CG6_W + r->ox + px];
			*p = pixop(op >> 1 & 15, sv, *p);
		}
	have_ref = 1;
}

static void test_replrop(void)
{
	struct region r = random_region();
	uint32_t d, m, spr;
	int x, y, w, h, op = random_op() & ~PIX_DONTCLIP;
	int pw = rn(3) ? 16 : 1 + rn(40), ph = rn(3) ? 16 : 1 + rn(40), depth = rn(3) ? 1 : 8;
	char what[160];

	regions(&r, &d, &m);
	rect(r.w, r.h, &x, &y, &w, &h);
	spr = random_mpr(pw, ph, depth, 0);
	snprintf(what, sizeof what, "replrop op %02x pat %dx%dx%d at %d,%d %dx%d", op, pw, ph, depth, x, y, w, h);
	start(what);
	{
		int sx = rn(pw), sy = rn(ph);
		call("_pr_replrop", 9, d, x, y, w, h, op, spr, sx, sy);
		call("_pr_replrop", 9, m, x, y, w, h, op, spr, sx, sy);
		replrop_ref(&r, x, y, w, h, op, spr, sx, sy);
	}
	compare(what, 0xff);
	call("_mem_destroy", 1, spr);
	regions_free(d, m);
}

static uint32_t random_points(int n, int bw, int bh, int spread)
{
	uint32_t p = h_alloc(8 * n);
	int cx = rn(bw), cy = rn(bh);

	for (int i = 0; i < n; i++) {
		wr32(p + 8 * i, cx + rn(2 * spread + 1) - spread);
		wr32(p + 8 * i + 4, cy + rn(2 * spread + 1) - spread);
	}
	return p;
}

static void test_polygon(void)
{
	struct region r = random_region();
	uint32_t d, m, npts, pts;
	int nb = rn(4) ? 1 : 2, total = 0, op = random_op() & ~PIX_DONTCLIP;
	int dx = rn(40) - 20, dy = rn(40) - 20, spread = rn(4) ? 60 : 300;
	char what[160];

	regions(&r, &d, &m);
	npts = h_alloc(4 * nb);
	for (int i = 0; i < nb; i++) {
		int k = 2 + rn(rn(3) ? 4 : 10);
		wr32(npts + 4 * i, k);
		total += k;
	}
	pts = random_points(total, r.w, r.h, spread);
	snprintf(what, sizeof what, "polygon op %02x %d bounds %d points", op, nb, total);
	start(what);
	call("_pr_polygon_2", 10, d, dx, dy, nb, npts, pts, op, 0, 0, 0);
	call("_pr_polygon_2", 10, m, dx, dy, nb, npts, pts, op, 0, 0, 0);
	compare(what, 0xff);
	h_free(pts);
	h_free(npts);
	regions_free(d, m);
}

static void test_polyline(void)
{
	struct region r = random_region();
	uint32_t d, m, pts;
	int n = 2 + rn(10), op = random_op() & ~PIX_DONTCLIP, close = rn(2);
	char what[160];

	regions(&r, &d, &m);
	pts = random_points(n, r.w, r.h, rn(3) ? 50 : 400);
	snprintf(what, sizeof what, "polyline op %02x %d points%s", op, n, close ? " closed" : "");
	start(what);
	{
		int dx = rn(20) - 10;
		call("_pr_polyline", 9, d, dx, 0, n, pts, close, 0, 0, op);
		call("_pr_polyline", 9, m, dx, 0, n, pts, close, 0, 0, op);
	}
	compare(what, 0xff);
	h_free(pts);
	regions_free(d, m);
}

static void test_polypoint(void)
{
	struct region r = random_region();
	uint32_t d, m, pts;
	int n = 1 + rn(40), op = random_op() & ~PIX_DONTCLIP;
	char what[160];

	regions(&r, &d, &m);
	pts = random_points(n, r.w, r.h, rn(3) ? 30 : 400);
	snprintf(what, sizeof what, "polypoint op %02x %d points", op, n);
	start(what);
	call("_pr_polypoint", 6, d, 0, 0, n, pts, op);
	call("_pr_polypoint", 6, m, 0, 0, n, pts, op);
	compare(what, 0xff);
	h_free(pts);
	regions_free(d, m);
}

/*
 * The Rev 3.0.1 PROM's GX console, register for register as its code at
 * 0xFEF6070..0xFEF6F3C writes it (docs/cg6.md, "What PROM 3.0.1 does"):
 * the probe's ID, the board's set-up, a screen clear, a character, the
 * cursor, and a scroll.  The PROM's mappings: FBC/TEC at VA 0x0FE20000,
 * FHC/THC at 0x0FE22000, the DAC at 0x0FE24000, the ROM at 0x0FE30000.
 */
static void pw(uint32_t off, uint32_t v) { cg6_write(&G, off, 4, v); }
static uint32_t pr(uint32_t off) { return cg6_read(&G, off, 4); }

/* the PROM's waits: fef66ce (STATUS busy), fef6706/fef671e (FULL) */
static void prom_wait_busy(void) { while (pr(CG6_FBC + FBC_STATUS) & FBC_S_BUSY) ; }

static void prom_rect(int x0, int y0, int x1, int y1, uint32_t c)	/* fef694c */
{
	pw(CG6_FBC + FBC_FCOLOR, c);
	pw(CG6_FBC + 0x904, y0);
	pw(CG6_FBC + 0x900, x0);
	pw(CG6_FBC + 0x904, y1 - 1);
	pw(CG6_FBC + 0x900, x1 - 1);
	while (pr(CG6_FBC + FBC_DRAWSTATUS) & FBC_S_FULL)
		;
	prom_wait_busy();
	pw(CG6_FBC + FBC_FCOLOR, 0xff);
}

static int vsync_phase;
static uint32_t prom_thc_misc(void)		/* the raster moves as it is polled */
{
	if (++vsync_phase % 5 == 0)
		cg6_vsync(&G, !G.vsync);
	return pr(CG6_THC + 0x818);
}

/*
 * -G prefix: traces for an RTL bench that need no library (tb/verilator's
 * tb_cg6).  prefix_prom.{txt,ini,fin} is test_prom's sequence; prefix_gen.*
 * drives the engine directly, register by register, the way the PROM and
 * libpixrect do: rectangles and points, the font register in colour1 and
 * colour8, blits, the CPU's own frame-buffer cycles between them, and
 * registers written and read back.  Each is a trace in -t's format, the
 * frame buffer before it (.ini) and after (.fin).  The model is the
 * reference, so nothing here is compared: the RTL is, against the model.
 */
#define FBC_Y1	0x094
#define FBC_X2	0x0a0
#define FBC_Y2	0x0a4
#define FBC_X3	0x0b0
#define FBC_Y3	0x0b4

static const char *gen_prefix;
static FILE *gen_trace;
static char gen_name[512];

static void gen_image(const char *ext)
{
	char path[600];
	FILE *o;

	snprintf(path, sizeof path, "%s.%s", gen_name, ext);
	if (!(o = fopen(path, "wb")) || fwrite(G.fb, 1, CG6_W * CG6_H, o) != CG6_W * CG6_H)
		die("can't write %s", path);
	fclose(o);
}

static void gen_open(const char *what)
{
	char path[600];

	snprintf(gen_name, sizeof gen_name, "%s_%s", gen_prefix, what);
	gen_image("ini");
	snprintf(path, sizeof path, "%s.txt", gen_name);
	if (!(gen_trace = fopen(path, "w")))
		die("can't write %s", path);
	trace = gen_trace;
}

static void gen_close(void)
{
	trace = NULL;
	fclose(gen_trace);
	gen_trace = NULL;
	gen_image("fin");
}

static void gw(uint32_t reg, uint32_t v) { cg6_write(&G, CG6_FBC + reg, 4, v); }
static uint32_t gr(uint32_t reg) { return cg6_read(&G, CG6_FBC + reg, 4); }
static void g_wait(void) { while (gr(FBC_STATUS) & FBC_S_BUSY) ; }
static void g_go(uint32_t reg) { while (gr(reg) & FBC_S_FULL) ; }

/* a coordinate: mostly on the screen, sometimes off it, rarely anywhere */
static int32_t g_coord(int lim, int wild)
{
	switch (rn(16)) {
	case 0: case 1: return rn(lim + 400) - 200;
	case 2: return wild ? (int32_t)rnd() : rn(3 * lim) - lim;
	case 3: return wild ? (rn(2) ? 40000 + rn(100000) : -40000 - rn(100000)) : lim - 1 - rn(8);
	default: return rn(lim);
	}
}

/* the raster state: colours, the raster op and its fields, the masks, the clip */
static void g_state(void)
{
	static const uint16_t ops[] = { 0xff00, 0xcccc, 0x5555, 0x6c60, 0xaaaa, 0x0000, 0x3c3c, 0xfc30 };
	uint32_t rop = rn(2) ? ops[rn(8)] : (rnd() & 0xffff);

	/* plane, pixel and pattern fields 0..3 (0 keeps the old one) */
	rop |= (uint32_t)rn(4) << 30 | (uint32_t)rn(4) << 28 | (uint32_t)rn(4) << 26 |
	       (uint32_t)rn(4) << 24 | (uint32_t)rn(4) << 22 | (rnd() & 0x30000);
	gw(FBC_RASTEROP, rop);
	gw(FBC_FCOLOR, rn(4) ? (uint32_t)rn(256) : rnd());
	gw(FBC_BCOLOR, rn(4) ? (uint32_t)rn(256) : rnd());
	gw(FBC_PLANEMASK, rn(3) ? 0xff : rnd());
	gw(FBC_PIXELMASK, rn(3) ? 0xffffffff : rnd());
	if (rn(3)) {
		gw(FBC_CLIPMINX, 0); gw(FBC_CLIPMINY, 0);
		gw(FBC_CLIPMAXX, CG6_W - 1); gw(FBC_CLIPMAXY, CG6_H - 1);
	} else {
		gw(FBC_CLIPMINX, g_coord(CG6_W, 0)); gw(FBC_CLIPMINY, g_coord(CG6_H, 0));
		gw(FBC_CLIPMAXX, g_coord(CG6_W, 0)); gw(FBC_CLIPMAXY, g_coord(CG6_H + 12, 0));
	}
	gw(FBC_OFFX, rn(4) ? 0 : rn(41) - 20);
	gw(FBC_OFFY, rn(4) ? 0 : rn(41) - 20);
	if (rn(3) == 0) {	/* a new pattern, or a new alignment */
		if (rn(2))
			for (int i = 0; i < 8; i++)
				gw(FBC_PATTERN + 4 * i, rn(4) ? rnd() : 0xaaaa5555u);
		gw(FBC_PATTALIGN, rn(2) ? (uint32_t)rn(16) << 16 | rn(16) : rnd());
	}
}

/* a vertex of primitive group p (0 point .. 4 rect), y and x in either order,
   absolute or, sometimes, relative to the last */
static void g_vertex(int p, int32_t x, int32_t y)
{
	uint32_t base = FBC_IPOINT + 0x40 * p, rel = rn(6) == 0 ? 0x10 : 0;

	if (rel) {			/* relative to the last vertex: as many pixels again */
		x = rn(81) - 40;
		y = rn(41) - 20;
	}
	if (rn(5) == 0)
		gw(base + 0x08, rnd());	/* z: stored, never drawn */
	if (rn(2)) { gw(base + rel + 4, y); gw(base + rel, x); }
	else { gw(base + rel, x); gw(base + rel + 4, y); }
}

static void g_rect(void)
{
	int32_t x0 = g_coord(CG6_W, 1), y0 = g_coord(CG6_H, 1), x1, y1;

	if (rn(3)) {
		x1 = x0 + rn(rn(4) ? 64 : 700) - 2;
		y1 = y0 + rn(rn(4) ? 40 : 600) - 2;
	} else {
		x1 = g_coord(CG6_W, 1);
		y1 = g_coord(CG6_H, 1);
	}
	g_state();
	if (rn(6) == 0)		/* a vertex of another kind first: a new queue */
		g_vertex(rn(4), g_coord(CG6_W, 0), g_coord(CG6_H, 0));
	if (rn(8) == 0) {	/* a point */
		g_vertex(0, x0, y0);
	} else {
		if (rn(6) == 0)	/* three vertices: the last two count */
			g_vertex(4, g_coord(CG6_W, 0), g_coord(CG6_H, 0));
		g_vertex(4, x0, y0);
		g_vertex(4, x1, y1);
	}
	g_go(FBC_DRAWSTATUS);
	if (rn(4))
		g_wait();
}

/*
 * Lines and polygons: their vertices are kept within 16 bits, which the RTL
 * saturates its coordinates to (docs/cg6.md, "Stage 2"): a line or polygon
 * with a vertex further out is drawn there with that vertex moved in.
 */
static int32_t g_lcoord(int lim)
{
	switch (rn(16)) {
	case 0: case 1: return rn(lim + 400) - 200;
	case 2: return rn(3 * lim) - lim;
	case 3: return rn(2) ? 32767 - rn(30000) : -32768 + rn(30000);
	default: return rn(lim);
	}
}

/* x0 and y0 on the screen: a first vertex that is relative is relative to them */
static void g_near(void)
{
	gw(FBC_X0, rn(CG6_W));
	gw(FBC_Y0, rn(CG6_H));
}

/* a line, or a polyline: each further vertex draws on from the last */
static void g_line(void)
{
	int n = rn(4) ? 1 : 1 + rn(6);
	int32_t x = g_lcoord(CG6_W), y = g_lcoord(CG6_H);

	g_state();
	g_near();
	if (rn(6) == 0)		/* a vertex of another kind first: a new queue */
		g_vertex(rn(5), g_coord(CG6_W, 0), g_coord(CG6_H, 0));
	g_vertex(1, x, y);
	for (int i = 0; i < n; i++) {
		if (rn(3)) {	/* short, of every slope */
			x += rn(rn(4) ? 80 : 700) - (rn(4) ? 40 : 350);
			y += rn(rn(4) ? 80 : 600) - (rn(4) ? 40 : 300);
			if (x > 32767) x = 32767;
			if (y > 32767) y = 32767;
			if (x < -32768) x = -32768;
			if (y < -32768) y = -32768;
		} else {
			x = g_lcoord(CG6_W);
			y = g_lcoord(CG6_H);
		}
		if (rn(4) == 0) {	/* horizontal, vertical, diagonal */
			switch (rn(3)) {
			case 0: y = G.y[G.nv ? (G.nv - 1) & 3 : 0]; break;
			case 1: x = G.x[G.nv ? (G.nv - 1) & 3 : 0]; break;
			default: break;
			}
		}
		g_vertex(1, x, y);
		g_go(FBC_DRAWSTATUS);
		if (rn(3) == 0)
			g_wait();
	}
	if (rn(4))
		g_wait();
}

/* a triangle or quadrilateral: 2..4 vertices (sometimes more, of which the
   last count), sometimes a point first, as cg6_polygon_2 and sunGX.c begin */
static void g_poly(void)
{
	int quad = rn(2), k = 2 + rn(quad ? 3 : 2), point = rn(3) == 0;
	int32_t cx = g_lcoord(CG6_W), cy = g_lcoord(CG6_H);
	int spread = rn(4) ? 60 + rn(200) : 1200;

	if (rn(8) == 0)
		k += 1 + rn(4);	/* more than the primitive takes */
	g_state();
	g_near();
	for (int i = 0; i < k; i++) {
		int32_t x = cx + rn(2 * spread) - spread, y = cy + rn(spread) - spread / 2;
		if (rn(8) == 0) y = cy;		/* horizontal edges */
		if (rn(10) == 0) { x = g_lcoord(CG6_W); y = g_lcoord(CG6_H); }
		if (x > 32767) x = 32767;
		if (x < -32768) x = -32768;
		if (y > 32767) y = 32767;
		if (y < -32768) y = -32768;
		g_vertex(i == 0 && point ? 0 : quad ? 3 : 2, x, y);
	}
	g_go(FBC_DRAWSTATUS);
	if (rn(4))
		g_wait();
}

static void g_font(void)
{
	int c8 = rn(3) == 0, k = 1 + rn(c8 ? 8 : 24);
	int32_t x0 = g_coord(CG6_W, 1), y0 = g_coord(CG6_H, 1);

	g_state();
	gw(FBC_MISC, (c8 ? 1u : 2u) << 17 | (rn(4) ? 0 : rnd() & 0x3e7fff));	/* data: colour8 or colour1 */
	gw(FBC_INCX, rn(3) ? 0 : rn(9) - 4);
	gw(FBC_INCY, rn(3) ? 1 : rn(5) - 2);
	gw(FBC_Y0, y0);
	gw(FBC_X0, x0);
	gw(FBC_X1, x0 + (rn(4) ? (c8 ? rn(6) : rn(36)) : rn(80) - 10) - 1);
	if (rn(3) == 0)
		gw(FBC_Y1, rnd());
	for (int i = 0; i < k; i++)
		gw(FBC_FONT, rnd());
	if (rn(2))
		g_wait();
}

static void g_blit(void)
{
	int w = 1 + rn(rn(4) ? 64 : 1152), h = 1 + rn(rn(4) ? 40 : 900);
	int32_t sx = rn(CG6_W + 100) - 50, sy = rn(CG6_H + 100) - 50, dx, dy;

	if (rn(2)) {		/* overlapping, every direction */
		dx = sx + rn(41) - 20;
		dy = sy + rn(21) - 10;
	} else {
		dx = rn(CG6_W + 100) - 50;
		dy = rn(CG6_H + 100) - 50;
	}
	if (rn(8) == 0) { sy = CG6_H + rn(30) - 10; }	/* a source past the frame buffer */
	g_state();
	gw(FBC_X0, sx); gw(FBC_Y0, sy);
	gw(FBC_X1, sx + w - 1); gw(FBC_Y1, sy + h - 1);
	gw(FBC_X2, dx); gw(FBC_Y2, dy);
	gw(FBC_X3, dx + w - 1); gw(FBC_Y3, dy + h - 1);
	g_go(FBC_BLITSTATUS);
	if (rn(4))
		g_wait();
}

/* the CPU's own cycles to the frame buffer, then at once an engine command
   that reads them */
static void g_cpu(void)
{
	int n = 1 + rn(40);

	g_wait();
	for (int i = 0; i < n; i++) {
		int size = 1 << rn(3);
		uint32_t a = (rn(4) ? rn(CG6_W * 40) : rn(CG6_W * CG6_H)) & ~(uint32_t)(size - 1);
		if (rn(3))
			cg6_write(&G, CG6_FB + a, size, rnd());
		else
			cg6_read(&G, CG6_FB + a, size);
	}
	if (rn(2)) {		/* a copy from where they went, straight after */
		g_state();
		gw(FBC_RASTEROP, 0xa980cccc);
		gw(FBC_PLANEMASK, 0xff);
		gw(FBC_PIXELMASK, 0xffffffff);
		gw(FBC_CLIPMINX, 0); gw(FBC_CLIPMINY, 0);
		gw(FBC_CLIPMAXX, CG6_W - 1); gw(FBC_CLIPMAXY, CG6_H - 1);
		gw(FBC_X0, 0); gw(FBC_Y0, 0);
		gw(FBC_X1, CG6_W - 1); gw(FBC_Y1, 39);
		gw(FBC_X2, rn(5)); gw(FBC_Y2, 40 + rn(800));
		g_go(FBC_BLITSTATUS);
	}
	g_wait();
	for (int i = 0; i < 4; i++)
		cg6_read(&G, CG6_FB + (rn(CG6_W * CG6_H) & ~3u), 4);
}

/*
 * The registers that are only stored: z and colour, the indexed registers,
 * the THC's timing and cursor, the TEC (its data registers in two banks by
 * VDC's type, as cg6_cntxsave reads them).  An RTL keeps them in a RAM that
 * a reset does not clear, so each is read only after this run has written
 * it.
 */
static uint8_t g_written[3][2][0x1000 / 4];	/* block, the TEC bank, word */

static void g_store(void)
{
	int n = 1 + rn(10);

	for (int i = 0; i < n; i++) {
		uint32_t base, o;
		int b, bank = 0;

		switch (rn(5)) {
		case 0:		/* FBC z and colour */
			b = 0; base = CG6_FBC; o = 0x80 + 0x10 * rn(4) + (rn(2) ? 8 : 12); break;
		case 1:		/* FBC indexed: z, w, colour -- none of a vertex's x and y */
			b = 0; base = CG6_FBC; o = 0x800 + 0x40 * rn(5);
			o += rn(2) ? (rn(2) ? 0x08 : 0x0c) + 0x10 * rn(2) : 0x30 + 4 * rn(4);
			break;
		case 2:		/* THC timing and cursor */
			b = 1; base = CG6_THC;
			o = rn(3) == 0 ? 0x800 + 4 * rn(6) : rn(4) == 0 ? 0x8fc : 0x900 + 4 * rn(64);
			break;
		default:	/* TEC */
			b = 2; base = CG6_TEC;
			switch (rn(4)) {
			case 0: o = 4 * rn(8); break;
			case 1: o = 0x800 + 4 * rn(0x180); break;
			default: o = 0x100 + 4 * rn(64); break;
			}
			if (rn(3) == 0) {	/* VDC: which bank the data registers are */
				cg6_write(&G, CG6_TEC + 8, 4, (rn(2) ? 0x8000u : 0xa000u) | (rnd() & 0x1fff));
				g_written[2][0][2] = 1;
			}
			bank = o >= 0x100 && o < 0x200 && (G.tec[2] >> 13 & 7) == 5;
			break;
		}
		if (!g_written[b][bank][o >> 2] || rn(3)) {
			uint32_t v = rnd();
			if (b == 2 && o == 8)		/* VDC itself: a bank */
				v = (rn(2) ? 0x8000u : 0xa000u) | (v & 0x1fff);
			cg6_write(&G, base + o, 4, v);
			g_written[b][bank][o >> 2] = 1;
		}
		cg6_read(&G, base + o, 4);
		if (b == 1 && o == 0x8fc)
			cg6_write(&G, base + o, 4, 0xffe0ffe0);	/* the cursor off the screen again */
	}
}

/* registers written and read back, the 2-bit fields that keep their value */
static void g_regs(void)
{
	static const uint16_t regs[] = { FBC_MISC, FBC_CLIPCHECK, FBC_X0, FBC_Y0, FBC_X1 + 0x10, FBC_Y0 + 0x30,
		FBC_OFFX, FBC_OFFY, FBC_INCX, FBC_INCY, FBC_CLIPMINX, FBC_CLIPMAXY, FBC_FCOLOR, FBC_BCOLOR,
		FBC_RASTEROP, FBC_PLANEMASK, FBC_PIXELMASK, FBC_PATTALIGN, FBC_CONFIG };
	int n = 1 + rn(12);

	g_wait();
	for (int i = 0; i < n; i++) {
		uint32_t r = regs[rn(sizeof regs / sizeof regs[0])];
		gw(r, rnd());
		gr(r);
		if (rn(2))
			gr(regs[rn(sizeof regs / sizeof regs[0])]);
	}
	gr(FBC_FONT);
	cg6_read(&G, CG6_FHC, 4);
	for (int i = 0; i < 8; i++)
		if (rn(4) == 0)
			gr(FBC_PATTERN + 4 * i);
	g_store();
	g_state();		/* nothing left in a state the next test cannot undo */
	gw(FBC_MISC, 2u << 17);
}

static void gen_run(long n)
{
	cg6_reset(&G);
	fill_random(G.fb, sizeof G.fb);
	/* the images are the screen's 900 lines; the rest of the 1 MiB starts as
	   zeros, which an RTL bench's memory has too */
	memset(G.fb + CG6_W * CG6_H, 0, CG6_FBSIZE - CG6_W * CG6_H);
	gen_open("gen");
	for (long i = 0; i < n; i++) {
		switch (rn(12)) {
		case 0: case 1: g_rect(); break;
		case 2: case 3: g_font(); break;
		case 4: case 5: g_blit(); break;
		case 6: g_cpu(); break;
		case 7: case 8: g_line(); break;
		case 9: case 10: g_poly(); break;
		default: g_regs(); break;
		}
	}
	g_wait();
	gen_close();
	printf("-G: %ld tests; engine: %lu points %lu lines %lu tris %lu quads %lu rects %lu blits %lu font, %lu pixels\n", n,
	       G.ndraw[PRIM_POINT], G.ndraw[PRIM_LINE], G.ndraw[PRIM_TRI], G.ndraw[PRIM_QUAD],
	       G.ndraw[PRIM_RECT], G.nblit, G.nfont, G.npix);
}

static void test_prom(void)
{
	static const uint32_t table[][2] = {	/* 0xFEFD588 */
		{ 0x010, 0 }, { 0x0c0, 0 }, { 0x0c4, 0 }, { 0x0d0, 0 }, { 0x0d4, 1 },
		{ 0x800, 0 }, { 0x804, 0 }, { 0x0e0, 0 }, { 0x0e4, 0 }, { 0x008, 0 },
		{ 0x100, 0xff }, { 0x104, 0 }, { 0x108, 0xa9806c60 }, { 0x10c, 0xff },
		{ 0x110, 0xffffffff }, { 0x11c, 0x10002 }, { 0x004, 0x14aac0 },
	};
	static const uint16_t glyph[22] = {	/* a 12-wide test pattern, MSB left */
		0x0000, 0x0f00, 0x1980, 0x30c0, 0x30c0, 0x6060, 0x6060, 0x7fe0,
		0x6060, 0x6060, 0x6060, 0x6060, 0x0000, 0x0000, 0x8010, 0xfff0,
		0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000 };
	int bad = 0, ox = (CG6_W - 960) / 2, oy = (CG6_H - 748) / 2;

	start("prom 3.0.1 console");
	cg6_reset(&G);
	fill_random(G.fb, sizeof G.fb);
	if (gen_prefix)			/* -G: this sequence traced, for an RTL bench */
		gen_open("prom");
	/* the probe: the P4 ID byte, 0x60 the GX at 1152x900 (0xFEF2552) */
	bad += cg6_read(&G, CG6_FHC, 1) != 0x60;
	pw(CG6_FHC, 0x10bbb);			/* 0xFEF60DC: 1152, 68020, test 11x11 */
	pw(CG6_TEC + 0, 0); pw(CG6_TEC + 4, 0); pw(CG6_TEC + 8, 0);
	pw(CG6_THC + 0x818, 0x1000);		/* reset */
	pw(CG6_THC + 0x818, 0x8f);
	pw(CG6_THC + 0x800, 0x10009); pw(CG6_THC + 0x804, 0x570000);
	pw(CG6_THC + 0x808, 0x15005d); pw(CG6_THC + 0x80c, 0x10005);
	pw(CG6_THC + 0x810, 0x2403a8); pw(CG6_THC + 0x814, 0x16b);
	for (int i = 0; i < 15; i++) {		/* 0xFEF66E6: a vsync, 15 times */
		while (!(prom_thc_misc() & THC_MISC_VSYNC))
			;
		while (prom_thc_misc() & THC_MISC_VSYNC)
			;
	}
	pw(CG6_THC + 0x818, 0x48f);		/* video on */
	bad += !(pr(CG6_THC + 0x818) & THC_MISC_VIDEO);
	/* the DAC: command 0x40, read mask 0xff, blink 0; entry 0 white, 255 black */
	pw(CG6_DAC + 0, 0x06060606); pw(CG6_DAC + 8, 0x40404040);
	pw(CG6_DAC + 0, 0x04040404); pw(CG6_DAC + 8, 0xffffffff);
	pw(CG6_DAC + 0, 0x05050505); pw(CG6_DAC + 8, 0);
	pw(CG6_DAC + 0, 0);
	for (int i = 0; i < 3; i++) pw(CG6_DAC + 4, 0xff000000);
	pw(CG6_DAC + 0, 0xff000000);
	for (int i = 0; i < 3; i++) pw(CG6_DAC + 4, 0);
	for (size_t i = 0; i < sizeof table / sizeof table[0]; i++)
		pw(CG6_FBC + table[i][0], table[i][1]);
	pw(CG6_FBC + FBC_CLIPMAXX, CG6_W - 1);	/* 0xFEF60F6 */
	pw(CG6_FBC + FBC_CLIPMAXY, CG6_H - 1);
	/* the ROM's logo: its first byte is not 0x64, so no logo (0xFEF6AF4) */
	bad += (cg6_read(&G, CG6_ROM, 4) & 0xff) == 0x64;
	prom_rect(0, 0, CG6_W, CG6_H, 0);	/* 0xFEF6606: clear to colour 0 */
	for (int i = 0; i < CG6_W * CG6_H; i++)
		bad += G.fb[i] != 0;
	bad += cg6_rgb(&G, 5, 5) != 0xffffff;
	/* a character at the console's (0,0) (0xFEF6736), then (1,0) inverse */
	for (int k = 0; k < 2; k++) {
		uint32_t inv = k ? 0xffffffff : 0;
		pw(CG6_FBC + FBC_Y0, oy);
		pw(CG6_FBC + FBC_X0, ox + 12 * k);
		pw(CG6_FBC + FBC_X1, ox + 12 * k + 11);
		for (int j = 0; j < 22; j++)
			pw(CG6_FBC + FBC_FONT, ((uint32_t)(int16_t)glyph[j] ^ inv) << 16);
	}
	for (int k = 0; k < 2; k++)
		for (int j = 0; j < 22; j++)
			for (int i = 0; i < 12; i++) {
				int on = (glyph[j] >> (15 - i) & 1) ^ k;
				bad += G.fb[(oy + j) * CG6_W + ox + 12 * k + i] != (on ? 0xff : 0);
			}
	bad += G.fb[oy * CG6_W + ox + 24] != 0;		/* nothing past the cell */
	bad += cg6_rgb(&G, ox + 4, oy + 1) != 0;	/* black text */
	/* the cursor at (0,0): bcolor 0xff, an XOR rectangle (0xFEF68CE) */
	pw(CG6_FBC + FBC_BCOLOR, 0xff);
	prom_rect(ox, oy, ox + 12, oy + 22, 0xff);
	pw(CG6_FBC + FBC_BCOLOR, 0);
	for (int j = 0; j < 22; j++)
		for (int i = 0; i < 12; i++) {
			int on = glyph[j] >> (15 - i) & 1;
			bad += G.fb[(oy + j) * CG6_W + ox + i] != (on ? 0 : 0xff);
		}
	/* a scroll (0xFEF6A16): rows 22.. up by 22, the PROM's blit */
	memcpy(before, G.fb, sizeof before);
	pw(CG6_FBC + 0xb4, oy + 747 - 22); pw(CG6_FBC + 0xb0, ox + 959);
	pw(CG6_FBC + 0xa4, oy); pw(CG6_FBC + 0xa0, ox);
	pw(CG6_FBC + 0x94, oy + 747); pw(CG6_FBC + 0x90, ox + 959);
	pw(CG6_FBC + 0x84, oy + 22); pw(CG6_FBC + 0x80, ox);
	while (pr(CG6_FBC + FBC_BLITSTATUS) & FBC_S_FULL)
		;
	prom_wait_busy();
	for (int j = 0; j < 748 - 22; j++)
		bad += memcmp(&G.fb[(oy + j) * CG6_W + ox], &before[(oy + j + 22) * CG6_W + ox], 960) != 0;
	result_prom("PROM 3.0.1: ID, set-up, clear, text, cursor, scroll", bad);
	if (gen_prefix)
		gen_close();

	/*
	 * The retrace interrupt as Solaris's cg6thc.h macros drive it (SunOS's
	 * own driver for a 3/60 is not at hand): thc_int_disable writes INT
	 * as 1 to clear, thc_int_enable sets INTEN; pending at vsync's start.
	 */
	bad = 0;
	cg6_vsync(&G, 0);
	pw(CG6_THC + 0x818, (pr(CG6_THC + 0x818) & ~THC_MISC_INTEN) | THC_MISC_INT);
	bad += cg6_irq(&G);
	pw(CG6_THC + 0x818, pr(CG6_THC + 0x818) | THC_MISC_INTEN);
	bad += (pr(CG6_THC + 0x818) & THC_MISC_INT) != 0 || cg6_irq(&G);
	cg6_vsync(&G, 1);
	bad += !(pr(CG6_THC + 0x818) & THC_MISC_INT) || !cg6_irq(&G);
	cg6_vsync(&G, 0);
	bad += !cg6_irq(&G);				/* held until cleared */
	pw(CG6_THC + 0x818, (pr(CG6_THC + 0x818) & ~THC_MISC_INTEN) | THC_MISC_INT);
	bad += cg6_irq(&G) || (pr(CG6_THC + 0x818) & THC_MISC_INT);
	result_prom("THC retrace interrupt: enable, pending at vsync, clear", bad);
	cg6_reset(&G);
}

static void print_stats(void)
{
	static const struct { uint32_t off; const char *name; } names[] = {
		{ 0x004, "misc" }, { 0x008, "clipcheck" }, { 0x010, "status" }, { 0x01c, "font" },
		{ 0x080, "x0" }, { 0x084, "y0" }, { 0x090, "x1" }, { 0x094, "y1" },
		{ 0x0a0, "x2" }, { 0x0a4, "y2" }, { 0x0b0, "x3" }, { 0x0b4, "y3" },
		{ 0x0c0, "offx" }, { 0x0c4, "offy" }, { 0x0d0, "incx" }, { 0x0d4, "incy" },
		{ 0x0e0, "clipminx" }, { 0x0e4, "clipminy" }, { 0x0f0, "clipmaxx" }, { 0x0f4, "clipmaxy" },
		{ 0x100, "fcolor" }, { 0x104, "bcolor" }, { 0x108, "rasterop" }, { 0x10c, "planemask" },
		{ 0x110, "pixelmask" }, { 0x11c, "pattalign" }, { 0x120, "pattern0-7" },
		{ 0x800, "ipointabsx" }, { 0x804, "ipointabsy" }, { 0x810, "ipointrelx" }, { 0x814, "ipointrely" },
		{ 0x840, "ilineabsx" }, { 0x844, "ilineabsy" }, { 0x850, "ilinerelx" }, { 0x854, "ilinerely" },
		{ 0x880, "itriabsx" }, { 0x884, "itriabsy" }, { 0x890, "itrirelx" }, { 0x894, "itrirely" },
		{ 0x8c0, "iquadabsx" }, { 0x8c4, "iquadabsy" }, { 0x8d0, "iquadrelx" }, { 0x8d4, "iquadrely" },
		{ 0x900, "irectabsx" }, { 0x904, "irectabsy" }, { 0x910, "irectrelx" }, { 0x914, "irectrely" },
	};
	for (int c = 0; c < NCAT && cats[c][0]; c++) {
		printf("%-10s fb r %lu w %lu; regs:", cats[c], fbuse[c][0], fbuse[c][1]);
		for (uint32_t r = 0; r < 0x400; r++) {
			if (!(reguse[c][r >> 5] >> (r & 31) & 1))
				continue;
			const char *nm = NULL;
			for (size_t k = 0; k < sizeof names / sizeof names[0]; k++)
				if (names[k].off == r * 4 || (names[k].off == 0x120 && r * 4 >= 0x120 && r * 4 < 0x140))
					nm = names[k].name;
			if (nm && !(r * 4 > 0x120 && r * 4 < 0x140))
				printf(" %s", nm);
			else if (!nm)
				printf(" ?%03x", r * 4);
		}
		printf("\n");
	}
}

int main(int argc, char **argv)
{
	long n = 2000;
	int busy = 0;
	FILE *f;
	long len;

	/* -G prefix [-n N] [-s seed]: the library-free traces (gen_run) */
	if (argc >= 3 && !strcmp(argv[1], "-G")) {
		n = 400;
		gen_prefix = argv[2];
		for (int i = 3; i < argc; i++) {
			if (!strcmp(argv[i], "-n") && i + 1 < argc) n = atol(argv[++i]);
			else if (!strcmp(argv[i], "-s") && i + 1 < argc) rs ^= (uint64_t)atol(argv[++i]) * 0x9e3779b97f4a7c15ull;
			else { fprintf(stderr, "bad argument %s\n", argv[i]); return 2; }
		}
		G.trace = tracefn;
		test_prom();
		gen_run(n);
		return nfail != 0;
	}
	/* -R trace initial final: replay a trace on a fresh model, as an RTL bench would */
	if ((argc == 5 || argc == 6) && !strcmp(argv[1], "-R")) {
		FILE *t = fopen(argv[2], "r"), *fi = fopen(argv[3], "rb"), *ff = fopen(argv[4], "rb");
		static uint8_t want[CG6_W * CG6_H];
		char kind;
		int size;
		unsigned off, v;
		unsigned long nr = 0, nmis = 0, bad = 0;

		if (!t || !fi || !ff)
			die("-R: can't open the files");
		G.busy_polls = argc == 6 ? atoi(argv[5]) : 0;	/* the run's -b */
		cg6_reset(&G);
		if (fread(G.fb, 1, CG6_W * CG6_H, fi) != CG6_W * CG6_H ||
		    fread(want, 1, CG6_W * CG6_H, ff) != CG6_W * CG6_H)
			die("-R: short image");
		while (fscanf(t, " %c%d %x %x", &kind, &size, &off, &v) == 4) {
			if (kind == 'w')
				cg6_write(&G, off, size, v);
			else if (cg6_read(&G, off, size) != v && off < CG6_FB)
				nmis++;		/* a register read that differs */
			nr++;
		}
		for (int i = 0; i < CG6_W * CG6_H; i++)
			bad += G.fb[i] != want[i];
		printf("replayed %lu accesses: %lu register reads differ, %lu pixels differ\n", nr, nmis, bad);
		return bad || nmis;
	}
	if (argc < 3) {
		fprintf(stderr, "usage: %s IMAGE.bin IMAGE.sym [-n N] [-s seed] [-b polls] [-v] [-S] [-t trace]\n", argv[0]);
		return 2;
	}
	for (int i = 3; i < argc; i++) {
		if (!strcmp(argv[i], "-n") && i + 1 < argc) n = atol(argv[++i]);
		else if (!strcmp(argv[i], "-s") && i + 1 < argc) rs ^= (uint64_t)atol(argv[++i]) * 0x9e3779b97f4a7c15ull;
		else if (!strcmp(argv[i], "-b") && i + 1 < argc) busy = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-v")) verbose++;
		else if (!strcmp(argv[i], "-S")) stats = 1;
		else if (!strcmp(argv[i], "-L") && i + 1 < argc) one_vector = argv[++i];
		else if (!strcmp(argv[i], "-P") && i + 1 < argc) one_poly = argv[++i];
		else if (!strcmp(argv[i], "-t") && i + 1 < argc) trace_file = fopen(argv[++i], "w");
		else if (!strcmp(argv[i], "-I") && i + 1 < argc) initial_path = argv[++i];
		else if (!strcmp(argv[i], "-F") && i + 1 < argc) final_path = argv[++i];
		else if (!strcmp(argv[i], "-k") && i + 1 < argc) trace_test = atol(argv[++i]);
		else if (!strcmp(argv[i], "-K") && i + 1 < argc) parse_kinds(argv[++i]);
		else { fprintf(stderr, "bad argument %s\n", argv[i]); return 2; }
	}
	ram = calloc(1, RAM_SIZE);
	if (!(f = fopen(argv[1], "rb")))
		die("can't open %s", argv[1]);
	fseek(f, 0, SEEK_END);
	len = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (fread(&ram[IMAGE_BASE], 1, len, f) != (size_t)len)
		die("short read");
	fclose(f);
	load_syms(argv[2]);
	heap_init();
	cpu_init();
	G.trace = tracefn;
	G.busy_polls = busy;
	test_prom();
	fill_random(G.fb, sizeof G.fb);	/* power-up contents */
	cg6_reset(&G);
	/* -I: the frame buffer the trace starts from; the trace begins here */
	if (initial_path) {
		FILE *o = fopen(initial_path, "wb");
		if (!o || fwrite(G.fb, 1, CG6_W * CG6_H, o) != CG6_W * CG6_H)
			die("can't write %s", initial_path);
		fclose(o);
	}
	trace = trace_file;

	/* cg6_make(fd, size, depth, attr): the library's own attach; size by
	   value (fbmake) */
	{
		strcpy(cat, "make");
#ifdef M68K
		FB = call("_cg6_make", 5, 3, CG6_W, CG6_H, 8, 0);
#else
		uint32_t size = h_alloc(8);
		wr32(size, CG6_W);
		wr32(size + 4, CG6_H);
		FB = call("_cg6_make", 4, 3, size, 8, 0);
#endif
		if (!FB)
			die("cg6_make failed");
		cat[0] = 0;
	}
	M = mem_create(CG6_W, CG6_H, 8);
	sync_mirror();

	if (one_poly) {		/* -P x,y,x,y,...: a polygon on a cleared mirror, its spans */
		int v[16], k = 0;
		const char *q = one_poly;
		uint32_t pts = h_alloc(64), np = h_alloc(4);
		while (k < 16 && sscanf(q, "%d", &v[k]) == 1) {
			k++;
			q = strchr(q, ',');
			if (!q) break;
			q++;
		}
		for (int i = 0; i < k; i++) wr32(pts + 4 * i, v[i]);
		wr32(np, k / 2);
		memset(image(M), 0, CG6_W * CG6_H);
		call("_pr_polygon_2", 10, M, 0, 0, 1, np, pts, PIX_SRC | PIX_COLOR(1), 0, 0, 0);
		for (int y = 0; y < CG6_H; y++) {
			int first = -1, last = -1, gaps = 0;
			for (int x = 0; x < CG6_W; x++)
				if (image(M)[y * CG6_W + x]) {
					if (first < 0) first = x;
					else if (x != last + 1) gaps++;
					last = x;
				}
			if (first >= 0)
				printf("y %d: %d..%d%s\n", y, first, last, gaps ? " (gaps)" : "");
		}
		n = 0;
	}
	if (one_vector) {		/* -L x0,y0,x1,y1,op,color: one vector, traced */
		int v[6];
		sscanf(one_vector, "%d,%d,%d,%d,%x,%d", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]);
		trace = stdout;
		start("vector");
		call("_cg6_vector", 7, FB, v[0], v[1], v[2], v[3], v[4], v[5]);
		trace = NULL;
		call("_mem_vector", 7, M, v[0], v[1], v[2], v[3], v[4], v[5]);
		compare("vector", 0xff);
		n = 0;
	}
	for (long i = 0; i < n; i++) {
		static const int kind_of[9] = { -1, -1, K_VECTOR, K_BATCH, K_STENCIL, K_REPLROP,
						K_POLYGON, K_POLYLINE, K_POLYPOINT };
		int t = rn(9);

		/* -K: a kind left out is drawn again (test_rop: when none of its own are in) */
		if (kind_of[t] < 0 ? !(kinds & ((1u << K_ROP_KINDS) - 1)) : !(kinds >> kind_of[t] & 1)) {
			i--;
			continue;
		}
		switch (t) {
		case 0: case 1: test_rop(); break;
		case 2: test_vector(); break;
		case 3: test_batch(); break;
		case 4: test_stencil(); break;
		case 5: test_replrop(); break;
		case 6: test_polygon(); break;
		case 7: test_polyline(); break;
		default: test_polypoint(); break;
		}
	}
	printf("%lu tests, %lu failed, %lu where Sun's mem code is the one wrong, "
	       "%lu batchrops with cg6_batchrop's stale clip, %lu runaway stencils; "
	       "%lu board accesses, %lu instructions; "
	       "engine: %lu points %lu lines %lu tris %lu quads %lu rects %lu blits %lu font, %lu refused\n",
	       ntests, nfail, nmemdis, nsunbug, nrunaway, nboard, ICOUNT, G.ndraw[0], G.ndraw[1], G.ndraw[2], G.ndraw[3],
	       G.ndraw[4], G.nblit, G.nfont, G.nfull);
	if (stats)
		print_stats();
	(void)nfallback; (void)fallback_mark;
	if (final_path) {
		FILE *o = fopen(final_path, "wb");
		if (!o || fwrite(G.fb, 1, CG6_W * CG6_H, o) != CG6_W * CG6_H)
			die("can't write %s", final_path);
		fclose(o);
	}
	if (trace_file)
		fclose(trace_file);
	return nfail != 0;
}
