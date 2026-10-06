//============================================================================
//  tb_cg4_scanout -- rtl/sun3/sun3_cg4_scanout.sv, the cg4's picture, at full
//  size in Sun-3.sv's raster (video_timing, 1160x904 in 1472x937), every
//  pixel against a model of the planes and the Bt458s (docs/cg4.md):
//
//    * the planes come from a memory that answers as the SDRAM adapter does
//      (rtl/sun3_mister_sdram.sv: a burst at a time, a clock's gap after each
//      answer), quickly in some frames and in others as if the CPU took every
//      other turn -- too slow for the screen unless the scan-out says it is
//      urgent;
//    * the planes' contents change every frame, so a line not fetched again
//      shows;
//    * the Bt458's state changes between frames: the command register's
//      overlay enables, the read mask, the overlay colours, video off;
//    * the screen switched on part-way through a frame, as the colour board
//      is, and the frame after it whole;
//    * the console's planes: lines whose enable plane is all ones, which need
//      no colour when the command register enables OL0, or OL1 and the
//      overlay plane is all ones too -- and lines whose overlay plane is all
//      ones over an enable plane that is not, which do; the bursts a frame
//      are counted, and every pixel still checked.
//
//      make -C tb/verilator tb_cg4_scanout
//============================================================================
`timescale 1ps/1ps

module tb_cg4_scanout;

localparam [25:0] COLOR_WORD   = 26'h0C80000;
localparam [25:0] OVERLAY_WORD = 26'h0D00000;
localparam [25:0] ENABLE_WORD  = 26'h0D10000;

reg mclk = 0, pclk = 0;
always #5000 mclk = ~mclk;                      // 100 MHz
always #6000 pclk = ~pclk;                      // 83.3 MHz
reg mrst = 1, prst = 1;

// ---- the raster ---------------------------------------------------------------
wire [11:0] cx;
wire [10:0] cy;
wire        de, hs, vs;
video_timing #(
    .H_ACTIVE(1160), .H_FRONT(24), .H_SYNC(128), .H_TOTAL(1472),
    .V_ACTIVE(904),  .V_FRONT(3),  .V_SYNC(4),   .V_TOTAL(937),
    .H_POSITIVE(1'b0), .V_POSITIVE(1'b0), .CXW(12), .CYW(11)
) timing (.clk(pclk), .rst(prst), .cx(cx), .cy(cy), .de(de), .hsync(hs), .vsync(vs));

// ---- the DUT ------------------------------------------------------------------
reg          enable = 1;
wire [25:0]  c_word;
wire         c_req, c_urgent;
reg          c_done = 0;
reg  [127:0] c_rdata = 0;
reg          video_on = 1;
reg  [7:0]   read_mask = 8'hFF, command = 8'h43;
reg  [23:0]  ovl1 = 24'hFFFF00, ovl2 = 24'hFFFFFF, ovl3 = 24'h000000;
wire [7:0]   cm_raddr;
reg  [23:0]  cm_rdata = 0;
wire [23:0]  rgb;
wire         retrace;

sun3_cg4_scanout dut (
    .mclk(mclk), .mrst(mrst), .enable(enable),
    .c_word(c_word), .c_req(c_req), .c_urgent(c_urgent), .c_done(c_done), .c_rdata(c_rdata),
    .clk_pixel(pclk), .pix_rst(prst), .cx(cx), .cy(cy),
    .video_on(video_on), .read_mask(read_mask), .command(command),
    .ovl1(ovl1), .ovl2(ovl2), .ovl3(ovl3),
    .cm_raddr(cm_raddr), .cm_rdata(cm_rdata),
    .rgb(rgb), .retrace(retrace)
);

// the colour map, read as sun3_cg4 reads it for the scan-out: a clock later
reg [23:0] cmap [0:255];
initial for (int i = 0; i < 256; i++) cmap[i] = {8'(i * 7 + 3), 8'(i * 13 + 5), 8'(i * 29 + 11)};
always @(posedge pclk) cm_rdata <= cmap[cm_raddr];

// ---- the planes: a word's contents are a hash of its address and the frame's seed
reg [31:0] seed = 32'h1234_5678;
function automatic [15:0] hashval(input [25:0] w, input [31:0] s);
    bit [31:0] h;
    h = {6'd0, w} ^ s;
    h = h ^ (h >> 16); h = h * 32'h7FEB352D;
    h = h ^ (h >> 15); h = h * 32'h846CA68B;
    h = h ^ (h >> 16);
    hashval = h[15:0];
endfunction

// In a console frame: the enable plane is all ones on even lines.  The overlay
// plane is all ones on lines 0 mod 4, and on lines 2 mod 4 all ones but for
// its last burst (words 64..71), which only a whole line's look can tell; and
// all ones on the odd lines, where the enable plane is not, so that the
// colour plane shows through most of them.
bit console = 0;
function automatic [15:0] wordval(input [25:0] w, input [31:0] s);
    int r, k;
    begin
        wordval = hashval(w, s);
        if (console && w >= ENABLE_WORD && w < ENABLE_WORD + 26'd64800) begin
            r = int'(w - ENABLE_WORD) / 72;
            if (r % 2 == 0) wordval = 16'hFFFF;
        end
        if (console && w >= OVERLAY_WORD && w < OVERLAY_WORD + 26'd64800) begin
            r = int'(w - OVERLAY_WORD) / 72;
            k = int'(w - OVERLAY_WORD) % 72;
            if (r % 2 == 1 || r % 4 == 0 || (r % 4 == 2 && k < 64)) wordval = 16'hFFFF;
        end
    end
endfunction

function automatic [7:0] byteval(input [25:0] base, input int b, input [31:0] s);
    bit [15:0] w;
    w = wordval(base + 26'(b / 2), s);
    byteval = (b % 2 == 0) ? w[15:8] : w[7:0];
endfunction

// ---- the memory: as sun3_mister_sdram answers a client -------------------------
// mode 0: every burst LAT clocks; mode 1: polite bursts wait for a CPU burst
// as well (and a little more), urgent ones do not.
localparam int LAT = 12;
integer     mode = 0;
reg         busy = 0, gap = 0;
integer     cnt = 0;
reg  [25:0] wl = 0;
reg         wl_urgent = 0;
integer     bursts = 0, urgent_bursts = 0;
reg         req_seen_off = 0;               // c_req while the screen was off

always @(posedge mclk) begin
    c_done <= 1'b0;
    if (!enable && c_req) req_seen_off <= 1'b1;
    if (busy) begin
        if (cnt == 0) begin
            for (int j = 0; j < 8; j++)
                c_rdata[16*(j^1) +: 16] <= wordval(wl + 26'(j), seed);
            c_done <= 1'b1;
            busy   <= 1'b0;
            gap    <= 1'b1;
            bursts <= bursts + 1;
            if (wl_urgent) urgent_bursts <= urgent_bursts + 1;
        end else
            cnt <= cnt - 1;
    end else if (gap)
        gap <= 1'b0;
    else if (c_req) begin
        busy      <= 1'b1;
        wl        <= {c_word[25:3], 3'b000};
        wl_urgent <= c_urgent;
        cnt       <= (mode == 1 && !c_urgent) ? LAT + 13 + ($urandom % 14) : LAT;
    end
end

// ---- the check: every pixel, four clocks after its cx/cy ------------------------
function automatic [23:0] expect_px(input [11:0] x, input [10:0] y, input [31:0] s,
                                    input bit von, input [7:0] rm, input [7:0] cmd,
                                    input [23:0] o1, input [23:0] o2, input [23:0] o3);
    int row, col, idx;
    bit [7:0] cb, ob8, eb8;
    bit ob, eb;
    bit [1:0] ol;
    begin
        if (!(x >= 4 && x < 1156 && y >= 2 && y < 902) || !von) return 24'h0;
        row = int'(y) - 2;
        col = int'(x) - 4;
        cb  = byteval(COLOR_WORD, row * 1152 + col, s);
        idx = row * 144 + col / 8;
        ob8 = byteval(OVERLAY_WORD, idx, s);
        eb8 = byteval(ENABLE_WORD, idx, s);
        ob  = ob8[7 - col % 8];                 // pixel 0 is a byte's MSB
        eb  = eb8[7 - col % 8];
        ol  = {ob & eb & cmd[1], eb & cmd[0]};  // the overlay only where enabled
        case (ol)
            2'd1:    return o1;
            2'd2:    return o2;
            2'd3:    return o3;
            default: return cmap[cb & rm];
        endcase
    end
endfunction

integer     frame = 0;                      // counts starts of vertical blank
reg  [3:0]  chk_d = 0, de_d = 0;
reg [23:0]  exp_d [0:3];
integer     errors [0:15];
integer     pixels [0:15];
integer     ubursts [0:15], fbursts [0:15];
integer     retrace_bad = 0;
bit         checking = 0;                   // this frame is checked
initial for (int i = 0; i < 16; i++) begin errors[i] = 0; pixels[i] = 0; ubursts[i] = 0; fbursts[i] = 0; end

always @(posedge pclk) begin
    exp_d[0] <= expect_px(cx, cy, seed, video_on, read_mask, command, ovl1, ovl2, ovl3);
    chk_d[0] <= checking;                   // the whole raster: black outside the screen
    de_d[0]  <= de;
    for (int k = 1; k < 4; k++) exp_d[k] <= exp_d[k-1];
    chk_d[3:1] <= chk_d[2:0];
    de_d[3:1]  <= de_d[2:0];
    if (chk_d[3]) begin
        if (de_d[3]) pixels[frame] <= pixels[frame] + 1;
        if (rgb !== exp_d[3]) begin
            if (errors[frame] < 5)
                $display("FAIL  frame %0d: a pixel read %06x, expected %06x (at %0t)", frame, rgb, exp_d[3], $time);
            errors[frame] <= errors[frame] + 1;
        end
    end
    if (!prst && retrace !== (cy >= 11'd904)) retrace_bad <= retrace_bad + 1;
end

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

// The frame boundary: the start of vertical blank, on the pixel clock.  The
// next frame's state is set there; its fetch begins a little after.
task automatic next_frame;
    begin
        do @(posedge pclk); while (!(cx == 12'd0 && cy == 11'd904));
        #1;
        ubursts[frame] = urgent_bursts;
        fbursts[frame] = bursts;
        frame = frame + 1;
        seed  = seed * 32'd1103515245 + 32'd12345;
    end
endtask

// ---- the sequence --------------------------------------------------------------
initial begin
    $display("tb_cg4_scanout: sun3_cg4_scanout, full frames, every pixel");
    repeat (20) @(posedge mclk);
    mrst = 0;
    prst = 0;

    next_frame();                           // 1: the first frame fetched
    next_frame();                           // 2: checked, a quick memory
    checking = 1;
    next_frame();                           // 3: as if the CPU took every other turn
    mode = 1;
    next_frame();                           // 4: OL0 only, a read mask, other overlay colours
    command = 8'h41; read_mask = 8'h0F;
    ovl1 = 24'h102030; ovl2 = 24'h405060; ovl3 = 24'h708090;
    next_frame();                           // 5: OL1 only, quick again
    mode = 0;
    command = 8'h42; read_mask = 8'hF0;
    next_frame();                           // 6: video off
    video_on = 0;
    next_frame();                           // 7: the screen off: nothing fetched
    checking = 0;
    video_on = 1; command = 8'h43; read_mask = 8'hFF;
    enable = 0;
    repeat (937 * 1472 / 2) @(posedge pclk);
    enable = 1;                             // ... and on again half-way down, slowly
    mode = 1;
    next_frame();                           // 8: whole again, slowly
    checking = 1;
    next_frame();                           // 9: the console's planes, both overlay enables, quick
    console = 1;
    mode = 0;
    command = 8'h43;
    next_frame();                           // 10: OL0 only, slowly
    command = 8'h41;
    mode = 1;
    next_frame();                           // 11: OL1 only, quick
    command = 8'h42;
    mode = 0;
    next_frame();                           // 12: neither: every line in colour
    command = 8'h40;
    next_frame();                           // 13: done
    checking = 0;
    repeat (8) @(posedge pclk);

    for (int f = 2; f <= 12; f++) begin
        if (f == 7) continue;
        check(errors[f] == 0, $sformatf("frame %0d: %0d of %0d pixels wrong", f, errors[f], pixels[f]));
        check(pixels[f] == 1160 * 904, $sformatf("frame %0d: %0d pixels checked", f, pixels[f]));
    end
    // frame 2: quick, so only the first line, before the screen begins, is urgent
    check(ubursts[2] - ubursts[1] == 90, $sformatf("a quick frame's urgent bursts: %0d (the first line's 90)", ubursts[2] - ubursts[1]));
    // frame 3: slow, so the scan-out had to say so
    check(ubursts[3] - ubursts[2] > 900, $sformatf("a slow frame's urgent bursts: %0d", ubursts[3] - ubursts[2]));
    check(!req_seen_off, "nothing is fetched while the screen is off");
    // the bursts a frame: 90 a line, or 18 for a line with no colour
    check(fbursts[2] - fbursts[1] == 900 * 90, $sformatf("frame 2: %0d bursts (all in colour)", fbursts[2] - fbursts[1]));
    check(fbursts[9] - fbursts[8] == 450 * 18 + 450 * 90,
          $sformatf("frame 9: %0d bursts (the 450 enabled lines need no colour)", fbursts[9] - fbursts[8]));
    check(fbursts[10] - fbursts[9] == 450 * 18 + 450 * 90,
          $sformatf("frame 10: %0d bursts (450 lines need no colour)", fbursts[10] - fbursts[9]));
    check(fbursts[11] - fbursts[10] == 225 * 18 + 675 * 90,
          $sformatf("frame 11: %0d bursts (225 lines, both planes all ones, need no colour)", fbursts[11] - fbursts[10]));
    check(fbursts[12] - fbursts[11] == 900 * 90, $sformatf("frame 12: %0d bursts (all in colour)", fbursts[12] - fbursts[11]));
    check(retrace_bad == 0, $sformatf("retrace is vertical blank: %0d clocks otherwise", retrace_bad));
    $display("tb_cg4_scanout: %0d bursts, %0d urgent", bursts, urgent_bursts);

    $display("");
    $display("tb_cg4_scanout: %0d checks, %0d failed", passes + fails, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

initial begin
    #(64'd400_000_000_000);                // 400 ms: 13 frames are 220
    $display("FAIL  timeout");
    $display("FAIL");
    $finish;
end

endmodule
