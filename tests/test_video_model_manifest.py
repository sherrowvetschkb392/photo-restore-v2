import json
import unittest
from pathlib import Path

from tools import validate_video_model_manifest as validator


MANIFEST = Path(__file__).resolve().parents[1] / "datasets" / "manifests" / "video-model-candidates.json"


class VideoModelManifestTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))

    def test_repository_manifest_is_safe_before_download(self):
        self.assertEqual(validator.validate(self.manifest), [])

    def test_download_authorization_is_required_to_change(self):
        manifest = json.loads(json.dumps(self.manifest))
        manifest["decision"]["download_authorized"] = True
        self.assertTrue(any("download_authorized" in error for error in validator.validate(manifest)))

    def test_unknown_primary_is_rejected(self):
        manifest = json.loads(json.dumps(self.manifest))
        manifest["decision"]["interpolation_primary"] = "unknown"
        self.assertTrue(any("must reference" in error for error in validator.validate(manifest)))


if __name__ == "__main__":
    unittest.main()
