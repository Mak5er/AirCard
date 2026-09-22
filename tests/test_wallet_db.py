import json
import sqlite3
import tempfile
import unittest
from contextlib import closing, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import Mock, patch

import aircard_backend
import apply_card_skin


CARD_HASH = "ABCDEFGHIJKLMNOPQRST="


def create_database(
    path: Path,
    *,
    columns: str = (
        "unique_id TEXT, foreground_color TEXT, label_color TEXT, "
        "primary_account_suffix TEXT"
    ),
    rows: list[tuple[str, str, str, str | None]] | None = None,
) -> None:
    with closing(sqlite3.connect(path)) as connection:
        connection.execute(f"CREATE TABLE pass ({columns})")
        if rows:
            connection.executemany(
                """
                INSERT INTO pass (
                    unique_id,
                    foreground_color,
                    label_color,
                    primary_account_suffix
                )
                VALUES (?, ?, ?, ?)
                """,
                rows,
            )
        connection.commit()


def database_bytes(
    *,
    rows: list[tuple[str, str, str, str | None]] | None = None,
    columns: str = (
        "unique_id TEXT, foreground_color TEXT, label_color TEXT, "
        "primary_account_suffix TEXT"
    ),
) -> bytes:
    with tempfile.TemporaryDirectory() as temporary:
        database = Path(temporary) / "passes23.sqlite"
        create_database(database, columns=columns, rows=rows)
        return database.read_bytes()


class WalletDBInspectionTests(unittest.TestCase):
    def test_delete_journal_database_without_sidecars(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "fixture.sqlite"
            create_database(
                database,
                rows=[
                    (
                        CARD_HASH,
                        "rgb(1, 2, 3)",
                        "rgb(4, 5, 6)",
                        None,
                    )
                ],
            )
            fixtures = {"passes23.sqlite": database.read_bytes()}

        with patch.object(
            apply_card_skin,
            "_extract_wallet_db_main_without_sidecars",
            return_value=fixtures["passes23.sqlite"],
        ):
            result = apply_card_skin.inspect_wallet_db("device", CARD_HASH)

        self.assertEqual(result["journalMode"], "delete")
        self.assertEqual(result["quickCheck"], ["ok"])
        self.assertEqual(result["rowCount"], 1)
        self.assertEqual(result["foregroundColor"], "rgb(1, 2, 3)")
        self.assertEqual(result["labelColor"], "rgb(4, 5, 6)")
        self.assertIsNone(result["primaryAccountSuffix"])
        self.assertEqual(
            result["sidecars"],
            {"journal": False, "wal": False, "shm": False},
        )
        self.assertIsNone(result["fileSizes"]["passes23.sqlite-journal"])
        self.assertIsNone(result["fileSizes"]["passes23.sqlite-wal"])
        self.assertNotIn(CARD_HASH, json.dumps(result))

    def test_wal_database_is_rejected_by_local_patch_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "passes23.sqlite"
            connection = sqlite3.connect(database)
            try:
                self.assertEqual(
                    connection.execute("PRAGMA journal_mode=WAL").fetchone()[0],
                    "wal",
                )
                connection.execute("PRAGMA wal_autocheckpoint=0")
                connection.execute(
                    """
                    CREATE TABLE pass (
                        unique_id TEXT,
                        foreground_color TEXT,
                        label_color TEXT,
                        primary_account_suffix TEXT
                    )
                    """
                )
                connection.execute(
                    "INSERT INTO pass VALUES (?, ?, ?, ?)",
                    (CARD_HASH, "fg", "label", "1234"),
                )
                connection.commit()
                connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                wal_database = database.read_bytes()
            finally:
                connection.close()

        with self.assertRaisesRegex(
            ValueError,
            "journal_mode must be delete",
        ):
            apply_card_skin.patch_wallet_db(
                wal_database,
                CARD_HASH,
                primary_account_suffix="0042",
            )

    def test_device_inspection_propagates_guarded_read_failure(self) -> None:
        with (
            patch.object(
                apply_card_skin,
                "_extract_wallet_db_main_without_sidecars",
                side_effect=RuntimeError(
                    "sidecars-present-or-unknown-before-read"
                ),
            ),
            self.assertRaisesRegex(RuntimeError, "sidecars-present"),
        ):
            apply_card_skin.inspect_wallet_db("device", CARD_HASH)

    def test_schema_missing_required_column_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "fixture.sqlite"
            with closing(sqlite3.connect(database)) as connection:
                connection.execute(
                    "CREATE TABLE pass (unique_id TEXT, foreground_color TEXT)"
                )
                connection.commit()
            fixtures = {"passes23.sqlite": database.read_bytes()}

        with (
            patch.object(
                apply_card_skin,
                "_extract_wallet_db_main_without_sidecars",
                return_value=fixtures["passes23.sqlite"],
            ),
            self.assertRaisesRegex(ValueError, "label_color"),
        ):
            apply_card_skin.inspect_wallet_db("device", CARD_HASH)

    def test_schema_missing_suffix_is_rejected(self) -> None:
        database = database_bytes(
            columns="unique_id TEXT, foreground_color TEXT, label_color TEXT"
        )
        with self.assertRaisesRegex(ValueError, "primary_account_suffix"):
            apply_card_skin.inspect_wallet_db_bytes(database, CARD_HASH)

    def test_zero_or_duplicate_matches_are_rejected(self) -> None:
        for rows, expected in (
            ([], "found 0"),
            (
                [
                    (CARD_HASH, "fg1", "label1", "1111"),
                    (CARD_HASH, "fg2", "label2", "2222"),
                ],
                "found at least 2",
            ),
        ):
            with self.subTest(expected=expected):
                with tempfile.TemporaryDirectory() as temporary:
                    database = Path(temporary) / "fixture.sqlite"
                    create_database(database, rows=rows)
                    fixtures = {"passes23.sqlite": database.read_bytes()}

                with (
                    patch.object(
                        apply_card_skin,
                        "_extract_wallet_db_main_without_sidecars",
                        return_value=fixtures["passes23.sqlite"],
                    ),
                    self.assertRaisesRegex(ValueError, expected),
                ):
                    apply_card_skin.inspect_wallet_db("device", CARD_HASH)

    def test_invalid_hash_is_rejected_before_extraction(self) -> None:
        read_database = Mock()
        with (
            patch.object(
                apply_card_skin,
                "_extract_wallet_db_main_without_sidecars",
                read_database,
            ),
            self.assertRaisesRegex(ValueError, "invalid card hash"),
        ):
            apply_card_skin.inspect_wallet_db("device", "../outside")
        read_database.assert_not_called()

    def test_sidecar_transport_failure_is_not_treated_as_absent(self) -> None:
        with (
            patch.object(
                apply_card_skin,
                "_extract_wallet_db_main_without_sidecars",
                side_effect=RuntimeError("transport interrupted"),
            ),
            self.assertRaisesRegex(RuntimeError, "transport interrupted"),
        ):
            apply_card_skin.inspect_wallet_db("device", CARD_HASH)

    def test_cli_prints_one_sanitized_json_object(self) -> None:
        output = StringIO()
        with (
            patch.object(
                aircard_backend,
                "inspect_wallet_db",
                return_value={
                    "rowCount": 1,
                    "foregroundColor": "fg",
                    "labelColor": "label",
                    "primaryAccountSuffix": None,
                },
            ),
            redirect_stdout(output),
        ):
            self.assertTrue(
                aircard_backend.cmd_inspect_wallet_db("device", CARD_HASH)
            )

        lines = output.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertTrue(json.loads(lines[0])["ok"])
        self.assertNotIn(CARD_HASH, lines[0])

    def test_cli_error_prints_one_json_object_and_exits_one(self) -> None:
        output = StringIO()
        with (
            patch.object(
                aircard_backend,
                "inspect_wallet_db",
                side_effect=ValueError("invalid card hash"),
            ),
            patch.object(
                aircard_backend.sys,
                "argv",
                [
                    "aircard_backend.py",
                    "--inspect-wallet-db",
                    "device",
                    "../outside",
                ],
            ),
            redirect_stdout(output),
            self.assertRaises(SystemExit) as exit_status,
        ):
            aircard_backend.main()

        self.assertEqual(exit_status.exception.code, 1)
        lines = output.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(
            json.loads(lines[0]),
            {"ok": False, "error": "invalid card hash"},
        )


class WalletDBPatchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.original = database_bytes(
            rows=[
                (
                    CARD_HASH,
                    "rgba(1, 2, 3, 1.00)",
                    "rgba(4, 5, 6, 1.00)",
                    "1234",
                ),
                (
                    "ZYXWVUTSRQPONMLKJIHG=",
                    "other foreground",
                    "other label",
                    "9876",
                ),
            ]
        )

    def prepared(self) -> dict:
        result = apply_card_skin.patch_wallet_db(
            self.original,
            CARD_HASH,
            foreground_color="#AABBCC",
        )
        result["cardHash"] = CARD_HASH
        return result

    def test_patch_changes_only_requested_column(self) -> None:
        result = apply_card_skin.patch_wallet_db(
            self.original,
            CARD_HASH,
            foreground_color="#AABBCC",
        )
        inspected = apply_card_skin.inspect_wallet_db_bytes(
            result["patchedBytes"],
            CARD_HASH,
        )

        self.assertEqual(
            result["originalColors"],
            {
                "foreground_color": "rgba(1, 2, 3, 1.00)",
                "label_color": "rgba(4, 5, 6, 1.00)",
                "primary_account_suffix": "1234",
            },
        )
        self.assertEqual(
            inspected["foregroundColor"],
            "rgba(170, 187, 204, 1.00)",
        )
        self.assertEqual(
            inspected["labelColor"],
            "rgba(4, 5, 6, 1.00)",
        )
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "patched.sqlite"
            database.write_bytes(result["patchedBytes"])
            with closing(sqlite3.connect(database)) as connection:
                other = connection.execute(
                    """
                    SELECT
                        foreground_color,
                        label_color,
                        primary_account_suffix
                    FROM pass
                    WHERE unique_id = ?
                    """,
                    ("ZYXWVUTSRQPONMLKJIHG=",),
                ).fetchone()
        self.assertEqual(other, ("other foreground", "other label", "9876"))

    def test_rgba_normalization_accepts_hex_and_rgb(self) -> None:
        result = apply_card_skin.patch_wallet_db(
            self.original,
            CARD_HASH,
            foreground_color="#00ff7F",
            label_color="rgb(9, 10, 255)",
        )
        self.assertEqual(
            result["appliedColors"],
            {
                "foreground_color": "rgba(0, 255, 127, 1.00)",
                "label_color": "rgba(9, 10, 255, 1.00)",
                "primary_account_suffix": "1234",
            },
        )

    def test_suffix_patch_accepts_four_ascii_digits(self) -> None:
        result = apply_card_skin.patch_wallet_db(
            self.original,
            CARD_HASH,
            primary_account_suffix="0042",
        )
        inspected = apply_card_skin.inspect_wallet_db_bytes(
            result["patchedBytes"],
            CARD_HASH,
        )

        self.assertEqual(inspected["primaryAccountSuffix"], "0042")
        self.assertEqual(
            result["originalColors"]["primary_account_suffix"],
            "1234",
        )
        self.assertEqual(
            result["appliedColors"]["primary_account_suffix"],
            "0042",
        )

    def test_explicit_null_suffix_sets_sql_null(self) -> None:
        result = apply_card_skin.patch_wallet_db(
            self.original,
            CARD_HASH,
            primary_account_suffix="NULL",
        )
        inspected = apply_card_skin.inspect_wallet_db_bytes(
            result["patchedBytes"],
            CARD_HASH,
        )
        self.assertIsNone(inspected["primaryAccountSuffix"])
        self.assertIsNone(
            result["appliedColors"]["primary_account_suffix"]
        )

    def test_invalid_suffix_is_rejected_before_local_database_write(self) -> None:
        for value in (
            "",
            None,
            "null",
            "123",
            "12345",
            "12A4",
            "１２３４",
            "١٢٣٤",
        ):
            with self.subTest(value=value):
                with (
                    patch.object(Path, "write_bytes") as write_bytes,
                    self.assertRaisesRegex(ValueError, "ASCII digits"),
                ):
                    apply_card_skin.patch_wallet_db(
                        self.original,
                        CARD_HASH,
                        primary_account_suffix=value,
                    )
                write_bytes.assert_not_called()

    def test_patch_reuses_schema_and_row_gates(self) -> None:
        missing_column = database_bytes(
            columns="unique_id TEXT, foreground_color TEXT"
        )
        with self.assertRaisesRegex(ValueError, "label_color"):
            apply_card_skin.patch_wallet_db(
                missing_column,
                CARD_HASH,
                foreground_color="#000000",
            )

        no_match = database_bytes(rows=[])
        with self.assertRaisesRegex(ValueError, "found 0"):
            apply_card_skin.patch_wallet_db(
                no_match,
                CARD_HASH,
                foreground_color="#000000",
            )

    def test_wal_journal_mode_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "passes23.sqlite"
            with closing(sqlite3.connect(database)) as connection:
                self.assertEqual(
                    connection.execute("PRAGMA journal_mode=WAL").fetchone()[0],
                    "wal",
                )
                connection.execute(
                    """
                    CREATE TABLE pass (
                        unique_id TEXT,
                        foreground_color TEXT,
                        label_color TEXT,
                        primary_account_suffix TEXT
                    )
                    """
                )
                connection.execute(
                    "INSERT INTO pass VALUES (?, ?, ?, ?)",
                    (CARD_HASH, "fg", "label", "1234"),
                )
                connection.commit()
                connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                wal_database = database.read_bytes()

        with self.assertRaisesRegex(ValueError, "journal_mode must be delete"):
            apply_card_skin.patch_wallet_db(
                wal_database,
                CARD_HASH,
                foreground_color="#000000",
            )

    def test_sidecar_presence_is_rejected_before_patch(self) -> None:
        with (
            patch.object(
                apply_card_skin,
                "_extract_wallet_db_main_without_sidecars",
                side_effect=RuntimeError(
                    "sidecars-present-or-unknown-before-read"
                ),
            ),
            self.assertRaisesRegex(RuntimeError, "sidecars-present"),
        ):
            apply_card_skin.prepare_wallet_db_patch(
                "device",
                CARD_HASH,
                foreground_color="#000000",
            )

    def test_sidecar_check_failure_is_rejected_as_unknown(self) -> None:
        with (
            patch.object(
                apply_card_skin,
                "_extract_wallet_db_main_without_sidecars",
                side_effect=RuntimeError("transport interrupted"),
            ),
            self.assertRaisesRegex(RuntimeError, "transport interrupted"),
        ):
            apply_card_skin.prepare_wallet_db_patch(
                "device",
                CARD_HASH,
                foreground_color="#000000",
            )

    def test_prewrite_mismatch_aborts_without_database_write(self) -> None:
        prepared = self.prepared()
        with (
            patch.object(
                apply_card_skin,
                "_extract_wallet_db_main_without_sidecars",
                return_value=b"database changed",
            ),
            patch.object(apply_card_skin, "write_file") as write_database,
            patch.object(
                apply_card_skin,
                "rollback_wallet_db_patch",
            ) as rollback,
            self.assertRaisesRegex(
                apply_card_skin.WalletDBPrewriteChangedError,
                "changed after preparation",
            ),
        ):
            apply_card_skin.apply_wallet_db_patch("device", prepared)
        write_database.assert_not_called()
        rollback.assert_not_called()

    def test_success_validates_exact_extracted_readback(self) -> None:
        prepared = self.prepared()
        with (
            patch.object(
                apply_card_skin,
                "_extract_wallet_db_main_without_sidecars",
                side_effect=[
                    prepared["originalBytes"],
                    prepared["patchedBytes"],
                ],
            ) as extract_database,
            patch.object(
                apply_card_skin,
                "write_file",
                return_value=True,
            ) as write_database,
        ):
            result = apply_card_skin.apply_wallet_db_patch("device", prepared)

        write_database.assert_called_once_with(
            "device",
            apply_card_skin.WALLET_DB_TARGET,
            "passes23.sqlite",
            prepared["patchedBytes"],
            retries=1,
        )
        self.assertEqual(extract_database.call_count, 2)
        self.assertEqual(result["quickCheck"], ["ok"])
        self.assertEqual(result["journalMode"], "delete")
        self.assertEqual(
            result["foregroundColor"],
            prepared["appliedColors"]["foreground_color"],
        )

    def test_write_failure_with_original_still_present_needs_no_rollback_write(
        self,
    ) -> None:
        prepared = self.prepared()
        with (
            patch.object(
                apply_card_skin,
                "_extract_wallet_db_main_without_sidecars",
                side_effect=[
                    prepared["originalBytes"],
                    prepared["originalBytes"],
                ],
            ),
            patch.object(
                apply_card_skin,
                "write_file",
                return_value=False,
            ) as write_database,
            patch.object(
                apply_card_skin,
                "_write_wallet_db_and_verify",
                wraps=apply_card_skin._write_wallet_db_and_verify,
            ),
            self.assertRaisesRegex(
                RuntimeError,
                "failed to write Wallet database",
            ),
        ):
            apply_card_skin.apply_wallet_db_patch("device", prepared)
        write_database.assert_called_once()

    def test_prewrite_failure_reports_exact_phase(self) -> None:
        def extract(
            _udid,
            _target,
            leaf,
            _output_path,
            **_kwargs,
        ):
            raise FileNotFoundError(f"{leaf} file not found")

        with (
            patch.object(
                apply_card_skin,
                "extract_file",
                side_effect=extract,
            ),
            self.assertRaisesRegex(
                RuntimeError,
                "apply-prewrite-main: FileNotFoundError: "
                "passes23.sqlite file not found",
            ),
        ):
            apply_card_skin._extract_wallet_db_main_without_sidecars(
                "device",
                "apply-prewrite",
            )

    def test_readback_mismatch_rolls_back_only_from_exact_patch(self) -> None:
        prepared = self.prepared()
        mismatched = prepared["patchedBytes"] + b"mismatch"
        with (
            patch.object(
                apply_card_skin,
                "_extract_wallet_db_main_without_sidecars",
                side_effect=[
                    prepared["originalBytes"],
                    mismatched,
                    mismatched,
                ],
            ),
            patch.object(
                apply_card_skin,
                "write_file",
                return_value=True,
            ) as write_database,
            self.assertRaisesRegex(
                RuntimeError,
                "FATAL: wallet database rollback could not be verified",
            ),
        ):
            apply_card_skin.apply_wallet_db_patch("device", prepared)
        self.assertEqual(write_database.call_count, 1)

    def test_public_rollback_restores_only_exact_patched_bytes(self) -> None:
        prepared = self.prepared()
        with (
            patch.object(
                apply_card_skin,
                "_extract_wallet_db_main_without_sidecars",
                side_effect=[
                    prepared["patchedBytes"],
                    prepared["originalBytes"],
                ],
            ),
            patch.object(
                apply_card_skin,
                "write_file",
                return_value=True,
            ) as write_database,
        ):
            apply_card_skin.rollback_wallet_db_patch("device", prepared)

        write_database.assert_called_once_with(
            "device",
            apply_card_skin.WALLET_DB_TARGET,
            "passes23.sqlite",
            prepared["originalBytes"],
            retries=1,
        )

    def test_rollback_refusal_or_unknown_current_bytes_is_fatal(self) -> None:
        prepared = self.prepared()
        with (
            patch.object(
                apply_card_skin,
                "_extract_wallet_db_main_without_sidecars",
                return_value=b"unknown current bytes",
            ),
            patch.object(apply_card_skin, "write_file") as write_database,
            self.assertRaisesRegex(
                RuntimeError,
                "FATAL: wallet database rollback could not be verified",
            ),
        ):
            apply_card_skin.rollback_wallet_db_patch("device", prepared)
        write_database.assert_not_called()


class WalletDBTransportTests(unittest.TestCase):
    def test_extract_main_rejects_any_present_sidecar(self) -> None:
        for sidecar in (
            "passes23.sqlite-journal",
            "passes23.sqlite-wal",
            "passes23.sqlite-shm",
        ):
            with self.subTest(sidecar=sidecar):
                def extract(
                    _udid,
                    _target,
                    leaf,
                    _output_path,
                    **_kwargs,
                ):
                    if leaf == "passes23.sqlite":
                        return b"database"
                    if leaf == sidecar:
                        return b"sidecar"
                    raise FileNotFoundError(leaf)

                with (
                    patch.object(
                        apply_card_skin,
                        "extract_file",
                        side_effect=extract,
                    ),
                    self.assertRaisesRegex(RuntimeError, "sidecar exists"),
                ):
                    apply_card_skin._extract_wallet_db_main_without_sidecars(
                        "device"
                    )

    def test_extract_main_accepts_only_explicitly_missing_sidecars(self) -> None:
        def extract(_udid, _target, leaf, _output_path, **_kwargs):
            if leaf == "passes23.sqlite":
                return b"database"
            raise FileNotFoundError(leaf)

        with patch.object(
            apply_card_skin,
            "extract_file",
            side_effect=extract,
        ) as extract_mock:
            database = (
                apply_card_skin._extract_wallet_db_main_without_sidecars(
                    "device"
                )
            )

        self.assertEqual(database, b"database")
        self.assertEqual(
            [call.args[2] for call in extract_mock.call_args_list],
            [
                "passes23.sqlite",
                "passes23.sqlite-journal",
                "passes23.sqlite-wal",
                "passes23.sqlite-shm",
            ],
        )

    def test_extract_main_treats_sidecar_transport_error_as_unknown(self) -> None:
        with (
            patch.object(
                apply_card_skin,
                "extract_file",
                side_effect=RuntimeError("transport interrupted"),
            ),
            self.assertRaisesRegex(RuntimeError, "transport interrupted"),
        ):
            apply_card_skin._extract_wallet_db_main_without_sidecars("device")

    def test_write_database_uses_airtraffic_and_extracts_readback(self) -> None:
        with (
            patch.object(
                apply_card_skin,
                "write_file",
                return_value=True,
            ) as write_database,
            patch.object(
                apply_card_skin,
                "_extract_wallet_db_main_without_sidecars",
                return_value=b"replacement",
            ) as extract_database,
        ):
            readback = apply_card_skin._write_wallet_db_and_verify(
                "device",
                b"replacement",
            )

        self.assertEqual(readback, b"replacement")
        write_database.assert_called_once_with(
            "device",
            apply_card_skin.WALLET_DB_TARGET,
            "passes23.sqlite",
            b"replacement",
            retries=1,
        )
        extract_database.assert_called_once_with(
            "device",
            "apply-readback",
        )

    def test_native_extract_allowlist_includes_all_database_sidecars(self) -> None:
        source = (
            Path(apply_card_skin.ROOT) / "Sources" / "device_helper.m"
        ).read_text()
        start = source.index("static NSDictionary *Extract(")
        end = source.index("\nstatic NSDictionary *FinishExtract", start)
        allowlist = source[start:end]

        for leaf in (
            "passes23.sqlite",
            "passes23.sqlite-journal",
            "passes23.sqlite-wal",
            "passes23.sqlite-shm",
        ):
            self.assertIn(leaf, allowlist)

    def test_native_extract_cleanup_removes_recovery_before_rewrite(
        self,
    ) -> None:
        source = (
            Path(apply_card_skin.ROOT) / "Sources" / "device_helper.m"
        ).read_text()
        start = source.index("static NSDictionary *FinishExtract(")
        end = source.index(
            "\nstatic NSDictionary *ListWalletDBRecoveryCandidates",
            start,
        )
        cleanup = source[start:end]

        link_removal = cleanup.index(
            "RemoveIfPresent(session->afc, linkDestination)"
        )
        recovery_removal = cleanup.index(
            "RemoveIfPresent(session->afc, recovered)"
        )
        self.assertLess(link_removal, recovery_removal)
        self.assertIn('@"recoveredAbsent": @YES', cleanup)

    def test_airtraffic_host_allows_one_pair_and_exits_before_python_timeout(
        self,
    ) -> None:
        source = (
            Path(apply_card_skin.ROOT) / "Sources" / "airtraffic_host.m"
        ).read_text()
        self.assertIn("if (argc < 4 || argc % 2 != 0)", source)
        self.assertIn("alarm(110)", source)


if __name__ == "__main__":
    unittest.main()
