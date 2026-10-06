`ifndef SUN3_ATTR_VH
`define SUN3_ATTR_VH
//
// Synthesis attributes, spelled once, per tool.  A typo in a macro is an
// elaboration error; a typo in an attribute is silently ignored.
//
// Vivado reads `ram_style' and ignores `ramstyle'; Quartus the reverse.
// Sun-3.qsf defines SUN3_QUARTUS; nothing else does.  The MiSTer's Cyclone V
// has M10K blocks (Sun-3_FPGA's MAX 10 had M9K).  Quartus has no
// per-register ASYNC_REG: its global SYNCHRONIZER_IDENTIFICATION setting and
// the SDC's asynchronous clock groups do that job (as in the Sun-2 project).
//
// SUN3_RAM_BLOCK_NORW is for a RAM with two write ports in two clocks, whose
// ports never touch the same byte at once: without no_rw_check, Quartus 17
// declines the true dual-port M10K for "unsupported read-during-write
// behavior" (276009) and builds the array from registers.
//
`ifdef SUN3_QUARTUS
 `define SUN3_RAM_BLOCK (* ramstyle = "M10K" *)
 `define SUN3_RAM_BLOCK_NORW (* ramstyle = "M10K, no_rw_check" *)
 `define SUN3_ASYNC_REG
`else
 `define SUN3_RAM_BLOCK (* ram_style = "block" *)
 `define SUN3_RAM_BLOCK_NORW (* ram_style = "block" *)
 `define SUN3_ASYNC_REG (* ASYNC_REG = "TRUE" *)
`endif

`endif // SUN3_ATTR_VH
