//
// sun3_mister_eeprom.sv
//
// The EEPROM (2 KiB, rtl/sun3/eeprom.v) kept in an image file on the SD card,
// as SunSparcStation keeps its NVRAM (its rtl/mister/nvram_sd.vhd).
//
// One hps_io block device: the OSD's "EEPROM" slot, a 2048-byte file.  Main
// remembers the file (an SC slot) and mounts it again at every core load
// while it reads the configuration string, before it sends boot0.rom, and it
// serves our block requests once that download is over.  So:
//  - on a mount of a 2048-byte image its four blocks are read twice: first
//    only to see whether the file is all zero, then into the EEPROM.  An
//    all-zero file is a new one: the EEPROM keeps what it holds (after
//    power-up, the built-in layout), and that is written to the file at
//    once.  A mount of any other size (an unmount reports 0) disconnects the
//    image: nothing is read from it or written to it;
//  - `ready' holds the machine in reset until the load is over, so the PROM
//    never reads the EEPROM before it.  If no image has been mounted by the
//    time boot0.rom is in, there is none to wait for.  A load that has not
//    finished WAIT_MS after that is given up on;
//  - each write the machine makes marks the EEPROM dirty; QUIET_MS after the
//    last one, all four blocks are written back.  A read-only image is
//    never written.
// The file is a plain byte image: file byte n is EEPROM byte n.
//
// hps_io (sys/hps_io.sv), for one 512-byte block: the core holds sd_rd or
// sd_wr with sd_lba until sd_ack rises, and drops it then; a read delivers
// each byte as a one-clock sd_buff_wr at sd_buff_addr; a write takes
// sd_buff_din for sd_buff_addr and then steps the address, its strobes
// several clocks apart; the transfer is over when sd_ack falls.  So the
// EEPROM's second port, in this clock, is the block buffer itself: its
// registered read is in time.  The machine's writes cross as a toggle.
//
// A mount while the machine runs loads the image there and then; the PROM
// reads its settings at a reset.
//
`timescale 1ns / 1ps

module sun3_mister_eeprom #(
    parameter int CLK_HZ   = 100_000_000,
    parameter int QUIET_MS = 500,       // the write-back, after the last write
    parameter int WAIT_MS  = 3000       // the longest wait for a load, once boot0.rom is in
) (
    input  wire        clk,             // hps_io's
    input  wire        rst,             // everything starts again (the PLL locking)

    // ---- hps_io, this image's slot ----------------------------------------------
    input  wire        img_mounted,
    input  wire        img_readonly,
    input  wire [63:0] img_size,
    output wire [31:0] sd_lba,
    output reg         sd_rd = 1'b0,
    output reg         sd_wr = 1'b0,
    input  wire        sd_ack,
    input  wire [8:0]  sd_buff_addr,
    input  wire [7:0]  sd_buff_dout,
    output wire [7:0]  sd_buff_din,
    input  wire        sd_buff_wr,

    // ---- the EEPROM's second port, in this clock ----------------------------------
    output wire [10:0] ee_addr,
    output wire        ee_we,
    output wire [7:0]  ee_wdata,
    input  wire [7:0]  ee_rdata,
    input  wire        ee_wr_tgl,       // toggles at each write the machine makes, in its clock

    input  wire        rom_loaded,      // boot0.rom is in: a remembered image was mounted before it
    output reg         ready = 1'b0     // the EEPROM holds the image, or there is none to wait for
);

    localparam int QUIET = CLK_HZ / 1000 * QUIET_MS;
    localparam int WAIT  = CLK_HZ / 1000 * WAIT_MS;

    localparam [1:0] S_IDLE = 2'd0, S_REQ = 2'd1, S_XFER = 2'd2;

    reg [1:0]  state        = S_IDLE;
    reg [1:0]  blk          = 2'd0;     // the block being moved
    reg        ena          = 1'b0;     // an image is connected
    reg        ro           = 1'b0;     // ... read only
    reg        load_pending = 1'b0;
    reg        loading      = 1'b0;     // the transfers are reads
    reg        check        = 1'b0;     // ... the first pass, which only looks
    reg        nonzero      = 1'b0;     // the first pass met a byte that is not zero
    reg        dirty        = 1'b0;
    reg [31:0] quiet_cnt    = 32'd0;
    reg [31:0] wait_cnt     = 32'd0;
    reg        mnt_d        = 1'b0;
    reg        ack_d        = 1'b0;

    // The machine's writes, into this clock.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] wr_s = 3'b000;
    always @(posedge clk) wr_s <= {wr_s[1:0], ee_wr_tgl};
    wire machine_wrote = wr_s[2] ^ wr_s[1];

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; sd_rd <= 1'b0; sd_wr <= 1'b0;
            ena <= 1'b0; ro <= 1'b0; load_pending <= 1'b0; loading <= 1'b0; check <= 1'b0;
            dirty <= 1'b0; quiet_cnt <= 32'd0; wait_cnt <= 32'd0; ready <= 1'b0;
            mnt_d <= 1'b0; ack_d <= 1'b0;
        end else begin
            mnt_d <= img_mounted;
            ack_d <= sd_ack;

            case (state)
            S_IDLE:
                if (load_pending) begin
                    load_pending <= 1'b0;
                    loading <= 1'b1;
                    check   <= 1'b1;
                    nonzero <= 1'b0;
                    blk     <= 2'd0;
                    sd_rd   <= 1'b1;
                    state   <= S_REQ;
                end else if (ena && !ro && dirty && quiet_cnt == 32'd0) begin
                    // Cleared first: a write during the transfers marks it again.
                    dirty   <= 1'b0;
                    loading <= 1'b0;
                    blk     <= 2'd0;
                    sd_wr   <= 1'b1;
                    state   <= S_REQ;
                end

            S_REQ:
                if (sd_ack) begin
                    sd_rd <= 1'b0;
                    sd_wr <= 1'b0;
                    state <= S_XFER;
                end

            S_XFER:
                if (ack_d && !sd_ack) begin
                    state <= S_IDLE;
                    if (load_pending || !ena) begin
                        // Another image since (or none): what was under way is moot.
                        loading <= 1'b0;
                        check   <= 1'b0;
                    end else if (blk != 2'd3) begin
                        blk   <= blk + 2'd1;
                        sd_rd <= loading;
                        sd_wr <= !loading;
                        state <= S_REQ;
                    end else if (check) begin
                        check <= 1'b0;
                        if (nonzero) begin          // an image: now into the EEPROM
                            blk   <= 2'd0;
                            sd_rd <= 1'b1;
                            state <= S_REQ;
                        end else begin              // a new file: it gets what the EEPROM holds
                            loading <= 1'b0;
                            dirty   <= 1'b1;
                            ready   <= 1'b1;
                        end
                    end else if (loading) begin
                        loading <= 1'b0;
                        ready   <= 1'b1;
                    end
                end

            default: state <= S_IDLE;
            endcase

            if (check && sd_ack && sd_buff_wr && sd_buff_dout != 8'h00) nonzero <= 1'b1;

            // The machine's writes (after the case: a mark wins over the clear above).
            if (machine_wrote && ena) begin
                dirty     <= 1'b1;
                quiet_cnt <= QUIET;
            end else if (quiet_cnt != 32'd0)
                quiet_cnt <= quiet_cnt - 32'd1;

            // boot0.rom is in: no image to wait for, or no more waiting.
            if (rom_loaded && !ready) begin
                if ((!ena && !load_pending && state == S_IDLE) || wait_cnt == WAIT) ready <= 1'b1;
                wait_cnt <= wait_cnt + 32'd1;
            end

            // A mount (hps_io holds img_mounted for the whole command).
            if (img_mounted && !mnt_d) begin
                if (img_size == 64'd2048) begin
                    ena          <= 1'b1;
                    ro           <= img_readonly;
                    load_pending <= 1'b1;
                end else
                    ena <= 1'b0;
                dirty <= 1'b0;
            end
        end
    end

    assign sd_lba      = {30'd0, blk};
    assign ee_addr     = {blk, sd_buff_addr};
    assign ee_we       = loading && !check && sd_ack && sd_buff_wr;
    assign ee_wdata    = sd_buff_dout;
    assign sd_buff_din = ee_rdata;

endmodule
