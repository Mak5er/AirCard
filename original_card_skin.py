#!/usr/bin/env python3
"""Capture and restore each card's original Wallet artwork on this Mac."""

from __future__ import annotations

import hashlib
import os
import tempfile
import zipfile
from pathlib import Path

from apply_card_skin import read_file

ORIGINAL_SKIN_ASSETS = (
    "cardBackgroundCombined@3x.png",
    "cardBackgroundCombined@2x.png",
    "cardBackgroundCombined.pdf",
)


def backup_path(udid: str, card_hash: str) -> Path:
    device_key = hashlib.sha256(udid.encode("utf-8")).hexdigest()
    card_key = hashlib.sha256(card_hash.encode("utf-8")).hexdigest()
    return (
        Path.home()
        / "Library"
        / "Application Support"
        / "AirCard"
        / "OriginalCardSkins"
        / device_key
        / f"{card_key}.zip"
    )


def load_original_skin(udid: str, card_hash: str) -> dict[str, bytes] | None:
    path = backup_path(udid, card_hash)
    if not path.is_file():
        return None
    try:
        with zipfile.ZipFile(path, "r") as archive:
            names = archive.namelist()
            if len(names) != len(ORIGINAL_SKIN_ASSETS) or set(names) != set(ORIGINAL_SKIN_ASSETS):
                return None
            assets = {name: archive.read(name) for name in names}
    except (OSError, zipfile.BadZipFile, RuntimeError):
        return None
    if any(not payload for payload in assets.values()):
        return None
    return assets


def has_original_skin(udid: str, card_hash: str) -> bool:
    return load_original_skin(udid, card_hash) is not None


def capture_original_skin(udid: str, card_hash: str) -> tuple[bool, str | None]:
    path = backup_path(udid, card_hash)
    if path.exists():
        if has_original_skin(udid, card_hash):
            return True, None
        return False, "An existing original-artwork backup is invalid; it was not replaced."

    originals: dict[str, bytes] = {}
    target = f"/var/mobile/Library/Passes/Cards/{card_hash}.pkpass"
    for asset in ORIGINAL_SKIN_ASSETS:
        try:
            payload = read_file(udid, target, asset, retries=2, require_restored=True)
        except (OSError, RuntimeError, ValueError, zipfile.BadZipFile) as error:
            return False, f"Could not back up the original card artwork ({asset}): {error}"
        if not payload:
            return False, f"Could not back up the original card artwork ({asset}); no artwork was changed."
        originals[asset] = payload

    try:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.parent.chmod(0o700)
        fd, temporary_name = tempfile.mkstemp(prefix=".original-skin-", dir=path.parent)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb") as output:
                with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
                    for asset in ORIGINAL_SKIN_ASSETS:
                        archive.writestr(asset, originals[asset])
                output.flush()
                os.fsync(output.fileno())
            os.link(temporary_name, path)
        finally:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass
    except OSError as error:
        return False, f"Could not save the original-artwork backup on this Mac: {error}"

    if not has_original_skin(udid, card_hash):
        return False, "The saved original-artwork backup could not be verified."
    return True, None
