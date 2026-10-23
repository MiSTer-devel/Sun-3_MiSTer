`timescale 1ns / 1ps

`include "sun3_attr.vh"
//
// sun3_cg6.sv -- the GX (cg6, "lego") on the P4: its registers, on the CPU's
// clock, and its drawing engine (sun3_cg6_engine.sv) on the memory's.
//
// docs/cg6.md is the specification, from Sun's code; tools/cg6model/ is that
// specification as a C model, checked against Sun's libpixrect, and
// tb/verilator/tb_cg6.sv replays the model's traces into this.  The GX shares
// the P4 slot with the cg4 (one or the other, chosen in reset), and with it
// the Bt458 (sun3_cg4.sv, its byte on D31:24: sun3_fpga.v), the colour plane
// in SDRAM and the scan-out (sun3_cg4_scanout.sv, colour only, with this
// board's cursor).  The rest is here:
//
//   0xFF300000  FHC: the P4 ID 0x60 (1152x900) in bits 31:24, revision 1,
//               19:0 stored
//   0xFF301000  THC: the timing (0x800..0x814) stored; misc (0x818): vsync
//               follows the raster, the retrace interrupt pending and
//               enabled; the cursor's place (0x8FC) and its two 32x32 planes
//               (0x900..0x9FC), to the scan-out
//   0xFF700000  FBC: the drawing engine's registers
//   0xFF701000  TEC: the transform engine (sun3_cg6_tec.sv): its data
//               registers converted by VDC's type, its vertex registers
//               through the MV matrix and, with autoload, on into the FBC's
//               queue, COMMAND1's matrix product; the second bank (below)
//   the ROM (0xFF380000), the DHC and the ALT: read 0
//
// **The FBC** (docs/cg6.md, "The FBC"): every register software sets reads
// back what was written, MISC's and RASTEROP's 2-bit fields keep their value
// when written 0, and the indexed vertex registers queue vertices (a vertex
// is complete when both its x and y are written; absolute ones get the raster
// offset, relative ones the last vertex; each lands in x0/y0..x3/y3 too, and
// in a ring of the last four, which the queue's primitive draws from).  A
// DRAWSTATUS read draws the queue's point, line, rectangle, triangle or
// quadrilateral.  z, the colour vertex registers and the indexed registers
// read back what was written to them, from the register store.  MISC's
// index (5:4) reads the queue's next slot (xnews reads the vertex before it
// back from x0/y0..x3/y3).
//
// **The register store** is an M10K of 1,024 words for everything that is
// only stored: z and colour (FBC 0x088.., 0x08C..), the indexed registers
// (FBC 0x800..0x93C), the THC's timing and cursor planes, and the TEC.  Its
// reads take a clock more.  The TEC's 64 data registers (0x100..0x1FC) have a
// second bank, used while VDC's type (bits 15:13) is 5: the kernel's
// cg6_cntxsave reads them with VDC 0x8000 and again with 0xA000 (types 4 and
// 5, Solaris's INTRNL0 and INTRNL1) and cg6_cntxrestore writes both back.
// The first bank is the TEC's own, read through it.
//
// **The TEC** is given every TEC write, and the first bank's reads.  While
// it is busy every TEC and FBC cycle waits (a read until its value is
// there); a write is answered at once.  TEC cycles wait for the engine as
// FBC writes do, so an autoloaded vertex lands while nothing else moves.
//
// **Commands.**  A DRAWSTATUS or BLITSTATUS read, or a FONT write, starts the
// engine; `busy' is from then until it answers.  While it is busy:
//   * DRAWSTATUS and BLITSTATUS read EXCEPTION | FULL | BUSY, and start
//     nothing: Sun's code reads again;
//   * STATUS reads BUSY | FULL;
//   * every other FBC cycle waits (DSACK held) until it is not -- so the
//     engine reads the registers as they are, and a FONT write waits for the
//     one before it.  The font's autoincrement is applied when it answers.
// sun3_fpga.v leaves these cycles out of its bus timeout.
//
// **The cursor** (docs/cg6.md, "The THC"): the scan-out reads a row of both
// planes (cur_row, on the pixel clock, answered the clock after) and the
// place (cur_xy: x in 31:16, y in 15:0, signed), and shows Bt458 overlay
// colour {B, A} where either bit is set.
//
module sun3_cg6 #(
    parameter bit [25:0] COLOR_WORD = 26'h0C80000      // the frame buffer in SDRAM (the cg4's colour plane)
) (
    input  wire         clk,
    input  wire         rst,            // INIT-

    // ---- the CPU's side: a select per block, a level for the whole cycle --------
    input  wire         sel_fhc,
    input  wire         sel_thc,
    input  wire         sel_fbc,
    input  wire         sel_tec,
    input  wire         sel_nul,        // the ROM, the DHC, the ALT
    input  wire         rw_n,
    input  wire [11:2]  adr,            // the register's offset in its 4 KiB
    input  wire [31:0]  wdata,          // a byte or word written is on every lane
    output reg  [31:0]  rdata = 32'h0,
    output reg          ack   = 1'b0,   // one clock
    output wire         irq,            // V.INTY-, the P4's interrupt: the THC's
    input  wire         retrace,        // vertical blank, the pixel clock's
    output wire         video_on,

    // ---- the cursor, for the scan-out (the pixel clock) ---------------------------
    input  wire         pclk,
    input  wire [4:0]   cur_row,
    output reg  [31:0]  cur_a = 32'h0,  // plane A's row, the clock after
    output reg  [31:0]  cur_b = 32'h0,  // plane B's
    output wire [31:0]  cur_xy,         // a level: changes only when written

    // ---- the engine, on the memory's clock ---------------------------------------
    input  wire         mclk,
    input  wire         mem_idle,       // the memory bridge has no CPU write queued
    output wire [25:0]  ge_word,
    output wire         ge_req,
    output wire         ge_we,
    output wire [127:0] ge_wdata,
    output wire [15:0]  ge_sel,
    input  wire         ge_done,
    input  wire [127:0] ge_rdata
);

    localparam [7:0] P4_ID   = 8'h60;   // the GX at 1152x900
    localparam [3:0] FHC_REV = 4'h1;    // libpixrect: 0 takes the vector workaround

    localparam [2:0] P_POINT = 3'd0, P_LINE = 3'd1, P_TRI = 3'd2, P_QUAD = 3'd3,
                     P_RECT = 3'd4, P_NONE = 3'd5;
    localparam [2:0] C_RECT = 3'd0, C_BLIT = 3'd1, C_FONT = 3'd2, C_LINE = 3'd3, C_POLY = 3'd4;

    // ---- the registers --------------------------------------------------------------
    reg  [19:0] fhc = 20'h0;
    reg  [21:0] misc = 22'h0;
    reg  [31:0] clipcheck = 32'h0, font = 32'h0;
    reg  [31:0] xr [0:3];
    reg  [31:0] yr [0:3];
    reg  [31:0] offx = 32'h0, offy = 32'h0, incx = 32'h0, incy = 32'h0;
    reg  [31:0] clipminx = 32'h0, clipminy = 32'h0, clipmaxx = 32'd1151, clipmaxy = 32'd899;
    reg  [31:0] fcolor = 32'h0, bcolor = 32'h0, rasterop = 32'h0;
    reg  [31:0] planemask = 32'hFF, pixelmask = 32'hFFFFFFFF, pattalign = 32'h0;
    reg  [31:0] pattern [0:7];
    initial for (int i = 0; i < 4; i++) begin xr[i] = 32'h0; yr[i] = 32'h0; end
    initial for (int i = 0; i < 8; i++) pattern[i] = 32'h0;

    // the vertex queue: its primitive, how many, the last four (a ring, the
    // vertex k at k mod 4), a vertex begun
    reg  [2:0]  prim = P_NONE;
    reg  [6:0]  nv = 7'd0;              // 0..64
    reg  [31:0] qx [0:3];
    reg  [31:0] qy [0:3];
    initial for (int i = 0; i < 4; i++) begin qx[i] = 32'h0; qy[i] = 32'h0; end
    reg  [1:0]  pend = 2'b00;           // [0] x, [1] y written
    reg  [31:0] pend_x = 32'h0, pend_y = 32'h0;

    // what a drawing command draws: its vertices, saturated, in order, and how
    // many (a polygon's 2..4; a rectangle's or line's 2; a point's twice)
    reg  signed [15:0] ex [0:3];
    reg  signed [15:0] ey [0:3];
    reg  [2:0]  ek = 3'd0;
    initial for (int i = 0; i < 4; i++) begin ex[i] = 16'sh0; ey[i] = 16'sh0; end

    // the THC: misc's stored bits (reset 12, video 10, sync enable 7, cursor
    // resolution 6, interrupt enable 5, cycles 3:0) and the interrupt pending
    reg  [12:0] thc_misc = 13'h0;
    reg         thc_pend = 1'b0;
    reg  [31:0] thc_curxy = 32'h0;
    assign irq      = thc_pend & thc_misc[5];
    assign video_on = thc_misc[10];
    assign cur_xy   = thc_curxy;

    // the TEC's VDC type, which picks the data registers' bank
    reg  [2:0]  tec_vdc = 3'd0;

    // the vertical blank, into this clock
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg  [2:0]  rt_s = 3'b000;
    always @(posedge clk) rt_s <= {rt_s[1:0], retrace};
    wire rt_now  = rt_s[1];
    wire rt_rise = rt_s[1] & ~rt_s[2];

    // ---- the engine's handshake ---------------------------------------------------------
    reg         start_tgl = 1'b0, start_out = 1'b0;     // start_out a clock later
    wire        done_tgl;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg  [1:0]  done_s = 2'b00;
    always @(posedge clk) done_s <= {done_s[0], done_tgl};
    wire        busy = start_tgl ^ done_s[1];
    reg         busy_q = 1'b0;
    wire        ebusy = busy | busy_q;  // and the clock its answer is taken in
    reg  [2:0]  cmd = C_RECT;

    // ---- the 2-bit fields that keep their value when written 0 ------------------------
    function automatic [31:0] keep0(input [31:0] old, input [31:0] v, input [31:0] fields);
        keep0 = v;
        for (int sh = 0; sh < 31; sh++)
            if (fields[sh] && v[sh +: 2] == 2'b00) keep0[sh +: 2] = old[sh +: 2];
    endfunction
    localparam [31:0] MISC_FIELDS = 32'h0012AA80;   // 21:20 18:17 16:15 14:13 12:11 10:9 8:7
    localparam [31:0] ROP_FIELDS  = 32'h55400000;   // 31:30 29:28 27:26 25:24 23:22

    function automatic signed [15:0] sat16(input [31:0] v);
        sat16 = (v[31:15] == 17'h00000 || v[31:15] == 17'h1FFFF) ? v[15:0] :
                v[31] ? 16'sh8000 : 16'sh7FFF;
    endfunction

    // ---- the CPU's cycle ------------------------------------------------------------------
    wire [11:0] off   = {adr, 2'b00};
    wire        sel   = sel_fhc | sel_thc | sel_fbc | sel_tec | sel_nul;
    reg         go_q  = 1'b0;
    reg         held  = 1'b0;           // a cycle waiting for the engine, or the store
    reg         srd   = 1'b0;           // ... the store's word is there
    wire        cmdrd = sel_fbc & rw_n & (off == 12'h014 || off == 12'h018);
    wire        stall = (sel_fbc & ~cmdrd & (off != 12'h010)) | sel_tec;
    wire        now   = (sel & ~go_q) | held;

    // the TEC: its busy holds TEC and FBC cycles; a first-bank read waits for it
    wire        tec_busy, tec_av;
    wire [31:0] tec_q, tec_ax, tec_ay;
    wire [2:0]  tec_agrp;
    reg         tec_rdw = 1'b0;         // a read the TEC is answering
    wire        tstall = (sel_fbc | sel_tec) & tec_busy;
    wire        tec_rd = sel_tec & rw_n & (off[11:8] == 4'h1) & (tec_vdc != 3'd5);

    // ---- the register store ---------------------------------------------------------------
    // FBC z and colour (0x088.., 0x08C..) and the indexed registers (0x800..0x93C);
    // THC timing (0x800..0x814) and the cursor planes (0x900..0x9FC); the TEC's
    // 0x000..0x1FC and 0x800..0xDFC.  Word index:
    //   FBC   0..255     {off[11], off[8:2]}
    //   THC   256..383   off[8:2]
    //   TEC   384..447   the data registers' second bank, off[7:2]
    //         512..895   0x800..0xDFC, off[10:2]
    //         896..1023  0x000..0x1FC, off[8:2]
    wire        st_fbc = sel_fbc & (((off[11:6] == 6'b000010) & off[3]) |
                                    ((off[11:9] == 3'b100) & (off[8:0] < 9'h140)));
    wire        st_thc = sel_thc & (((off[11:5] == 7'b1000000) & (off[4:2] <= 3'd5)) |
                                    (off[11:8] == 4'h9));
    wire        st_tec = sel_tec & ((off[11:9] == 3'b000) | (off[11] & (off[10:9] != 2'b11)));
    wire        st_hit = st_fbc | st_thc | st_tec;
    wire        tec_b1 = (tec_vdc == 3'd5) & (off[11:8] == 4'h1);
    wire [9:0]  sidx   = sel_fbc ? {2'b00, off[11], off[8:2]} :
                         sel_thc ? {3'b010, off[8:2]} :
                         off[11] ? (10'd512 + {1'b0, off[10:2]}) :
                         tec_b1  ? {4'b0110, off[7:2]} : {3'b111, off[8:2]};
    wire        take   = !rst && now && !tec_rdw && !(stall && ebusy) && !tstall && !tec_rd;  // the cycle is done now
    wire        tec_go = !rst && now && !tec_rdw && !(stall && ebusy) && !tstall && sel_tec &&
                         (tec_rd || !rw_n);
    wire        st_we  = take && !rw_n && st_hit;
    wire        st_rd  = rw_n && st_hit;

    `SUN3_RAM_BLOCK reg [31:0] store [0:1023];
    reg  [31:0] sq;
    always @(posedge clk) begin
        if (st_we) store[sidx] <= wdata;
        sq <= store[sidx];
    end

    // the cursor's planes, again, for the scan-out's clock
    reg  [31:0] cura [0:31];
    reg  [31:0] curb [0:31];
    initial for (int i = 0; i < 32; i++) begin cura[i] = 32'h0; curb[i] = 32'h0; end
    wire        cur_we = st_we && sel_thc && (off[11:8] == 4'h9);
    always @(posedge clk)
        if (cur_we) begin
            if (off[7]) curb[off[6:2]] <= wdata;
            else        cura[off[6:2]] <= wdata;
        end
    always @(posedge pclk) begin
        cur_a <= cura[cur_row];
        cur_b <= curb[cur_row];
    end

    // a vertex register: its group, and the coordinate's sum (one adder: the
    // raster offset for an absolute one, the last vertex for a relative one)
    wire [2:0]  vgrp   = off[8:6];
    wire        vis    = sel_fbc & ~rw_n & off[11] & (off[10:9] == 2'b00) & (vgrp <= P_RECT);
    wire        newq   = (prim != vgrp) & ~(prim == P_POINT & (vgrp == P_LINE | vgrp == P_TRI | vgrp == P_QUAD));
    wire [6:0]  nv_v   = newq ? 7'd0 : nv;
    wire [1:0]  pend_v = (prim != vgrp) ? 2'b00 : pend;
    wire        vrel   = off[4];
    wire        vy     = off[2];
    wire        vcoord = (off[5:0] == 6'h00) | (off[5:0] == 6'h04) | (off[5:0] == 6'h10) | (off[5:0] == 6'h14);
    wire [1:0]  vlast  = 2'(nv_v - 7'd1);
    wire [31:0] lastx  = qx[vlast];
    wire [31:0] lasty  = qy[vlast];
    wire [31:0] vbase  = vy ? (vrel ? ((nv_v != 0) ? lasty : yr[0]) : offy)
                            : (vrel ? ((nv_v != 0) ? lastx : xr[0]) : offx);
    wire [31:0] vsum   = wdata + vbase;
    wire [1:0]  pend_n = pend_v | (vy ? 2'b10 : 2'b01);
    wire [31:0] cx_n   = vy ? pend_x : vsum;
    wire [31:0] cy_n   = vy ? vsum : pend_y;
    // an autoloaded vertex's place in the queue
    wire        anewq  = (prim != tec_agrp) & ~(prim == P_POINT & (tec_agrp == P_LINE | tec_agrp == P_TRI | tec_agrp == P_QUAD));
    wire [6:0]  anv    = anewq ? 7'd0 : nv;

    // DRAWSTATUS: the queue's primitive and the vertices it draws, the last
    // k queued (a polygon of fewer, down to 2; a point's twice)
    wire [2:0]  kmax   = (prim == P_TRI) ? 3'd3 : (prim == P_QUAD) ? 3'd4 :
                         (prim == P_POINT) ? 3'd1 : 3'd2;
    wire        dpoly  = (prim == P_TRI) || (prim == P_QUAD);
    wire [2:0]  dk     = (dpoly && nv < 7'(kmax)) ? nv[2:0] : kmax;
    wire        dgo    = (prim != P_NONE) && (dpoly ? (nv >= 7'd2) : (nv >= 7'(kmax)));
    wire [1:0]  dbase  = 2'(nv - 7'(dk));       // the ring's first of them

    // FBC reads (but the store's)
    reg  [31:0] fbc_q;
    always @(*) begin
        fbc_q = 32'h0;
        if (off[11:6] == 6'b000010) begin                   // 0x080..0x0BC
            if (off[3:2] == 2'd0) fbc_q = xr[off[5:4]];
            else if (off[3:2] == 2'd1) fbc_q = yr[off[5:4]];
        end else if (off[11:5] == 7'b0001001)               // 0x120..0x13C
            fbc_q = pattern[off[4:2]];
        else case (off)
            12'h000: fbc_q = {P4_ID, FHC_REV, fhc};
            12'h004: fbc_q = {10'h0, misc[21:7], 1'b0, nv[1:0], misc[3:0]};
            12'h008: fbc_q = clipcheck;
            12'h010: fbc_q = ebusy ? 32'h30000000 : 32'h0;  // BUSY, FULL
            12'h01C: fbc_q = font;
            12'h0C0: fbc_q = offx;
            12'h0C4: fbc_q = offy;
            12'h0D0: fbc_q = incx;
            12'h0D4: fbc_q = incy;
            12'h0E0: fbc_q = clipminx;
            12'h0E4: fbc_q = clipminy;
            12'h0F0: fbc_q = clipmaxx;
            12'h0F4: fbc_q = clipmaxy;
            12'h100: fbc_q = fcolor;
            12'h104: fbc_q = bcolor;
            12'h108: fbc_q = rasterop;
            12'h10C: fbc_q = planemask;
            12'h110: fbc_q = pixelmask;
            12'h11C: fbc_q = pattalign;
            default: fbc_q = 32'h0;
        endcase
    end

`ifdef SUN3_SIM
    // +trace_cg6: every register cycle as it is done
    bit trace = 1'b0;
    initial trace = $test$plusargs("trace_cg6");
    always @(posedge clk)
        if (trace && take && !(st_rd && !srd))
            $display("[%0t] cg6: %s %s %03x data %08x%s", $time,
                     sel_fhc ? "FHC" : sel_thc ? "THC" : sel_fbc ? "FBC" : sel_tec ? "TEC" : "ROM",
                     rw_n ? "read " : "write", off, wdata, ebusy ? " (busy)" : "");
`endif

    always @(posedge clk) begin
        ack       <= 1'b0;
        go_q      <= sel;
        busy_q    <= busy;
        start_out <= start_tgl;

        if (rt_rise) thc_pend <= 1'b1;

        // the font's autoincrement, when the engine has drawn its row
        if (busy_q && !busy && cmd == C_FONT) begin
            xr[0] <= xr[0] + incx;
            xr[1] <= xr[1] + incx;
            yr[0] <= yr[0] + incy;
            yr[1] <= yr[1] + incy;
        end

        if (rst) begin
            held      <= 1'b0;
            srd       <= 1'b0;
            start_tgl <= 1'b0;
            start_out <= 1'b0;
            busy_q    <= 1'b0;
            fhc       <= 20'h0;
            misc      <= 22'h0;
            clipcheck <= 32'h0;
            font      <= 32'h0;
            for (int i = 0; i < 4; i++) begin xr[i] <= 32'h0; yr[i] <= 32'h0; end
            for (int i = 0; i < 8; i++) pattern[i] <= 32'h0;
            offx <= 32'h0; offy <= 32'h0; incx <= 32'h0; incy <= 32'h0;
            clipminx <= 32'h0; clipminy <= 32'h0; clipmaxx <= 32'd1151; clipmaxy <= 32'd899;
            fcolor <= 32'h0; bcolor <= 32'h0; rasterop <= 32'h0;
            planemask <= 32'hFF; pixelmask <= 32'hFFFFFFFF; pattalign <= 32'h0;
            prim      <= P_NONE;
            nv        <= 7'd0;
            pend      <= 2'b00;
            thc_misc  <= 13'h0;
            thc_pend  <= 1'b0;
            thc_curxy <= 32'h0;
            tec_vdc   <= 3'd0;
            tec_rdw   <= 1'b0;
        end else if (now) begin
            if (tec_rdw) begin
                if (!tec_busy) begin                // the TEC's answer
                    held    <= 1'b0;
                    tec_rdw <= 1'b0;
                    ack     <= 1'b1;
                    rdata   <= tec_q;
                end
            end else if ((stall && ebusy) || tstall)
                held <= 1'b1;                       // until the engine, or the TEC, is done
            else if (tec_rd) begin
                held    <= 1'b1;                    // tec_go: the TEC converts it
                tec_rdw <= 1'b1;
            end else if (st_rd && !srd) begin
                held <= 1'b1;                       // the store's word, a clock on
                srd  <= 1'b1;
            end else begin
                held <= 1'b0;
                srd  <= 1'b0;
                ack  <= 1'b1;
                rdata <= 32'h0;
                if (st_rd)
                    rdata <= sq;
                else if (sel_fhc) begin
                    if (off == 12'h000) begin
                        rdata <= {P4_ID, FHC_REV, fhc};
                        if (!rw_n) fhc <= wdata[19:0];
                    end
                end else if (sel_thc) begin
                    if (off == 12'h818) begin
                        rdata <= {15'h0, 1'b1, 3'b000, thc_misc[12], 1'b0, thc_misc[10], 1'b0, rt_now,
                                  thc_misc[7:5], thc_pend, thc_misc[3:0]};
                        if (!rw_n) begin
                            thc_misc <= wdata[12:0] & 13'h14EF;
                            if (wdata[4]) thc_pend <= 1'b0;     // INT written 1 clears it
                        end
                    end else if (off == 12'h8FC) begin
                        rdata <= thc_curxy;
                        if (!rw_n) thc_curxy <= wdata;
                    end
                end else if (sel_tec) begin
                    if (!rw_n && off == 12'h008) tec_vdc <= wdata[15:13];
                end else if (sel_fbc && rw_n) begin
                    rdata <= fbc_q;
                    if (cmdrd) begin
                        if (ebusy)
                            rdata <= 32'hB0000000;          // EXCEPTION | FULL | BUSY
                        else begin
                            rdata <= 32'h0;
                            if (off == 12'h018) begin       // BLITSTATUS: the blit
                                cmd       <= C_BLIT;
                                start_tgl <= ~start_tgl;
                            end else begin                  // DRAWSTATUS: the queue's primitive
                                if (dgo) begin
                                    cmd       <= (prim == P_LINE) ? C_LINE : dpoly ? C_POLY : C_RECT;
                                    start_tgl <= ~start_tgl;
                                end
                                ek <= dk;
                                for (int j = 0; j < 4; j++) begin
                                    ex[j] <= sat16(qx[2'(dbase + 2'(j))]);
                                    ey[j] <= sat16(qy[2'(dbase + 2'(j))]);
                                end
                                if (prim == P_POINT) begin  // a point is a rectangle of one
                                    ex[1] <= sat16(qx[dbase]);
                                    ey[1] <= sat16(qy[dbase]);
                                end
                                // a line keeps its end vertex queued; the rest start afresh
                                if (prim == P_LINE && nv >= 7'd2) begin
                                    nv    <= 7'd1;
                                    qx[0] <= qx[2'(nv - 7'd1)];
                                    qy[0] <= qy[2'(nv - 7'd1)];
                                end else begin
                                    nv   <= 7'd0;
                                    prim <= P_NONE;
                                end
                                pend <= 2'b00;
                            end
                        end
                    end
                end else if (sel_fbc) begin                 // FBC writes
                    if (off[11:6] == 6'b000010) begin
                        if (off[3:2] == 2'd0) xr[off[5:4]] <= wdata;
                        else if (off[3:2] == 2'd1) yr[off[5:4]] <= wdata;
                    end else if (off[11:5] == 7'b0001001) begin
                        pattern[off[4:2]] <= wdata;
                    end else if (vis) begin
                        prim <= vgrp;
                        nv   <= nv_v;
                        pend <= pend_v;
                        if (vcoord) begin
                            if (pend_n == 2'b11) begin
                                pend <= 2'b00;
                                if (nv_v < 7'd64) begin
                                    qx[nv_v[1:0]] <= cx_n;
                                    qy[nv_v[1:0]] <= cy_n;
                                    xr[nv_v[1:0]] <= cx_n;
                                    yr[nv_v[1:0]] <= cy_n;
                                    nv <= nv_v + 7'd1;
                                end
                            end else begin
                                pend <= pend_n;
                                if (vy) pend_y <= vsum; else pend_x <= vsum;
                            end
                        end
                    end else case (off)
                        12'h000: fhc       <= wdata[19:0];
                        12'h004: misc      <= 22'(keep0({10'h0, misc}, wdata, MISC_FIELDS));
                        12'h008: clipcheck <= wdata;
                        12'h01C: begin                      // a row of the font
                            font      <= wdata;
                            cmd       <= C_FONT;
                            start_tgl <= ~start_tgl;
                        end
                        12'h0C0: offx      <= wdata;
                        12'h0C4: offy      <= wdata;
                        12'h0D0: incx      <= wdata;
                        12'h0D4: incy      <= wdata;
                        12'h0E0: clipminx  <= wdata;
                        12'h0E4: clipminy  <= wdata;
                        12'h0F0: clipmaxx  <= wdata;
                        12'h0F4: clipmaxy  <= wdata;
                        12'h100: fcolor    <= wdata;
                        12'h104: bcolor    <= wdata;
                        12'h108: rasterop  <= keep0(rasterop, wdata, ROP_FIELDS);
                        12'h10C: planemask <= wdata;
                        12'h110: pixelmask <= wdata;
                        12'h11C: pattalign <= wdata;
                        default: ;
                    endcase
                end
            end
        end

        // an autoloaded vertex from the TEC: whole, absolute (the raster
        // offset added), into the queue as a CPU's would go; no FBC or TEC
        // cycle is taken meanwhile
        if (!rst && tec_av) begin
            prim <= tec_agrp;
            pend <= 2'b00;
            nv   <= anv;
            if (anv < 7'd64) begin
                qx[anv[1:0]] <= tec_ax + offx;
                qy[anv[1:0]] <= tec_ay + offy;
                xr[anv[1:0]] <= tec_ax + offx;
                yr[anv[1:0]] <= tec_ay + offy;
                nv <= anv + 7'd1;
            end
        end
    end


    sun3_cg6_tec tec (
        .clk   (clk),
        .rst   (rst),
        .go    (tec_go),
        .we    (!rw_n),
        .adr   (adr),
        .wdata (wdata),
        .busy  (tec_busy),
        .q     (tec_q),
        .av    (tec_av),
        .agrp  (tec_agrp),
        .ax    (tec_ax),
        .ay    (tec_ay)
    );

    // ---- the engine -----------------------------------------------------------------------
    // Its inputs are these registers, which do not change while it is busy.
    // A drawing command takes the vertices DRAWSTATUS chose; a blit and the
    // font take x0..x2, y0..y2.
    sun3_cg6_engine #(.COLOR_WORD(COLOR_WORD)) engine (
        .mclk      (mclk),
        .rst       (rst),
        .start_tgl (start_out),
        .done_tgl  (done_tgl),
        .mem_idle  (mem_idle),
        .cmd       (cmd),
        .x0        (sat16(xr[0])),
        .y0        (sat16(yr[0])),
        .x1        (sat16(xr[1])),
        .y1        (sat16(yr[1])),
        .x2        (sat16(xr[2])),
        .y2        (sat16(yr[2])),
        .vx0       (ex[0]), .vy0 (ey[0]),
        .vx1       (ex[1]), .vy1 (ey[1]),
        .vx2       (ex[2]), .vy2 (ey[2]),
        .vx3       (ex[3]), .vy3 (ey[3]),
        .vk        (ek),
        .clipminx  (sat16(clipminx)),
        .clipminy  (sat16(clipminy)),
        .clipmaxx  (sat16(clipmaxx)),
        .clipmaxy  (sat16(clipmaxy)),
        .font      (font),
        .colour8   (misc[18:17] == 2'd1),
        .fcolor    (fcolor[7:0]),
        .bcolor    (bcolor[7:0]),
        .rasterop  (rasterop),
        .planemask (planemask[7:0]),
        .pixelmask (pixelmask),
        .pattern   ({pattern[0], pattern[1], pattern[2], pattern[3],
                     pattern[4], pattern[5], pattern[6], pattern[7]}),
        .pattalign ({pattalign[19:16], pattalign[3:0]}),
        .ge_word   (ge_word),
        .ge_req    (ge_req),
        .ge_we     (ge_we),
        .ge_wdata  (ge_wdata),
        .ge_sel    (ge_sel),
        .ge_done   (ge_done),
        .ge_rdata  (ge_rdata)
    );

endmodule
