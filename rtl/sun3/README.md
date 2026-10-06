# The Sun-3/60

The machine itself, vendor-neutral: the RD68021 wrapper (`sun3_top.v`), the
MMU, control space, on-board I/O and bus glue (`sun3_fpga.v`), the SCSI board
(`sun3_si.sv`), the memory bridges and the bw2 scan-out.

Copied from MelkhiorVintageComputing/Sun-3_FPGA `rtl/sun3/` at `f435268`
(2026-10-03) by Romain Dolbeau. Its `CLAUDE.md` is the engineering log
behind every choice in these files. Unlike `rtl/vendor/`, these files are
edited for MiSTer, and every change is listed here so that fixes can travel
both ways.

## Changes from Sun-3_FPGA

* **`bootrom32.v`**: a `SUN3_BOOTROM_LOAD` variant. The PROM is a block RAM
  with a write port that hps_io fills from `games/Sun-3/boot0.rom` while the
  machine is held in reset (after Sun-2_MiSTer's `bootrom.v`). The compiled-in
  case body is still there without the macro.
* **`idprom_sun3.v`**: the checksum is computed from the other bytes instead of
  written as a literal (it is the same value, 0xC9). There is a
  `SUN3_IDPROM_LOAD` variant whose 32 bytes start as the built-in ones and may
  be overwritten from ioctl index 64 (`boot1.rom`, or Main_MiSTer's ID PROM
  made from the host's MAC).
* **`sun3_fpga.v`, `sun3_top.v`**: the two load ports above and the EEPROM's
  second port, passed through.
* **The cg4** (`SUN3_CG4`; docs/cg4.md), a P4 colour board, fitted when the
  `cg4_present` input says so:
  * `sun3_fpga.v` matches its registers (the Bt458s at 0xFF200000, the P4
    register at 0xFF300000) for the new `sun3_cg4.sv`, and its three planes
    (overlay 0xFF400000, enable 0xFF600000, colour 0xFF800000) for the
    bridge. Absent, they time out, as they do on a 3/60 without one. Its
    retrace interrupt reaches level 4 through the new `sun3_vint.v`, the
    3/60's DSACK PAL (U805): a pulse at the start of the on-board video's
    vertical blank until the P4 board first interrupts, then the P4 board
    alone until a reset. Upstream fed the bw2's vertical blank, as a level,
    straight into the interrupt PAL;
  * at every reset the EEPROM's console byte (0x1F) is made 0x20, the P4
    board, with the board, and 0x00, the bw2, without, unless it names a
    serial port;
  * `sun3_top.v` passes through what the scan-out needs: the Bt458s' state
    and the colour map's second read port;
  * `sun3_cached_fifo_bridge.v` takes the planes as `MATCH_CG`: uncached,
    at Wishbone word `{6'h3F, PA[25:2]}`, the top of the space;
  * `sun3_cg4_scanout.sv` (new) draws them, through the colour map, into
    the same raster as `fb_scanout.sv`.
* **`sun3_si.sv`**: the tape, st0, an Emulex MT-02 at target 4
  (`SUN3_TAPE`, `sun3_mt02.sv` from Sun-2_MiSTer), with its own block seam.
  A second disk at target 1 (`SUN3_SD1`, another `scsi_targ`, SunOS's sd2) on
  the fabric's fourth port, with its own block seam too. In simulation,
  `+trace_scsi` logs each selection and every byte on the bus with its phase.
  The DMA engine also ends a transfer when the target asks in STATUS or
  MESSAGE IN, even if the chip never asked for a byte: a tape READ at a file
  mark moves nothing, and the transfer never ended.
  The engine moves a longword per DVMA cycle instead of a byte (received
  bytes are gathered and written when their longword is full, when the count
  runs out or when the transfer ends short; sent bytes come from one longword
  read). A byte per cycle held the bus for 21 CPU clocks a byte, and it was
  what limited large disk transfers. The counters end as they did, which
  `tb/verilator/tb_si.sv` checks against the old engine, kept there as
  `sun3_si_ref.sv`.
* **`sun3_mt02.sv`** (from Sun-2_MiSTer `816c187`): a READ that meets a file
  mark or blank tape before its first block answers STATUS after 5 ms of
  "tape motion". The PROM's si driver sets the 5380's DMA mode only after
  the CDB, and the chip's phase-mismatch interrupt needs REQ to rise in DMA
  mode; answering at once, the target was already asking, and the PROM
  waited 15 s and gave up. Sun-2_MiSTer's copy could take the same change.
* **`icm7170.v`**: a load port and `TIME_RESET`. With `SUN3_TOD_LOAD` the chip
  is set once from MiSTer's RTC (`rtl/sun3_mister_tod.sv`), and a machine
  reset neither clears nor stops its time; it only turns off the chip's
  interrupt output. Its oscillator is a `TICK` input, FREQ one-clock pulses
  a second; tied high it counts CLK as before. With `SUN3_TOD_TICK_HZ`
  (`sun3_fpga.v`, `sun3_top.v`: a `tod_tick` port) it is a fixed 1 MHz from
  `rtl/sun3_mister_tick.sv`, so that the time and SunOS's 100 Hz clock stay
  right when the OSD changes the CPU's clock. Three bugs in the model are
  fixed:
  * the year turned at the end of November;
  * the weekday never advanced;
  * a reset stopped the clock.
* **`eeprom.v`**:
  * with `SUN3_EEPROM_SAVE`, a second port in a clock of its own, through
    which `rtl/sun3_mister_eeprom.sv` loads the EEPROM from its image file
    and saves it back, and a toggle that turns at each write the machine
    makes. The array is `SUN3_RAM_BLOCK_NORW`, so that Quartus builds the
    two-clock RAM in an M10K;
  * the test pattern at 0x0B8 is 0xAA55, NetBSD's `eeTestPattern`;
    Sun-3_FPGA had its bytes swapped. Neither the 1.9 nor the 3.0.1 PROM
    reads it;
  * in simulation, `+eeprom_boot=st` makes the boot device the tape, so
    `tb_emu` auto-boots from it without typing at the PROM.
* **`sun3_attr.vh`**: `SUN3_QUARTUS` asks for `M10K`, the Cyclone V's block,
  not the MAX 10's `M9K`. `SUN3_RAM_BLOCK_NORW` adds `no_rw_check`, for a RAM
  written from two clocks.

Unchanged, but not built here: `sun3_wishbone_bridge.v` and
`sun3_fifo_bridge.v` (the cached FIFO bridge is the one used),
`bus_trace.v` (`SUN3_NO_BUS_TRACE`), `wish7990_sun3_regs.v` (until the network,
Phase 5).
