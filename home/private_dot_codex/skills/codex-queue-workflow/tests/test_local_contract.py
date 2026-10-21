"""Local queue contract: private state, durable identity, and no duplicate work."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "completion_notify", Path(__file__).parents[1] / "scripts/completion_notify.py")
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)
THREAD = "01a0cd3a-d21d-7ca2-ad8e-34884d397ea8"


class LocalContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.request = {"argv": [sys.executable, "-c", "print('finished')"],
                        "cwd": str(self.root), "codex": sys.executable, "thread": THREAD}

    def start(self, folder):
        source = self.root / "input.json"
        source.write_text(json.dumps(self.request))
        with patch.object(sys, "argv", ["notify", "start", "--request", str(source),
                                       "--run-dir", str(folder)]), \
                patch.object(n, "validate_target"), patch("builtins.print"):
            return n.main()

    def test_private_directory_and_files_under_permissive_umask(self):
        folder = self.root / "job"
        old = os.umask(0)
        try:
            with patch.object(n.subprocess, "Popen") as launch:
                launch.return_value.pid = 123
                self.start(folder)
        finally:
            os.umask(old)
        self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
        for path in folder.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600, path.name)

    def test_supervisor_pid_is_durable(self):
        folder = self.root / "job"
        with patch.object(n.subprocess, "Popen") as launch:
            launch.return_value.pid = 123
            self.start(folder)
        self.assertTrue((folder / "supervisor.json").exists(), "PID lost after terminal handoff")
        self.assertEqual(json.loads((folder / "supervisor.json").read_text())["pid"], 123)

    def test_duplicate_start_does_not_launch_second_supervisor(self):
        folder = self.root / "job"
        with patch.object(n.subprocess, "Popen") as launch:
            launch.return_value.pid = 123
            self.start(folder)
            with self.assertRaises(FileExistsError):
                self.start(folder)
        launch.assert_called_once()

    def test_repeated_supervisor_does_not_repeat_work(self):
        with patch.object(n, "notify", return_value={"status": "queued"}), \
                patch.object(n.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            n.execute(self.request, self.root)
            n.execute(self.request, self.root)
        self.assertEqual(run.call_count, 1, "Supervisor replay ran the command twice")

    def test_terminal_receipt_retains_identity_and_pid(self):
        with patch.object(n, "notify", return_value={"status": "queued"}):
            n.execute(self.request, self.root)
        result = json.loads((self.root / "process.json").read_text())
        self.assertEqual(result.get("thread"), THREAD)
        self.assertEqual(result.get("cwd"), str(self.root))
        self.assertIsInstance(result.get("pid"), int)
        self.assertIn("finished_at", result)
        self.assertEqual((self.root / "stdout.log").read_text().strip(), "finished")

    def test_nonterminal_receipt_cannot_queue_completion(self):
        receipt = self.root / "process.json"
        receipt.write_text('{"status":"running"}')
        with patch.object(n.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            n.notify(sys.executable, THREAD, receipt)
        run.assert_not_called()

    def test_callback_preserves_newer_stop_instruction(self):
        receipt = self.root / "process.json"
        receipt.write_text('{"status":"exited","exit_code":0}')
        with patch.object(n.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            n.notify(sys.executable, THREAD, receipt)
        self.assertIn("stop", run.call_args.args[0][-1])
        self.assertIn("pause", run.call_args.args[0][-1])

    def test_wrong_thread_cannot_receive_receipt(self):
        receipt = self.root / "process.json"
        receipt.write_text(json.dumps({"status": "exited", "thread": THREAD, "exit_code": 0}))
        with patch.object(n.subprocess, "run") as run:
            result = n.notify(sys.executable, "01a07282-493e-7311-87b5-b15beeac50cb", receipt)
        self.assertEqual(result["status"], "failed")
        self.assertFalse((self.root / "process.notification.json").exists())
        run.assert_not_called()

    def test_supervisor_spawn_failure_preserves_result(self):
        folder = self.root / "failed-supervisor"
        with patch.object(n.subprocess, "Popen", side_effect=OSError("spawn denied")):
            with self.assertRaises(OSError):
                self.start(folder)
        result = json.loads((folder / "process.json").read_text())
        self.assertEqual(result["status"], "launch_failed")
        self.assertEqual(result["thread"], THREAD)
        self.assertIn("spawn denied", result["error"])


if __name__ == "__main__":
    unittest.main()
