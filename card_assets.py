#!/usr/bin/env python3
from __future__ import annotations

import struct
import subprocess
import tempfile
from pathlib import Path
from typing import Final

PNG_ASSET_NAMES: Final = (
    "cardBackgroundCombined@3x.png",
    "cardBackgroundCombined@2x.png",
)
PDF_ASSET_NAME: Final = "cardBackgroundCombined.pdf"
CACHE_FILES: Final = ("FrontFace", "PlaceHolder", "Preview")
PNG_SIGNATURE: Final = b"\x89PNG\r\n\x1a\n"


def build_card_assets(png_bytes: bytes) -> tuple[tuple[str, bytes], ...]:
    with tempfile.TemporaryDirectory(prefix="aircard-assets-") as temporary:
        png_path = Path(temporary) / "card.png"
        pdf_path = Path(temporary) / "card.pdf"
        png_path.write_bytes(png_bytes)
        subprocess.run(
            [
                "/usr/bin/sips",
                "-s",
                "format",
                "pdf",
                str(png_path),
                "--out",
                str(pdf_path),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        pdf_bytes = pdf_path.read_bytes()

    png_assets = tuple((name, png_bytes) for name in PNG_ASSET_NAMES)
    return (*png_assets, (PDF_ASSET_NAME, pdf_bytes))


def is_png(data: bytes) -> bool:
    """True when the payload starts with the PNG signature."""
    return data.startswith(PNG_SIGNATURE)


def png_dimensions(data: bytes) -> "tuple[int, int] | None":
    """Width and height of a PNG payload, or None when it is not a PNG."""
    if len(data) < 24 or not is_png(data) or data[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", data[16:24])
