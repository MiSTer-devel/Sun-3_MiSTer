`timescale 1ns / 1ps

`include "sun3_attr.vh"
//
// sun3_cg4.sv -- the cg4's registers: the P4 register and the Bt458 DACs.
//
// The 3/60's P4 colour board (501-1210, "cg4 type B"), as docs/cg4.md has
// it from the Rev 1.9 PROM and NetBSD's cg4.c.  Its three planes are memory
// and go through the memory bridge (sun3_fpga.v's MATCH_CG4MEM); this is the
// rest, an OBMEM device on the CPU's clock:
//
//   0xFF200000  Bt458: +0 address, +4 colour map, +8 control, +12 overlay map
//   0xFF300000  the P4 register
//
// The P4 register reads the cg4's ID, 0x41 (colour 8 + overlay, 1152x900),
// in bits 30:24.  Its low byte is control and status: 0x20 video on (read
// and write), 0x08 vertical retrace, 0x04 interrupt pending (write: clear),
// 0x02 interrupt enable.  The interrupt is level 4, raised at the start of
// vertical retrace while enabled, and held until cleared.
//
// The Bt458s, as a 3/60 wires them (cg4.c): every register takes its byte
// from the low lane, D7:0 -- the 68020 copies a byte or word it writes onto
// the other lanes, so byte and word writes land there too -- except the
// colour map, which takes a longword as four components in a row, D31:24
// first, and gives one back the same way.  A narrower access to the colour
// map moves that many components, from the low lanes up.  The address
// register counts colour-map entries; each takes three components, red,
// green, blue, and the address moves on after the blue.  The overlay map
// works the same way over its four entries.  Control registers 4..7 are the
// read mask, blink mask, command and test register.
//
// The display side (sun3_cg4_scanout.sv) reads the colour map through a
// second port of its own RAM, and the overlay colours, read mask and command
// register as plain levels, crossing into its clock (they change only when
// software writes them, and a pixel's worth of tearing is harmless).
//
module sun3_cg4 (
    input  wire        clk,
    input  wire        rst,            // system reset (INIT-)

    // ---- the CPU's side --------------------------------------------------
    input  wire        sel_dac,        // the cycle is for the Bt458s (level, whole cycle)
    input  wire        sel_p4,         // ... for the P4 register
    input  wire        rw_n,
    input  wire [3:2]  adr,            // which DAC register
    input  wire [3:0]  lanes,          // byte enables: [3] D31:24 .. [0] D7:0
    input  wire [31:0] wdata,
    output reg  [31:0] rdata = 32'h0,
    output reg         ack   = 1'b0,   // one clock
    output wire        irq,            // level 4

    // ---- for the scan-out --------------------------------------------------
    input  wire        retrace,        // vertical retrace, the pixel clock's
    output reg         video_on   = 1'b0,
    output reg  [7:0]  read_mask  = 8'hFF,
    output reg  [7:0]  command    = 8'h00,
    output reg  [23:0] ovl1 = 24'h0, ovl2 = 24'h0, ovl3 = 24'h0,
    // the colour map: written here, read by the scan-out in its own clock
    input  wire        cm_clk,
    input  wire [7:0]  cm_raddr,
    output reg  [23:0] cm_rdata = 24'h0
);

    localparam [7:0] P4_ID = 8'h41;     // cg4: colour 8 + overlay, 1152x900

    // ---- the Bt458's registers ---------------------------------------------------
    reg  [7:0]  addr  = 8'h0;           // the address register
    reg  [1:0]  comp  = 2'd0;           // which component of the entry: 0 red, 1 green, 2 blue
    reg  [23:0] entry = 24'h0;          // the entry being written, by component
    reg  [7:0]  blink = 8'h00, test = 8'h00;

    // ---- the colour map RAM ---------------------------------------------------
    // Two copies written together, one read by the CPU and one by the
    // scan-out: one write and one read port each, which is a block RAM; three
    // ports on one array are not.
    `SUN3_RAM_BLOCK reg [23:0] cmap    [0:255];
    `SUN3_RAM_BLOCK reg [23:0] cmap_px [0:255];
    reg         cm_we = 1'b0;
    reg  [7:0]  cm_wa = 8'h0;
    reg  [23:0] cm_wd = 24'h0;
    reg  [23:0] cm_q;                   // the CPU's read port, for readback
    always @(posedge clk) begin
        if (cm_we) cmap[cm_wa] <= cm_wd;
        cm_q <= cmap[addr];
    end
    always @(posedge clk)
        if (cm_we) cmap_px[cm_wa] <= cm_wd;
    always @(posedge cm_clk) cm_rdata <= cmap_px[cm_raddr];

    // the vertical retrace, into this clock
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg  [2:0]  rt_s = 3'b000;
    always @(posedge clk) rt_s <= {rt_s[1:0], retrace};
    wire rt_now  = rt_s[1];
    wire rt_rise = rt_s[1] & ~rt_s[2];

    reg         int_en = 1'b0, int_pend = 1'b0;
    assign irq = int_pend;

    // The cycle's components, in order, as many as lanes are enabled.
    function automatic [2:0] n_comps(input [3:0] l);
        n_comps = {2'b00, l[0]} + {2'b00, l[1]} + {2'b00, l[2]} + {2'b00, l[3]};
    endfunction
    function automatic [7:0] comp_k(input [31:0] d, input [2:0] n, input [1:0] k);
        // the k-th of n components: the low n lanes, the highest of them first
        comp_k = d[8 * (n - 1 - k) +: 8];
    endfunction

    // A colour-map access takes one component a clock.  A write builds the
    // entry in `entry' -- across cycles too: 192 packed longwords load 256
    // entries, so an entry is often begun by one cycle and finished by the
    // next -- and stores it when its blue arrives.  A read takes the entry
    // from the RAM first (two clocks: the address, then the data), and again
    // each time it moves on to the next entry.
    localparam [1:0] C_IDLE = 2'd0, C_LOAD = 2'd1, C_TAKE = 2'd2, C_COMP = 2'd3;
    reg  [1:0]  cst = C_IDLE;
    reg         go_q = 1'b0;
    reg  [2:0]  n = 3'd0, k = 3'd0;
    reg  [31:0] rd_acc = 32'h0;
    reg         rd_q = 1'b0;
    wire        sel = sel_dac | sel_p4;

    // the component of an entry, and an entry with one component replaced
    function automatic [7:0] pick(input [23:0] e, input [1:0] c);
        pick = (c == 2'd0) ? e[23:16] : (c == 2'd1) ? e[15:8] : e[7:0];
    endfunction
    function automatic [23:0] put(input [23:0] e, input [1:0] c, input [7:0] v);
        put = (c == 2'd0) ? {v, e[15:0]} : (c == 2'd1) ? {e[23:16], v, e[7:0]} : {e[23:8], v};
    endfunction

    reg  [23:0] ovl0 = 24'h0;           // overlay colour 0: kept, never shown
    function automatic [23:0] ovl_get(input [1:0] i);
        case (i)
            2'd0: ovl_get = ovl0;
            2'd1: ovl_get = ovl1;
            2'd2: ovl_get = ovl2;
            default: ovl_get = ovl3;
        endcase
    endfunction

    wire [7:0]  cv  = comp_k(wdata, n, k[1:0]);     // this clock's component, writing
    wire [23:0] ent = put(entry, comp, cv);
    wire        last = (k + 3'd1 == n);

`ifdef SUN3_SIM
    // +trace_cg4: every register cycle as it starts
    bit trace = 1'b0;
    initial trace = $test$plusargs("trace_cg4");
    always @(posedge clk)
        if (trace && !rst && sel && !go_q && cst == C_IDLE)
            $display("[%0t] cg4: %s %s reg %0d lanes %b data %08x%s", $time,
                     sel_p4 ? "P4 " : "DAC", rw_n ? "read " : "write", adr, lanes, wdata,
                     sel_p4 ? $sformatf(" (P4 was %02x)", {2'b00, video_on, 1'b1, rt_now, int_pend, int_en, 1'b0}) : "");
`endif

    always @(posedge clk) begin
        ack   <= 1'b0;
        cm_we <= 1'b0;
        go_q  <= sel;

        if (rt_rise && int_en) int_pend <= 1'b1;

        if (rst) begin
            cst      <= C_IDLE;
            video_on <= 1'b0;
            int_en   <= 1'b0;
            int_pend <= 1'b0;
            addr     <= 8'h0;
            comp     <= 2'd0;
        end else case (cst)
            C_IDLE:
                if (sel & ~go_q) begin              // the cycle's first clock here
                    if (sel_p4) begin
                        if (!rw_n) begin
                            video_on <= wdata[5];
                            int_en   <= wdata[1];
                            if (wdata[2]) int_pend <= 1'b0;
                        end
                        rdata <= {1'b0, P4_ID[6:0], 16'h0000,
                                  2'b00, video_on, 1'b1, rt_now, int_pend, int_en, 1'b0};
                        ack   <= 1'b1;
                    end else if (adr == 2'd1) begin // the colour map
                        n      <= n_comps(lanes);
                        k      <= 3'd0;
                        rd_q   <= rw_n;
                        rd_acc <= 32'h0;
                        cst    <= rw_n ? C_LOAD : C_COMP;
                    end else begin
                        case ({rw_n, adr})
                            3'b0_00: begin addr <= wdata[7:0]; comp <= 2'd0; end
                            3'b0_10: case (addr[1:0])
                                         2'd0: read_mask <= wdata[7:0];
                                         2'd1: blink     <= wdata[7:0];
                                         2'd2: command   <= wdata[7:0];
                                         default: test   <= wdata[7:0];
                                     endcase
                            3'b0_11: case (addr[1:0])   // the overlay map
                                         2'd0: ovl0 <= put(ovl0, comp, wdata[7:0]);
                                         2'd1: ovl1 <= put(ovl1, comp, wdata[7:0]);
                                         2'd2: ovl2 <= put(ovl2, comp, wdata[7:0]);
                                         default: ovl3 <= put(ovl3, comp, wdata[7:0]);
                                     endcase
                            default: ;
                        endcase
                        // the overlay map steps its component either way
                        if (adr == 2'd3) begin
                            if (comp == 2'd2) begin comp <= 2'd0; addr <= addr + 8'd1; end
                            else comp <= comp + 2'd1;
                        end
                        case (adr)
                            2'd0:    rdata <= {4{addr}};
                            2'd2:    rdata <= {4{(addr[1:0] == 2'd0) ? read_mask :
                                                 (addr[1:0] == 2'd1) ? blink :
                                                 (addr[1:0] == 2'd2) ? command : test}};
                            default: rdata <= {4{pick(ovl_get(addr[1:0]), comp)}};
                        endcase
                        ack <= 1'b1;
                    end
                end

            C_LOAD:                                 // cm_q is being read at `addr'
                cst <= C_TAKE;

            C_TAKE: begin
                entry <= cm_q;
                cst   <= C_COMP;
            end

            C_COMP: begin                           // one component
                if (rd_q)
                    rd_acc <= {rd_acc[23:0], pick(entry, comp)};
                else begin
                    entry <= ent;
                    if (comp == 2'd2) begin
                        cm_we <= 1'b1;
                        cm_wa <= addr;
                        cm_wd <= ent;
                    end
                end
                if (comp == 2'd2) begin
                    comp <= 2'd0;
                    addr <= addr + 8'd1;
                end else
                    comp <= comp + 2'd1;
                k <= k + 3'd1;
                if (last) begin
                    cst   <= C_IDLE;
                    ack   <= 1'b1;
                    // a read gives its components on the low lanes, the first
                    // highest; a single component goes to every lane
                    rdata <= (n == 3'd1) ? {4{pick(entry, comp)}}
                           : (n == 3'd2) ? {2{rd_acc[7:0], pick(entry, comp)}}
                           : {rd_acc[23:0], pick(entry, comp)};
                end else if (rd_q && comp == 2'd2)
                    cst <= C_LOAD;                  // the next entry, from the RAM
            end
        endcase
    end

endmodule
