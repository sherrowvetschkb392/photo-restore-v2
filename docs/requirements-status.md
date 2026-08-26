# Requirements status

This is the compact implementation snapshot. The canonical product scope,
requirement IDs, video-interpolation plan, release gates and implementation
order are defined in `product-requirements-roadmap.md`.

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
| Large-photo public processing | Complete at measured 2 MP limit | 1.92 MP passed; 3 MP stalled the NPU driver and remains explicitly unsupported |
| User-facing local/public UI and API | Complete | FastAPI, SQLite queue, browser UI, systemd and Cloudflare Access |
| Persistent job history | Complete for current appliance | SQLite index, input/output/report downloads and per-job deletion |
| Automatic retention and storage quotas | Complete | Terminal jobs are retained for 7 days by default; a 4 GiB job-storage quota and 2 GiB free-space reserve evict oldest terminal jobs without deleting queued/running work |
| Production health monitoring | Complete | API 0.5.0 reports worker/cleanup threads, job counts and stalls, upload readiness and storage; a read-only PowerShell audit checks systemd, Cloudflare, NPU, temperature and disk |
| Per-user ownership, quotas and rate limits | Pending (P0) | Cloudflare Access protects the edge, but the application does not yet isolate job history by identity |
| Database migration, backup and deployment rollback | Pending (P0) | Required before adding video jobs or broader public use |
| Job progress and cancellation | Pending (P0) | Current image queue exposes state but not worker heartbeat/progress or cancellation |
| Full photo restoration modes | Pending | Current production model provides general 4x enhancement; face, scratch, denoise/deblur and colorization remain separate research items |
| Video frame interpolation | Offline CLI implemented | CAIN (MIT) fixed-shape RKNN models; board-verified 2x interpolation worker with scene-cut/static policy and audio preservation; see `docs/video-development.md`. Public API exposure waits for P0 identity/quota work |

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

## Immediate implementation order

1. Keep the public image limit at 2,000,000 pixels and do not repeat the 3 MP
   driver-risk test without an explicit diagnostic reason.
2. Add schema migrations, verified backup/restore and atomic deployment rollback.
3. Add trusted user identity, task ownership, per-user limits, rate limiting,
   worker heartbeat and cancellation before introducing public video jobs.
4. Run an isolated, read-only RK3588 video codec preflight, then evaluate fixed-
   shape lightweight frame-interpolation models outside the public API.
5. Expand actual photo-restoration modes and integrate video only through the
   gates in `product-requirements-roadmap.md`.

The current project is a working Access-protected public image appliance with a
measured 2 MP safety limit, automatic storage retention and health monitoring.
Application-level identity isolation, recovery/rollback, cancellation, full
photo-restoration modes and video interpolation remain on the roadmap.
