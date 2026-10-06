//
// sun3_mister_cpuclk.sv
//
// The CPU's clock from the OSD: 20, 25 or 33.33 MHz (docs/design-plan.md,
// Phase 6), by rewriting the one counter of the main PLL that makes cpu_clk
// (rtl/pll.v: C1 divides 500 MHz by 25, 20 or 15) through sys/pll_cfg, the
// Altera PLL reconfiguration core, as sys_top does the HDMI PLL's.  The other
// three outputs -- the memory's, the pixels', the network's -- are other
// counters and keep running untouched, and the PLL stays locked: its M and N
// do not change.
//
// A change is made only while the machine is held in reset, and it keeps the
// machine in reset (`hold') until the new clock has settled, so no machine
// state lives through the instant the counter changes, when its output may
// have one short or long cycle.  An OSD change while the machine runs takes
// effect at the next reset -- the OSD's Reset, or the next time the core
// starts, which is how a saved setting comes back: the machine is in reset
// until boot0.rom has arrived, and Main sends the status before it.  Until
// then the counter is the bitstream's, 20 MHz, so a core at its default
// setting never reconfigures at all.
//
// Everything here runs on CLK_50M, a clock pin's, not the PLL this changes;
// sel, req and locked come from other clocks and are synchronised.  The
// framework's SDC already cuts CLK_50M from the core's PLL clocks.
//
// The bus to pll_cfg is Avalon-MM, in its waitrequest mode (the mode
// register's 0, the default): a write is held until waitrequest is low, and
// after START waitrequest stays high until the counter has been written into
// the PLL.  The C counter register (5) is {[22:18] counter, [17] odd-division
// duty correction, [16] bypass, [15:8] high count, [7:0] low count}
// (sys/pll_cfg/altera_pll_reconfig_core.v).
//
`timescale 1ns / 1ps

module sun3_mister_cpuclk #(
    parameter int SETTLE = 65536            // clk cycles after a change: 1.3 ms
) (
    input  wire        clk,                 // CLK_50M
    input  wire [1:0]  sel,                 // the OSD: 0 20 MHz, 1 25 MHz, 2 33.33 MHz (3 as 0)
    input  wire        req,                 // the machine's reset, before hold is added (any clock)
    input  wire        locked,              // the main PLL's
    output reg         hold   = 1'b0,       // keep the machine in reset: a change is under way
    output reg  [1:0]  cur    = 2'd0,       // the setting the PLL has (0 until a change)

    input  wire        cfg_waitrequest,     // to sys/pll_cfg's Avalon-MM slave
    output reg         cfg_write     = 1'b0,
    output reg  [5:0]  cfg_address   = 6'd0,
    output reg  [31:0] cfg_writedata = 32'd0
);

    localparam [5:0] REG_MODE  = 6'd0;
    localparam [5:0] REG_START = 6'd2;
    localparam [5:0] REG_C     = 6'd5;

    // C1: high and low counts, the odd-division bit when they differ
    function automatic [31:0] c1(input [1:0] s);
        case (s)
            2'd1:    c1 = {9'd0, 5'd1, 1'b0, 1'b0, 8'd10, 8'd10};  // /20  25.00 MHz
            2'd2:    c1 = {9'd0, 5'd1, 1'b1, 1'b0, 8'd8,  8'd7};   // /15  33.33 MHz
            default: c1 = {9'd0, 5'd1, 1'b1, 1'b0, 8'd13, 8'd12};  // /25  20.00 MHz
        endcase
    endfunction

    // what each setting is: 3 is 20 MHz, so it is 0
    function automatic [1:0] canon(input [1:0] s);
        canon = (s == 2'd3) ? 2'd0 : s;
    endfunction

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] sel_s1 = 2'd0;
    reg [1:0] sel_s2 = 2'd0, sel_s3 = 2'd0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg       req_s1 = 1'b0, lck_s1 = 1'b0;
    reg       req_s2 = 1'b0, lck_s2 = 1'b0;

    always @(posedge clk) begin
        sel_s1 <= sel;    sel_s2 <= sel_s1;    sel_s3 <= sel_s2;
        req_s1 <= req;    req_s2 <= req_s1;
        lck_s1 <= locked; lck_s2 <= lck_s1;
    end

    // the two bits of sel cross separately: take them when two samples agree
    wire [1:0] want = canon(sel_s2);
    wire       want_ok = (sel_s2 == sel_s3);

    localparam [2:0] IDLE = 3'd0, QUIET = 3'd1, MODE = 3'd2, CNT = 3'd3,
                     START = 3'd4, BUSY = 3'd5, SETTLED = 3'd6;
    reg [2:0]  state = IDLE;
    reg [1:0]  next  = 2'd0;
    reg [16:0] t     = 17'd0;

    wire accepted = cfg_write && !cfg_waitrequest;

    always @(posedge clk) begin
        if (accepted) cfg_write <= 1'b0;

        case (state)
        IDLE:
            if (req_s2 && lck_s2 && want_ok && want != cur) begin
                hold  <= 1'b1;
                next  <= want;
                t     <= 17'd0;
                state <= QUIET;
            end

        // the machine's own reset has been asserted for a while already;
        // give hold as long again to reach cpu_clk's reset synchroniser
        QUIET:
            if (t == 17'd255) begin
                cfg_write     <= 1'b1;
                cfg_address   <= REG_MODE;
                cfg_writedata <= 32'd0;              // waitrequest mode
                state         <= MODE;
            end else
                t <= t + 1'd1;

        MODE:
            if (accepted) begin
                cfg_write     <= 1'b1;
                cfg_address   <= REG_C;
                cfg_writedata <= c1(next);
                state         <= CNT;
            end

        CNT:
            if (accepted) begin
                cfg_write     <= 1'b1;
                cfg_address   <= REG_START;
                cfg_writedata <= 32'd0;
                state         <= START;
            end

        START:
            if (accepted) begin
                t     <= 17'd0;
                state <= BUSY;
            end

        // waitrequest is high from the cycle after START until the counter
        // is in the PLL; look only after it has had time to rise
        BUSY:
            if (t < 17'd16)
                t <= t + 1'd1;
            else if (!cfg_waitrequest && lck_s2) begin
                cur   <= next;
                t     <= 17'd0;
                state <= SETTLED;
            end

        SETTLED:
            if (t == 17'(SETTLE - 1)) begin
                hold  <= 1'b0;
                state <= IDLE;
            end else
                t <= t + 1'd1;

        default: state <= IDLE;
        endcase
    end

endmodule
