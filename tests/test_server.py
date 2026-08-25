import importlib.util
import os
import tempfile
import unittest
from pathlib import Path


class ServerInitializationTests(unittest.TestCase):
    def test_initialize_creates_isolated_layout(self) -> None:
        try:
            import fastapi  # noqa: F401
        except ImportError:
            self.skipTest("FastAPI is installed only in the board server environment")
        with tempfile.TemporaryDirectory() as directory:
            os.environ["PHOTO_RESTORE_ROOT"] = directory
            source = Path(__file__).resolve().parents[1] / "apps/server/app.py"
            spec = importlib.util.spec_from_file_location("photo_restore_server", source)
            module = importlib.util.module_from_spec(spec)
            assert spec.loader is not None
            spec.loader.exec_module(module)
            module.initialize()
            self.assertTrue((Path(directory) / "database/jobs.sqlite3").is_file())
            self.assertTrue((Path(directory) / "storage/jobs").is_dir())


if __name__ == "__main__":
    unittest.main()
