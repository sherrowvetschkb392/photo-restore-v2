#!/usr/bin/env python3
"""Offline video pipeline worker for RK3588 (CAIN interpolation + SRVGG SR).

Modes:
- interpolate: 2x frame rate with CAIN on the NPU, original resolution;
- upscale: 4x spatial super-resolution with SRVGG (RealESRGAN General x4v3),
  original frame rate;
- restore: upscale x4, downscale to 2x (oversampled quality), then 2x
  interpolation at the 2x resolution. Input is capped to 640x360 so the
  interpolation stage can use the measured full-frame 720p model.

Shared rules (see docs/video-development.md):
- exact 640x360 / 1280x720 interpolation inputs use full-frame CAIN models;
  other sizes use 256x256 tiles with 32 px linear-blend overlap;
- SRVGG contains no global-statistics ops, so tiled 256x256 -> 1024x1024 with
  24 px linear-blend overlap is exact apart from border context;
- scene cuts bypass interpolation (hold previous frame);
- near-static pairs bypass interpolation (copy previous frame);
- muxing trims both streams to the exact video length (never "-shortest");
- writes progress.json during the run and an atomic report.json at the end;
- never touches the photo API storage or other production paths.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import signal
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from fractions import Fraction
from pathlib import Path
from typing import Any

import numpy as np

TILE = 256
INTERP_OVERLAP = 32
SR_OVERLAP = 24
SR_SCALE = 4
SCENE_CUT_THRESHOLD = 0.18
STATIC_THRESHOLD = 0.002
INTERP_FULLFRAME = {(360, 640): "cain-interp-1x3x360x640-fp16.rknn",
                    (720, 1280): "cain-interp-1x3x720x1280-fp16.rknn"}
INTERP_TILE_MODEL = "cain-interp-1x3x256x256-fp16.rknn"
SR_TILE_MODEL = "srvgg-general-x4v3-1x3x256x256-fp16.rknn"
SR_TILE_OUT = TILE * SR_SCALE
MAX_INTERP_WIDTH = 1920
MAX_INTERP_HEIGHT = 1080
# upscale: 4x output must stay inside the measured H.264 encoder range
MAX_UPSCALE_INPUT = (540, 960)   # -> 2160x3840 output
# restore: interpolation runs on the 2x image; keep it at/below 1280x720
MAX_RESTORE_INPUT = (360, 640)   # -> 720x1280 interpolation stage


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_rate(value: str | None) -> float:
    if not value or value in {"0/0", "N/A"}:
        return 0.0
    try:
        return float(Fraction(value))
    except (ValueError, ZeroDivisionError):
        return 0.0


def run_json(command: list[str], timeout: int = 60) -> dict[str, Any]:
    completed = subprocess.run(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        timeout=timeout, check=False,
        env={**os.environ, "LC_ALL": "C", "LANG": "C"},
    )
    if completed.returncode != 0:
        raise RuntimeError(f"{command[0]} failed: {completed.stderr.strip()[:400]}")
    return json.loads(completed.stdout)


def ffprobe(path: Path, count_frames: bool = False) -> dict[str, Any]:
    command = ["ffprobe", "-v", "error"]
    if count_frames:
        command.append("-count_frames")
    command += ["-show_streams", "-show_format", "-of", "json", str(path)]
    return run_json(command)


def probe_input(path: Path) -> dict[str, Any]:
    probe = ffprobe(path)
    video = [s for s in probe.get("streams", []) if s.get("codec_type") == "video"]
    audio = [s for s in probe.get("streams", []) if s.get("codec_type") == "audio"]
    if len(video) != 1:
        raise ValueError(f"expected exactly one video stream, found {len(video)}")
    v = video[0]
    width, height = int(v["width"]), int(v["height"])
    avg = parse_rate(v.get("avg_frame_rate"))
    real = parse_rate(v.get("r_frame_rate"))
    fps = avg or real
    if fps <= 0 or fps > 120:
        raise ValueError(f"unsupported frame rate: {v.get('avg_frame_rate')!r}")
    vfr = abs(avg - real) / max(avg, real, 1e-9) > 0.01 if avg and real else False
    duration = float((probe.get("format") or {}).get("duration") or 0.0)
    return {
        "width": width, "height": height, "fps": fps, "vfr": vfr,
        "duration_seconds": duration,
        "video_codec": v.get("codec_name"),
        "audio_codec": audio[0].get("codec_name") if audio else None,
        "audio_stream": bool(audio),
    }


class RknnModel:
    """Lazy RKNNLite wrapper around one fixed-shape model."""

    def __init__(self, model_dir: Path, name: str):
        from rknnlite.api import RKNNLite  # deferred: importable without NPU
        self._rknn = RKNNLite()
        if self._rknn.load_rknn(str(model_dir / name)) != 0:
            raise RuntimeError(f"failed to load {name}")
        if self._rknn.init_runtime() != 0:
            raise RuntimeError(f"failed to init runtime for {name}")
        self.name = name
        self.inferences = 0

    def infer_nchw(self, *inputs: np.ndarray) -> list[np.ndarray]:
        out = self._rknn.inference(inputs=list(inputs),
                                   data_format=["nchw"] * len(inputs))
        self.inferences += 1
        return out

    def close(self) -> None:
        self._rknn.release()


def blend_mask(size: int, overlap: int) -> np.ndarray:
    """1xSIZExSIZE linear ramp mask that sums to 1 across tile overlaps."""
    w = np.ones(size, dtype=np.float32)
    ramp = np.linspace(0.0, 1.0, overlap + 2, dtype=np.float32)[1:-1]
    w[:overlap] = np.minimum(w[:overlap], ramp)
    w[-overlap:] = np.minimum(w[-overlap:], ramp[::-1])
    return (w[:, None] * w[None, :])[None, :, :]


def tile_origins(length: int, tile: int, overlap: int) -> list[int]:
    stride = tile - overlap
    origins = list(range(0, max(length - tile, 0) + 1, stride))
    if not origins or origins[-1] != length - tile:
        origins.append(max(length - tile, 0))
    return origins


def run_tiled(model: RknnModel, inputs: list[np.ndarray], out_hw: tuple[int, int],
              tile: int, overlap: int, scale: int) -> np.ndarray:
    """Generic fixed-shape tiled inference with linear-blend overlap.

    inputs: list of float32 NCHW tiles-sized frames cropped from the same
    reflect-padded canvas; returns the blended HWC float32 output in [0,1].
    The caller pads/crops. inputs are full frames (1,C,H,W), not tiles.
    """
    _, _, hp, wp = inputs[0].shape
    oh, ow = hp * scale, wp * scale
    acc = np.zeros((oh, ow, 3), dtype=np.float32)
    wsum = np.zeros((oh, ow, 1), dtype=np.float32)
    mask = blend_mask(tile * scale, overlap * scale).transpose(1, 2, 0)
    for y in tile_origins(hp, tile, overlap):
        for x in tile_origins(wp, tile, overlap):
            tiles = [f[:, :, y:y + tile, x:x + tile].astype(np.float32)
                     for f in inputs]
            out = model.infer_nchw(*tiles)[0][0].transpose(1, 2, 0)
            acc[y * scale:y * scale + tile * scale,
                x * scale:x * scale + tile * scale] += out * mask
            wsum[y * scale:y * scale + tile * scale,
                 x * scale:x * scale + tile * scale] += mask
    return np.clip(acc / np.maximum(wsum, 1e-6), 0.0, 1.0)[:oh, :ow]


def pad_reflect(frame: np.ndarray, tile: int, overlap: int) -> np.ndarray:
    """Pad an HWC uint8 frame so width/height are covered by the tile grid."""
    h, w = frame.shape[:2]
    stride = tile - overlap
    pad_h = (stride - h % stride) % stride + overlap
    pad_w = (stride - w % stride) % stride + overlap
    if h < tile:
        pad_h = max(pad_h, tile - h)
    if w < tile:
        pad_w = max(pad_w, tile - w)
    return np.pad(frame, ((0, pad_h), (0, pad_w), (0, 0)), mode="reflect")


class Pipeline:
    def __init__(self, model_dir: Path, width: int, height: int, mode: str):
        self.model_dir = model_dir
        self.mode = mode
        self._models: dict[str, RknnModel] = {}
        # interpolation geometry operates on the (possibly upscaled) frames
        interp_scale = 2 if mode == "restore" else 1
        self.iw, self.ih = width * interp_scale, height * interp_scale
        self.interp_fullframe = INTERP_FULLFRAME.get((self.ih, self.iw))

    def _load(self, name: str) -> RknnModel:
        if name not in self._models:
            self._models[name] = RknnModel(self.model_dir, name)
        return self._models[name]

    # ---- spatial SR -----------------------------------------------------
    def upscale_frame(self, frame: np.ndarray) -> np.ndarray:
        """uint8 HWC -> uint8 HWC at 4x resolution."""
        padded = pad_reflect(frame, TILE, SR_OVERLAP)
        x = padded.transpose(2, 0, 1)[None].astype(np.float32) / 255.0
        model = self._load(SR_TILE_MODEL)
        out = run_tiled(model, [x], (0, 0), TILE, SR_OVERLAP, SR_SCALE)
        h, w = frame.shape[:2]
        hr = np.clip(np.rint(out * 255.0), 0, 255).astype(np.uint8)
        return hr[:h * SR_SCALE, :w * SR_SCALE]

    # ---- temporal interpolation ------------------------------------------
    def midpoint(self, frame0: np.ndarray, frame1: np.ndarray) -> np.ndarray:
        """uint8 HWC pair at the interpolation geometry -> uint8 HWC mid."""
        if self.interp_fullframe:
            model = self._load(self.interp_fullframe)
            f0 = frame0.transpose(2, 0, 1)[None].astype(np.float32) / 255.0
            f1 = frame1.transpose(2, 0, 1)[None].astype(np.float32) / 255.0
            out = np.clip(model.infer_nchw(f0, f1)[0][0].transpose(1, 2, 0), 0, 1)
            return np.clip(np.rint(out * 255.0), 0, 255).astype(np.uint8)
        p0 = pad_reflect(frame0, TILE, INTERP_OVERLAP)
        p1 = pad_reflect(frame1, TILE, INTERP_OVERLAP)
        f0 = p0.transpose(2, 0, 1)[None].astype(np.float32) / 255.0
        f1 = p1.transpose(2, 0, 1)[None].astype(np.float32) / 255.0
        model = self._load(INTERP_TILE_MODEL)
        out = run_tiled(model, [f0, f1], (0, 0), TILE, INTERP_OVERLAP, 1)
        h, w = frame0.shape[:2]
        return np.clip(np.rint(out[:h, :w] * 255.0), 0, 255).astype(np.uint8)

    def close(self) -> None:
        for model in self._models.values():
            model.close()
        self._models.clear()

    @property
    def inference_count(self) -> int:
        return sum(m.inferences for m in self._models.values())

    @property
    def used_models(self) -> list[str]:
        return sorted(self._models)


def downscale_half(frame: np.ndarray) -> np.ndarray:
    """High-quality 2x downscale of an HWC uint8 frame (LANCZOS)."""
    from PIL import Image
    h, w = frame.shape[:2]
    image = Image.fromarray(frame)
    return np.asarray(
        image.resize((w // 2, h // 2), Image.Resampling.LANCZOS),
        dtype=np.uint8)


def luma_sample(frame: np.ndarray) -> np.ndarray:
    small = frame[::8, ::8].astype(np.float32) / 255.0
    return (0.299 * small[..., 0] + 0.587 * small[..., 1]
            + 0.114 * small[..., 2])


def start_decoder(input_path: Path, fps: float, log: Path) -> subprocess.Popen:
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-i", str(input_path),
        "-vf", f"fps={fps}",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
    ]
    log_handle = log.open("wb")
    return subprocess.Popen(command, stdout=subprocess.PIPE, stderr=log_handle,
                            env={**os.environ, "LC_ALL": "C", "LANG": "C"})


def start_encoder(output_h264: Path, fps_out: float, width: int, height: int,
                  bps: int, log: Path) -> subprocess.Popen:
    rate = Fraction(fps_out).limit_denominator(1001)
    command = [
        "gst-launch-1.0", "-q", "-e",
        "fdsrc", "fd=0", "!",
        "rawvideoparse", "format=rgb", f"width={width}", f"height={height}",
        f"framerate={rate.numerator}/{rate.denominator}", "!",
        "videoconvert", "!",
        "video/x-raw,format=NV12", "!",
        "mpph264enc", f"bps={bps}", f"bps-max={int(bps * 1.5)}", "gop=-1", "!",
        "h264parse", "!",
        "video/x-h264,stream-format=byte-stream,alignment=au", "!",
        "filesink", f"location={output_h264}",
    ]
    log_handle = log.open("wb")
    return subprocess.Popen(command, stdin=subprocess.PIPE, stderr=log_handle,
                            env={**os.environ, "LC_ALL": "C", "LANG": "C",
                                 "GST_REGISTRY_UPDATE": "no"})


def mux_audio(elementary: Path, input_path: Path, audio_codec: str | None,
              output: Path, log: Path, video_seconds: float) -> None:
    # Trim both streams to the exact video length. A plain "-shortest" would
    # let a slightly shorter audio track silently drop trailing video frames.
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(elementary), "-i", str(input_path),
        "-map", "0:v:0",
    ]
    if audio_codec:
        command += ["-map", "1:a:0?"]
        command += (["-c:a", "copy"] if audio_codec in {"aac", "mp3", "opus"}
                    else ["-c:a", "aac", "-b:a", "192k"])
    command += ["-c:v", "copy", "-t", f"{video_seconds:.3f}",
                "-movflags", "+faststart", str(output)]
    completed = subprocess.run(command, stdout=log.open("wb"),
                               stderr=subprocess.STDOUT, timeout=600, check=False,
                               env={**os.environ, "LC_ALL": "C", "LANG": "C"})
    if completed.returncode != 0:
        raise RuntimeError(f"ffmpeg mux failed; see {log.name}")


def write_progress(path: Path, **fields: Any) -> None:
    fields["updated_at_utc"] = utc_now()
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(fields), encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--model-dir", required=True, type=Path)
    parser.add_argument("--work-dir", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--mode", choices=["interpolate", "upscale", "restore"],
                        default="interpolate")
    parser.add_argument("--max-duration-seconds", type=float, default=600.0)
    parser.add_argument("--scene-cut-threshold", type=float, default=SCENE_CUT_THRESHOLD)
    parser.add_argument("--static-threshold", type=float, default=STATIC_THRESHOLD)
    parser.add_argument("--bitrate-factor", type=float, default=0.30,
                        help="bits per pixel per frame for the output H.264")
    args = parser.parse_args()

    input_path = args.input.resolve()
    output_path = args.output.resolve()
    work_dir = args.work_dir.resolve()
    report_path = args.report.resolve()
    if report_path.parent != work_dir or output_path.parent != work_dir:
        raise SystemExit("output and report must live inside the exact work directory")
    if not input_path.is_file():
        raise SystemExit(f"input video not found: {input_path}")
    work_dir.mkdir(parents=True, exist_ok=True)
    for tool in ("ffmpeg", "ffprobe", "gst-launch-1.0"):
        if shutil.which(tool) is None:
            raise SystemExit(f"missing required tool: {tool}")

    progress_path = work_dir / "progress.json"
    started = time.monotonic()
    write_progress(progress_path, phase="probe", result="RUNNING", mode=args.mode)

    info = probe_input(input_path)
    if info["duration_seconds"] > args.max_duration_seconds:
        raise SystemExit(
            f"input duration {info['duration_seconds']:.1f}s exceeds limit "
            f"{args.max_duration_seconds:.1f}s")
    width, height, fps = info["width"], info["height"], info["fps"]

    if args.mode == "interpolate":
        if width > MAX_INTERP_WIDTH or height > MAX_INTERP_HEIGHT:
            raise SystemExit(f"input {width}x{height} exceeds the interpolation limit")
        out_w, out_h, fps_out = width, height, fps * 2.0
    elif args.mode == "upscale":
        if not (height <= MAX_UPSCALE_INPUT[0] and width <= MAX_UPSCALE_INPUT[1]):
            raise SystemExit(
                f"input {width}x{height} exceeds the upscale limit "
                f"{MAX_UPSCALE_INPUT[1]}x{MAX_UPSCALE_INPUT[0]}")
        out_w, out_h, fps_out = width * SR_SCALE, height * SR_SCALE, fps
    else:  # restore
        if not (height <= MAX_RESTORE_INPUT[0] and width <= MAX_RESTORE_INPUT[1]):
            raise SystemExit(
                f"input {width}x{height} exceeds the restore limit "
                f"{MAX_RESTORE_INPUT[1]}x{MAX_RESTORE_INPUT[0]}")
        out_w, out_h, fps_out = width * 2, height * 2, fps * 2.0

    bps = int(out_w * out_h * fps_out * args.bitrate_factor)
    pipeline = Pipeline(args.model_dir.resolve(), width, height, args.mode)
    interp_geometry = "fullframe" if pipeline.interp_fullframe else "tiled-256"
    plan = {
        "mode": args.mode,
        "output": f"{out_w}x{out_h}@{fps_out:g}",
        "interpolation_geometry": interp_geometry if args.mode != "upscale" else None,
    }

    elementary = work_dir / "video-out.h264"
    decoder = start_decoder(input_path, fps, work_dir / "decode.log")
    encoder = start_encoder(elementary, fps_out, out_w, out_h, bps,
                            work_dir / "encode.log")

    in_bytes = width * height * 3
    out_bytes = out_w * out_h * 3
    counts = {"input_frames": 0, "output_frames": 0, "model_mids": 0,
              "sr_frames": 0, "scene_cuts": 0, "static_pairs": 0}

    def emit(frame: np.ndarray) -> None:
        encoder.stdin.write(frame.tobytes())
        counts["output_frames"] += 1

    def enhance(frame: np.ndarray) -> np.ndarray:
        """Per-frame spatial stage: identity, 4x SR, or 4x SR + 2x downscale."""
        if args.mode == "interpolate":
            return frame
        hr = pipeline.upscale_frame(frame)
        counts["sr_frames"] += 1
        if args.mode == "upscale":
            return hr
        return downscale_half(hr)

    previous: np.ndarray | None = None
    previous_luma: np.ndarray | None = None
    interrupted = False

    def handle_signal(signum, _frame):
        nonlocal interrupted
        interrupted = True

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    write_progress(progress_path, phase="process", result="RUNNING",
                   width=width, height=height, fps_in=fps, plan=plan)
    temporal = args.mode != "upscale"
    while True:
        if interrupted:
            write_progress(progress_path, phase="aborted", result="INTERRUPTED",
                           **counts)
            raise SystemExit("interrupted by signal")
        raw = decoder.stdout.read(in_bytes)
        if len(raw) < in_bytes:
            break
        current_in = np.frombuffer(raw, dtype=np.uint8).reshape(height, width, 3)
        counts["input_frames"] += 1
        current = enhance(current_in) if args.mode != "interpolate" else current_in.copy()
        if previous is None:
            emit(current)
            previous = current
            previous_luma = luma_sample(current)
            continue
        if not temporal:
            emit(current)
            previous = current
            continue
        current_luma = luma_sample(current)
        diff = float(np.abs(current_luma - previous_luma).mean())
        if diff >= args.scene_cut_threshold:
            mid = previous  # hold frame across the cut
            counts["scene_cuts"] += 1
        elif diff <= args.static_threshold:
            mid = previous
            counts["static_pairs"] += 1
        else:
            mid = pipeline.midpoint(previous, current)
            counts["model_mids"] += 1
        emit(mid)
        emit(current)
        previous = current
        previous_luma = current_luma
        if counts["input_frames"] % 10 == 0:
            write_progress(progress_path, phase="process", result="RUNNING",
                           elapsed_seconds=round(time.monotonic() - started, 1),
                           plan=plan, **counts)

    decoder.stdout.close()
    decoder.wait(timeout=60)
    encoder.stdin.close()
    if encoder.wait(timeout=600) != 0:
        raise RuntimeError("GStreamer encoder failed; see encode.log")
    pipeline.close()
    process_seconds = time.monotonic() - started

    write_progress(progress_path, phase="mux", result="RUNNING", **counts)
    video_seconds = counts["output_frames"] / fps_out
    mux_audio(elementary, input_path, info["audio_codec"], output_path,
              work_dir / "mux.log", video_seconds)

    write_progress(progress_path, phase="verify", result="RUNNING", **counts)
    probe = ffprobe(output_path, count_frames=True)
    vstreams = [s for s in probe.get("streams", []) if s.get("codec_type") == "video"]
    astreams = [s for s in probe.get("streams", []) if s.get("codec_type") == "audio"]
    if len(vstreams) != 1:
        raise RuntimeError("output has no valid video stream")
    v = vstreams[0]
    out_frames = int(v.get("nb_read_frames") or v.get("nb_frames") or 0)
    expected = counts["output_frames"]
    out_fps = parse_rate(v.get("avg_frame_rate") or v.get("r_frame_rate"))
    out_duration = float((probe.get("format") or {}).get("duration") or 0.0)
    checks = {
        "codec_h264": v.get("codec_name") == "h264",
        "dimensions": (int(v["width"]), int(v["height"])) == (out_w, out_h),
        "frame_count": abs(out_frames - expected) <= 2,
        "frame_rate": abs(out_fps - fps_out) / fps_out < 0.02,
        "duration_preserved": abs(out_duration - info["duration_seconds"]) <= 1.0,
        "audio_preserved": (not info["audio_stream"]) or bool(astreams),
    }
    ok = all(checks.values())
    report = {
        "schema_version": 1,
        "result": "PASS" if ok else "FAIL",
        "finished_at_utc": utc_now(),
        "platform": {"machine": platform.machine(),
                     "python": platform.python_version()},
        "input": {"name": input_path.name, "sha256": sha256(input_path), **info},
        "output": {"name": output_path.name, "bytes": output_path.stat().st_size,
                   "sha256": sha256(output_path),
                   "width": out_w, "height": out_h,
                   "fps": round(out_fps, 3), "frames": out_frames,
                   "duration_seconds": round(out_duration, 3)},
        "policy": {"bitrate_bps": bps,
                   "scene_cut_threshold": args.scene_cut_threshold,
                   "static_threshold": args.static_threshold,
                   **plan},
        "counts": counts,
        "models": {name: sha256(args.model_dir.resolve() / name)
                   for name in pipeline.used_models},
        "timing_seconds": {"process_loop": round(process_seconds, 3),
                           "total": round(time.monotonic() - started, 3)},
        "checks": checks,
    }
    temporary = report_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(report, indent=2), encoding="utf-8")
    temporary.replace(report_path)
    write_progress(progress_path, phase="done",
                   result="PASS" if ok else "FAIL", plan=plan, **counts)
    print(json.dumps(report, indent=2))
    print("RESULT=PASS_VIDEO_PIPELINE" if ok else "RESULT=FAIL_VIDEO_PIPELINE")
    return 0 if ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
