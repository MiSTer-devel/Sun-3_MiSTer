# The GX (cg6) model and the harness that runs SunOS's libpixrect against it.
#
#   make -C tools/cg6model                 build, link the library, run
#   make -C tools/cg6model run N=20000 SEED=7 BUSY=3
#   make -C tools/cg6model mutate          the mutation check (mutate.sh)
#
#   make -C tools/cg6model run68k [N= SEED= BUSY=]   the same on the 68020
#   make -C tools/cg6model mutate68k
#   make -C tools/cg6model trace68k [B=dir] [TN=300] [SEED=]
#                                          $(B)/t_lp68k.{txt,ini,fin}, every kind
#
#   make -C tools/cg6model xnews [XN=2000 SEED=]   OpenWindows 2.0's own TEC code
#                                          (xnews.c) against the model's TEC
#   make -C tools/cg6model mutatexn        the model's TEC broken: xnews.c must see it
#   make -C tools/cg6model tracexn [B=dir] [XTN=300] [SEED=]
#                                          $(B)/t_xn.{txt,ini,fin}, for tb_cg6
#
# Needs gcc and python3.  LIBPIXRECT is a SunOS 4.1.x SPARC libpixrect.a
# (/usr/lib/libpixrect.a), LIBPIXRECT68K a sun3 one; docs/cg6.md, "The C
# model", says where the ones this was checked with came from.  Nothing from
# SunOS is copied into the tree; the linked images go to $(B).
#
# The 68020 harness (harness68k, harness.c with -DM68K) runs on Musashi (MIT
# licence): MUSASHI is a checkout of it, by default fetched with git at a
# pinned commit into $(B)/musashi.  Its sources are copied into $(B)/m68k and
# its opcode tables generated there, so a checkout given is not written to.

LIBPIXRECT ?= ../../build/dist/sunos-4.1.3-sparc/libpixrect.a
LIBPIXRECT68K ?= ../../build/dist/sunos-4.1.1-sun3/usr/lib/libpixrect.a
XNEWS	?= ../../build/dist/sunos-4.1.1-sun3/usr/openwin/bin/xnews
XN	?= 2000
XTN	?= 300
B	:= ../../build/cg6model
N	?= 3000
TN	?= 300
SEED	?= 1
BUSY	?= 0

MUSASHI_URL := https://github.com/kstenerud/Musashi
MUSASHI_REV := 313ebf1bd9f4d0d93341eb5ce21fd8a119e9dbdd
MUSASHI	?= $(B)/musashi
MB	:= $(B)/m68k

CC	?= gcc
CFLAGS	:= -O2 -g -Wall -Wextra -Wno-unused-parameter
M68KDEFS := -DM68K_ILLG_HAS_CALLBACK=M68K_OPT_ON -DM68K_INSTRUCTION_HOOK=M68K_OPT_ON

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
	$(CC) $(CFLAGS) -o $@ harness.c cg6model.c sparc.c -lm

$(B)/lp.bin: $(LIBPIXRECT) aoutlink.py
	mkdir -p $(B)
	python3 aoutlink.py -o $(B)/lp --lib $(LIBPIXRECT) \
	    $(addprefix --root ,$(ROOTS)) $(addprefix --stub ,$(STUBS))

# ---- the 68020 ----
$(MUSASHI)/m68k.h:
	@test ! -e $(MUSASHI) || { echo "$(MUSASHI) is not a Musashi checkout"; exit 1; }
	git clone -q $(MUSASHI_URL) $(MUSASHI)
	git -C $(MUSASHI) checkout -q $(MUSASHI_REV)

MUSRC	:= m68k.h m68k_in.c m68kconf.h m68kcpu.c m68kcpu.h m68kdasm.c m68kfpu.c \
	   m68kmake.c m68kmmu.h

$(MB)/m68kops.c: $(MUSASHI)/m68k.h
	rm -rf $(MB)
	mkdir -p $(MB)
	cp $(addprefix $(MUSASHI)/,$(MUSRC)) $(MB)/
	cp -r $(MUSASHI)/softfloat $(MB)/
	$(CC) -o $(MB)/m68kmake $(MB)/m68kmake.c
	cd $(MB) && ./m68kmake > /dev/null

MUOBJ	:= $(MB)/m68kcpu.o $(MB)/m68kops.o $(MB)/m68kdasm.o $(MB)/softfloat.o

$(MB)/m68kcpu.o $(MB)/m68kops.o $(MB)/m68kdasm.o: $(MB)/%.o: $(MB)/m68kops.c
	$(CC) -O2 -w $(M68KDEFS) -I$(MB) -c -o $@ $(MB)/$*.c
$(MB)/softfloat.o: $(MB)/m68kops.c
	$(CC) -O2 -w $(M68KDEFS) -I$(MB) -c -o $@ $(MB)/softfloat/softfloat.c

$(B)/harness68k: harness.c cg6model.c cg6model.h $(MUOBJ)
	$(CC) $(CFLAGS) -DM68K $(M68KDEFS) -I$(MB) -o $@ harness.c cg6model.c $(MUOBJ) -lm

$(B)/xnews68k: xnews.c cg6model.c cg6model.h $(MUOBJ)
	$(CC) $(CFLAGS) $(M68KDEFS) -I$(MB) -o $@ xnews.c cg6model.c $(MUOBJ) -lm

# the TEC's arithmetic against the host's, then xnews's routines on it
xnews: $(B)/xnews68k
	$(B)/xnews68k -T
	$(B)/xnews68k $(XNEWS) -n $(XN) -s $(SEED)

mutatexn: $(B)/xnews68k
	XNEWS=$(abspath $(XNEWS)) M68K="$(M68KDEFS) -I$(abspath $(MB))" \
	    MUOBJ="$(abspath $(MUOBJ))" bash mutatexn.sh

tracexn: $(B)/xnews68k
	$(B)/xnews68k $(XNEWS) -n $(XTN) -s $(SEED) -t $(B)/t_xn.txt -I $(B)/t_xn.ini -F $(B)/t_xn.fin

$(B)/lp68k.bin: $(LIBPIXRECT68K) aoutlink.py
	mkdir -p $(B)
	python3 aoutlink.py -o $(B)/lp68k --lib $(LIBPIXRECT68K) \
	    $(addprefix --root ,$(ROOTS)) $(addprefix --stub ,$(STUBS))

# the random tests, then a traced run replayed on a fresh model
run: $(B)/harness $(B)/lp.bin
	$(B)/harness $(B)/lp.bin $(B)/lp.sym -n $(N) -s $(SEED) -b $(BUSY)
	$(B)/harness $(B)/lp.bin $(B)/lp.sym -n 300 -s $(SEED) -b $(BUSY) \
	    -t $(B)/trace.txt -I $(B)/initial.bin -F $(B)/final.bin
	$(B)/harness -R $(B)/trace.txt $(B)/initial.bin $(B)/final.bin $(BUSY)

run68k: $(B)/harness68k $(B)/lp68k.bin
	$(B)/harness68k $(B)/lp68k.bin $(B)/lp68k.sym -n $(N) -s $(SEED) -b $(BUSY)
	$(MAKE) trace68k
	$(B)/harness68k -R $(B)/t_lp68k.txt $(B)/t_lp68k.ini $(B)/t_lp68k.fin

# a trace of every kind of test for an RTL bench, as tb_cg6's t_lp (-b 0)
trace68k: $(B)/harness68k $(B)/lp68k.bin
	$(B)/harness68k $(B)/lp68k.bin $(B)/lp68k.sym -n $(TN) -s $(SEED) \
	    -t $(B)/t_lp68k.txt -I $(B)/t_lp68k.ini -F $(B)/t_lp68k.fin

mutate: $(B)/harness $(B)/lp.bin
	B=$(abspath $(B)) bash mutate.sh

mutate68k: $(B)/harness68k $(B)/lp68k.bin
	B=$(abspath $(B)) M68K="$(M68KDEFS) -I$(abspath $(MB))" \
	    MUOBJ="$(abspath $(MUOBJ))" bash mutate.sh

clean:
	rm -rf $(B)/harness $(B)/harness68k $(B)/lp.* $(B)/lp68k.* $(B)/trace.txt \
	    $(B)/initial.bin $(B)/final.bin $(B)/t_lp68k.* $(B)/xnews68k $(B)/t_xn.* $(MB)

.PHONY: all run run68k trace68k xnews tracexn mutatexn mutate mutate68k clean
