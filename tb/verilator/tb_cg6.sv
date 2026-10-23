//============================================================================
//  tb_cg6 -- the GX (rtl/sun3/sun3_cg6.sv and sun3_cg6_engine.sv) against
//  its C model (tools/cg6model/), with the Bt458 (sun3_cg4.sv, on D31:24 as
//  sun3_fpga.v wires it for the GX), the SDRAM adapter and controller
//  (rtl/sun3_mister_sdram.sv, rtl/sdram.sv) on sdram_model.sv, and the
//  colour-only scan-out (sun3_cg4_scanout.sv) taking its share of the SDRAM
//  all the while.
//
//  The traces (+t0= .. +t3=, each a prefix of .txt .ini .fin) are the model's:
//  every board access the PROM's console or Sun's libpixrect made of it, as
//  tools/cg6model/harness writes them (-G, -t -I -F).  The frame buffer is
//  loaded with the .ini, the trace is replayed through the CPU's side --
//  register cycles as sun3_fpga.v decodes them, frame-buffer cycles through a
//  bridge-like queue that posts writes -- and at the end every pixel of the
//  1152x900 is compared with the .fin.  On the way:
//    * DRAWSTATUS and BLITSTATUS are read again while they say FULL, as Sun's
//      code reads them, and STATUS until it is not BUSY, rather than matching
//      the model's values (its engine is instantaneous);
//    * every other register read is compared with the model's, for the
//      registers stage 1 keeps, and every frame-buffer read;
//    * the THC's vsync reads are not (the model's raster is not this one's).
//
//  Then, directed: the THC (vsync following the raster, the retrace
//  interrupt's enable, pending and clear, video on), the FHC (the P4 ID in
//  bits 31:24, kept through the P4 probe's write), the busy engine (FULL,
//  BUSY, and an FBC write held until it is done), the Bt458 as the PROM left
//  it, and one whole frame of the scan-out, every pixel through the colour
//  map, against the frame buffer.
//
//      make -C tb/verilator tb_cg6
//============================================================================
`timescale 1ps/1ps

module tb_cg6;

localparam [25:0] COLOR_WORD = 26'h0C80000;
localparam int    FBW = 1152, FBH = 900, NPIX = FBW * FBH;
localparam bit [15:0] JUNK = 16'hA55A;          // outside the frame buffer

reg clk = 0, mclk = 0, pclk = 0;
always #20000 clk  = ~clk;                      // the CPU: 25 MHz
always #5000  mclk = ~mclk;                     // the SDRAM: 100 MHz
always #6000  pclk = ~pclk;                     // the raster: 83.3 MHz
reg rst = 1, minit = 1, prst = 1, srst = 1;

// ---- the raster and the scan-out --------------------------------------------------
wire [11:0] cx;
wire [10:0] cy;
wire        de, hs, vs;
video_timing #(
    .H_ACTIVE(1160), .H_FRONT(24), .H_SYNC(128), .H_TOTAL(1472),
    .V_ACTIVE(904),  .V_FRONT(3),  .V_SYNC(4),   .V_TOTAL(937),
    .H_POSITIVE(1'b0), .V_POSITIVE(1'b0), .CXW(12), .CYW(11)
) timing (.clk(pclk), .rst(prst), .cx(cx), .cy(cy), .de(de), .hsync(hs), .vsync(vs));

wire [25:0]  cs_word;
wire         cs_req, cs_urgent, cs_done;
wire [127:0] cs_rdata;
wire [7:0]   cm_raddr, read_mask, command;
wire [23:0]  cm_rdata, ovl1, ovl2, ovl3, rgb;
wire         retrace, video_on;
wire [31:0]  cur_xy, cur_a, cur_b;
wire [4:0]   cur_row;

sun3_cg4_scanout scanout (
    .mclk(mclk), .mrst(srst), .enable(1'b1), .colour_only(1'b1),
    .c_word(cs_word), .c_req(cs_req), .c_urgent(cs_urgent), .c_done(cs_done), .c_rdata(cs_rdata),
    .clk_pixel(pclk), .pix_rst(prst), .cx(cx), .cy(cy),
    .video_on(video_on), .read_mask(read_mask), .command(command),
    .ovl1(ovl1), .ovl2(ovl2), .ovl3(ovl3),
    .cur_xy(cur_xy), .cur_row(cur_row), .cur_a(cur_a), .cur_b(cur_b),
    .cm_raddr(cm_raddr), .cm_rdata(cm_rdata),
    .rgb(rgb), .retrace(retrace)
);

// ---- the CPU's side -----------------------------------------------------------------
reg         sel_fhc = 0, sel_thc = 0, sel_fbc = 0, sel_tec = 0, sel_nul = 0, sel_dac = 0;
reg         rw_n = 1;
reg  [11:2] adr = 0;
reg  [31:0] wdata = 0;
wire [31:0] rdata, dac_rdata;
wire        ack, dac_ack, irq;

wire [25:0]  ge_word;
wire         ge_req, ge_we, ge_done;
wire [127:0] ge_wdata;
wire [15:0]  ge_sel;
wire [127:0] ge_rdata;
reg          mem_idle;

sun3_cg6 #(.COLOR_WORD(COLOR_WORD)) dut (
    .clk(clk), .rst(rst),
    .sel_fhc(sel_fhc), .sel_thc(sel_thc), .sel_fbc(sel_fbc), .sel_tec(sel_tec), .sel_nul(sel_nul),
    .rw_n(rw_n), .adr(adr), .wdata(wdata), .rdata(rdata), .ack(ack), .irq(irq),
    .retrace(retrace), .video_on(video_on),
    .pclk(pclk), .cur_row(cur_row), .cur_a(cur_a), .cur_b(cur_b), .cur_xy(cur_xy),
    .mclk(mclk), .mem_idle(mem_idle),
    .ge_word(ge_word), .ge_req(ge_req), .ge_we(ge_we), .ge_wdata(ge_wdata), .ge_sel(ge_sel),
    .ge_done(ge_done), .ge_rdata(ge_rdata)
);

// The Bt458, as sun3_fpga.v wires it for the GX: the byte on D31:24, one
// colour-map component a cycle, and read back on D31:24.
wire [31:0] dac_q;
sun3_cg4 dac (
    .clk(clk), .rst(rst), .sel_dac(sel_dac), .sel_p4(1'b0), .rw_n(rw_n), .adr(adr[3:2]),
    .lanes(4'b0001), .wdata({4{wdata[31:24]}}), .rdata(dac_q), .ack(dac_ack), .irq(),
    .retrace(retrace), .video_on(), .read_mask(read_mask), .command(command),
    .ovl1(ovl1), .ovl2(ovl2), .ovl3(ovl3),
    .cm_clk(pclk), .cm_raddr(cm_raddr), .cm_rdata(cm_rdata)
);
assign dac_rdata = {dac_q[31:24], 24'h0};

// ---- memory -------------------------------------------------------------------------
reg         wb_cyc = 0, wb_we = 0;
reg  [29:0] wb_adr = 0;
reg  [31:0] wb_dat = 0;
reg  [3:0]  wb_sel = 0;
wire [31:0] wb_q;
wire        wb_ack;

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire        SDRAM_DQML, SDRAM_DQMH;
wire  [1:0] SDRAM_BA;
wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;

sun3_mister_sdram sdram (
    .clk(mclk), .init(minit),
    .wb_cyc_i(wb_cyc), .wb_stb_i(wb_cyc), .wb_adr_i(wb_adr), .wb_dat_i(wb_dat), .wb_sel_i(wb_sel),
    .wb_we_i(wb_we), .wb_dat_o(wb_q), .wb_ack_o(wb_ack), .wb_line_o(),
    .fb_c_addr(28'd0), .fb_c_req(1'b0), .fb_c_done(), .fb_c_rdata(),
    .cs_word(cs_word), .cs_req(cs_req), .cs_urgent(cs_urgent), .cs_done(cs_done), .cs_rdata(cs_rdata),
    .ge_word(ge_word), .ge_req(ge_req), .ge_we(ge_we), .ge_wdata(ge_wdata), .ge_sel(ge_sel),
    .ge_done(ge_done), .ge_rdata(ge_rdata),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
    .SDRAM_CLK(SDRAM_CLK)
);

sdram_model chip (
    .clk(SDRAM_CLK), .cke(SDRAM_CKE), .nCS(SDRAM_nCS),
    .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE),
    .ba(SDRAM_BA), .a(SDRAM_A), .dqmh(SDRAM_DQMH), .dqml(SDRAM_DQML),
    .dq(SDRAM_DQ)
);

// the frame buffer's pixel p in the chip: SDRAM word COLOR_WORD + p/2, the
// even pixel in its high byte (rtl/sun3_mister_sdram.sv)
function automatic int fb_key(input int p);
    bit [25:0] w;
    w = COLOR_WORD + 26'(p / 2);
    return chip.key(w[23:22], w[21:9], {w[24], w[8:0]});
endfunction
function automatic [7:0] fb_peek(input int p);
    int k;
    bit [15:0] v;
    k = fb_key(p);
    v = chip.mem.exists(k) ? chip.mem[k] : chip.POWERUP;
    return (p % 2 == 0) ? v[15:8] : v[7:0];
endfunction

// ---- the frame-buffer cycles: a queue in front of the adapter, as the memory
// bridge's request FIFO is.  Writes are posted; a read waits for its answer.
// mem_idle is the bridge's WB_IDLE: nothing queued, nothing in flight.
typedef struct packed { bit we; bit [29:0] adr; bit [31:0] dat; bit [3:0] sel; } fbreq_t;
fbreq_t     fbq [$];
reg  [31:0] fb_rd_q;
bit         fb_rd_done = 0;
always @(posedge mclk) begin
    mem_idle <= (fbq.size() == 0) && !wb_cyc;
    if (wb_cyc) begin
        if (wb_ack) begin
            wb_cyc <= 1'b0;
            if (!wb_we) begin fb_rd_q <= wb_q; fb_rd_done <= 1'b1; end
        end
    end else if (fbq.size() != 0) begin
        fbreq_t r;
        r = fbq.pop_front();
        wb_cyc <= 1'b1;
        wb_we  <= r.we;
        wb_adr <= r.adr;
        wb_dat <= r.dat;
        wb_sel <= r.sel;
    end
end

// ---- results -----------------------------------------------------------------
// +failfast (mutate_cg6.sh): the first failure ends the run
integer passes = 0, fails = 0;
bit failfast = 0;
initial failfast = $test$plusargs("failfast");
task check(input bit ok, input string what);
    begin
        if (ok) passes = passes + 1;
        else begin
            fails = fails + 1;
            $display("FAIL  %s", what);
            if (failfast) begin
                $display("tb_cg6: %0d checks, %0d failed", passes + fails, fails);
                $display("FAIL");
                $finish;
            end
        end
    end
endtask

// ---- a bus cycle to the board ---------------------------------------------------------
// off is the offset in the P4 window (0xFF000000 + off); a byte or word
// written is on every lane, as the 68020 puts it.
longint cycles_held = 0;            // CPU clocks register cycles waited for the engine
task automatic bus(input bit wr, input [23:0] off, input int size, input [31:0] v, output [31:0] q);
    bit [31:0] d, w;
    int n;
    begin
        d = (size == 4) ? v : (size == 2) ? {2{v[15:0]}} : {4{v[7:0]}};
        if (off >= 24'h800000) begin                    // the frame buffer: the bridge
            fbreq_t r;
            bit [31:0] pa;
            pa = 32'hFF000000 | {8'h00, off};
            r.we  = wr;
            r.adr = {6'h3F, pa[25:2]};
            r.dat = d;
            r.sel = (size == 4) ? 4'hF : (size == 2) ? (off[1] ? 4'h3 : 4'hC) : (4'h8 >> off[1:0]);
            @(posedge clk);
            fbq.push_back(r);
            if (wr) q = 32'h0;
            else begin
                fb_rd_done = 0;
                while (!fb_rd_done) @(posedge mclk);
                w = fb_rd_q;
                q = (size == 4) ? w : (size == 2) ? (off[1] ? {16'h0, w[15:0]} : {16'h0, w[31:16]})
                                  : {24'h0, w[8 * (3 - off[1:0]) +: 8]};
            end
            @(posedge clk);
        end else begin
            @(posedge clk);
            #1;
            rw_n  = !wr;
            adr   = off[11:2];
            wdata = d;
            sel_fbc = (off[23:12] == 12'h700);
            sel_tec = (off[23:12] == 12'h701);
            sel_fhc = (off[23:12] == 12'h300);
            sel_thc = (off[23:12] == 12'h301);
            sel_dac = (off[23:13] == 11'h100);          // the 0xFF200000 page
            sel_nul = !(sel_fbc | sel_tec | sel_fhc | sel_thc | sel_dac);
            n = 0;
            do begin
                @(posedge clk);
                n++;
                if (n > 4_000_000) begin
                    $display("FAIL  a cycle to %06x never answered", off);
                    $finish;
                end
            end while (!(ack || dac_ack));
            w = dac_ack ? dac_rdata : rdata;
            if (n > 2) cycles_held += n;
            #1;
            {sel_fbc, sel_tec, sel_fhc, sel_thc, sel_dac, sel_nul} = 6'b0;
            rw_n = 1;
            q = (size == 4) ? w : (size == 2) ? (off[1] ? {16'h0, w[15:0]} : {16'h0, w[31:16]})
                              : {24'h0, w[8 * (3 - off[1:0]) +: 8]};
        end
    end
endtask

task automatic wr32(input [23:0] off, input [31:0] v);
    bit [31:0] q;
    bus(1, off, 4, v, q);
endtask
task automatic rd32(input [23:0] off, output [31:0] q);
    bus(0, off, 4, 32'h0, q);
endtask
task automatic wait_idle;
    bit [31:0] q;
    do rd32(24'h700010, q); while (q[28]);
endtask

// The registers that are kept, whose reads are compared with the model's:
// all but the THC's misc (its vsync is the raster's) and what neither keeps.
function automatic bit kept(input [23:0] off);
    bit [11:0] o;
    o = off[11:0];
    if (off[23:12] == 12'h300) return o == 12'h000;
    if (off[23:12] == 12'h301)                                      // the THC: timing, cursor
        return (o >= 12'h800 && o <= 12'h814) || o == 12'h8FC || (o >= 12'h900 && o < 12'hA00);
    if (off[23:12] == 12'h701)                                      // the TEC
        return o < 12'h200 || (o >= 12'h800 && o < 12'hE00);
    if (off[23:12] != 12'h700) return 0;
    if (o >= 12'h080 && o < 12'h0C0) return 1;                      // x, y, z, colour
    if (o >= 12'h120 && o < 12'h140) return 1;                      // the pattern
    if (o >= 12'h800 && o < 12'h940) return 1;                      // the indexed registers
    case (o)
        12'h000, 12'h004, 12'h008, 12'h01C, 12'h0C0, 12'h0C4, 12'h0D0, 12'h0D4,
        12'h0E0, 12'h0E4, 12'h0F0, 12'h0F4, 12'h100, 12'h104, 12'h108, 12'h10C,
        12'h110, 12'h11C: return 1;
        default: return 0;
    endcase
endfunction

// the Bt458 as the trace programmed it (the model's, docs/cg6.md "The DAC")
bit [7:0]  sh_addr = 0;
int        sh_step = 0;
bit [7:0]  sh_rgb [0:2];
bit [23:0] sh_cmap [0:255];
initial for (int i = 0; i < 256; i++) sh_cmap[i] = 24'h0;
task automatic shadow_dac(input [23:0] off, input [31:0] v);
    begin
        case (off[3:2])
            2'd0: begin sh_addr = v[31:24]; sh_step = 0; end
            2'd1: begin
                sh_rgb[sh_step] = v[31:24];
                if (++sh_step == 3) begin
                    sh_cmap[sh_addr] = {sh_rgb[0], sh_rgb[1], sh_rgb[2]};
                    sh_step = 0;
                    sh_addr++;
                end
            end
            default: ;
        endcase
    end
endtask

// ---- +lockstep: the model beside the RTL (tb_cg6_model.cpp) --------------------
// Every access is made of the model too, and after every command the whole
// frame buffer is compared with it: the first command that differs stops the
// run.  +lockstep=<k> does it for the k-th trace given (0 first);
// +lockstep_from=<n> compares from that trace's n-th access on; a FONT write
// is a command only with +lockstep_font (there are tens of thousands).
import "DPI-C" function void cg6m_reset();
import "DPI-C" function void cg6m_pixel_set(input int p, input int v);
import "DPI-C" function int  cg6m_pixel(input int p);
import "DPI-C" function void cg6m_write(input int off, input int size, input int v);
import "DPI-C" function int  cg6m_read(input int off, input int size);
bit lockstep = 0, lock_font = 0;
int lock_trace = -1, lock_from = 0;
initial begin
    if (!$value$plusargs("lockstep=%d", lock_trace)) lock_trace = -1;
    if (!$value$plusargs("lockstep_from=%d", lock_from)) lock_from = 0;
    lock_font = $test$plusargs("lockstep_font");
end

task automatic lock_compare(input string pfx, input int nacc, input string line);
    int bad;
    begin
        wait_idle();
        while (!mem_idle) @(posedge mclk);
        repeat (8) @(posedge mclk);
        bad = 0;
        for (int p = 0; p < NPIX; p++)
            if (fb_peek(p) != 8'(cg6m_pixel(p))) begin
                if (bad < 12) $display("LOCK  %s: after access %0d (%s): pixel (%0d,%0d) is %02x, the model's %02x",
                                       pfx, nacc, line.substr(0, line.len() - 2), p % FBW, p / FBW, fb_peek(p), 8'(cg6m_pixel(p)));
                bad++;
            end
        if (bad) begin
            $display("LOCK  %s: %0d pixels differ after access %0d", pfx, bad, nacc);
            $display("FAIL");
            $fflush;
            $finish;
        end
    end
endtask

// ---- one trace ----------------------------------------------------------------
byte unsigned img [0:NPIX-1];

task automatic load_image(input string path);
    int fd, n;
    begin
        fd = $fopen(path, "rb");
        if (fd == 0) begin $display("FAIL  cannot open %s", path); $finish; end
        n = $fread(img, fd);
        $fclose(fd);
        if (n != NPIX) begin $display("FAIL  %s: %0d bytes", path, n); $finish; end
    end
endtask

task automatic replay(input string pfx, input int ti);
    int fd, size, nacc, nreg, nregbad, nfb, nfbbad, nfull, nbusy, bad, nlines, ndac, ndacbad;
    string line;
    byte kind;
    bit [31:0] off32, v, q;
    bit [23:0] off;
    begin
        // a fresh board: the reset the model's cg6_reset is, and the image
        rst = 1;
        repeat (4) @(posedge clk);
        load_image({pfx, ".ini"});
        for (int k = 0; k < NPIX / 2; k++)
            chip.mem[fb_key(2 * k)] = {img[2 * k], img[2 * k + 1]};
        for (int p = NPIX; p < 1048576; p += 2)
            chip.mem[fb_key(p)] = 16'h0000;
        // the memory either side of the 1 MiB holds something, which the
        // engine must neither read (a source byte outside it is 0) nor write
        for (int p = 1048576; p < 1048576 + 4096; p += 2)
            chip.mem[fb_key(p)] = JUNK;
        for (int p = -65536; p < 0; p += 2)
            chip.mem[fb_key(p)] = JUNK;
        sh_addr = 0; sh_step = 0;
        lockstep = (ti == lock_trace);
        if (lockstep) begin
            cg6m_reset();
            for (int p = 0; p < 1048576; p++) cg6m_pixel_set(p, (p < NPIX) ? img[p] : 0);
        end
        @(posedge clk);
        rst = 0;
        repeat (4) @(posedge clk);

        fd = $fopen({pfx, ".txt"}, "r");
        if (fd == 0) begin $display("FAIL  cannot open %s.txt", pfx); $finish; end
        {nacc, nreg, nregbad, nfb, nfbbad, nfull, nbusy, nlines, ndac, ndacbad} = '0;
        while ($fgets(line, fd)) begin
            if ($sscanf(line, "%c%d %h %h", kind, size, off32, v) != 4) continue;
            off = off32[23:0];
            nacc++;
            if (lockstep) begin
                if (kind == "w") cg6m_write(off, size, v);
                else void'(cg6m_read(off, size));
            end
            if (kind == "w") begin
                bus(1, off, size, v, q);
                if (off[23:13] == 11'h100 && size == 4) shadow_dac(off, v);
                if (lockstep && lock_font && nacc >= lock_from && off == 24'h70001C) lock_compare(pfx, nacc, line);
            end else if (off == 24'h700014 || off == 24'h700018) begin
                do begin bus(0, off, size, 0, q); nfull += q[29]; end while (q[31] && q[29]);
                check(q == 0, $sformatf("%s: a command read %08x when taken", pfx, q));
                if (lockstep && nacc >= lock_from) lock_compare(pfx, nacc, line);
            end else if (off == 24'h700010) begin
                do begin bus(0, off, size, 0, q); nbusy += q[28]; end while (q[28] && !v[28]);
            end else begin
                bus(0, off, size, 0, q);
                if (off >= 24'h800000) begin
                    nfb++;
                    if (q != v) begin
                        nfbbad++;
                        if (nfbbad <= 5) $display("FAIL  %s: frame buffer read %06x/%0d: %08x, the model %08x", pfx, off, size, q, v);
                    end
                end else if (off[23:13] == 11'h100) begin
                    ndac++;
                    if (q != v) ndacbad++;
                end else if (kept(off)) begin
                    nreg++;
                    if (q != v) begin
                        nregbad++;
                        if (nregbad <= 5) $display("FAIL  %s: register read %06x: %08x, the model %08x", pfx, off, q, v);
                    end
                end
            end
        end
        $fclose(fd);
        wait_idle();
        while (!mem_idle) @(posedge mclk);
        repeat (8) @(posedge mclk);

        // nothing past the frame buffer's 1 MiB (row 910 ends 256 pixels in)
        bad = 0;
        for (int p = 1048576; p < 1048576 + 2048; p += 2) begin
            int k;
            k = fb_key(p);
            if (chip.mem.exists(k) && chip.mem[k] != JUNK) bad++;
        end
        for (int p = -65536; p < 0; p += 2)
            if (chip.mem[fb_key(p)] != JUNK) bad++;
        check(bad == 0, $sformatf("%s: %0d words outside the frame buffer written", pfx, bad));

        load_image({pfx, ".fin"});
        bad = 0;
        for (int p = 0; p < NPIX; p++)
            if (fb_peek(p) != img[p]) begin
                if (bad < 8) $display("FAIL  %s: pixel (%0d,%0d) is %02x, the model's %02x", pfx,
                                      p % FBW, p / FBW, fb_peek(p), img[p]);
                bad++;
            end
        $display("tb_cg6: %s: %0d accesses, %0d register reads compared, %0d frame-buffer reads, %0d DAC reads; %0d refused FULL, %0d BUSY",
                 pfx, nacc, nreg, nfb, ndac, nfull, nbusy);
        check(nacc > 0, $sformatf("%s: the trace is not empty", pfx));
        check(bad == 0, $sformatf("%s: %0d of %0d pixels differ from the model's", pfx, bad, NPIX));
        check(nregbad == 0, $sformatf("%s: %0d of %0d register reads differ", pfx, nregbad, nreg));
        check(nfbbad == 0, $sformatf("%s: %0d of %0d frame-buffer reads differ", pfx, nfbbad, nfb));
        check(ndacbad == 0, $sformatf("%s: %0d of %0d DAC reads differ", pfx, ndacbad, ndac));
        $fflush;
    end
endtask

// ---- the scan-out: one whole frame, every pixel, through the colour map -----------
int  frame_bad = 0, frame_px = 0;
bit  frame_chk = 0;
reg  [23:0] exp_d [0:3];
reg  [3:0]  chk_d = 0, de_d = 0;
// the cursor as the bench wrote it (sh_cur*), shown in overlay colours
// {B, A} gated by the command register's overlay enables
bit [31:0] sh_cura [0:31], sh_curb [0:31];
bit [31:0] sh_curxy = 32'h0;
initial for (int i = 0; i < 32; i++) begin sh_cura[i] = 0; sh_curb[i] = 0; end
function automatic [23:0] expect_px(input [11:0] x, input [10:0] y);
    int fx, fy, dx, dy;
    bit [1:0] o;
    if (!(x >= 4 && x < 1156 && y >= 2 && y < 902) || !video_on) return 24'h0;
    fx = int'(x) - 4; fy = int'(y) - 2;
    dx = fx - int'($signed(sh_curxy[31:16]));
    dy = fy - int'($signed(sh_curxy[15:0]));
    if (dx >= 0 && dx < 32 && dy >= 0 && dy < 32) begin
        o = {sh_curb[dy][31 - dx] & command[1], sh_cura[dy][31 - dx] & command[0]};
        if (o == 2'd1) return ovl1;
        if (o == 2'd2) return ovl2;
        if (o == 2'd3) return ovl3;
    end
    return sh_cmap[fb_peek(fy * FBW + fx) & read_mask];
endfunction
always @(posedge pclk) begin
    exp_d[0] <= frame_chk ? expect_px(cx, cy) : 24'h0;
    for (int k = 1; k < 4; k++) exp_d[k] <= exp_d[k-1];
    chk_d <= {chk_d[2:0], frame_chk};
    de_d  <= {de_d[2:0], de};
    if (chk_d[3]) begin
        if (de_d[3]) frame_px++;
        if (rgb !== exp_d[3]) begin
            if (frame_bad < 5) $display("FAIL  the scan-out: %06x, expected %06x (at %0t)", rgb, exp_d[3], $time);
            frame_bad++;
        end
    end
end
task automatic next_vblank;
    do @(posedge pclk); while (!(cx == 12'd0 && cy == 11'd904));
endtask

// ---- the sequence ----------------------------------------------------------------
string tr [0:3];
bit    have [0:3];
bit [31:0] q, q2;
longint t0;
initial begin
    $display("tb_cg6: sun3_cg6 and its engine against tools/cg6model's traces");
    for (int i = 0; i < 4; i++) have[i] = $value$plusargs($sformatf("t%0d=%%s", i), tr[i]);
    repeat (20) @(posedge mclk);
    prst  = 0;
    minit = 0;
    // the controller's power-up wait (12,100 clocks): nothing may ask before
    // it, since the `ready' that ends it would look like an answer
    repeat (12400) @(posedge mclk);
    srst = 0;
    repeat (20) @(posedge mclk);
    @(posedge clk);
    rst = 0;

    for (int i = 0; i < 4; i++)
        if (have[i]) replay(tr[i], i);
    check(have[0], "a trace was given (+t0=)");

    // ---- the Bt458 and the scan-out, as the first trace (the PROM's) left them
    // (the frame buffer is the last trace's: shown through the colour map)
    if (have[0] && tr[0].len() >= 5 && tr[0].substr(tr[0].len() - 5, tr[0].len() - 1) == "_prom") begin
        check(sh_cmap[0] == 24'hFFFFFF && sh_cmap[255] == 24'h000000, "the PROM's colour map: 0 white, 255 black");
    end
    // the colour map entries the bench's shadow holds, as the DAC has them
    wr32(24'h200000, 32'h01000000);
    wr32(24'h200004, 32'h12000000); wr32(24'h200004, 32'h34000000); wr32(24'h200004, 32'h56000000);
    sh_cmap[1] = 24'h123456;
    wr32(24'h200000, 32'h01000000);
    rd32(24'h200004, q);
    check(q == 32'h12000000, $sformatf("a colour-map component read on D31:24: %08x", q));
    wr32(24'h200000, 32'h06060606); wr32(24'h200008, 32'h40404040);
    wr32(24'h200000, 32'h04040404); wr32(24'h200008, 32'hFFFFFFFF);
    check(read_mask == 8'hFF && command == 8'h40, $sformatf("read mask %02x, command %02x", read_mask, command));

    // ---- the THC: vsync follows the raster, video on
    wr32(24'h301818, 32'h0000048F);
    check(video_on, "THC misc 0x48F: video on");
    begin
        int seen1 = 0, seen0 = 0, agree = 0, n = 0;
        t0 = $time;
        while ($time - t0 < 64'd40_000_000_000) begin        // 40 ms: two frames and more
            rd32(24'h301818, q);
            n++;
            if (q[8]) seen1++; else seen0++;
            if (q[8] == retrace) agree++;
        end
        check(seen1 > 0 && seen0 > 0, $sformatf("THC vsync is seen set (%0d) and clear (%0d)", seen1, seen0));
        check(agree >= n - 8, $sformatf("THC vsync follows the raster's: %0d of %0d reads", agree, n));
        check(q[16] && q[10] && q[7:5] == 3'b100 && q[3:0] == 4'hF, $sformatf("THC misc reads back: %08x", q));
    end
    // the retrace interrupt, as Solaris's thc_int_* drive it
    wr32(24'h301818, 32'h0000049F);             // INT written 1: cleared, still disabled
    next_vblank();
    repeat (100) @(posedge clk);
    rd32(24'h301818, q);
    check(q[4] && !irq, $sformatf("pending at vsync, but not enabled: misc %08x, irq %0d", q, irq));
    wr32(24'h301818, 32'h0000049F);             // cleared
    rd32(24'h301818, q);
    check(!q[4], "INT written 1 clears it");
    wr32(24'h301818, 32'h000004AF);             // enabled
    check(!irq, "no interrupt until vsync");
    next_vblank();
    repeat (100) @(posedge clk);
    check(irq, "the interrupt at vsync's start, enabled");
    do @(posedge pclk); while (retrace);
    repeat (10) @(posedge clk);
    check(irq, "held after vsync, until cleared");
    wr32(24'h301818, 32'h0000049F);             // thc_int_disable
    check(!irq, "INT written 1, enable 0: no interrupt");
    wr32(24'h301818, 32'h0000008F);
    check(!video_on, "THC misc without bit 10: video off");
    wr32(24'h301818, 32'h0000048F);

    // ---- the FHC: the P4 ID, and SunOS's p4probe writing it back inverted
    rst = 1; @(posedge clk); @(posedge clk); rst = 0; @(posedge clk);
    bus(0, 24'h300000, 1, 0, q);
    check(q == 32'h60, $sformatf("the P4 ID byte: %02x", q));
    rd32(24'h300000, q);
    check(q == 32'h60100000, $sformatf("FHC after reset: %08x", q));
    wr32(24'h300000, q ^ 32'h7F000000 ^ 32'h00010BBB);
    rd32(24'h300000, q);
    check(q == 32'h60110BBB, $sformatf("FHC after the probe's write: %08x (ID kept, 19:0 stored)", q));
    rd32(24'h700000, q2);
    check(q2 == q, "FBC config is the FHC");
    rd32(24'h380000, q);
    check(q == 0, "the board's ROM reads 0 (no logo)");
    wr32(24'h301818, 32'h0000048F);             // video on again, for the frame below

    // ---- a busy engine: a full-screen fill, then at once ...
    wr32(24'h700108, 32'hA980FF00);             // fill with fcolor
    wr32(24'h70010C, 32'hFF);
    wr32(24'h700100, 32'h5A);
    wr32(24'h700904, 0); wr32(24'h700900, 0);
    wr32(24'h700904, FBH - 1); wr32(24'h700900, FBW - 1);
    rd32(24'h700014, q);
    check(q == 0, $sformatf("DRAWSTATUS takes the rectangle: %08x", q));
    rd32(24'h700014, q);
    check(q == 32'hB0000000, $sformatf("DRAWSTATUS while busy: %08x (EXCEPTION | FULL | BUSY)", q));
    rd32(24'h700018, q);
    check(q == 32'hB0000000, $sformatf("BLITSTATUS while busy: %08x", q));
    rd32(24'h700010, q);
    check(q == 32'h30000000, $sformatf("STATUS while busy: %08x (BUSY | FULL)", q));
    t0 = $time;
    wr32(24'h700100, 32'hA5);                   // ... a register written: held until it is done
    check(!dut.busy, "an FBC write waits for the engine");
    check($time - t0 > 64'd5_000_000_000, $sformatf("... which took %0d us", ($time - t0) / 1000000));
    $display("tb_cg6: a full-screen fill (no destination read) took %0d us, beside the scan-out", ($time - t0) / 1000000);
    rd32(24'h700010, q);
    check(q == 0, $sformatf("STATUS when done: %08x", q));
    rd32(24'h700100, q);
    check(q == 32'hA5, "and the write was made");
    begin
        int nb = 0;
        for (int p = 0; p < NPIX; p += 997) nb += (fb_peek(p) != 8'h5A);
        check(nb == 0, $sformatf("the fill drew with the colour before the write: %0d pixels not", nb));
    end
    check(fb_peek(0) == 8'h5A && fb_peek(NPIX - 1) == 8'h5A, "the fill's corners");

    // ---- a relative vertex is relative to the last one: (100,100), then
    // (400,300), then (+5,+3) -- the rectangle (400,300)-(405,303)
    wr32(24'h700108, 32'hA980FF00); wr32(24'h700100, 32'h3C);
    wr32(24'h700904, 100); wr32(24'h700900, 100);
    wr32(24'h700904, 300); wr32(24'h700900, 400);
    wr32(24'h700914, 3);   wr32(24'h700910, 5);
    rd32(24'h700014, q);
    wait_idle();
    while (!mem_idle) @(posedge mclk);
    begin
        int nb = 0;
        for (int y = 298; y < 306; y++)
            for (int x = 398; x < 408; x++)
                nb += ((fb_peek(y * FBW + x) == 8'h3C) != (x >= 400 && x <= 405 && y >= 300 && y <= 303));
        nb += (fb_peek(100 * FBW + 100) == 8'h3C);
        check(nb == 0, $sformatf("a relative vertex: %0d pixels wrong", nb));
    end

    // ---- a font row longer than the word: 32 pixels of colour1, 4 of colour8
    wr32(24'h700108, 32'hA980FF00); wr32(24'h700100, 32'h66);
    wr32(24'h7000D0, 0); wr32(24'h7000D4, 1);
    wr32(24'h700004, 32'h00040000);                     // colour1
    wr32(24'h700080, 100); wr32(24'h700084, 200);
    wr32(24'h700090, 140); wr32(24'h700094, 200);       // x1 - x0 + 1 = 41
    wr32(24'h70001C, 32'hFFFFFFFF);
    wr32(24'h700004, 32'h00020000);                     // colour8
    wr32(24'h700080, 100); wr32(24'h700090, 140);
    wr32(24'h70001C, 32'hFFFFFFFF);
    wait_idle();
    while (!mem_idle) @(posedge mclk);
    begin
        int nb = 0;
        for (int x = 96; x < 150; x++) begin
            nb += ((fb_peek(200 * FBW + x) == 8'h66) != (x >= 100 && x < 132));
            nb += ((fb_peek(201 * FBW + x) == 8'h66) != (x >= 100 && x < 104));
        end
        check(nb == 0, $sformatf("a font row wider than its word: 32 pixels, or 4: %0d wrong", nb));
    end
    wr32(24'h7000D4, 0);

    // ---- the CPU's posted writes land before the engine draws: a copy set up
    // first, 64 longwords written to its source, and the copy started at once
    wr32(24'h700108, 32'hA980CCCC);
    wr32(24'h700080, 0);   wr32(24'h700084, 10);          // source (0,10)-(255,10)
    wr32(24'h700090, 255); wr32(24'h700094, 10);
    wr32(24'h7000A0, 0);   wr32(24'h7000A4, 20);          // to (0,20)
    for (int i = 0; i < 64; i++) begin
        bit [31:0] dq;
        bus(1, 24'h800000 + 24'(10 * FBW + 4 * i), 4, 32'hC0DE0000 | i, dq);
    end
    rd32(24'h700018, q);
    wait_idle();
    while (!mem_idle) @(posedge mclk);
    begin
        int nb = 0;
        for (int i = 0; i < 64; i++)
            for (int b = 0; b < 4; b++)
                nb += (fb_peek(20 * FBW + 4 * i + b) != 8'((32'hC0DE0000 | i) >> (24 - 8 * b)));
        check(nb == 0, $sformatf("a copy started straight after the CPU's writes copies them: %0d pixels not", nb));
    end

    // ---- the frame buffer's end: 1 MiB, 256 pixels into row 910.  A fill of
    // rows 905..920, the clip window well past them, writes up to there.
    wr32(24'h7000F4, 32'd2000);
    wr32(24'h700108, 32'hA980FF00); wr32(24'h700100, 32'h77);
    wr32(24'h700904, 905); wr32(24'h700900, 0);
    wr32(24'h700904, 920); wr32(24'h700900, FBW - 1);
    rd32(24'h700014, q);
    wait_idle();
    while (!mem_idle) @(posedge mclk);
    repeat (8) @(posedge mclk);
    begin
        int nb = 0, past = 0;
        for (int p = 905 * FBW; p < 1048576; p++) nb += (fb_peek(p) != 8'h77);
        for (int p = 1048576; p < 1048576 + 2048; p += 2) begin
            int k;
            k = fb_key(p);
            if (chip.mem.exists(k) && chip.mem[k] != JUNK) past++;
        end
        check(nb == 0, $sformatf("a fill to the frame buffer's end: %0d of its pixels not drawn", nb));
        check(past == 0, $sformatf("... and none past it: %0d words written", past));
        nb = 0;                                 // nor wrapped round to the top
        for (int p = 0; p < 2 * FBW; p++) nb += (fb_peek(p) != 8'h5A);
        check(nb == 0, $sformatf("... nor at the top: %0d pixels of rows 0 and 1 changed", nb));
    end
    wr32(24'h7000F4, FBH - 1);

    // ---- the scan-out: a whole frame through the colour map
    sh_cmap[8'h5A] = 24'h0;
    wr32(24'h200000, 32'h5A000000);
    wr32(24'h200004, 32'hC0000000); wr32(24'h200004, 32'h80000000); wr32(24'h200004, 32'h40000000);
    sh_cmap[8'h5A] = 24'hC08040;
    wr32(24'h700108, 32'hA980FF00); wr32(24'h700100, 32'h01);    // a rectangle of colour 1
    wr32(24'h700904, 300); wr32(24'h700900, 200);
    wr32(24'h700904, 500); wr32(24'h700900, 900);
    rd32(24'h700014, q);
    wait_idle();
    // the cursor, as the kernel's cg6_setcurshape loads it: A the mask, B the
    // image and the mask; at (290, 480), across the rectangle's corner, with
    // the overlay colours the retrace interrupt loads (1 and 3) and 2 too
    for (int r = 0; r < 32; r++) begin
        bit [31:0] m, im;
        m  = (r > 29) ? 32'h0 : 32'h7FFFFFFE ^ (32'h1 << r);
        im = {r[3:0], 4'hA, r[4:0], 3'b101, 8'h5C, 8'(r * 37)};
        sh_cura[r] = m; sh_curb[r] = im & m;
        if (r == 5) sh_curb[r] = 32'hF0F0F0F0;          // B alone: overlay colour 2
        wr32(24'h301900 + 24'(4 * r), sh_cura[r]);
        wr32(24'h301980 + 24'(4 * r), sh_curb[r]);
    end
    wr32(24'h200000, 32'h01000000);
    wr32(24'h20000C, 32'h11000000); wr32(24'h20000C, 32'h22000000); wr32(24'h20000C, 32'h33000000);
    wr32(24'h20000C, 32'h44000000); wr32(24'h20000C, 32'h55000000); wr32(24'h20000C, 32'h66000000);
    wr32(24'h20000C, 32'h77000000); wr32(24'h20000C, 32'h88000000); wr32(24'h20000C, 32'h99000000);
    wr32(24'h200000, 32'h06060606); wr32(24'h200008, 32'h43434343);     // overlays on
    sh_curxy = {16'd290, 16'd480};
    wr32(24'h3018FC, sh_curxy);
    rd32(24'h3018FC, q);
    check(q == sh_curxy, $sformatf("the cursor's place reads back: %08x", q));
    rd32(24'h301904 + 24'(4 * 7), q);
    check(q == sh_cura[8], $sformatf("cursor plane A's row 8 reads back: %08x", q));
    rd32(24'h301980 + 24'(4 * 9), q);
    check(q == sh_curb[9], $sformatf("cursor plane B's row 9 reads back: %08x", q));
    check(ovl1 == 24'h112233 && ovl3 == 24'h778899 && command == 8'h43, "the overlay colours and enables");
    next_vblank();
    next_vblank();                              // the lines fetched after the fill
    frame_chk = 1;
    next_vblank();
    frame_chk = 0;
    repeat (8) @(posedge pclk);
    check(frame_px == 1160 * 904 && frame_bad == 0,
          $sformatf("the scan-out with the cursor: %0d of %0d pixels wrong", frame_bad, frame_px));
    // ... and the cursor at the screen's top left, partly off it, and with
    // only OL0 enabled; then hidden as the kernel hides it
    sh_curxy = {-16'sd7, -16'sd11};
    wr32(24'h3018FC, sh_curxy);
    wr32(24'h200000, 32'h06060606); wr32(24'h200008, 32'h41414141);
    frame_bad = 0; frame_px = 0;
    next_vblank();
    frame_chk = 1;
    next_vblank();
    frame_chk = 0;
    repeat (8) @(posedge pclk);
    check(frame_px == 1160 * 904 && frame_bad == 0,
          $sformatf("the cursor partly off the screen, OL0 alone: %0d of %0d pixels wrong", frame_bad, frame_px));
    sh_curxy = 32'hFFE0FFE0;
    wr32(24'h3018FC, sh_curxy);
    wr32(24'h200000, 32'h06060606); wr32(24'h200008, 32'h43434343);
    frame_bad = 0; frame_px = 0;
    next_vblank();
    frame_chk = 1;
    next_vblank();
    frame_chk = 0;
    repeat (8) @(posedge pclk);
    check(frame_px == 1160 * 904 && frame_bad == 0,
          $sformatf("the cursor hidden at (-32, -32): %0d of %0d pixels wrong", frame_bad, frame_px));

    check(chip.errors == 0, $sformatf("the SDRAM chip model: %0d protocol errors", chip.errors));
    $display("tb_cg6: %0d CPU clocks in register cycles that waited for the engine", cycles_held);
    $display("");
    $display("tb_cg6: %0d checks, %0d failed", passes + fails, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

endmodule
