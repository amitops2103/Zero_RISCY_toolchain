# SPI Flash Behavioral Model — Integration Guide

## Overview

This document describes how `tb/spi_flash_model.sv` was created, how it is
wired into `tb/tb.sv`, and how to run the
`sw/apps/imperio_tests/testSPIMaster` test with ModelSim using automated
pass/fail detection based on the transcript.

---

## 1  Background — What Was Missing

The upstream `pulp-platform/pulpino` testbench (`tb/tb.sv`) instantiates a
`spi_slave` interface called `spi_master` and wires it to the PULPino SoC's
`spi_master_*` output ports.  That interface is used by the testbench tasks
(`tb_spi_pkg.sv`) to **boot** the chip (MEMLOAD="SPI") via the *slave* SPI
port of PULPino.

However, the `spi_master_*` ports (the SoC's **SPI Master** peripheral) had
**no external device** attached.  Software running on the core that talks to
an external SPI flash via the SPI master would therefore hang or produce
incorrect results, because the MISO lines were floating.

`testSPIMaster.c` exercises exactly this scenario: it programs the PULPino SPI
Master to talk to a Spansion S25FL128S NOR flash (JEDEC ID `0x0102194D`) using
both single-SPI and QPI (quad) modes, performs sector-erase / page-program /
read-back cycles, and checks for zero errors.

`tb/spi_flash_model.sv` provides the minimal behavioral flash responder needed
to make this test pass in RTL simulation.

---

## 2  File Inventory

| File | Description |
|------|-------------|
| `tb/spi_flash_model.sv` | Behavioral Spansion-like NOR flash (this PR) |
| `tb/tb.sv` | Upstream tb.sv + `spi_flash_model` instantiation (this PR) |

All other files in `tb/` (interfaces, boot-SPI tasks, JTAG packages, etc.) are
unchanged from the upstream `pulp-platform/pulpino` repository.

---

## 3  SPI Pin Wiring

### 3.1  Boot / Slave-SPI port (unchanged from upstream)

PULPino has a second, *slave* SPI port used by the testbench to load firmware
via JTAG or SPI before fetch-enable is asserted:

```
spi_sck  → spi_clk_i
spi_csn  → spi_cs_i
spi_sdo0 / sdi0..3 ↔ spi_sdo*_o / spi_sdi*_i   (boot SPI slave)
```

These are driven by `tb_spi_pkg.sv` tasks and are unrelated to the flash model.

### 3.2  SPI Master port → flash model (added in this PR)

```
spi_master_clk_o   → spi_flash_model_i.spi_clk      (SCK)
spi_master_csn0_o  → spi_flash_model_i.spi_csn      (CS#, active-low)
spi_master_mode_o  → spi_flash_model_i.spi_padmode  (protocol selector)
spi_master_sdo[3:0]→ spi_flash_model_i.spi_sdo[3:0] (IO[3:0] master→flash)
spi_flash_model_i.spi_sdi[3:0] → spi_master_sdi[3:0] (IO[3:0] flash→master)
```

All four IO lines (IO0–IO3) are connected so both single-SPI and QPI quad
modes work.

The `spi_padmode` signal carries the PULPino SPI master's current mode:

| Value | Meaning |
|-------|---------|
| `2'b00` (`SPI_STD`)     | Standard SPI — 1 bit/clock on IO0 |
| `2'b01` (`SPI_QUAD_TX`) | Quad write — 4 bits/clock on IO[3:0] |
| `2'b10` (`SPI_QUAD_RX`) | Quad read  — 4 bits/clock on IO[3:0] |

---

## 4  Supported Commands

| Opcode | Name | Notes |
|--------|------|-------|
| `0x9F` | RDID | Returns 4-byte JEDEC ID `0x0102194D` |
| `0x06` | WREN | Sets Write Enable Latch |
| `0x05` | RDSR1 | Status reg: WIP always 0, WEL reflects latch |
| `0x35` | RDCR | Config reg: bit[2]=0 (parameter sectors at bottom) |
| `0x71` | WRAR | Acknowledged; QPI toggling via `padmode` (see §5) |
| `0x20` | P4E | 4 kB parameter sector erase (3-byte address) |
| `0xD8` | SE | 64 kB uniform sector erase (3-byte address) |
| `0x02` | PP | Page program (3-byte address + data) |
| `0xEC` | 4QIOR | Quad I/O read, 4-byte addr, 10 dummy clocks |
| `0x13` | 4READ | Standard read, 4-byte addr (testbench SPI boot) |

---

## 5  QPI Enable / Disable

### Real flash behaviour
`testSPIMaster.c` toggles QPI by sending `WRAR` to address `0x00800003`
(CR2V) with data `0x48` (bit 6 = QUAD = 1) to enable, and `0x08` (bit 6 = 0)
to disable.

### Model behaviour
Because the PULPino SPI master drives `spi_master_mode_o` (`padmode`)
according to the transaction type it is executing (`SPI_CMD_WR` →
`SPI_STD`; `SPI_CMD_QWR` → `SPI_QUAD_TX`; `SPI_CMD_QRD` → `SPI_QUAD_TX`
shifting to `SPI_QUAD_RX`), the model infers the correct protocol directly
from `padmode` at each clock edge.  The WRAR register write is accepted and
logged, but has no side-effect in the model.

This means:
- **QPI is automatically enabled** the moment the PULPino SPI master starts
  sending commands with `SPI_QUAD_TX` padmode.
- **QPI is automatically disabled** when padmode reverts to `SPI_STD`.
- No model parameter needs to change to enable or disable QPI support.

To **disable quad support entirely** (single-SPI only) compile with:
```
+define+NO_QPI
```
and remove/skip the 0xEC and quad-related branches in the case statement.

---

## 6  Integration Steps (ModelSim)

### 6.1  Prerequisites

Follow the setup in `README.md` through to "PULPino integration" (§5).
The steps below assume:
- PULPino RTL is in `~/pulpino`
- ModelSim `vsim` is on `PATH`
- The RISC-V toolchain is on `PATH`

### 6.2  Copy the new files into PULPino

```bash
cp tb/spi_flash_model.sv  ~/pulpino/tb/spi_flash_model.sv
cp tb/tb.sv               ~/pulpino/tb/tb.sv
```

### 6.3  Add the flash model to the compilation filelist

Open `~/pulpino/tb/filelist.f` (or the equivalent `vcompile` Makefile target)
and add:

```
${PULP_PATH}/tb/spi_flash_model.sv
```

before `tb.sv` in the compilation order.

If PULPino uses `vlog` directly:

```bash
vlog -sv spi_flash_model.sv tb.sv
```

### 6.4  Build the testSPIMaster firmware

```bash
cd ~/pulpino/sw/build
make testSPIMaster           # builds the ELF
make testSPIMaster.slm       # generates SLM memory image
```

### 6.5  Run the simulation with automated pass/fail

```bash
cd ~/pulpino/sw/build

make testSPIMaster.vsimc     # non-GUI: transcript to stdout; $stop on finish
```

Or run ModelSim manually:

```bash
vsim -c -do "
  vlog -sv +incdir+../tb ../tb/spi_flash_model.sv ../tb/tb.sv;
  vsim -L altera_mf_ver tb +MEMLOAD=PRELOAD;
  run -all;
  quit -f
" 2>&1 | tee sim.log
```

Then check the transcript for pass/fail:

```bash
grep -E "\[SPI\] Test (OK|FAILED)" sim.log
```

Expected output for a passing run:

```
[SPI] Test OK
```

For automated CI checking:

```bash
if grep -q "\[SPI\] Test OK" sim.log; then
  echo "PASS"; exit 0
else
  echo "FAIL"; exit 1
fi
```

### 6.6  GUI waveform inspection (optional)

```bash
vsim tb +MEMLOAD=PRELOAD
add wave -r /tb/spi_flash_model_i/*
add wave /tb/spi_master/clk
add wave /tb/spi_master/csn
add wave /tb/spi_master/padmode
add wave /tb/spi_master/sdo
add wave /tb/spi_master/sdi
run -all
```

---

## 7  Minimal-Change Summary

Only two files were added to the repository:

```
tb/spi_flash_model.sv   ← new: behavioral flash (< 350 lines)
tb/tb.sv                ← modified: adds spi_flash_model_i instantiation
                           (all other logic is identical to upstream)
```

The changes to `tb.sv` relative to upstream are:

1. Added `spi_flash_model` instantiation block (≈ 15 lines) between the
   `i2c_eeprom_model` and `pulpino_top` instantiations.
2. Minor comment additions; no functional change to any other logic.

---

## 8  Memory Model Notes

- Internal storage: 64 kB (configurable via `FLASH_SIZE_BYTES` parameter).
- Erase sets bytes to `0xFF`; program ANDs new data with current content
  (NOR-flash semantics — erase before program).
- Write Enable Latch (WEL) must be set by `WREN (0x06)` before `P4E`, `SE`,
  or `PP` commands; it is cleared automatically after each write/erase.
- WIP (Write-In-Progress) is always returned as 0 because the model completes
  all operations instantaneously.
