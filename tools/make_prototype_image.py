#!/usr/bin/env python3
"""Create a small deterministic RGB image for end-to-end seam validation."""

from __future__ import annotations

import argparse
from pathlib import Path

import cv2
import numpy as np


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--width", type=int, default=173)
    parser.add_argument("--height", type=int, default=131)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.width <= 0 or args.height <= 0:
        raise ValueError("width and height must be positive")
    x = np.linspace(0, 1, args.width, dtype=np.float32)[None, :]
    y = np.linspace(0, 1, args.height, dtype=np.float32)[:, None]
    red = np.broadcast_to(x, (args.height, args.width))
    green = np.broadcast_to(y, (args.height, args.width))
    blue = 0.5 + 0.25 * np.sin(x * 12 * np.pi) * np.cos(y * 10 * np.pi)
    image = np.stack((red, green, blue), axis=2)
    pixels = np.clip(np.rint(image * 255), 0, 255).astype(np.uint8)
    cv2.rectangle(pixels, (17, 19), (83, 77), (255, 255, 255), thickness=2)
    cv2.line(
        pixels, (0, args.height - 1), (args.width - 1, 0), (0, 0, 0), thickness=2
    )
    cv2.ellipse(
        pixels, (125, 68), (26, 26), 0, 0, 360, (255, 220, 20), thickness=3
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(args.output), cv2.cvtColor(pixels, cv2.COLOR_RGB2BGR)):
        raise RuntimeError(f"failed to write prototype image: {args.output}")
    print(f"OUTPUT={args.output}")
    print(f"SIZE={args.width}x{args.height}")
    print("RESULT=PASS_PROTOTYPE_IMAGE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
