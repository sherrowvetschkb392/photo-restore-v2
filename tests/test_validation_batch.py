import hashlib
import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
BATCH_SCRIPT = PROJECT_ROOT / "apps/worker/validation_batch.py"


class ValidationBatchTests(unittest.TestCase):
    def test_two_image_batch_writes_verified_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            input_dir = root / "input"
            output_dir = root / "output"
            report_dir = root / "reports"
            input_dir.mkdir()
            items = []
            for index in (1, 2):
                filename = f"sample-{index}.png"
                data = f"validation-input-{index}".encode()
                (input_dir / filename).write_bytes(data)
                items.append(
                    {
                        "filename": filename,
                        "sha256": hashlib.sha256(data).hexdigest(),
                    }
                )

            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps({"dataset": "test-set", "items": items}), encoding="utf-8"
            )
            model = root / "model.rknn"
            model.write_bytes(b"fake-rknn-model")
            worker = root / "fake_worker.py"
            worker.write_text(
                textwrap.dedent(
                    """
                    import argparse, hashlib, json
                    from pathlib import Path
                    p=argparse.ArgumentParser()
                    p.add_argument('--input',type=Path,required=True)
                    p.add_argument('--output',type=Path,required=True)
                    p.add_argument('--model',type=Path,required=True)
                    p.add_argument('--report',type=Path,required=True)
                    p.add_argument('--max-input-pixels')
                    a=p.parse_args()
                    data=a.input.read_bytes()
                    a.output.parent.mkdir(parents=True,exist_ok=True)
                    a.output.write_bytes(data+b'-restored')
                    a.report.parent.mkdir(parents=True,exist_ok=True)
                    sha=lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
                    a.report.write_text(json.dumps({
                      'input_sha256':sha(a.input),'output_sha256':sha(a.output),
                      'plan':{'input_size':[10,10],'tile_count':1},
                      'output_size':[40,40],'inference_seconds':0.01,
                      'total_seconds':0.02,'max_rss_kib':1000
                    }),encoding='utf-8')
                    """
                ),
                encoding="utf-8",
            )
            summary = root / "summary.json"
            status = root / "status.json"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(BATCH_SCRIPT),
                    "--manifest",
                    str(manifest),
                    "--input-dir",
                    str(input_dir),
                    "--output-dir",
                    str(output_dir),
                    "--report-dir",
                    str(report_dir),
                    "--summary",
                    str(summary),
                    "--status",
                    str(status),
                    "--worker",
                    str(worker),
                    "--model",
                    str(model),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("RESULT=PASS_BOARD_VALIDATION_BATCH", completed.stdout)
            summary_data = json.loads(summary.read_text(encoding="utf-8"))
            status_data = json.loads(status.read_text(encoding="utf-8"))
            self.assertEqual(summary_data["image_count"], 2)
            self.assertEqual(len(summary_data["results"]), 2)
            self.assertEqual(status_data["state"], "COMPLETE")
            self.assertEqual(status_data["completed"], 2)
            for item in summary_data["results"]:
                output = output_dir / item["output_name"]
                self.assertTrue(output.is_file())
                self.assertEqual(
                    hashlib.sha256(output.read_bytes()).hexdigest(),
                    item["output_sha256"],
                )

    def test_batch_resumes_verified_completed_image(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            input_dir, output_dir, report_dir = (root / name for name in ("input", "output", "reports"))
            input_dir.mkdir(); output_dir.mkdir(); report_dir.mkdir()
            data = b"already-computed"
            input_path = input_dir / "sample.png"
            input_path.write_bytes(data)
            output_path = output_dir / "sample-x4.png"
            output_path.write_bytes(data + b"-restored")
            sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            report = {
                "input_sha256": sha(input_path), "output_sha256": sha(output_path),
                "plan": {"input_size": [10, 10], "tile_count": 1},
                "output_size": [40, 40], "inference_seconds": 0.0,
                "total_seconds": 0.0, "max_rss_kib": 1,
            }
            (report_dir / "sample-report.json").write_text(json.dumps(report), encoding="utf-8")
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"dataset": "resume-set", "items": [{"filename": "sample.png", "sha256": sha(input_path)}]}), encoding="utf-8")
            model = root / "model.rknn"; model.write_bytes(b"model")
            worker = root / "worker.py"
            worker.write_text("raise SystemExit('worker should not run during resume')", encoding="utf-8")
            summary, status = root / "summary.json", root / "status.json"
            completed = subprocess.run([
                sys.executable, str(BATCH_SCRIPT), "--manifest", str(manifest),
                "--input-dir", str(input_dir), "--output-dir", str(output_dir),
                "--report-dir", str(report_dir), "--summary", str(summary),
                "--status", str(status), "--worker", str(worker), "--model", str(model),
            ], check=False, capture_output=True, text=True)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("BATCH_IMAGE_RESUME", completed.stdout)
            self.assertEqual(json.loads(status.read_text())["state"], "COMPLETE")


if __name__ == "__main__":
    unittest.main()
