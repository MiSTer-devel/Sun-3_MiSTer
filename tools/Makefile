# Boot PROM preparation for the Sun-3/60 MiSTer core.
#
# The core does not carry Sun's PROM: the user puts a patched 3/60 PROM on
# the SD card as games/Sun-3/boot0.rom.  The stock 3/60 PROMs test parity
# memory, which this machine does not have, so each is patched first by
# rompatch, which checks every word it changes and fixes the PROM's checksum
# (both from Sun-3_FPGA, with their patch lists).
#
#   make -C tools                 build/rom/sun3_60_v1.9_noparity.bin, the boot0.rom
#   make -C tools fetch           the stock PROMs from sun3arc.org into build/rom/
#   make -C tools all-roms        also 3.0.1's noparity image, and 1.9's `fast'
#                                 image for the simulation (tb/verilator tb_emu)
#
# A stock image may also be dropped into build/rom/ by hand (sun3_60_v<ver>.bin,
# 65536 bytes); it is checked against the published SHA-256 either way.
#
#   build/rom/sun3_60_v1.9_noparity.bin    parity hardware taken out: boot0.rom
#   build/rom/sun3_60_v3.0.1_noparity.bin  the same for Rev 3.0.1
#   build/rom/sun3_60_v1.9_fast.bin        noparity plus Sun-3_FPGA's fastboot
#                                          list: simulation only (waits and
#                                          memory fills shortened)

TOP     = ..
ROMDIR  = $(TOP)/build/rom
SUN3ARC = https://www.sun3arc.org/ROMs/3_60

# sha256 of the unpacked images (Sun-3_FPGA tools/Makefile, from qemu-sun3)
SHA_1.9   = 471bf34cc9313814726c2e3506d85a13291603e37b45aaffa71bc1154a2d4851
SHA_2.8.3 = 8b29ec9fe1cd08f6d9ed362f3b508e7a7270780dc825d62d8f5eda00e0a0d940
SHA_3.0.1 = b562aa5d7bc51eed732fbafde1fd6ea1340977d2b04fb826201c079f699212c6

CC     ?= cc
CFLAGS ?= -O2 -Wall

all: $(ROMDIR)/sun3_60_v1.9_noparity.bin

all-roms: $(ROMDIR)/sun3_60_v1.9_noparity.bin $(ROMDIR)/sun3_60_v3.0.1_noparity.bin \
          $(ROMDIR)/sun3_60_v1.9_fast.bin

fetch: $(ROMDIR)/sun3_60_v1.9.bin $(ROMDIR)/sun3_60_v2.8.3.bin $(ROMDIR)/sun3_60_v3.0.1.bin

$(ROMDIR):
	mkdir -p $(ROMDIR)

rompatch: rompatch.c
	$(CC) $(CFLAGS) -o $@ $<

rom: rom.c
	$(CC) $(CFLAGS) -o $@ $<

# sun3arc serves 1.9 gzipped twice, the others once: gunzip until it stops
# being gzip.  The result is checked against the published hash either way.
$(ROMDIR)/sun3_60_v%.bin: | $(ROMDIR)
	@t=$@.tmp; curl -sfL -o $$t.gz $(SUN3ARC)/sun3_60_v$*.gz || { echo "cannot fetch $(SUN3ARC)/sun3_60_v$*.gz"; exit 1; }; \
	while gzip -t $$t.gz 2>/dev/null; do gunzip -c $$t.gz >$$t; mv $$t $$t.gz; done; \
	mv $$t.gz $@
	@echo "$(SHA_$*)  $@" | sha256sum -c --quiet || { rm -f $@; exit 1; }
	@echo "fetched $@ (sha256 ok)"

$(ROMDIR)/sun3_60_v1.9_noparity.bin: $(ROMDIR)/sun3_60_v1.9.bin rompatch sun3_60_v1.9_noparity.txt
	@echo "$(SHA_1.9)  $<" | sha256sum -c --quiet
	./rompatch $< $@ sun3_60_v1.9_noparity.txt

$(ROMDIR)/sun3_60_v1.9_fast.bin: $(ROMDIR)/sun3_60_v1.9.bin rompatch sun3_60_v1.9_noparity.txt sun3_60_v1.9_fastboot.txt
	@echo "$(SHA_1.9)  $<" | sha256sum -c --quiet
	./rompatch $< $@ sun3_60_v1.9_noparity.txt sun3_60_v1.9_fastboot.txt

$(ROMDIR)/sun3_60_v3.0.1_noparity.bin: $(ROMDIR)/sun3_60_v3.0.1.bin rompatch sun3_60_v3.0.1_noparity.txt
	@echo "$(SHA_3.0.1)  $<" | sha256sum -c --quiet
	./rompatch $< $@ sun3_60_v3.0.1_noparity.txt

clean:
	rm -f rompatch rom

.PHONY: all all-roms fetch clean
