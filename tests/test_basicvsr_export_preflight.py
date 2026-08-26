import unittest

from tools import preflight_basicvsr_export as preflight


class BasicVsrExportPreflightTests(unittest.TestCase):
    def test_errors_fail_before_operator_gate(self):
        self.assertEqual(
            preflight.classify({"errors": ["bad artifact"], "operators": {}}),
            "FAIL_PREFLIGHT",
        )

    def test_missing_compiled_ops_is_explicit_blocker(self):
        self.assertEqual(
            preflight.classify({"errors": [], "operators": {"mmcv_compiled_ops_available": False}, "model": {"class_imported": True}}),
            "BLOCKED_MMCV_DEFORMABLE_OP",
        )

    def test_multiple_blockers_are_not_hidden(self):
        self.assertEqual(
            preflight.classify({"errors": [], "operators": {"mmcv_compiled_ops_available": False}, "model": {"class_imported": False}}),
            "BLOCKED_MODEL_IMPORT_AND_MMCV_DEFORMABLE_OP",
        )

    def test_ready_requires_compiled_ops_and_model_import(self):
        report = {
            "errors": [],
            "operators": {"mmcv_compiled_ops_available": True},
            "model": {"class_imported": True},
        }
        self.assertEqual(preflight.classify(report), "READY_FOR_FIXED_SHAPE_EXPORT_PROTOTYPE")


if __name__ == "__main__":
    unittest.main()
