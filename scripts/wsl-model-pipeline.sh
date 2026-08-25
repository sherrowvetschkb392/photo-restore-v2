#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <linux-root> <conda-environment> <tile-size>" >&2
    exit 2
fi

linux_root="$1"
conda_environment="$2"
tile_size="$3"

if ! [[ "${tile_size}" =~ ^[0-9]+$ ]] \
    || (( tile_size < 64 || tile_size > 128 || tile_size % 16 != 0 )); then
    echo "Tile size must be 64..128 and aligned to 16: ${tile_size}" >&2
    exit 2
fi

conda_sh="${HOME}/miniconda3/etc/profile.d/conda.sh"
if [[ ! -f "${conda_sh}" ]]; then
    echo "Conda activation script not found: ${conda_sh}" >&2
    exit 3
fi

source "${conda_sh}"
conda activate "${conda_environment}"

scripts_dir="${linux_root}/workspace/scripts"
reports_dir="${linux_root}/workspace/reports"
samples_dir="${linux_root}/workspace/samples"
weights="${linux_root}/models/source/RealESRGAN_x4plus.pth"
prefix="realesrgan_x4plus_tile${tile_size}"
onnx_model="${linux_root}/models/onnx/${prefix}.onnx"
rknn_model="${linux_root}/models/rknn/${prefix}_fp16.rknn"

required_files=(
    "${weights}"
    "${scripts_dir}/export_realesrgan_onnx.py"
    "${scripts_dir}/preflight_rknn.py"
    "${scripts_dir}/build_rknn.py"
    "${scripts_dir}/make_validation_fixture.py"
)

for required_file in "${required_files[@]}"; do
    if [[ ! -f "${required_file}" ]]; then
        echo "Required file missing: ${required_file}" >&2
        exit 4
    fi
done

mkdir -p "${linux_root}/models/onnx" "${linux_root}/models/rknn" \
    "${reports_dir}" "${samples_dir}"

# RKNN Toolkit writes intermediate check*.onnx files to the current working
# directory. Keep those compiler artifacts inside the WSL workspace.
cd "${linux_root}/workspace"

echo
echo "== WSL environment =="
python --version
python -m pip check

echo
echo "== Export ONNX: tile ${tile_size} =="
python "${scripts_dir}/export_realesrgan_onnx.py" \
    --weights "${weights}" \
    --output "${onnx_model}" \
    --tile-size "${tile_size}" \
    --report "${reports_dir}/onnx-tile${tile_size}.json"

echo
echo "== RKNN preflight: tile ${tile_size} =="
python "${scripts_dir}/preflight_rknn.py" \
    --onnx "${onnx_model}" \
    --tile-size "${tile_size}"

echo
echo "== Compile RKNN: tile ${tile_size} =="
python "${scripts_dir}/build_rknn.py" \
    --onnx "${onnx_model}" \
    --output "${rknn_model}" \
    --report "${reports_dir}/rknn-tile${tile_size}-fp16.json" \
    --log "${reports_dir}/rknn-build-tile${tile_size}.log" \
    --tile-size "${tile_size}"

echo
echo "== Create validation fixture: tile ${tile_size} =="
python "${scripts_dir}/make_validation_fixture.py" \
    --onnx "${onnx_model}" \
    --output-dir "${samples_dir}" \
    --tile-size "${tile_size}"

echo
echo "RESULT=PASS_WSL_MODEL_PIPELINE"
