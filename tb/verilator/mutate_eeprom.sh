#!/bin/bash
# Mutation check for tb_mister_eeprom: each line puts a bug into a copy of the
# saver (rtl/sun3_mister_eeprom.sv) or of the EEPROM (rtl/sun3/eeprom.v), and
# the test must fail.
#
#     tb/verilator/mutate_eeprom.sh
#
# A "NOT CAUGHT" is a hole in the test, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
W=/tmp/sun3_eepmut
mkdir -p $W
run() {
  name="$1"; which="$2"; shift 2
  cp $RTL/sun3_mister_eeprom.sv $W/saver.sv
  cp $RTL/sun3/eeprom.v $W/eeprom.v
  if [ "$which" = saver ]; then f=$W/saver.sv; orig=$RTL/sun3_mister_eeprom.sv; else f=$W/eeprom.v; orig=$RTL/sun3/eeprom.v; fi
  sed -i "$@" $f
  if cmp -s $orig $f; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-MULTIDRIVEN -I$RTL/sun3 \
    +define+SIMULATION=1 +define+SUN3_EEPROM_SAVE=1 +define+SUN3_MEM_MIB=24 --top-module tb_mister_eeprom \
    --Mdir $W/obj -o tb tb_mister_eeprom.sv $W/saver.sv $W/eeprom.v >$W/build.log 2>&1 || { echo "$name: BUILD FAILED"; return; }
  out=$($W/obj/tb 2>&1)
  summary=$(echo "$out" | grep -E "^tb_mister_eeprom: [0-9]|timeout")
  first=$(echo "$out" | grep -m1 "^FAIL ")
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary -- $first"; fi
}
# the saver
run "any size is an EEPROM"          saver -e "s/if (img_size == 64'd2048) begin/if (img_size != 64'd0) begin/"
run "an unmount stays connected"     saver -e "s/^                    ena <= 1'b0;$/                    ;/"
run "read-only images written"       saver -e "s/end else if (ena \&\& !ro \&\& dirty/end else if (ena \&\& dirty/"
run "no first pass"                  saver -e "s/check   <= 1'b1;/check   <= 1'b0;/"
run "the first pass sees only zeros" saver -e "s/sd_buff_dout != 8'h00) nonzero/1'b0) nonzero/"
run "a new file not given the EEPROM" saver -e "/a new file: it gets what the EEPROM holds/,+3{s/dirty   <= 1'b1;/dirty   <= 1'b0;/}"
run "the load never reaches the EEPROM" saver -e "s/assign ee_we       = loading \&\& !check/assign ee_we       = 1'b0 \&\& !check/"
run "every block is block 0"         saver -e "s/assign ee_addr     = {blk, sd_buff_addr};/assign ee_addr     = {2'b00, sd_buff_addr};/"
run "only one block"                 saver -e "s/end else if (blk != 2'd3) begin/end else if (1'b0) begin/"
run "no wait for quiet"              saver -e "s/quiet_cnt <= QUIET;/quiet_cnt <= 32'd0;/"
run "the machine's writes ignored"   saver -e "s/if (machine_wrote \&\& ena) begin/if (1'b0) begin/"
run "writes during a save lost"      saver -e "s/if (machine_wrote \&\& ena) begin/if (machine_wrote \&\& ena \&\& state == S_IDLE) begin/"
run "the request left up"            saver -e "/S_REQ:/,+3{s/sd_rd <= 1'b0;/sd_rd <= sd_rd;/}"
run "ready without the PROM"         saver -e "s/if (rom_loaded \&\& !ready) begin/if (!ready) begin/"
run "ready before the load"          saver -e "s/if ((!ena \&\& !load_pending \&\& state == S_IDLE) || wait_cnt == WAIT)/if (1'b1)/"
run "no giving up"                   saver -e "s/ || wait_cnt == WAIT) ready/) ready/"
run "ready early in the load"        saver -e "/an image: now into the EEPROM/,+3{s/sd_rd <= 1'b1;/sd_rd <= 1'b1; ready <= 1'b1;/}"
# the EEPROM
run "the second port never writes"   eeprom -e "s/if (save_we) sram\[save_addr\] <= save_wdata;/if (1'b0) sram[save_addr] <= save_wdata;/"
run "no write toggle"                eeprom -e "s/if (WR) save_wr_tgl <= ~save_wr_tgl;/if (1'b0) save_wr_tgl <= ~save_wr_tgl;/"
run "test pattern backwards"         eeprom -e "s/sram\[11'h0b8\] = 8'haa;/sram[11'h0b8] = 8'h55;/"
