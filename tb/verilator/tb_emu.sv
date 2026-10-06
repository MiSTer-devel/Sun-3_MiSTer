//============================================================================
//  tb_emu -- the whole MiSTer core as sys_top sees it: Sun-3.sv's emu module
//  with its real SDRAM controller, disk bridge and boot PROM loader.  Only the
//  framework is stood in for: tb/verilator/pll_stub.sv for the PLLs,
//  tb/verilator/hps_io_model.sv for hps_io, and sdram_model.sv for the SDRAM
//  chip on the board.  (After Sun-2_MiSTer's.)
//
//  What it records:
//    screen_<frame>.ppm   each time the picture changes, the 1160x904 raster
//                         as a 24-bit colour image
//    console.log          anything on the serial port (ttya), 9600 8N1
//    the log              the PROM's diagnostic LEDs as they change, every bus
//                         error with its time, a heartbeat, the cache's counts,
//                         and each Ethernet frame the machine puts in the
//                         network's DDR3 mailbox (Network eth0, the default)
//
//  Plusargs (and hps_io_model.sv's): +timeout_ms=<ms> (default 3000),
//  +heartbeat_ms=<ms> (default 100), +screen_ms=<ms>: write a changed screen
//  at most this often (default 200; a frame is 3 MB, and a PROM drawing
//  text changes nearly every one), +stop_on=<text>: end the run soon after
//  the console has printed <text> (`_' stands for a space: plusargs cannot
//  carry one), e.g. +stop_on=> for the monitor's prompt, +screen_stats: the
//  CPU's cycles to each screen plane with every heartbeat (they are always
//  printed at the end).  +status=1000 takes the colour board out;
//  +eeprom_boot=st auto-boots from the tape (rtl/sun3/eeprom.v).
//
//  For chasing a fault: +watch=<hex> / +watch2=<hex> log every CPU and
//  Wishbone cycle to 16 bytes of main memory; +pctrace_from=<ms>
//  +pctrace_to=<ms> write each decoded instruction's address and first word
//  to pctrace.txt; +memdump=<hex> +memdump_len=<hex> write main memory to
//  memdump.bin at the end.  The tape's own trace is +trace_tape, the cg4's
//  +trace_cg4, the SCSI bus's +trace_scsi (sun3_si.sv), and hps_io_model's
//  +trace_vd logs every block of every virtual drive.
//
//      make -C tb/verilator tb_emu
//============================================================================
`timescale 1ps/1ps

module tb_emu;

`include "emu_wires.vh"

// ---- what the board and the framework supply -------------------------------
reg clk50 = 1'b0;
always #10000 clk50 = ~clk50;
assign CLK_50M = clk50;

reg rst = 1'b1;
assign RESET = rst;
initial #500_000 rst = 1'b0;

reg clk_audio = 1'b0;
always #20345 clk_audio = ~clk_audio;           // 24.576 MHz
assign CLK_AUDIO = clk_audio;

assign HDMI_WIDTH       = 12'd1920;
assign HDMI_HEIGHT      = 12'd1080;
assign SD_MISO          = 1'b1;
assign SD_CD            = 1'b1;
assign UART_CTS         = 1'b0;
assign UART_RXD         = 1'b1;
assign UART_DSR         = 1'b0;
assign USER_IN          = 7'h7F;
assign OSD_STATUS       = 1'b0;

emu dut (.*);

sdram_model chip (
    .clk(SDRAM_CLK), .cke(SDRAM_CKE), .nCS(SDRAM_nCS),
    .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE),
    .ba(SDRAM_BA), .a(SDRAM_A), .dqmh(SDRAM_DQMH), .dqml(SDRAM_DQML),
    .dq(SDRAM_DQ)
);

// ---- DDR3: the network's mailbox, and what is sent through it ------------------------
// The 64 KiB window at 0x1FF00000, answering a read two clocks after it is
// taken.  The bench plays the transmit half of Main's daemon: a frame posted
// is logged, with its addresses and type, and taken (TX_RPTR follows, or the
// ring would fill and hold the LANCE); nothing is ever delivered.  (After
// Sun-2_MiSTer's.)
localparam [28:0] DDR_BASE = 29'h03FE0000;
reg  [63:0] ddr [0:8191];
reg  [63:0] ddr_q = 64'd0;
reg  [1:0]  ddr_rd_pipe = 2'b00;
reg  [12:0] ddr_rd_addr = 13'd0;
initial for (int i = 0; i < 8192; i++) ddr[i] = 64'd0;
assign DDRAM_BUSY       = 1'b0;
assign DDRAM_DOUT       = ddr_q;
assign DDRAM_DOUT_READY = ddr_rd_pipe[1];
always @(posedge DDRAM_CLK) begin
    ddr_rd_pipe <= {ddr_rd_pipe[0], 1'b0};
    if ((DDRAM_RD || DDRAM_WE) && (DDRAM_ADDR < DDR_BASE || DDRAM_ADDR >= DDR_BASE + 8192))
        $display("[%0t] ddr: access outside the mailbox at %h", $time, DDRAM_ADDR);
    else if (DDRAM_WE) ddr[DDRAM_ADDR - DDR_BASE] <= DDRAM_DIN;
    else if (DDRAM_RD) begin
        ddr_rd_addr    <= DDRAM_ADDR - DDR_BASE;
        ddr_rd_pipe[0] <= 1'b1;
    end
    if (ddr_rd_pipe[0]) ddr_q <= ddr[ddr_rd_addr];
end

// The layout is rtl/sun3_mister_enet.sv's: MAGIC, GEN, TX_WPTR, TX_RPTR, ...,
// the MAC in word 6, the TX ring of eight at 0x1000.
function automatic [7:0] tx_byte(input int slot, input int i);
    int o = 'h1000 + 'h800 * slot + 8 + i;
    tx_byte = ddr[o / 8][(o % 8) * 8 +: 8];
endfunction

longint unsigned tx_taken = 0, magic_seen = 0, gen_seen = 0;
always @(posedge DDRAM_CLK) begin
    if (ddr[0] != magic_seen || (ddr[0] != 0 && ddr[1] != gen_seen)) begin
        magic_seen = ddr[0];
        gen_seen   = ddr[1];
        $display("[%0t] ether: mailbox magic %h, generation %h, MAC %h", $time, ddr[0], ddr[1], ddr[6]);
    end
    if (ddr[0] == 0) tx_taken = 0;
    else if (ddr[2] != tx_taken && ddr[2] - ddr[3] <= 8) begin
        int slot = int'(tx_taken % 8);
        int n    = int'(ddr[('h1000 + 'h800 * slot) / 8] & 64'h7FF);
        string d = "";
        for (int i = 0; i < 6; i++) d = {d, $sformatf("%s%02x", i ? ":" : "", tx_byte(slot, i))};
        d = {d, " <- "};
        for (int i = 6; i < 12; i++) d = {d, $sformatf("%s%02x", i > 6 ? ":" : "", tx_byte(slot, i))};
        $display("[%0t] ether: frame %0d out, %0d bytes, %s, type %02x%02x", $time, tx_taken + 1, n, d,
                 tx_byte(slot, 12), tx_byte(slot, 13));
        tx_taken = tx_taken + 1;
        ddr[3]   = tx_taken;
    end
end

// ---- the screen ----------------------------------------------------------------
localparam int W = 1160, H = 904;
reg  [23:0] frame [0:W*H-1];
integer     fx = 0, fy = 0, frames = 0, shots = 0;
reg         de_d = 1'b0, vs_d = 1'b1;
reg  [31:0] sum = 32'd0, last_sum = 32'hFFFFFFFF;
real        screen_ms = 200.0;
realtime    last_shot = -1.0e18;
initial if (!$value$plusargs("screen_ms=%f", screen_ms)) screen_ms = 200.0;

task automatic dump_frame(input integer n);
    integer fd;
    string  name;
    begin
        name = $sformatf("screen_%05d.ppm", n);
        fd = $fopen(name, "wb");
        $fwrite(fd, "P6\n%0d %0d\n255\n", W, H);
        for (int i = 0; i < W*H; i++)
            $fwrite(fd, "%c%c%c", frame[i][23:16], frame[i][15:8], frame[i][7:0]);
        $fclose(fd);
        $display("[%0t] frame %0d changed: %s", $time, n, name);
    end
endtask

always @(posedge CLK_VIDEO) if (CE_PIXEL) begin
    de_d <= VGA_DE;
    vs_d <= VGA_VS;
    if (VGA_DE) begin
        if (fx < W && fy < H) frame[fy*W + fx] <= {VGA_R, VGA_G, VGA_B};
        sum <= {sum[30:0], sum[31]} ^ {8'd0, VGA_R, VGA_G, VGA_B} ^ 32'(fx);
        fx  <= fx + 1;
    end else if (de_d) begin
        fx <= 0;
        fy <= fy + 1;
    end
    if (vs_d && !VGA_VS) begin                  // the start of vertical sync
        frames <= frames + 1;
        if (fy == H && sum != last_sum && $realtime - last_shot >= screen_ms * 1.0e9) begin
            dump_frame(frames);                 // a whole frame, a new picture, not too soon
            last_sum  <= sum;
            last_shot = $realtime;
            shots     <= shots + 1;
        end
        fy  <= 0;
        fx  <= 0;
        sum <= 32'd0;
    end
end

// ---- the serial port: 9600 8N1 ----------------------------------------------------
integer con_fd;
string  con_tail = "";
string  stop_on  = "";
bit     stopping = 0;
initial begin
    con_fd = $fopen("console.log", "w");
    if ($value$plusargs("stop_on=%s", stop_on))
        for (int i = 0; i < stop_on.len(); i++) if (stop_on[i] == "_") stop_on[i] = " ";
end

initial begin : uart
    localparam longint BIT = 104_166_667;       // ps
    bit [7:0] b;
    forever begin
        @(negedge UART_TXD);
        #(BIT / 2);
        if (UART_TXD == 1'b0) begin
            for (int i = 0; i < 8; i++) begin #BIT; b[i] = UART_TXD; end
            #BIT;
            $fwrite(con_fd, "%c", b); $fflush(con_fd);
            if (b == 8'h0A) $display("[%0t] console: line", $time);
            if (stop_on.len() > 0 && !stopping) begin
                con_tail = {con_tail, string'(b)};
                if (con_tail.len() > 64) con_tail = con_tail.substr(con_tail.len() - 64, con_tail.len() - 1);
                if (con_tail.len() >= stop_on.len() &&
                    con_tail.substr(con_tail.len() - stop_on.len(), con_tail.len() - 1) == stop_on) begin
                    stopping = 1;
                    $display("[%0t] console printed \"%s\": stopping", $time, stop_on);
                    #(64'd20_000_000_000);      // 20 ms more, for what follows it
                    finish_run("stop_on");
                end
            end
        end
    end
end

// ---- what the machine is doing ------------------------------------------------------
always @(dut.diag_leds)
    $display("[%0t] diag_leds = %02x", $time, dut.diag_leds);

integer berrs = 0;
always @(negedge dut.machine.BERRn) begin
    berrs = berrs + 1;
    $display("[%0t] bus error %0d", $time, berrs);
end

always @(LED_USER) $display("[%0t] LED_USER = %0d (machine %s)", $time, LED_USER, LED_USER ? "in reset" : "running");

// The CPU's cycles to the screens, by plane: [0] reads, [1] writes.
integer n_bw2 [0:1] = '{0, 0}, n_ovl [0:1] = '{0, 0}, n_enb [0:1] = '{0, 0}, n_col [0:1] = '{0, 0};
always @(posedge dut.machine.sun3.MATCH_FB) n_bw2[!dut.machine.sun3.SUN3_RW_n] += 1;
always @(posedge dut.machine.sun3.MATCH_CG4MEM)
    case (dut.machine.sun3.ma_pmap2devices[18:7])
        12'hFF4: n_ovl[!dut.machine.sun3.SUN3_RW_n] += 1;
        12'hFF6: n_enb[!dut.machine.sun3.SUN3_RW_n] += 1;
        default: n_col[!dut.machine.sun3.SUN3_RW_n] += 1;
    endcase

initial begin : heartbeat
    real hb;
    if (!$value$plusargs("heartbeat_ms=%f", hb)) hb = 100.0;
    forever begin
        #(longint'(hb * 1.0e9));
        $display("[%0t] %0.0f ms: frames %0d, screens %0d, bus errors %0d, LED_DISK %b",
                 $time, $realtime / 1.0e9, frames, shots, berrs, LED_DISK);
        if ($test$plusargs("screen_stats"))
            $display("[screens] bw2 %0d/%0d, overlay %0d/%0d, enable %0d/%0d, colour %0d/%0d, uncached %0d",
                     n_bw2[0], n_bw2[1], n_ovl[0], n_ovl[1], n_enb[0], n_enb[1], n_col[0], n_col[1],
                     dut.machine.sun3.wbridge.n_uncached);
        $fflush;        // a run is watched while it goes, and its log is usually a file
    end
end

// +watch=<hex> (and +watch2=<hex>): the 16 bytes of main memory at that
// physical address -- every CPU cycle to them as the bridge takes it, and
// every Wishbone cycle for them.
bit [31:0] watch_pa [0:1];
bit        watching [0:1];
initial begin
    watching[0] = $value$plusargs("watch=%h", watch_pa[0]);
    watching[1] = $value$plusargs("watch2=%h", watch_pa[1]);
end
function automatic bit watched(input [31:0] pa);
    return (watching[0] && pa[31:4] == watch_pa[0][31:4]) || (watching[1] && pa[31:4] == watch_pa[1][31:4]);
endfunction
reg w_ack_q = 1'b0;
always @(posedge dut.machine.sun3.wbridge.CLK) begin
    w_ack_q <= dut.machine.sun3.wbridge.W_ACK;
    if (dut.machine.sun3.wbridge.W_ACK && !w_ack_q && dut.machine.sun3.wbridge.MATCH_MEM &&
        watched(dut.machine.sun3.wbridge.P_ADR_IN))
        $display("[%0t] watch: CPU %s %08x, data in %08x out %08x, lanes %b%b%b%b", $time,
                 dut.machine.sun3.wbridge.P_RW_n ? "read " : "write", dut.machine.sun3.wbridge.P_ADR_IN,
                 dut.machine.sun3.wbridge.P_DATA_IN, dut.machine.sun3.wbridge.P_DATA_OUT,
                 dut.machine.sun3.wbridge.EN_UUBYTE, dut.machine.sun3.wbridge.EN_ULBYTE,
                 dut.machine.sun3.wbridge.EN_LUBYTE, dut.machine.sun3.wbridge.EN_LLBYTE);
end
always @(posedge dut.clk_mem)
    if (dut.wb_cyc && dut.wb_stb && dut.wb_ack && watched({dut.wb_adr, 2'b00}))
        $display("[%0t] watch: WB  %s word %08x (byte %08x) data %08x sel %b", $time,
                 dut.wb_we ? "write" : "read ", dut.wb_adr, {dut.wb_adr, 2'b00},
                 dut.wb_we ? dut.wb_dat_m2s : dut.wb_dat_s2m, dut.wb_sel);

// +pctrace_from=<ms> +pctrace_to=<ms>: every instruction the CPU decodes
// between those times, its address and first word, into pctrace.txt.
real pct_from = -1.0, pct_to = -1.0;
int  pct_fd = 0;
reg  pct_dec_q = 1'b0;
reg  [31:0] pct_pc_q = 32'hFFFFFFFF;
initial begin
    if ($value$plusargs("pctrace_from=%f", pct_from)) begin
        if (!$value$plusargs("pctrace_to=%f", pct_to)) pct_to = pct_from + 1.0;
        pct_fd = $fopen("pctrace.txt", "w");
    end
end
always @(posedge dut.cpu_clk)
    if (pct_fd != 0 && $realtime >= pct_from * 1.0e9 && $realtime < pct_to * 1.0e9) begin
        pct_dec_q <= dut.machine.rd68021_cpu.u_seq.at_decode;
        pct_pc_q  <= dut.machine.rd68021_cpu.u_ifu.pc_d;
        if (dut.machine.rd68021_cpu.u_seq.at_decode &&
            (!pct_dec_q || dut.machine.rd68021_cpu.u_ifu.pc_d != pct_pc_q))
            $fwrite(pct_fd, "%0t %08x %04x\n", $time, dut.machine.rd68021_cpu.u_ifu.pc_d,
                    dut.machine.rd68021_cpu.u_ifu.stg_d);
    end

// +memdump=<hex>: main memory from that physical address, +memdump_len=<hex>
// bytes of it (default 64 KiB), into memdump.bin at the end of the run.
// Physical address p is SDRAM word p/2 (rtl/sun3_mister_sdram.sv), and the
// cell is sdram.sv's decode of that.
task automatic dump_memory;
    bit [31:0] a0, n, w;
    bit [15:0] v;
    int fd, k;
    begin
        if ($value$plusargs("memdump=%h", a0)) begin
            if (!$value$plusargs("memdump_len=%h", n)) n = 32'h10000;
            fd = $fopen("memdump.bin", "wb");
            for (bit [31:0] a = a0; a < a0 + n; a += 2) begin
                w = a >> 1;
                k = chip.key(w[23:22], w[21:9], {w[24], w[8:0]});
                v = chip.mem.exists(k) ? chip.mem[k] : chip.POWERUP;
                $fwrite(fd, "%c%c", v[15:8], v[7:0]);
            end
            $fclose(fd);
            $display("memdump.bin: 0x%0x bytes from 0x%08x", n, a0);
        end
    end
endtask

task automatic finish_run(input string why);
    begin
        dump_memory();
        if (fy > 0) dump_frame(frames);          // whatever is on screen now
        $display("[cache] hits %0d, misses %0d, uncached %0d, write hits %0d, fills %0d, refused lookups %0d",
                 dut.machine.sun3.wbridge.n_hit, dut.machine.sun3.wbridge.n_miss,
                 dut.machine.sun3.wbridge.n_uncached, dut.machine.sun3.wbridge.n_whit,
                 dut.machine.sun3.wbridge.n_fill, dut.machine.sun3.wbridge.n_rd_notok);
        $display("[screens] CPU cycles, reads/writes: bw2 %0d/%0d, cg4 overlay %0d/%0d, enable %0d/%0d, colour %0d/%0d",
                 n_bw2[0], n_bw2[1], n_ovl[0], n_ovl[1], n_enb[0], n_enb[1], n_col[0], n_col[1]);
        $display("tb_emu: stopped (%s) at %0.0f ms: %0d frames, %0d screens, %0d bus errors",
                 why, $realtime / 1.0e9, frames, shots, berrs);
        $fclose(con_fd);
        $finish;
    end
endtask

initial begin : finish
    real t;
    if (!$value$plusargs("timeout_ms=%f", t)) t = 3000.0;
    #(longint'(t * 1.0e9));
    finish_run("timeout");
end

endmodule
