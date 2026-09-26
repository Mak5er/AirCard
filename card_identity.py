"""Display name for a Wallet pass, limited to what is already on the card face.

Full account numbers, barcodes, NFC payloads, and pass update secrets are
never returned. Callers use this to label a scanned pass id.
"""

from __future__ import annotations

import json
import re
from typing import Any

_STYLE_KEYS = (
    "storeCard",
    "generic",
    "coupon",
    "eventTicket",
    "boardingPass",
)
_FACE_GROUPS = ("headerFields", "primaryFields", "secondaryFields", "auxiliaryFields")
_SUFFIX_HINTS = ("suffix", "last4", "last 4", "accountnumber", "account number")
_PAN_RE = re.compile(r"\d(?:[ -]?\d){12,18}")


def parse_pass_json(raw: bytes) -> dict[str, Any] | None:
    if not raw or raw[:1] not in (b"{", b"["):
        return None
    try:
        payload = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def _clean_text(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    text = " ".join(value.split())
    if not text or len(text) > 80:
        return None
    digits = re.sub(r"\D", "", text)
    if len(digits) >= 8 or _PAN_RE.search(text):
        return None
    return text


def _suffix(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    digits = re.sub(r"\D", "", trimmed)
    if len(digits) in (4, 5) and len(trimmed) <= 12:
        return f"•••• {digits}"
    return None


def _field_hint(field: dict[str, Any]) -> str:
    return f"{field.get('key', '')} {field.get('label', '')}".lower()


def identity_from_pass(payload: dict[str, Any]) -> dict[str, str | None]:
    """Return a short title and detail line for the card face."""
    title = (
        _clean_text(payload.get("logoText"))
        or _clean_text(payload.get("organizationName"))
        or _clean_text(payload.get("description"))
    )
    parts: list[str] = []
    for key in ("organizationName", "description", "logoText"):
        text = _clean_text(payload.get(key))
        if text and text != title and text not in parts:
            parts.append(text)

    suffix = None
    for style in _STYLE_KEYS:
        block = payload.get(style)
        if not isinstance(block, dict):
            continue
        for group in _FACE_GROUPS:
            fields = block.get(group)
            if not isinstance(fields, list):
                continue
            for field in fields:
                if not isinstance(field, dict):
                    continue
                hinted = any(hint in _field_hint(field) for hint in _SUFFIX_HINTS)
                if hinted:
                    suffix = suffix or _suffix(field.get("value"))
                    continue
                if group not in ("headerFields", "primaryFields"):
                    continue
                shown = _clean_text(field.get("value"))
                if shown and shown != title and shown not in parts and len(parts) < 3:
                    parts.append(shown)
    if suffix and suffix not in parts:
        parts.append(suffix)
    if title is None and parts:
        title = parts.pop(0)
    detail = " · ".join(parts) if parts else None
    return {"title": title, "detail": detail}


def is_png(data: bytes) -> bool:
    return data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) <= 8 * 1024 * 1024


def is_pdf(data: bytes) -> bool:
    return data.startswith(b"%PDF") and len(data) <= 12 * 1024 * 1024
