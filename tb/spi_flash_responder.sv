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
// Module: spi_flash_responder
// ============================================================
// Minimal SPI flash behavioral model for use in ModelSim RTL simulation.
// Connects directly to the spi_slave interface signals used in
// pulpino/tb/tb.sv to emulate an external SPI flash device.
//
// Designed to satisfy the pulpino imperio SPI master test
// (sw/apps/imperio_tests/testSPIMaster/testSPIMaster.c):
//   - check_standard_mode: RDID, WREN
//   - check_qpi_mode:      RDID, WREN, WRAR (QPI enable/disable),
//                          P4E, PP, 4QIOR (quad read), RDSR1, RDCR
//
// ============================================================
// Usage in tb.sv  (add inside the module, after spi_slave instantiation)
// ============================================================
//   spi_flash_responder #(
//       .MEM_DEPTH ( 65536        ),
//       .JEDEC_ID  ( 32'h0102194D )
//   ) flash_i (
//       .spi_clk    ( spi_master.clk     ),
//       .spi_csn    ( spi_master.csn     ),
//       .spi_padmode( spi_master.padmode ),
//       .spi_sdo    ( spi_master.sdo     ),
//       .spi_sdi    ( spi_master.sdi     )
//   );
//
// ============================================================
// Signal directions
// ============================================================
//   spi_clk    – SPI clock, driven by the SoC SPI master (input to flash)
//   spi_csn    – chip-select, active-low, driven by SoC (input to flash)
//   spi_padmode– current pad mode from the SoC SPI master output:
//                  2'b00 (SPI_STD)     single-bit standard SPI
//                  2'b01 (SPI_QUAD_TX) SoC drives all 4 sdo[3:0] lines
//                  2'b10 (SPI_QUAD_RX) SoC reads all 4 sdi[3:0] lines
//   spi_sdo    – data from SoC to flash (MOSI in std, IO0-IO3 in quad)
//   spi_sdi    – data from flash to SoC (MISO in std, IO0-IO3 in quad)
//
// ============================================================
// Supported commands
// ============================================================
//   0x9F – RDID : Read JEDEC Identification (returns JEDEC_ID parameter)
//   0x06 – WREN : Write Enable (sets Write Enable Latch)
//   0x05 – RDSR1: Read Status Register 1 (WIP always 0 in simulation)
//   0x35 – RDCR : Read Configuration Register (returns 0x00; bit 2 = 0
//                  indicates parameter sectors at bottom, as the test requires)
//   0x71 – WRAR : Write Any Register (4-byte address field; used by the test
//                  to enable/disable QPI and set 512-byte page size; the
//                  responder accepts these writes without error)
//   0x20 – P4E  : Parameter 4 kB Sector Erase (fills 4 kB with 0xFF)
//   0xD8 – SE   : Uniform 64 kB Sector Erase (fills 64 kB with 0xFF)
//   0x02 – PP   : Page Program (writes bytes to internal memory array)
//   0xEC – 4QIOR: Quad I/O Read, 4-byte address (responds on sdi[3:0]);
//                  dummy cycles are handled via padmode transition detection
//
// ============================================================
// Bit ordering
// ============================================================
// All transfers follow standard SPI convention: MSB first.
//
// Standard receive (SPI_STD, command/address/write-data phases):
//   For each bit period: sample spi_sdo[0] on posedge spi_clk, MSB first.
//   An N-bit field is received by shifting into bits [N-1 .. 0].
//
// Standard transmit (SPI_STD, read-data phase):
//   Drive spi_sdi[0] with the next response bit BEFORE each posedge spi_clk
//   so the SoC can sample it.  MSB is driven first.
//
// Quad receive (SPI_QUAD_TX, padmode driven by SoC):
//   4 bits per clock: spi_sdo[3]=MSB of nibble, spi_sdo[0]=LSB of nibble.
//   High nibble is clocked before low nibble.
//
// Quad transmit (SPI_QUAD_RX, padmode driven by SoC):
//   Drive spi_sdi[3:0] with the next 4 response bits before each posedge.
//   High nibble (bits[7:4]) before low nibble (bits[3:0]).
//
// ============================================================
// QPI mode handling
// ============================================================
// The SoC's SPI master sets spi_padmode = SPI_QUAD_TX when it is driving
// the bus (command, address, write data) and SPI_QUAD_RX when it expects
// a read response.  The responder uses spi_padmode at the start of each
// transaction to decide whether to decode command/address in standard or
// quad mode.
//
// For read responses in quad mode the responder waits until spi_padmode
// transitions to SPI_QUAD_RX (which naturally covers the programmed dummy
// cycles) before driving spi_sdi[3:0].
//
// For read responses in standard mode the responder begins driving spi_sdi[0]
// immediately after receiving the command byte (padmode stays SPI_STD
// throughout; dummy cycles are not inserted for standard reads in the test).
// ============================================================

module spi_flash_responder
  #(
    parameter int          MEM_DEPTH = 65536,        // bytes; must be power of 2
    parameter logic [31:0] JEDEC_ID  = 32'h0102_194D // Spansion S25FS-S family
  )
  (
    input  logic       spi_clk,
    input  logic       spi_csn,
    input  logic [1:0] spi_padmode,
    input  logic [3:0] spi_sdo,   // SoC → flash
    output logic [3:0] spi_sdi    // flash → SoC
  );

  timeunit      1ns;
  timeprecision 1ps;

  localparam SPI_STD     = 2'b00;
  localparam SPI_QUAD_TX = 2'b01;
  localparam SPI_QUAD_RX = 2'b10;

  // Internal memory (simulates flash storage, initialised to erased state)
  logic [7:0] mem [0:MEM_DEPTH-1];

  // Write Enable Latch; set by WREN (0x06), cleared after program/erase
  logic wel;

  // ------------------------------------------------------------------ //
  // Initialisation
  // ------------------------------------------------------------------ //
  initial begin : init
    integer i;
    for (i = 0; i < MEM_DEPTH; i = i + 1)
      mem[i] = 8'hFF;
    wel     = 1'b0;
    spi_sdi = 4'b0;
  end

  // ------------------------------------------------------------------ //
  // Helper: receive N bits in standard mode (sdo[0], MSB first)
  //   Returns the value in the N LSBs of 'data'.
  // ------------------------------------------------------------------ //
  task automatic rx_std(output logic [31:0] data, input int n_bits);
    data = 32'b0;
    for (int i = n_bits - 1; i >= 0; i--) begin
      @(posedge spi_clk);
      data[i] = spi_sdo[0];
    end
  endtask

  // ------------------------------------------------------------------ //
  // Helper: receive N nibbles in quad mode (sdo[3:0], MSB nibble first)
  //   n_nibbles must equal n_bits/4 for the field being received.
  //   Returns the value in the (n_nibbles*4) LSBs of 'data'.
  // ------------------------------------------------------------------ //
  task automatic rx_quad(output logic [31:0] data, input int n_nibbles);
    data = 32'b0;
    for (int i = n_nibbles - 1; i >= 0; i--) begin
      @(posedge spi_clk);
      data[4*i+3] = spi_sdo[3];
      data[4*i+2] = spi_sdo[2];
      data[4*i+1] = spi_sdo[1];
      data[4*i+0] = spi_sdo[0];
    end
  endtask

  // ------------------------------------------------------------------ //
  // Helper: transmit N bits in standard mode (sdi[0], MSB first)
  //   Drive each bit BEFORE the posedge so the SoC samples it.
  // ------------------------------------------------------------------ //
  task automatic tx_std(input logic [31:0] data, input int n_bits);
    for (int i = n_bits - 1; i >= 0; i--) begin
      spi_sdi[0] = data[i];
      @(posedge spi_clk);
    end
    spi_sdi = 4'b0;
  endtask

  // ------------------------------------------------------------------ //
  // Helper: transmit a byte in quad mode (sdi[3:0], MSB nibble first)
  //   Waits until spi_padmode == SPI_QUAD_RX before starting, which
  //   transparently absorbs any configured dummy cycles.
  //   Drive each nibble BEFORE the posedge so the SoC samples it.
  // ------------------------------------------------------------------ //
  task automatic tx_byte_quad(input logic [7:0] bval);
    // Drive high nibble, wait for SoC to sample
    spi_sdi = bval[7:4];
    @(posedge spi_clk);
    // Drive low nibble, wait for SoC to sample
    spi_sdi = bval[3:0];
    @(posedge spi_clk);
    spi_sdi = 4'b0;
  endtask

  // ------------------------------------------------------------------ //
  // Helper: wait until spi_padmode transitions to SPI_QUAD_RX
  //   (absorbs dummy clock cycles generated by the SoC SPI master)
  // ------------------------------------------------------------------ //
  task automatic wait_for_quad_rx();
    while (spi_padmode != SPI_QUAD_RX && !spi_csn)
      @(posedge spi_clk);
  endtask

  // ------------------------------------------------------------------ //
  // Helper: receive one byte using current padmode
  //   Standard: 8 clock cycles on sdo[0]
  //   Quad TX:  2 clock cycles on sdo[3:0]
  // ------------------------------------------------------------------ //
  task automatic rx_byte_auto(output logic [7:0] bval);
    logic [31:0] tmp;
    if (spi_padmode == SPI_QUAD_TX) begin
      rx_quad(tmp, 2);
    end else begin
      rx_std(tmp, 8);
    end
    bval = tmp[7:0];
  endtask

  // ------------------------------------------------------------------ //
  // Helper: receive a 24-bit address using current padmode
  // ------------------------------------------------------------------ //
  task automatic rx_addr24(output logic [23:0] addr);
    logic [31:0] tmp;
    if (spi_padmode == SPI_QUAD_TX)
      rx_quad(tmp, 6);    // 24 bits = 6 nibbles
    else
      rx_std(tmp, 24);
    addr = tmp[23:0];
  endtask

  // ------------------------------------------------------------------ //
  // Helper: receive a 32-bit address using current padmode
  // ------------------------------------------------------------------ //
  task automatic rx_addr32(output logic [31:0] addr);
    if (spi_padmode == SPI_QUAD_TX)
      rx_quad(addr, 8);   // 32 bits = 8 nibbles
    else
      rx_std(addr, 32);
  endtask

  // ------------------------------------------------------------------ //
  // Main transaction loop
  // ------------------------------------------------------------------ //
  initial begin : main_loop
    logic [7:0]  cmd;
    logic [31:0] addr32;
    logic [23:0] addr24;
    logic [31:0] wrar_addr;
    logic [7:0]  bval;
    integer      addr_idx;

    forever begin
      // Wait for chip-select assertion (CSn low = start of transaction)
      wait (!spi_csn);

      // -------------------------------------------------------------- //
      // Receive command byte
      // Check padmode at transaction start: QUAD_TX means QPI mode.
      // -------------------------------------------------------------- //
      rx_byte_auto(cmd);

      // -------------------------------------------------------------- //
      // Dispatch on command
      // -------------------------------------------------------------- //
      case (cmd)

        // ------------------------------------------------------------ //
        // 0x9F – RDID: Read JEDEC Identification
        //   Returns the 32-bit JEDEC_ID parameter (MSB first).
        //   Standard: 32 bits on sdi[0].
        //   QPI:      wait for QUAD_RX padmode then 8 nibbles on sdi[3:0].
        // ------------------------------------------------------------ //
        8'h9F: begin
          if (spi_padmode == SPI_QUAD_TX || spi_padmode == SPI_QUAD_RX) begin
            wait_for_quad_rx();
            for (int i = 7; i >= 0; i--) begin
              spi_sdi = JEDEC_ID[4*i+3 -: 4]; // bits [4*i+3 : 4*i], MSB nibble first
              @(posedge spi_clk);
            end
            spi_sdi = 4'b0;
          end else begin
            // Standard mode: drive immediately after command is received
            tx_std(JEDEC_ID, 32);
          end
        end

        // ------------------------------------------------------------ //
        // 0x06 – WREN: Write Enable
        //   Sets the Write Enable Latch; no data phase.
        // ------------------------------------------------------------ //
        8'h06: begin
          wel = 1'b1;
        end

        // ------------------------------------------------------------ //
        // 0x71 – WRAR: Write Any Register
        //   The test encodes both the 3-byte register address and the
        //   1-byte register value in the 32-bit address field
        //   (spi_setup_cmd_addr(0x71, 8, reg_addr_and_val, 32)).
        //   No separate data phase (spi_set_datalen(0)).
        //
        //   Register writes recognised:
        //     addr[31:8] == 24'h800003, addr[7:0] == 8'h48  → QPI enable
        //     addr[31:8] == 24'h800003, addr[7:0] == 8'h08  → QPI disable
        //     addr[31:8] == 24'h800004, addr[7:0] == 8'h10  → page size 512B
        //   All are accepted silently; the responder tracks QPI state via
        //   the spi_padmode signal so no internal QPI flag is needed.
        // ------------------------------------------------------------ //
        8'h71: begin
          rx_addr32(wrar_addr);
          // Accept the write silently; padmode from the SoC already
          // reflects whether subsequent transactions use quad signalling.
        end

        // ------------------------------------------------------------ //
        // 0x05 – RDSR1: Read Status Register 1
        //   Bit 0 = WIP (write-in-progress).  Operations complete
        //   instantly in simulation so WIP is always 0.
        //   Returns 0x00 (8 bits).
        // ------------------------------------------------------------ //
        8'h05: begin
          if (spi_padmode == SPI_QUAD_TX || spi_padmode == SPI_QUAD_RX) begin
            wait_for_quad_rx();
            tx_byte_quad(8'h00);
          end else begin
            tx_std(32'h0, 8);
          end
        end

        // ------------------------------------------------------------ //
        // 0x35 – RDCR: Read Configuration Register 1
        //   Bit 2 selects parameter-sector location:
        //     0 = parameter sectors at the BOTTOM (required by the test)
        //     1 = parameter sectors at the top  (test would abort)
        //   Always returns 0x00 (bit 2 = 0).
        // ------------------------------------------------------------ //
        8'h35: begin
          tx_std(32'h0, 8);
        end

        // ------------------------------------------------------------ //
        // 0x20 – P4E: Parameter 4 kB Sector Erase
        //   Receives a 24-bit byte address (3 bytes).
        //   Erases the aligned 4 kB sector containing that address.
        //   Requires WEL; clears WEL after completion.
        // ------------------------------------------------------------ //
        8'h20: begin
          rx_addr24(addr24);
          if (wel) begin
            addr_idx = addr24 & ~24'hFFF;    // 4 kB aligned (clear lower 12 bits)
            for (int i = 0; i < 4096; i++)
              mem[(addr_idx + i) & (MEM_DEPTH - 1)] = 8'hFF;
            wel = 1'b0;
          end
        end

        // ------------------------------------------------------------ //
        // 0xD8 – SE: Uniform 64 kB Sector Erase
        //   Receives a 24-bit byte address.
        //   Erases the aligned 64 kB sector containing that address.
        //   Requires WEL; clears WEL after completion.
        // ------------------------------------------------------------ //
        8'hD8: begin
          rx_addr24(addr24);
          if (wel) begin
            addr_idx = addr24 & ~24'hFFFF;   // 64 kB aligned (clear lower 16 bits)
            for (int i = 0; i < 65536; i++)
              mem[(addr_idx + i) & (MEM_DEPTH - 1)] = 8'hFF;
            wel = 1'b0;
          end
        end

        // ------------------------------------------------------------ //
        // 0x02 – PP: Page Program
        //   Receives a 24-bit byte address then a stream of data bytes
        //   until CSn is deasserted.
        //   Writes are AND-ed with existing memory contents (flash behaviour).
        //   Requires WEL; clears WEL after completion.
        //
        //   The SoC uses SPI_CMD_QWR so padmode = SPI_QUAD_TX throughout.
        // ------------------------------------------------------------ //
        8'h02: begin
          rx_addr24(addr24);
          addr_idx = addr24;
          if (wel) begin
            while (!spi_csn) begin
              rx_byte_auto(bval);
              // Guard: CSn may have risen during the last byte receive
              if (!spi_csn) begin
                mem[addr_idx & (MEM_DEPTH - 1)] =
                    mem[addr_idx & (MEM_DEPTH - 1)] & bval;
                addr_idx = addr_idx + 1;
              end
            end
            wel = 1'b0;
          end
        end

        // ------------------------------------------------------------ //
        // 0xEC – 4QIOR: Quad I/O Read, 4-byte address
        //   Receives a 32-bit byte address in quad mode (8 nibble-clocks).
        //   Waits for spi_padmode to transition to SPI_QUAD_RX, which
        //   transparently absorbs any configured dummy cycles (the test
        //   uses spi_setup_dummy(10, 0) → 10 dummy clocks).
        //   Then drives memory bytes on sdi[3:0] until CSn is deasserted.
        //
        //   Only used in QPI mode (SPI_CMD_QRD from SoC), so padmode
        //   will be SPI_QUAD_TX when the command is received.
        // ------------------------------------------------------------ //
        8'hEC: begin
          rx_addr32(addr32);
          addr_idx = addr32;
          // Absorb dummy cycles: wait for SoC to switch to receive mode
          wait_for_quad_rx();
          // Stream data until chip-select is deasserted
          while (!spi_csn) begin
            bval = mem[addr_idx & (MEM_DEPTH - 1)];
            // High nibble
            spi_sdi = bval[7:4];
            @(posedge spi_clk);
            if (spi_csn) break;
            // Low nibble
            spi_sdi = bval[3:0];
            @(posedge spi_clk);
            if (spi_csn) break;
            addr_idx = addr_idx + 1;
          end
          spi_sdi = 4'b0;
        end

        // ------------------------------------------------------------ //
        // Unknown command – ignore and wait for CSn deassert
        // ------------------------------------------------------------ //
        default: begin
          // Nothing to do; fall through to the wait(spi_csn) below
        end

      endcase

      // Wait for chip-select deassert (end of transaction)
      wait (spi_csn);
      spi_sdi = 4'b0;

    end // forever
  end // initial

endmodule
