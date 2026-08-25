import tempfile
import unittest
from pathlib import Path

import numpy as np

from apps.worker.tiling import enhance_tiled, enhance_tiled_to_memmap, make_tile_plan


def nearest_x4(tile: np.ndarray) -> np.ndarray:
    return np.repeat(np.repeat(tile, 4, axis=0), 4, axis=1)


class TilingTests(unittest.TestCase):
    def test_tile_plan_covers_arbitrary_shape(self) -> None:
        plan = make_tile_plan(123, 211, tile_size=96, overlap=8, scale=4)
        self.assertEqual(plan.stride, 80)
        self.assertEqual(plan.y_starts[-1] + 96, plan.padded_height)
        self.assertEqual(plan.x_starts[-1] + 96, plan.padded_width)
        self.assertEqual(plan.tile_count, len(plan.y_starts) * len(plan.x_starts))

    def test_overlap_add_reconstructs_nearest_neighbor(self) -> None:
        rng = np.random.default_rng(42)
        image = rng.random((73, 141, 3), dtype=np.float32)
        result, plan = enhance_tiled(
            image, nearest_x4, tile_size=96, overlap=8, scale=4
        )
        expected = nearest_x4(image)
        self.assertEqual(result.shape, expected.shape)
        self.assertGreater(plan.tile_count, 1)
        np.testing.assert_allclose(result, expected, atol=2e-6, rtol=0)

    def test_tiny_image_is_padded_and_cropped(self) -> None:
        image = np.full((16, 24, 3), 0.25, dtype=np.float32)
        result, plan = enhance_tiled(
            image, nearest_x4, tile_size=96, overlap=8, scale=4
        )
        self.assertEqual(plan.tile_count, 1)
        self.assertEqual(result.shape, (64, 96, 3))
        np.testing.assert_allclose(result, 0.25, atol=1e-6, rtol=0)

    def test_disk_backed_matches_memory_compositor(self) -> None:
        rng = np.random.default_rng(20260826)
        image = rng.random((123, 211, 3), dtype=np.float32)
        memory_result, memory_plan = enhance_tiled(
            image, nearest_x4, tile_size=96, overlap=8, scale=4
        )
        expected = np.clip(np.rint(memory_result * 255.0), 0, 255).astype(np.uint8)
        with tempfile.TemporaryDirectory() as directory:
            raw_path = Path(directory) / "result.rgb"
            disk_result, disk_plan = enhance_tiled_to_memmap(
                image,
                nearest_x4,
                raw_path,
                tile_size=96,
                overlap=8,
                scale=4,
            )
            self.assertEqual(disk_plan, memory_plan)
            self.assertEqual(disk_result.shape, expected.shape)
            np.testing.assert_array_equal(disk_result, expected)
            disk_result._mmap.close()

    def test_disk_backed_removes_partial_output_after_failure(self) -> None:
        image = np.zeros((123, 211, 3), dtype=np.float32)
        calls = 0

        def fail_after_first_tile(tile: np.ndarray) -> np.ndarray:
            nonlocal calls
            calls += 1
            if calls > 1:
                raise RuntimeError("injected inference failure")
            return nearest_x4(tile)

        with tempfile.TemporaryDirectory() as directory:
            raw_path = Path(directory) / "partial.rgb"
            with self.assertRaisesRegex(RuntimeError, "injected inference failure"):
                enhance_tiled_to_memmap(
                    image,
                    fail_after_first_tile,
                    raw_path,
                    tile_size=96,
                    overlap=8,
                    scale=4,
                )
            self.assertFalse(raw_path.exists())


if __name__ == "__main__":
    unittest.main()
