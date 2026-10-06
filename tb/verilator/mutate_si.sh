#!/bin/bash
# Mutation check for tb_si: each line puts back a bug in sun3_si.sv's packed
# DMA, and the test must fail.
#
#     tb/verilator/mutate_si.sh
#
# A "NOT CAUGHT" is a hole in the test, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
W=$RTL/vendor/wish5380
T=/tmp/sun3_simut
mkdir -p $T
run() {
  name="$1"; shift
  cp $RTL/sun3/sun3_si.sv $T/m.sv
  sed -i "$@" $T/m.sv
  if cmp -s $RTL/sun3/sun3_si.sv $T/m.sv; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $T/obj
  verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD -I$RTL/sun3 +define+SIMULATION=1 \
    --top-module tb_si --Mdir $T/obj -o tb \
    $W/wish5380_pkg.sv $W/sci_regs.sv $W/sci_bus.sv $W/wish5380.sv $W/scsi_fabric.sv $W/scsi_targ.sv \
    $RTL/sun3/wish7990_dvma_to_020.v $T/m.sv sun3_si_ref.sv tb_si.sv >$T/build.log 2>&1 || { echo "$name: BUILD FAILED"; return; }
  out=$($T/obj/tb 2>&1)
  summary=$(echo "$out" | grep -E "^tb_si:|timed out")
  first=$(echo "$out" | grep -m2 "^FAIL:" | tr '\n' ';')
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT ($summary)"; else echo "$name: caught -- $summary -- $first"; fi
}
run "no write at a full longword"     -e "s/(dma_addr\[1:0\] == 2'b00 || rx_left == 16'd0 || stopped)/(rx_left == 16'd0 || stopped)/"
run "no write at the end of the count" -e "s/(dma_addr\[1:0\] == 2'b00 || rx_left == 16'd0 || stopped)/(dma_addr[1:0] == 2'b00 || stopped)/"
run "no write when ended short"       -e "s/|| rx_left == 16'd0 || stopped)/|| rx_left == 16'd0)/"
run "ends with bytes still gathered"  -e "s/if (send || pk_n == 3'd0) begin/if (1'b1) begin/"
run "EOP from fifo_count"             -e "s/e_eop = (rx_left == 16'd1)/e_eop = (fifo_count == 16'd1)/"
run "UDC count parity swapped"        -e "s/udc_dec = fifo_count\[0\] ?/udc_dec = !fifo_count[0] ?/"
run "UDC count below zero"            -e "s/(udc_count > udc_dec) ? udc_count - udc_dec : 16'h0/udc_count - udc_dec/"
run "a fault counts all gathered"     -e "s/e_cnt      = m_err ? 3'd1 : pk_n/e_cnt      = pk_n/"
run "a fault reports the last byte"   -e "s/e_byte_val = m_err ? pk_first : pk_last/e_byte_val = pk_last/"
run "fifo_data not the last byte"     -e "s/pk_last  <= c_rdat;/pk_last  <= pk_last;/"
run "first byte taken at every byte"  -e "s/if (pk_n == 3'd0) begin/if (1'b1) begin/"
run "lanes kept after a write"        -e "s/else begin pk_n <= 3'd0; pk_sel <= 4'h0; est <= E_RUN; end/else begin pk_n <= 3'd0; est <= E_RUN; end/"
run "gathered bytes kept at start"    -e "s/^             pk_n    <= 3'd0;$/             pk_n    <= pk_n;/"
run "read longword kept past its end" -e "s/if (dma_addr\[1:0\] == 2'b11) sb_ok <= 1'b0;/if (1'b0) sb_ok <= 1'b0;/"
run "read longword kept at start"     -e "s/^             sb_ok   <= 1'b0;$/             sb_ok   <= sb_ok;/"
run "send reads one byte"             -e "s/m_sel <= 4'b1111;/m_sel <= 4'b0001 << a_lane;/"
