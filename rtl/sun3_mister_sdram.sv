//
// sun3_mister_sdram.sv
//
// The Sun-3's memory on the MiSTer SDRAM board: a Wishbone slave for
// sun3_cached_fifo_bridge and a line port for the bw2's fb_scanout, both in
// front of rtl/sdram.sv (Sorgelig's controller, BL8, CAS 2, at ~100 MHz).
// Everything here runs on the controller's clock; the bridge's async FIFOs are
// where the CPU's clock is crossed.  Adapted from Sun-2_MiSTer's
// rtl/sun2_mister_sdram.sv (816c187): the state machine, the handshakes and
// the refresh pacing are that module's; the lanes and the map are the Sun-3's.
//
// **Lanes.**  The Sun-3's bus is 32 bits, big-endian, and its bridge puts a
// bus word on Wishbone unchanged: wb_sel[3] is bits 31:24, the byte at the
// lowest address.  A line (16 bytes, sun3_cached_fifo_bridge's and
// fb_scanout's unit) has word k at [32k+31:32k].  So a Wishbone word's high
// half is the even SDRAM word and its low half the odd one:
//
//   Wishbone word w, bits 31:16  ->  SDRAM word 2w     (DQ15:8 the lower byte)
//   Wishbone word w, bits 15:0   ->  SDRAM word 2w + 1
//
// and SDRAM word j of an aligned BL8 burst is line bits [16*(j^1) +: 16].
// fb_scanout's bit order (pixel p at {p[6:5], ~p[4:0]}) then holds as it did
// on the Wukong's and the DECA's DDR3.
//
// **Map** (a 32 MiB module is enough):
//
//   main memory    Wishbone word w (w < 6 Mi: 24 MiB)       -> SDRAM words 2w, 2w+1
//   bw2 window     Wishbone word FB_WB_BASE + r (2 MiB)     -> FB_SDRAM_WORD + 2r, +1
//   fb_scanout     c_addr (16-bit words, beat-aligned)      -> FB_SDRAM_WORD + c_addr
//   cg4 window     Wishbone word {8'hFF, PA[23:2]}: the bridge's MATCH_CG
//                    colour   PA 0xFF800000 + o (1 MiB)    -> CG_COLOR_WORD + o/2
//                    overlay  PA 0xFF400000 + o (128 KiB)  -> CG_OVERLAY_WORD + o/2
//                    enable   PA 0xFF600000 + o (128 KiB)  -> CG_ENABLE_WORD + o/2
//   cg4 scan-out   cs_word (an SDRAM word, burst-aligned)   -> as given
//
// FB_WB_BASE is where the bridge puts the bw2 window, {11'h07F, A[20:2]}:
// byte 0x0FE00000.  The frame buffer sits 24 MiB up, in bank 3 of a 32 MiB
// chip, away from the CPU's rows.
//
// **Clients.**  The scan-outs have deadlines and the CPU does not.  The bw2's
// is small (a line of 1152 pixels is 9 bursts, against a 17.7 us scan line)
// and keeps absolute priority; only the screen being shown is fetched.  The
// cg4's is 90 bursts a line, most of the SDRAM's time, so it takes turns with
// the CPU and demands priority only when it says it is about to run dry
// (cs_urgent; sun3_cg4_scanout.sv), as Sun-2_MiSTer's colour scan-out does.
//
// **Handshakes.**  Both clients hold a request until it is answered and only
// then move on, and both see the answer a clock after it is given: the bridge
// drops CYC on the edge it samples wb_ack_o, fb_scanout advances c_addr on the
// edge it samples c_done.  So after every completion this waits one clock
// (S_GAP) before it looks at either request again.  Without that, the request
// just answered is still visible and is run a second time -- and the answer to
// the repeat completes whatever the client asks for next, with the wrong data.
//
// The controller takes a request as a held level and reports completion as the
// rising edge of `ready': on a read that edge brings the first burst word in
// `dout' and the other seven follow on consecutive clocks; on a write it means
// the WRITE command has issued.  rd is dropped as soon as the first word
// arrives, wr as soon as ready rises, so the controller cannot take either
// again when it comes back to idle.  It wants a refresh toggle every 7.8 us;
// this gives one every 764 clocks.
//
`timescale 1ns / 1ps
module sun3_mister_sdram #(
    parameter [29:0] FB_WB_BASE      = 30'h03F80000,  // the bridges' bw2 window: byte 0x0FE00000
    parameter [25:0] FB_SDRAM_WORD   = 26'h0C00000,   // 24 MiB, in 16-bit words
    parameter [25:0] CG_COLOR_WORD   = 26'h0C80000,   // 25 MiB
    parameter [25:0] CG_OVERLAY_WORD = 26'h0D00000,   // 26 MiB
    parameter [25:0] CG_ENABLE_WORD  = 26'h0D10000    // 26 MiB + 128 KiB
) (
    input  wire         clk,            // the controller's clock, ~100 MHz
    input  wire         init,           // hold the controller in its power-up sequence

    // Wishbone slave (from sun3_cached_fifo_bridge)
    input  wire         wb_cyc_i,
    input  wire         wb_stb_i,
    input  wire [29:0]  wb_adr_i,       // 32-bit word address
    input  wire [31:0]  wb_dat_i,
    input  wire [3:0]   wb_sel_i,
    input  wire         wb_we_i,
    output reg  [31:0]  wb_dat_o  = 32'h0,
    output reg          wb_ack_o  = 1'b0,
    output reg  [127:0] wb_line_o = 128'h0,

    // bw2 line port (from fb_scanout)
    input  wire [27:0]  fb_c_addr,      // 16-bit word address within the frame buffer
    input  wire         fb_c_req,       // a level, held for the whole line
    output reg          fb_c_done  = 1'b0,
    output reg  [127:0] fb_c_rdata = 128'h0,

    // cg4 line port (from sun3_cg4_scanout): bursts, with urgency
    input  wire [25:0]  cs_word,
    input  wire         cs_req,
    input  wire         cs_urgent,
    output reg          cs_done    = 1'b0,
    output reg  [127:0] cs_rdata   = 128'h0,

    // SDRAM pins
    inout  wire [15:0]  SDRAM_DQ,
    output wire [12:0]  SDRAM_A,
    output wire         SDRAM_DQML,
    output wire         SDRAM_DQMH,
    output wire [1:0]   SDRAM_BA,
    output wire         SDRAM_nCS,
    output wire         SDRAM_nWE,
    output wire         SDRAM_nRAS,
    output wire         SDRAM_nCAS,
    output wire         SDRAM_CKE,
    output wire         SDRAM_CLK
);

    // ---- address translation ------------------------------------------------
    // The cg4's window first: it is above the bw2's too.  PA[23:20] says the
    // plane (8 colour, 4 overlay, 6 enable), PA[19:2] the word in it.
    wire        wb_is_cg  = (wb_adr_i[29:22] == 8'hFF);
    wire [25:0] wb_cg_base = (wb_adr_i[21:18] == 4'h8) ? CG_COLOR_WORD :
                             (wb_adr_i[21:18] == 4'h4) ? CG_OVERLAY_WORD : CG_ENABLE_WORD;
    wire        wb_is_fb  = !wb_is_cg && (wb_adr_i >= FB_WB_BASE);
    wire [29:0] wb_fb_rel = wb_adr_i - FB_WB_BASE;
    // SDRAM word of the high (even) half of this Wishbone word.
    wire [25:0] wb_word   = wb_is_cg ? wb_cg_base + {wb_adr_i[17:0], 1'b0} :
                            wb_is_fb ? FB_SDRAM_WORD + {wb_fb_rel[23:0], 1'b0}
                                     : {wb_adr_i[24:0], 1'b0};

    // ---- refresh pacing --------------------------------------------------------
    reg       refresh = 1'b0;
    reg [9:0] refcnt  = 10'd0;
    always @(posedge clk) begin
        refcnt <= refcnt + 10'd1;
        if (refcnt == 10'd763) begin
            refcnt  <= 10'd0;
            refresh <= ~refresh;
        end
    end

    // ---- the controller --------------------------------------------------------
    reg  [25:0] c_word = 26'd0;         // SDRAM word address of the access
    reg  [15:0] c_din  = 16'h0;
    reg  [1:0]  c_bs   = 2'b00;         // [1] high byte (DQ15:8), [0] low byte
    reg         c_rd   = 1'b0;
    reg         c_wr   = 1'b0;
    wire [15:0] dout;
    wire        ready;

    sdram sdram (
        .init      (init),
        .clk       (clk),
        .SDRAM_EN  (1'b1),

        .SDRAM_DQ  (SDRAM_DQ),
        .SDRAM_A   (SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML),
        .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_BA  (SDRAM_BA),
        .SDRAM_nCS (SDRAM_nCS),
        .SDRAM_nWE (SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE (SDRAM_CKE),
        .SDRAM_CLK (SDRAM_CLK),

        .sel       (1'b1),
        .addr      (c_word),            // addr[26:1]: a word address
        .dout      (dout),
        .din       (c_din),
        .wr        (c_wr),
        .bs        (c_bs),
        .rd        (c_rd),
        .ready     (ready),
        .refresh   (refresh),

        .cpsel     (1'b0),
        .cpaddr    (26'd0),
        .cpdin     (16'd0),
        .cprd      (),
        .cpreq     (1'b0),
        .cpbusy    ()
    );

    reg  ready_d = 1'b0;
    always @(posedge clk) ready_d <= ready;
    wire ready_rise = ready & ~ready_d;

    // ---- one access at a time ---------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0,
                     S_RD   = 3'd1,     // rd held, waiting for the first word
                     S_RDB  = 3'd2,     // collecting words 1..7
                     S_WR   = 3'd3,     // wr held, waiting for the command
                     S_GAP  = 3'd4;     // the client has not yet seen the answer

    reg [2:0]   st      = S_IDLE;
    reg         for_fb  = 1'b0;         // whose read this is
    reg         for_cs  = 1'b0;
    // Turns between the cg4's scan-out and the CPU: whoever was served last
    // goes to the back.  0 the scan-out, 1 the CPU.
    reg         last_cpu = 1'b0;
    wire        wb_want  = wb_cyc_i & wb_stb_i;
    wire        pick_cs  = cs_req & (cs_urgent | !wb_want | last_cpu);
    reg [2:0]   widx    = 3'd0;
    reg [127:0] line    = 128'h0;
    reg [1:0]   lane    = 2'd0;
    reg         lo_left = 1'b0;         // a write's odd (low) half is still to go
    reg [15:0]  lo_din  = 16'h0;
    reg [1:0]   lo_bs   = 2'b00;

    always @(posedge clk) begin
        wb_ack_o  <= 1'b0;
        fb_c_done <= 1'b0;
        cs_done   <= 1'b0;

        if (init) begin
            st   <= S_IDLE;
            c_rd <= 1'b0;
            c_wr <= 1'b0;
        end else case (st)
            S_IDLE: begin
                for_fb <= 1'b0;
                for_cs <= 1'b0;
                if (fb_c_req) begin
                    // The bw2's scan-out first: it has a deadline and asks for
                    // a line's worth every scan line, so the CPU barely notices.
                    for_fb <= 1'b1;
                    c_word <= FB_SDRAM_WORD + {fb_c_addr[24:3], 3'b000};
                    c_rd   <= 1'b1;
                    st     <= S_RD;
                end else if (pick_cs) begin
                    for_cs   <= 1'b1;
                    last_cpu <= 1'b0;
                    c_word   <= {cs_word[25:3], 3'b000};
                    c_rd     <= 1'b1;
                    st       <= S_RD;
                end else if (wb_want) begin
                    last_cpu <= 1'b1;
                    lane <= wb_adr_i[1:0];
                    if (!wb_we_i) begin
                        c_word <= {wb_word[25:3], 3'b000};     // the whole line
                        c_rd   <= 1'b1;
                        st     <= S_RD;
                    end else if (wb_sel_i[3:2] != 2'b00) begin
                        c_word  <= wb_word;                    // the high half first
                        c_din   <= wb_dat_i[31:16];
                        c_bs    <= wb_sel_i[3:2];
                        c_wr    <= 1'b1;
                        lo_left <= (wb_sel_i[1:0] != 2'b00);
                        lo_din  <= wb_dat_i[15:0];
                        lo_bs   <= wb_sel_i[1:0];
                        st      <= S_WR;
                    end else if (wb_sel_i[1:0] != 2'b00) begin
                        c_word  <= wb_word + 26'd1;
                        c_din   <= wb_dat_i[15:0];
                        c_bs    <= wb_sel_i[1:0];
                        c_wr    <= 1'b1;
                        lo_left <= 1'b0;
                        st      <= S_WR;
                    end else begin
                        wb_ack_o <= 1'b1;                      // nothing to write
                        st       <= S_GAP;
                    end
                end
            end

            S_RD:
                if (ready_rise) begin
                    c_rd           <= 1'b0;
                    line[16 +: 16] <= dout;                    // burst word 0: 0^1 = 1
                    widx           <= 3'd1;
                    st             <= S_RDB;
                end

            S_RDB: begin
                line[16 * (widx ^ 3'd1) +: 16] <= dout;
                if (widx == 3'd7) begin
                    // Word 7 is bits [111:96] (7^1 = 6); it arrives with `dout'
                    // now, so the finished line is assembled from both.
                    if (for_fb) begin
                        fb_c_rdata <= {line[127:112], dout, line[95:0]};
                        fb_c_done  <= 1'b1;
                    end else if (for_cs) begin
                        cs_rdata <= {line[127:112], dout, line[95:0]};
                        cs_done  <= 1'b1;
                    end else begin
                        wb_line_o <= {line[127:112], dout, line[95:0]};
                        wb_dat_o  <= (lane == 2'd3) ? {line[127:112], dout}
                                                    : line[lane*32 +: 32];
                        wb_ack_o  <= 1'b1;
                    end
                    st <= S_GAP;
                end else
                    widx <= widx + 3'd1;
            end

            S_WR:
                if (ready_rise) begin
                    if (lo_left) begin
                        // Drop wr for a clock between the two so the controller
                        // sees a new request rather than a held one.
                        c_wr    <= 1'b0;
                        lo_left <= 1'b0;
                        c_word  <= c_word + 26'd1;
                        c_din   <= lo_din;
                        c_bs    <= lo_bs;
                        st      <= S_WR;
                    end else begin
                        c_wr     <= 1'b0;
                        wb_ack_o <= 1'b1;
                        st       <= S_GAP;
                    end
                end else if (!c_wr)
                    c_wr <= 1'b1;               // the second half's request

            S_GAP:
                st <= S_IDLE;

            default:
                st <= S_IDLE;
        endcase
    end

endmodule
