# Modeling an SPI Flash in RTL Simulation – PULPino `testSPIMaster` Use Case

This guide explains how to attach a simulated SPI flash to the PULPino SPI Master port during
RTL simulation so that `sw/apps/imperio_tests/testSPIMaster/testSPIMaster.c` can run end-to-end
and produce an automated **PASS / FAIL** result without waveform inspection.

> **Related document:** [`../sim/modelsim_spi_verification.md`](../sim/modelsim_spi_verification.md)
> covers the full ModelSim build/run/regression flow. Read it alongside this guide.

---

## 1. What `testSPIMaster` needs from the SPI flash model

The `testSPIMaster` test sends the following command sequences over the SPI Master pins.
Your flash model must respond correctly to each one.

| # | Command (hex) | Name | Description |
|---|---------------|------|-------------|
| 1 | `0x9F` | READ ID (JEDEC) | Returns 3-byte Manufacturer/Device ID; test expects `0x01 0x02 0x19` (Spansion S25FL128P) |
| 2 | `0x05` | READ STATUS REGISTER 1 | Polled after erase/program; `WIP` bit (bit 0) must clear to `0` |
| 3 | `0x06` | WRITE ENABLE | Sets WEL bit; required before every erase/program |
| 4 | `0xD8` | SECTOR ERASE (64 kB) | Erases addressed sector; model must set `WIP=1` then clear it |
| 5 | `0x02` | PAGE PROGRAM | Writes up to 256 bytes; model must set `WIP=1` then clear it |
| 6 | `0x03` | READ DATA | Sequential read from addressed location |
| 7 | `0x71` | WRITE REGISTER (QPI enable) | Enables Quad/QPI mode (Spansion-specific) |
| 8 | `0x38` / quad `0xEB` | QPI READ (quad cmd) | 4-bit data path read (IO[3:0]) |
| 9 | `0x32` / quad `0x12` | QPI WRITE (quad cmd) | 4-bit data path write (IO[3:0]) |

The expected JEDEC ID (`0x0102194D`) is defined in `testSPIMaster.c` as the pass criterion for
the first check. Your model **must** return exactly this value on a `0x9F` command.

---

## 2. Choosing a simulation approach

There are two practical approaches to provide an SPI flash model in simulation:

### Option A – Use a pre-built behavioral SPI flash model (recommended)

A ready-made, validated Verilog behavioral model gives the most accurate flash behaviour with
minimal effort.

**Spansion / Cypress S25FL** model (the exact device expected by `testSPIMaster`):
- Cypress/Infineon distribute a free Verilog simulation model for the S25FL128P / S25FL064 family
  through their website and IP download portals.
- File names typically look like `s25fl128p.v` or `s25fl064l.v`.
- These models support standard SPI, Quad SPI (QSPI), and QPI modes out of the box.

**Alternative open-source models:**
- `spiflash.v` from [YosysHQ/picosoc](https://github.com/YosysHQ/picosoc) – implements a simple
  25-series SPI flash; easy to adapt JEDEC ID.
- `spim.v` included in some PULPino forks under `tb/` – check your local `pulpino/tb/` directory.

**How to use:**

1. Place `s25fl128p.v` (or your chosen model) under `pulpino/tb/`.
2. Add it to your ModelSim compilation script:
   ```tcl
   # in vcompile.tcl / Makefile
   vlog -sv pulpino/tb/s25fl128p.v
   ```
3. Instantiate the model in the top-level testbench (`pulpino/tb/tb_pulpino.sv`):
   ```verilog
   s25fl128p u_spi_flash (
       .SCK  (spi_master_sck),    // SPI clock from PULPino SPI Master
       .SI   (spi_master_sdi),    // MOSI  (DQ0)
       .CSNeg(spi_master_csn[0]), // Chip select, active low
       .WPNeg(1'b1),              // Write-protect, tie high (disabled)
       .HOLDNeg(1'b1),            // HOLD, tie high (disabled)
       .SO   (spi_master_sdo)     // MISO  (DQ1)
   );
   ```
4. For Quad/QPI models that expose all four data lines:
   ```verilog
   s25fl128p u_spi_flash (
       .SCK    (spi_master_sck),
       .CSNeg  (spi_master_csn[0]),
       .SI     (spi_master_sdio[0]),  // DQ0 / MOSI
       .SO     (spi_master_sdio[1]),  // DQ1 / MISO
       .WPNeg  (spi_master_sdio[2]),  // DQ2 / WP# (driven by PULPino in quad mode)
       .HOLDNeg(spi_master_sdio[3])   // DQ3 / HOLD# (driven by PULPino in quad mode)
   );
   ```
   See [Section 4](#4-connecting-spi-pins) for the full pin mapping.

---

### Option B – Write a minimal testbench SPI responder

If you do not have a vendor model, you can write a simple Verilog/SystemVerilog module that
decodes the specific commands `testSPIMaster` sends and returns the expected data.

A reference implementation is provided in this repository under
[`../../tb/spi_flash_responder.v`](../../tb/spi_flash_responder.v).

**When to choose this option:**
- You need a quick, dependency-free model that compiles without any vendor package.
- You only care about the commands actually used by `testSPIMaster` (not full flash compliance).
- You are debugging timing/protocol issues and want a model you can fully control.

**Limitations:**
- Does not simulate flash timing (erase/program latency, `WIP` clearing cycles).
- Does not validate write-protect or deep-power-down logic.
- Not suitable for production sign-off; use a vendor model for that.

---

## 3. Common pitfalls

### 3.1 JEDEC ID mismatch

`testSPIMaster` compares the `0x9F` response against the hard-coded constant
`FLASH_ID = 0x0102194D` (bytes: `0x01`, `0x02`, `0x19`, followed by continuation byte `0x4D`).

- If your model returns a different ID (e.g., a generic `0xEF4017` Winbond ID), the test prints
  **`TEST FAIL`** immediately at the very first check.
- **Fix:** Either use the Spansion S25FL128P model, or patch the JEDEC response in your custom
  model to return `0x01`, `0x02`, `0x19`.

### 3.2 QPI enable sequence (`0x71` / Write Register)

`testSPIMaster` enters QPI (quad) mode by sending command `0x71` followed by one data byte that
sets the Configuration Register. Many generic flash models ignore unknown commands silently.

- **Symptom:** Standard SPI tests pass, but QPI tests timeout or return `0xFF` bytes.
- **Fix:** Ensure your model handles `0x71` and transitions its internal data bus width from 1-bit
  to 4-bit (quad) mode for subsequent reads and writes.
- **Verify:** After the `0x71` sequence, the SPI master shifts data on all four IO lines
  simultaneously. Watch the `sdio[3:0]` bus in the waveform window (or add `$display` in the
  model) to confirm all four lines are driven.

### 3.3 Dummy cycle count mismatch

`testSPIMaster` calls `spi_setup_dummy(SPI_DUMMY_QSPI_N)` before a Quad Read. The number of
dummy cycles is hard-coded in the PULPino driver header and must match what the flash model
expects between the address phase and the first data byte.

| Mode | Typical dummy cycles |
|------|---------------------|
| Standard Read (`0x03`) | 0 |
| Fast Read (`0x0B`) | 8 |
| Quad I/O Read (`0xEB`) | 6 (Spansion S25FL) |
| QPI Read (`0x0B` in QPI) | varies by model |

- **Symptom:** Data read back is shifted by N bytes; first N bytes are garbage.
- **Fix:** Match the constant `SPI_DUMMY_QSPI_N` (in `pulpino/sw/libs/spi_lib/include/spi.h`) to
  the dummy cycle count in your flash model's datasheet table.

### 3.4 CS polarity and setup/hold timing

The PULPino SPI Master deasserts CS (drives `csn` high) between transactions. Some models require
a minimum CS-high time (`tCHSL`) between consecutive transactions.

- **Symptom:** Second or later transactions fail; first always passes.
- **Fix:** Add a small `#20` delay in the testbench between assertions of `csn` if your model
  uses timing checks. In zero-timing behavioral models this is usually not an issue.

### 3.5 Write Enable (`0x06`) not acknowledged

Every erase and program operation must be preceded by a Write Enable (`0x06`) command.
If your model's `WEL` bit is not set, the write/erase is silently ignored.

- **Symptom:** Program/erase commands complete without error, but read back returns `0xFF` (erased
  state) or old data.
- **Fix:** Ensure the model tracks the `WEL` flag and only programs/erases memory when `WEL=1`.
  The model should also clear `WEL` automatically after a successful write/erase.

### 3.6 Status Register `WIP` bit not clearing

`testSPIMaster` polls the Status Register (`0x05`) in a tight loop until the `WIP` (Write In
Progress) bit clears after erase/program operations.

- **Symptom:** Simulation hangs forever (or hits `+MAX_CYCLES` watchdog) after sector erase.
- **Fix:** Your model must set `WIP=1` when an erase/program starts and then clear it after a
  fixed simulated delay (e.g., `#1000` for a behavioral model; a realistic value would be
  100 µs–100 ms in real time).

---

## 4. Connecting SPI pins

The PULPino SPI Master exposes the following top-level ports (from `pulpino/rtl/top.sv`):

| PULPino port | Direction | Flash pin | Notes |
|---|---|---|---|
| `spi_master_clk_o` | output | `SCK` | SPI clock |
| `spi_master_csn0_o` | output | `CS#` / `CEJ` | Chip select 0, active low |
| `spi_master_csn1_o` | output | second device CS | Leave open or tie high if unused |
| `spi_master_sdo0_o` | output | `SI` / `DQ0` (MOSI) | Data out in standard SPI; DQ0 in quad |
| `spi_master_sdi0_i` | input | `SO` / `DQ1` (MISO) | Data in in standard SPI; DQ1 in quad |
| `spi_master_sdo1_o` | output | `WP#` / `DQ2` | Driven low/high by PULPino in quad mode |
| `spi_master_sdi1_i` | input | `WP#` / `DQ2` | Read back in quad mode |
| `spi_master_sdo2_o` | output | `HOLD#` / `DQ3` | Driven low/high by PULPino in quad mode |
| `spi_master_sdi2_i` | input | `HOLD#` / `DQ3` | Read back in quad mode |
| `spi_master_sdo3_o` | output | `DQ3` (full quad) | Fourth data line (some PULPino variants) |
| `spi_master_sdi3_i` | input | `DQ3` (full quad) | Fourth data line (some PULPino variants) |

### Minimum connections for standard SPI (1-bit data)

```verilog
// Inside tb_pulpino.sv
your_flash_model u_flash (
    .SCK   (spi_master_clk_o),
    .CSNeg (spi_master_csn0_o),
    .SI    (spi_master_sdo0_o),   // MOSI
    .SO    (spi_master_sdi0_i),   // MISO
    .WPNeg (1'b1),                // tie high = write-protect disabled
    .HOLDNeg(1'b1)                // tie high = not in hold
);
```

### Full connections for Quad/QPI (4-bit data)

In quad mode the PULPino SPI Master drives **all four IO lines** (DQ0–DQ3) during write and
tri-states them during read. You must wire the bidirectional lines using `inout` buses or via
`assign` tri-state logic:

```verilog
// Bidirectional quad bus wiring
wire [3:0] sdio;

assign sdio[0] = (quad_out_en) ? spi_master_sdo0_o : 1'bz;
assign sdio[1] = (quad_out_en) ? spi_master_sdo1_o : 1'bz;
assign sdio[2] = (quad_out_en) ? spi_master_sdo2_o : 1'bz;
assign sdio[3] = (quad_out_en) ? spi_master_sdo3_o : 1'bz;

assign spi_master_sdi0_i = sdio[0];
assign spi_master_sdi1_i = sdio[1];
assign spi_master_sdi2_i = sdio[2];
assign spi_master_sdi3_i = sdio[3];

your_quad_flash_model u_flash (
    .SCK  (spi_master_clk_o),
    .CSNeg(spi_master_csn0_o),
    .DQ   (sdio)              // 4-bit bidirectional bus
);
```

> `quad_out_en` is typically a signal driven by the PULPino SPI Master RTL that indicates when
> the master is driving (write phase) vs. when the flash drives (read phase). Check your
> specific PULPino variant's SPI master source for the correct enable signal name.

---

## 5. Verifying via transcript PASS/FAIL

### 5.1 Expected transcript output

When the test passes, the ModelSim transcript (stdout in batch mode) should contain lines similar
to the following, in order:

```
# ---- testSPIMaster ----
# [Standard Mode] Reading Flash ID...
# Flash ID = 0x0102194D  --> PASS
# [Standard Mode] Erase sector 0...
# [Standard Mode] Program 256 bytes...
# [Standard Mode] Read back and compare... PASS
# [QPI Mode] Entering QPI...
# [QPI Mode] Write 256 bytes...
# [QPI Mode] Read back and compare... PASS
# TEST PASS
```

The final `TEST PASS` line is the machine-checkable token your regression script looks for.

### 5.2 Failure transcript examples

**JEDEC ID mismatch:**
```
# Flash ID = 0xEF4017  --> FAIL  (expected 0x0102194D)
# TEST FAIL: 1 errors
```

**QPI timeout (WIP never clears):**
```
# [QPI Mode] Waiting for WIP... (stall after many cycles)
# Simulation killed by watchdog (+MAX_CYCLES exceeded)
```
No `TEST PASS` line → regression script returns **FAIL**.

**Data mismatch:**
```
# [Standard Mode] Read back and compare...
# Mismatch at byte 3: expected 0xA5, got 0xFF
# TEST FAIL: 1 errors
```

### 5.3 Regression script check

The script in [`../../scripts/run_spi_test.sh`](../../scripts/run_spi_test.sh) automates the
check. The essential grep pattern is:

```bash
if grep -q "TEST PASS" /tmp/spi_sim.log; then
    echo "RESULT: PASS"
    exit 0
else
    echo "RESULT: FAIL"
    grep -E "FAIL|Error|mismatch" /tmp/spi_sim.log | head -20
    exit 1
fi
```

You can extend the pattern to catch more failure modes:

```bash
PASS_PATTERN="TEST PASS"
FAIL_PATTERN="TEST FAIL\|Fatal\|Error\|\$fatal\|WIP stuck"
```

---

## 6. Quick-start checklist

Use this checklist when setting up SPI flash simulation for the first time:

- [ ] Obtain a Verilog model for Spansion S25FL128P **or** use the provided minimal responder
      (`tb/spi_flash_responder.v`).
- [ ] Confirm the model returns JEDEC ID `0x01 0x02 0x19` on command `0x9F`.
- [ ] Wire SCK, CS#, MOSI (DQ0), MISO (DQ1) at minimum; add DQ2/DQ3 for quad support.
- [ ] If using quad mode: verify the model handles command `0x71` (QPI enable).
- [ ] Match dummy cycle count (`SPI_DUMMY_QSPI_N` in `spi.h`) to the model's table.
- [ ] Confirm `WIP` bit clears after erase/program (no hang on status-poll loop).
- [ ] Run `make testSPIMaster.vsimc` and check transcript for `TEST PASS`.
- [ ] Integrate into the regression script and confirm `exit 0` on success.
