#!/bin/bash
# run_tests.sh — RV32I ISA Compliance Test Runner
# Compiles each test with iverilog, runs simulation, reports results.
# Usage: ./run_tests.sh [test_name]  (omit test_name to run all)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TB="${SCRIPT_DIR}/tb_rv32i_cpu.v"
RTL_SRC="${SCRIPT_DIR}/../src/rv32i_cpu.v"
TEST_DIR="${SCRIPT_DIR}/tests"
BUILD_DIR="${SCRIPT_DIR}/build"
RTL="${BUILD_DIR}/rv32i_cpu_sim.v"

mkdir -p "${BUILD_DIR}"

# Create sim-compatible RTL copy (forward-declare wires for iverilog)
python3 -c "
lines = open('${RTL_SRC}').readlines()
out = []
for i, line in enumerate(lines, 1):
    out.append(line)
    if i == 114:
        out.append('    wire        mem_stall;\n')
        out.append('    wire [31:0] wb_data;\n')
        out.append('    wire        mul_stall;\n')
        out.append('    wire        div_stall;\n')
        out.append('    wire        mul_div_stall;\n')
        out.append('    wire        load_use_hazard;\n')
        out.append('    wire        fetch_stall;\n')
result = []
for line in out:
    s = line.strip()
    if s == 'wire mem_stall  = (exmem_mem_read || exmem_mem_write) && exmem_valid && !dmem_ready;':
        result.append(line.replace('wire mem_stall  =', 'assign mem_stall ='))
    elif s == 'wire [31:0] wb_data;' and len(result) > 120:
        result.append(line.replace('wire [31:0] wb_data;', '// wb_data: forward-declared near line 115'))
    elif s.startswith('wire mul_stall ='):
        result.append(line.replace('wire mul_stall =', 'assign mul_stall ='))
    elif s.startswith('wire div_stall ='):
        result.append(line.replace('wire div_stall =', 'assign div_stall ='))
    elif s.startswith('wire mul_div_stall ='):
        result.append(line.replace('wire mul_div_stall =', 'assign mul_div_stall ='))
    elif s == 'wire load_use_hazard;' and len(result) > 350:
        result.append(line.replace('wire load_use_hazard;', '// load_use_hazard: forward-declared near line 115'))
    elif s.startswith('assign load_use_hazard =') and len(result) > 350:
        result.append(line)  # keep the assign as-is
    elif s == 'wire        fetch_stall = imem_req && !imem_ready;':
        result.append(line.replace('wire        fetch_stall =', 'assign fetch_stall ='))
    elif s == 'wire fetch_stall = imem_req && !imem_ready;':
        result.append(line.replace('wire fetch_stall =', 'assign fetch_stall ='))
    else:
        result.append(line)
with open('${RTL}', 'w') as f:
    f.writelines(result)
"

PASS_COUNT=0
FAIL_COUNT=0
TIMEOUT_COUNT=0
TOTAL=0
FAILED_TESTS=""

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

run_test() {
    local test_hex="$1"
    local extra_flags="$2"
    local test_name
    test_name="$(basename "${test_hex}" .hex)"
    local suffix=""
    if [ -n "${extra_flags}" ]; then
        suffix="_stall"
    fi
    TOTAL=$((TOTAL + 1))

    printf "  [%-24s] " "${test_name}${suffix}"

    # Compile
    if ! iverilog -g2012 -o "${BUILD_DIR}/${test_name}${suffix}.vvp" \
        -DTEST_HEX=\""${test_hex}"\" ${extra_flags} \
        "${TB}" "${RTL}" 2>"${BUILD_DIR}/${test_name}${suffix}.compile.log"; then
        printf "${RED}COMPILE ERROR${NC}\n"
        cat "${BUILD_DIR}/${test_name}${suffix}.compile.log"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS="${FAILED_TESTS} ${test_name}${suffix}(compile)"
        return
    fi

    # Run simulation (use perl timeout on macOS)
    local sim_out
    sim_out=$(cd "${BUILD_DIR}" && perl -e 'alarm 60; exec @ARGV' vvp -N "${test_name}${suffix}.vvp" 2>&1) || true

    # Parse result
    if echo "${sim_out}" | grep -q "^PASS"; then
        local cycles
        cycles=$(echo "${sim_out}" | grep "^PASS" | sed 's/.*(\([0-9]*\) cycles)/\1/')
        printf "${GREEN}PASS${NC} (%s cycles)\n" "${cycles}"
        PASS_COUNT=$((PASS_COUNT + 1))
    elif echo "${sim_out}" | grep -q "^FAIL"; then
        local tohost
        tohost=$(echo "${sim_out}" | grep "^FAIL" | sed 's/FAIL: tohost = \([0-9]*\).*/\1/')
        printf "${RED}FAIL${NC} (tohost=%s)\n" "${tohost}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS="${FAILED_TESTS} ${test_name}"
        # Show register dump
        echo "${sim_out}" | grep -A 40 "Register File" || true
    elif echo "${sim_out}" | grep -q "^TIMEOUT"; then
        printf "${YELLOW}TIMEOUT${NC}\n"
        TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
        FAILED_TESTS="${FAILED_TESTS} ${test_name}(timeout)"
        echo "${sim_out}" | grep -A 40 "Register File" || true
    else
        printf "${RED}UNKNOWN${NC}\n"
        echo "${sim_out}" | tail -20
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS="${FAILED_TESTS} ${test_name}(unknown)"
    fi
}

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  RV32I ISA Compliance Test Suite${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Check for --stall flag
STALL_MODE=0
TESTS_TO_RUN=()
for arg in "$@"; do
    if [ "$arg" = "--stall" ]; then
        STALL_MODE=1
    else
        TESTS_TO_RUN+=("$arg")
    fi
done

run_tests_with_flags() {
    local flags="$1"
    if [ ${#TESTS_TO_RUN[@]} -gt 0 ]; then
        for name in "${TESTS_TO_RUN[@]}"; do
            hex="${TEST_DIR}/${name}.hex"
            if [ ! -f "${hex}" ]; then
                echo "ERROR: Test not found: ${hex}"
                exit 1
            fi
            run_test "${hex}" "${flags}"
        done
    else
        for hex in "${TEST_DIR}"/*.hex; do
            run_test "${hex}" "${flags}"
        done
    fi
}

# Normal run (zero-latency memory)
run_tests_with_flags ""

# Stall mode: re-run with multi-cycle memory latencies
if [ "${STALL_MODE}" -eq 1 ]; then
    echo ""
    echo -e "${CYAN}  --- Re-running with IMEM_LATENCY=2, DMEM_LATENCY=3 ---${NC}"
    echo ""
    run_tests_with_flags "-DIMEM_LATENCY=2 -DDMEM_LATENCY=3"
fi

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "  Results: ${GREEN}${PASS_COUNT} passed${NC}, ${RED}${FAIL_COUNT} failed${NC}, ${YELLOW}${TIMEOUT_COUNT} timeout${NC} / ${TOTAL} total"
if [ -n "${FAILED_TESTS}" ]; then
    echo -e "  Failed:${RED}${FAILED_TESTS}${NC}"
fi
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Exit with failure if any test failed
if [ "${FAIL_COUNT}" -gt 0 ] || [ "${TIMEOUT_COUNT}" -gt 0 ]; then
    exit 1
fi
exit 0
