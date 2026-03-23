// Copyright 2017 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

//------------------------------------------------------------------------------
// spi_flash_model.sv
//
// Minimal SPI flash behavioral model for PULPino RTL simulation.
//
// Supports the command subset required by
//   sw/apps/imperio_tests/testSPIMaster/testSPIMaster.c
// running on the PULPino SPI master peripheral.
//
// Supported commands
//   0x9F  RDID  – Read JEDEC ID; returns 0x0102_194D (Spansion S25FL-L)
//   0x06  WREN  – Write Enable (sets WEL latch)
//   0x05  RDSR1 – Read Status Register 1 (WIP bit 0; always returns 0 = idle)
//   0x35  RDCR  – Read Configuration Register 1 (bit2=0 = parameter at bottom)
//   0x71  WRAR  – Write to Any Register; used by test to enable/disable QPI
//   0x20  P4E   – Parameter 4 kB Sector Erase (erases 4 KB to 0xFF)
//   0x02  PP    – Page Program (write bytes into internal memory array)
//   0xEC  4QIOR – Quad I/O Read with 32-bit address and 10 dummy cycles
//
// Wiring in tb.sv
//   spi_clk     ← spi_master.clk
//   spi_csn     ← spi_master.csn
//   spi_padmode ← spi_master.padmode
//   spi_sdo     ← spi_master.sdo   (DUT output → flash input)
//   spi_sdi     → spi_master.sdi   (flash output → DUT input)
//
// Protocol assumptions
//   • SPI mode 0 (CPOL=0, CPHA=0): DUT samples sdi on posedge spi_clk.
//   • padmode[1:0] from the DUT indicates the current bus width:
//       2'b00  SPI_STD     – 1-bit MOSI (sdo[0]) / MISO (sdi[0])
//       2'b01  SPI_QUAD_TX – DUT driving 4-bit data on sdo[3:0]
//       2'b10  SPI_QUAD_RX – DUT receiving; flash drives sdi[3:0]
//   • The model follows padmode on every clock edge, so it automatically
//     handles mid-transaction mode switches (cmd→data on QRD transactions).
//
// Limitations
//   • Only 64 KB of memory is modelled (MEM_SIZE parameter).
//   • WIP is always returned as 0 (erase/program are instantaneous in sim).
//   • No timing checks; purely behavioural.
//   • Only CS0 is modelled.
//------------------------------------------------------------------------------

`timescale 1ns/1ps

module spi_flash_model
#(
  parameter int MEM_SIZE = 65536  // modelled flash size in bytes (64 KB)
)
(
  input  logic        spi_clk,
  input  logic        spi_csn,      // active-low chip select from DUT
  input  logic [1:0]  spi_padmode,  // bus-mode indicator from DUT
  input  logic [3:0]  spi_sdo,      // DUT SPI data outputs → flash inputs
  output logic [3:0]  spi_sdi       // flash SPI data outputs → DUT inputs
);

  timeunit      1ns;
  timeprecision 1ps;

  // -------------------------------------------------------------------------
  // SPI mode encodings (must match pulpino apb_spi_master)
  // -------------------------------------------------------------------------
  localparam logic [1:0] SPI_STD     = 2'b00;
  localparam logic [1:0] SPI_QUAD_TX = 2'b01;
  localparam logic [1:0] SPI_QUAD_RX = 2'b10;

  // -------------------------------------------------------------------------
  // JEDEC ID returned by this model (Spansion S25FL-L series)
  // -------------------------------------------------------------------------
  localparam logic [31:0] JEDEC_ID = 32'h0102_194D;

  // -------------------------------------------------------------------------
  // Internal memory array (initialized to 0xFF = erased state)
  // -------------------------------------------------------------------------
  logic [7:0] mem [0:MEM_SIZE-1];

  // -------------------------------------------------------------------------
  // Flash status flags
  // -------------------------------------------------------------------------
  logic wel;     // Write Enable Latch
  logic qpi_en;  // QPI (quad) mode enabled flag (informational)

  // -------------------------------------------------------------------------
  // Initialization
  // -------------------------------------------------------------------------
  initial begin : flash_init
    integer i;
    for (i = 0; i < MEM_SIZE; i++)
      mem[i] = 8'hFF;
    wel    = 1'b0;
    qpi_en = 1'b0;
    spi_sdi = 4'b0000;
  end

  // -------------------------------------------------------------------------
  // Helper tasks
  // -------------------------------------------------------------------------

  // recv_bits: receive 'n' bits from the DUT via sdo.
  //   Bits are shifted in MSB-first.
  //   Samples on posedge spi_clk, using padmode to determine bus width.
  //   Works for STD (1 bit/clk) and QUAD_TX (4 bits/clk).
  //   Returns the received value right-aligned in 'data'.
  task automatic recv_bits(input int n, output logic [63:0] data);
    int bits_done;
    bits_done = 0;
    data = '0;
    while (bits_done < n) begin
      @(posedge spi_clk);
      if (spi_padmode == SPI_QUAD_TX) begin
        data = {data[59:0], spi_sdo[3], spi_sdo[2], spi_sdo[1], spi_sdo[0]};
        bits_done += 4;
      end else begin
        // SPI_STD: 1 bit per clock on sdo[0]
        data = {data[62:0], spi_sdo[0]};
        bits_done += 1;
      end
    end
  endtask

  // send_bits: drive 'n' bits on sdi toward the DUT.
  //   Bits are sent MSB-first.
  //   All bits are driven on negedge spi_clk so data is stable before the
  //   DUT's posedge sample.  Waiting for the first negedge also guarantees
  //   that the DUT's padmode output has had time to settle from QUAD_TX to
  //   QUAD_RX (the DUT advances its state machine at posedge; padmode is
  //   updated combinationally and fully settled by the next negedge).
  //   Uses padmode to determine bus width:
  //     SPI_QUAD_RX → drive sdi[3:0] (4 bits/clk)
  //     SPI_STD     → drive sdi[0]   (1 bit/clk)
  task automatic send_bits(input int n, input logic [63:0] data);
    int         bits_done;
    logic [63:0] sr;
    // left-align data so bit [63] is the first bit to send
    sr = data << (64 - n);
    bits_done = 0;
    // Drive all bits on negedge (first negedge = right after last cmd posedge)
    while (bits_done < n) begin
      @(negedge spi_clk);
      if (spi_padmode == SPI_QUAD_RX) begin
        spi_sdi = {sr[63], sr[62], sr[61], sr[60]};
        sr = sr << 4;
        bits_done += 4;
      end else begin
        spi_sdi = {3'b000, sr[63]};
        sr = sr << 1;
        bits_done += 1;
      end
    end
  endtask

  // skip_clocks: consume 'n' clock cycles without sampling data.
  //   Used for dummy cycles in read commands.
  task automatic skip_clocks(input int n);
    repeat (n) @(posedge spi_clk);
  endtask

  // -------------------------------------------------------------------------
  // Main SPI transaction loop
  //
  // Implemented as an initial-forever loop so that local variables can be
  // declared inside (automatic storage) without ambiguity under all
  // SystemVerilog simulators.
  // -------------------------------------------------------------------------
  initial begin : spi_main
    forever begin : spi_txn
      // ---- automatic local variables for this transaction ----
      logic [63:0] raw;
      logic  [7:0] cmd;
      logic [31:0] addr;
      int          byte_addr;
      int          i;

      // Wait for chip-select assertion (active low)
      @(negedge spi_csn);
      #1;  // small setup delay after CSN falls

      spi_sdi = 4'b0000;

      // ------------------------------------------------------------------
      // Receive 8-bit command (MSB first).
      // padmode tells us bus width; both STD and QUAD_TX are handled by
      // recv_bits transparently.
      // ------------------------------------------------------------------
      recv_bits(8, raw);
      cmd = raw[7:0];

      // ------------------------------------------------------------------
      // Dispatch on command
      // ------------------------------------------------------------------
      case (cmd)

        // ------ 0x9F: Read JEDEC ID ----------------------------------------
        // No address, no dummy; drive 32-bit ID MSB-first.
        // Works for SPI_CMD_RD (STD) and SPI_CMD_QRD (QUAD).
        8'h9F: begin
          send_bits(32, {32'b0, JEDEC_ID});
          // Wait for CS deassert (DUT may still clock after reading 32 bits)
          @(posedge spi_csn);
        end

        // ------ 0x06: Write Enable -----------------------------------------
        // Command only; sets WEL latch.
        8'h06: begin
          wel = 1'b1;
          @(posedge spi_csn);
        end

        // ------ 0x05: Read Status Register 1 (SR1) -------------------------
        // Drive 8-bit status: bit0 = WIP (always 0 = idle in this model),
        //                     bit1 = WEL.
        8'h05: begin
          send_bits(8, {56'b0, 6'b0, wel, 1'b0});
          @(posedge spi_csn);
        end

        // ------ 0x35: Read Configuration Register 1 (CR1) -----------------
        // Bit 2 = 0 → parameter sectors at bottom (required by test).
        // All other bits returned as 0.
        8'h35: begin
          send_bits(8, 64'h00);
          @(posedge spi_csn);
        end

        // ------ 0x71: Write to Any Register (WRAR) -------------------------
        // Test uses this to enable/disable QPI (address 0x800003XX).
        // We accept the 32-bit address word and toggle qpi_en for the
        // QPI-enable register addresses.
        8'h71: begin
          recv_bits(32, raw);
          addr = raw[31:0];
          // Address 0x80000348 = enable QPI; 0x80000308 = disable QPI.
          // Model tracks the flag for information only; the DUT's padmode
          // output already drives the actual bus mode.
          if      (addr == 32'h8000_0348) qpi_en = 1'b1;
          else if (addr == 32'h8000_0308) qpi_en = 1'b0;
          // Other register writes (page-size, etc.) are silently accepted.
          wel = 1'b0;  // clear WEL after any register write
          @(posedge spi_csn);
        end

        // ------ 0x20: Parameter 4 kB Sector Erase (P4E) -------------------
        // 24-bit byte address follows.  The DUT packs it as top 24 bits of
        // the address register (addr_reg = address<<8, sent as 24 bits),
        // so the received 24 bits equal the byte address directly.
        8'h20: begin
          recv_bits(24, raw);
          byte_addr = int'(raw[23:0]);
          // Erase 4 KB starting at 4 KB-aligned base
          byte_addr = byte_addr & ~(4096 - 1);
          for (i = 0; i < 4096; i++) begin
            if ((byte_addr + i) < MEM_SIZE)
              mem[byte_addr + i] = 8'hFF;
          end
          wel = 1'b0;  // clear WEL after erase
          @(posedge spi_csn);
        end

        // ------ 0x02: Page Program (PP) ------------------------------------
        // 24-bit byte address then data bytes until CS deasserts.
        // Uses bitwise AND with existing contents: NOR-flash program can only
        // clear bits (0→0) without an erase; it cannot set bits (0→1).
        8'h02: begin : pp_cmd
          logic [63:0] bval;
          int          idx;
          recv_bits(24, raw);
          byte_addr = int'(raw[23:0]);
          idx = byte_addr;
          // Receive data bytes until CSN goes high
          fork : pp_fork
            begin
              forever begin
                recv_bits(8, bval);
                if ((idx >= 0) && (idx < MEM_SIZE))
                  mem[idx] = mem[idx] & bval[7:0];
                idx++;
              end
            end
            @(posedge spi_csn);
          join_any
          disable pp_fork;
          wel = 1'b0;
          // CSN is already high (posedge spi_csn triggered join_any exit)
        end  // pp_cmd

        // ------ 0xEC: 4-byte address Quad I/O Read (4QIOR) ----------------
        // Protocol: cmd(8) addr(32) dummy(10) data(N×8)
        // padmode: QUAD_TX for cmd/addr/dummy, QUAD_RX for data.
        8'hEC: begin : qior_cmd
          logic [63:0] outval;
          int          idx;
          // Receive 32-bit address in QUAD_TX
          recv_bits(32, raw);
          byte_addr = int'(raw[31:0]);
          // Consume 10 dummy clock cycles
          skip_clocks(10);
          // Data phase: drive bytes until CS deasserts (padmode = QUAD_RX)
          idx = byte_addr;
          fork : qior_fork
            begin
              forever begin
                if ((idx >= 0) && (idx < MEM_SIZE))
                  outval = {56'b0, mem[idx]};
                else
                  outval = {56'b0, 8'hFF};
                send_bits(8, outval);
                idx++;
              end
            end
            @(posedge spi_csn);
          join_any
          disable qior_fork;
          spi_sdi = 4'b0000;
          // CSN is already high
        end  // qior_cmd

        // ------ Unknown command: wait for CS high and ignore ---------------
        default: begin
          $display("%t [spi_flash_model] WARNING: unknown command 0x%02X – ignoring",
                   $time, cmd);
          @(posedge spi_csn);
        end

      endcase

      spi_sdi = 4'b0000;

    end  // forever spi_txn
  end  // initial spi_main

endmodule
