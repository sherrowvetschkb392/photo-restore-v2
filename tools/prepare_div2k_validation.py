#!/usr/bin/env python3
"""Select and isolate a small representative DIV2K x4 validation subset."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageStat


CANDIDATES = (
    "0810x4.png",
    "0846x4.png",
    "0852x4.png",
    "0855x4.png",
    "0863x4.png",
    "0868x4.png",
    "0880x4.png",
    "0894x4.png",
)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zip", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--review-sheet", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    raw_dir = args.dataset_root / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    args.review_sheet.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(args.zip) as archive:
        entries = {
            Path(name).name: name
            for name in archive.namelist()
            if name.lower().endswith(".png")
        }
        missing = sorted(set(CANDIDATES) - set(entries))
        if missing:
            raise RuntimeError(f"archive is missing candidates: {missing}")

        cards: list[tuple[str, Image.Image, tuple[int, int], float, float]] = []
        manifest_items: list[dict[str, object]] = []
        for filename in CANDIDATES:
            data = archive.read(entries[filename])
            image = Image.open(io.BytesIO(data)).convert("RGB")
            thumbnail = image.copy()
            thumbnail.thumbnail((240, 180), Image.Resampling.LANCZOS)
            stat_image = image.copy()
            stat_image.thumbnail((128, 128), Image.Resampling.BILINEAR)
            stat = ImageStat.Stat(stat_image)
            mean = float(np.mean(stat.mean))
            contrast = float(np.mean(stat.stddev))
            cards.append((filename, thumbnail, image.size, mean, contrast))

            output = raw_dir / filename
            output.write_bytes(data)
            manifest_items.append(
                {
                    "filename": filename,
                    "source_page_url": "https://data.vision.ee.ethz.ch/cvl/DIV2K/",
                    "asset_url": "https://data.vision.ee.ethz.ch/cvl/DIV2K/DIV2K_valid_LR_bicubic_X4.zip",
                    "creator": "DIV2K dataset contributors; individual image attribution is not included in the archive",
                    "license": "Upstream archive does not include a license file; retained locally for research validation only and not redistributed",
                    "license_url": "https://data.vision.ee.ethz.ch/cvl/DIV2K/",
                    "sha256": sha256_bytes(data),
                    "notes": f"LR bicubic x4 validation image; size={image.width}x{image.height}; mean={mean:.2f}; contrast={contrast:.2f}",
                }
            )

    cell_width, cell_height = 280, 230
    sheet = Image.new("RGB", (cell_width * 2, cell_height * 4), "#202124")
    draw = ImageDraw.Draw(sheet)
    for index, (filename, thumbnail, size, mean, contrast) in enumerate(cards):
        column = index % 2
        row = index // 2
        left = column * cell_width
        top = row * cell_height
        image_left = left + (cell_width - thumbnail.width) // 2
        sheet.paste(thumbnail, (image_left, top + 8))
        draw.text(
            (left + 8, top + 192),
            f"{filename}  {size[0]}x{size[1]}\nmean={mean:.1f} contrast={contrast:.1f}",
            fill="white",
        )
    sheet.save(args.review_sheet, format="JPEG", quality=92)

    manifest = {
        "dataset": "div2k-x4-sample",
        "retrieved_at_utc": datetime.now(timezone.utc).isoformat(),
        "description": (
            "Eight representative LR bicubic x4 images selected from the official "
            "DIV2K validation archive for local RK3588 engineering validation."
        ),
        "archive": {
            "filename": args.zip.name,
            "sha256": sha256_file(args.zip),
            "bytes": args.zip.stat().st_size,
        },
        "items": manifest_items,
    }
    args.manifest.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(f"ARCHIVE_SHA256={manifest['archive']['sha256']}")
    print(f"RAW_DIRECTORY={raw_dir}")
    print(f"MANIFEST={args.manifest}")
    print(f"REVIEW_SHEET={args.review_sheet}")
    print(f"IMAGE_COUNT={len(manifest_items)}")
    print("RESULT=PASS_DIV2K_VALIDATION_PREPARE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
