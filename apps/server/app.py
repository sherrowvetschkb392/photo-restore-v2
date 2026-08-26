#!/usr/bin/env python3
"""Local HTTP API and single-worker queue for RK3588 photo restoration."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import queue
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import traceback
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image, ImageOps, UnidentifiedImageError

SERVICE_VERSION = "0.6.0"
ROOT = Path(os.environ.get("PHOTO_RESTORE_ROOT", "/userdata/photo-restore-v2"))
STORAGE = ROOT / "storage"
DATABASE = ROOT / "database" / "jobs.sqlite3"
MODEL = ROOT / "models" / "realesrgan_x4plus_tile96_fp16.rknn"
WORKER = ROOT / "app" / "worker" / "restore_image.py"
VIDEO_WORKER = ROOT / "app" / "worker" / "interpolate_video.py"
VIDEO_MODEL_DIR = ROOT / "models" / "video"
VIDEO_MODEL_FILES = (
    "cain-interp-1x3x256x256-fp16.rknn",
    "cain-interp-1x3x360x640-fp16.rknn",
    "cain-interp-1x3x720x1280-fp16.rknn",
    "srvgg-general-x4v3-1x3x256x256-fp16.rknn",
)
VIDEO_MODES = ("interpolate", "upscale", "restore")
FRONTEND = ROOT / "app" / "frontend"
PYTHON = ROOT / "venv" / "bin" / "python"
MAX_UPLOAD_BYTES = int(os.environ.get("PHOTO_RESTORE_MAX_UPLOAD_BYTES", 20 * 1024 * 1024))
MAX_INPUT_PIXELS = int(os.environ.get("PHOTO_RESTORE_MAX_INPUT_PIXELS", 2_000_000))
MAX_VIDEO_UPLOAD_BYTES = int(os.environ.get("PHOTO_RESTORE_MAX_VIDEO_UPLOAD_BYTES", 300 * 1024 * 1024))
MAX_VIDEO_DURATION_SECONDS = float(os.environ.get("PHOTO_RESTORE_MAX_VIDEO_DURATION_SECONDS", 600))
VIDEO_JOB_TIMEOUT_SECONDS = int(os.environ.get("PHOTO_RESTORE_VIDEO_JOB_TIMEOUT_SECONDS", 4 * 3600))
PREVIEW_MAX_EDGE = int(os.environ.get("PHOTO_RESTORE_PREVIEW_MAX_EDGE", 1600))
JOB_RETENTION_SECONDS = max(
    0, int(os.environ.get("PHOTO_RESTORE_JOB_RETENTION_SECONDS", 7 * 24 * 3600))
)
MAX_STORAGE_BYTES = max(
    0, int(os.environ.get("PHOTO_RESTORE_MAX_STORAGE_BYTES", 4 * 1024**3))
)
MIN_FREE_BYTES = max(
    0, int(os.environ.get("PHOTO_RESTORE_MIN_FREE_BYTES", 2 * 1024**3))
)
CLEANUP_INTERVAL_SECONDS = max(
    10, int(os.environ.get("PHOTO_RESTORE_CLEANUP_INTERVAL_SECONDS", 15 * 60))
)
JOB_STALL_SECONDS = max(
    60, int(os.environ.get("PHOTO_RESTORE_JOB_STALL_SECONDS", 10 * 60))
)
ALLOWED_EXTENSIONS = {".png", ".jpg", ".jpeg"}
VIDEO_ALLOWED_EXTENSIONS = {".mp4", ".mov", ".mkv", ".avi"}
# Mirrors apps/worker/interpolate_video.py input guards.
VIDEO_MODE_LIMITS = {
    "interpolate": (1920, 1080),
    "upscale": (960, 540),
    "restore": (640, 360),
}
PUBLIC_VIDEO_ERROR = "视频处理失败，请检查文件格式后重试"
JOB_QUEUE: queue.Queue[str] = queue.Queue()
STOP = threading.Event()
WORKER_THREAD: threading.Thread | None = None
CLEANUP_THREAD: threading.Thread | None = None
STORAGE_LOCK = threading.RLock()
LAST_CLEANUP: dict[str, object] = {
    "time_utc": None,
    "deleted_jobs": 0,
    "deleted_bytes": 0,
    "storage_used_bytes": 0,
    "storage_free_bytes": 0,
}
PUBLIC_PROCESSING_ERROR = "图片处理失败，请检查文件格式后重试"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def connect() -> sqlite3.Connection:
    connection = sqlite3.connect(DATABASE, timeout=30)
    connection.row_factory = sqlite3.Row
    return connection


def initialize() -> None:
    for path in (
        STORAGE / "incoming",
        STORAGE / "jobs",
        STORAGE / "outputs",
        STORAGE / "reports",
        STORAGE / "tmp",
        DATABASE.parent,
    ):
        path.mkdir(parents=True, exist_ok=True)
    with connect() as connection:
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute(
            """CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, state TEXT NOT NULL, original_name TEXT NOT NULL,
                input_path TEXT NOT NULL, output_path TEXT, report_path TEXT, error TEXT,
                input_sha256 TEXT, output_sha256 TEXT, width INTEGER, height INTEGER,
                created_at_utc TEXT NOT NULL, updated_at_utc TEXT NOT NULL
            )"""
        )
        columns = {row["name"] for row in connection.execute("PRAGMA table_info(jobs)")}
        for name, sql_type in (("input_sha256", "TEXT"), ("output_sha256", "TEXT"), ("width", "INTEGER"), ("height", "INTEGER"), ("job_type", "TEXT DEFAULT 'image'"), ("video_mode", "TEXT")):
            if name not in columns:
                connection.execute(f"ALTER TABLE jobs ADD COLUMN {name} {sql_type}")
        connection.execute("UPDATE jobs SET state='QUEUED', error=NULL, updated_at_utc=? WHERE state='RUNNING'", (utc_now(),))


def tree_size(path: Path) -> int:
    total = 0
    if not path.exists():
        return total
    for root, directories, files in os.walk(path, followlinks=False):
        root_path = Path(root)
        directories[:] = [
            name for name in directories if not (root_path / name).is_symlink()
        ]
        for name in files:
            file_path = root_path / name
            try:
                if file_path.is_symlink():
                    continue
                total += file_path.stat().st_size
            except OSError:
                pass
    return total


def job_directory(row: sqlite3.Row) -> Path:
    directory = Path(row["input_path"]).parent.resolve(strict=False)
    jobs_root = (STORAGE / "jobs").resolve(strict=False)
    if directory == jobs_root or jobs_root not in directory.parents:
        raise RuntimeError(f"unsafe job directory: {directory}")
    return directory


def parse_utc(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def cleanup_storage(
    now: datetime | None = None, *, required_bytes: int = 0
) -> dict[str, object]:
    global LAST_CLEANUP
    with STORAGE_LOCK:
        current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
        cutoff = current - timedelta(seconds=JOB_RETENTION_SECONDS)
        used_bytes = tree_size(STORAGE)
        free_bytes = shutil.disk_usage(STORAGE).free
        deleted_jobs = 0
        deleted_bytes = 0
        with connect() as connection:
            rows = connection.execute(
                "SELECT * FROM jobs WHERE state IN ('COMPLETE','FAILED') "
                "ORDER BY updated_at_utc ASC"
            ).fetchall()
            for row in rows:
                try:
                    expired = (
                        JOB_RETENTION_SECONDS == 0
                        or parse_utc(row["updated_at_utc"]) <= cutoff
                    )
                except (TypeError, ValueError):
                    expired = True
                over_quota = (
                    MAX_STORAGE_BYTES > 0
                    and used_bytes + required_bytes > MAX_STORAGE_BYTES
                )
                low_space = (
                    MIN_FREE_BYTES > 0
                    and free_bytes < MIN_FREE_BYTES + required_bytes
                )
                if not (expired or over_quota or low_space):
                    continue
                try:
                    directory = job_directory(row)
                except RuntimeError:
                    continue
                job_bytes = tree_size(directory)
                shutil.rmtree(directory, ignore_errors=True)
                if directory.exists():
                    continue
                connection.execute("DELETE FROM jobs WHERE id=?", (row["id"],))
                deleted_jobs += 1
                deleted_bytes += job_bytes
                used_bytes = max(0, used_bytes - job_bytes)
                free_bytes = shutil.disk_usage(STORAGE).free
        LAST_CLEANUP = {
            "time_utc": current.isoformat(),
            "deleted_jobs": deleted_jobs,
            "deleted_bytes": deleted_bytes,
            "storage_used_bytes": used_bytes,
            "storage_free_bytes": free_bytes,
        }
        return dict(LAST_CLEANUP)


def ensure_upload_capacity(required_bytes: int = 0) -> int:
    summary = cleanup_storage(required_bytes=max(0, required_bytes))
    used_bytes = int(summary["storage_used_bytes"])
    free_bytes = int(summary["storage_free_bytes"])
    if MAX_STORAGE_BYTES > 0 and used_bytes + required_bytes > MAX_STORAGE_BYTES:
        raise HTTPException(status_code=507, detail="server storage quota is full")
    if MIN_FREE_BYTES > 0 and free_bytes < MIN_FREE_BYTES + required_bytes:
        raise HTTPException(status_code=507, detail="server storage reserve is low")
    return used_bytes


def cleanup_loop() -> None:
    while not STOP.wait(CLEANUP_INTERVAL_SECONDS):
        try:
            cleanup_storage()
        except (OSError, sqlite3.Error):
            # Retention failures must not terminate the API or NPU worker.
            pass


def job_health_snapshot(now: datetime | None = None) -> dict[str, object]:
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    counts = {state: 0 for state in ("QUEUED", "RUNNING", "COMPLETE", "FAILED")}
    oldest_running_seconds: float | None = None
    with connect() as connection:
        for row in connection.execute(
            "SELECT state,COUNT(*) AS count FROM jobs GROUP BY state"
        ):
            counts[str(row["state"])] = int(row["count"])
        running_rows = connection.execute(
            "SELECT id,input_path,updated_at_utc,job_type FROM jobs WHERE state='RUNNING'"
        ).fetchall()
    for row in running_rows:
        # Video workers report liveness through progress.json; a long video job
        # is only stalled when its progress file also stops updating.
        activity: datetime | None = None
        try:
            if row["job_type"] == "video":
                progress = Path(row["input_path"]).parent / "progress.json"
                if progress.is_file():
                    activity = datetime.fromtimestamp(
                        progress.stat().st_mtime, tz=timezone.utc
                    )
        except (OSError, ValueError):
            activity = None
        if activity is None:
            try:
                activity = parse_utc(str(row["updated_at_utc"]))
            except (TypeError, ValueError):
                continue
        age = max(0.0, (current - activity).total_seconds())
        if oldest_running_seconds is None or age > oldest_running_seconds:
            oldest_running_seconds = age
    return {
        "counts": counts,
        "oldest_running_seconds": (
            round(oldest_running_seconds, 1)
            if oldest_running_seconds is not None
            else None
        ),
        "stalled": (
            oldest_running_seconds is not None
            and oldest_running_seconds >= JOB_STALL_SECONDS
        ),
    }


def job_row_progress(row: sqlite3.Row) -> dict[str, object] | None:
    """Whitelisted live progress for running video jobs (from progress.json)."""
    if row["job_type"] != "video" or row["state"] not in {"QUEUED", "RUNNING"}:
        return None
    progress = Path(row["input_path"]).parent / "progress.json"
    try:
        if not progress.is_file():
            return None
        data = json.loads(progress.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    allowed = ("phase", "result", "input_frames", "output_frames", "model_mids",
               "sr_frames", "scene_cuts", "static_pairs", "elapsed_seconds")
    return {key: data.get(key) for key in allowed if key in data}


def row_to_dict(row: sqlite3.Row) -> dict[str, object]:
    job_type = row["job_type"] if "job_type" in row.keys() and row["job_type"] else "image"
    public_error = PUBLIC_VIDEO_ERROR if job_type == "video" else PUBLIC_PROCESSING_ERROR
    return {
        "id": row["id"],
        "state": row["state"],
        "job_type": job_type,
        "video_mode": row["video_mode"] if "video_mode" in row.keys() else None,
        "original_name": row["original_name"],
        # Never expose worker output, tracebacks, commands or board paths through
        # the public API. This also sanitizes records created by older versions.
        "error": public_error if row["state"] == "FAILED" else None,
        "input_sha256": row["input_sha256"],
        "output_sha256": row["output_sha256"],
        "width": row["width"],
        "height": row["height"],
        "created_at_utc": row["created_at_utc"],
        "updated_at_utc": row["updated_at_utc"],
        "progress": job_row_progress(row),
        "input_url": f"/api/jobs/{row['id']}/input",
        "input_preview_url": f"/api/jobs/{row['id']}/input/preview",
        "output_url": f"/api/jobs/{row['id']}/output" if row["state"] == "COMPLETE" else None,
        "output_preview_url": f"/api/jobs/{row['id']}/output/preview" if row["state"] == "COMPLETE" else None,
        "report_url": f"/api/jobs/{row['id']}/report" if row["state"] == "COMPLETE" else None,
    }


def get_job(job_id: str) -> sqlite3.Row:
    with connect() as connection:
        row = connection.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="job not found")
    return row


def set_state(job_id: str, state: str, error: str | None = None, output_sha256: str | None = None) -> None:
    with connect() as connection:
        connection.execute("UPDATE jobs SET state=?, error=?, output_sha256=COALESCE(?,output_sha256), updated_at_utc=? WHERE id=?", (state, error, output_sha256, utc_now(), job_id))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def probe_video(path: Path) -> dict[str, object]:
    """ffprobe the uploaded video; raises HTTPException(415) when invalid."""
    try:
        completed = subprocess.run(
            ["ffprobe", "-v", "error", "-show_streams", "-show_format",
             "-of", "json", str(path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            timeout=60, check=False,
            env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        )
        data = json.loads(completed.stdout) if completed.returncode == 0 else {}
    except (OSError, ValueError) as exc:
        raise HTTPException(status_code=415, detail="uploaded file is not a readable video") from exc
    videos = [s for s in data.get("streams", []) if s.get("codec_type") == "video"]
    if not videos:
        raise HTTPException(status_code=415, detail="uploaded file has no video stream")
    video = videos[0]
    width, height = int(video.get("width") or 0), int(video.get("height") or 0)
    duration = float((data.get("format") or {}).get("duration") or 0.0)
    if width <= 0 or height <= 0 or duration <= 0:
        raise HTTPException(status_code=415, detail="uploaded video metadata is invalid")
    return {"width": width, "height": height, "duration_seconds": duration}


def preview_path(row: sqlite3.Row, kind: str) -> Path:
    if kind not in {"input", "output"}:
        raise ValueError(f"unsupported preview kind: {kind}")
    return Path(row["input_path"]).parent / f"{kind}-preview.jpg"


def create_preview(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.stem}.", suffix=".jpg", dir=destination.parent
    )
    os.close(handle)
    temporary = Path(temporary_name)
    try:
        with Image.open(source) as image:
            image = ImageOps.exif_transpose(image).convert("RGB")
            image.thumbnail((PREVIEW_MAX_EDGE, PREVIEW_MAX_EDGE), Image.Resampling.LANCZOS)
            image.save(temporary, format="JPEG", quality=88, optimize=True)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def create_video_preview(source: Path, destination: Path, seek_seconds: float = 0.5) -> None:
    """Extract one JPEG frame from a video with ffmpeg (bounded longest edge)."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.stem}.", suffix=".jpg", dir=destination.parent
    )
    os.close(handle)
    temporary = Path(temporary_name)
    try:
        completed = subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-ss", f"{seek_seconds:.1f}", "-i", str(source),
                "-frames:v", "1",
                "-vf", f"scale='min({PREVIEW_MAX_EDGE},iw)':-2",
                "-q:v", "3", str(temporary),
            ],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
            check=False, env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        )
        if completed.returncode != 0 or not temporary.is_file() or temporary.stat().st_size == 0:
            raise RuntimeError(f"ffmpeg preview failed for {source.name}")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def ensure_preview(row: sqlite3.Row, kind: str) -> Path:
    destination = preview_path(row, kind)
    if not destination.is_file():
        source = Path(row["input_path"] if kind == "input" else row["output_path"])
        if not source.is_file():
            raise HTTPException(status_code=409, detail=f"{kind} media is not ready")
        if "job_type" in row.keys() and row["job_type"] == "video":
            seek = 0.5 if kind == "input" else 1.0
            create_video_preview(source, destination, seek_seconds=seek)
        else:
            create_preview(source, destination)
    return destination


def process_job(job_id: str) -> None:
    row = get_job(job_id)
    input_path, output_path, report_path = map(Path, (row["input_path"], row["output_path"], row["report_path"]))
    output_preview_path = preview_path(row, "output")
    set_state(job_id, "RUNNING")
    if "job_type" in row.keys() and row["job_type"] == "video":
        mode = row["video_mode"] or "interpolate"
        command = [
            str(PYTHON), str(VIDEO_WORKER),
            "--input", str(input_path), "--output", str(output_path),
            "--model-dir", str(VIDEO_MODEL_DIR), "--work-dir", str(input_path.parent),
            "--report", str(report_path), "--mode", mode,
            "--max-duration-seconds", str(MAX_VIDEO_DURATION_SECONDS),
        ]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=VIDEO_JOB_TIMEOUT_SECONDS)
        (input_path.parent / "worker.log").write_text(completed.stdout + completed.stderr, encoding="utf-8")
        if completed.returncode != 0 or not output_path.is_file() or not report_path.is_file():
            raise RuntimeError(f"video worker exited with code {completed.returncode}; see worker.log")
        create_video_preview(output_path, output_preview_path, seek_seconds=1.0)
        set_state(job_id, "COMPLETE", output_sha256=sha256(output_path))
        return
    command = [str(PYTHON), str(WORKER), "--input", str(input_path), "--output", str(output_path), "--model", str(MODEL), "--report", str(report_path), "--preview-output", str(output_preview_path), "--preview-max-edge", str(PREVIEW_MAX_EDGE), "--max-input-pixels", str(MAX_INPUT_PIXELS), "--compositor", "auto", "--work-dir", str(STORAGE / "tmp")]
    completed = subprocess.run(command, capture_output=True, text=True, timeout=3600)
    (input_path.parent / "worker.log").write_text(completed.stdout + completed.stderr, encoding="utf-8")
    if completed.returncode != 0 or not output_path.is_file() or not report_path.is_file() or not output_preview_path.is_file():
        raise RuntimeError(f"worker exited with code {completed.returncode}; see worker.log")
    set_state(job_id, "COMPLETE", output_sha256=sha256(output_path))


def worker_loop() -> None:
    while not STOP.is_set():
        try:
            job_id = JOB_QUEUE.get(timeout=1)
        except queue.Empty:
            continue
        try:
            process_job(job_id)
        except Exception:
            try:
                row = get_job(job_id)
                log_path = Path(row["input_path"]).parent / "worker.log"
                with log_path.open("a", encoding="utf-8") as stream:
                    stream.write("\n--- API WORKER EXCEPTION ---\n")
                    stream.write(traceback.format_exc())
            except (OSError, HTTPException):
                # A diagnostic write failure must not terminate the queue worker.
                pass
            set_state(job_id, "FAILED", PUBLIC_PROCESSING_ERROR)
        finally:
            JOB_QUEUE.task_done()
            try:
                cleanup_storage()
            except (OSError, sqlite3.Error):
                pass


def enqueue_existing() -> None:
    with connect() as connection:
        rows = connection.execute("SELECT id FROM jobs WHERE state='QUEUED' ORDER BY created_at_utc").fetchall()
    for row in rows:
        JOB_QUEUE.put(row["id"])


app = FastAPI(title="Photo Restore V2", version=SERVICE_VERSION)
app.mount("/static", StaticFiles(directory=str(FRONTEND), check_dir=False), name="static")


@app.get("/", include_in_schema=False)
def index() -> FileResponse:
    index_path = FRONTEND / "index.html"
    if not index_path.is_file():
        raise HTTPException(status_code=503, detail="frontend is not deployed")
    return FileResponse(index_path, media_type="text/html")


@app.on_event("startup")
def startup() -> None:
    global CLEANUP_THREAD, WORKER_THREAD
    STOP.clear()
    initialize()
    cleanup_storage()
    enqueue_existing()
    WORKER_THREAD = threading.Thread(target=worker_loop, name="npu-worker", daemon=True)
    WORKER_THREAD.start()
    CLEANUP_THREAD = threading.Thread(
        target=cleanup_loop, name="storage-cleanup", daemon=True
    )
    CLEANUP_THREAD.start()


@app.on_event("shutdown")
def shutdown() -> None:
    STOP.set()


@app.get("/api/health")
def health() -> dict[str, object]:
    database_ok = False
    jobs: dict[str, object] = {
        "counts": {},
        "oldest_running_seconds": None,
        "stalled": False,
    }
    try:
        with connect() as connection:
            connection.execute("SELECT 1").fetchone()
        database_ok = True
        jobs = job_health_snapshot()
    except sqlite3.Error:
        pass
    worker_thread_alive = WORKER_THREAD is not None and WORKER_THREAD.is_alive()
    cleanup_thread_alive = CLEANUP_THREAD is not None and CLEANUP_THREAD.is_alive()
    storage_free_bytes = 0
    try:
        storage_free_bytes = shutil.disk_usage(STORAGE).free
    except OSError:
        pass
    storage_used_bytes = int(LAST_CLEANUP.get("storage_used_bytes") or 0)
    storage_quota_ok = (
        MAX_STORAGE_BYTES == 0 or storage_used_bytes < MAX_STORAGE_BYTES
    )
    storage_reserve_ok = (
        MIN_FREE_BYTES == 0 or storage_free_bytes >= MIN_FREE_BYTES
    )
    video_worker_ok = VIDEO_WORKER.is_file()
    video_models_missing = [
        name for name in VIDEO_MODEL_FILES
        if not (VIDEO_MODEL_DIR / name).is_file()
    ]
    alerts: list[str] = []
    if not database_ok:
        alerts.append("database_unavailable")
    if not MODEL.is_file():
        alerts.append("model_unavailable")
    if not WORKER.is_file():
        alerts.append("worker_source_unavailable")
    if not video_worker_ok:
        alerts.append("video_worker_unavailable")
    if video_models_missing:
        alerts.append("video_models_unavailable")
    if not (FRONTEND / "index.html").is_file():
        alerts.append("frontend_unavailable")
    if not worker_thread_alive:
        alerts.append("worker_thread_unavailable")
    if not cleanup_thread_alive:
        alerts.append("cleanup_thread_unavailable")
    if not storage_quota_ok:
        alerts.append("storage_quota_full")
    if not storage_reserve_ok:
        alerts.append("storage_reserve_low")
    if bool(jobs.get("stalled")):
        alerts.append("running_job_stalled")
    core_ready = (
        database_ok
        and MODEL.is_file()
        and WORKER.is_file()
        and (FRONTEND / "index.html").is_file()
        and worker_thread_alive
        and cleanup_thread_alive
    )
    accepting_uploads = (
        core_ready
        and storage_quota_ok
        and storage_reserve_ok
        and not bool(jobs.get("stalled"))
    )
    ready = accepting_uploads
    video_ready = video_worker_ok and not video_models_missing
    accepting_video_uploads = (
        video_ready
        and database_ok
        and worker_thread_alive
        and storage_quota_ok
        and storage_reserve_ok
        and not bool(jobs.get("stalled"))
    )
    return {
        "status": "ok" if ready else "degraded",
        "service": "photo-restore-v2",
        "version": SERVICE_VERSION,
        "time_utc": utc_now(),
        "python": platform.python_version(),
        "architecture": platform.machine(),
        "database_ready": database_ok,
        "model_ready": MODEL.is_file(),
        "worker_ready": WORKER.is_file(),
        "frontend_ready": (FRONTEND / "index.html").is_file(),
        "video_ready": video_ready,
        "video_worker_ready": video_worker_ok,
        "video_models_missing": video_models_missing,
        "queue_size": JOB_QUEUE.qsize(),
        "worker_thread_alive": worker_thread_alive,
        "cleanup_thread_alive": cleanup_thread_alive,
        "accepting_uploads": accepting_uploads,
        "accepting_video_uploads": accepting_video_uploads,
        "max_video_upload_bytes": MAX_VIDEO_UPLOAD_BYTES,
        "max_video_duration_seconds": MAX_VIDEO_DURATION_SECONDS,
        "video_mode_limits": VIDEO_MODE_LIMITS,
        "alerts": alerts,
        "jobs": jobs,
        "max_upload_bytes": MAX_UPLOAD_BYTES,
        "max_input_pixels": MAX_INPUT_PIXELS,
        "preview_max_edge": PREVIEW_MAX_EDGE,
        "job_retention_seconds": JOB_RETENTION_SECONDS,
        "max_storage_bytes": MAX_STORAGE_BYTES,
        "min_free_bytes": MIN_FREE_BYTES,
        "cleanup_interval_seconds": CLEANUP_INTERVAL_SECONDS,
        "job_stall_seconds": JOB_STALL_SECONDS,
        "storage_used_bytes": storage_used_bytes,
        "storage_free_bytes": storage_free_bytes,
        "last_cleanup": dict(LAST_CLEANUP),
    }


@app.post("/api/jobs", status_code=202)
def create_job(file: UploadFile = File(...)) -> dict[str, object]:
    original_name = Path(file.filename or "upload").name
    extension = Path(original_name).suffix.lower()
    if extension not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=415, detail="only PNG and JPEG are supported")
    with STORAGE_LOCK:
        existing_storage_bytes = ensure_upload_capacity(MAX_UPLOAD_BYTES)
        job_id = uuid.uuid4().hex
        job_dir = STORAGE / "jobs" / job_id
        job_dir.mkdir(parents=True)
        input_path = job_dir / f"input{extension}"
        output_path, report_path = job_dir / "output.png", job_dir / "report.json"
        size = 0
        digest = hashlib.sha256()
        try:
            with input_path.open("xb") as stream:
                while chunk := file.file.read(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_UPLOAD_BYTES:
                        raise HTTPException(status_code=413, detail="upload exceeds size limit")
                    if MAX_STORAGE_BYTES > 0 and existing_storage_bytes + size > MAX_STORAGE_BYTES:
                        raise HTTPException(status_code=507, detail="upload exceeds server storage quota")
                    if MIN_FREE_BYTES > 0 and shutil.disk_usage(STORAGE).free < MIN_FREE_BYTES:
                        raise HTTPException(status_code=507, detail="server storage reserve is low")
                    digest.update(chunk)
                    stream.write(chunk)
            with Image.open(input_path) as image:
                image.verify()
            with Image.open(input_path) as image:
                width, height = image.size
            if width * height > MAX_INPUT_PIXELS:
                raise HTTPException(status_code=413, detail=f"image has {width * height} pixels; limit is {MAX_INPUT_PIXELS}")
            # Reserve space for the raw 4x RGB memmap and a worst-case full
            # output copy before the NPU job enters the queue.
            processing_reserve_bytes = width * height * 16 * 3 * 2
            ensure_upload_capacity(processing_reserve_bytes)
            create_preview(input_path, job_dir / "input-preview.jpg")
        except (UnidentifiedImageError, OSError) as exc:
            shutil.rmtree(job_dir, ignore_errors=True)
            raise HTTPException(status_code=415, detail="uploaded file is not a valid PNG/JPEG") from exc
        except Exception:
            shutil.rmtree(job_dir, ignore_errors=True)
            raise
        now = utc_now()
        with connect() as connection:
            connection.execute("INSERT INTO jobs (id,state,original_name,input_path,output_path,report_path,error,input_sha256,width,height,created_at_utc,updated_at_utc) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", (job_id, "QUEUED", original_name, str(input_path), str(output_path), str(report_path), None, digest.hexdigest(), width, height, now, now))
    JOB_QUEUE.put(job_id)
    return row_to_dict(get_job(job_id))


@app.post("/api/video-jobs", status_code=202)
def create_video_job(file: UploadFile = File(...), mode: str = Form("interpolate")) -> dict[str, object]:
    original_name = Path(file.filename or "upload").name
    extension = Path(original_name).suffix.lower()
    if extension not in VIDEO_ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=415, detail="only MP4/MOV/MKV/AVI are supported")
    if mode not in VIDEO_MODES:
        raise HTTPException(status_code=422, detail=f"mode must be one of: {', '.join(VIDEO_MODES)}")
    with STORAGE_LOCK:
        existing_storage_bytes = ensure_upload_capacity(MAX_VIDEO_UPLOAD_BYTES)
        job_id = uuid.uuid4().hex
        job_dir = STORAGE / "jobs" / job_id
        job_dir.mkdir(parents=True)
        input_path = job_dir / f"input{extension}"
        output_path, report_path = job_dir / "output.mp4", job_dir / "report.json"
        size = 0
        digest = hashlib.sha256()
        try:
            with input_path.open("xb") as stream:
                while chunk := file.file.read(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_VIDEO_UPLOAD_BYTES:
                        raise HTTPException(status_code=413, detail="upload exceeds size limit")
                    if MAX_STORAGE_BYTES > 0 and existing_storage_bytes + size > MAX_STORAGE_BYTES:
                        raise HTTPException(status_code=507, detail="upload exceeds server storage quota")
                    if MIN_FREE_BYTES > 0 and shutil.disk_usage(STORAGE).free < MIN_FREE_BYTES:
                        raise HTTPException(status_code=507, detail="server storage reserve is low")
                    digest.update(chunk)
                    stream.write(chunk)
            info = probe_video(input_path)
            if info["duration_seconds"] > MAX_VIDEO_DURATION_SECONDS:
                raise HTTPException(status_code=413, detail=f"video is {info['duration_seconds']:.0f}s; limit is {MAX_VIDEO_DURATION_SECONDS:.0f}s")
            max_w, max_h = VIDEO_MODE_LIMITS[mode]
            if info["width"] > max_w or info["height"] > max_h:
                raise HTTPException(status_code=413, detail=f"{mode} mode accepts at most {max_w}x{max_h}; got {info['width']}x{info['height']}")
            # Reserve space for the elementary H.264 plus the final MP4.
            ensure_upload_capacity(max(size * 3, 64 * 1024 * 1024))
            create_video_preview(input_path, job_dir / "input-preview.jpg", seek_seconds=0.5)
        except HTTPException:
            shutil.rmtree(job_dir, ignore_errors=True)
            raise
        except Exception:
            shutil.rmtree(job_dir, ignore_errors=True)
            raise
        now = utc_now()
        with connect() as connection:
            connection.execute("INSERT INTO jobs (id,state,original_name,input_path,output_path,report_path,error,input_sha256,width,height,created_at_utc,updated_at_utc,job_type,video_mode) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (job_id, "QUEUED", original_name, str(input_path), str(output_path), str(report_path), None, digest.hexdigest(), info["width"], info["height"], now, now, "video", mode))
    JOB_QUEUE.put(job_id)
    return row_to_dict(get_job(job_id))


@app.get("/api/jobs")
def list_jobs(limit: int = 50) -> list[dict[str, object]]:
    limit = max(1, min(limit, 100))
    with connect() as connection:
        rows = connection.execute("SELECT * FROM jobs ORDER BY created_at_utc DESC LIMIT ?", (limit,)).fetchall()
    return [row_to_dict(row) for row in rows]


@app.get("/api/jobs/{job_id}")
def job_detail(job_id: str) -> dict[str, object]:
    return row_to_dict(get_job(job_id))


@app.get("/api/jobs/{job_id}/input")
def job_input(job_id: str) -> FileResponse:
    row = get_job(job_id)
    return FileResponse(row["input_path"], filename=row["original_name"])


@app.get("/api/jobs/{job_id}/input/preview")
def job_input_preview(job_id: str) -> FileResponse:
    row = get_job(job_id)
    return FileResponse(ensure_preview(row, "input"), media_type="image/jpeg")


@app.get("/api/jobs/{job_id}/output")
def job_output(job_id: str) -> FileResponse:
    row = get_job(job_id)
    if row["state"] != "COMPLETE" or not Path(row["output_path"]).is_file():
        raise HTTPException(status_code=409, detail="output is not ready")
    if "job_type" in row.keys() and row["job_type"] == "video":
        mode = row["video_mode"] or "interpolate"
        return FileResponse(
            row["output_path"],
            media_type="video/mp4",
            filename=f"{Path(row['original_name']).stem}-{mode}.mp4",
        )
    return FileResponse(row["output_path"], media_type="image/png", filename=f"{Path(row['original_name']).stem}-x4.png")


@app.get("/api/jobs/{job_id}/output/preview")
def job_output_preview(job_id: str) -> FileResponse:
    row = get_job(job_id)
    if row["state"] != "COMPLETE":
        raise HTTPException(status_code=409, detail="output is not ready")
    return FileResponse(ensure_preview(row, "output"), media_type="image/jpeg")


@app.get("/api/jobs/{job_id}/report")
def job_report(job_id: str) -> FileResponse:
    row = get_job(job_id)
    if row["state"] != "COMPLETE" or not Path(row["report_path"]).is_file():
        raise HTTPException(status_code=409, detail="report is not ready")
    return FileResponse(row["report_path"], media_type="application/json", filename=f"{job_id}-report.json")


@app.delete("/api/jobs/{job_id}")
def delete_job(job_id: str) -> dict[str, object]:
    with STORAGE_LOCK:
        row = get_job(job_id)
        if row["state"] in {"QUEUED", "RUNNING"}:
            raise HTTPException(status_code=409, detail="an active job cannot be deleted")
        directory = job_directory(row)
        shutil.rmtree(directory, ignore_errors=True)
        if directory.exists():
            raise HTTPException(status_code=500, detail="job files could not be deleted")
        with connect() as connection:
            connection.execute("DELETE FROM jobs WHERE id=?", (job_id,))
    return {"deleted": True, "job_id": job_id}
