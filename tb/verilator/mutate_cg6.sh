#!/bin/bash
# Mutation check for tb_cg6: each line puts a bug into a copy of sun3_cg6.sv
# or sun3_cg6_engine.sv, and the bench must fail.  Run `make -C tb/verilator
# tb_cg6' first: it makes the traces (obj_tb_cg6/t_*), which this replays.
#
#     tb/verilator/mutate_cg6.sh [name-filter]
#
# A "NOT CAUGHT" is a hole in the bench, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
T=$(pwd)/obj_tb_cg6
W=/tmp/sun3_cg6mut
mkdir -p $W
[ -f $T/t_prom.txt ] && [ -f $T/t_gen.txt ] || { echo "no traces in $T: make tb_cg6 first"; exit 1; }
TRACES="+t0=$T/t_prom +t1=$T/t_gen"
[ -f $T/t_lp.txt ] && TRACES="$TRACES +t2=$T/t_lp"
run() {
  name="$1"; file="$2"; shift 2
  if [ -n "$FILTER" ] && ! echo "$name" | grep -q "$FILTER"; then return; fi
  cp $RTL/sun3/sun3_cg6.sv $W/cg6.sv
  cp $RTL/sun3/sun3_cg6_engine.sv $W/engine.sv
  sed -i "$@" $W/$file
  if cmp -s $RTL/sun3/sun3_cg6.sv $W/cg6.sv && cmp -s $RTL/sun3/sun3_cg6_engine.sv $W/engine.sv; then
    echo "$name: MUTATION DID NOT APPLY"; return
  fi
  rm -rf $W/obj
  verilator --binary --timing -I$RTL/sun3 -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module tb_cg6 --Mdir $W/obj -o tb \
    tb_cg6.sv $W/cg6.sv $W/engine.sv $RTL/sun3/sun3_cg4.sv $RTL/sun3/sun3_cg4_scanout.sv $RTL/sun3/video_timing.sv \
    sdram_model.sv altddio_out_stub.v $RTL/sdram.sv $RTL/sun3_mister_sdram.sv $(pwd)/tb_cg6_model.cpp >$W/build.log 2>&1 \
    || { echo "$name: BUILD FAILED"; return; }
  out=$(timeout 1800 $W/obj/tb $TRACES 2>&1)
  summary=$(echo "$out" | grep -E "^tb_cg6: [0-9]+ checks|never answered")
  first=$(echo "$out" | grep -m1 "^FAIL ")
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary -- $first"; fi
}
FILTER="$1"
E=engine.sv
R=cg6.sv
# ---- the engine: the raster-op unit
run "f and b swapped in the truth table"  $E -e "s/rasterop\[{1'b0, fcolor\[i\], bcolor\[i\], 2'b00} +: 4\]/rasterop[{1'b0, bcolor[i], fcolor[i], 2'b00} +: 4]/"
run "the plane mask ignored"              $E -e "s/nib\[i\] = pmask\[i\] ? /nib[i] = 1'b1 ? /"
run "the destination never read"          $E -e "s/st <= need_d ? E_DRD : E_CALC;/st <= E_CALC;/"
run "the pixel mask from the first half"  $E -e "s/rev16(ln\[0\] ? xmask\[15:0\] : xmask\[31:16\])/rev16(xmask[31:16])/"
run "the pixel mask LSB leftmost"         $E -e "s/rev16(ln\[0\] ? xmask\[15:0\] : xmask\[31:16\])/(ln[0] ? xmask[15:0] : xmask[31:16])/"
run "the clip's left edge ignored"        $E -e "s/wire signed \[17:0\] cx0 = smax(s18'(clipminx), 18'sd0);/wire signed [17:0] cx0 = 18'sd0;/"
run "the clip's right edge exclusive"     $E -e "s/wire signed \[17:0\] cx1 = smin(s18'(clipmaxx), 18'sd1151);/wire signed [17:0] cx1 = smin(s18'(clipmaxx) - 18'sd1, 18'sd1151);/"
run "the clip's bottom past the 1 MiB"    $E -e "s/wire \[10:0\]        xbr_n = (cy == 10'd910 \&\& xb > 11'd255) ? 11'd255 : xb;/wire [10:0]        xbr_n = xb;/"
run "a rectangle's right edge exclusive"  $E -e "s/e_xb = smin(s18'(x1), cx1);/e_xb = smin(s18'(x1) - 18'sd1, cx1);/"
run "the pattern field's zeros as ones"   $E -e "s/wire        s_draw = (rasterop\[27:26\] != 2'd1);/wire        s_draw = 1'b1;/"
# ---- the engine: blits
run "blits always top-down"               $E -e "s/((cmd == C_BLIT) \&\& (y2 > y0))/1'b0/g" -e "s/up <= (cmd == C_BLIT) \&\& (y2 > y0);/up <= 1'b0;/"
run "the funnel's word step lost"         $E -e "s/fun <= fun >> {fr\[3:2\], 5'b00000};/fun <= fun;/"
run "the funnel's byte step lost"         $E -e "s/wire \[127:0\] fun_out = 128'(fun >> {fr\[1:0\], 3'b000});/wire [127:0] fun_out = 128'(fun);/"
run "a source past the 1 MiB not zero"    $E -e "s/s_blit\[8 \* b +: 8\] = vmask\[b\] ? fun_out\[8 \* b +: 8\] : 8'h00;/s_blit[8 * b +: 8] = fun_out[8 * b +: 8];/"
run "a blit's height one short"           $E -e "s/wire signed \[17:0\] bh   = s18'(y1) - s18'(y0) + 18'sd1;/wire signed [17:0] bh   = s18'(y1) - s18'(y0);/"
# ---- the engine: the font register
run "colour8's bytes low first"           $E -e "s/font\[8 \* (3 - 32'(k)) +: 8\]/font[8 * 32'(k) +: 8]/"
run "colour1's bits LSB first"            $E -e "s/{8{fwin\[15 - b\]}}/{8{fwin[b]}}/"
run "a font row of 33 pixels"             $E -e "s/colour8 ? 18'sd3 : 18'sd31/colour8 ? 18'sd3 : 18'sd32/"
# ---- the engine: memory
run "the CPU's writes not waited for"     $E -e "s/if (mem_idle) st <= E_SETUP;/st <= E_SETUP;/"
run "a burst's words written low first"   $E -e "s/ge_wdata <= res\[32 \* wsel +: 32\];/ge_wdata <= res[32 * (3 - wsel) +: 32];/"
# ---- the register file
run "a P4 ID of 0x61"                     $R -e "s/localparam \[7:0\] P4_ID   = 8'h60;/localparam [7:0] P4_ID   = 8'h61;/"
run "MISC's fields not kept"              $R -e "s/if (fields\[sh\] \&\& v\[sh +: 2\] == 2'b00) keep0/if (1'b0) keep0/"
run "a vertex done on its x alone"        $R -e "s/if (pend_n == 2'b11) begin/if (pend_n[0]) begin/"
run "the raster offset not added"         $R -e "s/(vrel ? ((nv_v != 0) ? vb_x : xr\[0\]) : offx)/(vrel ? ((nv_v != 0) ? vb_x : xr[0]) : 32'h0)/"
run "a relative vertex from x0, always"   $R -e "s/(vrel ? ((nv_v != 0) ? vb_x : xr\[0\]) : offx)/(vrel ? xr[0] : offx)/"
run "a new primitive keeps the queue"     $R -e "s/wire        newq   = (prim != vgrp) \& /wire        newq   = 1'b0 \& /"
run "a point not drawn"                   $R -e "s/(prim == P_POINT \&\& nv >= 7'd1)/1'b0/"
run "the font's y not incremented"        $R -e "s/yr\[0\] <= yr\[0\] + incy;/yr[0] <= yr[0];/"
run "the font's x1 not incremented"       $R -e "s/xr\[1\] <= xr\[1\] + incx;/xr[1] <= xr[1];/"
run "a refused command without EXCEPTION" $R -e "s/rdata <= 32'hB0000000;/rdata <= 32'h30000000;/"
run "FBC cycles not held while busy"      $R -e "s/if (stall \&\& ebusy)/if (1'b0)/"
run "the blit from x1, y1"                $R -e "s/.x2        (sat16(xr\[2\])),/.x2        (sat16(xr[1])),/"
run "the THC's vsync stuck at 0"          $R -e "s/thc_misc\[10\], 1'b0, rt_now,/thc_misc[10], 1'b0, 1'b0,/"
run "the interrupt whether enabled or not" $R -e "s/assign irq      = thc_pend \& thc_misc\[5\];/assign irq      = thc_pend;/"
run "INT written 1 does not clear it"     $R -e "s/if (wdata\[4\]) thc_pend <= 1'b0;/if (1'b0) thc_pend <= 1'b0;/"
run "video on from bit 7"                 $R -e "s/assign video_on = thc_misc\[10\];/assign video_on = thc_misc[7];/"
run "the FHC's ID bits writable"          $R -e "s/localparam \[7:0\] P4_ID   = 8'h60;/reg [7:0] P4_ID = 8'h60;/" \
                                          -e "s/if (!rw_n) fhc <= wdata\[19:0\];/if (!rw_n) begin fhc <= wdata[19:0]; P4_ID <= wdata[31:24]; end/"
