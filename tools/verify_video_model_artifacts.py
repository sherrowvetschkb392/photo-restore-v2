#!/usr/bin/env python3
"""Verify downloaded video model artifacts against their recorded metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(record_path: Path) -> list[str]:
    record = json.loads(record_path.read_text(encoding="utf-8-sig"))
    errors: list[str] = []
    if record.get("schema_version") != 1:
        errors.append("unsupported schema_version")
    if record.get("weights_downloaded") is not True:
        errors.append("record does not declare weights_downloaded=true")
    if record.get("board_upload") is not False:
        errors.append("record must declare board_upload=false")
    for item in record.get("artifacts", []):
        path = Path(item["path"])
        if not path.is_file():
            errors.append(f"missing artifact: {path}")
            continue
        actual_bytes = path.stat().st_size
        if actual_bytes != int(item["bytes"]):
            errors.append(f"size mismatch for {path}: {actual_bytes} != {item['bytes']}")
        actual_hash = sha256(path)
        if actual_hash != item["sha256"]:
            errors.append(f"sha256 mismatch for {path}: {actual_hash} != {item['sha256']}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("record", type=Path)
    args = parser.parse_args()
    errors = verify(args.record.resolve())
    if errors:
        for error in errors:
            print(f"[ERROR] {error}")
        print("RESULT=FAIL_VIDEO_MODEL_ARTIFACT_VERIFY")
        return 2
    record = json.loads(args.record.read_text(encoding="utf-8-sig"))
    print(f"Candidate: {record['candidate']}")
    print(f"Artifacts: {len(record['artifacts'])}")
    print("Weights: verified")
    print("Board upload: False")
    print("RESULT=PASS_VIDEO_MODEL_ARTIFACT_VERIFY")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
