import base64
import io
import json
import subprocess
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch

import aircard_backend
import apply_card_skin


PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)
PDF_BYTES = b"%PDF-1.4\nbackup"
CARD_HASH = "ABCDEFGHIJKLMNOPQRST="
DB_COLORS = {
    "foregroundColor": "rgba(1, 2, 3, 1.00)",
    "labelColor": "rgba(4, 5, 6, 1.00)",
}


class CardBackupTests(unittest.TestCase):
    def inspect_result(self) -> dict:
        return {
            **DB_COLORS,
            "primaryAccountSuffix": "1234",
            "journalMode": "delete",
            "quickCheck": ["ok"],
            "rowCount": 1,
        }

    def test_backup_zip_contains_artwork_and_sanitized_style(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "AirCard-Card-1.zip"
            output = io.StringIO()
            with (
                patch.object(
                    aircard_backend,
                    "extract_file",
                    return_value=PNG_1X1,
                ) as extract,
                patch.object(
                    aircard_backend,
                    "inspect_wallet_db",
                    return_value=self.inspect_result(),
                ),
                redirect_stdout(output),
            ):
                result = aircard_backend.cmd_backup_card(
                    "device",
                    CARD_HASH,
                    str(destination),
                )

            self.assertTrue(result)
            response = json.loads(output.getvalue())
            self.assertEqual(response["fileName"], destination.name)
            self.assertNotIn(CARD_HASH, output.getvalue())
            self.assertEqual(extract.call_count, 1)
            with zipfile.ZipFile(destination) as archive:
                self.assertEqual(
                    set(archive.namelist()),
                    {"cardBackgroundCombined@3x.png", "wallet-style.json"},
                )
                self.assertEqual(
                    archive.read("cardBackgroundCombined@3x.png"),
                    PNG_1X1,
                )
                wallet_style = json.loads(archive.read("wallet-style.json"))
            self.assertEqual(
                wallet_style,
                {
                    "formatVersion": 2,
                    "source": "passes23.sqlite",
                    "foregroundColor": DB_COLORS["foregroundColor"],
                    "labelColor": DB_COLORS["labelColor"],
                    "primaryAccountSuffix": "1234",
                    "imageAsset": "cardBackgroundCombined@3x.png",
                },
            )
            self.assertNotIn(CARD_HASH, json.dumps(wallet_style))

    def test_backup_falls_back_from_png_to_pdf(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "backup.zip"
            destination.write_bytes(b"existing backup")
            output = io.StringIO()
            with (
                patch.object(
                    aircard_backend,
                    "extract_file",
                    side_effect=[None, None, PDF_BYTES],
                ) as extract,
                patch.object(
                    aircard_backend,
                    "inspect_wallet_db",
                    return_value=self.inspect_result(),
                ),
                redirect_stdout(output),
            ):
                result = aircard_backend.cmd_backup_card(
                    "device",
                    CARD_HASH,
                    str(destination),
                )

            self.assertTrue(result)
            self.assertEqual(
                [call.args[2] for call in extract.call_args_list],
                [asset for asset, _mime in aircard_backend.CARD_ARTWORK_ASSETS],
            )
            response = json.loads(output.getvalue())
            self.assertEqual(
                response["imageAsset"],
                "cardBackgroundCombined.pdf",
            )
            self.assertTrue(
                response["imageDataURI"].startswith("data:application/pdf;base64,")
            )

    def test_backup_fails_without_artwork_and_leaves_no_zip(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "backup.zip"
            inspect = Mock()
            with (
                patch.object(
                    aircard_backend,
                    "extract_file",
                    return_value=None,
                ),
                patch.object(aircard_backend, "inspect_wallet_db", inspect),
                redirect_stdout(io.StringIO()),
            ):
                result = aircard_backend.cmd_backup_card(
                    "device",
                    CARD_HASH,
                    str(destination),
                )

            self.assertFalse(result)
            self.assertFalse(destination.exists())
            self.assertEqual(list(Path(temporary).iterdir()), [])
            inspect.assert_not_called()

    def test_backup_rejects_invalid_hash_before_device_read(self) -> None:
        extract = Mock()
        with (
            patch.object(aircard_backend, "extract_file", extract),
            redirect_stdout(io.StringIO()),
        ):
            result = aircard_backend.cmd_backup_card(
                "device",
                "../outside",
                "/tmp/backup.zip",
            )

        self.assertFalse(result)
        extract.assert_not_called()

    def test_backup_rejects_invalid_destination_before_device_read(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            invalid_destinations = [
                root / "missing" / "backup.zip",
                root,
            ]
            for destination in invalid_destinations:
                with self.subTest(destination=destination):
                    extract = Mock()
                    with (
                        patch.object(
                            aircard_backend,
                            "extract_file",
                            extract,
                        ),
                        redirect_stdout(io.StringIO()),
                    ):
                        result = aircard_backend.cmd_backup_card(
                            "device",
                            CARD_HASH,
                            str(destination),
                        )
                    self.assertFalse(result)
                    extract.assert_not_called()

    def test_backup_failure_leaves_no_partial_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "backup.zip"
            destination.write_bytes(b"existing backup")
            with (
                patch.object(
                    aircard_backend,
                    "extract_file",
                    return_value=PNG_1X1,
                ),
                patch.object(
                    aircard_backend,
                    "inspect_wallet_db",
                    return_value=self.inspect_result(),
                ),
                patch.object(
                    aircard_backend.zipfile,
                    "ZipFile",
                    side_effect=RuntimeError("zip failed"),
                ),
                redirect_stdout(io.StringIO()),
            ):
                result = aircard_backend.cmd_backup_card(
                    "device",
                    CARD_HASH,
                    str(destination),
                )

            self.assertFalse(result)
            self.assertEqual(destination.read_bytes(), b"existing backup")
            self.assertEqual(list(Path(temporary).iterdir()), [destination])


class CardFlashTests(unittest.TestCase):
    def prepared_database(self) -> dict:
        return {
            "originalColors": {
                "foreground_color": "rgba(1, 2, 3, 1.00)",
                "label_color": "rgba(4, 5, 6, 1.00)",
                "primary_account_suffix": "1234",
            },
            "appliedColors": {
                "foreground_color": "rgba(170, 187, 204, 1.00)",
                "label_color": "rgba(7, 8, 9, 1.00)",
                "primary_account_suffix": "1234",
            },
        }

    def test_extract_file_restores_artwork_bytes_before_returning(self) -> None:
        target = "/var/mobile/Library/Passes/Cards/card.pkpass"
        successful_operation = {
            "exitCode": 0,
            "targetGatePassed": True,
            "operation": {"ok": True},
        }

        native_calls: list[str] = []

        def fake_native(command, *args):
            native_calls.append(command)
            if command == "extract":
                Path(args[3]).write_bytes(PNG_1X1)
            if command == "finish-extract":
                return {
                    "exitCode": 0,
                    "targetGatePassed": True,
                    "operation": {
                        "ok": True,
                        "recoveredAbsent": True,
                    },
                }
            return successful_operation

        with tempfile.TemporaryDirectory() as temporary:
            with (
                patch.object(
                    apply_card_skin,
                    "native",
                    side_effect=fake_native,
                ),
                patch.object(
                    apply_card_skin,
                    "run_json",
                    return_value={"exitCode": 0, "ok": True},
                ) as airtraffic,
                patch.object(
                    apply_card_skin,
                    "write_file",
                    return_value=True,
                ) as write_file,
            ):
                result = apply_card_skin.extract_file(
                    "device",
                    target,
                    "cardBackgroundCombined@3x.png",
                    str(Path(temporary) / "artwork.png"),
                )

        self.assertEqual(result, PNG_1X1)
        write_file.assert_called_once_with(
            "device",
            target,
            "cardBackgroundCombined@3x.png",
            PNG_1X1,
            retries=1,
        )
        self.assertIn("finish-extract", native_calls)
        self.assertEqual(airtraffic.call_count, 1)

    def test_extract_file_stops_retrying_when_recovery_is_unverified(
        self,
    ) -> None:
        successful_operation = {
            "exitCode": 0,
            "targetGatePassed": True,
            "operation": {"ok": True},
        }
        snapshots = 0
        native_calls: list[str] = []

        def fake_native(command, *args):
            nonlocal snapshots
            native_calls.append(command)
            if command == "snapshot-books":
                snapshots += 1
            if command == "extract":
                Path(args[3]).write_bytes(PNG_1X1)
            if command == "finish-extract":
                return {
                    "exitCode": 2,
                    "targetGatePassed": True,
                    "operation": {
                        "ok": False,
                        "recoveredAbsent": False,
                    },
                }
            return successful_operation

        with tempfile.TemporaryDirectory() as temporary:
            with (
                patch.object(
                    apply_card_skin,
                    "native",
                    side_effect=fake_native,
                ),
                patch.object(
                    apply_card_skin,
                    "run_json",
                    return_value={"exitCode": 0, "ok": True},
                ),
                patch.object(
                    apply_card_skin,
                    "write_file",
                    return_value=False,
                ),
                self.assertRaisesRegex(
                    RuntimeError,
                    "failed to restore original",
                ),
            ):
                apply_card_skin.extract_file(
                    "device",
                    "/var/mobile/Library/Passes/Cards/card.pkpass",
                    "cardBackgroundCombined@3x.png",
                    str(Path(temporary) / "artwork.png"),
                    retries=3,
                    raise_errors=True,
                )

        self.assertEqual(snapshots, 1)
        self.assertIn("finish-extract", native_calls)

    def test_extract_file_does_not_rewrite_when_cleanup_fails(
        self,
    ) -> None:
        successful_operation = {
            "exitCode": 0,
            "targetGatePassed": True,
            "operation": {"ok": True},
        }
        snapshots = 0

        def fake_native(command, *args):
            nonlocal snapshots
            if command == "snapshot-books":
                snapshots += 1
            if command == "extract":
                Path(args[3]).write_bytes(PNG_1X1)
            if command == "finish-extract":
                return {
                    "exitCode": 2,
                    "targetGatePassed": True,
                    "operation": {
                        "ok": False,
                        "recoveredAbsent": False,
                    },
                }
            return successful_operation

        with tempfile.TemporaryDirectory() as temporary:
            with (
                patch.object(
                    apply_card_skin,
                    "native",
                    side_effect=fake_native,
                ),
                patch.object(
                    apply_card_skin,
                    "run_json",
                    return_value={"exitCode": 0, "ok": True},
                ),
                patch.object(
                    apply_card_skin,
                    "write_file",
                    return_value=True,
                ) as write_file,
                self.assertRaisesRegex(
                    RuntimeError,
                    "cleanup or rewrite failed",
                ),
            ):
                apply_card_skin.extract_file(
                    "device",
                    "/var/mobile/Library/Passes/Cards/card.pkpass",
                    "cardBackgroundCombined@3x.png",
                    str(Path(temporary) / "artwork.png"),
                    retries=3,
                    raise_errors=True,
                )

        self.assertEqual(snapshots, 1)
        write_file.assert_not_called()

    def test_extract_file_cleans_up_missing_optional_sidecar(
        self,
    ) -> None:
        successful_operation = {
            "exitCode": 0,
            "targetGatePassed": True,
            "operation": {"ok": True},
        }
        snapshots = 0
        native_calls: list[str] = []

        def fake_native(command, *args):
            nonlocal snapshots
            native_calls.append(command)
            if command == "snapshot-books":
                snapshots += 1
            if command == "extract":
                return {
                    "exitCode": 2,
                    "targetGatePassed": True,
                    "operation": {
                        "ok": False,
                        "reason": "file not found",
                    },
                }
            if command == "finish-extract":
                return {
                    "exitCode": 0,
                    "targetGatePassed": True,
                    "operation": {
                        "ok": True,
                        "recoveredAbsent": True,
                    },
                }
            return successful_operation

        with tempfile.TemporaryDirectory() as temporary:
            with (
                patch.object(
                    apply_card_skin,
                    "native",
                    side_effect=fake_native,
                ),
                patch.object(
                    apply_card_skin,
                    "run_json",
                    return_value={"exitCode": 0, "ok": True},
                ),
                self.assertRaisesRegex(
                    FileNotFoundError,
                    "passes23.sqlite-journal file not found",
                ),
            ):
                apply_card_skin.extract_file(
                    "device",
                    apply_card_skin.WALLET_DB_TARGET,
                    "passes23.sqlite-journal",
                    str(Path(temporary) / "journal"),
                    retries=3,
                    raise_errors=True,
                )

        self.assertEqual(snapshots, 1)
        self.assertIn("finish-extract", native_calls)

    def test_extract_file_treats_post_relocation_main_not_found_as_failure(
        self,
    ) -> None:
        successful_operation = {
            "exitCode": 0,
            "targetGatePassed": True,
            "operation": {"ok": True},
        }
        snapshots = 0
        native_calls: list[str] = []

        def fake_native(command, *args):
            nonlocal snapshots
            native_calls.append(command)
            if command == "snapshot-books":
                snapshots += 1
            if command == "extract":
                return {
                    "exitCode": 2,
                    "targetGatePassed": True,
                    "operation": {
                        "ok": False,
                        "reason": "file not found",
                    },
                }
            return successful_operation

        with tempfile.TemporaryDirectory() as temporary:
            with (
                patch.object(
                    apply_card_skin,
                    "native",
                    side_effect=fake_native,
                ),
                patch.object(
                    apply_card_skin,
                    "run_json",
                    return_value={"exitCode": 0, "ok": True},
                ),
                self.assertRaisesRegex(
                    RuntimeError,
                    "failed to restore original passes23.sqlite",
                ),
            ):
                apply_card_skin.extract_file(
                    "device",
                    apply_card_skin.WALLET_DB_TARGET,
                    "passes23.sqlite",
                    str(Path(temporary) / "database"),
                    retries=3,
                    raise_errors=True,
                )

        self.assertEqual(snapshots, 1)
        self.assertNotIn("finish-extract", native_calls)

    def test_extract_file_can_report_the_failed_stage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with (
                patch.object(
                    apply_card_skin,
                    "native",
                    return_value={"exitCode": 1, "operation": {"ok": False}},
                ),
                self.assertRaisesRegex(
                    RuntimeError,
                    "failed to snapshot Books state",
                ),
            ):
                apply_card_skin.extract_file(
                    "device",
                    "/var/mobile/Library/Passes/Cards/card.pkpass",
                    "cardBackgroundCombined@3x.png",
                    str(Path(temporary) / "artwork.png"),
                    retries=1,
                    raise_errors=True,
                )

    def test_extract_file_rejects_unsupported_target_before_device_access(
        self,
    ) -> None:
        native = Mock()
        with (
            patch.object(apply_card_skin, "native", native),
            self.assertRaisesRegex(ValueError, "unsupported extraction target"),
        ):
            apply_card_skin.extract_file(
                "device",
                "/private/var/mobile/Library/Preferences",
                "com.apple.Passbook.plist",
                "/tmp/output",
            )
        native.assert_not_called()

    def test_flash_rejects_invalid_card_hash_before_device_write(self) -> None:
        write_file = Mock(return_value=True)
        with (
            patch.object(aircard_backend, "write_file", write_file),
            redirect_stdout(io.StringIO()),
        ):
            result = aircard_backend.cmd_flash(
                "device",
                "../outside",
                "-",
                foreground_color="#AABBCC",
            )

        self.assertFalse(result)
        write_file.assert_not_called()

    def test_color_only_flash_is_database_only(self) -> None:
        prepared = self.prepared_database()
        output = io.StringIO()
        with (
            patch.object(
                aircard_backend,
                "prepare_wallet_db_patch",
                return_value=prepared,
            ),
            patch.object(
                aircard_backend,
                "apply_wallet_db_patch",
                return_value={"quickCheck": ["ok"]},
            ) as apply_database,
            patch.object(
                aircard_backend,
                "write_file",
                return_value=True,
            ) as write_file,
            redirect_stdout(output),
        ):
            result = aircard_backend.cmd_flash(
                "device",
                CARD_HASH,
                "-",
                "#AABBCC",
                "rgb(7, 8, 9)",
            )

        self.assertTrue(result)
        apply_database.assert_called_once_with("device", prepared)
        write_file.assert_not_called()
        success = json.loads(output.getvalue().splitlines()[-1])
        self.assertEqual(
            success["originalColors"],
            {
                "foregroundColor": "rgba(1, 2, 3, 1.00)",
                "labelColor": "rgba(4, 5, 6, 1.00)",
            },
        )
        self.assertEqual(
            success["appliedColors"],
            {
                "foregroundColor": "rgba(170, 187, 204, 1.00)",
                "labelColor": "rgba(7, 8, 9, 1.00)",
            },
        )
        self.assertIn("Reboot required", success["message"])

    def test_batch_database_command_prepares_and_applies_once(self) -> None:
        prepared = {
            "cards": [
                {
                    "cardHash": CARD_HASH,
                    "requestIndex": 0,
                    "originalColors": {
                        "foreground_color": "old foreground",
                        "label_color": "old label",
                        "primary_account_suffix": "1234",
                    },
                    "appliedColors": {
                        "foreground_color": "new foreground",
                        "label_color": "old label",
                        "primary_account_suffix": "1234",
                    },
                },
                {
                    "cardHash": "ZYXWVUTSRQPONMLKJIHG=",
                    "requestIndex": 1,
                    "originalColors": {
                        "foreground_color": "other foreground",
                        "label_color": "other label",
                        "primary_account_suffix": "9876",
                    },
                    "appliedColors": {
                        "foreground_color": "other foreground",
                        "label_color": "new label",
                        "primary_account_suffix": "0042",
                    },
                },
            ],
        }
        updates = [
            {
                "cardHash": CARD_HASH,
                "requestIndex": 0,
                "foregroundColor": "#AABBCC",
            },
            {
                "cardHash": "ZYXWVUTSRQPONMLKJIHG=",
                "requestIndex": 1,
                "labelColor": "#010203",
                "primaryAccountSuffix": "0042",
            },
        ]
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as temporary:
            updates_path = Path(temporary) / "updates.json"
            updates_path.write_text(json.dumps(updates))
            with (
                patch.object(
                    aircard_backend,
                    "prepare_wallet_db_batch_patch",
                    return_value=prepared,
                ) as prepare,
                patch.object(
                    aircard_backend,
                    "apply_wallet_db_batch_patch",
                    return_value=[{}, {}],
                ) as apply_database,
                redirect_stdout(output),
            ):
                result = aircard_backend.cmd_flash_wallet_db_batch(
                    "device",
                    str(updates_path),
                )

        self.assertTrue(result)
        prepare.assert_called_once_with("device", updates)
        apply_database.assert_called_once_with("device", prepared)
        success = json.loads(output.getvalue().splitlines()[-1])
        self.assertEqual(success["type"], "success")
        self.assertEqual(len(success["cards"]), 2)
        self.assertEqual(
            [card["requestIndex"] for card in success["cards"]],
            [0, 1],
        )
        self.assertNotIn(CARD_HASH, output.getvalue())

    def test_swift_flash_runs_one_database_batch_after_all_artwork(self) -> None:
        source = (Path(aircard_backend.script_dir) / "AirCardApp.swift").read_text()
        start = source.index("    func applySkin() {")
        end = source.index(
            "    // MARK: - Passcode Theme (.passthm) Handlers",
            start,
        )
        flow = source[start:end]

        artwork_loop = flow.index(
            "for (idx, card) in artworkCards.enumerated()"
        )
        database_batch = flow.index(
            "if !flashFailed && !databaseCards.isEmpty"
        )
        self.assertLess(artwork_loop, database_batch)
        self.assertEqual(flow.count('"--flash-wallet-db-batch"'), 1)
        self.assertNotIn('"--foreground-color"', flow)
        self.assertNotIn('"--label-color"', flow)
        self.assertNotIn('"--primary-account-suffix"', flow)

    def test_suffix_only_flash_is_database_only(self) -> None:
        prepared = self.prepared_database()
        prepared["appliedColors"]["primary_account_suffix"] = "0042"
        output = io.StringIO()
        with (
            patch.object(
                aircard_backend,
                "prepare_wallet_db_patch",
                return_value=prepared,
            ) as prepare,
            patch.object(
                aircard_backend,
                "apply_wallet_db_patch",
                return_value={"quickCheck": ["ok"]},
            ),
            patch.object(
                aircard_backend,
                "write_file",
                return_value=True,
            ) as write_file,
            redirect_stdout(output),
        ):
            result = aircard_backend.cmd_flash(
                "device",
                CARD_HASH,
                "-",
                primary_account_suffix="0042",
            )

        self.assertTrue(result)
        prepare.assert_called_once_with(
            "device",
            CARD_HASH,
            None,
            None,
            "0042",
        )
        write_file.assert_not_called()
        success = json.loads(output.getvalue().splitlines()[-1])
        self.assertEqual(success["originalPrimaryAccountSuffix"], "1234")
        self.assertEqual(success["appliedPrimaryAccountSuffix"], "0042")

    def test_explicit_null_suffix_is_forwarded_to_database(self) -> None:
        prepared = self.prepared_database()
        prepared["appliedColors"]["primary_account_suffix"] = None
        with (
            patch.object(
                aircard_backend,
                "prepare_wallet_db_patch",
                return_value=prepared,
            ) as prepare,
            patch.object(aircard_backend, "apply_wallet_db_patch"),
            redirect_stdout(io.StringIO()),
        ):
            result = aircard_backend.cmd_flash(
                "device",
                CARD_HASH,
                "-",
                primary_account_suffix="NULL",
            )

        self.assertTrue(result)
        prepare.assert_called_once_with(
            "device",
            CARD_HASH,
            None,
            None,
            "NULL",
        )

    def test_blank_or_invalid_suffix_is_rejected_before_device_read(self) -> None:
        for value in ("", "123", "12345", "12A4", "１２３４"):
            with self.subTest(value=value):
                prepare = Mock()
                with (
                    patch.object(
                        aircard_backend,
                        "prepare_wallet_db_patch",
                        prepare,
                    ),
                    redirect_stdout(io.StringIO()),
                ):
                    result = aircard_backend.cmd_flash(
                        "device",
                        CARD_HASH,
                        "-",
                        primary_account_suffix=value,
                    )
                self.assertFalse(result)
                prepare.assert_not_called()

    def test_database_failure_preserves_guarded_rollback_result(self) -> None:
        prepared = self.prepared_database()
        write_file = Mock()
        output = io.StringIO()
        with (
            patch.object(
                aircard_backend,
                "prepare_wallet_db_patch",
                return_value=prepared,
            ),
            patch.object(
                aircard_backend,
                "apply_wallet_db_patch",
                side_effect=RuntimeError(
                    "failed to write Wallet color database; "
                    "wallet database rollback verified"
                ),
            ),
            patch.object(aircard_backend, "write_file", write_file),
            redirect_stdout(output),
        ):
            result = aircard_backend.cmd_flash(
                "device",
                CARD_HASH,
                "-",
                foreground_color="#AABBCC",
            )

        self.assertFalse(result)
        self.assertIn("rollback verified", output.getvalue())
        write_file.assert_not_called()

    def test_database_failure_logs_phase_without_duplicate_or_full_hash(
        self,
    ) -> None:
        output = io.StringIO()
        missing = FileNotFoundError(
            "prepare-main: FileNotFoundError: passes23.sqlite file not found"
        )
        error = RuntimeError(str(missing))
        error.__cause__ = missing
        with (
            patch.object(
                aircard_backend,
                "prepare_wallet_db_patch",
                side_effect=error,
            ),
            redirect_stdout(output),
        ):
            result = aircard_backend.cmd_flash(
                "device",
                CARD_HASH,
                "-",
                foreground_color="#AABBCC",
            )

        self.assertFalse(result)
        messages = [
            json.loads(line) for line in output.getvalue().splitlines()
        ]
        diagnostics = [
            message
            for message in messages
            if message.get("type") == "diagnostic"
        ]
        self.assertEqual(
            [(item["phase"], item["status"]) for item in diagnostics],
            [("prepare", "started"), ("prepare", "failed")],
        )
        self.assertEqual(
            diagnostics[0]["operationId"],
            diagnostics[1]["operationId"],
        )
        self.assertEqual(diagnostics[1]["errorType"], "FileNotFoundError")
        self.assertIn("prepare-main", diagnostics[1]["message"])
        self.assertEqual(
            sum(message.get("type") == "error" for message in messages),
            0,
        )
        self.assertNotIn(CARD_HASH, output.getvalue())
        self.assertNotIn(CARD_HASH[:8], output.getvalue())

    def test_artwork_cache_failure_rolls_back_database_colors(self) -> None:
        prepared = self.prepared_database()
        rollback = Mock()
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as temporary:
            image_path = Path(temporary) / "card.png"
            image_path.write_bytes(PNG_1X1)
            with (
                patch.object(
                    aircard_backend,
                    "prepare_wallet_db_patch",
                    return_value=prepared,
                ),
                patch.object(aircard_backend, "apply_wallet_db_patch"),
                patch.object(
                    aircard_backend,
                    "rollback_wallet_db_patch",
                    rollback,
                ),
                patch.object(
                    aircard_backend,
                    "write_file",
                    side_effect=[
                        True,
                        True,
                        True,
                        False,
                        True,
                        True,
                        True,
                        True,
                        True,
                    ],
                ),
                redirect_stdout(output),
            ):
                result = aircard_backend.cmd_flash(
                    "device",
                    CARD_HASH,
                    str(image_path),
                    foreground_color="#AABBCC",
                )

        self.assertFalse(result)
        rollback.assert_called_once_with("device", prepared)
        self.assertIn("Wallet database rollback verified", output.getvalue())
        messages = [
            json.loads(line) for line in output.getvalue().splitlines()
        ]
        diagnostics = [
            (message["phase"], message["status"])
            for message in messages
            if message.get("type") == "diagnostic"
        ]
        self.assertIn(("rollback", "started"), diagnostics)
        self.assertIn(("rollback", "completed"), diagnostics)
        self.assertNotIn(("transaction", "completed"), diagnostics)

    def test_flash_writes_pdf_and_invalidates_placeholder(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image_path = Path(temporary) / "card.png"
            image_path.write_bytes(PNG_1X1)
            write_file = Mock(return_value=True)

            with (
                patch.object(
                    aircard_backend,
                    "prepare_wallet_db_patch",
                ) as prepare_database,
                patch.object(
                    aircard_backend,
                    "apply_wallet_db_patch",
                ) as apply_database,
                patch.object(aircard_backend, "write_file", write_file),
                redirect_stdout(io.StringIO()),
            ):
                result = aircard_backend.cmd_flash(
                    "device",
                    CARD_HASH,
                    str(image_path),
                )

        self.assertTrue(result)
        prepare_database.assert_not_called()
        apply_database.assert_not_called()
        writes = [call.args for call in write_file.call_args_list]
        pass_assets = {
            leaf: payload
            for _, target, leaf, payload in writes
            if target.endswith(".pkpass")
        }
        self.assertEqual(
            set(pass_assets),
            {
                "cardBackgroundCombined@3x.png",
                "cardBackgroundCombined@2x.png",
                "cardBackgroundCombined.pdf",
            },
        )
        self.assertTrue(
            pass_assets["cardBackgroundCombined.pdf"].startswith(b"%PDF-")
        )

        cache_entries = {(target, leaf) for _, target, leaf, _ in writes}
        for extension in (".cache", ".pkcache"):
            for leaf in aircard_backend.CACHE_FILES:
                self.assertIn(
                    (
                        f"/var/mobile/Library/Passes/Cards/"
                        f"{CARD_HASH}{extension}",
                        leaf,
                    ),
                    cache_entries,
                )

    def test_flash_reports_failure_when_an_asset_write_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image_path = Path(temporary) / "card.png"
            image_path.write_bytes(PNG_1X1)
            output = io.StringIO()
            with (
                patch.object(
                    aircard_backend,
                    "write_file",
                    side_effect=[
                        True,
                        True,
                        False,
                        True,
                        True,
                        True,
                        True,
                        True,
                        True,
                    ],
                ),
                redirect_stdout(output),
            ):
                result = aircard_backend.cmd_flash(
                    "device",
                    CARD_HASH,
                    str(image_path),
                )

        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertFalse(result)
        self.assertEqual(messages[-1]["type"], "error")
        self.assertFalse(
            any(message["type"] == "success" for message in messages)
        )

    def test_flash_reports_failure_when_pdf_conversion_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image_path = Path(temporary) / "card.png"
            image_path.write_bytes(PNG_1X1)
            write_file = Mock(return_value=True)
            output = io.StringIO()

            with (
                patch.object(aircard_backend, "write_file", write_file),
                patch.object(
                    aircard_backend,
                    "build_card_assets",
                    side_effect=subprocess.CalledProcessError(1, ["sips"]),
                ),
                redirect_stdout(output),
            ):
                result = aircard_backend.cmd_flash(
                    "device",
                    CARD_HASH,
                    str(image_path),
                )

        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertFalse(result)
        self.assertEqual(messages[-1]["type"], "error")
        write_file.assert_not_called()


if __name__ == "__main__":
    unittest.main()
