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
| Disk-backed large-image compositor | Complete | RK3588 output hash matches the reference memory compositor; row-band overlap-add writes finalized RGB rows to a project-local memmap |
| Lightweight browser previews | Complete | Deployed API validation confirms input/output JPEG previews are bounded to a 1600-pixel longest edge; downloads remain full resolution |
| Large-photo public processing | Pending | Public limit remains 2,000,000 pixels until board memory/disk/time validation |
| User-facing local/public UI and API | Complete | FastAPI, SQLite queue, browser UI, systemd and Cloudflare Access |
| Persistent job history | Complete for current appliance | SQLite index, input/output/report downloads and per-job deletion |
| Automatic retention and storage quotas | Complete | Terminal jobs are retained for 7 days by default; a 4 GiB job-storage quota and 2 GiB free-space reserve evict oldest terminal jobs without deleting queued/running work |
| Production health monitoring | Complete | API 0.5.0 reports worker/cleanup threads, job counts and stalls, upload readiness and storage; a read-only PowerShell audit checks systemd, Cloudflare, NPU, temperature and disk |

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

1. Keep the public input limit at 2,000,000 pixels. The 1.92 MP tier passed at
   137.156 seconds NPU time, 158.146 seconds total and 622344 KiB peak RSS.
2. Treat inputs above 2 MP as unsafe with the current RKNN Runtime 2.3.2 and
   driver 0.9.2. The isolated 3 MP test stalled at tile 211/475 with NPU Core0
   fixed at 100%; SIGTERM/SIGKILL could not recover it and the board had to be
   rebooted. It was not an OOM, storage or thermal failure.
3. Revisit larger inputs only after a runtime/driver upgrade or a worker design
   that releases and reinitializes RKNN between bounded tile batches.
4. Observe the deployed 7-day retention, 4 GiB quota and 2 GiB free-space
   reserve under normal public use, then tune only from measured storage data.

The current project is a working authenticated public appliance with a measured
2 MP safety limit and automatic storage retention. Larger-photo stability and
runtime/driver resilience is the remaining production gap.
