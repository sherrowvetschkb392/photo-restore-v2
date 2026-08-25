#!/usr/bin/env python3
"""Run and verify an isolated RK3588 MPP H.264 codec smoke test."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from fractions import Fraction
from pathlib import Path
from typing import Any

try:
    import resource
except ImportError:  # pragma: no cover - Windows validates pure helper functions.
    resource = None


WIDTH = 640
HEIGHT = 360
FPS = 30
FRAME_COUNT = 300
DURATION_SECONDS = FRAME_COUNT / FPS


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


def validate_probe(probe: dict[str, Any]) -> dict[str, Any]:
    streams = probe.get("streams") or []
    video_streams = [stream for stream in streams if stream.get("codec_type") == "video"]
    audio_streams = [stream for stream in streams if stream.get("codec_type") == "audio"]
    if len(video_streams) != 1:
        raise ValueError(f"expected one video stream, found {len(video_streams)}")
    if len(audio_streams) != 1:
        raise ValueError(f"expected one audio stream, found {len(audio_streams)}")
    video = video_streams[0]
    audio = audio_streams[0]
    if video.get("codec_name") != "h264":
        raise ValueError(f"expected H.264 output, found {video.get('codec_name')}")
    if (int(video.get("width") or 0), int(video.get("height") or 0)) != (WIDTH, HEIGHT):
        raise ValueError(f"unexpected output dimensions: {video.get('width')}x{video.get('height')}")
    frame_rate = parse_rate(video.get("avg_frame_rate") or video.get("r_frame_rate"))
    if not 29.0 <= frame_rate <= 31.0:
        raise ValueError(f"unexpected frame rate: {frame_rate}")
    frames = int(video.get("nb_read_frames") or video.get("nb_frames") or 0)
    if not FRAME_COUNT - 2 <= frames <= FRAME_COUNT + 2:
        raise ValueError(f"unexpected decoded frame count: {frames}")
    if audio.get("codec_name") != "aac":
        raise ValueError(f"expected AAC output, found {audio.get('codec_name')}")
    sample_rate = int(audio.get("sample_rate") or 0)
    if sample_rate != 48000:
        raise ValueError(f"unexpected audio sample rate: {sample_rate}")
    duration = float((probe.get("format") or {}).get("duration") or 0.0)
    if not 9.5 <= duration <= 10.5:
        raise ValueError(f"unexpected output duration: {duration}")
    return {
        "video_codec": video.get("codec_name"),
        "audio_codec": audio.get("codec_name"),
        "width": int(video["width"]),
        "height": int(video["height"]),
        "frame_rate": round(frame_rate, 3),
        "decoded_frame_count": frames,
        "audio_sample_rate": sample_rate,
        "duration_seconds": round(duration, 3),
        "pixel_format": video.get("pix_fmt"),
        "format_name": (probe.get("format") or {}).get("format_name"),
    }


def temperatures() -> dict[str, float]:
    result: dict[str, float] = {}
    for zone in Path("/sys/class/thermal").glob("thermal_zone*"):
        try:
            name = (zone / "type").read_text(encoding="utf-8").strip()
            value = float((zone / "temp").read_text(encoding="utf-8").strip()) / 1000.0
        except (OSError, ValueError):
            continue
        result[name] = round(value, 1)
    return result


def run_checked(command: list[str], log_path: Path, timeout: int = 120) -> float:
    started = time.monotonic()
    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
        check=False,
        env={**os.environ, "LC_ALL": "C", "LANG": "C", "GST_REGISTRY_UPDATE": "no"},
    )
    elapsed = time.monotonic() - started
    log_path.write_text(completed.stdout, encoding="utf-8")
    if completed.returncode != 0:
        raise RuntimeError(
            f"command failed with exit code {completed.returncode}; see {log_path.name}"
        )
    return elapsed


def inspect_plugin(name: str, destination: Path) -> str:
    completed = subprocess.run(
        ["gst-inspect-1.0", name],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
        check=False,
        env={**os.environ, "LC_ALL": "C", "LANG": "C", "GST_REGISTRY_UPDATE": "no"},
    )
    destination.write_text(completed.stdout, encoding="utf-8")
    if completed.returncode != 0:
        raise RuntimeError(f"required GStreamer plugin is unavailable: {name}")
    for line in completed.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("Version"):
            value = stripped[len("Version") :].lstrip(" :\t")
            if value:
                return value
    return "unknown"


def ffprobe(path: Path) -> dict[str, Any]:
    completed = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-count_frames",
            "-show_streams",
            "-show_format",
            "-of",
            "json",
            str(path),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=60,
        check=False,
        env={**os.environ, "LC_ALL": "C", "LANG": "C"},
    )
    if completed.returncode != 0:
        raise RuntimeError(f"ffprobe failed: {completed.stderr.strip()}")
    return json.loads(completed.stdout)


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    handle, temporary_name = tempfile.mkstemp(
        prefix=f".{path.stem}.", suffix=".json", dir=path.parent
    )
    os.close(handle)
    temporary = Path(temporary_name)
    try:
        temporary.write_text(json.dumps(value, indent=2), encoding="utf-8")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-dir", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()

    work_dir = args.work_dir.resolve()
    report_path = args.report.resolve()
    if report_path.parent != work_dir:
        raise SystemExit("report must be inside the exact work directory")
    work_dir.mkdir(parents=True, exist_ok=True)
    protected_names = {"report.json"}
    unexpected = [path.name for path in work_dir.iterdir() if path.name not in protected_names]
    if unexpected:
        raise SystemExit(f"work directory is not empty: {', '.join(sorted(unexpected))}")

    required = ["gst-launch-1.0", "gst-inspect-1.0", "ffmpeg", "ffprobe"]
    missing = [name for name in required if shutil.which(name) is None]
    if missing:
        raise SystemExit(f"missing required tools: {', '.join(missing)}")

    elementary = work_dir / "mpp-h264-640x360.h264"
    output = work_dir / "mpp-codec-smoke-640x360.mp4"
    temperatures_before = temperatures()
    started = time.monotonic()
    encoder_version = inspect_plugin("mpph264enc", work_dir / "mpph264enc-inspect.txt")
    decoder_version = inspect_plugin("mppvideodec", work_dir / "mppvideodec-inspect.txt")

    print("STAGE=HARDWARE_ENCODE", flush=True)
    encode_seconds = run_checked(
        [
            "gst-launch-1.0",
            "-e",
            "videotestsrc",
            f"num-buffers={FRAME_COUNT}",
            "pattern=smpte",
            "!",
            f"video/x-raw,width={WIDTH},height={HEIGHT},framerate={FPS}/1",
            "!",
            "videoconvert",
            "!",
            "video/x-raw,format=NV12",
            "!",
            "mpph264enc",
            "!",
            "h264parse",
            "!",
            "video/x-h264,stream-format=byte-stream,alignment=au",
            "!",
            "filesink",
            f"location={elementary}",
        ],
        work_dir / "hardware-encode.log",
    )
    if not elementary.is_file() or elementary.stat().st_size == 0:
        raise RuntimeError("hardware encoder did not produce an H.264 stream")

    print("STAGE=HARDWARE_DECODE", flush=True)
    decode_seconds = run_checked(
        [
            "gst-launch-1.0",
            "filesrc",
            f"location={elementary}",
            "!",
            "h264parse",
            "!",
            "mppvideodec",
            "!",
            "fakesink",
            "sync=false",
        ],
        work_dir / "hardware-decode.log",
    )

    print("STAGE=MUX_AUDIO", flush=True)
    mux_seconds = run_checked(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "warning",
            "-y",
            "-r",
            str(FPS),
            "-i",
            str(elementary),
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency=1000:sample_rate=48000:duration={DURATION_SECONDS}",
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-c:v",
            "copy",
            "-c:a",
            "aac",
            "-b:a",
            "128k",
            "-shortest",
            "-movflags",
            "+faststart",
            str(output),
        ],
        work_dir / "mux.log",
    )

    print("STAGE=VERIFY", flush=True)
    probe = ffprobe(output)
    (work_dir / "ffprobe.json").write_text(json.dumps(probe, indent=2), encoding="utf-8")
    verified = validate_probe(probe)
    temperatures_after = temperatures()
    total_seconds = time.monotonic() - started
    max_rss_kib = (
        int(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
        if resource is not None
        else None
    )
    report = {
        "schema_version": 1,
        "result": "PASS",
        "tested_at_utc": utc_now(),
        "platform": {"architecture": platform.machine(), "python": platform.python_version()},
        "pipeline": {
            "generator": "GStreamer videotestsrc",
            "encoder": "mpph264enc",
            "decoder": "mppvideodec",
            "container_mux": "FFmpeg",
            "audio": "FFmpeg AAC 48 kHz sine fixture",
            "width": WIDTH,
            "height": HEIGHT,
            "frame_rate": FPS,
            "frame_count": FRAME_COUNT,
            "duration_seconds": DURATION_SECONDS,
        },
        "plugins": {"mpph264enc_version": encoder_version, "mppvideodec_version": decoder_version},
        "timing_seconds": {
            "hardware_encode": round(encode_seconds, 3),
            "hardware_decode": round(decode_seconds, 3),
            "mux_audio": round(mux_seconds, 3),
            "total": round(total_seconds, 3),
        },
        "verified_output": verified,
        "artifacts": {
            "elementary_h264": elementary.name,
            "elementary_h264_bytes": elementary.stat().st_size,
            "elementary_h264_sha256": sha256(elementary),
            "output_mp4": output.name,
            "output_mp4_bytes": output.stat().st_size,
            "output_mp4_sha256": sha256(output),
        },
        "max_rss_kib": max_rss_kib,
        "temperatures_before_c": temperatures_before,
        "temperatures_after_c": temperatures_after,
    }
    atomic_json(report_path, report)
    print(json.dumps(report, indent=2), flush=True)
    print("RESULT=PASS_VIDEO_CODEC_SMOKE", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
