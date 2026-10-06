//============================================================================
//  tb_mister_tod -- rtl/sun3_mister_tod.sv into rtl/sun3/icm7170.v as
//  sun3_fpga.v builds it with SUN3_TOD_LOAD (TIME_RESET = 0) and
//  SUN3_TOD_TICK_HZ, its oscillator rtl/sun3_mister_tick.sv, read back as
//  SunOS and NetBSD read a Sun-3's 7170: hundredths first (which latches the
//  rest), then hours, minutes, seconds, month, date, year since 1968, weekday.
//
//  As in Sun-3.sv, the converter and the tick's counter run on a fixed clock
//  (mclk, clk_mem's 100 MHz) and the chip on the CPU's (clk), whose speed the
//  bench changes as the OSD does.  The tick is scaled down (FREQ = 1000 a
//  second, a tick every 20 mclk clocks: a second is 200 us) so that a day
//  goes by in seconds of simulation.
//
//  Checked: Main_MiSTer's RTC message (BCD, weekday binary) becomes the chip's
//  binary counters with the year counted from 1968; 28 years back; only the
//  first update loads; the chip runs from power-up, and a machine reset keeps
//  the time running but turns its interrupt off; the end of a month, of
//  November (the year stays), of December (the year turns), 28/29 February,
//  and the weekday stepping with the date.  (Each of the last three was wrong
//  in the model as it came from Sun-3_FPGA.)  And Phase 6's: the tick is
//  one CPU clock for every DIV mclk clocks, at every CPU speed, and the time
//  keeps to it, not to the CPU's clock, as that clock changes under it.
//
//      make -C tb/verilator tb_mister_tod
//============================================================================
`timescale 1ns/1ps

module tb_mister_tod;

localparam int  FREQ   = 1000;                  // ticks a second, here
localparam int  DIV    = 20;                    // mclk clocks a tick
localparam real SEC_NS = FREQ * DIV * 10.0;     // a second, in ns

reg mclk = 0;
always #5 mclk = ~mclk;                         // 100 MHz, fixed

realtime cpu_half = 12.5;                       // 40 MHz to start with
reg clk = 0;
always #(cpu_half) clk = ~clk;

task automatic wait_s(input real s);
    #(s * SEC_NS);
endtask

// ---- the oscillator --------------------------------------------------------------
wire tick;
sun3_mister_tick #(.DIV(DIV)) osc (.clk_src(mclk), .clk_dst(clk), .tick(tick));

integer ticks = 0;
always @(posedge clk) if (tick) ticks <= ticks + 1;

// ---- the converter -------------------------------------------------------------
reg  [64:0] rtc = 0;
reg         back28 = 0;
wire        tgl;
wire [55:0] tod;

sun3_mister_tod #(.ONCE(1'b1)) conv (.clk(mclk), .rtc(rtc), .back28(back28), .ld(tgl), .tod(tod));

// 28 years back, on a converter of its own (it loads once)
reg  [64:0] rtc3 = 0;
wire        tgl3;
wire [55:0] tod3;
sun3_mister_tod #(.ONCE(1'b1)) conv3 (.clk(mclk), .rtc(rtc3), .back28(1'b1), .ld(tgl3), .tod(tod3));

// a second converter that takes every update, for the rollover tests
reg  [64:0] rtc2 = 0;
wire        tgl2;
wire [55:0] tod2;
sun3_mister_tod #(.ONCE(1'b0)) conv2 (.clk(mclk), .rtc(rtc2), .back28(1'b0), .ld(tgl2), .tod(tod2));
reg use2 = 0;

// the crossing as Sun-3.sv makes it
reg [2:0] s = 0;
always @(posedge clk) s <= {s[1:0], use2 ? tgl2 : tgl};
wire ld = s[2] ^ s[1];

// ---- the chip ---------------------------------------------------------------------
reg        resetn = 0;
reg  [4:0] a = 0;
reg  [7:0] din = 0;
reg        rd_n = 1, wr_n = 1;
wire [7:0] dout;
wire       int_n;

icm7170 #(.FREQ(FREQ), .TIME_RESET(0)) chip (
    .CLK(clk), .TICK(tick), .D_IN(din), .D_OUT(dout), .D_EN(), .A(a), .RD(rd_n), .WR(wr_n), .CS(1'b0),
    .RESETn(resetn), .LOAD(ld), .LOAD_TIME(use2 ? tod2 : tod), .INTERRUPT(int_n));

integer passes = 0, fails = 0;
task automatic check(input bit ok, input string what);
    if (ok) passes++;
    else begin fails++; $display("FAIL  %s", what); end
endtask

task automatic rd(input [4:0] r, output [7:0] v);
    @(posedge clk); a <= r; rd_n <= 0;
    @(posedge clk); @(negedge clk); v = dout;
    rd_n <= 1;
    repeat (2) @(posedge clk);
endtask

task automatic wr(input [4:0] r, input [7:0] v);
    @(posedge clk); a <= r; din <= v; wr_n <= 0;
    @(posedge clk); wr_n <= 1;
    repeat (2) @(posedge clk);
endtask

// The time as software reads it: {year, month, date, weekday, hour, minute, second}
task automatic read_time(output [55:0] t);
    reg [7:0] h, hr, mi, se, mo, da, yr, wd;
    begin
        rd(5'h00, h);                           // latches the rest
        rd(5'h01, hr); rd(5'h02, mi); rd(5'h03, se);
        rd(5'h04, mo); rd(5'h05, da); rd(5'h06, yr); rd(5'h07, wd);
        t = {yr, mo, da, wd, hr, mi, se};
    end
endtask

function automatic [7:0] b(input int v); return {4'(v / 10), 4'(v % 10)}; endfunction

// Main_MiSTer's message: BCD second..year, then the weekday in binary, on
// hps_io's clock
task automatic send(input int yy, mo, da, hh, mi, ss, wd, input bit second_conv = 0);
    reg [64:0] m;
    begin
        @(posedge mclk);
        if (second_conv) begin
            m = {~rtc2[64], 8'h40, 8'(wd), b(yy), b(mo), b(da), b(hh), b(mi), b(ss)};
            rtc2 <= m;
        end else begin
            m = {~rtc[64], 8'h40, 8'(wd), b(yy), b(mo), b(da), b(hh), b(mi), b(ss)};
            rtc <= m;
        end
        repeat (8) @(posedge mclk);
        repeat (4) @(posedge clk);              // and across into the chip's clock
    end
endtask

function automatic [55:0] t(input int yr, mo, da, wd, hh, mi, ss);
    t = {8'(yr), 8'(mo), 8'(da), 8'(wd), 8'(hh), 8'(mi), 8'(ss)};
endfunction

task automatic expect_time(input [55:0] want, input string what);
    reg [55:0] got;
    begin
        read_time(got);
        check(got == want, $sformatf("%s: read %014x, want %014x", what, got, want));
    end
endtask

task automatic run_chip;                         // RUN, 24-hour, interrupts enabled
    wr(5'h11, 8'h1C);
endtask

// The ticks over one second at the CPU's present speed: one each, every DIV
// mclk clocks
task automatic count_ticks(input string speed);
    integer t0;
    begin
        @(posedge mclk);
        t0 = ticks;
        wait_s(1.0);
        check(ticks - t0 >= FREQ - 1 && ticks - t0 <= FREQ + 1,
              $sformatf("%s: %0d ticks in a second, want %0d", speed, ticks - t0, FREQ));
    end
endtask

initial begin
    $display("tb_mister_tod: sun3_mister_tod into the ICM7170, its oscillator sun3_mister_tick");
    repeat (4) @(posedge clk);

    // the core loads while the machine is still in reset: the time must land
    send(26, 10, 4, 13, 45, 30, 0);              // Sunday 4 October 2026, 13:45:30
    repeat (10) @(posedge clk);
    resetn = 1;
    repeat (4) @(posedge clk);
    expect_time(t(58, 10, 4, 0, 13, 45, 30), "loaded during reset: 2026 is year 58 from 1968");

    // later updates are ignored (ONCE)
    send(26, 10, 4, 13, 46, 0, 0);
    expect_time(t(58, 10, 4, 0, 13, 45, 30), "a later update does not load");

    // running from power-up, nobody having started it: two seconds go by.  (Out
    // of reset the model's divider starts at 0xFF -- 255 us of the board's
    // 1 MHz, a quarter of a second at this bench's FREQ -- hence the margin.)
    wait_s(2.4);
    expect_time(t(58, 10, 4, 0, 13, 45, 32), "two seconds later, running from power-up");

    // a machine reset keeps the time, and the chip running, interrupt off
    run_chip();                                  // as SunOS leaves it: interrupts on
    wr(5'h10, 8'h02);                            // the 1/100 s interrupt unmasked
    wait_s(0.03);
    check(int_n == 1'b0, "SunOS's 100 Hz interrupt is on");
    resetn = 0; repeat (5) @(posedge clk); resetn = 1;
    begin
        reg [55:0] a1, a2;
        reg [7:0]  st;
        rd(5'h10, st);                           // clears what was pending
        wait_s(0.5);                             // past the divider's start-up, many ticks
        check(int_n == 1'b1, "after a machine reset the chip interrupts no more");
        read_time(a1);
        wait_s(2.0);
        read_time(a2);
        check(a1[55:8] == 48'(t(58, 10, 4, 0, 13, 45, 0) >> 8) && a1[7:0] >= 8'd32,
              $sformatf("a machine reset keeps the time: %014x", a1));
        check(a2[7:0] == a1[7:0] + 8'd2, $sformatf("and the clock running: %014x then %014x", a1, a2));
    end

    // 28 years back: 2026 is 1998, year 30 from 1968; MiSTer never set (1970)
    // is not shifted
    @(posedge mclk);
    rtc3 <= {~rtc3[64], 8'h40, 8'd0, b(26), b(10), b(4), b(13), b(45), b(30)};
    repeat (8) @(posedge mclk);
    check(tod3 == t(30, 10, 4, 0, 13, 45, 30), $sformatf("28 years back: %014x", tod3));

    // (switching the bench's mux is a turn of its own: let it cross before
    // the second converter's first turn, or the two cancel)
    use2 = 1;
    repeat (4) @(posedge clk);
    send(26, 2, 28, 23, 59, 59, 6, 1);           // Saturday 28 Feb 2026
    expect_time(t(58, 2, 28, 6, 23, 59, 59), "a second converter loads every update");
    run_chip();
    wait_s(1.05);
    expect_time(t(58, 3, 1, 0, 0, 0, 0), "28 Feb 2026 is not a leap year");

    send(28, 2, 28, 23, 59, 59, 1, 1);           // 2028 is year 60, a leap year
    wait_s(1.05);
    expect_time(t(60, 2, 29, 2, 0, 0, 0), "28 Feb 2028 goes to the 29th");

    send(26, 11, 30, 23, 59, 59, 1, 1);
    wait_s(1.05);
    expect_time(t(58, 12, 1, 2, 0, 0, 0), "30 Nov goes to 1 Dec, same year");

    send(26, 12, 31, 23, 59, 59, 4, 1);
    wait_s(1.05);
    expect_time(t(59, 1, 1, 5, 0, 0, 0), "31 Dec goes to 1 Jan, the next year");

    send(26, 4, 30, 23, 59, 59, 4, 1);
    wait_s(1.05);
    expect_time(t(58, 5, 1, 5, 0, 0, 0), "30 Apr goes to 1 May");

    // ---- Phase 6: the CPU's clock changes, the tick and the time do not ----
    // The board's CPU clock is 20, 25 or 33.33 MHz against a 1 MHz tick; here
    // 40, 66.7 and 25 MHz against 5 MHz, with a change between each.  A load
    // zeroes the hundredths, so the reads, half a second after it, are clear
    // of a second's edge.
    count_ticks("CPU clock 25 ns");
    cpu_half = 7.5;
    count_ticks("CPU clock 15 ns");
    cpu_half = 20.0;
    count_ticks("CPU clock 40 ns");

    cpu_half = 12.5;
    send(26, 10, 5, 12, 0, 0, 1, 1);             // Monday 5 October 2026, 12:00:00
    wait_s(0.5);
    expect_time(t(58, 10, 5, 1, 12, 0, 0), "loaded, the CPU clock at 25 ns");
    wait_s(3.0);
    expect_time(t(58, 10, 5, 1, 12, 0, 3), "three seconds at 25 ns");
    cpu_half = 7.5;
    wait_s(3.0);
    expect_time(t(58, 10, 5, 1, 12, 0, 6), "three more at 15 ns");
    cpu_half = 20.0;
    wait_s(3.0);
    expect_time(t(58, 10, 5, 1, 12, 0, 9), "three more at 40 ns");
    cpu_half = 12.5;
    wait_s(60.0);
    expect_time(t(58, 10, 5, 1, 12, 1, 9), "and a minute after that, at 25 ns");

    $display("");
    $display("tb_mister_tod: %0d checks, %0d failed", passes + fails, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

endmodule
