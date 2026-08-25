#!/usr/bin/env python3
"""Comprehensive preflight for the x86_64 RKNN conversion environment."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import platform
import shutil
import subprocess
import sys
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path


EXPECTED_VERSIONS = {
    "rknn-toolkit2": "2.3.2",
    "numpy": "1.26.4",
    "onnx": "1.16.1",
    "protobuf": "4.25.4",
    "torch": "2.4.0",
}

REQUIRED_MODULES = (
    "pkg_resources",
    "numpy",
    "onnx",
    "onnxruntime",
    "cv2",
    "torch",
    "scipy",
    "ruamel.yaml",
    "rknn.api",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package_version(name: str) -> str:
    try:
        return version(name)
    except PackageNotFoundError:
        return "missing"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--onnx", type=Path, required=True)
    parser.add_argument("--target", default="rk3588")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    errors: list[str] = []
    report: dict[str, object] = {
        "python": sys.version.split()[0],
        "architecture": platform.machine(),
        "packages": {},
        "imports": {},
    }

    if sys.version_info[:2] != (3, 10):
        errors.append(f"expected Python 3.10, got {sys.version.split()[0]}")
    if platform.machine() != "x86_64":
        errors.append(f"expected x86_64, got {platform.machine()}")

    packages = report["packages"]
    assert isinstance(packages, dict)
    for name, expected in EXPECTED_VERSIONS.items():
        actual = package_version(name)
        packages[name] = actual
        if name == "torch":
            if not actual.startswith(expected):
                errors.append(f"{name}: expected {expected}.x, got {actual}")
        elif actual != expected:
            errors.append(f"{name}: expected {expected}, got {actual}")

    packages["setuptools"] = package_version("setuptools")
    packages["onnxruntime"] = package_version("onnxruntime")
    packages["opencv-python"] = package_version("opencv-python")

    imports = report["imports"]
    assert isinstance(imports, dict)
    for module_name in REQUIRED_MODULES:
        try:
            importlib.import_module(module_name)
        except Exception as exc:  # diagnostic boundary
            imports[module_name] = f"failed:{type(exc).__name__}:{exc}"
            errors.append(f"import {module_name} failed: {exc}")
        else:
            imports[module_name] = "ok"

    pip_check = subprocess.run(
        [sys.executable, "-m", "pip", "check"],
        capture_output=True,
        text=True,
        check=False,
    )
    report["pip_check"] = (pip_check.stdout + pip_check.stderr).strip()
    if pip_check.returncode != 0:
        errors.append("pip check failed")

    if not args.onnx.is_file():
        errors.append(f"ONNX model missing: {args.onnx}")
    else:
        import onnx

        report["onnx_mapping_api"] = hasattr(onnx, "mapping")
        if not hasattr(onnx, "mapping"):
            errors.append(
                "ONNX lacks onnx.mapping required by RKNN Toolkit2 2.3.2"
            )

        model = onnx.load(args.onnx)
        onnx.checker.check_model(model)
        input_shape = [
            dim.dim_value
            for dim in model.graph.input[0].type.tensor_type.shape.dim
        ]
        output_shape = [
            dim.dim_value
            for dim in model.graph.output[0].type.tensor_type.shape.dim
        ]
        report["onnx"] = {
            "path": str(args.onnx),
            "bytes": args.onnx.stat().st_size,
            "sha256": sha256(args.onnx),
            "input_shape": input_shape,
            "output_shape": output_shape,
            "nodes": len(model.graph.node),
            "op_types": sorted({node.op_type for node in model.graph.node}),
        }
        if input_shape != [1, 3, 64, 64]:
            errors.append(f"unexpected ONNX input shape: {input_shape}")
        if output_shape != [1, 3, 256, 256]:
            errors.append(f"unexpected ONNX output shape: {output_shape}")

    disk = shutil.disk_usage(Path.home())
    memory_available_kib = 0
    meminfo = Path("/proc/meminfo")
    if meminfo.is_file():
        for line in meminfo.read_text(encoding="utf-8").splitlines():
            if line.startswith("MemAvailable:"):
                memory_available_kib = int(line.split()[1])
                break
    report["resources"] = {
        "disk_free_gib": round(disk.free / 1024**3, 2),
        "memory_available_gib": round(memory_available_kib / 1024**2, 2),
    }
    if disk.free < 5 * 1024**3:
        errors.append("less than 5 GiB free in the WSL home filesystem")
    if memory_available_kib < 4 * 1024**2:
        errors.append("less than 4 GiB memory available")

    if imports.get("rknn.api") == "ok":
        from rknn.api import RKNN

        rknn = RKNN(verbose=False)
        try:
            result = rknn.config(
                target_platform=args.target,
                optimization_level=3,
            )
            report["rknn_config_result"] = result
            if result != 0:
                errors.append(f"RKNN config returned {result}")
        except Exception as exc:  # diagnostic boundary
            errors.append(f"RKNN initialization/config failed: {exc}")
        finally:
            rknn.release()

    rknn_spec = importlib.util.find_spec("rknn")
    missing_native: list[str] = []
    checked_native = 0
    if rknn_spec and rknn_spec.submodule_search_locations:
        for root in rknn_spec.submodule_search_locations:
            for library in Path(root).rglob("*.so"):
                checked_native += 1
                result = subprocess.run(
                    ["ldd", str(library)],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                for line in (result.stdout + result.stderr).splitlines():
                    if "not found" in line:
                        missing_native.append(f"{library}: {line.strip()}")
    report["native_libraries_checked"] = checked_native
    report["missing_native_libraries"] = missing_native
    if missing_native:
        errors.extend(missing_native)

    report["errors"] = errors
    print(json.dumps(report, indent=2, ensure_ascii=False))
    if errors:
        print("RESULT=FAIL_RKNN_PREFLIGHT")
        return 1

    print("RESULT=PASS_RKNN_PREFLIGHT")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
