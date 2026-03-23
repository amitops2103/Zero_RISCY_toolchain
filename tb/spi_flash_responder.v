// Copyright 2017 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// ---------------------------------------------------------------------------
// spi_flash_responder.v
//
// Minimal behavioral SPI flash model for PULPino testSPIMaster simulation.
//
// Responds to the commands used by sw/apps/imperio_tests/testSPIMaster:
//   0x9F  READ JEDEC ID       -> returns 0x01, 0x02, 0x19
//   0x05  READ STATUS REG 1   -> returns {7'b0, wip}
//   0x06  WRITE ENABLE        -> sets WEL flag
//   0xD8  SECTOR ERASE        -> clears 64 kB sector, sets WIP then clears it
//   0x02  PAGE PROGRAM        -> writes up to 256 bytes, sets WIP then clears it
//   0x03  READ DATA           -> sequential byte read
//   0x71  WRITE REGISTER      -> QPI-enable command (enter quad mode)
//
// Quad/QPI mode (IO[3:0]):
//   After command 0x71 the responder switches to 4-bit data for reads and writes.
//   The DQ bus must be wired as bidirectional in the testbench (see guide).
//
// Limitations:
//   - No real timing (WIP clears after ERASE_DELAY / PROG_DELAY clock cycles).
//   - No deep-power-down, OTP, or security register support.
//   - Memory size fixed at FLASH_DEPTH bytes (default 16 MB).
//   - Intended for functional simulation only; not for timing sign-off.
//
// Usage (standard SPI, from testbench):
//   spi_flash_responder #(.JEDEC_ID(24'h010219)) u_flash (
//       .sck  (spi_master_clk_o),
//       .csn  (spi_master_csn0_o),
//       .mosi (spi_master_sdo0_o),
//       .miso (spi_master_sdi0_i)
//   );
//
// See docs/spi/spi_flash_model_guide.md for full wiring guidance including
// quad IO lines.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module spi_flash_responder #(
    // JEDEC manufacturer + device ID bytes [23:0].
    // testSPIMaster expects 0x010219 (Spansion S25FL128P).
    parameter [23:0] JEDEC_ID   = 24'h010219,
    // Continuation/4th ID byte returned after the 3-byte JEDEC ID.
    parameter [7:0]  JEDEC_EXT  = 8'h4D,
    // Total flash size in bytes (default 16 MB).
    parameter integer FLASH_DEPTH = 16 * 1024 * 1024,
    // Simulated WIP clear delay in clock cycles after ERASE command.
    parameter integer ERASE_DELAY = 200,
    // Simulated WIP clear delay in clock cycles after PROGRAM command.
    parameter integer PROG_DELAY  = 20
) (
    input  wire sck,   // SPI clock (CPOL=0, CPHA=0 – Mode 0)
    input  wire csn,   // Chip select, active low
    input  wire mosi,  // Master-out/slave-in (DQ0 in standard mode)
    output wire miso   // Master-in/slave-out  (DQ1 in standard mode)
);

    // -----------------------------------------------------------------------
    // Internal memory
    // -----------------------------------------------------------------------
    reg [7:0] mem [0:FLASH_DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < FLASH_DEPTH; i = i + 1)
            mem[i] = 8'hFF;  // erased state
    end

    // -----------------------------------------------------------------------
    // Shift-register state
    // -----------------------------------------------------------------------
    reg [7:0]  shift_in;     // incoming byte, assembled MSB-first
    reg [7:0]  shift_out;    // outgoing byte, driven MSB-first
    reg [2:0]  bit_cnt;      // counts 0..7 within a byte
    reg [7:0]  byte_cnt;     // counts bytes within a transaction

    // -----------------------------------------------------------------------
    // Command/address/data state machine
    // -----------------------------------------------------------------------
    localparam ST_IDLE    = 3'd0;
    localparam ST_CMD     = 3'd1;
    localparam ST_ADDR    = 3'd2;
    localparam ST_DATA_RD = 3'd3;
    localparam ST_DATA_WR = 3'd4;
    localparam ST_JEDEC   = 3'd5;
    localparam ST_STATUS  = 3'd6;

    reg [2:0]  state;
    reg [7:0]  cmd_reg;
    reg [23:0] addr_reg;
    reg [7:0]  page_buf [0:255];
    reg [7:0]  page_len;

    // -----------------------------------------------------------------------
    // Flash flags
    // -----------------------------------------------------------------------
    reg wip;    // Write In Progress
    reg wel;    // Write Enable Latch
    reg qpi_en; // QPI (quad) mode enable

    // -----------------------------------------------------------------------
    // MISO output register
    // -----------------------------------------------------------------------
    reg miso_reg;
    assign miso = (csn) ? 1'bz : miso_reg;

    // -----------------------------------------------------------------------
    // WIP auto-clear task (uses $time-based delay)
    // -----------------------------------------------------------------------
    task automatic clear_wip_after(input integer delay_cycles);
        integer d;
        begin
            // Wait for 'delay_cycles' rising edges of sck, then clear WIP.
            // Simple approximation: use #(delay_cycles * 20) ns (assumes ~50 MHz).
            d = delay_cycles * 20;
            #d wip = 1'b0;
        end
    endtask

    // -----------------------------------------------------------------------
    // SCK rising edge – sample MOSI, assemble incoming byte
    // -----------------------------------------------------------------------
    always @(posedge sck or posedge csn) begin
        if (csn) begin
            // CS deasserted: reset bit/byte counters, latch any completed page write
            if (state == ST_DATA_WR && cmd_reg == 8'h02 && wel) begin
                // Commit page buffer to memory
                for (i = 0; i < page_len; i = i + 1)
                    mem[(addr_reg + i) % FLASH_DEPTH] = page_buf[i];
                wip <= 1'b1;
                wel <= 1'b0;
                fork
                    clear_wip_after(PROG_DELAY);
                join_none
            end
            bit_cnt  <= 3'd7;
            byte_cnt <= 8'd0;
            shift_in <= 8'd0;
            state    <= ST_CMD;
        end else begin
            // Sample MOSI on rising SCK
            shift_in <= {shift_in[6:0], mosi};

            if (bit_cnt == 3'd0) begin
                // A full byte has been received
                bit_cnt <= 3'd7;
                case (state)
                    ST_CMD: begin
                        cmd_reg  <= {shift_in[6:0], mosi};
                        byte_cnt <= 8'd0;
                        case ({shift_in[6:0], mosi})
                            8'h9F: begin
                                // READ JEDEC ID
                                shift_out <= JEDEC_ID[23:16];
                                state     <= ST_JEDEC;
                            end
                            8'h05: begin
                                // READ STATUS REGISTER 1
                                shift_out <= {6'b0, wel, wip};
                                state     <= ST_STATUS;
                            end
                            8'h06: begin
                                // WRITE ENABLE – set WEL, stay idle
                                wel   <= 1'b1;
                                state <= ST_CMD;
                            end
                            8'hD8: begin
                                // SECTOR ERASE – collect 3-byte address
                                addr_reg <= 24'd0;
                                state    <= ST_ADDR;
                            end
                            8'h02: begin
                                // PAGE PROGRAM – collect 3-byte address
                                addr_reg <= 24'd0;
                                page_len <= 8'd0;
                                state    <= ST_ADDR;
                            end
                            8'h03: begin
                                // READ DATA – collect 3-byte address
                                addr_reg <= 24'd0;
                                state    <= ST_ADDR;
                            end
                            8'h71: begin
                                // WRITE REGISTER (QPI enable) – one data byte follows
                                state <= ST_DATA_WR;
                            end
                            default: begin
                                // Unknown command: stay in CMD state, ignore
                                state <= ST_CMD;
                            end
                        endcase
                    end

                    ST_ADDR: begin
                        // Collect 3 address bytes, MSB first
                        addr_reg <= {addr_reg[15:0], shift_in[6:0], mosi};
                        byte_cnt <= byte_cnt + 8'd1;
                        if (byte_cnt == 8'd2) begin
                            // 3rd address byte received
                            byte_cnt <= 8'd0;
                            case (cmd_reg)
                                8'hD8: begin
                                    // Sector erase: clear 64 kB
                                    if (wel) begin
                                        for (i = 0; i < 65536; i = i + 1)
                                            mem[(({addr_reg[15:0], shift_in[6:0], mosi} & ~24'hFFFF) + i) % FLASH_DEPTH] = 8'hFF;
                                        wip <= 1'b1;
                                        wel <= 1'b0;
                                        fork
                                            clear_wip_after(ERASE_DELAY);
                                        join_none
                                    end
                                    state <= ST_CMD;
                                end
                                8'h02: begin
                                    // Page program: move to write-data phase
                                    state <= ST_DATA_WR;
                                end
                                8'h03: begin
                                    // Read data: prepare first byte and move to read phase
                                    shift_out <= mem[{addr_reg[15:0], shift_in[6:0], mosi}];
                                    addr_reg  <= {addr_reg[15:0], shift_in[6:0], mosi} + 24'd1;
                                    state     <= ST_DATA_RD;
                                end
                                default: state <= ST_CMD;
                            endcase
                        end
                    end

                    ST_DATA_WR: begin
                        case (cmd_reg)
                            8'h02: begin
                                // Accumulate page buffer (max 256 bytes)
                                page_buf[page_len] <= {shift_in[6:0], mosi};
                                page_len <= page_len + 8'd1;
                                // (commit happens on CS deassert above)
                            end
                            8'h71: begin
                                // QPI enable: bit 1 of config byte enables QPI
                                qpi_en <= {shift_in[6:0], mosi}[1];
                                state  <= ST_CMD;
                            end
                            default: state <= ST_CMD;
                        endcase
                    end

                    ST_JEDEC: begin
                        // Shift out remaining JEDEC bytes
                        byte_cnt <= byte_cnt + 8'd1;
                        case (byte_cnt)
                            8'd0: shift_out <= JEDEC_ID[15:8];
                            8'd1: shift_out <= JEDEC_ID[7:0];
                            8'd2: shift_out <= JEDEC_EXT;
                            default: shift_out <= 8'hFF;
                        endcase
                    end

                    ST_STATUS: begin
                        // Continue returning status register while CS is low
                        shift_out <= {6'b0, wel, wip};
                    end

                    ST_DATA_RD: begin
                        // Prepare next byte; addr_reg was pre-incremented
                        shift_out <= mem[addr_reg % FLASH_DEPTH];
                        addr_reg  <= addr_reg + 24'd1;
                    end

                    default: state <= ST_CMD;
                endcase
            end else begin
                bit_cnt <= bit_cnt - 3'd1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // SCK falling edge – shift out MISO
    // -----------------------------------------------------------------------
    always @(negedge sck) begin
        if (!csn) begin
            miso_reg  <= shift_out[7];
            shift_out <= {shift_out[6:0], 1'b0};
        end
    end

    // -----------------------------------------------------------------------
    // Debug display (enabled when VERBOSE parameter exists; customize as needed)
    // -----------------------------------------------------------------------
`ifdef SPI_FLASH_VERBOSE
    always @(posedge csn) begin
        if (state != ST_CMD)
            $display("[spi_flash] CS deasserted: cmd=0x%02X addr=0x%06X state=%0d wip=%b",
                     cmd_reg, addr_reg, state, wip);
    end
`endif

endmodule
