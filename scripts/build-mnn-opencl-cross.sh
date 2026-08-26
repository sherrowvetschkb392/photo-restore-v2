#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${1:?project root is required}"
OUTPUT_ROOT="${2:?output root is required}"
MNN_REF="${3:-3.0.0}"
INSTALL_TOOLS="${4:-false}"
OPENCL_LIBRARY="${5:?ARM64 OpenCL library is required}"
WORK_ROOT="${6:-/mnt/d/photo-restore-mnn-opencl}"
SOURCE_ROOT="${WORK_ROOT}/MNN"

if [[ "${INSTALL_TOOLS}" == "true" ]]; then
    sudo apt-get install -y --no-install-recommends \
        git cmake ninja-build build-essential \
        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
        protobuf-compiler libprotobuf-dev opencl-headers ocl-icd-opencl-dev
fi

for command in git cmake ninja aarch64-linux-gnu-gcc aarch64-linux-gnu-g++ python3; do
    command -v "${command}" >/dev/null 2>&1 || {
        printf 'ERROR=missing_command:%s\n' "${command}" >&2
        exit 2
    }
done
python3 -c 'import onnx, numpy' >/dev/null 2>&1 || {
    printf '%s\n' 'ERROR=python_modules_missing:onnx_or_numpy' >&2
    exit 3
}
[[ -f "${OPENCL_LIBRARY}" ]] || { printf 'ERROR=opencl_library_missing:%s\n' "${OPENCL_LIBRARY}" >&2; exit 4; }

mkdir -p "${WORK_ROOT}" "${OUTPUT_ROOT}"
available_bytes="$(df -Pk "${WORK_ROOT}" | awk 'NR==2 {print $4 * 1024}')"
if [[ -z "${available_bytes}" || "${available_bytes}" -lt $((20 * 1024 * 1024 * 1024)) ]]; then
    printf 'ERROR=insufficient_build_disk_space:path=%s:available_bytes=%s\n' "${WORK_ROOT}" "${available_bytes:-unknown}" >&2
    exit 7
fi
if [[ ! -d "${SOURCE_ROOT}/.git" ]]; then
    git clone --depth 1 --branch "${MNN_REF}" https://github.com/alibaba/MNN.git "${SOURCE_ROOT}"
else
    git -C "${SOURCE_ROOT}" fetch --depth 1 origin "${MNN_REF}"
    git -C "${SOURCE_ROOT}" checkout --detach FETCH_HEAD
fi
MNN_COMMIT="$(git -C "${SOURCE_ROOT}" rev-parse HEAD)"

HOST_BUILD="${WORK_ROOT}/build-host"
ARM_BUILD="${WORK_ROOT}/build-arm64"
rm -rf "${HOST_BUILD}" "${ARM_BUILD}"

cmake -S "${SOURCE_ROOT}" -B "${HOST_BUILD}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DMNN_BUILD_CONVERTER=ON \
    -DMNN_BUILD_SHARED_LIBS=ON \
    -DMNN_BUILD_TOOLS=ON \
    -DMNN_OPENCL=OFF \
    -DMNN_BUILD_TEST=OFF
cmake --build "${HOST_BUILD}" --target MNNConvert -j "$(nproc)"
MNN_CONVERT="$(find "${HOST_BUILD}" -type f -name MNNConvert -perm -111 -print -quit)"
[[ -n "${MNN_CONVERT}" ]] || { printf '%s\n' 'ERROR=MNNConvert_not_found' >&2; exit 5; }

OPENCL_INCLUDE="${WORK_ROOT}/opencl-include"
rm -rf "${OPENCL_INCLUDE}"
mkdir -p "${OPENCL_INCLUDE}/CL"
cp -a /usr/include/CL/. "${OPENCL_INCLUDE}/CL/"

cmake -S "${SOURCE_ROOT}" -B "${ARM_BUILD}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
    -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
    -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -DMNN_OPENCL=ON \
    -DMNN_BUILD_SHARED_LIBS=ON \
    -DMNN_BUILD_CONVERTER=OFF \
    -DMNN_BUILD_TOOLS=OFF \
    -DMNN_BUILD_TEST=OFF \
    -DOpenCL_INCLUDE_DIR="${OPENCL_INCLUDE}" \
    -DOpenCL_LIBRARY="${OPENCL_LIBRARY}"
cmake --build "${ARM_BUILD}" --target MNN -j "$(nproc)"

ONNX_MODEL="${OUTPUT_ROOT}/mnn-opencl-smoke.onnx"
MNN_MODEL="${OUTPUT_ROOT}/mnn-opencl-smoke.mnn"
python3 "${PROJECT_ROOT}/tools/mnn/make_opencl_smoke_onnx.py" \
    --output "${ONNX_MODEL}" \
    --report "${OUTPUT_ROOT}/mnn-opencl-smoke-onnx.json"
"${MNN_CONVERT}" -f ONNX --modelFile "${ONNX_MODEL}" --MNNModel "${MNN_MODEL}" --bizCode photo_restore_v2

MNN_LIBRARY="$(find "${ARM_BUILD}" -maxdepth 3 -type f -name 'libMNN.so*' -print | sort | tail -1)"
[[ -n "${MNN_LIBRARY}" ]] || { printf '%s\n' 'ERROR=libMNN_not_found' >&2; exit 6; }
cp -L "${MNN_LIBRARY}" "${OUTPUT_ROOT}/libMNN.so"

aarch64-linux-gnu-g++ -std=c++14 -O2 \
    -I"${SOURCE_ROOT}/include" \
    "${PROJECT_ROOT}/tools/mnn/mnn_opencl_smoke.cpp" \
    -L"${OUTPUT_ROOT}" -lMNN -ldl -lpthread \
    -Wl,-rpath,'$ORIGIN' \
    -o "${OUTPUT_ROOT}/mnn-opencl-smoke"

cat > "${OUTPUT_ROOT}/build-record.json" <<JSON
{
  "schema_version": 1,
  "mnn_ref": "${MNN_REF}",
  "mnn_commit": "${MNN_COMMIT}",
  "architecture": "aarch64",
  "opencl": true,
  "board_upload": false
}
JSON
sha256sum \
    "${OUTPUT_ROOT}/libMNN.so" \
    "${OUTPUT_ROOT}/mnn-opencl-smoke" \
    "${OUTPUT_ROOT}/mnn-opencl-smoke.mnn" \
    > "${OUTPUT_ROOT}/SHA256SUMS"

printf 'MNN_REF=%s\n' "${MNN_REF}"
printf 'MNN_COMMIT=%s\n' "${MNN_COMMIT}"
printf 'OUTPUT=%s\n' "${OUTPUT_ROOT}"
printf 'WORK_ROOT=%s\n' "${WORK_ROOT}"
printf '%s\n' 'BOARD_UPLOAD=False'
printf '%s\n' 'RESULT=PASS_MNN_OPENCL_CROSS_BUILD'
