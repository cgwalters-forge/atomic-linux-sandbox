"""Synthetic audit/parser and acceptance tests; these do not validate a VM boot."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

TESTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("report", TESTS / "transient-etc-report.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def event(serial, names, success="yes", extra=""):
    lines = [f'type=SYSCALL msg=audit(123.000:{serial}): arch=c000003e syscall=257 '
             f'success={success} exit=3 items={len(names)} pid=42 ppid=1 comm="helper" exe="/usr/bin/helper" '
             f'key="atomic-linux-etc" {extra}',
             f'type=CWD msg=audit(123.000:{serial}): cwd="/etc"']
    for index, (name, kind) in enumerate(names):
        lines.append(f'type=PATH msg=audit(123.000:{serial}): item={index} name={name} nametype={kind}')
    return "\n".join(lines)


class ParserTests(unittest.TestCase):
    def test_audit_rule_reload_uses_file_mode(self):
        # auditctl only recognizes file mode with exactly `-R FILE`;
        # continue-on-error must be a directive inside that file instead.
        root = TESTS.parent / "custom/transient-etc/usr/lib"
        dropin = root / "systemd/system/audit-rules.service.d/50-atomic-linux-etc-watch.conf"
        command = next(line for line in dropin.read_text().splitlines()
                       if line.startswith("ExecStartPost="))
        self.assertEqual(command.split("=", 1)[1].split(), [
            "-/usr/bin/auditctl", "-R", "/usr/lib/atomic-linux/etc-watch.rules"])
        rules = [line for line in (root / "atomic-linux/etc-watch.rules").read_text().splitlines()
                 if line and not line.startswith("#")]
        self.assertEqual(rules, ["-c", "-d task,never", "-w /etc -p wa -k atomic-linux-etc"])

    def render(self, text, entries=()):
        return report.render_report("/run/upper", list(entries), report.parse_events(text),
                                    "enabled 1\nlost 7\nbacklog 3", "watch", "active")

    def test_create_then_delete_survives_in_report(self):
        text = event(1, [('"/etc/vanished"', "CREATE")]) + "\n" + event(
            2, [('"/etc/vanished"', "DELETE")])
        out = self.render(text)
        self.assertEqual(out.count("| /etc/vanished |"), 2)
        self.assertIn("CREATE", out)
        self.assertIn("DELETE", out)
        self.assertIn("successful watched operation", out)

    def test_rename_lists_both_endpoints(self):
        rows = report.observations(report.parse_events(event(1, [
            ('"/etc/old"', "DELETE"), ('"/etc/new"', "CREATE"), ('"/etc"', "PARENT")])))
        self.assertEqual([r[0] for r in rows], ["/etc/old", "/etc/new"])

    def test_failed_attempt_does_not_attribute_upperdir(self):
        out = self.render(event(1, [('"/etc/denied"', "NORMAL")], "no"),
                          [("/etc/denied", "file")])
        self.assertIn("failed attempt", out)
        self.assertNotIn("see successful", out)
        self.assertIn("unattributed (upperdir only)", out)

    def test_ambiguous_basename_never_matches(self):
        out = self.render(event(1, [('"config"', "CREATE")]),
                          [("/etc/a/config", "file"), ("/etc/b/config", "file")])
        self.assertEqual(out.count("unattributed (upperdir only)"), 2)
        self.assertIn("unresolved relative path", out)
        self.assertNotIn("see successful", out)

    def test_exact_match_and_upperdir_only_directory(self):
        out = self.render(event(1, [('"/etc/a/config"', "NORMAL")]),
                          [("/etc/a/config", "file"), ("/etc/a", "dir")])
        self.assertIn("/etc/a/config | file | see successful", out)
        self.assertIn("/etc/a | dir | unattributed", out)

    def test_hex_names_spaces_and_markdown(self):
        name = "/etc/a b|<c>"
        rows = report.observations(report.parse_events(event(1, [(name.encode().hex(), "CREATE")])))
        self.assertEqual(rows[0][0], name)
        out = self.render(event(1, [(name.encode().hex(), "CREATE")]))
        self.assertIn("a b&#124;&lt;c&gt;", out)

    def test_no_pid_lookup_or_parent_guess(self):
        with patch.object(report, "run", side_effect=AssertionError("PID lookup")):
            out = self.render(event(1, [('"/etc/config"', "NORMAL")]))
        self.assertIn("service unknown", out)
        self.assertNotIn("parent in", out)
        recorded = self.render(event(1, [('"/etc/config"', "NORMAL")], extra='unit="test.service"'))
        self.assertIn("recorded unit: test.service", recorded)

    def test_event_time_cgroup_only(self):
        for cgroup, expected in (("/system.slice/test.service/helper", "recorded cgroup unit: test.service"),
                                 ("/user.slice/session.scope", "service unknown"),
                                 ("test.service", "service unknown"),
                                 ("/a.service/b.service", "service unknown")):
            with self.subTest(cgroup=cgroup):
                out = self.render(event(1, [('"/etc/config"', "NORMAL")], extra=f'cgroup="{cgroup}"'))
                self.assertIn(expected, out)

    def test_loss_early_boot_and_incomplete_groups_visible(self):
        out = self.render('type=PATH msg=audit(123.000:1): name="/etc/lost" nametype=CREATE')
        self.assertIn("lost 7", out)
        self.assertIn("Early-boot gap", out)
        self.assertIn("Incomplete event groups: 1", out)
        self.assertIn("task,never", out)

    def test_partial_multi_path_event(self):
        text = event(1, [('"/etc/old"', "DELETE"), ('"/etc/new"', "CREATE")])
        self.assertIn("Incomplete event groups: 0", self.render(text))
        out = self.render("\n".join(text.splitlines()[:-1]))
        self.assertIn("Incomplete event groups: 1", out)
        self.assertIn("expected items=2; received PATH indexes=['0']", out)
        self.assertIn("| /etc/old |", out)

    def test_path_metadata_mismatch(self):
        text = event(1, [('"/etc/old"', "DELETE"), ('"/etc/new"', "CREATE")])
        for broken in (text.replace("item=1", "item=0"), text.replace("item=1", "item=2"),
                       text.replace("items=2", "items=invalid"), text.replace("items=2", ""),
                       text.replace("item=1", "item=invalid"), text.replace("items=2", "items=999999999999")):
            with self.subTest(broken=broken):
                self.assertIn("Incomplete event groups: 1", self.render(broken))

    def test_null_and_parent_paths_count(self):
        out = self.render(event(1, [('(null)', "UNKNOWN"), ('"/etc"', "PARENT")]))
        self.assertIn("Incomplete event groups: 0", out)
        self.assertNotIn("| (null) |", out)

    def test_unknown_outcome_not_successful(self):
        out = self.render(event(1, [('"/etc/config"', "NORMAL")], "unknown"))
        self.assertIn("outcome unknown", out)
        self.assertNotIn("| successful watched operation |", out)

    def test_ausearch_errors_and_empty_results_fail(self):
        for code, text in ((2, "bad input"), (1, "<no matches>"), (0, "")):
            with self.subTest(code=code), patch.object(report, "run", return_value=
                    subprocess.CompletedProcess([], code, text, "error")):
                with self.assertRaises(RuntimeError):
                    report.audit_events()

    def test_walk_errors_fail(self):
        with patch.object(report.os, "walk") as walk:
            walk.side_effect = lambda *a, **kw: kw["onerror"](PermissionError("denied"))
            with self.assertRaises(PermissionError):
                list(report.upper_entries("/missing"))


class WatchTests(unittest.TestCase):
    STATE = {"ActiveState": "active", "SubState": "exited", "Result": "success",
             "ExecMainStatus": "0", "ConditionResult": "yes", "ActiveEnterTimestampMonotonic": "123"}

    def test_successful_activation(self):
        text = "\n".join(f"{k}={v}" for k, v in self.STATE.items())
        with patch.object(report, "checked", return_value=text):
            self.assertEqual(report.require_early_watch(), text)

    def test_failed_skipped_inactive_or_missing_activation_rejected(self):
        for key, value in (("ActiveState", "failed"), ("ActiveState", "inactive"),
                           ("SubState", "dead"), ("Result", "exit-code"),
                           ("ExecMainStatus", "1"), ("ConditionResult", "no"),
                           ("ActiveEnterTimestampMonotonic", "0"),
                           ("ActiveEnterTimestampMonotonic", "invalid")):
            fields = dict(self.STATE, **{key: value})
            with self.subTest(key=key, value=value), patch.object(report, "checked", return_value=
                    "\n".join(f"{k}={v}" for k, v in fields.items())):
                with self.assertRaisesRegex(RuntimeError, "did not activate"):
                    report.require_early_watch()
        with patch.object(report, "checked", return_value=""):
            with self.assertRaises(RuntimeError):
                report.require_early_watch()

    def test_main_requires_early_activation_even_with_late_watch(self):
        with patch.object(report, "upperdir", return_value="/run/upper"), patch.object(
                report, "checked", side_effect=["enabled 1", "-w /etc -p wa -k atomic-linux-etc", ""]):
            with self.assertRaisesRegex(RuntimeError, "did not activate"):
                report.main()


class AcceptanceTests(unittest.TestCase):
    def run_fake_vm(self, mode):
        """Only emulate the transport: verify failure propagation, not boot."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bcvk = root / "bcvk"
            bcvk.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
if "ssh" not in args:
    sys.exit(0)
cmd = args[-1]
if cmd == "cat /proc/sys/kernel/random/boot_id":
    state = Path(os.environ["FAKE_STATE"])
    count = int(state.read_text()) if state.exists() else 0
    state.write_text(str(count + 1))
    print(count)
elif cmd.startswith("test ! -e") and os.environ["FAKE_MODE"] == "lost-ssh":
    sys.exit(255)
elif "python3 -I" in cmd:
    print("collector broke", file=sys.stderr)
    sys.exit(9 if os.environ["FAKE_MODE"] == "collector-fails" else 0)
elif "base64 -d" in cmd:
    print("- **failed** (exit 1): synthetic service failure")
''')
            bcvk.chmod(0o755)
            sleep = root / "sleep"
            sleep.write_text("#!/bin/sh\nexit 0\n")
            sleep.chmod(0o755)
            output = root / "report.md"
            env = dict(os.environ, BCVK=str(bcvk), FAKE_MODE=mode,
                       FAKE_STATE=str(root / "state"), PATH=f"{root}:{os.environ['PATH']}")
            result = subprocess.run(["bash", str(TESTS / "transient-etc-vm-test.sh"),
                                     "fake:transient", str(output)], env=env,
                                    capture_output=True, text=True, timeout=30)
            return result, output.read_text(), (root / "report-diagnostics/collector.log").exists()

    def test_collector_failure_fails_acceptance(self):
        result, text, diagnostic = self.run_fake_vm("collector-fails")
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertIn("acceptance FAILED", text)
        self.assertNotIn("Acceptance passed", text)
        self.assertTrue(diagnostic)

    def test_service_failures_visible_but_non_gating(self):
        result, text, _ = self.run_fake_vm("service-fails")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("synthetic service failure", text)

    def test_lost_ssh_not_marker_disappearance(self):
        result, text, _ = self.run_fake_vm("lost-ssh")
        self.assertEqual(result.returncode, 255, result.stderr)
        self.assertNotIn("Acceptance passed", text)


if __name__ == "__main__":
    unittest.main()
