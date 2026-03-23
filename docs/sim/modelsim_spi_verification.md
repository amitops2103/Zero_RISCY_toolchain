# ModelSim RTL Simulation – PULPino SPI Master Automated Verification

This document describes how to run the **`imperio_tests/testSPIMaster`** application under ModelSim for the PULPino/Zero-RISCY SoC and obtain an automated **PASS / FAIL** result by comparing data—without waveform inspection.

---

## Prerequisites

| Tool / Item | Version used in this guide |
|-------------|---------------------------|
| ModelSim (Intel FPGA Starter) | 20.1.1 |
| RISC-V GNU toolchain (`riscv32-unknown-elf-gcc`) | 7.1.1 |
| PULPino source (`~/pulpino`) | `pulp-platform/pulpino` main |
| CMake | 3.5.1 (built from source) |
| Python 2 virtual environment | `venv_pulp` |

All software setup steps (toolchain, ModelSim, CMake, PULPino clone) are covered in the top-level [README](../../README.md).

---

## Step 1 – Activate the Python 2 environment and set PATH

```bash
source ~/venv_pulp/bin/activate
source ~/pulpino/sw/build/bashrc_pulpino.txt   # sets ModelSim + toolchain PATH
```

Verify:

```bash
which vsim              # should print .../modelsim_ase/bin/vsim
which riscv32-unknown-elf-gcc
```

---

## Step 2 – Build the `testSPIMaster` application

```bash
cd ~/pulpino/sw/build
make testSPIMaster
```

This produces (inside `build/`):

| File | Description |
|------|-------------|
| `apps/testSPIMaster/testSPIMaster.elf` | ELF binary |
| `apps/testSPIMaster/testSPIMaster.hex` | Intel-HEX memory image loaded by the simulation |
| `apps/testSPIMaster/testSPIMaster.s19` | Motorola S-record (alternate format) |

If the target is not found, verify that `sw/apps/imperio_tests/testSPIMaster/CMakeLists.txt` is picked up by the top-level `sw/CMakeLists.txt`.

---

## Step 3 – Add a `TEST PASS` / `TEST FAIL` token to the test (if not already present)

The PULPino `uart_printf` / `printf` output goes to the simulation transcript.  
Open `sw/apps/imperio_tests/testSPIMaster/testSPIMaster.c` and confirm—or add—a final print that the regression script can grep:

```c
/* at the end of main(), after all checks */
if (error_count == 0) {
    printf("TEST PASS\n");
} else {
    printf("TEST FAIL: %d errors\n", error_count);
}
return error_count;   /* non-zero exit causes vsim to return non-zero */
```

> **Note:** If you cannot or prefer not to modify upstream PULPino code, search the transcript for other deterministic strings already printed by the test (e.g., `"SPI_MASTER_TEST_DONE"` or a final `"Errors: 0"` line) and update `PASS_TOKEN` in the regression script accordingly.

---

## Step 4 – Run the simulation in ModelSim batch mode

The PULPino build system generates a `vsim` make target that runs the simulation non-interactively:

```bash
cd ~/pulpino/sw/build
make testSPIMaster.vsimc 2>&1 | tee /tmp/spi_sim.log
```

`*.vsimc` is the **command-line / batch** variant of the simulation targets (no GUI). It:
1. Compiles the RTL (if not already compiled via `make vcompile`).
2. Loads the `.hex` image into the SPI flash model and instruction memory.
3. Runs to `$finish` or timeout.
4. Writes all `$display` / `uart_printf` output to stdout.

### Manual batch invocation (equivalent)

If you need to invoke `vsim` directly:

```bash
cd ~/pulpino/tb
vsim -c \
  -do "
    vsim -lib work tb_pulpino \
      +STIM=../sw/build/apps/testSPIMaster/testSPIMaster.hex \
      +MAX_CYCLES=2000000;
    run -all;
    quit -f" \
  2>&1 | tee /tmp/spi_sim.log
```

Key plusargs:

| Plusarg | Purpose |
|---------|---------|
| `+STIM=<path>` | Path to the `.hex` file loaded into the instruction/data memory or SPI flash model |
| `+MAX_CYCLES=<N>` | Safety watchdog; simulation stops after N clock cycles even if `$finish` was not reached |

The SPI flash behavioral model (`spi_flash_model.sv` or equivalent inside `pulpino/tb/`) is automatically instantiated by the top-level testbench `tb_pulpino`. No extra plusargs are needed to attach it.

---

## Step 5 – Interpret the result

After the simulation finishes, inspect `/tmp/spi_sim.log`:

```
# Entering Standard Mode Test...
# Flash ID: 0x0102194D  (PASS)
# Entering QPI Mode Test...
# Write/Read compare: OK
# TEST PASS
```

A non-zero `error_count` returned by `main()` is caught by the PULPino exit-code mechanism (the testbench monitors the `EXIT_VALID` signal and calls `$fatal` / `$finish` accordingly). The regression script in the next section automates this check.

---

## Step 6 – Automated regression

Use the provided script [`scripts/run_spi_test.sh`](../../scripts/run_spi_test.sh):

```bash
# Run from the repository root
cd ~/pulpino
bash ~/Zero_RISCY_toolchain/scripts/run_spi_test.sh
echo "Exit code: $?"   # 0 = PASS, non-zero = FAIL
```

The script:
1. Activates the Python 2 virtualenv and sets PATH.
2. Builds `testSPIMaster` via `make`.
3. Runs ModelSim in command-line mode with a timeout.
4. Greps the transcript for the `TEST PASS` token.
5. Returns **0** on success, **1** on failure.

---

## Verification coverage provided by `testSPIMaster`

| Test case | What is verified |
|-----------|-----------------|
| Read JEDEC ID (`0x9F`) | SPI master sends cmd, reads 4-byte response, compares to expected `0x0102194D` |
| Standard write / read | Program page, read page back, byte-by-byte compare |
| QPI mode enable / disable | `0x71` command sequence, quad data path used for write and read |
| Erase | Sector erase + blank-check |
| Clock divider variation | Repeated at different `SPI_REG_CLKDIV` values |

All comparisons are done in **software** running on the Zero-RISCY core; the result is printed and checked without waveform inspection.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `vsim: command not found` | PATH not set | Run `source bashrc_pulpino.txt` |
| `make testSPIMaster` fails with missing target | CMake not run yet | Run `./cmake_configure.zeroriscy.gcc.sh` first |
| Simulation times out without output | Watchdog too short | Increase `+MAX_CYCLES` |
| `TEST FAIL: N errors` in log | Data mismatch in SPI loopback | Check flash model configuration and SPI clock divider |
| `$fatal` in transcript | RTL error or assertion failure | Read the `$fatal` message for details |
