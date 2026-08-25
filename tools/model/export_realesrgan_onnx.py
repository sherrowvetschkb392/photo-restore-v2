#!/usr/bin/env python3
"""Export the official RealESRGAN_x4plus RRDBNet weights to fixed-shape ONNX.

The model intentionally excludes image tiling, padding, color conversion and
file I/O. Those operations belong to the board-side inference pipeline.
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
from torch.nn import functional as F


class ResidualDenseBlock(nn.Module):
    def __init__(self, channels: int = 64, growth_channels: int = 32) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(channels, growth_channels, 3, 1, 1)
        self.conv2 = nn.Conv2d(channels + growth_channels, growth_channels, 3, 1, 1)
        self.conv3 = nn.Conv2d(channels + 2 * growth_channels, growth_channels, 3, 1, 1)
        self.conv4 = nn.Conv2d(channels + 3 * growth_channels, growth_channels, 3, 1, 1)
        self.conv5 = nn.Conv2d(channels + 4 * growth_channels, channels, 3, 1, 1)
        self.activation = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x: Tensor) -> Tensor:
        x1 = self.activation(self.conv1(x))
        x2 = self.activation(self.conv2(torch.cat((x, x1), dim=1)))
        x3 = self.activation(self.conv3(torch.cat((x, x1, x2), dim=1)))
        x4 = self.activation(self.conv4(torch.cat((x, x1, x2, x3), dim=1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), dim=1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, channels: int = 64, growth_channels: int = 32) -> None:
        super().__init__()
        self.rdb1 = ResidualDenseBlock(channels, growth_channels)
        self.rdb2 = ResidualDenseBlock(channels, growth_channels)
        self.rdb3 = ResidualDenseBlock(channels, growth_channels)

    def forward(self, x: Tensor) -> Tensor:
        return self.rdb3(self.rdb2(self.rdb1(x))) * 0.2 + x


class RRDBNet(nn.Module):
    def __init__(
        self,
        input_channels: int = 3,
        output_channels: int = 3,
        channels: int = 64,
        blocks: int = 23,
        growth_channels: int = 32,
        scale: int = 4,
    ) -> None:
        super().__init__()
        if scale != 4:
            raise ValueError("This exporter currently supports scale=4 only")

        self.conv_first = nn.Conv2d(input_channels, channels, 3, 1, 1)
        self.body = nn.Sequential(
            *(RRDB(channels, growth_channels) for _ in range(blocks))
        )
        self.conv_body = nn.Conv2d(channels, channels, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(channels, channels, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(channels, channels, 3, 1, 1)
        self.conv_hr = nn.Conv2d(channels, channels, 3, 1, 1)
        self.conv_last = nn.Conv2d(channels, output_channels, 3, 1, 1)
        self.activation = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x: Tensor) -> Tensor:
        feature = self.conv_first(x)
        body_feature = self.conv_body(self.body(feature))
        feature = feature + body_feature
        feature = self.activation(
            self.conv_up1(F.interpolate(feature, scale_factor=2, mode="nearest"))
        )
        feature = self.activation(
            self.conv_up2(F.interpolate(feature, scale_factor=2, mode="nearest"))
        )
        return self.conv_last(self.activation(self.conv_hr(feature)))


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tile-size", type=int, default=64)
    parser.add_argument("--opset", type=int, default=12)
    parser.add_argument("--seed", type=int, default=20260825)
    parser.add_argument("--report", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.tile_size <= 0 or args.tile_size % 4 != 0:
        raise ValueError("tile-size must be a positive multiple of 4")

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    checkpoint = torch.load(args.weights, map_location="cpu", weights_only=True)
    if list(checkpoint.keys()) != ["params_ema"]:
        raise ValueError(f"Unexpected checkpoint keys: {list(checkpoint.keys())}")

    model = RRDBNet().eval()
    incompatible = model.load_state_dict(checkpoint["params_ema"], strict=True)
    if incompatible.missing_keys or incompatible.unexpected_keys:
        raise RuntimeError(f"State dict mismatch: {incompatible}")

    sample = torch.rand(1, 3, args.tile_size, args.tile_size, dtype=torch.float32)
    with torch.inference_mode():
        torch_output = model(sample).cpu().numpy()

    expected_shape = (1, 3, args.tile_size * 4, args.tile_size * 4)
    if torch_output.shape != expected_shape:
        raise RuntimeError(
            f"Unexpected PyTorch output: {torch_output.shape}, expected {expected_shape}"
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.onnx.export(
        model,
        sample,
        args.output,
        input_names=["input"],
        output_names=["output"],
        opset_version=args.opset,
        do_constant_folding=True,
        dynamic_axes=None,
    )

    onnx_model = onnx.load(args.output)
    onnx.checker.check_model(onnx_model)
    session = ort.InferenceSession(
        str(args.output), providers=["CPUExecutionProvider"]
    )
    ort_output = session.run(["output"], {"input": sample.cpu().numpy()})[0]
    max_abs_error = float(np.max(np.abs(torch_output - ort_output)))
    mean_abs_error = float(np.mean(np.abs(torch_output - ort_output)))

    report = {
        "weights": str(args.weights),
        "weights_sha256": file_sha256(args.weights),
        "checkpoint_key": "params_ema",
        "architecture": "RRDBNet-23x64x32-x4",
        "tile_size": args.tile_size,
        "input_shape": list(sample.shape),
        "output_shape": list(torch_output.shape),
        "opset": args.opset,
        "onnx": str(args.output),
        "onnx_sha256": file_sha256(args.output),
        "onnx_bytes": args.output.stat().st_size,
        "max_abs_error": max_abs_error,
        "mean_abs_error": mean_abs_error,
        "torch_version": torch.__version__,
        "onnx_version": onnx.__version__,
        "onnxruntime_version": ort.__version__,
    }

    report_path = args.report or args.output.with_suffix(".json")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print(json.dumps(report, indent=2, ensure_ascii=False))
    print("RESULT=PASS_ONNX_EXPORT")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

