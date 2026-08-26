#!/usr/bin/env python3
"""Preflight BasicVSR++ checkpoint loading and fixed-shape export risks.

This tool is deliberately read-only.  It does not export ONNX, install native
operators, upload files, or touch the RK3588.  Its job is to separate ordinary
checkpoint/package problems from the compiled deformable-alignment operator
gate before an export implementation is attempted.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import inspect
import json
import platform
from pathlib import Path
from typing import Any

from packaging.requirements import Requirement


EXPECTED_HASHES = {
    "basicvsr_plusplus_x4.pth": "db622b2fd4caae0a4c63ab5e54f1cfef7a62a0f3b8ad101aba2eae068d928549",
    "spynet.pth": "c6c1bd09b52d05ba17f3e701f549d6faf5e314aabce8ae462c1c171a8d6c4914",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package_version(name: str) -> str | None:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return None


def missing_declared_dependencies(distribution: str) -> list[str]:
    missing: list[str] = []
    for declaration in importlib.metadata.requires(distribution) or []:
        requirement = Requirement(declaration)
        if requirement.marker is not None and not requirement.marker.evaluate():
            continue
        if package_version(requirement.name) is None:
            missing.append(requirement.name)
    return sorted(set(missing), key=str.lower)


def extract_state_dict(checkpoint: Any) -> tuple[dict[str, Any], str]:
    if not isinstance(checkpoint, dict):
        raise TypeError(f"checkpoint root must be a dict, got {type(checkpoint).__name__}")
    for key in ("state_dict", "params_ema", "params"):
        value = checkpoint.get(key)
        if isinstance(value, dict) and value:
            return value, key
    if checkpoint and all(isinstance(key, str) for key in checkpoint):
        tensor_like = sum(hasattr(value, "shape") for value in checkpoint.values())
        if tensor_like:
            return checkpoint, "root"
    raise ValueError("checkpoint does not contain a recognized non-empty state dict")


def summarize_keys(state_dict: dict[str, Any]) -> dict[str, Any]:
    keys = sorted(state_dict)
    prefixes: dict[str, int] = {}
    tensor_count = 0
    parameter_count = 0
    for key, value in state_dict.items():
        prefix = key.split(".", 1)[0]
        prefixes[prefix] = prefixes.get(prefix, 0) + 1
        if hasattr(value, "shape"):
            tensor_count += 1
            try:
                parameter_count += int(value.numel())
            except (AttributeError, TypeError):
                pass
    return {
        "key_count": len(keys),
        "tensor_count": tensor_count,
        "parameter_count": parameter_count,
        "top_level_prefixes": dict(sorted(prefixes.items())),
        "first_keys": keys[:12],
    }


def classify(report: dict[str, Any]) -> str:
    if report.get("errors"):
        return "FAIL_PREFLIGHT"
    model = report.get("model", {})
    operators = report.get("operators", {})
    if not model.get("class_imported") and not operators.get("mmcv_compiled_ops_available"):
        return "BLOCKED_MODEL_IMPORT_AND_MMCV_DEFORMABLE_OP"
    if not model.get("class_imported"):
        return "BLOCKED_MODEL_IMPORT"
    if not operators.get("mmcv_compiled_ops_available"):
        return "BLOCKED_MMCV_DEFORMABLE_OP"
    return "READY_FOR_FIXED_SHAPE_EXPORT_PROTOTYPE"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", required=True, type=Path)
    parser.add_argument("--spynet", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--frames", type=int, default=5)
    parser.add_argument("--height", type=int, default=64)
    parser.add_argument("--width", type=int, default=64)
    args = parser.parse_args()

    errors: list[str] = []
    if args.frames < 2 or args.height <= 0 or args.width <= 0:
        errors.append("frames must be >= 2 and spatial dimensions must be positive")
    if args.height % 16 or args.width % 16:
        errors.append("height and width must be divisible by 16")

    report: dict[str, Any] = {
        "schema_version": 1,
        "candidate": "BasicVSR++",
        "purpose": "read_only_fixed_shape_export_preflight",
        "board_upload": False,
        "platform": {
            "python": platform.python_version(),
            "architecture": platform.machine(),
            "packages": {
                name: package_version(name)
                for name in (
                    "torch", "torchvision", "numpy", "onnx", "onnxruntime",
                    "mmcv-lite", "mmengine", "mmagic"
                )
            },
        },
        "contract": {
            "input_shape": [1, args.frames, 3, args.height, args.width],
            "output_shape": [1, args.frames, 3, args.height * 4, args.width * 4],
            "dtype": "float32",
            "range": [0.0, 1.0],
            "fixed_shape": True,
        },
        "artifacts": [],
        "checkpoint": {},
        "declared_dependencies": {},
        "operators": {},
        "model": {},
        "errors": errors,
    }

    try:
        report["declared_dependencies"] = {
            "mmagic_missing": missing_declared_dependencies("mmagic"),
            "mmengine_missing": missing_declared_dependencies("mmengine"),
            "mmcv_lite_missing": missing_declared_dependencies("mmcv-lite"),
        }
    except Exception as exc:
        report["declared_dependencies"] = {"error": f"{type(exc).__name__}: {exc}"}

    for path in (args.weights.resolve(), args.spynet.resolve()):
        item: dict[str, Any] = {"path": str(path), "exists": path.is_file()}
        if path.is_file():
            item["bytes"] = path.stat().st_size
            item["sha256"] = sha256(path)
            expected = EXPECTED_HASHES.get(path.name)
            item["expected_sha256"] = expected
            item["sha256_verified"] = expected is None or item["sha256"] == expected
            if not item["sha256_verified"]:
                errors.append(f"SHA-256 mismatch: {path}")
        else:
            errors.append(f"artifact missing: {path}")
        report["artifacts"].append(item)

    try:
        import torch

        checkpoint = torch.load(args.weights.resolve(), map_location="cpu", weights_only=True)
        state_dict, source = extract_state_dict(checkpoint)
        report["checkpoint"] = {"loaded": True, "state_dict_source": source, **summarize_keys(state_dict)}
    except Exception as exc:  # recorded in the report for reproducible diagnosis
        report["checkpoint"] = {"loaded": False, "error": f"{type(exc).__name__}: {exc}"}
        errors.append("checkpoint_load_failed")

    try:
        import mmcv.ops  # noqa: F401
        from mmcv.ops import ModulatedDeformConv2d  # noqa: F401

        report["operators"]["mmcv_compiled_ops_available"] = True
    except Exception as exc:
        report["operators"]["mmcv_compiled_ops_available"] = False
        report["operators"]["mmcv_compiled_ops_error"] = f"{type(exc).__name__}: {exc}"

    try:
        from torchvision.ops import deform_conv2d

        report["operators"]["torchvision_deform_conv2d_imported"] = callable(deform_conv2d)
    except Exception as exc:
        report["operators"]["torchvision_deform_conv2d_imported"] = False
        report["operators"]["torchvision_deform_conv2d_error"] = f"{type(exc).__name__}: {exc}"

    try:
        from mmagic.models.editors.basicvsr_plusplus import BasicVSRPlusPlusNet

        report["model"] = {
            "class_imported": True,
            "class": f"{BasicVSRPlusPlusNet.__module__}.{BasicVSRPlusPlusNet.__name__}",
            "constructor_signature": str(inspect.signature(BasicVSRPlusPlusNet)),
        }
    except Exception as exc:
        report["model"] = {
            "class_imported": False,
            "error": f"{type(exc).__name__}: {exc}",
        }

    report["export_gate"] = classify(report)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, allow_nan=False), encoding="utf-8")
    print(json.dumps(report, indent=2, allow_nan=False))
    print(f"RESULT={report['export_gate']}_BASICVSR_EXPORT_PREFLIGHT")
    if report["export_gate"] == "FAIL_PREFLIGHT":
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
