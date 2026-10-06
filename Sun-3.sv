//============================================================================
//  Sun-3/60C for MiSTer
//
//  The emu module: the MiSTer framework (sys/) on one side, the Sun-3 machine
//  (rtl/sun3/sun3_top.v, from Sun-3_FPGA) on the other, and the board-level
//  pieces that join them.  The machine is fixed by Sun-3.qsf's macro block and
//  described in docs/hardware.md: a Sun-3/60C with its RD68021 and RD68884,
//  24 MiB, the on-board bw2, a cg4 colour board in the P4 slot, SCSI and
//  serial ports.
//
//  Built so far (docs/design-plan.md): Phases 1 to 5 -- the PROM, its
//  console with MiSTer's keyboard and mouse as a Sun Type 3 and a Sun-3
//  mouse, the keyboard's bell, the TOD chip set from MiSTer's clock, two SCSI
//  disks and the tape, the EEPROM kept in a file, the cg4 (docs/cg4.md) and
//  the LANCE on Main_MiSTer's network mailbox; and Phase 6's CPU clock.
//
//  Clocks (rtl/pll.v, rtl/pll_serial.v)
//    clk_mem   100.000 MHz  SDRAM, the memory side of the Wishbone bridge, hps_io,
//                           the keyboard and mouse, the TOD chip's 1 MHz
//    clk_pix    83.333 MHz  the raster
//    cpu_clk    20.000 MHz  the machine and its block seam; 25 or 33.33 MHz from
//                           the OSD, by reconfiguring its counter alone
//    clk_mii     2.500 MHz  the LANCE's MII
//    clk_ser     4.9152 MHz the SCCs' baud rate generators
//    CLK_50M    50.000 MHz  the framework's: the PLL's reconfiguration
//    CLK_AUDIO  24.576 MHz  the framework's: the keyboard's beeper
//
//  Memory: 24 MiB of main memory, the bw2 and the cg4's three planes on the
//  SDRAM board, behind rtl/sun3_mister_sdram.sv.  The boot PROM is not in the bitstream: it is
//  games/Sun-3/boot0.rom (a 3/60 PROM patched for no parity: tools/), which
//  Main_MiSTer sends on ioctl index 0 at start-up, and the machine stays in
//  reset until it has arrived.
//
//  After Sun-2_MiSTer's Sun-2.sv, which has the history of most choices here.
//============================================================================

`timescale 1ns / 1ps

`include "sun3_config.vh"

module emu
(
    `include "sys/emu_ports.vh"
);

    // ---- what this core does not use ------------------------------------------
    assign ADC_BUS  = 'Z;
    assign USER_OUT = '1;
    assign {UART_RTS, UART_DTR} = 2'b00;
    assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

    assign VGA_SL      = 2'b00;
    assign VGA_F1      = 1'b0;
    assign VGA_SCALER  = 1'b0;
    assign VGA_DISABLE = 1'b0;
    assign HDMI_FREEZE    = 1'b0;
    assign HDMI_BLACKOUT  = 1'b0;
    assign HDMI_BOB_DEINT = 1'b0;

    assign BUTTONS   = 2'b00;
    assign LED_POWER = 2'b00;

    // ---- the OSD ---------------------------------------------------------------
    // status[0] is the reset item and nothing else; the options start at 1, and
    // the bits keep the places docs/design-plan.md gives them (the Network's
    // [11:9] is what Main_MiSTer's Sun family support reads).  The disks and
    // the EEPROM are SC: Main remembers the image last chosen and mounts it
    // again whenever the core starts, so the PROM finds its settings and the
    // disk, and auto-boots.  The slots are docs/design-plan.md's.
    `include "build_id.v"
    localparam CONF_STR = {
        "Sun-3;UART9600;",
        "SC0,IMGVHD,SCSI disk ID 0 (sd0);",
        "SC1,IMGVHD,SCSI disk ID 1 (sd2);",
        "S2,QIC,Tape (st0);",
        "O[4:3],Tape volume,1,2,3;",
        "SC3,NVR,EEPROM;",
        "-;",
        "O[2:1],Aspect ratio,Original,Full Screen,4:3;",
        "O[6:5],Scale,V-Integer,Normal,Narrower HV-Integer,Wider HV-Integer;",
        "O[12],Colour board,On,Off;",
        "O[14:13],CPU clock,20 MHz,25 MHz,33 MHz;",
        "-;",
        "O[8:7],Keyboard bell,Normal,Loud,Quiet,Off;",
        "O[16],Clock,MiSTer's time,28 years back;",
        "O[11:9],Network,eth0,Off,eth1,macvlan,tap0;",
        "O[15],Diag switch,Normal,Diag;",
        "-;",
        "R0,Reset;",
        "V,v",`BUILD_DATE
    };

    wire [127:0] status;
    wire [1:0]   buttons;

    // The raster is 1160x904 (the 1152x900 screen and a small border, which
    // fb_scanout needs for its prefetch) of square pixels.  V-Integer is the
    // default, so it is listed first and its status value is 0: video_freak's
    // own numbering is 0 normal, 1 V-integer.
    wire [1:0] ar    = status[2:1];
    wire [2:0] scale = (status[6:5] == 2'd0) ? 3'd1 :
                       (status[6:5] == 2'd1) ? 3'd0 : {1'b0, status[6:5]};

    // ---- clocks ------------------------------------------------------------------
    wire clk_mem, clk_pix, clk_mii, cpu_clk, clk_ser;
    wire locked_main, locked_ser;

    wire [63:0] reconfig_to_pll, reconfig_from_pll;

    pll pll (
        .refclk            (CLK_50M),
        .rst               (1'b0),
        .outclk_0          (clk_mem),
        .outclk_1          (cpu_clk),
        .outclk_2          (clk_pix),
        .outclk_3          (clk_mii),
        .locked            (locked_main),
        .reconfig_to_pll   (reconfig_to_pll),
        .reconfig_from_pll (reconfig_from_pll)
    );

    pll_serial pll_serial (
        .refclk   (CLK_50M),
        .rst      (1'b0),
        .outclk_0 (clk_ser),
        .locked   (locked_ser)
    );

    wire locked = locked_main & locked_ser;


    // ---- hps_io --------------------------------------------------------------------
    wire [10:0] ps2_key;
    wire [24:0] ps2_mouse;
    wire [64:0] rtc;

    // The virtual drives: VD 0 and 1 the disks, VD 2 the tape, VD 3 the EEPROM.
    wire [31:0] sd_lba[4];
    wire [3:0]  sd_rd, sd_wr, sd_ack;
    wire [13:0] sd_buff_addr;
    wire [7:0]  sd_buff_dout;
    wire [7:0]  sd_buff_din[4];
    wire        sd_buff_wr;
    wire [3:0]  img_mounted;
    wire        img_readonly;
    wire [63:0] img_size;

    wire        ioctl_download;
    wire [15:0] ioctl_index;
    wire        ioctl_wr;
    wire [26:0] ioctl_addr;
    wire [7:0]  ioctl_dout;

    hps_io #(.CONF_STR(CONF_STR), .VDNUM(4)) hps_io (
        .clk_sys        (clk_mem),
        .HPS_BUS        (HPS_BUS),
        .EXT_BUS        (),

        .buttons        (buttons),
        .status         (status),
        .status_menumask(16'd0),

        .ps2_key        (ps2_key),
        .ps2_mouse      (ps2_mouse),
        .RTC            (rtc),

        .sd_lba         (sd_lba),
        .sd_rd          (sd_rd),
        .sd_wr          (sd_wr),
        .sd_ack         (sd_ack),
        .sd_buff_addr   (sd_buff_addr),
        .sd_buff_dout   (sd_buff_dout),
        .sd_buff_din    (sd_buff_din),
        .sd_buff_wr     (sd_buff_wr),
        .img_mounted    (img_mounted),
        .img_readonly   (img_readonly),
        .img_size       (img_size),

        .ioctl_download (ioctl_download),
        .ioctl_index    (ioctl_index),
        .ioctl_wr       (ioctl_wr),
        .ioctl_addr     (ioctl_addr),
        .ioctl_dout     (ioctl_dout),
        .ioctl_wait     (1'b0)
    );

    // ---- the boot PROM, from boot0.rom ---------------------------------------------
    // 64 KiB, big-endian 32-bit words: byte 4w is bits 31:24 of word w.  The
    // machine is held in reset until a whole image has been received.
    reg        rom_wr_en   = 1'b0;
    reg [13:0] rom_wr_addr = 14'd0;
    reg [31:0] rom_wr_data = 32'h0;
    reg [23:0] rom_hi      = 24'h0;
    reg        rom_loading = 1'b0;
    reg        rom_loaded  = 1'b0;

    always @(posedge clk_mem) begin
        rom_wr_en <= 1'b0;
        if (ioctl_download && ioctl_index[7:0] == 8'd0) begin       // boot0.rom; boot1.rom would be 64
            rom_loading <= 1'b1;
            rom_loaded  <= 1'b0;
            if (ioctl_wr && ioctl_addr < 27'd65536) begin
                if (ioctl_addr[1:0] != 2'd3)
                    rom_hi[8 * (2'd2 - ioctl_addr[1:0]) +: 8] <= ioctl_dout;
                else begin
                    rom_wr_en   <= 1'b1;
                    rom_wr_addr <= ioctl_addr[15:2];
                    rom_wr_data <= {rom_hi, ioctl_dout};
                end
            end
        end else if (rom_loading) begin
            rom_loading <= 1'b0;
            rom_loaded  <= 1'b1;
        end
    end

    // ---- the ID PROM, from boot1.rom ------------------------------------------------
    // ioctl index 64, which Main_MiSTer sends games/Sun-3/boot1.rom on, is a
    // 32-byte ID PROM image, written over the built-in one as it comes
    // (rtl/sun3/idprom_sun3.v).  Main's Sun support makes one from the
    // MiSTer's own Ethernet address when there is no file.  Its Ethernet
    // address, bytes 2..7, is kept here too, for the network's mailbox; it
    // starts as idprom_sun3.v's built-in one.
    reg        idp_wr_en   = 1'b0;
    reg  [4:0] idp_wr_addr = 5'd0;
    reg  [7:0] idp_wr_data = 8'h0;
    reg [47:0] idp_mac     = 48'h08_00_20_11_22_33;

    always @(posedge clk_mem) begin
        idp_wr_en <= 1'b0;
        if (ioctl_download && ioctl_index[7:0] == 8'd64 && ioctl_wr && ioctl_addr < 27'd32) begin
            idp_wr_en   <= 1'b1;
            idp_wr_addr <= ioctl_addr[4:0];
            idp_wr_data <= ioctl_dout;
            if (ioctl_addr >= 27'd2 && ioctl_addr <= 27'd7)
                idp_mac[8 * (3'd7 - ioctl_addr[2:0]) +: 8] <= ioctl_dout;
        end
    end

    // Memory and the EEPROM's file restart only when the clocks do: a machine
    // reset must not lose the SDRAM's contents or start the EEPROM's load again.
    wire reset_mem;
    reset_sync rst_mem (.clk(clk_mem), .rst_async_in(~locked), .rst_sync_out(reset_mem));

    // ---- the EEPROM, kept in a file ------------------------------------------------
    // VD 3, an image of the EEPROM's 2 KiB, read into it before the machine
    // starts and written back when the machine has changed it
    // (rtl/sun3_mister_eeprom.sv); the EEPROM's second port is its buffer.
    wire        ee_ready, ee_we, ee_wr_tgl;
    wire [10:0] ee_addr;
    wire [7:0]  ee_wdata, ee_rdata;

    sun3_mister_eeprom eeprom (
        .clk          (clk_mem),
        .rst          (reset_mem),
        .img_mounted  (img_mounted[3]),
        .img_readonly (img_readonly),
        .img_size     (img_size),
        .sd_lba       (sd_lba[3]),
        .sd_rd        (sd_rd[3]),
        .sd_wr        (sd_wr[3]),
        .sd_ack       (sd_ack[3]),
        .sd_buff_addr (sd_buff_addr[8:0]),
        .sd_buff_dout (sd_buff_dout),
        .sd_buff_din  (sd_buff_din[3]),
        .sd_buff_wr   (sd_buff_wr),
        .ee_addr      (ee_addr),
        .ee_we        (ee_we),
        .ee_wdata     (ee_wdata),
        .ee_rdata     (ee_rdata),
        .ee_wr_tgl    (ee_wr_tgl),
        .rom_loaded   (rom_loaded),
        .ready        (ee_ready)
    );

    // ---- resets -----------------------------------------------------------------------
    // The machine: the OSD's reset, the framework's, an unlocked PLL, no PROM
    // yet, or an EEPROM image still loading; and while the CPU's clock is
    // being changed, which happens only in one of those.
    wire machine_reset_req = status[0] | buttons[1] | RESET | ~locked | ~rom_loaded | ~ee_ready;
    wire cpuclk_hold;
    wire machine_reset_raw = machine_reset_req | cpuclk_hold;

    // ---- the CPU's clock ---------------------------------------------------------------
    // 20, 25 or 33.33 MHz from the OSD, by rewriting the main PLL's cpu_clk
    // counter (rtl/sun3_mister_cpuclk.sv) through the framework's PLL
    // reconfiguration core, on CLK_50M.  It changes in a machine reset and
    // holds the machine there until the clock has settled; a change made
    // while the machine runs waits for the next reset.
    wire        cfg_waitrequest, cfg_write;
    wire [5:0]  cfg_address;
    wire [31:0] cfg_writedata;

    pll_cfg pll_cfg (
        .mgmt_clk          (CLK_50M),
        .mgmt_reset        (1'b0),
        .mgmt_waitrequest  (cfg_waitrequest),
        .mgmt_read         (1'b0),
        .mgmt_readdata     (),
        .mgmt_write        (cfg_write),
        .mgmt_address      (cfg_address),
        .mgmt_writedata    (cfg_writedata),
        .reconfig_to_pll   (reconfig_to_pll),
        .reconfig_from_pll (reconfig_from_pll)
    );

    sun3_mister_cpuclk cpuclk (
        .clk             (CLK_50M),
        .sel             (status[14:13]),
        .req             (machine_reset_req),
        .locked          (locked_main),
        .hold            (cpuclk_hold),
        .cur             (),
        .cfg_waitrequest (cfg_waitrequest),
        .cfg_write       (cfg_write),
        .cfg_address     (cfg_address),
        .cfg_writedata   (cfg_writedata)
    );

    wire reset_cpu;
    reset_sync rst_cpu (.clk(cpu_clk), .rst_async_in(machine_reset_raw), .rst_sync_out(reset_cpu));

    // The video too: a machine reset must not blank the screen.
    wire reset_pix;
    reset_sync rst_pix (.clk(clk_pix), .rst_async_in(~locked), .rst_sync_out(reset_pix));

    // The diag switch, from the OSD, taken while the machine is in reset as the
    // DECA took its slide switch: the PROM reads it at power-up.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg diag_s1 = 1'b0;
    reg diag_s2 = 1'b0, diag_switch = 1'b0;
    always @(posedge cpu_clk) begin
        diag_s1 <= status[15];
        diag_s2 <= diag_s1;
        if (reset_cpu) diag_switch <= diag_s2;
    end

    // The colour board, from the OSD, fitted or taken out while the machine is
    // in reset, as a board would be: the PROM and SunOS look for it once.  "On"
    // is status 0, so a new core starts with it.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg cg4_s1 = 1'b0;
    reg cg4_s2 = 1'b0, cg4_present = 1'b0;
    always @(posedge cpu_clk) begin
        cg4_s1 <= ~status[12];
        cg4_s2 <= cg4_s1;
        if (reset_cpu) cg4_present <= cg4_s2;
    end

    // ---- keyboard and mouse ---------------------------------------------------------
    // On clk_mem rather than the CPU's clock, so that the CPU's clock can change
    // (Phase 6) without the keyboard's 1200 baud changing with it.  The serial
    // lines are asynchronous by nature: the SCC synchronises its receivers, and
    // the model its one receiver.
    wire reset_kbm;
    reset_sync rst_kbm (.clk(clk_mem), .rst_async_in(machine_reset_raw), .rst_sync_out(reset_kbm));

    wire kbm_rxda, kbm_txda, kbm_rxdb, beeper;

    sun3_mister_kbd_mouse #(.CLK_HZ(100_000_000)) kbd_mouse (
        .clk          (clk_mem),
        .rst          (reset_kbm),
        .ps2_key      (ps2_key),
        .ps2_mouse    (ps2_mouse),
        .kbd_ser_tx   (kbm_rxda),
        .kbd_ser_rx   (kbm_txda),
        .mouse_ser_tx (kbm_rxdb),
        .beeper       (beeper)
    );

    // The keyboard's bell and key click, as sound: a softened 2083 Hz square
    // wave, made on the audio clock.  The OSD's "Keyboard bell" is its volume.
    wire signed [15:0] bell_sample;

    sun3_mister_bell bell (
        .clk    (CLK_AUDIO),
        .beeper (beeper),
        .volume (status[8:7]),
        .sample (bell_sample)
    );

    assign AUDIO_S   = 1'b1;
    assign AUDIO_MIX = 2'b00;
    assign AUDIO_L   = bell_sample;
    assign AUDIO_R   = bell_sample;

    // ---- the time of day -------------------------------------------------------------
    // MiSTer's local time when the core loads, as a Sun-3 keeps it in its
    // ICM7170 (rtl/sun3_mister_tod.sv), loaded into the chip once; the chip
    // keeps it through machine resets.  The OSD's "Clock" may set it 28 years
    // back.  It crosses into the CPU's clock as a toggle; the time itself is
    // held from then on.
    wire        tod_tgl;
    wire [55:0] tod_time;

    sun3_mister_tod tod (
        .clk    (clk_mem),
        .rtc    (rtc),
        .back28 (status[16]),
        .ld     (tod_tgl),
        .tod    (tod_time)
    );

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] tod_s = 3'b000;
    always @(posedge cpu_clk) tod_s <= {tod_s[1:0], tod_tgl};
    wire tod_ld = tod_s[2] ^ tod_s[1];

    // The chip's oscillator: 1 MHz from clk_mem (SUN3_TOD_TICK_HZ), not the
    // CPU's clock, which the OSD changes.  SunOS's 100 Hz is the chip's.
    wire tod_tick;
    sun3_mister_tick #(.DIV(100_000_000 / `SUN3_TOD_TICK_HZ)) tod_osc (
        .clk_src (clk_mem),
        .clk_dst (cpu_clk),
        .tick    (tod_tick)
    );

    // ---- the disk ----------------------------------------------------------------------
    wire        blk_start, blk_we, blk_done, blk_err, blk_ready, blk_buf_we, blk_busy;
    wire [31:0] blk_lba, blk_count;
    wire [7:0]  blk_buf_rdata, blk_buf_wdata;
    wire [8:0]  blk_buf_addr;

    sun3_mister_block disk (
        .clk           (cpu_clk),
        .blk_start     (blk_start),
        .blk_we        (blk_we),
        .blk_lba       (blk_lba),
        .blk_buf_rdata (blk_buf_rdata),
        .blk_done      (blk_done),
        .blk_err       (blk_err),
        .blk_ready     (blk_ready),
        .blk_count     (blk_count),
        .blk_buf_we    (blk_buf_we),
        .blk_buf_addr  (blk_buf_addr),
        .blk_buf_wdata (blk_buf_wdata),
        .busy          (blk_busy),
        .changed       (),

        .clk_hps       (clk_mem),
        .sd_lba        (sd_lba[0]),
        .sd_rd         (sd_rd[0]),
        .sd_wr         (sd_wr[0]),
        .sd_ack        (sd_ack[0]),
        .sd_buff_addr  (sd_buff_addr[8:0]),
        .sd_buff_dout  (sd_buff_dout),
        .sd_buff_din   (sd_buff_din[0]),
        .sd_buff_wr    (sd_buff_wr),
        .img_mounted   (img_mounted[0]),
        .img_size      (img_size)
    );

    // ---- the second disk ---------------------------------------------------------------
    // SCSI target 1, on VD 1.  SunOS numbers its disks by target * 8 + LUN, so
    // this is sd2 (sd1 is target 0's LUN 1).  The Rev 1.9 PROM's disk unit is
    // target * 4 + LUN, so it boots it as sd(0,4,0).
    wire        blk1_start, blk1_we, blk1_done, blk1_err, blk1_ready, blk1_buf_we, blk1_busy;
    wire [31:0] blk1_lba, blk1_count;
    wire [7:0]  blk1_buf_rdata, blk1_buf_wdata;
    wire [8:0]  blk1_buf_addr;

    sun3_mister_block disk1 (
        .clk           (cpu_clk),
        .blk_start     (blk1_start),
        .blk_we        (blk1_we),
        .blk_lba       (blk1_lba),
        .blk_buf_rdata (blk1_buf_rdata),
        .blk_done      (blk1_done),
        .blk_err       (blk1_err),
        .blk_ready     (blk1_ready),
        .blk_count     (blk1_count),
        .blk_buf_we    (blk1_buf_we),
        .blk_buf_addr  (blk1_buf_addr),
        .blk_buf_wdata (blk1_buf_wdata),
        .busy          (blk1_busy),
        .changed       (),

        .clk_hps       (clk_mem),
        .sd_lba        (sd_lba[1]),
        .sd_rd         (sd_rd[1]),
        .sd_wr         (sd_wr[1]),
        .sd_ack        (sd_ack[1]),
        .sd_buff_addr  (sd_buff_addr[8:0]),
        .sd_buff_dout  (sd_buff_dout),
        .sd_buff_din   (sd_buff_din[1]),
        .sd_buff_wr    (sd_buff_wr),
        .img_mounted   (img_mounted[1]),
        .img_size      (img_size)
    );

    // ---- the tape --------------------------------------------------------------------------
    // The same bridge on VD 2, read only: the image is a .qic from
    // tools/mktape, and the OSD's "Tape volume" picks the cartridge in it.
    wire        tblk_start, tblk_done, tblk_err, tblk_ready, tblk_buf_we, tblk_busy, tape_changed;
    wire [31:0] tblk_lba, tblk_count;
    wire [7:0]  tblk_buf_rdata, tblk_buf_wdata;
    wire [8:0]  tblk_buf_addr;

    sun3_mister_block tape (
        .clk           (cpu_clk),
        .blk_start     (tblk_start),
        .blk_we        (1'b0),
        .blk_lba       (tblk_lba),
        .blk_buf_rdata (tblk_buf_rdata),
        .blk_done      (tblk_done),
        .blk_err       (tblk_err),
        .blk_ready     (tblk_ready),
        .blk_count     (tblk_count),
        .blk_buf_we    (tblk_buf_we),
        .blk_buf_addr  (tblk_buf_addr),
        .blk_buf_wdata (tblk_buf_wdata),
        .busy          (tblk_busy),
        .changed       (tape_changed),

        .clk_hps       (clk_mem),
        .sd_lba        (sd_lba[2]),
        .sd_rd         (sd_rd[2]),
        .sd_wr         (sd_wr[2]),
        .sd_ack        (sd_ack[2]),
        .sd_buff_addr  (sd_buff_addr[8:0]),
        .sd_buff_dout  (sd_buff_dout),
        .sd_buff_din   (sd_buff_din[2]),
        .sd_buff_wr    (sd_buff_wr),
        .img_mounted   (img_mounted[2]),
        .img_size      (img_size)
    );

    // The volume, from the OSD's clock: taken once two samples agree, so a
    // change caught between its two bits is never seen as a third volume.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] tvol_s1 = 2'd0;
    reg [1:0] tvol_s2 = 2'd0, tape_volume = 2'd0;
    always @(posedge cpu_clk) begin
        tvol_s1 <= status[4:3];
        tvol_s2 <= tvol_s1;
        if (tvol_s2 == tvol_s1) tape_volume <= tvol_s2;
    end

    // ---- memory -------------------------------------------------------------------------
    wire         wb_cyc, wb_stb, wb_we, wb_ack;
    wire [29:0]  wb_adr;
    wire [31:0]  wb_dat_m2s, wb_dat_s2m;
    wire [3:0]   wb_sel;
    wire [127:0] wb_line;

    wire [27:0]  fb_c_addr;
    wire         fb_c_req, fb_c_done;
    wire [127:0] fb_c_rdata;

    wire [25:0]  cs_word;
    wire         cs_req, cs_urgent, cs_done;
    wire [127:0] cs_rdata;

    // Only the screen being shown is fetched: the cg4's when the board is in.
    // The board changes only in a machine reset, so two flops are enough.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg cg4m_s1 = 1'b0;
    reg cg4_mem = 1'b0;
    always @(posedge clk_mem) begin
        cg4m_s1 <= cg4_present;
        cg4_mem <= cg4m_s1;
    end

    sun3_mister_sdram sdram (
        .clk        (clk_mem),
        .init       (reset_mem),

        .wb_cyc_i   (wb_cyc),
        .wb_stb_i   (wb_stb),
        .wb_adr_i   (wb_adr),
        .wb_dat_i   (wb_dat_m2s),
        .wb_sel_i   (wb_sel),
        .wb_we_i    (wb_we),
        .wb_dat_o   (wb_dat_s2m),
        .wb_ack_o   (wb_ack),
        .wb_line_o  (wb_line),

        .fb_c_addr  (fb_c_addr),
        .fb_c_req   (fb_c_req & ~cg4_mem),
        .fb_c_done  (fb_c_done),
        .fb_c_rdata (fb_c_rdata),

        .cs_word    (cs_word),
        .cs_req     (cs_req),
        .cs_urgent  (cs_urgent),
        .cs_done    (cs_done),
        .cs_rdata   (cs_rdata),

        .SDRAM_DQ   (SDRAM_DQ),
        .SDRAM_A    (SDRAM_A),
        .SDRAM_DQML (SDRAM_DQML),
        .SDRAM_DQMH (SDRAM_DQMH),
        .SDRAM_BA   (SDRAM_BA),
        .SDRAM_nCS  (SDRAM_nCS),
        .SDRAM_nWE  (SDRAM_nWE),
        .SDRAM_nRAS (SDRAM_nRAS),
        .SDRAM_nCAS (SDRAM_nCAS),
        .SDRAM_CKE  (SDRAM_CKE),
        .SDRAM_CLK  (SDRAM_CLK)
    );

    // ---- the network ----------------------------------------------------------------------
    // The PHY behind the LANCE: frames to and from Main_MiSTer's Sun support
    // (support/sun, which serves the Sun-2 and SPARCstation cores too) through
    // a mailbox in DDR3 (rtl/sun3_mister_enet.sv, magic S3ETH001).  The OSD's
    // Network picks the host side, in the SPARC core's order -- eth0 (the
    // default, 0), Off (1), eth1, macvlan, tap0 -- and Main reads it from the
    // same status bits.  The mailbox is published each time the machine leaves
    // reset, which is after Main has started and sent boot0.rom.
    wire       reset_mii;
    reset_sync rst_mii (.clk(clk_mii), .rst_async_in(~locked), .rst_sync_out(reset_mii));

    wire [3:0] mii_txd, mii_rxd;
    wire       mii_tx_en, mii_rx_dv, mii_crs;

    // The mailbox side, and with it DDRAM_CLK, is on clk_mem: a global clock,
    // which the HPS's port at the top of the die needs.  Only the MII side of
    // the module runs on clk_mii.
    assign DDRAM_CLK = clk_mem;

    sun3_mister_enet #(.CLK_HZ(100_000_000)) enet (
        .clk              (clk_mem),
        .rst              (reset_mem),
        .mii_clk          (clk_mii),
        .mii_rst          (reset_mii),
        .restart          (machine_reset_raw),
        .enable           (status[11:9] != 3'd1),
        .loopback_n       (1'b1),         // a 3/60's cable is always in
        .mac              (idp_mac),

        .mii_txd          (mii_txd),
        .mii_tx_en        (mii_tx_en),
        .mii_rxd          (mii_rxd),
        .mii_rx_dv        (mii_rx_dv),
        .mii_crs          (mii_crs),

        .DDRAM_BUSY       (DDRAM_BUSY),
        .DDRAM_BURSTCNT   (DDRAM_BURSTCNT),
        .DDRAM_ADDR       (DDRAM_ADDR),
        .DDRAM_DOUT       (DDRAM_DOUT),
        .DDRAM_DOUT_READY (DDRAM_DOUT_READY),
        .DDRAM_RD         (DDRAM_RD),
        .DDRAM_DIN        (DDRAM_DIN),
        .DDRAM_BE         (DDRAM_BE),
        .DDRAM_WE         (DDRAM_WE)
    );

    // ---- the machine ----------------------------------------------------------------------
    wire       fb_video_en, v_int;
    wire [7:0] diag_leds;

    wire        cg4_retrace, cg4_video_on;
    wire [7:0]  cg4_read_mask, cg4_command, cg4_cm_raddr;
    wire [23:0] cg4_ovl1, cg4_ovl2, cg4_ovl3, cg4_cm_rdata;

    sun3_top machine (
        .CLK           (cpu_clk),
        .clk4m9152     (clk_ser),
        .clk32k768     (1'b0),          // unused inside (the TOD runs on tod_tick)
        .sys_reset     (reset_cpu),
        .trace_freeze  (1'b0),

        .tx            (UART_TXD),
        .rx            (UART_RXD),

        .kbd_tx        (kbm_txda),
        .kbd_rx        (kbm_rxda),
        .mou_rx        (kbm_rxdb),

        // the LANCE's MII, to the mailbox above: both clocks are the PHY's,
        // and there are no collisions on that wire
        .phy_txd       (mii_txd),
        .phy_tx_en     (mii_tx_en),
        .phy_tx_er     (),
        .phy_tx_clk    (clk_mii),
        .phy_col       (1'b0),
        .phy_rxd       (mii_rxd),
        .phy_rx_dv     (mii_rx_dv),
        .phy_rx_er     (1'b0),
        .phy_rx_clk    (clk_mii),
        .phy_crs       (mii_crs),
        .phy_int_n     (1'b1),
        .phy_reset_n   (),

        .tod_ld        (tod_ld),
        .tod_time      (tod_time),
        .tod_tick      (tod_tick),

        .cg4_present   (cg4_present),
        .cg4_retrace   (cg4_retrace),
        .cg4_video_on  (cg4_video_on),
        .cg4_read_mask (cg4_read_mask),
        .cg4_command   (cg4_command),
        .cg4_ovl1      (cg4_ovl1),
        .cg4_ovl2      (cg4_ovl2),
        .cg4_ovl3      (cg4_ovl3),
        .cg4_cm_clk    (clk_pix),
        .cg4_cm_raddr  (cg4_cm_raddr),
        .cg4_cm_rdata  (cg4_cm_rdata),

        .blk_start     (blk_start),
        .blk_we        (blk_we),
        .blk_lba       (blk_lba),
        .blk_buf_rdata (blk_buf_rdata),
        .blk_done      (blk_done),
        .blk_err       (blk_err),
        .blk_ready     (blk_ready),
        .blk_count     (blk_count),
        .blk_buf_we    (blk_buf_we),
        .blk_buf_addr  (blk_buf_addr),
        .blk_buf_wdata (blk_buf_wdata),

        .tblk_start     (tblk_start),
        .tblk_lba       (tblk_lba),
        .tblk_buf_rdata (tblk_buf_rdata),
        .tblk_done      (tblk_done),
        .tblk_err       (tblk_err),
        .tblk_ready     (tblk_ready),
        .tblk_count     (tblk_count),
        .tblk_buf_we    (tblk_buf_we),
        .tblk_buf_addr  (tblk_buf_addr),
        .tblk_buf_wdata (tblk_buf_wdata),
        .tape_changed   (tape_changed),
        .tape_volume    (tape_volume),

        .blk1_start     (blk1_start),
        .blk1_we        (blk1_we),
        .blk1_lba       (blk1_lba),
        .blk1_buf_rdata (blk1_buf_rdata),
        .blk1_done      (blk1_done),
        .blk1_err       (blk1_err),
        .blk1_ready     (blk1_ready),
        .blk1_count     (blk1_count),
        .blk1_buf_we    (blk1_buf_we),
        .blk1_buf_addr  (blk1_buf_addr),
        .blk1_buf_wdata (blk1_buf_wdata),

        .V_INT         (v_int),

        .leds          (diag_leds),
        .en_boot       (),
        .diag_switch   (diag_switch),
        .todebug       (),
        .fb_video_en   (fb_video_en),

        .rom_wr_clk    (clk_mem),
        .rom_wr_en     (rom_wr_en),
        .rom_wr_addr   (rom_wr_addr),
        .rom_wr_data   (rom_wr_data),

        .idp_wr_clk    (clk_mem),
        .idp_wr_en     (idp_wr_en),
        .idp_wr_addr   (idp_wr_addr),
        .idp_wr_data   (idp_wr_data),

        .ee_save_clk    (clk_mem),
        .ee_save_addr   (ee_addr),
        .ee_save_we     (ee_we),
        .ee_save_wdata  (ee_wdata),
        .ee_save_rdata  (ee_rdata),
        .ee_save_wr_tgl (ee_wr_tgl),

        .wb_cyc_o      (wb_cyc),
        .wb_stb_o      (wb_stb),
        .wb_adr_o      (wb_adr),
        .wb_dat_o      (wb_dat_m2s),
        .wb_sel_o      (wb_sel),
        .wb_we_o       (wb_we),
        .wb_dat_i      (wb_dat_s2m),
        .wb_ack_i      (wb_ack),
        .wb_clk_i      (clk_mem),
        .wb_rst_i      (reset_mem),
        .wb_line_i     (wb_line)
    );

    // ---- video --------------------------------------------------------------------------
    // 1160x904 active in a 1472x937 total at 83.333 MHz: 60.4 Hz.  fb_scanout
    // centres the 1152x900 screen in it, a 4-pixel and 2-line border.
    wire [11:0] cx;
    wire [10:0] cy;
    wire        de, hs, vs;
    wire [23:0] rgb, bw2_rgb, cg4_rgb;

    video_timing #(
        .H_ACTIVE(1160), .H_FRONT(24), .H_SYNC(128), .H_TOTAL(1472),
        .V_ACTIVE(904),  .V_FRONT(3),  .V_SYNC(4),   .V_TOTAL(937),
        .H_POSITIVE(1'b0), .V_POSITIVE(1'b0),
        .CXW(12), .CYW(11)
    ) timing (
        .clk(clk_pix), .rst(reset_pix),
        .cx(cx), .cy(cy), .de(de), .hsync(hs), .vsync(vs)
    );

    // The video interrupt (level 4) is the vertical blanking, as on the DECA;
    // sun3_fpga synchronises it into the CPU's clock.
    reg vblank = 1'b0;
    always @(posedge clk_pix) vblank <= (cy >= 11'd904);
    assign v_int = vblank;

    fb_scanout #(
        .FB_APP_BASE (28'h0000000),         // sun3_mister_sdram adds the frame buffer's offset
        .FB_W        (1152),
        .FB_H        (900),
        .SCREEN_W    (1160),
        .SCREEN_H    (904)
    ) scanout (
        .ui_clk    (clk_mem),
        .ui_rst    (reset_mem),
        .c_addr    (fb_c_addr),
        .c_req     (fb_c_req),
        .c_done    (fb_c_done),
        .c_rdata   (fb_c_rdata),
        .clk_pixel (clk_pix),
        .pix_rst   (reset_pix),
        .cx        (cx),
        .cy        (cy),
        .video_en  (fb_video_en),
        .rgb       (bw2_rgb)
    );

    // The cg4's picture (rtl/sun3/sun3_cg4_scanout.sv): its planes through the
    // Bt458s, whose colour map it reads on this clock.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg cg4p_s1 = 1'b0;
    reg cg4_pix = 1'b0;
    always @(posedge clk_pix) begin
        cg4p_s1 <= cg4_present;
        cg4_pix <= cg4p_s1;
    end

    sun3_cg4_scanout cg4_scanout (
        .mclk      (clk_mem),
        .mrst      (reset_mem),
        .enable    (cg4_mem),
        .c_word    (cs_word),
        .c_req     (cs_req),
        .c_urgent  (cs_urgent),
        .c_done    (cs_done),
        .c_rdata   (cs_rdata),
        .clk_pixel (clk_pix),
        .pix_rst   (reset_pix),
        .cx        (cx),
        .cy        (cy),
        .video_on  (cg4_video_on),
        .read_mask (cg4_read_mask),
        .command   (cg4_command),
        .ovl1      (cg4_ovl1),
        .ovl2      (cg4_ovl2),
        .ovl3      (cg4_ovl3),
        .cm_raddr  (cg4_cm_raddr),
        .cm_rdata  (cg4_cm_rdata),
        .rgb       (cg4_rgb),
        .retrace   (cg4_retrace)
    );

    // The screen: the cg4's when the board is in (a 3/60C's monitor is on the
    // P4 board), the bw2's otherwise.  The cg4's pixels are four clocks behind
    // cx/cy, the bw2's none, so the syncs and DE wait for whichever is shown.
    reg [3:0] de_d = 4'h0, hs_d = 4'hF, vs_d = 4'hF;
    always @(posedge clk_pix) begin
        de_d <= {de_d[2:0], de};
        hs_d <= {hs_d[2:0], hs};
        vs_d <= {vs_d[2:0], vs};
    end
    wire de_o = cg4_pix ? de_d[3] : de;
    wire hs_o = cg4_pix ? hs_d[3] : hs;
    wire vs_o = cg4_pix ? vs_d[3] : vs;
    assign rgb = cg4_pix ? cg4_rgb : bw2_rgb;

    assign CLK_VIDEO = clk_pix;
    assign CE_PIXEL  = 1'b1;
    assign VGA_R     = rgb[23:16];
    assign VGA_G     = rgb[15:8];
    assign VGA_B     = rgb[7:0];
    assign VGA_HS    = hs_o;
    assign VGA_VS    = vs_o;

    // A one-pixel font scaled by 1080/904 is a font whose strokes are one or two
    // pixels wide depending on where they land, and blurred between.  V-Integer
    // draws the 904 lines 1:1 at 1080p, with a border; Original keeps the
    // pixels square, Full Screen fills the display, 4:3 is 4:3.
    video_freak video_freak (
        .CLK_VIDEO   (clk_pix),
        .CE_PIXEL    (1'b1),
        .VGA_VS      (vs_o),
        .HDMI_WIDTH  (HDMI_WIDTH),
        .HDMI_HEIGHT (HDMI_HEIGHT),
        .VGA_DE      (VGA_DE),
        .VIDEO_ARX   (VIDEO_ARX),
        .VIDEO_ARY   (VIDEO_ARY),
        .VGA_DE_IN   (de_o),
        .ARX         ((ar == 2'd0) ? 12'd1160 : (ar == 2'd2) ? 12'd4 : 12'd0),
        .ARY         ((ar == 2'd0) ? 12'd904  : (ar == 2'd2) ? 12'd3 : 12'd0),
        .CROP_SIZE   (12'd0),
        .CROP_OFF    (5'd0),
        .SCALE       (scale)
    );

    // ---- LEDs ---------------------------------------------------------------------------
    // User: the machine is in reset (no PROM yet, or the OSD's reset).
    // Disk: a disk or the tape is moving a block, ORed with the HPS's own activity.
    assign LED_USER = reset_cpu;
    assign LED_DISK = {1'b0, blk_busy | blk1_busy | tblk_busy};

endmodule
