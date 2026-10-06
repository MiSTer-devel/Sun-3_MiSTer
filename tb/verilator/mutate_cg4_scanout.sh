#!/bin/bash
# Mutation check for tb_cg4_scanout: each line puts a bug into a copy of
# sun3_cg4_scanout.sv, and the test must fail.
#
#     tb/verilator/mutate_cg4_scanout.sh
#
# A "NOT CAUGHT" is a hole in the test, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
W=/tmp/sun3_cg4somut
mkdir -p $W
run() {
  name="$1"; shift
  cp $RTL/sun3/sun3_cg4_scanout.sv $W/so.sv
  sed -i "$@" $W/so.sv
  if cmp -s $RTL/sun3/sun3_cg4_scanout.sv $W/so.sv; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator --binary --timing -I$RTL/sun3 -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module tb_cg4_scanout \
    --Mdir $W/obj -o tb tb_cg4_scanout.sv $W/so.sv $RTL/sun3/video_timing.sv >$W/build.log 2>&1 \
    || { echo "$name: BUILD FAILED"; return; }
  out=$($W/obj/tb 2>&1)
  summary=$(echo "$out" | grep -E "^tb_cg4_scanout: [0-9]+ checks|timeout")
  first=$(echo "$out" | grep -m1 "^FAIL ")
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary -- $first"; fi
}
run "colour bytes little-endian"     -e "s/cbeat\[{p1\[3:2\], ~p1\[1:0\], 3'b000} +: 8\]/cbeat[{p1[3:2], p1[1:0], 3'b000} +: 8]/"
run "overlay bits LSB first"         -e "s/obeat\[{p1\[6:5\], ~p1\[4:0\]}\]/obeat[{p1[6:5], p1[4:0]}]/"
run "OL0 and OL1 the other way"      -e "s/ol2      <= {ovb \& enb \& cmd\[1\], enb \& cmd\[0\]};/ol2      <= {enb \& cmd[0], ovb \& enb \& cmd[1]};/"
run "overlay enables ignored"        -e "s/ol2      <= {ovb \& enb \& cmd\[1\], enb \& cmd\[0\]};/ol2      <= {ovb \& enb, enb};/"
run "overlay shown where not enabled" -e "s/ol2      <= {ovb \& enb \& cmd\[1\], enb \& cmd\[0\]};/ol2      <= {ovb \& cmd[1], enb \& cmd[0]};/"
run "read mask ignored"              -e "s/cm_raddr <= pix \& rm;/cm_raddr <= pix;/"
run "video on ignored"               -e "s/rgb <= !(vis3 \& von)  ? 24'd0 :/rgb <= !vis3  ? 24'd0 :/"
run "overlay a pixel early"          -e "s/(ol3 == 2'd1)  ? ovl1 :/(ol2 == 2'd1)  ? ovl1 :/"
run "enable plane from the overlay"  -e "s/? ENABLE_WORD  + 26'(fetch_row) \* 26'd72/? OVERLAY_WORD + 26'(fetch_row) * 26'd72/"
run "colour lines 1024 bytes apart"  -e "s/26'(fetch_row) \* 26'd576/26'(fetch_row) * 26'd512/"
run "colour beat stored one on"      -e "s/cbuf\[{fetch_row\[1:0\], cb}\] <= c_rdata;/cbuf[{fetch_row[1:0], cb + 7'd1}] <= c_rdata;/"
run "fetch four lines ahead"         -e "s/(fetch_row < shown + 11'd3);/(fetch_row < shown + 11'd4);/"
run "never urgent"                   -e "s/assign c_urgent = active \&\& (fetch_row <= shown);/assign c_urgent = 1'b0;/"
run "always urgent"                  -e "s/assign c_urgent = active \&\& (fetch_row <= shown);/assign c_urgent = active;/"
run "not armed by a frame's start"   -e "s/wire        active = enable \&\& armed \&\& /wire        active = enable \&\& /"
run "retrace a line late"            -e "s/assign retrace = (cy >= SCREEN_H);/assign retrace = (cy > SCREEN_H);/"
run "colour never fetched"           -e "s/(beat == 7'(CB0 - 1) \&\& no_colour)/(beat == 7'(CB0 - 1))/"
run "colour always fetched"          -e "s/(beat == 7'(CB0 - 1) \&\& no_colour)/(beat == 7'(CB0 - 1) \&\& 1'b0)/"
run "skipped whatever the command"   -e "s/no_colour = en_ones \&\& (ole\[0\] || (ole\[1\] \&\& ov_ones \&\& all_ones));/no_colour = en_ones;/"
run "OL1 skips without the enable"   -e "s/no_colour = en_ones \&\& (ole\[0\] || (ole\[1\] \&\& ov_ones \&\& all_ones));/no_colour = (ole[0] \&\& en_ones) || (ole[1] \&\& ov_ones \&\& all_ones);/"
run "overlay's last burst not looked at" -e "s/(ole\[1\] \&\& ov_ones \&\& all_ones)/(ole[1] \&\& ov_ones)/"
run "enable's ones kept across lines" -e "0,/                    en_ones   <= 1'b1;/s///"
