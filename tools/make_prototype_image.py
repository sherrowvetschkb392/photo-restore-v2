#!/usr/bin/env python3
"""Create a small deterministic RGB image for end-to-end seam validation."""

from __future__ import annotations

import argparse
import struct
import zlib
from pathlib import Path

import numpy as np


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--width", type=int, default=173)
    parser.add_argument("--height", type=int, default=131)
    return parser.parse_args()


def write_rgb_png(path: Path, pixels: np.ndarray) -> None:
    """Write an 8-bit RGB PNG using only the Python standard library."""
    if pixels.dtype != np.uint8 or pixels.ndim != 3 or pixels.shape[2] != 3:
        raise ValueError(f"expected uint8 HWC RGB pixels, got {pixels.shape}")

    def chunk(kind: bytes, data: bytes) -> bytes:
        payload = kind + data
        return (
            struct.pack(">I", len(data))
            + payload
            + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)
        )

    height, width, _ = pixels.shape
    scanlines = b"".join(b"\x00" + row.tobytes() for row in pixels)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk("IHDR".encode("ascii"), struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk("IDAT".encode("ascii"), zlib.compress(scanlines, level=6))
    png += chunk("IEND".encode("ascii"), b"")
    path.write_bytes(png)


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

    rectangle = (
        ((np.arange(args.height)[:, None] >= 19) & (np.arange(args.height)[:, None] <= 77))
        & ((np.arange(args.width)[None, :] >= 17) & (np.arange(args.width)[None, :] <= 83))
    )
    rectangle_inner = (
        ((np.arange(args.height)[:, None] >= 21) & (np.arange(args.height)[:, None] <= 75))
        & ((np.arange(args.width)[None, :] >= 19) & (np.arange(args.width)[None, :] <= 81))
    )
    pixels[rectangle & ~rectangle_inner] = (255, 255, 255)

    yy, xx = np.ogrid[: args.height, : args.width]
    line_y = (args.height - 1) * (1.0 - xx / max(args.width - 1, 1))
    pixels[np.abs(yy - line_y) <= 1.0] = (0, 0, 0)
    radius = np.sqrt((xx - 125) ** 2 + (yy - 68) ** 2)
    pixels[(radius >= 23) & (radius <= 26)] = (255, 220, 20)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    write_rgb_png(args.output, pixels)
    print(f"OUTPUT={args.output}")
    print(f"SIZE={args.width}x{args.height}")
    print("RESULT=PASS_PROTOTYPE_IMAGE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
