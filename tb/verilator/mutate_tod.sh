#!/bin/bash
# Mutation check for tb_mister_tod: each line puts a bug into a copy of the
# RTC converter, of the ICM7170 or of its oscillator (sun3_mister_tick), and
# the test must fail.  The ICM7170 ones include the three the model had as it
# came from Sun-3_FPGA, and the two ways it could still follow the CPU's
# clock instead of its tick.
#
#     tb/verilator/mutate_tod.sh
#
# A "NOT CAUGHT" is a hole in the test, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
W=/tmp/sun3_todmut
mkdir -p $W
run() {
  name="$1"; which="$2"; shift 2
  cp $RTL/sun3_mister_tod.sv $W/conv.sv
  cp $RTL/sun3_mister_tick.sv $W/tick.sv
  cp $RTL/sun3/icm7170.v $W/chip.v
  case "$which" in
    conv) f=$W/conv.sv; orig=$RTL/sun3_mister_tod.sv ;;
    tick) f=$W/tick.sv; orig=$RTL/sun3_mister_tick.sv ;;
    *)    f=$W/chip.v;  orig=$RTL/sun3/icm7170.v ;;
  esac
  sed -i "$@" $f
  if cmp -s $orig $f; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module tb_mister_tod \
    --Mdir $W/obj -o tb tb_mister_tod.sv $W/conv.sv $W/tick.sv $W/chip.v >$W/build.log 2>&1 || { echo "$name: BUILD FAILED"; return; }
  out=$($W/obj/tb 2>&1)
  summary=$(echo "$out" | grep -E "^tb_mister_tod: [0-9]|timeout")
  first=$(echo "$out" | grep -m1 "^FAIL ")
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary -- $first"; fi
}
# the converter
run "years from 1970"              conv -e "s/: full - 8'd68;/: full - 8'd70;/"
run "never 28 years back"          conv -e "s/(back28 \&\& full >= 8'd96)/(1'b0)/"
run "every update loads"           conv -e "s/if (!(ONCE \&\& loaded) \&\& /if (/"
run "month and date swapped"       conv -e "s/1'b0, unbcd(rtc\[39:32\]),            \/\/ month/1'b0, unbcd(rtc[31:24]),            \/\/ month/"
# the chip
run "year turns after November"    chip -e "s/if (counter_month == 8'd12) begin/if (counter_month == 8'd11) begin/"
run "weekday never advances"       chip -e "/was never advanced/d"
run "a reset stops the clock"      chip -e "s/command_reg <= TIME_RESET ? 8'b00000101 : (command_reg \& 8'hEF);/command_reg <= 8'b00000101;/"
run "a reset keeps the interrupt"  chip -e "s/command_reg <= TIME_RESET ? 8'b00000101 : (command_reg \& 8'hEF);/command_reg <= TIME_RESET ? 8'b00000101 : command_reg;/"
run "a reset clears the time"      chip -e "s/if (TIME_RESET) begin/if (1'b1) begin/"
run "LOAD ignored"                 chip -e "s/      if (LOAD) begin/      if (1'b0) begin/"
run "the divider counts CLK"       chip -e "s/end else if (TICK) begin/end else begin/"
run "a hundredth each CLK at zero" chip -e "s/assign tick_100hz = TICK \& (osc_divider == 31'd0);/assign tick_100hz = (osc_divider == 31'd0);/"
# the oscillator
run "a tick every DIV+1"           tick -e "s/if (cnt == DIV - 1) begin/if (cnt == DIV) begin/"
run "a two-clock pulse"            tick -e "s/assign tick = s\[2\] ^ s\[1\];/assign tick = s[2] ^ s[0];/"
run "the toggle, not its turns"    tick -e "s/assign tick = s\[2\] ^ s\[1\];/assign tick = s[1];/"
run "every other turn"             tick -e "s/assign tick = s\[2\] ^ s\[1\];/assign tick = s[1] \& ~s[2];/"
