# Model pipeline

## Environments

| Purpose | Location |
|---|---|
| Versioned source code | `C:\Users\LJD\rk\photo-restore-v2` |
| x86_64 RKNN conversion | `/home/ljd/photo-restore-rknn232` in WSL2 |
| RK3588 inference runtime | `/userdata/photo-restore-v2` |

Large model artifacts are not committed to Git.

RKNN Toolkit2 2.3.2 must use ONNX 1.16.1. Although its wheel metadata allows
newer ONNX releases, the compiler imports the legacy `onnx.mapping` API, which
is not present in ONNX 1.22. Critical compatibility versions are recorded in
`tools/model/constraints-rknn232.txt` and enforced by the preflight script.

## Initial model

- Model: official `RealESRGAN_x4plus`
- Architecture: RRDBNet, 23 RRDB blocks, 64 features, 32 growth channels
- Scale: 4x
- Initial fixed input: NCHW float32 `1×3×64×64`
- Fixed output: NCHW float32 `1×3×256×256`
- ONNX opset: 12
- Initial RKNN build: FP16, without quantization

The 64-pixel tile is a compatibility probe, not the final performance choice.
After end-to-end inference succeeds, compare 64, 96 and 128-pixel fixed tiles.

The first RKNN build uses `target_platform=rk3588`, optimization level 3 and
`do_quantization=False`. Image normalization is intentionally outside the
model; the board pipeline supplies NCHW float32 RGB values in the same range
used by the ONNX model.

The compiled model retains NCHW as its framework layout, while the RKNN board
input ABI requests NHWC. The worker transposes each prepared tile to contiguous
NHWC before calling RKNNLite. Model output remains NCHW. Validation fails if
the RKNN/ONNX maximum absolute error exceeds `0.01` or mean absolute error
exceeds `0.001`.

## Initial RK3588 result

- Model: tile64, non-quantized FP16, all three NPU cores
- First inference: 0.371 s
- Steady mean: 0.241 s/tile
- Peak RSS: 169876 KiB
- RKNN vs ONNX max absolute error: 0.0011561
- RKNN vs ONNX mean absolute error: 0.0001555
- Five-run NPU temperature increase: less than 1 °C

Later comparison selected tile 96 as the default: tile 128 passed numerical
validation but delivered lower per-pixel throughput (about 17,569 input
pixels/s versus about 22,344 for tile 96) and used more memory.

The final aligned matrix (64/80/96/112/128, seven runs each) confirmed tile 96.
With an assumed 8-pixel overlap per side, it achieved 15,484 effective input
pixels/s, the best result in the matrix. The first application version fixes
the RKNN input tile at 96×96 and starts with an 8-pixel input overlap per side.

## Source weight

```text
RealESRGAN_x4plus.pth
SHA-256: 4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1
checkpoint key: params_ema
tensor count: 702
```
