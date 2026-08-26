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

### Current provisional decision

For the first quality-oriented prototype, use **BasicVSR++ 4×** as the spatial
video-super-resolution primary and **RIFE-small** as the separate frame-rate
primary. Keep **RealBasicVSR** as an optional 1× real-world cleanup stage,
**RVRT** as a higher-risk quality backup, and **IFRNet** as the lighter
interpolation fallback. This is a product-quality prioritization, not a claim
that BasicVSR++ is already RKNN-compatible.

The reason is product fit: the main gap includes resolution, and the official
BasicVSR++ checkpoint explicitly targets BI×4/BD×4 video super-resolution.
RealBasicVSR is retained for real-world cleanup because its official model is
1×. RIFE remains separate because temporal interpolation and spatial
restoration should be independently switchable and measurable.

| Candidate | Role | Why it is considered | Main RKNN risk | Current decision |
|---|---|---|---|---|
| IFRNet | 2× frame interpolation | Relatively compact, direct two-frame midpoint contract | Flow/warp implementation and export shape must be inspected | Lighter interpolation fallback |
| RIFE (small variant) | 2× frame interpolation | Mature frame interpolation family with small variants | Version/license and custom warp operators vary by repository | Interpolation primary |
| BasicVSR++ | Temporal video super-resolution | Strong temporal propagation and 2×/4× spatial enhancement | Deformable alignment, long recurrent state, high memory | Quality backup; only if primary fails or board budget allows |
| RealBasicVSR | Real-world video super-resolution | Restoration-oriented spatial quality and temporal consistency | Degradation model and recurrent alignment may not export cleanly | Spatial quality primary |
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
