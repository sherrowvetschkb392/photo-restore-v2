"""Image tiling, reflective padding and overlap-add blending."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Iterator

import numpy as np


@dataclass(frozen=True)
class TilePlan:
    input_height: int
    input_width: int
    padded_height: int
    padded_width: int
    pad_top: int
    pad_bottom: int
    pad_left: int
    pad_right: int
    tile_size: int
    overlap: int
    stride: int
    scale: int
    y_starts: tuple[int, ...]
    x_starts: tuple[int, ...]

    @property
    def tile_count(self) -> int:
        return len(self.y_starts) * len(self.x_starts)


def _padded_axis(length: int, tile_size: int, overlap: int) -> tuple[int, int, int]:
    if length <= 0:
        raise ValueError("image dimensions must be positive")
    stride = tile_size - 2 * overlap
    minimum = length + 2 * overlap
    if minimum <= tile_size:
        padded = tile_size
    else:
        steps = (minimum - tile_size + stride - 1) // stride
        padded = tile_size + steps * stride
    before = overlap
    after = padded - length - before
    return padded, before, after


def make_tile_plan(
    height: int,
    width: int,
    *,
    tile_size: int = 96,
    overlap: int = 8,
    scale: int = 4,
) -> TilePlan:
    if tile_size <= 0 or scale <= 0:
        raise ValueError("tile_size and scale must be positive")
    if overlap < 0 or 2 * overlap >= tile_size:
        raise ValueError("overlap must be non-negative and less than half the tile")
    stride = tile_size - 2 * overlap
    padded_height, pad_top, pad_bottom = _padded_axis(height, tile_size, overlap)
    padded_width, pad_left, pad_right = _padded_axis(width, tile_size, overlap)
    y_starts = tuple(range(0, padded_height - tile_size + 1, stride))
    x_starts = tuple(range(0, padded_width - tile_size + 1, stride))
    if y_starts[-1] + tile_size != padded_height:
        raise RuntimeError("vertical tile grid does not cover the padded image")
    if x_starts[-1] + tile_size != padded_width:
        raise RuntimeError("horizontal tile grid does not cover the padded image")
    return TilePlan(
        input_height=height,
        input_width=width,
        padded_height=padded_height,
        padded_width=padded_width,
        pad_top=pad_top,
        pad_bottom=pad_bottom,
        pad_left=pad_left,
        pad_right=pad_right,
        tile_size=tile_size,
        overlap=overlap,
        stride=stride,
        scale=scale,
        y_starts=y_starts,
        x_starts=x_starts,
    )


def iter_tiles(plan: TilePlan) -> Iterator[tuple[int, int, int, int]]:
    index = 0
    for y in plan.y_starts:
        for x in plan.x_starts:
            yield index, plan.tile_count, y, x
            index += 1


def _pad_image(image: np.ndarray, plan: TilePlan) -> np.ndarray:
    if image.ndim != 3 or image.shape[2] != 3:
        raise ValueError(f"expected HWC RGB image, got shape {image.shape}")
    mode = "reflect" if image.shape[0] > 1 and image.shape[1] > 1 else "edge"
    return np.pad(
        image,
        (
            (plan.pad_top, plan.pad_bottom),
            (plan.pad_left, plan.pad_right),
            (0, 0),
        ),
        mode=mode,
    )


def _blend_axis(length: int, overlap_output: int) -> np.ndarray:
    weights = np.ones(length, dtype=np.float32)
    if overlap_output <= 0:
        return weights
    positions = (np.arange(overlap_output, dtype=np.float32) + 0.5) / overlap_output
    ramp = np.sin(positions * (np.pi / 2.0)) ** 2
    weights[:overlap_output] = ramp
    weights[-overlap_output:] = ramp[::-1]
    return weights


def make_blend_weight(plan: TilePlan) -> np.ndarray:
    output_tile = plan.tile_size * plan.scale
    overlap_output = (plan.tile_size - plan.stride) * plan.scale
    axis = _blend_axis(output_tile, overlap_output)
    return np.outer(axis, axis).astype(np.float32, copy=False)


def enhance_tiled(
    image: np.ndarray,
    infer_tile: Callable[[np.ndarray], np.ndarray],
    *,
    tile_size: int = 96,
    overlap: int = 8,
    scale: int = 4,
    progress: Callable[[int, int], None] | None = None,
) -> tuple[np.ndarray, TilePlan]:
    """Enhance an RGB float32 HWC image with normalized overlap-add blending."""
    if image.dtype != np.float32:
        image = image.astype(np.float32)
    plan = make_tile_plan(
        image.shape[0], image.shape[1], tile_size=tile_size, overlap=overlap, scale=scale
    )
    padded = _pad_image(image, plan)
    output_height = plan.padded_height * scale
    output_width = plan.padded_width * scale
    accumulator = np.zeros((output_height, output_width, 3), dtype=np.float32)
    weight_sum = np.zeros((output_height, output_width), dtype=np.float32)
    weight = make_blend_weight(plan)

    expected_output_shape = (tile_size * scale, tile_size * scale, 3)
    for index, total, y, x in iter_tiles(plan):
        tile = np.ascontiguousarray(padded[y : y + tile_size, x : x + tile_size])
        enhanced = np.asarray(infer_tile(tile), dtype=np.float32)
        if enhanced.shape != expected_output_shape:
            raise RuntimeError(
                f"tile output shape {enhanced.shape}, expected {expected_output_shape}"
            )
        out_y = y * scale
        out_x = x * scale
        out_slice = (
            slice(out_y, out_y + expected_output_shape[0]),
            slice(out_x, out_x + expected_output_shape[1]),
        )
        accumulator[out_slice] += enhanced * weight[..., None]
        weight_sum[out_slice] += weight
        if progress:
            progress(index + 1, total)

    if float(weight_sum.min()) <= 0:
        raise RuntimeError("tile blending produced uncovered output pixels")
    accumulator /= weight_sum[..., None]
    top = plan.pad_top * scale
    left = plan.pad_left * scale
    bottom = top + plan.input_height * scale
    right = left + plan.input_width * scale
    return accumulator[top:bottom, left:right], plan

