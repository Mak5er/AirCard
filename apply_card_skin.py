#!/usr/bin/env python3
"""Apply custom card skins to Apple Wallet passes using airlift exploit."""

from __future__ import annotations

import io
import json
import os
import plistlib
import posixpath
import secrets
import signal
import re
import sqlite3
from contextlib import closing, contextmanager
from contextvars import ContextVar
import selectors
import stat
import struct
import subprocess
import sys
import tempfile
import time
import zipfile
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
_wallet_db_progress = ContextVar("wallet_db_progress", default=None)


@contextmanager
def wallet_db_progress(callback):
    """Observe transaction checkpoints without changing device operations."""
    token = _wallet_db_progress.set(callback)
    try:
        yield
    finally:
        _wallet_db_progress.reset(token)


def _report_wallet_db_progress(phase, index=0):
    callback = _wallet_db_progress.get()
    if callback is None:
        return
    stages = {
        "prepare": (0, "準備資料庫"),
        "apply-prewrite": (4, "寫入前比對"),
        "apply-write": (8, "寫入資料庫"),
        "apply-readback": (9, "寫入後讀回驗證"),
        "apply-validate": (13, "驗證資料庫完整性與卡片欄位"),
    }
    if phase.startswith("rollback"):
        callback(None, "更新失敗，正在檢查並還原原始資料庫…")
        return
    stage = stages.get(phase.removesuffix("-after"))
    if stage is not None:
        step, label = stage
        detail = ("讀取主資料庫", "檢查 journal 日誌", "檢查 WAL 日誌", "檢查 SHM 附屬檔")[index]
        callback(step + index, f"{label}：{detail}…" if phase not in ("apply-write", "apply-validate") else f"{label}…")


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


def _helper_failure(command, returncode, stderr):
    name = Path(command[0]).name
    action = f" {command[1]}" if name == "device_helper" and len(command) > 1 else ""
    status = f"退出碼 {returncode}"
    if returncode < 0:
        try:
            status += f"，訊號 {signal.Signals(-returncode).name}"
        except ValueError:
            pass
    detail = stderr.strip()[-2048:] or "未提供錯誤輸出"
    return RuntimeError(f"{name}{action} 執行失敗（{status}）：{detail}")


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
    if result is None or completed.returncode < 0:
        raise _helper_failure(command, completed.returncode, completed.stderr)
    result["exitCode"] = completed.returncode
    return result


def run_json_streaming(command: list[str], timeout: int, on_progress=None) -> dict:
    # Drain both pipes while enforcing a deadline for the entire process,
    # including periods with no output or an incomplete JSON line.
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + timeout
    result = None
    pending = b""
    stderr = bytearray()

    def consume(line):
        nonlocal result
        try:
            value = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return
        if isinstance(value, dict):
            if value.get("type") in ("atc_progress", "atc_status"):
                if on_progress:
                    on_progress(value)
            else:
                result = value

    try:
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ)
            selector.register(proc.stderr, selectors.EVENT_READ)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                for key, _ in selector.select(remaining):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    elif key.fileobj is proc.stderr:
                        stderr.extend(chunk)
                        del stderr[:-65536]
                    else:
                        pending += chunk
                        while b"\n" in pending:
                            line, pending = pending.split(b"\n", 1)
                            consume(line)
            if pending:
                consume(pending)
            proc.wait(timeout=max(0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired as error:
        raise TimeoutError(f"{Path(command[0]).name}在 {timeout} 秒後逾時") from error
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        proc.stdout.close()
        proc.stderr.close()

    if result is None or proc.returncode < 0:
        raise _helper_failure(command, proc.returncode, stderr.decode(errors='replace'))
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


def require_airtraffic_device(udid: str) -> None:
    """Check the actual AirTraffic handshake before staging any files."""
    result = run_json([os.fspath(AIRTRAFFIC_HOST), "--probe", udid], timeout=20)
    if result.get("exitCode") != 0 or not result.get("ok") or not result.get("syncAllowed"):
        raise ConnectionError(
            f"AirTraffic 握手失敗： {result.get('error', '未收到 SyncAllowed')}. "
            "請解鎖 iPhone 並檢查連線後重試。"
        )


def write_file(udid: str, target: str, leaf: str, payload: bytes, retries: int = 3) -> bool:
    require_airtraffic_device(udid)
    for attempt in range(1, max(1, retries) + 1):
        try:
            token = secrets.token_hex(10)
            source = f"{SOURCE_PREFIX}{token}"
            link_destination = f"{LINK_PREFIX}{token}"
            recovered = f"{RECOVERED_PREFIX}{token}"

            link_identifier = f"../../{source}/p0/p1/p2/link"
            payload_identifier = f"../../{source}/payload"

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
                    if attempt < retries:
                        time.sleep(0.3 * attempt)
                        continue
                    return False

                atc_cmd = [os.fspath(AIRTRAFFIC_HOST), udid]
                for identifier, destination in zip(identifiers, destinations):
                    atc_cmd.extend((identifier, destination))
                try:
                    atc = run_json(atc_cmd, timeout=120)
                finally:
                    finish = native(
                        "finish-write", udid, source, link_destination,
                        recovered, os.fspath(snapshot_root),
                    )

            ok = bool(atc.get("exitCode") == 0 and atc.get("ok") and operation_ok(finish))
            if ok:
                return True
        except (TimeoutError, subprocess.TimeoutExpired):
            raise
        except Exception as error:
            print(f"第 {attempt} 次寫入失敗：{error}", file=sys.stderr, flush=True)

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
    def report(message):
        if progress_callback:
            progress_callback({"type": "atc_status", "message": message})
        else:
            print(message, file=sys.stderr, flush=True)

    if not files:
        return True

    report("正在檢查 AirTraffic 連線…")
    require_airtraffic_device(udid)
    for attempt in range(1, max(1, retries) + 1):
        try:
            token = secrets.token_hex(10)
            source = f"{SOURCE_PREFIX}{token}"
            link_destination = f"{LINK_PREFIX}{token}"
            recovered = f"{RECOVERED_PREFIX}{token}"

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

                report(f"正在備份 Books 狀態（第 {attempt}/{max(1, retries)} 次嘗試）…")
                snapshot = native("snapshot-books", udid, os.fspath(snapshot_root))
                if not operation_ok(snapshot):
                    report(f"Books 狀態備份失敗： {snapshot}")
                    if attempt < retries:
                        time.sleep(0.4 * attempt)
                        continue
                    return False

                report("正在將圖片暫存到裝置…")
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
                    report(f"暫存失敗： {stage}")
                    if attempt < retries:
                        time.sleep(0.4 * attempt)
                        continue
                    return False

                atc_cmd = [os.fspath(AIRTRAFFIC_HOST), udid]
                for identifier, destination in zip(identifiers, destinations):
                    atc_cmd.extend((identifier, destination))

                timeout = max(120, len(files) * 2)
                try:
                    atc = run_json_streaming(atc_cmd, timeout=timeout, on_progress=progress_callback)
                    if not atc.get("ok"):
                        report(f"AirTraffic 操作失敗： {atc.get('error', '未知錯誤')}")
                finally:
                    report("正在恢復 Books 狀態並清理臨時檔案…")
                    finish = native(
                        "finish-write", udid, source, link_destination,
                        recovered, os.fspath(snapshot_root),
                    )
                    if not operation_ok(finish):
                        report(f"清理失敗： {finish}")

            ok = bool(atc.get("exitCode") == 0 and atc.get("ok") and operation_ok(finish))
            if ok:
                return True
        except (TimeoutError, subprocess.TimeoutExpired):
            # Repeating a stalled connection for every asset can take many minutes.
            raise
        except Exception as error:
            report(f"第 {attempt} 次批量寫入失敗： {error}")

        if attempt < retries:
            time.sleep(0.4 * attempt)

    return False


def invalidate_cache(udid: str, card_hash: str) -> bool:
    """Remove every rendered card face so Wallet must rebuild from the pass."""
    all_ok = True
    cache_leaves = ["FrontFace", "PlaceHolder", "Preview"]
    for ext in [".cache", ".pkcache"]:
        cache_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}{ext}"
        try:
            all_ok = remove_files(udid, cache_dir, cache_leaves) and all_ok
        except Exception:
            all_ok = False
    return all_ok


def validate_card_hash(card_hash: str) -> None:
    if not CARD_HASH_RE.fullmatch(card_hash):
        raise ValueError("卡片雜湊值無效")


def _confirmed_missing_recovery_file(result: dict) -> bool:
    """Accept only the typed AFC not-found result, never a generic read failure."""
    operation = result.get("operation", {})
    return bool(
        result.get("exitCode") == 2
        and result.get("targetGatePassed")
        and operation.get("ok") is False
        and operation.get("reasonCode") == "file_not_found"
        and operation.get("afcStatus") == 8
    )


def extract_file(udid: str, target: str, leaf: str, output_path: str,
                 retries: int = 1, raise_errors: bool = False) -> bytes | None:
    """Temporarily relocate an allowed file; retain recovered bytes until restored.

    Reading through this transport is not a read-only device operation. A failed
    restore leaves the recovered file on the device for recovery, never deletes it.
    """
    target = posixpath.normpath(target)
    if leaf not in EXTRACT_ALLOWED_LEAVES or not (
        target == WALLET_DB_TARGET or target.startswith(WALLET_DB_TARGET + "/")
    ):
        raise ValueError("不支援擷取此目標")
    require_airtraffic_device(udid)
    token = secrets.token_hex(10)
    source, link, recovered = (SOURCE_PREFIX + token, LINK_PREFIX + token, RECOVERED_PREFIX + token)
    link_id = f"../../{source}/p0/p1/p2/link"
    target_id = posixpath.relpath(posixpath.join(target, leaf), AIRLOCK_ROOT)
    try:
        with tempfile.TemporaryDirectory(prefix="airlift-extract-") as temporary:
            work = Path(temporary)
            snapshot = work / "books-snapshot"
            snapshot.mkdir()
            archive, books = work / "payload.zip", work / "Books.plist"
            archive.write_bytes(build_archive(target, b"aircard-extract"))
            books.write_bytes(build_books([link_id, target_id]))
            if not operation_ok(native("snapshot-books", udid, str(snapshot))):
                raise RuntimeError("備份 Books 狀態失敗")
            cleanup_authorized = False
            relocated = False
            missing = False
            missing_after_dispatch = False
            extraction_error = None
            extracted = None
            try:
                stage = native("stage", udid, source, link, recovered,
                               str(archive), str(books), str(snapshot))
                cleanup_authorized = bool(stage.get("operation", {}).get("cleanupAuthorized", operation_ok(stage)))
                if not operation_ok(stage):
                    raise RuntimeError("擷取暫存失敗")
                relocated = True  # A timeout may still have moved the file.
                result = run_json([str(AIRTRAFFIC_HOST), udid, link_id, link, target_id, recovered], timeout=120)
                if result.get("exitCode") == 5 and result.get("missingIdentifiers") == [target_id]:
                    # The repo's helper validates the full manifest before moving anything.
                    missing = True
                    raise FileNotFoundError(f"找不到 {leaf} 檔案")
                if result.get("exitCode") != 0 or not result.get("ok"):
                    raise RuntimeError(f"AirTraffic 無法擷取 {leaf}")
                dispatched = (
                    result.get("fileCompleteMessages") == 2
                    and result.get("syncAllowed") is True
                    and result.get("readyForSync") is True
                )
                result = native("extract", udid, recovered, leaf, output_path)
                if not operation_ok(result):
                    # Optional SQLite sidecars often do not exist. The manifest
                    # can still advertise their requested IDs. Match typed AFC
                    # absence only after a successful two-asset dispatch; main
                    # DB failures and incomplete/failed transports remain errors.
                    if leaf in WALLET_DB_SIDECARS and dispatched and _confirmed_missing_recovery_file(result):
                        missing = True
                        missing_after_dispatch = True
                        raise FileNotFoundError(f"找不到可選附屬檔 {leaf}")
                    detail = result.get("operation", {})
                    raise RuntimeError(
                        f"無法讀取復原檔案 {leaf}：{detail.get('reason', '輔助工具讀取失敗')} "
                        f"（AFC={detail.get('afcStatus', '未知')}，原因={detail.get('reasonCode', '未知')}）"
                    )
                extracted = Path(output_path).read_bytes()
            except Exception as error:
                extraction_error = error
                raise
            finally:
                if cleanup_authorized:
                    try:
                        if relocated and not missing and extracted is None:
                            # Attempt recovery even if AirTraffic timed out after moving.
                            result = native("extract", udid, recovered, leaf, output_path)
                            if operation_ok(result):
                                extracted = Path(output_path).read_bytes()
                        # Restore Books and remove staging, but keep the recovered original.
                        finish = native("finish-extract", udid, source, link, recovered, str(snapshot))
                        if not operation_ok(finish):
                            raise ExtractionRestoreError(f"擷取後清理失敗，請保留 Media/{recovered}")
                        if missing_after_dispatch:
                            cleanup = finish.get("operation", {})
                            if cleanup.get("recoveredAbsent") is not True or cleanup.get("recoveredStatStatus") != 8:
                                raise ExtractionRestoreError(
                                    f"附屬檔狀態在檢查後改變或無法確認；請保留 Media/{recovered}"
                                )
                        if relocated and not missing:
                            detail = f"；原始錯誤：{extraction_error}" if extraction_error else ""
                            if extracted is None:
                                raise ExtractionRestoreError(
                                    "未取得可還原的原始資料，無法確認原位置檔案狀態；"
                                    "已停止更新，請勿重試或清除先前的復原檔"
                                    f"{detail}"
                                )
                            if not write_file(udid, target, leaf, extracted, retries=1):
                                raise ExtractionRestoreError(f"原始檔還原未確認成功，請保留 Media/{recovered}{detail}")
                        # Books were already restored; do not reapply the older snapshot
                        # after write_file has completed its own staging transaction.
                        finish = None if missing_after_dispatch else native("discard-extracted", udid, recovered)
                        if finish is not None and not operation_ok(finish):
                            raise ExtractionRestoreError("擷取後的最終清理失敗")
                    except Exception as error:
                        raise ExtractionRestoreError(
                            f"擷取還原失敗，請保留 Media/{recovered}：{error}"
                        ) from error
            if not extracted and leaf not in WALLET_DB_SIDECARS:
                raise RuntimeError(f"擷取的 {leaf} 為空")
            return extracted
    except ExtractionRestoreError:
        raise
    except (OSError, RuntimeError, subprocess.SubprocessError):
        if raise_errors:
            raise
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
    raise ValueError("顏色格式必須為 #RRGGBB 或 rgb(r, g, b)")


def normalize_primary_account_suffix(value: object) -> str | None:
    """Validate an explicitly requested Wallet card-number suffix."""
    if value is None or value == "NULL":
        return None
    if not isinstance(value, str) or re.fullmatch(r"[0-9]{4}", value) is None:
        raise ValueError(
            "末四碼必須為四位半形數字，或設為 NULL 以隱藏"
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
    # Keep the known Wallet schema gate, but never read or write label_color.
    required = {
        "unique_id",
        "foreground_color",
        "label_color",
        "primary_account_suffix",
    }
    missing = sorted(required.difference(columns))
    if missing:
        raise ValueError(
            "Wallet 資料庫缺少必要欄位："
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
        SELECT foreground_color, primary_account_suffix
        FROM pass
        WHERE unique_id = ?
        """,
        (card_hash,),
    ).fetchmany(2)
    row_count = len(rows)
    if row_count != 1:
        qualifier = "至少 " if row_count == 2 else ""
        raise ValueError(
            "Wallet 資料庫必須恰好符合一張卡片 "
            f"（找到 {qualifier}{row_count} 張）"
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
        "primaryAccountSuffix": row[1],
    }


def inspect_wallet_db_batch_bytes(
    database_bytes: bytes,
    card_hashes: list[str],
) -> list[dict]:
    """Inspect multiple card rows from one local database image."""
    if not card_hashes:
        raise ValueError("至少需要一張 Wallet 卡片")
    for card_hash in card_hashes:
        validate_card_hash(card_hash)
    if not database_bytes or len(database_bytes) > EXTRACT_LIMITS[WALLET_DB_LEAF]:
        raise ValueError("Wallet 資料庫為空或過大")
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
                    "primaryAccountSuffix": row[1],
                })
            return results


def inspect_wallet_db_bytes(database_bytes: bytes, card_hash: str) -> dict:
    """Validate and inspect one card from a local Wallet database."""
    return inspect_wallet_db_batch_bytes(database_bytes, [card_hash])[0]


def _normalize_wallet_db_update(
    card_hash: str,
    foreground_color: str | None,
    primary_account_suffix: str | None | object,
) -> dict:
    validate_card_hash(card_hash)
    updates: dict[str, str | None] = {
        column: normalize_wallet_db_color(value)
        for column, value in {
            "foreground_color": foreground_color,
        }.items()
        if value is not None
    }
    if primary_account_suffix is not WALLET_DB_UNCHANGED:
        updates["primary_account_suffix"] = normalize_primary_account_suffix(
            primary_account_suffix
        )
    if not updates:
        raise ValueError("至少需要一項 Wallet 資料庫變更")
    return updates


def patch_wallet_db_batch(original: bytes, updates: list[dict]) -> dict:
    """Patch all requested cards in one local SQLite transaction."""
    if not updates:
        raise ValueError("至少需要一項 Wallet 資料庫變更")
    if not original or len(original) > EXTRACT_LIMITS[WALLET_DB_LEAF]:
        raise ValueError("Wallet 資料庫為空或過大")

    normalized_updates: list[dict] = []
    seen_hashes: set[str] = set()
    seen_request_indices: set[int] = set()
    allowed_keys = {
        "cardHash",
        "foregroundColor",
        "primaryAccountSuffix",
        "requestIndex",
    }
    for update in updates:
        if not isinstance(update, dict):
            raise ValueError("Wallet 資料庫更新必須為物件")
        unknown_keys = set(update).difference(allowed_keys)
        if unknown_keys:
            raise ValueError(
                "未知的 Wallet 資料庫更新欄位："
                + ", ".join(sorted(unknown_keys))
            )
        card_hash = update.get("cardHash")
        if not isinstance(card_hash, str):
            raise ValueError("Wallet 資料庫更新缺少 cardHash")
        if card_hash in seen_hashes:
            raise ValueError("同一張 Wallet 卡片有重複更新")
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
            raise ValueError("Wallet 資料庫 requestIndex 必須為非負整數")
        if (
            request_index is not None
            and request_index in seen_request_indices
        ):
            raise ValueError("Wallet 資料庫 requestIndex 重複")
        if request_index is not None:
            seen_request_indices.add(request_index)
        normalized_updates.append({
            "cardHash": card_hash,
            "requestIndex": request_index,
            "updates": _normalize_wallet_db_update(
                card_hash,
                update.get("foregroundColor"),
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
                raise ValueError("Wallet 資料庫 journal_mode 必須為 delete")
            if metadata["quickCheck"] != ["ok"]:
                raise ValueError(
                    "Wallet 資料庫在更新前未通過完整性檢查"
                )

            for update in normalized_updates:
                row = _wallet_db_card_row(connection, update["cardHash"])
                cards.append({
                    "cardHash": update["cardHash"],
                    "requestIndex": update["requestIndex"],
                    "originalColors": {
                        "foreground_color": row[0],
                        "primary_account_suffix": row[1],
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
                            "每張 Wallet 卡片必須恰好更新一筆資料"
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
                    "Wallet 資料庫在更新後未通過完整性檢查"
                )
            for card in cards:
                row = _wallet_db_card_row(connection, card["cardHash"])
                applied = {
                    "foreground_color": row[0],
                    "primary_account_suffix": row[1],
                }
                mismatches = [
                    column
                    for column, expected in card["updates"].items()
                    if applied[column] != expected
                ]
                if mismatches:
                    raise ValueError(
                        "Wallet 資料庫欄位未正確儲存："
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
    primary_account_suffix: str | None | object = WALLET_DB_UNCHANGED,
) -> dict:
    """Patch one card through the shared batch transaction."""
    batch = patch_wallet_db_batch(
        original,
        [{
            "cardHash": card_hash,
            "foregroundColor": foreground_color,
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
    for index, leaf in enumerate(WALLET_DB_SIDECARS, start=1):
        _report_wallet_db_progress(phase, index)
        sidecar = _extract_optional_wallet_db_sidecar(
            udid,
            leaf,
            work / leaf,
            phase,
        )
        if sidecar is not None:
            raise RuntimeError(
                f"{phase}-{leaf}: Wallet 資料庫仍有日誌附屬檔，已停止寫入"
            )


def _extract_wallet_db_main_without_sidecars(
    udid: str,
    phase: str = "wallet-db",
) -> bytes:
    """Extract the main DB and fail unless every journal sidecar is absent."""
    _report_wallet_db_progress(phase)
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
            raise RuntimeError(f"{phase}-main: 無法取得 Wallet 資料庫")
        _require_wallet_db_sidecars_absent(udid, work, f"{phase}-after")
        return main


def prepare_wallet_db_patch(
    udid: str,
    card_hash: str,
    foreground_color: str | None = None,
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
    _report_wallet_db_progress(f"{phase}-write")
    if not write_file(
        udid,
        WALLET_DB_TARGET,
        WALLET_DB_LEAF,
        replacement,
        retries=1,
    ):
        raise RuntimeError(f"{phase}-write: 寫入 Wallet 資料庫失敗")
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
                "rollback-compare: 即時資料庫已在嘗試更新後變更；"
                "已拒絕以過期資料還原"
            )
        if readback != original:
            raise RuntimeError(
                "rollback-byte-compare: 原始資料與裝置讀回的資料不符"
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
                    "rollback-quick-check: 還原後的資料庫未通過完整性檢查"
                )
            if inspected["journalMode"] != "delete":
                raise RuntimeError(
                    "rollback-journal-mode: 還原後的資料庫日誌模式已變更"
                )
    except Exception as error:
        raise RuntimeError(
            "嚴重錯誤：無法確認 Wallet 資料庫已還原："
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
                "apply-prewrite-compare: Wallet 資料庫已在"
                "準備完成後變更，已停止寫入"
            )
        write_attempted = True
        readback = _write_wallet_db_and_verify(udid, patched, "apply")
        if readback != patched:
            raise RuntimeError(
                "apply-readback-compare: Wallet 資料庫讀回的資料"
                "不符"
            )
        _report_wallet_db_progress("apply-validate")
        inspected_cards = inspect_wallet_db_batch_bytes(
            readback,
            [card["cardHash"] for card in cards],
        )
        for card, inspected in zip(cards, inspected_cards):
            if inspected["journalMode"] != "delete":
                raise RuntimeError(
                    "apply-journal-mode: Wallet 資料庫日誌模式已變更"
                )
            expected = card["appliedColors"]
            actual = {
                "foreground_color": inspected["foregroundColor"],
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
                    "apply-value-check: Wallet 資料庫欄位未正確儲存："
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
            f"{error}; 已確認 Wallet 資料庫還原成功"
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


def remove_files(udid: str, target: str, leaves: list[str], retries: int = 1) -> bool:
    """Remove cache files with the existing transport and unconditional cleanup."""
    if not leaves:
        return True
    if any(not leaf or "/" in leaf or leaf in {".", ".."} for leaf in leaves):
        raise ValueError("快取名稱必須為單純檔名")
    require_airtraffic_device(udid)
    token = secrets.token_hex(10)
    source, link, recovered = (SOURCE_PREFIX + token, LINK_PREFIX + token, RECOVERED_PREFIX + token)
    link_id = f"../../{source}/p0/p1/p2/link"
    ids = [f"../../{link}/{leaf}" for leaf in leaves]
    with tempfile.TemporaryDirectory(prefix="airlift-remove-") as temporary:
        work = Path(temporary)
        snapshot = work / "books-snapshot"
        snapshot.mkdir()
        archive, books = work / "payload.zip", work / "Books.plist"
        archive.write_bytes(build_archive(target, b"aircard-cache"))
        books.write_bytes(build_books([link_id, *ids]))
        if not operation_ok(native("snapshot-books", udid, str(snapshot))):
            return False
        cleanup_authorized = False
        try:
            stage = native("stage", udid, source, link, recovered,
                           str(archive), str(books), str(snapshot))
            cleanup_authorized = bool(stage.get("operation", {}).get("cleanupAuthorized", operation_ok(stage)))
            if not operation_ok(stage):
                return False
            args = [str(AIRTRAFFIC_HOST), "--remove-cache", udid, link_id, link]
            for i, identifier in enumerate(ids):
                args.extend([identifier, f"{source}/removed-{i}"])
            result = run_json_streaming(args, timeout=120)
        finally:
            if cleanup_authorized:
                finish = native("finish-write", udid, source, link, recovered, str(snapshot))
        return result.get("exitCode") == 0 and bool(result.get("ok")) and operation_ok(finish)


def main():
    if len(sys.argv) < 3:
        print("用法：apply_card_skin.py <udid> <image_path> [card_hash ...]")
        return
    udid = sys.argv[1]
    img_path = Path(sys.argv[2])
    if not img_path.is_file():
        print(f"錯誤：找不到 {img_path}")
        sys.exit(1)
    img_data = img_path.read_bytes()
    hashes = sys.argv[3:]

    print(f"已載入圖片：{len(img_data)} 位元組")
    print(f"即將更新裝置 {udid} 的 {len(hashes)} 張卡片…")

    for index, h in enumerate(hashes, 1):
        target_dir = f"/var/mobile/Library/Passes/Cards/{h}.pkpass"
        print(f"\n[{index}/{len(hashes)}] 正在處理卡片： {h}")

        print("  -> 正在批次寫入卡片外觀…")
        card_assets = [
            ("cardBackgroundCombined@3x.png", img_data),
            ("cardBackgroundCombined@2x.png", img_data),
        ]
        ok_batch = write_files_batch(udid, target_dir, card_assets)
        if not ok_batch:
            ok3x = write_file(udid, target_dir, "cardBackgroundCombined@3x.png", img_data)
            ok2x = write_file(udid, target_dir, "cardBackgroundCombined@2x.png", img_data)
            ok_batch = ok3x and ok2x
        print(f"     結果： {'成功' if ok_batch else '失敗'}")

        print("  -> 正在清除卡片快取…")
        ok_cache = invalidate_cache(udid, h)
        print(f"     結果： {'成功' if ok_cache else '失敗（或快取已清空）'}")

    print("\n已完成！請完全關閉 iPhone 上的錢包 App 後重新開啟。")


if __name__ == "__main__":
    main()
