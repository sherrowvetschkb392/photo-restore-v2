#!/usr/bin/env python3
"""Verify board-side Python dependencies used by the image worker."""

from __future__ import annotations

import argparse
import json
import platform
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pillow-only", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.pillow_only:
        try:
            import PIL
        except ModuleNotFoundError:
            print("Pillow=missing")
            return 10
        print(f"Pillow={PIL.__version__}")
        print("RESULT=PASS_BOARD_PILLOW")
        return 0

    import numpy
    import PIL
    from rknnlite.api import RKNNLite

    result = {
        "python": platform.python_version(),
        "architecture": platform.machine(),
        "numpy": numpy.__version__,
        "Pillow": PIL.__version__,
        "rknnlite_import": RKNNLite.__module__,
        "executable": sys.executable,
    }
    print(json.dumps(result, indent=2))
    print("RESULT=PASS_BOARD_IMAGE_RUNTIME")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
