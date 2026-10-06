//
// sun3_mister_tod.sv
//
// The Sun-3's time of day, from MiSTer's clock.
//
// Main_MiSTer sends hps_io's RTC when it loads the core and every minute
// after: MiSTer's local time as BCD -- second, minute, hour, day of the month,
// month, the year's last two digits -- then the weekday (0 Sunday .. 6, plain
// binary), with bit 64 toggling on each update (user_io.cpp, send_rtc).  The
// first one is turned into what a Sun-3 keeps in its ICM7170 and loaded into
// it; later ones are ignored, as a battery-backed clock would ignore them, so
// a time set with date(1) stands until the core is loaded again.
//
// Unlike the Sun-2's MM58167, the 7170 holds a whole date.  SunOS and NetBSD
// keep it as binary counters, 24-hour time, the weekday 0..6 from Sunday, and
// the year as years since 1968 (NetBSD sys/arch/sun3/sun3/clock.c: sc_year0 =
// 1968; the chip's own leap rule is "divisible by 4", true of 1968) -- so
// 2026 is 58, and the chip reaches 2067.
//
// back28 sets the clock 28 years back -- 2026 becomes 1998.  The calendar
// repeats every 28 years between 1901 and 2099 (weekdays and leap years
// alike), so the date, the weekday and the time of day stay exactly MiSTer's;
// only the year is one SunOS 4.1.1 was built for, short of 2000.  A MiSTer
// whose clock was never set (1970..1995) is loaded as it is, never shifted.
//
// The Sun's idea of time is UTC with its time zone applied on top, and this
// is local time, so the Sun shows MiSTer's wall clock when its zone is GMT.
//
// tod is held once loaded, and `ld' toggles when it is: the receiver, in
// another clock, takes it on the toggle (Sun-3.sv).
//
`timescale 1ns / 1ps

module sun3_mister_tod #(
    parameter bit ONCE = 1'b1           // only the first update; 0 for tests
) (
    input  wire        clk,             // hps_io's clock
    input  wire [64:0] rtc,             // hps_io RTC: [64] toggles
    input  wire        back28,          // 28 years earlier
    output reg         ld  = 1'b0,      // toggles each time tod is loaded
    output reg  [55:0] tod = 56'd0      // binary {year-1968, month, date, weekday, hour, minute, second}
);

    function automatic [6:0] unbcd(input [7:0] b);
        unbcd = {3'b000, b[7:4]} * 7'd10 + {3'b000, b[3:0]};
    endfunction

    reg  seen    = 1'b0;
    reg  loaded  = 1'b0;
    reg  started = 1'b0;

    wire [6:0] yy   = unbcd(rtc[47:40]);
    wire [7:0] full = (yy < 7'd70) ? 8'd100 + {1'b0, yy} : {1'b0, yy};   // years since 1900
    // years since 1968, shifted only where the result stays within the chip
    wire [7:0] yr   = (back28 && full >= 8'd96) ? full - 8'd96 : full - 8'd68;

    always @(posedge clk) begin
        if (!started) begin
            started <= 1'b1;
            seen    <= rtc[64];             // what was there before us is not an update
        end else if (rtc[64] != seen) begin
            seen <= rtc[64];
            if (!(ONCE && loaded) && full >= 8'd68 && full < 8'd168) begin
                tod <= {yr,
                        1'b0, unbcd(rtc[39:32]),            // month 1..12
                        1'b0, unbcd(rtc[31:24]),            // date 1..31
                        5'd0, rtc[50:48],                   // weekday 0..6
                        1'b0, unbcd(rtc[23:16]),            // hour 0..23
                        1'b0, unbcd(rtc[15:8]),             // minute
                        1'b0, unbcd(rtc[7:0])};             // second
                ld     <= ~ld;
                loaded <= 1'b1;
            end
        end
    end

endmodule
