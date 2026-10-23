//============================================================================
//  tb_cdrom -- rtl/sun3/sun3_cdrom.sv (sr0, target 6) on Wish5380's SCSI
//  fabric, driven by an initiator that selects as the Sun-3's si board does
//  (its own ID bit and the target's, no ATN unless asked), with a block back
//  end that behaves like sun3_mister_block: a start while it is busy is
//  ignored, and every block takes a while.
//
//  The disc is made here: 402 blocks of 512 bytes (100 whole 2048-byte
//  sectors and half of one more), each beginning with its own block number,
//  so a block from the wrong place cannot pass.  Checked:
//
//    no disc: INQUIRY still answers (a CD-ROM, removable, SONY CDU-8012),
//    everything that needs the disc is NOT READY / 3A (medium not present);
//    a disc inserted while the machine runs: UNIT ATTENTION / 28 once, to
//    the next command or to REQUEST SENSE; removing it is not one;
//    the commands SunOS 4.1's sr driver sends at open (TEST UNIT READY,
//    INQUIRY, PREVENT MEDIUM REMOVAL, READ CAPACITY) and the PROM's disk
//    driver (TEST UNIT READY, READ(6) of block 0, then 512-byte blocks);
//    512-byte blocks after reset: READ(6) and READ(10) across the
//    2048-byte sector seams, READ(6) of 256 blocks, the last block, past it;
//    MODE SENSE(6): header, block descriptor, pages 01 and 0E, 3F, DBD,
//    saved values and an unknown page refused;
//    MODE SELECT(6) to 2048-byte blocks: READ CAPACITY, MODE SENSE, READ(6)
//    and READ(10) in 2048-byte blocks, the range check, and back to 512; a
//    block length of 2336 (mode 2) refused, and the size left as it was; a
//    bus reset back to 512;
//    READ TOC in LBA and MSF, at both block sizes, the lead-out alone, a
//    track that is not there; READ SUB-CHANNEL; the audio commands refused;
//    writes refused without a DATA OUT phase; a vendor command's ten bytes
//    taken whole; a LUN that is not there, by CDB and by IDENTIFY;
//    a medium error part way through a read, and the read-ahead's blocks
//    arriving in order under a slow back end.
//
//      make -C tb/verilator tb_cdrom
//============================================================================
`timescale 1ns/1ps

module tb_cdrom;

reg clk = 0;
always #25 clk = ~clk;                      // 20 MHz, the machine's clock
reg rst = 1;

// ---- the bus ---------------------------------------------------------------
scsi_t ini, targ, bus;
scsi_fabric fabric (.a_i(ini), .b_i(targ), .c_i('0), .d_i('0), .bus_o(bus));

blk_req_t blk_o;
blk_rsp_t blk_i;
reg       media_changed = 0;

sun3_cdrom #(.CLK_PERIOD_PS(50000), .TARGET_ID(6)) dut (
    .clk_i(clk), .rst_i(rst), .drive_o(targ), .bus_i(bus),
    .blk_o(blk_o), .blk_i(blk_i), .media_changed_i(media_changed));

// ---- the disc --------------------------------------------------------------
localparam int NBLK = 402;
function automatic bit [7:0] disc_byte(input int lba, input int i);
    if (i < 4) return 8'(lba >> (8 * (3 - i)));
    return 8'((lba * 7 + i * 3) & 8'hFF);
endfunction

reg        ready = 0;
reg [31:0] count = 0;
reg [31:0] err_lba = 32'hFFFFFFFF;
integer    fetches = 0;

task automatic mount(input bit present);
    @(posedge clk);
    ready <= present;
    count <= present ? NBLK : 0;
    media_changed <= 1;
    @(posedge clk);
    media_changed <= 0;
    repeat (20) @(posedge clk);
endtask

reg       b_done = 0, b_err = 0, b_we = 0;
reg [8:0] b_addr = 0;
reg [7:0] b_wdata = 0;
integer   latency = 150;
realtime  t_asked [int];           // when each block was last asked for

always_comb begin
    blk_i           = '0;
    blk_i.done      = b_done;
    blk_i.err       = b_err;
    blk_i.ready     = ready;
    blk_i.count     = count;
    blk_i.buf_we    = b_we;
    blk_i.buf_addr  = b_addr;
    blk_i.buf_wdata = b_wdata;
end

integer starts_while_busy = 0;
// A start the back end sees while it is busy with a block: it would be lost.
task automatic busy_clock;
    @(posedge clk);
    if (blk_o.start) begin
        starts_while_busy++;
        $display("[%0t] a start for block %0d while the back end is busy", $time, blk_o.lba);
    end
endtask
always @(posedge clk) if (blk_o.start && blk_o.we) begin $display("FAIL: the CD asked to write"); $finish; end

initial begin : backend
    reg [31:0] lba;
    forever begin
        @(posedge clk);
        b_done <= 1'b0;
        if (blk_o.start) begin
            lba = blk_o.lba;
            fetches++;
            t_asked[lba] = $realtime;
            repeat (latency) busy_clock();
            if (!ready || lba >= count || lba == err_lba)
                b_err <= 1'b1;
            else begin
                b_err <= 1'b0;
                for (int i = 0; i < 512; i++) begin
                    b_we    <= 1'b1;
                    b_addr  <= 9'(i);
                    b_wdata <= disc_byte(int'(lba), i);
                    busy_clock();
                end
                b_we <= 1'b0;
            end
            b_done <= 1'b1;
        end
    end
end

// ---- checks ----------------------------------------------------------------
integer passes = 0, fails = 0;
task automatic check(input bit ok, input string what);
    if (ok) passes++;
    else begin fails++; $display("FAIL: %s", what); end
endtask

// d[off ..] holds n consecutive 512-byte blocks of the disc from `first'.
function automatic bit blocks_are(input bit [7:0] d[$], input int off, input int first, input int n);
    if (d.size() < off + 512 * n) return 0;
    for (int b = 0; b < n; b++)
        for (int i = 0; i < 512; i++)
            if (d[off + 512 * b + i] != disc_byte(first + b, i)) return 0;
    return 1;
endfunction

// ---- the initiator ---------------------------------------------------------
initial ini = '0;

bit [7:0] din [$];
realtime  t_first;              // when DATA IN's 512th byte arrived
bit [7:0] dout [$];             // what DATA OUT sends
bit [7:0] st_byte, msg_byte;
bit       timed_out;
int       ncdb_taken, nout_taken;

// One command, selection to bus free.  c is the CDB (its length is the
// target's to decide, from the opcode); `identify' >= 0 selects with ATN and
// sends IDENTIFY for that LUN first; `abort_after' >= 0 resets the bus once
// that many DATA IN bytes have arrived.
task automatic cmd(input bit [7:0] c [12], input int identify = -1, input int abort_after = -1);
    int k, n, guard;
    din.delete();
    st_byte = 8'hFF; msg_byte = 8'hFF; timed_out = 0;
    k = 0; n = 0;

    @(posedge clk);
    ini.data <= 8'h80 | 8'h40;                 // the host's ID 7 and target 6
    ini.sel  <= 1'b1;
    if (identify >= 0) ini.atn <= 1'b1;
    guard = 0;
    while (!bus.bsy) begin @(posedge clk); guard++; if (guard > 200000) begin timed_out = 1; break; end end
    ini.sel  <= 1'b0;
    ini.data <= 8'h00;
    if (timed_out) begin check(0, "selection answered"); return; end

    forever begin
        guard = 0;
        @(posedge clk);
        while (bus.bsy && !bus.req) begin
            @(posedge clk);
            guard++;
            if (guard > 400000) begin timed_out = 1; break; end
        end
        if (timed_out) begin check(0, $sformatf("command %02x finishes", c[0])); break; end
        if (!bus.bsy) break;
        if (bus.io) begin
            case ({bus.msg, bus.cd})
                2'b00: begin din.push_back(bus.data); if (din.size() == 512) t_first = $realtime; end
                2'b01: st_byte = bus.data;
                2'b11: msg_byte = bus.data;
                default: ;
            endcase
            ini.ack <= 1'b1;
        end else if (bus.msg) begin            // MESSAGE OUT: IDENTIFY, then drop ATN
            ini.data <= 8'h80 | 8'(identify);
            ini.atn  <= 1'b0;
            ini.ack  <= 1'b1;
        end else begin
            if (bus.cd) begin ini.data <= (k < 12) ? c[k] : 8'h00; k++; end
            else begin ini.data <= (n < dout.size()) ? dout[n] : 8'h00; n++; end
            ini.ack <= 1'b1;
        end
        @(posedge clk);
        while (bus.req) @(posedge clk);
        ini.ack  <= 1'b0;
        ini.data <= 8'h00;
        if (abort_after >= 0 && din.size() == abort_after) begin
            repeat (8) @(posedge clk);
            ini.rst <= 1'b1;
            repeat (20) @(posedge clk);
            ini.rst <= 1'b0;
            repeat (5) @(posedge clk);
            break;
        end
    end
    ncdb_taken = k; nout_taken = n;
    ini.atn <= 1'b0;
    repeat (3) @(posedge clk);
endtask

function automatic void cdb6(output bit [7:0] c [12], input bit [7:0] b0, b1, b2, b3, b4, b5);
    c = '{b0, b1, b2, b3, b4, b5, 0, 0, 0, 0, 0, 0};
endfunction

bit [7:0] c [12];
bit [7:0] sense [$];

task automatic c6(input bit [7:0] b0, b1, b2, b3, b4, b5);
    cdb6(c, b0, b1, b2, b3, b4, b5);
    cmd(c);
endtask

task automatic c10(input bit [7:0] b0, b1, b2, b3, b4, b5, b6, b7, b8, b9);
    c = '{b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, 0, 0};
    cmd(c);
endtask

task automatic get_sense(input int alloc = 18);
    c6(8'h03, 0, 0, 0, 8'(alloc), 0);
    sense = din;
endtask

function automatic bit sense_is(input bit [3:0] key, input bit [7:0] asc);
    return sense.size() >= 14 && sense[0][6:0] == 7'h70 && sense[2][3:0] == key && sense[12] == asc;
endfunction

task automatic read6(input int lba, input int n);
    c6(8'h08, 8'(lba >> 16) & 8'h1F, 8'(lba >> 8), 8'(lba), 8'(n), 0);
endtask

task automatic read10(input int lba, input int n);
    c10(8'h28, 0, 8'(lba >> 24), 8'(lba >> 16), 8'(lba >> 8), 8'(lba), 0, 8'(n >> 8), 8'(n), 0);
endtask

task automatic capacity(output int last, output int bl);
    c10(8'h25, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    last = (din.size() == 8) ? {din[0], din[1], din[2], din[3]} : -1;
    bl   = (din.size() == 8) ? {din[4], din[5], din[6], din[7]} : -1;
endtask

// MODE SELECT(6) with a header and one block descriptor of this block length.
task automatic mode_select_bl(input int bl, input bit [7:0] density = 0);
    dout = '{8'h00, 8'h00, 8'h00, 8'h08, density, 8'h00, 8'h00, 8'h00, 8'h00,
             8'(bl >> 16), 8'(bl >> 8), 8'(bl)};
    c6(8'h15, 8'h10, 0, 0, 12, 0);
    dout.delete();
endtask

task automatic read_toc(input bit msf, input int track, input int alloc = 804);
    c10(8'h43, msf ? 8'h02 : 8'h00, 0, 0, 0, 0, 8'(track), 8'(alloc >> 8), 8'(alloc), 0);
endtask

// ---- the test --------------------------------------------------------------
int last, bl, nf;
initial begin
    repeat (10) @(posedge clk);
    rst = 0;
    repeat (50) @(posedge clk);

    // ---- no disc ---------------------------------------------------------------
    c6(8'h12, 0, 0, 0, 36, 0);
    check(st_byte == 8'h00 && din.size() == 36, "INQUIRY with no disc: GOOD, 36 bytes");
    check(din.size() == 36 && din[0] == 8'h05 && din[1] == 8'h80,
          "... peripheral type 5 (CD-ROM), removable");
    check(din.size() == 36 && din[4] == 8'd31, "... additional length 31");
    check(din.size() == 36 && din[8] == "S" && din[11] == "Y" && din[15] == " " &&
          din[16] == "C" && din[23] == "C" && din[27] == "8" && din[30] == "2",
          "... SONY CD-ROM CDU-8012, the drive sr(4S) names");
    check(ncdb_taken == 6 && msg_byte == 8'h00, "... six CDB bytes, COMMAND COMPLETE");
    c6(8'h12, 0, 0, 0, 5, 0);
    check(din.size() == 5, "INQUIRY with an allocation of 5: five bytes");
    c6(8'h12, 8'h20, 0, 0, 36, 0);
    check(st_byte == 8'h00 && din.size() == 36 && din[0] == 8'h7f, "INQUIRY of LUN 1 (in the CDB): nothing there");
    cdb6(c, 8'h12, 0, 0, 0, 36, 0);
    cmd(c, 2);
    check(st_byte == 8'h00 && din.size() == 36 && din[0] == 8'h7f, "INQUIRY of LUN 2 (by IDENTIFY): nothing there");
    cdb6(c, 8'h00, 0, 0, 0, 0, 0);
    cmd(c, 0);
    check(st_byte == 8'h02, "TEST UNIT READY with IDENTIFY, LUN 0, no disc: CHECK");

    c6(8'h00, 0, 0, 0, 0, 0);
    check(st_byte == 8'h02 && din.size() == 0, "TEST UNIT READY with no disc: CHECK CONDITION");
    get_sense(18);
    check(sense.size() == 18 && sense_is(4'h2, 8'h3a), "... sense NOT READY, 3A medium not present, 18 bytes");
    get_sense(0);
    check(sense.size() == 4, "REQUEST SENSE with an allocation of 0: four bytes (SCSI-1)");
    read6(0, 1);
    check(st_byte == 8'h02 && din.size() == 0, "READ(6) with no disc: CHECK, nothing moved");
    get_sense(18);
    check(sense_is(4'h2, 8'h3a), "... NOT READY / 3A");
    capacity(last, bl);
    check(st_byte == 8'h02 && din.size() == 0, "READ CAPACITY with no disc: CHECK");
    read_toc(0, 0);
    check(st_byte == 8'h02 && din.size() == 0, "READ TOC with no disc: CHECK");
    c6(8'h1b, 0, 0, 0, 1, 0);
    check(st_byte == 8'h00, "START UNIT with no disc: GOOD");

    // ---- a disc is inserted ---------------------------------------------------
    mount(1);
    c6(8'h00, 0, 0, 0, 0, 0);
    check(st_byte == 8'h02, "first command after a disc goes in: CHECK");
    get_sense(18);
    check(sense_is(4'h6, 8'h28), "... UNIT ATTENTION, 28 medium may have changed");
    c6(8'h00, 0, 0, 0, 0, 0);
    check(st_byte == 8'h00, "... reported once: TEST UNIT READY now GOOD");
    get_sense(18);
    check(sense_is(4'h0, 8'h00), "... and no sense left");
    mount(1);
    c6(8'h00, 0, 0, 0, 0, 0);
    check(st_byte == 8'h02, "another disc: CHECK");
    c6(8'h00, 0, 0, 0, 0, 0);
    check(st_byte == 8'h00, "... and the CHECK alone cleared it, no REQUEST SENSE needed");
    mount(1);
    c6(8'h12, 0, 0, 0, 36, 0);
    check(st_byte == 8'h00 && din.size() == 36, "a new disc: INQUIRY is not held up by the UNIT ATTENTION");
    get_sense(18);
    check(sense_is(4'h6, 8'h28), "... REQUEST SENSE reports it");
    c6(8'h00, 0, 0, 0, 0, 0);
    check(st_byte == 8'h00, "... and that consumed it");

    // ---- SunOS's sropen, the PROM's sdopen --------------------------------------
    c6(8'h1e, 0, 0, 0, 1, 0);
    check(st_byte == 8'h00, "PREVENT MEDIUM REMOVAL: GOOD");
    capacity(last, bl);
    check(st_byte == 8'h00 && last == NBLK - 1 && bl == 512,
          $sformatf("READ CAPACITY after reset: last block %0d, 512-byte blocks (got %0d, %0d)", NBLK - 1, last, bl));
    read6(0, 1);
    check(st_byte == 8'h00 && din.size() == 512 && blocks_are(din, 0, 0, 1), "READ(6) of block 0 (the PROM's label read)");
    read6(3, 3);
    check(st_byte == 8'h00 && blocks_are(din, 0, 3, 3), "READ(6) of blocks 3..5, across the 2048-byte seam");
    read10(0, 300);
    check(st_byte == 8'h00 && din.size() == 300 * 512 && blocks_are(din, 0, 0, 300),
          "READ(10) of 300 blocks: the count's high byte counts");
    read10(62, 8);
    check(st_byte == 8'h00 && din.size() == 8 * 512 && blocks_are(din, 0, 62, 8),
          "READ(10) of blocks 62..69, across two seams");
    read6(100, 0);
    check(st_byte == 8'h00 && din.size() == 256 * 512 && blocks_are(din, 0, 100, 256),
          "READ(6) with a count of 0: 256 blocks");
    read6(NBLK - 1, 1);
    check(st_byte == 8'h00 && blocks_are(din, 0, NBLK - 1, 1), "READ of the last block");
    read6(NBLK - 2, 3);
    check(st_byte == 8'h02 && din.size() == 0, "READ past the end: CHECK, nothing moved");
    get_sense(18);
    check(sense_is(4'h5, 8'h21) && sense[0] == 8'hF0 && {sense[3], sense[4], sense[5], sense[6]} == NBLK - 2,
          "... ILLEGAL REQUEST, 21 LBA out of range, the LBA in the information field");
    read10(5, 0);
    check(st_byte == 8'h00 && din.size() == 0, "READ(10) of no blocks: GOOD, nothing moved");

    // ---- MODE SENSE ------------------------------------------------------------
    c6(8'h1a, 0, 8'h00, 0, 255, 0);
    check(st_byte == 8'h00 && din.size() == 12, "MODE SENSE page 0: header and block descriptor, 12 bytes");
    check(din.size() == 12 && din[0] == 8'd11 && din[3] == 8'd8 && {din[5], din[6], din[7]} == NBLK &&
          {din[9], din[10], din[11]} == 512, "... length 11, descriptor 8: 402 blocks of 512 bytes");
    c6(8'h1a, 0, 8'h3f, 0, 255, 0);
    check(din.size() == 36 && din[0] == 8'd35 && din[12] == 8'h01 && din[13] == 8'h06 &&
          din[20] == 8'h0e && din[21] == 8'h0e && din[29] == 8'hff,
          "MODE SENSE 3F: descriptor, page 01, page 0E (volume full)");
    c6(8'h1a, 8'h08, 8'h0e, 0, 255, 0);
    check(din.size() == 20 && din[3] == 8'd0 && din[4] == 8'h0e, "MODE SENSE with DBD: no descriptor, page 0E at once");
    c6(8'h1a, 0, 8'h01, 0, 4, 0);
    check(din.size() == 4 && din[0] == 8'd19, "MODE SENSE cut short by its allocation, the length still the whole");
    c6(8'h1a, 0, 8'hc0, 0, 255, 0);
    check(st_byte == 8'h02, "MODE SENSE of saved values: CHECK");
    get_sense(18);
    check(sense_is(4'h5, 8'h39), "... ILLEGAL REQUEST, 39 saving not supported");
    c6(8'h1a, 0, 8'h04, 0, 255, 0);
    check(st_byte == 8'h02, "MODE SENSE of page 04 (a disk's geometry): CHECK");
    get_sense(18);
    check(sense_is(4'h5, 8'h24), "... ILLEGAL REQUEST, 24 invalid field");

    // ---- 2048-byte blocks ---------------------------------------------------------
    mode_select_bl(2048);
    check(st_byte == 8'h00 && nout_taken == 12, "MODE SELECT to 2048-byte blocks: twelve bytes taken, GOOD");
    capacity(last, bl);
    check(last == NBLK / 4 - 1 && bl == 2048,
          $sformatf("READ CAPACITY: last sector %0d, 2048 bytes (got %0d, %0d)", NBLK / 4 - 1, last, bl));
    c6(8'h1a, 0, 8'h00, 0, 255, 0);
    check(din.size() == 12 && {din[5], din[6], din[7]} == NBLK / 4 && {din[9], din[10], din[11]} == 2048,
          "MODE SENSE's descriptor: 100 blocks of 2048");
    read6(1, 2);
    check(st_byte == 8'h00 && din.size() == 4096 && blocks_are(din, 0, 4, 8),
          "READ(6) of sectors 1..2: 4096 bytes, the image's blocks 4..11");
    read10(16, 1);
    check(st_byte == 8'h00 && din.size() == 2048 && blocks_are(din, 0, 64, 4),
          "READ(10) of sector 16 (the ISO 9660 volume descriptor): blocks 64..67");
    read10(NBLK / 4 - 1, 1);
    check(st_byte == 8'h00 && blocks_are(din, 0, (NBLK / 4 - 1) * 4, 4), "READ of the last whole sector");
    read10(NBLK / 4 - 1, 2);
    check(st_byte == 8'h02 && din.size() == 0, "READ of the half sector at the end: out of range");
    read_toc(0, 0);
    check(st_byte == 8'h00 && din.size() == 20 && din[1] == 8'h12 && din[2] == 1 && din[3] == 1,
          "READ TOC: 20 bytes, tracks 1 to 1");
    check(din.size() == 20 && din[5] == 8'h14 && din[6] == 8'h01 && {din[8], din[9], din[10], din[11]} == 0,
          "... track 1: a data track at LBA 0");
    check(din.size() == 20 && din[13] == 8'h14 && din[14] == 8'haa && {din[16], din[17], din[18], din[19]} == NBLK / 4,
          "... lead-out at LBA 100, in 2048-byte blocks");
    read_toc(1, 0);
    check(din.size() == 20 && din[9] == 0 && din[10] == 2 && din[11] == 0 &&
          din[17] == 0 && din[18] == 3 && din[19] == 25,
          $sformatf("READ TOC in MSF: track 1 at 00:02:00, lead-out at 00:03:25 (got %0d:%0d:%0d)",
                    din.size() == 20 ? din[17] : 0, din.size() == 20 ? din[18] : 0, din.size() == 20 ? din[19] : 0));
    read_toc(0, 8'haa);
    check(din.size() == 12 && din[1] == 8'h0a && din[6] == 8'haa && {din[8], din[9], din[10], din[11]} == NBLK / 4,
          "READ TOC from AA: the lead-out alone");
    read_toc(0, 1, 12);
    check(din.size() == 12, "READ TOC cut short by its allocation");
    read_toc(0, 2);
    check(st_byte == 8'h02, "READ TOC from track 2: CHECK");
    get_sense(18);
    check(sense_is(4'h5, 8'h24), "... invalid field");
    mode_select_bl(2336, 8'h81);
    check(st_byte == 8'h02, "MODE SELECT to 2336-byte blocks (mode 2): CHECK");
    get_sense(18);
    check(sense_is(4'h5, 8'h26), "... 26 invalid field in the parameter list");
    capacity(last, bl);
    check(bl == 2048, "... and the block size is still 2048");
    dout = '{8'h00, 8'h00, 8'h00, 8'h00};
    c6(8'h15, 8'h10, 0, 0, 4, 0);
    dout.delete();
    capacity(last, bl);
    check(bl == 2048, "MODE SELECT with no block descriptor: the size kept");
    mode_select_bl(2049);
    check(st_byte == 8'h02, "MODE SELECT to 2049-byte blocks: CHECK (all three bytes of the length count)");
    mode_select_bl(0);
    capacity(last, bl);
    check(bl == 2048, "MODE SELECT with a block length of 0: the size kept");
    mode_select_bl(512);
    capacity(last, bl);
    check(st_byte == 8'h00 && last == NBLK - 1 && bl == 512, "MODE SELECT back to 512-byte blocks");
    // No descriptor, and a page whose bytes 9..11 would read as 2048.
    dout = '{8'h00, 8'h00, 8'h00, 8'h00, 8'h01, 8'h06, 8'h00, 8'h00, 8'h00, 8'h00, 8'h08, 8'h00};
    c6(8'h15, 8'h10, 0, 0, 12, 0);
    dout.delete();
    capacity(last, bl);
    check(bl == 512, "MODE SELECT with a page and no descriptor: the page is not taken for one");
    read6(7, 2);
    check(blocks_are(din, 0, 7, 2), "... and READ is in 512-byte blocks again");
    read_toc(0, 0);
    check(din.size() == 20 && {din[16], din[17], din[18], din[19]} == NBLK, "READ TOC's lead-out in 512-byte blocks: 402");

    // A bus reset is the power-on block size again.
    mode_select_bl(2048);
    c6(8'h12, 0, 0, 0, 36, 0);
    @(posedge clk); ini.rst <= 1'b1; repeat (20) @(posedge clk); ini.rst <= 1'b0; repeat (5) @(posedge clk);
    capacity(last, bl);
    check(st_byte == 8'h00 && bl == 512, "a bus reset: 512-byte blocks again");

    // ---- the rest of the command set -----------------------------------------------
    c10(8'h42, 0, 8'h00, 0, 0, 0, 0, 0, 16, 0);
    check(st_byte == 8'h00 && din.size() == 4 && din[1] == 8'h15, "READ SUB-CHANNEL, no sub-Q: four bytes, no audio status");
    c10(8'h42, 8'h02, 8'h40, 8'h01, 0, 0, 0, 0, 16, 0);
    check(din.size() == 16 && din[3] == 8'd12 && din[4] == 8'h01 && din[6] == 8'h01, "READ SUB-CHANNEL, current position: 16 bytes");
    c10(8'h47, 0, 0, 0, 2, 0, 0, 3, 0, 0);
    check(st_byte == 8'h02, "PLAY AUDIO MSF: CHECK");
    get_sense(18);
    check(sense_is(4'h5, 8'h64), "... 64 illegal mode for this track");
    c10(8'h4b, 0, 0, 0, 0, 0, 0, 0, 1, 0);
    get_sense(18);
    check(sense_is(4'h5, 8'h2c), "PAUSE/RESUME: command sequence error");
    c10(8'h4e, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    check(st_byte == 8'h00, "STOP PLAY: GOOD");
    c6(8'h1b, 0, 0, 0, 2, 0);
    check(st_byte == 8'h00, "STOP UNIT with eject: GOOD");
    c6(8'h1e, 0, 0, 0, 0, 0);
    check(st_byte == 8'h00, "ALLOW MEDIUM REMOVAL: GOOD");
    c6(8'h0b, 0, 0, 8'h10, 0, 0);
    check(st_byte == 8'h00, "SEEK(6): GOOD");
    c6(8'h01, 0, 0, 0, 0, 0);
    check(st_byte == 8'h00, "REZERO: GOOD");
    c6(8'h0a, 0, 0, 0, 1, 0);
    check(st_byte == 8'h02 && nout_taken == 0, "WRITE(6): CHECK, and no DATA OUT asked for");
    get_sense(18);
    check(sense_is(4'h5, 8'h20), "... invalid command");
    c10(8'h2a, 0, 0, 0, 0, 0, 0, 0, 1, 0);
    check(st_byte == 8'h02 && ncdb_taken == 10 && nout_taken == 0, "WRITE(10): ten CDB bytes taken, CHECK");
    c10(8'hc9, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    check(st_byte == 8'h02 && ncdb_taken == 10, "Sony's PLAYBACK CONTROL (C9): ten bytes taken, refused");
    c6(8'h00, 8'h20, 0, 0, 0, 0);
    check(st_byte == 8'h02, "TEST UNIT READY of LUN 1: CHECK");
    get_sense(18);
    check(sense_is(4'h5, 8'h25), "... 25 LUN not supported");

    // ---- a medium error, and a slow back end ----------------------------------------
    err_lba = 32'd42;
    read6(40, 4);
    check(st_byte == 8'h02 && din.size() == 2 * 512 && blocks_are(din, 0, 40, 2),
          "a bad block: the good ones before it, then CHECK");
    get_sense(18);
    check(sense_is(4'h3, 8'h11) && sense[0] == 8'hF0 && {sense[3], sense[4], sense[5], sense[6]} == 42,
          "... MEDIUM ERROR, 11 unrecovered read error, at block 42");
    read6(42, 2);
    check(st_byte == 8'h02 && din.size() == 0 && !timed_out, "a READ that starts at the bad block: CHECK, nothing moved");
    get_sense(18);
    check(sense_is(4'h3, 8'h11) && {sense[3], sense[4], sense[5], sense[6]} == 42, "... MEDIUM ERROR at block 42");
    err_lba = 32'hFFFFFFFF;
    latency = 3000;
    read10(200, 12);
    check(t_asked.exists(201) && t_asked[201] < t_first,
          "the read-ahead: block 201 asked for before the bus has finished block 200");
    check(st_byte == 8'h00 && blocks_are(din, 0, 200, 12), "READ(10) of 12 blocks with a slow back end: in order");
    latency = 5;
    read10(300, 12);
    check(st_byte == 8'h00 && blocks_are(din, 0, 300, 12), "... and a fast one");
    latency = 150;
    check(starts_while_busy == 0, "no block asked for while the back end was busy");

    // A bus reset in the middle of a read, its next block in flight.
    latency = 4000;
    cdb6(c, 8'h08, 0, 0, 8'd10, 8'd3, 0);
    cmd(c, -1, 512);
    latency = 150;
    read6(20, 2);
    check(st_byte == 8'h00 && !timed_out && blocks_are(din, 0, 20, 2),
          "after a bus reset mid-READ: the next READ gets its own blocks");

    // ---- the disc taken out -------------------------------------------------------
    mount(0);
    c6(8'h00, 0, 0, 0, 0, 0);
    check(st_byte == 8'h02, "disc removed: TEST UNIT READY CHECK");
    get_sense(18);
    check(sense_is(4'h2, 8'h3a), "... NOT READY / 3A, not a UNIT ATTENTION");

    $display("tb_cdrom: %0d checks, %0d failed, %0d block fetches", passes + fails, fails, fetches);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

initial begin
    #2_000_000_000;
    $display("FAIL: tb_cdrom timed out");
    $finish;
end

endmodule
