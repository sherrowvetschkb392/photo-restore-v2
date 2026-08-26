#!/usr/bin/env python3
"""Probe whether TorchVision modulated deform convolution exports to ONNX."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()

    import torch
    from torch import nn
    from torchvision.ops import deform_conv2d

    class Probe(nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.weight = nn.Parameter(torch.linspace(-0.1, 0.1, 3 * 3 * 3 * 3).reshape(3, 3, 3, 3))
            self.bias = nn.Parameter(torch.zeros(3))

        def forward(self, image, offset, mask):
            return deform_conv2d(image, offset, self.weight, self.bias, padding=1, mask=mask)

    torch.manual_seed(7)
    model = Probe().eval()
    image = torch.rand(1, 3, 16, 16)
    offset = torch.zeros(1, 18, 16, 16)
    mask = torch.full((1, 9, 16, 16), 0.5)
    report = {
        "schema_version": 1,
        "operator": "torchvision.ops.deform_conv2d",
        "modulated": True,
        "fixed_shapes": {
            "image": list(image.shape),
            "offset": list(offset.shape),
            "mask": list(mask.shape),
        },
        "cpu_execution": {},
        "onnx_export": {},
        "board_upload": False,
    }
    try:
        with torch.inference_mode():
            output = model(image, offset, mask)
        report["cpu_execution"] = {"passed": True, "output_shape": list(output.shape), "finite": bool(torch.isfinite(output).all())}
    except Exception as exc:
        report["cpu_execution"] = {"passed": False, "error": f"{type(exc).__name__}: {exc}"}

    if report["cpu_execution"].get("passed"):
        try:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            torch.onnx.export(
                model,
                (image, offset, mask),
                args.output,
                input_names=["image", "offset", "mask"],
                output_names=["output"],
                opset_version=16,
                do_constant_folding=True,
            )
            report["onnx_export"] = {"passed": True, "path": str(args.output.resolve()), "bytes": args.output.stat().st_size}
            report["gate"] = "READY_FOR_ONNX_OPERATOR_AUDIT"
        except Exception as exc:
            args.output.unlink(missing_ok=True)
            report["onnx_export"] = {"passed": False, "error": f"{type(exc).__name__}: {exc}"}
            report["gate"] = "BLOCKED_TORCHVISION_DEFORM_CONV_ONNX_EXPORT"
    else:
        report["gate"] = "BLOCKED_TORCHVISION_DEFORM_CONV_CPU_EXECUTION"

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, allow_nan=False), encoding="utf-8")
    print(json.dumps(report, indent=2, allow_nan=False))
    print(f"RESULT={report['gate']}_DEFORM_CONV_PROBE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
