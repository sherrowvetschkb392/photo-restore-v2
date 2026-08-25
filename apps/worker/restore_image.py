#!/usr/bin/env python3
"""Restore one image with the fixed tile96 Real-ESRGAN RKNN model."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import resource
import shutil
import tempfile
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps
from rknnlite.api import RKNNLite

from tiling import TilePlan, enhance_tiled, enhance_tiled_to_memmap


DISK_COMPOSITOR_THRESHOLD_PIXELS = 500_000
MINIMUM_FREE_DISK_RESERVE_BYTES = 256 * 1024 * 1024


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--preview-output", type=Path)
    parser.add_argument("--preview-max-edge", type=int, default=1600)
    parser.add_argument("--tile-size", type=int, default=96)
    parser.add_argument("--overlap", type=int, default=8)
    parser.add_argument("--scale", type=int, default=4)
    parser.add_argument("--max-input-pixels", type=int, default=2_000_000)
    parser.add_argument("--jpeg-quality", type=int, default=95)
    parser.add_argument(
        "--compositor", choices=("auto", "memory", "disk"), default="auto"
    )
    parser.add_argument("--work-dir", type=Path)
    return parser.parse_args()


def atomic_save(image: Image.Image, output: Path, jpeg_quality: int) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    suffix = output.suffix.lower()
    if suffix not in {".png", ".jpg", ".jpeg"}:
        raise ValueError("output extension must be .png, .jpg or .jpeg")
    handle, temporary_name = tempfile.mkstemp(
        prefix=f".{output.stem}.", suffix=output.suffix, dir=output.parent
    )
    os.close(handle)
    temporary = Path(temporary_name)
    try:
        if suffix == ".png":
            image.save(temporary, format="PNG", compress_level=6)
        else:
            image.save(
                temporary,
                format="JPEG",
                quality=jpeg_quality,
                subsampling=0,
                optimize=True,
            )
        with temporary.open("rb") as stream:
            os.fsync(stream.fileno())
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)


class RknnTileEngine:
    def __init__(self, model: Path) -> None:
        self._rknn = RKNNLite(verbose=False)
        code = self._rknn.load_rknn(str(model))
        if code != 0:
            raise RuntimeError(f"load_rknn failed with code {code}")
        core_mask = getattr(RKNNLite, "NPU_CORE_0_1_2", RKNNLite.NPU_CORE_AUTO)
        code = self._rknn.init_runtime(core_mask=core_mask)
        if code != 0:
            raise RuntimeError(f"init_runtime failed with code {code}")

    def infer(self, tile: np.ndarray) -> np.ndarray:
        runtime_input = np.ascontiguousarray(tile[None, ...], dtype=np.float32)
        outputs = self._rknn.inference(inputs=[runtime_input], data_format=["nhwc"])
        if not outputs:
            raise RuntimeError("RKNN inference returned no output")
        output = np.asarray(outputs[0], dtype=np.float32)
        if output.ndim != 4 or output.shape[0] != 1 or output.shape[1] != 3:
            raise RuntimeError(f"unexpected RKNN output shape: {output.shape}")
        return np.ascontiguousarray(output[0].transpose(1, 2, 0))

    def close(self) -> None:
        self._rknn.release()


def plan_to_dict(plan: TilePlan) -> dict[str, object]:
    return {
        "input_size": [plan.input_width, plan.input_height],
        "padded_size": [plan.padded_width, plan.padded_height],
        "padding": {
            "top": plan.pad_top,
            "bottom": plan.pad_bottom,
            "left": plan.pad_left,
            "right": plan.pad_right,
        },
        "tile_size": plan.tile_size,
        "overlap_per_side": plan.overlap,
        "stride": plan.stride,
        "scale": plan.scale,
        "tile_count": plan.tile_count,
    }


def main() -> int:
    args = parse_args()
    if args.tile_size != 96 or args.scale != 4:
        raise ValueError("the selected RKNN model requires tile-size=96 and scale=4")
    if not args.input.is_file() or not args.model.is_file():
        raise FileNotFoundError("input image or RKNN model is missing")

    total_started = time.perf_counter()
    with Image.open(args.input) as source:
        source = ImageOps.exif_transpose(source).convert("RGB")
        width, height = source.size
        input_pixels = width * height
        if args.max_input_pixels > 0 and input_pixels > args.max_input_pixels:
            raise ValueError(
                f"input has {input_pixels} pixels; prototype limit is "
                f"{args.max_input_pixels}. Large-image stripe processing is not yet enabled."
            )
        input_array = np.asarray(source, dtype=np.float32) / 255.0

    compositor = args.compositor
    if compositor == "auto":
        compositor = (
            "disk" if input_pixels > DISK_COMPOSITOR_THRESHOLD_PIXELS else "memory"
        )
    work_dir = args.work_dir or args.output.parent
    raw_output_bytes = width * args.scale * height * args.scale * 3
    required_free_bytes = raw_output_bytes * 2 + MINIMUM_FREE_DISK_RESERVE_BYTES
    if compositor == "disk":
        work_dir.mkdir(parents=True, exist_ok=True)
        free_bytes = shutil.disk_usage(work_dir).free
        if free_bytes < required_free_bytes:
            raise OSError(
                f"insufficient working disk space: need at least {required_free_bytes} "
                f"bytes free, found {free_bytes}"
            )

    engine = RknnTileEngine(args.model)
    inference_started = time.perf_counter()
    last_update = 0.0

    def progress(done: int, total: int) -> None:
        nonlocal last_update
        now = time.perf_counter()
        if done == total or now - last_update >= 1.0:
            elapsed = now - inference_started
            rate = done / elapsed if elapsed > 0 else 0.0
            remaining = (total - done) / rate if rate > 0 else 0.0
            print(
                f"PROGRESS {done}/{total} ({done / total:.1%}) "
                f"elapsed={elapsed:.1f}s eta={remaining:.1f}s",
                flush=True,
            )
            last_update = now

    raw_output_path: Path | None = None
    raw_output: np.memmap | None = None
    try:
        if compositor == "disk":
            handle, raw_output_name = tempfile.mkstemp(
                prefix=".photo-restore-", suffix=".rgb", dir=work_dir
            )
            os.close(handle)
            raw_output_path = Path(raw_output_name)
            raw_output, plan = enhance_tiled_to_memmap(
                input_array,
                engine.infer,
                raw_output_path,
                tile_size=args.tile_size,
                overlap=args.overlap,
                scale=args.scale,
                progress=progress,
            )
            output_image = Image.fromarray(raw_output)
        else:
            restored, plan = enhance_tiled(
                input_array,
                engine.infer,
                tile_size=args.tile_size,
                overlap=args.overlap,
                scale=args.scale,
                progress=progress,
            )
            output_array = np.clip(np.rint(restored * 255.0), 0, 255).astype(np.uint8)
            output_image = Image.fromarray(output_array)
        inference_seconds = time.perf_counter() - inference_started
        full_output_size = output_image.size
        atomic_save(output_image, args.output, args.jpeg_quality)
        if args.preview_output:
            if args.preview_max_edge <= 0:
                raise ValueError("preview-max-edge must be positive")
            output_image.thumbnail(
                (args.preview_max_edge, args.preview_max_edge), Image.Resampling.LANCZOS
            )
            atomic_save(output_image, args.preview_output, 88)
    finally:
        engine.close()
        if raw_output is not None:
            raw_output.flush()
            del raw_output
        if raw_output_path is not None:
            raw_output_path.unlink(missing_ok=True)
    total_seconds = time.perf_counter() - total_started

    report = {
        "input": str(args.input),
        "input_sha256": file_sha256(args.input),
        "output": str(args.output),
        "output_sha256": file_sha256(args.output),
        "model": str(args.model),
        "model_sha256": file_sha256(args.model),
        "plan": plan_to_dict(plan),
        "output_size": list(full_output_size),
        "preview_output": str(args.preview_output) if args.preview_output else None,
        "preview_size": list(output_image.size) if args.preview_output else None,
        "compositor": compositor,
        "raw_output_bytes": raw_output_bytes if compositor == "disk" else 0,
        "required_free_bytes": required_free_bytes if compositor == "disk" else 0,
        "inference_seconds": round(inference_seconds, 3),
        "total_seconds": round(total_seconds, 3),
        "max_rss_kib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "prototype_max_input_pixels": args.max_input_pixels,
    }
    report_text = json.dumps(report, indent=2, ensure_ascii=False)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(report_text + "\n", encoding="utf-8")
    print(report_text)
    print("RESULT=PASS_IMAGE_RESTORE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
