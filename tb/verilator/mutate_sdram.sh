#!/bin/bash
# Mutation check for tb_mister_sdram: each line puts a bug into a copy of the
# SDRAM adapter, and the test must fail.
#
#     tb/verilator/mutate_sdram.sh
#
# A "NOT CAUGHT" is a hole in the test, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
W=/tmp/sun3_sdrammut
mkdir -p $W
# run NAME SED-ARGS... mutates the adapter; CTRL=1 run ... the controller (sdram.sv)
run() {
  name="$1"; shift
  cp $RTL/sun3_mister_sdram.sv $W/adapter.sv
  cp $RTL/sdram.sv $W/ctrl.sv
  if [ -n "$CTRL" ]; then f=$W/ctrl.sv; o=$RTL/sdram.sv; else f=$W/adapter.sv; o=$RTL/sun3_mister_sdram.sv; fi
  sed -i "$@" $f
  if cmp -s $o $f; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module tb_mister_sdram \
    --Mdir $W/obj -o tb tb_mister_sdram.sv sdram_model.sv altddio_out_stub.v $W/ctrl.sv $W/adapter.sv \
    >$W/build.log 2>&1 || { echo "$name: BUILD FAILED"; return; }
  out=$($W/obj/tb 2>&1)
  summary=$(echo "$out" | grep -E "^tb_mister_sdram: [0-9]|timeout")
  first=$(echo "$out" | grep -m1 "^FAIL ")
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary -- $first"; fi
}
# The Sun-2's halfword order (a line's halfword j at [16j]): round-trips through
# the CPU, so only the layout and the scan-out checks can see it.
run "Sun-2 line order"             -e 's/line\[16 \* (widx ^ 3.d1) +: 16\] <= dout;/line[16 * widx +: 16] <= dout;/' \
                                   -e 's/line\[16 +: 16\] <= dout;   /line[0 +: 16] <= dout;   /'
run "halves of a write swapped"    -e 's/c_din   <= wb_dat_i\[31:16\];/c_din   <= wb_dat_i[15:0];/'
run "low half's byte selects"      -e 's/lo_bs   <= wb_sel_i\[1:0\];/lo_bs   <= 2'"'"'b11;/'
run "low half of a write dropped"  -e 's/lo_left <= (wb_sel_i\[1:0\] != 2.b00);/lo_left <= 1'"'"'b0;/'
run "no gap after an answer"       -e 's/                st <= S_GAP;/                st <= S_IDLE;/' \
                                   -e 's/                    st <= S_GAP;/                    st <= S_IDLE;/' \
                                   -e 's/                        st       <= S_GAP;/                        st       <= S_IDLE;/'
run "scan-out ignores the base"    -e 's/c_word <= FB_SDRAM_WORD + {fb_c_addr\[24:3\], 3.b000};/c_word <= {fb_c_addr[24:3], 3'"'"'b000};/' 
run "lane 3 from the stale line"   -e 's/(lane == 2.d3) ? {line\[127:112\], dout}/(lane == 2'"'"'d3) ? line[127:96]/'
run "Wishbone window base ignored" -e 's/wire        wb_is_fb  = !wb_is_cg \&\& (wb_adr_i >= FB_WB_BASE);/wire        wb_is_fb  = 1'"'"'b0;/'
run "cg4 window ignored"           -e 's/wire        wb_is_cg  = (wb_adr_i\[29:22\] == 8.hFF);/wire        wb_is_cg  = 1'"'"'b0;/'
run "cg4 overlay and enable swapped" -e 's/(wb_adr_i\[21:18\] == 4.h4) ? CG_OVERLAY_WORD : CG_ENABLE_WORD;/(wb_adr_i[21:18] == 4'"'"'h4) ? CG_ENABLE_WORD : CG_OVERLAY_WORD;/'
run "cg4 window's word not doubled" -e 's/wb_cg_base + {wb_adr_i\[17:0\], 1.b0}/wb_cg_base + wb_adr_i[17:0]/'
run "cg4 scan-out never yields"    -e 's/wire        pick_cs  = cs_req \& (cs_urgent | !wb_want | last_cpu);/wire        pick_cs  = cs_req;/'
run "cg4 urgency ignored"          -e 's/wire        pick_cs  = cs_req \& (cs_urgent | !wb_want | last_cpu);/wire        pick_cs  = cs_req \& (!wb_want | last_cpu);/'
run "cg4 scan-out starves"         -e 's/wire        pick_cs  = cs_req \& (cs_urgent | !wb_want | last_cpu);/wire        pick_cs  = cs_req \& (cs_urgent | !wb_want);/'
run "cg4 burst answered as the CPU's" -e 's/end else if (for_cs) begin/end else if (1'"'"'b0) begin/'
# Byte selects lost in the cg4's window alone (libpixrect's byte and halfword
# writes would clobber the neighbouring pixels); main memory's are checked above.
run "cg4 window's high half whole" -e 's/                        c_bs    <= wb_sel_i\[3:2\];/                        c_bs    <= wb_is_cg ? 2'"'"'b11 : wb_sel_i[3:2];/'
run "cg4 window's low half whole"  -e 's/                        lo_bs   <= wb_sel_i\[1:0\];/                        lo_bs   <= wb_is_cg ? 2'"'"'b11 : wb_sel_i[1:0];/' \
                                   -e 's/                        c_bs    <= wb_sel_i\[1:0\];/                        c_bs    <= wb_is_cg ? 2'"'"'b11 : wb_sel_i[1:0];/'
# The GX's engine port
run "engine never served"          -e 's/wire        pick_ge  = ge_req \& (!wb_want | !last_ge);/wire        pick_ge  = 1'"'"'b0;/'
run "engine never yields"          -e 's/wire        pick_ge  = ge_req \& (!wb_want | !last_ge);/wire        pick_ge  = ge_req;/'
run "engine burst answered as the CPU's" -e 's/end else if (for_ge) begin/end else if (1'"'"'b0) begin/'
run "engine's burst words not exchanged" -e 's/assign c_bdin\[16\*gj +: 16\] = ge_wdata\[16\*(gj^1) +: 16\];/assign c_bdin[16*gj +: 16] = ge_wdata[16*gj +: 16];/'
run "engine's byte selects ignored" -e 's/assign c_bbs\[2\*gj +: 2\]    = ge_sel\[2\*(gj^1) +: 2\];/assign c_bbs[2*gj +: 2]    = 2'"'"'b11;/'
run "engine's selects of the wrong word" -e 's/assign c_bbs\[2\*gj +: 2\]    = ge_sel\[2\*(gj^1) +: 2\];/assign c_bbs[2*gj +: 2]    = ge_sel[2*gj +: 2];/'
run "engine's burst not held to its end" -e '/S_WRB:/{n;s/if (ready_rise) begin/if (1'"'"'b1) begin/}'
# the controller's burst write (sdram.sv's wrb)
CTRL=1 run "burst: every word at column 0"   -e 's/SDRAM_A    <= {~bbs\[2\*wb_j +: 2\], 1.b0, cas_addr\[9:3\], wb_j};/SDRAM_A    <= {~bbs[2*wb_j +: 2], 1'"'"'b0, cas_addr[9:3], 3'"'"'d0};/'
CTRL=1 run "burst: every word word 0's mask" -e 's/SDRAM_A    <= {~bbs\[2\*wb_j +: 2\], 1.b0, cas_addr\[9:3\], wb_j};/SDRAM_A    <= {~bbs[1:0], 1'"'"'b0, cas_addr[9:3], wb_j};/'
CTRL=1 run "burst: seven words"              -e 's/if (wb_j == 3.d7) begin/if (wb_j == 3'"'"'d6) begin/'
CTRL=1 run "burst: the data a word late"     -e 's/dq_out     <= bdin\[16\*wb_j +: 16\];/dq_out     <= bdin[16*(wb_j - 3'"'"'d1) +: 16];/'
CTRL=1 run "burst: taken as a single write"  -e 's/				if(saved_wrb) begin/				if(1'"'"'b0) begin/'
