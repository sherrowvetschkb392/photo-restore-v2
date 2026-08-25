#!/usr/bin/env python3
"""Create deterministic low-resolution video-super-resolution fixtures.

The fixtures model the spatial part of the video pipeline: a short temporal
window of low-resolution RGB frames maps to high-resolution frames.  They are
synthetic regression gates, not a claim about real-world restoration quality.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path

import numpy as np
from PIL import Image


SCHEMA_VERSION = 1


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def scene(width: int, height: int, time_position: float) -> np.ndarray:
    """Render a deterministic high-resolution RGB scene in [0, 1]."""
    x = np.linspace(0.0, 1.0, width, dtype=np.float32)[None, :]
    y = np.linspace(0.0, 1.0, height, dtype=np.float32)[:, None]
    image = np.stack(
        (
            0.10 + 0.35 * np.broadcast_to(x, (height, width)),
            0.12 + 0.30 * np.broadcast_to(y, (height, width)),
            0.16 + 0.08 * np.sin(x * 16.0 * np.pi) * np.cos(y * 10.0 * np.pi),
        ),
        axis=2,
    ).astype(np.float32)
    center_x = int(round(width * (0.18 + 0.52 * time_position)))
    center_y = int(height * 0.55)
    radius = max(4, width // 18)
    yy, xx = np.ogrid[:height, :width]
    mask = (xx - center_x) ** 2 + (yy - center_y) ** 2 <= radius**2
    image[mask] = (0.92, 0.18, 0.12)
    # Thin diagonals and a checker patch exercise texture preservation.
    for offset in range(-height, width, max(3, width // 32)):
        diagonal = np.arange(height) + offset
        valid = (diagonal >= 0) & (diagonal < width)
        image[np.arange(height)[valid], diagonal[valid]] = (0.90, 0.90, 0.88)
    patch_left = int(width * (0.66 - 0.12 * time_position))
    patch_top = int(height * 0.20)
    patch_size = max(8, width // 10)
    for row in range(patch_size):
        for col in range(patch_size):
            px, py = patch_left + col, patch_top + row
            if 0 <= px < width and 0 <= py < height:
                image[py, px] = (0.08, 0.72, 0.82) if (row + col) % 2 else (0.95, 0.78, 0.12)
    return np.clip(image, 0.0, 1.0)


def scene_cut(width: int, height: int, time_position: float) -> np.ndarray:
    image = np.zeros((height, width, 3), dtype=np.float32)
    if time_position < 0.5:
        image[...] = (0.78, 0.10, 0.12)
        image[:, : width // 3] = (0.95, 0.75, 0.08)
    else:
        image[...] = (0.08, 0.25, 0.78)
        image[:, width * 2 // 3 :] = (0.10, 0.88, 0.68)
    return image


def to_nchw(frames: np.ndarray) -> np.ndarray:
    return np.ascontiguousarray(frames.transpose(0, 3, 1, 2), dtype=np.float32)


def save_preview(path: Path, frame: np.ndarray) -> None:
    Image.fromarray(np.rint(np.clip(frame, 0.0, 1.0) * 255.0).astype(np.uint8)).save(path, format="PNG", optimize=True)


def create_case(root: Path, name: str, renderer, *, frames: int, width: int, height: int, scale: int, interpolate: bool) -> dict[str, object]:
    case_dir = root / name
    case_dir.mkdir(parents=True, exist_ok=False)
    positions = np.linspace(0.0, 1.0, frames, dtype=np.float32)
    high = np.stack([renderer(width * scale, height * scale, float(p)) for p in positions], axis=0)
    low_images = [Image.fromarray(np.rint(frame * 255.0).astype(np.uint8)).resize((width, height), Image.Resampling.LANCZOS) for frame in high]
    low = np.stack([np.asarray(image, dtype=np.float32) / 255.0 for image in low_images], axis=0)
    np.save(case_dir / "input.npy", to_nchw(low), allow_pickle=False)
    np.save(case_dir / "target.npy", to_nchw(high), allow_pickle=False)
    for index, frame in enumerate(low):
        save_preview(case_dir / f"input-{index:02d}.png", frame)
        save_preview(case_dir / f"target-{index:02d}.png", high[index])
    files = [{"filename": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)} for path in sorted(case_dir.iterdir())]
    return {
        "name": name,
        "interpolate": interpolate,
        "scene_cut": not interpolate,
        "frame_count": frames,
        "input_shape": [frames, 3, height, width],
        "output_shape": [frames, 3, height * scale, width * scale],
        "input_dtype": "float32",
        "output_dtype": "float32",
        "range": [0.0, 1.0],
        "scale": scale,
        "policy": "run_temporal_model" if interpolate else "reset_state_and_copy_or_cut",
        "files": files,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--width", type=int, default=64)
    parser.add_argument("--height", type=int, default=64)
    parser.add_argument("--frames", type=int, default=5)
    parser.add_argument("--scale", type=int, choices=(2, 4), default=2)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if min(args.width, args.height, args.frames) <= 0:
        raise SystemExit("width, height and frames must be positive")
    if args.width % 16 or args.height % 16:
        raise SystemExit("width and height must be divisible by 16")
    root = args.output_dir.resolve()
    if root.exists():
        if not args.force:
            raise SystemExit(f"output directory already exists: {root}")
        shutil.rmtree(root)
    root.mkdir(parents=True)
    cases = [
        create_case(root, "moving-texture", scene, frames=args.frames, width=args.width, height=args.height, scale=args.scale, interpolate=True),
        create_case(root, "scene-cut", scene_cut, frames=args.frames, width=args.width, height=args.height, scale=args.scale, interpolate=False),
    ]
    (root / "manifest.json").write_text(json.dumps({"schema_version": SCHEMA_VERSION, "width": args.width, "height": args.height, "frames": args.frames, "scale": args.scale, "cases": cases}, indent=2, allow_nan=False), encoding="utf-8")
    print(f"OUTPUT={root}")
    print(f"CASES={len(cases)}")
    print("RESULT=PASS_VIDEO_ENHANCEMENT_FIXTURES")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
