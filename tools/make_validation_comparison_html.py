#!/usr/bin/env python3
"""Build a zoomable, slider-based comparison page for validation outputs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    summary = json.loads(args.summary.read_text(encoding="utf-8"))
    assets = args.output.parent / "comparison-assets"
    assets.mkdir(parents=True, exist_ok=True)
    items = []
    for result in summary["results"]:
        name = result["input_name"]
        original = Image.open(args.raw_dir / name).convert("RGB")
        restored = Image.open(args.output_dir / result["output_name"]).convert("RGB")
        baseline = original.resize(restored.size, Image.Resampling.BICUBIC)
        crop_box = (round(restored.width * 0.2), round(restored.height * 0.2), round(restored.width * 0.8), round(restored.height * 0.8))
        baseline_crop = baseline.crop(crop_box)
        restored_crop = restored.crop(crop_box)
        stem = Path(name).stem
        baseline_path = assets / f"{stem}-baseline.jpg"
        restored_path = assets / f"{stem}-rknn.jpg"
        baseline_crop_path = assets / f"{stem}-baseline-crop.jpg"
        restored_crop_path = assets / f"{stem}-rknn-crop.jpg"
        baseline.save(baseline_path, quality=90, optimize=True)
        restored.save(restored_path, quality=92, optimize=True)
        baseline_crop.save(baseline_crop_path, quality=94, optimize=True)
        restored_crop.save(restored_crop_path, quality=94, optimize=True)
        items.append(
            {
                "name": name,
                "size": f"{original.width}×{original.height} → {restored.width}×{restored.height}",
                "tiles": result["tile_count"],
                "seconds": result["total_seconds"],
                "full_low": f"comparison-assets/{baseline_path.name}",
                "full_high": f"comparison-assets/{restored_path.name}",
                "detail_low": f"comparison-assets/{baseline_crop_path.name}",
                "detail_high": f"comparison-assets/{restored_crop_path.name}",
            }
        )

    payload = json.dumps(items, ensure_ascii=False, separators=(",", ":"), default=str)
    page = f'''<div id="validation-compare">
  <style>
    #validation-compare {{ color: var(--foreground); font-family: system-ui, sans-serif; }}
    #validation-compare .toolbar {{ display:flex; flex-wrap:wrap; gap:12px; align-items:center; margin-bottom:12px; }}
    #validation-compare select, #validation-compare input {{ font:inherit; }}
    #validation-compare select {{ min-width:180px; padding:6px 8px; }}
    #validation-compare .stage {{ position:relative; overflow:hidden; background:#111; min-height:240px; }}
    #validation-compare .stage img {{ display:block; width:100%; height:auto; image-rendering:auto; }}
    #validation-compare .stage .top {{ position:absolute; inset:0 auto 0 0; width:50%; overflow:hidden; }}
    #validation-compare .stage .top img {{ width:100%; max-width:none; }}
    #validation-compare .labels {{ display:flex; justify-content:space-between; font-size:12px; padding:4px 0 8px; }}
    #validation-compare .grid {{ display:grid; grid-template-columns: minmax(0, 1.3fr) minmax(0, 1fr); gap:16px; }}
    #validation-compare .panel h3 {{ margin:8px 0; font-size:15px; font-weight:500; }}
    #validation-compare .meta {{ color:var(--muted-foreground); font-size:13px; margin-bottom:8px; }}
    #validation-compare .hint {{ color:var(--muted-foreground); font-size:12px; }}
    @media (max-width: 700px) {{ #validation-compare .grid {{ grid-template-columns:1fr; }} }}
  </style>
  <div class="toolbar">
    <label>图片 <select id="vc-select" aria-label="选择验证图片"></select></label>
    <label>修复图覆盖 <input id="vc-range" type="range" min="0" max="100" value="50" aria-label="调整修复图覆盖比例"></label>
    <span id="vc-meta" class="meta"></span>
  </div>
  <div class="grid">
    <section class="panel"><h3>整图：原图浏览器放大 vs RKNN 修复</h3><div id="vc-full" class="stage"></div><div class="labels"><span>原图放大基线</span><span>RKNN 修复</span></div></section>
    <section class="panel"><h3>局部细节：可放大查看纹理</h3><div id="vc-detail" class="stage detail"></div><div class="labels"><span>原图放大基线</span><span>RKNN 修复</span></div></section>
  </div>
  <p class="hint">拖动滑块改变右侧修复图的覆盖范围；选择不同图片查看细节。左图不是原始低分辨率直接缩放，而是先用双三次插值放大到同一输出尺寸。</p>
  <script>
    (() => {{
      const data = {payload};
      const select = document.getElementById('vc-select');
      const range = document.getElementById('vc-range');
      const meta = document.getElementById('vc-meta');
      const full = document.getElementById('vc-full');
      const detail = document.getElementById('vc-detail');
      data.forEach((item, index) => {{ const option = document.createElement('option'); option.value = index; option.textContent = item.name; select.appendChild(option); }});
      function render() {{
        const item = data[Number(select.value)];
        const pct = Number(range.value);
        meta.textContent = `${{item.size}} · ${{item.tiles}} tiles · ${{item.seconds.toFixed(2)}} 秒`;
        full.innerHTML = `<img src="${{item.full_high}}" alt="${{item.name}} RKNN 修复"><div class="top" style="width:${{pct}}%"><img src="${{item.full_low}}" alt="${{item.name}} 原图放大基线"></div>`;
        detail.innerHTML = `<img src="${{item.detail_high}}" alt="${{item.name}} 中心细节 RKNN 修复"><div class="top" style="width:${{pct}}%"><img src="${{item.detail_low}}" alt="${{item.name}} 中心细节原图放大基线"></div>`;
      }}
      select.addEventListener('change', render); range.addEventListener('input', render); render();
    }})();
  </script>
</div>'''
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(page, encoding="utf-8")
    print(f"OUTPUT={args.output}")
    print("RESULT=PASS_VALIDATION_COMPARISON_HTML")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
