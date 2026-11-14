"""Run the real acceptance driver with a deterministic, disposable bcvk fake."""

import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


DRIVER = Path(__file__).with_name("transient-etc-vm-test.sh").resolve()
FAKE = '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
import time

args = sys.argv[1:]
operation = args[3]
mode = os.environ["FAKE_MODE"]
root = Path(os.environ["FAKE_ROOT"])
with (root / "calls").open("a") as log:
    log.write(operation + " " + args[-1][:80] + "\\n")
if operation == "run":
    if mode == "install-hang":
        time.sleep(60)
    sys.exit(0)
if operation == "rm":
    if mode.endswith("cleanup-hang"):
        time.sleep(60)
    sys.exit(23 if "cleanup-fail" in mode else 0)
command = args[-1]
if command.startswith(("journalctl", "cat /var/log", "auditctl")):
    if mode == "diagnostic-hang":
        time.sleep(60)
    sys.exit(27)
if mode == "ssh-hang":
    time.sleep(60)
if mode == "unreachable":
    sys.exit(255)
if "boot_id" in command:
    if (root / "reboot").exists() and mode == "reboot-hang":
        time.sleep(60)
    print("new" if (root / "reboot").exists() else "old")
elif command == "systemctl reboot":
    (root / "reboot").touch()
elif "python3 -I" in command:
    if mode.startswith("collector-fail"):
        sys.exit(42)
    print("mock observations")
sys.exit(0)
'''

ENCODER = '''#!/usr/bin/env python3
import os
import sys
if os.environ["FAKE_MODE"] == "encoding-fail" and sys.argv[-1].endswith("transient-etc-report.py"):
    sys.exit(66)
os.execv("/usr/bin/base64", ["base64", *sys.argv[1:]])
'''


class AcceptanceTests(unittest.TestCase):
    def run_driver(self, mode, keep=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / "bcvk"
            fake.write_text(FAKE)
            fake.chmod(0o700)
            encoder = root / "base64"
            encoder.write_text(ENCODER)
            encoder.chmod(0o700)
            report = root / "report.md"
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                       BCVK=str(fake), FAKE_MODE=mode,
                       FAKE_ROOT=directory, KEEP_FAILED_VM=str(int(keep)),
                       VM_CALL_TIMEOUT="1", INSTALL_TIMEOUT_SECS="1",
                       DIAGNOSTIC_TIMEOUT_SECS="1", CLEANUP_TIMEOUT_SECS="1",
                       # Bash SECONDS has one-second granularity; leave room
                       # for process startup at a tick boundary on busy CI.
                       BOOT_WAIT_SECS="3", EXERCISE_TIMEOUT_SECS="1")
            start = time.monotonic()
            result = subprocess.run(
                ["bash", str(DRIVER), "localhost/test:transient", str(report)],
                env=env, capture_output=True, text=True, timeout=12)
            self.assertLess(time.monotonic() - start, 11)
            text = report.read_text()
            calls = (root / "calls").read_text()
            self.assertIn(f"Acceptance exit status: {result.returncode}", text)
            self.assertEqual("**Acceptance passed;" in text, result.returncode == 0)
            return result.returncode, text, calls

    def test_success(self):
        status, text, calls = self.run_driver("success")
        self.assertEqual(status, 0)
        self.assertIn("Report collection passed", text)
        self.assertIn("\nrm ", calls)

    def test_bounded_hung_operations(self):
        for mode in ("install-hang", "ssh-hang", "reboot-hang"):
            with self.subTest(mode=mode):
                status, _, calls = self.run_driver(mode)
                self.assertNotEqual(status, 0)
                self.assertIn("\nrm ", calls)

    def test_unreachable_guest_retained(self):
        status, _, calls = self.run_driver("unreachable", keep=True)
        self.assertEqual(status, 255)
        self.assertNotIn("\nrm ", calls)

    def test_failed_collector_preserves_status_despite_cleanup(self):
        for mode in ("collector-fail-cleanup-fail", "collector-fail-cleanup-hang"):
            with self.subTest(mode=mode):
                status, text, _ = self.run_driver(mode)
                self.assertEqual(status, 42)
                self.assertIn("Report collection failed (exit 42)", text)
                self.assertIn("VM cleanup failed", text)

    def test_failed_collector_retained(self):
        status, text, calls = self.run_driver("collector-fail", keep=True)
        self.assertEqual(status, 42)
        self.assertIn("Report collection failed", text)
        self.assertNotIn("\nrm ", calls)

    def test_collector_loading_failure_rejects_success(self):
        status, text, calls = self.run_driver("encoding-fail")
        self.assertEqual(status, 66)
        self.assertIn("Report collection failed (exit 66)", text)
        self.assertIn("\nrm ", calls)

    def test_cleanup_failure_rejects_success(self):
        for mode in ("cleanup-fail", "cleanup-hang"):
            with self.subTest(mode=mode):
                status, text, _ = self.run_driver(mode)
                self.assertEqual(status, 23 if mode == "cleanup-fail" else 124)
                self.assertIn("VM cleanup failed", text)

    def test_best_effort_diagnostics_are_bounded(self):
        status, _, _ = self.run_driver("diagnostic-hang")
        self.assertEqual(status, 0)


if __name__ == "__main__":
    unittest.main()
