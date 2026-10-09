"""Unit tests for apply_card_skin.read_file (device calls mocked)."""

import unittest
from pathlib import Path
from unittest.mock import patch

import apply_card_skin


def _ok(extra=None):
    result = {"exitCode": 0, "targetGatePassed": True, "operation": {"ok": True}}
    if extra:
        result["operation"].update(extra)
    return result


class ReadFileTests(unittest.TestCase):
    def test_rejects_non_plain_leaf(self) -> None:
        for bad in ("", ".", "..", "a/b", "/abs"):
            with self.assertRaises(ValueError):
                apply_card_skin.read_file("udid", "/var/tmp", bad)

    def test_happy_path_reads_and_restores(self) -> None:
        expected = b"original-bytes"
        seen = {}

        def fake_native(command, udid, *args):
            seen[command] = args
            if command == "afc-read":
                Path(args[1]).write_bytes(expected)
            return _ok()

        with (
            patch.object(apply_card_skin.secrets, "token_hex", return_value="a" * 20),
            patch.object(apply_card_skin, "native", side_effect=fake_native),
            patch.object(apply_card_skin, "run_json", return_value={"exitCode": 0, "ok": True}),
            patch.object(apply_card_skin, "write_file", return_value=True) as mock_write,
        ):
            data = apply_card_skin.read_file("udid", "/var/tmp", "leaf.bin")

        self.assertEqual(data, expected)
        # Written back to the same target/leaf
        mock_write.assert_called_once()
        _, target, leaf, payload = mock_write.call_args.args
        self.assertEqual((target, leaf, payload), ("/var/tmp", "leaf.bin", expected))

    def test_atc_failure_returns_none(self) -> None:
        with (
            patch.object(apply_card_skin, "native", return_value=_ok()),
            patch.object(apply_card_skin, "run_json", return_value={"exitCode": 1, "ok": False}),
            patch.object(apply_card_skin, "write_file") as mock_write,
        ):
            self.assertIsNone(apply_card_skin.read_file("udid", "/var/tmp", "leaf.bin"))
        mock_write.assert_not_called()

    def test_afc_read_failure_preserves_recovered(self) -> None:
        """Original sits in Media/recovered: must NOT run finish cleanup."""
        calls = []

        def fake_native(command, udid, *args):
            calls.append(command)
            return _ok()

        with (
            patch.object(apply_card_skin, "native", side_effect=fake_native),
            patch.object(apply_card_skin, "run_json", return_value={"exitCode": 0, "ok": True}),
            patch.object(apply_card_skin, "write_file") as mock_write,
        ):
            self.assertIsNone(apply_card_skin.read_file("udid", "/var/tmp", "leaf.bin"))
        mock_write.assert_not_called()
        self.assertNotIn("finish-write", calls)

    def test_strict_read_rejects_bytes_when_device_restore_fails(self) -> None:
        expected = b"captured-but-not-restored"

        def fake_native(command, udid, *args):
            if command == "afc-read":
                Path(args[1]).write_bytes(expected)
            return _ok()

        with (
            patch.object(apply_card_skin, "native", side_effect=fake_native),
            patch.object(apply_card_skin, "run_json", return_value={"exitCode": 0, "ok": True}),
            patch.object(apply_card_skin, "write_file", return_value=False),
        ):
            self.assertIsNone(apply_card_skin.read_file(
                "udid", "/var/tmp", "leaf.bin", require_restored=True
            ))


if __name__ == "__main__":
    unittest.main()
