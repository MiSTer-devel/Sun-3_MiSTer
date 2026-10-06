// SPDX-License-Identifier: MIT
//
// Wish7990 - an Ethernet MAC software-compatible with the AMD Am79C90
// (C-LANCE).
//
// The host side is the part's own pins: the slave port that RAP and RDP hide
// behind, RESET, INTR, and the three CSR3 bus mode outputs.  Unlike Wish82586,
// the register file is *inside* here, because on this part it is on the die -
// doc/interface.md argues that at length.  What a machine supplies is where
// those two ports sit in its address map, which is wb_le's job.
//
// le_init reads the initialisation block, le_tx walks the transmit ring and
// le_rx the receive ring with le_filt in front of it.  They share one memory
// port through wb_arb, in the order init > receive > transmit: receive comes
// before transmit because it cannot ask the wire to wait.

module wish7990 #(
    parameter int PHY_DATA_W = 4,     // 4 = MII, 8 = GMII
    parameter int WB_ADDR_W  = 30,
    parameter int WB_DATA_W  = 32,
    // 1.6 ms in system clocks, for the descriptor ring poll (p. 30).  Both
    // engines get the same value: the receive side polls for a free buffer on
    // the same interval the transmit side looks for work.
    parameter int POLL_TICKS = 80000
) (
    input  logic                   clk,
    input  logic                   rst,

    // ---- the part's host pins ---------------------------------------------
    input  logic                   reset_i,
    input  logic                   cs_i,
    input  logic                   adr_i,
    input  logic                   we_i,
    input  logic [15:0]            wdata_i,
    output logic [15:0]            rdata_o,
    output logic                   ready_o,
    output logic                   intr_o,

    // CSR3, for a board that recreates a real DAL bus.  BSWP is consumed
    // inside by the data engines; ACON and BCON have no Wishbone meaning and
    // are carried out inert.
    output logic                   bswp_o,
    output logic                   acon_o,
    output logic                   bcon_o,

    // ---- Wishbone B4 classic master, shared memory -------------------------
    output logic                   wbm_cyc_o,
    output logic                   wbm_stb_o,
    output logic                   wbm_we_o,
    output logic [WB_DATA_W/8-1:0] wbm_sel_o,
    output logic [WB_ADDR_W-1:0]   wbm_adr_o,
    output logic [WB_DATA_W-1:0]   wbm_dat_o,
    input  logic [WB_DATA_W-1:0]   wbm_dat_i,
    input  logic                   wbm_ack_i,
    input  logic                   wbm_err_i,

    // ---- MII / GMII --------------------------------------------------------
    input  logic                   mii_tx_clk,
    output logic [PHY_DATA_W-1:0]  mii_txd,
    output logic                   mii_tx_en,
    output logic                   mii_tx_er,
    input  logic                   mii_rx_clk,
    input  logic [PHY_DATA_W-1:0]  mii_rxd,
    input  logic                   mii_rx_dv,
    input  logic                   mii_rx_er,
    input  logic                   mii_crs,
    input  logic                   mii_col
);

  // ---- the four registers and the address port ------------------------------
  logic [23:0] iadr;
  logic        init_pulse, strt, stop, tdmd, inea;
  // Declared here rather than beside the block that drives each one: every
  // net below is read by an instance that comes before that block, and xvlog
  // will not take a net used before its declaration.
  logic        idon, merr_init;
  logic        rxon, txon;
  logic        rint, miss, merr_rx, rx_fault;
  logic        rx_fifo_rd;
  logic        tint, babl, merr_tx, tx_fault;
  logic        tx_done_s1, tx_done_s2;

  le_regs u_regs (
      .clk        (clk),
      .rst        (rst),
      .reset_i    (reset_i),
      .cs_i       (cs_i),
      .adr_i      (adr_i),
      .we_i       (we_i),
      .wdata_i    (wdata_i),
      .rdata_o    (rdata_o),
      .ready_o    (ready_o),
      .intr_o     (intr_o),
      .iadr_o     (iadr),
      .bswp_o     (bswp_o),
      .acon_o     (acon_o),
      .bcon_o     (bcon_o),
      .init_o     (init_pulse),
      .strt_o     (strt),
      .stop_o     (stop),
      .tdmd_o     (tdmd),
      .inea_o     (inea),
      .idon_set_i (idon),
      // CERR is never set: it is the 10BASE5 heartbeat and MII has none; see
      // doc/interface.md.
      .rint_set_i (rint),
      .tint_set_i (tint),
      .babl_set_i (babl),
      .cerr_set_i (1'b0),
      .miss_set_i (miss),
      .merr_set_i (merr_init | merr_tx | merr_rx),
      .rxon_i     (rxon),
      .txon_i     (txon)
  );

  // ---- the initialisation block reader ---------------------------------------
  logic [15:0] mode;
  logic [47:0] padr;
  logic [63:0] ladrf;
  logic [23:0] rdra, tdra;
  logic [2:0]  rlen, tlen;
  logic        ib_ready;

  logic        p0_req, p0_we, p0_ack, p0_err;
  logic [1:0]  p0_size;
  logic [3:0]  p0_sel;
  logic [23:0] p0_addr;
  logic [31:0] p0_wdata;
  logic [31:0] bus_rdata;

  le_init u_init (
      .clk         (clk),
      .rst         (rst),
      .stop_i      (stop),
      .strt_i      (strt),
      .init_i      (init_pulse),
      .iadr_i      (iadr),
      .idon_o      (idon),
      .merr_o      (merr_init),
      .rxon_o      (rxon),
      .txon_o      (txon),
      .mode_o      (mode),
      .padr_o      (padr),
      .ladrf_o     (ladrf),
      .rdra_o      (rdra),
      .rlen_o      (rlen),
      .tdra_o      (tdra),
      .tlen_o      (tlen),
      .ready_o     (ib_ready),
      .rx_fault_i  (rx_fault),
      .tx_fault_i  (tx_fault),
      .bus_req_o   (p0_req),
      .bus_we_o    (p0_we),
      .bus_size_o  (p0_size),
      .bus_sel_o   (p0_sel),
      .bus_addr_o  (p0_addr),
      .bus_wdata_o (p0_wdata),
      .bus_ack_i   (p0_ack),
      .bus_rdata_i (bus_rdata),
      .bus_err_i   (p0_err)
  );

  // ---- the receive front end, its clock crossing and its ring engine ---------
  logic        rxfe_wr, rxfe_full, rxfe_active;
  logic [11:0] rxfe_word;
  logic [15:0] rxfe_bytes;

  // Internal loopback runs entirely in this clock domain: le_tx pushes the
  // bytes it stages straight into a synchronous FIFO and le_rx listens to that
  // instead of the wire, so a looped frame never crosses a clock boundary.
  logic        lb_wr, lb_full, lb_empty, lb_rd, lb_active;
  logic [11:0] lb_word, lb_data;
  logic [6:0]  lb_level;
  logic        rxf_empty, rxf_rd;
  logic [11:0] rxf_data;

  logic        p1_req, p1_we, p1_ack, p1_err;
  logic [1:0]  p1_size;
  logic [3:0]  p1_sel;
  logic [23:0] p1_addr;
  logic [31:0] p1_wdata;

  // KEEP_FCS: the C-LANCE writes the four FCS bytes into the receive buffer and
  // counts them in MCNT.  NetBSD's am7990.c subtracts them itself with
  // `lance_read(sc, ..., (int)rmd.rmd3 - 4)`, so a chip that stripped them
  // would hand every driver a frame four bytes short.
  mii_rx #(.DATA_W(PHY_DATA_W), .KEEP_FCS(1'b1)) u_mii_rx (
      .rx_clk       (mii_rx_clk),
      .rst          (rst),
      .rxd          (mii_rxd),
      .rx_dv        (mii_rx_dv),
      .rx_er        (mii_rx_er),
      .fifo_wr_o    (rxfe_wr),
      .fifo_data_o  (rxfe_word),
      .fifo_full_i  (rxfe_full),
      // Only for the unit tests and for reading waveforms.
      .active_o     (rxfe_active),
      .byte_count_o (rxfe_bytes)
  );

  // 256 entries.  That is not about the sustained rate, which the word-wide
  // path settles: it is to ride out the pause while the receive engine closes
  // one buffer and fetches the next descriptor.
  async_fifo #(.WIDTH(12), .DEPTH(256)) u_rx_fifo (
      .wclk    (mii_rx_clk),
      .wrst    (rst),
      .wr_en   (rxfe_wr),
      .wr_data (rxfe_word),
      .wfull   (rxfe_full),
      .rclk    (clk),
      .rrst    (rst),
      .rd_en   (rxf_rd),
      .rd_data (rxf_data),
      .rempty  (rxf_empty)
  );

  // p. 24: in internal loopback "the C-LANCE will not receive any packets
  // externally", so the wire is not merely ignored - it is not listened to.
  wire        rx_fifo_empty = lb_active ? lb_empty : rxf_empty;
  wire [11:0] rx_fifo_data  = lb_active ? lb_data  : rxf_data;
  assign      rxf_rd        = !lb_active && rx_fifo_rd;
  assign      lb_rd         =  lb_active && rx_fifo_rd;

  // Deep enough for the longest frame p. 24 allows back: "The received packet
  // can be up to 36 bytes (32 + 4 bytes CRC) when DTCR = 0", plus the word
  // that closes it.  The limit itself is enforced in le_tx rather than left to
  // this FIFO filling, because le_rx drains it as le_tx writes and whether it
  // overflowed would depend on how the two happened to interleave.
  sync_fifo #(.WIDTH(12), .DEPTH(64)) u_lb_fifo (
      .clk     (clk),
      .rst     (rst),
      .flush   (1'b0),
      .wr_en   (lb_wr),
      .wr_data (lb_word),
      .full    (lb_full),
      .rd_en   (lb_rd),
      .rd_data (lb_data),
      .empty   (lb_empty),
      .level   (lb_level)
  );

  le_rx #(.POLL_TICKS(POLL_TICKS)) u_rx (
      .clk          (clk),
      .rst          (rst),
      .stop_i       (stop),
      .rxon_i       (rxon),
      .rdra_i       (rdra),
      .rlen_i       (rlen),
      .bswp_i       (bswp_o),
      .padr_i       (padr),
      .ladrf_i      (ladrf),
      .prom_i       (mode[wish7990_pkg::MODE_PROM]),
      .rint_o       (rint),
      .miss_o       (miss),
      .merr_o       (merr_rx),
      .fault_o      (rx_fault),
      .fifo_empty_i (rx_fifo_empty),
      .fifo_data_i  (rx_fifo_data),
      .fifo_rd_o    (rx_fifo_rd),
      .bus_req_o    (p1_req),
      .bus_we_o     (p1_we),
      .bus_size_o   (p1_size),
      .bus_sel_o    (p1_sel),
      .bus_addr_o   (p1_addr),
      .bus_wdata_o  (p1_wdata),
      .bus_ack_i    (p1_ack),
      .bus_rdata_i  (bus_rdata),
      .bus_err_i    (p1_err)
  );

  // ---- the transmit ring engine ----------------------------------------------
  logic        tx_late;
  logic [3:0]  tx_retry_limit;
  logic        tx_ram_we;
  logic [10:0] tx_ram_waddr, tx_ram_raddr;
  logic [7:0]  tx_ram_wdata, tx_ram_rdata;
  logic        tx_go, tx_no_crc, tx_done, tx_ok, tx_xcoll, tx_defer, tx_no_crs;
  logic [15:0] tx_len;
  logic [3:0]  tx_ncoll;

  logic        p2_req, p2_we, p2_ack, p2_err;
  logic [1:0]  p2_size;
  logic [3:0]  p2_sel;
  logic [23:0] p2_addr;
  logic [31:0] p2_wdata;

  le_tx #(.POLL_TICKS(POLL_TICKS)) u_tx (
      .clk         (clk),
      .rst         (rst),
      .stop_i      (stop),
      .txon_i      (txon),
      .tdmd_i      (tdmd),
      .tdra_i      (tdra),
      .tlen_i      (tlen),
      .dtcr_i      (mode[wish7990_pkg::MODE_DTCR]),
      .drty_i      (mode[wish7990_pkg::MODE_DRTY]),
      .loop_i      (mode[wish7990_pkg::MODE_LOOP]),
      .intl_i      (mode[wish7990_pkg::MODE_INTL]),
      .coll_i      (mode[wish7990_pkg::MODE_COLL]),
      .bswp_i      (bswp_o),
      .tint_o      (tint),
      .babl_o      (babl),
      .merr_o      (merr_tx),
      .fault_o     (tx_fault),
      .lb_wr_o     (lb_wr),
      .lb_data_o   (lb_word),
      .lb_full_i   (lb_full),
      .lb_active_o (lb_active),
      .ram_we_o    (tx_ram_we),
      .ram_addr_o  (tx_ram_waddr),
      .ram_data_o  (tx_ram_wdata),
      .tx_go_o     (tx_go),
      .tx_len_o    (tx_len),
      .tx_no_crc_o (tx_no_crc),
      .tx_retry_limit_o (tx_retry_limit),
      .tx_done_i   (tx_done_s2),
      .tx_ok_i     (tx_ok),
      .tx_ncoll_i  (tx_ncoll),
      .tx_xcoll_i  (tx_xcoll),
      .tx_defer_i  (tx_defer),
      .tx_no_crs_i (tx_no_crs),
      .tx_late_i   (tx_late),
      .bus_req_o   (p2_req),
      .bus_we_o    (p2_we),
      .bus_size_o  (p2_size),
      .bus_sel_o   (p2_sel),
      .bus_addr_o  (p2_addr),
      .bus_wdata_o (p2_wdata),
      .bus_ack_i   (p2_ack),
      .bus_rdata_i (bus_rdata),
      .bus_err_i   (p2_err)
  );

  // done_o is produced in the PHY's transmit clock domain; two flops bring it
  // across.  go_i goes the other way and mii_tx synchronises it itself, which
  // is what makes the handshake four phase rather than a pulse either way.
  always_ff @(posedge clk) begin
    if (rst) begin
      tx_done_s1 <= 1'b0;
      tx_done_s2 <= 1'b0;
    end else begin
      tx_done_s1 <= tx_done;
      tx_done_s2 <= tx_done_s1;
    end
  end

  dp_ram #(.WIDTH(8), .DEPTH(2048)) u_tx_ram (
      .wclk    (clk),
      .wr_en   (tx_ram_we),
      .wr_addr (tx_ram_waddr),
      .wr_data (tx_ram_wdata),
      .rclk    (mii_tx_clk),
      .rd_addr (tx_ram_raddr),
      .rd_data (tx_ram_rdata)
  );

  mii_tx #(.DATA_W(PHY_DATA_W)) u_mii_tx (
      .tx_clk        (mii_tx_clk),
      .rst           (rst),
      .go_i          (tx_go),
      .len_i         (tx_len),
      .done_o        (tx_done),
      .ok_o          (tx_ok),
      .ncoll_o       (tx_ncoll),
      .xcoll_o       (tx_xcoll),
      .defer_o       (tx_defer),
      .no_crs_o      (tx_no_crs),
      .late_o        (tx_late),
      // Half duplex parameters are the 10/100 defaults; the C-LANCE has no
      // CONFIGURE command to change them, unlike the 82586.  The retry limit
      // is not one of them: MODE.DRTY moves it.
      .retry_limit_i (tx_retry_limit),
      .ifs_i         (8'd96),
      .slot_time_i   (11'd512),
      // The LANCE does not pad.  ETHER_MIN_TU 60 in the Sun header is a
      // minimum the *driver* enforces; a driver that under-pads emits a runt,
      // exactly as it would on hardware.  See doc/interface.md.
      .min_len_i     (8'd0),
      .no_crc_i      (tx_no_crc),
      .ram_addr_o    (tx_ram_raddr),
      .ram_data_i    (tx_ram_rdata),
      .txd           (mii_txd),
      .tx_en         (mii_tx_en),
      .tx_er         (mii_tx_er),
      .crs           (mii_crs),
      .col           (mii_col)
  );

  // ---- the memory port -------------------------------------------------------
  logic        m_req, m_we, m_ack, m_err;
  logic [1:0]  m_size;
  logic [3:0]  m_sel;
  logic [23:0] m_addr;
  logic [31:0] m_wdata, m_rdata;

  wb_arb u_arb (
      .clk        (clk),
      .rst        (rst),
      .p0_req_i   (p0_req),
      .p0_we_i    (p0_we),
      .p0_size_i  (p0_size),
      .p0_sel_i   (p0_sel),
      .p0_addr_i  (p0_addr),
      .p0_wdata_i (p0_wdata),
      .p0_ack_o   (p0_ack),
      .p0_err_o   (p0_err),
      // The receive engine takes port 1, ahead of transmit, because it cannot
      // ask the wire to wait.
      .p1_req_i   (p1_req),
      .p1_we_i    (p1_we),
      .p1_size_i  (p1_size),
      .p1_sel_i   (p1_sel),
      .p1_addr_i  (p1_addr),
      .p1_wdata_i (p1_wdata),
      .p1_ack_o   (p1_ack),
      .p1_err_o   (p1_err),
      .p2_req_i   (p2_req),
      .p2_we_i    (p2_we),
      .p2_size_i  (p2_size),
      .p2_sel_i   (p2_sel),
      .p2_addr_i  (p2_addr),
      .p2_wdata_i (p2_wdata),
      .p2_ack_o   (p2_ack),
      .p2_err_o   (p2_err),
      .rdata_o    (bus_rdata),
      .req_o      (m_req),
      .we_o       (m_we),
      .size_o     (m_size),
      .sel_o      (m_sel),
      .addr_o     (m_addr),
      .wdata_o    (m_wdata),
      .ack_i      (m_ack),
      .err_i      (m_err),
      .rdata_i    (m_rdata)
  );

  wb_master #(
      .WB_ADDR_W (WB_ADDR_W),
      .WB_DATA_W (WB_DATA_W)
  ) u_master (
      .clk       (clk),
      .rst       (rst),
      .req_i     (m_req),
      .we_i      (m_we),
      .size_i    (m_size),
      .sel_i     (m_sel),
      .addr_i    (m_addr),
      .wdata_i   (m_wdata),
      .ack_o     (m_ack),
      .rdata_o   (m_rdata),
      .err_o     (m_err),
      .wbm_cyc_o (wbm_cyc_o),
      .wbm_stb_o (wbm_stb_o),
      .wbm_we_o  (wbm_we_o),
      .wbm_sel_o (wbm_sel_o),
      .wbm_adr_o (wbm_adr_o),
      .wbm_dat_o (wbm_dat_o),
      .wbm_dat_i (wbm_dat_i),
      .wbm_ack_i (wbm_ack_i),
      .wbm_err_i (wbm_err_i)
  );


  // Signals the register file produces and the blocks still to come consume.
  // Shrink this as each of them lands; it should be empty by the end.
  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, inea, ib_ready, rxfe_active, rxfe_bytes,
                   lb_level, 1'b0};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
