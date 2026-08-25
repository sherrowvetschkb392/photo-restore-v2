#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <wsl|board> <exact-root>" >&2
    exit 2
fi

mode="$1"
root="$2"

case "${mode}" in
    wsl)
        expected_root='/home/ljd/photo-restore-rknn232'
        ;;
    board)
        expected_root='/userdata/photo-restore-v2'
        ;;
    *)
        echo "Unsupported cleanup mode: ${mode}" >&2
        exit 2
        ;;
esac

if [[ "${root}" != "${expected_root}" ]]; then
    echo "Refusing cleanup: expected ${expected_root}, got ${root}" >&2
    exit 3
fi
if [[ ! -d "${root}" ]]; then
    echo "Cleanup root does not exist: ${root}" >&2
    exit 3
fi
if [[ "$(realpath -- "${root}")" != "${expected_root}" ]]; then
    echo "Resolved cleanup root is not the expected path" >&2
    exit 3
fi

if [[ "${mode}" == 'wsl' ]]; then
    required=(
        "${root}/models/source/RealESRGAN_x4plus.pth"
        "${root}/models/onnx/realesrgan_x4plus_tile96.onnx"
        "${root}/models/rknn/realesrgan_x4plus_tile96_fp16.rknn"
        "${root}/workspace/samples/tile96-input.npy"
        "${root}/workspace/samples/tile96-onnx-output.npy"
    )
    for path in "${required[@]}"; do
        [[ -f "${path}" ]] || { echo "Required file missing: ${path}" >&2; exit 4; }
    done

    rm -f -- \
        "${root}/models/onnx/realesrgan_x4plus_tile64.onnx" \
        "${root}/models/onnx/realesrgan_x4plus_tile80.onnx" \
        "${root}/models/onnx/realesrgan_x4plus_tile112.onnx" \
        "${root}/models/onnx/realesrgan_x4plus_tile128.onnx" \
        "${root}/models/rknn/realesrgan_x4plus_tile64_fp16.rknn" \
        "${root}/models/rknn/realesrgan_x4plus_tile80_fp16.rknn" \
        "${root}/models/rknn/realesrgan_x4plus_tile112_fp16.rknn" \
        "${root}/models/rknn/realesrgan_x4plus_tile128_fp16.rknn" \
        "${root}/workspace/check0_base_optimize.onnx" \
        "${root}/workspace/check3_fuse_ops.onnx"

    for tile in 64 80 112 128; do
        rm -f -- \
            "${root}/workspace/samples/tile${tile}-input.npy" \
            "${root}/workspace/samples/tile${tile}-onnx-output.npy" \
            "${root}/workspace/samples/tile${tile}-fixture.json"
    done

    [[ -f "${root}/models/onnx/realesrgan_x4plus_tile96.onnx" ]]
    [[ -f "${root}/models/rknn/realesrgan_x4plus_tile96_fp16.rknn" ]]
    echo 'WSL_CLEANUP_OK'
else
    required=(
        "${root}/models/realesrgan_x4plus_tile96_fp16.rknn"
        "${root}/venv/bin/python"
    )
    for path in "${required[@]}"; do
        [[ -e "${path}" ]] || { echo "Required file missing: ${path}" >&2; exit 4; }
    done

    rm -f -- \
        "${root}/models/realesrgan_x4plus_tile64_fp16.rknn" \
        "${root}/models/realesrgan_x4plus_tile80_fp16.rknn" \
        "${root}/models/realesrgan_x4plus_tile112_fp16.rknn" \
        "${root}/models/realesrgan_x4plus_tile128_fp16.rknn" \
        "${root}/models/realesrgan_x4plus_tile64_fp16.rknn.uploading" \
        "${root}/models/realesrgan_x4plus_tile80_fp16.rknn.uploading" \
        "${root}/models/realesrgan_x4plus_tile112_fp16.rknn.uploading" \
        "${root}/models/realesrgan_x4plus_tile128_fp16.rknn.uploading"

    for tile in 64 80 112 128; do
        rm -f -- \
            "${root}/data/validation/tile${tile}-input.npy" \
            "${root}/data/validation/tile${tile}-onnx-output.npy" \
            "${root}/data/validation/tile${tile}-fixture.json"
    done

    [[ -f "${root}/models/realesrgan_x4plus_tile96_fp16.rknn" ]]
    echo 'RK3588_CLEANUP_OK'
fi

