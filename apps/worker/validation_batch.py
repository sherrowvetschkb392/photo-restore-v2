#!/usr/bin/env python3
"""Run an isolated image-validation batch on the RK3588 board."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


CURRENT_PROCESS: subprocess.Popen[str] | None = None


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def result_from_report(
    filename: str, input_hash: str, output_path: Path, report: dict[str, object]
) -> dict[str, object]:
    output_hash = file_sha256(output_path)
    if report.get("input_sha256") != input_hash:
        raise ValueError(f"report input hash mismatch: {filename}")
    if report.get("output_sha256") != output_hash:
        raise ValueError(f"report output hash mismatch: {filename}")
    return {
        "input_name": filename,
        "input_sha256": input_hash,
        "output_name": output_path.name,
        "output_sha256": output_hash,
        "input_size": report["plan"]["input_size"],
        "output_size": report["output_size"],
        "tile_count": report["plan"]["tile_count"],
        "inference_seconds": report["inference_seconds"],
        "total_seconds": report["total_seconds"],
        "max_rss_kib": report["max_rss_kib"],
    }


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    os.replace(temporary, path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--report-dir", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--status", type=Path, required=True)
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--max-input-pixels", type=int, default=2_000_000)
    return parser.parse_args()


def terminate(signum: int, _frame: object) -> None:
    global CURRENT_PROCESS
    if CURRENT_PROCESS is not None and CURRENT_PROCESS.poll() is None:
        CURRENT_PROCESS.terminate()
        try:
            CURRENT_PROCESS.wait(timeout=10)
        except subprocess.TimeoutExpired:
            CURRENT_PROCESS.kill()
            CURRENT_PROCESS.wait()
    raise SystemExit(128 + signum)


def main() -> int:
    global CURRENT_PROCESS
    args = parse_args()
    for signal_name in ("SIGHUP", "SIGINT", "SIGTERM"):
        signum = getattr(signal, signal_name, None)
        if signum is not None:
            signal.signal(signum, terminate)

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    items = manifest.get("items")
    if not isinstance(items, list) or not items:
        raise ValueError("manifest has no validation items")
    if len(items) > 20:
        raise ValueError("validation batch exceeds 20 images")
    if not args.worker.is_file() or not args.model.is_file():
        raise FileNotFoundError("worker or RKNN model is missing")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.report_dir.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    started_at = utc_now()
    results: list[dict[str, object]] = []

    def write_status(state: str, current: str | None = None, error: str | None = None) -> None:
        atomic_json(
            args.status,
            {
                "state": state,
                "total": len(items),
                "completed": len(results),
                "current": current,
                "error": error,
                "started_at_utc": started_at,
                "updated_at_utc": utc_now(),
                "elapsed_seconds": round(time.perf_counter() - started, 3),
            },
        )

    write_status("RUNNING")
    try:
        for index, item in enumerate(items, start=1):
            filename = str(item["filename"])
            if Path(filename).name != filename:
                raise ValueError(f"unsafe filename: {filename}")
            input_path = args.input_dir / filename
            if not input_path.is_file():
                raise FileNotFoundError(f"input is missing: {input_path}")
            actual_input_hash = file_sha256(input_path)
            if actual_input_hash != item["sha256"]:
                raise ValueError(f"input SHA-256 mismatch: {filename}")

            stem = input_path.stem
            output_path = args.output_dir / f"{stem}-x4.png"
            report_path = args.report_dir / f"{stem}-report.json"
            # A detached batch may be restarted after an SSH/network outage.
            # Reuse only a pair that is internally and externally verified.
            if output_path.is_file() and report_path.is_file():
                try:
                    existing_report = json.loads(report_path.read_text(encoding="utf-8"))
                    results.append(result_from_report(filename, actual_input_hash, output_path, existing_report))
                    write_status("RUNNING")
                    print(f"BATCH_IMAGE_RESUME {index}/{len(items)} {filename}", flush=True)
                    continue
                except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
                    output_path.unlink(missing_ok=True)
                    report_path.unlink(missing_ok=True)
            write_status("RUNNING", current=filename)
            print(f"BATCH_IMAGE_START {index}/{len(items)} {filename}", flush=True)
            command = [
                sys.executable,
                str(args.worker),
                "--input",
                str(input_path),
                "--output",
                str(output_path),
                "--model",
                str(args.model),
                "--report",
                str(report_path),
                "--max-input-pixels",
                str(args.max_input_pixels),
            ]
            CURRENT_PROCESS = subprocess.Popen(command, text=True)
            exit_code = CURRENT_PROCESS.wait()
            CURRENT_PROCESS = None
            if exit_code != 0:
                raise RuntimeError(f"restore_image failed for {filename}: exit {exit_code}")
            report = json.loads(report_path.read_text(encoding="utf-8"))
            results.append(result_from_report(filename, actual_input_hash, output_path, report))
            write_status("RUNNING")
            print(f"BATCH_IMAGE_PASS {index}/{len(items)} {filename}", flush=True)

        summary = {
            "dataset": manifest["dataset"],
            "generated_at_utc": utc_now(),
            "image_count": len(results),
            "tile_size": 96,
            "overlap_per_side": 8,
            "scale": 4,
            "elapsed_seconds": round(time.perf_counter() - started, 3),
            "results": results,
        }
        atomic_json(args.summary, summary)
        write_status("COMPLETE")
        print("RESULT=PASS_BOARD_VALIDATION_BATCH", flush=True)
        return 0
    except BaseException as exc:
        write_status("FAILED", error=f"{type(exc).__name__}: {exc}")
        raise


if __name__ == "__main__":
    raise SystemExit(main())
