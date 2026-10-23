/*
 * A SPARC V8 integer-unit interpreter, enough to run SunOS's compiled C
 * (libpixrect) in user mode.  No FPU, no traps but the harness's own: an
 * `unimp' word is handed to the host (the stubs), and anything else the
 * interpreter does not know stops the run.
 *
 * Register windows are a stack in host memory, never spilled: SunOS's
 * compiled C never reaches into another frame's registers through memory.
 */
#ifndef SPARC_H
#define SPARC_H
#include <stdint.h>

#define SP_NWIN	4096		/* windows deep: far more than any call chain */

struct sparc {
	uint32_t pc, npc, y;
	int n, z, v, c;		/* icc */
	uint32_t g[8];
	uint32_t *w;		/* windows: outs, locals, ins of each, overlapping */
	int cwp;		/* index of the current window's outs in w[] */
	unsigned long icount;
	/* the host's side */
	uint32_t (*rd)(uint32_t a, int size);			/* size 1, 2, 4 */
	void (*wr)(uint32_t a, int size, uint32_t v);
	int (*unimp)(struct sparc *, uint32_t insn);		/* 1: handled */
	int stop;		/* set by the host to end sparc_run */
};

void sparc_init(struct sparc *);
uint32_t sparc_get(struct sparc *, int r);
void sparc_set(struct sparc *, int r, uint32_t v);
/* run until stop is set or n instructions; returns nonzero on a fault */
int sparc_run(struct sparc *, unsigned long n);
extern char sparc_fault[200];

/* register numbers */
#define R_G(n)	(n)
#define R_O(n)	(8 + (n))
#define R_L(n)	(16 + (n))
#define R_I(n)	(24 + (n))
#define R_SP	R_O(6)
#define R_FP	R_I(6)
#define R_O7	R_O(7)

#endif
