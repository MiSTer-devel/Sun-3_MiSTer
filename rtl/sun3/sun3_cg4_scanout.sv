`timescale 1ns / 1ps
//
// sun3_cg4_scanout.sv -- the cg4's picture.
//
// 1152x900, in the same 1160x904 raster as the bw2, out of the three planes
// in SDRAM (rtl/sun3_mister_sdram.sv), through the Bt458s as docs/cg4.md has
// them: per pixel, the overlay input is OL = {overlay bit & enable bit,
// enable bit}, each gated by its command-register enable; if OL is not 0 the
// pixel is overlay colour OL, otherwise colour-map entry (colour byte & read
// mask).  Where the enable plane is 0 the colour plane shows, whatever the
// overlay holds.
//
// After Sun-2_MiSTer's rtl/sun2-vme/sun2_cgtwo_scanout.sv (the cgtwo's, one
// plane), which has the reasoning behind the fetch:
//
//   mclk       the memory's, where lines are fetched
//   clk_pixel  the raster's
//
// **The fetch runs ahead**, in a ring of four lines, up to three lines ahead
// of the one on screen, asking politely -- the SDRAM adapter takes turns with
// the CPU -- until the next line to be shown is not complete (`c_urgent'), and
// only then demanding priority.  A line is 90 bursts of 16 bytes: 9 of
// enable and 9 of overlay (a bit a pixel, the bw2's layout), then 72 of
// colour (a byte a pixel).
//
// **A line nobody can see the colour of is not fetched in colour.**  If a
// line's enable plane is all ones and the command register enables OL0 -- or
// OL1, and the overlay plane is all ones too -- every pixel of it is an
// overlay colour.
// That is how the PROM and SunOS leave the screen for their consoles, so the
// console costs 18 bursts a line, not 90.  The ring keeps whatever colour
// it had for such a line; nothing reads it.  (The command register is taken
// as the line is fetched, up to three lines early: changing it changes those
// lines a frame late, once.)
//
// **Byte and bit order** are the Sun-3's big-endian bus's, as the SDRAM
// adapter lays a line out (word k of a burst at [32k+31:32k]): colour byte b
// of a burst is at {b[3:2], ~b[1:0], 3'b000}, and pixel p of a 1-bit burst at
// {p[6:5], ~p[4:0]}, as fb_scanout.sv takes the bw2's.
//
// **Latency**: rgb is four clocks behind cx/cy -- the line buffers' read, the
// colour map's address, its read (in sun3_cg4.sv, on this clock), the mix.
// Sun-3.sv delays the syncs and DE to match while the cg4 is shown.
//
module sun3_cg4_scanout #(
    parameter int        FB_W     = 1152,
    parameter int        FB_H     = 900,
    parameter int        SCREEN_W = 1160,
    parameter int        SCREEN_H = 904,
    // the planes in SDRAM, as 16-bit word addresses (sun3_mister_sdram.sv)
    parameter bit [25:0] COLOR_WORD   = 26'h0C80000,   // 25 MiB
    parameter bit [25:0] OVERLAY_WORD = 26'h0D00000,   // 26 MiB
    parameter bit [25:0] ENABLE_WORD  = 26'h0D10000    // 26 MiB + 128 KiB
) (
    // ---- mclk: lines in --------------------------------------------------
    input  wire         mclk,
    input  wire         mrst,
    input  wire         enable,         // shown: fetch nothing otherwise
    output wire [25:0]  c_word,         // SDRAM word of the 16-byte burst
    output wire         c_req,
    output wire         c_urgent,
    input  wire         c_done,
    input  wire [127:0] c_rdata,

    // ---- clk_pixel ---------------------------------------------------------------
    input  wire         clk_pixel,
    input  wire         pix_rst,
    input  wire [11:0]  cx,
    input  wire [10:0]  cy,
    // the Bt458s' state (sun3_cg4.sv; it changes only when software writes it)
    input  wire         video_on,
    input  wire [7:0]   read_mask,
    input  wire [7:0]   command,
    input  wire [23:0]  ovl1, ovl2, ovl3,
    output reg  [7:0]   cm_raddr = 8'h0,    // the colour map, read one clock later
    input  wire [23:0]  cm_rdata,
    output reg  [23:0]  rgb = 24'd0,
    output wire         retrace
);

    localparam int CBEATS = FB_W / 16;                  // 72
    localparam int MBEATS = FB_W / 128;                 // 9
    localparam int BEATS  = CBEATS + 2 * MBEATS;        // 90
    localparam int X0     = (SCREEN_W - FB_W) / 2;      // 4
    localparam int Y0     = (SCREEN_H - FB_H) / 2;      // 2

    // ---- the line rings: four lines each ---------------------------------------------
    reg  [127:0] cbuf [0:511];          // {line[1:0], beat[6:0]}, 72 used of 128
    reg  [127:0] obuf [0:63];           // {line[1:0], beat[3:0]}, 9 used of 16
    reg  [127:0] ebuf [0:63];

    // ==================================================================
    // clk_pixel
    // ==================================================================
    wire        in_y = (cy >= Y0) && (cy < Y0 + FB_H);
    wire        in_x = (cx >= X0) && (cx < X0 + FB_W);
    wire [10:0] row  = cy - Y0[10:0];
    wire [10:0] col  = cx[10:0] - X0[10:0];

    assign retrace = (cy >= SCREEN_H);

    // Toggles for the fetcher: the start of vertical blank begins a frame's
    // fetch, and the start of each displayed line says the line before it is
    // finished with.
    reg fs_tgl = 1'b0, ls_tgl = 1'b0;
    always @(posedge clk_pixel)
        if (pix_rst) begin
            fs_tgl <= 1'b0;
            ls_tgl <= 1'b0;
        end else begin
            if (cx == 0 && cy == SCREEN_H) fs_tgl <= ~fs_tgl;
            if (cx == 0 && in_y)           ls_tgl <= ~ls_tgl;
        end

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [7:0]  rm_s1 = 8'hFF, cmd_s1 = 8'h00;
    reg        von_s1 = 1'b0;
    reg [7:0]  rm = 8'hFF, cmd = 8'h00;
    reg        von = 1'b0;
    always @(posedge clk_pixel) begin
        rm_s1 <= read_mask; cmd_s1 <= command; von_s1 <= video_on;
        rm    <= rm_s1;     cmd    <= cmd_s1;  von    <= von_s1;
    end

    // stage 1: the line buffers; stage 2: the colour map's address and the
    // overlay input; stage 3: the colour map's data (sun3_cg4); stage 4: the mix
    reg  [127:0] cbeat = 128'd0, obeat = 128'd0, ebeat = 128'd0;
    reg  [6:0]   p1 = 7'd0;
    reg          vis1 = 1'b0, vis2 = 1'b0, vis3 = 1'b0;
    reg  [1:0]   ol2 = 2'd0, ol3 = 2'd0;

    wire [7:0]   pix = cbeat[{p1[3:2], ~p1[1:0], 3'b000} +: 8];
    wire         ovb = obeat[{p1[6:5], ~p1[4:0]}];
    wire         enb = ebeat[{p1[6:5], ~p1[4:0]}];

    always @(posedge clk_pixel) begin
        cbeat <= cbuf[{row[1:0], col[10:4]}];
        obeat <= obuf[{row[1:0], col[10:7]}];
        ebeat <= ebuf[{row[1:0], col[10:7]}];
        p1    <= col[6:0];
        vis1  <= in_x & in_y;

        cm_raddr <= pix & rm;
        ol2      <= {ovb & enb & cmd[1], enb & cmd[0]};
        vis2     <= vis1;

        ol3  <= ol2;
        vis3 <= vis2;

        rgb <= !(vis3 & von)  ? 24'd0 :
               (ol3 == 2'd1)  ? ovl1 :
               (ol3 == 2'd2)  ? ovl2 :
               (ol3 == 2'd3)  ? ovl3 : cm_rdata;
    end

    // ==================================================================
    // mclk
    // ==================================================================
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg fs_s1 = 1'b0, ls_s1 = 1'b0;
    reg fs_s2 = 1'b0, ls_s2 = 1'b0, fs_s3 = 1'b0, ls_s3 = 1'b0;
    always @(posedge mclk) begin
        fs_s1 <= fs_tgl; fs_s2 <= fs_s1; fs_s3 <= fs_s2;
        ls_s1 <= ls_tgl; ls_s2 <= ls_s1; ls_s3 <= ls_s2;
    end
    wire fs_pulse = fs_s2 ^ fs_s3;
    wire ls_pulse = ls_s2 ^ ls_s3;

    reg  [10:0] fetch_row = 11'd0;      // next line to fetch
    reg  [10:0] shown     = 11'd0;      // lines whose display has begun
    reg  [6:0]  beat      = 7'd0;       // 0..8 enable, 9..17 overlay, 18..89 colour
    // Nothing is fetched until a frame starts.  A frame's start forgets where
    // the fetch was, so a burst must not be in flight then: the fetch ends
    // with the frame's last line, well before, but not if it began at some
    // arbitrary point after a reset or when the screen was switched on.
    reg         armed     = 1'b0;

    wire        active = enable && armed && (fetch_row < FB_H[10:0]) && (fetch_row < shown + 11'd3);
    assign c_req    = active;
    assign c_urgent = active && (fetch_row <= shown);

    // the burst's SDRAM word: colour lines are 1152 bytes (576 words), the
    // 1-bit planes' 144 (72); a burst is 8 words
    localparam int OB0 = MBEATS, CB0 = 2 * MBEATS;      // the first overlay and colour beats
    wire [6:0]  mb = (beat >= 7'(OB0)) ? beat - 7'(OB0) : beat;
    wire [6:0]  cb = beat - 7'(CB0);
    assign c_word = (beat < 7'(OB0))
                  ? ENABLE_WORD  + 26'(fetch_row) * 26'd72  + {16'd0, mb, 3'b000}
                  : (beat < 7'(CB0))
                  ? OVERLAY_WORD + 26'(fetch_row) * 26'd72  + {16'd0, mb, 3'b000}
                  : COLOR_WORD   + 26'(fetch_row) * 26'd576 + {16'd0, cb, 3'b000};

    // the command register's overlay enables, from the CPU's clock
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg  [1:0]  ole_s1 = 2'b00;
    reg  [1:0]  ole    = 2'b00;
    always @(posedge mclk) begin
        ole_s1 <= command[1:0];
        ole    <= ole_s1;
    end
    // this line's enable and overlay planes, so far all ones?
    reg         en_ones = 1'b1, ov_ones = 1'b1;
    wire        all_ones = &c_rdata;
    wire        no_colour = en_ones && (ole[0] || (ole[1] && ov_ones && all_ones));

    always @(posedge mclk) begin
        if (mrst || !enable)
            armed <= 1'b0;
        else if (fs_pulse)
            armed <= 1'b1;

        if (mrst || fs_pulse) begin
            fetch_row <= 11'd0;
            shown     <= 11'd0;
            beat      <= 7'd0;
            en_ones   <= 1'b1;
            ov_ones   <= 1'b1;
        end else begin
            if (ls_pulse)
                shown <= shown + 11'd1;
            if (active && c_done) begin
                if (beat < 7'(OB0))
                    en_ones <= en_ones & all_ones;
                else if (beat < 7'(CB0))
                    ov_ones <= ov_ones & all_ones;
                if (beat == 7'(BEATS - 1) || (beat == 7'(CB0 - 1) && no_colour)) begin
                    beat      <= 7'd0;
                    fetch_row <= fetch_row + 11'd1;
                    en_ones   <= 1'b1;
                    ov_ones   <= 1'b1;
                end else
                    beat <= beat + 7'd1;
            end
        end
    end

    always @(posedge mclk)
        if (active && c_done) begin
            if (beat < 7'(OB0))
                ebuf[{fetch_row[1:0], mb[3:0]}] <= c_rdata;
            else if (beat < 7'(CB0))
                obuf[{fetch_row[1:0], mb[3:0]}] <= c_rdata;
            else
                cbuf[{fetch_row[1:0], cb}] <= c_rdata;
        end

endmodule
