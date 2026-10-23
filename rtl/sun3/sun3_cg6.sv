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
// in SDRAM and the scan-out (sun3_cg4_scanout.sv, colour only).  The rest
// is here:
//
//   0xFF300000  FHC: the P4 ID 0x60 (1152x900) in bits 31:24, revision 1,
//               19:0 stored
//   0xFF301000  THC: misc (0x818): vsync follows the raster, the retrace
//               interrupt pending and enabled; the timing and the cursor
//               (0x800..0x9FC) are a later stage's and read 0
//   0xFF700000  FBC: the drawing engine's registers
//   0xFF701000  TEC: writes ignored, reads 0 (a later stage stores it)
//   the ROM (0xFF380000), the DHC and the ALT: read 0
//
// **The FBC** (docs/cg6.md, "The FBC"): every register software sets reads
// back what was written, MISC's and RASTEROP's 2-bit fields keep their value
// when written 0, and the indexed vertex registers queue vertices (a vertex
// is complete when both its x and y are written; absolute ones get the raster
// offset, relative ones the last vertex; each lands in x0/y0..x3/y3 too).
// Stage 1 draws rectangles and points; a line, triangle or quadrilateral is
// queued as the model queues it and draws nothing.  z, the colour vertex
// registers, the pattern and the indexed registers' own values are not kept
// (they read 0).
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

    // ---- the engine, on the memory's clock ---------------------------------------
    input  wire         mclk,
    input  wire         mem_idle,       // the memory bridge has no CPU write queued
    output wire [25:0]  ge_word,
    output wire         ge_req,
    output wire         ge_we,
    output wire [31:0]  ge_wdata,
    output wire [3:0]   ge_sel,
    input  wire         ge_done,
    input  wire [127:0] ge_rdata
);

    localparam [7:0] P4_ID   = 8'h60;   // the GX at 1152x900
    localparam [3:0] FHC_REV = 4'h1;    // libpixrect: 0 takes the vector workaround

    localparam [2:0] P_POINT = 3'd0, P_LINE = 3'd1, P_TRI = 3'd2, P_QUAD = 3'd3,
                     P_RECT = 3'd4, P_NONE = 3'd5;
    localparam [1:0] C_RECT = 2'd0, C_BLIT = 2'd1, C_FONT = 2'd2;

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
    initial for (int i = 0; i < 4; i++) begin xr[i] = 32'h0; yr[i] = 32'h0; end

    // the vertex queue: its primitive, how many, the last two, a vertex begun
    reg  [2:0]  prim = P_NONE;
    reg  [6:0]  nv = 7'd0;              // 0..64
    reg  [31:0] va_x = 32'h0, va_y = 32'h0, vb_x = 32'h0, vb_y = 32'h0;
    reg  [1:0]  pend = 2'b00;           // [0] x, [1] y written
    reg  [31:0] pend_x = 32'h0, pend_y = 32'h0;

    // the THC: misc's stored bits (reset 12, video 10, sync enable 7, cursor
    // resolution 6, interrupt enable 5, cycles 3:0) and the interrupt pending
    reg  [12:0] thc_misc = 13'h0;
    reg         thc_pend = 1'b0;
    assign irq      = thc_pend & thc_misc[5];
    assign video_on = thc_misc[10];

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
    reg  [1:0]  cmd = C_RECT;

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
    reg         held  = 1'b0;           // a cycle waiting for the engine
    wire        cmdrd = sel_fbc & rw_n & (off == 12'h014 || off == 12'h018);
    wire        stall = sel_fbc & ~cmdrd & (off != 12'h010);
    wire        now   = (sel & ~go_q) | held;

    // a vertex register: its group, and the coordinate's sum (one adder: the
    // raster offset for an absolute one, the last vertex for a relative one)
    wire [2:0]  vgrp   = off[8:6];
    wire        vis    = sel_fbc & ~rw_n & off[11] & (off[10:9] == 2'b00) & (vgrp <= P_RECT);
    wire        newq   = (prim != vgrp) & ~(prim == P_POINT & (vgrp == P_TRI | vgrp == P_QUAD));
    wire [6:0]  nv_v   = newq ? 7'd0 : nv;
    wire [1:0]  pend_v = (prim != vgrp) ? 2'b00 : pend;
    wire        vrel   = off[4];
    wire        vy     = off[2];
    wire        vcoord = (off[5:0] == 6'h00) | (off[5:0] == 6'h04) | (off[5:0] == 6'h10) | (off[5:0] == 6'h14);
    wire [31:0] vbase  = vy ? (vrel ? ((nv_v != 0) ? vb_y : yr[0]) : offy)
                            : (vrel ? ((nv_v != 0) ? vb_x : xr[0]) : offx);
    wire [31:0] vsum   = wdata + vbase;
    wire [1:0]  pend_n = pend_v | (vy ? 2'b10 : 2'b01);
    wire [31:0] cx_n   = vy ? pend_x : vsum;
    wire [31:0] cy_n   = vy ? vsum : pend_y;

    // FBC reads
    reg  [31:0] fbc_q;
    always @(*) begin
        fbc_q = 32'h0;
        if (off[11:6] == 6'b000010) begin                   // 0x080..0x0BC
            if (off[3:2] == 2'd0) fbc_q = xr[off[5:4]];
            else if (off[3:2] == 2'd1) fbc_q = yr[off[5:4]];
        end else case (off)
            12'h000: fbc_q = {P4_ID, FHC_REV, fhc};
            12'h004: fbc_q = {10'h0, misc};
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
        if (trace && !rst && now && !(stall && ebusy))
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
            start_tgl <= 1'b0;
            start_out <= 1'b0;
            busy_q    <= 1'b0;
            fhc       <= 20'h0;
            misc      <= 22'h0;
            clipcheck <= 32'h0;
            font      <= 32'h0;
            for (int i = 0; i < 4; i++) begin xr[i] <= 32'h0; yr[i] <= 32'h0; end
            offx <= 32'h0; offy <= 32'h0; incx <= 32'h0; incy <= 32'h0;
            clipminx <= 32'h0; clipminy <= 32'h0; clipmaxx <= 32'd1151; clipmaxy <= 32'd899;
            fcolor <= 32'h0; bcolor <= 32'h0; rasterop <= 32'h0;
            planemask <= 32'hFF; pixelmask <= 32'hFFFFFFFF; pattalign <= 32'h0;
            prim      <= P_NONE;
            nv        <= 7'd0;
            pend      <= 2'b00;
            thc_misc  <= 13'h0;
            thc_pend  <= 1'b0;
        end else if (now) begin
            if (stall && ebusy)
                held <= 1'b1;                       // until the engine is done
            else begin
                held <= 1'b0;
                ack  <= 1'b1;
                rdata <= 32'h0;
                if (sel_fhc) begin
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
                    end
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
                                if ((prim == P_RECT && nv >= 7'd2) || (prim == P_POINT && nv >= 7'd1)) begin
                                    cmd       <= C_RECT;
                                    start_tgl <= ~start_tgl;
                                end
                                if (prim == P_POINT) begin  // a point is a rectangle of one
                                    va_x <= vb_x;
                                    va_y <= vb_y;
                                end
                                // a line keeps its end vertex queued; the rest start afresh
                                if (prim == P_LINE && nv >= 7'd2)
                                    nv <= 7'd1;
                                else begin
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
                    end else if (vis) begin
                        prim <= vgrp;
                        nv   <= nv_v;
                        pend <= pend_v;
                        if (vcoord) begin
                            if (pend_n == 2'b11) begin
                                pend <= 2'b00;
                                if (nv_v < 7'd64) begin
                                    va_x <= vb_x;
                                    va_y <= vb_y;
                                    vb_x <= cx_n;
                                    vb_y <= cy_n;
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
    end

    // ---- the engine -----------------------------------------------------------------------
    // Its inputs are these registers, which do not change while it is busy.
    // A rectangle is the queue's last two vertices (a point's twice); a blit
    // and the font take x0..x2, y0..y2.
    wire rect = (cmd == C_RECT);

    sun3_cg6_engine #(.COLOR_WORD(COLOR_WORD)) engine (
        .mclk      (mclk),
        .rst       (rst),
        .start_tgl (start_out),
        .done_tgl  (done_tgl),
        .mem_idle  (mem_idle),
        .cmd       (cmd),
        .x0        (sat16(rect ? va_x : xr[0])),
        .y0        (sat16(rect ? va_y : yr[0])),
        .x1        (sat16(rect ? vb_x : xr[1])),
        .y1        (sat16(rect ? vb_y : yr[1])),
        .x2        (sat16(xr[2])),
        .y2        (sat16(yr[2])),
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
        .ge_word   (ge_word),
        .ge_req    (ge_req),
        .ge_we     (ge_we),
        .ge_wdata  (ge_wdata),
        .ge_sel    (ge_sel),
        .ge_done   (ge_done),
        .ge_rdata  (ge_rdata)
    );

endmodule
