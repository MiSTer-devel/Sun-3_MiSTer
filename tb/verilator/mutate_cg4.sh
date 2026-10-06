#!/bin/bash
# Mutation check for tb_cg4: each line puts a bug into a copy of sun3_cg4.sv,
# and the test must fail.
#
#     tb/verilator/mutate_cg4.sh
#
# A "NOT CAUGHT" is a hole in the test, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
W=/tmp/sun3_cg4mut
mkdir -p $W
run() {
  name="$1"; shift
  cp $RTL/sun3/sun3_cg4.sv $W/cg4.sv
  sed -i "$@" $W/cg4.sv
  if cmp -s $RTL/sun3/sun3_cg4.sv $W/cg4.sv; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator --binary --timing -I$RTL/sun3 -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module tb_cg4 \
    --Mdir $W/obj -o tb tb_cg4.sv $W/cg4.sv >$W/build.log 2>&1 || { echo "$name: BUILD FAILED"; return; }
  out=$($W/obj/tb 2>&1)
  summary=$(echo "$out" | grep -E "^tb_cg4: [0-9]|timeout")
  first=$(echo "$out" | grep -m1 "^FAIL ")
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary -- $first"; fi
}
run "a bw2's ID, not the cg4's"      -e "s/localparam \[7:0\] P4_ID = 8'h41;/localparam [7:0] P4_ID = 8'h01;/"
run "registers from the high lane"   -e "s/3'b0_00: begin addr <= wdata\[7:0\];/3'b0_00: begin addr <= wdata[31:24];/"
run "packed components low first"    -e "s/comp_k = d\[8 \* (n - 1 - k) +: 8\];/comp_k = d[8 * k +: 8];/"
run "an entry reloaded per cycle"    -e "s/cst    <= rw_n ? C_LOAD : C_COMP;/cst    <= C_LOAD;/"
run "address steps after green"      -e "0,/if (comp == 2'd2) begin$/s//if (comp == 2'd1) begin/"
# (Skipping the wait at the start of a read is harmless: the address has been
# still for several clocks by then.  Crossing to the next entry it is not.)
run "the next entry not waited for"  -e "s/cst <= C_LOAD;                  \/\/ the next entry, from the RAM/cst <= C_TAKE;/"
run "overlay entries 1 and 2 swapped" -e "s/2'd1: ovl1 <= put(ovl1, comp, wdata\[7:0\]);/2'd1: ovl2 <= put(ovl2, comp, wdata[7:0]);/"
run "video bit 4, not 5"             -e "s/video_on <= wdata\[5\];/video_on <= wdata[4];/"
run "retrace never interrupts"       -e "s/if (rt_rise \&\& int_en) int_pend <= 1'b1;/if (1'b0) int_pend <= 1'b1;/"
run "the interrupt never clears"     -e "s/if (wdata\[2\]) int_pend <= 1'b0;/if (1'b0) int_pend <= 1'b0;/"
# SunOS's own accesses (the kernel's p4probe, the mono driver, FBIOSVIDEO, the
# retrace handler):
run "the P4 register's ID writable"  -e "s/localparam \[7:0\] P4_ID = 8'h41;/reg [7:0] P4_ID = 8'h41;/" \
                                     -e "s/video_on <= wdata\[5\];/video_on <= wdata[5]; P4_ID[6:0] <= wdata[30:24];/"
run "pending cleared only if enabled" -e "s/if (wdata\[2\]) int_pend <= 1'b0;/if (wdata[2] \&\& wdata[1]) int_pend <= 1'b0;/"
run "a write never disables"         -e "s/int_en   <= wdata\[1\];/int_en   <= int_en | wdata[1];/"
run "every P4 write clears pending"  -e "s/if (wdata\[2\]) int_pend <= 1'b0;/if (1'b1) int_pend <= 1'b0;/"
run "retrace interrupts when disabled" -e "s/if (rt_rise \&\& int_en) int_pend <= 1'b1;/if (rt_rise) int_pend <= 1'b1;/"
run "the address keeps the component" -e "s/3'b0_00: begin addr <= wdata\[7:0\]; comp <= 2'd0; end/3'b0_00: begin addr <= wdata[7:0]; end/"
