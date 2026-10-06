// Build configuration for the Sun-3 replica.
//
// Every knob has a default here; the simulation scripts and the synthesis
// flow override them with -d / -define.  Nothing else in rtl/ defines a
// configuration macro -- a `define buried in a source file is a knob that
// silently wins over the command line (the old design had two such, which
// could turn both Ethernet implementations on at once).
//
//   SUN3_CPU_RD68021     build Inputs/RD68021 instead of the Suska 68K30L
//   SUN3_ETH_WISH7990    the on-board Ethernet, Wish7990 (Am79C90), at OBIO 0x120000
//   SUN3_SCSI            the on-board SCSI (sun3_si.sv: Wish5380's 5380 and disk
//                        target, an Am9516 subset), at OBIO 0x140000, with the
//                        disk's block seam brought out to the board
//   SUN3_FPU             an MC68881 (Inputs/RD68884) at CpID 1 next to the
//                        RD68021 (COPROCESSOR=1), enabled by EN.FPP; needs
//                        SUN3_CPU_RD68021.  Without it every coprocessor
//                        cycle ends in BERR, i.e. an F-line trap
//   SUN3_FPU_WAIT        the FPU's same-clock bus front end: 0 or 1 wait
//                        state (RD68884 BUS_SYNC_WAIT; default 0)
//   SUN3_HAS_DVMA        derived, not set: a DVMA master exists (either of the two)
//   SUN3_WB_FIFO         the memory bridge through two dual-clock FIFOs
//                        (sun3_fifo_bridge.v): writes acknowledged when queued,
//                        reads matched by tag, the Wishbone side on its own
//                        clock (sun3_top's wb_clk_i / wb_rst_i); otherwise the
//                        synchronous sun3_wishbone_bridge
//   SUN3_WB_CACHE        with SUN3_WB_FIFO: a direct-mapped, write-through,
//                        no-allocate read cache of 16-byte lines in front of
//                        the FIFOs (sun3_cached_fifo_bridge.v); a read miss
//                        brings back the whole line (sun3_top's wb_line_i)
//   SUN3_WB_CACHE_IDX    its size: 2**IDX lines (default 9: 8 KiB, the largest
//                        whose index is all page offset, see the bridge)
//   SUN3_FB              the on-board bw2 video memory, at the top of DDR3
//                        (on unless SUN3_NO_FB).  Every real 3/60 has it and the PROM assumes it
//                        (without it the monitor's `h' draws into an
//                        unmapped page).  It does not move the console.
//   SUN3_VIDEO           the bw2 on the board's HDMI output (fb_scanout.sv,
//                        VESA 1280x1024@60 with 1152x900 centred; needs
//                        SUN3_FB): EN.VIDEO enables it, its vertical blanking
//                        is the level-4 video interrupt (V_INT)
//   SUN3_FB_CONSOLE      the EEPROM names the screen as the console (needs
//                        SUN3_FB and a video output); otherwise serial A
//
// Added by Sun-3_MiSTer (rtl/sun3/README.md has the details):
//   SUN3_BOOTROM_LOAD    the boot PROM is a block RAM written from outside
//                        (bootrom32.v), not a ROM built into the bitstream
//   SUN3_IDPROM_LOAD     the ID PROM may be overwritten from outside
//                        (idprom_sun3.v)
//   SUN3_EEPROM_SAVE     the EEPROM has a second port for loading and saving
//                        it outside the machine, and tells of each write
//                        (eeprom.v)
//   SUN3_TOD_LOAD        the ICM7170 is set from outside, and a reset keeps
//                        its time (icm7170.v)
//   SUN3_TOD_TICK_HZ     the ICM7170's oscillator is the tod_tick input, this
//                        many one-CLK pulses a second, instead of CLK
//                        itself: CLK may then change (Sun-3_MiSTer, whose
//                        CPU clock is set from the OSD)
//   SUN3_TAPE            st0, an MT-02 QIC tape at SCSI target 4
//                        (sun3_mt02.sv), with its own block seam
//   SUN3_SD1             a second disk at SCSI target 1 (Wish5380's
//                        scsi_targ; SunOS's sd2), with its own block seam
//   SUN3_CG4             a P4 cg4 colour board, fitted while the cg4_present
//                        input says so (sun3_cg4.sv, docs/cg4.md)
//
//   SUN3_MEM_MIB         installed main memory, in MiB
//   SUN3_CPU_HZ          the CPU clock (CLK), in Hz: the TOD chip counts it
//                        unless SUN3_TOD_TICK_HZ.  Must match the clock
//                        actually supplied; the sim and syn flows set both
//                        from one variable.  Sun-3_MiSTer's CLK starts at
//                        it and may be faster: the SCSI board's settle
//                        delays and the LANCE's ring poll, counted in its
//                        clocks, are then shorter in proportion
//   SUN3_BOOTROM_FILE    the boot PROM case body, from build/rom/ (or
//                        SUN3_BOOTROM_SELECTED, see below)
//   SUN3_NO_BUS_TRACE    leave out bus_trace.v (8 block RAMs of 4 KiB); its
//                        control space then reads as zeros
//   SUN3_NO_FAULT_LOG    leave out fault_log.v (the last 32 bus errors, ~1,000
//                        ALMs of registers); its control space then reads
//                        as zeros too (Sun-3_MiSTer)
//   DEVICE_8BITS_ON_32BITS_BUS
//                        byte devices answer as 32-bit ports with the byte
//                        replicated on all lanes (on unless SUN3_BYTE_PORTS_8)

`ifndef SUN3_CONFIG_VH
`define SUN3_CONFIG_VH

`ifndef SUN3_CPU_HZ
 `define SUN3_CPU_HZ 20000000
`endif

// SUN3_WB_CACHE without SUN3_WB_FIFO is refused by the sim and syn scripts
// (Verilog has no portable `error).
`ifndef SUN3_WB_CACHE_IDX
 `define SUN3_WB_CACHE_IDX 9
`endif

`ifndef SUN3_FPU_WAIT
 `define SUN3_FPU_WAIT 0
`endif

`ifndef SUN3_MEM_MIB
 `define SUN3_MEM_MIB 4
`endif

// SUN3_BOOTROM_SELECTED: the build copied the PROM it wants to a fixed name in
// its own output directory (syn/build.tcl), because Vivado's -verilog_define
// does not carry a quoted string through intact.  xvlog's -d does, so the
// simulation flows name the file directly.
`ifdef SUN3_BOOTROM_SELECTED
 `define SUN3_BOOTROM_FILE "bootrom_selected_32bits.vh"
`endif
`ifndef SUN3_BOOTROM_FILE
 `define SUN3_BOOTROM_FILE "bootrom_sun3_60_v1.9_fast_32bits.vh"
`endif

`ifndef SUN3_NO_FB
 `define SUN3_FB
`endif

`ifdef SUN3_ETH_WISH7990
 `define SUN3_HAS_DVMA
`endif
`ifdef SUN3_SCSI
 `define SUN3_HAS_DVMA
`endif

`ifndef SUN3_BYTE_PORTS_8
 `define DEVICE_8BITS_ON_32BITS_BUS
`endif

`endif // SUN3_CONFIG_VH
