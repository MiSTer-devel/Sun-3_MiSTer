# Verilator unit tests for the MiSTer glue.
#
#   make -C tb/verilator            all of them
#   make -C tb/verilator tb_mister_sdram
#
# Verilator 5 with --timing; each target builds into obj_<name>/ and runs.
# Run from WSL: the scripts and the checkout's line endings assume it.

V      ?= verilator
RTL    := ../../rtl
VFLAGS := --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
          -Wno-UNSIGNED -Wno-CMPCONST -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY \
          -I$(RTL)/sun3 +define+SIMULATION=1

TESTS := tb_mister_sdram tb_mister_block tb_mister_kbd_mouse tb_mister_bell tb_kbm_scc tb_mister_tod tb_mt02 \
         tb_cg4 tb_cg4_scanout tb_mister_eeprom tb_si tb_vint tb_mister_enet tb_mister_cpuclk

# The whole core is its own makefile; it is a run, not a quick test, so it is
# not part of `all'.
.DEFAULT_GOAL := all
include emu.mk

all: $(TESTS)

# The SDRAM adapter (the Sun-3's lanes and map) and the controller, against a
# behavioural chip.
tb_mister_sdram:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv sdram_model.sv altddio_out_stub.v $(RTL)/sdram.sv $(RTL)/sun3_mister_sdram.sv
	./obj_$@/$@

# The disk/tape bridge between a SCSI target's block seam and hps_io.
tb_mister_block:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv $(RTL)/sun3_mister_block.sv
	./obj_$@/$@

# MiSTer's PS/2 keyboard and mouse as a Sun Type 3 keyboard and a Mouse
# Systems mouse, on the two serial lines.
tb_mister_kbd_mouse:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv $(RTL)/sun3_mister_kbd_mouse.sv
	./obj_$@/$@

# The keyboard's beeper as sound, on the audio clock.
tb_mister_bell:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv $(RTL)/sun3_mister_bell.sv
	./obj_$@/$@

# The bridge into the keyboard/mouse Z8530 as sun3_fpga.v builds it,
# programmed and serviced the way SunOS 4 does.
tb_kbm_scc:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv $(RTL)/sun3_mister_kbd_mouse.sv $(RTL)/vendor/z8530_scc/z8530_scc.sv
	./obj_$@/$@

# The OSD's CPU clock: the main PLL's cpu_clk counter rewritten through
# pll_cfg in a machine reset, against pll_stub.sv's PLL and pll_cfg.
tb_mister_cpuclk:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv pll_stub.sv $(RTL)/sun3_mister_cpuclk.sv $(RTL)/sun3/reset_sync.sv
	./obj_$@/$@

# MiSTer's RTC into the ICM7170, read back as SunOS reads it, the chip's
# oscillator a fixed tick under a CPU clock that changes.
tb_mister_tod:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv $(RTL)/sun3_mister_tod.sv $(RTL)/sun3_mister_tick.sv $(RTL)/sun3/icm7170.v
	./obj_$@/$@

# The network's mailbox: the PHY behind the LANCE, between Wish7990's own MII
# blocks and DDR3, with Main_MiSTer's daemon played by the bench.
W7990 := $(RTL)/vendor/wish7990
tb_mister_enet:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $(W7990)/crc32_eth.sv $(W7990)/mii_tx.sv $(W7990)/mii_rx.sv \
	    $(RTL)/sun3_mister_enet.sv $@.sv
	./obj_$@/$@

# The EEPROM kept in an image file: the saver and eeprom.v's two ports, with
# the .qsf's memory size.
tb_mister_eeprom:
	$(V) $(VFLAGS) -Wno-MULTIDRIVEN +define+SUN3_EEPROM_SAVE=1 +define+SUN3_MEM_MIB=24 --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv $(RTL)/sun3_mister_eeprom.sv $(RTL)/sun3/eeprom.v
	./obj_$@/$@

# The tape: the MT-02 against tapes built by tools/mktape itself, so the image
# format is tested from both ends.
tb_mt02:
	mkdir -p obj_$@
	python3 mk_mt02_tapes.py obj_$@ ../../tools/mktape
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $(RTL)/vendor/wish5380/wish5380_pkg.sv $(RTL)/vendor/wish5380/scsi_fabric.sv \
	    $(RTL)/sun3/sun3_mt02.sv $@.sv
	./obj_$@/$@ +dir=obj_$@

# The on-board SCSI's DMA (sun3_si.sv) against the byte-per-cycle engine it
# replaced (sun3_si_ref.sv): the same commands must leave the same memory,
# disk and registers, in less time.
WISH5380 := $(addprefix $(RTL)/vendor/wish5380/,wish5380_pkg.sv sci_regs.sv sci_bus.sv wish5380.sv \
            scsi_fabric.sv scsi_targ.sv)
tb_si:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $(WISH5380) $(RTL)/sun3/wish7990_dvma_to_020.v $(RTL)/sun3/sun3_si.sv sun3_si_ref.sv $@.sv
	./obj_$@/$@

# The cg4's P4 register and Bt458s, driven as the PROM and NetBSD drive them.
tb_cg4:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv $(RTL)/sun3/sun3_cg4.sv
	./obj_$@/$@

# The level-4 interrupt's source (sun3_vint.v), with the interrupt PAL and the
# P4 register, driven as SunOS's cgfour driver drives them.
tb_vint:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv $(RTL)/sun3/sun3_vint.v $(RTL)/sun3/sun3_irq_priority.v $(RTL)/sun3/sun3_cg4.sv
	./obj_$@/$@

# The cg4's picture: full frames in Sun-3.sv's raster, every pixel, against a
# memory that answers quickly and slowly.
tb_cg4_scanout:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv $(RTL)/sun3/sun3_cg4_scanout.sv $(RTL)/sun3/video_timing.sv
	./obj_$@/$@

# The RD68021 and RD68884 as sun3_top wires them, against the CPU+FPU corpus a
# real Mac II (68020 + 68881) passed (corpus/README.md).  Not in `all': it is
# a check of the vendored cores, not of the MiSTer glue.
CORPUS ?= corpus/cpu_fpu_full_corpus.json
RD21   := $(RTL)/vendor/rd68021
RD884  := $(RTL)/vendor/rd68884
tb_cpu_fpu:
	mkdir -p obj_$@
	python3 mk_fpu_corpus.py $(CORPUS) obj_$@/corpus.txt
	$(V) $(VFLAGS) -Wno-BLKANDNBLK -Wno-MULTIDRIVEN --top-module $@ --Mdir obj_$@ -o $@ \
	    $(RD21)/rd68021_pkg.sv $(RD21)/gen/rd68021_frame_pkg.sv $(RD21)/gen/rd68021_ucode_pkg.sv \
	    $(RD21)/gen/rd68021_cpdec_rom.sv $(RD21)/gen/rd68021_decode_rom.sv $(RD21)/gen/rd68021_eadec_rom.sv \
	    $(RD21)/gen/rd68021_eamode_rom.sv $(RD21)/gen/rd68021_ucode_rom.sv \
	    $(RD21)/rd68021_sync.sv $(RD21)/rd68021_dedge_ff.sv $(RD21)/rd68021_shifter.sv \
	    $(RD21)/rd68021_divider.sv $(RD21)/rd68021_bitfield.sv $(RD21)/rd68021_biu.sv \
	    $(RD21)/rd68021_icache.sv $(RD21)/rd68021_ifu.sv $(RD21)/rd68021_seq.sv $(RD21)/rd68021_top.sv \
	    $(RD884)/rd68884_pkg.sv $(RD884)/gen/rd68884_ucode_pkg.sv $(RD884)/gen/rd68884_crom.sv \
	    $(RD884)/gen/rd68884_ucode_rom.sv $(RD884)/rd68884_sync.sv $(RD884)/rd68884_biu.sv \
	    $(RD884)/rd68884_regfile.sv $(RD884)/rd68884_seq.sv $(RD884)/rd68884_top.sv \
	    $@.sv
	./obj_$@/$@ +list=obj_$@/corpus.txt $(SIMARGS)

clean:
	rm -rf obj_* run_*

.PHONY: all clean $(TESTS)
