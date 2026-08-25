from __future__ import annotations

import importlib.util
import os
import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from PIL import Image


class ServerInitializationTests(unittest.TestCase):
    def load_server(self, directory: str):
        os.environ["PHOTO_RESTORE_ROOT"] = directory
        source_override = os.environ.get("PHOTO_RESTORE_SERVER_SOURCE")
        source = (
            Path(source_override)
            if source_override
            else Path(__file__).resolve().parents[1] / "apps/server/app.py"
        )
        spec = importlib.util.spec_from_file_location("photo_restore_server", source)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module

    def insert_job(
        self,
        module,
        *,
        job_id: str,
        state: str,
        updated_at: str,
        directory: Path | None = None,
    ) -> Path:
        job_dir = directory or (module.STORAGE / "jobs" / job_id)
        job_dir.mkdir(parents=True, exist_ok=True)
        input_path = job_dir / "input.png"
        input_path.write_bytes(b"input")
        with module.connect() as connection:
            connection.execute(
                """INSERT INTO jobs (
                    id,state,original_name,input_path,output_path,report_path,error,
                    created_at_utc,updated_at_utc
                ) VALUES (?,?,?,?,?,?,?,?,?)""",
                (
                    job_id,
                    state,
                    "photo.png",
                    str(input_path),
                    str(job_dir / "output.png"),
                    str(job_dir / "report.json"),
                    None,
                    updated_at,
                    updated_at,
                ),
            )
        return job_dir

    def test_initialize_creates_isolated_layout(self) -> None:
        try:
            import fastapi  # noqa: F401
        except ImportError:
            self.skipTest("FastAPI is installed only in the board server environment")
        with tempfile.TemporaryDirectory() as directory:
            module = self.load_server(directory)
            module.initialize()
            self.assertTrue((Path(directory) / "database/jobs.sqlite3").is_file())
            self.assertTrue((Path(directory) / "storage/jobs").is_dir())

    def test_version_and_retention_defaults_are_fixed(self) -> None:
        try:
            import fastapi  # noqa: F401
        except ImportError:
            self.skipTest("FastAPI is installed only in the board server environment")
        with tempfile.TemporaryDirectory() as directory:
            module = self.load_server(directory)
            self.assertEqual(module.SERVICE_VERSION, "0.4.0")
            self.assertEqual(module.JOB_RETENTION_SECONDS, 604800)
            self.assertEqual(module.MAX_STORAGE_BYTES, 4294967296)
            self.assertEqual(module.MIN_FREE_BYTES, 2147483648)
            self.assertEqual(module.CLEANUP_INTERVAL_SECONDS, 900)

    def test_failed_job_response_never_exposes_internal_error(self) -> None:
        try:
            import fastapi  # noqa: F401
        except ImportError:
            self.skipTest("FastAPI is installed only in the board server environment")
        with tempfile.TemporaryDirectory() as directory:
            module = self.load_server(directory)
            module.initialize()
            now = module.utc_now()
            with module.connect() as connection:
                connection.execute(
                    """INSERT INTO jobs (
                        id,state,original_name,input_path,output_path,report_path,error,
                        created_at_utc,updated_at_utc
                    ) VALUES (?,?,?,?,?,?,?,?,?)""",
                    (
                        "failed-job", "FAILED", "photo.png", "/userdata/private/input.png",
                        "/userdata/private/output.png", "/userdata/private/report.json",
                        "Traceback: secret internal path", now, now,
                    ),
                )
            response = module.row_to_dict(module.get_job("failed-job"))
            self.assertEqual(response["error"], module.PUBLIC_PROCESSING_ERROR)
            self.assertNotIn("Traceback", response["error"])
            self.assertNotIn("/userdata", response["error"])

    def test_preview_is_bounded_and_history_compatible(self) -> None:
        try:
            import fastapi  # noqa: F401
        except ImportError:
            self.skipTest("FastAPI is installed only in the board server environment")
        with tempfile.TemporaryDirectory() as directory:
            module = self.load_server(directory)
            module.initialize()
            job_dir = Path(directory) / "storage/jobs/preview-job"
            job_dir.mkdir(parents=True)
            input_path = job_dir / "input.png"
            output_path = job_dir / "output.png"
            report_path = job_dir / "report.json"
            Image.new("RGB", (510, 384), (20, 40, 60)).save(input_path)
            Image.new("RGB", (2040, 1536), (60, 40, 20)).save(output_path)
            now = module.utc_now()
            with module.connect() as connection:
                connection.execute(
                    """INSERT INTO jobs (
                        id,state,original_name,input_path,output_path,report_path,
                        created_at_utc,updated_at_utc
                    ) VALUES (?,?,?,?,?,?,?,?)""",
                    (
                        "preview-job", "COMPLETE", "photo.png", str(input_path),
                        str(output_path), str(report_path), now, now,
                    ),
                )
            row: sqlite3.Row = module.get_job("preview-job")
            input_preview = module.ensure_preview(row, "input")
            output_preview = module.ensure_preview(row, "output")
            with Image.open(input_preview) as image:
                self.assertEqual(image.size, (510, 384))
                self.assertEqual(image.format, "JPEG")
            with Image.open(output_preview) as image:
                self.assertEqual(image.size, (1600, 1205))
                self.assertEqual(image.format, "JPEG")
            response = module.row_to_dict(row)
            self.assertEqual(
                response["output_preview_url"],
                "/api/jobs/preview-job/output/preview",
            )

    def test_cleanup_removes_only_expired_terminal_jobs(self) -> None:
        try:
            import fastapi  # noqa: F401
        except ImportError:
            self.skipTest("FastAPI is installed only in the board server environment")
        with tempfile.TemporaryDirectory() as directory:
            module = self.load_server(directory)
            module.initialize()
            module.JOB_RETENTION_SECONDS = 3600
            module.MAX_STORAGE_BYTES = 0
            module.MIN_FREE_BYTES = 0
            now = datetime.now(timezone.utc)
            expired = self.insert_job(
                module,
                job_id="expired-complete",
                state="COMPLETE",
                updated_at=(now - timedelta(hours=2)).isoformat(),
            )
            recent = self.insert_job(
                module,
                job_id="recent-complete",
                state="COMPLETE",
                updated_at=now.isoformat(),
            )
            queued = self.insert_job(
                module,
                job_id="old-queued",
                state="QUEUED",
                updated_at=(now - timedelta(days=2)).isoformat(),
            )
            running = self.insert_job(
                module,
                job_id="old-running",
                state="RUNNING",
                updated_at=(now - timedelta(days=2)).isoformat(),
            )
            summary = module.cleanup_storage(now)
            self.assertEqual(summary["deleted_jobs"], 1)
            self.assertFalse(expired.exists())
            self.assertTrue(recent.exists())
            self.assertTrue(queued.exists())
            self.assertTrue(running.exists())
            with module.connect() as connection:
                ids = {row["id"] for row in connection.execute("SELECT id FROM jobs")}
            self.assertNotIn("expired-complete", ids)
            self.assertIn("old-queued", ids)
            self.assertIn("old-running", ids)

    def test_cleanup_refuses_job_directory_outside_storage_root(self) -> None:
        try:
            import fastapi  # noqa: F401
        except ImportError:
            self.skipTest("FastAPI is installed only in the board server environment")
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            module = self.load_server(directory)
            module.initialize()
            module.JOB_RETENTION_SECONDS = 0
            module.MAX_STORAGE_BYTES = 0
            module.MIN_FREE_BYTES = 0
            outside_dir = Path(outside) / "do-not-delete"
            now = datetime.now(timezone.utc).isoformat()
            self.insert_job(
                module,
                job_id="unsafe-job",
                state="FAILED",
                updated_at=now,
                directory=outside_dir,
            )
            summary = module.cleanup_storage()
            self.assertEqual(summary["deleted_jobs"], 0)
            self.assertTrue(outside_dir.exists())
            self.assertEqual(module.get_job("unsafe-job")["state"], "FAILED")

    def test_cleanup_evicts_oldest_terminal_job_for_required_capacity(self) -> None:
        try:
            import fastapi  # noqa: F401
        except ImportError:
            self.skipTest("FastAPI is installed only in the board server environment")
        with tempfile.TemporaryDirectory() as directory:
            module = self.load_server(directory)
            module.initialize()
            module.JOB_RETENTION_SECONDS = 30 * 24 * 3600
            module.MIN_FREE_BYTES = 0
            now = datetime.now(timezone.utc)
            oldest = self.insert_job(
                module,
                job_id="oldest-complete",
                state="COMPLETE",
                updated_at=(now - timedelta(hours=2)).isoformat(),
            )
            newest = self.insert_job(
                module,
                job_id="newest-complete",
                state="COMPLETE",
                updated_at=(now - timedelta(hours=1)).isoformat(),
            )
            used = module.tree_size(module.STORAGE)
            module.MAX_STORAGE_BYTES = used + 1
            summary = module.cleanup_storage(now, required_bytes=2)
            self.assertEqual(summary["deleted_jobs"], 1)
            self.assertFalse(oldest.exists())
            self.assertTrue(newest.exists())


if __name__ == "__main__":
    unittest.main()
