#!/bin/bash
# Mutation check for tb_cg6: each line puts a bug into a copy of sun3_cg6.sv,
# sun3_cg6_engine.sv, sun3_cg6_tec.sv or (the cursor) sun3_cg4_scanout.sv,
# and the bench must fail.  Run `make -C tb/verilator
# tb_cg6' first: it makes the traces (obj_tb_cg6/t_*), which this replays.
#
#     [JOBS=n] tb/verilator/mutate_cg6.sh [name-filter]
#
# A "NOT CAUGHT" is a hole in the bench, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
T=$(pwd)/obj_tb_cg6
W=/tmp/sun3_cg6mut.$$
mkdir -p $W
[ -f $T/t_prom.txt ] && [ -f $T/t_gen.txt ] || { echo "no traces in $T: make tb_cg6 first"; exit 1; }
TRACES="+t0=$T/t_prom +t1=$T/t_gen"
[ -f $T/t_lp.txt ] && TRACES="$TRACES +t2=$T/t_lp"
[ -f $T/t_lp68k.txt ] && TRACES="$TRACES +t3=$T/t_lp68k"
[ -f $T/t_xn.txt ] && TRACES="$TRACES +t4=$T/t_xn"
# JOBS=n runs n mutants at once, each in its own directory; tb_cg6 stops at
# its first failure (+failfast)
JOBS=${JOBS:-1}
NM=0
one() {
  d="$1"; name="$2"
  verilator --binary --timing -I$RTL/sun3 -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module tb_cg6 --Mdir $d/obj -o tb \
    tb_cg6.sv $d/cg6.sv $d/engine.sv $d/tec.sv $RTL/sun3/sun3_cg4.sv $d/scanout.sv $RTL/sun3/video_timing.sv \
    sdram_model.sv altddio_out_stub.v $RTL/sdram.sv $RTL/sun3_mister_sdram.sv $(pwd)/tb_cg6_model.cpp >$d/build.log 2>&1 \
    || { echo "$name: BUILD FAILED"; return; }
  out=$(timeout 3600 $d/obj/tb $TRACES +failfast 2>&1)
  summary=$(echo "$out" | grep -E "^tb_cg6: [0-9]+ checks|never answered")
  first=$(echo "$out" | grep -m1 "^FAIL ")
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary -- $first"; fi
  rm -rf $d
}
run() {
  name="$1"; file="$2"; shift 2
  if [ -n "$FILTER" ] && ! echo "$name" | grep -q "$FILTER"; then return; fi
  NM=$((NM + 1))
  d=$W/m$NM
  rm -rf $d; mkdir -p $d
  cp $RTL/sun3/sun3_cg6.sv $d/cg6.sv
  cp $RTL/sun3/sun3_cg6_engine.sv $d/engine.sv
  cp $RTL/sun3/sun3_cg6_tec.sv $d/tec.sv
  cp $RTL/sun3/sun3_cg4_scanout.sv $d/scanout.sv
  sed -i "$@" $d/$file
  if cmp -s $RTL/sun3/sun3_cg6.sv $d/cg6.sv && cmp -s $RTL/sun3/sun3_cg6_engine.sv $d/engine.sv &&
     cmp -s $RTL/sun3/sun3_cg6_tec.sv $d/tec.sv && cmp -s $RTL/sun3/sun3_cg4_scanout.sv $d/scanout.sv; then
    echo "$name: MUTATION DID NOT APPLY"; return
  fi
  one $d "$name" &
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
}
FILTER="$1"
E=engine.sv
R=cg6.sv
S=scanout.sv
X=tec.sv
# ---- the engine: the raster-op unit
run "f and b swapped in the truth table"  $E -e "s/rasterop\[{1'b0, fcolor\[i\], bcolor\[i\], 2'b00} +: 4\]/rasterop[{1'b0, bcolor[i], fcolor[i], 2'b00} +: 4]/"
run "the plane mask ignored"              $E -e "s/nib\[i\] = pmask\[i\] ? /nib[i] = 1'b1 ? /"
run "the destination never read"          $E -e "s/st <= need_d ? E_DRD : E_CALC;/st <= E_CALC;/"
run "the pixel mask from the first half"  $E -e "s/rev16(ln\[0\] ? xmask\[15:0\] : xmask\[31:16\])/rev16(xmask[31:16])/"
run "the pixel mask LSB leftmost"         $E -e "s/rev16(ln\[0\] ? xmask\[15:0\] : xmask\[31:16\])/(ln[0] ? xmask[15:0] : xmask[31:16])/"
run "the clip's left edge ignored"        $E -e "s/cx0  <= smax(s18'(clipminx), 18'sd0);/cx0  <= 18'sd0;/"
run "the clip's right edge exclusive"     $E -e "s/cx1  <= smin(s18'(clipmaxx), 18'sd1151);/cx1  <= smin(s18'(clipmaxx) - 18'sd1, 18'sd1151);/"
run "the clip's bottom past the 1 MiB"    $E -e "s/wire \[10:0\]        xbr_n = (cy == 10'd910 \&\& xb > 11'd255) ? 11'd255 : xb;/wire [10:0]        xbr_n = xb;/"
run "a rectangle's right edge exclusive"  $E -e "s/c_xb = smin(rx1, cx1);/c_xb = smin(rx1 - 18'sd1, cx1);/"
run "non-overlap: the last column drawn"  $E -e "s/rx1  <= s18'(vx1) - (nonovl ? 18'sd1 : 18'sd0);/rx1  <= s18'(vx1);/"
run "non-overlap: the last row drawn"     $E -e "s/ry1  <= s18'(vy1) - (nonovl ? 18'sd1 : 18'sd0);/ry1  <= s18'(vy1);/"
run "non-overlap: a point dropped"        $R -e "s/.nonovl    (lrect \&\& rasterop\[25:24\] == 2'd2)/.nonovl    (rasterop[25:24] == 2'd2)/"
run "the pattern field's zeros as ones"   $E -e "s/wire        s_draw = (rasterop\[27:26\] != 2'd1);/wire        s_draw = 1'b1;/"
# ---- the engine: blits
run "blits always top-down"               $E -e "s/((cmd == C_BLIT) \&\& (y2 > y0))/1'b0/g" -e "s/up <= (cmd == C_BLIT) \&\& (y2 > y0);/up <= 1'b0;/"
run "the funnel's word step lost"         $E -e "s/fun <= fun >> {fr\[3:2\], 5'b00000};/fun <= fun;/"
run "the funnel's byte step lost"         $E -e "s/wire \[127:0\] fun_out = 128'(fun >> {fr\[1:0\], 3'b000});/wire [127:0] fun_out = 128'(fun);/"
run "a source past the 1 MiB not zero"    $E -e "s/s_blit\[8 \* b +: 8\] = vmask\[b\] ? fun_out\[8 \* b +: 8\] : 8'h00;/s_blit[8 * b +: 8] = fun_out[8 * b +: 8];/"
run "a blit's height one short"           $E -e "s/bh   <= s18'(y1) - s18'(y0) + 18'sd1;/bh   <= s18'(y1) - s18'(y0);/"
# ---- the engine: the font register
run "colour8's bytes low first"           $E -e "s/font\[8 \* (3 - 32'(k)) +: 8\]/font[8 * 32'(k) +: 8]/"
run "colour1's bits LSB first"            $E -e "s/{8{fwin\[15 - b\]}}/{8{fwin[b]}}/"
run "a font row of 33 pixels"             $E -e "s/colour8 ? 18'sd3 : 18'sd31/colour8 ? 18'sd3 : 18'sd32/"
# ---- the engine: memory
run "the CPU's writes not waited for"     $E -e "s/if (mem_idle \&\& !dwait) st <= E_SETUP;/if (!dwait) st <= E_SETUP;/"
run "a burst's selects in byte order"     $E -e "s/                    ge_sel   <= en_l;/                    ge_sel   <= en;/"
run "a burst written whatever its selects" $E -e "s/                    ge_sel   <= en_l;/                    ge_sel   <= 16'hFFFF;/"
# ---- the register file
run "a P4 ID of 0x61"                     $R -e "s/localparam \[7:0\] P4_ID   = 8'h60;/localparam [7:0] P4_ID   = 8'h61;/"
run "MISC's fields not kept"              $R -e "s/if (fields\[sh\] \&\& v\[sh +: 2\] == 2'b00) keep0/if (1'b0) keep0/"
run "a vertex done on its x alone"        $R -e "s/if (pend_n == 2'b11) begin/if (pend_n[0]) begin/"
run "the raster offset not added"         $R -e "s/(vrel ? ((nv_v != 0) ? lastx : xr\[0\]) : offx)/(vrel ? ((nv_v != 0) ? lastx : xr[0]) : 32'h0)/"
run "a relative vertex from x0, always"   $R -e "s/(vrel ? ((nv_v != 0) ? lastx : xr\[0\]) : offx)/(vrel ? xr[0] : offx)/"
run "a new primitive keeps the queue"     $R -e "s/wire        newq   = (prim != vgrp) \& /wire        newq   = 1'b0 \& /"
run "a point not drawn"                   $R -e "s/wire        dgo    = (prim != P_NONE) \&\& /wire        dgo    = (prim != P_POINT) \&\& (prim != P_NONE) \&\& /"
run "the font's y not incremented"        $R -e "s/yr\[0\] <= yr\[0\] + incy;/yr[0] <= yr[0];/"
run "the font's x1 not incremented"       $R -e "s/xr\[1\] <= xr\[1\] + incx;/xr[1] <= xr[1];/"
run "a refused command without EXCEPTION" $R -e "s/rdata <= 32'hB0000000;/rdata <= 32'h30000000;/"
run "FBC cycles not held while busy"      $R -e "s/(stall \&\& ebusy)/(1'b0)/g"
run "the blit from x1, y1"                $R -e "s/\.i_x2        (sat16(xr\[2\])),/.i_x2        (sat16(xr[1])),/"
run "the THC's vsync stuck at 0"          $R -e "s/thc_misc\[10\], 1'b0, rt_now,/thc_misc[10], 1'b0, 1'b0,/"
run "the interrupt whether enabled or not" $R -e "s/assign irq      = thc_pend \& thc_misc\[5\];/assign irq      = thc_pend;/"
run "INT written 1 does not clear it"     $R -e "s/if (wdata\[4\]) thc_pend <= 1'b0;/if (1'b0) thc_pend <= 1'b0;/"
run "video on from bit 7"                 $R -e "s/assign video_on = thc_misc\[10\];/assign video_on = thc_misc[7];/"
run "the FHC's ID bits writable"          $R -e "s/localparam \[7:0\] P4_ID   = 8'h60;/reg [7:0] P4_ID = 8'h60;/" \
                                          -e "s/if (!rw_n) fhc <= wdata\[19:0\];/if (!rw_n) begin fhc <= wdata[19:0]; P4_ID <= wdata[31:24]; end/"
# ---- stage 2: the pattern
run "the pattern not drawn"               $E -e "s/wire        s_patt = (rasterop\[27:26\] == 2'd3);/wire        s_patt = 1'b0;/"
run "the pattern's x alignment ignored"   $E -e "s/wire \[31:0\]  prr  = {prow_r, prow_r} << pattalign\[7:4\];/wire [31:0]  prr  = {prow_r, prow_r};/"
run "the pattern's y alignment ignored"   $E -e "s/wire \[3:0\]   prw  = 4'(cy\[3:0\] + pattalign\[3:0\]);/wire [3:0]   prw  = cy[3:0];/"
run "the pattern's alignment subtracted"  $E -e "s/wire \[3:0\]   prw  = 4'(cy\[3:0\] + pattalign\[3:0\]);/wire [3:0]   prw  = 4'(cy[3:0] - pattalign[3:0]);/"
run "the pattern's rows' halves swapped"  $E -e "s/wire \[15:0\]  prow = prw\[0\] ? pwd\[15:0\] : pwd\[31:16\];/wire [15:0]  prow = prw[0] ? pwd[31:16] : pwd[15:0];/"
run "the pattern's bits LSB leftmost"     $E -e "s/{8{s_patt ? prot\[15 - b\] : s_draw}}/{8{s_patt ? prot[b] : s_draw}}/"
run "the pattern drawn without d"         $E -e "s/wire        s_var  = (cmd == C_BLIT) || (cmd == C_FONT) || s_patt;/wire        s_var  = (cmd == C_BLIT) || (cmd == C_FONT);/"
# ---- stage 2: lines
run "a line from its first vertex"        $E -e "s/wire               l_sw  = (vx1 < vx0);/wire               l_sw  = 1'b0;/"
run "a line's error from 0"               $E -e "s/le   <= 22'sd0 - s22'((l_maj ? l_dx : l_ady) >>> 1);/le   <= 22'sd0;/"
run "a line's minor step at 0"            $E -e "s/wire               lstep = (le2 > 0) \&\& (lrem != 0);/wire               lstep = (le2 >= 0) \&\& (lrem != 0);/"
run "a line's last pixel dropped"         $E -e "s/lrem <= l_maj ? l_dx : l_ady;/lrem <= (l_maj ? l_dx : l_ady) - 18'sd1;/"
run "a steep line stepped along x"        $E -e "s/wire               l_maj = (l_dx >= l_ady);/wire               l_maj = 1'b1;/"
run "a line's run ends a pixel short"     $E -e "s/                        sp_x1 <= lx;/                        sp_x1 <= lx - 22'sd1;/"
run "a line keeps its first vertex"       $R -e "s/                                    qx\[0\] <= qx\[2'(nv - 7'd1)\];/                                    qx[0] <= qx[2'(nv - 7'd2)];/"
run "a line not kept at all"              $R -e "s/if (prim == P_LINE \&\& nv >= 7'd2) begin/if (1'b0) begin/"
# ---- stage 2: polygons
run "a polygon of every vertex queued"    $R -e "s/wire \[2:0\]  kmax   = (prim == P_TRI) ? 3'd3/wire [2:0]  kmax   = (prim == P_TRI) ? 3'd4/"
run "a point not a polygon's first"       $R -e "s/wire        newq   = (prim != vgrp) \& ~(prim == P_POINT \& (vgrp == P_LINE | vgrp == P_TRI | vgrp == P_QUAD));/wire        newq   = (prim != vgrp) \& ~(prim == P_POINT \& vgrp == P_LINE);/"
run "a point not a line's first"          $R -e "s/wire        newq   = (prim != vgrp) \& ~(prim == P_POINT \& (vgrp == P_LINE | vgrp == P_TRI | vgrp == P_QUAD));/wire        newq   = (prim != vgrp) \& ~(prim == P_POINT \& (vgrp == P_TRI | vgrp == P_QUAD));/"
run "a polygon's span to the next edge"   $E -e "s/                            sp_x1 <= k1 - 22'sd1;/                            sp_x1 <= k1;/"
run "a polygon's second span dropped"     $E -e "s/if (pna == 3'd4 \&\& k3 > k2) begin/if (1'b0) begin/"
run "a polygon's sort a stage short"      $E -e "s/if (k1 > k2) begin k1 <= k2; k2 <= k1; end/begin end/"
run "a polygon's last row drawn"          $E -e "s/on = (3'(i) < pne) \&\& (py >= e_y0\[i\]) \&\& (py < e_y1\[i\]);/on = (3'(i) < pne) \&\& (py >= e_y0[i]) \&\& (py <= e_y1[i]);/"
run "an edge stepped before its first row" $E -e "s/ \&\& (py >= e_y0\[i\]) \&\& (py + 22'sd1 < e_y1\[i\]);/ \&\& (py + 22'sd1 < e_y1[i]);/"
run "an edge's half step rounded up"      $E -e "s/p_xadj <= (p_e <= 0) ? /p_xadj <= (p_e < 0) ? /" -e "s/p_e    <= (p_e <= 0) ? p_e + p_dy : p_e;/p_e    <= (p_e < 0) ? p_e + p_dy : p_e;/"
run "a 45-degree edge shallow"            $E -e "s/wire               p_stp = (p_dy >= p_adx);/wire               p_stp = (p_dy > p_adx);/"
run "a left edge's odd dy not corrected"  $E -e "s/e_er\[pne\[1:0\]\] <= p_dys - p_e + s22'({21'd0, p_dy\[0\]});/e_er[pne[1:0]] <= p_dys - p_e;/"
run "a left edge's step rounding"         $E -e "s/((22'sd1 - p_q) >>> 1) + 22'sd1;/((22'sd0 - p_q) >>> 1) + 22'sd1;/"
run "a right edge's half step dropped"    $E -e "s/e_x\[pne\[1:0\]\]  <= p_xa + p_xadj + (p_q >>> 1);/e_x[pne[1:0]]  <= p_xa + p_xadj;/"
run "the divider's remainder lost"        $E -e "s/wire signed \[21:0\] p_qdy = p_adx - s22'({1'b0, dv_r});/wire signed [21:0] p_qdy = p_adx;/"
run "a steep left edge's test"            $E -e "s/2'd3:    c = (e_t\[i\] + e_ka\[i\] <= 0);/2'd3:    c = (e_t[i] > 0);/"
run "a shallow right edge's test"         $E -e "s/2'd0:    c = (e_t\[i\] <= 0);/2'd0:    c = (e_t[i] < 0);/"
run "a polygon's closing edge left out"   $E -e "s/wire \[2:0\]  pj    = (pi + 3'd1 == vk) ? 3'd0 : pi + 3'd1;/wire [2:0]  pj    = pi + 3'd1;/"
# ---- stage 2: the register store, the TEC's banks, the cursor
run "the TEC's second bank ignored"       $R -e "s/wire        tec_b1 = (tec_vdc == 3'd5) \& (off\[11:8\] == 4'h1);/wire        tec_b1 = 1'b0;/"
run "the TEC's bank by VDC type 4"        $R -e "s/wire        tec_b1 = (tec_vdc == 3'd5) \& /wire        tec_b1 = (tec_vdc == 3'd4) \& /"
run "the store read a clock early"        $R -e "s/else if (st_rd \&\& !srd) begin/else if (1'b0) begin/"
run "the indexed registers not stored"    $R -e "s/((off\[11:9\] == 3'b100) \& (off\[8:0\] < 9'h140)));/1'b0);/"
run "the THC's timing not stored"         $R -e "s/wire        st_thc = sel_thc \& (((off\[11:5\] == 7'b1000000) \& (off\[4:2\] <= 3'd5)) |/wire        st_thc = sel_thc \& (/"
run "the pattern not read back"           $R -e "s/            fbc_q = pattern\[off\[4:2\]\];/            fbc_q = 32'h0;/"
run "the cursor's place not kept"         $R -e "s/if (!rw_n) thc_curxy <= wdata;/if (1'b0) thc_curxy <= wdata;/"
run "the cursor's planes swapped"         $R -e "s/if (off\[7\]) curb\[off\[6:2\]\] <= wdata;/if (!off[7]) curb[off[6:2]] <= wdata;/" -e "s/else        cura\[off\[6:2\]\] <= wdata;/if (off[7]) cura[off[6:2]] <= wdata;/"
run "the cursor's bits LSB leftmost"      $S -e "s/cbit1 <= 5'd31 - cdx\[4:0\];/cbit1 <= cdx[4:0];/"
run "the cursor's enables ignored"        $S -e "s/col2     <= cin1 ? {cur_b\[cbit1\] \& cole\[1\], cur_a\[cbit1\] \& cole\[0\]} : 2'd0;/col2     <= cin1 ? {cur_b[cbit1], cur_a[cbit1]} : 2'd0;/"
run "the cursor's A and B swapped"        $S -e "s/col2     <= cin1 ? {cur_b\[cbit1\] \& cole\[1\], cur_a\[cbit1\] \& cole\[0\]} : 2'd0;/col2     <= cin1 ? {cur_a[cbit1] \& cole[1], cur_b[cbit1] \& cole[0]} : 2'd0;/"
run "the cursor a pixel to the right"     $S -e "s/wire signed \[16:0\] cdx = \$signed({6'd0, col}) - /wire signed [16:0] cdx = \$signed({6'd0, col}) - 17'sd1 - /"
run "the cursor 33 rows"                  $S -e "s/(cdy >= 0) \&\& (cdy < 17'sd32);/(cdy >= 0) \&\& (cdy <= 17'sd32);/"
run "the cursor under the colour"         $S -e "s/ol3  <= (col2 != 2'd0) ? col2 : ol2;/ol3  <= ol2;/"
# ---- the TEC (sun3_cg6_tec.sv, and its place in the register file)
run "TEC: to integer toward zero"         $X -e "s/f2i = ~{1'b0, ip} + {31'h0, ~frac};/f2i = ~{1'b0, ip} + 32'h1;/"
run "TEC: to fixed a bit short"           $X -e "s/(fixed ? 9'd16 : 9'd0)/(fixed ? 9'd15 : 9'd0)/"
run "TEC: autoload rounded as fixed"      $X -e "s/wire \[31:0\] dq_i = f2i(dq, (st == S_RD) \&\& (vtype == 3'd1));/wire [31:0] dq_i = f2i(dq, vtype == 3'd1);/"
run "TEC: to integer not saturated"       $X -e "s/else if (v\[30:23\] == 8'hFF || e >= 9'd158)/else if (v[30:23] == 8'hFF || e >= 9'd159)/"
run "TEC: from fixed a bit out"           $X -e "s/? 10'sd142 : 10'sd158;/? 10'sd143 : 10'sd158;/"
run "TEC: ties rounded up"                $X -e "s/wire        r_inc  = n_m\[11\] \& ((|n_m\[10:0\]) | n_m\[12\]);/wire        r_inc  = n_m[11];/"
run "TEC: rounding truncates"             $X -e "s/wire        r_inc  = n_m\[11\] \& ((|n_m\[10:0\]) | n_m\[12\]);/wire        r_inc  = 1'b0;/"
run "TEC: overflow not infinity"          $X -e "s/(r_e >= 11'sd255) ? {pk_s, 8'hFF, 23'h0}/(r_e > 11'sd255) ? {pk_s, 8'hFF, 23'h0}/"
run "TEC: a product's sticky lost"        $X -e "s/pk_m  <= {mup\[47:13\], mup\[12\] | (|mup\[11:0\])};/pk_m  <= {mup[47:13], mup[12]};/"
run "TEC: a denormal factor not zero"     $X -e "s/mu_z <= (vin\[k\[1:0\]\]\[30:23\] == 8'd0) || (dq\[30:23\] == 8'd0);/mu_z <= (vin[k[1:0]][30:23] == 8'd0);/"
run "TEC: an addend's sticky lost"        $X -e "s/(al_sh | {26'h0, al_st})/al_sh/"
run "TEC: the larger by exponent alone"   $X -e "s/wire        al_swap = fb\[30:0\] > fa\[30:0\];/wire        al_swap = fb[30:23] > fa[30:23];/"
run "TEC: a difference's sign the first's" $X -e "s/ad_s   <= al_big\[31\];/ad_s   <= fa[31];/"
run "TEC: infinity plus anything"         $X -e "s/if (fa\[30:23\] == 8'hFF)       ad_by <= {fa\[31\], 8'hFF, 23'h0};/if (1'b0) ad_by <= 32'h0;/"
run "TEC: a relative vertex translated"   $X -e "s/else        vin\[2\] <= c_rel ? 32'h0 : mv\[13\] ? dq : F_ONE;/else        vin[2] <= mv[13] ? dq : F_ONE;/"
run "TEC: a relative vertex not added"    $X -e "s/end else if (!op_cmd \&\& c_rel)/end else if (1'b0)/"
run "TEC: four rows taken as three"       $X -e "s/nk     <= mv\[10\] ? 3'd4 : 3'd3;/nk     <= 3'd3;/"
run "TEC: MV's h ignored"                 $X -e "s/else        vin\[2\] <= c_rel ? 32'h0 : mv\[13\] ? dq : F_ONE;/else        vin[2] <= c_rel ? 32'h0 : F_ONE;/"
run "TEC: MV's z ignored"                 $X -e "s/if (mv\[10\]) vin\[2\] <= mv\[12\] ? dq : 32'h0;/if (mv[10]) vin[2] <= dq;/"
run "TEC: MV's columns one short"         $X -e "s/nj     <= {1'b0, mv\[9:8\]} + 3'd1;/nj     <= {1'b0, mv[9:8]};/"
run "TEC: autoload's y from data 4"       $X -e "s/S_AUTO1: ra = 6'd5;/S_AUTO1: ra = 6'd4;/"
run "TEC: autoload always a point"        $X -e "s/agrp <= c_adr\[8:6\];/agrp <= 3'd0;/"
run "TEC: autoload read while written"    $X -e "s/                    st <= S_AUTO0;/                    st <= S_AUTO1;/"
run "TEC: a fixed vertex as an integer"   $X -e "s/pk_e  <= ((adr\[11\] ? (adr\[10:9\] == 2'd1)/pk_e  <= ((adr[11] ? (adr[10:9] == 2'd0)/"
run "TEC: a float vertex converted"       $X -e "s/pk_bv <= (adr\[11\] ? (adr\[10:9\] == 2'd2)/pk_bv <= (adr[11] ? 1'b0/"
run "TEC: fixed reads not converted"      $X -e "s/q    <= (vtype <= 3'd1) ? dq_i : dq;/q    <= (vtype == 3'd0) ? dq_i : dq;/"
run "TEC: integer writes not converted"   $X -e "s/: (vtype > 3'd1)) || (wdata == 32'h0);/: (vtype != 3'd1)) || (wdata == 32'h0);/"
run "TEC: the second bank's writes in the first" $X -e "s/(((adr\[11:8\] == 4'h1) \&\& (vtype != 3'd5)) || w_vtx)/((adr[11:8] == 4'h1) || w_vtx)/"
run "TEC: a command's A its first only"   $X -e "s/S_AL:    ra = (3'(k + 3'd1) < nk) ? 6'(aa + 6'(k) + 6'd1) : bb;/S_AL:    ra = (3'(k + 3'd1) < nk) ? aa : bb;/"
run "TEC: a command's n ignored"          $X -e "s/nj     <= {1'b0, wdata\[29:28\]} + 3'd1;/nj     <= 3'd2;/"
run "TEC: a command's m as n"             $X -e "s/nk     <= {1'b0, wdata\[31:30\]} + 3'd1;/nk     <= {1'b0, wdata[29:28]} + 3'd1;/"
run "TEC: autoload without the raster offset" $R -e "s/qx\[anv\[1:0\]\] <= tec_ax + offx;/qx[anv[1:0]] <= tec_ax;/" -e "s/xr\[anv\[1:0\]\] <= tec_ax + offx;/xr[anv[1:0]] <= tec_ax;/"
run "TEC: autoload a new queue after a point" $R -e "s/wire        anewq  = (prim != tec_agrp) \& ~(prim == P_POINT \& (tec_agrp == P_LINE | tec_agrp == P_TRI | tec_agrp == P_QUAD));/wire        anewq  = (prim != tec_agrp);/"
run "TEC: FBC cycles not held for it"     $R -e "s/wire        tstall = (sel_fbc | sel_tec) \& tec_busy;/wire        tstall = sel_tec \& tec_busy;/"
run "redo: DRAWSTATUS again draws nothing" $R -e "s/end else if (redo) begin        \/\/ DRAWSTATUS: the last primitive again/end else if (1'b0) begin/"
run "redo: not cancelled by a new vertex" $R -e "s/                                redo  <= 1'b0;\$/                                redo  <= redo;/"
run "redo: not cancelled by another kind" $R -e "s/if (prim != vgrp) redo <= 1'b0;   \/\/ another kind of primitive/if (1'b0) redo <= 1'b0;/"
run "redo: always a rectangle"            $R -e "s/cmd       <= lcmd;/cmd       <= C_RECT;/"
run "region fill: no redraw by the lone x's"  $R -e "s/wire        redraw = rkeep \&\& (rnew == 2'b11) \&\& (nv == 7'd0);/wire        redraw = 1'b0;/"
run "region fill: the lone x's swapped"   $R -e "s/ex\[0\] <= rnx0; ey\[0\] <= rry0;/ex[0] <= rnx1; ey[0] <= rry0;/" -e "s/ex\[1\] <= rnx1; ey\[1\] <= rry1;/ex[1] <= rnx0; ey[1] <= rry1;/"
run "region fill: not cancelled by a y"   $R -e "s/else if (vcoord) rkeep <= 1'b0;/else if (1'b0) rkeep <= 1'b0;/"
run "region fill: one row"                $R -e "s/rry1  <= sat16(qy\[2'(dbase + 2'd1)\]);/rry1  <= sat16(qy[dbase]);/"
run "region fill: with one x alone"       $R -e "s/wire        redraw = rkeep \&\& (rnew == 2'b11)/wire        redraw = rkeep \&\& (rnew != 2'b00)/"
run "clip bits: visible with a point outside"  $R -e "s/if (\&(in | ~m))/if (|(in \& m))/"
run "clip bits: hidden past any edges"    $R -e "s/else if (\&(l | ~m) || \&(r | ~m) || \&(t | ~m) || \&(b | ~m))/else if (\&(l | r | t | b | ~m))/"
run "clip bits: the clip's right edge exclusive" $R -e "s/c_in\[j\] = (cpx\[j\] >= ccx0) \&\& (cpx\[j\] <= ccx1)/c_in[j] = (cpx[j] >= ccx0) \&\& (cpx[j] < ccx1)/"
run "clip bits: a polygon's first vertex left out" $R -e "s/wire \[3:0\]  dmask  = (dk >= 3'd4) ? 4'b1111 : (dk == 3'd3) ? 4'b0111 : (dk == 3'd2) ? 4'b0011 : 4'b0001;/wire [3:0]  dmask  = (dk >= 3'd4) ? 4'b1110 : (dk == 3'd3) ? 4'b0110 : (dk == 3'd2) ? 4'b0010 : 4'b0001;/"
run "clip bits: a blit's source and destination swapped" $R -e "s/wire \[5:0\]  bcls   = {cclass(4'b0011, /wire [5:0]  bcls   = {cclass(4'b1100, /" -e "s/, c_l, c_r, c_t, c_b), cclass(4'b1100, c_in/, c_l, c_r, c_t, c_b), cclass(4'b0011, c_in/"
run "clip bits: DRAWSTATUS without them"  $R -e "s/rdata <= {29'h0, dcls};/rdata <= 32'h0;/"
run "MISC's vertical blank as written"   $R -e "s/12'h004: fbc_q = {10'h0, misc\[21:20\], misc_vb, misc\[18:7\]/12'h004: fbc_q = {10'h0, misc[21:20], misc[19], misc[18:7]/"
run "MISC's vertical blank not cleared"   $R -e "s/if (wdata\[19\]) misc_vb <= 1'b0;/if (1'b0) misc_vb <= 1'b0;/"
run "MISC's vertical blank never set"     $R -e "s/if (!rst \&\& rt_rise) misc_vb <= 1'b1;/if (1'b0) misc_vb <= 1'b1;/"
run "TEC: MISC's index not the queue's"   $R -e "s/12'h004: fbc_q = {10'h0, misc\[21:20\], misc_vb, misc\[18:7\], 1'b0, nv\[1:0\], misc\[3:0\]};/12'h004: fbc_q = {10'h0, misc[21:20], misc_vb, misc[18:0]};/"
run "TEC: a read answered before the TEC" $R -e "s/if (!tec_busy) begin                \/\/ the TEC's answer/if (1'b1) begin/"
wait
rm -rf $W
