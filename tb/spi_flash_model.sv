// Copyright 2017 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// ----------------------------------------------------------------------------
// Minimal behavioral SPI flash model for PULPino testbench
//
// Emulates a Spansion S25FL128S-like NOR flash (JEDEC ID 0x0102194D).
// The model is sufficient to pass sw/apps/imperio_tests/testSPIMaster.
//
// Supported commands
//   0x9F  RDID   - 4-byte JEDEC ID read  (returns JEDEC_ID parameter)
//   0x06  WREN   - set Write Enable Latch
//   0x05  RDSR1  - status register 1: WIP always 0, bit[1]=WEL
//   0x35  RDCR   - config register 1: bit[2]=0 => param sectors at bottom
//   0x71  WRAR   - write any register (accepted silently; see QPI notes below)
//   0x20  P4E    - 4 kB parameter sector erase (3-byte address)
//   0xD8  SE     - 64 kB sector erase          (3-byte address)
//   0x02  PP     - page program                (3-byte address + data)
//   0xEC  4QIOR  - quad I/O read, 4-byte addr, 10 dummy clocks (QPI)
//   0x13  4READ  - standard read, 4-byte addr  (testbench SPI-boot verify)
//
// QPI enable / disable notes
//   The real flash uses WRAR to address 0x00800003 (CR2V bit 6 = QUAD) to
//   toggle QPI mode.  This model does NOT need to track that register bit
//   because it infers the wire protocol from spi_padmode:
//     2'b00 (SPI_STD)     => 1-wire SPI  (1 bit / clock)
//     2'b01 (SPI_QUAD_TX) => 4-wire QPI  (4 bits / clock, master writes)
//     2'b10 (SPI_QUAD_RX) => 4-wire QPI  (4 bits / clock, flash writes)
//   WRAR transactions are accepted and logged; padmode drives the behaviour.
//
// Parameters
//   JEDEC_ID         - 32-bit ID returned by 0x9F; default 0x0102194D
//   FLASH_SIZE_BYTES - internal storage size;     default 64 kB
//
// Wiring in tb.sv (see tb.sv for the complete instantiation block):
//   spi_flash_model flash_model_i (
//     .spi_clk     ( spi_master.clk     ),
//     .spi_csn     ( spi_master.csn     ),
//     .spi_padmode ( spi_master.padmode ),
//     .spi_sdo     ( spi_master.sdo     ),   // MOSI - from PULPino master
//     .spi_sdi     ( spi_master.sdi     )    // MISO - to   PULPino master
//   );
// ----------------------------------------------------------------------------

module spi_flash_model #(
  parameter integer FLASH_SIZE_BYTES = 65536,       // 64 kB internal storage
  parameter [31:0]  JEDEC_ID         = 32'h0102194D // Spansion S25FL128S-like
) (
  input  wire        spi_clk,     // SCK  from PULPino SPI master
  input  wire        spi_csn,     // CSN  (active-low) from PULPino SPI master
  input  wire [1:0]  spi_padmode, // mode from PULPino SPI master interface
  input  wire [3:0]  spi_sdo,     // IO[3:0] driven by PULPino master (MOSI dir.)
  output logic [3:0] spi_sdi      // IO[3:0] driven by this model   (MISO dir.)
);

  // --------------------------------------------------------------------------
  // Padmode encodings - mirror if_spi_slave.sv / if_spi_master.sv
  // --------------------------------------------------------------------------
  localparam SPI_STD     = 2'b00; // standard SPI : 1 bit  per clock
  localparam SPI_QUAD_TX = 2'b01; // quad TX      : 4 bits per clock (master drives)
  localparam SPI_QUAD_RX = 2'b10; // quad RX      : 4 bits per clock (flash drives)

  // --------------------------------------------------------------------------
  // Flash memory array (NOR: erase sets 0xFF; program ANDs new data in)
  // --------------------------------------------------------------------------
  logic [7:0] mem [0:FLASH_SIZE_BYTES-1];

  // Write Enable Latch
  logic wel;

  // Initialise
  initial begin : init_mem
    integer k;
    for (k = 0; k < FLASH_SIZE_BYTES; k = k + 1)
      mem[k] = 8'hFF;
    wel     = 1'b0;
    spi_sdi = 4'hZ;
  end

  // ==========================================================================
  // Helper tasks
  // ==========================================================================

  // --------------------------------------------------------------------------
  // recv_cmd_byte_with_mode
  //   Waits for the first SCK posedge, reads padmode to determine protocol,
  //   captures the full 8-bit command, and returns use_quad.
  //   use_quad=1 => QPI (4 bits/clock on sdo[3:0])
  //   use_quad=0 => standard SPI (1 bit/clock on sdo[0])
  // --------------------------------------------------------------------------
  task automatic recv_cmd_byte_with_mode;
    output logic [7:0] cmd;
    output logic       use_quad;
    logic [7:0] shift;
    integer     rem;
  begin
    shift = 8'h00;

    // First rising edge: latch padmode and capture first bits
    @(posedge spi_clk or posedge spi_csn);
    if (spi_csn) begin cmd = 8'hFF; use_quad = 1'b0; return; end

    use_quad = (spi_padmode == SPI_QUAD_TX);

    if (use_quad) begin
      shift = {4'h0, spi_sdo[3:0]}; // 4 bits captured; 4 more needed
      rem   = 4;
    end else begin
      shift = {7'h0, spi_sdo[0]};   // 1 bit captured;  7 more needed
      rem   = 7;
    end

    while (rem > 0) begin
      @(posedge spi_clk or posedge spi_csn);
      if (spi_csn) break;
      if (use_quad) begin
        shift = {shift[3:0], spi_sdo[3:0]};
        rem   = rem - 4;
      end else begin
        shift = {shift[6:0], spi_sdo[0]};
        rem   = rem - 1;
      end
    end

    cmd = shift;
  end
  endtask

  // --------------------------------------------------------------------------
  // recv_bits_n
  //   Receive n bits MSB-first from sdo.
  //   QPI: 4 bits/clock on sdo[3:0];  STD: 1 bit/clock on sdo[0].
  //   Returns value right-justified in val[63:0]; exits early on CSN.
  // --------------------------------------------------------------------------
  task automatic recv_bits_n;
    input  integer      n;
    input  logic        use_quad;
    output logic [63:0] val;
    integer rem;
  begin
    val = 64'h0;
    rem = n;
    while (rem > 0) begin
      @(posedge spi_clk or posedge spi_csn);
      if (spi_csn) break;
      if (use_quad) begin
        val = {val[59:0], spi_sdo[3:0]};
        rem = rem - 4;
      end else begin
        val = {val[62:0], spi_sdo[0]};
        rem = rem - 1;
      end
    end
  end
  endtask

  // --------------------------------------------------------------------------
  // send_bits_n
  //   Drive n bits of val MSB-first on sdi.
  //   SPI mode-0 timing:
  //     - First bit/nibble is driven immediately (setup before next posedge).
  //     - Subsequent bits/nibbles are changed on negedge (stable by posedge).
  //     - After the last bit the task waits for its sampling posedge, then
  //       tri-states sdi.
  // --------------------------------------------------------------------------
  task automatic send_bits_n;
    input integer      n;
    input logic [63:0] val;
    input logic        use_quad;
    integer rem;
  begin
    rem = n;

    // Drive the first nibble/bit right now (before any clock edge)
    if (use_quad) begin
      spi_sdi = val[rem-1 -: 4];
      rem     = rem - 4;
    end else begin
      spi_sdi = {3'b000, val[rem-1]};
      rem     = rem - 1;
    end

    while (rem > 0) begin
      @(posedge spi_clk or posedge spi_csn); // master samples current bit
      if (spi_csn) break;
      @(negedge spi_clk or posedge spi_csn); // change on falling edge
      if (spi_csn) break;
      if (use_quad) begin
        spi_sdi = val[rem-1 -: 4];
        rem     = rem - 4;
      end else begin
        spi_sdi = {3'b000, val[rem-1]};
        rem     = rem - 1;
      end
    end

    // Wait for the last bit/nibble to be sampled
    @(posedge spi_clk or posedge spi_csn);
    spi_sdi = 4'hZ;
  end
  endtask

  // --------------------------------------------------------------------------
  // skip_clocks
  //   Skip n SCK rising edges (dummy cycles between address and data).
  // --------------------------------------------------------------------------
  task automatic skip_clocks;
    input integer n;
    integer k;
  begin
    for (k = 0; k < n; k = k + 1) begin
      @(posedge spi_clk or posedge spi_csn);
      if (spi_csn) break;
    end
  end
  endtask

  // --------------------------------------------------------------------------
  // recv_data_to_mem
  //   Receive data bytes from the SPI master and program them into mem[].
  //   Runs until spi_csn deasserts.  Returns number of bytes written.
  //   NOR-flash semantics: programming ANDs new data with current content
  //   (can only clear bits; erase sets them back to 1).
  // --------------------------------------------------------------------------
  task automatic recv_data_to_mem;
    input  integer start_addr;
    input  logic   use_quad;
    output integer bytes_written;
    integer   addr;
    logic [7:0] bval;
    integer     i;        // bit index for std-mode byte assembly
    logic       aborted;  // set when CSN fires mid-byte
  begin
    addr          = start_addr;
    bytes_written = 0;
    bval          = 8'h00;

    while (!spi_csn && (addr < FLASH_SIZE_BYTES)) begin
      bval    = 8'h00;
      aborted = 1'b0;

      if (use_quad) begin
        // High nibble
        @(posedge spi_clk or posedge spi_csn);
        if (spi_csn) begin aborted = 1'b1; end
        else         bval[7:4] = spi_sdo[3:0];
        // Low nibble (only if not aborted)
        if (!aborted) begin
          @(posedge spi_clk or posedge spi_csn);
          if (spi_csn) begin aborted = 1'b1; end
          else         bval[3:0] = spi_sdo[3:0];
        end
      end else begin
        // 8 individual bits, MSB first
        for (i = 7; i >= 0 && !aborted; i = i - 1) begin
          @(posedge spi_clk or posedge spi_csn);
          if (spi_csn) aborted = 1'b1;
          else         bval[i] = spi_sdo[0];
        end
      end

      if (!aborted) begin
        mem[addr] = mem[addr] & bval; // NOR AND-program
        addr          = addr + 1;
        bytes_written = bytes_written + 1;
      end else begin
        break; // CSN went high mid-byte; discard partial byte
      end
    end
  end
  endtask

  // --------------------------------------------------------------------------
  // send_data_from_mem
  //   Drive bytes from mem[start_addr] onto sdi until spi_csn deasserts.
  //   Timing:
  //     - Called right after skip_clocks(), which returns at a posedge.
  //     - We wait for one negedge before driving the first nibble/bit so that
  //       the data is stable well before the master's sampling posedge.
  //   QPI mode (use_quad=1):  4 bits/clock on sdi[3:0], nibble-per-nibble.
  //   STD mode (use_quad=0):  1 bit/clock  on sdi[0],   bit-per-bit.
  // --------------------------------------------------------------------------
  task automatic send_data_from_mem;
    input integer start_addr;
    input logic   use_quad;
    integer   addr;
    logic [7:0] bval;
    integer     i;       // bit index for std-mode output
    logic       done;    // set to exit the loop cleanly
  begin
    addr = start_addr;
    done = 1'b0;

    // Wait for negedge before driving the first data bit/nibble
    @(negedge spi_clk or posedge spi_csn);
    if (spi_csn) begin spi_sdi = 4'hZ; return; end

    while (!done && !spi_csn && (addr < FLASH_SIZE_BYTES)) begin
      bval = mem[addr];
      addr = addr + 1;

      if (use_quad) begin
        // -------------------------------------------------------
        // Quad mode: drive high nibble, sample, negedge, low nibble
        // -------------------------------------------------------
        spi_sdi = bval[7:4]; // high nibble setup (at negedge time)
        @(posedge spi_clk or posedge spi_csn); // master samples high nibble
        if (spi_csn) begin done = 1'b1; break; end
        @(negedge spi_clk or posedge spi_csn);
        if (spi_csn) begin done = 1'b1; break; end
        spi_sdi = bval[3:0]; // low nibble setup
        @(posedge spi_clk or posedge spi_csn); // master samples low nibble
        if (spi_csn) begin done = 1'b1; break; end
        // negedge for next byte (drives next high nibble at loop top)
        @(negedge spi_clk or posedge spi_csn);
        if (spi_csn) begin done = 1'b1; break; end
        // Loop iterates: spi_sdi assigned to next bval[7:4] at top

      end else begin
        // -------------------------------------------------------
        // Standard mode: 8 bits, MSB first; change on negedge
        // -------------------------------------------------------
        for (i = 7; i >= 0 && !done; i = i - 1) begin
          spi_sdi = {3'b000, bval[i]};
          @(posedge spi_clk or posedge spi_csn); // master samples
          if (spi_csn) begin done = 1'b1; break; end
          if (i > 0) begin
            @(negedge spi_clk or posedge spi_csn);
            if (spi_csn) begin done = 1'b1; break; end
          end
        end
        // After last bit sampled, wait for negedge before next byte
        if (!done && !spi_csn && (addr < FLASH_SIZE_BYTES)) begin
          @(negedge spi_clk or posedge spi_csn);
          if (spi_csn) done = 1'b1;
        end
      end
    end

    spi_sdi = 4'hZ;
  end
  endtask

  // ==========================================================================
  // Main transaction loop
  // ==========================================================================
  initial begin : main_loop
    forever begin
      // Wait for chip-select assertion (negedge of active-low CSN)
      @(negedge spi_csn);
      spi_sdi = 4'hZ;

      process_transaction();

      // Ensure CSN is deasserted before trying to start the next transaction
      if (!spi_csn)
        @(posedge spi_csn);
      spi_sdi = 4'hZ;
    end
  end

  // --------------------------------------------------------------------------
  // process_transaction - decode and handle one complete SPI transaction
  // --------------------------------------------------------------------------
  task automatic process_transaction;
    // ---- local variables (declared at top of task, not inside case arms) ----
    logic  [7:0] cmd;
    logic        use_quad;   // inferred from padmode at first SCK edge
    logic [63:0] addr_raw;
    logic [31:0] addr;
    integer      bw;         // bytes written counter (PP command)
    integer      erase_base; // aligned base address for erase operations
    integer      k;          // loop index for erase fill
  begin
    // Step 1: receive command byte and learn the wire protocol
    recv_cmd_byte_with_mode(cmd, use_quad);
    if (spi_csn) return; // aborted during command reception

    $display("[FLASH] t=%0t  cmd=0x%02X  %s",
             $time, cmd, use_quad ? "QPI" : "STD");

    case (cmd)

      // --------------------------------------------------------------------
      // 0x9F  RDID - Read JEDEC Identification (4 bytes)
      //   Returns Manufacturer (0x01) | MemType (0x02) | Cap (0x19) | 0x4D
      //   = 0x0102194D.  testSPIMaster checks this exact value in both STD
      //   and QPI modes.
      // --------------------------------------------------------------------
      8'h9F: begin
        send_bits_n(32, {32'h0, JEDEC_ID}, use_quad);
      end

      // --------------------------------------------------------------------
      // 0x06  WREN - Set Write Enable Latch
      // --------------------------------------------------------------------
      8'h06: begin
        wel = 1'b1;
        $display("[FLASH] WREN - WEL set");
      end

      // --------------------------------------------------------------------
      // 0x05  RDSR1 - Read Status Register 1
      //   Bit[1] = WEL, Bit[0] = WIP (always 0: operations complete instantly)
      // --------------------------------------------------------------------
      8'h05: begin
        send_bits_n(8, {56'h0, 6'h0, wel, 1'b0}, use_quad);
      end

      // --------------------------------------------------------------------
      // 0x35  RDCR - Read Configuration Register 1
      //   Bit[2] = TB: 0 => parameter sectors at bottom (what the test needs)
      //   All other bits 0.
      // --------------------------------------------------------------------
      8'h35: begin
        send_bits_n(8, 64'h0, use_quad);
      end

      // --------------------------------------------------------------------
      // 0x71  WRAR - Write to Any Register
      //   Wire format: CMD(8b) + 4-byte field = [31:8] reg_addr | [7:0] data
      //   (PULPino driver encodes both address and data in the 32-bit addr
      //   field with addr_len=32 and data_len=0.)
      //   QPI toggling: this model ignores the register value; the wire
      //   protocol is fully controlled by spi_padmode from the SPI master.
      //   WEL is consumed (cleared) on any write command.
      // --------------------------------------------------------------------
      8'h71: begin
        recv_bits_n(32, use_quad, addr_raw);
        if (!spi_csn) begin
          $display("[FLASH] WRAR reg=0x%06X data=0x%02X (protocol via padmode)",
                   addr_raw[31:8], addr_raw[7:0]);
          wel = 1'b0;
        end
      end

      // --------------------------------------------------------------------
      // 0x20  P4E - Parameter 4 kB Sector Erase (3-byte address)
      //   Erases the 4 kB block containing the given address.
      //   Only executes when WEL=1; always clears WEL afterwards.
      // --------------------------------------------------------------------
      8'h20: begin
        recv_bits_n(24, use_quad, addr_raw);
        addr = {8'h0, addr_raw[23:0]};
        if (wel) begin
          erase_base = {addr[31:12], 12'h000}; // 4 kB-aligned
          for (k = erase_base;
               (k < erase_base + 4096) && (k < FLASH_SIZE_BYTES);
               k = k + 1)
            mem[k] = 8'hFF;
          $display("[FLASH] P4E erased 4 kB @ 0x%06X", erase_base);
        end
        wel = 1'b0;
      end

      // --------------------------------------------------------------------
      // 0xD8  SE - Uniform 64 kB Sector Erase (3-byte address)
      // --------------------------------------------------------------------
      8'hD8: begin
        recv_bits_n(24, use_quad, addr_raw);
        addr = {8'h0, addr_raw[23:0]};
        if (wel) begin
          erase_base = {addr[31:16], 16'h0000}; // 64 kB-aligned
          for (k = erase_base;
               (k < erase_base + 65536) && (k < FLASH_SIZE_BYTES);
               k = k + 1)
            mem[k] = 8'hFF;
          $display("[FLASH] SE erased 64 kB @ 0x%06X", erase_base);
        end
        wel = 1'b0;
      end

      // --------------------------------------------------------------------
      // 0x02  PP - Page Program (3-byte address + data until CSN)
      //   NOR-flash AND-programming: erase before programming.
      // --------------------------------------------------------------------
      8'h02: begin
        recv_bits_n(24, use_quad, addr_raw);
        addr = {8'h0, addr_raw[23:0]};
        bw   = 0;
        if (wel)
          recv_data_to_mem(addr, use_quad, bw);
        wel = 1'b0;
        $display("[FLASH] PP  wrote %0d bytes @ 0x%06X", bw, addr);
      end

      // --------------------------------------------------------------------
      // 0xEC  4QIOR - Quad I/O Read, 4-byte address, 10 dummy clocks
      //   Used by testSPIMaster flash_read_qpi() and flash_check().
      // --------------------------------------------------------------------
      8'hEC: begin
        recv_bits_n(32, use_quad, addr_raw);
        addr = addr_raw[31:0];
        skip_clocks(10);                    // 10 dummy clock cycles
        send_data_from_mem(addr, use_quad);
      end

      // --------------------------------------------------------------------
      // 0x13  4READ - Standard read with 4-byte address (no dummy cycles)
      //   Used by the PULPino testbench for SPI-boot memory verification.
      // --------------------------------------------------------------------
      8'h13: begin
        recv_bits_n(32, use_quad, addr_raw);
        addr = addr_raw[31:0];
        skip_clocks(0);
        send_data_from_mem(addr, use_quad);
      end

      // --------------------------------------------------------------------
      // Unknown command
      // --------------------------------------------------------------------
      default: begin
        $display("[FLASH] WARNING t=%0t  UNKNOWN cmd=0x%02X - ignored",
                 $time, cmd);
      end

    endcase

    // Wait for CSN to deassert if the handler returned before it did
    if (!spi_csn)
      @(posedge spi_csn);
  end
  endtask

endmodule
