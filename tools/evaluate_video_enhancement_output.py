#!/usr/bin/env python3
"""Evaluate temporal video enhancement output against a fixture."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np


def normalize(array: np.ndarray, expected: tuple[int, int, int, int]) -> np.ndarray:
    if array.shape == expected:
        normalized = array
    elif array.shape == (expected[0], expected[2], expected[3], 3):
        normalized = array.transpose(0, 3, 1, 2)
    else:
        raise ValueError(f"unsupported output shape {array.shape}; expected TCHW or THWC {expected}")
    if not np.issubdtype(normalized.dtype, np.floating):
        raise ValueError(f"candidate output must be floating point, got {normalized.dtype}")
    normalized = np.ascontiguousarray(normalized, dtype=np.float32)
    if not np.isfinite(normalized).all():
        raise ValueError("candidate output contains NaN or infinity")
    minimum, maximum = float(normalized.min()), float(normalized.max())
    if minimum < -0.01 or maximum > 1.01:
        raise ValueError(f"candidate output range [{minimum}, {maximum}] is outside [0,1]")
    return np.clip(normalized, 0.0, 1.0)


def mae(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.mean(np.abs(a.astype(np.float64) - b.astype(np.float64))))


def psnr(a: np.ndarray, b: np.ndarray) -> float | None:
    mse = float(np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2))
    return None if mse == 0.0 else 10.0 * math.log10(1.0 / mse)


def temporal_error(array: np.ndarray, target: np.ndarray) -> float:
    if array.shape[0] < 2:
        return 0.0
    return mae(np.diff(array, axis=0), np.diff(target, axis=0))


def evaluate(case_dir: Path, candidate_path: Path) -> dict[str, object]:
    manifest = json.loads((case_dir.parent / "manifest.json").read_text(encoding="utf-8"))
    case = next(item for item in manifest["cases"] if item["name"] == case_dir.name)
    if not case["interpolate"]:
        raise ValueError("scene-cut fixtures must reset temporal model state")
    input_frames = np.load(case_dir / "input.npy", allow_pickle=False)
    target = np.load(case_dir / "target.npy", allow_pickle=False)
    expected = tuple(int(value) for value in case["output_shape"])
    candidate = normalize(np.load(candidate_path, allow_pickle=False), expected)
    nearest = np.repeat(np.repeat(input_frames, int(case["scale"]), axis=2), int(case["scale"]), axis=3)
    candidate_mae, baseline_mae = mae(candidate, target), mae(nearest, target)
    candidate_temporal, baseline_temporal = temporal_error(candidate, target), temporal_error(nearest, target)
    return {
        "schema_version": 1,
        "case": case["name"],
        "candidate_metrics": {"mae": candidate_mae, "psnr_db": psnr(candidate, target), "temporal_error": candidate_temporal},
        "nearest_upscale_baseline": {"mae": baseline_mae, "psnr_db": psnr(nearest, target), "temporal_error": baseline_temporal},
        "beats_spatial_baseline": candidate_mae < baseline_mae,
        "temporal_error_not_worse_than_baseline": candidate_temporal <= baseline_temporal * 1.05,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--case-dir", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--require-gates", action="store_true")
    args = parser.parse_args()
    report = evaluate(args.case_dir.resolve(), args.candidate.resolve())
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, allow_nan=False), encoding="utf-8")
    print(json.dumps(report, indent=2, allow_nan=False))
    if args.require_gates and not (report["beats_spatial_baseline"] and report["temporal_error_not_worse_than_baseline"]):
        print("RESULT=FAIL_VIDEO_ENHANCEMENT_GATES")
        return 2
    print("RESULT=PASS_VIDEO_ENHANCEMENT_EVALUATION")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
