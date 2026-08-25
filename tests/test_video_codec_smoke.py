import importlib.util
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1] / "apps" / "worker" / "video_codec_smoke.py"
SPEC = importlib.util.spec_from_file_location("video_codec_smoke", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class VideoCodecSmokeTests(unittest.TestCase):
    def sample_probe(self):
        return {
            "streams": [
                {
                    "codec_type": "video",
                    "codec_name": "h264",
                    "width": 640,
                    "height": 360,
                    "avg_frame_rate": "30/1",
                    "nb_read_frames": "300",
                    "pix_fmt": "yuv420p",
                },
                {
                    "codec_type": "audio",
                    "codec_name": "aac",
                    "sample_rate": "48000",
                },
            ],
            "format": {"duration": "10.000000", "format_name": "mov,mp4,m4a,3gp,3g2,mj2"},
        }

    def test_valid_probe_is_normalized(self):
        result = MODULE.validate_probe(self.sample_probe())
        self.assertEqual(result["decoded_frame_count"], 300)
        self.assertEqual(result["frame_rate"], 30.0)
        self.assertEqual(result["audio_codec"], "aac")

    def test_wrong_dimensions_are_rejected(self):
        probe = self.sample_probe()
        probe["streams"][0]["width"] = 1280
        with self.assertRaisesRegex(ValueError, "dimensions"):
            MODULE.validate_probe(probe)

    def test_missing_audio_is_rejected(self):
        probe = self.sample_probe()
        probe["streams"] = probe["streams"][:1]
        with self.assertRaisesRegex(ValueError, "audio stream"):
            MODULE.validate_probe(probe)

    def test_bad_frame_count_is_rejected(self):
        probe = self.sample_probe()
        probe["streams"][0]["nb_read_frames"] = "250"
        with self.assertRaisesRegex(ValueError, "frame count"):
            MODULE.validate_probe(probe)


if __name__ == "__main__":
    unittest.main()
