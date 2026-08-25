# Requirements status

## Original project goal

Build an offline photo-restoration workstation for the RK3588 board. The
workstation should accept ordinary user photos, run Real-ESRGAN x4plus on the
board NPU, and return a verified restored image without requiring cloud access.

## Status

| Requirement | Status | Evidence |
|---|---|---|
| RK3588 runtime and NPU access | Complete | Runtime audit and board inference reports |
| Reproducible PTH → ONNX → RKNN build | Complete | `tools/model/`, WSL reports, checksums |
| Fixed model selection | Complete | tile96 FP16, overlap 8, scale 4 |
| Numerical ONNX/RKNN validation | Complete | max error below 0.01, mean error below 0.001 |
| Tiled image worker | Complete for prototype limit | `apps/worker/restore_image.py` |
| Seam-safe reconstruction tests | Complete | `tests/test_tiling.py` |
| Batch validation and resume after SSH loss | Complete | `scripts/restore-validation-set.ps1` |
| Real photo single-image command | Implemented | `scripts/restore-photo.ps1` |
| High-resolution visual comparison | Implemented | validation comparison viewer |
| Large-photo production processing | Pending | Current worker limit is 2,000,000 input pixels |
| User-facing local UI/API | Pending | `apps/` has no service or UI yet |
| Persistent photo library and job history | Pending | No database/index yet |

## Current image contract

Input is a local PNG or JPEG. The Windows command validates the file, computes
its SHA-256, uploads it to an isolated board job directory, and starts one
detached restoration job. The board worker:

1. applies EXIF orientation and converts the image to RGB;
2. rejects images over the current 2,000,000-pixel prototype limit;
3. pads and splits the image into 96×96 tiles with 8-pixel overlap;
4. runs each tile through the FP16 RKNN model;
5. blends overlapping output tiles and crops padding;
6. writes a PNG or JPEG atomically;
7. writes a JSON report containing input/output/model hashes and timing.

The default local command is:

```powershell
.\scripts\restore-photo.ps1 -InputImage "C:\path\to\photo.jpg"
```

If no output is supplied, the result is written to
`benchmarks/restored/<input-stem>-x4.png`. The input is never modified. The
board-side temporary job is removed after verified download unless
`-KeepRemoteArtifacts` is supplied.

## Next implementation order

1. Keep the verified single-image path as the reference behavior.
2. Replace the in-memory compositor with stripe/disk-backed processing so
   larger originals can be accepted safely.
3. Add a local batch command for a user-selected folder, with per-file reports
   and resume behavior.
4. Add a small offline UI or local HTTP API only after the CLI contract is
   stable.
5. Add retention rules and a searchable job/output index if the workstation
   will be used as a long-running appliance.

The current project is therefore at the validated engine/prototype stage, not
yet at the final appliance/UI stage.
