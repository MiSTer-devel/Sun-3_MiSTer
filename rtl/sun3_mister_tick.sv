//
// sun3_mister_tick.sv
//
// A fixed-rate tick for a clock that changes: one clk_dst pulse for every DIV
// clocks of clk_src.  The source counts DIV of its own, fixed clocks and
// turns a toggle; the destination takes the toggle through two flops and
// makes a one-clock pulse of each turn.
//
// It is the ICM7170's oscillator (icm7170.v, SUN3_TOD_TICK_HZ): DIV 100 of
// clk_mem's 100 MHz is 1 MHz, into cpu_clk, which runs at 20 to 33.33 MHz
// from the OSD (docs/design-plan.md, Phase 6).  The chip divides it down to
// its hundredths, and SunOS's clock interrupt is the chip's 100 Hz, so the
// time and the kernel's tick stay right whatever the CPU's clock is.
//
// clk_dst must sample each state of the toggle at least twice, so it has to
// be more than twice as fast as the toggle turns: here a turn is 1 us, 20
// CPU clocks at the slowest.
//
`timescale 1ns / 1ps

module sun3_mister_tick #(
    parameter int DIV = 100                 // clk_src clocks a tick
) (
    input  wire clk_src,                    // fixed: clk_mem
    input  wire clk_dst,                    // the machine's: cpu_clk
    output wire tick                        // in clk_dst, one clock each
);

    reg [$clog2(DIV)-1:0] cnt = '0;
    reg                   tgl = 1'b0;

    always @(posedge clk_src) begin
        if (cnt == DIV - 1) begin
            cnt <= '0;
            tgl <= ~tgl;
        end else
            cnt <= cnt + 1'd1;
    end

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] s = 3'b000;
    always @(posedge clk_dst) s <= {s[1:0], tgl};
    assign tick = s[2] ^ s[1];

endmodule
