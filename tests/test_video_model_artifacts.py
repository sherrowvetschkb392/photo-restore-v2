import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from tools import verify_video_model_artifacts as verifier


class VideoModelArtifactTests(unittest.TestCase):
    def test_valid_record_and_hash_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = root / "model.pth"
            artifact.write_bytes(b"fixture-model")
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            record = root / "weights-record.json"
            record.write_text(json.dumps({
                "schema_version": 1,
                "candidate": "fixture",
                "weights_downloaded": True,
                "board_upload": False,
                "artifacts": [{"path": str(artifact), "bytes": artifact.stat().st_size, "sha256": digest}],
            }), encoding="utf-8")
            self.assertEqual(verifier.verify(record), [])

    def test_modified_artifact_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = root / "model.pth"
            artifact.write_bytes(b"fixture-model")
            record = root / "weights-record.json"
            record.write_text(json.dumps({
                "schema_version": 1,
                "weights_downloaded": True,
                "board_upload": False,
                "artifacts": [{"path": str(artifact), "bytes": 13, "sha256": "0" * 64}],
            }), encoding="utf-8")
            self.assertTrue(verifier.verify(record))


if __name__ == "__main__":
    unittest.main()
