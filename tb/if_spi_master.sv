// Copyright 2017 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// ============================================================
// Interface: spi_bus_master  (fixed version)
// ============================================================
// This interface is declared in pulpino/tb/if_spi_master.sv.
// It is NOT directly used in pulpino/tb/tb.sv (which uses spi_slave instead).
// It is provided here as a reference / alternative for testbenches that need a
// bus-master-side view, e.g. when the testbench itself is the SPI master and
// needs to send/receive to a DUT acting as an SPI slave.
//
// Signal directions (from the testbench master's perspective):
//   clk      – SPI clock, driven by this master
//   csn      – chip-select driven by this master (active-low)
//   padmode  – current transfer mode driven by this master:
//                SPI_STD     (2'b00) – single-bit MOSI/MISO
//                SPI_QUAD_TX (2'b01) – master transmits on all 4 sdo lines
//                SPI_QUAD_RX (2'b10) – master receives on all 4 sdi lines
//   sdo[3:0] – data driven *by the master* toward the slave (MOSI / IO0-IO3)
//   sdi[3:0] – data driven *by the slave* toward the master (MISO / IO0-IO3)
//
// ============================================================
// BUG FIXES applied to the original pulpino/tb/if_spi_master.sv
// ============================================================
//
// The original file contained off-by-one index errors in the send and
// receive tasks for both standard and quad modes.  The bugs cause out-of-
// bounds array accesses and incorrect bit ordering.
//
// Standard-mode send (original buggy code):
//   for (int i = data.size(); i > 0; i--)
//     sdo[0] = data[i];           // BUG: data[data.size()] is out of bounds
//                                 //      on the first iteration; should be
//                                 //      data[i-1]
//
// Standard-mode receive (original buggy code):
//   for (int i = data.size(); i > 0; i--)
//     data[i] = sdi[0];           // BUG: same out-of-bounds issue;
//                                 //      should be data[i-1]
//
// Quad-mode send (original buggy code):
//   sdo[j] = data[4*i-j+1];      // BUG: for i=data.size()/4 and j<=1 this
//                                 //      exceeds the array bounds.
//                                 //      Correct formula: data[4*(i-1)+j]
//
// Quad-mode receive (original buggy code):
//   data[4*i-j+1] = sdi[j];      // BUG: same wrong formula.
//                                 //      Correct formula: data[4*(i-1)+j]
//
// Derivation of the correct quad index  data[4*(i-1)+j]
// -------------------------------------------------------
// The outer loop runs i from data.size()/4 down to 1.
// In each iteration the 4 bits of the nibble for group (i-1) are transferred,
// with sdo[3]/sdi[3] carrying the most-significant bit of that nibble.
// Group (i-1) occupies indices [4*(i-1) .. 4*(i-1)+3] in the array, so:
//   sdo[j] <-> data[4*(i-1)+j]   for j in {0,1,2,3}
//
// Cross-check with tb_spi_pkg.sv (which drives raw signals directly and is
// known-correct):
//   spi_sdo3 = command[4*i-1]   == data[4*(i-1)+3]  (j=3)  ✓
//   spi_sdo2 = command[4*i-2]   == data[4*(i-1)+2]  (j=2)  ✓
//   spi_sdo1 = command[4*i-3]   == data[4*(i-1)+1]  (j=1)  ✓
//   spi_sdo0 = command[4*i-4]   == data[4*(i-1)+0]  (j=0)  ✓
// ============================================================

interface spi_bus_master
  #(
    parameter period = 50ns
  );

  timeunit      1ns;
  timeprecision 1ps;

  localparam SPI_STD     = 2'b00;
  localparam SPI_QUAD_TX = 2'b01;
  localparam SPI_QUAD_RX = 2'b10;

  logic       clk;
  logic [3:0] sdo;
  logic [3:0] sdi;
  logic       csn;
  logic [1:0] padmode;

  //---------------------------------------------------------------------------
  // Master Tasks
  //---------------------------------------------------------------------------

  // Assert / deassert chip-select.
  task set_csn(logic csn_in);
    #(period/2);
    csn = csn_in;
    #(period/2);
  endtask

  // Send 'data' to the slave.
  // Standard mode (use_quad==0):
  //   Iterates i from data.size() down to 1 and drives sdo[0] = data[i-1].
  //   This sends data[data.size()-1] first and data[0] last (one bit/cycle).
  // Quad mode (use_quad==1):
  //   Iterates i from data.size()/4 down to 1; in each cycle drives 4 bits:
  //     sdo[3]=data[4*(i-1)+3]  sdo[2]=data[4*(i-1)+2]
  //     sdo[1]=data[4*(i-1)+1]  sdo[0]=data[4*(i-1)+0]
  //   Bit group (i-1) is driven first, so data[data.size()-1] is the first
  //   bit on sdo[3] (MSB of first nibble).
  task send(input logic use_quad, input logic data[]);
    if (use_quad)
    begin
      padmode = SPI_QUAD_TX;
      for (int i = data.size()/4; i > 0; i--)
      begin
        for (int j = 3; j >= 0; j-- )
          sdo[j] = data[4*(i-1)+j];   // fixed: was data[4*i-j+1]

        clock(1);
      end
    end else begin
      padmode = SPI_STD;
      for (int i = data.size(); i > 0; i--)
      begin
        sdo[0] = data[i-1];           // fixed: was data[i]
        clock(1);
      end
    end
  endtask

  // Receive data from the slave into 'data'.
  // Standard mode (use_quad==0):
  //   Iterates i from data.size() down to 1 and captures data[i-1] = sdi[0].
  // Quad mode (use_quad==1):
  //   Iterates i from data.size()/4 down to 1; each cycle captures 4 bits:
  //     data[4*(i-1)+3]=sdi[3]  data[4*(i-1)+2]=sdi[2]
  //     data[4*(i-1)+1]=sdi[1]  data[4*(i-1)+0]=sdi[0]
  task receive(input logic use_quad, output logic data[]);
    if (use_quad)
    begin
      padmode = SPI_QUAD_RX;
      for (int i = data.size()/4; i > 0; i--)
      begin
        for (int j = 3; j >= 0; j-- )
          data[4*(i-1)+j] = sdi[j];   // fixed: was data[4*i-j+1]

        clock(1);
      end
    end else begin
      padmode = SPI_STD;
      for (int i = data.size(); i > 0; i--)
      begin
        data[i-1] = sdi[0];           // fixed: was data[i]
        clock(1);
      end
    end
  endtask

  // Toggle the SPI clock for 'cycles' full cycles.
  // Clock starts low; each cycle: rising edge, then falling edge.
  task clock(input int cycles);
    for(int i = 0; i < cycles; i++)
    begin
      #(period/2) clk = 1;
      #(period/2) clk = 0;
    end
  endtask
endinterface
