# Video interpolation development

## Goal

The first video feature is offline 2x frame interpolation, not per-frame
Real-ESRGAN and not a claim of DLSS-equivalent real-time frame generation.
Initial candidates must operate on adjacent decoded frames and generate one
middle frame while preserving the input resolution.

Product scope, security gates and the complete roadmap remain defined in
`product-requirements-roadmap.md`. This document records the technical video
pipeline decisions and measured board evidence.

## RK3588 preflight result

The read-only board preflight was run on 2026-08-26. It did not install or
change anything.

| Capability | Result |
|---|---|
| Platform | RK3588, aarch64, Debian 11, kernel 5.10.160 |
| Rockchip MPP device | Present, readable and writable |
| RGA device | Present, readable and writable |
| DRM render nodes | Present |
| GStreamer | 1.18.5 |
| GStreamer MPP decoder | `mppvideodec` available |
| GStreamer H.264 encoder | `mpph264enc` available |
| GStreamer H.265 encoder | `mpph265enc` available |
| Rockchip MPP packages | 1.5.0-1 installed |
| Rockchip GStreamer package | 1.14-4 installed |
| FFmpeg / ffprobe | Missing; current blocker |
| OpenCV in project venv | Missing; intentionally not required yet |
| Available memory | about 3.22 GiB |
| Available project filesystem | about 13.59 GiB |
| Maximum measured temperature | 33.3 °C |
| Existing API / Tunnel | Active |
| Active media workers | 0 |

The result demonstrates that the board already has a vendor hardware video
path. It does not yet prove that a complete MP4 decode/interpolate/encode job
works. That requires a generated codec smoke test after FFmpeg/ffprobe are
available.

## Tool responsibilities

The first prototype deliberately separates responsibilities:

- GStreamer Rockchip plugins provide the primary MPP hardware decode/encode
  path;
- FFmpeg generates deterministic test sources and provides container/audio
  utilities where useful;
- ffprobe validates input and output streams, codecs, frame rate, frame count,
  duration, pixel format and audio synchronization;
- RGA is evaluated for resize/color conversion only after an actual pipeline
  confirms its negotiated formats;
- RKNNLite2 runs only the interpolation model;
- OpenCV is not installed as a prerequisite. Add it only if a measured need
  cannot be met by FFmpeg, GStreamer, Pillow or NumPy.

Plain Debian FFmpeg is not assumed to expose Rockchip MPP codecs. Its absence of
`rkmpp` encoders/decoders would not invalidate the existing GStreamer MPP path.
Reports must identify which component actually performed decode and encode.

## Safe FFmpeg installation workflow

The installer is two-stage and idempotent. First run a package simulation:

```powershell
.\scripts\install-video-tools.ps1
```

The simulation:

- records installed Rockchip GStreamer/MPP package versions;
- runs `apt-get -s --no-remove install ffmpeg`;
- refuses a plan that removes any package;
- refuses a plan that installs/upgrades a protected Rockchip package;
- writes the ignored plan report to
  `benchmarks\video-preflight\ffmpeg-install-plan.json`;
- performs no package changes.

Only after reviewing a safe simulation, install with:

```powershell
.\scripts\install-video-tools.ps1 -Install
```

The install path uses `--no-remove`, verifies `ffmpeg` and `ffprobe`, confirms
that the protected Rockchip package versions did not change, then reruns the
read-only video preflight. Repeating the command after installation skips the
package transaction and only verifies the existing tools.

The script intentionally does not run `apt update`. Updating all repository
metadata is a separate board-administration decision and must not be hidden
inside this project installer.

## Hardware codec smoke test

FFmpeg/ffprobe 4.3.9 were installed successfully. The protected package versions
remained unchanged and the repeated preflight reported
`READY_FOR_CODEC_SMOKE_TEST` with no blockers or warnings.

The isolated codec smoke test is now implemented:

```powershell
.\scripts\test-video-codec.ps1
```

It performs the following exact stages:

1. generate a deterministic 640x360, 30 fps, 10-second clip and a simple audio
   track inside a project-local development directory;
2. encode exactly 300 generated frames through `mpph264enc`;
3. decode the resulting H.264 stream through `mppvideodec` into a sink;
4. copy the verified hardware-produced H.264 stream into MP4 and add a
   deterministic 48 kHz AAC audio fixture;
5. verify the output can be decoded and has the expected width, height, frame
   rate, duration, frame count and audio stream;
6. record elapsed time, peak memory, temperature and the exact pipeline;
7. download the report and playable sample with SHA-256 verification;
8. preserve an incomplete run for diagnosis and require explicit `-Restart`;
9. remove only the exact isolated generated directory when requested with
   `-Cleanup`;
10. leave the photo API and Cloudflare services unchanged.

The board directory is fixed to:

```text
/userdata/photo-restore-v2/data/video-development/codec-smoke-640x360
```

The local ignored results are written to:

```text
benchmarks/video-codec-smoke/report.json
benchmarks/video-codec-smoke/mpp-codec-smoke-640x360.mp4
```

The test never silently falls back to software H.264. A successful report must
name `mpph264enc` and `mppvideodec`, and ffprobe must observe H.264 video, AAC
audio, 640x360, approximately 30 fps, 300 decoded frames and approximately ten
seconds duration.

### Measured RK3588 result

The first real board run passed on 2026-08-26:

| Measurement | Result |
|---|---:|
| Hardware encode | 0.656 s for 300 frames |
| Hardware decode | 0.211 s for 300 frames |
| AAC/MP4 mux | 0.511 s |
| Complete test | 1.884 s |
| Output | H.264 + AAC, 640x360, 30 fps, 300 frames, 10.0 s |
| Output size | 1,121,878 bytes |
| Peak child-process RSS | 64,468 KiB |
| Maximum temperature before/after | 35.2 / 35.2 °C |

The downloaded MP4 SHA-256 matched the board report. The photo API and
Cloudflare Tunnel remained active. This establishes a working MPP hardware
codec baseline but is not an interpolation-performance measurement.

This test still does not use an interpolation model. Model download and RKNN
conversion begin only after the hardware codec path is verified end to end.

## Model-independent interpolation contract

The codec baseline is complete, but model selection must not be based on a
single attractive demo. The repository now provides deterministic adjacent-
frame fixtures and a common evaluator before any RIFE/IFRNet-class model is
downloaded.

Generate or regenerate the ignored fixtures:

```powershell
.\scripts\prepare-interpolation-fixtures.ps1
```

The fixed initial tensor contract is:

| Property | Value |
|---|---|
| Input pair | `frame0`, `frame1` |
| Time position | 0.5 |
| Layout | NCHW |
| Dtype | float32 |
| Range | `[0, 1]` RGB |
| Initial shape | `1×3×256×256` per frame |
| Candidate output | one midpoint frame, NCHW or NHWC accepted by evaluator |
| Output shape | `1×3×256×256` |

Four fixture cases are generated under the ignored
`data/video-development/interpolation-fixtures/` tree:

- `linear-motion`: independently moving opaque shapes;
- `occlusion-reveal`: a striped object passes behind a foreground occluder;
- `thin-texture`: moving narrow lines and small detail;
- `scene-cut`: an abrupt cut that must skip the interpolation model and copy the
  selected neighboring frame according to the pipeline policy.

Every case includes PNG previews, NCHW `.npy` tensors, an exact synthetic
midpoint where applicable, file sizes and SHA-256 values. The generator is
deterministic for all media/tensor artifacts; only the manifest generation time
changes.

Evaluate a candidate model output with:

```powershell
python tools/evaluate_interpolation_output.py `
  --case-dir data/video-development/interpolation-fixtures/linear-motion `
  --candidate path/to/candidate-output.npy `
  --report benchmarks/video-interpolation-contract/candidate.json `
  --require-beats-baseline
```

The evaluator rejects integer output, wrong shapes, NaN/infinity and values
outside the normalized range. It reports MAE, RMSE, PSNR and maximum absolute
error, then compares the result with copying frame 0, copying frame 1 and the
simple average of both frames.

A candidate may continue to RKNN conversion only when:

1. its license and model source are recorded;
2. ONNX output follows the fixed tensor contract;
3. it beats the best simple baseline on every interpolation fixture, not only
   on aggregate;
4. visual inspection does not show unacceptable double edges, tearing or
   disappearing thin details;
5. scene-cut policy bypasses the model;
6. RKNN output remains close to its own ONNX output and still beats the simple
   baselines;
7. the fixed-shape model can be released and reinitialized without destabilizing
   the existing image service.

The synthetic contract is a compatibility and regression gate, not a claim of
real-world quality. Licensed real video fixtures for faces, camera motion,
occlusion, animation and text remain required before product integration.

## Spatial video enhancement contract

Frame interpolation changes time sampling; it does not increase spatial detail.
The product therefore treats video enhancement as a separate temporal model
chain. A candidate video-SR model receives a short low-resolution RGB frame
window and returns the same frames at 2× or 4× resolution. The initial contract
uses float32 NCHW tensors in `[0,1]`, five frames, and fixed 64×64 input /
128×128 output for the 2× gate. A 4× gate is the same contract with 256×256
output.

Generate the ignored synthetic fixtures with:

```powershell
.\scripts\prepare-video-enhancement-fixtures.ps1
```

The fixtures contain moving fine texture and a scene cut. The evaluator must
reject wrong layout, dtype, range or shape; compare against nearest-neighbor
upscale; and report both spatial MAE/PSNR and temporal-difference error. A
candidate advances only when it improves spatial error over nearest-neighbor
without materially increasing temporal inconsistency, passes scene-cut state
reset, and remains numerically close after ONNX→RKNN conversion. This is a
quality gate for temporal video super-resolution, not permission to run the
existing image Real-ESRGAN independently on every frame.

The next model review must record license, source, temporal window, supported
operators (especially warp/grid sampling), fixed-shape export, memory use and
measured 2×/4× quality before any weight is downloaded to the board.

## WSL video-export environment: incident review and permanent rules

The isolated `photo-restore-videoexport` environment passed its complete
bootstrap on 2026-08-26 with the following verified core versions:

| Package | Verified version |
|---|---|
| PyTorch | 2.4.0+cu121 |
| TorchVision | 0.19.0+cu121 |
| NumPy | 1.26.4 |
| ONNX | 1.16.1 |
| ONNX Runtime | 1.18.1 |
| MMCV Lite | 2.1.0 |
| MMEngine | 0.10.7 |
| MMagic | 1.2.0 |

The repeated setup failures were caused by an incorrect dependency strategy,
not by RK3588 or the downloaded model weights. Too many packages were first
installed with `--no-deps`. That omitted both native Torch runtime wheels and
ordinary Python transitive dependencies. The missing modules then appeared one
at a time (`tomli`, `platformdirs`, `mmcv`, and `lazy_loader`). Repeatedly adding
the module named by the latest traceback treated symptoms instead of resolving
the dependency graph.

The final repair uses these rules:

1. isolate experimental video packages in `photo-restore-videoexport`; never
   repair them inside the working RKNN 2.3.2 export environment or board venv;
2. pin only ABI- and compatibility-sensitive packages such as Torch, NumPy,
   ONNX, ONNX Runtime, MMCV, MMEngine and MMagic;
3. let pip resolve normal dependencies for Torch, MMCV/MMEngine, SciPy,
   scikit-image, Matplotlib and ONNX Runtime;
4. use `--no-deps` only for MMagic because its broad application dependency set
   is intentionally outside this fixed BasicVSR++ export path;
5. after installation, import the complete required module set and assert all
   core versions in one final gate;
6. make reruns idempotent: detect the actual Conda environment executable and
   avoid force-reinstalling already correct packages;
7. distinguish a Python packaging failure from a model-operator failure.
   `mmcv-lite` makes the configuration/model package importable, but it does not
   prove that BasicVSR++ deformable alignment can export to ONNX or RKNN.

For future environment failures, the required order is:

1. preserve the complete traceback;
2. inspect the failing distribution's declared dependency graph and run a
   complete import probe for the intended execution path;
3. classify missing items as a normal transitive dependency, an optional
   application dependency, or a compiled/custom operator;
4. update the full dependency group and final validation gate once;
5. rerun the idempotent installer and require
   `RESULT=PASS_VIDEO_EXPORT_ENV_READY` before model work continues.

Do not upload anything to RK3588 merely because this WSL environment passes.
The next independent gates are BasicVSR++ model construction, checkpoint
loading, fixed-shape ONNX export, operator audit and ONNX numerical validation.
