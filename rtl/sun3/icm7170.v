`timescale 1ns / 1ps

// ICM7170 Real-Time Clock - Verilog Implementation
// Based on Intersil ICM7170 Datasheet
// but synchronous to the CPU clock to make everyone's life easier...
//
// MiSTer (TIME_RESET = 0, LOAD): the time counters are a battery-backed
// clock's -- RESETn clears the control registers but not the time, which
// starts from power-up values and is set once from outside through LOAD
// (the MiSTer's RTC, rtl/sun3_mister_tod.sv): LOAD_TIME is binary
// {year since 1968, month 1-12, date 1-31, weekday 0-6 from Sunday, hours
// 0-23, minutes, seconds}, the encoding SunOS and NetBSD keep in a Sun-3's
// 7170.  With TIME_RESET = 1 and LOAD tied low it is Sun-3_FPGA's model.
//
// The oscillator is TICK: the chip counts FREQ of them a second, each a
// one-CLK pulse.  Tied high, it counts CLK, as Sun-3_FPGA's model did.  On
// MiSTer (SUN3_TOD_TICK_HZ) it is a fixed 1 MHz made from the memory clock,
// so that the time and SunOS's 100 Hz tick stay right whatever the CPU's
// clock is (docs/design-plan.md, Phase 6).

module icm7170 #(parameter FREQ=19660800,
		 parameter TIME_RESET=1)
   (input 	     CLK, // let's ignore the original and clock everything properly
    input 	 TICK, // the oscillator: FREQ a second, one CLK each
    // Data Bus
    input [7:0]  D_IN, //  data bus D0-D7
    output [7:0] D_OUT, //  data bus D0-D7
    output 	 D_EN,
    // Address Bus
    input [4:0]  A, // Address inputs A0-A4
    // Control Signals
    input 	 RD, // Read strobe (active low)
    input 	 WR, // Write strobe (active low)
    input 	 CS, // Chip select (active low)
    input 	 RESETn, // extra RESET
    // Setting the time from outside (MiSTer), a one-clock pulse
    input 	 LOAD,
    input [55:0] LOAD_TIME,
    // Interrupts
    output 	 INTERRUPT // Interrupt output (open drain)
);
   
   //==============================================================================
   // Internal Registers and Memory
   //==============================================================================
   
   // Time Counter Registers (Address 00h-07h)
   // Power-up values too, for TIME_RESET = 0, where RESETn leaves them alone.
   reg [7:0] 	 counter_hundredths = 8'd0;   // 00h: 1/100 seconds (0-99)
   reg [7:0] 	 counter_hours = 8'd0;        // 01h: Hours (0-23 or 1-12)
   reg [7:0] 	 counter_minutes = 8'd0;      // 02h: Minutes (0-59)
   reg [7:0] 	 counter_seconds = 8'd0;      // 03h: Seconds (0-59)
   reg [7:0] 	 counter_month = 8'd1;        // 04h: Month (1-12)
   reg [7:0] 	 counter_date = 8'd1;         // 05h: Date (1-31)
   reg [7:0] 	 counter_year = 8'd0;         // 06h: Year (0-99)
   reg [7:0] 	 counter_day_of_week = 8'd0;  // 07h: Day of week (0-6)
   
   // Alarm RAM Registers (Address 08h-0Fh)
   reg [7:0] 	 alarm_hundredths;      // 08h: Alarm 1/100 seconds + mask bit
   reg [7:0] 	 alarm_hours;           // 09h: Alarm hours + mask bit
   reg [7:0] 	 alarm_minutes;         // 0Ah: Alarm minutes + mask bit
   reg [7:0] 	 alarm_seconds;         // 0Bh: Alarm seconds + mask bit
   reg [7:0] 	 alarm_month;           // 0Ch: Alarm month + mask bit
   reg [7:0] 	 alarm_date;            // 0Dh: Alarm date + mask bit
   reg [7:0] 	 alarm_year;            // 0Eh: Alarm year + mask bit
   reg [7:0] 	 alarm_day_of_week;     // 0Fh: Alarm day of week + mask bit
   
   // Control Registers
   reg [7:0] 	 interrupt_mask_reg;    // 10h: Interrupt mask register (write)
   reg [7:0] 	 interrupt_status_reg;  // 10h: Interrupt status register (read)
   // A battery-backed chip runs from power-up, in 24-hour mode (TIME_RESET = 0).
   reg [7:0] 	 command_reg = TIME_RESET ? 8'h05 : 8'h0C; // 11h: Command register
   
   // Latched time data for stable reads
   reg [7:0] 	 latched_hundredths;
   reg [7:0] 	 latched_hours;
   reg [7:0] 	 latched_minutes;
   reg [7:0] 	 latched_seconds;
   reg [7:0] 	 latched_month;
   reg [7:0] 	 latched_date;
   reg [7:0] 	 latched_year;
   reg [7:0] 	 latched_day_of_week;
   reg 		 data_latched;
   
   //==============================================================================
   // Alarm Comparison Logic
   //==============================================================================
   
   wire 	 alarm_match =
		 (!alarm_hundredths[7]  && (latched_hundredths  == alarm_hundredths[6:0])  || alarm_hundredths[7]) &&
                 (!alarm_hours[7]       && (latched_hours       == alarm_hours[6:0])       || alarm_hours[7]) &&
                 (!alarm_minutes[7]     && (latched_minutes     == alarm_minutes[6:0])     || alarm_minutes[7]) &&
                 (!alarm_seconds[7]     && (latched_seconds     == alarm_seconds[6:0])     || alarm_seconds[7]) &&
                 (!alarm_month[7]       && (latched_month       == alarm_month[6:0])       || alarm_month[7]) &&
                 (!alarm_date[7]        && (latched_date        == alarm_date[6:0])        || alarm_date[7]) &&
                 (!alarm_year[7]        && (latched_year        == alarm_year[6:0])        || alarm_year[7]) &&
                 (!alarm_day_of_week[7] && (latched_day_of_week == alarm_day_of_week[6:0]) || alarm_day_of_week[7]);
   
   //==============================================================================
   // Support stuff for date
   //==============================================================================
   function is_leap;
      input integer y;
      begin
         // y is 0..99 meaning 19yy or 20yy. We'll treat 2000+ behaviour: leap years every 4.
         // For simple model: year divisible by 4 -> leap (correct for 1900/2000 edge not handled)
         is_leap = ((y % 4) == 0);
      end
   endfunction // is_leap
   
   function [5:0] days_in_month;
      input integer m;
      input integer y;
      begin
         case (m)
           1,3,5,7,8,10,12: days_in_month = 6'd31;
           4,6,9,11: days_in_month = 6'd30;
           2: days_in_month = (is_leap(y) ? 6'd29 : 6'd28);
           default: days_in_month = 6'd31;
         endcase
      end
   endfunction
   
   //==============================================================================
   // Clock Generation and Timing
   //==============================================================================
   
   // Oscillator frequency divider
   reg [31:0] osc_divider;
   wire       tick_100hz;
   
   // Crystal frequency selection from command register
   wire [1:0] crystal_freq_sel = command_reg[1:0];
   wire [31:0] osc_div_ratio;
   wire [6:0]  osc_div_reminder;
 
   assign osc_div_ratio  = (FREQ / 100);
   // FIXME: HANDLEME
   assign  osc_div_reminder = (FREQ % 100);    
   assign tick_100hz = TICK & (osc_divider == 31'd0);
   
   always @(posedge CLK) begin
      if (!RESETn) begin
	 osc_divider <= 32'h000000FF; // quick start
      end else if (TICK) begin
	 if (osc_divider == 32'h0000000) begin
            osc_divider <= osc_div_ratio - 1;
	 end else begin
            osc_divider <= osc_divider - 1;
	 end
      end
   end

   //==============================================================================
   // Interrupt Generation
   //==============================================================================
   
   wire interrupt_enable = command_reg[4];
   wire any_interrupt = |(interrupt_status_reg[6:0] & interrupt_mask_reg[6:0]);
   
   //==============================================================================
   // Time Counter Logic
   //==============================================================================
   
   // Simple binary increment function
   function [7:0] binary_increment;
      input [7:0] val;
      input [7:0] max_val;
      begin
         if (val >= max_val) begin
            binary_increment = 8'd0;
         end else begin
            binary_increment = val + 1;
         end
      end
   endfunction
   
   // Time counter updates
   wire run_enable = command_reg[3];  // Run/Stop bit
   wire hour_format = command_reg[2]; // 12/24 hour format
   reg [1:0] clear_irq_needed;
   
   
   always @(posedge CLK) begin
      if (!RESETn) begin
	 if (TIME_RESET) begin
	    counter_hundredths <= 8'd0;
            counter_seconds <= 8'd0;
            counter_minutes <= 8'd0;
            counter_hours <= 8'd0;
            counter_date <= 8'd1;
            counter_month <= 8'd1;
            counter_year <= 8'd0;
            counter_day_of_week <= 8'd0;
	 end
         interrupt_status_reg <= 8'd0;
         data_latched <= 1'b0;
	 clear_irq_needed <= 2'b0;
	 // TIME_RESET = 0: the chip keeps running through a machine reset; only its
	 // interrupt output is turned off, so a PROM starting over does not take
	 // the 100 Hz tick SunOS left enabled.
	 command_reg <= TIME_RESET ? 8'b00000101 : (command_reg & 8'hEF);
      end else begin
	 interrupt_status_reg[7] <= any_interrupt;
	 if (clear_irq_needed > 2'b00) begin
	    clear_irq_needed <= clear_irq_needed - 1;
	    if (clear_irq_needed == 2'b01) interrupt_status_reg <= 8'h00;
	 end
	 if (~RD & ~CS) begin
	    if (A == 5'h00) begin
               // Reading hundredths register - latch all time data
               latched_hundredths <= counter_hundredths;
               latched_hours <= counter_hours;
               latched_minutes <= counter_minutes;
               latched_seconds <= counter_seconds;
               latched_month <= counter_month;
               latched_date <= counter_date;
               latched_year <= counter_year;
               latched_day_of_week <= counter_day_of_week;
               data_latched <= 1'b1; // checkme: cannot go to 0 except on reset?
	    end // if (A == 5'h00)
	    if (A == 5'h10) begin
	       clear_irq_needed <= 2'b10; // wipe out in 2 cycles, after the host got the data
	    end
	 end
	 if (~WR & ~CS) begin
            case (A)
              5'h00: counter_hundredths <= D_IN;
              5'h01: counter_hours <= D_IN;
              5'h02: counter_minutes <= D_IN;
              5'h03: counter_seconds <= D_IN;
              5'h04: counter_month <= D_IN;
              5'h05: counter_date <= D_IN;
              5'h06: counter_year <= D_IN;
              5'h07: counter_day_of_week <= D_IN;
              5'h08: alarm_hundredths <= D_IN;
              5'h09: alarm_hours <= D_IN;
              5'h0A: alarm_minutes <= D_IN;
              5'h0B: alarm_seconds <= D_IN;
              5'h0C: alarm_month <= D_IN;
              5'h0D: alarm_date <= D_IN;
              5'h0E: alarm_year <= D_IN;
              5'h0F: alarm_day_of_week <= D_IN;
              5'h10: interrupt_mask_reg <= D_IN;
              5'h11: command_reg <= D_IN;
            endcase
	 end else if (run_enable & tick_100hz) begin
            interrupt_status_reg[1] <= 1'b1;  // 1/100 sec flag
	    
            // Hundredths of seconds counter (0-99)
            counter_hundredths <= binary_increment(counter_hundredths, 8'd99);
            if (counter_hundredths == 8'd99) begin
               interrupt_status_reg[3] <= 1'b1;  // Seconds flag
               
               // Seconds counter (0-59)
               counter_seconds <= binary_increment(counter_seconds, 8'd59);
               if (counter_seconds == 8'd59) begin
                  interrupt_status_reg[4] <= 1'b1;  // Minutes flag
                  
                  // Minutes counter (0-59)
                  counter_minutes <= binary_increment(counter_minutes, 8'd59);
                  if (counter_minutes == 8'd59) begin
		     interrupt_status_reg[5] <= 1'b1;  // Hours flag
                     
                     // Hours counter // TODO: hour_format (can be handled on read)
                     counter_hours <= binary_increment(counter_hours, 8'd23);
                     if (counter_hours == 8'd23) begin
			interrupt_status_reg[6] <= 1'b1;  // Days flag
			counter_day_of_week <= (counter_day_of_week >= 8'd6) ? 8'd0 : counter_day_of_week + 8'd1;   // was never advanced
			
			counter_date <= 1 + binary_increment(counter_date - 1, days_in_month(counter_month, counter_year) - 1);
			if (counter_date == days_in_month(counter_month, counter_year)) begin
			   
			   counter_month <= 1 + binary_increment(counter_month - 1, 11);
			   if (counter_month == 8'd12) begin   // was 11: the year turned at the end of November
			      counter_year <= binary_increment(counter_year, 99);
			   end
			end
                     end
                  end
               end
            end
            
            // Set 10Hz interrupt flag every 10 hundredths
            if (counter_hundredths % 10 == 9) begin
               interrupt_status_reg[2] <= 1'b1;  // 1/10 sec flag
            end
	 end // if (run_enable & tick_100hz)
	 if (alarm_match && interrupt_mask_reg[0]) begin
            interrupt_status_reg[0] <= 1'b1;  // Alarm flag
	 end
      end // else: !if(!RESETn)
      // Set from outside: last, so it wins over this clock's count.
      if (LOAD) begin
	 counter_hundredths  <= 8'd0;
	 counter_year        <= LOAD_TIME[55:48];
	 counter_month       <= LOAD_TIME[47:40];
	 counter_date        <= LOAD_TIME[39:32];
	 counter_day_of_week <= LOAD_TIME[31:24];
	 counter_hours       <= LOAD_TIME[23:16];
	 counter_minutes     <= LOAD_TIME[15:8];
	 counter_seconds     <= LOAD_TIME[7:0];
      end
   end

   //==============================================================================
   // Bus Interface Logic
   //==============================================================================
   
   // Data output multiplexer
   reg [7:0] data_out;
   wire      read_enable = !RD && !CS;
   
   always @(*) begin
      case (A)
        5'h00: data_out = data_latched ? latched_hundredths  : counter_hundredths;
        5'h01: data_out = data_latched ? latched_hours       : counter_hours;
        5'h02: data_out = data_latched ? latched_minutes     : counter_minutes;
        5'h03: data_out = data_latched ? latched_seconds     : counter_seconds;
        5'h04: data_out = data_latched ? latched_month       : counter_month;
        5'h05: data_out = data_latched ? latched_date        : counter_date;
        5'h06: data_out = data_latched ? latched_year        : counter_year;
        5'h07: data_out = data_latched ? latched_day_of_week : counter_day_of_week;
        5'h08: data_out = alarm_hundredths;
        5'h09: data_out = alarm_hours;
        5'h0A: data_out = alarm_minutes;
        5'h0B: data_out = alarm_seconds;
        5'h0C: data_out = alarm_month;
        5'h0D: data_out = alarm_date;
        5'h0E: data_out = alarm_year;
        5'h0F: data_out = alarm_day_of_week;
        5'h10: data_out = interrupt_status_reg;
        5'h11: data_out = 8'h00;  // Command register is write-only
        default: data_out = 8'h00;
      endcase
   end
   
   //==============================================================================
   // Output Assignments
   //==============================================================================
   
   // Bidirectional data bus
   assign D_OUT = data_out;
   assign D_EN = read_enable;
   
   // Interrupt output (open drain, active low)
   assign INTERRUPT = (interrupt_enable && any_interrupt) ? 1'b0 : 1'b1;
   
endmodule // icm7170

