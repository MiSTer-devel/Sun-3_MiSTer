//============================================================================
//  tb_vint -- rtl/sun3/sun3_vint.v, the 3/60's level-4 interrupt source, with
//  the interrupt PAL it feeds (sun3_irq_priority.v) and the cg4's P4 register
//  (sun3_cg4.sv) whose interrupt it takes, driven the way SunOS's cgfour driver
//  drives them (docs/cg4.md, "What SunOS 4.1.1 does with it"):
//
//    * before any P4 interrupt, level 4 latches only at the start of a
//      vertical blank: turning EN_IRQ4 on during one latches nothing until
//      the next, and the latch holds until EN_IRQ4 is turned off;
//    * colour-map updates begun at every point of the frame, each as the
//      driver does one (P4 |= 6, then EN_IRQ4; the handler loads only when the
//      P4 pending bit is set, then P4 &= ~2 and EN_IRQ4 off): one level-4
//      entry each, every one with the pending bit set -- none spurious, which
//      is the interrupt storm the bw2's blank used to cause;
//    * once the P4 board has interrupted, blanks no longer reach level 4;
//    * a reset forgets that, and blanks reach it again;
//    * the GX (sun3_cg6.sv) in the slot instead, its THC's retrace interrupt
//      driven as the sun3 4.1.1 cgsix driver (cgsix.o 1.49) drives it: an
//      update is THC misc &= ~0x1020, |= 0x10 (pending cleared, disabled),
//      the soft copy, misc = misc & ~0x1000 | 0x20 (enabled), then EN_IRQ4;
//      cgsixpoll loads when its soft flags say so, then EN_IRQ4 off and misc
//      &= ~0x1020, |= 0x10.  Updates begun all through the frame each take
//      one level-4 entry, at a vertical blank's start, none spurious; with
//      the THC's enable off nothing reaches level 4, though the retrace
//      still sets pending.
//
//      make -C tb/verilator tb_vint
//============================================================================
`timescale 1ns/1ps

module tb_vint;

reg clk = 0;
always #25 clk = ~clk;                          // 20 MHz, the CPU's clock
reg rst = 1;

// ---- a frame: FRAME clocks, the last BLANK of them vertical blank, as one
// raster drives both the on-board video and the cg4 in Sun-3.sv
localparam int FRAME = 2000, BLANK = 70;
integer cnt = 0;
always @(posedge clk) cnt <= (cnt == FRAME - 1) ? 0 : cnt + 1;
wire vblank = (cnt >= FRAME - BLANK);

// ---- the DUT and its neighbours
reg  en_irq4 = 0;
wire p4_int, v_int;
wire [2:0] ipl_n;
wire [2:0] level = ~ipl_n;

sun3_vint dut (.CLK(clk), .RESET(rst), .VBLANK(vblank), .P4_INT(p4_int), .V_INT(v_int));

sun3_irq_priority irq (.CLK(clk), .EN_IRQ7(1'b0), .EN_IRQ6(1'b0), .EN_IRQ5(1'b0),
                       .EN_IRQ4(en_irq4), .EN_IRQ3(1'b0), .EN_IRQ2(1'b0), .EN_IRQ1(1'b0),
                       .EN_INT(1'b1), .RTC(1'b0), .V_INT(v_int), .SCC_IRQ(1'b0),
                       .E_IRQ(1'b0), .PAR_IRQ(1'b0), .S_IRQ(1'b0), .IPL_n(ipl_n));

reg         sel_p4 = 0, rw_n = 1;
reg  [31:0] wdata = 0;
wire [31:0] rdata;
wire        ack;
wire [23:0] o1, o2, o3;
wire [7:0]  rm, cmd;
wire        von;
wire [23:0] cm_rdata;
wire        cg4_irq, cg6_irq;
assign p4_int = cg4_irq | cg6_irq;
sun3_cg4 cg4 (.clk(clk), .rst(rst), .sel_dac(1'b0), .sel_p4(sel_p4), .rw_n(rw_n),
              .adr(2'd0), .lanes(4'hF), .wdata(wdata), .rdata(rdata), .ack(ack),
              .irq(cg4_irq), .retrace(vblank), .video_on(von), .read_mask(rm),
              .command(cmd), .ovl1(o1), .ovl2(o2), .ovl3(o3),
              .cm_clk(clk), .cm_raddr(8'd0), .cm_rdata(cm_rdata));

// the GX, its THC alone driven (its engine idle)
reg         sel_thc = 0;
reg  [11:2] thc_adr = 10'h206;                  // 0x818, misc
wire [31:0] g_rdata;
wire        g_ack;
sun3_cg6 cg6 (.clk(clk), .rst(rst), .sel_fhc(1'b0), .sel_thc(sel_thc), .sel_fbc(1'b0), .sel_tec(1'b0),
              .sel_nul(1'b0), .rw_n(rw_n), .adr(thc_adr), .wdata(wdata), .rdata(g_rdata), .ack(g_ack),
              .irq(cg6_irq), .retrace(vblank), .video_on(),
              .pclk(clk), .cur_row(5'd0), .cur_a(), .cur_b(), .cur_xy(),
              .mclk(clk), .mem_idle(1'b1), .ge_word(), .ge_req(), .ge_we(), .ge_wdata(), .ge_sel(),
              .ge_done(1'b0), .ge_rdata(128'h0));

task automatic thc_read(output [31:0] v);
    begin
        @(posedge clk); sel_thc <= 1; rw_n <= 1;
        do @(posedge clk); while (!g_ack);
        v = g_rdata;
        sel_thc <= 0;
        @(posedge clk);
    end
endtask
task automatic thc_write(input [31:0] v);
    begin
        @(posedge clk); sel_thc <= 1; rw_n <= 0; wdata <= v;
        do @(posedge clk); while (!g_ack);
        sel_thc <= 0; rw_n <= 1;
        @(posedge clk);
    end
endtask

// ---- the CPU's accesses
task automatic p4_read(output [31:0] v);
    begin
        @(posedge clk); sel_p4 <= 1; rw_n <= 1;
        do @(posedge clk); while (!ack);
        v = rdata;
        sel_p4 <= 0;
        @(posedge clk);
    end
endtask
task automatic p4_write(input [31:0] v);
    begin
        @(posedge clk); sel_p4 <= 1; rw_n <= 0; wdata <= v;
        do @(posedge clk); while (!ack);
        sel_p4 <= 0; rw_n <= 1;
        @(posedge clk);
    end
endtask

// ---- results
integer passes = 0, fails = 0;
task check(input bit ok, input string what);
    begin
        if (ok) passes = passes + 1;
        else begin
            fails = fails + 1;
            $display("FAIL  %s", what);
        end
    end
endtask

task automatic wait_cnt(input int c);
    do @(posedge clk); while (cnt != c);
endtask

// clocks until level 4, up to a limit (the limit if it never comes)
task automatic until_l4(input int limit, output int n);
    begin
        n = 0;
        while (level != 3'd4 && n < limit) begin @(posedge clk); n = n + 1; end
    end
endtask

// ---- the cgfour driver: its ioctl and its level-4 poll routine
bit soft_pending = 0;
integer entries = 0, loads = 0, spurious = 0;

task automatic ioctl_putcmap;
    reg [31:0] v;
    begin
        if (soft_pending) begin                 // an update still pending
            en_irq4 <= 0;
            p4_read(v); p4_write(v & ~32'h2);
        end
        soft_pending = 1;
        p4_read(v); p4_write(v | 32'h6);        // clear pending, enable
        @(posedge clk); en_irq4 <= 1;           // setintrenable(1)
    end
endtask

task automatic poll;                            // cgfourpoll, once level 4 is up
    reg [31:0] v;
    begin
        entries = entries + 1;
        repeat (20) @(posedge clk);             // exception entry
        p4_read(v);
        if (soft_pending && v[2]) begin         // cgfourintr_b
            loads = loads + 1;
            repeat (40) @(posedge clk);         // the colour map
            soft_pending = 0;
            en_irq4 <= 0;                       // setintrenable(0)
            p4_read(v); p4_write(v & ~32'h2);   // writes bit 2 back as 1: clears it
        end else
            spurious = spurious + 1;            // claimed, nothing loaded
        repeat (10) @(posedge clk);             // rte
    end
endtask

// ---- the cgsix driver: cg6_putcolormap and cgsixpoll/cgsixintr
bit g_soft = 0;
integer g_entries = 0, g_loads = 0, g_spurious = 0, g_updates = 0, g_early = 0;

task automatic cgsix_putcmap;
    reg [31:0] v;
    begin
        if (g_soft) begin                       // an update still pending
            en_irq4 <= 0;
            thc_read(v); thc_write((v & ~32'h1020) | 32'h10);
        end
        g_soft = 1;                             // cgsix_update_cmap
        thc_read(v); thc_write((v & ~32'h1000) | 32'h20);
        @(posedge clk); en_irq4 <= 1;           // setintrenable(1)
    end
endtask

task automatic cgsix_poll;
    reg [31:0] v;
    begin
        g_entries = g_entries + 1;
        repeat (20) @(posedge clk);
        if (g_soft) begin                       // cgsixintr
            g_loads = g_loads + 1;
            repeat (40) @(posedge clk);         // the colour map, on the DAC
            g_soft = 0;
            en_irq4 <= 0;                       // setintrenable(0)
            thc_read(v); thc_write((v & ~32'h1020) | 32'h10);
        end else
            g_spurious = g_spurious + 1;
        repeat (10) @(posedge clk);
    end
endtask

// ---- the sequence
initial begin
    int n, l4, ph, updates;
    reg [31:0] v;
    $display("tb_vint: sun3_vint with the interrupt PAL and the P4 register");
    repeat (10) @(posedge clk);
    rst = 0;
    repeat (10) @(posedge clk);

    // 1. No P4 interrupt yet: EN_IRQ4 on part-way into a blank latches
    // nothing for the rest of it, then latches at the next blank's start.
    wait_cnt(FRAME - BLANK + 20);
    en_irq4 = 1;
    until_l4(BLANK - 21, n);
    check(level != 3'd4, "EN_IRQ4 on during a blank: no level 4 for the rest of it");
    wait_cnt(0);
    until_l4(FRAME, n);
    check(level == 3'd4 && n >= FRAME - BLANK - 2 && n <= FRAME - BLANK + 6,
          $sformatf("... level 4 at the next blank's start (%0d clocks after the frame's start)", n));
    repeat (3 * FRAME) @(posedge clk);
    check(level == 3'd4, "the latch holds level 4 while EN_IRQ4 is on");
    en_irq4 = 0;
    repeat (4) @(posedge clk);
    check(level != 3'd4, "EN_IRQ4 off drops level 4");
    // ... and EN_IRQ4 on mid-frame: level 4 at the blank's start, not before
    wait_cnt(300);
    en_irq4 = 1;
    until_l4(FRAME, n);
    check(n >= FRAME - BLANK - 300 - 2 && n <= FRAME - BLANK - 300 + 6,
          $sformatf("EN_IRQ4 on mid-frame: level 4 at the blank's start (%0d clocks on)", n));
    en_irq4 = 0;
    repeat (4) @(posedge clk);

    // 2. Colour-map updates begun all through the frame, the blank included.
    updates = 0;
    for (ph = 0; ph < FRAME; ph = ph + 23) begin
        wait_cnt(ph);
        ioctl_putcmap();
        updates = updates + 1;
        // run until the update has been loaded, taking every level 4
        n = 0;
        while (soft_pending && n < 3 * FRAME) begin
            @(posedge clk); n = n + 1;
            if (level == 3'd4 && en_irq4) poll();
        end
        check(!soft_pending, $sformatf("an update begun at clock %0d of the frame is loaded", ph));
    end
    check(loads == updates, $sformatf("%0d updates, %0d colour-map loads", updates, loads));
    check(spurious == 0, $sformatf("level-4 entries with nothing pending: %0d (of %0d)", spurious, entries));
    check(entries == updates, $sformatf("one level-4 entry an update: %0d for %0d", entries, updates));

    // 3. The P4 board has interrupted: blanks no longer reach level 4.
    p4_read(v);
    check(!v[1], "the P4 interrupt is off after the last load");
    en_irq4 = 1;
    until_l4(3 * FRAME, n);
    check(level != 3'd4, "after a P4 interrupt, blanks do not reach level 4");
    en_irq4 = 0;

    // 4. A reset forgets the P4 board: blanks reach level 4 again.
    rst = 1; repeat (4) @(posedge clk); rst = 0;
    repeat (4) @(posedge clk);
    en_irq4 = 1;
    until_l4(2 * FRAME, n);
    check(level == 3'd4, "after a reset, a blank reaches level 4 again");
    en_irq4 = 0;
    repeat (4) @(posedge clk);

    $display("tb_vint: %0d updates, %0d level-4 entries, %0d spurious", updates, entries, spurious);

    // 5. The GX: a reset, the PROM's THC misc (video on, no interrupt), then
    // the cgsix driver's colour-map updates begun all through the frame.
    rst = 1; repeat (4) @(posedge clk); rst = 0;
    repeat (4) @(posedge clk);
    thc_write(32'h0000048F);
    g_updates = 0; g_entries = 0; g_loads = 0; g_spurious = 0; g_early = 0;
    for (ph = 0; ph < FRAME; ph = ph + 37) begin
        wait_cnt(ph);
        cgsix_putcmap();
        g_updates = g_updates + 1;
        n = 0;
        while (g_soft && n < 3 * FRAME) begin
            @(posedge clk); n = n + 1;
            if (level == 3'd4 && en_irq4) begin
                if (!(cnt >= FRAME - BLANK && cnt < FRAME - BLANK + 12)) g_early = g_early + 1;
                cgsix_poll();
            end
        end
        check(!g_soft, $sformatf("a GX update begun at clock %0d of the frame is loaded", ph));
    end
    check(g_loads == g_updates, $sformatf("GX: %0d updates, %0d colour-map loads", g_updates, g_loads));
    check(g_spurious == 0, $sformatf("GX: level-4 entries with nothing to load: %0d (of %0d)", g_spurious, g_entries));
    check(g_entries == g_updates, $sformatf("GX: one level-4 entry an update: %0d for %0d", g_entries, g_updates));
    check(g_early == 0, $sformatf("GX: every level 4 at a blank's start: %0d not", g_early));
    // ... the THC's enable off: the retrace still sets pending, nothing reaches level 4
    thc_read(v);
    check(!v[5] && !v[4], $sformatf("GX: after the last load, misc %08x: disabled, nothing pending", v));
    en_irq4 = 1;
    until_l4(3 * FRAME, n);
    check(level != 3'd4, "GX: the THC's interrupt disabled: no level 4");
    en_irq4 = 0;
    thc_read(v);
    check(v[4], $sformatf("GX: ... though the retrace set pending: misc %08x", v));
    $display("tb_vint: the GX: %0d updates, %0d level-4 entries, %0d spurious", g_updates, g_entries, g_spurious);
    $display("");
    $display("tb_vint: %0d checks, %0d failed", passes + fails, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

initial begin
    #(64'd400_000_000);                         // 400 ms
    $display("FAIL  timeout");
    $display("FAIL");
    $finish;
end

endmodule
