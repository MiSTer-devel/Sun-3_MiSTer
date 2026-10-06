//============================================================================
//  tb_si -- the Sun-3/60's on-board SCSI DMA (rtl/sun3/sun3_si.sv) against
//  the engine it replaced, which moved a byte per DVMA cycle
//  (sun3_si_ref.sv, here).
//
//  Two rigs run the same commands.  Each is a sun3_si (or the reference), the
//  DVMA bridge onto the 68020 bus (wish7990_dvma_to_020, behind the same
//  one-master arbiter sun3_fpga.v has), a model of that bus -- a CPU that
//  gives it up at the end of a cycle of its own, and memory behind it -- and a
//  back end for the disk's block seam.  A driver programs the 5380 and the
//  UDC the way Linux's sun3_scsi.c does: the chain in DVMA memory, the CDB by
//  programmed I/O, the data by DMA, then STATUS and MESSAGE IN.
//
//  After every command the rigs must agree on what a driver reads (fifo_count,
//  fifo_data, the UDC's count and status, the CSR, the 5380's Bus and Status
//  with EOP's END OF DMA), on the status and message bytes, and on every byte
//  of memory and of the disk.  Each rig also checks
//  its own results: a read brings in the disk's bytes and nothing around
//  them, a write puts memory's on the disk, and the residual is right.  The
//  commands cover every alignment, transfers that end at the count and ones
//  the target ends short with 0 to 3 bytes still gathered, a count that runs
//  out before the target's data, reads, writes, and a DVMA bus error and a
//  read after it.  The packed engine must also take the bus less: a 2.5 KB
//  read must finish in under 60% of the reference's time.
//
//      make -C tb/verilator tb_si
//============================================================================
`timescale 1ns/1ps

module si_rig #(
    parameter bit    REF  = 1'b0,
    parameter string NAME = "si"
) (
    input  logic clk,
    input  logic rst,
    input  int   go,          // commands the top lets this rig start
    output int   at,          // commands it has finished
    output bit   done
);
    localparam int BLOCKS = 64;
    localparam int CHAIN  = 32'h000100;
    localparam int PH_DATA_OUT = 0, PH_DATA_IN = 1, PH_COMMAND = 2, PH_STATUS = 3, PH_MSG_IN = 7;
    localparam logic [6:0] UDC_MODE = 7'h38, UDC_CMD = 7'h2e, UDC_CAR_HI = 7'h26,
                           UDC_CAR_LO = 7'h22, UDC_COUNT = 7'h32;

    int fails = 0;
    int cycle = 0;
    always @(posedge clk) cycle <= cycle + 1;

    // ---- the CPU's port into the board ---------------------------------------
    logic        match = 1'b0, rw_n = 1'b1;
    logic [4:0]  adr = 5'd0;
    logic [31:0] wdata = 32'd0;
    wire  [31:0] rdata;
    wire         ack, irq, dma_active;

    // ---- DVMA, and the disk's block seam ---------------------------------------
    wire         m_cyc, m_we, m_ack, m_err;
    wire  [3:0]  m_sel;
    wire  [29:0] m_adr;
    wire  [31:0] m_dat_o, m_dat_i;
    wire         blk_start, blk_we;
    wire  [31:0] blk_lba;
    wire  [7:0]  blk_buf_rdata;
    logic        blk_done = 1'b0, blk_buf_we = 1'b0;
    logic [8:0]  blk_buf_addr = 9'd0;
    logic [7:0]  blk_buf_wdata = 8'd0;

    generate if (REF) begin : g
        sun3_si_ref #(.CLK_PERIOD_PS(50000)) dut (
            .clk(clk), .rst(rst), .match(match), .rw_n(rw_n), .adr(adr), .wdata(wdata),
            .rdata(rdata), .ack(ack), .irq(irq),
            .m_cyc(m_cyc), .m_we(m_we), .m_sel(m_sel), .m_adr(m_adr), .m_dat_o(m_dat_o),
            .m_dat_i(m_dat_i), .m_ack(m_ack), .m_err(m_err),
            .blk_start(blk_start), .blk_we(blk_we), .blk_lba(blk_lba), .blk_buf_rdata(blk_buf_rdata),
            .blk_done(blk_done), .blk_err(1'b0), .blk_ready(1'b1), .blk_count(BLOCKS),
            .blk_buf_we(blk_buf_we), .blk_buf_addr(blk_buf_addr), .blk_buf_wdata(blk_buf_wdata),
            .dma_active(dma_active));
    end else begin : g
        sun3_si #(.CLK_PERIOD_PS(50000)) dut (
            .clk(clk), .rst(rst), .match(match), .rw_n(rw_n), .adr(adr), .wdata(wdata),
            .rdata(rdata), .ack(ack), .irq(irq),
            .m_cyc(m_cyc), .m_we(m_we), .m_sel(m_sel), .m_adr(m_adr), .m_dat_o(m_dat_o),
            .m_dat_i(m_dat_i), .m_ack(m_ack), .m_err(m_err),
            .blk_start(blk_start), .blk_we(blk_we), .blk_lba(blk_lba), .blk_buf_rdata(blk_buf_rdata),
            .blk_done(blk_done), .blk_err(1'b0), .blk_ready(1'b1), .blk_count(BLOCKS),
            .blk_buf_we(blk_buf_we), .blk_buf_addr(blk_buf_addr), .blk_buf_wdata(blk_buf_wdata),
            .dma_active(dma_active));
    end endgenerate

    // ---- the DVMA arbiter (sun3_fpga.v's, with the SCSI its only master) ---------
    reg  dv_busy = 1'b0;
    wire dv_ack, dv_err;
    always @(posedge clk)
        if (rst)                  dv_busy <= 1'b0;
        else if (!dv_busy)        dv_busy <= m_cyc;
        else if (dv_ack | dv_err) dv_busy <= 1'b0;
    wire dv_cyc = dv_busy & m_cyc;
    assign m_ack = dv_busy & dv_ack;
    assign m_err = dv_busy & dv_err;

    // ---- the bridge onto the 68020 bus ----------------------------------------------
    wire [31:0] mc_A, mc_DO;
    wire [2:0]  mc_FC;
    wire [1:0]  mc_SIZ;
    wire        mc_AS_OUT, mc_DS, mc_RW, mc_BR, mc_BGACK;
    logic       mc_BG = 1'b1, cpu_as = 1'b1, dsack = 1'b1, berr = 1'b1;
    logic [31:0] mc_DI;

    wish7990_dvma_to_020 bridge (
        .clk(clk), .reset_n(~rst),
        .wb_cyc_i(dv_cyc), .wb_stb_i(dv_cyc), .wb_we_i(m_we), .wb_sel_i(m_sel),
        .wb_adr_i(m_adr), .wb_dat_i(m_dat_o), .wb_dat_o(m_dat_i),
        .wb_ack_o(dv_ack), .wb_err_o(dv_err),
        .mc_A_OUT(mc_A), .mc_D_IN(mc_DI), .mc_D_OUT(mc_DO), .mc_FC(mc_FC), .mc_SIZ(mc_SIZ),
        .mc_AS_N_IN(cpu_as & mc_AS_OUT), .mc_AS_N_OUT(mc_AS_OUT), .mc_DS_N(mc_DS),
        .mc_RW_N(mc_RW), .mc_DSACK0_N(dsack), .mc_DSACK1_N(dsack), .mc_BERR_N(berr),
        .mc_BR_N(mc_BR), .mc_BG_N(mc_BG), .mc_BGACK_N(mc_BGACK));

    // ---- the bus: a CPU that runs four-clock cycles and grants the bus at the
    // end of one, and memory that answers a DVMA cycle after a few clocks -------
    byte mem  [0:65535];
    byte disk [0:BLOCKS*512-1];
    int  fault_lo = 0, fault_hi = 0;       // DVMA addresses that answer BERR
    int  cpu_st = 0, cpu_n = 0, mem_n = 0;
    localparam int RD_WAIT = 6, WR_WAIT = 3;

    always @(posedge clk) begin
        case (cpu_st)
            0: begin
                cpu_n  <= cpu_n + 1;
                cpu_as <= (cpu_n % 4 == 3);
                if (!mc_BR && cpu_n % 4 == 3) begin mc_BG <= 1'b0; cpu_as <= 1'b1; cpu_st <= 1; end
            end
            1: if (!mc_BGACK)  begin mc_BG <= 1'b1; cpu_st <= 2; end
               else if (mc_BR) begin mc_BG <= 1'b1; cpu_st <= 0; end
            default: if (mc_BGACK && mc_BR) cpu_st <= 0;
        endcase
    end

    wire [15:0] ma = {mc_A[15:2], 2'b00};
    assign mc_DI = {mem[ma], mem[ma + 1], mem[ma + 2], mem[ma + 3]};

    always @(posedge clk) begin
        if (!mc_AS_OUT && !mc_BGACK) begin
            if (dsack && berr) begin
                if (mem_n == (mc_RW ? RD_WAIT : WR_WAIT)) begin
                    mem_n <= 0;
                    if (mc_A[23:0] >= fault_lo && mc_A[23:0] < fault_hi)
                        berr <= 1'b0;
                    else begin
                        dsack <= 1'b0;
                        if (!mc_RW) begin
                            int n, k;
                            n = (mc_SIZ == 2'b00) ? 4 : mc_SIZ;
                            k = mc_A[1:0];
                            for (int i = 0; i < n; i++)
                                mem[ma + k + i] = mc_DO[31 - 8*(k + i) -: 8];
                        end
                    end
                end else
                    mem_n <= mem_n + 1;
            end
        end else begin
            dsack <= 1'b1; berr <= 1'b1; mem_n <= 0;
        end
    end

    // ---- the disk's back end: a block after a short wait, as sun3_mister_block
    // moves it --------------------------------------------------------------------
    int          b_st = 0, b_n = 0, b_wait = 0;
    logic [31:0] b_lba;
    logic        b_we;
    always @(posedge clk) begin
        blk_done   <= 1'b0;
        blk_buf_we <= 1'b0;
        case (b_st)
            0: if (blk_start) begin b_lba <= blk_lba; b_we <= blk_we; b_n <= 0; b_wait <= 20; b_st <= 1; end
            1: if (b_wait == 0) b_st <= b_we ? 3 : 2; else b_wait <= b_wait - 1;
            2: begin                                    // fill the target's buffer
                blk_buf_we    <= 1'b1;
                blk_buf_addr  <= b_n[8:0];
                blk_buf_wdata <= disk[b_lba * 512 + b_n];
                if (b_n == 511) b_st <= 4;
                b_n <= b_n + 1;
            end
            3: begin                                    // drain it: data a clock behind the address
                if (b_n < 512) blk_buf_addr <= b_n[8:0];
                if (b_n >= 2) disk[b_lba * 512 + b_n - 2] = blk_buf_rdata;
                if (b_n == 513) b_st <= 4;
                b_n <= b_n + 1;
            end
            default: begin blk_done <= 1'b1; b_st <= 0; end
        endcase
    end

    // ---- register access, as the CPU makes it --------------------------------------
    task automatic acc(input bit wr, input logic [4:0] a, input logic [15:0] d, output logic [15:0] q);
        @(posedge clk);
        match <= 1'b1; rw_n <= !wr; adr <= a; wdata <= {d, d};
        do @(negedge clk); while (!ack);
        q = rdata[15:0];
        @(posedge clk);
        match <= 1'b0; rw_n <= 1'b1;
    endtask
    task automatic reg_w(input logic [4:0] a, input logic [15:0] v);
        logic [15:0] q; acc(1'b1, a, v, q);
    endtask
    task automatic reg_r(input logic [4:0] a, output logic [15:0] v);
        acc(1'b0, a, 16'h0, v);
    endtask
    task automatic chip_w(input int r, input logic [7:0] v);
        logic [15:0] q; acc(1'b1, r[4:0], {8'h00, v}, q);
    endtask
    task automatic chip_r(input int r, output logic [7:0] v);
        logic [15:0] q; acc(1'b0, r[4:0], 16'h0, q); v = q[7:0];
    endtask
    task automatic udc_w(input logic [6:0] p, input logic [15:0] v);
        reg_w(5'h12, {9'd0, p}); reg_w(5'h10, v);
    endtask
    task automatic udc_r(input logic [6:0] p, output logic [15:0] v);
        reg_w(5'h12, {9'd0, p}); reg_r(5'h10, v);
    endtask
    task automatic put16(input int a, input logic [15:0] v);
        mem[a] = v[15:8]; mem[a + 1] = v[7:0];
    endtask

    task automatic fail(input string what);
        $display("FAIL: %s command %0d: %s", NAME, at, what);
        fails++;
    endtask

    // Current SCSI Bus Status: REQ, and the phase {MSG, C/D, I/O}.
    task automatic wait_req(input int ph);
        logic [7:0] csb;
        for (int n = 0; n < 100000; n++) begin
            chip_r(4, csb);
            if (csb[5]) begin
                if ({csb[4], csb[3], csb[2]} != ph[2:0])
                    fail($sformatf("REQ in phase %0d, wanted %0d", {csb[4], csb[3], csb[2]}, ph));
                return;
            end
        end
        fail($sformatf("no REQ for phase %0d", ph));
    endtask
    task automatic wait_bus(input int bit_n, input bit level);
        logic [7:0] csb;
        for (int n = 0; n < 100000; n++) begin
            chip_r(4, csb);
            if (csb[bit_n] == level) return;
        end
        fail($sformatf("bus status bit %0d never %0d", bit_n, level));
    endtask
    // one byte by programmed I/O, in either direction
    task automatic pio(input int ph, input logic [7:0] out, output logic [7:0] in);
        wait_req(ph);
        chip_w(3, {5'd0, ph[2:0]});
        if (ph[0]) chip_r(0, in);
        else begin chip_w(0, out); chip_w(1, 8'h01); in = out; end
        chip_w(1, ph[0] ? 8'h10 : 8'h11);
        wait_bus(5, 1'b0);
        chip_w(1, 8'h00);
    endtask

    // ---- one command --------------------------------------------------------------------
    // What a driver reads when the DMA is over, and how long it ran.
    logic [15:0] s_fifo_count, s_fifo_data, s_udc_count, s_udc_status, s_csr;
    logic [7:0]  s_bsr, s_status, s_msg;
    int          s_cycles;

    // reset_after: the target still wants data when the DMA is over (a bus
    // error, or a count shorter than the transfer), so the bus is reset
    task automatic command(input logic [7:0] cdb [10], input int ncdb, input bit dout,
                           input int bufa, input int count, input bit reset_after);
        logic [7:0]  v;
        logic [15:0] q;
        int t0;
        // the UDC's chain, in DVMA memory (sun3_scsi.c's sun3_udc_regs)
        put16(CHAIN + 0,  dout ? 16'h0282 : 16'h0182);
        put16(CHAIN + 2,  {bufa[23:16], 8'h00});
        put16(CHAIN + 4,  bufa[15:0]);
        put16(CHAIN + 6,  dout ? 16'((count + 1) / 2) : 16'(count / 2));
        put16(CHAIN + 8,  16'h0040);
        put16(CHAIN + 10, dout ? 16'h00c2 : 16'h00d2);
        reg_w(5'h18, dout ? 16'h000f : 16'h0007);       // SEND, INTR_EN, FIFO_RES, SCSI_RES
        udc_w(UDC_CMD, 16'h0000);
        udc_w(UDC_CAR_HI, {8'(CHAIN >> 16), 8'h00});
        udc_w(UDC_CAR_LO, 16'(CHAIN));
        udc_w(UDC_MODE, 16'h000d);
        udc_w(UDC_CMD, 16'h0032);
        // select target 0, without arbitration (TCR's I/O clear, or the chip
        // will not drive the IDs)
        chip_w(3, 8'h00);
        chip_w(0, 8'h81); chip_w(1, 8'h01); chip_w(1, 8'h05);
        wait_bus(6, 1'b1);
        chip_w(1, 8'h01); chip_w(1, 8'h00);
        // fifo_count takes a write only outside a data phase, and a free bus
        // reads as DATA OUT: write it once the target asks for the CDB
        wait_req(PH_COMMAND);
        reg_w(5'h16, 16'(count));
        for (int i = 0; i < ncdb; i++) pio(PH_COMMAND, cdb[i], v);
        // the data, by DMA
        wait_req(dout ? PH_DATA_OUT : PH_DATA_IN);
        if (dout) begin chip_w(3, 8'h00); chip_w(1, 8'h01); chip_w(2, 8'h02); chip_w(5, 8'h00); end
        else begin chip_w(3, 8'h01); chip_w(2, 8'h02); chip_w(7, 8'h00); end
        t0 = cycle;
        udc_w(UDC_CMD, 16'h00a0);                       // START CHAIN
        for (int n = 0; ; n++) begin
            reg_r(5'h18, q);
            if (!q[15] && q[10]) break;                 // DMA ACTIVE down, FIFO EMPTY up
            if (n > 200000) begin fail("the DMA never ended"); break; end
        end
        s_cycles = cycle - t0;
        repeat (100) @(posedge clk);
        reg_r(5'h16, s_fifo_count);
        reg_r(5'h14, s_fifo_data);
        udc_r(UDC_COUNT, s_udc_count);
        udc_r(UDC_CMD, s_udc_status);
        reg_r(5'h18, s_csr);
        chip_r(5, s_bsr);                               // END OF DMA is EOP's mark
        chip_w(2, 8'h00); chip_w(1, 8'h00); chip_r(7, v);
        if (reset_after) begin
            // the target still wants data: reset the bus
            chip_w(1, 8'h80); repeat (50) @(posedge clk); chip_w(1, 8'h00);
            s_status = 8'hff; s_msg = 8'hff;
        end else begin
            pio(PH_STATUS, 8'h00, s_status);
            pio(PH_MSG_IN, 8'h00, s_msg);
        end
        wait_bus(6, 1'b0);
        // tidy up as sun3scsi_dma_finish does
        udc_w(UDC_CMD, 16'h0000);
        reg_w(5'h16, 16'h0000);
        reg_w(5'h18, 16'h0005); reg_w(5'h18, 16'h0007);
    endtask

    // ---- the commands, with the checks each rig makes of itself ------------------------------
    task automatic barrier();
        at = at + 1;
        wait (go > at);
    endtask

    function automatic logic [7:0] pat(input int i, input int salt);
        pat = 8'((i * 37) ^ (i >> 7) ^ salt);
    endfunction

    // a transfer from the target into memory: mem[bufa +: got] must be `want',
    // with the bytes either side untouched
    task automatic check_in(input int bufa, input int got, input byte want [], input int count);
        if (s_fifo_count != 16'(count - got))
            fail($sformatf("residual %0d, wanted %0d", s_fifo_count, count - got));
        for (int i = 0; i < got; i++)
            if (mem[bufa + i] != want[i]) begin
                fail($sformatf("byte %0d is %02x, wanted %02x", i, mem[bufa + i], want[i]));
                break;
            end
    endtask

    task automatic run_read(input bit ten, input int lba, input int nblk, input int bufa, input int count);
        logic [7:0] cdb [10];
        byte want [];
        byte before_lo, before_hi;
        cdb = '{default: 8'h00};
        if (ten) begin
            cdb[0] = 8'h28; cdb[2] = 8'(lba >> 24); cdb[3] = 8'(lba >> 16);
            cdb[4] = 8'(lba >> 8); cdb[5] = 8'(lba); cdb[8] = 8'(nblk);
        end else begin
            cdb[0] = 8'h08; cdb[2] = 8'(lba >> 8); cdb[3] = 8'(lba); cdb[4] = 8'(nblk);
        end
        before_lo = mem[bufa - 1];
        before_hi = mem[bufa + nblk * 512];
        command(cdb, ten ? 10 : 6, 1'b0, bufa, count, 1'b0);
        want = new [nblk * 512];
        for (int i = 0; i < nblk * 512; i++) want[i] = disk[lba * 512 + i];
        check_in(bufa, nblk * 512, want, count);
        if (mem[bufa - 1] != before_lo) fail("the byte before the buffer was written");
        if (count == nblk * 512 && mem[bufa + nblk * 512] != before_hi)
            fail("the byte after the buffer was written");
        if (count == nblk * 512 && !s_bsr[7]) fail("no END OF DMA at the count");
        if (s_status != 8'h00) fail($sformatf("status %02x", s_status));
    endtask

    task automatic run_write(input bit ten, input int lba, input int nblk, input int bufa,
                             input int count, input int salt);
        logic [7:0] cdb [10];
        cdb = '{default: 8'h00};
        for (int i = 0; i < count; i++) mem[bufa + i] = pat(i, salt);
        if (ten) begin
            cdb[0] = 8'h2a; cdb[4] = 8'(lba >> 8); cdb[5] = 8'(lba); cdb[8] = 8'(nblk);
        end else begin
            cdb[0] = 8'h0a; cdb[2] = 8'(lba >> 8); cdb[3] = 8'(lba); cdb[4] = 8'(nblk);
        end
        command(cdb, ten ? 10 : 6, 1'b1, bufa, count, 1'b0);
        for (int i = 0; i < nblk * 512; i++)
            if (disk[lba * 512 + i] != mem[bufa + i]) begin
                fail($sformatf("disk byte %0d is %02x, wanted %02x", i, disk[lba * 512 + i], mem[bufa + i]));
                break;
            end
        // sending, the 5380 takes the next byte before the target asks for
        // it, so a transfer the target ends short has taken one more
        if (s_fifo_count != 16'(count - nblk * 512 - (count > nblk * 512)))
            fail($sformatf("residual %0d, wanted %0d", s_fifo_count, count - nblk * 512 - (count > nblk * 512)));
        if (s_status != 8'h00) fail($sformatf("status %02x", s_status));
    endtask

    // INQUIRY, REQUEST SENSE, MODE SENSE, READ CAPACITY: the target gives
    // min(alloc, its length); the rigs compare the bytes with each other.
    task automatic run_info(input logic [7:0] op, input int alloc, input int bufa, input int len);
        logic [7:0] cdb [10];
        byte after;
        cdb = '{default: 8'h00};
        cdb[0] = op;
        if (op == 8'h25) begin
            command(cdb, 10, 1'b0, bufa, alloc, 1'b0);
        end else begin
            cdb[4] = 8'(alloc);
            after = mem[bufa + len];
            command(cdb, 6, 1'b0, bufa, alloc, 1'b0);
            if (alloc > len && mem[bufa + len] != after) fail("a byte past the data was written");
        end
        if (s_fifo_count != 16'(alloc - len))
            fail($sformatf("residual %0d, wanted %0d", s_fifo_count, alloc - len));
        if (s_status != 8'h00) fail($sformatf("status %02x", s_status));
    endtask

    initial begin
        at = 0;
        done = 1'b0;
        for (int i = 0; i < 65536; i++) mem[i] = pat(i, 8'h5a);
        for (int i = 0; i < BLOCKS * 512; i++) disk[i] = pat(i, i / 512);
        wait (!rst);
        repeat (10) @(posedge clk);
        reg_w(5'h18, 16'h0003);                          // the chip and the UDC out of reset
        repeat (10) @(posedge clk);
        wait (go > at);

        for (int o = 0; o < 4; o++) begin run_info(8'h12, 56, 32'h1000 + o, 36); barrier(); end   // short: 0-3 left gathered
        for (int o = 0; o < 4; o++) begin run_info(8'h12, 5, 32'h1100 + o, 5); barrier(); end
        for (int o = 0; o < 4; o++) begin run_info(8'h12, 7, 32'h1200 + o, 7); barrier(); end
        run_info(8'h03, 255, 32'h1301, 18); barrier();
        run_info(8'h1a, 255, 32'h1402, 12); barrier();
        run_info(8'h25, 8, 32'h1503, 8); barrier();
        for (int o = 0; o < 4; o++) begin run_read(1'b0, 3 + o, 1, 32'h2000 + o * 16 + o, 512); barrier(); end
        run_read(1'b0, 7, 2, 32'h2801, 1024); barrier();
        run_read(1'b0, 11, 3, 32'h3002, 1536); barrier();
        run_read(1'b1, 20, 5, 32'h4000, 2560); barrier();             // the timed one
        for (int o = 0; o < 4; o++) begin run_write(1'b0, 40 + o, 1, 32'h5000 + o * 16 + o, 512, o); barrier(); end
        run_write(1'b1, 44, 3, 32'h6001, 1536, 9); barrier();           // timed too
        run_read(1'b1, 44, 3, 32'h7003, 1536); barrier();               // and read back
        run_read(1'b0, 50, 1, 32'h7801, 600); barrier();                // the target stops at 512
        run_write(1'b0, 51, 1, 32'h7a02, 513, 11); barrier();           // ... and here
        // a count that runs out before the target's data: the DMA ends at
        // the count with a byte still gathered, and the target still asks
        begin
            logic [7:0] cdb [10];
            byte want [];
            cdb = '{default: 8'h00};
            cdb[0] = 8'h08; cdb[3] = 8'd54; cdb[4] = 8'd1;
            command(cdb, 6, 1'b0, 32'h7c01, 300, 1'b1);
            want = new [300];
            for (int i = 0; i < 300; i++) want[i] = disk[54 * 512 + i];
            check_in(32'h7c01, 300, want, 300);
            if (mem[32'h7c01 + 300] != pat(32'h7c01 + 300, 8'h5a)) fail("a byte past the count was written");
            if (!s_bsr[7]) fail("no END OF DMA at the count");
            barrier();
        end
        // a read into a page that faults part way through
        begin
            logic [7:0] cdb [10];
            cdb = '{default: 8'h00};
            cdb[0] = 8'h08; cdb[3] = 8'd52; cdb[4] = 8'd1;
            fault_lo = 32'h8000; fault_hi = 32'h9000;
            command(cdb, 6, 1'b0, 32'h7f01, 512, 1'b1);
            fault_lo = 0; fault_hi = 0;
            // 255 bytes reach memory before 0x8000; the byte that faults is
            // counted too (the error comes with the acknowledge)
            if (!s_csr[13]) fail("no BUS ERROR in the CSR");
            if (s_fifo_count != 16'(512 - 256)) fail($sformatf("residual %0d after the fault, wanted 256", s_fifo_count));
            if (mem[32'h8000] != pat(32'h8000, 8'h5a)) fail("the faulting page was written");
            barrier();
        end
        // and the next transfer starts clean
        run_read(1'b0, 53, 1, 32'h9003, 512); barrier();
        done = 1'b1;
    end
endmodule

module tb_si;
    logic clk = 1'b0, rst = 1'b1;
    always #25 clk = ~clk;                               // 20 MHz
    initial #500 rst = 1'b0;

    localparam int T_READ = 21, T_WRITE = 26;       // the timed commands: READ(10) and WRITE(10)

    int go = 0;
    int ref_at, new_at, fails = 0;
    bit ref_done, new_done;

    si_rig #(.REF(1'b1), .NAME("reference")) r_ref (.clk(clk), .rst(rst), .go(go), .at(ref_at), .done(ref_done));
    si_rig #(.REF(1'b0), .NAME("packed"))    r_new (.clk(clk), .rst(rst), .go(go), .at(new_at), .done(new_done));

    task automatic differ(input int k, input string what);
        $display("FAIL: command %0d: %s", k, what);
        fails++;
    endtask

    initial begin
        int k;
        go = 1;
        for (k = 0; !(ref_done && new_done); k++) begin
            wait ((ref_at > k || ref_done) && (new_at > k || new_done));
            if (ref_done != new_done) begin differ(k, "one rig ran out of commands"); break; end
            if (ref_done) break;
            if (r_ref.s_fifo_count != r_new.s_fifo_count)
                differ(k, $sformatf("fifo_count %04x, reference %04x", r_new.s_fifo_count, r_ref.s_fifo_count));
            if (r_ref.s_fifo_data != r_new.s_fifo_data)
                differ(k, $sformatf("fifo_data %04x, reference %04x", r_new.s_fifo_data, r_ref.s_fifo_data));
            if (r_ref.s_udc_count != r_new.s_udc_count)
                differ(k, $sformatf("UDC count %04x, reference %04x", r_new.s_udc_count, r_ref.s_udc_count));
            if (r_ref.s_udc_status != r_new.s_udc_status)
                differ(k, $sformatf("UDC status %04x, reference %04x", r_new.s_udc_status, r_ref.s_udc_status));
            if (r_ref.s_csr != r_new.s_csr)
                differ(k, $sformatf("CSR %04x, reference %04x", r_new.s_csr, r_ref.s_csr));
            if (r_ref.s_bsr != r_new.s_bsr)
                differ(k, $sformatf("5380 Bus and Status %02x, reference %02x", r_new.s_bsr, r_ref.s_bsr));
            if (r_ref.s_status != r_new.s_status || r_ref.s_msg != r_new.s_msg)
                differ(k, "status or message byte");
            for (int i = 0; i < 65536; i++)
                if (r_ref.mem[i] != r_new.mem[i]) begin
                    differ(k, $sformatf("memory %04x is %02x, reference %02x", i, r_new.mem[i], r_ref.mem[i]));
                    break;
                end
            for (int i = 0; i < 64 * 512; i++)
                if (r_ref.disk[i] != r_new.disk[i]) begin
                    differ(k, $sformatf("disk byte %0d is %02x, reference %02x", i, r_new.disk[i], r_ref.disk[i]));
                    break;
                end
            if (k == T_READ || k == T_WRITE)
                $display("command %0d: %0d bytes %s in %0d clocks, reference %0d (%.1f and %.1f clocks a byte)",
                         k, k == T_READ ? 2560 : 1536, k == T_READ ? "read" : "written",
                         r_new.s_cycles, r_ref.s_cycles,
                         r_new.s_cycles / (k == T_READ ? 2560.0 : 1536.0),
                         r_ref.s_cycles / (k == T_READ ? 2560.0 : 1536.0));
            if (k == T_READ && r_new.s_cycles * 10 >= r_ref.s_cycles * 6)
                differ(k, "the packed engine is not 40% faster");
            go = k + 2;
        end
        fails += r_ref.fails + r_new.fails;
        $display("tb_si: %0d commands, %0d failures", k, fails);
        if (fails == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

    initial begin
        #200ms;
        $display("FAIL: timed out (reference at %0d, packed at %0d)", ref_at, new_at);
        $finish;
    end
endmodule
