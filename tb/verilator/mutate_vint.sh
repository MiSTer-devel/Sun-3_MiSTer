#!/bin/bash
# Mutation check for tb_vint: each line puts a bug into a copy of sun3_vint.v,
# and the test must fail.
#
#     tb/verilator/mutate_vint.sh
#
# A "NOT CAUGHT" is a hole in the test, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
W=/tmp/sun3_vintmut
mkdir -p $W
run() {
  name="$1"; shift
  cp $RTL/sun3/sun3_vint.v $W/vint.v
  sed -i "$@" $W/vint.v
  if cmp -s $RTL/sun3/sun3_vint.v $W/vint.v; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator --binary --timing -I$RTL/sun3 -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module tb_vint \
    --Mdir $W/obj -o tb tb_vint.sv $W/vint.v $RTL/sun3/sun3_irq_priority.v $RTL/sun3/sun3_cg4.sv >$W/build.log 2>&1 \
    || { echo "$name: BUILD FAILED"; return; }
  out=$($W/obj/tb 2>&1)
  summary=$(echo "$out" | grep -E "^tb_vint: [0-9]+ checks|timeout")
  first=$(echo "$out" | grep -m1 "^FAIL ")
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary -- $first"; fi
}
run "the blank's level, not its start"  -e "s/wire v_intx = VBLANK \& ~vblank_d;/wire v_intx = VBLANK;/"
run "the blank's end, not its start"    -e "s/wire v_intx = VBLANK \& ~vblank_d;/wire v_intx = ~VBLANK \& vblank_d;/"
run "the old wiring: blank OR P4"       -e "s/assign V_INT = P4_INT | (~seen \& v_intx);/assign V_INT = P4_INT | VBLANK;/"
run "both sources, always"              -e "s/assign V_INT = P4_INT | (~seen \& v_intx);/assign V_INT = P4_INT | v_intx;/"
run "the P4 board ignored"              -e "s/assign V_INT = P4_INT | (~seen \& v_intx);/assign V_INT = ~seen \& v_intx;/"
run "the flag never set"                -e "s/else if (P4_INT)/else if (1'b0)/"
run "the flag set by a blank"           -e "s/else if (P4_INT)/else if (VBLANK)/"
run "the flag kept across a reset"      -e "s/            seen <= 1'b0;/            seen <= seen;/"
