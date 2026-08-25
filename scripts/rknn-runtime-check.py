#!/usr/bin/env python3
"""Read-only RKNNLite and board runtime diagnostic."""

from __future__ import annotations

import ctypes
import hashlib
import os
import platform
import re
import subprocess
import sys
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path


RUNTIME_PATH = Path(os.environ.get("RKNN_RUNTIME_LIBRARY", "/usr/lib/librknnrt.so"))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def runtime_version(path: Path) -> str:
    result = subprocess.run(
        ["strings", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    match = re.search(r"librknnrt version: ([^\n]+)", result.stdout)
    return match.group(1).strip() if match else "unknown"


def main() -> int:
    print("RKNN_RUNTIME_CHECK")
    print(f"python={sys.version.split()[0]}")
    print(f"architecture={platform.machine()}")

    try:
        lite_version = version("rknn-toolkit-lite2")
    except PackageNotFoundError:
        print("rknn_toolkit_lite2=missing")
        return 2

    print(f"rknn_toolkit_lite2={lite_version}")

    try:
        from rknnlite.api import RKNNLite  # pylint: disable=import-outside-toplevel
    except Exception as exc:  # diagnostic boundary
        print(f"rknnlite_import=failed:{type(exc).__name__}:{exc}")
        return 3

    print(f"rknnlite_import=ok:{RKNNLite.__module__}")

    if not RUNTIME_PATH.is_file():
        print(f"runtime_library=missing:{RUNTIME_PATH}")
        return 4

    print(f"runtime_library={RUNTIME_PATH}")
    print(f"runtime_version={runtime_version(RUNTIME_PATH)}")
    print(f"runtime_sha256={sha256(RUNTIME_PATH)}")

    try:
        ctypes.CDLL(str(RUNTIME_PATH))
    except OSError as exc:
        print(f"runtime_dlopen=failed:{exc}")
        return 5

    print("runtime_dlopen=ok")

    npu_device = Path("/dev/dri/renderD129")
    print(f"npu_device={npu_device}")
    print(f"npu_device_exists={str(npu_device.exists()).lower()}")
    print(f"npu_device_readable={str(os.access(npu_device, os.R_OK)).lower()}")
    print(f"npu_device_writable={str(os.access(npu_device, os.W_OK)).lower()}")
    print("model_inference=not_tested")
    print("RESULT=PASS_RUNTIME_ONLY")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

