import unittest

try:
    import torch
except ImportError:
    torch = None

if torch is not None:
    from tools.export_temporal_fusion_sr_onnx import TemporalFusionSrStudent


@unittest.skipIf(torch is None, "Torch is installed only in the WSL export environment")
class TemporalFusionSrExportTests(unittest.TestCase):
    def test_fixed_shape_contract(self):
        model = TemporalFusionSrStudent(frames=5, channels=8, blocks=1, scale=4).eval()
        output = model(torch.zeros(1, 5, 3, 16, 16))
        self.assertEqual(tuple(output.shape), (1, 3, 64, 64))

    def test_even_frame_count_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "odd"):
            TemporalFusionSrStudent(frames=4)


if __name__ == "__main__":
    unittest.main()
