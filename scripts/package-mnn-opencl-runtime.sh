#!/usr/bin/env bash
set -euo pipefail

OUTPUT_ROOT="${1:?MNN output root is required}"
RUNTIME_ROOT="${OUTPUT_ROOT}/runtime"

command -v aarch64-linux-gnu-g++ >/dev/null 2>&1 || {
    printf '%s\n' 'ERROR=missing_command:aarch64-linux-gnu-g++' >&2
    exit 2
}
[[ -f "${OUTPUT_ROOT}/libMNN.so" ]] || {
    printf 'ERROR=missing_artifact:%s\n' "${OUTPUT_ROOT}/libMNN.so" >&2
    exit 3
}
[[ -f "${OUTPUT_ROOT}/mnn-opencl-smoke" ]] || {
    printf 'ERROR=missing_artifact:%s\n' "${OUTPUT_ROOT}/mnn-opencl-smoke" >&2
    exit 3
}

rm -rf "${RUNTIME_ROOT}"
mkdir -p "${RUNTIME_ROOT}"

copy_runtime_library() {
    local name="$1"
    local source
    source="$(aarch64-linux-gnu-g++ -print-file-name="${name}")"
    if [[ "${source}" == "${name}" || ! -f "${source}" ]]; then
        printf 'ERROR=cross_runtime_library_not_found:%s:%s\n' "${name}" "${source}" >&2
        exit 4
    fi
    cp -L "${source}" "${RUNTIME_ROOT}/${name}"
    chmod 755 "${RUNTIME_ROOT}/${name}"
}

# The WSL cross toolchain is newer than the Debian 11 board.  Keep its loader
# and userspace ABI private to this isolated test instead of replacing board
# libraries or installing packages globally.
for name in \
    ld-linux-aarch64.so.1 \
    libc.so.6 \
    libm.so.6 \
    libmvec.so.1 \
    libstdc++.so.6 \
    libgcc_s.so.1 \
    libdl.so.2 \
    libpthread.so.0 \
    librt.so.1; do
    copy_runtime_library "${name}"
done

cat > "${OUTPUT_ROOT}/runtime-record.json" <<JSON
{
  "schema_version": 1,
  "architecture": "aarch64",
  "strategy": "isolated_cross_toolchain_runtime",
  "loader": "runtime/ld-linux-aarch64.so.1",
  "board_system_libraries_changed": false
}
JSON

printf 'RUNTIME=%s\n' "${RUNTIME_ROOT}"
printf '%s\n' 'BOARD_SYSTEM_LIBRARIES_CHANGED=False'
printf '%s\n' 'RESULT=PASS_MNN_OPENCL_RUNTIME_PACKAGE'
