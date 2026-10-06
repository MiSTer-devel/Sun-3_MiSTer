// sun3_vint.v -- the 3/60's level-4 "video" interrupt source, V.INT-.
//
// On the 3/60 (501-1205, sheet 8A) V.INT- is an output of the DSACK PAL, U805
// (fuse map 1590-01), from three inputs: V.INTX-, the on-board video's
// interrupt (VIDEO4 U1004, sheet 10: one V.CLK low as the line counter wraps,
// at the start of vertical blanking); V.INTY-, the P4 connector's interrupt
// pin (P1/P2 pin 54, pulled up); and INIT-, the board reset.  Active high
// here, its equations are
//
//     seen  = !INIT & (seen | V.INTY)                (pin 13, a sticky flag)
//     V.INT = (V.INTY & seen) | (!seen & V.INTX)
//
// so V.INT follows the on-board pulse until a P4 board first interrupts, and
// then the P4 board's interrupt alone until the next reset.  The interrupt
// PAL (sun3_irq_priority.v) latches V.INT while EN_IRQ4 is set, so:
//
//   * without a P4 board, level 4 can only latch at the start of a blank:
//     turning EN_IRQ4 on during one latches nothing until the next;
//   * with one, once it has interrupted, only its own interrupt (its enable
//     and pending bits, sun3_cg4.sv) reaches level 4.  SunOS's cgfour driver
//     relies on that: it turns level 4 on anywhere in the frame and loads the
//     colour map only when the P4 board's pending bit is set (docs/cg4.md).
//
// The pin 13 feedback is combinational in the PAL, so the P4 interrupt that
// sets the flag reaches V.INT at once; here the flag is a register and the
// interrupt is passed straight through the same way.  The on-board pulse is
// one CLK here: the CPU's clock is what sun3_irq_priority samples.

module sun3_vint (
    input  wire CLK,
    input  wire RESET,      // INIT-
    input  wire VBLANK,     // the on-board video's vertical blank, in CLK's domain
    input  wire P4_INT,     // V.INTY-, the P4 board's interrupt
    output wire V_INT       // V.INT-, to the interrupt PAL's level-4 term
);
    reg vblank_d = 1'b0;
    reg seen     = 1'b0;    // a P4 board has interrupted since the reset

    always @(posedge CLK) begin
        vblank_d <= VBLANK;
        if (RESET)
            seen <= 1'b0;
        else if (P4_INT)
            seen <= 1'b1;
    end

    wire v_intx = VBLANK & ~vblank_d;           // the start of vertical blanking

    assign V_INT = P4_INT | (~seen & v_intx);

endmodule
