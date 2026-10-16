#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${KOKKOS_PRIMER_BUILD_DIR:-${SCRIPT_DIR}/build}"
TEST_EXECUTABLE="${BUILD_DIR}/kokkos_tests"
OUTPUT_DIR="${KOKKOS_PRIMER_PROFILE_OUTPUT_DIR:-${SCRIPT_DIR}/profiling-name-results}"
PROFILE_BASE="${OUTPUT_DIR}/profiling_names"
TARGET_ALIAS="KokkosPrimer.NcuRename.Functor"
OUTER_ALIAS="KokkosPrimer.NcuRename.Outer"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $1" >&2
        exit 1
    fi
}

check_contains() {
    local needle="$1"
    local file="$2"
    if ! grep -Fq -- "$needle" "$file"; then
        echo "ERROR: expected '$needle' in $file" >&2
        exit 1
    fi
}

check_not_contains() {
    local needle="$1"
    local file="$2"
    if grep -Fq -- "$needle" "$file"; then
        echo "ERROR: did not expect '$needle' in $file" >&2
        exit 1
    fi
}

preflight() {
    require_command ncu
    require_command nsys
    require_command python3

    local ncu_help
    local required_options=(
        --rename-kernels
        --rename-kernels-path
        --rename-kernels-export
        --kernel-name-base
    )
    ncu_help="$(ncu --help)"
    for option in "${required_options[@]}"; do
        if ! grep -Fq -- "$option" <<<"$ncu_help"; then
            echo "ERROR: installed ncu does not support $option" >&2
            exit 1
        fi
    done

    local discovery_json="${OUTPUT_DIR}/nsys_discovery.json"
    mkdir -p "$OUTPUT_DIR"
    python3 "${SCRIPT_DIR}/profiling_name_tools.py" --discover --json \
        > "$discovery_json"

    for report in cuda_gpu_kern_sum cuda_gpu_trace nvtx_kern_sum nvtx_gpu_proj_sum; do
        if ! grep -Fq -- "\"$report\"" "$discovery_json"; then
            echo "ERROR: installed nsys lacks required report $report. " \
                 "Install a newer Nsight Systems release and retry." >&2
            exit 1
        fi
    done
    if ! grep -Fq -- "\"nvtx_gpu_proj_trace\"" "$discovery_json"; then
        echo "ERROR: installed nsys lacks required recipe nvtx_gpu_proj_trace. " \
             "Install a newer Nsight Systems release and retry." >&2
        exit 1
    fi

    echo "PASS: NCU pre-collection rename flags are available"
    echo "PASS: NSYS stats reports and recipes are discoverable"
    echo "Discovery inventory: $discovery_json"
}

profile_with_nsys() {
    if [ ! -x "$TEST_EXECUTABLE" ]; then
        echo "ERROR: test executable not found: $TEST_EXECUTABLE" >&2
        echo "Build the test suite first, or set KOKKOS_PRIMER_BUILD_DIR." >&2
        exit 1
    fi

    mkdir -p "$OUTPUT_DIR"
    nsys profile \
        --trace=cuda,nvtx \
        --sample=none \
        --backtrace=none \
        --output="$PROFILE_BASE" \
        --force-overwrite=true \
        "$TEST_EXECUTABLE" --gtest_filter=ProfilingNames.StableKernelNames

    local nsys_report="${PROFILE_BASE}.nsys-rep"
    if [ ! -s "$nsys_report" ]; then
        echo "ERROR: nsys did not create $nsys_report" >&2
        exit 1
    fi

    local sqlite_file="${OUTPUT_DIR}/profiling_names.sqlite"
    nsys export -t sqlite --force-overwrite=true \
        "$nsys_report" -o "$sqlite_file"
    if [ ! -s "$sqlite_file" ]; then
        echo "ERROR: nsys did not create $sqlite_file" >&2
        exit 1
    fi

    local yaml_file="${OUTPUT_DIR}/ncu-kernel-renames.yaml"
    python3 "${SCRIPT_DIR}/profiling_name_tools.py" \
        "$sqlite_file" \
        --label-prefix KokkosPrimer.NcuRename. \
        --output "$yaml_file"
    check_contains "$TARGET_ALIAS" "$yaml_file"
    check_not_contains "$OUTER_ALIAS" "$yaml_file"

    nsys stats "$nsys_report" \
        --report cuda_gpu_kern_sum:nvtx-name \
        --format csv \
        --timeunit ns \
        --quiet \
        --force-export=true \
        > "${OUTPUT_DIR}/cuda_gpu_kern_sum_nvtx_name.csv"
    check_contains \
        "$TARGET_ALIAS" "${OUTPUT_DIR}/cuda_gpu_kern_sum_nvtx_name.csv"
    check_not_contains \
        "$OUTER_ALIAS" "${OUTPUT_DIR}/cuda_gpu_kern_sum_nvtx_name.csv"

    nsys stats "$nsys_report" \
        --report nvtx_kern_sum \
        --format csv \
        --timeunit ns \
        --quiet \
        --force-export=true \
        > "${OUTPUT_DIR}/nvtx_kern_sum.csv"
    check_contains "$TARGET_ALIAS" "${OUTPUT_DIR}/nvtx_kern_sum.csv"
    check_contains "$OUTER_ALIAS" "${OUTPUT_DIR}/nvtx_kern_sum.csv"

    echo "PASS: NSYS correlated Kokkos test launches with NVTX names"
    echo "NCU rename map: $yaml_file"
}

profile_first_ncu_pass_with_map() {
    local yaml_file="${OUTPUT_DIR}/ncu-kernel-renames.yaml"
    if [ ! -s "$yaml_file" ]; then
        echo "ERROR: run the nsys step first to generate $yaml_file" >&2
        exit 1
    fi

    local ncu_base="${OUTPUT_DIR}/ncu_first_pass_by_alias"
    local ncu_log="${OUTPUT_DIR}/ncu_first_pass_by_alias.log"
    local ncu_report=""
    local candidate

    # Remove both report formats so a stale capture cannot satisfy validation.
    for candidate in "${ncu_base}.ncu-rep" "${ncu_base}.ncu-repz"; do
        if [ -e "$candidate" ]; then
            echo "Removing existing NCU report: $candidate"
            rm -f -- "$candidate"
        fi
        if [ -e "$candidate" ]; then
            echo "ERROR: could not remove existing NCU report: $candidate" >&2
            exit 1
        fi
    done

    # Collect the small workload without a name filter. Verify selection by the
    # mapped alias when importing the report, after applying the rename map.
    ncu \
        --force-overwrite \
        --export "$ncu_base" \
        --section LaunchStats \
        --rename-kernels on \
        --rename-kernels-path "$yaml_file" \
        "$TEST_EXECUTABLE" --gtest_filter=ProfilingNames.StableKernelNames \
        2>&1 | tee "$ncu_log"

    # Newer NCU releases can write compressed reports with a .ncu-repz suffix.
    for candidate in "${ncu_base}.ncu-rep" "${ncu_base}.ncu-repz"; do
        if [ -s "$candidate" ]; then
            ncu_report="$candidate"
            break
        fi
    done
    if [ -z "$ncu_report" ]; then
        echo "ERROR: NCU did not collect the mapped kernel" >&2
        exit 1
    fi

    ncu \
        --import "$ncu_report" \
        --page raw \
        --csv \
        --print-kernel-base demangled \
        --kernel-name-base demangled \
        --kernel-name "$TARGET_ALIAS" \
        --rename-kernels on \
        --rename-kernels-path "$yaml_file" \
        > "${OUTPUT_DIR}/ncu_import.csv"
    check_contains "$TARGET_ALIAS" "${OUTPUT_DIR}/ncu_import.csv"

    echo "PASS: NCU loaded the rename map for its initial collection"
    check_not_contains "KokkosPrimer.NcuRename.Lambda" "${OUTPUT_DIR}/ncu_import.csv"
    check_not_contains "KokkosPrimer.NcuRename.WorkTag" "${OUTPUT_DIR}/ncu_import.csv"

    echo "PASS: importing by the mapped alias selects only the functor kernel"
}

run_unit_tests() {
    (
        cd "$SCRIPT_DIR"
        python3 -m unittest -v test_profiling_name_tools.py
    )
}

case "${1:-all}" in
    unit)
        run_unit_tests
        ;;
    preflight)
        preflight
        ;;
    nsys)
        preflight
        profile_with_nsys
        ;;
    ncu)
        preflight
        profile_first_ncu_pass_with_map
        ;;
    all)
        run_unit_tests
        preflight
        profile_with_nsys
        profile_first_ncu_pass_with_map
        ;;
    *)
        echo "Usage: $0 [unit|preflight|nsys|ncu|all]" >&2
        exit 2
        ;;
esac
