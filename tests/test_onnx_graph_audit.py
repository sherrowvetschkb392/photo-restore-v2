import tempfile, unittest
from pathlib import Path
try:
    import onnx
    from onnx import TensorProto, helper
except ImportError:
    onnx = None
from tools import audit_onnx_graph as audit

@unittest.skipIf(onnx is None, "ONNX is installed only in the export environment")
class OnnxGraphAuditTests(unittest.TestCase):
    def test_static_safe_graph_passes(self):
        graph = helper.make_graph([helper.make_node("Identity", ["input"], ["output"])], "safe", [helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 3, 64, 64])], [helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 3, 64, 64])])
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "safe.onnx"; onnx.save(helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)]), path)
            self.assertEqual(audit.audit(path)["export_gate"], "READY_FOR_NUMERICAL_CHECK")

    def test_grid_sample_is_blocked(self):
        graph = helper.make_graph([helper.make_node("GridSample", ["input", "grid"], ["output"])], "risky", [helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 3, 8, 8]), helper.make_tensor_value_info("grid", TensorProto.FLOAT, [1, 8, 8, 2])], [helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 3, 8, 8])])
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "risky.onnx"; onnx.save(helper.make_model(graph, opset_imports=[helper.make_opsetid("", 16)]), path)
            self.assertEqual(audit.audit(path)["export_gate"], "BLOCKED_HIGH_RISK_OPS")
