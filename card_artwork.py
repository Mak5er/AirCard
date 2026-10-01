#!/usr/bin/env python3
"""Card artwork: the remote reference a payment pass keeps.

An SE payment pass does not store its card face. Its bundle holds a reference
file instead::

    Cards/<card-id>.pkpass/cardBackgroundCombined.png.urls

    {"cardBackgroundCombined@2x.png": {"url": "https://.../assets/<id>",
                                       "size": 453184,
                                       "sha1": "0b8274b3..."}}

This module owns that format: parsing it, choosing the best declared asset,
checking the downloaded bytes against the declared size and sha1, and the
download itself. It depends on the standard library only. Device access (reading the manifest, finding cards) stays in
apply_card_skin and aircard_backend, so everything here is unit-testable
without a phone.
"""
from __future__ import annotations

import hashlib
import json
import plistlib
import re
import time
import urllib.error
import urllib.request
from typing import Final
from urllib.parse import urlparse

#: The reference file Wallet writes next to a payment pass bundle.
CARD_ARTWORK_MANIFEST: Final = "cardBackgroundCombined.png.urls"

#: Only Apple's asset service may be contacted, whatever the manifest says.
APPLE_ASSET_HOST_SUFFIX: Final = ".apple.com"

DOWNLOAD_TIMEOUT: Final = 45
DOWNLOAD_LIMIT: Final = 32 * 1024 * 1024

#: Best card face first: a 3x PNG beats a 2x, which beats a PDF.
ASSET_PREFERENCE: Final = (
    "cardBackgroundCombined@3x.png",
    "cardBackgroundCombined@2x.png",
    "cardBackgroundCombined.png",
    "cardBackgroundCombined.pdf",
)

REMOTE_URL_PATTERN: Final = re.compile(rb"https?://[^\s\"'<>\\]+")


def _first_url(value: object, depth: int = 0) -> "str | None":
    if depth > 12:
        return None
    if isinstance(value, str):
        return value if value.startswith(("http://", "https://")) else None
    if isinstance(value, bytes):
        return _first_url(value.decode("utf-8", "replace"), depth + 1)
    if isinstance(value, dict):
        for item in value.values():
            found = _first_url(item, depth + 1)
            if found:
                return found
    if isinstance(value, (list, tuple)):
        for item in value:
            found = _first_url(item, depth + 1)
            if found:
                return found
    return None


def _parse(data: bytes):
    for loader in (json.loads, plistlib.loads):
        try:
            return loader(data)
        except Exception:
            continue
    return None


def manifest_entries(data: bytes) -> dict:
    """Card-artwork assets declared by a `<asset>.urls` manifest.

    Returns ``{asset name: {"url": str, "size": int | None, "sha1": str | None}}``.
    A manifest that does not use the documented shape still yields an entry when
    it contains a usable URL, so older or unexpected payloads keep working.
    """
    if not data:
        return {}

    parsed = _parse(data)
    entries: dict = {}
    if isinstance(parsed, dict):
        for name, meta in parsed.items():
            if not isinstance(name, str):
                continue
            if isinstance(meta, dict) and isinstance(meta.get("url"), str):
                size = meta.get("size")
                sha1 = meta.get("sha1")
                entries[name] = {
                    "url": meta["url"],
                    "size": size if isinstance(size, int) else None,
                    "sha1": sha1 if isinstance(sha1, str) else None,
                }
            elif isinstance(meta, str) and meta.startswith(("http://", "https://")):
                entries[name] = {"url": meta, "size": None, "sha1": None}
    if entries:
        return entries

    url = manifest_url(data)
    return {CARD_ARTWORK_MANIFEST: {"url": url, "size": None, "sha1": None}} if url else {}


def manifest_url(data: bytes) -> "str | None":
    """The first usable URL in a manifest, whatever shape it uses."""
    if not data:
        return None
    parsed = _parse(data)
    found = _first_url(parsed) if parsed is not None else None
    if found:
        return found
    match = REMOTE_URL_PATTERN.search(data)
    return match.group(0).decode("utf-8", "replace") if match else None


def ordered_assets(entries: dict) -> list:
    """Declared assets, best card face first, then everything else."""
    preferred = [name for name in ASSET_PREFERENCE if name in entries]
    return preferred + sorted(name for name in entries if name not in preferred)


#: Magic bytes of the formats Apple's asset service is known to return.
KNOWN_SIGNATURES: Final = (
    (b"\x89PNG\r\n\x1a\n", ".png"),
    (b"%PDF", ".pdf"),
    (b"\xff\xd8\xff", ".jpg"),
    (b"GIF8", ".gif"),
)


def detect_asset_format(data: bytes) -> "str | None":
    """Extension for the bytes Apple actually served, or None if unrecognised.

    Nothing is re-encoded: the payload is saved exactly as it arrives, so this
    only names the format. A payload that is not one of the known image types
    (an error page, for instance) is rejected instead of being saved as .png.
    """
    for signature, extension in KNOWN_SIGNATURES:
        if data.startswith(signature):
            return extension
    return None


def verify_declared(data: bytes, size, sha1) -> list:
    """Mismatches between downloaded bytes and what the manifest declared."""
    problems = []
    if isinstance(size, int) and len(data) != size:
        problems.append(f"size {len(data)} != declared {size}")
    if isinstance(sha1, str) and sha1:
        actual = hashlib.sha1(data).hexdigest()
        if actual != sha1:
            problems.append(f"sha1 {actual[:12]}... != declared {sha1[:12]}...")
    return problems


def declared_checks(size, sha1) -> bool:
    """True when the manifest declared enough to verify a download at all."""
    return isinstance(size, int) or bool(sha1)


def download_asset(url: str, retries: int = 2) -> bytes:
    """Fetch one declared asset, retrying transient failures only."""
    parsed = urlparse(url)
    if parsed.scheme != "https" or not (parsed.hostname or "").endswith(APPLE_ASSET_HOST_SUFFIX):
        raise ValueError("Refused a card artwork URL outside Apple's asset service")

    last_error = None
    for attempt in range(1, max(1, retries) + 1):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "AirCard"})
            with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT) as response:
                data = response.read(DOWNLOAD_LIMIT + 1)
            if len(data) > DOWNLOAD_LIMIT:
                raise ValueError("Card artwork response was too large")
            return data
        except urllib.error.HTTPError as error:
            last_error = error
            # A 4xx will not improve on retry; 5xx and timeouts might.
            if 400 <= error.code < 500:
                raise
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last_error = error
        if attempt < retries:
            time.sleep(1.0 * attempt)
    raise last_error if last_error else ValueError("Card artwork download failed")
