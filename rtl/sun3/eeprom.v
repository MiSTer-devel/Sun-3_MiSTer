`timescale 1ns / 1ps

`include "sun3_config.vh"
`include "sun3_attr.vh"

// The 2 KiB configuration EEPROM (OBIO 0x40000), preloaded with a layout the
// 3/60 PROM accepts.  Offsets are those of the Sun-3 EEPROM layout.
//
// With SUN3_EEPROM_SAVE it has a second port, in a clock of its own, through
// which the contents are loaded from and saved to a file outside the machine
// (on MiSTer, rtl/sun3_mister_eeprom.sv and the OSD's EEPROM image), and
// save_wr_tgl toggles at each write the machine makes, so that the saver
// knows there is something new.  (Sun-3_MiSTer.)
module eeprom(input CLK,
	      input [10:0]     idx,
	      input 	       WR,
	      input [7:0]      din,
	      output reg [7:0] dout
`ifdef SUN3_EEPROM_SAVE
	      , input 	       save_clk,
	      input [10:0]     save_addr,
	      input 	       save_we,
	      input [7:0]      save_wdata,
	      output reg [7:0] save_rdata,
	      output reg       save_wr_tgl = 1'b0
`endif
							  );

   // Preloaded contents, as plain blocking assignments in one initial block:
   // the form both Vivado and Quartus turn into an initialised block RAM.
`ifdef SUN3_EEPROM_SAVE
   `SUN3_RAM_BLOCK_NORW reg [7:0] sram[0:2047];
`else
   `SUN3_RAM_BLOCK reg [7:0] sram[0:2047];
`endif

   integer a;
   initial
     begin
`ifdef SUN3_SIM
	dout = $random;
`endif
	for (a = 0; a < 2048; a = a + 1) sram[a] = 8'h00;
	sram[11'h014] = `SUN3_MEM_MIB; // megabytes of memory installed
	sram[11'h015] = 8'h00; // memory tested
	sram[11'h016] = 8'h00; // monitor: 1152x900, the 3/60's bw2 (0x20 was 1280x1024)
	// 0x17: watchdog action ?
	sram[11'h018] = 8'h12; // boot from eeprom-specified device
	sram[11'h019] = 8'h73; // boot device (2 bytes)
	sram[11'h01a] = 8'h64;
`ifdef SUN3_FB_CONSOLE
	sram[11'h01f] = 8'h00; // primary terminal (0x00: frame buffer and keyboard)
`else
	sram[11'h01f] = 8'h10; // primary terminal (0x10: serial A)
`endif
	// 0x21: keyboard click?
	sram[11'h022] = 8'h69; // diag boot (2)
	sram[11'h023] = 8'h65;
	sram[11'h050] = 8'h50;
	sram[11'h051] = 8'h22;
	sram[11'h059] = 8'h25;
	sram[11'h05a] = 8'h80;
	sram[11'h05b] = 8'h12;
	sram[11'h061] = 8'h25;
	sram[11'h062] = 8'h80;
	sram[11'h063] = 8'h12;
	// The test pattern, 0xAA55 (NetBSD's dev/sun/eeprom.h, eeTestPattern;
	// Sun-3_FPGA had the bytes the other way round).  Neither the 1.9 nor
	// the 3.0.1 PROM looks at it.
	sram[11'h0b8] = 8'haa;
	sram[11'h0b9] = 8'h55;
	sram[11'h70b] = 8'h12;
`ifdef SUN3_SIM
	// +eeprom_boot=st (Sun-3_MiSTer's tb_emu): auto-boot from another
	// device than sd, without typing at the PROM.
	begin : sim_boot
	   reg [15:0] dev;
	   if ($value$plusargs("eeprom_boot=%s", dev)) begin
	      sram[11'h019] = dev[15:8];
	      sram[11'h01a] = dev[7:0];
	   end
	end
`endif
     end

   always @(posedge CLK)
     begin
	if (WR) sram[idx] <= din;
	dout <= sram[idx];
     end

`ifdef SUN3_EEPROM_SAVE
   // The saver writes only while it loads a file, which at power-up is with
   // the machine in reset: the two ports write the same byte at once only
   // if a file is mounted just as the machine writes that byte.  The toggle
   // turns at every clock of a write: the saver's clock is more than twice
   // this one, so it sees each turn.
   always @(posedge CLK)
     if (WR) save_wr_tgl <= ~save_wr_tgl;

   always @(posedge save_clk)
     begin
	if (save_we) sram[save_addr] <= save_wdata;
	save_rdata <= sram[save_addr];
     end
`endif

endmodule // eeprom
