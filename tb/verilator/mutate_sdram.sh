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
run() {
  name="$1"; shift
  cp $RTL/sun3_mister_sdram.sv $W/adapter.sv
  sed -i "$@" $W/adapter.sv
  if cmp -s $RTL/sun3_mister_sdram.sv $W/adapter.sv; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module tb_mister_sdram \
    --Mdir $W/obj -o tb tb_mister_sdram.sv sdram_model.sv altddio_out_stub.v $RTL/sdram.sv $W/adapter.sv \
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
