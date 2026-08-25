import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from tools import evaluate_interpolation_output as evaluator
from tools import make_interpolation_fixtures as fixtures


class InterpolationContractTests(unittest.TestCase):
    def test_generator_is_deterministic_for_array_artifacts(self):
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            first_root, second_root = Path(first), Path(second)
            self.assertEqual(fixtures.main.__name__, "main")
            first_case = fixtures.create_case(first_root, "linear-motion", fixtures.moving_shapes, 64, 64, True, "test")
            second_case = fixtures.create_case(second_root, "linear-motion", fixtures.moving_shapes, 64, 64, True, "test")
            first_hashes = {entry["filename"]: entry["sha256"] for entry in first_case["files"]}
            second_hashes = {entry["filename"]: entry["sha256"] for entry in second_case["files"]}
            self.assertEqual(first_hashes, second_hashes)

    def test_normalize_accepts_nhwc(self):
        candidate = np.zeros((1, 16, 32, 3), dtype=np.float32)
        normalized = evaluator.normalize_output(candidate, (1, 3, 16, 32))
        self.assertEqual(normalized.shape, (1, 3, 16, 32))

    def test_normalize_rejects_integer_and_out_of_range(self):
        with self.assertRaisesRegex(ValueError, "floating point"):
            evaluator.normalize_output(np.zeros((1, 3, 16, 16), dtype=np.uint8), (1, 3, 16, 16))
        with self.assertRaisesRegex(ValueError, "outside"):
            evaluator.normalize_output(np.full((1, 3, 16, 16), 2.0, dtype=np.float32), (1, 3, 16, 16))

    def test_exact_target_beats_baselines(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixtures.create_case(root, "linear-motion", fixtures.moving_shapes, 64, 64, True, "test")
            manifest = {
                "schema_version": 1,
                "cases": [{
                    "name": "linear-motion",
                    "interpolate": True,
                    "output_shape": [1, 3, 64, 64],
                }],
            }
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            case_dir = root / "linear-motion"
            report = evaluator.evaluate(case_dir, case_dir / "target.npy")
            self.assertEqual(report["candidate_metrics"]["mae"], 0.0)
            self.assertIsNone(report["candidate_metrics"]["psnr_db"])
            self.assertTrue(report["candidate_metrics"]["exact_match"])
            self.assertTrue(report["beats_best_baseline_mae"])

    def test_scene_cut_is_not_evaluated_as_interpolation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixtures.create_case(root, "scene-cut", fixtures.scene_cut, 64, 64, False, "test")
            (root / "manifest.json").write_text(
                json.dumps({"cases": [{"name": "scene-cut", "interpolate": False, "output_shape": [1, 3, 64, 64]}]}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "bypass"):
                evaluator.evaluate(root / "scene-cut", root / "scene-cut" / "target.npy")


if __name__ == "__main__":
    unittest.main()
