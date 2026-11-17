"""Exercise diagnostic decisions without connecting to an iPhone."""

import importlib.util
import json
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "card_write_diagnostics", ROOT / "tools/card-write-diagnostics/run.py"
)
diagnostics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(diagnostics)


def native_result(operation=None, **summary):
    return {
        "exitCode": 0,
        "targetGatePassed": True,
        "productType": "iPhone14,5",
        "productVersion": "27.2",
        "buildVersion": "24B119",
        "operation": {"ok": True, **(operation or {})},
        **summary,
    }


class FakeDevice:
    """Model file effects separately from the host's send result."""

    def __init__(
        self,
        *,
        link_kind="S_IFDIR",
        source_kind="S_IFLNK",
        control_match=True,
        status_error=None,
        probe_ok=True,
        stage_ok=True,
        sync_exception=None,
        cleanup_conflict=False,
    ):
        self.link_kind = link_kind
        self.source_kind = source_kind
        self.control_match = control_match
        self.status_error = status_error
        self.probe_ok = probe_ok
        self.stage_ok = stage_ok
        self.sync_exception = sync_exception
        self.cleanup_conflict = cleanup_conflict
        self.calls = []
        self.staged = False
        self.settled = False
        self.run_dir = None

    @staticmethod
    def missing():
        return {"state": "missing", "status": 8}

    @staticmethod
    def present(kind, **extra):
        return {"state": "present", "status": 0, "kind": kind, **extra}

    def objects(self):
        result = {
            key: self.missing()
            for key in ("source", "stagedLink", "payload", "link", "control")
        }
        if self.staged:
            result.update(
                source=self.present("S_IFDIR"),
                stagedLink=self.present(
                    self.source_kind, linkTarget="../../../var/tmp"
                ),
                payload=self.present("S_IFREG"),
            )
        if self.settled:
            result.update(
                stagedLink=self.missing(),
                payload=self.missing(),
                link=self.present(self.link_kind),
                control=self.present("S_IFREG"),
            )
        at_error = (
            self.status_error == "preflight" and not self.staged
        ) or (self.status_error == "post_sync" and self.settled)
        if at_error:
            result["link"] = {"state": "error", "status": 10}
        return result

    def __call__(self, command, timeout):
        self.calls.append((list(command), timeout))
        if Path(command[0]).name == "airtraffic_host":
            if self.sync_exception is not None:
                raise self.sync_exception
            self.settled = True
            return {
                "exitCode": 0,
                "ok": True,
                "syncAllowed": True,
                "readyForSync": True,
                "fileCompleteMessages": 2,
            }

        operation = command[1]
        if operation == "probe":
            return native_result(
                {"ok": self.probe_ok, "booksStagingAbsent": True},
                exitCode=0 if self.probe_ok else 2,
            )
        if operation == "diagnostic-status":
            objects = self.objects()
            ok = not any(node["state"] == "error" for node in objects.values())
            return native_result({"ok": ok, "objects": objects}, exitCode=0 if ok else 2)
        if operation == "diagnostic-snapshot":
            directory = Path(command[-1])
            directory.mkdir(parents=True, exist_ok=True)
            self.run_dir = directory.parent
            (directory / "manifest.plist").write_bytes(
                plistlib.dumps({"version": 1, "files": {}, "directories": {}})
            )
            return native_result()
        if operation == "stage":
            self.staged = True
            self.run_dir = Path(command[-1]).parent
            return native_result({"ok": self.stage_ok}, exitCode=0 if self.stage_ok else 2)
        if operation == "afc-read":
            data = (self.run_dir / "expected.bin").read_bytes()
            if not self.control_match:
                data = b"not the payload sent by this run"
            Path(command[-1]).write_bytes(data)
            return native_result({"size": len(data)})
        if operation == "diagnostic-cleanup":
            verified = not self.cleanup_conflict
            return native_result(
                {
                    "ok": verified,
                    "mediaCleanup": "verified",
                    "booksRestore": "verified" if verified else "unknown",
                    "recoveryRequired": not verified,
                    "conflict": self.cleanup_conflict,
                },
                exitCode=0 if verified else 2,
            )
        raise AssertionError(f"Unexpected command: {operation}")

    def command_names(self):
        return [
            "sync" if Path(command[0]).name == "airtraffic_host" else command[1]
            for command, _ in self.calls
        ]


class CardWriteDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work_root = Path(self.temporary.name)
        self.poll = patch.object(diagnostics, "POLL_SECONDS", 0)
        self.poll.start()
        self.addCleanup(self.poll.stop)

    def runner(self, fake):
        return diagnostics.Runner(
            "test-private-device", work_root=self.work_root, command_runner=fake
        )

    def assert_recovery_material(self, report):
        directory = Path(report["run_dir"])
        for leaf in ("state.json", "expected.bin", "Books.plist", "events.jsonl"):
            self.assertTrue((directory / leaf).is_file(), leaf)
        self.assertTrue((directory / "snapshot/manifest.plist").is_file())
        self.assertTrue(report["recovery_required"])
        return directory

    def test_materialized_link_requires_matching_media_control(self):
        fake = FakeDevice()
        report = self.runner(fake).run()
        self.assertEqual(report["outcome"], "link_materialized")
        self.assertTrue(report["control_bytes_match"])
        self.assertEqual(report["media_cleanup"], "verified")
        self.assertEqual(report["books_restore"], "verified")
        self.assertFalse(report["recovery_required"])

    def test_link_preserved_is_a_diagnostic_result_only(self):
        fake = FakeDevice(link_kind="S_IFLNK")
        report = self.runner(fake).run()
        self.assertEqual(report["outcome"], "link_preserved")
        self.assertTrue(report["control_bytes_match"])
        self.assertFalse(report.get("wallet_write_verified", False))

    def test_send_success_with_wrong_control_is_inconclusive(self):
        fake = FakeDevice(control_match=False)
        report = self.runner(fake).run()
        self.assertEqual(report["outcome"], "inconclusive")
        self.assertFalse(report["control_bytes_match"])

    def test_preflight_access_error_cannot_be_treated_as_missing(self):
        fake = FakeDevice(status_error="preflight")
        report = self.runner(fake).run()
        self.assertNotIn("stage", fake.command_names())
        self.assertNotIn("sync", fake.command_names())
        self.assertEqual(report["outcome"], "phase_failed")

    def test_failed_probe_does_not_stage_or_sync(self):
        fake = FakeDevice(probe_ok=False)
        report = self.runner(fake).run()
        self.assertEqual(report["outcome"], "phase_failed")
        self.assertEqual(report["phase"], "preflight")
        self.assertEqual(report["media_cleanup"], "not_needed")
        self.assertEqual(fake.command_names(), ["probe"])

    def test_post_sync_access_error_cannot_confirm_materialization(self):
        fake = FakeDevice(status_error="post_sync")
        report = self.runner(fake).run()
        self.assertIn(report["outcome"], ("phase_failed", "inconclusive"))
        self.assertNotEqual(report["outcome"], "link_materialized")
        self.assertEqual(report["stage_results"]["observe"]["objects"]["link"]["status"], 10)

    def test_source_must_be_a_symlink_before_sync(self):
        fake = FakeDevice(source_kind="S_IFDIR")
        report = self.runner(fake).run()
        self.assertNotIn("sync", fake.command_names())
        self.assertIn(report["outcome"], ("phase_failed", "inconclusive"))

    def test_known_stage_failure_still_runs_controlled_cleanup(self):
        fake = FakeDevice(stage_ok=False)
        report = self.runner(fake).run()
        self.assertEqual(report["outcome"], "phase_failed")
        self.assertNotIn("sync", fake.command_names())
        self.assertIn("diagnostic-cleanup", fake.command_names())
        self.assertEqual(report["media_cleanup"], "verified")
        self.assertEqual(report["stage_results"]["stage"]["exitCode"], 2)
        self.assertEqual(report["stage_results"]["stage"]["errorType"], "RuntimeError")

    def test_timeout_preserves_pending_state_without_immediate_cleanup(self):
        fake = FakeDevice(sync_exception=subprocess.TimeoutExpired("host", 120))
        report = self.runner(fake).run()
        directory = self.assert_recovery_material(report)
        state = json.loads((directory / "state.json").read_text())
        self.assertTrue(state["sync_issued"])
        self.assertFalse(state["sync_result_known"])
        self.assertNotIn("diagnostic-cleanup", fake.command_names())

    def test_interrupt_preserves_recovery_material(self):
        fake = FakeDevice(sync_exception=KeyboardInterrupt())
        report = self.runner(fake).run()
        self.assert_recovery_material(report)
        self.assertNotIn("diagnostic-cleanup", fake.command_names())

    def test_recover_cleans_only_after_both_moves_are_observed(self):
        fake = FakeDevice(sync_exception=subprocess.TimeoutExpired("host", 120))
        report = self.runner(fake).run()
        directory = self.assert_recovery_material(report)
        previous_stage_count = fake.command_names().count("stage")
        previous_sync_count = fake.command_names().count("sync")
        fake.settled = True

        recovered = self.runner(fake).recover(directory)

        self.assertFalse(recovered["recovery_required"])
        self.assertEqual(recovered["media_cleanup"], "verified")
        self.assertEqual(fake.command_names().count("stage"), previous_stage_count)
        self.assertEqual(fake.command_names().count("sync"), previous_sync_count)

    def test_recover_with_unknown_sync_state_preserves_snapshot(self):
        fake = FakeDevice(sync_exception=subprocess.TimeoutExpired("host", 120))
        report = self.runner(fake).run()
        directory = self.assert_recovery_material(report)
        before = list(fake.command_names())

        recovered = self.runner(fake).recover(directory)

        self.assert_recovery_material(recovered)
        self.assertEqual(fake.command_names().count("stage"), before.count("stage"))
        self.assertEqual(fake.command_names().count("sync"), before.count("sync"))
        self.assertNotIn("diagnostic-cleanup", fake.command_names())

    def test_recover_rejects_a_different_explicit_device(self):
        fake = FakeDevice(sync_exception=subprocess.TimeoutExpired("host", 120))
        report = self.runner(fake).run()
        directory = self.assert_recovery_material(report)
        before = list(fake.calls)
        other = diagnostics.Runner(
            "another-private-device", work_root=self.work_root, command_runner=fake
        )

        with self.assertRaises(ValueError):
            other.recover(directory)

        self.assertEqual(fake.calls, before)
        self.assert_recovery_material(report)

    def test_recover_rejects_changed_backup_inputs_before_device_calls(self):
        fake = FakeDevice(sync_exception=subprocess.TimeoutExpired("host", 120))
        report = self.runner(fake).run()
        directory = self.assert_recovery_material(report)
        before = list(fake.calls)
        (directory / "Books.plist").write_bytes(b"different Books state")

        with self.assertRaises(ValueError):
            self.runner(fake).recover(directory)

        self.assertEqual(fake.calls, before)

    def test_unresolved_run_blocks_a_new_experiment(self):
        fake = FakeDevice(sync_exception=subprocess.TimeoutExpired("host", 120))
        report = self.runner(fake).run()
        self.assert_recovery_material(report)
        before = list(fake.calls)

        with self.assertRaises(ValueError):
            self.runner(fake).run()

        self.assertEqual(fake.calls, before)

    def test_cleanup_conflict_keeps_snapshot_and_requires_recovery(self):
        fake = FakeDevice(cleanup_conflict=True)
        report = self.runner(fake).run()
        self.assert_recovery_material(report)
        self.assertNotEqual(report["books_restore"], "verified")
        self.assertEqual(report["media_cleanup"], "verified")
        self.assertNotIn("restore-books", fake.command_names())

    def test_two_asset_destinations_are_media_roots_not_external_writes(self):
        fake = FakeDevice()
        self.runner(fake).run()
        transfers = [
            command for command, _ in fake.calls
            if Path(command[0]).name == "airtraffic_host"
        ]
        self.assertEqual(len(transfers), 1)
        command = transfers[0]
        self.assertEqual(len(command), 6)
        source_link, destination_link, source_control, destination_control = command[2:]
        self.assertRegex(source_link, r"^\.\./\.\./airlift-src-[a-f0-9]{20}/p0/p1/p2/link$")
        self.assertRegex(destination_link, r"^airlift-link-[a-f0-9]{20}$")
        self.assertRegex(source_control, r"^\.\./\.\./airlift-src-[a-f0-9]{20}/payload$")
        self.assertRegex(destination_control, r"^airlift-recovered-[a-f0-9]{20}$")
        self.assertNotIn("/", destination_link)
        self.assertNotIn("/", destination_control)

    def test_partial_stdout_does_not_defeat_child_deadline(self):
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            diagnostics.command_json(
                [sys.executable, "-c", "import time; print('{}', flush=True); time.sleep(30)"],
                timeout=0.1,
            )
        self.assertLess(time.monotonic() - started, 3)

    def test_device_lock_blocks_a_simultaneous_run(self):
        fake = FakeDevice()
        runner = self.runner(fake)
        with runner.lock():
            with self.assertRaisesRegex(ValueError, "device lock"):
                self.runner(fake).run()
        self.assertEqual(fake.calls, [])

    def test_recover_completed_run_is_a_noop(self):
        fake = FakeDevice()
        report = self.runner(fake).run()
        before = list(fake.calls)
        recovered = self.runner(fake).recover(report["run_dir"])
        self.assertEqual(recovered, report)
        self.assertEqual(fake.calls, before)

    def test_failed_cleanup_exit_cannot_claim_verified_recovery(self):
        fake = FakeDevice()

        def command(command, timeout):
            response = fake(command, timeout)
            if "diagnostic-cleanup" in command:
                response["exitCode"] = 2
            return response

        report = diagnostics.Runner("test-device", self.work_root, command).run()
        self.assertTrue(report["recovery_required"])
        self.assertNotEqual(report["media_cleanup"], "verified")

    def test_owned_books_rollback_does_not_clear_global_recovery(self):
        fake = FakeDevice(cleanup_conflict=True)
        report = self.runner(fake).run()
        before = list(fake.calls)
        restores = []

        def command(command, timeout):
            if "diagnostic-restore-owned-books" in command:
                restores.append(command)
                self.assertTrue(Path(command[-1]).is_dir())
                return native_result({"ok": True, "ownedBooksRestore": "verified",
                                      "otherBooksUnchanged": True, "backupVerified": True})
            return fake(command, timeout)

        result = diagnostics.Runner("test-private-device", self.work_root, command).restore_owned_books(report["run_dir"])
        self.assertEqual(result["owned_books_restore"], "verified")
        self.assertTrue(result["other_books_unchanged"])
        self.assertTrue(result["owned_books_backup_verified"])
        self.assertTrue(result["recovery_required"])
        self.assertEqual(result["books_restore"], "unknown")
        self.assertEqual(len(restores), 1)
        self.assertEqual(fake.calls[len(before):][0][0][1], "probe")
        self.assertEqual(fake.command_names().count("stage"), 1)
        self.assertEqual(fake.command_names().count("sync"), 1)

    def test_owned_books_rollback_rejects_unverified_sync_without_device_calls(self):
        fake = FakeDevice(sync_exception=subprocess.TimeoutExpired("host", 120))
        report = self.runner(fake).run()
        before = list(fake.calls)
        with self.assertRaisesRegex(ValueError, "verified sync"):
            self.runner(fake).restore_owned_books(report["run_dir"])
        self.assertEqual(fake.calls, before)

    def test_owned_books_rollback_failure_preserves_pending_state(self):
        fake = FakeDevice(cleanup_conflict=True)
        report = self.runner(fake).run()

        def command(command, timeout):
            if "diagnostic-restore-owned-books" in command:
                return native_result({"ok": False, "ownedBooksRestore": "unknown",
                                      "otherBooksUnchanged": None}, exitCode=2)
            return fake(command, timeout)

        result = diagnostics.Runner("test-private-device", self.work_root, command).restore_owned_books(report["run_dir"])
        self.assertEqual(result["owned_books_restore"], "unknown")
        self.assertTrue(result["recovery_required"])
        self.assertIsNone(result["other_books_unchanged"])
        self.assertTrue((Path(result["run_dir"]) / "snapshot/manifest.plist").is_file())


if __name__ == "__main__":
    unittest.main()
