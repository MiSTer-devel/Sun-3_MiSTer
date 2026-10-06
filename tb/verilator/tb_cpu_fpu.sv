//============================================================================
//  tb_cpu_fpu -- the RD68021 and the RD68884, wired as rtl/sun3/sun3_top.v
//  wires them (the FPU at CpID 1 with its same-clock bus front end, its DSACK
//  and data lanes merged in front of the CPU), running the CPU+FPU corpus that
//  scored 1319 of 1320 on a real Mac II -- the same pair, a 68020 and a 68881.
//
//  The corpus is lbmactwo_MiSTer's SingleStepTests/cpu_fpu
//  (tb/verilator/corpus/, see its README): each test is a short program that
//  ends in STOP #$2700 and leaves its answer in one data register.  Here the
//  program goes at $1000 with the reset vectors pointing at it, as there; its
//  STOP becomes a BRA.W to an epilogue at $2000 that stores D0-D7 at $F000
//  (MOVEM.L) and stops, and every exception vector points at a handler at
//  $3000 that stores its vector offset at $F020 and stops.  So the bench reads
//  the answer off the bus and needs nothing from inside the CPU.
//
//  Memory is a zero-wait 32-bit port: DSACK1/DSACK0 both low while AS is,
//  writes by the byte enables sun3_fpga.v derives from SIZ and A1:A0.
//
//      make -C tb/verilator tb_cpu_fpu [CORPUS=...]
//      (+list=<file> from mk_fpu_corpus.py, +only=<n> to run one test,
//       +verbose for every result)
//============================================================================
`timescale 1ns/1ps

module tb_cpu_fpu;

reg clk = 0;
always #25 clk = ~clk;                          // 20 MHz, the 3/60's
reg rst = 1;

// ---- memory: 64 KiB, big-endian, mirrored over the address space --------------
reg [7:0] mem [0:65535];

// ---- the CPU ------------------------------------------------------------------------
wire [31:0] a, d_cpu_o;
wire        d_oe;
wire [2:0]  fc;
wire [1:0]  siz;
wire        as_n, ds_n, rw, rmc_n, dben_n, ecs_n, ocs_n, ipend_n, bg_n;
wire        fc_oe, a_oe, siz_oe, rw_oe, rmc_oe, as_oe, ds_oe, dben_oe, reset_n_oe, halt_n_oe;
wire        xreset_n_o, xhalt_n_o;
wire [31:0] cpu_d_i;
wire [1:0]  cpu_dsack_n;

rd68021_top #(.COPROCESSOR(1'b1)) cpu (
    .clk(clk), .rst_n(~rst),
    .fc_o(fc), .fc_oe(fc_oe), .a_o(a), .a_oe(a_oe),
    .d_i(cpu_d_i), .d_o(d_cpu_o), .d_oe(d_oe),
    .siz_o(siz), .siz_oe(siz_oe),
    .ecs_n_o(ecs_n), .ocs_n_o(ocs_n), .rw_o(rw), .rw_oe(rw_oe), .rmc_n_o(rmc_n), .rmc_oe(rmc_oe),
    .as_n_o(as_n), .as_oe(as_oe), .ds_n_o(ds_n), .ds_oe(ds_oe), .dben_o(dben_n), .dben_oe(dben_oe),
    .dsack_n_i(cpu_dsack_n),
    .ipl_n_i(3'b111), .ipend_n_o(ipend_n), .avec_n_i(1'b1),
    .br_n_i(1'b1), .bg_n_o(bg_n), .bgack_n_i(1'b1),
    .berr_n_i(1'b1), .reset_n_i(~rst), .reset_n_o(xreset_n_o), .reset_n_oe(reset_n_oe),
    .halt_n_i(~rst), .halt_n_o(xhalt_n_o), .halt_n_oe(halt_n_oe),
    .cdis_n_i(1'b1));

// ---- the FPU, at CpID 1 (sun3_fpga.v's fpu_sel, without EN.FPP) ----------------------
wire        fpu_sel = (fc == 3'd7) && (a[19:16] == 4'h2) && (a[15:13] == 3'd1);
wire [31:0] fpu_d_o;
wire [3:0]  fpu_d_oe;
wire [1:0]  fpu_dsack_n;
wire        fpu_dsack_oe;

rd68884_top #(.BUS_SYNC(1), .BUS_SYNC_WAIT(0)) fpu (
    .clk(clk), .rst_n(~rst), .reset_n_i(~rst),
    .cs_n_i(~fpu_sel), .as_n_i(as_n), .ds_n_i(ds_n), .rw_i(rw),
    .size_n_i(1'b1), .a_i({a[4:1], 1'b1}),
    .d_i(d_cpu_o), .d_o(fpu_d_o), .d_oe(fpu_d_oe),
    .dsack_n_o(fpu_dsack_n), .dsack_oe(fpu_dsack_oe));

// ---- the bus: memory answers anything that is not CPU space ---------------------------
wire        mem_sel = !as_n && fc != 3'd7;
wire [15:0] ma = {a[15:2], 2'b00};
wire [31:0] mem_q = {mem[ma], mem[ma + 16'd1], mem[ma + 16'd2], mem[ma + 16'd3]};
wire [1:0]  mem_dsack_n = mem_sel ? 2'b00 : 2'b11;

genvar fl;
generate for (fl = 0; fl < 4; fl = fl + 1) begin : lane
    assign cpu_d_i[8*fl +: 8] = fpu_d_oe[fl] ? fpu_d_o[8*fl +: 8] : mem_q[8*fl +: 8];
end endgenerate
assign cpu_dsack_n = mem_dsack_n & (fpu_dsack_oe ? fpu_dsack_n : 2'b11);

// The byte enables of a write, as sun3_fpga.v derives them (UU = D31:24, the
// byte at the lowest address).
wire en_ll = ( a[0] &  a[1]) | ( a[1] &  siz[1]) | (~siz[0] & ~siz[1]) | ( a[0] & siz[0] & siz[1]);
wire en_lu = (~a[0] &  a[1]) | ( a[0] & ~a[1] & siz[1]) | (~a[1] & ~siz[0] & ~siz[1]) | (~a[1] & siz[0] & siz[1]);
wire en_ul = ( a[0] & ~a[1]) | (~a[1] & ~siz[0]) | (~a[1] & siz[1]);
wire en_uu = (~a[0] & ~a[1]);

// ---- what the program leaves behind -------------------------------------------------------
reg [31:0] dreg [0:7];
reg [7:0]  dseen = 8'h00;
reg [31:0] vec_off = 32'h0;
reg        trapped = 1'b0;
reg        wrote = 1'b0;

always @(posedge clk) begin
    if (as_n) wrote <= 1'b0;
    else if (mem_sel && !ds_n && !rw && !wrote) begin
        wrote <= 1'b1;
        if (en_uu) mem[ma]          <= d_cpu_o[31:24];
        if (en_ul) mem[ma + 16'd1]  <= d_cpu_o[23:16];
        if (en_lu) mem[ma + 16'd2]  <= d_cpu_o[15:8];
        if (en_ll) mem[ma + 16'd3]  <= d_cpu_o[7:0];
        if (a[15:0] >= 16'hF000 && a[15:0] < 16'hF020 && en_uu && en_ll) begin
            dreg[a[4:2]]  <= d_cpu_o;
            dseen[a[4:2]] <= 1'b1;
        end
        if (a[15:0] == 16'hF020) begin
            vec_off <= d_cpu_o;
            trapped <= 1'b1;
        end
    end
end

// ---- setting up a test ----------------------------------------------------------------------
task automatic poke16(input int ad, input [15:0] v);
    mem[ad] = v[15:8]; mem[ad + 1] = v[7:0];
endtask
task automatic poke32(input int ad, input [31:0] v);
    poke16(ad, v[31:16]); poke16(ad + 2, v[15:0]);
endtask

task automatic set_up(input byte prog [], input int stop_at);
    for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
    poke32(32'h0, 32'h0000FFF8);                // SSP, below the mailbox's page
    poke32(32'h4, 32'h00001000);                // PC
    for (int v = 2; v < 256; v++) poke32(4 * v, 32'h00003000);
    for (int i = 0; i < prog.size(); i++) mem[16'h1000 + i] = prog[i];
    // STOP -> BRA.W $2000
    poke16(16'h1000 + stop_at, 16'h6000);
    poke16(16'h1000 + stop_at + 2, 16'(32'h2000 - (32'h1000 + stop_at + 2)));
    // $2000: MOVEM.L D0-D7,($0000F000).L; STOP #$2700
    poke16(16'h2000, 16'h48F9); poke16(16'h2002, 16'h00FF); poke32(16'h2004, 32'h0000F000);
    poke16(16'h2008, 16'h4E72); poke16(16'h200A, 16'h2700);
    // $3000: the exception handler: the frame's format/vector word into D0,
    // then MOVE.L D0,($0000F020).L; STOP #$2700
    poke16(16'h3000, 16'h7000);                 // MOVEQ #0,D0
    poke16(16'h3002, 16'h302F); poke16(16'h3004, 16'h0006);   // MOVE.W 6(A7),D0
    poke16(16'h3006, 16'h23C0); poke32(16'h3008, 32'h0000F020);
    poke16(16'h300C, 16'h4E72); poke16(16'h300E, 16'h2700);
endtask

// ---- the run ----------------------------------------------------------------------------------
integer passes = 0, fails = 0, traps = 0, hangs = 0;
initial begin
    string     list, name;
    integer    fd, reg_n, n, stop_at, only, k, r;
    reg [31:0] expect_v;
    byte       prog [];
    bit        verbose;

    if (!$value$plusargs("list=%s", list)) list = "obj_tb_cpu_fpu/corpus.txt";
    if (!$value$plusargs("only=%d", only)) only = -1;
    verbose = $test$plusargs("verbose");
    fd = $fopen(list, "r");
    if (fd == 0) begin $display("tb_cpu_fpu: cannot open %s", list); $finish; end
    $display("tb_cpu_fpu: RD68021 + RD68884 against the CPU+FPU corpus (%s)", list);

    k = 0;
    while (!$feof(fd)) begin
        r = $fscanf(fd, "%d %h %d %d\n", reg_n, expect_v, n, stop_at);
        if (r != 4) break;
        prog = new[n];
        for (int i = 0; i < n; i++) begin
            int b;
            r = $fscanf(fd, "%h", b);
            prog[i] = 8'(b);
        end
        r = $fgets(name, fd);                   // the rest of the bytes' line
        r = $fgets(name, fd);
        if (name.len() > 0 && name[name.len() - 1] == "\n") name = name.substr(0, name.len() - 2);
        if (only >= 0 && k != only) begin k++; continue; end

        rst = 1;
        set_up(prog, stop_at);
        dseen = 8'h00; trapped = 1'b0;
        repeat (8) @(posedge clk);
        rst = 0;
        begin
            int t;
            for (t = 0; t < 100000 && dseen != 8'hFF && !trapped; t++) @(posedge clk);
            repeat (4) @(posedge clk);
            if (trapped) begin
                traps++; fails++;
                $display("FAIL  #%0d %s: exception, vector offset %03x", k, name, vec_off[11:0]);
            end else if (dseen != 8'hFF) begin
                hangs++; fails++;
                $display("FAIL  #%0d %s: never finished", k, name);
            end else if (dreg[reg_n] != expect_v) begin
                fails++;
                $display("FAIL  #%0d %s: D%0d = %08x, expected %08x", k, name, reg_n, dreg[reg_n], expect_v);
            end else begin
                passes++;
                if (verbose) $display("  ok  #%0d %s: D%0d = %08x", k, name, reg_n, dreg[reg_n]);
            end
        end
        k++;
    end
    $fclose(fd);
    $display("");
    $display("tb_cpu_fpu: %0d tests, %0d passed, %0d failed (%0d exceptions, %0d never finished)",
             passes + fails, passes, fails, traps, hangs);
    if (fails == 0 && passes > 0) $display("PASS"); else $display("FAIL");
    $finish;
end

endmodule
