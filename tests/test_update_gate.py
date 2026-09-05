"""Gate tests never invoke a real updater or change desktop configuration."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "integration"))
import update_gate as gate


def snapshot(readiness="ready"):
    return {"ok": True, "schemaVersion": 1, "scanId": "scan-1", "completedAt": "now",
            "readiness": readiness, "checkCount": 1,
            "results": [{"id": "one", "status": "pass", "summary": "Good"}],
            "baseline": {"schemaVersion": 1}}


class GateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def test_settings_default_off_and_round_trip(self):
        self.assertFalse(gate.enabled(self.directory))
        path = self.directory / "update-settings.json"
        for active in (True, False):
            gate.atomic_json(path, {"schemaVersion": 1, "enabled": active})
            self.assertEqual(gate.enabled(self.directory), active)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_bad_settings_never_silently_disable_gate(self):
        path = self.directory / "update-settings.json"
        for text in ('null', '{}', '{', '[]', '{"schemaVersion":2,"enabled":false}',
                     '{"schemaVersion":1,"enabled":"false"}'):
            with self.subTest(text=text):
                path.write_text(text)
                with self.assertRaises(gate.GateError):
                    gate.enabled(self.directory)

    def test_settings_reads_refuse_symlinks_fifos_and_oversize(self):
        path = self.directory / "update-settings.json"
        target = self.directory / "target"
        target.write_text('{}')
        path.symlink_to(target)
        with self.assertRaises(OSError):
            gate.enabled(self.directory)
        path.unlink()
        os.mkfifo(path)
        with self.assertRaises(gate.GateError):
            gate.enabled(self.directory)
        path.unlink()
        path.write_bytes(b' ' * 8193)
        with self.assertRaises(gate.GateError):
            gate.enabled(self.directory)

    def test_disabled_update_goes_straight_to_omarchy_without_ipc(self):
        with patch.object(gate, "state_dir", return_value=self.directory), \
             patch.object(gate, "scan") as scan, \
             patch.object(gate, "acquire_update_lock") as lock, \
             patch.object(gate.shutil, "which", return_value="/real/omarchy"), \
             patch.object(gate.os, "execv") as execute:
            gate.main(["update", "-y"])
            scan.assert_not_called()
            lock.assert_not_called()
            execute.assert_called_once_with("/real/omarchy", ["/real/omarchy", "update", "-y"])

    def test_enabled_update_records_snapshot_before_handoff(self):
        gate.atomic_json(self.directory / "update-settings.json", {"schemaVersion": 1, "enabled": True})
        expected = snapshot()
        def execute(path, argv):
            self.assertEqual(gate.read_json(self.directory / "pre-update.json"), expected)
            self.assertFalse((self.directory / "baseline.json").exists())
        with patch.object(gate, "state_dir", return_value=self.directory), \
             patch.object(gate, "scan", return_value=expected), \
             patch.object(gate, "acquire_update_lock", return_value=None), \
             patch.object(gate.shutil, "which", return_value="/real/omarchy"), \
             patch.object(gate.os, "execv", side_effect=execute) as handoff:
            gate.main(["update"])
            handoff.assert_called_once()

    def test_failed_gate_never_launches_updater(self):
        gate.atomic_json(self.directory / "update-settings.json", {"schemaVersion": 1, "enabled": True})
        for state in ("review", "not_recommended", "unknown"):
            with self.subTest(state=state), \
                 patch.object(gate, "state_dir", return_value=self.directory), \
                 patch.object(gate, "scan", return_value=snapshot(state)), \
                 patch.object(gate, "acquire_update_lock", return_value=None), \
                 patch.object(gate.os, "execv") as handoff:
                self.assertEqual(gate.main(["update", "-y"]), 1)
                handoff.assert_not_called()
                self.assertFalse((self.directory / "pre-update.json").exists())

    def test_write_failure_prevents_handoff(self):
        gate.atomic_json(self.directory / "update-settings.json", {"schemaVersion": 1, "enabled": True})
        with patch.object(gate, "state_dir", return_value=self.directory), \
             patch.object(gate, "scan", return_value=snapshot()), \
             patch.object(gate, "acquire_update_lock", return_value=None), \
             patch.object(gate, "atomic_json", side_effect=OSError("disk full")), \
             patch.object(gate.os, "execv") as handoff:
            self.assertEqual(gate.main(["update"]), 1)
            handoff.assert_not_called()

    def test_ready_informational_and_review_policy(self):
        value = snapshot()
        self.assertTrue(gate.may_continue(value, True, False))
        value["results"][0].update(status="warn", material=False)
        self.assertTrue(gate.may_continue(value, True, False))
        value["readiness"] = "review"
        self.assertFalse(gate.may_continue(value, True, True))
        self.assertFalse(gate.may_continue(value, False, False))
        self.assertFalse(gate.may_continue(value, False, True, ask=lambda _: ""))
        self.assertTrue(gate.may_continue(value, False, True, ask=lambda _: "yes"))

    def test_inconsistent_ready_cannot_bypass_findings(self):
        for status in ("fail", "warn", "unknown"):
            value = snapshot()
            value["results"][0].update(status=status)
            self.assertFalse(gate.may_continue(value, True, False))
        value["results"][0].update(status="fail", severity="blocker", material=False)
        self.assertFalse(gate.may_continue(value, False, True, ask=lambda _: "yes"))

    def test_snapshot_rejects_missing_duplicate_and_mismatched_checks(self):
        base = snapshot()
        bad = [dict(base, scanId="scan-old"), dict(base, ok=False), dict(base, results=[]),
               dict(base, checkCount=2), dict(base, readiness="probably"), dict(base, baseline=None),
               dict(base, checkCount=2, results=base["results"] * 2)]
        for value in bad:
            with self.subTest(value=value), self.assertRaises(gate.GateError):
                gate.validate_snapshot(value, "scan-1")

    def test_scan_requires_its_own_completion(self):
        calls = []
        def call(method, *args):
            calls.append((method, args))
            if method == "run": return "scan-1"
            if method == "status": return json.dumps({"scanId": "scan-1", "scanRunning": False,
                                                       "lastCompletedScanId": "scan-1"})
            if method == "updateSnapshot": return json.dumps(snapshot())
            self.fail(method)
        self.assertEqual(gate.scan(call=call), snapshot())
        self.assertIn(("updateSnapshot", ("scan-1",)), calls)

    def test_busy_cancelled_or_replaced_scan_never_passes(self):
        for run, scan_id, completed in (("busy", "scan-1", "scan-1"),
                                        ("scan-1", "scan-1", "old"),
                                        ("scan-1", "scan-2", "scan-2")):
            def call(method, *args):
                if method == "run": return run
                if method == "status": return json.dumps({"scanId": scan_id, "scanRunning": False,
                                                           "lastCompletedScanId": completed})
                self.fail("Unexpected IPC call: " + method)
            with self.assertRaises(gate.GateError):
                gate.scan(call=call)

    def test_deadline_cancels_only_requested_scan(self):
        calls = []
        def call(method, *args):
            calls.append((method, args))
            if method == "run": return "scan-1"
            if method == "status": return json.dumps({"scanId": "scan-1", "scanRunning": True})
            return "cancelled"
        with self.assertRaises(gate.GateError):
            gate.scan(call=call, timeout=0)
        self.assertIn(("cancelScan", ("scan-1",)), calls)

    def test_terminal_checklist_includes_every_status_without_escape_codes(self):
        value = snapshot()
        value["results"] = [{"id": s, "status": s, "summary": "hello\x1b[2J\nworld"}
                            for s in sorted(gate.STATUSES)]
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            gate.print_checklist(value)
        for status in gate.STATUSES:
            self.assertIn(status.upper(), output.getvalue())
        self.assertNotIn("\x1b", output.getvalue())

    def test_ipc_output_is_bounded_and_timed(self):
        self.assertEqual(gate.bounded_command([sys.executable, "-c", "print('ok')"]), "ok")
        with self.assertRaises(gate.GateError):
            gate.bounded_command([sys.executable, "-c", "print('x' * 600000)"], timeout=2)
        with self.assertRaises(gate.GateError):
            gate.bounded_command([sys.executable, "-c", "import time; time.sleep(5)"], timeout=.05)

    def test_update_lock_excludes_concurrent_updates_and_survives_exec(self):
        with patch.dict(os.environ, {"XDG_RUNTIME_DIR": str(self.directory)}):
            fd = gate.acquire_update_lock()
            try:
                with self.assertRaises(BlockingIOError):
                    gate.acquire_update_lock()
                self.assertTrue(os.get_inheritable(fd))
                self.assertEqual(os.environ["OMARCHY_UPDATE_LOCK_FD"], str(fd))
                result = subprocess.run([sys.executable, "-c",
                    "import os; os.fstat(int(os.environ['OMARCHY_UPDATE_LOCK_FD']))"], pass_fds=(fd,))
                self.assertEqual(result.returncode, 0)
            finally:
                os.close(fd)

    def test_pre_update_never_launches_updater_even_when_disabled(self):
        with patch.object(gate, "state_dir", return_value=self.directory), \
             patch.object(gate.os, "execv") as handoff:
            self.assertEqual(gate.main(["pre-update"]), 0)
            handoff.assert_not_called()

    def test_real_cli_handoff_with_fake_updater(self):
        """Exercise exec, arguments, IPC and inherited lock in real processes."""
        fake_bin = self.directory / "bin"
        fake_bin.mkdir()
        runtime = self.directory / "runtime"
        runtime.mkdir()
        updater = fake_bin / "omarchy"
        updater.write_text("#!" + sys.executable + "\n" +
            "import json,os,sys\n" +
            "from pathlib import Path\n" +
            "fd=os.environ.get('OMARCHY_UPDATE_LOCK_FD')\n" +
            "if fd: os.fstat(int(fd))\n" +
            "Path(os.environ['UPDATE_RECORD']).write_text(json.dumps({'args':sys.argv[1:],'locked':bool(fd)}))\n")
        updater.chmod(0o755)
        fake_ipc = fake_bin / "omarchy-shell"
        value = snapshot()
        fake_ipc.write_text("#!" + sys.executable + "\n" +
            "import json,sys\n" +
            "method=sys.argv[2]\n" +
            "if method=='run': print('scan-1')\n" +
            "elif method=='status': print(json.dumps({'scanId':'scan-1','scanRunning':False,'lastCompletedScanId':'scan-1'}))\n" +
            "elif method=='updateSnapshot': print(" + repr(json.dumps(value)) + ")\n" +
            "else: sys.exit(1)\n")
        fake_ipc.chmod(0o755)
        record = self.directory / "update-record"
        env = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ["PATH"],
                   XDG_STATE_HOME=str(self.directory / "state"), XDG_RUNTIME_DIR=str(runtime),
                   UPDATE_RECORD=str(record))
        env.pop("OMARCHY_UPDATE_LOCK_FD", None)
        command = [sys.executable, str(ROOT / "scripts/omapreflight")]
        off = subprocess.run(command + ["update", "-y"], env=env, capture_output=True, text=True)
        self.assertEqual(off.returncode, 0, off.stderr)
        self.assertEqual(json.loads(record.read_text()), {"args": ["update", "-y"], "locked": False})
        self.assertNotIn("checklist", off.stdout)
        subprocess.run(command + ["auto-run", "enable"], env=env, check=True, capture_output=True)
        on = subprocess.run(command + ["update", "-y"], env=env, capture_output=True, text=True)
        self.assertEqual(on.returncode, 0, on.stderr)
        self.assertIn("[PASS", on.stdout)
        self.assertEqual(json.loads(record.read_text()), {"args": ["update", "-y"], "locked": True})
        saved = self.directory / "state/omapreflight/pre-update.json"
        self.assertEqual(json.loads(saved.read_text()), value)


if __name__ == "__main__":
    unittest.main()
