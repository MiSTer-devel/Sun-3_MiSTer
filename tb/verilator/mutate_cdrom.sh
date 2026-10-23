#!/bin/bash
# Mutation check for tb_cdrom: each line puts back a bug, and the test must
# fail.
#
#     tb/verilator/mutate_cdrom.sh                 all of them
#     ONLY='TOC|MODE' tb/verilator/mutate_cdrom.sh  those whose names match
#
# A "NOT CAUGHT" is a hole in the test, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
# Each mutant builds in its own directory, JOBS at a time (default 3), and the
# C++ unoptimised: the bench runs in a second, the compile is what costs.
B=/tmp/sun3_cdmut
JOBS=${JOBS:-3}
mkdir -p $B
n=0
run() {
  n=$((n + 1))
  if [ -n "$ONLY" ] && ! echo "$1" | grep -qE "$ONLY"; then return; fi
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
  one "$n" "$@" &
}
one() {
  W=$B/$1; shift
  name="$1"; shift
  mkdir -p $W
  cp $RTL/sun3/sun3_cdrom.sv $W/m.sv
  sed -i "$@" $W/m.sv
  if cmp -s $RTL/sun3/sun3_cdrom.sv $W/m.sv; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD -I$RTL/sun3 +define+SIMULATION=1 \
    -MAKEFLAGS "OPT_FAST=-O0 OPT_SLOW=-O0" --top-module tb_cdrom --Mdir $W/obj -o tb \
    $RTL/vendor/wish5380/wish5380_pkg.sv $RTL/vendor/wish5380/scsi_fabric.sv $W/m.sv tb_cdrom.sv >$W/build.log 2>&1 \
    || { echo "$name: BUILD FAILED ($W/build.log)"; return; }
  out=$($W/obj/tb 2>&1)
  summary=$(echo "$out" | grep -E "^tb_cdrom:|timed out")
  first=$(echo "$out" | grep -m3 "^FAIL:" | tr '\n' ';')
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT ($summary)"; else echo "$name: caught -- $summary -- $first"; fi
  rm -rf $W
}
run "2048-byte blocks at reset"        -e "s/bs2k <= 1'b0; ua <= 1'b0;/bs2k <= 1'b1; ua <= 1'b0;/"
run "bus reset keeps the block size"   -e "/A bus reset is a hard reset/,/end else begin/{s/bs2k       <= 1'b0;/;/}"
run "not removable"                    -e "s/resp = 8'h80;  /resp = 8'h00;  /"
run "a disk, not a CD-ROM"             -e "s/(lun == 3'd0) ? 8'h05 : 8'h7f/(lun == 3'd0) ? 8'h00 : 8'h7f/"
run "capacity is the count"            -e "s/: cap_blocks - 32'd1;/: cap_blocks;/"
run "2048: LBA not scaled"             -e "s/assign img_lba    = bs2k ? {cmd_lba\[29:0\], 2'b00} : cmd_lba;/assign img_lba    = cmd_lba;/"
run "2048: count not scaled"           -e "s/assign img_blocks = bs2k ? {cmd_blocks\[21:0\], 2'b00} : cmd_blocks;/assign img_blocks = cmd_blocks;/"
run "2048: size not divided"           -e "s/assign cap_blocks = bs2k ? {2'b00, blk_i.count\[31:2\]} : blk_i.count;/assign cap_blocks = blk_i.count;/"
run "MODE SELECT 2048 ignored"         -e "s/24'd2048: bs2k <= 1'b1;/24'd2048: ;/"
run "MODE SELECT 512 ignored"          -e "s/24'd512:  bs2k <= 1'b0;/24'd512:  ;/"
run "MODE SELECT takes any length"     -e "s/default:  check(SK_ILLEGAL, ASC_INVALID_PARAM);/default:  ;/"
run "MODE SELECT without a descriptor" -e "s/msel_bdl >= 8'd8)/1'b1)/"
run "MODE SELECT list offset"          -e "s/10'd11: msel_bl\[7:0\]   <= bus_i.data;/10'd10: msel_bl[7:0]   <= bus_i.data;/"
run "no UNIT ATTENTION"                -e "s/if (media_changed_i \&\& blk_i.ready) ua <= 1'b1;/;/"
run "UNIT ATTENTION on removal too"    -e "s/if (media_changed_i \&\& blk_i.ready) ua <= 1'b1;/if (media_changed_i) ua <= 1'b1;/"
run "UNIT ATTENTION never cleared"     -e "/else if (ua \&\& op != C_INQUIRY/{n;s/ua <= 1'b0;/;/}"
run "REQUEST SENSE keeps it"           -e "/if (ua) begin/{n;s/ua          <= 1'b0;/;/}"
run "INQUIRY held up by it"            -e "s/else if (ua \&\& op != C_INQUIRY \&\& op != C_REQUEST_SENSE) begin/else if (ua \&\& op != C_REQUEST_SENSE) begin/"
run "ready with no disc"               -e "s/C_TEST_UNIT_READY, C_REZERO, C_SEEK6, C_SEEK10, C_VERIFY10:/C_TEST_UNIT_READY, C_REZERO, C_SEEK6, C_SEEK10, C_VERIFY10: ; 8'hff:/"
run "no medium: wrong ASC"             -e "s/ASC_NO_MEDIUM       = 8'h3a/ASC_NO_MEDIUM       = 8'h3b/"
run "range check off by one"           -e "s/else if (cmd_end > {1'b0, cap_blocks}) begin/else if (cmd_end >= {1'b0, cap_blocks}) begin/"
run "no LBA in the sense"              -e "s/sense_info  <= cmd_lba;/sense_info  <= 32'd0;/"
run "READ(6) of 0 is 0"                -e "s/(cdb\[39:32\] == 8'd0) ? 24'd256 :/(cdb[39:32] == 8'd0) ? 24'd0 :/"
run "READ(10) count's high byte lost"  -e "s/assign cdb_len10 = {8'd0, cdb\[63:56\], cdb\[71:64\]};/assign cdb_len10 = {16'd0, cdb[71:64]};/"
run "TOC lead-out in 512 always"       -e "s/3'd7: resp = !toc_lead ? 8'h00 : toc_msf ? toc_f : cap_blocks\[7:0\];/3'd7: resp = !toc_lead ? 8'h00 : toc_msf ? toc_f : blk_i.count[7:0];/"
run "TOC MSF without the 2 seconds"    -e "s/toc_rem   <= blk_i.count\[25:2\] + 24'd150;/toc_rem   <= blk_i.count[25:2];/"
run "TOC track 1 not at 00:02:00"      -e "s/(toc_msf ? 8'h02 : 8'h00)/8'h00/"
run "TOC from AA: both entries"        -e "s/toc_aa    <= cdb\[55:48\] == 8'haa;/toc_aa    <= 1'b0;/"
run "TOC from track 2 taken"           -e "s/else if (cdb\[55:48\] > 8'd1 \&\& cdb\[55:48\] != 8'haa)/else if (1'b0)/"
run "TOC not a data track"             -e "s/3'd1: resp = 8'h14;                   \/\/ ADR 1, a data track/3'd1: resp = 8'h10;/"
run "MODE SENSE descriptor 512 always" -e "s/assign cur_bl = bs2k ? 24'd2048 : 24'd512;/assign cur_bl = 24'd512;/"
run "MODE SENSE ignores DBD"           -e "s/ms_bd     <= !cdb\[11\];/ms_bd     <= 1'b1;/"
run "MODE SENSE length byte"           -e "s/2'd0: resp = {2'b00, ms_len - 6'd1};/2'd0: resp = {2'b00, ms_len};/"
run "MODE SENSE takes page 04"         -e "s/cdb\[21:16\] != 6'h0e \&\& cdb\[21:16\] != 6'h3f)/cdb[21:16] != 6'h0e \&\& cdb[21:16] != 6'h3f \&\& cdb[21:16] != 6'h04)/"
run "MODE SENSE saved values taken"    -e "s/if (cdb\[23:22\] == 2'b11)/if (1'b0)/"
run "vendor CDBs six bytes"            -e "s/3'd1, 3'd2, 3'd6: len_of_op = 4'd10;/3'd1, 3'd2: len_of_op = 4'd10;/"
run "fetch while busy"                 -e "s/!fetch_busy \&\& !med_err \&\& fetch_left != 24'd0 \&\& !full\[fetch_sel\]/!med_err \&\& fetch_left != 24'd0 \&\& !full[fetch_sel]/"
run "one bank only"                    -e "s/assign fetch_sel = full\[bank_bus\] ? ~bank_bus : bank_bus;/assign fetch_sel = bank_bus;/"
run "medium error unreported"          -e "/S_RDWAIT:/{n;s/if (med_err || media_fault) begin/if (1'b0) begin/}"
run "stale block taken after reset"    -e "/A bus reset is a hard reset/,/end else begin/{s/fetch_live <= 1'b0;/;/}"
run "REQUEST SENSE of 0 is 0"          -e "s/(alloc6 == 10'd0) ? 10'd4 :/(alloc6 == 10'd0) ? 10'd0 :/"
run "writes taken"                     -e "s/C_READ6, C_READ10:/C_READ6, C_READ10, 8'h0a:/"
run "PLAY taken"                       -e "s/else              check(SK_ILLEGAL, ASC_ILLEGAL_MODE);/else ;/"
run "PAUSE taken"                      -e "s/check(SK_ILLEGAL, ASC_SEQUENCE_ERROR);/;/"
run "sub-channel status"               -e "s/4'd1: resp = 8'h15;/4'd1: resp = 8'h00;/"
run "any LUN answers"                  -e "s/if (lun != 3'd0 \&\& op != C_INQUIRY \&\& op != C_REQUEST_SENSE)/if (1'b0)/"
run "no block in a medium error"      -e "s/sense_info  <= err_blk;/sense_info  <= 32'd0;/g"
run "IDENTIFY's LUN ignored"           -e "s/if (bus_i.data\[7\]) lun <= bus_i.data\[2:0\];/;/"
wait
