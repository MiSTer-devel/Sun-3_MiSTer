# The GX (cg6) model and the harness that runs SunOS's libpixrect against it.
#
#   make -C tools/cg6model                 build, link the library, run
#   make -C tools/cg6model run N=20000 SEED=7 BUSY=3
#   make -C tools/cg6model mutate          the mutation check (mutate.sh)
#
# Needs gcc and python3.  LIBPIXRECT is a SunOS 4.1.x SPARC libpixrect.a
# (/usr/lib/libpixrect.a); docs/cg6.md, "The C model", says where the one
# this was checked with came from.  Nothing from SunOS is copied into the
# tree; the linked image goes to $(B).

LIBPIXRECT ?= ../../build/dist/sunos-4.1.3-sparc/libpixrect.a
B	:= ../../build/cg6model
N	?= 3000
SEED	?= 1
BUSY	?= 0

CC	?= gcc
CFLAGS	:= -O2 -g -Wall -Wextra -Wno-unused-parameter

# what the harness calls; pr_* dispatch to the cg6 routines by pr_ops
ROOTS	:= _cg6_make _cg6_destroy _cg6_rop _cg6_vector _cg6_vector0 _cg6_batchrop \
	   _cg6_stencil _cg6_get _cg6_put _cg6_region _cg6_putcolormap \
	   _cg6_getcolormap _cg6_ops _pr_polygon_2 _pr_polyline _pr_polypoint \
	   _pr_replrop _pro_line _mem_create _mem_destroy _mem_region _mem_rop \
	   _mem_vector _mem_batchrop _mem_stencil _mem_get _mem_put _mem_ops
STUBS	:= _pr_makefromfd _pr_unmakefromfd

all: run

$(B)/harness: harness.c cg6model.c cg6model.h sparc.c sparc.h
	mkdir -p $(B)
	$(CC) $(CFLAGS) -o $@ harness.c cg6model.c sparc.c

$(B)/lp.bin: $(LIBPIXRECT) aoutlink.py
	mkdir -p $(B)
	python3 aoutlink.py -o $(B)/lp --lib $(LIBPIXRECT) \
	    $(addprefix --root ,$(ROOTS)) $(addprefix --stub ,$(STUBS))

# the random tests, then a traced run replayed on a fresh model
run: $(B)/harness $(B)/lp.bin
	$(B)/harness $(B)/lp.bin $(B)/lp.sym -n $(N) -s $(SEED) -b $(BUSY)
	$(B)/harness $(B)/lp.bin $(B)/lp.sym -n 300 -s $(SEED) -b $(BUSY) \
	    -t $(B)/trace.txt -I $(B)/initial.bin -F $(B)/final.bin
	$(B)/harness -R $(B)/trace.txt $(B)/initial.bin $(B)/final.bin $(BUSY)

mutate: $(B)/harness $(B)/lp.bin
	B=$(abspath $(B)) bash mutate.sh

clean:
	rm -f $(B)/harness $(B)/lp.* $(B)/trace.txt $(B)/initial.bin $(B)/final.bin

.PHONY: all run mutate clean
