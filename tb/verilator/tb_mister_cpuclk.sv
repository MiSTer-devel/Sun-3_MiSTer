//============================================================================
//  tb_mister_cpuclk -- rtl/sun3_mister_cpuclk.sv, the OSD's CPU clock,
//  against pll_stub.sv's main PLL and its model of sys/pll_cfg, wired as
//  Sun-3.sv wires them: the module on CLK_50M, its hold ORed into the
//  machine's reset, and that through rtl/sun3/reset_sync.sv into cpu_clk.
//
//  Checked: the bitstream's 20 MHz needs no reconfiguration at all; nothing
//  changes while the machine runs, whatever the OSD says, and a change waits
//  for the next reset; then it writes the mode (waitrequest), C1 and START,
//  in that order and nothing else, and cpu_clk becomes 25 or 33.33 MHz with
//  50% duty (25/25, 20/20, 15/15 ns high/low), the memory clock untouched;
//  the machine is in reset when the counter changes, hold having risen at
//  least 256 CLK_50M clocks before the first write, and it stays in reset
//  for SETTLE clocks after; a setting is not made again, 3 is 20 MHz, a
//  setting changed during a change is made next, nothing happens while the
//  PLL is unlocked; a setting saved in the OSD is made as the core starts,
//  while the reconfiguration core still holds writes off; and the Avalon
//  writes are held while waitrequest is.
//
//      make -C tb/verilator tb_mister_cpuclk
//============================================================================
`timescale 1ps/1ps

module tb_mister_cpuclk;

localparam int SETTLE = 1000;

reg clk50 = 0;
always #10000 clk50 = ~clk50;

// ---- the PLL, its reconfiguration, the switch ------------------------------------------
wire        clk_mem, cpu_clk, clk_pix, clk_mii, locked;
wire [63:0] to_pll, from_pll;

pll pll_i (.refclk(clk50), .rst(1'b0), .outclk_0(clk_mem), .outclk_1(cpu_clk), .outclk_2(clk_pix),
           .outclk_3(clk_mii), .locked(locked), .reconfig_to_pll(to_pll), .reconfig_from_pll(from_pll));

wire        wait_r, wr;
wire [5:0]  addr;
wire [31:0] wdata;

pll_cfg cfg (.mgmt_clk(clk50), .mgmt_reset(1'b0), .mgmt_waitrequest(wait_r), .mgmt_read(1'b0),
             .mgmt_readdata(), .mgmt_write(wr), .mgmt_address(addr), .mgmt_writedata(wdata),
             .reconfig_to_pll(to_pll), .reconfig_from_pll(from_pll));

reg  [1:0] sel = 2'd0;
reg        req = 1'b1;                  // power-up: no PROM yet
wire       hold;
wire [1:0] cur;

sun3_mister_cpuclk #(.SETTLE(SETTLE)) dut (
    .clk(clk50), .sel(sel), .req(req), .locked(locked), .hold(hold), .cur(cur),
    .cfg_waitrequest(wait_r), .cfg_write(wr), .cfg_address(addr), .cfg_writedata(wdata));

wire reset_cpu;
reset_sync rs (.clk(cpu_clk), .rst_async_in(req | hold), .rst_sync_out(reset_cpu));

// A second board that starts with 33 MHz saved: the change is made at the
// core's start, while the reconfiguration core is still initialising and
// holds its first write off with waitrequest.
wire        cpu_clk2, clk_mem2, locked2, wait2, wr2, hold2;
wire [63:0] to_pll2, from_pll2;
wire [5:0]  addr2;
wire [31:0] wdata2;
reg         req2 = 1'b1;
pll pll2 (.refclk(clk50), .rst(1'b0), .outclk_0(clk_mem2), .outclk_1(cpu_clk2), .outclk_2(),
          .outclk_3(), .locked(locked2), .reconfig_to_pll(to_pll2), .reconfig_from_pll(from_pll2));
pll_cfg cfg2 (.mgmt_clk(clk50), .mgmt_reset(1'b0), .mgmt_waitrequest(wait2), .mgmt_read(1'b0),
              .mgmt_readdata(), .mgmt_write(wr2), .mgmt_address(addr2), .mgmt_writedata(wdata2),
              .reconfig_to_pll(to_pll2), .reconfig_from_pll(from_pll2));
sun3_mister_cpuclk #(.SETTLE(SETTLE)) dut2 (
    .clk(clk50), .sel(2'd2), .req(req2), .locked(locked2), .hold(hold2), .cur(),
    .cfg_waitrequest(wait2), .cfg_write(wr2), .cfg_address(addr2), .cfg_writedata(wdata2));
int held_off2 = 0;
always @(posedge clk50) if (wr2 && wait2) held_off2++;

function automatic real now_ns();             // the bench's times, in ns
    return $realtime / 1000.0;
endfunction

integer passes = 0, fails = 0;
task automatic check(input bit ok, input string what);
    if (ok) passes++;
    else begin fails++; $display("FAIL  %s", what); end
endtask

// ---- what the clocks do -----------------------------------------------------------------
realtime cpu_rise = 0, cpu_fall = 0, cpu_hi = 0, cpu_lo = 0;
always @(posedge cpu_clk) begin cpu_lo = now_ns() - cpu_fall; cpu_rise = now_ns(); end
always @(negedge cpu_clk) begin cpu_hi = now_ns() - cpu_rise; cpu_fall = now_ns(); end
realtime mem_rise = 0, mem_fall = 0, mem_hi = 0, mem_lo = 0;
always @(posedge clk_mem) begin mem_lo = now_ns() - mem_fall; mem_rise = now_ns(); end
always @(negedge clk_mem) begin mem_hi = now_ns() - mem_rise; mem_fall = now_ns(); end

// the instant each change reaches the PLL, and the machine's state then
int      applies = 0;
realtime applied_at = 0;
int      held_at_apply = 1;
reg      seen22 = 1'b0;
always @(to_pll[22]) if (to_pll[22] != seen22) begin
    seen22 = to_pll[22];
    applies++;
    applied_at = now_ns();
    if (!reset_cpu || !hold) held_at_apply = 0;
end

// hold: when it last rose and fell; the first write since it rose
realtime hold_rose = 0, hold_fell = 0;
always @(posedge hold) hold_rose = now_ns();
always @(negedge hold) hold_fell = now_ns();

task automatic expect_cpu(input real hi_ns, input string what);
    repeat (4) @(posedge cpu_clk);
    check(cpu_hi == hi_ns && cpu_lo == hi_ns,
          $sformatf("%s: cpu_clk %0.1f ns high, %0.1f low, want %0.1f each", what, cpu_hi, cpu_lo, hi_ns));
    check(mem_hi == 5.0 && mem_lo == 5.0,
          $sformatf("%s: clk_mem %0.1f/%0.1f ns, want 5/5", what, mem_hi, mem_lo));
endtask

// Writes from n0 on are exactly mode 0, C1 = c, START
task automatic expect_writes(input int n0, input [31:0] c, input string what);
    check(cfg.nwr == n0 + 3, $sformatf("%s: %0d writes, want 3", what, cfg.nwr - n0));
    if (cfg.nwr == n0 + 3) begin
        check(cfg.wr_addr[n0] == 6'd0 && cfg.wr_data[n0] == 32'd0,
              $sformatf("%s: first the mode, waitrequest: %0d <- %08x", what, cfg.wr_addr[n0], cfg.wr_data[n0]));
        check(cfg.wr_addr[n0 + 1] == 6'd5 && cfg.wr_data[n0 + 1] == c,
              $sformatf("%s: then C1: %0d <- %08x, want 5 <- %08x", what, cfg.wr_addr[n0 + 1], cfg.wr_data[n0 + 1], c));
        check(cfg.wr_addr[n0 + 2] == 6'd2,
              $sformatf("%s: then START: %0d", what, cfg.wr_addr[n0 + 2]));
    end
endtask

// A change made in a reset: the machine held across it, and for SETTLE after
task automatic expect_held(input string what);
    check(held_at_apply == 1, $sformatf("%s: the machine is in reset when the counter changes", what));
    check(hold_fell - applied_at >= SETTLE * 20.0,
          $sformatf("%s: held %0.0f ns after the change, want >= %0d", what, hold_fell - applied_at, SETTLE * 20));
    check(!hold && !reset_cpu || req, $sformatf("%s: and then let go", what));
endtask

// wait for the switch to have finished whatever it was doing (between two
// changes in one reset, hold is low for a clock)
task automatic settle;
    repeat (8) @(posedge clk50);
    forever begin
        wait (!hold);
        repeat (16) @(posedge clk50);
        if (!hold) break;
    end
endtask

realtime first_wr = 0;
int      first_seen = 0;
always @(posedge clk50) if (wr && !first_seen) begin first_wr = now_ns(); first_seen = 1; end

initial begin
    int n0, a0;
    $display("tb_mister_cpuclk: sun3_mister_cpuclk, the main PLL's C1 through pll_cfg");

    // ---- power-up at the default: nothing to do ----
    #50000000;                                         // 50 us: past lock and the core's init
    check(cfg.nwr == 0 && !hold, "20 MHz at power-up: no reconfiguration");
    expect_cpu(25.0, "the bitstream's counter");

    // ---- power-up with 33 MHz saved (the second board) ----
    check(held_off2 > 0, $sformatf("33 MHz saved: the first write was held off %0d clocks", held_off2));
    check(cfg2.nwr == 3 && cfg2.wr_addr[0] == 6'd0 && cfg2.wr_addr[1] == 6'd5 &&
          cfg2.wr_data[1] == 32'h0006_0807 && cfg2.wr_addr[2] == 6'd2,
          $sformatf("33 MHz saved: mode, C1, START (%0d writes)", cfg2.nwr));
    begin
        realtime r0, f0, r1;
        @(posedge cpu_clk2); r0 = now_ns();
        @(negedge cpu_clk2); f0 = now_ns();
        @(posedge cpu_clk2); r1 = now_ns();
        check(f0 - r0 == 15.0 && r1 - f0 == 15.0,
              $sformatf("33 MHz saved: cpu_clk %0.1f/%0.1f ns, want 15/15", f0 - r0, r1 - f0));
    end
    check(cfg2.faults == 0, "33 MHz saved: the writes were held under waitrequest");
    req2 = 1'b0;
    req = 1'b0;                                     // the machine runs
    #20000000;

    // ---- an OSD change while the machine runs waits ----
    sel = 2'd2;
    #200000000;
    check(cfg.nwr == 0 && !hold && !reset_cpu, "33 MHz chosen while running: nothing yet");
    expect_cpu(25.0, "still 20 MHz");

    // ---- the OSD's reset: a short pulse ----
    n0 = cfg.nwr; first_seen = 0;
    @(posedge clk50); req = 1'b1;
    #1000000;
    req = 1'b0;
    #2000000;
    check(hold && reset_cpu, "the reset is held by the change");
    settle();
    expect_writes(n0, 32'h0006_0807, "33 MHz");
    expect_cpu(15.0, "33.33 MHz");
    expect_held("33 MHz");
    check(first_wr - hold_rose >= 256 * 20.0,
          $sformatf("33 MHz: hold %0.0f ns before the first write, want >= %0d", first_wr - hold_rose, 256 * 20));
    check(cur == 2'd2, "33 MHz: cur is 2");

    // ---- the same setting is not made again ----
    n0 = cfg.nwr;
    @(posedge clk50); req = 1'b1; #1000000; req = 1'b0;
    #100000000;
    check(cfg.nwr == n0 && !hold, "a reset at the same setting: nothing");

    // ---- a change at power-up, the reset long ----
    n0 = cfg.nwr; a0 = applies;
    sel = 2'd1;
    @(posedge clk50); req = 1'b1;
    settle();
    expect_writes(n0, 32'h0004_0A0A, "25 MHz");
    expect_cpu(20.0, "25 MHz");
    expect_held("25 MHz");
    check(reset_cpu, "25 MHz: the machine's own reset still holds it");
    check(applies == a0 + 1, "25 MHz: one change");
    req = 1'b0;
    #2000000;
    check(!reset_cpu, "25 MHz: released with the machine's reset");

    // ---- 3 is 20 MHz ----
    n0 = cfg.nwr;
    sel = 2'd3;
    @(posedge clk50); req = 1'b1; #1000000; req = 1'b0;
    settle();
    expect_writes(n0, 32'h0006_0D0C, "3, as 20 MHz");
    expect_cpu(25.0, "20 MHz again");
    check(cur == 2'd0, "3 is kept as 0");
    n0 = cfg.nwr;
    sel = 2'd0;
    @(posedge clk50); req = 1'b1; #1000000; req = 1'b0;
    #100000000;
    check(cfg.nwr == n0 && !hold, "then 0: the same, nothing");

    // ---- a setting changed in the middle of a change is made next ----
    n0 = cfg.nwr; a0 = applies;
    sel = 2'd2;
    @(posedge clk50); req = 1'b1;
    wait (cfg.nwr == n0 + 2);                       // C1 written
    sel = 2'd1;
    settle();
    check(applies == a0 + 2, $sformatf("changed during a change: %0d changes, want 2", applies - a0));
    check(cfg.nwr == n0 + 6 && cfg.wr_data[n0 + 4] == 32'h0004_0A0A,
          $sformatf("changed during a change: %0d writes, the second C1 %08x", cfg.nwr - n0, cfg.wr_data[n0 + 4]));
    expect_cpu(20.0, "the second setting, 25 MHz");
    req = 1'b0;
    #2000000;

    // ---- nothing while the PLL is unlocked ----
    n0 = cfg.nwr;
    pll_i.locked = 1'b0;
    sel = 2'd0;
    @(posedge clk50); req = 1'b1;
    #100000000;
    check(cfg.nwr == n0 && !hold, "unlocked: no change, no hold");
    pll_i.locked = 1'b1;
    settle();
    expect_writes(n0, 32'h0006_0D0C, "after the lock");
    expect_cpu(25.0, "20 MHz after the lock");
    req = 1'b0;
    #2000000;

    check(cfg.faults == 0, $sformatf("Avalon: %0d writes not held under waitrequest, or reads", cfg.faults));

    $display("");
    $display("tb_mister_cpuclk: %0d checks, %0d failed", passes + fails, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

initial begin
    repeat (50) #1_000_000_000;                     // 50 ms
    $display("tb_mister_cpuclk: timeout");
    $display("FAIL");
    $finish;
end

endmodule
