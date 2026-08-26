#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${1:?project root is required}"
OUTPUT_ROOT="${2:?output root is required}"
MNN_SOURCE_ROOT="${3:?MNN source root is required}"

for command in aarch64-linux-gnu-g++ sha256sum; do
    command -v "${command}" >/dev/null 2>&1 || {
        printf 'ERROR=missing_command:%s\n' "${command}" >&2
        exit 2
    }
done
[[ -f "${MNN_SOURCE_ROOT}/include/MNN/Interpreter.hpp" ]] || {
    printf 'ERROR=MNN_headers_missing:%s\n' "${MNN_SOURCE_ROOT}" >&2
    exit 3
}
[[ -f "${OUTPUT_ROOT}/libMNN.so" ]] || {
    printf 'ERROR=libMNN_missing:%s\n' "${OUTPUT_ROOT}/libMNN.so" >&2
    exit 4
}

# Rebuild only the tiny smoke executable.  The 452-file MNN library and model
# are deliberately reused so capability checks do not trigger costly rebuilds.
aarch64-linux-gnu-g++ -std=c++14 -O2 \
    -I"${MNN_SOURCE_ROOT}/include" \
    "${PROJECT_ROOT}/tools/mnn/mnn_opencl_smoke.cpp" \
    -L"${OUTPUT_ROOT}" -lMNN -ldl -lpthread \
    -Wl,-rpath,'$ORIGIN' \
    -o "${OUTPUT_ROOT}/mnn-opencl-smoke"

sha256sum "${PROJECT_ROOT}/tools/mnn/mnn_opencl_smoke.cpp" \
    > "${OUTPUT_ROOT}/mnn-opencl-smoke-source.sha256"
printf '%s\n' 'RESULT=PASS_MNN_OPENCL_SMOKE_INCREMENTAL_BUILD'
