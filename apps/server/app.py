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
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from PIL import Image, UnidentifiedImageError

SERVICE_VERSION = "0.2.0"
ROOT = Path(os.environ.get("PHOTO_RESTORE_ROOT", "/userdata/photo-restore-v2"))
STORAGE = ROOT / "storage"
DATABASE = ROOT / "database" / "jobs.sqlite3"
MODEL = ROOT / "models" / "realesrgan_x4plus_tile96_fp16.rknn"
WORKER = ROOT / "app" / "worker" / "restore_image.py"
PYTHON = ROOT / "venv" / "bin" / "python"
MAX_UPLOAD_BYTES = int(os.environ.get("PHOTO_RESTORE_MAX_UPLOAD_BYTES", 20 * 1024 * 1024))
MAX_INPUT_PIXELS = int(os.environ.get("PHOTO_RESTORE_MAX_INPUT_PIXELS", 2_000_000))
ALLOWED_EXTENSIONS = {".png", ".jpg", ".jpeg"}
JOB_QUEUE: queue.Queue[str] = queue.Queue()
STOP = threading.Event()
WORKER_THREAD: threading.Thread | None = None


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def connect() -> sqlite3.Connection:
    connection = sqlite3.connect(DATABASE, timeout=30)
    connection.row_factory = sqlite3.Row
    return connection


def initialize() -> None:
    for path in (STORAGE / "incoming", STORAGE / "jobs", STORAGE / "outputs", STORAGE / "reports", STORAGE / "tmp", DATABASE.parent):
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


def row_to_dict(row: sqlite3.Row) -> dict[str, object]:
    return {
        "id": row["id"],
        "state": row["state"],
        "original_name": row["original_name"],
        "error": row["error"],
        "input_sha256": row["input_sha256"],
        "output_sha256": row["output_sha256"],
        "width": row["width"],
        "height": row["height"],
        "created_at_utc": row["created_at_utc"],
        "updated_at_utc": row["updated_at_utc"],
        "input_url": f"/api/jobs/{row['id']}/input",
        "output_url": f"/api/jobs/{row['id']}/output" if row["state"] == "COMPLETE" else None,
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


def process_job(job_id: str) -> None:
    row = get_job(job_id)
    input_path, output_path, report_path = map(Path, (row["input_path"], row["output_path"], row["report_path"]))
    set_state(job_id, "RUNNING")
    command = [str(PYTHON), str(WORKER), "--input", str(input_path), "--output", str(output_path), "--model", str(MODEL), "--report", str(report_path), "--max-input-pixels", str(MAX_INPUT_PIXELS)]
    completed = subprocess.run(command, capture_output=True, text=True, timeout=3600)
    (input_path.parent / "worker.log").write_text(completed.stdout + completed.stderr, encoding="utf-8")
    if completed.returncode != 0 or not output_path.is_file() or not report_path.is_file():
        raise RuntimeError(f"worker exit {completed.returncode}: {(completed.stderr or completed.stdout)[-1000:]}")
    set_state(job_id, "COMPLETE", output_sha256=sha256(output_path))


def worker_loop() -> None:
    while not STOP.is_set():
        try:
            job_id = JOB_QUEUE.get(timeout=1)
        except queue.Empty:
            continue
        try:
            process_job(job_id)
        except Exception as exc:
            set_state(job_id, "FAILED", f"{type(exc).__name__}: {exc}")
        finally:
            JOB_QUEUE.task_done()


def enqueue_existing() -> None:
    with connect() as connection:
        rows = connection.execute("SELECT id FROM jobs WHERE state='QUEUED' ORDER BY created_at_utc").fetchall()
    for row in rows:
        JOB_QUEUE.put(row["id"])


app = FastAPI(title="Photo Restore V2", version=SERVICE_VERSION)


@app.on_event("startup")
def startup() -> None:
    global WORKER_THREAD
    initialize()
    enqueue_existing()
    WORKER_THREAD = threading.Thread(target=worker_loop, name="npu-worker", daemon=True)
    WORKER_THREAD.start()


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
    ready = database_ok and MODEL.is_file() and WORKER.is_file()
    return {"status": "ok" if ready else "degraded", "service": "photo-restore-v2", "version": SERVICE_VERSION, "time_utc": utc_now(), "python": platform.python_version(), "architecture": platform.machine(), "database_ready": database_ok, "model_ready": MODEL.is_file(), "worker_ready": WORKER.is_file(), "queue_size": JOB_QUEUE.qsize(), "max_upload_bytes": MAX_UPLOAD_BYTES, "max_input_pixels": MAX_INPUT_PIXELS}


@app.post("/api/jobs", status_code=202)
def create_job(file: UploadFile = File(...)) -> dict[str, object]:
    original_name = Path(file.filename or "upload").name
    extension = Path(original_name).suffix.lower()
    if extension not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=415, detail="only PNG and JPEG are supported")
    job_id = uuid.uuid4().hex
    job_dir = STORAGE / "jobs" / job_id
    job_dir.mkdir(parents=True)
    input_path, output_path, report_path = job_dir / f"input{extension}", job_dir / "output.png", job_dir / "report.json"
    size = 0
    digest = hashlib.sha256()
    try:
        with input_path.open("xb") as stream:
            while chunk := file.file.read(1024 * 1024):
                size += len(chunk)
                if size > MAX_UPLOAD_BYTES:
                    raise HTTPException(status_code=413, detail="upload exceeds size limit")
                digest.update(chunk)
                stream.write(chunk)
        with Image.open(input_path) as image:
            image.verify()
        with Image.open(input_path) as image:
            width, height = image.size
        if width * height > MAX_INPUT_PIXELS:
            raise HTTPException(status_code=413, detail=f"image has {width * height} pixels; limit is {MAX_INPUT_PIXELS}")
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


@app.get("/api/jobs/{job_id}/output")
def job_output(job_id: str) -> FileResponse:
    row = get_job(job_id)
    if row["state"] != "COMPLETE" or not Path(row["output_path"]).is_file():
        raise HTTPException(status_code=409, detail="output is not ready")
    return FileResponse(row["output_path"], media_type="image/png", filename=f"{Path(row['original_name']).stem}-x4.png")


@app.get("/api/jobs/{job_id}/report")
def job_report(job_id: str) -> FileResponse:
    row = get_job(job_id)
    if row["state"] != "COMPLETE" or not Path(row["report_path"]).is_file():
        raise HTTPException(status_code=409, detail="report is not ready")
    return FileResponse(row["report_path"], media_type="application/json", filename=f"{job_id}-report.json")


@app.delete("/api/jobs/{job_id}")
def delete_job(job_id: str) -> dict[str, object]:
    row = get_job(job_id)
    if row["state"] == "RUNNING":
        raise HTTPException(status_code=409, detail="a running job cannot be deleted")
    with connect() as connection:
        connection.execute("DELETE FROM jobs WHERE id=?", (job_id,))
    shutil.rmtree(Path(row["input_path"]).parent, ignore_errors=True)
    return {"deleted": True, "job_id": job_id}
