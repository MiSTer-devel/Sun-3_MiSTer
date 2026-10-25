//
// sun3_cdrom.sv
//
// sr0: a SCSI CD-ROM drive at target 6 on the Sun-3/60's on-board SCSI bus
// (rtl/sun3/sun3_si.sv, SUN3_CDROM), reading a flat image of 2048-byte
// sectors (an .iso) through the same block seam as the disks and the tape
// (Wish5380's blk_req_t / blk_rsp_t; on MiSTer, rtl/sun3_mister_block.sv on
// VD 4).  Its bus side, the byte handshake and the two-bank read-ahead are
// Wish5380's scsi_targ (rtl/vendor/wish5380/scsi_targ.sv, MIT, Romain
// Dolbeau), read only; what is new is what a CD drive answers.
//
// What it has to satisfy (docs/hardware.md, the SCSI row):
//
//   * The PROM boots a CD with its disk driver: `b sd(0,30,N)' on Rev 3.0.1
//     (unit 0x30 is target 6, LUN 0), sun3arc's install guide.  That driver
//     (sunstand sd.c) sends TEST UNIT READY until the unit is ready, READ(6)
//     of block 0 for the Sun label, then READ(6) of 512-byte blocks.  So the
//     drive must come up in 512-byte blocks, as Sun's CD drives did (their
//     firmware, or a jumper); the image's 2048-byte sector n is then blocks
//     4n .. 4n+3.  A Sun install CD carries a Sun label in its first 512
//     bytes (the ISO 9660 system area) with a partition per architecture.
//   * SunOS 4.1's sr driver (sundev/srreg.h 1.2 89/09/07, and scsi/targets/
//     srdef.h 1.11 89/12/18, both from SunOS 4.1.3) is built FIVETWELVE:
//     "set drive to read 2048 bytes per sector (default to 512
//     bytes/sector)".  It knows the drive by INQUIRY (its table names SONY,
//     Toshiba, Philips and Hitachi; sr(4S): "the SONY CDU-8012 ... and other
//     CDROM drives which have the same SCSI command set"), locks the door at
//     open (PREVENT/ALLOW MEDIUM REMOVAL), reads the capacity, reads with
//     READ(6) or READ(10), and changes the block size only to read mode-2
//     sectors (MODE SENSE, then MODE SELECT with a block descriptor) and back.
//     Its ioctls use READ TOC, READ SUB-CHANNEL and the audio commands.
//
// So, at reset and after a bus reset, 512-byte blocks; MODE SELECT(6) with a
// block descriptor of 512 or 2048 changes it (2048 for drivers that want the
// native size), any other length is refused -- a flat image has no mode-2
// sectors.  READ CAPACITY, MODE SENSE's block descriptor, the TOC's LBAs and
// every READ count in the current block size.
//
// Commands: TEST UNIT READY, REZERO, REQUEST SENSE, INQUIRY (type 5, the
// removable bit), MODE SELECT(6), MODE SENSE(6) (pages 01 and 0E, and 3F),
// START/STOP UNIT, PREVENT/ALLOW MEDIUM REMOVAL, RESERVE, RELEASE, SEND
// DIAGNOSTIC, READ(6), READ(10), SEEK(6), SEEK(10), VERIFY(10), READ
// CAPACITY, READ TOC (one data track, LBA or MSF), READ SUB-CHANNEL (no audio
// status) and STOP PLAY.  The audio PLAY commands answer ILLEGAL REQUEST,
// "illegal mode for this track" (the disc is data), PAUSE/RESUME "command
// sequence error"; writes and anything else, "invalid command".
//
// With no image mounted the drive still answers, NOT READY with ASC 3A
// (medium not present), as an empty drive does.  A disc mounted while the
// machine runs is reported once as UNIT ATTENTION, ASC 28 (medium may have
// changed); not after a reset, which the PROM's driver would only retry.
//
// Nothing here disconnects, as in scsi_targ.
//
`timescale 1ns / 1ps
`include "sun3_attr.vh"

module sun3_cdrom #(
    parameter int CLK_PERIOD_PS = 50000,
    parameter int TARGET_ID     = 6,         // sr0, as SunOS 4.1.1's GENERIC has it
    // INQUIRY strings.  The SONY CDU-8012 is the drive sr(4S) names.
    parameter logic [63:0]  VENDOR   = "SONY    ",
    parameter logic [127:0] PRODUCT  = "CD-ROM CDU-8012 ",
    parameter logic [31:0]  REVISION = "3.1a"
) (
    input  logic     clk_i,
    input  logic     rst_i,

    output scsi_t    drive_o,
    /* verilator lint_off UNUSEDSIGNAL */
    input  scsi_t    bus_i,
    /* verilator lint_on UNUSEDSIGNAL */

    output blk_req_t blk_o,
    input  blk_rsp_t blk_i,

    input  logic     media_changed_i         // one clock: an image was mounted or removed
);

    // ---------------------------------------------------------------------
    // Codes
    // ---------------------------------------------------------------------
    localparam logic [7:0] C_TEST_UNIT_READY = 8'h00, C_REZERO        = 8'h01,
                           C_REQUEST_SENSE   = 8'h03, C_READ6         = 8'h08,
                           C_SEEK6           = 8'h0b, C_INQUIRY       = 8'h12,
                           C_MODE_SELECT6    = 8'h15, C_RESERVE       = 8'h16,
                           C_RELEASE         = 8'h17, C_MODE_SENSE6   = 8'h1a,
                           C_START_STOP      = 8'h1b, C_SEND_DIAG     = 8'h1d,
                           C_PREVENT_ALLOW   = 8'h1e, C_READ_CAPACITY = 8'h25,
                           C_READ10          = 8'h28, C_SEEK10        = 8'h2b,
                           C_VERIFY10        = 8'h2f, C_READ_SUBCH    = 8'h42,
                           C_READ_TOC        = 8'h43, C_PLAY10        = 8'h45,
                           C_PLAY_MSF        = 8'h47, C_PLAY_TI       = 8'h48,
                           C_PLAY_TREL10     = 8'h49, C_PAUSE_RESUME  = 8'h4b,
                           C_STOP_PLAY       = 8'h4e, C_PLAY12        = 8'ha5,
                           C_PLAY_TREL12     = 8'ha9;

    localparam logic [7:0] ST_GOOD = 8'h00, ST_CHECK = 8'h02;

    localparam logic [3:0] SK_NO_SENSE = 4'h0, SK_NOT_READY = 4'h2, SK_MEDIUM = 4'h3,
                           SK_ILLEGAL  = 4'h5, SK_UNIT_ATTN = 4'h6;

    localparam logic [7:0] ASC_UNRECOVERED_READ = 8'h11, ASC_INVALID_COMMAND = 8'h20,
                           ASC_LBA_OUT_OF_RANGE = 8'h21, ASC_INVALID_FIELD   = 8'h24,
                           ASC_LUN_NOT_SUPPORTED = 8'h25, ASC_INVALID_PARAM  = 8'h26,
                           ASC_MEDIUM_CHANGED   = 8'h28, ASC_SEQUENCE_ERROR  = 8'h2c,
                           ASC_SAVING_NOT_SUPP  = 8'h39, ASC_NO_MEDIUM       = 8'h3a,
                           ASC_ILLEGAL_MODE     = 8'h64;

    localparam logic [7:0] M_COMMAND_COMPLETE = 8'h00, M_ABORT = 8'h06,
                           M_BUS_DEVICE_RESET = 8'h0c;

    localparam int T_SETTLE = (400_000 + CLK_PERIOD_PS - 1) / CLK_PERIOD_PS;
    localparam int SCNT_W   = $clog2(T_SETTLE + 1);
    localparam logic [SCNT_W-1:0] N_SETTLE = T_SETTLE[SCNT_W-1:0];
    localparam logic [7:0] ID_MASK = 8'(1 << TARGET_ID);

    // ---------------------------------------------------------------------
    // The sector buffer: two 512-byte banks, the back end writing one while
    // the bus reads the other (scsi_targ's read-ahead).  Read only, so the
    // bus side never writes: one write port, one read port.
    // ---------------------------------------------------------------------
    `SUN3_RAM_BLOCK logic [7:0] mem [0:1023];
    logic [9:0] a_addr, b_addr;
    logic [7:0] a_rdata;

    always_ff @(posedge clk_i)
        a_rdata <= mem[a_addr];
    always_ff @(posedge clk_i)
        if (blk_i.buf_we) mem[b_addr] <= blk_i.buf_wdata;

    logic        blk_start;
    logic [31:0] blk_lba;
    always_comb begin
        blk_o.start     = blk_start;
        blk_o.we        = 1'b0;            // read only
        blk_o.lba       = blk_lba;
        blk_o.buf_rdata = 8'h00;           // the back end never reads the buffer
    end

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE, S_SELWAIT, S_MSGOUT, S_CMD, S_EXEC, S_RDWAIT, S_TOCDIV,
        S_DATAIN, S_DATAOUT, S_STATUS, S_MSGIN, S_FREE
    } state_t;
    localparam logic [1:0] H_SETUP = 2'd0, H_REQ = 2'd1, H_REL = 2'd2;

    state_t      st;
    logic [1:0]  hs;
    logic [SCNT_W-1:0] sel_cnt;
    logic [9:0]  idx, xfer_len;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [95:0] cdb;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [3:0]  cdb_len;
    logic [2:0]  lun;
    logic        atn_seen;
    logic [7:0]  status, msg_rx;

    logic        bs2k;                // 2048-byte logical blocks (else 512)
    logic        ua;                  // UNIT ATTENTION pending: a new disc
    logic [23:0] blk_left;            // 512-byte blocks still to move on the bus

    // The read-ahead (scsi_targ's): bank_bus is the bank the bus is moving,
    // bank_fetch the one the back end is filling.
    logic        bank_bus, bank_fetch, fetch_sel;
    logic [1:0]  full;
    logic        fetch_busy, fetch_live;
    logic [31:0] fetch_lba, fetch_cur;
    logic [23:0] fetch_left;
    logic        med_err;
    logic [31:0] med_err_lba;

    logic [3:0]  sense_key;
    logic [7:0]  sense_asc;
    logic        sense_valid;
    logic [31:0] sense_info;

    // MODE SELECT's parameter list, as it streams past.
    logic [7:0]  msel_bdl;
    logic [23:0] msel_bl;

    // MODE SENSE: which parts the reply has.
    logic        ms_bd, ms_p1, ms_pe;
    // READ TOC: MSF addresses, the lead-out alone; and the lead-out's MSF.
    logic        toc_msf, toc_aa;
    logic [23:0] toc_rem;
    logic [7:0]  toc_m, toc_s, toc_f;
    // READ SUB-CHANNEL: the sub-Q data wanted, and its format.
    logic        sc_q;
    logic [7:0]  sc_fmt;

    localparam logic [2:0] R_NONE = 3'd0, R_MEDIA = 3'd1, R_INQUIRY = 3'd2, R_SENSE = 3'd3,
                           R_CAPACITY = 3'd4, R_MODE = 3'd5, R_TOC = 3'd6, R_SUBCH = 3'd7;
    logic [2:0]  resp_kind;

    // ---------------------------------------------------------------------
    // The bus
    // ---------------------------------------------------------------------
    logic       connected, drive_bus;
    logic [2:0] phase;                 // MSG, C/D, I/O
    logic [7:0] data_out;

    assign connected = (st != S_IDLE) && (st != S_FREE);
    assign drive_bus = connected && phase[0];

    always_comb begin
        drive_o      = '0;
        drive_o.bsy  = connected;
        drive_o.msg  = connected && phase[2];
        drive_o.cd   = connected && phase[1];
        drive_o.io   = connected && phase[0];
        drive_o.req  = connected && (hs == H_REQ);
        drive_o.data = drive_bus ? data_out : 8'h00;
        drive_o.dbp  = drive_bus ? ~(^data_out) : 1'b0;
    end

    // DATA IN is held while the back end fills a bank, and while the TOC's
    // lead-out is worked out: a phase change in the middle of a transfer
    // ends it for the Sun-3's DMA (scsi_targ.sv explains).
    always_comb
        case (st)
            S_MSGOUT:  phase = 3'b110;
            S_CMD:     phase = 3'b010;
            S_DATAIN, S_RDWAIT, S_TOCDIV:
                       phase = 3'b001;
            S_STATUS:  phase = 3'b011;
            S_MSGIN:   phase = 3'b111;
            default:   phase = 3'b000;        // DATA OUT, and the idle states
        endcase

    // ---------------------------------------------------------------------
    // The disc's size in the current block size
    // ---------------------------------------------------------------------
    logic [31:0] cap_blocks, last_lba;
    assign cap_blocks = bs2k ? {2'b00, blk_i.count[31:2]} : blk_i.count;
    assign last_lba   = (cap_blocks == 32'd0) ? 32'd0 : cap_blocks - 32'd1;

    logic [23:0] cur_bl;               // the block length, for the descriptors
    assign cur_bl = bs2k ? 24'd2048 : 24'd512;

    // ---------------------------------------------------------------------
    // Generated responses, functions of the byte index
    // ---------------------------------------------------------------------
    logic [2:0] vend_i;
    logic [3:0] prod_i;
    logic [1:0] rev_i;
    assign vend_i = 3'd7  - idx[2:0];
    assign prod_i = 4'd15 - idx[3:0];
    assign rev_i  = 2'd3  - idx[1:0];

    // MODE SENSE: the header, the block descriptor if wanted, page 01 (error
    // recovery, 8 bytes) and page 0E (CD audio control, 16 bytes).
    logic [5:0] ms_len;
    assign ms_len = 6'd4 + (ms_bd ? 6'd8 : 6'd0) + (ms_p1 ? 6'd8 : 6'd0) + (ms_pe ? 6'd16 : 6'd0);
    logic [5:0] ms_o1, ms_o2, ms_o3;
    assign ms_o1 = idx[5:0] - 6'd4;                       // in the block descriptor
    assign ms_o2 = ms_o1 - (ms_bd ? 6'd8 : 6'd0);         // in page 01
    assign ms_o3 = ms_o2 - (ms_p1 ? 6'd8 : 6'd0);         // in page 0E

    function automatic logic [7:0] bd_byte(input logic [2:0] i, input logic [31:0] n,
                                           input logic [23:0] bl);
        case (i)
            3'd1: bd_byte = (n[31:24] != 8'd0) ? 8'hff : n[23:16];
            3'd2: bd_byte = (n[31:24] != 8'd0) ? 8'hff : n[15:8];
            3'd3: bd_byte = (n[31:24] != 8'd0) ? 8'hff : n[7:0];
            3'd5: bd_byte = bl[23:16];
            3'd6: bd_byte = bl[15:8];
            3'd7: bd_byte = bl[7:0];
            default: bd_byte = 8'h00;                     // density 0, reserved
        endcase
    endfunction

    function automatic logic [7:0] page_e(input logic [3:0] i);
        case (i)
            4'd0:  page_e = 8'h0e;
            4'd1:  page_e = 8'h0e;
            4'd2:  page_e = 8'h04;                        // IMMED
            4'd8:  page_e = 8'h01;                        // port 0: channel 0
            4'd9:  page_e = 8'hff;                        // ... full volume
            4'd10: page_e = 8'h02;                        // port 1: channel 1
            4'd11: page_e = 8'hff;
            default: page_e = 8'h00;
        endcase
    endfunction

    // READ TOC: a four-byte header, then track 1 and the lead-out (or the
    // lead-out alone), eight bytes each.
    logic [9:0] toc_d;
    logic       toc_lead;
    logic [2:0] toc_f8;
    assign toc_d    = idx - 10'd4;
    assign toc_lead = toc_aa || toc_d[3];
    assign toc_f8   = toc_d[2:0];

    logic [7:0] resp;
    always_comb begin
        resp = 8'h00;
        case (resp_kind)
            R_INQUIRY:
                if (idx >= 10'd32)      resp = REVISION[8*rev_i +: 8];
                else if (idx >= 10'd16) resp = PRODUCT[8*prod_i +: 8];
                else if (idx >= 10'd8)  resp = VENDOR[8*vend_i +: 8];
                else case (idx[2:0])
                    3'd0: resp = (lun == 3'd0) ? 8'h05 : 8'h7f;   // CD-ROM; or nothing here
                    3'd1: resp = 8'h80;                         // removable
                    3'd2: resp = 8'h02;
                    3'd3: resp = 8'h02;
                    3'd4: resp = 8'd31;                         // thirty-six bytes in all
                    default: resp = 8'h00;
                endcase

            R_SENSE:
                case (idx[4:0])
                    5'd0:  resp = {sense_valid, 7'h70};
                    5'd2:  resp = {4'h0, sense_key};
                    5'd3:  resp = sense_info[31:24];
                    5'd4:  resp = sense_info[23:16];
                    5'd5:  resp = sense_info[15:8];
                    5'd6:  resp = sense_info[7:0];
                    5'd7:  resp = 8'd10;
                    5'd12: resp = sense_asc;
                    default: resp = 8'h00;
                endcase

            R_CAPACITY:
                case (idx[2:0])
                    3'd0: resp = last_lba[31:24];
                    3'd1: resp = last_lba[23:16];
                    3'd2: resp = last_lba[15:8];
                    3'd3: resp = last_lba[7:0];
                    3'd6: resp = bs2k ? 8'h08 : 8'h02;
                    default: resp = 8'h00;
                endcase

            R_MODE:
                if (idx < 10'd4)
                    case (idx[1:0])
                        2'd0: resp = {2'b00, ms_len - 6'd1};  // mode data length
                        2'd3: resp = ms_bd ? 8'd8 : 8'd0;     // block descriptor length
                        default: resp = 8'h00;                // medium type, device specific
                    endcase
                else if (ms_bd && ms_o1 < 6'd8)
                    resp = bd_byte(ms_o1[2:0], cap_blocks, cur_bl);
                else if (ms_p1 && ms_o2 < 6'd8)
                    resp = (ms_o2[2:0] == 3'd0) ? 8'h01 : (ms_o2[2:0] == 3'd1) ? 8'h06 : 8'h00;
                else
                    resp = page_e(ms_o3[3:0]);

            R_TOC:
                if (idx < 10'd4)
                    case (idx[1:0])
                        2'd1: resp = toc_aa ? 8'h0a : 8'h12;  // data length
                        2'd2: resp = 8'h01;                   // first track
                        2'd3: resp = 8'h01;                   // last track
                        default: resp = 8'h00;
                    endcase
                else
                    case (toc_f8)
                        3'd1: resp = 8'h14;                   // ADR 1, a data track
                        3'd2: resp = toc_lead ? 8'haa : 8'h01;
                        3'd4: resp = (toc_lead && !toc_msf) ? cap_blocks[31:24] : 8'h00;
                        3'd5: resp = !toc_lead ? 8'h00 : toc_msf ? toc_m : cap_blocks[23:16];
                        3'd6: resp = !toc_lead ? (toc_msf ? 8'h02 : 8'h00)
                                               : toc_msf ? toc_s : cap_blocks[15:8];
                        3'd7: resp = !toc_lead ? 8'h00 : toc_msf ? toc_f : cap_blocks[7:0];
                        default: resp = 8'h00;
                    endcase

            R_SUBCH:
                // No audio has played: status 15h, "no current audio status";
                // the position, for sub-Q format 1, at the start of track 1.
                case (idx[3:0])
                    4'd1: resp = 8'h15;
                    4'd3: resp = sc_q ? 8'd12 : 8'd0;
                    4'd4: resp = sc_fmt;
                    4'd5: resp = 8'h14;
                    4'd6: resp = 8'h01;
                    4'd7: resp = 8'h01;
                    default: resp = 8'h00;
                endcase

            default: resp = 8'h00;
        endcase
    end

    always_comb
        case (st)
            S_STATUS: data_out = status;
            S_MSGIN:  data_out = M_COMMAND_COMPLETE;
            default:  data_out = (resp_kind == R_MEDIA) ? a_rdata : resp;
        endcase

    assign a_addr    = {bank_bus, idx[8:0]};
    assign b_addr    = {bank_fetch, blk_i.buf_addr};
    assign fetch_sel = full[bank_bus] ? ~bank_bus : bank_bus;

    // ---------------------------------------------------------------------
    // Command decode
    // ---------------------------------------------------------------------
    logic [7:0]  op;
    assign op = cdb[7:0];

    logic [31:0] cdb_lba6, cdb_lba10, cmd_lba;
    logic [23:0] cdb_len6, cdb_len10, cmd_blocks;
    assign cdb_lba6  = {11'd0, cdb[12:8], cdb[23:16], cdb[31:24]};
    assign cdb_len6  = (cdb[39:32] == 8'd0) ? 24'd256 : {16'd0, cdb[39:32]};
    assign cdb_lba10 = {cdb[23:16], cdb[31:24], cdb[39:32], cdb[47:40]};
    assign cdb_len10 = {8'd0, cdb[63:56], cdb[71:64]};
    assign cmd_lba    = (op == C_READ10) ? cdb_lba10 : cdb_lba6;
    assign cmd_blocks = (op == C_READ10) ? cdb_len10 : cdb_len6;

    // The run, in 512-byte blocks of the image.
    logic [31:0] img_lba;
    logic [23:0] img_blocks;
    assign img_lba    = bs2k ? {cmd_lba[29:0], 2'b00} : cmd_lba;
    assign img_blocks = bs2k ? {cmd_blocks[21:0], 2'b00} : cmd_blocks;
    logic [32:0] cmd_end;
    assign cmd_end = {1'b0, cmd_lba} + {9'd0, cmd_blocks};

    logic [9:0]  alloc6, alloc10;
    assign alloc6  = {2'd0, cdb[39:32]};
    // Ten-byte allocation lengths, clamped to what any reply here can be.
    assign alloc10 = (cdb[63:58] != 6'd0) ? 10'h3ff : {cdb[57:56], cdb[71:64]};

    logic [3:0] len_of_op;
    always_comb
        case (bus_i.data[7:5])
            3'd1, 3'd2, 3'd6: len_of_op = 4'd10;     // groups 1, 2, and 6 (Sony's own)
            3'd5:             len_of_op = 4'd12;
            default:          len_of_op = 4'd6;
        endcase

    logic sel_match;
    assign sel_match = bus_i.sel && !bus_i.bsy && !bus_i.io &&
                       ((bus_i.data & ID_MASK) != 8'h00);

    logic media_fault;
    assign media_fault = blk_i.done && blk_i.err;

    function automatic logic [9:0] min10(input logic [9:0] a, input logic [9:0] b);
        min10 = (a < b) ? a : b;
    endfunction

    // A medium error's block, in the current block size, for the sense data.
    logic [31:0] err_blk;
    assign err_blk = (med_err ? med_err_lba : fetch_cur) >> (bs2k ? 2 : 0);

    // ---------------------------------------------------------------------
    // The sequencer
    // ---------------------------------------------------------------------
    task automatic check(input logic [3:0] key, input logic [7:0] asc);
        status      <= ST_CHECK;
        sense_key   <= key;
        sense_asc   <= asc;
        sense_valid <= 1'b0;
        sense_info  <= 32'd0;
        st          <= S_STATUS;
    endtask

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            st <= S_IDLE; hs <= H_SETUP; sel_cnt <= '0;
            idx <= '0; xfer_len <= '0; cdb <= '0; cdb_len <= 4'd6;
            lun <= '0; atn_seen <= 1'b0; status <= ST_GOOD; msg_rx <= '0;
            resp_kind <= R_NONE;
            bs2k <= 1'b0; ua <= 1'b0; blk_left <= '0;
            blk_start <= 1'b0; blk_lba <= '0;
            bank_bus <= 1'b0; bank_fetch <= 1'b0; full <= 2'b00;
            fetch_busy <= 1'b0; fetch_live <= 1'b0;
            fetch_lba <= '0; fetch_left <= '0; fetch_cur <= '0;
            med_err <= 1'b0; med_err_lba <= '0;
            sense_key <= SK_NO_SENSE; sense_asc <= 8'h00;
            sense_valid <= 1'b0; sense_info <= '0;
            msel_bdl <= '0; msel_bl <= '0;
            ms_bd <= 1'b0; ms_p1 <= 1'b0; ms_pe <= 1'b0;
            toc_msf <= 1'b0; toc_aa <= 1'b0; toc_rem <= '0;
            toc_m <= '0; toc_s <= '0; toc_f <= '0;
            sc_q <= 1'b0; sc_fmt <= '0;
        end else begin
            blk_start <= 1'b0;

            // A new disc: reported once, to the next command.
            if (media_changed_i && blk_i.ready) ua <= 1'b1;

            // The back end's answer, wherever the target is (scsi_targ).
            if (blk_i.done) begin
                fetch_busy <= 1'b0;
                if (fetch_live) begin
                    if (blk_i.err) begin
                        med_err     <= 1'b1;
                        med_err_lba <= fetch_cur;
                    end else
                        full[bank_fetch] <= 1'b1;
                end
            end

            // The read-ahead: the next block as soon as a bank is free.
            if ((st == S_RDWAIT || st == S_DATAIN) && resp_kind == R_MEDIA &&
                !fetch_busy && !med_err && fetch_left != 24'd0 && !full[fetch_sel]) begin
                blk_lba    <= fetch_lba;
                blk_start  <= 1'b1;
                bank_fetch <= fetch_sel;
                fetch_cur  <= fetch_lba;
                fetch_busy <= 1'b1;
                fetch_live <= 1'b1;
                fetch_lba  <= fetch_lba + 32'd1;
                fetch_left <= fetch_left - 24'd1;
            end

            if (bus_i.rst) begin
                // A bus reset is a hard reset: the command is forgotten and
                // the block size is the power-on one again.
                st         <= S_IDLE;
                hs         <= H_SETUP;
                sel_cnt    <= '0;
                fetch_live <= 1'b0;
                fetch_left <= '0;
                full       <= 2'b00;
                med_err    <= 1'b0;
                bs2k       <= 1'b0;
            end else begin
                case (st)
                    S_IDLE:
                        if (sel_match) begin
                            if (sel_cnt == N_SETTLE) begin
                                st       <= S_SELWAIT;
                                atn_seen <= bus_i.atn;
                                lun      <= '0;
                                status   <= ST_GOOD;
                                idx      <= '0;
                            end else
                                sel_cnt <= sel_cnt + 1'b1;
                        end else
                            sel_cnt <= '0;

                    S_SELWAIT: begin
                        if (bus_i.atn) atn_seen <= 1'b1;
                        if (!bus_i.sel) begin
                            hs  <= H_SETUP;
                            idx <= '0;
                            st  <= (bus_i.atn || atn_seen) ? S_MSGOUT : S_CMD;
                        end
                    end

                    S_MSGOUT:
                        case (hs)
                            H_SETUP: hs <= H_REQ;
                            H_REQ: if (bus_i.ack) begin
                                hs     <= H_REL;
                                msg_rx <= bus_i.data;
                                if (bus_i.data[7]) lun <= bus_i.data[2:0];
                            end
                            default: if (!bus_i.ack) begin
                                hs <= H_SETUP;
                                if (msg_rx == M_ABORT || msg_rx == M_BUS_DEVICE_RESET)
                                    st <= S_FREE;
                                else if (!bus_i.atn) begin
                                    idx <= '0;
                                    st  <= S_CMD;
                                end
                            end
                        endcase

                    S_CMD:
                        case (hs)
                            H_SETUP: hs <= H_REQ;
                            H_REQ: if (bus_i.ack) begin
                                hs <= H_REL;
                                cdb[8*idx[3:0] +: 8] <= bus_i.data;
                                if (idx == 10'd0) cdb_len <= len_of_op;
                                if (idx == 10'd1 && !atn_seen) lun <= bus_i.data[7:5];
                            end
                            default: if (!bus_i.ack) begin
                                hs <= H_SETUP;
                                if (idx + 10'd1 == {6'd0, cdb_len}) begin
                                    idx <= '0;
                                    st  <= S_EXEC;
                                end else
                                    idx <= idx + 10'd1;
                            end
                        endcase

                    // ---- what the command means ----------------------------
                    S_EXEC: begin
                        hs        <= H_SETUP;
                        idx       <= '0;
                        resp_kind <= R_NONE;
                        status    <= ST_GOOD;
                        st        <= S_STATUS;
                        if (op != C_REQUEST_SENSE) begin
                            sense_key   <= SK_NO_SENSE;
                            sense_asc   <= 8'h00;
                            sense_valid <= 1'b0;
                            sense_info  <= '0;
                        end

                        if (lun != 3'd0 && op != C_INQUIRY && op != C_REQUEST_SENSE)
                            check(SK_ILLEGAL, ASC_LUN_NOT_SUPPORTED);
                        else if (ua && op != C_INQUIRY && op != C_REQUEST_SENSE) begin
                            ua <= 1'b0;
                            check(SK_UNIT_ATTN, ASC_MEDIUM_CHANGED);
                        end else case (op)
                            C_INQUIRY: begin
                                resp_kind <= R_INQUIRY;
                                xfer_len  <= min10(alloc6, 10'd36);
                                if (alloc6 != 10'd0) st <= S_DATAIN;
                            end

                            C_REQUEST_SENSE: begin
                                // An allocation of zero is four bytes (SCSI-1).
                                // A pending UNIT ATTENTION is the sense, and
                                // reporting it consumes it.
                                resp_kind <= R_SENSE;
                                xfer_len  <= (alloc6 == 10'd0) ? 10'd4 : min10(alloc6, 10'd18);
                                st        <= S_DATAIN;
                                if (ua) begin
                                    ua          <= 1'b0;
                                    sense_key   <= SK_UNIT_ATTN;
                                    sense_asc   <= ASC_MEDIUM_CHANGED;
                                    sense_valid <= 1'b0;
                                    sense_info  <= '0;
                                end
                            end

                            C_TEST_UNIT_READY, C_REZERO, C_SEEK6, C_SEEK10, C_VERIFY10:
                                if (!blk_i.ready) check(SK_NOT_READY, ASC_NO_MEDIUM);

                            // The door and the motor: nothing to do.  The OSD
                            // can always change the disc, as a paper clip can.
                            C_START_STOP, C_PREVENT_ALLOW, C_RESERVE, C_RELEASE,
                            C_SEND_DIAG, C_STOP_PLAY: ;

                            C_READ_CAPACITY:
                                if (!blk_i.ready) check(SK_NOT_READY, ASC_NO_MEDIUM);
                                else begin
                                    resp_kind <= R_CAPACITY;
                                    xfer_len  <= 10'd8;
                                    st        <= S_DATAIN;
                                end

                            C_MODE_SENSE6:
                                if (cdb[23:22] == 2'b11)
                                    check(SK_ILLEGAL, ASC_SAVING_NOT_SUPP);
                                else if (cdb[21:16] != 6'h00 && cdb[21:16] != 6'h01 &&
                                         cdb[21:16] != 6'h0e && cdb[21:16] != 6'h3f)
                                    check(SK_ILLEGAL, ASC_INVALID_FIELD);
                                else begin
                                    resp_kind <= R_MODE;
                                    ms_bd     <= !cdb[11];
                                    ms_p1     <= cdb[21:16] == 6'h01 || cdb[21:16] == 6'h3f;
                                    ms_pe     <= cdb[21:16] == 6'h0e || cdb[21:16] == 6'h3f;
                                    xfer_len  <= min10(alloc6, {4'd0, 6'd4
                                                 + (!cdb[11] ? 6'd8 : 6'd0)
                                                 + ((cdb[21:16] == 6'h01 || cdb[21:16] == 6'h3f) ? 6'd8 : 6'd0)
                                                 + ((cdb[21:16] == 6'h0e || cdb[21:16] == 6'h3f) ? 6'd16 : 6'd0)});
                                    if (alloc6 != 10'd0) st <= S_DATAIN;
                                end

                            C_MODE_SELECT6:
                                if (alloc6 != 10'd0) begin
                                    xfer_len <= alloc6;
                                    msel_bdl <= 8'd0;
                                    msel_bl  <= 24'd0;
                                    st       <= S_DATAOUT;
                                end

                            C_READ6, C_READ10:
                                if (!blk_i.ready)
                                    check(SK_NOT_READY, ASC_NO_MEDIUM);
                                else if (cmd_end > {1'b0, cap_blocks}) begin
                                    check(SK_ILLEGAL, ASC_LBA_OUT_OF_RANGE);
                                    sense_valid <= 1'b1;
                                    sense_info  <= cmd_lba;
                                end else if (cmd_blocks != 24'd0) begin
                                    blk_left   <= img_blocks;
                                    resp_kind  <= R_MEDIA;
                                    xfer_len   <= 10'd512;
                                    fetch_lba  <= img_lba;
                                    fetch_left <= img_blocks;
                                    bank_bus   <= 1'b0;
                                    full       <= 2'b00;
                                    med_err    <= 1'b0;
                                    st         <= S_RDWAIT;
                                end

                            C_READ_TOC:
                                if (!blk_i.ready)
                                    check(SK_NOT_READY, ASC_NO_MEDIUM);
                                else if (cdb[55:48] > 8'd1 && cdb[55:48] != 8'haa)
                                    check(SK_ILLEGAL, ASC_INVALID_FIELD);
                                else begin
                                    resp_kind <= R_TOC;
                                    toc_msf   <= cdb[9];
                                    toc_aa    <= cdb[55:48] == 8'haa;
                                    xfer_len  <= min10(alloc10, (cdb[55:48] == 8'haa) ? 10'd12 : 10'd20);
                                    // The lead-out in frames: 2048-byte
                                    // sectors, and the two seconds before
                                    // track 1.
                                    toc_rem   <= blk_i.count[25:2] + 24'd150;
                                    toc_m     <= 8'd0;
                                    toc_s     <= 8'd0;
                                    if (alloc10 != 10'd0) st <= S_TOCDIV;
                                end

                            C_READ_SUBCH:
                                if (!blk_i.ready)
                                    check(SK_NOT_READY, ASC_NO_MEDIUM);
                                else begin
                                    resp_kind <= R_SUBCH;
                                    sc_q      <= cdb[22];
                                    sc_fmt    <= cdb[31:24];
                                    xfer_len  <= min10(alloc10, cdb[22] ? 10'd16 : 10'd4);
                                    if (alloc10 != 10'd0) st <= S_DATAIN;
                                end

                            C_PLAY10, C_PLAY_MSF, C_PLAY_TI, C_PLAY_TREL10, C_PLAY12, C_PLAY_TREL12:
                                if (!blk_i.ready) check(SK_NOT_READY, ASC_NO_MEDIUM);
                                else              check(SK_ILLEGAL, ASC_ILLEGAL_MODE);

                            C_PAUSE_RESUME:
                                check(SK_ILLEGAL, ASC_SEQUENCE_ERROR);

                            default:
                                check(SK_ILLEGAL, ASC_INVALID_COMMAND);
                        endcase
                    end

                    // ---- the lead-out's minutes, seconds and frames ------------
                    S_TOCDIV:
                        if (toc_rem >= 24'd4500) begin
                            toc_rem <= toc_rem - 24'd4500;
                            toc_m   <= toc_m + 8'd1;
                        end else if (toc_rem >= 24'd75) begin
                            toc_rem <= toc_rem - 24'd75;
                            toc_s   <= toc_s + 8'd1;
                        end else begin
                            toc_f <= toc_rem[7:0];
                            hs    <= H_SETUP;
                            st    <= S_DATAIN;
                        end

                    // ---- the back end filling a bank ---------------------------
                    S_RDWAIT:
                        if (med_err || media_fault) begin
                            check(SK_MEDIUM, ASC_UNRECOVERED_READ);
                            sense_valid <= 1'b1;
                            sense_info  <= err_blk;
                            fetch_left <= '0;
                            fetch_live <= 1'b0;
                        end else if (full[bank_bus]) begin
                            idx <= '0;
                            hs  <= H_SETUP;
                            st  <= S_DATAIN;
                        end

                    S_DATAIN:
                        case (hs)
                            H_SETUP: hs <= H_REQ;
                            H_REQ: if (bus_i.ack) hs <= H_REL;
                            default: if (!bus_i.ack) begin
                                hs <= H_SETUP;
                                if (idx + 10'd1 == xfer_len) begin
                                    idx <= '0;
                                    if (resp_kind == R_MEDIA) begin
                                        full[bank_bus] <= 1'b0;
                                        if (blk_left != 24'd1 && !med_err) begin
                                            blk_left <= blk_left - 24'd1;
                                            bank_bus <= ~bank_bus;
                                            st       <= S_RDWAIT;
                                        end else if (med_err) begin
                                            check(SK_MEDIUM, ASC_UNRECOVERED_READ);
                                            sense_valid <= 1'b1;
                                            sense_info  <= err_blk;
                                            fetch_left <= '0;
                                            fetch_live <= 1'b0;
                                        end else begin
                                            fetch_live <= 1'b0;
                                            st         <= S_STATUS;
                                        end
                                    end else
                                        st <= S_STATUS;
                                end else
                                    idx <= idx + 10'd1;
                            end
                        endcase

                    // ---- MODE SELECT's list: the block descriptor's length --------
                    S_DATAOUT:
                        case (hs)
                            H_SETUP: hs <= H_REQ;
                            H_REQ: if (bus_i.ack) begin
                                hs <= H_REL;
                                case (idx)
                                    10'd3:  msel_bdl       <= bus_i.data;
                                    10'd9:  msel_bl[23:16] <= bus_i.data;
                                    10'd10: msel_bl[15:8]  <= bus_i.data;
                                    10'd11: msel_bl[7:0]   <= bus_i.data;
                                    default: ;
                                endcase
                            end
                            default: if (!bus_i.ack) begin
                                hs <= H_SETUP;
                                if (idx + 10'd1 == xfer_len) begin
                                    idx <= '0;
                                    st  <= S_STATUS;
                                    // A descriptor's block length of zero
                                    // changes nothing.
                                    if (xfer_len >= 10'd12 && msel_bdl >= 8'd8)
                                        case (msel_bl)
                                            24'd0:    ;
                                            24'd512:  bs2k <= 1'b0;
                                            24'd2048: bs2k <= 1'b1;
                                            default:  check(SK_ILLEGAL, ASC_INVALID_PARAM);
                                        endcase
                                end else
                                    idx <= idx + 10'd1;
                            end
                        endcase

                    S_STATUS:
                        case (hs)
                            H_SETUP: hs <= H_REQ;
                            H_REQ: if (bus_i.ack) hs <= H_REL;
                            default: if (!bus_i.ack) begin
                                hs <= H_SETUP;
                                st <= S_MSGIN;
                            end
                        endcase

                    S_MSGIN:
                        case (hs)
                            H_SETUP: hs <= H_REQ;
                            H_REQ: if (bus_i.ack) hs <= H_REL;
                            default: if (!bus_i.ack) begin
                                hs <= H_SETUP;
                                st <= S_FREE;
                                // Retrieving the sense is what consumes it.
                                if (op == C_REQUEST_SENSE) begin
                                    sense_key   <= SK_NO_SENSE;
                                    sense_asc   <= 8'h00;
                                    sense_valid <= 1'b0;
                                    sense_info  <= '0;
                                end
                            end
                        endcase

                    default: begin          // S_FREE
                        hs      <= H_SETUP;
                        sel_cnt <= '0;
                        msg_rx  <= '0;
                        st      <= S_IDLE;
                    end
                endcase
            end
        end
    end

`ifdef SIMULATION
    // +trace_cd: every command, and how it ended.
    bit     trace;
    integer moved;
    initial trace = $test$plusargs("trace_cd");
    always @(posedge clk_i) if (trace && !rst_i) begin
        if (st == S_CMD && hs == H_REQ && bus_i.ack && idx == 10'd0) moved = 0;
        if ((st == S_DATAIN || st == S_DATAOUT) && hs == H_REQ && bus_i.ack) moved = moved + 1;
        if (st == S_EXEC)
            $display("[%0t] sr0: cdb %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x (%0d bytes), %0d-byte blocks",
                     $time, cdb[7:0], cdb[15:8], cdb[23:16], cdb[31:24], cdb[39:32], cdb[47:40],
                     cdb[55:48], cdb[63:56], cdb[71:64], cdb[79:72], cdb_len, bs2k ? 2048 : 512);
        if (st == S_STATUS && hs == H_REQ && bus_i.ack)
            $display("[%0t] sr0:   status %02x, %0d data bytes; sense key %h asc %02x",
                     $time, status, moved, sense_key, sense_asc);
    end
`endif

endmodule
