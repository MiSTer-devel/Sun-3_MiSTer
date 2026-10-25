/*
 * A SPARC V8 integer-unit interpreter (sparc.h).  The encodings are the
 * SPARC Architecture Manual's, version 8: format 1 (call), format 2 (sethi,
 * Bicc) and format 3 (arithmetic, loads and stores).  Delayed control
 * transfer is pc/npc, with the annul bit as the manual gives it.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sparc.h"

char sparc_fault[200];

void sparc_init(struct sparc *s)
{
	if (!s->w)
		s->w = calloc(SP_NWIN * 16 + 16, sizeof *s->w);
	memset(s->g, 0, sizeof s->g);
	s->cwp = (SP_NWIN - 2) * 16;
	s->n = s->z = s->v = s->c = 0;
	s->y = 0;
}

uint32_t sparc_get(struct sparc *s, int r)
{
	if (r < 8)
		return r ? s->g[r] : 0;
	return s->w[s->cwp + r - 8];
}

void sparc_set(struct sparc *s, int r, uint32_t v)
{
	if (r < 8) {
		if (r)
			s->g[r] = v;
	} else
		s->w[s->cwp + r - 8] = v;
}

#define GET(r) sparc_get(s, r)
#define SET(r, v) sparc_set(s, r, v)

static int fault(struct sparc *s, const char *what, uint32_t insn)
{
	snprintf(sparc_fault, sizeof sparc_fault, "%s: insn %08x at pc %08x",
		 what, insn, s->pc);
	return 1;
}

static void logic_cc(struct sparc *s, uint32_t r)
{
	s->n = r >> 31;
	s->z = r == 0;
	s->v = s->c = 0;
}

static uint32_t add_cc(struct sparc *s, uint32_t a, uint32_t b, int cin, int setcc)
{
	uint64_t wide = (uint64_t)a + b + cin;
	uint32_t r = (uint32_t)wide;

	if (setcc) {
		s->n = r >> 31;
		s->z = r == 0;
		s->v = ((a & b & ~r) | (~a & ~b & r)) >> 31;
		s->c = wide >> 32 & 1;
	}
	return r;
}

static uint32_t sub_cc(struct sparc *s, uint32_t a, uint32_t b, int cin, int setcc)
{
	uint32_t r = a - b - cin;

	if (setcc) {
		s->n = r >> 31;
		s->z = r == 0;
		s->v = ((a & ~b & ~r) | (~a & b & r)) >> 31;
		s->c = (uint64_t)a < (uint64_t)b + cin;
	}
	return r;
}

static int cond(struct sparc *s, int c)
{
	int r;

	switch (c & 7) {
	case 0: r = 0; break;				/* n / a */
	case 1: r = s->z; break;			/* e / ne */
	case 2: r = s->z | (s->n ^ s->v); break;	/* le / g */
	case 3: r = s->n ^ s->v; break;			/* l / ge */
	case 4: r = s->c | s->z; break;			/* leu / gu */
	case 5: r = s->c; break;			/* cs / cc */
	case 6: r = s->n; break;			/* neg / pos */
	default: r = s->v; break;			/* vs / vc */
	}
	return c & 8 ? !r : r;
}

int sparc_run(struct sparc *s, unsigned long count)
{
	for (unsigned long k = 0; k < count && !s->stop; k++) {
		uint32_t insn, pc = s->pc, npc = s->npc;
		int op, rd, op3, rs1;
		uint32_t a, b, r, ea;

		if (pc & 3)
			return fault(s, "misaligned pc", 0);
		insn = s->rd(pc, 4);
		s->icount++;
		op = insn >> 30;
		rd = insn >> 25 & 31;
		s->pc = npc;
		s->npc = npc + 4;

		if (op == 1) {			/* call */
			SET(R_O7, pc);
			s->npc = pc + (insn << 2);
			continue;
		}
		if (op == 0) {
			int op2 = insn >> 22 & 7;

			if (op2 == 4) {		/* sethi */
				SET(rd, insn << 10);
				continue;
			}
			if (op2 == 2) {		/* Bicc */
				int c = insn >> 25 & 15, annul = insn >> 29 & 1;
				int32_t disp = (int32_t)(insn << 10) >> 8;

				if (c == 8) {			/* ba */
					if (annul) {
						s->pc = pc + disp;
						s->npc = s->pc + 4;
					} else
						s->npc = pc + disp;
				} else if (cond(s, c)) {
					s->npc = pc + disp;
				} else if (annul) {		/* skip the delay slot */
					s->pc = npc + 4;
					s->npc = npc + 8;
				}
				continue;
			}
			if (op2 == 0) {		/* unimp: the host's */
				s->pc = pc;
				s->npc = npc;
				if (s->unimp && s->unimp(s, insn))
					continue;
				return fault(s, "unimp", insn);
			}
			s->pc = pc;
			return fault(s, "format 2 op", insn);
		}

		op3 = insn >> 19 & 63;
		rs1 = insn >> 14 & 31;
		a = GET(rs1);
		if (insn & 0x2000)
			b = (uint32_t)((int32_t)(insn << 19) >> 19);
		else
			b = GET(insn & 31);

		if (op == 3) {			/* loads and stores */
			ea = a + b;
			switch (op3) {
			case 0x00: case 0x03: case 0x04: case 0x07: case 0x0f:
				if (ea & 3) { s->pc = pc; return fault(s, "misaligned word", insn); }
				break;
			case 0x02: case 0x06: case 0x0a:
				if (ea & 1) { s->pc = pc; return fault(s, "misaligned half", insn); }
				break;
			}
			if ((op3 == 0x03 || op3 == 0x07) && (ea & 7)) {
				s->pc = pc;
				return fault(s, "misaligned double", insn);
			}
			switch (op3) {
			case 0x00: SET(rd, s->rd(ea, 4)); break;			/* ld */
			case 0x01: SET(rd, s->rd(ea, 1)); break;			/* ldub */
			case 0x02: SET(rd, s->rd(ea, 2)); break;			/* lduh */
			case 0x03:							/* ldd */
				r = s->rd(ea, 4);
				SET(rd & ~1, r);
				SET(rd | 1, s->rd(ea + 4, 4));
				break;
			case 0x04: s->wr(ea, 4, GET(rd)); break;			/* st */
			case 0x05: s->wr(ea, 1, GET(rd)); break;			/* stb */
			case 0x06: s->wr(ea, 2, GET(rd)); break;			/* sth */
			case 0x07:							/* std */
				s->wr(ea, 4, GET(rd & ~1));
				s->wr(ea + 4, 4, GET(rd | 1));
				break;
			case 0x09: SET(rd, (uint32_t)(int8_t)s->rd(ea, 1)); break;	/* ldsb */
			case 0x0a: SET(rd, (uint32_t)(int16_t)s->rd(ea, 2)); break;	/* ldsh */
			case 0x0d:							/* ldstub */
				r = s->rd(ea, 1);
				s->wr(ea, 1, 0xff);
				SET(rd, r);
				break;
			case 0x0f:							/* swap */
				r = s->rd(ea, 4);
				s->wr(ea, 4, GET(rd));
				SET(rd, r);
				break;
			default:
				s->pc = pc;
				return fault(s, "load/store op", insn);
			}
			continue;
		}

		/* op == 2 */
		switch (op3) {
		case 0x00: SET(rd, a + b); break;
		case 0x10: SET(rd, add_cc(s, a, b, 0, 1)); break;
		case 0x08: SET(rd, a + b + s->c); break;
		case 0x18: SET(rd, add_cc(s, a, b, s->c, 1)); break;
		case 0x04: SET(rd, a - b); break;
		case 0x14: SET(rd, sub_cc(s, a, b, 0, 1)); break;
		case 0x0c: SET(rd, a - b - s->c); break;
		case 0x1c: SET(rd, sub_cc(s, a, b, s->c, 1)); break;
		case 0x01: SET(rd, a & b); break;
		case 0x11: r = a & b; logic_cc(s, r); SET(rd, r); break;
		case 0x02: SET(rd, a | b); break;
		case 0x12: r = a | b; logic_cc(s, r); SET(rd, r); break;
		case 0x03: SET(rd, a ^ b); break;
		case 0x13: r = a ^ b; logic_cc(s, r); SET(rd, r); break;
		case 0x05: SET(rd, a & ~b); break;
		case 0x15: r = a & ~b; logic_cc(s, r); SET(rd, r); break;
		case 0x06: SET(rd, a | ~b); break;
		case 0x16: r = a | ~b; logic_cc(s, r); SET(rd, r); break;
		case 0x07: SET(rd, ~(a ^ b)); break;
		case 0x17: r = ~(a ^ b); logic_cc(s, r); SET(rd, r); break;
		case 0x0a: case 0x1a: {						/* umul */
			uint64_t p = (uint64_t)a * b;
			s->y = p >> 32;
			if (op3 & 0x10)
				logic_cc(s, (uint32_t)p);
			SET(rd, (uint32_t)p);
			break;
		}
		case 0x0b: case 0x1b: {						/* smul */
			int64_t p = (int64_t)(int32_t)a * (int32_t)b;
			s->y = (uint64_t)p >> 32;
			if (op3 & 0x10)
				logic_cc(s, (uint32_t)p);
			SET(rd, (uint32_t)p);
			break;
		}
		case 0x0e: case 0x1e: {						/* udiv */
			uint64_t n = (uint64_t)s->y << 32 | a, q;
			if (!b) { s->pc = pc; return fault(s, "division by zero", insn); }
			q = n / b;
			if (q > 0xffffffffu) q = 0xffffffffu;
			if (op3 & 0x10) logic_cc(s, (uint32_t)q);
			SET(rd, (uint32_t)q);
			break;
		}
		case 0x0f: case 0x1f: {						/* sdiv */
			int64_t n = (int64_t)((uint64_t)s->y << 32 | a), q;
			if (!b) { s->pc = pc; return fault(s, "division by zero", insn); }
			q = n / (int32_t)b;
			if (q > 0x7fffffff) q = 0x7fffffff;
			if (q < -0x7fffffffll - 1) q = -0x7fffffffll - 1;
			if (op3 & 0x10) logic_cc(s, (uint32_t)q);
			SET(rd, (uint32_t)q);
			break;
		}
		case 0x24: {							/* mulscc */
			uint32_t op1 = (a >> 1) | (uint32_t)(s->n ^ s->v) << 31;
			uint32_t op2 = s->y & 1 ? b : 0;
			s->y = (s->y >> 1) | a << 31;
			SET(rd, add_cc(s, op1, op2, 0, 1));
			break;
		}
		case 0x25: SET(rd, a << (b & 31)); break;
		case 0x26: SET(rd, a >> (b & 31)); break;
		case 0x27: SET(rd, (uint32_t)((int32_t)a >> (b & 31))); break;
		case 0x28:							/* rd %y */
			if (rs1) { s->pc = pc; return fault(s, "rd asr", insn); }
			SET(rd, s->y);
			break;
		case 0x30:							/* wr %y */
			if (rd) { s->pc = pc; return fault(s, "wr asr", insn); }
			s->y = a ^ b;
			break;
		case 0x38:							/* jmpl */
			r = a + b;
			if (r & 3) { s->pc = pc; return fault(s, "misaligned jmpl", insn); }
			SET(rd, pc);
			s->npc = r;
			break;
		case 0x3c:							/* save */
			if (s->cwp < 16) { s->pc = pc; return fault(s, "window stack exhausted", insn); }
			r = a + b;
			s->cwp -= 16;
			SET(rd, r);
			break;
		case 0x3d:							/* restore */
			if (s->cwp >= SP_NWIN * 16) { s->pc = pc; return fault(s, "restore past the top", insn); }
			r = a + b;
			s->cwp += 16;
			SET(rd, r);
			break;
		default:
			s->pc = pc;
			return fault(s, "arithmetic op", insn);
		}
	}
	return 0;
}
