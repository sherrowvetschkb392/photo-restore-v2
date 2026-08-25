#!/usr/bin/env python3
"""Load a fixed-tile RKNN model and compare NPU output with ONNX reference."""

from __future__ import annotations

import argparse
import json
import os
import resource
import time
from pathlib import Path

import numpy as np
from rknnlite.api import RKNNLite


def thermal_snapshot() -> dict[str, float]:
    result: dict[str, float] = {}
    for zone in sorted(Path("/sys/class/thermal").glob("thermal_zone*")):
        try:
            name = (zone / "type").read_text(encoding="utf-8").strip()
            value = float((zone / "temp").read_text(encoding="utf-8").strip()) / 1000
        except (OSError, ValueError):
            continue
        result[name] = value
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--tile-size", type=int, required=True)
    parser.add_argument("--report", type=Path)
    return parser.parse_args()


def check_code(stage: str, code: int) -> None:
    if code != 0:
        raise RuntimeError(f"{stage} failed with code {code}")


def main() -> int:
    args = parse_args()
    input_data = np.load(args.input, allow_pickle=False).astype(np.float32, copy=False)
    reference = np.load(args.reference, allow_pickle=False).astype(np.float32, copy=False)
    expected_input_shape = (1, 3, args.tile_size, args.tile_size)
    expected_output_shape = (1, 3, args.tile_size * 4, args.tile_size * 4)
    if input_data.shape != expected_input_shape:
        raise ValueError(f"Unexpected input shape: {input_data.shape}")
    if reference.shape != expected_output_shape:
        raise ValueError(f"Unexpected reference shape: {reference.shape}")

    # RKNN's board input ABI is NHWC even though the source ONNX graph is NCHW.
    # Supplying NHWC directly avoids a per-call implicit transpose in RKNNLite.
    runtime_input = np.ascontiguousarray(input_data.transpose(0, 2, 3, 1))

    report: dict[str, object] = {
        "pid": os.getpid(),
        "runs": args.runs,
        "tile_size": args.tile_size,
        "source_input_shape": list(input_data.shape),
        "runtime_input_layout": "NHWC",
        "runtime_input_shape": list(runtime_input.shape),
        "temperature_before_c": thermal_snapshot(),
    }
    rknn = RKNNLite(verbose=False)
    try:
        started = time.perf_counter()
        check_code("load_rknn", rknn.load_rknn(str(args.model)))
        report["load_seconds"] = round(time.perf_counter() - started, 6)

        started = time.perf_counter()
        core_mask = getattr(RKNNLite, "NPU_CORE_0_1_2", RKNNLite.NPU_CORE_AUTO)
        check_code("init_runtime", rknn.init_runtime(core_mask=core_mask))
        report["init_seconds"] = round(time.perf_counter() - started, 6)
        report["core_mask"] = int(core_mask)

        timings: list[float] = []
        output = None
        for _ in range(args.runs):
            started = time.perf_counter()
            outputs = rknn.inference(inputs=[runtime_input], data_format=["nhwc"])
            timings.append(time.perf_counter() - started)
            if not outputs:
                raise RuntimeError("RKNN inference returned no output")
            output = np.asarray(outputs[0], dtype=np.float32)

        assert output is not None
        if output.shape != reference.shape:
            raise RuntimeError(
                f"Output shape mismatch: RKNN {output.shape}, reference {reference.shape}"
            )
        difference = np.abs(output - reference)
        max_abs_error = float(difference.max())
        mean_abs_error = float(difference.mean())
        report.update(
            {
                "output_shape": list(output.shape),
                "inference_seconds": [round(item, 6) for item in timings],
                "first_inference_seconds": round(timings[0], 6),
                "steady_mean_seconds": round(
                    float(np.mean(timings[1:] if len(timings) > 1 else timings)), 6
                ),
                "max_abs_error": max_abs_error,
                "mean_abs_error": mean_abs_error,
                "rknn_output_min": float(output.min()),
                "rknn_output_max": float(output.max()),
                "rknn_output_mean": float(output.mean()),
                "max_rss_kib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                "temperature_after_c": thermal_snapshot(),
            }
        )
        if max_abs_error > 0.01 or mean_abs_error > 0.001:
            raise RuntimeError(
                "RKNN output exceeded error limits: "
                f"max={max_abs_error}, mean={mean_abs_error}"
            )
    finally:
        rknn.release()

    report_text = json.dumps(report, indent=2, ensure_ascii=False)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(report_text + "\n", encoding="utf-8")
    print(report_text)
    print("RESULT=PASS_BOARD_RKNN_INFERENCE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
