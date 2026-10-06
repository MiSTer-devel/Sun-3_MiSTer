//============================================================================
//  tb_cg4 -- rtl/sun3/sun3_cg4.sv, the cg4's P4 register and Bt458s, driven
//  the way the software drives them (docs/cg4.md):
//
//    * the Rev 1.9 PROM's DAC set-up (0xFEF6CF0), byte writes -- which the
//      68020 copies onto every lane -- to the control registers through the
//      address register, then the four overlay colours;
//    * NetBSD's cg4b_init and cg4b_ldcmap for a 3/60: longword writes, the
//      colour map as 192 longwords of packed components, and read back the
//      same way;
//    * the P4 register: the cg4's ID, video on, the retrace interrupt;
//    * SunOS 4.1.1's own accesses, from a disassembly of its kernel objects
//      (docs/cg4.md): p4probe's write of the inverted ID, the mono driver's
//      plain *p4 = 0x24, FBIOSVIDEO's (*p4 & ~0x24) | v, and the retrace
//      handler's sequence -- P4 tested, the Bt458 loaded by bytes, then
//      P4 &= ~2 -- with the next retrace raising nothing.
//
//  The colour map is checked through the CPU's readback and through the
//  scan-out's own read port, entry by entry.
//
//      make -C tb/verilator tb_cg4
//============================================================================
`timescale 1ns/1ps

module tb_cg4;

reg clk = 0, pclk = 0;
always #25 clk  = ~clk;                         // 20 MHz, the CPU's
always #6  pclk = ~pclk;                        // ~83 MHz, the pixel clock's
reg rst = 1;

reg         sel_dac = 0, sel_p4 = 0, rw_n = 1;
reg  [3:2]  adr = 0;
reg  [3:0]  lanes = 0;
reg  [31:0] wdata = 0;
wire [31:0] rdata;
wire        ack, irq;
reg         retrace = 0;
wire        video_on;
wire [7:0]  read_mask, command;
wire [23:0] ovl1, ovl2, ovl3;
reg  [7:0]  cm_raddr = 0;
wire [23:0] cm_rdata;

sun3_cg4 dut (
    .clk(clk), .rst(rst),
    .sel_dac(sel_dac), .sel_p4(sel_p4), .rw_n(rw_n), .adr(adr), .lanes(lanes),
    .wdata(wdata), .rdata(rdata), .ack(ack), .irq(irq),
    .retrace(retrace), .video_on(video_on), .read_mask(read_mask), .command(command),
    .ovl1(ovl1), .ovl2(ovl2), .ovl3(ovl3),
    .cm_clk(pclk), .cm_raddr(cm_raddr), .cm_rdata(cm_rdata));

integer passes = 0, fails = 0;
task automatic check(input bit ok, input string what);
    if (ok) passes++;
    else begin fails++; $display("FAIL  %s", what); end
endtask

// One bus cycle, as sun3_fpga presents it: the select held until ack.
task automatic cyc(input bit p4, input bit wr, input [1:0] r, input [3:0] l, input [31:0] d,
                   output [31:0] q);
    integer t;
    begin
        @(posedge clk);
        sel_dac <= !p4; sel_p4 <= p4; rw_n <= !wr; adr <= r; lanes <= l; wdata <= d;
        t = 0;
        do begin @(posedge clk); t++; end while (!ack && t < 100);
        q = rdata;
        if (!ack) begin fails++; $display("FAIL  no acknowledge"); end
        sel_dac <= 0; sel_p4 <= 0;
        repeat (2) @(posedge clk);
    end
endtask

// The 68020's byte write to the register's first byte: lane D31:24, the byte
// on every lane.  Its longword: all four lanes.
reg [31:0] q;
task automatic wbyte(input [1:0] r, input [7:0] v); cyc(0, 1, r, 4'b1000, {4{v}}, q); endtask
task automatic wlong(input [1:0] r, input [31:0] v); cyc(0, 1, r, 4'b1111, v, q); endtask
task automatic rlong(input [1:0] r, output [31:0] v); cyc(0, 0, r, 4'b1111, 32'h0, v); endtask
// SunOS reads and writes the P4 register as a longword
task automatic p4_rd(output [31:0] v); cyc(1, 0, 0, 4'b1111, 32'h0, v); endtask
task automatic p4_wr(input [31:0] v); cyc(1, 1, 0, 4'b1111, v, q); endtask

// one vertical retrace, from its start to its end
task automatic vblank;
    @(posedge pclk) retrace <= 1;
    repeat (8) @(posedge clk);
    @(posedge pclk) retrace <= 0;
    repeat (8) @(posedge clk);
endtask

// a colour-map entry, through the scan-out's port
task automatic cm_entry(input [7:0] i, output [23:0] e);
    @(posedge pclk); cm_raddr <= i;
    @(posedge pclk); @(posedge pclk);
    e = cm_rdata;
endtask

localparam [1:0] BT_ADDR = 2'd0, BT_CMAP = 2'd1, BT_CTRL = 2'd2, BT_OMAP = 2'd3;

reg [7:0]  cmbytes [0:767];
reg [23:0] want [0:255];

initial begin
    $display("tb_cg4: sun3_cg4, the P4 register and the Bt458s");
    repeat (4) @(posedge clk);
    rst = 0;
    repeat (4) @(posedge clk);

    // ---- the P4 register ---------------------------------------------------------
    cyc(1, 0, 0, 4'b1111, 32'h0, q);
    check(q[30:24] == 7'h41, $sformatf("P4 ID is the cg4's 0x41: %08x", q));
    check(q[5] == 1'b0, "video off after reset");
    cyc(1, 1, 0, 4'b0001, 32'h20, q);            // as the PROM: OR in 0x20
    check(video_on, "video on");
    cyc(1, 0, 0, 4'b1111, 32'h0, q);
    check(q[5], "the P4 register reads video on");

    // ---- the PROM's DAC set-up (0xFEF6CF0) -------------------------------------------
    begin
        reg [7:0] ctl [4]  = '{8'hFF, 8'h00, 8'h73, 8'h00};
        reg [7:0] ovl [12] = '{8'hFF, 8'hFF, 8'h00, 8'hFF, 8'hFF, 8'hFF, 8'h00, 8'hFF, 8'hFF, 8'h00, 8'h00, 8'h00};
        for (int i = 0; i < 4; i++) begin
            wbyte(BT_ADDR, 8'(i + 4));
            wbyte(BT_CTRL, ctl[i]);
        end
        wbyte(BT_ADDR, 8'h00);
        for (int i = 0; i < 12; i++) wbyte(BT_OMAP, ovl[i]);
    end
    check(read_mask == 8'hFF, $sformatf("PROM: read mask %02x", read_mask));
    check(command == 8'h73, $sformatf("PROM: command %02x", command));
    check(ovl1 == 24'hFFFFFF, $sformatf("PROM: overlay 1 white: %06x", ovl1));
    check(ovl2 == 24'h00FFFF, $sformatf("PROM: overlay 2 cyan: %06x", ovl2));
    check(ovl3 == 24'h000000, $sformatf("PROM: overlay 3 black: %06x", ovl3));
    wbyte(BT_ADDR, 8'h06);
    cyc(0, 0, BT_CTRL, 4'b1000, 32'h0, q);
    check(q[7:0] == 8'h73, $sformatf("command reads back: %08x", q));

    // ---- NetBSD's cg4b_init and cg4b_ldcmap (3/60: 32-bit, packed) --------------------
    wlong(BT_ADDR, 32'h04040404); wlong(BT_CTRL, 32'hFFFFFFFF);
    wlong(BT_ADDR, 32'h05050505); wlong(BT_CTRL, 32'h0);
    wlong(BT_ADDR, 32'h06060606); wlong(BT_CTRL, 32'h43434343);
    wlong(BT_ADDR, 32'h07070707); wlong(BT_CTRL, 32'h0);
    check(command == 8'h43, $sformatf("NetBSD: command %02x", command));
    // the register's byte is the low lane's (cg4.c: "the 3/60 uses the low
    // byte"); every write software makes has the same byte on all lanes, so
    // this one does not
    wlong(BT_ADDR, 32'h11223306);
    cyc(0, 0, BT_CTRL, 4'b1111, 32'h0, q);
    check(q[7:0] == 8'h43, $sformatf("the address register takes D7:0: register 6 reads %08x", q));

    for (int i = 0; i < 256; i++) begin
        want[i] = {8'(i * 7 + 3), 8'(255 - i), 8'(i ^ 8'h5A)};
        cmbytes[3*i]     = want[i][23:16];
        cmbytes[3*i + 1] = want[i][15:8];
        cmbytes[3*i + 2] = want[i][7:0];
    end
    wlong(BT_ADDR, 32'h0);
    for (int i = 0; i < 192; i++)
        wlong(BT_CMAP, {cmbytes[4*i], cmbytes[4*i + 1], cmbytes[4*i + 2], cmbytes[4*i + 3]});

    // through the scan-out's port
    begin
        int bad = 0;
        for (int i = 0; i < 256; i++) begin
            @(posedge pclk); cm_raddr <= 8'(i);
            @(posedge pclk); @(posedge pclk);
            if (cm_rdata != want[i]) begin
                if (bad < 4) $display("      entry %0d: %06x, want %06x", i, cm_rdata, want[i]);
                bad++;
            end
        end
        check(bad == 0, $sformatf("192 packed longwords load all 256 entries (%0d wrong)", bad));
    end

    // read back the same way
    begin
        int bad = 0;
        reg [31:0] v;
        wlong(BT_ADDR, 32'h0);
        for (int i = 0; i < 192; i++) begin
            rlong(BT_CMAP, v);
            if (v != {cmbytes[4*i], cmbytes[4*i + 1], cmbytes[4*i + 2], cmbytes[4*i + 3]}) begin
                if (bad < 4) $display("      longword %0d: %08x", i, v);
                bad++;
            end
        end
        check(bad == 0, $sformatf("and read back as 192 packed longwords (%0d wrong)", bad));
    end

    // a single entry by bytes, from the middle: entry 10, R G B
    wbyte(BT_ADDR, 8'd10);
    wbyte(BT_CMAP, 8'h11); wbyte(BT_CMAP, 8'h22); wbyte(BT_CMAP, 8'h33);
    @(posedge pclk); cm_raddr <= 8'd10; @(posedge pclk); @(posedge pclk);
    check(cm_rdata == 24'h112233, $sformatf("one entry by three byte writes: %06x", cm_rdata));
    @(posedge pclk); cm_raddr <= 8'd11; @(posedge pclk); @(posedge pclk);
    check(cm_rdata == want[11], "the entry after it is untouched");

    // ---- the retrace interrupt -------------------------------------------------------
    cyc(1, 1, 0, 4'b0001, 32'h22, q);            // video on, interrupt enabled
    @(posedge pclk); retrace <= 1;
    repeat (6) @(posedge clk);
    check(irq, "retrace raises the interrupt when enabled");
    cyc(1, 0, 0, 4'b1111, 32'h0, q);
    check(q[3] && q[2], $sformatf("P4: retrace and interrupt pending: %08x", q));
    cyc(1, 1, 0, 4'b0001, 32'h26, q);            // clear it
    check(!irq, "the interrupt clears");
    @(posedge pclk); retrace <= 0;
    repeat (8) @(posedge clk);

    // ---- SunOS 4.1.1's accesses (docs/cg4.md, "What SunOS 4.1.1 does with it") --------

    // p4probe (fbutil.o): read it, clear bit 0, write it back with the ID bits
    // 30:24 inverted, and read again.  The ID must not change -- a P4 register
    // that took it would be memory -- and the low byte goes back as it was.
    begin
        reg [31:0] v, r;
        p4_rd(v);
        v = v & ~32'h1;
        p4_wr(v ^ 32'h7F000000);
        p4_rd(r);
        check(((r ^ v) & 32'h7F000000) == 0,
              $sformatf("p4probe: the ID survives a write of its inverse: %08x, wrote %08x", r, v ^ 32'h7F000000));
        check(r[5] && video_on, "p4probe: video stays on");
        check(r[1] == v[1], "p4probe: the interrupt enable stays as it was");
    end

    // The mono driver (bwtwo.o, which drives the overlay as bwtwo1) writes the
    // whole register: *p4 = 0x24, video on and the interrupt cleared, with
    // the enable off.  First a pending interrupt, as the colour driver leaves
    // one: P4 |= 6 (or.l), then a retrace.
    begin
        reg [31:0] v;
        p4_rd(v); p4_wr(v | 32'h6);
        vblank();
        check(irq, "P4 |= 6, then a retrace: the interrupt is pending");
        p4_wr(32'h00000024);
        p4_rd(v);
        check(!irq && !v[2], $sformatf("*p4 = 0x24 clears the pending interrupt: %08x", v));
        check(!v[1], $sformatf("*p4 = 0x24 turns the interrupt enable off: %08x", v));
        check(v[5] && video_on, "*p4 = 0x24 keeps video on");
        check(v[30:24] == 7'h41, "*p4 = 0x24 leaves the ID");
        vblank();
        check(!irq, "with the enable off, the next retrace raises nothing");
    end

    // FBIOSVIDEO (cgfour.o and bwtwo.o): *p4 = (*p4 & ~0x24) | (on ? 0x20 : 0),
    // and FBIOGVIDEO tests bit 5.  Bit 2 written as 0 leaves a pending
    // interrupt pending, and bit 1 goes back as it was.
    begin
        reg [31:0] v;
        p4_rd(v); p4_wr(v | 32'h6);
        vblank();
        check(irq, "pending again");
        p4_rd(v); p4_wr(v & ~32'h24);
        p4_rd(v);
        check(!video_on && !v[5], $sformatf("FBIOSVIDEO off: the video is off, and FBIOGVIDEO reads it: %08x", v));
        check(irq && v[2], "FBIOSVIDEO leaves a pending interrupt pending");
        check(v[1], "FBIOSVIDEO leaves the interrupt enable on");
        p4_rd(v); p4_wr((v & ~32'h24) | 32'h20);
        p4_rd(v);
        check(video_on && v[5], "FBIOSVIDEO on");
        check(irq, "and the interrupt is still pending");
    end

    // The retrace handler, as cgfourpoll and cgfourintr_b run it: P4 read and
    // bit 2 tested; the Bt458 loaded by bytes -- the address register, the
    // overlay map's entries 1 and 3, the address rounded down to a multiple
    // of four entries, then each component of whole groups of four entries --
    // and P4 &= ~2 (and.l), which writes bit 2 back as 1, clearing the
    // interrupt, and bit 1 as 0, disabling it.
    begin
        reg [31:0] v;
        reg [23:0] sw_cmap [8];
        reg [23:0] e;
        int bad = 0;
        for (int i = 0; i < 8; i++) sw_cmap[i] = {8'(8'h30 + i), 8'(8'hC0 - i), 8'(i * 17)};
        p4_rd(v);
        check(v[2], "the handler finds the pending bit");
        wbyte(BT_ADDR, 8'd1);
        wbyte(BT_OMAP, 8'h12); wbyte(BT_OMAP, 8'h34); wbyte(BT_OMAP, 8'h56);
        wbyte(BT_ADDR, 8'd3);
        wbyte(BT_OMAP, 8'h9A); wbyte(BT_OMAP, 8'hBC); wbyte(BT_OMAP, 8'hDE);
        wbyte(BT_ADDR, 8'd22 & 8'hFC);               // entries 22..26 changed: from 20, two groups
        for (int i = 0; i < 8; i++) begin
            wbyte(BT_CMAP, sw_cmap[i][23:16]); wbyte(BT_CMAP, sw_cmap[i][15:8]); wbyte(BT_CMAP, sw_cmap[i][7:0]);
        end
        p4_rd(v); p4_wr(v & ~32'h2);
        check(!irq, "the handler's P4 &= ~2 clears the interrupt");
        p4_rd(v);
        check(!v[1] && !v[2], $sformatf("and disables it: %08x", v));
        check(ovl1 == 24'h123456 && ovl3 == 24'h9ABCDE,
              $sformatf("the handler's overlay entries 1 and 3: %06x %06x", ovl1, ovl3));
        check(ovl2 == 24'h00FFFF, $sformatf("overlay entry 2 untouched: %06x", ovl2));
        for (int i = 0; i < 8; i++) begin
            cm_entry(8'(20 + i), e);
            if (e != sw_cmap[i]) begin
                if (bad < 4) $display("      entry %0d: %06x, want %06x", 20 + i, e, sw_cmap[i]);
                bad++;
            end
        end
        check(bad == 0, $sformatf("the handler's byte-wise load of entries 20..27 (%0d wrong)", bad));
        cm_entry(8'd19, e); check(e == want[19], "entry 19 untouched");
        cm_entry(8'd28, e); check(e == want[28], "entry 28 untouched");
        vblank();
        check(!irq, "disabled by the handler: the next retrace raises nothing");
    end

    // Writing the address register restarts the component count (Bt458): an
    // entry begun and abandoned is not stored, and the next is whole.
    begin
        reg [23:0] e;
        wbyte(BT_ADDR, 8'd40);
        wbyte(BT_CMAP, 8'hEE);
        wbyte(BT_ADDR, 8'd41);
        wbyte(BT_CMAP, 8'h44); wbyte(BT_CMAP, 8'h55); wbyte(BT_CMAP, 8'h66);
        cm_entry(8'd41, e); check(e == 24'h445566, $sformatf("an address write restarts at red: entry 41 %06x", e));
        cm_entry(8'd40, e); check(e == want[40], $sformatf("an abandoned entry is not stored: entry 40 %06x", e));
    end

    $display("");
    $display("tb_cg4: %0d checks, %0d failed", passes + fails, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

endmodule
