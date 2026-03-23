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
// Interface: spi_slave
// ============================================================
// This interface is declared in pulpino/tb/if_spi_slave.sv and is
// instantiated in pulpino/tb/tb.sv as:
//
//   spi_slave spi_master();
//
// Despite the instance name "spi_master", the *type* is spi_slave.
// The testbench uses it to model an external SPI device (e.g. a flash chip)
// that the PULPino SoC's SPI master peripheral communicates with.
//
// Signal directions (from the SoC's perspective):
//   clk      – SPI clock driven by the SoC SPI master output
//   csn      – chip-select driven by the SoC SPI master output (active-low)
//   padmode  – current transfer mode driven by the SoC SPI master output:
//                SPI_STD     (2'b00) – single-bit MOSI/MISO
//                SPI_QUAD_TX (2'b01) – SoC transmits on all 4 sdo lines
//                SPI_QUAD_RX (2'b10) – SoC receives on all 4 sdi lines
//   sdo[3:0] – data driven *by the SoC* toward the external device (MOSI / IO0-IO3)
//   sdi[3:0] – data driven *by the external device* toward the SoC (MISO / IO0-IO3)
//
// In tb.sv the interface is wired to the PULPino SPI master pins:
//   .spi_master_clk_o  ( spi_master.clk      )
//   .spi_master_csn0_o ( spi_master.csn      )
//   .spi_master_mode_o ( spi_master.padmode  )
//   .spi_master_sdo0_o ( spi_master.sdo[0]   )  // MOSI / IO0
//   .spi_master_sdo1_o ( spi_master.sdo[1]   )  // IO1
//   .spi_master_sdo2_o ( spi_master.sdo[2]   )  // IO2
//   .spi_master_sdo3_o ( spi_master.sdo[3]   )  // IO3
//   .spi_master_sdi0_i ( spi_master.sdi[0]   )  // MISO / IO0
//   .spi_master_sdi1_i ( spi_master.sdi[1]   )  // IO1
//   .spi_master_sdi2_i ( spi_master.sdi[2]   )  // IO2
//   .spi_master_sdi3_i ( spi_master.sdi[3]   )  // IO3
//
// Usage model – connecting spi_flash_responder to this interface:
//   spi_flash_responder flash_i (
//       .spi_clk    ( spi_master.clk     ),
//       .spi_csn    ( spi_master.csn     ),
//       .spi_padmode( spi_master.padmode ),
//       .spi_sdo    ( spi_master.sdo     ),
//       .spi_sdi    ( spi_master.sdi     )
//   );
//
// Slave tasks
// -----------
// wait_csn(v) – block until csn == v.
//
// send(use_quad, data[]) – drive sdi[0] (standard) with the bit-array
//     'data', LSB of the array first.  'use_quad' parameter is accepted
//     but quad output is NOT implemented in this task (see note below).
//
// NOTE: The spi_slave.send task only drives sdi[0] and iterates from
//       data[data.size()-1] down to data[0].  It does NOT support quad
//       output on sdi[3:0].  For quad (QPI) responses use spi_flash_responder
//       which drives sdi[3:0] directly.
// ============================================================

interface spi_slave
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
  // Slave Tasks
  //---------------------------------------------------------------------------

  // Block until csn equals csn_in.
  task wait_csn(logic csn_in);
    if (csn_in) begin
      if (~csn)
        wait(csn);
    end else begin
      if (csn)
        wait(~csn);
    end
  endtask

  // Drive sdi[0] with the contents of 'data', one bit per clock cycle.
  // Iterates from data[data.size()-1] down to data[0] (LSB-index first).
  // 'use_quad' is accepted for interface compatibility but only sdi[0] is
  // driven; quad output must be handled externally (see spi_flash_responder).
  task send(input logic use_quad, input logic data[]);
    for (int i = data.size()-1; i >= 0; i--)
    begin
      sdi[0] = data[i];
      clock(1);
    end
  endtask

  // Wait for 'cycles' rising edges of clk (driven by the SoC).
  task clock(input int cycles);
    for(int i = 0; i < cycles; i++)
    begin
      if (clk) begin
        wait (~clk);
      end

      wait (clk);
    end
  endtask
endinterface
