# Development workflow

## Three environments

```text
Windows Git workspace
  source code, scripts, documentation, commits
          |
          | copy versioned conversion tools
          v
WSL2 x86_64 conversion workspace
  PTH -> fixed-shape ONNX -> RK3588 RKNN
  creates deterministic ONNX reference tensors
          |
          | checksum-aware SSH/SCP deployment
          v
RK3588 board workspace
  RKNNLite2 loads .rknn and runs NPU inference
  compares NPU output with the ONNX reference
```

The Windows Git repository contains reproducible source code, not large model
artifacts. WSL is the model compiler. RK3588 is the actual runtime target.

## One-command model validation

From PowerShell in the repository:

```powershell
.\scripts\build-and-validate-model.ps1 -TileSize 96 -Runs 5
```

To choose a final tile size with repeatable measurements:

```powershell
.\scripts\benchmark-tile-matrix.ps1
```

The matrix tests 64, 80, 96, 112 and 128. These sizes are aligned to 16 for
the NPU. It ranks both raw input throughput and effective throughput assuming
an 8-pixel overlap on every side. Results are written to ignored CSV and JSON
files under `benchmarks/`.

## Final tile decision

The five-size RK3588 matrix selected **tile 96** with an initial overlap of
**8 input pixels per side** (16 pixels total per axis). Measured results:

| Tile | Time/tile | Raw px/s | Effective edge | Effective px/s | Peak RSS |
|---:|---:|---:|---:|---:|---:|
| 96 | 0.413318 s | 22,298 | 80 | 15,484 | 236.8 MiB |
| 128 | 0.908222 s | 18,040 | 112 | 13,812 | 334.4 MiB |
| 80 | 0.324555 s | 19,719 | 64 | 12,620 | 196.4 MiB |
| 112 | 0.737918 s | 16,999 | 96 | 12,489 | 287.5 MiB |
| 64 | 0.232564 s | 17,612 | 48 | 9,907 | 167.3 MiB |

Tile 96 has the highest raw and overlap-adjusted throughput. Its effective
throughput is about 12.1% above tile 128 and 22.7% above tile 80, while memory,
temperature and numerical error remain safe. The model tile size is now fixed
at 96 for the first application version. Real-image seam tests may change the
overlap, but not the compiled model tile size.

## Image prototype safety limit

The first real-image worker uses in-memory float32 overlap-add blending. It is
limited to 2,000,000 input pixels to keep memory use safe on the 4 GB board.
This phase validates color, padding, tile alignment and seams. Production-size
photos require a later stripe/disk-backed compositor before the limit is
raised.

The command performs these stages and stops immediately on a failed stage:

1. synchronize versioned Python tools into WSL;
2. export official `params_ema` weights to fixed-shape ONNX;
3. validate packages, native libraries, ONNX API compatibility and shapes;
4. compile a non-quantized RK3588 FP16 RKNN model;
5. create deterministic input and ONNX reference output;
6. compare local and remote SHA-256 values;
7. upload to a temporary board path with retries when needed;
8. atomically activate only a verified model;
9. run repeated NPU inference and enforce numerical-error limits;
10. download the board JSON report into `benchmarks/`.

## Artifact policy

| Artifact | Location | Git |
|---|---|---|
| Source and scripts | Windows repository | tracked |
| PTH/ONNX/RKNN | WSL and board model directories | ignored |
| Photos and outputs | RK3588 `/userdata` | never tracked |
| Board benchmark JSON | Windows `benchmarks/` | ignored |

## Current measurements

| Tile | Steady time | Input pixels/s | Peak RSS | Mean error | Max error |
|---:|---:|---:|---:|---:|---:|
| 64 | 0.2437 s | about 16,810 | 169,748 KiB | 0.0001555 | 0.0011561 |
| 96 | 0.4119 s | about 22,373 | 239,016 KiB | 0.0001514 | 0.0010464 |
| 128 | 0.9325 s | about 17,569 | 336,504 KiB | 0.0001536 | 0.0019253 |

Tile 96 currently provides about 33% more input-pixel throughput than tile 64,
while its memory use remains comfortable on the 4 GB board. Tile 128 reduces
the number of tile boundaries, but its per-pixel throughput is about 21% lower
than tile 96 and its peak RSS is about 41% higher. Tile 96 is therefore the
current default. A larger tile must win an end-to-end real-image benchmark,
including overlap and stitching, before replacing it.

For a 4000×3000 input without overlap, the measured NPU-only estimate is about
9.2 minutes for tile 96 and 11.9 minutes for tile 128. Real processing will be
slower because it also includes overlap, padding, image conversion and output
encoding.
