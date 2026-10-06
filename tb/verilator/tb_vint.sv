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
//    * a reset forgets that, and blanks reach it again.
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
sun3_cg4 cg4 (.clk(clk), .rst(rst), .sel_dac(1'b0), .sel_p4(sel_p4), .rw_n(rw_n),
              .adr(2'd0), .lanes(4'hF), .wdata(wdata), .rdata(rdata), .ack(ack),
              .irq(p4_int), .retrace(vblank), .video_on(von), .read_mask(rm),
              .command(cmd), .ovl1(o1), .ovl2(o2), .ovl3(o3),
              .cm_clk(clk), .cm_raddr(8'd0), .cm_rdata(cm_rdata));

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
