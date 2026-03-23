# tb/ – PULPino Testbench with SPI Flash Model

This directory contains the PULPino top-level testbench plus a minimal SPI
flash behavioral model added to support the
`sw/apps/imperio_tests/testSPIMaster/testSPIMaster.c` self-checking test.

---

## Files

| File | Origin / Purpose |
|------|-----------------|
| `tb.sv` | PULPino top-level testbench (upstream `pulp-platform/pulpino tb/tb.sv`, modified to instantiate `spi_flash_model`). |
| `if_spi_slave.sv` | SPI slave interface definition (upstream, unchanged). Provides `spi_slave` interface used by `tb.sv`. |
| `spi_flash_model.sv` | **New** – Minimal SPI flash behavioral model. See details below. |

---

## spi_flash_model – Overview

`spi_flash_model` is a pure-behavioral SystemVerilog module that emulates just
enough of an SPI flash to let `testSPIMaster.c` run and pass self-checking
comparisons in ModelSim RTL simulation.

### Wiring

```
                      ┌─────────────────────────────────────┐
                      │  pulpino_top / SPI master peripheral │
                      │                                      │
  spi_master.clk   ◄──┤  spi_master_clk_o                   │
  spi_master.csn   ◄──┤  spi_master_csn0_o                  │
  spi_master.padmode◄─┤  spi_master_mode_o                  │
  spi_master.sdo[3:0]◄┤  spi_master_sdo{0..3}_o             │
  spi_master.sdi[3:0]─►  spi_master_sdi{0..3}_i             │
                      └─────────────────────────────────────┘
         │ (same wires via spi_slave interface)
         ▼
  ┌─────────────────┐
  │  spi_flash_model│
  │   (flash_model_i│
  │    in tb.sv)    │
  └─────────────────┘
```

### Supported Commands

| Opcode | Name | Description |
|--------|------|-------------|
| `0x9F` | RDID | Returns JEDEC ID `0x0102_194D` (Spansion S25FL-L) in 32 bits. Works for both standard (`SPI_CMD_RD`) and quad (`SPI_CMD_QRD`) transactions. |
| `0x06` | WREN | Sets the internal Write Enable Latch (WEL). |
| `0x05` | RDSR1 | Returns Status Register 1. Bit 0 (WIP) is always `0` so the test never stalls waiting for busy to clear. |
| `0x35` | RDCR | Returns Configuration Register 1 with bit 2 = `0` (parameter sectors at bottom), which is what the test verifies. |
| `0x71` | WRAR | Accepts writes to any register address. Address `0x80000348` sets an internal `qpi_en` flag; `0x80000308` clears it. All other addresses are accepted and silently ignored. |
| `0x20` | P4E | Parameter 4 KB sector erase. Erases a 4 KB-aligned block to `0xFF` in the internal memory array. |
| `0x02` | PP | Page program. Writes data bytes into the internal memory array using a logical AND (standard flash program semantic). |
| `0xEC` | 4QIOR | Quad I/O Read with 32-bit address and 10 dummy cycles, followed by a quad data phase. Returns bytes from the internal memory array. |

### Protocol

The model uses the `padmode[1:0]` output from the DUT to determine the bus
mode on each clock edge:

| padmode | Meaning | Model behaviour |
|---------|---------|----------------|
| `2'b00` SPI_STD | Single-bit | Sample `sdo[0]`; drive `sdi[0]` |
| `2'b01` SPI_QUAD_TX | DUT driving 4-bit | Sample `sdo[3:0]` |
| `2'b10` SPI_QUAD_RX | DUT receiving 4-bit | Drive `sdi[3:0]` |

This means the model handles mid-transaction mode switches
(e.g. command in QUAD_TX, data in QUAD_RX for `SPI_CMD_QRD`) automatically,
with no need to know in advance which transaction type the DUT is using.

### Memory Model

The flash is backed by a `logic [7:0] mem[0:MEM_SIZE-1]` array
(default `MEM_SIZE = 65536` = 64 KB), initialised to `0xFF` at time zero.

Erase (`0x20`) sets a 4 KB-aligned region back to `0xFF`.  
Program (`0x02`) performs a bitwise AND of existing contents with the new
data (standard NOR-flash program semantic).  
Read (`0xEC`) returns the current array contents.

### Limitations

* **Only CS0** is modelled. The model uses the single `spi_master.csn` signal.
* **No timing** – all operations complete in zero simulation time (WIP is
  always returned as 0). This is sufficient for the directed test but would
  not catch software that relies on realistic erase/program timing.
* **No write protection** – WEL is cleared after every successful write/erase
  but is not enforced as a guard (writes are accepted regardless).
* **64 KB address space** only; accesses beyond `MEM_SIZE` return `0xFF`.
* **SPI mode 0 assumed** (CPOL=0, CPHA=0). This matches the PULPino SPI
  master default.

---

## How to Run the Imperio Test in ModelSim

1. Compile all sources including `tb/spi_flash_model.sv` and `tb/tb.sv`.
2. Load the `testSPIMaster.elf` into the simulated memory via the normal
   PULPino `make` flow (MEMLOAD=PRELOAD or MEMLOAD=SPI).
3. Run the simulation. Transcript should show:
   ```
   ID: 0102194D          ← standard mode JEDEC check
   ID: 0102194D          ← QPI mode JEDEC check
   ```
   and **no** lines containing `Content of flash memory is incorrect`.
4. Simulation ends via `gpio_out[8]` assertion and `$stop()` as normal.

### Pass / Fail Criteria

* **PASS** – transcript contains two `ID: 0102194D` lines and no memory
  mismatch messages, and simulation exits via `$stop()`.
* **FAIL** – any line containing `Content of flash memory is incorrect`,
  `parameter sectors are at the top`, or a non-zero error count from the
  test framework.

---

## Compatibility

The modified `tb.sv` is a strict superset of the upstream PULPino testbench:

* All existing MEMLOAD modes (`PRELOAD`, `SPI`, `STANDALONE`) are unchanged.
* All Arduino tests (`ARDUINO_UART`, `ARDUINO_GPIO`, `ARDUINO_SPI`, etc.)
  continue to work. The `spi_master.send()` task still drives `sdi[0]`;
  the flash model only drives `sdi` during transactions initiated by the DUT
  (while `spi_master.csn` is low), so there is no contention during boot
  SPI loading.
