#!/usr/bin/env python3
"""Evaluate one candidate middle-frame output against a deterministic fixture."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np


def normalize_output(array: np.ndarray, expected_shape: tuple[int, int, int, int]) -> np.ndarray:
    height, width = expected_shape[2], expected_shape[3]
    if array.shape == expected_shape:
        normalized = array
    elif array.shape == (1, height, width, 3):
        normalized = array.transpose(0, 3, 1, 2)
    elif array.shape == expected_shape[1:]:
        normalized = array[None, ...]
    elif array.shape == (height, width, 3):
        normalized = array.transpose(2, 0, 1)[None, ...]
    else:
        raise ValueError(f"unsupported output shape {array.shape}; expected NCHW or NHWC for {expected_shape}")
    if not np.issubdtype(normalized.dtype, np.floating):
        raise ValueError(f"candidate output must be floating point, got {normalized.dtype}")
    normalized = np.ascontiguousarray(normalized, dtype=np.float32)
    if not np.isfinite(normalized).all():
        raise ValueError("candidate output contains NaN or infinity")
    minimum = float(normalized.min())
    maximum = float(normalized.max())
    if minimum < -0.01 or maximum > 1.01:
        raise ValueError(f"candidate output range [{minimum}, {maximum}] is outside [0,1]")
    return np.clip(normalized, 0.0, 1.0)


def metrics(candidate: np.ndarray, target: np.ndarray) -> dict[str, float | bool | None]:
    difference = candidate.astype(np.float64) - target.astype(np.float64)
    mae = float(np.mean(np.abs(difference)))
    mse = float(np.mean(difference**2))
    rmse = math.sqrt(mse)
    exact_match = mse == 0.0
    psnr = None if exact_match else 10.0 * math.log10(1.0 / mse)
    return {
        "mae": mae,
        "rmse": rmse,
        "psnr_db": psnr,
        "max_abs_error": float(np.max(np.abs(difference))),
        "exact_match": exact_match,
    }


def load_case(case_dir: Path) -> tuple[dict[str, object], np.ndarray, np.ndarray, np.ndarray]:
    manifest_path = case_dir.parent / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    entries = [case for case in manifest["cases"] if case["name"] == case_dir.name]
    if len(entries) != 1:
        raise ValueError(f"fixture case is not uniquely declared: {case_dir.name}")
    case = entries[0]
    if not case["interpolate"]:
        raise ValueError("scene-cut fixtures must bypass the interpolation model")
    frame0 = np.load(case_dir / "frame0.npy", allow_pickle=False)
    frame1 = np.load(case_dir / "frame1.npy", allow_pickle=False)
    target = np.load(case_dir / "target.npy", allow_pickle=False)
    return case, frame0, frame1, target


def evaluate(case_dir: Path, candidate_path: Path) -> dict[str, object]:
    case, frame0, frame1, target = load_case(case_dir)
    expected_shape = tuple(int(value) for value in case["output_shape"])
    candidate = normalize_output(np.load(candidate_path, allow_pickle=False), expected_shape)
    average = (frame0 + frame1) * 0.5
    candidate_metrics = metrics(candidate, target)
    baselines = {
        "copy_frame0": metrics(frame0, target),
        "copy_frame1": metrics(frame1, target),
        "average_frames": metrics(average, target),
    }
    best_baseline_mae = min(value["mae"] for value in baselines.values())
    return {
        "schema_version": 1,
        "case": case["name"],
        "candidate": str(candidate_path.resolve()),
        "candidate_metrics": candidate_metrics,
        "baselines": baselines,
        "best_baseline_mae": best_baseline_mae,
        "beats_best_baseline_mae": candidate_metrics["mae"] < best_baseline_mae,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--case-dir", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--require-beats-baseline", action="store_true")
    args = parser.parse_args()
    report = evaluate(args.case_dir.resolve(), args.candidate.resolve())
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, allow_nan=False), encoding="utf-8")
    print(json.dumps(report, indent=2, allow_nan=False))
    if args.require_beats_baseline and not report["beats_best_baseline_mae"]:
        print("RESULT=FAIL_INTERPOLATION_OUTPUT_BASELINE")
        return 2
    print("RESULT=PASS_INTERPOLATION_OUTPUT_EVALUATION")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
