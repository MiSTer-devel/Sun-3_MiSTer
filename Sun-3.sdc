derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
#
# The outputs are counter[n] in outclk order: rtl/pll/pll_0002.v clk_mem,
# cpu_clk, clk_pix, clk_mii (the reconfigurable form fixes each to its
# counter); rtl/pll_serial/pll_serial_0002.v clk_ser.
set pll_main   {*|pll|pll_inst|altera_pll_i|cyclonev_pll|counter}
set pll_serial {*|pll_serial|pll_inst|altera_pll_i|general}

# cpu_clk is timed at the fastest the OSD offers.  The bitstream's counter is
# /25 (20 MHz), and rtl/sun3_mister_cpuclk.sv rewrites it to /20 or /15 of
# the same 500 MHz, so the clock derive_pll_clocks made is made again here on
# the same pin with the smallest of those dividers.
set cpu_clk_fastest_div 15
set cpu_clk [get_clocks "${pll_main}\[1\].output_counter|divclk"]
if {[get_collection_size $cpu_clk] != 1} {
    post_message -type error "Sun-3.sdc: cpu_clk not found as ${pll_main}\[1\].output_counter|divclk"
} else {
    create_generated_clock -name [get_clock_info -name $cpu_clk] \
        -source [get_clock_info -master_clock_pin $cpu_clk] \
        -master_clock [get_clock_info -master_clock $cpu_clk] \
        -divide_by $cpu_clk_fastest_div -duty_cycle 50 \
        [get_clock_info -targets $cpu_clk]
}

# Every clock this core makes comes from CLK_50M, so TimeQuest would time
# paths between them as related.  None is: each crossing is designed as an
# asynchronous one and goes through synchronisers or a dual-clock RAM --
#
#   cpu_clk <-> clk_mem   sun3_cached_fifo_bridge's two async FIFOs; the disk
#                         bridge's toggles and staging RAMs; the boot PROM's
#                         write port (the machine is held in reset while it is
#                         written) and the ID PROM's (written before the PROM
#                         first reads it); the OSD's diag switch; the TOD
#                         chip's 1 MHz tick (sun3_mister_tick)
#   clk_mem <-> clk_pix   fb_scanout's toggles and line buffer
#   cpu_clk  -> clk_pix   EN.VIDEO, synchronised in fb_scanout
#   clk_pix  -> cpu_clk   the vertical blanking (V_INT), synchronised in sun3_fpga
#   clk_ser               the SCCs' baud rate generators, crossed inside z8530_scc
#   clk_mii  <-> cpu_clk  the LANCE's MII side, crossed inside Wish7990 (its
#                         async FIFOs and synchronisers)
#   clk_mii  <-> clk_mem  sun3_mister_enet's two frame buffers (dual-clock
#                         RAMs) and their request/acknowledge flags, through
#                         two flops each way
#
# so they are cut here.  (CLK_50M itself, on which sun3_mister_cpuclk runs,
# is cut from all of them by sys_top.sdc.)  After Sun-2_MiSTer's Sun-2.sdc.
set_clock_groups -asynchronous \
    -group [get_clocks "${pll_main}\[0\].output_counter|divclk"] \
    -group [get_clocks "${pll_main}\[1\].output_counter|divclk"] \
    -group [get_clocks "${pll_main}\[2\].output_counter|divclk"] \
    -group [get_clocks "${pll_main}\[3\].output_counter|divclk"] \
    -group [get_clocks "${pll_serial}\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"]
