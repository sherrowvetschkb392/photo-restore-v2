#!/usr/bin/env python3
"""Validate the pre-download video model candidate manifest."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from urllib.parse import urlparse


REQUIRED_DECISION_KEYS = {
    "spatial_quality_primary",
    "spatial_quality_backup",
    "interpolation_primary",
    "interpolation_backup",
    "download_authorized",
}
REQUIRED_CANDIDATE_KEYS = {
    "name",
    "family",
    "role",
    "source_url",
    "license_status",
    "temporal_window",
    "spatial_scale",
    "rknn_risks",
}
ALLOWED_FAMILIES = {"interpolation", "video_super_resolution"}
# pre_download_review: nothing downloaded yet. Later statuses record which
# models have been verified and deployed on the board.
ALLOWED_STATUSES = {
    "pre_download_review",
    "cain_interpolation_implemented",
    "video_enhancement_deployed",
}


def validate(manifest: dict[str, object]) -> list[str]:
    errors: list[str] = []
    if manifest.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    status = manifest.get("status")
    if status not in ALLOWED_STATUSES:
        errors.append(f"status must be one of {sorted(ALLOWED_STATUSES)}")
    decision = manifest.get("decision")
    if not isinstance(decision, dict):
        errors.append("decision must be an object")
        decision = {}
    missing = REQUIRED_DECISION_KEYS - set(decision)
    errors.extend(f"decision missing {key}" for key in sorted(missing))
    if status == "pre_download_review" and decision.get("download_authorized") is not False:
        errors.append("download_authorized must be false in the pre-download manifest")
    candidates = manifest.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        errors.append("candidates must be a non-empty list")
        return errors
    names: set[str] = set()
    by_family: dict[str, list[str]] = {}
    for index, candidate in enumerate(candidates):
        prefix = f"candidates[{index}]"
        if not isinstance(candidate, dict):
            errors.append(f"{prefix} must be an object")
            continue
        missing = REQUIRED_CANDIDATE_KEYS - set(candidate)
        errors.extend(f"{prefix} missing {key}" for key in sorted(missing))
        name = candidate.get("name")
        if not isinstance(name, str) or not name.strip():
            errors.append(f"{prefix}.name must be non-empty")
            continue
        if name in names:
            errors.append(f"duplicate candidate name: {name}")
        names.add(name)
        family = candidate.get("family")
        if family not in ALLOWED_FAMILIES:
            errors.append(f"{prefix}.family is unsupported: {family}")
        else:
            by_family.setdefault(str(family), []).append(name)
        source_url = candidate.get("source_url")
        parsed = urlparse(source_url) if isinstance(source_url, str) else None
        if parsed is None or parsed.scheme != "https" or not parsed.netloc:
            errors.append(f"{prefix}.source_url must be an HTTPS URL")
        risks = candidate.get("rknn_risks")
        # Candidates that already carry pinned RKNN hashes have passed the
        # operator-risk review, so an empty risk list is legitimate for them.
        if not isinstance(risks, list) or (not risks and "rknn_sha256" not in candidate):
            errors.append(f"{prefix}.rknn_risks must be a non-empty list")
    for key in ("spatial_quality_primary", "interpolation_primary"):
        if decision.get(key) not in names:
            errors.append(f"decision.{key} must reference a candidate")
    for key in ("spatial_quality_backup", "interpolation_backup"):
        values = decision.get(key)
        if not isinstance(values, list) or not values:
            errors.append(f"decision.{key} must be a non-empty list")
        else:
            errors.extend(f"decision.{key} references unknown candidate: {name}" for name in values if name not in names)
    if decision.get("spatial_quality_primary") in by_family.get("interpolation", []):
        errors.append("spatial quality primary must be video_super_resolution")
    if decision.get("interpolation_primary") in by_family.get("video_super_resolution", []):
        errors.append("interpolation primary must be interpolation")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"RESULT=FAIL_VIDEO_MODEL_MANIFEST: {exc}")
        return 2
    errors = validate(manifest)
    if errors:
        for error in errors:
            print(f"[ERROR] {error}")
        print("RESULT=FAIL_VIDEO_MODEL_MANIFEST")
        return 2
    print(f"Candidates: {len(manifest['candidates'])}")
    print(f"Spatial primary: {manifest['decision']['spatial_quality_primary']}")
    print(f"Interpolation primary: {manifest['decision']['interpolation_primary']}")
    print(f"Downloads authorized: {manifest['decision']['download_authorized']}")
    print("RESULT=PASS_VIDEO_MODEL_MANIFEST")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
