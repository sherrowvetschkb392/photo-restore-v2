import unittest

import numpy as np

from apps.worker.tiling import enhance_tiled, make_tile_plan


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


if __name__ == "__main__":
    unittest.main()
