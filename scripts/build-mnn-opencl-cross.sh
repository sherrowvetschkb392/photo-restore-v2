#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${1:?project root is required}"
OUTPUT_ROOT="${2:?output root is required}"
MNN_REF="${3:-3.0.0}"
INSTALL_TOOLS="${4:-false}"
OPENCL_LIBRARY="${5:?ARM64 OpenCL library is required}"
WORK_ROOT="${6:-/mnt/d/photo-restore-mnn-opencl}"
SOURCE_ROOT="${WORK_ROOT}/MNN"

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "${PYTHON_BIN}" ]]; then
    for candidate in \
        /home/ljd/miniconda3/envs/photo-restore-videoexport/bin/python \
        /home/ljd/miniconda3/envs/photo-restore-rknn232/bin/python \
        python3; do
        if command -v "${candidate}" >/dev/null 2>&1 || [[ -x "${candidate}" ]]; then
            if "${candidate}" -c 'import onnx, numpy' >/dev/null 2>&1; then
                PYTHON_BIN="${candidate}"
                break
            fi
        fi
    done
fi

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
[[ -n "${PYTHON_BIN}" ]] || {
    printf '%s\n' 'ERROR=python_modules_missing:onnx_or_numpy:checked_videoexport_rknn232_system' >&2
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
MNN_CONVERT="$(find "${HOST_BUILD}" -type f -name MNNConvert -perm -111 -print -quit 2>/dev/null || true)"
if [[ -z "${MNN_CONVERT}" ]]; then
    rm -rf "${HOST_BUILD}"
    cmake -S "${SOURCE_ROOT}" -B "${HOST_BUILD}" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DMNN_BUILD_CONVERTER=ON \
        -DMNN_BUILD_SHARED_LIBS=ON \
        -DMNN_BUILD_TOOLS=ON \
        -DMNN_OPENCL=OFF \
        -DMNN_BUILD_TEST=OFF
    cmake --build "${HOST_BUILD}" --target MNNConvert -j "$(nproc)"
    MNN_CONVERT="$(find "${HOST_BUILD}" -type f -name MNNConvert -perm -111 -print -quit)"
fi
[[ -n "${MNN_CONVERT}" ]] || { printf '%s\n' 'ERROR=MNNConvert_not_found' >&2; exit 5; }

OPENCL_INCLUDE="${WORK_ROOT}/opencl-include"
rm -rf "${OPENCL_INCLUDE}"
mkdir -p "${OPENCL_INCLUDE}/CL"
cp -a /usr/include/CL/. "${OPENCL_INCLUDE}/CL/"

rm -rf "${ARM_BUILD}"
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
    -DMNN_SEP_BUILD=OFF \
    -DMNN_BUILD_SHARED_LIBS=ON \
    -DMNN_BUILD_CONVERTER=OFF \
    -DMNN_BUILD_TOOLS=OFF \
    -DMNN_BUILD_TEST=OFF \
    -DOpenCL_INCLUDE_DIR="${OPENCL_INCLUDE}" \
    -DOpenCL_LIBRARY="${OPENCL_LIBRARY}"
cmake --build "${ARM_BUILD}" --target MNN -j "$(nproc)"

grep -Eq '^MNN_OPENCL:BOOL=ON$' "${ARM_BUILD}/CMakeCache.txt" || {
    printf '%s\n' 'ERROR=MNN_OPENCL_not_enabled_in_cmake_cache' >&2
    exit 8
}
grep -Eq '^MNN_SEP_BUILD:BOOL=OFF$' "${ARM_BUILD}/CMakeCache.txt" || {
    printf '%s\n' 'ERROR=MNN_SEP_BUILD_not_disabled_in_cmake_cache' >&2
    exit 9
}

ONNX_MODEL="${OUTPUT_ROOT}/mnn-opencl-smoke.onnx"
MNN_MODEL="${OUTPUT_ROOT}/mnn-opencl-smoke.mnn"
"${PYTHON_BIN}" "${PROJECT_ROOT}/tools/mnn/make_opencl_smoke_onnx.py" \
    --output "${ONNX_MODEL}" \
    --report "${OUTPUT_ROOT}/mnn-opencl-smoke-onnx.json"
"${MNN_CONVERT}" -f ONNX --modelFile "${ONNX_MODEL}" --MNNModel "${MNN_MODEL}" --bizCode photo_restore_v2

MNN_LIBRARY="$(find "${ARM_BUILD}" -maxdepth 3 -type f -name 'libMNN.so*' -print | sort | tail -1)"
[[ -n "${MNN_LIBRARY}" ]] || { printf '%s\n' 'ERROR=libMNN_not_found' >&2; exit 6; }
rm -f "${OUTPUT_ROOT}/libMNN.so" "${OUTPUT_ROOT}/libMNN_CL.so"
cp -L "${MNN_LIBRARY}" "${OUTPUT_ROOT}/libMNN.so"

OPENCL_PLUGIN="$(find "${ARM_BUILD}" -type f -name 'libMNN_CL.so*' -print | sort | tail -1)"
if [[ -n "${OPENCL_PLUGIN}" ]]; then
    cp -L "${OPENCL_PLUGIN}" "${OUTPUT_ROOT}/libMNN_CL.so"
fi
if ! grep -q 'source/backend/opencl/CMakeFiles/MNN_CL.dir' "${ARM_BUILD}/build.ninja"; then
    printf '%s\n' 'ERROR=OpenCL_backend_objects_not_linked' >&2
    exit 10
fi

aarch64-linux-gnu-g++ -std=c++14 -O2 \
    -I"${SOURCE_ROOT}/include" \
    "${PROJECT_ROOT}/tools/mnn/mnn_opencl_smoke.cpp" \
    -L"${OUTPUT_ROOT}" -lMNN -ldl -lpthread \
    -Wl,-rpath,'$ORIGIN' \
    -o "${OUTPUT_ROOT}/mnn-opencl-smoke"

bash "${PROJECT_ROOT}/scripts/package-mnn-opencl-runtime.sh" "${OUTPUT_ROOT}"

cat > "${OUTPUT_ROOT}/build-record.json" <<JSON
{
  "schema_version": 1,
  "mnn_ref": "${MNN_REF}",
  "mnn_commit": "${MNN_COMMIT}",
  "architecture": "aarch64",
  "opencl": true,
  "separate_backend": false,
  "opencl_plugin": $(if [[ -f "${OUTPUT_ROOT}/libMNN_CL.so" ]]; then printf 'true'; else printf 'false'; fi),
  "board_upload": false
}
JSON
(
    cd "${OUTPUT_ROOT}"
    sha256sum \
        libMNN.so \
        mnn-opencl-smoke \
        mnn-opencl-smoke.mnn \
        runtime-record.json \
        runtime/* \
        > SHA256SUMS
    if [[ -f libMNN_CL.so ]]; then
        sha256sum libMNN_CL.so >> SHA256SUMS
    fi
)

printf 'MNN_REF=%s\n' "${MNN_REF}"
printf 'MNN_COMMIT=%s\n' "${MNN_COMMIT}"
printf 'PYTHON_BIN=%s\n' "${PYTHON_BIN}"
printf 'OUTPUT=%s\n' "${OUTPUT_ROOT}"
printf 'WORK_ROOT=%s\n' "${WORK_ROOT}"
printf '%s\n' 'BOARD_UPLOAD=False'
printf '%s\n' 'RESULT=PASS_MNN_OPENCL_CROSS_BUILD'
