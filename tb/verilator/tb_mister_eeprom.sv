//============================================================================
//  tb_mister_eeprom -- rtl/sun3_mister_eeprom.sv and rtl/sun3/eeprom.v as
//  Sun-3.sv joins them: the EEPROM's first port is the CPU's (20 MHz, a
//  model here), its second the saver's block buffer, and a model of hps_io's
//  virtual-disk port (100 MHz) serves the image, sequenced as sys/hps_io.sv
//  does it (tb_mister_block.sv has the details).  Like Main_MiSTer, the model
//  serves no block before boot0.rom is in.
//
//  Checked: with no image the machine waits for boot0.rom and for nothing
//  else, and hps_io is never asked; a 2048-byte image is all in the EEPROM
//  when `ready' rises, and is not written back; an all-zero image keeps what
//  the EEPROM holds (the built-in layout) and is given it at once; the
//  machine's writes reach the image in one save, QUIET after the last of a
//  burst, whether WR lasts one clock or two; a write during a save is saved
//  by another; a read-only image is never written; other sizes and an
//  unmount disconnect the image; a load the HPS never serves is given up on
//  WAIT after boot0.rom; a mount while the machine runs loads there and
//  then; every request is down before its transfer ends.
//
//      make -C tb/verilator tb_mister_eeprom
//============================================================================
`timescale 1ps/1ps

module tb_mister_eeprom;

localparam int QUIET_MS = 1, WAIT_MS = 4;
localparam int QUIET = 100_000, WAIT = 400_000;     // the same, in clk_hps clocks

reg clk = 0, clk_hps = 0;
always #25000 clk     = ~clk;               // 20 MHz, the CPU
always #5000  clk_hps = ~clk_hps;           // 100 MHz, hps_io

// ---- DUT --------------------------------------------------------------------------
reg         rst = 1, rom_loaded = 0;
reg         img_mounted = 0, img_readonly = 0;
reg  [63:0] img_size = 0;
wire [31:0] sd_lba;
wire        sd_rd, sd_wr;
reg         sd_ack = 0;
reg  [8:0]  sd_buff_addr = 0;
reg  [7:0]  sd_buff_dout = 0;
wire [7:0]  sd_buff_din;
reg         sd_buff_wr = 0;
wire [10:0] ee_addr;
wire        ee_we, ee_wr_tgl, ready;
wire [7:0]  ee_wdata, ee_rdata;

sun3_mister_eeprom #(.CLK_HZ(100_000_000), .QUIET_MS(QUIET_MS), .WAIT_MS(WAIT_MS)) dut (
    .clk(clk_hps), .rst(rst),
    .img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
    .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
    .sd_buff_wr(sd_buff_wr),
    .ee_addr(ee_addr), .ee_we(ee_we), .ee_wdata(ee_wdata), .ee_rdata(ee_rdata),
    .ee_wr_tgl(ee_wr_tgl), .rom_loaded(rom_loaded), .ready(ready)
);

reg  [10:0] idx = 0;
reg         wr = 0;
reg  [7:0]  din = 0;
wire [7:0]  dout;

eeprom ee (
    .CLK(clk), .idx(idx), .WR(wr), .din(din), .dout(dout),
    .save_clk(clk_hps), .save_addr(ee_addr), .save_we(ee_we), .save_wdata(ee_wdata),
    .save_rdata(ee_rdata), .save_wr_tgl(ee_wr_tgl)
);

integer passes = 0, fails = 0;
task check(input bit ok, input string what);
    begin
        if (ok) passes = passes + 1;
        else begin fails = fails + 1; $display("FAIL  %s", what); end
    end
endtask

// ---- the CPU's port ---------------------------------------------------------------
task automatic cpu_write(input int a, input bit [7:0] v, input int clocks = 1);
    begin
        @(negedge clk);
        idx = 11'(a); din = v; wr = 1;
        repeat (clocks) @(negedge clk);
        wr = 0;
        repeat (3) @(negedge clk);
    end
endtask

task automatic cpu_read(input int a, output bit [7:0] v);
    begin
        @(negedge clk);
        idx = 11'(a);
        @(negedge clk);
        v = dout;
    end
endtask

// ---- hps_io and the image -----------------------------------------------------------
bit [7:0] image [2048];
integer   hps_reads = 0, hps_writes = 0, req_left_up = 0;
bit       stall = 0;                        // the HPS answers nothing
bit       img_readonly_now = 0;             // the file is read only: a write leaves it as it is
longint   img_sizes [2] = '{4096, 512};     // sizes that are not an EEPROM
integer   cur_blk = -1;                     // the block being written, while it is
integer   clocks = 0;                       // clk_hps clocks since the start
integer   last_save_start = 0;              // the clock the last write request was seen
int unsigned hseed = 32'h5EED1234;
function automatic int hrnd(input int lo, input int hi);
    hseed = hseed * 32'd1664525 + 32'd1013904223;
    hrnd = lo + int'(hseed % (hi - lo + 1));
endfunction

always @(posedge clk_hps) clocks <= clocks + 1;

initial begin : hps
    forever begin
        @(posedge clk_hps);
        if ((sd_rd || sd_wr) && rom_loaded && !stall) begin
            bit rd;
            int b;
            rd = sd_rd;
            b  = int'(sd_lba);
            if (!rd) last_save_start = clocks;
            repeat (hrnd(20, 300)) @(posedge clk_hps);     // the HPS notices
            sd_ack <= 1;
            sd_buff_addr <= 0;
            if (!rd) cur_blk = b;
            for (int i = 0; i < 512; i++) begin
                repeat (hrnd(4, 9)) @(posedge clk_hps);    // the next bus strobe
                if (rd) begin
                    sd_buff_dout <= image[b*512 + i];
                    @(posedge clk_hps); sd_buff_wr <= 1;
                    @(posedge clk_hps); sd_buff_wr <= 0;
                    @(posedge clk_hps); if (i != 511) sd_buff_addr <= sd_buff_addr + 1;
                end else begin
                    if (!img_readonly_now) image[b*512 + i] = sd_buff_din;
                    if (i != 511) sd_buff_addr <= sd_buff_addr + 1;
                end
            end
            repeat (3) @(posedge clk_hps);
            if (sd_rd || sd_wr) req_left_up = req_left_up + 1;
            sd_ack <= 0;
            cur_blk = -1;
            if (rd) hps_reads = hps_reads + 1; else hps_writes = hps_writes + 1;
        end
    end
end

task automatic mount(input longint bytes, input bit ro);
    begin
        @(posedge clk_hps);
        img_size <= 64'(bytes);
        img_readonly <= ro;
        img_readonly_now = ro;
        @(posedge clk_hps);
        img_mounted <= 1;
        repeat (8) @(posedge clk_hps);              // hps_io holds it for the command
        img_mounted <= 0;
        @(posedge clk_hps);
    end
endtask

// The core loaded afresh: the saver from its reset, boot0.rom not yet in.
task automatic restart();
    begin
        while (sd_ack) @(posedge clk_hps);
        rst = 1; rom_loaded = 0; stall = 0;
        repeat (10) @(posedge clk_hps);
        rst = 0;
        repeat (10) @(posedge clk_hps);
    end
endtask

task automatic hps_wait(input int n);
    repeat (n) @(posedge clk_hps);
endtask

// Waits up to `max' clocks for `ready'.
task automatic wait_ready(input int max);
    for (int k = 0; k < max && !ready; k++) @(posedge clk_hps);
endtask

task automatic wait_writes(input int n, input int max);
    for (int k = 0; k < max && hps_writes < n; k++) @(posedge clk_hps);
    while (sd_ack) @(posedge clk_hps);
endtask

task automatic wait_reads(input int n, input int max);
    for (int k = 0; k < max && hps_reads < n; k++) @(posedge clk_hps);
endtask

function automatic int ram_vs_image();
    int bad = 0;
    for (int i = 0; i < 2048; i++) if (ee.sram[i] != image[i]) bad++;
    return bad;
endfunction

bit [7:0] snap [2048];
task automatic snapshot();
    for (int i = 0; i < 2048; i++) snap[i] = ee.sram[i];
endtask
function automatic int ram_vs_snap();
    int bad = 0;
    for (int i = 0; i < 2048; i++) if (ee.sram[i] != snap[i]) bad++;
    return bad;
endfunction

task automatic fill_image(input int seed);
    for (int i = 0; i < 2048; i++) image[i] = 8'((seed * 41 + i * 13 + (i >> 5)) ^ (i >> 8));
endtask

bit [7:0] v;
integer   w0, r0, t0;

initial begin
    $display("tb_mister_eeprom: sun3_mister_eeprom and eeprom.v against an hps_io model");

    // ---- no image ----------------------------------------------------------------
    restart();
    hps_wait(2000);
    check(!ready, "no image, no boot0.rom: the machine waits");
    rom_loaded = 1;
    hps_wait(10);
    check(ready, "no image: ready as soon as boot0.rom is in");
    cpu_read('h014, v);  check(v == 8'd24, $sformatf("built-in: 0x014 is %0d MiB, expected 24", v));
    cpu_read('h019, v);  check(v == "s", "built-in: boot device s.");
    cpu_read('h01a, v);  check(v == "d", "built-in: boot device .d");
    cpu_read('h0b8, v);  check(v == 8'hAA, $sformatf("built-in: test pattern byte 0x0B8 is %02x, expected AA", v));
    cpu_read('h0b9, v);  check(v == 8'h55, $sformatf("built-in: test pattern byte 0x0B9 is %02x, expected 55", v));
    cpu_write('h100, 8'h5A);
    cpu_read('h100, v);  check(v == 8'h5A, "the CPU's port reads back its write");
    hps_wait(2 * QUIET);
    check(hps_reads == 0 && hps_writes == 0,
          $sformatf("no image: hps_io asked %0d reads, %0d writes", hps_reads, hps_writes));

    // ---- a new file, all zero -----------------------------------------------------
    restart();
    snapshot();
    for (int i = 0; i < 2048; i++) image[i] = 8'h00;
    mount(2048, 0);
    hps_wait(1000);
    check(!ready, "a new file mounted, boot0.rom not in: the machine waits");
    rom_loaded = 1;
    t0 = clocks;
    wait_ready(WAIT / 2);
    check(ready, "a new file: ready after its first pass");
    check(hps_reads == 4, $sformatf("a new file: %0d reads, expected the 4 of one pass", hps_reads));
    check(ram_vs_snap() == 0, $sformatf("a new file: %0d EEPROM bytes changed", ram_vs_snap()));
    wait_writes(4, QUIET);
    check(hps_writes == 4 && clocks - t0 < QUIET,
          $sformatf("a new file: %0d blocks written, %0d clocks after boot0.rom (at once: < %0d)",
                    hps_writes, clocks - t0, QUIET));
    check(ram_vs_image() == 0, $sformatf("a new file: %0d bytes differ from the EEPROM", ram_vs_image()));

    // ---- the machine's writes -----------------------------------------------------
    w0 = hps_writes;
    cpu_write('h019, "s");
    hps_wait(20_000);
    cpu_write('h01a, "t", 2);                       // WR held for two clocks
    hps_wait(20_000);
    cpu_write('h01e, 8'h01);
    t0 = clocks;
    hps_wait(QUIET * 8 / 10);
    check(hps_writes == w0 && image['h01a] == "d", "the machine's writes: nothing saved before QUIET");
    wait_writes(w0 + 4, QUIET);
    check(hps_writes == w0 + 4, $sformatf("the machine's writes: %0d blocks saved, expected 4", hps_writes - w0));
    check(last_save_start - t0 >= QUIET,
          $sformatf("the save began %0d clocks after the last write, before QUIET (%0d)", last_save_start - t0, QUIET));
    check(image['h019] == "s" && image['h01a] == "t" && image['h01e] == 8'h01,
          $sformatf("the machine's writes in the file: %02x %02x %02x", image['h019], image['h01a], image['h01e]));
    check(ram_vs_image() == 0, $sformatf("after the save, %0d bytes differ", ram_vs_image()));
    hps_wait(2 * QUIET);
    check(hps_writes == w0 + 4, "a burst of writes is one save");

    // ---- a write during a save -----------------------------------------------------
    w0 = hps_writes;
    cpu_write('h030, 8'h11);
    while (cur_blk != 2) @(posedge clk_hps);        // block 0 is written already
    cpu_write('h031, 8'h22);
    wait_writes(w0 + 8, 3 * QUIET);
    check(image['h030] == 8'h11 && image['h031] == 8'h22,
          $sformatf("a write during a save: the file has %02x %02x", image['h030], image['h031]));
    check(hps_writes == w0 + 8, $sformatf("a write during a save: %0d blocks saved, expected 8", hps_writes - w0));

    // ---- an image ---------------------------------------------------------------------
    restart();
    fill_image(1);
    r0 = hps_reads; w0 = hps_writes;
    mount(2048, 0);
    hps_wait(2000);
    check(!ready, "an image mounted, boot0.rom not in: the machine waits");
    rom_loaded = 1;
    wait_ready(WAIT / 2);
    check(ready, "an image: ready after its load");
    check(ram_vs_image() == 0, $sformatf("an image: %0d bytes not loaded when ready rose", ram_vs_image()));
    check(hps_reads - r0 == 8, $sformatf("an image: %0d reads, expected 8 (two passes)", hps_reads - r0));
    cpu_read('h123, v);  check(v == image['h123], "an image: the CPU reads it");
    hps_wait(2 * QUIET);
    check(hps_writes == w0, "an image: a load is not written back");

    // ---- a mount while the machine runs ----------------------------------------------
    fill_image(2);
    r0 = hps_reads;
    mount(2048, 0);
    wait_reads(r0 + 8, WAIT);
    hps_wait(100);
    check(ready && ram_vs_image() == 0,
          $sformatf("mounted while running: ready %0d, %0d bytes not loaded", ready, ram_vs_image()));

    // ---- read only ------------------------------------------------------------------
    fill_image(3);
    r0 = hps_reads; w0 = hps_writes;
    mount(2048, 1);
    wait_reads(r0 + 8, WAIT);
    hps_wait(100);
    check(ram_vs_image() == 0, "read only: loaded");
    cpu_write('h040, ~image['h040]);
    hps_wait(3 * QUIET);
    check(hps_writes == w0, $sformatf("read only: %0d blocks written", hps_writes - w0));

    for (int i = 0; i < 2048; i++) image[i] = 8'h00;
    snapshot();
    r0 = hps_reads;
    mount(2048, 1);
    wait_reads(r0 + 4, WAIT);
    hps_wait(3 * QUIET);
    check(hps_writes == w0 && ram_vs_snap() == 0,
          $sformatf("read only and new: %0d blocks written, %0d bytes changed", hps_writes - w0, ram_vs_snap()));

    // ---- other sizes, and none ------------------------------------------------------
    foreach (img_sizes[k]) begin
        fill_image(4 + k);
        snapshot();
        r0 = hps_reads; w0 = hps_writes;
        mount(img_sizes[k], 0);
        hps_wait(QUIET);
        cpu_write('h050, 8'h77 + 8'(k));
        hps_wait(3 * QUIET);
        check(hps_reads == r0 && hps_writes == w0,
              $sformatf("a %0d-byte image: %0d reads, %0d writes", img_sizes[k], hps_reads - r0, hps_writes - w0));
        check(ee.sram['h050] == 8'h77 + 8'(k), "the EEPROM works on without an image");
    end

    fill_image(9);
    r0 = hps_reads;
    mount(2048, 0);
    wait_reads(r0 + 8, WAIT);
    hps_wait(100);
    w0 = hps_writes;
    mount(0, 0);
    cpu_write('h060, 8'h99);
    hps_wait(3 * QUIET);
    check(hps_writes == w0 && image['h060] != 8'h99, "unmounted: nothing written");

    // ---- a load never served --------------------------------------------------------
    restart();
    fill_image(10);
    stall = 1;
    mount(2048, 0);
    rom_loaded = 1;
    t0 = clocks;
    hps_wait(WAIT * 9 / 10);
    check(!ready, "a load not served: the machine waits");
    wait_ready(WAIT / 5);
    check(ready && clocks - t0 >= WAIT,
          $sformatf("a load not served: ready %0d after %0d clocks (WAIT %0d)", ready, clocks - t0, WAIT));
    r0 = hps_reads;
    stall = 0;
    wait_reads(r0 + 8, WAIT);
    hps_wait(100);
    check(ram_vs_image() == 0, "a load served late lands all the same");

    check(req_left_up == 0, $sformatf("sd_rd/sd_wr still up at the end of %0d transfers", req_left_up));

    $display("");
    $display("tb_mister_eeprom: %0d checks, %0d failed (%0d hps reads, %0d writes)",
             passes + fails, fails, hps_reads, hps_writes);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

initial begin
    #(64'd2_000_000_000_000);
    $display("FAIL  timeout");
    $finish;
end

endmodule
