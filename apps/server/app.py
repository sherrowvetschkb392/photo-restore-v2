#!/usr/bin/env python3
"""Local HTTP API and single-worker queue for RK3588 photo restoration."""

from __future__ import annotations

import hashlib
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

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image, ImageOps, UnidentifiedImageError

SERVICE_VERSION = "0.4.0"
ROOT = Path(os.environ.get("PHOTO_RESTORE_ROOT", "/userdata/photo-restore-v2"))
STORAGE = ROOT / "storage"
DATABASE = ROOT / "database" / "jobs.sqlite3"
MODEL = ROOT / "models" / "realesrgan_x4plus_tile96_fp16.rknn"
WORKER = ROOT / "app" / "worker" / "restore_image.py"
FRONTEND = ROOT / "app" / "frontend"
PYTHON = ROOT / "venv" / "bin" / "python"
MAX_UPLOAD_BYTES = int(os.environ.get("PHOTO_RESTORE_MAX_UPLOAD_BYTES", 20 * 1024 * 1024))
MAX_INPUT_PIXELS = int(os.environ.get("PHOTO_RESTORE_MAX_INPUT_PIXELS", 2_000_000))
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
ALLOWED_EXTENSIONS = {".png", ".jpg", ".jpeg"}
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
        for name, sql_type in (("input_sha256", "TEXT"), ("output_sha256", "TEXT"), ("width", "INTEGER"), ("height", "INTEGER")):
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


def row_to_dict(row: sqlite3.Row) -> dict[str, object]:
    return {
        "id": row["id"],
        "state": row["state"],
        "original_name": row["original_name"],
        # Never expose worker output, tracebacks, commands or board paths through
        # the public API. This also sanitizes records created by older versions.
        "error": PUBLIC_PROCESSING_ERROR if row["state"] == "FAILED" else None,
        "input_sha256": row["input_sha256"],
        "output_sha256": row["output_sha256"],
        "width": row["width"],
        "height": row["height"],
        "created_at_utc": row["created_at_utc"],
        "updated_at_utc": row["updated_at_utc"],
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


def ensure_preview(row: sqlite3.Row, kind: str) -> Path:
    destination = preview_path(row, kind)
    if not destination.is_file():
        source = Path(row["input_path"] if kind == "input" else row["output_path"])
        if not source.is_file():
            raise HTTPException(status_code=409, detail=f"{kind} image is not ready")
        create_preview(source, destination)
    return destination


def process_job(job_id: str) -> None:
    row = get_job(job_id)
    input_path, output_path, report_path = map(Path, (row["input_path"], row["output_path"], row["report_path"]))
    output_preview_path = preview_path(row, "output")
    set_state(job_id, "RUNNING")
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
    try:
        with connect() as connection:
            connection.execute("SELECT 1").fetchone()
        database_ok = True
    except sqlite3.Error:
        pass
    ready = database_ok and MODEL.is_file() and WORKER.is_file() and (FRONTEND / "index.html").is_file()
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
        "queue_size": JOB_QUEUE.qsize(),
        "max_upload_bytes": MAX_UPLOAD_BYTES,
        "max_input_pixels": MAX_INPUT_PIXELS,
        "preview_max_edge": PREVIEW_MAX_EDGE,
        "job_retention_seconds": JOB_RETENTION_SECONDS,
        "max_storage_bytes": MAX_STORAGE_BYTES,
        "min_free_bytes": MIN_FREE_BYTES,
        "cleanup_interval_seconds": CLEANUP_INTERVAL_SECONDS,
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
