`timescale 1ns / 1ps

`include "sun3_config.vh"
`include "sun3_attr.vh"

// The 32-byte ID PROM (Architecture Manual 4.2): format 1, machine type,
// Ethernet address, date, serial, checksum (the XOR of bytes 0x00-0x0F is 0),
// 16 reserved bytes.  The checksum is computed here, not written down, so
// changing any other byte cannot leave the PROM saying "ID PROM INVALID".
//
// With SUN3_IDPROM_LOAD the 32 bytes are a memory that starts out holding
// these and that something outside the machine may overwrite: on MiSTer,
// hps_io with games/Sun-3/boot1.rom, or with the image Main_MiSTer's Sun
// family support makes from the host's own Ethernet address.  Whatever is
// written is taken as it is, checksum included.  The write port is in the
// loader's clock and the read port the CPU's; nothing is written once the
// machine runs.  (After Sun-2_MiSTer's rtl/sun2-common/idprom.v.)
module idprom_sun3(input CLK,
		   input [4:0] 	    idx,
		   output reg [7:0] dout
`ifdef SUN3_IDPROM_LOAD
		   , input 	    wr_clk,
		   input 	    wr_en,
		   input [4:0] 	    wr_addr,
		   input [7:0] 	    wr_data
`endif
		   );

   localparam [7:0] FORMAT  = 8'h01;
   localparam [7:0] MACHINE = 8'h17;   // Sun-3/60 ("Ferrari"); 0x11 is the 3/160 ("Carrera")
   localparam [7:0] ETH0 = 8'h08, ETH1 = 8'h00, ETH2 = 8'h20;   // Sun's OUI
   localparam [7:0] ETH3 = 8'h11, ETH4 = 8'h22, ETH5 = 8'h33;
   localparam [7:0] DATE0 = 8'h22, DATE1 = 8'he8, DATE2 = 8'hd5, DATE3 = 8'hce;
   localparam [7:0] SER0 = 8'h00, SER1 = 8'h84, SER2 = 8'ha2;
   localparam [7:0] CKSUM = FORMAT ^ MACHINE ^ ETH0 ^ ETH1 ^ ETH2 ^ ETH3 ^ ETH4 ^ ETH5 ^
			    DATE0 ^ DATE1 ^ DATE2 ^ DATE3 ^ SER0 ^ SER1 ^ SER2;

   function [7:0] contents(input [4:0] i);
      case (i)
	5'h00: contents = FORMAT;
	5'h01: contents = MACHINE;
	5'h02: contents = ETH0;
	5'h03: contents = ETH1;
	5'h04: contents = ETH2;
	5'h05: contents = ETH3;
	5'h06: contents = ETH4;
	5'h07: contents = ETH5;
	5'h08: contents = DATE0;
	5'h09: contents = DATE1;
	5'h0a: contents = DATE2;
	5'h0b: contents = DATE3;
	5'h0c: contents = SER0;
	5'h0d: contents = SER1;
	5'h0e: contents = SER2;
	5'h0f: contents = CKSUM;
	default: contents = 8'hff;      // reserved
      endcase
   endfunction

`ifdef SUN3_IDPROM_LOAD
   reg [7:0] mem [0:31];
   integer   i;
   initial for (i = 0; i < 32; i = i + 1) mem[i] = contents(i);

   always @(posedge wr_clk)
     if (wr_en) mem[wr_addr] <= wr_data;

   always @(posedge CLK)
     dout <= mem[idx];
`else
   always @(posedge CLK)
     dout <= contents(idx);
`endif

endmodule
