# SPI Master / Slave Testbench Interface Guide

This document explains the two SPI testbench interfaces used in the PULPino
simulation flow, describes the indexing bugs that exist in the original
`if_spi_master.sv`, and shows how to connect the included
`spi_flash_responder` module to model an external SPI flash for the
**imperio SPI master test** (`testSPIMaster.c`).

---

## 1. Interface Overview

### `spi_slave`  (defined in `tb/if_spi_slave.sv`)

```
interface spi_slave #(parameter period = 50ns);
  logic       clk;      // SPI clock (driven by the SoC)
  logic [3:0] sdo;      // SoC → flash data lines (MOSI / IO0-IO3)
  logic [3:0] sdi;      // flash → SoC data lines (MISO / IO0-IO3)
  logic       csn;      // Chip select, active-low (driven by the SoC)
  logic [1:0] padmode;  // Current pad mode (driven by the SoC)
  ...
endinterface
```

In `pulpino/tb/tb.sv` this interface is instantiated as:

```systemverilog
spi_slave spi_master();
```

Despite the instance name `spi_master`, the *type* is `spi_slave`.  The
testbench uses this interface to **represent the external SPI device** (a
flash chip) that the PULPino SoC's SPI master peripheral communicates with.

The SoC's SPI master output pins wire directly to the interface:

```systemverilog
.spi_master_clk_o  ( spi_master.clk     )   // SoC clock output → flash CLK
.spi_master_csn0_o ( spi_master.csn     )   // SoC chip-select  → flash CSn
.spi_master_mode_o ( spi_master.padmode )   // SoC mode output  → flash (observe)
.spi_master_sdo0_o ( spi_master.sdo[0]  )   // SoC MOSI / IO0   → flash input
.spi_master_sdo1_o ( spi_master.sdo[1]  )   // SoC IO1          → flash input
.spi_master_sdo2_o ( spi_master.sdo[2]  )   // SoC IO2          → flash input
.spi_master_sdo3_o ( spi_master.sdo[3]  )   // SoC IO3          → flash input
.spi_master_sdi0_i ( spi_master.sdi[0]  )   // flash MISO / IO0 → SoC input
.spi_master_sdi1_i ( spi_master.sdi[1]  )   // flash IO1        → SoC input
.spi_master_sdi2_i ( spi_master.sdi[2]  )   // flash IO2        → SoC input
.spi_master_sdi3_i ( spi_master.sdi[3]  )   // flash IO3        → SoC input
```

### `spi_bus_master`  (defined in `tb/if_spi_master.sv`)

```
interface spi_bus_master #(parameter period = 50ns);
  logic       clk;
  logic [3:0] sdo;
  logic [3:0] sdi;
  logic       csn;
  logic [1:0] padmode;
  task send(input logic use_quad, input logic data[]);
  task receive(input logic use_quad, output logic data[]);
  ...
endinterface
```

This interface is intended for testbenches where the **testbench itself
acts as the SPI master**.  It is *not* instantiated in the stock PULPino
`tb.sv` but is available for alternative verification scenarios.

---

## 2. `padmode` Values

Both interfaces share the same encoding for `padmode`:

| Value  | Constant    | Meaning |
|--------|-------------|---------|
| `2'b00`| `SPI_STD`   | Single-bit standard SPI.  SoC drives `sdo[0]` (MOSI); flash drives `sdi[0]` (MISO). |
| `2'b01`| `SPI_QUAD_TX` | Quad transmit.  SoC drives all four `sdo[3:0]` lines simultaneously. |
| `2'b10`| `SPI_QUAD_RX` | Quad receive.  Flash must drive all four `sdi[3:0]` lines; SoC reads them. |

The `padmode` signal is driven by the SoC's SPI master hardware and
changes dynamically within a transaction:

* **Command / address / write-data phase** → `SPI_STD` or `SPI_QUAD_TX`
* **Read-data phase** → `SPI_STD` or `SPI_QUAD_RX`

A flash model can use the transition from `SPI_QUAD_TX` to `SPI_QUAD_RX`
to detect when the dummy-cycle phase ends and the actual data phase begins,
without needing to know the configured dummy count.

---

## 3. Driving and Observing `sdo` / `sdi`

### Standard SPI (SPI_STD)

```
         ___   ___   ___   ___   ___   ___   ___   ___
clk  ___|   |_|   |_|   |_|   |_|   |_|   |_|   |_|   |___

sdo[0] < D7 >< D6 >< D5 >< D4 >< D3 >< D2 >< D1 >< D0 >
         MSB                                           LSB

sdi[0] < R7 >< R6 >< R5 >< R4 >< R3 >< R2 >< R1 >< R0 >
```

* The SoC drives `sdo[0]` *before* each `posedge clk`; the flash samples
  on `posedge clk`.
* The flash drives `sdi[0]` *before* each `posedge clk`; the SoC samples
  on `posedge clk`.
* `sdo[3:1]` and `sdi[3:1]` are unused in this mode.
* Data is always **MSB first**.

### Quad TX mode (SPI_QUAD_TX) – SoC transmits

```
         ___         ___         ___
clk  ___|   |_______|   |_______|   |___

sdo  < D[7:4]    >< D[3:0]    >< ...
      ↑ MSB nibble ↑ LSB nibble
```

* SoC drives all four `sdo[3:0]` lines simultaneously.
* `sdo[3]` carries the MSB of each nibble; `sdo[0]` carries the LSB.
* The flash samples `sdo[3:0]` on `posedge clk`.
* High nibble (bits `[7:4]`) is transmitted before low nibble (`[3:0]`).

### Quad RX mode (SPI_QUAD_RX) – flash transmits

```
         ___         ___         ___
clk  ___|   |_______|   |_______|   |___

sdi  < R[7:4]    >< R[3:0]    >< ...
      ↑ MSB nibble ↑ LSB nibble
```

* Flash must drive all four `sdi[3:0]` lines *before* each `posedge clk`.
* `sdi[3]` is the MSB of each nibble; `sdi[0]` is the LSB.
* Drive the high nibble (bits `[7:4]`) first.

---

## 4. Bugs in the Original `spi_bus_master` Interface

The original file `pulpino/tb/if_spi_master.sv` contains off-by-one
index errors in both `send` and `receive` tasks.

### 4.1 Standard mode – `data[i]` should be `data[i-1]`

```systemverilog
// ORIGINAL (buggy)
for (int i = data.size(); i > 0; i--)
begin
  sdo[0] = data[i];   // ← data[data.size()] is out of bounds on first iteration
  clock(1);
end

// FIXED
for (int i = data.size(); i > 0; i--)
begin
  sdo[0] = data[i-1]; // ← correct: accesses data[data.size()-1] .. data[0]
  clock(1);
end
```

The same off-by-one applies to the `receive` task:
```systemverilog
// ORIGINAL (buggy)
data[i] = sdi[0];    // out of bounds

// FIXED
data[i-1] = sdi[0]; // correct
```

### 4.2 Quad mode – `data[4*i-j+1]` should be `data[4*(i-1)+j]`

```systemverilog
// ORIGINAL (buggy) – for i=data.size()/4=2 and j=1: data[8-1+1]=data[8]
// which is out of bounds for an 8-element array.
sdo[j] = data[4*i-j+1];

// FIXED
sdo[j] = data[4*(i-1)+j];
```

**Derivation of the correct formula:**

With `i` running from `data.size()/4` down to `1`, the *group index*
is `(i-1)` (zero-based, counting from the most-significant group).
Group `(i-1)` occupies positions `[4*(i-1) .. 4*(i-1)+3]` in the array,
with `j=3` being the most-significant bit of the group:

```
group (i-1):  data[4*(i-1)+3]  data[4*(i-1)+2]  data[4*(i-1)+1]  data[4*(i-1)+0]
                    ↓                  ↓                  ↓                  ↓
               sdo[3] / sdi[3]  sdo[2] / sdi[2]  sdo[1] / sdi[1]  sdo[0] / sdi[0]
```

Cross-check with `tb_spi_pkg.sv` (known-correct raw-signal tasks):
```systemverilog
spi_sdo3 = command[4*i-1];  // == data[4*(i-1)+3]  ✓
spi_sdo2 = command[4*i-2];  // == data[4*(i-1)+2]  ✓
spi_sdo1 = command[4*i-3];  // == data[4*(i-1)+1]  ✓
spi_sdo0 = command[4*i-4];  // == data[4*(i-1)+0]  ✓
```

The same fix applies to the `receive` task:
```systemverilog
// ORIGINAL (buggy)
data[4*i-j+1] = sdi[j];

// FIXED
data[4*(i-1)+j] = sdi[j];
```

All four fixes are applied in `tb/if_spi_master.sv` in this repository.

---

## 5. Connecting `spi_flash_responder` to `spi_slave`

### 5.1 Instantiation in `tb.sv`

Add the following lines inside the `tb` module, after the `spi_slave
spi_master()` instantiation:

```systemverilog
spi_flash_responder #(
    .MEM_DEPTH ( 65536        ),   // 64 kB internal memory
    .JEDEC_ID  ( 32'h0102194D )    // Spansion S25FS-S ID (required by test)
) flash_i (
    .spi_clk    ( spi_master.clk     ),
    .spi_csn    ( spi_master.csn     ),
    .spi_padmode( spi_master.padmode ),
    .spi_sdo    ( spi_master.sdo     ),
    .spi_sdi    ( spi_master.sdi     )
);
```

The responder drives `spi_master.sdi[3:0]` directly, so no additional
`assign` statements are needed.

### 5.2 Command flow for `check_standard_mode`

| Step | C code | SPI transaction | Responder action |
|------|--------|-----------------|------------------|
| 1 | `spi_read_fifo(&id, 32)` after `0x9F` cmd | 8 cmd clocks (STD), 32 data clocks (STD) | Returns `JEDEC_ID` on `sdi[0]` |
| 2 | `SPI_CMD_WR` for `0x06` | 8 cmd clocks (STD) | Sets `wel = 1` |

### 5.3 Command flow for `check_qpi_mode`

| Step | C code | SPI transaction | Responder action |
|------|--------|-----------------|------------------|
| 1 | WRAR `0x71` addr `0x80000348` | 8+32 clocks (STD) | Accepts write silently |
| 2 | RDID `0x9F` | 2 cmd + 8 data clocks (QUAD) | Returns `JEDEC_ID` on `sdi[3:0]` |
| 3 | WREN `0x06` (QPI) | 2 clocks (QUAD_TX) | Sets `wel = 1` |
| 4 | WRAR disable QPI | 2+8 clocks (QUAD_TX) | Accepts write silently |
| 5 | RDCR `0x35` | 8+8 clocks (STD) | Returns `0x00` (bit 2 = 0) |
| 6 | WREN + WRAR enable QPI | STD, then QUAD_TX | Sets `wel`, accepts write |
| 7 | WREN + WRAR page size | QUAD_TX | Sets `wel`, accepts write |
| 8 | WREN + P4E `0x20` | QUAD_TX | Erases 4 kB sector |
| 9 | WREN + PP `0x02` + 512 B | QUAD_TX | Programs 512 bytes |
| 10 | RDSR1 `0x05` (WIP check) | QUAD_TX/RX | Returns `0x00` (WIP = 0) |
| 11 | 4QIOR `0xEC` read 512 B | QUAD_TX cmd/addr, QUAD_RX data | Drives `mem[0..511]` |

---

## 6. QPI Enable / Disable via WRAR (0x71)

The test configures the flash through `WRAR` writes using
`spi_setup_cmd_addr(0x71, 8, addr_and_val, 32)`:

| Call | addr_and_val | Meaning |
|------|-------------|---------|
| `SPI_CMD_WR,  addr=0x80000348` | `{addr: 0x800003, val: 0x48}` | Enable QPI (CR3V bit 6 = 1) |
| `SPI_CMD_QWR, addr=0x80000308` | `{addr: 0x800003, val: 0x08}` | Disable QPI (CR3V bit 6 = 0) |
| `SPI_CMD_QWR, addr=0x80000348` | same re-enable | Enable QPI again |
| `SPI_CMD_QWR, addr=0x80000410` | `{addr: 0x800004, val: 0x10}` | Set page size to 512 B |

After the first WRAR (`SPI_CMD_WR`, standard), the DUT switches subsequent
transactions to `SPI_CMD_QRD` / `SPI_CMD_QWR`, which causes the SoC SPI
master to set `spi_padmode = SPI_QUAD_TX`.  The `spi_flash_responder` uses
`spi_padmode` as the ground truth for the current transfer width and does
not need to track QPI state internally.

---

## 7. Important Notes

* **JEDEC ID must match exactly.**  The test hard-checks for `0x0102194D`.
  If your flash model returns a different ID the test will increment the
  error counter immediately.

* **RDCR bit 2 must be 0.**  The test reads the Configuration Register
  (`0x35`) and aborts if bit 2 is set (which would indicate parameter
  sectors at the top of the address space).  The responder always returns
  `0x00`.

* **WIP is always 0 in simulation.**  Program and erase operations complete
  instantaneously; `RDSR1` (0x05) always returns `0x00`.

* **Dummy cycles for 4QIOR.**  The test calls `spi_setup_dummy(10, 0)`,
  inserting 10 extra clocks between address and data.  The responder
  handles this by waiting for the `SPI_QUAD_RX` padmode transition rather
  than counting clocks, so it is insensitive to the configured dummy count.

* **ModelSim compatibility.**  All constructs used in `spi_flash_responder`
  are compatible with ModelSim (tested against the PULPino simulation flow):
  `initial` blocks, `automatic` tasks, `@(posedge ...)`, `wait(...)`, and
  `forever`.  No DPI, no clocking blocks, no interfaces required.
