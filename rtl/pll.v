// The core's main PLL, in the layout sys/pll_q17.qip expects (rtl/pll.qip).
// Every output divides one 500 MHz (50 MHz x 10, no fractional part), so
// every frequency is exact:
//
//   outclk_0  100.000 MHz  /5    SDRAM, the memory side of the Wishbone bridge, hps_io
//   outclk_1   20.000 MHz  /25   cpu_clk: the RD68021, the RD68884, sun3_fpga
//   outclk_2   83.333 MHz  /6    pixel clock: 1152x900 in a 1472x937 raster, 60.4 Hz
//   outclk_3    2.500 MHz  /200  the LANCE's MII clocks: 10 Mb/s, its own speed
//
// cpu_clk's counter, C1, is rewritten through reconfig_to_pll by
// rtl/sun3_mister_cpuclk.sv and sys/pll_cfg (the OSD's CPU clock: /20 is
// 25 MHz, /15 33.33 MHz); the others never change.  rtl/pll/pll_0002.v is the
// IP generator's reconfigurable form, which fixes each output to its counter.
//
// Sun-2_MiSTer's rtl/pll.v, output for output, except that cpu_clk is 50% high
// (the RD68021 uses both edges evenly; the Sun-2's CPU wanted 52%).  The CPU's
// clock once had a PLL of its own, but the DE10-Nano's 50 MHz pins reach only
// three fractional PLLs once HDMI has its own, and the 4.9152 MHz serial clock
// divides nothing here: it keeps the third, rtl/pll_serial.v.
module pll (
    input  wire        refclk,
    input  wire        rst,
    output wire        outclk_0,
    output wire        outclk_1,
    output wire        outclk_2,
    output wire        outclk_3,
    output wire        locked,
    input  wire [63:0] reconfig_to_pll,
    output wire [63:0] reconfig_from_pll
);
    pll_0002 pll_inst (
        .refclk            (refclk),
        .rst               (rst),
        .outclk_0          (outclk_0),
        .outclk_1          (outclk_1),
        .outclk_2          (outclk_2),
        .outclk_3          (outclk_3),
        .locked            (locked),
        .reconfig_to_pll   (reconfig_to_pll),
        .reconfig_from_pll (reconfig_from_pll)
    );
endmodule
