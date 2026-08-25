import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from tools import evaluate_video_enhancement_output as evaluator
from tools import make_video_enhancement_fixtures as fixtures


class VideoEnhancementContractTests(unittest.TestCase):
    def test_normalize_accepts_thwc_and_rejects_integer(self):
        candidate = np.zeros((5, 128, 128, 3), dtype=np.float32)
        normalized = evaluator.normalize(candidate, (5, 3, 128, 128))
        self.assertEqual(normalized.shape, (5, 3, 128, 128))
        with self.assertRaisesRegex(ValueError, "floating point"):
            evaluator.normalize(np.zeros((5, 3, 128, 128), dtype=np.uint8), (5, 3, 128, 128))

    def test_exact_target_beats_nearest_baseline(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            case = fixtures.create_case(root, "moving-texture", fixtures.scene, frames=3, width=32, height=32, scale=2, interpolate=True)
            manifest = {"cases": [case]}
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            report = evaluator.evaluate(root / "moving-texture", root / "moving-texture" / "target.npy")
            self.assertTrue(report["beats_spatial_baseline"])
            self.assertTrue(report["temporal_error_not_worse_than_baseline"])

    def test_scene_cut_is_rejected_for_temporal_evaluation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            case = fixtures.create_case(root, "scene-cut", fixtures.scene_cut, frames=3, width=32, height=32, scale=2, interpolate=False)
            (root / "manifest.json").write_text(json.dumps({"cases": [case]}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "reset"):
                evaluator.evaluate(root / "scene-cut", root / "scene-cut" / "target.npy")


if __name__ == "__main__":
    unittest.main()
