#!/usr/bin/env bash
# scripts/run_spi_test.sh
#
# Regression script: build the PULPino testSPIMaster application, run it in
# ModelSim command-line mode, and verify the simulation transcript contains
# the PASS token.
#
# Exit codes
#   0 – TEST PASS (PASS token found in transcript)
#   1 – TEST FAIL (FAIL token found, timeout, or build error)
#
# Usage:
#   bash scripts/run_spi_test.sh [OPTIONS]
#
# Options:
#   --pulpino-dir DIR    Path to PULPino checkout (default: $HOME/pulpino)
#   --build-dir DIR      Path to PULPino sw/build directory (default: $PULPINO/sw/build)
#   --log FILE           Where to write the full ModelSim transcript (default: /tmp/spi_sim_$(date +%s).log)
#   --max-cycles N       Watchdog cycle limit passed to vsim (default: 2000000)
#   --pass-token STR     String grepped for PASS (default: "TEST PASS")
#   --fail-token STR     String grepped for FAIL (default: "TEST FAIL")
#   --venv DIR           Python2 virtualenv to activate (default: $HOME/venv_pulp)
#   --bashrc FILE        Extra environment file to source (default: $BUILD_DIR/bashrc_pulpino.txt)
#   --no-build           Skip the make step (use existing binaries)
#   --help               Print this help and exit

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults                                                                     #
# --------------------------------------------------------------------------- #
PULPINO_DIR="${HOME}/pulpino"
BUILD_DIR=""            # resolved after PULPINO_DIR is known
LOG_FILE=""             # resolved at runtime
MAX_CYCLES=2000000
PASS_TOKEN="TEST PASS"
FAIL_TOKEN="TEST FAIL"
VENV_DIR="${HOME}/venv_pulp"
BASHRC_FILE=""          # resolved after BUILD_DIR is known
NO_BUILD=0
APP_NAME="testSPIMaster"

# --------------------------------------------------------------------------- #
# Argument parsing                                                             #
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pulpino-dir)  PULPINO_DIR="$2";  shift 2 ;;
        --build-dir)    BUILD_DIR="$2";    shift 2 ;;
        --log)          LOG_FILE="$2";     shift 2 ;;
        --max-cycles)   MAX_CYCLES="$2";   shift 2 ;;
        --pass-token)   PASS_TOKEN="$2";   shift 2 ;;
        --fail-token)   FAIL_TOKEN="$2";   shift 2 ;;
        --venv)         VENV_DIR="$2";     shift 2 ;;
        --bashrc)       BASHRC_FILE="$2";  shift 2 ;;
        --no-build)     NO_BUILD=1;        shift   ;;
        --help)
            sed -n '/^# Usage:/,/^[^#]/{ /^[^#]/!p }' "$0" | sed 's/^# \{0,2\}//'
            exit 0 ;;
        *) echo "ERROR: unknown option '$1'. Use --help for usage." >&2; exit 1 ;;
    esac
done

# Resolve derived defaults
[[ -z "$BUILD_DIR"   ]] && BUILD_DIR="${PULPINO_DIR}/sw/build"
[[ -z "$LOG_FILE"    ]] && LOG_FILE="/tmp/spi_sim_$(date +%s).log"
[[ -z "$BASHRC_FILE" ]] && BASHRC_FILE="${BUILD_DIR}/bashrc_pulpino.txt"

HEX_FILE="${BUILD_DIR}/apps/${APP_NAME}/${APP_NAME}.hex"

# --------------------------------------------------------------------------- #
# Helpers                                                                      #
# --------------------------------------------------------------------------- #
info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; }
pass()  { echo "[PASS]  $*"; }
fail()  { echo "[FAIL]  $*" >&2; }

# --------------------------------------------------------------------------- #
# 1. Activate environment                                                      #
# --------------------------------------------------------------------------- #
info "Activating environment..."

if [[ -f "${VENV_DIR}/bin/activate" ]]; then
    # shellcheck source=/dev/null
    source "${VENV_DIR}/bin/activate"
    info "Activated virtualenv: ${VENV_DIR}"
else
    info "Virtualenv not found at '${VENV_DIR}' – skipping activation."
fi

if [[ -f "${BASHRC_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${BASHRC_FILE}"
    info "Sourced: ${BASHRC_FILE}"
else
    info "bashrc file not found at '${BASHRC_FILE}' – skipping."
fi

# --------------------------------------------------------------------------- #
# 2. Sanity checks                                                             #
# --------------------------------------------------------------------------- #
if ! command -v vsim &>/dev/null; then
    error "vsim not found in PATH. Add ModelSim to PATH and re-run."
    exit 1
fi

if ! command -v riscv32-unknown-elf-gcc &>/dev/null; then
    error "riscv32-unknown-elf-gcc not found in PATH. Set up the RISC-V toolchain first."
    exit 1
fi

if [[ ! -d "${BUILD_DIR}" ]]; then
    error "Build directory not found: ${BUILD_DIR}"
    error "Run cmake_configure.zeroriscy.gcc.sh inside ${PULPINO_DIR}/sw/build first."
    exit 1
fi

# --------------------------------------------------------------------------- #
# 3. Build the test application                                                #
# --------------------------------------------------------------------------- #
if [[ $NO_BUILD -eq 0 ]]; then
    info "Building ${APP_NAME} in ${BUILD_DIR} ..."
    make -C "${BUILD_DIR}" "${APP_NAME}" 2>&1 | tee /tmp/spi_build.log
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        error "Build failed. See /tmp/spi_build.log for details."
        exit 1
    fi
    info "Build succeeded."
fi

if [[ ! -f "${HEX_FILE}" ]]; then
    error "Expected HEX file not found: ${HEX_FILE}"
    error "Build the application first (or remove --no-build)."
    exit 1
fi

info "HEX image: ${HEX_FILE}"

# --------------------------------------------------------------------------- #
# 4. Run ModelSim in command-line / batch mode                                 #
# --------------------------------------------------------------------------- #
info "Starting ModelSim simulation (log → ${LOG_FILE}) ..."
info "Watchdog: ${MAX_CYCLES} cycles"

# The PULPino build system exposes a *.vsimc Make target that runs vsim in
# batch mode.  Use it when available; fall back to a direct vsim invocation.
VSIM_TCL_SCRIPT=$(mktemp /tmp/vsim_run_XXXXXX.tcl)
cat > "${VSIM_TCL_SCRIPT}" <<EOF
# Auto-generated TCL script – do not edit manually
onbreak {resume}
set StdArithNoWarnings 1
set NumericStdNoWarnings 1

vsim -lib "${BUILD_DIR}/modelsim_libs/work" tb_pulpino \\
     +STIM="${HEX_FILE}" \\
     +MAX_CYCLES=${MAX_CYCLES}

run -all
quit -f
EOF

RC=0
make -C "${BUILD_DIR}" "${APP_NAME}.vsimc" 2>&1 | tee "${LOG_FILE}"
MAKE_RC=${PIPESTATUS[0]}
if [[ $MAKE_RC -eq 0 ]]; then
    info "ModelSim make target finished."
else
    # Fall back: invoke vsim directly with the generated TCL script
    info "Make target '${APP_NAME}.vsimc' not available; invoking vsim directly..."
    vsim -c -do "${VSIM_TCL_SCRIPT}" 2>&1 | tee -a "${LOG_FILE}"
    RC=${PIPESTATUS[0]}
fi

rm -f "${VSIM_TCL_SCRIPT}"

# --------------------------------------------------------------------------- #
# 5. Parse transcript for PASS / FAIL tokens                                   #
# --------------------------------------------------------------------------- #
info "Parsing transcript: ${LOG_FILE}"

PASS_COUNT=$(grep -c "${PASS_TOKEN}" "${LOG_FILE}" 2>/dev/null || true)
FAIL_COUNT=$(grep -c "${FAIL_TOKEN}" "${LOG_FILE}" 2>/dev/null || true)

echo ""
echo "=================================================="
echo " Simulation result summary"
echo "=================================================="
echo " Log file  : ${LOG_FILE}"
echo " PASS hits : ${PASS_COUNT}  (token: '${PASS_TOKEN}')"
echo " FAIL hits : ${FAIL_COUNT}  (token: '${FAIL_TOKEN}')"
echo "=================================================="
echo ""

if [[ "${PASS_COUNT}" -gt 0 && "${FAIL_COUNT}" -eq 0 ]]; then
    pass "SPI master test: TEST PASS"
    exit 0
else
    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        fail "SPI master test: FAIL token found in transcript."
        grep "${FAIL_TOKEN}" "${LOG_FILE}" | head -5 >&2
    elif [[ "${PASS_COUNT}" -eq 0 ]]; then
        fail "SPI master test: PASS token NOT found – simulation may have timed out or crashed."
        tail -20 "${LOG_FILE}" >&2
    fi
    exit 1
fi
