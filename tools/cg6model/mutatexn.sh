#!/bin/bash
# Mutation check of the model's TEC against xnews (xnews.c): each mutation
# breaks one rule of the TEC (docs/cg6.md, "The TEC"), and xnews68k -T (the
# arithmetic against the host's) or xnews68k -c (xnews's own routines
# against it) must fail.  A "NOT CAUGHT" is a hole in the check.
#
#   make -C tools/cg6model mutatexn [XNEWS=...]    (sets M68K, MUOBJ, XNEWS)
set -u
D=$(cd "$(dirname "$0")" && pwd)
N=${1:-2000}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# from @@ to @@ what: literal text in cg6model.c
mutations=(
	'return (uint32_t)-(int64_t)(ip + frac);@@return (uint32_t)-(int64_t)ip;@@to integer toward minus infinity'
	'if (rest > half || (rest == half && (m & 1)))@@if (rest >= half)@@ties to even'
	'mb = mb >> d | ((mb & ((1ull << d) - 1)) != 0);@@mb = mb >> d;@@the addend'"'"'s sticky bit'
	'case 1: return tec_i2f(v, 16);@@case 1: return tec_i2f(v, 15);@@fixed in'
	'case 1: return tec_f2i(f, 16);@@case 1: return tec_f2i(f, 15);@@fixed out'
	'int base = idx + j * rows;@@int base = idx + j * 4;@@MV'"'"'s matrix column by column'
	'uint32_t w = rel ? 0 : mv >> 13 & 1 ? d[3] : F_ONE;@@uint32_t w = mv >> 13 & 1 ? d[3] : F_ONE;@@a relative vertex untranslated'
	'if (rel)
			acc = tec_fadd(d[4 + j], acc);@@if (0)
			acc = tec_fadd(d[4 + j], acc);@@a relative vertex from the last result'
	'(int32_t)tec_f2i(d[4], 0) + g->offx@@(int32_t)tec_f2i(tec_fadd(d[4], 0x3f000000), 0) + g->offx@@autoload rounded down'
	'(int32_t)tec_f2i(d[5], 0) + g->offy@@(int32_t)tec_f2i(d[5], 0)@@autoload through the raster offset'
	'int base = bi + j * m;@@int base = bi + j * n;@@a command'"'"'s B column by column'
	'a[k] = d[(ai + k) & 63];@@a[k] = d[(ai + 2 * k) & 63];@@a command'"'"'s A in a row'
	'(uint32_t)(g->nv & 3) << 4 |@@(uint32_t)((g->nv - 1) & 3) << 4 |@@MISC'"'"'s index the next slot'
	'f_pack(s, ea + eb - 127,@@f_pack(s, ea + eb - 126,@@the product'"'"'s exponent'
	'(g->misc_vblank ? MISC_VBLANK : 0);@@(g->misc & MISC_VBLANK);@@MISC'"'"'s vertical blank, not as written'
)

caught=0; total=0
for m in "${mutations[@]}"; do
	from=${m%%@@*}; rest=${m#*@@}; to=${rest%%@@*}; what=${rest#*@@}
	total=$((total + 1))
	cp "$D"/*.c "$D"/*.h "$W"/
	FROM=$from TO=$to python3 -c 'import os, sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace(os.environ["FROM"], os.environ["TO"], 1))' "$W/cg6model.c"
	if cmp -s "$D/cg6model.c" "$W/cg6model.c"; then
		echo "BAD MUTATION (no change): $what"
		continue
	fi
	gcc -O2 $M68K -o "$W/x" "$W/xnews.c" "$W/cg6model.c" $MUOBJ -lm 2>/dev/null || { echo "BAD MUTATION (no build): $what"; continue; }
	if (cd "$W" && ./x -T >/dev/null 2>&1 && timeout 600 ./x "$XNEWS" -n "$N" -s 1 -c >/dev/null 2>&1); then
		echo "NOT CAUGHT: $what"
	else
		echo "caught: $what"
		caught=$((caught + 1))
	fi
done
echo "$caught of $total caught"
[ "$caught" = "$total" ]
