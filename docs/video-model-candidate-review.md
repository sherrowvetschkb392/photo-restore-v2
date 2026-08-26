# Video model candidate review

This is a pre-download review. No model weights are bundled or copied to the
board by this document. A candidate must pass source/license verification and
the repository's fixed-shape contracts before it can enter RKNN conversion.

## Selection rules

1. Keep temporal interpolation and spatial video super-resolution as separate
   model families. They may be composed later, but they are not interchangeable.
2. Prefer models with an inference graph that can be exported to fixed-shape
   ONNX without changing warping semantics.
3. Treat `grid_sample`, custom CUDA flow warps, deformable convolution and
   dynamic shape/control flow as explicit RKNN risk items.
4. Record the exact commit, license text, weight URL, checksum and conversion
   report before any weight is downloaded.
5. First experiments stay at the ignored local fixture sizes. No public API or
   production systemd service is changed during candidate evaluation.

## Initial shortlist

### Historical quality-first decision

The initial quality-first review selected **BasicVSR++ 4×** as the spatial
video-super-resolution primary and **RIFE-small** as the separate frame-rate
primary. Keep **RealBasicVSR** as an optional 1× real-world cleanup stage,
**RVRT** as a higher-risk quality backup, and **IFRNet** as the lighter
interpolation fallback. The later operator probes below supersede BasicVSR++ as
the RK3588 deployment candidate while retaining it as a quality reference.

The reason is product fit: the main gap includes resolution, and the official
BasicVSR++ checkpoint explicitly targets BI×4/BD×4 video super-resolution.
RealBasicVSR is retained for real-world cleanup because its official model is
1×. RIFE remains separate because temporal interpolation and spatial
restoration should be independently switchable and measurable.

| Candidate | Role | Why it is considered | Main RKNN risk | Current decision |
|---|---|---|---|---|
| IFRNet | 2× frame interpolation | Relatively compact, direct two-frame midpoint contract | Flow/warp implementation and export shape must be inspected | Lighter interpolation fallback |
| RIFE (small variant) | 2× frame interpolation | Mature frame interpolation family with small variants | Version/license and custom warp operators vary by repository | Interpolation primary |
| BasicVSR++ | Temporal video super-resolution | Strong temporal propagation and official 2×/4× enhancement checkpoints | Deformable alignment, long recurrent state, high memory | PC quality reference; RK3588 conversion blocked |
| RealBasicVSR | Real-world video super-resolution | Restoration-oriented cleanup and temporal consistency | Degradation model and recurrent alignment may not export cleanly | Deferred optional 1× cleanup |
| RVRT | Temporal video super-resolution | Windowed transformer alternative for restoration | Attention/memory cost and unsupported operators | Deferred unless lightweight candidates fail |

The table is a prioritization, not a license assertion. The license of the
exact repository commit and weight file must be rechecked at download time.

## Required candidate record

Each downloaded candidate must have a JSON record containing:

```json
{
  "name": "example",
  "family": "interpolation or video_super_resolution",
  "source_url": "https://...",
  "source_commit": "...",
  "license": "...​",
  "license_verified_at_utc": "...",
  "weights_url": "https://...",
  "weights_sha256": "...",
  "temporal_window": 2,
  "input_layout": "NCHW",
  "input_shape": [1, 3, 256, 256],
  "output_shape": [1, 3, 256, 256],
  "spatial_scale": 1,
  "operators_reviewed": [],
  "rknn_conversion": "not_started"
}
```

For video super-resolution, `input_shape` and `output_shape` refer to one
frame; the temporal window is represented by a documented tensor contract and
must not be silently flattened in a way that changes model semantics.

## Gate order

1. Verify repository license, weight license and redistribution constraints.
2. Pin the source commit and compute the weight checksum.
3. Export a fixed-shape ONNX graph without CUDA-only code paths.
4. Enumerate ONNX operators and flag warp/grid sampling explicitly.
5. Run ONNX inference on the ignored interpolation or enhancement fixtures.
6. Compare output against the relevant baseline and inspect motion edges,
   texture, faces, text and scene cuts.
7. Convert only the passing candidate to RKNN and compare ONNX/RKNN output.
8. Run one isolated board inference before considering a video pipeline.

No candidate is approved for public video upload until the production safety
milestones in `product-requirements-roadmap.md` are complete.

The first BasicVSR++ artifact cache is intentionally local and ignored by Git.
Its record contains the official URLs, byte counts and SHA-256 values for the
4× checkpoint and SPyNet dependency. The cache must pass
`tools/verify_video_model_artifacts.py` before export work begins. Weight files
are not uploaded to RK3588 until ONNX export and operator review pass.

`tools/audit_onnx_graph.py` blocks graphs containing dynamic I/O or high-risk
operators such as `GridSample`, deformable convolution and control-flow nodes.

The isolated export setup is managed by
`scripts/prepare-video-export.ps1`. Its default mode is a no-change plan;
`-Install` only changes the named WSL Conda development environment. It never
installs packages into the board venv and never uploads a model.

### BasicVSR++ export decision (2026-08-26)

The official checkpoint and SPyNet weights passed SHA-256 verification, and the
checkpoint loaded successfully with 275 tensors and 7,322,934 parameters. The
fixed 5-frame 64×64 → 256×256 contract is valid. Conversion is nevertheless
blocked for RK3588:

- MMagic BasicVSR++ depends on MMCV modulated deformable convolution;
- `mmcv-lite` has no `mmcv._ext` compiled operator;
- TorchVision's modulated `deform_conv2d` runs on CPU, but PyTorch ONNX export
  rejects it as the unrecognized custom operator
  `torchvision::deform_conv2d`;
- wrapping either implementation as a custom ONNX operator would not make it a
  supported RKNN operator and would change the deployment contract.

BasicVSR++ therefore remains a PC-side quality reference/possible distillation
teacher, not the RK3588 deployment model. The RKNN prototype moves to a compact
fixed-window temporal-fusion student built only from standard Conv, activation,
addition, reshape and PixelShuffle operations. Passing its architecture export
probe is not a quality claim; training or teacher distillation is required
before comparison with the video-enhancement fixtures.

### No-training deployment route

The current product route prioritizes existing pre-trained models because the
project does not have dedicated training hardware. The custom temporal-fusion
student and teacher distillation are deferred research, not current delivery
requirements.

The practical model chain is:

1. use the already validated RKNN Real-ESRGAN image worker for optional spatial
   enhancement, with explicit temporal-flicker quality checks;
2. evaluate the pre-trained `rife-ncnn-vulkan` model for 2× interpolation on
   the RK3588 Mali GPU instead of converting RIFE to RKNN first;
3. keep `realesrgan-ncnn-vulkan` as a GPU spatial fallback, including the
   `realesr-animevideov3` preset for animation material;
4. keep BasicVSR++ only as a PC-side reference; do not require training or
   distillation for the initial public video feature.

This route still requires a read-only Vulkan/ICD inventory, an isolated NCNN
build/runtime smoke test, model checksum/license recording, scene-cut bypass,
and real video quality/performance measurement. A Vulkan path is not assumed
merely because `/dev/mali0` exists.

### Existing-system heterogeneous route

Replacing the production operating system is deferred. The Linux 5.10 / Debian
11 deployment should use each accelerator for the work it handles best:

1. MPP performs hardware video decode and encode;
2. RGA performs supported resize, colour conversion and buffer movement;
3. RKNN/NPU remains the primary spatial-enhancement backend;
4. Mali OpenCL is considered for a pre-trained MNN/TNN interpolation backend
   only after a direct `clGetPlatformIDs`/device probe passes;
5. CAIN is the first RKNN interpolation candidate because its channel-attention
   design avoids the optical-flow `GridSample` path that blocks RIFE/IFRNet;
6. CPU workers handle scene-cut detection, scheduling, audio muxing and a
   traditional FFmpeg interpolation fallback.

The OpenCL loader file alone is not evidence of a usable GPU runtime. Run
`scripts/video-opencl-preflight.ps1`; only
`READY_FOR_OPENCL_INFERENCE_BACKEND_PROBE` permits an MNN/TNN OpenCL smoke
test. If the gate is blocked, proceed with CAIN fixed-shape ONNX/RKNN operator
inspection without changing the board runtime.
