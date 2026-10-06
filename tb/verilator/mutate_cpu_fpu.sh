#!/bin/bash
# Mutation check for tb_cpu_fpu: each line breaks the CPU-FPU wiring in a copy
# of the bench (the wiring sun3_top.v uses), and the corpus must fail.  Run
# after `make tb_cpu_fpu` (it reads the list that left in obj_tb_cpu_fpu).
#
#     tb/verilator/mutate_cpu_fpu.sh
#
# A "NOT CAUGHT" is a hole in the corpus or the bench, not a pass.
cd "$(dirname "$0")" || exit 1
R=../../rtl/vendor
W=/tmp/sun3_fpumut
mkdir -p $W
SRC="$R/rd68021/rd68021_pkg.sv $R/rd68021/gen/rd68021_frame_pkg.sv $R/rd68021/gen/rd68021_ucode_pkg.sv
  $R/rd68021/gen/rd68021_cpdec_rom.sv $R/rd68021/gen/rd68021_decode_rom.sv $R/rd68021/gen/rd68021_eadec_rom.sv
  $R/rd68021/gen/rd68021_eamode_rom.sv $R/rd68021/gen/rd68021_ucode_rom.sv $R/rd68021/rd68021_sync.sv
  $R/rd68021/rd68021_dedge_ff.sv $R/rd68021/rd68021_shifter.sv $R/rd68021/rd68021_divider.sv
  $R/rd68021/rd68021_bitfield.sv $R/rd68021/rd68021_biu.sv $R/rd68021/rd68021_icache.sv
  $R/rd68021/rd68021_ifu.sv $R/rd68021/rd68021_seq.sv $R/rd68021/rd68021_top.sv
  $R/rd68884/rd68884_pkg.sv $R/rd68884/gen/rd68884_ucode_pkg.sv $R/rd68884/gen/rd68884_crom.sv
  $R/rd68884/gen/rd68884_ucode_rom.sv $R/rd68884/rd68884_sync.sv $R/rd68884/rd68884_biu.sv
  $R/rd68884/rd68884_regfile.sv $R/rd68884/rd68884_seq.sv $R/rd68884/rd68884_top.sv"
run() {
  name="$1"; shift
  cp tb_cpu_fpu.sv $W/tb.sv
  sed -i "$@" $W/tb.sv
  if cmp -s tb_cpu_fpu.sv $W/tb.sv; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-BLKANDNBLK -Wno-MULTIDRIVEN --top-module tb_cpu_fpu \
    --Mdir $W/obj -o tb $SRC $W/tb.sv >$W/build.log 2>&1 || { echo "$name: BUILD FAILED"; return; }
  out=$($W/obj/tb +list=obj_tb_cpu_fpu/corpus.txt 2>&1)
  summary=$(echo "$out" | grep -E "^tb_cpu_fpu: [0-9]")
  first=$(echo "$out" | grep -m1 "^FAIL ")
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary -- $first"; fi
}
run "no FPU"                       -e "s/wire        fpu_sel = (fc == 3'd7) \&\& (a\[19:16\] == 4'h2) \&\& (a\[15:13\] == 3'd1);/wire        fpu_sel = 1'b0;/"
run "the FPU at CpID 2"            -e "s/(a\[15:13\] == 3'd1);/(a[15:13] == 3'd2);/"
run "the FPU's lanes not merged"   -e "s/assign cpu_d_i\[8\*fl +: 8\] = fpu_d_oe\[fl\] ? fpu_d_o\[8\*fl +: 8\] : mem_q\[8\*fl +: 8\];/assign cpu_d_i[8*fl +: 8] = mem_q[8*fl +: 8];/"
run "A0 not strapped high"         -e "s/.a_i({a\[4:1\], 1'b1})/.a_i(a[4:0])/"
run "a 16-bit FPU port"            -e "s/.size_n_i(1'b1)/.size_n_i(1'b0)/"
