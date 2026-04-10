#!/bin/bash
# run_tests.sh — RV32IMAC ISA Compliance Test Runner
# Compiles each test with iverilog, runs simulation, reports results.
# Usage: ./run_tests.sh [--stall] [test_name ...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TB="${SCRIPT_DIR}/tb_rv32i_cpu.v"
RTL="${SCRIPT_DIR}/../src/rv32i_cpu.v"
TEST_DIR="${SCRIPT_DIR}/tests"
BUILD_DIR="${SCRIPT_DIR}/build"

mkdir -p "${BUILD_DIR}"

PASS_COUNT=0
FAIL_COUNT=0
TIMEOUT_COUNT=0
TOTAL=0
FAILED_TESTS=""

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
    # Add WFI timer for wfi test
    if [ "${test_name}" = "test_wfi" ]; then
        extra_flags="${extra_flags} -DWFI_TIMER_CYCLES=200"
    fi
    # Add NMI pulse for nmi test
    if [ "${test_name}" = "test_nmi" ]; then
        extra_flags="${extra_flags} -DNMI_CYCLES=50"
    fi
    # Add timer interrupt for vectored interrupt test
    if [ "${test_name}" = "test_vectored_irq" ]; then
        extra_flags="${extra_flags} -DWFI_TIMER_CYCLES=80"
    fi
    # Add software interrupt for MSIP test
    if [ "${test_name}" = "test_soft_irq" ]; then
        extra_flags="${extra_flags} -DSOFT_IRQ_CYCLES=80"
    fi
    # Add instruction memory error for fetch fault test
    if [ "${test_name}" = "test_imem_error" ]; then
        extra_flags="${extra_flags} -DIMEM_ERROR_CYCLES=30"
    fi
    # Add NMI + timer for NMI-during-interrupt test
    if [ "${test_name}" = "test_nmi_during_irq" ]; then
        extra_flags="${extra_flags} -DWFI_TIMER_CYCLES=80 -DNMI_CYCLES=120"
    fi
    # Add external interrupt for MEIP test
    if [ "${test_name}" = "test_ext_irq" ]; then
        extra_flags="${extra_flags} -DEXT_IRQ_CYCLES=80"
    fi
    TOTAL=$((TOTAL + 1))

    printf "  [%-24s] " "${test_name}${suffix}"

    if ! iverilog -g2012 -o "${BUILD_DIR}/${test_name}${suffix}.vvp" \
        -DTEST_HEX=\""${test_hex}"\" ${extra_flags} \
        "${TB}" "${RTL}" 2>"${BUILD_DIR}/${test_name}${suffix}.compile.log"; then
        printf "${RED}COMPILE ERROR${NC}\n"
        cat "${BUILD_DIR}/${test_name}${suffix}.compile.log"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS="${FAILED_TESTS} ${test_name}${suffix}(compile)"
        return
    fi

    local sim_out
    sim_out=$(cd "${BUILD_DIR}" && perl -e 'alarm 60; exec @ARGV' vvp -N "${test_name}${suffix}.vvp" 2>&1) || true

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
        FAILED_TESTS="${FAILED_TESTS} ${test_name}${suffix}"
        echo "${sim_out}" | grep -A 40 "Register File" || true
    elif echo "${sim_out}" | grep -q "^TIMEOUT"; then
        printf "${YELLOW}TIMEOUT${NC}\n"
        TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
        FAILED_TESTS="${FAILED_TESTS} ${test_name}${suffix}(timeout)"
        echo "${sim_out}" | grep -A 40 "Register File" || true
    else
        printf "${RED}UNKNOWN${NC}\n"
        echo "${sim_out}" | tail -20
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS="${FAILED_TESTS} ${test_name}${suffix}(unknown)"
    fi
}

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  RV32IMAC ISA Compliance Test Suite (8-Stage Pipeline)${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

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

run_tests_with_flags ""

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

if [ "${FAIL_COUNT}" -gt 0 ] || [ "${TIMEOUT_COUNT}" -gt 0 ]; then
    exit 1
fi
exit 0
