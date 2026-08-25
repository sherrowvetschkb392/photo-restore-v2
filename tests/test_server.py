import importlib.util
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path

from PIL import Image


class ServerInitializationTests(unittest.TestCase):
    def load_server(self, directory: str):
        os.environ["PHOTO_RESTORE_ROOT"] = directory
        source = Path(__file__).resolve().parents[1] / "apps/server/app.py"
        spec = importlib.util.spec_from_file_location("photo_restore_server", source)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module

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


if __name__ == "__main__":
    unittest.main()
