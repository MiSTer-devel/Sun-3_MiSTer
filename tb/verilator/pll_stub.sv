// Simulation stand-ins for rtl/pll.v, rtl/pll_serial.v and sys/pll_cfg
// (altera_pll and its reconfiguration core are not simulable here): the same
// ports and the same frequencies, from the same reset-free start.  The clocks
// are not phase-related the way the PLLs' are -- the design treats every
// crossing as asynchronous, so the simulation should too.  (After
// Sun-2_MiSTer's.)
//
// The main PLL's four outputs are its C counters 0..3 dividing 500 MHz, as
// in rtl/pll/pll_0002.v: each is high for its high count and low for its low
// count of 2 ns, the odd-division bit moving 1 ns from the high to the low
// half (Quartus's 50% duty for an odd divider).  pll_cfg is the
// reconfiguration core as sun3_mister_cpuclk uses it: Avalon-MM in its
// waitrequest mode, busy at start-up and while the PLL is unlocked, the C
// counter register (5) taken in and written into the PLL some clocks after a
// write to START (2), waitrequest high until then (in the waitrequest mode).  Here reconfig_to_pll
// carries the stub's own fields, not Altera's: [3:0] the counter, [11:4] its
// high count, [19:12] its low count, [20] odd, [21] bypass, [22] a toggle for
// each write; reconfig_from_pll[16] is locked, as Altera's is.  The model also
// records every accepted write and counts Avalon protocol faults for the
// benches.
`timescale 1ps/1ps

module pll (
    input  wire        refclk,
    input  wire        rst,
    output reg         outclk_0 = 1'b0,    // 100.000 MHz  clk_mem     C0  /5
    output reg         outclk_1 = 1'b0,    //  20.000 MHz  cpu_clk     C1  /25, 50% duty
    output reg         outclk_2 = 1'b0,    //  83.333 MHz  clk_pix     C2  /6
    output reg         outclk_3 = 1'b0,    //   2.500 MHz  clk_mii     C3  /200
    output reg         locked   = 1'b0,
    input  wire [63:0] reconfig_to_pll,
    output wire [63:0] reconfig_from_pll
);
    // high count, low count, odd: the bitstream's
    reg [7:0] hi [4] = '{8'd3, 8'd13, 8'd3, 8'd100};
    reg [7:0] lo [4] = '{8'd2, 8'd12, 8'd3, 8'd100};
    reg       odd[4] = '{1'b1, 1'b1, 1'b0, 1'b0};

    function automatic longint high_ps(input int n);
        return 64'(hi[n]) * 2000 - (odd[n] ? 1000 : 0);
    endfunction
    function automatic longint low_ps(input int n);
        return 64'(lo[n]) * 2000 + (odd[n] ? 1000 : 0);
    endfunction

    always begin #(low_ps(0)) outclk_0 = 1'b1; #(high_ps(0)) outclk_0 = 1'b0; end
    always begin #(low_ps(1)) outclk_1 = 1'b1; #(high_ps(1)) outclk_1 = 1'b0; end
    always begin #(low_ps(2)) outclk_2 = 1'b1; #(high_ps(2)) outclk_2 = 1'b0; end
    always begin #(low_ps(3)) outclk_3 = 1'b1; #(high_ps(3)) outclk_3 = 1'b0; end
    initial #1_000_000 locked = 1'b1;   // 1 us

    reg seen = 1'b0;
    always @(reconfig_to_pll[22]) begin
        if (reconfig_to_pll[22] != seen && reconfig_to_pll[3:0] < 4) begin
            hi[reconfig_to_pll[3:0]]  = reconfig_to_pll[21] ? 8'd1 : reconfig_to_pll[11:4];
            lo[reconfig_to_pll[3:0]]  = reconfig_to_pll[21] ? 8'd0 : reconfig_to_pll[19:12];
            odd[reconfig_to_pll[3:0]] = reconfig_to_pll[21] ? 1'b0 : reconfig_to_pll[20];
        end
        seen = reconfig_to_pll[22];
    end

    assign reconfig_from_pll = {47'd0, locked, 16'd0};
endmodule

module pll_serial (
    input  wire refclk,
    input  wire rst,
    output reg  outclk_0 = 1'b0,    // 4.9152 MHz
    output reg  locked   = 1'b0
);
    always #101725 outclk_0 = ~outclk_0;
    initial #1_000_000 locked = 1'b1;
endmodule

module pll_cfg (
    input  wire        mgmt_clk,
    input  wire        mgmt_reset,
    output wire        mgmt_waitrequest,
    input  wire        mgmt_read,
    output wire [31:0] mgmt_readdata,
    input  wire        mgmt_write,
    input  wire [5:0]  mgmt_address,
    input  wire [31:0] mgmt_writedata,
    output reg  [63:0] reconfig_to_pll = 64'd0,
    input  wire [63:0] reconfig_from_pll
);
    localparam int INIT = 410;          // the real core's self-reset and DPRIO init
    localparam int BUSY = 40;           // clocks from START to the counter in the PLL

    wire locked = reconfig_from_pll[16];
    int  init_t = 0;
    int  busy_t = 0;
    reg  mode   = 1'b0;                 // 0 waitrequest mode
    reg  [31:0] c_pend = 32'd0;
    reg         c_have = 1'b0;

    // (in polling mode the change is made just the same, without the wait)
    assign mgmt_waitrequest = (init_t < INIT) || !locked || (busy_t != 0 && mode == 1'b0);
    assign mgmt_readdata    = 32'd0;

    // for the benches: every accepted write, and the protocol's faults
    int          nwr = 0;
    reg [5:0]    wr_addr [256];
    reg [31:0]   wr_data [256];
    int          faults = 0;
    reg          last_wr = 1'b0, last_wait = 1'b0;
    reg [5:0]    last_addr;
    reg [31:0]   last_data;

    always @(posedge mgmt_clk) begin
        if (init_t < INIT) init_t <= init_t + 1;

        // a write held off by waitrequest must stay as it was
        if (last_wr && last_wait &&
            (!mgmt_write || mgmt_address != last_addr || mgmt_writedata != last_data))
            faults <= faults + 1;
        if (mgmt_read) faults <= faults + 1;            // nothing here reads
        last_wr   <= mgmt_write;
        last_wait <= mgmt_waitrequest;
        last_addr <= mgmt_address;
        last_data <= mgmt_writedata;

        if (busy_t != 0) begin
            busy_t <= busy_t - 1;
            if (busy_t == 1 && c_have) begin
                reconfig_to_pll[3:0]   <= 4'(c_pend[22:18]);
                reconfig_to_pll[11:4]  <= c_pend[15:8];
                reconfig_to_pll[19:12] <= c_pend[7:0];
                reconfig_to_pll[20]    <= c_pend[17];
                reconfig_to_pll[21]    <= c_pend[16];
                reconfig_to_pll[22]    <= ~reconfig_to_pll[22];
                c_have                 <= 1'b0;
            end
        end

        if (mgmt_write && !mgmt_waitrequest) begin
            if (nwr < 256) begin
                wr_addr[nwr] <= mgmt_address;
                wr_data[nwr] <= mgmt_writedata;
            end
            nwr <= nwr + 1;
            case (mgmt_address)
                6'd0: mode <= mgmt_writedata[0];
                6'd5: begin c_pend <= mgmt_writedata; c_have <= 1'b1; end
                6'd2: busy_t <= BUSY;
                default: ;
            endcase
        end
    end
endmodule
