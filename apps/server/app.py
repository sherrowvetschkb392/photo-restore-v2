#!/usr/bin/env python3
"""Local HTTP entry point for the RK3588 photo restoration service."""

from __future__ import annotations

import os
import platform
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI


SERVICE_VERSION = "0.1.0"
ROOT = Path(os.environ.get("PHOTO_RESTORE_ROOT", "/userdata/photo-restore-v2"))
STORAGE = ROOT / "storage"
DATABASE = ROOT / "database" / "jobs.sqlite3"
MODEL = ROOT / "models" / "realesrgan_x4plus_tile96_fp16.rknn"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


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
    with sqlite3.connect(DATABASE) as connection:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY,
                state TEXT NOT NULL,
                original_name TEXT NOT NULL,
                input_path TEXT NOT NULL,
                output_path TEXT,
                report_path TEXT,
                error TEXT,
                created_at_utc TEXT NOT NULL,
                updated_at_utc TEXT NOT NULL
            )
            """
        )


app = FastAPI(title="Photo Restore V2", version=SERVICE_VERSION)


@app.on_event("startup")
def startup() -> None:
    initialize()


@app.get("/api/health")
def health() -> dict[str, object]:
    database_ok = False
    try:
        with sqlite3.connect(DATABASE) as connection:
            connection.execute("SELECT 1").fetchone()
        database_ok = True
    except sqlite3.Error:
        pass
    return {
        "status": "ok" if database_ok and MODEL.is_file() else "degraded",
        "service": "photo-restore-v2",
        "version": SERVICE_VERSION,
        "time_utc": utc_now(),
        "python": platform.python_version(),
        "architecture": platform.machine(),
        "root": str(ROOT),
        "database_ready": database_ok,
        "model_ready": MODEL.is_file(),
    }
