#!/usr/bin/env python3
"""Create deterministic input and ONNX reference output for board validation."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--onnx", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20260825)
    parser.add_argument("--tile-size", type=int, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(args.seed)
    input_data = rng.random(
        (1, 3, args.tile_size, args.tile_size), dtype=np.float32
    )

    session = ort.InferenceSession(
        str(args.onnx), providers=["CPUExecutionProvider"]
    )
    output_data = session.run(["output"], {"input": input_data})[0].astype(
        np.float32, copy=False
    )

    prefix = f"tile{args.tile_size}"
    input_path = args.output_dir / f"{prefix}-input.npy"
    output_path = args.output_dir / f"{prefix}-onnx-output.npy"
    report_path = args.output_dir / f"{prefix}-fixture.json"
    np.save(input_path, input_data, allow_pickle=False)
    np.save(output_path, output_data, allow_pickle=False)

    report = {
        "seed": args.seed,
        "tile_size": args.tile_size,
        "input_shape": list(input_data.shape),
        "output_shape": list(output_data.shape),
        "input_sha256": sha256(input_path),
        "output_sha256": sha256(output_path),
        "output_min": float(output_data.min()),
        "output_max": float(output_data.max()),
        "output_mean": float(output_data.mean()),
        "onnxruntime_version": ort.__version__,
    }
    report_path.write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(report, indent=2))
    print("RESULT=PASS_VALIDATION_FIXTURE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
