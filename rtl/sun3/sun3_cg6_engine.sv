`timescale 1ns / 1ps

`include "sun3_attr.vh"
//
// sun3_cg6_engine.sv -- the GX's drawing engine, on the memory's clock.
//
// docs/cg6.md is the specification and tools/cg6model/cg6model.c the model
// this is checked against (tb/verilator/tb_cg6.sv replays its traces).  The
// register file is sun3_cg6.sv, on the CPU's clock; it starts a command with
// `start_tgl' and holds every input below still until `done_tgl' answers
// (the CPU's accesses to the FBC wait meanwhile), so they are read here as
// they are, without a copy: quasi-static levels, crossing clocks only after
// the toggle's two flops.
//
// Stage 1 (docs/cg6.md, "Stages") draws what the PROM's console and
// libpixrect's fills, copies and text need:
//
//   rect   the rectangle between two vertices, inclusive (and a point, the
//          rectangle of one)
//   font   one row of the font register's word: up to 32 pixels of colour1
//          or 4 of colour8, at y0 from x0 to x1
//   blit   (x0,y0)-(x1,y1) to (x2,y2), the source read before it is written
//
// through the raster-op unit -- RASTEROP's truth table on f, b, s and d, a
// bit plane at a time, the plane mask, the pixel mask (bit 31 - (x & 31)),
// and the clip window -- which is all of it but the pattern: RASTEROP's
// pattern field 3 draws ones here (stage 3).  Lines, triangles and
// quadrilaterals are a later stage's; sun3_cg6.sv queues their vertices and
// draws nothing.
//
// **Memory.**  The frame buffer is the colour plane the cg4 has, 1 MiB at
// SDRAM word COLOR_WORD, a byte a pixel, 1152 a line, in the SDRAM adapter's
// layout (rtl/sun3_mister_sdram.sv): line k (16 bytes) is the burst at word
// COLOR_WORD + 8k, its byte b at {b[3:2], ~b[1:0], 3'b000}.  A screen line is
// 72 bursts, so no burst crosses one.  The engine is the adapter's fourth
// client (ge_*): a burst read, or a 32-bit word written with byte selects.
// The adapter's controller writes 16 bits at a time, so a whole burst written
// is eight writes.
//
// **The work is done a burst (16 pixels) at a time**: for each burst a span
// touches, the bytes it writes (the span, the pixel mask, the clip, the
// frame buffer's 1 MiB), each byte's source s, and -- only when the raster op
// or the plane mask needs it -- the destination burst read first.  Then the
// bytes go through the truth table and out, a word at a time, the words with
// nothing to write skipped.  A blit reads each source line's span into a line
// buffer first (an M10K, 128 bursts) and takes each destination burst's 16
// bytes out of it through a funnel shifter, so the copy may overlap in either
// direction along a line; rows run bottom-up when the copy moves down.
//
// **Coordinates** come in as 16-bit signed numbers, sun3_cg6.sv's registers
// saturated: everything that can be drawn is well inside.
//
// **Coherency.**  The CPU's frame-buffer writes go through the memory
// bridge's request FIFO; a command waits until that is empty (`mem_idle',
// sun3_cached_fifo_bridge's WB_IDLE, on this clock) before it touches
// memory.  The PROM and libpixrect wait for BUSY before they touch the frame
// buffer themselves.
//
module sun3_cg6_engine #(
    parameter bit [25:0] COLOR_WORD = 26'h0C80000      // 25 MiB, the cg4's colour plane
) (
    input  wire         mclk,
    input  wire         rst,            // the machine's reset, any clock: synchronised here

    input  wire         start_tgl,      // a command (sun3_cg6.sv's clock)
    output reg          done_tgl = 1'b0,
    input  wire         mem_idle,

    // the command, held still from start_tgl to done_tgl
    input  wire [1:0]   cmd,            // 0 rect, 1 blit, 2 font
    input  wire signed [15:0] x0, y0, x1, y1, x2, y2,
    input  wire signed [15:0] clipminx, clipminy, clipmaxx, clipmaxy,
    input  wire [31:0]  font,
    input  wire         colour8,        // MISC's data field is colour8
    input  wire [7:0]   fcolor, bcolor,
    input  wire [31:0]  rasterop,
    input  wire [7:0]   planemask,
    input  wire [31:0]  pixelmask,

    // the SDRAM adapter's engine port
    output reg  [25:0]  ge_word  = 26'd0,
    output reg          ge_req   = 1'b0,
    output reg          ge_we    = 1'b0,
    output reg  [31:0]  ge_wdata = 32'h0,
    output reg  [3:0]   ge_sel   = 4'h0,
    input  wire         ge_done,
    input  wire [127:0] ge_rdata
);

    localparam [1:0] C_RECT = 2'd0, C_BLIT = 2'd1, C_FONT = 2'd2;

    // ---- the clock crossing ------------------------------------------------------
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] rst_s = 2'b11, st_s = 2'b00;
    always @(posedge mclk) begin
        rst_s <= {rst_s[0], rst};
        st_s  <= {st_s[0], start_tgl};
    end
    wire mrst    = rst_s[1];
    wire pending = st_s[1] ^ done_tgl;      // a command not yet answered

    // ---- what a command draws with (levels, still while it runs) ----------------
    // The plane and pixel masks by RASTEROP's fields: 1 none, 3 the register,
    // 0 and 2 all.  s for drawing: the pattern field, 1 zeros, otherwise ones.
    wire [7:0]  pmask = (rasterop[31:30] == 2'd1) ? 8'h00 :
                        (rasterop[31:30] == 2'd3) ? planemask : 8'hFF;
    wire [31:0] xmask = (rasterop[29:28] == 2'd1) ? 32'h0 :
                        (rasterop[29:28] == 2'd3) ? pixelmask : 32'hFFFFFFFF;
    wire        s_draw = (rasterop[27:26] != 2'd1);

    // Each plane's nibble of the truth table, chosen by its f and b bits
    // (index f*8 + b*4 + s*2 + d); a plane the mask leaves alone keeps d.
    reg  [3:0]  nib [0:7];
    reg         need_d;
    always @(*) begin
        need_d = 1'b0;
        for (int i = 0; i < 8; i++) begin
            nib[i] = pmask[i] ? rasterop[{1'b0, fcolor[i], bcolor[i], 2'b00} +: 4] : 4'b1010;
            if (cmd == C_RECT)
                need_d = need_d | (nib[i][{s_draw, 1'b1}] != nib[i][{s_draw, 1'b0}]);
            else
                need_d = need_d | (nib[i][1] != nib[i][0]) | (nib[i][3] != nib[i][2]);
        end
    end

    // ---- the command's extent, clipped -----------------------------------------
    // The clip window, and the frame buffer: x 0..1151, rows 0..910 (the
    // 1 MiB ends 256 pixels into row 910).
    typedef logic signed [17:0] s18;
    function automatic s18 smax(input s18 a, input s18 b); return (a > b) ? a : b; endfunction
    function automatic s18 smin(input s18 a, input s18 b); return (a < b) ? a : b; endfunction

    wire s18 cx0 = smax(s18'(clipminx), 18'sd0);
    wire s18 cx1 = smin(s18'(clipmaxx), 18'sd1151);
    wire s18 cy0 = smax(s18'(clipminy), 18'sd0);
    wire s18 cy1 = smin(s18'(clipmaxy), 18'sd910);

    wire s18 bw   = s18'(x1) - s18'(x0) + 18'sd1;          // a blit's (and the font's) width
    wire s18 bh   = s18'(y1) - s18'(y0) + 18'sd1;
    wire s18 fend = s18'(x0) + smin(bw - 18'sd1, colour8 ? 18'sd3 : 18'sd31);

    s18  e_xa, e_xb, e_ya, e_yb;
    logic e_ok;
    always @(*) begin
        case (cmd)
            C_BLIT: begin
                e_ok = (bw > 0) && (bh > 0);
                e_xa = smax(s18'(x2), cx0);
                e_xb = smin(s18'(x2) + bw - 18'sd1, cx1);
                e_ya = smax(s18'(y2), cy0);
                e_yb = smin(s18'(y2) + bh - 18'sd1, cy1);
            end
            C_FONT: begin
                e_ok = (bw > 0);
                e_xa = smax(s18'(x0), cx0);
                e_xb = smin(fend, cx1);
                e_ya = smax(s18'(y0), cy0);
                e_yb = smin(s18'(y0), cy1);
            end
            default: begin
                e_ok = (x1 >= x0) && (y1 >= y0);
                e_xa = smax(s18'(x0), cx0);
                e_xb = smin(s18'(x1), cx1);
                e_ya = smax(s18'(y0), cy0);
                e_yb = smin(s18'(y1), cy1);
            end
        endcase
    end


    // ---- the state ------------------------------------------------------------------
    localparam [4:0] E_IDLE = 5'd0,  E_DRAIN = 5'd1,  E_SETUP = 5'd2,  E_ROW  = 5'd3,
                     E_ROW2 = 5'd4,  E_ROW3  = 5'd5,  E_SRC   = 5'd6,  E_LINE = 5'd7,
                     E_BUF0 = 5'd8,  E_BUF1  = 5'd9,  E_FUN1  = 5'd10, E_FUN2 = 5'd11,
                     E_FUN3 = 5'd12, E_DRD   = 5'd13, E_CALC  = 5'd14, E_WR   = 5'd15,
                     E_NEXT = 5'd16, E_ROW4 = 5'd17;
    reg  [4:0]  st = E_IDLE;
    reg         last = 1'b0;            // E_NEXT: the command is finished

    reg  [10:0] xa = 11'd0, xb = 11'd0;     // the span on every row (0..1151)
    reg  [10:0] xbr = 11'd0;                // ... on this one (row 910 ends at 255)
    reg  [9:0]  cy = 10'd0, yend = 10'd0;   // the row, the last row (0..910)
    reg         up = 1'b0;                  // rows bottom-up
    reg  [6:0]  ln = 7'd0, lend = 7'd0;     // the burst in the row (0..71), the last
    reg  [15:0] lrow = 16'd0;               // the row's first burst: cy * 72
    reg  [25:0] lw = 26'd0;                 // the burst's SDRAM word (8-aligned)
    reg  signed [17:0] fsh = 18'sd0;        // the font: 16 * ln - x0

    // a blit's source, per row
    reg  signed [17:0] sy = 18'sd0;         // the source row
    reg         srow = 1'b0;                // the source row is in the frame buffer
    reg  signed [22:0] soff = 23'sd0;       // its byte offset from the destination's
    reg  signed [18:0] q = 19'sd0, qz = 19'sd0;    // the next source burst, the last
    reg  signed [18:0] qb = 19'sd0;                // the first destination burst's source burst
    reg  [6:0]  qi = 7'd0;                  // where q goes in the line buffer
    reg  [6:0]  bidx = 7'd0;                // the line buffer's burst for this destination burst
    reg  signed [12:0] va = 13'sd0, vb = 13'sd0;   // destination x whose source exists

    reg  [15:0] en = 16'h0;                 // the burst's bytes to write (byte array order)
    reg  [127:0] sb = 128'h0;               // their sources, a byte each (byte b at [8b])
    reg  [127:0] dline = 128'h0;            // the destination burst, as the SDRAM has it
    reg  [127:0] res = 128'h0;              // the result, as the SDRAM has it
    reg  [3:0]  wleft = 4'h0;               // words of `res' still to write

    // ---- byte order --------------------------------------------------------------
    // A burst as the SDRAM adapter has it to a byte array (byte b at [8b]) and
    // back: the same exchange both ways.
    function automatic [127:0] swz(input [127:0] r);
        for (int b = 0; b < 16; b++)
            swz[8 * b +: 8] = r[{b[3:2], ~b[1:0], 3'b000} +: 8];
    endfunction

    // The bytes b of burst L (x = 16L + b) with lo <= x <= hi, found by the
    // burst and the nibble: lo and hi are -1 .. 1152.
    function automatic [15:0] range16(input [6:0] L, input signed [12:0] lo, input signed [12:0] hi);
        logic signed [8:0] ll, hl, l9;
        ll = lo[12:4];
        hl = hi[12:4];
        l9 = {2'b00, L};
        for (int b = 0; b < 16; b++)
            range16[b] = ((l9 > ll) || (l9 == ll && 4'(b) >= lo[3:0])) &&
                         ((l9 < hl) || (l9 == hl && 4'(b) <= hi[3:0]));
    endfunction

    function automatic signed [12:0] clamp13(input signed [22:0] v);
        return (v < 0) ? -13'sd1 : (v > 23'sd1152) ? 13'sd1152 : 13'(v);
    endfunction

    // ---- the line buffer: a blit's source row, a burst an entry ------------------
    `SUN3_RAM_BLOCK reg [127:0] lbuf [0:127];
    reg  [6:0]   lb_ra = 7'd0;
    reg  [127:0] lb_q;
    wire         lb_we;                     // a source burst answered: at qi, on this edge
    always @(posedge mclk) begin
        if (lb_we) lbuf[qi] <= ge_rdata;
        lb_q <= lbuf[lb_ra];
    end

    // ---- a burst's sources -----------------------------------------------------------
    // The font register: x0's pixel is the word's MSB (colour1) or its top
    // byte (colour8); fsh is -15..31 for the bursts the span touches.
    wire [63:0]  fext = {16'h0, font, 16'h0};
    wire [5:0]   fsa  = 6'(18'sd32 - fsh);
    wire [15:0]  fwin = fext[fsa +: 16];        // fwin[15 - b]: byte b's bit
    reg  [127:0] s_font;
    always @(*)
        for (int b = 0; b < 16; b++) begin
            logic [1:0] k;
            k = 2'(fsh + 18'(b));
            s_font[8 * b +: 8] = colour8 ? font[8 * (3 - 32'(k)) +: 8] : {8{fwin[15 - b]}};
        end

    // A blit's: two bursts of the line buffer, 32 bytes, and the 16 from byte
    // soff[3:0] of them through the funnel, in two steps (words, then bytes);
    // a byte whose source is outside the frame buffer is 0.
    reg  [127:0] b0 = 128'h0;
    reg  [255:0] fun = 256'h0;
    wire [3:0]   fr = soff[3:0];
    wire [127:0] fun_out = 128'(fun >> {fr[1:0], 3'b000});
    wire [15:0]  vmask = range16(ln, va, vb) & {16{srow}};
    reg  [127:0] s_blit;
    always @(*)
        for (int b = 0; b < 16; b++)
            s_blit[8 * b +: 8] = vmask[b] ? fun_out[8 * b +: 8] : 8'h00;

    // ---- the raster op: each byte's bits through its plane's nibble --------------
    wire [127:0] d_ba = swz(dline);
    reg  [127:0] r_ba;
    always @(*)
        for (int b = 0; b < 16; b++)
            for (int i = 0; i < 8; i++)
                r_ba[8 * b + i] = nib[i][{sb[8 * b + i], need_d & d_ba[8 * b + i]}];

    // the burst's SDRAM word
    wire [25:0]  lword = COLOR_WORD + {7'd0, lrow + {9'd0, ln}, 3'b000};

    // a row's source (a blit): its line, and its offset from the destination
    wire signed [17:0] sy_n = s18'({8'd0, cy}) + s18'(y0) - s18'(y2);
    wire signed [22:0] so_n = 23'(sy) * 23'sd1152 + 23'(s18'(x0)) - 23'(s18'(x2));
    wire [10:0]        xbr_n = (cy == 10'd910 && xb > 11'd255) ? 11'd255 : xb;
    wire signed [22:0] qa_n = (23'({12'd0, xa}) + soff) >>> 4;

    // the lowest word still to write
    wire [1:0]         wsel = wleft[0] ? 2'd0 : wleft[1] ? 2'd1 : wleft[2] ? 2'd2 : 2'd3;

    assign lb_we = (st == E_SRC) && ge_req && ge_done;

    always @(posedge mclk) begin
        // the port: a request is held until it is answered
        if (ge_req && ge_done) ge_req <= 1'b0;

        if (mrst) begin
            st       <= E_IDLE;
            last     <= 1'b0;
            done_tgl <= 1'b0;
        end else case (st)
            E_IDLE:
                if (pending && !ge_req) st <= E_DRAIN;

            E_DRAIN:                        // the CPU's posted writes first
                if (mem_idle) st <= E_SETUP;

            E_SETUP: begin
                xa <= 11'(e_xa);
                xb <= 11'(e_xb);
                up <= (cmd == C_BLIT) && (y2 > y0);
                if (!e_ok || e_xa > e_xb || e_ya > e_yb) begin
                    last <= 1'b1;
                    st   <= E_NEXT;
                end else begin
                    cy   <= ((cmd == C_BLIT) && (y2 > y0)) ? 10'(e_yb) : 10'(e_ya);
                    yend <= ((cmd == C_BLIT) && (y2 > y0)) ? 10'(e_ya) : 10'(e_yb);
                    last <= 1'b0;
                    st   <= E_ROW;
                end
            end

            E_ROW: begin                    // a row: its span and, for a blit, its source
                xbr  <= xbr_n;
                ln   <= xa[10:4];
                lend <= xbr_n[10:4];
                lrow <= {cy, 6'd0} + {3'd0, cy, 3'd0};
                fsh  <= s18'({xa[10:4], 4'b0000}) - s18'(x0);
                sy   <= sy_n;
                va   <= clamp13(23'(s18'(x2)) - 23'(s18'(x0)));        // x + x0 - x2 >= 0
                st   <= E_ROW2;
            end

            E_ROW2: begin                   // (a clock each, for the 100 MHz)
                srow <= (sy >= 0) && (sy <= 18'sd910);
                soff <= so_n;
                st   <= E_ROW3;
            end

            E_ROW3: begin
                q    <= 19'(qa_n);
                qz   <= 19'((23'({12'd0, xbr}) + soff) >>> 4);
                qb   <= 19'(23'({16'd0, xa[10:4]}) + (soff >>> 4));
                qi   <= 7'd0;
                vb   <= clamp13(23'sd1048575 - soff);                  // ... inside the 1 MiB
                st   <= E_ROW4;
            end

            E_ROW4: begin
                // the line buffer's entry for the first burst: 0, or -1 when
                // that burst's own bytes all come before the source's first
                bidx <= 7'(qb - q);
                if (xa > xbr) begin
                    ln <= lend;                 // row 910 past its 256th pixel: the next row
                    st <= E_NEXT;
                end else if (cmd == C_BLIT && srow)
                    st <= E_SRC;
                else
                    st <= E_LINE;
            end

            E_SRC:                          // the source row's span into the line buffer
                if (!ge_req) begin
                    ge_req  <= 1'b1;
                    ge_we   <= 1'b0;
                    ge_word <= COLOR_WORD + 26'($signed({q, 3'b000}));
                end else if (ge_done) begin  // (lb_we)
                    qi    <= qi + 7'd1;
                    q     <= q + 19'sd1;
                    if (q == qz) st <= E_LINE;
                end

            E_LINE: begin                   // a burst: what it writes, and its source
                en    <= range16(ln, 13'(xa), 13'(xbr)) &
                         {<<{ln[0] ? xmask[15:0] : xmask[31:16]}};
                sb    <= (cmd == C_FONT) ? s_font : {128{s_draw}};
                lw    <= lword;
                lb_ra <= bidx;
                st    <= E_BUF0;
            end

            E_BUF0: begin                   // lbuf[bidx] is read on this edge
                lb_ra <= bidx + 7'd1;
                if (en == 16'h0)
                    st <= E_NEXT;               // nothing to write here
                else if (cmd == C_BLIT)
                    st <= E_BUF1;
                else
                    st <= need_d ? E_DRD : E_CALC;
            end

            E_BUF1: begin                   // ... and lbuf[bidx + 1] on this one
                b0 <= lb_q;
                st <= E_FUN1;
            end

            E_FUN1: begin
                fun <= {swz(lb_q), swz(b0)};
                st  <= E_FUN2;
            end

            E_FUN2: begin                   // the words
                fun <= fun >> {fr[3:2], 5'b00000};
                st  <= E_FUN3;
            end

            E_FUN3: begin                   // the bytes
                sb <= s_blit;
                st <= need_d ? E_DRD : E_CALC;
            end

            E_DRD:                          // the destination, when the op needs it
                if (!ge_req) begin
                    ge_req  <= 1'b1;
                    ge_we   <= 1'b0;
                    ge_word <= lw;
                end else if (ge_done) begin
                    dline <= ge_rdata;
                    st    <= E_CALC;
                end

            E_CALC: begin
                res   <= swz(r_ba);
                wleft <= {|en[15:12], |en[11:8], |en[7:4], |en[3:0]};
                st    <= E_WR;
            end

            E_WR:                           // the words with something to write
                if (!ge_req) begin
                    if (wleft == 4'h0)
                        st <= E_NEXT;
                    else begin
                        ge_req   <= 1'b1;
                        ge_we    <= 1'b1;
                        ge_word  <= {lw[25:3], wsel, 1'b0};
                        ge_wdata <= res[32 * wsel +: 32];
                        ge_sel   <= {en[4 * wsel], en[4 * wsel + 1], en[4 * wsel + 2], en[4 * wsel + 3]};
                        wleft[wsel] <= 1'b0;
                    end
                end

            E_NEXT:                         // the next burst, row, or the end
                if (last) begin
                    done_tgl <= ~done_tgl;
                    last     <= 1'b0;
                    st       <= E_IDLE;
                end else if (ln != lend) begin
                    ln   <= ln + 7'd1;
                    bidx <= bidx + 7'd1;
                    fsh  <= fsh + 18'sd16;
                    st   <= E_LINE;
                end else if (cy == yend)
                    last <= 1'b1;
                else begin
                    cy <= up ? cy - 10'd1 : cy + 10'd1;
                    st <= E_ROW;
                end

            default: st <= E_IDLE;
        endcase
    end

endmodule
