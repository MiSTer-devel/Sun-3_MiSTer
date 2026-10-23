#!/bin/bash
# Mutation check of the cg6model harness: each mutation breaks one rule of
# the model (docs/cg6.md), and the harness, running Sun's libpixrect against
# it, must fail.  A "NOT CAUGHT" is a hole in the harness.
#
#   bash tools/cg6model/mutate.sh [N]     (after make -C tools/cg6model)
set -u
D=$(cd "$(dirname "$0")" && pwd)
B=${B:-$D/../../build/cg6model}
N=${1:-1500}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# from @@ to @@ what: literal text in cg6model.c
mutations=(
	'r |= (rop >> k & 1) << i;@@r |= (rop >> (k ^ 1) & 1) << i;@@the raster-op truth table'
	'v = (v & ~(3u << sh)) | (old & 3u << sh);@@(void)old;@@an IGNORE field keeps its value'
	'return g->pixelmask >> (31 - (i & 31)) & 1;@@return g->pixelmask >> (i & 31) & 1;@@the pixel mask bit order'
	'int row = (y + ay) & 15, col = (x + ax) & 15;@@int row = (y - ay) & 15, col = (x - ax) & 15;@@the pattern alignment adds'
	'if (x1 < x0) {@@if (0) {@@lines drawn left to right'
	'keep = 1;@@keep = 0;@@a line keeps its end vertex'
	'if (g->pend != 3)@@if (!(g->pend & 1))@@a vertex needs both coordinates'
	'e->x += e->step >> 1;@@e->x += e->step;@@the polygon edge half step'
	'e->err += e->dy - e->dx;@@e->err += e->dy - e->dx + 1;@@the polygon edge DDA'
	'x < xs[i + 1]; x++)@@x <= xs[i + 1]; x++)@@polygon spans half open'
	'ydir = dy > sy ? -1 : 1;@@ydir = 1;@@the blit overlap direction'
	'g->y[0] += g->incy;@@g->y[0] += 0;@@the font autoincrement'
	'return FBC_S_EXCEPTION | FBC_S_FULL | FBC_S_BUSY;@@return FBC_S_FULL | FBC_S_BUSY;@@a refusal reads as exception and full'
	'if (!inclip(g, x, y) || !pixel_enabled(g, pmi))@@if (!pixel_enabled(g, pmi) || x < 0 || y < 0 || x >= CG6_W || y >= CG6_H)@@the clip window'
	'*p = (cg6_rop8(g->rasterop, g->fcolor, g->bcolor, s, *p) & pm) | (*p & ~pm);@@*p = cg6_rop8(g->rasterop, g->fcolor, g->bcolor, s, *p);@@the plane mask'
	'case 0x00: g->pend_x = sv + g->offx;@@case 0x00: g->pend_x = sv;@@the raster offset'
	'if (on && !g->vsync)@@if (0)@@the retrace interrupt'
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
	gcc -O2 -o "$W/h" "$W/harness.c" "$W/cg6model.c" "$W/sparc.c" 2>/dev/null || { echo "BAD MUTATION (no build): $what"; continue; }
	if (cd "$W" && timeout 600 ./h "$B/lp.bin" "$B/lp.sym" -n "$N" -s 1 -b 2 >/dev/null 2>&1); then
		echo "NOT CAUGHT: $what"
	else
		echo "caught: $what"
		caught=$((caught + 1))
	fi
done
echo "$caught of $total caught"
[ "$caught" = "$total" ]
