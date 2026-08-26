#!/usr/bin/env python3
"""Create a deterministic Conv+ReLU ONNX model for the MNN OpenCL gate."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()

    weights = np.zeros((3, 3, 1, 1), dtype=np.float32)
    weights[0, 0, 0, 0] = 0.50
    weights[1, 1, 0, 0] = 0.75
    weights[2, 2, 0, 0] = 1.25
    bias = np.array([0.10, -0.05, 0.025], dtype=np.float32)

    graph = helper.make_graph(
        [
            helper.make_node("Conv", ["input", "weights", "bias"], ["convolved"], kernel_shape=[1, 1]),
            helper.make_node("Relu", ["convolved"], ["output"]),
        ],
        "photo_restore_mnn_opencl_smoke",
        [helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 3, 64, 64])],
        [helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 3, 64, 64])],
        [numpy_helper.from_array(weights, "weights"), numpy_helper.from_array(bias, "bias")],
    )
    model = helper.make_model(
        graph,
        producer_name="photo-restore-v2",
        opset_imports=[helper.make_opsetid("", 13)],
    )
    model.ir_version = 8
    onnx.checker.check_model(model)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, args.output)

    report = {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "model": str(args.output),
        "sha256": sha256(args.output),
        "input_shape": [1, 3, 64, 64],
        "output_shape": [1, 3, 64, 64],
        "operators": ["Conv", "Relu"],
        "channel_scales": [0.50, 0.75, 1.25],
        "channel_biases": [0.10, -0.05, 0.025],
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"MODEL={args.output}")
    print(f"SHA256={report['sha256']}")
    print("RESULT=PASS_MNN_OPENCL_SMOKE_ONNX")


if __name__ == "__main__":
    main()

