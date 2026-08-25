#!/usr/bin/env python3
"""Compile a fixed-shape Real-ESRGAN ONNX model for RK3588."""

from __future__ import annotations

import argparse
import hashlib
import json
import time
from importlib.metadata import version
from pathlib import Path

import onnx
from rknn.api import RKNN


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--onnx", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--target", default="rk3588")
    return parser.parse_args()


def check_result(stage: str, result: int) -> None:
    if result != 0:
        raise RuntimeError(f"RKNN {stage} failed with code {result}")


def main() -> int:
    args = parse_args()
    if not args.onnx.is_file():
        raise FileNotFoundError(args.onnx)

    model = onnx.load(args.onnx)
    onnx.checker.check_model(model)
    input_dims = list(model.graph.input[0].type.tensor_type.shape.dim)
    input_shape = [dimension.dim_value for dimension in input_dims]
    if input_shape != [1, 3, 64, 64]:
        raise ValueError(f"Unexpected ONNX input shape: {input_shape}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.log.parent.mkdir(parents=True, exist_ok=True)

    started = time.monotonic()
    rknn = RKNN(verbose=True, verbose_file=str(args.log))
    try:
        check_result(
            "config",
            rknn.config(
                target_platform=args.target,
                optimization_level=3,
            ),
        )
        check_result("load_onnx", rknn.load_onnx(model=str(args.onnx)))
        check_result("build", rknn.build(do_quantization=False))
        check_result("export_rknn", rknn.export_rknn(str(args.output)))
    finally:
        rknn.release()

    elapsed = time.monotonic() - started
    report = {
        "target": args.target,
        "quantization": False,
        "precision_intent": "FP16",
        "optimization_level": 3,
        "input_layout": "NCHW",
        "input_shape": input_shape,
        "onnx": str(args.onnx),
        "onnx_sha256": file_sha256(args.onnx),
        "rknn": str(args.output),
        "rknn_sha256": file_sha256(args.output),
        "rknn_bytes": args.output.stat().st_size,
        "elapsed_seconds": round(elapsed, 3),
        "rknn_toolkit2_version": version("rknn-toolkit2"),
        "log": str(args.log),
        "board_inference": "not_tested",
    }
    args.report.write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(json.dumps(report, indent=2, ensure_ascii=False))
    print("RESULT=PASS_RKNN_BUILD")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

