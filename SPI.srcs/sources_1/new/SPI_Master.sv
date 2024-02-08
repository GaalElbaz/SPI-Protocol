`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: SPI_Master
// thanks for nandland for providing most of the code.
//////////////////////////////////////////////////////////////////////////////////


module SPI_Master
  #(parameter SPI_MODE = 0, // SPI mode (0, 1, 2, or 3)
    parameter CLKS_PER_HALF_BIT = 2) // Clocks per half bit for SPI clock generation
  (
   // Control/Data Signals,
   input        i_Rst_L,     // FPGA Reset
   input        i_Clk,       // FPGA Clock
   
   // TX (MOSI) Signals
   input [7:0]  i_TX_Byte,        // Byte to transmit on MOSI
   input        i_TX_DV,          // Data Valid Pulse with i_TX_Byte
   output logic   o_TX_Ready,       // Transmit Ready for next byte
   
   // RX (MISO) Signals
   output logic       o_RX_DV,     // Data Valid pulse (1 clock cycle)
   output logic [7:0] o_RX_Byte,   // Byte received on MISO

   // SPI Interface
   output logic o_SPI_Clk,   // Generated SPI Clock
   input      i_SPI_MISO, // MISO signal from slave
   output logic o_SPI_MOSI  // MOSI signal to slave
   );

  // SPI Interface (All Runs at SPI Clock Domain)
  logic w_CPOL;     // Clock polarity, sets the polarity of the clock signal during the idle state.
  logic w_CPHA;     // Clock phase, selects the clock phase. Depending on the CPHA bit, the rising or falling clock edge is used to sample and/or shift the data. 

  logic [$clog2(CLKS_PER_HALF_BIT*2)-1:0] r_SPI_Clk_Count; // Counter for SPI clock generation
  logic r_SPI_Clk;  // SPI clock signal
  logic [4:0] r_SPI_Clk_Edges; // Number of clock edges
  logic r_Leading_Edge;  // Flag indicating leading edge of clock
  logic r_Trailing_Edge; // Flag indicating trailing edge of clock
  logic       r_TX_DV;    // Transmit Data Valid signal
  logic [7:0] r_TX_Byte;  // Byte to transmit

  logic [2:0] r_RX_Bit_Count;
  logic [2:0] r_TX_Bit_Count;
  
  // CPOL: Clock Polarity
  // CPOL=0 means clock idles at 0, leading edge is rising edge.
  // CPOL=1 means clock idles at 1, leading edge is falling edge.
  assign w_CPOL  = (SPI_MODE == 2) | (SPI_MODE == 3); // Calculate CPOL based on SPI mode

  // CPHA: Clock Phase
  // CPHA=0 means the "out" side changes the data on trailing edge of clock
  //              the "in" side captures data on leading edge of clock
  // CPHA=1 means the "out" side changes the data on leading edge of clock
  //              the "in" side captures data on the trailing edge of clock
  assign w_CPHA  = (SPI_MODE == 1) | (SPI_MODE == 3); // Calculate CPHA based on SPI mode

  // Purpose: Generate SPI Clock correct number of times when DV pulse comes
  always @(posedge i_Clk or negedge i_Rst_L)
  begin
    if (~i_Rst_L) // Reset state
    begin
      o_TX_Ready      <= 1'b0;   // Set TX ready signal to 0
      r_SPI_Clk_Edges <= 16;     // Initialize clock edge count,  always 16
      r_Leading_Edge  <= 1'b0;   // Initialize leading edge flag
      r_Trailing_Edge <= 1'b0;   // Initialize trailing edge flag
      r_SPI_Clk       <= w_CPOL; // Initialize SPI clock to CPOL value
      r_SPI_Clk_Count <= 0;      // Initialize clock count
    end
    else // Normal operation
    begin

      // Default assignments
      r_Leading_Edge  <= 1'b0; // Reset leading edge flag
      r_Trailing_Edge <= 1'b0; // Reset trailing edge flag
      
      if (i_TX_DV) // If TX data valid -> there are bits to transmit -> generate clock
      begin
        o_TX_Ready      <= 1'b0;   // Set TX ready signal to 0
        r_SPI_Clk_Edges <= 16;     // Initialize clock edge count for new transmission
      end
      else if (r_SPI_Clk_Edges > 0) // If there are remaining clock edges for current transmission
      begin
        o_TX_Ready <= 1'b0; // Set TX ready signal to 0
        
        if (r_SPI_Clk_Count == CLKS_PER_HALF_BIT*2-1) // If reached end of half bit period -> a full bit got transmitted, toggle clock.
        begin
          r_SPI_Clk_Edges <= r_SPI_Clk_Edges - 1'b1; // Decrement clock edge count
          r_Trailing_Edge <= 1'b1; // Set trailing edge flag
          r_SPI_Clk_Count <= 0;    // Reset clock count
          r_SPI_Clk       <= ~r_SPI_Clk; // Toggle SPI clock
        end
        else if (r_SPI_Clk_Count == CLKS_PER_HALF_BIT-1) // If reached mid-point of half bit period
        begin
          r_SPI_Clk_Edges <= r_SPI_Clk_Edges - 1'b1; // Decrement clock edge count
          r_Leading_Edge  <= 1'b1; // Set leading edge flag
          r_SPI_Clk_Count <= r_SPI_Clk_Count + 1'b1; // Increment clock count
          r_SPI_Clk       <= ~r_SPI_Clk; // Toggle SPI clock (?)
        end
        else // Otherwise, continue counting clock cycles
        begin
          r_SPI_Clk_Count <= r_SPI_Clk_Count + 1'b1; // Increment clock count
        end
      end  
      else // If there are no remaining clock edges -> all bits were transmited
      begin
        o_TX_Ready <= 1'b1; // Set TX ready signal to 1
      end
    end // else: !if(~i_Rst_L)
  end // always @ (posedge i_Clk or negedge i_Rst_L)


  // Purpose: Register i_TX_Byte when Data Valid is pulsed.
  // Keeps local storage of byte in case higher level module changes the data
  always @(posedge i_Clk or negedge i_Rst_L)
  begin
    if (~i_Rst_L) // Reset state
    begin
      r_TX_Byte <= 8'h00; // Initialize TX byte to 0
      r_TX_DV   <= 1'b0;   // Reset TX data valid signal
    end
    else // Normal operation
      begin
        r_TX_DV <= i_TX_DV; // Delay TX data valid signal by 1 clock cycle
        if (i_TX_DV) // If TX data valid
        begin
          r_TX_Byte <= i_TX_Byte; // Register TX byte
        end
      end // else: !if(~i_Rst_L)
  end // always @ (posedge i_Clk or negedge i_Rst_L)


  // Purpose: Generate MOSI data
  // Works with both CPHA=0 and CPHA=1
  always @(posedge i_Clk or negedge i_Rst_L)
  begin
    if (~i_Rst_L) // Reset state
    begin
      o_SPI_MOSI     <= 1'b0; // Initialize MOSI to 0
      r_TX_Bit_Count <= 3'b111; // Start sending MSb first
    end
    else // Normal operation
    begin
      // If ready is high, reset bit counts to default
      if (o_TX_Ready) // If ready to transmit
      begin
        r_TX_Bit_Count <= 3'b111; // Reset bit count
      end
      // Catch the case where we start transaction and CPHA = 0
      else if (r_TX_DV & ~w_CPHA) // If data valid and clock phase is 0
      begin
        o_SPI_MOSI     <= r_TX_Byte[3'b111]; // Send MSb of the byte
        r_TX_Bit_Count <= 3'b110; // Decrement bit count after sending MSb
      end
      else if ((r_Leading_Edge & w_CPHA) | (r_Trailing_Edge & ~w_CPHA)) // Normal data transmission
      begin
        // For each clock edge, transmit the next bit of the byte
        r_TX_Bit_Count <= r_TX_Bit_Count - 1'b1; // Move to the next bit
        o_SPI_MOSI     <= r_TX_Byte[r_TX_Bit_Count]; // Send the corresponding bit
      end
    end
  end


  // Purpose: Read in MISO data.
  always @(posedge i_Clk or negedge i_Rst_L)
  begin
    if (~i_Rst_L) // Reset state
    begin
      o_RX_Byte      <= 8'h00; // Initialize RX byte to 0
      o_RX_DV        <= 1'b0;   // Reset RX data valid signal
      r_RX_Bit_Count <= 3'b111; // Start with MSb for RX byte
    end
    else // Normal operation
    begin

      // Default Assignments
      o_RX_DV   <= 1'b0; // Reset RX data valid signal

      if (o_TX_Ready) // If ready to transmit, reset bit count to default
      begin
        r_RX_Bit_Count <= 3'b111; // Reset bit count
      end
      else if ((r_Leading_Edge & ~w_CPHA) | (r_Trailing_Edge & w_CPHA)) // If leading edge for CPOL=0 or trailing edge for CPOL=1
      begin
        o_RX_Byte[r_RX_Bit_Count] <= i_SPI_MISO;  // Sample data from MISO line
        r_RX_Bit_Count            <= r_RX_Bit_Count - 1'b1; // Move to the next bit
        if (r_RX_Bit_Count == 3'b000) // If reached end of byte
        begin
          o_RX_DV   <= 1'b1;   // Byte done, pulse Data Valid
        end
      end
    end
  end
  
  
  // Purpose: Add clock delay to signals for alignment.
  always @(posedge i_Clk or negedge i_Rst_L)
  begin
    if (~i_Rst_L) // Reset state
    begin
      o_SPI_Clk  <= w_CPOL; // Initialize SPI clock with CPOL value
    end
    else // Normal operation
      begin
        o_SPI_Clk <= r_SPI_Clk; // Delay SPI clock by one clock cycle
      end // else: !if(~i_Rst_L)
  end // always @ (posedge i_Clk or negedge i_Rst_L)
  

endmodule // SPI_Master

