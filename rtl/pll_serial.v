// The serial clock: 4.9152 MHz for both Z8530s' baud rate generators, on a
// PLL of its own because it divides nothing the other PLLs make.  A
// fractional VCO gets within a part per million of it; the SCCs need it to
// within a few percent.  (Sun-2_MiSTer's rtl/pll_serial.v, unchanged.)
module pll_serial (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire locked
);
    pll_serial_0002 pll_inst (
        .refclk   (refclk),
        .rst      (rst),
        .outclk_0 (outclk_0),
        .locked   (locked)
    );
endmodule
