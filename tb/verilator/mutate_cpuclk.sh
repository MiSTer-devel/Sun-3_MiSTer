#!/bin/bash
# Mutation check for tb_mister_cpuclk: each line puts a bug into a copy of
# rtl/sun3_mister_cpuclk.sv, and the test must fail.
#
#     tb/verilator/mutate_cpuclk.sh
#
# A "NOT CAUGHT" is a hole in the test, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
W=/tmp/sun3_cpuclkmut
mkdir -p $W
run() {
  name="$1"; shift
  cp $RTL/sun3_mister_cpuclk.sv $W/dut.sv
  sed -i "$@" $W/dut.sv
  if cmp -s $RTL/sun3_mister_cpuclk.sv $W/dut.sv; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY -I$RTL/sun3 --top-module tb_mister_cpuclk \
    --Mdir $W/obj -o tb tb_mister_cpuclk.sv pll_stub.sv $W/dut.sv $RTL/sun3/reset_sync.sv >$W/build.log 2>&1 \
    || { echo "$name: BUILD FAILED"; return; }
  out=$($W/obj/tb 2>&1)
  summary=$(echo "$out" | grep -E "^tb_mister_cpuclk: [0-9]|timeout")
  first=$(echo "$out" | grep -m1 "^FAIL ")
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary -- $first"; fi
}
# the counts
run "33 MHz without the odd bit"   -e "s/2'd2:    c1 = {9'd0, 5'd1, 1'b1, 1'b0, 8'd8,  8'd7};/2'd2:    c1 = {9'd0, 5'd1, 1'b0, 1'b0, 8'd8,  8'd7};/"
run "33 MHz is /16"                -e "s/8'd8,  8'd7};/8'd8,  8'd8};/"
run "25 MHz 11 and 9"              -e "s/8'd10, 8'd10};/8'd11, 8'd9};/"
run "20 MHz is /26"                -e "s/8'd13, 8'd12};/8'd13, 8'd13};/"
run "counter 0, clk_mem's"         -e "s/2'd2:    c1 = {9'd0, 5'd1,/2'd2:    c1 = {9'd0, 5'd0,/"
run "the bypass bit"               -e "s/2'd1:    c1 = {9'd0, 5'd1, 1'b0, 1'b0,/2'd1:    c1 = {9'd0, 5'd1, 1'b0, 1'b1,/"
run "3 kept as 3"                  -e "s/canon = (s == 2'd3) ? 2'd0 : s;/canon = s;/"
# when it changes
run "changes while running"        -e "s/if (req_s2 \&\& lck_s2 \&\& want_ok/if (lck_s2 \&\& want_ok/"
run "changes while unlocked"       -e "s/if (req_s2 \&\& lck_s2 \&\& want_ok/if (req_s2 \&\& want_ok/"
run "no hold"                      -e "s/hold  <= 1'b1;/hold  <= 1'b0;/"
run "no quiet time before"         -e "s/if (t == 17'd255) begin/if (1'b1) begin/"
run "let go at once"               -e "s/if (t == 17'(SETTLE - 1)) begin/if (1'b1) begin/"
run "done without waitrequest"     -e "s/else if (!cfg_waitrequest \&\& lck_s2) begin/else if (lck_s2) begin/"
run "cur never updated"            -e "/cur   <= next;/d"
# the writes
run "C1 into the M counter"        -e "s/cfg_address   <= REG_C;/cfg_address   <= 6'd4;/"
run "no START"                     -e "s/cfg_address   <= REG_START;/cfg_address   <= REG_MODE;/"
run "polling mode"                 -e "s/cfg_writedata <= 32'd0;              \/\/ waitrequest mode/cfg_writedata <= 32'd1;/"
run "a write not held"             -e "s/if (accepted) cfg_write <= 1'b0;/if (cfg_write) cfg_write <= 1'b0;/"
