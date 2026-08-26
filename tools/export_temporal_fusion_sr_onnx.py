#!/usr/bin/env python3
"""Export an RKNN-oriented fixed-shape temporal fusion SR student prototype.

This is an architecture/export probe, not a trained quality model.  It uses
only standard convolutions, residual additions and PixelShuffle so the graph
can be audited before any expensive training or teacher distillation begins.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import torch
from torch import Tensor, nn


class ResidualBlock(nn.Module):
    def __init__(self, channels: int) -> None:
        super().__init__()
        self.body = nn.Sequential(
            nn.Conv2d(channels, channels, 3, 1, 1),
            nn.ReLU(inplace=False),
            nn.Conv2d(channels, channels, 3, 1, 1),
        )

    def forward(self, value: Tensor) -> Tensor:
        return value + self.body(value)


class TemporalFusionSrStudent(nn.Module):
    def __init__(self, frames: int = 5, channels: int = 32, blocks: int = 4, scale: int = 4) -> None:
        super().__init__()
        if frames < 3 or frames % 2 == 0:
            raise ValueError("frames must be an odd number >= 3")
        self.frames = frames
        self.scale = scale
        self.head = nn.Conv2d(frames * 3, channels, 3, 1, 1)
        self.body = nn.Sequential(*(ResidualBlock(channels) for _ in range(blocks)))
        self.fusion = nn.Conv2d(channels, channels, 3, 1, 1)
        self.upscale = nn.Sequential(
            nn.Conv2d(channels, 3 * scale * scale, 3, 1, 1),
            nn.PixelShuffle(scale),
        )

    def forward(self, frames: Tensor) -> Tensor:
        batch, temporal, channels, height, width = frames.shape
        flattened = frames.reshape(batch, temporal * channels, height, width)
        features = torch.relu(self.head(flattened))
        features = features + self.fusion(self.body(features))
        return self.upscale(features)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def initialize(model: nn.Module, seed: int) -> None:
    torch.manual_seed(seed)
    for module in model.modules():
        if isinstance(module, nn.Conv2d):
            nn.init.kaiming_uniform_(module.weight, a=0.2)
            if module.bias is not None:
                nn.init.zeros_(module.bias)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--frames", type=int, default=5)
    parser.add_argument("--width", type=int, default=64)
    parser.add_argument("--height", type=int, default=64)
    parser.add_argument("--channels", type=int, default=32)
    parser.add_argument("--blocks", type=int, default=4)
    parser.add_argument("--scale", type=int, default=4, choices=(2, 4))
    parser.add_argument("--seed", type=int, default=20260826)
    args = parser.parse_args()
    if args.width <= 0 or args.height <= 0 or args.width % 16 or args.height % 16:
        raise SystemExit("width and height must be positive and divisible by 16")

    model = TemporalFusionSrStudent(args.frames, args.channels, args.blocks, args.scale).eval()
    initialize(model, args.seed)
    generator = torch.Generator().manual_seed(args.seed + 1)
    sample = torch.rand(1, args.frames, 3, args.height, args.width, generator=generator)
    with torch.inference_mode():
        torch_output = model(sample).numpy()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.onnx.export(
        model,
        sample,
        args.output,
        input_names=["frames"],
        output_names=["enhanced_center"],
        opset_version=12,
        do_constant_folding=True,
        dynamic_axes=None,
    )
    onnx_model = onnx.load(args.output)
    onnx.checker.check_model(onnx_model)
    session = ort.InferenceSession(str(args.output), providers=["CPUExecutionProvider"])
    ort_output = session.run(None, {"frames": sample.numpy()})[0]
    difference = np.abs(torch_output - ort_output)
    op_types = sorted({node.op_type for node in onnx_model.graph.node})
    parameter_count = sum(parameter.numel() for parameter in model.parameters())
    report = {
        "schema_version": 1,
        "model": "TemporalFusionSrStudent",
        "status": "architecture_probe_untrained",
        "quality_claim": False,
        "board_upload": False,
        "contract": {
            "input_shape": list(sample.shape),
            "output_shape": list(torch_output.shape),
            "dtype": "float32",
            "range": "training_contract_pending; probe input is [0,1]",
            "scale": args.scale,
            "center_frame_index": args.frames // 2,
        },
        "architecture": {
            "channels": args.channels,
            "residual_blocks": args.blocks,
            "parameter_count": parameter_count,
            "uses_optical_flow": False,
            "uses_deformable_convolution": False,
            "uses_custom_operator": False,
        },
        "onnx": {
            "path": str(args.output.resolve()),
            "bytes": args.output.stat().st_size,
            "sha256": sha256(args.output),
            "opset": 12,
            "op_types": op_types,
        },
        "numerical_validation": {
            "max_abs_error": float(difference.max()),
            "mean_abs_error": float(difference.mean()),
            "passed": bool(difference.max() <= 1e-4 and difference.mean() <= 1e-5),
        },
        "next_gate": "training_or_teacher_distillation_required_before_quality_evaluation",
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, allow_nan=False), encoding="utf-8")
    print(json.dumps(report, indent=2, allow_nan=False))
    if not report["numerical_validation"]["passed"]:
        print("RESULT=FAIL_TEMPORAL_FUSION_SR_ONNX_NUMERICAL_CHECK")
        return 2
    print("RESULT=PASS_TEMPORAL_FUSION_SR_ONNX_EXPORT")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
