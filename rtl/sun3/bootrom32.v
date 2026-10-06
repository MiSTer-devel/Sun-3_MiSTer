`timescale 1ns / 1ps

`include "sun3_config.vh"
`include "sun3_attr.vh"

`ifdef SUN3_BOOTROM_LOAD
// The 64 KiB boot PROM as a block RAM that something outside the machine
// fills -- on MiSTer, hps_io from games/Sun-3/boot0.rom at start-up -- so the
// bitstream carries no Sun firmware.  The write port is in the loader's clock;
// the read port is the CPU's and behaves exactly as the compiled-in ROM below
// does, one clock of latency.  The machine is held in reset until the load is
// done, so the two ports are never busy at once.  (After Sun-2_MiSTer's
// rtl/sun2-common/bootrom.v.)
module bootrom32(input CLK,
		 input [13:0] 	   idx,
		 output reg [31:0] dout,
		 input 		   wr_clk,
		 input 		   wr_en,
		 input [13:0] 	   wr_addr,
		 input [31:0] 	   wr_data
		 );

   `SUN3_RAM_BLOCK reg [31:0] mem [0:16383];

   always @(posedge wr_clk)
     if (wr_en) mem[wr_addr] <= wr_data;

   always @(posedge CLK)
     dout <= mem[idx];

endmodule // bootrom32

`else
// The 64 KiB boot PROM, as 16384 32-bit words.  The contents are generated
// into build/rom/ by tools/ (see tools/Makefile) and selected by
// SUN3_BOOTROM_FILE in sun3_config.vh.
module bootrom32(input CLK,
		 input [13:0] 	   idx,
		 output reg [31:0] dout
		 );

  always @(posedge CLK)
    begin
       case(idx)
`include `SUN3_BOOTROM_FILE
       endcase // case (idx)
    end

endmodule // bootrom32
`endif
