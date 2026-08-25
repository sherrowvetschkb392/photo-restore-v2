#!/usr/bin/env python3
"""Create deterministic frame-pair fixtures for interpolation model evaluation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

import numpy as np
from PIL import Image


SCHEMA_VERSION = 1
DEFAULT_WIDTH = 256
DEFAULT_HEIGHT = 256


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: object) -> None:
    handle, temporary_name = tempfile.mkstemp(
        prefix=f".{path.stem}.", suffix=".json", dir=path.parent
    )
    os.close(handle)
    temporary = Path(temporary_name)
    try:
        temporary.write_text(json.dumps(value, indent=2, allow_nan=False), encoding="utf-8")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def background(width: int, height: int) -> np.ndarray:
    x = np.linspace(0.0, 1.0, width, dtype=np.float32)[None, :]
    y = np.linspace(0.0, 1.0, height, dtype=np.float32)[:, None]
    red = 0.12 + 0.48 * np.broadcast_to(x, (height, width))
    green = 0.10 + 0.45 * np.broadcast_to(y, (height, width))
    blue = 0.18 + 0.08 * np.sin(x * 8.0 * np.pi) * np.cos(y * 6.0 * np.pi)
    return np.stack((red, green, blue), axis=2).astype(np.float32)


def draw_rectangle(
    image: np.ndarray,
    left: int,
    top: int,
    width: int,
    height: int,
    color: tuple[float, float, float],
) -> None:
    right = min(image.shape[1], left + width)
    bottom = min(image.shape[0], top + height)
    left = max(0, left)
    top = max(0, top)
    if right > left and bottom > top:
        image[top:bottom, left:right] = color


def draw_circle(
    image: np.ndarray,
    center_x: int,
    center_y: int,
    radius: int,
    color: tuple[float, float, float],
) -> None:
    y, x = np.ogrid[: image.shape[0], : image.shape[1]]
    mask = (x - center_x) ** 2 + (y - center_y) ** 2 <= radius**2
    image[mask] = color


def moving_shapes(width: int, height: int, time_position: float) -> np.ndarray:
    image = background(width, height)
    rect_x = int(round(width * (0.12 + 0.46 * time_position)))
    circle_x = int(round(width * (0.76 - 0.34 * time_position)))
    draw_rectangle(image, rect_x, int(height * 0.28), 48, 58, (0.92, 0.20, 0.12))
    draw_circle(image, circle_x, int(height * 0.68), 25, (0.12, 0.86, 0.38))
    return image


def occlusion_reveal(width: int, height: int, time_position: float) -> np.ndarray:
    image = background(width, height)
    # Static foreground occluder. A striped object moves behind it, so the exact
    # midpoint includes both newly revealed and newly occluded content.
    object_x = int(round(width * (-0.02 + 0.62 * time_position)))
    object_y = int(height * 0.42)
    draw_rectangle(image, object_x, object_y, 92, 42, (0.88, 0.72, 0.10))
    for offset in range(0, 92, 12):
        draw_rectangle(image, object_x + offset, object_y, 5, 42, (0.16, 0.22, 0.82))
    draw_rectangle(image, int(width * 0.43), int(height * 0.18), 42, 168, (0.10, 0.10, 0.12))
    return image


def thin_texture(width: int, height: int, time_position: float) -> np.ndarray:
    image = background(width, height)
    shift = int(round(16 * time_position))
    for x in range(-16 + shift, width + 16, 16):
        if 0 <= x < width:
            image[:, x : x + 2] = (0.95, 0.95, 0.95)
    for y in range(8, height, 24):
        left = max(0, int(width * 0.15) + shift)
        right = min(width, int(width * 0.82) + shift)
        image[y : y + 2, left:right] = (0.05, 0.05, 0.05)
    draw_circle(
        image,
        int(round(width * (0.25 + 0.42 * time_position))),
        int(height * 0.52),
        18,
        (0.80, 0.18, 0.82),
    )
    return image


def scene_cut(width: int, height: int, time_position: float) -> np.ndarray:
    if time_position < 0.5:
        image = np.zeros((height, width, 3), dtype=np.float32)
        image[..., 0] = 0.82
        image[..., 1] = 0.12
        draw_circle(image, int(width * 0.28), int(height * 0.5), 42, (1.0, 0.82, 0.10))
        return image
    image = np.zeros((height, width, 3), dtype=np.float32)
    image[..., 1] = 0.24
    image[..., 2] = 0.80
    draw_rectangle(image, int(width * 0.58), int(height * 0.28), 54, 112, (0.08, 0.90, 0.72))
    return image


def to_nchw(image: np.ndarray) -> np.ndarray:
    return np.ascontiguousarray(image.transpose(2, 0, 1)[None, ...], dtype=np.float32)


def save_png(path: Path, image: np.ndarray) -> None:
    pixels = np.clip(np.rint(image * 255.0), 0, 255).astype(np.uint8)
    Image.fromarray(pixels).save(path, format="PNG", optimize=True)


def create_case(
    root: Path,
    name: str,
    renderer: Callable[[int, int, float], np.ndarray],
    width: int,
    height: int,
    interpolate: bool,
    description: str,
) -> dict[str, object]:
    case_dir = root / name
    case_dir.mkdir(parents=True, exist_ok=False)
    frame0 = renderer(width, height, 0.0)
    frame1 = renderer(width, height, 1.0)
    target = renderer(width, height, 0.5) if interpolate else frame1.copy()
    arrays = {
        "frame0.npy": to_nchw(frame0),
        "frame1.npy": to_nchw(frame1),
        "target.npy": to_nchw(target),
    }
    previews = {
        "frame0.png": frame0,
        "frame1.png": frame1,
        "target.png": target,
    }
    for filename, value in arrays.items():
        np.save(case_dir / filename, value, allow_pickle=False)
    for filename, value in previews.items():
        save_png(case_dir / filename, value)
    files = []
    for path in sorted(case_dir.iterdir()):
        files.append({"filename": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)})
    return {
        "name": name,
        "description": description,
        "interpolate": interpolate,
        "scene_cut": not interpolate,
        "time_position": 0.5,
        "input_layout": "NCHW",
        "input_dtype": "float32",
        "input_range": [0.0, 1.0],
        "input_shape": [1, 3, height, width],
        "output_shape": [1, 3, height, width],
        "policy": "run_model" if interpolate else "skip_model_and_copy_next_frame",
        "files": files,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--width", type=int, default=DEFAULT_WIDTH)
    parser.add_argument("--height", type=int, default=DEFAULT_HEIGHT)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if args.width <= 0 or args.height <= 0 or args.width % 16 or args.height % 16:
        raise SystemExit("width and height must be positive and divisible by 16")
    output_dir = args.output_dir.resolve()
    if output_dir.exists():
        if not args.force:
            raise SystemExit(f"output directory already exists: {output_dir}")
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)
    cases = [
        create_case(output_dir, "linear-motion", moving_shapes, args.width, args.height, True, "Two independently moving opaque shapes."),
        create_case(output_dir, "occlusion-reveal", occlusion_reveal, args.width, args.height, True, "A moving striped object passes behind a static occluder."),
        create_case(output_dir, "thin-texture", thin_texture, args.width, args.height, True, "Moving fine lines and a small textured object."),
        create_case(output_dir, "scene-cut", scene_cut, args.width, args.height, False, "An abrupt scene cut that must bypass interpolation."),
    ]
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "generator": "tools/make_interpolation_fixtures.py",
        "width": args.width,
        "height": args.height,
        "cases": cases,
    }
    atomic_json(output_dir / "manifest.json", manifest)
    print(f"OUTPUT={output_dir}")
    print(f"CASES={len(cases)}")
    print("RESULT=PASS_INTERPOLATION_FIXTURES")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
