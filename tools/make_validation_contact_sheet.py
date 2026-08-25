#!/usr/bin/env python3
"""Create a compact visual review sheet for a validation dataset."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    summary = json.loads(args.summary.read_text(encoding="utf-8"))
    results = summary.get("results", [])
    if not results:
        raise ValueError("summary contains no results")
    cell_w, cell_h = 560, 390
    cols = 2
    rows = (len(results) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell_w, rows * cell_h), "#20242b")
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("arial.ttf", 18)
    except OSError:
        font = ImageFont.load_default()

    for index, result in enumerate(results):
        x = (index % cols) * cell_w
        y = (index // cols) * cell_h
        name = result["input_name"]
        raw = Image.open(args.raw_dir / name).convert("RGB")
        restored = Image.open(args.output_dir / result["output_name"]).convert("RGB")
        draw.rectangle((x + 8, y + 8, x + cell_w - 8, y + cell_h - 8), outline="#6f7782", width=2)
        draw.text((x + 18, y + 16), f"{name}   {result['input_size']} → {result['output_size']}", fill="white", font=font)
        for image, offset in ((raw, 18), (restored, 286)):
            preview = image.copy()
            preview.thumbnail((250, 300), Image.Resampling.LANCZOS)
            px = x + offset + (250 - preview.width) // 2
            py = y + 55 + (300 - preview.height) // 2
            sheet.paste(preview, (px, py))
        draw.text((x + 18, y + cell_h - 34), f"tiles={result['tile_count']}  total={result['total_seconds']:.2f}s", fill="#c9d1d9", font=font)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(args.output, quality=92, optimize=True)
    print(f"OUTPUT={args.output}")
    print(f"SIZE={sheet.width}x{sheet.height}")
    print("RESULT=PASS_VALIDATION_CONTACT_SHEET")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
