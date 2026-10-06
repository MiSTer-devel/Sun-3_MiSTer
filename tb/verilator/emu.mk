# tb_emu: the whole core, built from the same sources and defines as Quartus.
#
# The file list is files.qip's and the defines are Sun-3.qsf's VERILOG_MACROs,
# read here rather than copied, so the simulation cannot drift from the build.
# The one framework module the core instantiates, sys/video_freak.sv (with the
# divider and multiplier it uses, sys/math.sv), is added by name.  Only the
# framework is replaced: the PLLs (pll_stub.sv), hps_io (hps_io_model.sv) and
# the SDRAM chip (sdram_model.sv).  (After Sun-2_MiSTer's.)
#
#   make -C tb/verilator tb_emu [MEM_MIB=24] [TIMEOUT_MS=3000] [ROM=...] [DISK=...] [DISK1=...] [EEPROM=...] [KEYS=...] [SIMARGS=...]
#
# MEM_MIB overrides the .qsf's SUN3_MEM_MIB.  The PROM is the simulation's
# `fast' image (tools/: noparity plus Sun-3_FPGA's fastboot list -- the
# memory fill and two waits shortened) sent through the real boot0.rom
# loader; ROM= takes any other, e.g. ../../build/rom/sun3_60_v1.9_noparity.bin
# for the bitstream's own.

TOP_DIR    := ../..
QIP_FILES  := $(shell sed -n -E 's/^set_global_assignment -name (SYSTEM)?VERILOG_FILE ([^ ]+).*$$/\2/p' $(TOP_DIR)/files.qip | tr -d '\r')
QSF_DEFS   := $(shell sed -n -E 's/^set_global_assignment -name VERILOG_MACRO "([^"]+)".*$$/+define+\1/p' $(TOP_DIR)/Sun-3.qsf | tr -d '\r')
MEM_MIB    ?= 24
TIMEOUT_MS ?= 3000
ROM        ?= $(TOP_DIR)/build/rom/sun3_60_v1.9_fast.bin
EMU_OBJ    := obj_tb_emu
EMU_RUN    ?= run_tb_emu
EMU_SIM_ARGS = +rom=$(abspath $(ROM)) +timeout_ms=$(TIMEOUT_MS) $(if $(DISK),+disk=$(abspath $(DISK))) $(if $(DISK1),+disk1=$(abspath $(DISK1))) $(if $(EEPROM),+eeprom=$(abspath $(EEPROM))) $(if $(KEYS),'+keys=$(KEYS)') $(SIMARGS)

# The defines, with SUN3_MEM_MIB taken from MEM_MIB, and SUN3_SIM for the
# RTL's simulation-only parts (power-up garbage, the cache's counters).
EMU_DEFS   := $(filter-out +define+SUN3_MEM_MIB=%,$(QSF_DEFS)) +define+SUN3_MEM_MIB=$(MEM_MIB) +define+SUN3_SIM=1

$(TOP_DIR)/build/rom/sun3_60_v1.9_fast.bin:
	$(MAKE) -C $(TOP_DIR)/tools all-roms

# -O3, fast X assignment and -O2 C++ (Verilator's own default is -Os) run the
# whole core about 30% faster.  --threads crashes Verilator 5.020 with --timing.
EMU_OPT    ?= -O3 --x-assign fast -CFLAGS -O2

tb_emu_build:
	mkdir -p $(EMU_OBJ)
	printf '`define BUILD_DATE "sim"\n' > $(EMU_OBJ)/build_id.v
	$(V) $(VFLAGS) $(EMU_OPT) -Wno-MULTIDRIVEN -Wno-SYNCASYNCNET -Wno-LATCH -Wno-COMBDLY -Wno-UNOPTFLAT \
	    -Wno-CASEINCOMPLETE -Wno-CASEOVERLAP -Wno-TIMESCALEMOD -Wno-IMPLICIT -Wno-REALCVT \
	    -Wno-MULTITOP -Wno-INITIALDLY -Wno-BLKANDNBLK \
	    $(EMU_DEFS) \
	    -I$(EMU_OBJ) -I$(TOP_DIR) -I$(TOP_DIR)/rtl/sun3 \
	    --top-module tb_emu --Mdir $(EMU_OBJ) -o tb_emu -j 0 \
	    tb_emu.sv pll_stub.sv hps_io_model.sv sdram_model.sv altddio_out_stub.v \
	    $(TOP_DIR)/sys/math.sv $(TOP_DIR)/sys/video_freak.sv $(addprefix $(TOP_DIR)/,$(QIP_FILES))

tb_emu: $(ROM) tb_emu_build
	mkdir -p $(EMU_RUN)
	cd $(EMU_RUN) && ../$(EMU_OBJ)/tb_emu $(EMU_SIM_ARGS)

.PHONY: tb_emu tb_emu_build
