#!/usr/bin/env python3
"""Offline 2x frame-interpolation worker for RK3588 (CAIN / RKNN NPU).

Reads a CFR (or CFR-conformable) video, doubles its frame rate with a fixed
-shape CAIN RKNN model, preserves the audio track and verifies the result.

Design rules (see docs/video-development.md):
- full-frame fixed-shape models for exact 640x360 and 1280x720 inputs;
- 256x256 tiled inference with 32 px linear-blend overlap for other sizes;
- scene cuts bypass the model (hold previous frame);
- near-static pairs bypass the model (copy previous frame);
- output frame count is 2N-1 at 2x frame rate, duration matches the input;
- writes progress.json during the run and an atomic report.json at the end;
- never touches the photo API storage or production paths.
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
import sys
import tempfile
import time
from datetime import datetime, timezone
from fractions import Fraction
from pathlib import Path
from typing import Any

import numpy as np

TILE = 256
TILE_OVERLAP = 32
TILE_STRIDE = TILE - TILE_OVERLAP
SCENE_CUT_THRESHOLD = 0.18
STATIC_THRESHOLD = 0.002
SUPPORTED_FULLFRAME = {(360, 640): "cain-interp-1x3x360x640-fp16.rknn",
                       (720, 1280): "cain-interp-1x3x720x1280-fp16.rknn"}
TILE_MODEL = "cain-interp-1x3x256x256-fp16.rknn"
MAX_WIDTH = 1920
MAX_HEIGHT = 1080


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
    if width > MAX_WIDTH or height > MAX_HEIGHT:
        raise ValueError(f"input {width}x{height} exceeds {MAX_WIDTH}x{MAX_HEIGHT} limit")
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


class CainModel:
    """Lazy RKNNLite wrapper around one fixed-shape CAIN model."""

    def __init__(self, model_dir: Path, name: str):
        from rknnlite.api import RKNNLite  # deferred: importable without NPU
        self._rknn = RKNNLite()
        if self._rknn.load_rknn(str(model_dir / name)) != 0:
            raise RuntimeError(f"failed to load {name}")
        if self._rknn.init_runtime() != 0:
            raise RuntimeError(f"failed to init runtime for {name}")
        self.name = name
        self.inferences = 0

    def infer(self, frame0: np.ndarray, frame1: np.ndarray) -> np.ndarray:
        out = self._rknn.inference(inputs=[frame0, frame1],
                                   data_format=["nchw", "nchw"])[0]
        self.inferences += 1
        return np.clip(out[0].transpose(1, 2, 0), 0.0, 1.0)

    def close(self) -> None:
        self._rknn.release()


class Interpolator:
    def __init__(self, model_dir: Path, width: int, height: int):
        self.model_dir = model_dir
        self.width = width
        self.height = height
        self.fullframe_name = SUPPORTED_FULLFRAME.get((height, width))
        self._models: dict[str, CainModel] = {}
        self._blend = self._build_blend_mask() if not self.fullframe_name else None

    def _load(self, name: str) -> CainModel:
        if name not in self._models:
            self._models[name] = CainModel(self.model_dir, name)
        return self._models[name]

    def _build_blend_mask(self) -> np.ndarray:
        w = np.ones(TILE, dtype=np.float32)
        ramp = np.linspace(0.0, 1.0, TILE_OVERLAP + 2, dtype=np.float32)[1:-1]
        w[:TILE_OVERLAP] = np.minimum(w[:TILE_OVERLAP], ramp)
        w[-TILE_OVERLAP:] = np.minimum(w[-TILE_OVERLAP:], ramp[::-1])
        return (w[:, None] * w[None, :])[None, :, :]  # 1x256x256

    def _tile_origins(self, length: int) -> list[int]:
        origins = list(range(0, max(length - TILE, 0) + 1, TILE_STRIDE))
        if not origins or origins[-1] != length - TILE:
            origins.append(max(length - TILE, 0))
        return origins

    def midpoint(self, frame0: np.ndarray, frame1: np.ndarray) -> np.ndarray:
        """frame0/frame1: uint8 HWC RGB. Returns float32 HWC in [0,1]."""
        if self.fullframe_name:
            model = self._load(self.fullframe_name)
            f0 = frame0.transpose(2, 0, 1)[None].astype(np.float32) / 255.0
            f1 = frame1.transpose(2, 0, 1)[None].astype(np.float32) / 255.0
            return model.infer(f0, f1)
        return self._midpoint_tiled(frame0, frame1)

    def _midpoint_tiled(self, frame0: np.ndarray, frame1: np.ndarray) -> np.ndarray:
        h, w = self.height, self.width
        pad_h = (TILE_STRIDE - h % TILE_STRIDE) % TILE_STRIDE + TILE_OVERLAP
        pad_w = (TILE_STRIDE - w % TILE_STRIDE) % TILE_STRIDE + TILE_OVERLAP
        ph = max(pad_h, TILE - h) if h < TILE else pad_h
        pw = max(pad_w, TILE - w) if w < TILE else pad_w
        f0 = np.pad(frame0, ((0, ph), (0, pw), (0, 0)), mode="reflect")
        f1 = np.pad(frame1, ((0, ph), (0, pw), (0, 0)), mode="reflect")
        hp, wp = f0.shape[:2]
        acc = np.zeros((hp, wp, 3), dtype=np.float32)
        wsum = np.zeros((hp, wp, 1), dtype=np.float32)
        model = self._load(TILE_MODEL)
        for y in self._tile_origins(hp):
            for x in self._tile_origins(wp):
                t0 = f0[y:y + TILE, x:x + TILE].transpose(2, 0, 1)[None] / 255.0
                t1 = f1[y:y + TILE, x:x + TILE].transpose(2, 0, 1)[None] / 255.0
                out = model.infer(t0.astype(np.float32), t1.astype(np.float32))
                weight = self._blend.transpose(1, 2, 0)
                acc[y:y + TILE, x:x + TILE] += out * weight
                wsum[y:y + TILE, x:x + TILE] += weight
        return (acc / np.maximum(wsum, 1e-6))[:h, :w]

    def close(self) -> None:
        for model in self._models.values():
            model.close()
        self._models.clear()

    @property
    def inference_count(self) -> int:
        return sum(m.inferences for m in self._models.values())


def luma_sample(frame: np.ndarray) -> np.ndarray:
    small = frame[::8, ::8].astype(np.float32) / 255.0
    return (0.299 * small[..., 0] + 0.587 * small[..., 1]
            + 0.114 * small[..., 2])


def start_decoder(input_path: Path, fps: float, width: int, height: int,
                  log: Path) -> subprocess.Popen:
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-i", str(input_path),
        "-vf", f"fps={fps}",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
    ]
    log_handle = log.open("wb")
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=log_handle,
                            env={**os.environ, "LC_ALL": "C", "LANG": "C"})
    return proc


def start_encoder(output_h264: Path, fps_out: float, width: int, height: int,
                  bps: int, log: Path) -> subprocess.Popen:
    rate = Fraction(fps_out).limit_denominator(1001)
    command = [
        "gst-launch-1.0", "-q", "-e",
        "fdsrc", "fd=0", "!",
        f"rawvideoparse", f"format=rgb", f"width={width}", f"height={height}",
        f"framerate={rate.numerator}/{rate.denominator}", "!",
        "videoconvert", "!",
        "video/x-raw,format=NV12", "!",
        "mpph264enc", f"bps={bps}", f"bps-max={int(bps * 1.5)}", "gop=-1", "!",
        "h264parse", "!",
        "video/x-h264,stream-format=byte-stream,alignment=au", "!",
        "filesink", f"location={output_h264}",
    ]
    log_handle = log.open("wb")
    proc = subprocess.Popen(command, stdin=subprocess.PIPE, stderr=log_handle,
                            env={**os.environ, "LC_ALL": "C", "LANG": "C",
                                 "GST_REGISTRY_UPDATE": "no"})
    return proc


def mux_audio(elementary: Path, input_path: Path, audio_codec: str | None,
              output: Path, log: Path, video_seconds: float) -> None:
    # Trim both streams to the exact interpolated video length. A plain
    # "-shortest" would let a slightly shorter audio track silently drop
    # trailing video frames.
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
                               stderr=subprocess.STDOUT, timeout=300, check=False,
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
    write_progress(progress_path, phase="probe", result="RUNNING")

    info = probe_input(input_path)
    if info["duration_seconds"] > args.max_duration_seconds:
        raise SystemExit(
            f"input duration {info['duration_seconds']:.1f}s exceeds limit "
            f"{args.max_duration_seconds:.1f}s")
    width, height, fps = info["width"], info["height"], info["fps"]
    fps_out = fps * 2.0
    bps = int(width * height * fps_out * args.bitrate_factor)
    mode = "fullframe" if (height, width) in SUPPORTED_FULLFRAME else "tiled-256"

    elementary = work_dir / "video-2x.h264"
    decoder = start_decoder(input_path, fps, width, height,
                            work_dir / "decode.log")
    encoder = start_encoder(elementary, fps_out, width, height, bps,
                            work_dir / "encode.log")
    interpolator = Interpolator(args.model_dir.resolve(), width, height)

    frame_bytes = width * height * 3
    counts = {"input_frames": 0, "output_frames": 0, "model_mids": 0,
              "scene_cuts": 0, "static_pairs": 0}

    def emit(buf: bytes) -> None:
        encoder.stdin.write(buf)
        counts["output_frames"] += 1

    previous: np.ndarray | None = None
    previous_luma: np.ndarray | None = None
    interrupted = False

    def handle_signal(signum, frame):
        nonlocal interrupted
        interrupted = True

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    write_progress(progress_path, phase="interpolate", result="RUNNING",
                   width=width, height=height, fps_in=fps, fps_out=fps_out,
                   mode=mode)
    while True:
        if interrupted:
            write_progress(progress_path, phase="aborted", result="INTERRUPTED",
                           **counts)
            raise SystemExit("interrupted by signal")
        raw = decoder.stdout.read(frame_bytes)
        if len(raw) < frame_bytes:
            break
        current = np.frombuffer(raw, dtype=np.uint8).reshape(height, width, 3)
        counts["input_frames"] += 1
        if previous is None:
            emit(raw)
            previous = current.copy()
            previous_luma = luma_sample(current)
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
            mid_f = interpolator.midpoint(previous, current)
            mid = np.clip(np.rint(mid_f * 255.0), 0, 255).astype(np.uint8)
            counts["model_mids"] += 1
        emit(mid.tobytes())
        emit(raw)
        previous = current.copy()
        previous_luma = current_luma
        if counts["input_frames"] % 25 == 0:
            write_progress(progress_path, phase="interpolate", result="RUNNING",
                           elapsed_seconds=round(time.monotonic() - started, 1),
                           **counts)

    decoder.stdout.close()
    decoder.wait(timeout=60)
    encoder.stdin.close()
    if encoder.wait(timeout=300) != 0:
        raise RuntimeError("GStreamer encoder failed; see encode.log")
    interpolator.close()
    inference_seconds = time.monotonic() - started

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
        "dimensions": (int(v["width"]), int(v["height"])) == (width, height),
        "frame_count": abs(out_frames - expected) <= 2,
        "frame_rate_doubled": abs(out_fps - fps_out) / fps_out < 0.02,
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
                   "fps": round(out_fps, 3), "frames": out_frames,
                   "duration_seconds": round(out_duration, 3)},
        "policy": {"mode": mode, "bitrate_bps": bps,
                   "scene_cut_threshold": args.scene_cut_threshold,
                   "static_threshold": args.static_threshold},
        "counts": counts,
        "models": {name: sha256(args.model_dir.resolve() / name)
                   for name in ({interpolator.fullframe_name} if interpolator.fullframe_name
                                else {TILE_MODEL})},
        "timing_seconds": {"interpolate_loop": round(inference_seconds, 3),
                           "total": round(time.monotonic() - started, 3)},
        "checks": checks,
    }
    temporary = report_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(report, indent=2), encoding="utf-8")
    temporary.replace(report_path)
    write_progress(progress_path, phase="done",
                   result="PASS" if ok else "FAIL", **counts)
    print(json.dumps(report, indent=2))
    print("RESULT=PASS_VIDEO_INTERPOLATION" if ok else "RESULT=FAIL_VIDEO_INTERPOLATION")
    return 0 if ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
