#!/usr/bin/env python3
"""Audit an ONNX graph for fixed-shape RKNN export risks."""
from __future__ import annotations
import argparse, hashlib, json
from pathlib import Path
try:
    import onnx
except ImportError:  # export environment provides ONNX
    onnx = None

HIGH_RISK_OPS = {"GridSample", "DeformConv", "DeformableConv", "Loop", "If", "Scan", "NonZero", "RoiAlign"}

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""): digest.update(chunk)
    return digest.hexdigest()

def shape(value_info: onnx.ValueInfoProto) -> list[int | str]:
    result = []
    for dim in value_info.type.tensor_type.shape.dim:
        result.append(int(dim.dim_value) if dim.dim_value else (dim.dim_param or "dynamic"))
    return result

def audit(path: Path) -> dict[str, object]:
    if onnx is None:
        raise RuntimeError("onnx package is required for graph auditing")
    model = onnx.load(path); onnx.checker.check_model(model)
    ops = sorted({node.op_type for node in model.graph.node})
    risky = sorted(set(ops) & HIGH_RISK_OPS)
    inputs = [{"name": item.name, "shape": shape(item)} for item in model.graph.input]
    outputs = [{"name": item.name, "shape": shape(item)} for item in model.graph.output]
    dynamic = any(isinstance(d, str) for item in inputs + outputs for d in item["shape"])
    return {"schema_version": 1, "onnx": str(path.resolve()), "bytes": path.stat().st_size, "sha256": sha256(path), "ir_version": model.ir_version, "opset_imports": [{"domain": x.domain, "version": x.version} for x in model.opset_import], "node_count": len(model.graph.node), "inputs": inputs, "outputs": outputs, "op_types": ops, "high_risk_ops": risky, "has_dynamic_io": dynamic, "export_gate": "BLOCKED_HIGH_RISK_OPS" if risky else ("BLOCKED_DYNAMIC_IO" if dynamic else "READY_FOR_NUMERICAL_CHECK")}

def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("onnx", type=Path); parser.add_argument("--report", type=Path); args = parser.parse_args()
    try: report = audit(args.onnx.resolve())
    except Exception as exc: print(f"RESULT=FAIL_ONNX_GRAPH_AUDIT: {type(exc).__name__}: {exc}"); return 2
    if args.report: args.report.parent.mkdir(parents=True, exist_ok=True); args.report.write_text(json.dumps(report, indent=2, allow_nan=False), encoding="utf-8")
    print(json.dumps(report, indent=2, allow_nan=False))
    if report["high_risk_ops"] or report["has_dynamic_io"]: print(f"RESULT=BLOCK_ONNX_GRAPH_AUDIT:{report['export_gate']}"); return 2
    print("RESULT=PASS_ONNX_GRAPH_AUDIT"); return 0

if __name__ == "__main__": raise SystemExit(main())
