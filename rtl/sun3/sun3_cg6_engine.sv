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
// The commands (docs/cg6.md, "The FBC"):
//
//   rect   the rectangle between two vertices, inclusive (and a point, the
//          rectangle of one)
//   line   Bresenham between two vertices, both ends drawn, stepped from the
//          left end, the error term from -(major/2)
//   poly   a triangle or quadrilateral of 2..4 vertices, scan-converted as
//          libpixrect's pr_polygon_2 does it in memory: Sun's edge DDA
//          (cg6model.c's edge_setup, edge_step) for each edge, on each row
//          the pixels from one edge's x up to, not including, the next's
//   font   one row of the font register's word: up to 32 pixels of colour1
//          or 4 of colour8, at y0 from x0 to x1
//   blit   (x0,y0)-(x1,y1) to (x2,y2), the source read before it is written
//
// through the raster-op unit -- RASTEROP's truth table on f, b, s and d, a
// bit plane at a time, the plane mask, the pixel mask (bit 31 - (x & 31)),
// the clip window, and for the drawing commands the pattern (s is bit
// 15 - ((x + alignx) & 15) of row (y + aligny) & 15 when RASTEROP's pattern
// field is 3, 0 when it is 1, else 1).
//
// **Spans.**  Every command is runs of pixels on a row.  A rectangle, a
// blit and the font are a row loop over one span; a line and a polygon have
// a generator that hands spans, one at a time, to the same row machinery: a
// line's runs of pixels on a row (one pixel a row when it is steep), a
// polygon's one or two spans a row.  Each span is clipped as it is taken.
//
// **Memory.**  The frame buffer is the colour plane the cg4 has, 1 MiB at
// SDRAM word COLOR_WORD, a byte a pixel, 1152 a line, in the SDRAM adapter's
// layout (rtl/sun3_mister_sdram.sv): line k (16 bytes) is the burst at word
// COLOR_WORD + 8k, its byte b at {b[3:2], ~b[1:0], 3'b000}.  A screen line is
// 72 bursts, so no burst crosses one.  The engine is the adapter's fourth
// client (ge_*): a burst read, or a burst written with a select a byte (the
// controller's eight WRITEs on consecutive clocks).
//
// **The work is done a burst (16 pixels) at a time**: for each burst a span
// touches, the bytes it writes (the span, the pixel mask, the clip, the
// frame buffer's 1 MiB), each byte's source s, and -- only when the raster op
// or the plane mask needs it -- the destination burst read first.  Then the
// bytes go through the truth table and out as one burst.  A blit reads each source line's span into a line
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
    input  wire [2:0]   cmd,            // 0 rect, 1 blit, 2 font, 3 line, 4 poly
    input  wire signed [15:0] i_x0, i_y0, i_x1, i_y1, i_x2, i_y2,      // a blit's and the font's
    input  wire signed [15:0] i_vx0, i_vy0, i_vx1, i_vy1, i_vx2, i_vy2, i_vx3, i_vy3,  // a drawing's vertices
    input  wire [2:0]   vk,             // ... how many, a polygon's
    input  wire signed [15:0] i_clipminx, i_clipminy, i_clipmaxx, i_clipmaxy,
    input  wire [31:0]  font,
    input  wire         colour8,        // MISC's data field is colour8
    input  wire [7:0]   fcolor, bcolor,
    input  wire [31:0]  rasterop,
    input  wire [7:0]   planemask,
    input  wire [31:0]  pixelmask,
    input  wire [255:0] pattern,        // PATTERN0..7, PATTERN0 at [255:224]
    input  wire [7:0]   pattalign,      // {x, y}, 4 bits each

    // the SDRAM adapter's engine port
    output reg  [25:0]  ge_word  = 26'd0,
    output reg          ge_req   = 1'b0,
    output reg          ge_we    = 1'b0,
    output reg  [127:0] ge_wdata = 128'h0,   // a line, as ge_rdata
    output reg  [15:0]  ge_sel   = 16'h0,    // ... a select for each byte, [b] for [8b+7:8b]
    input  wire         ge_done,
    input  wire [127:0] ge_rdata
);

    localparam [2:0] C_RECT = 3'd0, C_BLIT = 3'd1, C_FONT = 3'd2, C_LINE = 3'd3, C_POLY = 3'd4;

    // ---- the clock crossing ------------------------------------------------------
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] rst_s = 2'b11, st_s = 2'b00;
    always @(posedge mclk) begin
        rst_s <= {rst_s[0], rst};
        st_s  <= {st_s[0], start_tgl};
    end
    wire mrst    = rst_s[1];
    wire pending = st_s[1] ^ done_tgl;      // a command not yet answered


    wire gen = (cmd == C_LINE) || (cmd == C_POLY);  // spans from a generator

    // ---- what a command draws with (levels, still while it runs) ----------------
    // The plane and pixel masks by RASTEROP's fields: 1 none, 3 the register,
    // 0 and 2 all.  s for drawing: the pattern field, 1 zeros, 3 the pattern,
    // otherwise ones.
    wire [7:0]  pmask = (rasterop[31:30] == 2'd1) ? 8'h00 :
                        (rasterop[31:30] == 2'd3) ? planemask : 8'hFF;
    wire [31:0] xmask = (rasterop[29:28] == 2'd1) ? 32'h0 :
                        (rasterop[29:28] == 2'd3) ? pixelmask : 32'hFFFFFFFF;
    wire        s_draw = (rasterop[27:26] != 2'd1);
    wire        s_patt = (rasterop[27:26] == 2'd3);
    wire        s_var  = (cmd == C_BLIT) || (cmd == C_FONT) || s_patt;  // s is not one value

    // Each plane's nibble of the truth table, chosen by its f and b bits
    // (index f*8 + b*4 + s*2 + d); a plane the mask leaves alone keeps d.
    reg  [3:0]  nib [0:7];
    reg         need_d;
    always @(*) begin
        need_d = 1'b0;
        for (int i = 0; i < 8; i++) begin
            nib[i] = pmask[i] ? rasterop[{1'b0, fcolor[i], bcolor[i], 2'b00} +: 4] : 4'b1010;
            if (!s_var)
                need_d = need_d | (nib[i][{s_draw, 1'b1}] != nib[i][{s_draw, 1'b0}]);
            else
                need_d = need_d | (nib[i][1] != nib[i][0]) | (nib[i][3] != nib[i][2]);
        end
    end

    // ---- the command's extent, clipped -----------------------------------------
    // The clip window, and the frame buffer: x 0..1151, rows 0..910 (the
    // 1 MiB ends 256 pixels into row 910).
    typedef logic signed [17:0] s18;
    typedef logic signed [21:0] s22;
    // bit i of the result is bit 15-i of k ({<<{k}}, which Quartus 17 lacks)
    function automatic [15:0] rev16(input [15:0] k);
        for (int i = 0; i < 16; i++) rev16[i] = k[15 - i];
    endfunction
    function automatic s18 smax(input s18 a, input s18 b); return (a > b) ? a : b; endfunction
    function automatic s18 smin(input s18 a, input s18 b); return (a < b) ? a : b; endfunction
    function automatic s22 lmax(input s22 a, input s22 b); return (a > b) ? a : b; endfunction
    function automatic s22 lmin(input s22 a, input s22 b); return (a < b) ? a : b; endfunction

    wire signed [17:0] cx0 = smax(s18'(clipminx), 18'sd0);
    wire signed [17:0] cx1 = smin(s18'(clipmaxx), 18'sd1151);
    wire signed [17:0] cy0 = smax(s18'(clipminy), 18'sd0);
    wire signed [17:0] cy1 = smin(s18'(clipmaxy), 18'sd910);

    wire signed [17:0] bw   = s18'(x1) - s18'(x0) + 18'sd1;          // a blit's (and the font's) width
    wire signed [17:0] bh   = s18'(y1) - s18'(y0) + 18'sd1;
    wire signed [17:0] fend = s18'(x0) + smin(bw - 18'sd1, colour8 ? 18'sd3 : 18'sd31);

    s18  c_xa, c_xb, c_ya, c_yb;
    logic c_ok;
    always @(*) begin
        case (cmd)
            C_BLIT: begin
                c_ok = (bw > 0) && (bh > 0);
                c_xa = smax(s18'(x2), cx0);
                c_xb = smin(s18'(x2) + bw - 18'sd1, cx1);
                c_ya = smax(s18'(y2), cy0);
                c_yb = smin(s18'(y2) + bh - 18'sd1, cy1);
            end
            C_FONT: begin
                c_ok = (bw > 0);
                c_xa = smax(s18'(x0), cx0);
                c_xb = smin(fend, cx1);
                c_ya = smax(s18'(y0), cy0);
                c_yb = smin(s18'(y0), cy1);
            end
            default: begin
                c_ok = (vx1 >= vx0) && (vy1 >= vy0);
                c_xa = smax(s18'(vx0), cx0);
                c_xb = smin(s18'(vx1), cx1);
                c_ya = smax(s18'(vy0), cy0);
                c_yb = smin(s18'(vy1), cy1);
            end
        endcase
    end

    // ... registered: the vertices fan out to the rectangle, line and polygon
    // units at once, and the full build did not route with these read straight
    // from them.  The command's inputs are copied on leaving E_IDLE, so these
    // are right from E_SETUP on (E_DRAIN lies between).
    logic e_ok = 1'b0;
    logic signed [17:0] e_xa = 18'sd0, e_xb = 18'sd0, e_ya = 18'sd0, e_yb = 18'sd0;
    always @(posedge mclk) begin
        e_ok <= c_ok; e_xa <= c_xa; e_xb <= c_xb; e_ya <= c_ya; e_yb <= c_yb;
    end


    // ---- the state ------------------------------------------------------------------
    localparam [5:0] E_IDLE = 6'd0,  E_DRAIN = 6'd1,  E_SETUP = 6'd2,  E_ROW  = 6'd3,
                     E_ROW2 = 6'd4,  E_ROW3  = 6'd5,  E_SRC   = 6'd6,  E_LINE = 6'd7,
                     E_BUF0 = 6'd8,  E_BUF1  = 6'd9,  E_FUN1  = 6'd10, E_FUN2 = 6'd11,
                     E_FUN3 = 6'd12, E_DRD   = 6'd13, E_CALC  = 6'd14, E_WR   = 6'd15,
                     E_NEXT = 6'd16, E_ROW4  = 6'd17,
                     // the generators' (a line's, a polygon's) and a span taken from one
                     E_SPAN = 6'd18, E_GRET  = 6'd19, E_LSET  = 6'd20, E_LGEN = 6'd21,
                     E_PSET = 6'd22, E_PE0   = 6'd23, E_PDIV  = 6'd24, E_PE1  = 6'd25,
                     E_PE2  = 6'd26, E_PE3   = 6'd27, E_PROW0 = 6'd28, E_PROW = 6'd29,
                     E_PS1  = 6'd30, E_PS2   = 6'd31, E_PS3   = 6'd32, E_PNEXT = 6'd33,
                     E_PST1 = 6'd34, E_PST2  = 6'd35;
    reg  [5:0]  st = E_IDLE;

    // The command's coordinates and clip window, copied on mclk when a command
    // is taken (E_IDLE, `pending'; they are held still from start_tgl to
    // done_tgl, so the copy is exact).  The engine's comparisons and min/max
    // read these local registers, not sun3_cg6.sv's on the CPU's clock: the
    // full build failed to route with every use reaching back across the
    // chip to the register file (sun3_cg6's ex/ey).
    // Each feeds the rectangle, line and polygon units' comparators at once;
    // MAX_FANOUT lets the fitter duplicate them next to their consumers (with
    // one copy each, vx1/vy1 alone still did not route).
    (* altera_attribute = "-name MAX_FANOUT 12" *)
    reg signed [15:0] x0 = 16'sd0, y0 = 16'sd0, x1 = 16'sd0, y1 = 16'sd0, x2 = 16'sd0, y2 = 16'sd0;
    (* altera_attribute = "-name MAX_FANOUT 12" *)
    reg signed [15:0] vx0 = 16'sd0, vy0 = 16'sd0, vx1 = 16'sd0, vy1 = 16'sd0;
    (* altera_attribute = "-name MAX_FANOUT 12" *)
    reg signed [15:0] vx2 = 16'sd0, vy2 = 16'sd0, vx3 = 16'sd0, vy3 = 16'sd0;
    (* altera_attribute = "-name MAX_FANOUT 12" *)
    reg signed [15:0] clipminx = 16'sd0, clipminy = 16'sd0, clipmaxx = 16'sd0, clipmaxy = 16'sd0;
    always @(posedge mclk)
        if (st == E_IDLE && pending) begin
            x0 <= i_x0; y0 <= i_y0; x1 <= i_x1; y1 <= i_y1; x2 <= i_x2; y2 <= i_y2;
            vx0 <= i_vx0; vy0 <= i_vy0; vx1 <= i_vx1; vy1 <= i_vy1;
            vx2 <= i_vx2; vy2 <= i_vy2; vx3 <= i_vx3; vy3 <= i_vy3;
            clipminx <= i_clipminx; clipminy <= i_clipminy;
            clipmaxx <= i_clipmaxx; clipmaxy <= i_clipmaxy;
        end
    reg         last = 1'b0;            // E_NEXT: the command is finished

    reg  [10:0] xa = 11'd0, xb = 11'd0;     // the span on every row (0..1151)
    reg  [10:0] xbr = 11'd0;                // ... on this one (row 910 ends at 255)
    reg  [9:0]  cy = 10'd0, yend = 10'd0;   // the row, the last row (0..910)
    reg         up = 1'b0;                  // rows bottom-up
    reg  [6:0]  ln = 7'd0, lend = 7'd0;     // the burst in the row (0..71), the last
    reg  [15:0] lrow = 16'd0;               // the row's first burst: cy * 72
    reg  [25:0] lw = 26'd0;                 // the burst's SDRAM word (8-aligned)
    reg  signed [17:0] fsh = 18'sd0;        // the font: 16 * ln - x0
    reg  [15:0] prot = 16'h0;               // the pattern's row, turned by its x alignment

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
    reg         wsent = 1'b0;               // the burst is asked for

    // a span from a generator: its row and ends, unclipped; the generator is done
    reg  signed [21:0] sp_y = 22'sd0, sp_x0 = 22'sd0, sp_x1 = 22'sd0;
    reg         gdone = 1'b0;

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

    // The pattern: the row for line cy, turned left by the x alignment, so
    // that byte b of every burst (x = 16L + b) takes bit 15 - b.
    wire [3:0]   prw  = 4'(cy[3:0] + pattalign[3:0]);
    wire [31:0]  pwd  = pattern[255 - 32 * prw[3:1] -: 32];
    wire [15:0]  prow = prw[0] ? pwd[15:0] : pwd[31:16];
    wire [31:0]  prr  = {prow, prow} << pattalign[7:4];
    reg  [127:0] s_pat;
    always @(*)
        for (int b = 0; b < 16; b++)
            s_pat[8 * b +: 8] = {8{s_patt ? prot[15 - b] : s_draw}};

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

    // the burst's byte selects, as the SDRAM has it (byte b at {b[3:2], ~b[1:0]})
    reg  [15:0]  en_l;
    always @(*)
        for (int b = 0; b < 16; b++)
            en_l[{b[3:2], ~b[1:0]}] = en[b];

    assign lb_we = (st == E_SRC) && ge_req && ge_done;

    // ---- a span taken from a generator, clipped -------------------------------------
    wire signed [21:0] spa = lmax(sp_x0, s22'(cx0));
    wire signed [21:0] spb = lmin(sp_x1, s22'(cx1));
    wire               sp_vis = (sp_y >= s22'(cy0)) && (sp_y <= s22'(cy1)) && (spa <= spb);

    // ---- the line generator -------------------------------------------------------------
    // Drawn from its left end; x-major (|dx| >= |dy|) a run of pixels a row,
    // otherwise a pixel a row.
    wire               l_sw  = (vx1 < vx0);
    // registered, as the extents are: E_LSET comes after E_SETUP
    reg  signed [17:0] l_xa = 18'sd0, l_ya = 18'sd0, l_dx = 18'sd0, l_dy = 18'sd0;
    always @(posedge mclk) begin
        l_xa <= l_sw ? s18'(vx1) : s18'(vx0);
        l_ya <= l_sw ? s18'(vy1) : s18'(vy0);
        l_dx <= l_sw ? s18'(vx0) - s18'(vx1) : s18'(vx1) - s18'(vx0);   // >= 0
        l_dy <= l_sw ? s18'(vy0) - s18'(vy1) : s18'(vy1) - s18'(vy0);
    end
    wire signed [17:0] l_ady = (l_dy < 0) ? -l_dy : l_dy;
    wire               l_maj = (l_dx >= l_ady);

    reg  signed [21:0] lx = 22'sd0, ly = 22'sd0, le = 22'sd0, lrun = 22'sd0;
    reg  signed [17:0] ldx = 18'sd0, lady = 18'sd0, lrem = 18'sd0;
    reg                lneg = 1'b0, lmaj = 1'b0;
    wire signed [21:0] le2   = le + s22'(lmaj ? lady : ldx);
    wire               lstep = (le2 > 0) && (lrem != 0);    // the minor axis steps
    wire               lend_ = (lrem == 0);                 // the last pixel

    // ---- the polygon generator -------------------------------------------------------------
    // Edges set up one at a time (a divider for |dx| / dy), then rows: each
    // edge's x walked as Sun's code walks it.  Per edge, after set-up:
    //   step    t = err + kt; x += xs;  then  err = t + (c ? ka : kb), x += c ? xi : 0
    // where c, by the edge's kind (shallow or steep, going right or left),
    // is t <= 0 (shallow right), t > 0 (shallow left, steep right), or
    // t + ka <= 0 (steep left).
    reg  [2:0]  pi = 3'd0;                  // the vertex an edge starts at
    reg  [2:0]  pne = 3'd0;                 // edges made
    reg  signed [21:0] pymin = 22'sd0, pymax = 22'sd0, py = 22'sd0;
    reg  signed [21:0] e_y0 [0:3];
    reg  signed [21:0] e_y1 [0:3];
    reg  signed [21:0] e_x  [0:3];
    reg  signed [21:0] e_er [0:3];
    reg  signed [21:0] e_kt [0:3];
    reg  signed [21:0] e_ka [0:3];
    reg  signed [21:0] e_kb [0:3];
    reg  signed [21:0] e_xs [0:3];
    reg  [1:0]  e_kd [0:3];                 // 0 shallow right, 1 shallow left, 2 steep right, 3 steep left
    reg  signed [21:0] e_t  [0:3];
    reg  [3:0]  e_go = 4'h0;                // stepping on this row
    initial for (int i = 0; i < 4; i++) begin
        e_y0[i] = 0; e_y1[i] = 0; e_x[i] = 0; e_er[i] = 0; e_kt[i] = 0;
        e_ka[i] = 0; e_kb[i] = 0; e_xs[i] = 0; e_kd[i] = 0; e_t[i] = 0;
    end
    // one edge's set-up
    reg  signed [21:0] p_xa = 22'sd0, p_ya = 22'sd0, p_yb = 22'sd0, p_dx = 22'sd0, p_dy = 22'sd0;
    reg  signed [21:0] p_e = 22'sd0, p_xadj = 22'sd0;
    reg  [17:0] dv_q = 18'd0, dv_r = 18'd0, dv_n = 18'd0;   // |dx| / dy: quotient, remainder, dividend
    reg  [4:0]  dv_i = 5'd0;
    // the vertices, by number
    wire signed [15:0] pvx [0:3];
    wire signed [15:0] pvy [0:3];
    assign pvx[0] = vx0; assign pvx[1] = vx1; assign pvx[2] = vx2; assign pvx[3] = vx3;
    assign pvy[0] = vy0; assign pvy[1] = vy1; assign pvy[2] = vy2; assign pvy[3] = vy3;
    wire [2:0]  pj    = (pi + 3'd1 == vk) ? 3'd0 : pi + 3'd1;
    wire signed [21:0] pa_x = s22'(pvx[pi[1:0]]), pa_y = s22'(pvy[pi[1:0]]);
    wire signed [21:0] pb_x = s22'(pvx[pj[1:0]]), pb_y = s22'(pvy[pj[1:0]]);
    wire [17:0] dv_rs = {dv_r[16:0], dv_n[17]};             // the divider's next partial remainder
    wire        dv_ge = (dv_rs >= 18'(p_dy));
    // the edge's numbers once divided
    wire signed [21:0] p_adx = (p_dx < 0) ? -p_dx : p_dx;
    wire signed [21:0] p_q   = s22'({1'b0, dv_q});
    wire signed [21:0] p_qdy = p_adx - s22'({1'b0, dv_r});  // q * dy
    wire signed [21:0] p_dys = (p_dx < 0) ? -p_qdy : p_qdy; // step * dy
    wire signed [21:0] p_qh  = (p_qdy - (dv_q[0] ? p_dy : 22'sd0)) >>> 1;   // (q >> 1) * dy
    wire               p_neg = (p_dx < 0);
    wire               p_stp = (p_dy >= p_adx);             // steep
    // a row: which edges are on it, their x, sorted (the ones off it last)
    localparam signed [21:0] XMAX = 22'sh1FFFFF;
    reg  signed [21:0] k0 = 0, k1 = 0, k2 = 0, k3 = 0;
    reg  [2:0]  pna = 3'd0;                 // edges on the row
    reg  [1:0]  psp = 2'd0;                 // 0 the first span next, 1 the second, 2 stepping

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
                gdone <= 1'b0;
                if (cmd == C_LINE)
                    st <= E_LSET;
                else if (cmd == C_POLY)
                    st <= E_PSET;
                else if (!e_ok || e_xa > e_xb || e_ya > e_yb) begin
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
                prot <= prr[31:16];
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
                         rev16(ln[0] ? xmask[15:0] : xmask[31:16]);
                sb    <= (cmd == C_FONT) ? s_font : s_pat;
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
                wsent <= 1'b0;
                st    <= E_WR;
            end

            E_WR:                           // the burst, its bytes selected
                if (!ge_req && !wsent) begin
                    ge_req   <= 1'b1;
                    ge_we    <= 1'b1;
                    ge_word  <= lw;
                    ge_wdata <= res;
                    ge_sel   <= en_l;
                    wsent    <= 1'b1;
                end else if (ge_req && ge_done)
                    st <= E_NEXT;

            E_NEXT:                         // the next burst, row, span, or the end
                if (last) begin
                    done_tgl <= ~done_tgl;
                    last     <= 1'b0;
                    st       <= E_IDLE;
                end else if (ln != lend) begin
                    ln   <= ln + 7'd1;
                    bidx <= bidx + 7'd1;
                    fsh  <= fsh + 18'sd16;
                    st   <= E_LINE;
                end else if (gen)
                    st <= E_GRET;
                else if (cy == yend)
                    last <= 1'b1;
                else begin
                    cy <= up ? cy - 10'd1 : cy + 10'd1;
                    st <= E_ROW;
                end

            // ---- a span from a generator: clipped, then drawn as a row
            E_SPAN:
                if (sp_vis) begin
                    cy <= 10'(sp_y);
                    xa <= 11'(spa);
                    xb <= 11'(spb);
                    st <= E_ROW;
                end else
                    st <= E_GRET;

            E_GRET:                         // back to the generator, or the end
                if (gdone) begin
                    last <= 1'b1;
                    st   <= E_NEXT;
                end else
                    st <= (cmd == C_LINE) ? E_LGEN : E_PNEXT;

            // ---- a line
            E_LSET: begin
                lx   <= s22'(l_xa);
                ly   <= s22'(l_ya);
                lrun <= s22'(l_xa);
                ldx  <= l_dx;
                lady <= l_ady;
                lneg <= (l_dy < 0);
                lmaj <= l_maj;
                le   <= 22'sd0 - s22'((l_maj ? l_dx : l_ady) >>> 1);
                lrem <= l_maj ? l_dx : l_ady;
                st   <= E_LGEN;
            end

            E_LGEN: begin                   // a pixel a clock; a span when the row changes
                lrem <= lrem - 18'sd1;
                gdone <= lend_;
                if (lmaj) begin
                    lx <= lx + 22'sd1;
                    le <= lstep ? le2 - s22'(ldx) : le2;
                    if (lstep) ly <= lneg ? ly - 22'sd1 : ly + 22'sd1;
                    if (lstep || lend_) begin
                        sp_y  <= ly;
                        sp_x0 <= lrun;
                        sp_x1 <= lx;
                        lrun  <= lx + 22'sd1;
                        st    <= E_SPAN;
                    end
                end else begin
                    ly <= lneg ? ly - 22'sd1 : ly + 22'sd1;
                    le <= lstep ? le2 - s22'(lady) : le2;
                    if (lstep) lx <= lx + 22'sd1;
                    sp_y  <= ly;
                    sp_x0 <= lx;
                    sp_x1 <= lx;
                    st    <= E_SPAN;
                end
            end

            // ---- a polygon: its edges
            E_PSET: begin
                pi    <= 3'd0;
                pne   <= 3'd0;
                pymin <= 22'sh1FFFFF;
                pymax <= -22'sh200000;
                st    <= E_PE0;
            end

            E_PE0:                          // the edge from vertex pi to the next
                if (pi == vk)
                    st <= E_PROW0;
                else if (pa_y == pb_y)
                    pi <= pi + 3'd1;            // horizontal: no edge
                else begin
                    p_xa <= (pa_y > pb_y) ? pb_x : pa_x;
                    p_ya <= (pa_y > pb_y) ? pb_y : pa_y;
                    p_yb <= (pa_y > pb_y) ? pa_y : pb_y;
                    p_dx <= (pa_y > pb_y) ? pa_x - pb_x : pb_x - pa_x;
                    p_dy <= (pa_y > pb_y) ? pa_y - pb_y : pb_y - pa_y;
                    dv_n <= 18'((pa_y > pb_y) ? ((pa_x - pb_x < 0) ? pb_x - pa_x : pa_x - pb_x)
                                              : ((pb_x - pa_x < 0) ? pa_x - pb_x : pb_x - pa_x));
                    dv_q <= 18'd0;
                    dv_r <= 18'd0;
                    dv_i <= 5'd18;
                    st   <= E_PDIV;
                end

            E_PDIV: begin                   // |dx| / dy, a bit a clock
                dv_n <= {dv_n[16:0], 1'b0};
                dv_r <= dv_ge ? dv_rs - 18'(p_dy) : dv_rs;
                dv_q <= {dv_q[16:0], dv_ge};
                dv_i <= dv_i - 5'd1;
                if (dv_i == 5'd1) st <= E_PE1;
            end

            E_PE1: begin
                p_e    <= p_qh - (p_adx >>> 1);
                st     <= E_PE2;
            end

            E_PE2: begin                    // the half step in, rounded Sun's way
                p_xadj <= (p_e <= 0) ? (p_neg ? -22'sd1 : 22'sd1) : 22'sd0;
                p_e    <= (p_e <= 0) ? p_e + p_dy : p_e;
                st     <= E_PE3;
            end

            E_PE3: begin                    // the edge, made
                e_y0[pne[1:0]] <= p_ya;
                e_y1[pne[1:0]] <= p_yb;
                if (p_stp) begin
                    e_x[pne[1:0]]  <= p_xa;
                    e_er[pne[1:0]] <= -(p_dy >>> 1);
                    e_kt[pne[1:0]] <= p_dx;
                    e_ka[pne[1:0]] <= p_neg ? p_dy : -p_dy;
                    e_kb[pne[1:0]] <= 22'sd0;
                    e_xs[pne[1:0]] <= 22'sd0;
                    e_kd[pne[1:0]] <= p_neg ? 2'd3 : 2'd2;
                end else if (!p_neg) begin
                    e_x[pne[1:0]]  <= p_xa + p_xadj + (p_q >>> 1);
                    e_er[pne[1:0]] <= p_e - p_dx;
                    e_kt[pne[1:0]] <= p_dys;
                    e_ka[pne[1:0]] <= p_dy - p_dx;
                    e_kb[pne[1:0]] <= -p_dx;
                    e_xs[pne[1:0]] <= p_q;
                    e_kd[pne[1:0]] <= 2'd0;
                end else begin
                    e_x[pne[1:0]]  <= p_xa + p_xadj + ((22'sd1 - p_q) >>> 1) + 22'sd1;
                    e_er[pne[1:0]] <= p_dys - p_e + s22'({21'd0, p_dy[0]});
                    e_kt[pne[1:0]] <= p_adx;
                    e_ka[pne[1:0]] <= p_dys - p_dy;
                    e_kb[pne[1:0]] <= p_dys;
                    e_xs[pne[1:0]] <= -p_q;
                    e_kd[pne[1:0]] <= 2'd1;
                end
                pymin <= lmin(pymin, p_ya);
                pymax <= lmax(pymax, p_yb);
                pne   <= pne + 3'd1;
                pi    <= pi + 3'd1;
                st    <= E_PE0;
            end

            // ---- a polygon: its rows
            E_PROW0: begin
                py  <= pymin;
                psp <= 2'd0;
                if (pne == 3'd0 || pymin >= pymax) begin
                    last <= 1'b1;
                    st   <= E_NEXT;
                end else
                    st <= E_PROW;
            end

            E_PROW: begin                   // the edges on this row, and their x
                logic [2:0] n;
                n = 3'd0;
                for (int i = 0; i < 4; i++) begin
                    logic on;
                    on = (3'(i) < pne) && (py >= e_y0[i]) && (py < e_y1[i]);
                    n = n + {2'd0, on};
                    e_go[i] <= (3'(i) < pne) && (py >= e_y0[i]) && (py + 22'sd1 < e_y1[i]);
                    case (i)
                        0: k0 <= on ? e_x[0] : XMAX;
                        1: k1 <= on ? e_x[1] : XMAX;
                        2: k2 <= on ? e_x[2] : XMAX;
                        default: k3 <= on ? e_x[3] : XMAX;
                    endcase
                end
                pna <= n;
                st  <= E_PS1;
            end

            E_PS1: begin                    // sorted: (0,1) (2,3), (0,2) (1,3), (1,2)
                if (k0 > k1) begin k0 <= k1; k1 <= k0; end
                if (k2 > k3) begin k2 <= k3; k3 <= k2; end
                st <= E_PS2;
            end
            E_PS2: begin
                if (k0 > k2) begin k0 <= k2; k2 <= k0; end
                if (k1 > k3) begin k1 <= k3; k3 <= k1; end
                st <= E_PS3;
            end
            E_PS3: begin
                if (k1 > k2) begin k1 <= k2; k2 <= k1; end
                st <= E_PNEXT;
            end

            E_PNEXT:                        // the row's spans, then the edges step
                case (psp)
                    2'd0: begin
                        psp <= 2'd1;
                        if (pna >= 3'd2 && k1 > k0) begin
                            sp_y  <= py;
                            sp_x0 <= k0;
                            sp_x1 <= k1 - 22'sd1;
                            st    <= E_SPAN;
                        end
                    end
                    2'd1: begin
                        psp <= 2'd2;
                        if (pna == 3'd4 && k3 > k2) begin
                            sp_y  <= py;
                            sp_x0 <= k2;
                            sp_x1 <= k3 - 22'sd1;
                            st    <= E_SPAN;
                        end
                    end
                    default:
                        st <= E_PST1;
                endcase

            E_PST1: begin                   // each edge on to the next row: t, and x by its step
                for (int i = 0; i < 4; i++) begin
                    e_t[i] <= e_er[i] + e_kt[i];
                    if (e_go[i]) e_x[i] <= e_x[i] + e_xs[i];
                end
                st <= E_PST2;
            end

            E_PST2: begin                   // ... and the correction
                for (int i = 0; i < 4; i++)
                    if (e_go[i]) begin
                        logic c;
                        case (e_kd[i])
                            2'd0:    c = (e_t[i] <= 0);
                            2'd3:    c = (e_t[i] + e_ka[i] <= 0);
                            default: c = (e_t[i] > 0);
                        endcase
                        e_er[i] <= e_t[i] + (c ? e_ka[i] : e_kb[i]);
                        if (c) e_x[i] <= e_x[i] + ((e_kd[i][0]) ? -22'sd1 : 22'sd1);
                    end
                py  <= py + 22'sd1;
                psp <= 2'd0;
                if (py + 22'sd1 >= pymax) begin
                    last <= 1'b1;
                    st   <= E_NEXT;
                end else
                    st <= E_PROW;
            end

            default: st <= E_IDLE;
        endcase
    end

endmodule
