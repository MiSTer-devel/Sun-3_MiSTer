`timescale 1ns / 1ps

`include "sun3_attr.vh"
//
// sun3_cg6_tec.sv -- the GX's TEC (transform engine): the part OpenWindows
// 2.0's xnews uses, on the CPU's clock beside the register file
// (sun3_cg6.sv), which hands it every TEC write and the data registers'
// reads (bank 0's; bank 1 is the register file's store).
//
// docs/cg6.md, "The TEC", is the specification, from xnews's code;
// tools/cg6model/cg6model.c (tec_*) is that specification in C, checked
// against xnews's own routines (tools/cg6model/xnews.c), and
// tb/verilator/tb_cg6.sv replays its traces into this.
//
//   0x000  MV: 14 autoload, 13 h (w from data 3), 12 z (z from data 2),
//          10 rows (0 three: x y w; 1 four: x y z w), 9:8 columns - 1,
//          5:0 the matrix's first data register; 15 divide is not built
//   0x008  VDC: 15:13 the type the data registers are read and written in:
//          0 integer, 1 16.16 fixed, 2 IEEE single, 5 the second bank (not
//          here), the rest the register as it is
//   0x010  COMMAND1: 31:30 m - 1, 29:28 n - 1, 21:16 A, 13:8 B, 5:0 C:
//          C (1 x n) = A (1 x m) . B (m x n), B column by column
//   0x100  the 64 data registers: IEEE single inside, an M10K
//   0x800  the vertex registers: integer 0x800, fixed 0xA00, float 0xC00;
//          point, line, triangle, quadrilateral, rectangle 0x40 apart; abs
//          x y z w at +0..+0xC, rel at +0x10..  A coordinate goes to data
//          register 0..3; x then transforms the point: for each column j
//          of the MV matrix, data[4 + j] = (x y [z] w) . column j, w 1 for
//          an absolute vertex (data 3 with h), 0 for a relative one, which
//          adds data[4 + j] as it was.  With autoload data 4 and 5, rounded
//          down, go to the FBC as a vertex of the same kind (av, a clock).
//
// The arithmetic is cg6model.c's: IEEE single, round to nearest even, a
// denormal is zero, an exponent of 255 infinity, no NaNs; to integer and
// to fixed toward minus infinity, saturated.  One multiply (a DSP), one
// add, one normalise-and-round between them, a step at a time: a 2D vertex
// takes about 65 clocks.  `busy' holds every TEC and FBC cycle until it is
// done; a write is taken at once.
//
// Not built (nor modelled): MV's divide, VDC's multiply (bit 12) and its
// matrix, the clip planes and clipcheck's results and exceptions, COMMAND2
// to 4 and the command's identity bits.
//
module sun3_cg6_tec (
    input  wire         clk,
    input  wire         rst,

    input  wire         go,             // a cycle, the clock it is taken
    input  wire         we,
    input  wire [11:2]  adr,
    input  wire [31:0]  wdata,
    output reg          busy = 1'b0,
    output reg  [31:0]  q = 32'h0,      // a data register's read, once !busy

    output reg          av = 1'b0,      // autoload: a vertex for the FBC
    output reg  [2:0]   agrp = 3'd0,
    output reg  [31:0]  ax = 32'h0,     // integers, without the raster offset
    output reg  [31:0]  ay = 32'h0
);

    localparam [31:0] F_ONE = 32'h3F800000;

    // ---- float to integer or 16.16, toward minus infinity, saturated --------------------
    function automatic [31:0] f2i(input [31:0] v, input fixed);
        reg [8:0]  e;
        reg [30:0] m, ip;
        reg [4:0]  sh;
        reg        frac;
        begin
            e    = {1'b0, v[30:23]} + (fixed ? 9'd16 : 9'd0);
            m    = {1'b1, v[22:0], 7'b0};                   // 1.f, the unit at bit 30
            sh   = 5'(9'd157 - e);                          // for e 127..157
            ip   = m >> sh;
            frac = |(m & ~(31'h7FFFFFFF << sh));
            if (v[30:23] == 8'd0)
                f2i = 32'h0;
            else if (v[30:23] == 8'hFF || e >= 9'd158)
                f2i = v[31] ? 32'h80000000 : 32'h7FFFFFFF;
            else if (e < 9'd127)
                f2i = v[31] ? 32'hFFFFFFFF : 32'h0;
            else if (v[31])
                f2i = ~{1'b0, ip} + {31'h0, ~frac};         // -(ip + frac)
            else
                f2i = {1'b0, ip};
        end
    endfunction

    function automatic [5:0] lzc36(input [35:0] v);
        begin
            lzc36 = 6'd36;
            for (int i = 0; i < 36; i++)
                if (v[i]) lzc36 = 6'(35 - i);
        end
    endfunction

    // ---- the registers ------------------------------------------------------------------
    reg  [15:0] mv = 16'h0;
    reg  [2:0]  vtype = 3'd0;

    // ---- the sequencer's state ----------------------------------------------------------
    typedef enum logic [4:0] {
        S_IDLE, S_RD, S_PKA, S_PKB, S_PUT, S_VY, S_VZ, S_VW, S_AL,
        S_TERM, S_MUL2, S_MUL3, S_ADD1, S_ADD2, S_NEXT, S_REL, S_WRITE, S_WAITW,
        S_AUTO0, S_AUTO1, S_AUTO2, S_AUTO3
    } state_t;
    state_t st = S_IDLE;

    reg  [11:2] c_adr = 10'h0;          // the cycle that began it
    wire        c_data  = (c_adr[11:8] == 4'h1);
    wire [1:0]  c_coord = c_adr[3:2];
    wire        c_rel   = c_adr[4];
    reg         op_cmd = 1'b0;          // a command, else a vertex
    reg  [2:0]  nk = 3'd0, nj = 3'd0;   // terms a column (rows, or m), columns
    reg  [2:0]  k = 3'd0, j = 3'd0;
    reg  [5:0]  aa = 6'd0, bb = 6'd0;   // a command's A and B
    reg  [5:0]  ba = 6'd0;              // the matrix element now
    reg  [5:0]  dst = 6'd0;             // the column's result
    reg  [31:0] vin [0:3];
    reg  [31:0] acc = 32'h0;
    reg  [1:0]  pk_to = 2'd0;           // the rounded value is: 0 converted, 1 a product, 2 a sum, 3 a relative sum
    initial for (int i = 0; i < 4; i++) vin[i] = 32'h0;

    wire        go_rd  = go && !we;
    wire        go_cmd = go && we && (adr == 10'h004);
    wire        w_vtx  = adr[11] && (adr[10:9] != 2'b11) && !adr[5] && (adr[8:6] <= 3'd4);
    wire        go_cv  = go && we && (((adr[11:8] == 4'h1) && (vtype != 3'd5)) || w_vtx);

    // ---- the data registers: the read address for the state after this one ------------
    reg  [5:0]  ra;
    always @(*) begin
        case (st)
            S_IDLE:  ra = go_cmd ? wdata[21:16] : adr[7:2];
            S_AL:    ra = (3'(k + 3'd1) < nk) ? 6'(aa + 6'(k) + 6'd1) : bb;
            S_PUT:   ra = 6'd1;
            S_VY:    ra = 6'd2;
            S_VZ:    ra = 6'd3;
            S_VW:    ra = mv[5:0];
            S_NEXT:  ra = (3'(k + 3'd1) < nk) ? 6'(ba + 6'd1) : dst;
            S_WAITW: ra = 6'(ba + 6'd1);
            S_AUTO0: ra = 6'd4;
            S_AUTO1: ra = 6'd5;
            default: ra = ba;
        endcase
    end

    // and its write, in the state that makes it: a value converted (S_PUT),
    // a column's result (S_WRITE)
    wire        dwe = (st == S_PUT) || (st == S_WRITE);
    wire [5:0]  dwa = (st == S_WRITE) ? dst : c_data ? c_adr[7:2] : {4'h0, c_coord};
    wire [31:0] dwd = acc;

    `SUN3_RAM_BLOCK reg [31:0] dram [0:63];
    reg  [31:0] dq;
    always @(posedge clk) begin
        if (dwe) dram[dwa] <= dwd;
        dq <= dram[ra];
    end

    // ---- the multiply: 24 x 24 bits, registered in and out (a DSP) ----------------------
    reg  [23:0] mua = 24'h0, mub = 24'h0;
    reg  [47:0] mup = 48'h0;
    reg         mu_s = 1'b0, mu_z = 1'b0, mu_i = 1'b0;
    reg  signed [9:0] mu_e = 10'sh0;
    always @(posedge clk) mup <= mua * mub;

    // ---- the add: its operands, and their alignment -------------------------------------
    reg  [31:0] fa = 32'h0, fb = 32'h0;
    reg  [26:0] ad_ma = 27'h0, ad_mb = 27'h0;
    reg         ad_sub = 1'b0, ad_s = 1'b0, ad_bv = 1'b0;
    reg  [7:0]  ad_e = 8'h0;
    reg  [31:0] ad_by = 32'h0;

    wire        al_swap = fb[30:0] > fa[30:0];
    wire [31:0] al_big  = al_swap ? fb : fa;
    wire [31:0] al_sml  = al_swap ? fa : fb;
    wire [7:0]  al_d    = al_big[30:23] - al_sml[30:23];
    wire [26:0] al_ms   = {1'b1, al_sml[22:0], 3'b000};
    wire [26:0] al_sh   = al_ms >> al_d;
    wire        al_st   = |(al_ms & ~(27'h7FFFFFF << al_d));
    wire [26:0] al_mb   = (al_d >= 8'd27) ? 27'd1 : (al_sh | {26'h0, al_st});
    wire [27:0] ad_sum  = ad_sub ? ({1'b0, ad_ma} - {1'b0, ad_mb}) : ({1'b0, ad_ma} + {1'b0, ad_mb});

    // ---- normalise and round: pk_m x 2^(pk_e - 161), or pk_by when pk_bv ----------------
    reg         pk_s = 1'b0, pk_bv = 1'b0;
    reg  signed [9:0] pk_e = 10'sh0;
    reg  [35:0] pk_m = 36'h0;
    reg  [31:0] pk_by = 32'h0;
    reg  [35:0] n_m = 36'h0;
    reg  signed [10:0] n_e = 11'sh0;
    reg         n_z = 1'b0;
    wire [5:0]  pk_lz = lzc36(pk_m);
    always @(posedge clk) begin                     // the first half, every clock
        n_m <= pk_m << pk_lz;
        n_e <= 11'(pk_e) + 11'sd1 - 11'(signed'({5'b0, pk_lz}));
        n_z <= (pk_m == 36'h0);
    end
    wire [23:0] r_sig  = n_m[35:12];
    wire        r_inc  = n_m[11] & ((|n_m[10:0]) | n_m[12]);
    wire [24:0] r_sum  = {1'b0, r_sig} + {24'h0, r_inc};
    wire signed [10:0] r_e = n_e + (r_sum[24] ? 11'sd1 : 11'sd0);
    wire [22:0] r_frac = r_sum[24] ? r_sum[23:1] : r_sum[22:0];
    wire [31:0] pk_val = pk_bv ? pk_by :
                         n_z ? {pk_s, 31'h0} :
                         (r_e >= 11'sd255) ? {pk_s, 8'hFF, 23'h0} :
                         (r_e <= 11'sd0) ? {pk_s, 31'h0} : {pk_s, r_e[7:0], r_frac};

    // an integer written: its magnitude
    wire [31:0] w_mag = wdata[31] ? (~wdata + 32'd1) : wdata;

    always @(posedge clk) begin
        av  <= 1'b0;
        if (rst) begin
            st    <= S_IDLE;
            busy  <= 1'b0;
            mv    <= 16'h0;
            vtype <= 3'd0;
        end else case (st)
            S_IDLE: begin
                c_adr <= adr;
                if (go_rd) begin                    // a data register: ra has it
                    busy <= 1'b1;
                    st   <= S_RD;
                end else if (go && we && adr == 10'h000) begin
                    mv <= wdata[15:0];
                end else if (go && we && adr == 10'h002) begin
                    vtype <= wdata[15:13];
                end else if (go_cmd) begin          // A's first register: ra has it
                    busy   <= 1'b1;
                    op_cmd <= 1'b1;
                    nk     <= {1'b0, wdata[31:30]} + 3'd1;
                    nj     <= {1'b0, wdata[29:28]} + 3'd1;
                    aa     <= wdata[21:16];
                    bb     <= wdata[13:8];
                    dst    <= wdata[5:0];
                    k      <= 3'd0;
                    st     <= S_AL;
                end else if (go_cv) begin
                    // to IEEE single: integer and fixed normalised and rounded
                    busy  <= 1'b1;
                    pk_s  <= wdata[31];
                    pk_m  <= {1'b0, w_mag, 3'b000};
                    pk_e  <= ((adr[11] ? (adr[10:9] == 2'd1) : (vtype == 3'd1))) ? 10'sd142 : 10'sd158;
                    pk_bv <= (adr[11] ? (adr[10:9] == 2'd2) : (vtype > 3'd1)) || (wdata == 32'h0);
                    pk_by <= wdata;
                    pk_to <= 2'd0;
                    st    <= S_PKA;
                end
            end

            // ---- a data register's read, in the type's terms ------------------------------
            S_RD: begin
                q    <= (vtype == 3'd0) ? f2i(dq, 1'b0) : (vtype == 3'd1) ? f2i(dq, 1'b1) : dq;
                busy <= 1'b0;
                st   <= S_IDLE;
            end

            // ---- normalise (n_* now), round ---------------------------------------------------
            S_PKA: st <= S_PKB;
            S_PKB: case (pk_to)
                2'd0: begin                         // converted: to its register
                    acc <= pk_val;
                    st  <= S_PUT;
                end
                2'd1: begin                         // a product
                    if (k == 3'd0) begin
                        acc <= pk_val;
                        st  <= S_NEXT;
                    end else begin
                        fa    <= acc;
                        fb    <= pk_val;
                        pk_to <= 2'd2;
                        st    <= S_ADD1;
                    end
                end
                2'd2: begin acc <= pk_val; st <= S_NEXT; end
                default: begin acc <= pk_val; st <= S_WRITE; end
            endcase

            // ---- a value written: data register, or a vertex's coordinate -------------------
            S_PUT: begin                            // dwe: acc to its register
                if (c_data || c_coord != 2'd0) begin
                    busy <= 1'b0;
                    st   <= S_IDLE;
                end else begin                      // x: the vertex through MV
                    op_cmd <= 1'b0;
                    vin[0] <= acc;
                    nk     <= mv[10] ? 3'd4 : 3'd3;
                    nj     <= {1'b0, mv[9:8]} + 3'd1;
                    st     <= S_VY;
                end
            end
            S_VY: begin vin[1] <= dq; st <= S_VZ; end
            S_VZ: begin
                if (mv[10]) vin[2] <= mv[12] ? dq : 32'h0;
                st <= S_VW;
            end
            S_VW: begin
                if (mv[10]) vin[3] <= c_rel ? 32'h0 : mv[13] ? dq : F_ONE;
                else        vin[2] <= c_rel ? 32'h0 : mv[13] ? dq : F_ONE;
                ba  <= mv[5:0];
                dst <= 6'd4;
                j   <= 3'd0;
                k   <= 3'd0;
                st  <= S_TERM;
            end

            // ---- a command's A ------------------------------------------------------------------
            S_AL: begin
                vin[k[1:0]] <= dq;
                if (3'(k + 3'd1) < nk)
                    k <= k + 3'd1;
                else begin
                    k  <= 3'd0;
                    j  <= 3'd0;
                    ba <= bb;
                    st <= S_TERM;
                end
            end

            // ---- a term: vin[k] x the matrix element (dq), then added -----------------------
            S_TERM: begin
                mua  <= {1'b1, vin[k[1:0]][22:0]};
                mub  <= {1'b1, dq[22:0]};
                mu_s <= vin[k[1:0]][31] ^ dq[31];
                mu_z <= (vin[k[1:0]][30:23] == 8'd0) || (dq[30:23] == 8'd0);
                mu_i <= (vin[k[1:0]][30:23] == 8'hFF) || (dq[30:23] == 8'hFF);
                mu_e <= 10'(signed'({2'b0, vin[k[1:0]][30:23]})) + 10'(signed'({2'b0, dq[30:23]})) - 10'sd127;
                st   <= S_MUL2;
            end
            S_MUL2: st <= S_MUL3;                   // mup = mua x mub
            S_MUL3: begin
                pk_s  <= mu_s;
                pk_e  <= mu_e;
                pk_m  <= {mup[47:13], mup[12] | (|mup[11:0])};
                pk_bv <= mu_z | mu_i;
                pk_by <= mu_z ? {mu_s, 31'h0} : {mu_s, 8'hFF, 23'h0};
                pk_to <= 2'd1;
                st    <= S_PKA;
            end
            S_ADD1: begin                           // fa + fb: align
                ad_e   <= al_big[30:23];
                ad_s   <= al_big[31];
                ad_sub <= fa[31] ^ fb[31];
                ad_ma  <= {1'b1, al_big[22:0], 3'b000};
                ad_mb  <= al_mb;
                ad_bv  <= 1'b1;
                if (fa[30:23] == 8'hFF)       ad_by <= {fa[31], 8'hFF, 23'h0};
                else if (fb[30:23] == 8'hFF)  ad_by <= {fb[31], 8'hFF, 23'h0};
                else if (fb[30:23] == 8'd0)   ad_by <= (fa[30:23] != 8'd0) ? fa : {fa[31] & fb[31], 31'h0};
                else if (fa[30:23] == 8'd0)   ad_by <= fb;
                else                          ad_bv <= 1'b0;
                st <= S_ADD2;
            end
            S_ADD2: begin
                pk_s  <= ad_s;
                pk_e  <= 10'(signed'({2'b0, ad_e}));
                pk_m  <= {ad_sum, 8'h00};
                pk_bv <= ad_bv || (ad_sum == 28'h0);
                pk_by <= ad_bv ? ad_by : 32'h0;
                st    <= S_PKA;
            end
            S_NEXT: begin
                if (3'(k + 3'd1) < nk) begin
                    k  <= k + 3'd1;
                    ba <= ba + 6'd1;
                    st <= S_TERM;
                end else if (!op_cmd && c_rel)      // ra has dst: the last result
                    st <= S_REL;
                else
                    st <= S_WRITE;
            end
            S_REL: begin
                fa    <= dq;
                fb    <= acc;
                pk_to <= 2'd3;
                st    <= S_ADD1;
            end
            S_WRITE: begin                          // dwe: acc to dst
                if (3'(j + 3'd1) < nj) begin
                    st <= S_WAITW;
                end else if (!op_cmd && mv[14])
                    st <= S_AUTO0;
                else begin
                    busy <= 1'b0;
                    st   <= S_IDLE;
                end
            end
            S_WAITW: begin                          // ra has the next column's first
                j   <= j + 3'd1;
                k   <= 3'd0;
                ba  <= ba + 6'd1;
                dst <= dst + 6'd1;
                st  <= S_TERM;
            end

            // ---- autoload: data 4 and 5, rounded down, to the FBC -------------------------
            S_AUTO0: st <= S_AUTO1;
            S_AUTO1: begin ax <= f2i(dq, 1'b0); st <= S_AUTO2; end
            S_AUTO2: begin
                ay   <= f2i(dq, 1'b0);
                agrp <= c_adr[8:6];
                av   <= 1'b1;
                st   <= S_AUTO3;
            end
            S_AUTO3: begin                          // av seen while still busy
                busy <= 1'b0;
                st   <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end

endmodule
