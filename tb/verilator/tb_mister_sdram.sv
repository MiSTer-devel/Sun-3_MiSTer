//============================================================================
//  tb_mister_sdram -- rtl/sun3_mister_sdram.sv + rtl/sdram.sv against the
//  behavioural SDR SDRAM in sdram_model.sv.  From Sun-2_MiSTer's bench of its
//  own adapter, with the Sun-3's lanes and map.
//
//  The Wishbone master here behaves as sun3_cached_fifo_bridge does: CYC held
//  until it samples ACK, dropped on that edge, and a new request started on
//  the very next clock.  That back-to-back restart is the timing at which the
//  first-draft adapter ran a request twice and answered the next one with the
//  previous address's data, so every access below is made at it.  The frame
//  buffer reader behaves as fb_scanout does: c_req held for a line, c_addr
//  advanced on the edge it samples c_done.
//
//  Checked: every halfword and byte lane against a shadow; whole 128-bit
//  lines, since the cache installs them (word k of a line at [32k+31:32k],
//  bytes as on the big-endian bus); the in-chip layout (a Wishbone word's
//  bits 31:16 are the even SDRAM word), because a consistent swap would
//  round-trip and still be wrong for fb_scanout; scan-out beats while the CPU
//  is busy; beat counts (no repeats, none lost); and the chip model's own
//  protocol checks and refresh spacing.
//
//  The cg4's window ({8'hFF, PA[23:2]}: colour, overlay, enable) is checked
//  the same way -- every mix of byte selects in each plane, as libpixrect's
//  mem_rop writes them -- its planes' places in the chip, and its scan-out
//  port: a third client that takes turns with the CPU unless it says it is
//  urgent.
//
//  The shadow counts halfwords in address order: halfword 2w is Wishbone word
//  w's bits 31:16, 2w+1 its bits 15:0.  A line's halfword j is therefore at
//  bits [16*(j^1) +: 16].
//
//      make -C tb/verilator tb_mister_sdram
//============================================================================
`timescale 1ps/1ps

module tb_mister_sdram;

localparam integer TH = 5000;                  // 100 MHz
localparam [29:0]  FB_WB_BASE    = 30'h03F80000;
localparam [25:0]  FB_SDRAM_WORD = 26'h0C00000;
localparam [29:0]  MEM_WORDS     = 30'h0600000;    // 24 MiB
localparam [25:0]  CG_COLOR_WORD   = 26'h0C80000;
localparam [25:0]  CG_OVERLAY_WORD = 26'h0D00000;
localparam [25:0]  CG_ENABLE_WORD  = 26'h0D10000;
// the cg4's planes as the bridge puts them on Wishbone: {8'hFF, PA[23:2]}
function automatic [29:0] cgw(input [23:0] pa);
    cgw = {8'hFF, pa[23:2]};
endfunction

reg clk = 0;
always #TH clk = ~clk;
reg init = 1;

// ---- DUT --------------------------------------------------------------------
reg         cyc = 0, we = 0;
reg  [29:0] adr = 0;
reg  [31:0] dat = 0;
reg   [3:0] sel = 0;
wire [31:0] rdat;
wire        ack;
wire [127:0] line;

reg  [27:0] fb_addr = 0;
reg         fb_req  = 0;
wire        fb_done;
wire [127:0] fb_rdata;

reg  [25:0] cs_word = 0;
reg         cs_req  = 0, cs_urgent = 0;
wire        cs_done;
wire [127:0] cs_rdata;

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire        SDRAM_DQML, SDRAM_DQMH;
wire  [1:0] SDRAM_BA;
wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;

sun3_mister_sdram #(.FB_WB_BASE(FB_WB_BASE), .FB_SDRAM_WORD(FB_SDRAM_WORD)) dut (
    .clk(clk), .init(init),
    .wb_cyc_i(cyc), .wb_stb_i(cyc), .wb_adr_i(adr), .wb_dat_i(dat), .wb_sel_i(sel),
    .wb_we_i(we), .wb_dat_o(rdat), .wb_ack_o(ack), .wb_line_o(line),
    .fb_c_addr(fb_addr), .fb_c_req(fb_req), .fb_c_done(fb_done), .fb_c_rdata(fb_rdata),
    .cs_word(cs_word), .cs_req(cs_req), .cs_urgent(cs_urgent), .cs_done(cs_done), .cs_rdata(cs_rdata),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
    .SDRAM_CLK(SDRAM_CLK)
);

sdram_model chip (
    .clk(SDRAM_CLK), .cke(SDRAM_CKE), .nCS(SDRAM_nCS),
    .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE),
    .ba(SDRAM_BA), .a(SDRAM_A), .dqmh(SDRAM_DQMH), .dqml(SDRAM_DQML),
    .dq(SDRAM_DQ)
);

// ---- results -----------------------------------------------------------------
integer passes = 0, fails = 0;
task check(input bit ok, input string what);
    begin
        if (ok) passes = passes + 1;
        else begin
            fails = fails + 1;
            $display("FAIL  %s", what);
        end
    end
endtask

// ---- the bridge-like Wishbone master ---------------------------------------------
reg         req_t = 0, seen_t = 0, done_t = 0;
reg         go_we;
reg  [29:0] go_adr;
reg  [31:0] go_dat;
reg   [3:0] go_sel;
reg  [31:0] res_dat;
reg [127:0] res_line;
integer     wb_acks = 0;

// A stream: reads one after another, each asked as the last is answered,
// cyc never falling.  Their data is not checked; they are traffic.
reg         stream_t = 0, stream_seen = 0, in_stream = 0;
integer     stream_n = 0, stream_left = 0;
reg  [29:0] stream_base = 0, stream_adr = 0;

always @(posedge clk) begin
    if (!cyc && req_t != seen_t) begin
        seen_t <= req_t;
        cyc <= 1; we <= go_we; adr <= go_adr; dat <= go_dat; sel <= go_sel;
    end else if (!cyc && stream_t != stream_seen) begin
        stream_seen <= stream_t;
        stream_left <= stream_n;
        stream_adr  <= stream_base;
    end else if (!cyc && stream_left > 0) begin
        cyc <= 1; we <= 0; adr <= stream_adr; sel <= 4'hF;
        in_stream   <= 1;
        stream_adr  <= stream_adr + 30'd1;
        stream_left <= stream_left - 1;
    end else if (cyc && ack) begin
        res_dat  <= rdat;
        res_line <= line;
        done_t   <= ~done_t;
        wb_acks  <= wb_acks + 1;
        if (in_stream && stream_left > 0) begin
            // the next read at once: cyc stays up, as Wishbone allows
            adr         <= stream_adr;
            stream_adr  <= stream_adr + 30'd1;
            stream_left <= stream_left - 1;
        end else begin
            cyc       <= 0;
            in_stream <= 0;
        end
    end
end

task automatic stream(input [29:0] a, input integer n);
    begin
        @(negedge clk);
        stream_base = a; stream_n = n;
        stream_t = ~stream_t;
    end
endtask

task automatic stream_wait;
    begin
        do @(negedge clk); while (cyc || stream_left > 0 || stream_t != stream_seen);
    end
endtask

task automatic wb(input bit w, input [29:0] a, input [31:0] d, input [3:0] s);
    reg t0;
    begin
        @(negedge clk);
        t0 = done_t;
        go_we = w; go_adr = a; go_dat = d; go_sel = s;
        req_t = ~req_t;
        do @(negedge clk); while (done_t == t0);
    end
endtask

// ---- shadows: halfword index = Wishbone word * 2 + (0 for bits 31:16, 1 for 15:0) ----
bit [15:0] cgm [int];           // the cg4's planes, keyed by SDRAM word
bit  [1:0] cgk [int];
bit [15:0] mm [int];            // main memory
bit [15:0] fbm [int];           // frame buffer aperture, relative halfwords
bit  [1:0] mmk [int], fbk [int]; // which bytes of each are known: [1] high, [0] low

function automatic [15:0] mm_get(input int h);
    mm_get = mm.exists(h) ? mm[h] : 16'h0000;
endfunction

// The SDRAM word of the high half of a cg4-window Wishbone word.
function automatic int cg_sdram(input [29:0] a);
    int base;
    base = (a[21:18] == 4'h8) ? int'(CG_COLOR_WORD) : (a[21:18] == 4'h4) ? int'(CG_OVERLAY_WORD) : int'(CG_ENABLE_WORD);
    cg_sdram = base + int'(a[17:0]) * 2;
endfunction

task automatic shadow_write(input [29:0] a, input [31:0] d, input [3:0] s);
    int h;
    bit [15:0] v;
    bit is_fb;
    begin
        if (a[29:22] == 8'hFF) begin
            h = cg_sdram(a);
            for (int half = 0; half < 2; half++) begin
                int sh;
                sh = 1 - half;
                v = cgm.exists(h + half) ? cgm[h + half] : 16'h0;
                if (s[sh*2 + 1]) v[15:8] = d[sh*16 + 8 +: 8];
                if (s[sh*2])     v[7:0]  = d[sh*16 +: 8];
                if (s[sh*2 +: 2] != 0) begin
                    cgm[h + half] = v;
                    cgk[h + half] = (cgk.exists(h + half) ? cgk[h + half] : 2'b00) | s[sh*2 +: 2];
                end
            end
            return;
        end
        is_fb = (a >= FB_WB_BASE);
        h = is_fb ? int'((a - FB_WB_BASE) * 2) : int'(a * 2);
        for (int half = 0; half < 2; half++) begin
            int sh;
            sh = 1 - half;                       // half 0 is bits 31:16, sel[3:2]
            if (is_fb) v = fbm.exists(h + half) ? fbm[h + half] : 16'h0;
            else       v = mm_get(h + half);
            if (s[sh*2 + 1]) v[15:8] = d[sh*16 + 8 +: 8];
            if (s[sh*2])     v[7:0]  = d[sh*16 +: 8];
            if (s[sh*2 +: 2] != 0) begin
                if (is_fb) begin
                    fbm[h + half] = v;
                    fbk[h + half] = (fbk.exists(h + half) ? fbk[h + half] : 2'b00) | s[sh*2 +: 2];
                end else begin
                    mm[h + half]  = v;
                    mmk[h + half] = (mmk.exists(h + half) ? mmk[h + half] : 2'b00) | s[sh*2 +: 2];
                end
            end
        end
    end
endtask

task automatic wwrite(input [29:0] a, input [31:0] d, input [3:0] s);
    begin
        wb(1, a, d, s);
        shadow_write(a, d, s);
    end
endtask

// Read word a; check the 32-bit answer and the whole line it came with.
// Bytes nothing has written are don't-care: the chip powers up with
// whatever it likes in them (the model says 0x0000).
task automatic wread_check(input [29:0] a, input string what);
    bit [127:0] exp_line, care;
    int base, h;
    bit [1:0] known;
    begin
        wb(0, a, 32'h0, 4'hF);
        base = int'({a[29:2], 2'b00}) * 2;
        for (int k = 0; k < 8; k++) begin
            if (a[29:22] == 8'hFF) begin
                h = cg_sdram({a[29:2], 2'b00}) + k;
                known = cgk.exists(h) ? cgk[h] : 2'b00;
                exp_line[16*(k^1) +: 16] = known ? cgm[h] : 16'h0;
            end else if (a >= FB_WB_BASE) begin
                h = base - int'(FB_WB_BASE * 2) + k;
                known = fbk.exists(h) ? fbk[h] : 2'b00;
                exp_line[16*(k^1) +: 16] = known ? fbm[h] : 16'h0;
            end else begin
                known = mmk.exists(base + k) ? mmk[base + k] : 2'b00;
                exp_line[16*(k^1) +: 16] = mm_get(base + k);
            end
            care[16*(k^1) +: 16] = {{8{known[1]}}, {8{known[0]}}};
        end
        check(((res_dat ^ exp_line[32*a[1:0] +: 32]) & care[32*a[1:0] +: 32]) == 0,
              $sformatf("%s: word 0x%07x read %08x, expected %08x (mask %08x)", what, a, res_dat,
                        exp_line[32*a[1:0] +: 32], care[32*a[1:0] +: 32]));
        check(((res_line ^ exp_line) & care) == 0,
              $sformatf("%s: line of 0x%07x read %032x, expected %032x (mask %032x)", what, a,
                        res_line, exp_line, care));
    end
endtask

// The chip cell holding SDRAM word w, by sdram.sv's own decode.
function automatic [15:0] chip_cell(input [25:0] w);
    int k;
    begin
        k = chip.key(w[23:22], w[21:9], {w[24], w[8:0]});
        chip_cell = chip.mem.exists(k) ? chip.mem[k] : 16'hDEAD;
    end
endfunction

// ---- the fb_scanout-like reader --------------------------------------------------
reg         fb_t = 0, fb_seen = 0;
integer     fb_left = 0, fb_n = 0;
reg  [27:0] fb_start = 0;
reg [127:0] fb_got [0:255];
integer     fb_dones = 0;

always @(posedge clk) begin
    if (!fb_req && fb_t != fb_seen) begin
        fb_seen <= fb_t;
        fb_addr <= fb_start;
        fb_req  <= 1;
        fb_left <= fb_n;
    end else if (fb_req && fb_done) begin
        fb_got[fb_dones] <= fb_rdata;
        fb_dones <= fb_dones + 1;
        fb_addr  <= fb_addr + 28'd8;
        if (fb_left == 1) fb_req <= 0;
        fb_left  <= fb_left - 1;
    end
end

task automatic fb_fetch(input [27:0] start, input integer n);
    begin
        @(negedge clk);
        fb_dones = 0;
        fb_start = start; fb_n = n;
        fb_t = ~fb_t;
    end
endtask

task automatic fb_wait;
    begin
        do @(negedge clk); while (fb_req || fb_t != fb_seen);
    end
endtask

task automatic fb_check(input [27:0] start, input integer n, input string what);
    bit [127:0] e;
    begin
        check(fb_dones == n, $sformatf("%s: %0d beats answered for %0d asked", what, fb_dones, n));
        for (int b = 0; b < n; b++) begin
            for (int k = 0; k < 8; k++) begin
                int q;
                q = int'(start) + b*8 + k;
                e[16*(k^1) +: 16] = fbm.exists(q) ? fbm[q] : 16'h0;
            end
            check(fb_got[b] == e, $sformatf("%s: beat %0d read %032x, expected %032x", what, b, fb_got[b], e));
        end
    end
endtask

// ---- the cg4 scan-out-like reader: bursts at given SDRAM words --------------------
reg         cs_t = 0, cs_seen = 0;
integer     cs_left = 0, cs_n = 0;
reg  [25:0] cs_start = 0;
reg [127:0] cs_got [0:255];
integer     cs_dones = 0;

always @(posedge clk) begin
    if (!cs_req && cs_t != cs_seen) begin
        cs_seen <= cs_t;
        cs_word <= cs_start;
        cs_req  <= 1;
        cs_left <= cs_n;
    end else if (cs_req && cs_done) begin
        cs_got[cs_dones] <= cs_rdata;
        cs_dones <= cs_dones + 1;
        cs_word  <= cs_word + 26'd8;
        if (cs_left == 1) cs_req <= 0;
        cs_left  <= cs_left - 1;
    end
end

// Turns: the longest run of scan-out bursts answered while the CPU waits.
// Polite, it is one -- the CPU's turn comes next; urgent, the scan-out keeps
// the SDRAM until it has its line.
integer cs_run = 0, cs_run_polite = 0, cs_run_urgent = 0;
integer cs_in_stream = 0;           // scan-out bursts answered while a stream runs
always @(posedge clk) begin
    if (cs_done && stream_left > 0) cs_in_stream <= cs_in_stream + 1;
    if (ack || !cyc)
        cs_run <= 0;
    else if (cs_done) begin
        cs_run <= cs_run + 1;
        if (cs_urgent) begin if (cs_run + 1 > cs_run_urgent) cs_run_urgent <= cs_run + 1; end
        else           begin if (cs_run + 1 > cs_run_polite) cs_run_polite <= cs_run + 1; end
    end
end

task automatic cs_fetch(input [25:0] start, input integer n, input bit urgent);
    begin
        @(negedge clk);
        cs_dones = 0;
        cs_start = start; cs_n = n; cs_urgent = urgent;
        cs_t = ~cs_t;
    end
endtask

task automatic cs_wait;
    begin
        do @(negedge clk); while (cs_req || cs_t != cs_seen);
    end
endtask

task automatic cs_check(input [25:0] start, input integer n, input string what);
    bit [127:0] e, care;
    bit [1:0] known;
    begin
        check(cs_dones == n, $sformatf("%s: %0d bursts answered for %0d asked", what, cs_dones, n));
        for (int b = 0; b < n; b++) begin
            for (int k = 0; k < 8; k++) begin
                int q;
                q = int'(start) + b*8 + k;
                e[16*(k^1) +: 16] = cgm.exists(q) ? cgm[q] : 16'h0;
                known = cgk.exists(q) ? cgk[q] : 2'b00;
                care[16*(k^1) +: 16] = {{8{known[1]}}, {8{known[0]}}};
            end
            check(((cs_got[b] ^ e) & care) == 0,
                  $sformatf("%s: burst %0d read %032x, expected %032x (mask %032x)", what, b, cs_got[b], e, care));
        end
    end
endtask

// ---- the sequence --------------------------------------------------------------
int unsigned seed = 32'h5EED_0001;
function automatic [31:0] rnd;
    seed = seed * 32'd1664525 + 32'd1013904223;
    rnd = seed;
endfunction

initial begin
    $display("tb_mister_sdram: sun3_mister_sdram + sdram.sv against a chip model");
    repeat (4) @(posedge clk);
    init <= 0;
    repeat (13000) @(posedge clk);       // the controller's ~12100-clock power-up

    check(chip.mode_set, "the mode register was loaded");
    check(chip.cl == 3'd2 && chip.bl == 8, "CAS latency 2, burst length 8");

    // 1. halfwords, each half separately, then whole longwords as the 68020
    //    writes them
    for (int i = 0; i < 64; i++) begin
        wwrite(30'h0000100 + i, (32'hA000 + i) << 16,           4'b1100);
        wwrite(30'h0000100 + i, 32'h0000_0000 | (16'hB000 + i), 4'b0011);
    end
    for (int i = 0; i < 64; i++) wread_check(30'h0000100 + i, "halfwords");
    for (int i = 0; i < 64; i++) wwrite(30'h0000200 + i, {16'hC000 + 16'(i), 16'hD000 + 16'(i)}, 4'b1111);
    for (int i = 0; i < 64; i++) wread_check(30'h0000200 + i, "longwords");

    // 2. the in-chip layout: a word's bits 31:16 (A1=0 on the 68020's bus)
    //    are the even SDRAM word
    check(chip_cell(26'h0000200) == 16'hA000, "Wishbone word 0x100, bits 31:16, is SDRAM word 0x200");
    check(chip_cell(26'h0000201) == 16'hB000, "Wishbone word 0x100, bits 15:0, is SDRAM word 0x201");
    check(chip_cell(26'h0000207) == 16'hB003, "Wishbone word 0x103, bits 15:0, is SDRAM word 0x207");
    check(chip_cell(26'h0000400) == 16'hC000, "Wishbone word 0x200, a longword's bits 31:16, is SDRAM word 0x400");

    // 3. byte lanes merge
    wwrite(30'h0000100, 32'h0000_00C1, 4'b0001);
    wwrite(30'h0000100, 32'h0000_C200, 4'b0010);
    wwrite(30'h0000101, 32'h00C3_0000, 4'b0100);
    wwrite(30'h0000101, 32'hC400_0000, 4'b1000);
    wread_check(30'h0000100, "byte lanes");
    wread_check(30'h0000101, "byte lanes");
    // every mix of byte selects, each over a word whose four bytes are known,
    // so a byte written that was not selected shows
    for (int m = 1; m < 16; m++) begin
        wwrite(30'h0000180 + m, 32'h5A5A_5A5A, 4'b1111);
        wwrite(30'h0000180 + m, 32'h0102_0304 * m, 4'(m));
        wread_check(30'h0000180 + m, $sformatf("byte selects %b", 4'(m)));
    end
    // a write with no lane selected changes nothing and is still answered
    wwrite(30'h0000100, 32'hFFFF_FFFF, 4'b0000);
    wread_check(30'h0000100, "empty write");

    // 4. row and bank conflicts: other rows, other banks, alternately, across
    //    all 24 MiB
    for (int i = 0; i < 24; i++) begin
        wwrite(30'h0000400 + i * 30'h40000, 32'h1111_0000 + i, 4'b0011);
        wwrite(30'h0000400 + i * 30'h40000, (32'h2222 + i) << 16, 4'b1100);
    end
    for (int i = 23; i >= 0; i--) wread_check(30'h0000400 + i * 30'h40000, "row conflicts");

    // 5. back to back, different lines: the answer must be the new address's
    wwrite(30'h0000800, 32'h0000_1234, 4'b0011);
    wwrite(30'h0000900, 32'h0000_5678, 4'b0011);
    for (int i = 0; i < 8; i++) begin
        wread_check(30'h0000800, "back to back A");
        wread_check(30'h0000900, "back to back B");
    end

    // 6. the frame buffer through Wishbone, read back by the scan-out port
    for (int r = 0; r < 72; r++)                  // two scan lines' worth of words
        wwrite(FB_WB_BASE + r, {16'hF000 + 16'(r * 2), 16'hF000 + 16'(r * 2 + 1)}, 4'b1111);
    check(chip_cell(FB_SDRAM_WORD) == 16'hF000, "the bw2's first halfword is its first SDRAM word");
    fb_fetch(28'd0, 18);
    fb_wait();
    fb_check(28'd0, 18, "scan-out alone");
    wread_check(FB_WB_BASE + 5, "frame buffer via Wishbone");

    // 7. scan-out and CPU traffic at once
    fb_fetch(28'd0, 18);
    for (int i = 0; i < 40; i++) begin
        wwrite(30'h0001000 + i, rnd(), 4'b0011);
        wread_check(30'h0000100 + (i % 64), "CPU during scan-out");
    end
    fb_wait();
    fb_check(28'd0, 18, "scan-out during CPU traffic");

    // 8. random traffic across 24 MiB, long enough for a few hundred refreshes
    for (int i = 0; i < 3000; i++) begin
        bit [29:0] a;
        bit [31:0] r;
        r = rnd();
        a = 30'(r[22:0] % MEM_WORDS);            // anywhere in the 24 MiB
        case (r[25:24])
            2'd0: wwrite(a, rnd(), 4'b1111);
            2'd1: wwrite(a, rnd(), r[29:28] == 0 ? 4'b0011 : 4'b1100);
            2'd2: wwrite(a, rnd(), r[29:26] == 0 ? 4'b0001 : r[29:26]);
            2'd3: wread_check(a, "random");
        endcase
        if (i % 500 == 0) fb_fetch(28'd0, 9);
    end
    fb_wait();
    // read back everything the random phase wrote
    foreach (mm[h]) wread_check(30'(h / 2), "final sweep");

    // 9. the cg4's planes through its window: where each lands in the chip,
    //    read back by the CPU and by the scan-out port
    for (int i = 0; i < 36; i++) begin          // a colour line's first 144 bytes
        wwrite(cgw(24'h800000 + 4*i), {8'(4*i), 8'(4*i+1), 8'(4*i+2), 8'(4*i+3)}, 4'b1111);
        wwrite(cgw(24'h400000 + 4*i), 32'hA5A50000 | i, 4'b1111);
        wwrite(cgw(24'h600000 + 4*i), 32'h5A5A0000 | i, 4'b1111);
    end
    wwrite(cgw(24'h800000 + 1152), 32'hC0C1C2C3, 4'b1111);    // line 1's first word
    check(chip_cell(CG_COLOR_WORD) == 16'h0001, "colour plane byte 0 is CG_COLOR_WORD's high byte");
    check(chip_cell(CG_OVERLAY_WORD + 1) == 16'h0000, "overlay plane word 0's low half");
    check(chip_cell(CG_OVERLAY_WORD) == 16'hA5A5, "overlay plane at CG_OVERLAY_WORD");
    check(chip_cell(CG_ENABLE_WORD) == 16'h5A5A, "enable plane at CG_ENABLE_WORD");
    check(chip_cell(CG_COLOR_WORD + 576) == 16'hC0C1, "colour line 1 is 576 words on");
    wread_check(cgw(24'h800000 + 8), "colour via Wishbone");
    wread_check(cgw(24'h400000 + 12), "overlay via Wishbone");
    wread_check(cgw(24'h600000 + 140), "enable via Wishbone");
    // libpixrect's mem_rop reads and writes the planes by bytes and halfwords
    // as well (read, merge, write back): every mix of byte selects in each
    // plane, over a word whose four bytes are known
    for (int p = 0; p < 3; p++) begin
        bit [23:0] base;
        base = (p == 0) ? 24'h800000 + 24'd2304 : (p == 1) ? 24'h400000 + 24'd288 : 24'h600000 + 24'd288;
        for (int m = 1; m < 16; m++) begin
            wwrite(cgw(base + 24'(4*m)), 32'h5A5A_5A5A ^ (32'h0101_0101 * p), 4'b1111);
            wwrite(cgw(base + 24'(4*m)), 32'h0102_0304 * m, 4'(m));
            wread_check(cgw(base + 24'(4*m)), $sformatf("cg4 plane %0d, byte selects %b", p, 4'(m)));
        end
    end
    cs_fetch(CG_COLOR_WORD, 9, 0);
    cs_wait();
    cs_check(CG_COLOR_WORD, 9, "cg4 scan-out, colour");
    cs_fetch(CG_OVERLAY_WORD, 9, 0);
    cs_wait();
    cs_check(CG_OVERLAY_WORD, 9, "cg4 scan-out, overlay");

    // 10. the cg4's scan-out and the CPU at once, polite and urgent; and the
    //     bw2's scan-out as well
    for (int i = 36; i < 288; i++)              // the rest of colour line 0
        wwrite(cgw(24'h800000 + 4*i), rnd(), 4'b1111);
    for (int pass = 0; pass < 2; pass++) begin
        cs_fetch(CG_COLOR_WORD, 72, pass[0]);
        fb_fetch(28'd0, 9);
        for (int i = 0; i < 60; i++) begin
            wwrite(30'h0002000 + i, rnd(), 4'b1111);
            wread_check(30'h0000100 + (i % 64), pass ? "CPU beside an urgent scan-out" : "CPU beside a polite scan-out");
        end
        cs_wait();
        fb_wait();
        cs_check(CG_COLOR_WORD, 72, pass ? "urgent cg4 scan-out" : "polite cg4 scan-out");
        fb_check(28'd0, 9, "bw2 scan-out beside the cg4's");
    end
    check(cs_run_polite == 1, $sformatf("a polite scan-out takes turns with the CPU: %0d bursts in a row while it waited", cs_run_polite));

    // 11. a CPU that never lets cyc fall between reads: a polite scan-out
    //     still has every other turn, and has its line long before the CPU is
    //     done
    cs_fetch(CG_COLOR_WORD, 72, 0);
    stream(30'h0000100, 400);
    cs_wait();
    stream_wait();
    cs_check(CG_COLOR_WORD, 72, "polite cg4 scan-out beside a streaming CPU");
    check(cs_in_stream >= 64, $sformatf("a polite scan-out has turns beside a streaming CPU: %0d of 72 bursts while it streamed", cs_in_stream));
    check(cs_run_urgent >= 32, $sformatf("an urgent scan-out keeps the SDRAM: %0d bursts in a row while the CPU waited", cs_run_urgent));

    check(chip.errors == 0, $sformatf("chip protocol: %0d violations", chip.errors));
    check(chip.max_refresh_gap > 0 && chip.max_refresh_gap <= 780,
          $sformatf("refresh: longest gap %0d clocks, limit 780 (7.8 us)", chip.max_refresh_gap));

    $display("");
    $display("tb_mister_sdram: %0d checks, %0d failed, %0d Wishbone answers", passes + fails, fails, wb_acks);
    chip.report_timing();
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

initial begin
    #(64'd500_000_000_000);                      // 500 ms of simulated time
    $display("FAIL  timeout");
    $finish;
end

endmodule
