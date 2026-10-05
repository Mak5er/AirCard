#!/usr/bin/env python3
"""
Backend engine for AirCard native macOS GUI app.
"""
from __future__ import annotations

import base64
import io
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from urllib.parse import urlparse

# SIGTERM requests cancellation without interrupting manifest restoration.
_artwork_cancel_requested = False


def _request_artwork_cancel(signum, frame):
    global _artwork_cancel_requested
    _artwork_cancel_requested = True


def _artwork_cancelled_result():
    return {"ok": False, "cancelled": True, "error": "Card artwork download cancelled."}

# Augment PATH so bundled tools and system tools are always found
script_dir = Path(__file__).resolve().parent
bundled_bin = script_dir / "bin"
bundled_lib = script_dir / "lib"
app_bin = Path("/Applications/AirCard.app/Contents/Resources/bin")
app_lib = Path("/Applications/AirCard.app/Contents/Resources/lib")

paths_to_add = [
    str(bundled_bin),
    str(app_bin),
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin"
]
for p in reversed(paths_to_add):
    if os.path.isdir(p) and p not in os.environ.get("PATH", ""):
        os.environ["PATH"] = f"{p}:{os.environ.get('PATH', '')}"

lib_paths = [str(bundled_lib), str(app_lib)]
for lp in lib_paths:
    if os.path.isdir(lp):
        cur_dyld = os.environ.get("DYLD_LIBRARY_PATH", "")
        os.environ["DYLD_LIBRARY_PATH"] = f"{lp}:{cur_dyld}" if cur_dyld else lp

from apply_card_skin import (
    file_service_available,
    read_files_batch,
    native,
    operation_ok,
    read_file,
    release_stat_link,
    stat_paths,
    write_file,
    write_files_batch,
    remove_files,
    build_archive_multi,
    ROOT,
    DEVICE_HELPER,
)
from card_assets import CACHE_FILES, build_card_assets
from card_assets import png_dimensions
from card_artwork import (
    detect_asset_format,
    CARD_ARTWORK_MANIFEST,
    declared_checks,
    download_asset,
    manifest_entries,
    ordered_assets,
    verify_declared,
)
from aircard import (
    find_device_helper,
    get_connected_device,
    get_all_connected_devices,
    load_saved_cards,
    save_cards,
)


#: Where Wallet keeps one ".pkpass" bundle per verified card.
CARDS_ROOT = "/var/mobile/Library/Passes/Cards"


def cmd_device(target_udid: str | None = None):
    if not find_device_helper():
        print(json.dumps({"connected": False, "error": "device_helper_missing"}))
        return
    device = get_connected_device(target_udid)
    if not device:
        print(json.dumps({"connected": False, "error": "no_device"}))
        return
    if device.get("product"):
        try:
            probe = native("probe", device["udid"])
            device["airlift_compatible"] = operation_ok(probe)
        except Exception:
            device["airlift_compatible"] = False
    else:
        device["airlift_compatible"] = False
    device["connected"] = True
    print(json.dumps(device))


def cmd_devices(target_udid: str | None = None):
    if not find_device_helper():
        print(json.dumps({"connected": False, "error": "device_helper_missing", "devices": []}))
        return
    devices = get_all_connected_devices()
    if not devices:
        print(json.dumps({"connected": False, "error": "no_device", "devices": []}))
        return

    active_device = None
    if target_udid:
        for d in devices:
            if d["udid"] == target_udid:
                active_device = dict(d)
                break
    if not active_device:
        paired = [d for d in devices if d.get("product")]
        active_device = dict(paired[0] if paired else devices[0])

    if active_device.get("product"):
        try:
            probe = native("probe", active_device["udid"])
            active_device["airlift_compatible"] = operation_ok(probe)
        except Exception:
            active_device["airlift_compatible"] = False
    else:
        active_device["airlift_compatible"] = False
    active_device["connected"] = True

    for d in devices:
        if d["udid"] == active_device["udid"]:
            d["airlift_compatible"] = active_device.get("airlift_compatible")

    print(json.dumps({
        "connected": True,
        "devices": devices,
        "selected_udid": active_device["udid"],
        "device": active_device,
    }))


def cmd_get_saved_cards():
    cards = load_saved_cards()
    print(json.dumps({"ok": True, "cards": cards}))


def cmd_save_cards(cards_json: str):
    try:
        cards = json.loads(cards_json)
        if isinstance(cards, list):
            save_cards(cards)
            print(json.dumps({"ok": True}))
            return
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return
    print(json.dumps({"ok": False, "error": "Invalid format"}))


def cmd_prepare_image(src: str, dst: str):
    path = Path(src).expanduser()
    if not path.is_file():
        print(json.dumps({"ok": False, "error": f"File not found: {src}"}))
        return
    try:
        from PIL import Image, ImageOps
        with Image.open(path) as img:
            img = img.convert("RGBA")
            target_size = (1536, 969)
            fitted = ImageOps.fit(img, target_size, method=Image.Resampling.LANCZOS)
            fitted.save(dst, format="PNG")
        print(json.dumps({"ok": True, "path": dst}))
        return
    except ImportError:
        pass
    except Exception as e:
        pass
    
    # Fallback to macOS built-in sips tool (built into every macOS, 0 dependencies!)
    try:
        import subprocess
        subprocess.check_call([
            "/usr/bin/sips",
            "-s", "format", "png",
            "-z", "969", "1536",
            str(path),
            "--out", str(dst)
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(json.dumps({"ok": True, "path": dst}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


def cmd_flash(udid: str, card_hash: str, image_path: str) -> bool:
    img_path = Path(image_path)
    if not img_path.is_file():
        print(json.dumps({"ok": False, "error": "Image file not found"}))
        return False

    try:
        asset_payloads = build_card_assets(img_path.read_bytes())
    except (OSError, subprocess.SubprocessError):
        print(json.dumps({
            "type": "error",
            "card": card_hash,
            "message": "Failed to prepare card artwork"
        }))
        sys.stdout.flush()
        return False

    pkpass_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}.pkpass"

    # One step per artwork file, then one step for each rendered-cache directory.
    num_assets = len(asset_payloads)
    total_steps = num_assets + 2
    all_ok = True

    def on_asset_progress(event: dict) -> None:
        index = event.get("index", 0)
        leaf = event.get("leaf", "")
        current = min(max(int(index), 0), num_assets)
        print(json.dumps({
            "type": "progress",
            "card": card_hash,
            "step": current,
            "total": total_steps,
            "leaf": leaf,
            "message": f"Writing {leaf} ({current}/{total_steps})...",
        }))
        sys.stdout.flush()

    print(json.dumps({
        "type": "progress",
        "card": card_hash,
        "step": 0,
        "total": total_steps,
        "message": f"Writing {num_assets} artwork files (fast batch)..."
    }))
    sys.stdout.flush()

    try:
        ok = write_files_batch(
            udid,
            pkpass_dir,
            asset_payloads,
            progress_callback=on_asset_progress,
        )
    except (OSError, RuntimeError, subprocess.SubprocessError):
        ok = False

    if not ok:
        for file_index, (asset, payload) in enumerate(asset_payloads, 1):
            print(json.dumps({
                "type": "progress",
                "card": card_hash,
                "step": file_index,
                "total": total_steps,
                "leaf": asset,
                "message": f"[Fallback] Writing {asset} ({file_index}/{total_steps})...",
            }))
            sys.stdout.flush()
            try:
                ok_single = write_file(udid, pkpass_dir, asset, payload)
            except Exception:
                ok_single = False
            if not ok_single:
                all_ok = False

    # Wallet only rebuilds a face after the old cache entry is gone.
    for cache_offset, ext in enumerate((".cache", ".pkcache"), start=1):
        cache_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}{ext}"
        step = num_assets + cache_offset
        print(json.dumps({
            "type": "progress",
            "card": card_hash,
            "step": step,
            "total": total_steps,
            "message": f"Invalidating cache ({ext})..."
        }))
        sys.stdout.flush()
        try:
            ok_cache = remove_files(udid, cache_dir, list(CACHE_FILES))
        except Exception:
            ok_cache = False
        if not ok_cache:
            all_ok = False
            print(json.dumps({
                "type": "error",
                "card": card_hash,
                "step": step,
                "total": total_steps,
                "message": f"Could not clear Wallet cache ({ext}); card was not reported as updated."
            }))
            sys.stdout.flush()

    if not all_ok:
        print(json.dumps({
            "type": "error",
            "card": card_hash,
            "step": total_steps,
            "total": total_steps,
            "message": f"Failed to update {card_hash[:12]}..."
        }))
        sys.stdout.flush()
        return False

    print(json.dumps({
        "type": "success",
        "card": card_hash,
        "step": total_steps,
        "total": total_steps,
        "message": f"Successfully updated {card_hash[:12]}..."
    }))
    sys.stdout.flush()
    return True


def cmd_release_artwork_link(udid: str) -> bool:
    """Remove the kept read-only symlink from the phone's Media folder."""
    try:
        release_stat_link(udid, CARDS_ROOT)
    except (OSError, RuntimeError, subprocess.SubprocessError):
        print(json.dumps({"ok": False, "error": "Could not remove the lookup link"}))
        return False
    print(json.dumps({"ok": True}))
    return True


def cmd_probe_card_artwork(udid: str, card_ids: list) -> bool:
    """Report which cards expose a remote card-artwork manifest.

    Only these cards can download their original card artwork, so the GUI shows the
    download button for them alone. Stats a fixed, per-ID allowlist through a
    relocated symlink; no Wallet file is opened, moved or rewritten.
    """
    wanted = [
        card for card in card_ids
        if re.fullmatch(r"[-A-Za-z0-9_+=]{20,64}", card)
    ]
    if not wanted:
        print(json.dumps({"ok": True, "available": [], "checked": 0}))
        return True

    names = [f"{card}.pkpass/{CARD_ARTWORK_MANIFEST}" for card in wanted]
    try:
        results = stat_paths(udid, CARDS_ROOT, names, retries=3)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError):
        results = {}

    if not results:
        # The device lookup itself failed. Reporting an empty list here would
        # silently hide every download button, so callers treat it as an error.
        if not file_service_available(udid):
            message = ("The iPhone's file service is unavailable, which usually means "
                       "it is locked. Unlock it, keep the screen on, and try again.")
        else:
            message = "Could not read card artwork state from the iPhone. Reconnect and try again."
        print(json.dumps({
            "ok": False,
            "error": message,
            "checked": len(wanted),
            "resolved": 0,
        }))
        return False

    def _eligible(name: str) -> bool:
        entry = results.get(name) or {}
        if entry.get("present"):
            return True
        # AFC status 10 is a sandbox denial: the manifest cannot be ruled out,
        # and the download path reads it through AirTraffic instead of AFC.
        return entry.get("afcStatus") == 10

    available = [card for card, name in zip(wanted, names) if _eligible(name)]
    print(json.dumps({
        "ok": True,
        "available": available,
        "checked": len(wanted),
        "resolved": len(results),
    }))
    return True


def resolve_card_artwork(manifest: bytes) -> dict:
    """Pick the best declared asset, download it and check it against the manifest.

    Returns {"ok": True, image, asset, host, verified, problems, attempted,
    width, height} or {"ok": False, error, attempted}. Shared by the single-card
    and the batch download so both behave identically.
    """
    entries = manifest_entries(manifest)
    if not entries:
        return {"ok": False,
                "error": "The card's artwork manifest did not contain a usable URL.",
                "attempted": []}

    # Try the declared assets best-first: a failing @3x must not stop @2x, and a
    # download whose bytes contradict the manifest is retried on the next asset.
    attempts = []
    unverified = None
    image = None
    asset = None
    declared = None
    problems = []
    host = ""
    for name in ordered_assets(entries):
        if _artwork_cancel_requested:
            return _artwork_cancelled_result()
        meta = entries.get(name) or {}
        url = meta.get("url")
        if not url:
            continue
        try:
            candidate = download_asset(url)
        except urllib.error.HTTPError as error:
            attempts.append(f"{name}: HTTP {error.code}")
            continue
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as error:
            attempts.append(f"{name}: {error}")
            continue

        if _artwork_cancel_requested:
            return _artwork_cancelled_result()
        if not detect_asset_format(candidate):
            attempts.append(f"{name}: not a usable image (PNG, PDF, JPEG or GIF expected)")
            continue
        found = verify_declared(candidate, meta.get("size"), meta.get("sha1"))
        if found:
            attempts.append(f"{name}: {'; '.join(found)}")
            if unverified is None:
                unverified = (name, candidate, meta, found, urlparse(url).hostname or "")
            continue
        image, asset, declared, problems = candidate, name, meta, []
        host = urlparse(url).hostname or ""
        break

    if image is None and unverified is not None:
        # Nothing matched its declaration; keep the bytes but say so.
        asset, image, declared, problems, host = unverified

    if image is None:
        return {"ok": False,
                "error": "Could not download the card artwork: " + ("; ".join(attempts) or "no usable URL"),
                "attempted": attempts}

    extension = detect_asset_format(image)
    if not extension:
        return {"ok": False,
                "error": ("Apple's asset service did not return a usable image "
                          "(PNG, PDF, JPEG or GIF expected)."),
                "asset": asset, "attempted": attempts}

    size = png_dimensions(image)  # None for anything that is not a PNG
    declared_any = declared_checks(declared.get("size"), declared.get("sha1"))
    return {
        "ok": True,
        # Exactly the bytes Apple served: no format conversion on the way out.
        "data": image,
        "asset": asset,
        "extension": extension,
        "host": host,
        # "verified" only claims something when the manifest declared size/sha1.
        "verified": bool(declared_any and not problems),
        "problems": problems,
        "attempted": attempts,
        "width": size[0] if size else None,
        "height": size[1] if size else None,
    }


def _valid_card_hash(card_hash: str) -> bool:
    return bool(re.fullmatch(r"[-A-Za-z0-9_+=]{20,64}", card_hash))


def _artwork_export_result(resolved: dict, path: Path) -> dict:
    return {
        "ok": True,
        "source": f"remote/{resolved['host']}",
        "asset": resolved["asset"],
        "extension": resolved["extension"],
        "verified": resolved["verified"],
        "problems": resolved["problems"],
        "attempted": resolved["attempted"],
        "bytes": len(resolved["data"]),
        "width": resolved["width"],
        "height": resolved["height"],
        "path": str(path),
    }


def cmd_fetch_card_artwork(udid: str, card_hash: str, output_path: str) -> bool:
    """Download the original card face named by the card's remote asset manifest."""
    if not _valid_card_hash(card_hash):
        print(json.dumps({"ok": False, "error": "Invalid card ID"}))
        return False

    destination = Path(output_path).expanduser()
    if not destination.parent.is_dir():
        print(json.dumps({"ok": False, "error": "Export folder does not exist"}))
        return False

    try:
        # read_files_batch writes every manifest back in the same cycle, so one
        # card costs one device round trip and the pass cannot lose the file.
        manifests = read_files_batch(udid, CARDS_ROOT,
                                     [f"{card_hash}.pkpass/{CARD_ARTWORK_MANIFEST}"], retries=2)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError):
        manifests = {}
    manifest = manifests.get(f"{card_hash}.pkpass/{CARD_ARTWORK_MANIFEST}")

    if _artwork_cancel_requested:
        print(json.dumps(_artwork_cancelled_result()))
        return False

    if not manifest:
        if not file_service_available(udid):
            print(json.dumps({
                "ok": False,
                "error": ("The iPhone's file service is unavailable, so the pass "
                          "cannot be read. Unlock the iPhone, keep the screen on, "
                          "and try again."),
            }))
        else:
            print(json.dumps({
                "ok": False,
                "error": ("This card has no remote card artwork on the iPhone. "
                          "Open it once in Wallet (Apple Pay) and try again."),
            }))
        return False

    resolved = resolve_card_artwork(manifest)
    if _artwork_cancel_requested:
        print(json.dumps(_artwork_cancelled_result()))
        return False
    if not resolved["ok"]:
        print(json.dumps({"ok": False, "error": resolved["error"],
                          "attempted": resolved.get("attempted", [])}))
        return False

    try:
        destination.write_bytes(resolved["data"])
    except OSError as error:
        print(json.dumps({"ok": False, "error": f"Could not save image: {error}"}))
        return False

    print(json.dumps(_artwork_export_result(resolved, destination)))
    return True


def cmd_fetch_card_artworks(udid: str, output_directory: str, card_hashes: list) -> bool:
    """Download the original artwork of several cards in one device round trip.

    All manifests are read in a single move cycle, then each cover is fetched and
    verified by the same code path the single-card command uses. One failing card
    never stops the others.
    """
    if not card_hashes or not all(_valid_card_hash(card) for card in card_hashes):
        print(json.dumps({"ok": False, "error": "Invalid card ID"}))
        return False
    cards = card_hashes

    directory = Path(output_directory).expanduser()
    if not directory.is_dir():
        print(json.dumps({"ok": False, "error": "Export folder does not exist"}))
        return False

    leaves = [f"{card}.pkpass/{CARD_ARTWORK_MANIFEST}" for card in cards]
    try:
        manifests = read_files_batch(udid, CARDS_ROOT, leaves, retries=2)
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError):
        manifests = {}

    if not _artwork_cancel_requested and not manifests and not file_service_available(udid):
        print(json.dumps({
            "ok": False,
            "error": ("The iPhone's file service is unavailable, so the passes cannot be "
                      "read. Unlock the iPhone, keep the screen on, and try again."),
        }))
        return False

    results = []
    saved = 0
    for card in cards:
        entry = {"card": card}
        if _artwork_cancel_requested:
            entry.update(_artwork_cancelled_result())
            results.append(entry)
            continue
        manifest = manifests.get(f"{card}.pkpass/{CARD_ARTWORK_MANIFEST}")
        if not manifest:
            entry.update({"ok": False,
                          "error": ("No readable artwork manifest for this card. Open it "
                                    "once in Wallet (Apple Pay) and try again.")})
            results.append(entry)
            continue

        resolved = resolve_card_artwork(manifest)
        if _artwork_cancel_requested:
            entry.update(_artwork_cancelled_result())
            results.append(entry)
            continue
        if not resolved["ok"]:
            entry.update({"ok": False, "error": resolved["error"],
                          "attempted": resolved.get("attempted", [])})
            results.append(entry)
            continue

        path = directory / f"AirCard-{card[:12]}{resolved['extension']}"
        try:
            path.write_bytes(resolved["data"])
        except OSError as error:
            entry.update({"ok": False, "error": f"Could not save image: {error}"})
            results.append(entry)
            continue

        saved += 1
        entry.update(_artwork_export_result(resolved, path))
        results.append(entry)

    print(json.dumps({
        "ok": saved > 0,
        "cancelled": _artwork_cancel_requested,
        "saved": saved,
        "failed": len(cards) - saved,
        "checked": len(cards),
        "results": results,
        "error": "" if saved else "No card artwork could be downloaded.",
    }))
    return saved > 0


KEYPAD_SUBTEXTS = {
    "0": "+",
    "1": "",
    "2": "A B C",
    "3": "D E F",
    "4": "G H I",
    "5": "J K L",
    "6": "M N O",
    "7": "P Q R S",
    "8": "T U V",
    "9": "W X Y Z",
}

# Cyrillic keypad subtexts for Russian & Ukrainian locales
CYRILLIC_SUBTEXTS_RU = {
    "2": "А Б В Г",
    "3": "Д Е Ж З",
    "4": "И Й К Л",
    "5": "М Н О П",
    "6": "Р С Т У",
    "7": "Ф Х Ц Ч",
    "8": "Ш Щ Ъ Ы",
    "9": "Ь Э Ю Я",
}

CYRILLIC_SUBTEXTS_UK = {
    "2": "А Б В Г",
    "3": "Д Е Ж З",
    "4": "І Ї Й К",
    "5": "Л М Н О",
    "6": "П Р С Т",
    "7": "У Ф Х Ц",
    "8": "Ч Ш Щ Ь",
    "9": "Ю Я",
}


# System locales supported for TelephonyUI passcode keypad caches
KEYPAD_LOCALES = [
    "en", "other", "ru", "uk", "es", "fr", "de", "it", "pt", "tr", "pl", "nl", "ja", "ko", "zh", "ar", "he"
]


def parse_passthm_archive(
    passthm_path: str,
    telephony_ver: str = "TelephonyUI-10",
    target_lang: str = "all",
    target_bold: str = "both"
) -> list[tuple[str, str, bytes]]:
    path = Path(passthm_path).expanduser()
    if not path.is_file():
        raise FileNotFoundError(f"Passcode theme file not found: {passthm_path}")

    with zipfile.ZipFile(path, "r") as z:
        image_entries = [
            n for n in z.namelist()
            if not n.startswith("__MACOSX")
            and not n.endswith("/")
            and not Path(n).name.startswith(".")
            and any(n.lower().endswith(ext) for ext in (".png", ".jpg", ".jpeg"))
        ]
        if not image_entries:
            return []

        # Support universal (TelephonyUI-8 + 9 + 10) or specific folder
        norm_ver = (telephony_ver or "TelephonyUI-10").strip()
        if norm_ver.lower() in ("all", "universal"):
            target_dirs = [
                "/var/mobile/Library/Caches/TelephonyUI-10",
                "/var/mobile/Library/Caches/TelephonyUI-9",
                "/var/mobile/Library/Caches/TelephonyUI-8",
            ]
        else:
            target_dirs = [f"/var/mobile/Library/Caches/{norm_ver}"]

        items_dict: dict[str, bytes] = {}

        # Normalize target_lang & target_bold
        target_lang = (target_lang or "all").lower().strip()
        target_bold = (target_bold or "both").lower().strip()

        for entry in image_entries:
            leaf = Path(entry).name
            data = z.read(entry)

            stem = Path(leaf).stem
            stem_clean = re.sub(r"--?white(?:-bold)?$", "", stem, flags=re.IGNORECASE)
            m = re.search(r"^(?:([a-zA-Z]+)-)?([0-9*#])(?:-([^-\n]+))?", stem_clean)
            digit = None
            subtext = ""
            orig_lang = None
            if m:
                orig_lang = m.group(1)
                digit = m.group(2)
                if m.group(3):
                    subtext = m.group(3).strip()
            if not digit:
                m2 = re.search(r"([0-9*#])", leaf)
                if m2:
                    digit = m2.group(1)

            # Strip non-subtext keywords from subtext
            if subtext and subtext.lower() in ("bold", "regular", "white", "black", "light", "dark", "normal"):
                subtext = ""

            # If user requested universal (all + both), keep raw leaf
            if target_lang == "all" and target_bold == "both":
                items_dict[leaf] = data

            if digit:
                if target_lang == "all":
                    langs = list(KEYPAD_LOCALES)
                    if orig_lang and orig_lang.lower() not in langs:
                        langs.insert(0, orig_lang.lower())
                else:
                    # Put target_lang FIRST, other SECOND
                    langs = [target_lang]
                    if target_lang != "other":
                        langs.append("other")

                if target_bold == "bold":
                    bold_suffixes = ["-bold"]
                elif target_bold == "regular":
                    bold_suffixes = [""]
                else:
                    bold_suffixes = ["", "-bold"]

                std_subtext = KEYPAD_SUBTEXTS.get(digit)

                for lang in langs:
                    for bold_suffix in bold_suffixes:
                        # 1. Blank subtext variant (e.g. ru-5---white-bold.png)
                        items_dict[f"{lang}-{digit}---white{bold_suffix}.png"] = data

                        # 2. Standard Latin subtext (e.g. ru-5-J K L--white-bold.png)
                        if std_subtext:
                            items_dict[f"{lang}-{digit}-{std_subtext}--white{bold_suffix}.png"] = data
                            if " " in std_subtext:
                                items_dict[f"{lang}-{digit}-{std_subtext.replace(' ', '')}--white{bold_suffix}.png"] = data

                        # 3. Cyrillic subtexts for Russian & Ukrainian
                        if lang in ("ru", "all") and digit in CYRILLIC_SUBTEXTS_RU:
                            cyr_ru = CYRILLIC_SUBTEXTS_RU[digit]
                            items_dict[f"{lang}-{digit}-{cyr_ru}--white{bold_suffix}.png"] = data
                        if lang in ("uk", "all") and digit in CYRILLIC_SUBTEXTS_UK:
                            cyr_uk = CYRILLIC_SUBTEXTS_UK[digit]
                            items_dict[f"{lang}-{digit}-{cyr_uk}--white{bold_suffix}.png"] = data

                        # 4. Custom subtext variant if present in the source asset
                        if subtext:
                            items_dict[f"{lang}-{digit}-{subtext}--white{bold_suffix}.png"] = data

        res = []
        for tdir in target_dirs:
            for leaf, data in items_dict.items():
                res.append((tdir, leaf, data))
        return res


def cmd_inspect_passthm(passthm_path: str):
    path = Path(passthm_path).expanduser()
    if not path.is_file():
        print(json.dumps({"ok": False, "error": f"File not found: {passthm_path}"}))
        return
    try:
        detected_ver = "TelephonyUI-10"
        with zipfile.ZipFile(path, "r") as z:
            for entry in z.namelist():
                low = entry.lower()
                if "telephonyui-8" in low or "telephony-8" in low:
                    detected_ver = "TelephonyUI-8"
                    break
                elif "telephonyui-9" in low or "telephony-9" in low:
                    detected_ver = "TelephonyUI-9"
                    break

        items = parse_passthm_archive(str(path), detected_ver)
        if not items:
            print(json.dumps({"ok": False, "error": "No image assets found in archive"}))
            return

        keys_preview = {}
        for _, leaf, data in items:
            m = re.search(r'^[a-zA-Z]+-([0-9*#])-?', leaf)
            digit = m.group(1) if m else None
            if not digit:
                m2 = re.search(r'([0-9*#])', leaf)
                if m2:
                    digit = m2.group(1)
            if digit and digit not in keys_preview:
                b64 = base64.b64encode(data).decode("utf-8")
                mime = "image/png" if leaf.lower().endswith(".png") else "image/jpeg"
                keys_preview[digit] = f"data:{mime};base64,{b64}"

        print(json.dumps({
            "ok": True,
            "name": path.stem,
            "detected_version": detected_ver,
            "file_count": len(items),
            "keys_preview": keys_preview
        }))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


def cmd_flash_passthm(
    udid: str,
    passthm_path: str,
    telephony_ver: str = "TelephonyUI-10",
    target_lang: str = "all",
    target_bold: str = "both"
) -> bool:
    path = Path(passthm_path).expanduser()
    if not path.is_file():
        print(json.dumps({"ok": False, "error": "Passcode theme file not found"}))
        return False

    try:
        items_to_write = parse_passthm_archive(str(path), telephony_ver, target_lang, target_bold)
        if not items_to_write:
            print(json.dumps({"ok": False, "error": "No image assets found in archive"}))
            return False

        # Group items by target directory (e.g. /var/mobile/Library/Caches/TelephonyUI-10)
        items_by_dir: dict[str, list[tuple[str, bytes]]] = {}
        for tdir, leaf, payload in items_to_write:
            items_by_dir.setdefault(tdir, []).append((leaf, payload))

        # Check for marker files like _big or _small in the theme package
        try:
            with zipfile.ZipFile(path, "r") as z:
                for entry in z.namelist():
                    leaf_name = Path(entry).name
                    if leaf_name in ("_big", "_small") and not entry.endswith("/"):
                        marker_data = z.read(entry)
                        for tdir in items_by_dir:
                            if not any(leaf == leaf_name for leaf, _ in items_by_dir[tdir]):
                                items_by_dir[tdir].append((leaf_name, marker_data))
        except Exception:
            pass

        total_steps = sum(len(f) for f in items_by_dir.values())
        processed_files = 0

        print(json.dumps({
            "type": "progress",
            "step": 0,
            "total": total_steps,
            "message": f"Flashing passcode theme '{path.stem}' ({total_steps} assets)..."
        }))
        sys.stdout.flush()

        for tdir, dir_files in items_by_dir.items():
            tdir_name = Path(tdir).name
            base_step = processed_files

            def make_progress_handler(base: int):
                def on_atc_progress(p: dict):
                    idx = p.get("index", 0)
                    leaf = p.get("leaf", "")
                    curr = min(base + idx, total_steps)
                    print(json.dumps({
                        "type": "progress",
                        "step": curr,
                        "total": total_steps,
                        "leaf": leaf,
                        "message": f"Writing {leaf} ({curr}/{total_steps})..."
                    }))
                    sys.stdout.flush()
                return on_atc_progress

            print(json.dumps({
                "type": "progress",
                "step": base_step,
                "total": total_steps,
                "message": f"Flashing {len(dir_files)} asset(s) into {tdir_name}..."
            }))
            sys.stdout.flush()

            ok = write_files_batch(
                udid,
                tdir,
                dir_files,
                retries=3,
                progress_callback=make_progress_handler(base_step),
            )

            if not ok:
                # If batch failed, fallback to file-by-file write for this directory
                print(json.dumps({
                    "type": "warning",
                    "message": f"Batch write notice for {tdir_name}, falling back to file-by-file write..."
                }))
                sys.stdout.flush()

                failed_leaves = []
                for f_idx, (leaf, payload) in enumerate(dir_files, 1):
                    curr = base_step + f_idx
                    print(json.dumps({
                        "type": "progress",
                        "step": curr,
                        "total": total_steps,
                        "leaf": leaf,
                        "message": f"[Fallback] Writing {leaf} ({curr}/{total_steps})..."
                    }))
                    sys.stdout.flush()

                    single_ok = write_file(udid, tdir, leaf, payload, retries=3)
                    if not single_ok:
                        failed_leaves.append(leaf)
                    time.sleep(0.08)

                if failed_leaves:
                    print(json.dumps({
                        "type": "error",
                        "message": f"Could not write {len(failed_leaves)} file(s) in {tdir_name}: {', '.join(failed_leaves[:5])}"
                    }))
                    sys.stdout.flush()
                    return False

            processed_files += len(dir_files)

        print(json.dumps({
            "type": "success",
            "step": total_steps,
            "total": total_steps,
            "message": f"Passcode theme '{path.stem}' successfully applied! Lock your iPhone to check."
        }))
        sys.stdout.flush()
        return True

    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return False


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "No command provided"}))
        sys.exit(1)

    cmd = sys.argv[1]
    norm_cmd = cmd.lstrip("-")
    if norm_cmd in ("fetch-card-artwork", "fetch-card-artworks"):
        signal.signal(signal.SIGTERM, _request_artwork_cancel)
    if norm_cmd == "device":
        target = sys.argv[2] if len(sys.argv) > 2 else None
        cmd_device(target)
    elif norm_cmd == "devices":
        target = sys.argv[2] if len(sys.argv) > 2 else None
        cmd_devices(target)
    elif norm_cmd == "cards":
        cmd_get_saved_cards()
    elif norm_cmd == "save-cards" and len(sys.argv) > 2:
        cmd_save_cards(sys.argv[2])
    elif norm_cmd == "prepare-image" and len(sys.argv) > 3:
        cmd_prepare_image(sys.argv[2], sys.argv[3])
    elif norm_cmd == "flash" and len(sys.argv) > 4:
        if not cmd_flash(sys.argv[2], sys.argv[3], sys.argv[4]):
            sys.exit(1)
    elif norm_cmd == "release-artwork-link" and len(sys.argv) > 2:
        if not cmd_release_artwork_link(sys.argv[2]):
            sys.exit(1)
    elif norm_cmd == "probe-card-artwork" and len(sys.argv) > 3:
        if not cmd_probe_card_artwork(sys.argv[2], sys.argv[3:]):
            sys.exit(1)
    elif norm_cmd == "fetch-card-artworks" and len(sys.argv) > 4:
        if not cmd_fetch_card_artworks(sys.argv[2], sys.argv[3], sys.argv[4:]):
            sys.exit(1)
    elif norm_cmd == "fetch-card-artwork" and len(sys.argv) > 4:
        if not cmd_fetch_card_artwork(sys.argv[2], sys.argv[3], sys.argv[4]):
            sys.exit(1)
    elif norm_cmd == "inspect-passthm" and len(sys.argv) > 2:
        cmd_inspect_passthm(sys.argv[2])
    elif norm_cmd == "flash-passthm" and len(sys.argv) > 3:
        t_ver = sys.argv[4] if len(sys.argv) > 4 else "TelephonyUI-10"
        t_lang = sys.argv[5] if len(sys.argv) > 5 else "all"
        t_bold = sys.argv[6] if len(sys.argv) > 6 else "both"
        if not cmd_flash_passthm(sys.argv[2], sys.argv[3], t_ver, t_lang, t_bold):
            sys.exit(1)
    else:
        print(json.dumps({"error": f"Unknown command: {cmd}"}))
        sys.exit(1)


if __name__ == "__main__":
    main()
