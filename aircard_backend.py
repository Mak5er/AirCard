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
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

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
    apply_wallet_db_batch_patch,
    apply_wallet_db_patch,
    extract_file,
    inspect_wallet_db,
    native,
    normalize_primary_account_suffix,
    operation_ok,
    prepare_wallet_db_batch_patch,
    prepare_wallet_db_patch,
    rollback_wallet_db_patch,
    validate_card_hash,
    write_file,
    write_files_batch,
    build_archive_multi,
    ROOT,
    DEVICE_HELPER,
    WALLET_DB_UNCHANGED,
)
from card_assets import CACHE_FILES, build_card_assets
from aircard import (
    find_device_helper,
    get_connected_device,
    load_saved_cards,
    save_cards,
)


def cmd_device():
    if not find_device_helper():
        print(json.dumps({"connected": False, "error": "device_helper_missing"}))
        return
    device = get_connected_device()
    if not device:
        print(json.dumps({"connected": False, "error": "no_device"}))
        return
    probe = native("probe", device["udid"])
    device["airlift_compatible"] = operation_ok(probe)
    device["connected"] = True
    print(json.dumps(device))


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


CARD_ARTWORK_ASSETS = (
    ("cardBackgroundCombined@3x.png", "image/png"),
    ("cardBackgroundCombined@2x.png", "image/png"),
    ("cardBackgroundCombined.pdf", "application/pdf"),
)


def emit_db_diagnostic(
    operation_id: str,
    phase: str,
    status: str,
    started_at: float,
    error: Exception | None = None,
) -> None:
    elapsed_ms = round((time.monotonic() - started_at) * 1000)
    root_error = error
    while root_error is not None and root_error.__cause__ is not None:
        root_error = root_error.__cause__
    if error is None:
        message = (
            f"DB [{operation_id}] {phase} {status} "
            f"({elapsed_ms} ms)"
        )
    else:
        message = (
            f"DB [{operation_id}] {phase} {status} "
            f"after {elapsed_ms} ms: {type(root_error).__name__}: {error}"
        )
    payload = {
        "type": "diagnostic",
        "operationId": operation_id,
        "phase": phase,
        "status": status,
        "elapsedMs": elapsed_ms,
        "message": message,
    }
    if error is not None:
        payload["errorType"] = type(root_error).__name__
    print(json.dumps(payload))
    sys.stdout.flush()


def cmd_backup_card(
    udid: str,
    card_hash: str,
    destination_path: str,
) -> bool:
    """Back up current artwork and database style after explicit user action."""
    try:
        validate_card_hash(card_hash)
    except ValueError as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        return False

    destination = Path(destination_path).expanduser()
    parent = destination.parent
    if not parent.is_dir():
        print(json.dumps({
            "ok": False,
            "error": "Backup destination parent does not exist",
        }))
        return False
    if destination.exists() or destination.is_symlink():
        try:
            is_regular = stat.S_ISREG(destination.lstat().st_mode)
        except OSError:
            is_regular = False
        if not is_regular:
            print(json.dumps({
                "ok": False,
                "error": "Backup destination is not a regular file",
            }))
            return False

    target = f"/var/mobile/Library/Passes/Cards/{card_hash}.pkpass"
    temporary_path: Path | None = None
    try:
        artwork = None
        image_asset = None
        image_mime = None
        with tempfile.TemporaryDirectory(prefix="aircard-backup-read-") as temporary:
            output_path = os.fspath(Path(temporary) / "card-artwork")
            for asset, mime_type in CARD_ARTWORK_ASSETS:
                artwork = extract_file(
                    udid, target, asset, output_path, retries=1
                )
                if artwork is None:
                    continue
                image_asset = asset
                image_mime = mime_type
                break
        if artwork is None or image_asset is None or image_mime is None:
            raise RuntimeError("Card artwork is unavailable")

        database = inspect_wallet_db(udid, card_hash)
        wallet_style = {
            "formatVersion": 2,
            "source": "passes23.sqlite",
            "foregroundColor": database["foregroundColor"],
            "labelColor": database["labelColor"],
            "primaryAccountSuffix": database["primaryAccountSuffix"],
            "imageAsset": image_asset,
        }
        image_data_uri = (
            f"data:{image_mime};base64,"
            f"{base64.b64encode(artwork).decode('ascii')}"
        )

        with tempfile.NamedTemporaryFile(
            prefix=f".{destination.name}.",
            suffix=".tmp",
            dir=parent,
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
        with zipfile.ZipFile(
            temporary_path,
            "w",
            compression=zipfile.ZIP_DEFLATED,
        ) as archive:
            archive.writestr(image_asset, artwork)
            archive.writestr(
                "wallet-style.json",
                json.dumps(
                    wallet_style,
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                ).encode("utf-8"),
            )
        os.replace(temporary_path, destination)
        temporary_path = None

        response = {
            "ok": True,
            "fileName": destination.name,
            "imageDataURI": image_data_uri,
            "imageAsset": image_asset,
            "foregroundColor": wallet_style["foregroundColor"],
            "labelColor": wallet_style["labelColor"],
            "primaryAccountSuffix": wallet_style["primaryAccountSuffix"],
        }
        print(json.dumps(response))
        return True
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        return False
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def cmd_inspect_wallet_db(udid: str, card_hash: str) -> bool:
    try:
        result = inspect_wallet_db(udid, card_hash)
        print(json.dumps({"ok": True, **result}))
        return True
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        return False


def cmd_flash_wallet_db_batch(udid: str, updates_path: str) -> bool:
    operation_id = os.urandom(4).hex()
    phase = "prepare"
    phase_started_at = time.monotonic()
    transaction_started_at = phase_started_at
    try:
        raw = Path(updates_path).read_bytes()
        if not raw or len(raw) > 1024 * 1024:
            raise ValueError("Wallet database update file is empty or too large")
        updates = json.loads(raw)
        if not isinstance(updates, list) or not updates:
            raise ValueError("Wallet database update file must contain a list")

        emit_db_diagnostic(
            operation_id,
            phase,
            "started",
            phase_started_at,
        )
        print(json.dumps({
            "type": "progress",
            "step": 1,
            "total": 2,
            "message": "Preparing Wallet database transaction...",
        }))
        sys.stdout.flush()
        prepared = prepare_wallet_db_batch_patch(udid, updates)
        emit_db_diagnostic(
            operation_id,
            phase,
            "completed",
            phase_started_at,
        )

        phase = "apply"
        phase_started_at = time.monotonic()
        emit_db_diagnostic(
            operation_id,
            phase,
            "started",
            phase_started_at,
        )
        print(json.dumps({
            "type": "progress",
            "step": 2,
            "total": 2,
            "message": "Updating Wallet database...",
        }))
        sys.stdout.flush()
        apply_wallet_db_batch_patch(udid, prepared)
        emit_db_diagnostic(
            operation_id,
            phase,
            "completed",
            phase_started_at,
        )
        emit_db_diagnostic(
            operation_id,
            "transaction",
            "completed",
            transaction_started_at,
        )

        cards = [{
            "requestIndex": card.get("requestIndex"),
            "originalColors": {
                "foregroundColor": card["originalColors"]["foreground_color"],
                "labelColor": card["originalColors"]["label_color"],
            },
            "appliedColors": {
                "foregroundColor": card["appliedColors"]["foreground_color"],
                "labelColor": card["appliedColors"]["label_color"],
            },
            "originalPrimaryAccountSuffix": card["originalColors"][
                "primary_account_suffix"
            ],
            "appliedPrimaryAccountSuffix": card["appliedColors"][
                "primary_account_suffix"
            ],
        } for card in prepared["cards"]]
        print(json.dumps({
            "type": "success",
            "step": 2,
            "total": 2,
            "message": (
                f"Wallet database updated once for {len(cards)} card(s). "
                "Restart your iPhone to apply the changes."
            ),
            "cards": cards,
        }))
        sys.stdout.flush()
        return True
    except (
        json.JSONDecodeError,
        OSError,
        RuntimeError,
        TypeError,
        ValueError,
        subprocess.SubprocessError,
    ) as error:
        emit_db_diagnostic(
            operation_id,
            phase,
            "failed",
            phase_started_at,
            error,
        )
        return False


def cmd_flash(
    udid: str,
    card_hash: str,
    image_path: str,
    foreground_color: str | None = None,
    label_color: str | None = None,
    primary_account_suffix: str | None | object = WALLET_DB_UNCHANGED,
) -> bool:
    try:
        validate_card_hash(card_hash)
        if primary_account_suffix is not WALLET_DB_UNCHANGED:
            normalize_primary_account_suffix(primary_account_suffix)
    except ValueError as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        return False
    card_log_id = "redacted"

    img_path = Path(image_path) if image_path and image_path != "-" else None
    if img_path is not None and not img_path.is_file():
        print(json.dumps({"ok": False, "error": "Image file not found"}))
        return False

    if img_path is None:
        asset_payloads = []
    else:
        try:
            asset_payloads = build_card_assets(img_path.read_bytes())
        except (OSError, subprocess.SubprocessError):
            print(json.dumps({
                "type": "error",
                "card": card_log_id,
                "message": "Failed to prepare card artwork"
            }))
            sys.stdout.flush()
            return False

    pkpass_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}.pkpass"
    
    database_requested = (
        foreground_color is not None
        or label_color is not None
        or primary_account_suffix is not WALLET_DB_UNCHANGED
    )
    cache_steps = len(CACHE_FILES) * 2 if asset_payloads else 0
    total_steps = (
        len(asset_payloads)
        + cache_steps
        + (2 if database_requested else 0)
        + 1
    )
    step = 0
    all_ok = True
    failures: list[str] = []

    original_colors: dict[str, str] = {}
    applied_colors: dict[str, str] = {}
    original_primary_account_suffix: str | None = None
    applied_primary_account_suffix: str | None = None
    prepared_database: dict | None = None
    operation_id: str | None = None
    database_started_at: float | None = None
    if database_requested:
        operation_id = os.urandom(4).hex()
        database_started_at = time.monotonic()
        current_phase = "prepare"
        phase_started_at = time.monotonic()
        emit_db_diagnostic(
            operation_id,
            "prepare",
            "started",
            phase_started_at,
        )
        step += 1
        print(json.dumps({
            "type": "progress",
            "card": card_log_id,
            "step": step,
            "total": total_steps,
            "message": "Preparing Wallet database transaction..."
        }))
        sys.stdout.flush()
        try:
            prepared_database = prepare_wallet_db_patch(
                udid,
                card_hash,
                foreground_color,
                label_color,
                primary_account_suffix,
            )
            original_colors = {
                "foregroundColor": prepared_database["originalColors"][
                    "foreground_color"
                ],
                "labelColor": prepared_database["originalColors"]["label_color"],
            }
            applied_colors = {
                "foregroundColor": prepared_database["appliedColors"][
                    "foreground_color"
                ],
                "labelColor": prepared_database["appliedColors"]["label_color"],
            }
            original_primary_account_suffix = prepared_database[
                "originalColors"
            ]["primary_account_suffix"]
            applied_primary_account_suffix = prepared_database[
                "appliedColors"
            ]["primary_account_suffix"]
            emit_db_diagnostic(
                operation_id,
                "prepare",
                "completed",
                phase_started_at,
            )

            current_phase = "apply"
            phase_started_at = time.monotonic()
            emit_db_diagnostic(
                operation_id,
                "apply",
                "started",
                phase_started_at,
            )
            step += 1
            print(json.dumps({
                "type": "progress",
                "card": card_log_id,
                "step": step,
                "total": total_steps,
                "message": "Updating Wallet database..."
            }))
            sys.stdout.flush()
            apply_wallet_db_patch(udid, prepared_database)
            emit_db_diagnostic(
                operation_id,
                "apply",
                "completed",
                phase_started_at,
            )
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            all_ok = False
            failure = str(error)
            failures.append(failure)
            emit_db_diagnostic(
                operation_id,
                current_phase,
                "failed",
                phase_started_at,
                error,
            )

    if not all_ok:
        return False

    for asset, payload in asset_payloads:
        step += 1
        print(json.dumps({
            "type": "progress",
            "card": card_log_id,
            "step": step,
            "total": total_steps,
            "asset": asset,
            "message": f"Writing {asset}..."
        }))
        sys.stdout.flush()
        try:
            ok = write_file(udid, pkpass_dir, asset, payload)
        except (OSError, RuntimeError, subprocess.SubprocessError):
            ok = False
        if not ok:
            all_ok = False
            failures.append(f"Failed to write {asset}")
            print(json.dumps({
                "type": "error",
                "card": card_log_id,
                "asset": asset,
                "message": f"Failed to write {asset}"
            }))
            sys.stdout.flush()

    if asset_payloads:
        for ext in [".cache", ".pkcache"]:
            cache_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}{ext}"
            for leaf in CACHE_FILES:
                step += 1
                print(json.dumps({
                    "type": "progress",
                    "card": card_log_id,
                    "step": step,
                    "total": total_steps,
                    "message": f"Invalidating cache ({leaf} in {ext})..."
                }))
                sys.stdout.flush()
                try:
                    ok = write_file(udid, cache_dir, leaf, b"corrupted")
                except (OSError, RuntimeError, subprocess.SubprocessError):
                    ok = False
                if not ok:
                    all_ok = False
                    failures.append(
                        f"Failed to invalidate cache ({leaf} in {ext})"
                    )
                    print(json.dumps({
                        "type": "error",
                        "card": card_log_id,
                        "message": (
                            f"Failed to invalidate cache ({leaf} in {ext})"
                        ),
                    }))
                    sys.stdout.flush()

    if not all_ok and database_requested:
        rollback_started_at = time.monotonic()
        emit_db_diagnostic(
            operation_id,
            "rollback",
            "started",
            rollback_started_at,
        )
        try:
            if prepared_database is None:
                raise RuntimeError("color rollback state is unavailable")
            rollback_wallet_db_patch(udid, prepared_database)
            failures.append("Wallet database rollback verified")
            emit_db_diagnostic(
                operation_id,
                "rollback",
                "completed",
                rollback_started_at,
            )
        except RuntimeError as rollback_error:
            failures.append(str(rollback_error))
            emit_db_diagnostic(
                operation_id,
                "rollback",
                "failed",
                rollback_started_at,
                rollback_error,
            )

    step += 1
    if not all_ok:
        print(json.dumps({
            "type": "error",
            "card": card_log_id,
            "step": step,
            "total": total_steps,
            "message": "; ".join(failures),
        }))
        sys.stdout.flush()
        return False

    if database_requested:
        emit_db_diagnostic(
            operation_id,
            "transaction",
            "completed",
            database_started_at,
        )
    print(json.dumps({
        "type": "success",
        "card": card_log_id,
        "step": step,
        "total": total_steps,
        "message": (
            "Successfully updated card. Reboot required: restart your iPhone "
            "to apply Wallet database changes."
            if database_requested
            else "Successfully updated card."
        ),
        "originalColors": original_colors,
        "appliedColors": applied_colors,
        "originalPrimaryAccountSuffix": original_primary_account_suffix,
        "appliedPrimaryAccountSuffix": applied_primary_account_suffix,
    }))
    sys.stdout.flush()
    return True


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
    if norm_cmd == "device":
        cmd_device()
    elif norm_cmd == "cards":
        cmd_get_saved_cards()
    elif norm_cmd == "save-cards" and len(sys.argv) > 2:
        cmd_save_cards(sys.argv[2])
    elif norm_cmd == "prepare-image" and len(sys.argv) > 3:
        cmd_prepare_image(sys.argv[2], sys.argv[3])
    elif norm_cmd == "backup-card" and len(sys.argv) == 5:
        if not cmd_backup_card(sys.argv[2], sys.argv[3], sys.argv[4]):
            sys.exit(1)
    elif norm_cmd == "inspect-wallet-db" and len(sys.argv) == 4:
        if not cmd_inspect_wallet_db(sys.argv[2], sys.argv[3]):
            sys.exit(1)
    elif norm_cmd == "flash-wallet-db-batch" and len(sys.argv) == 4:
        if not cmd_flash_wallet_db_batch(sys.argv[2], sys.argv[3]):
            sys.exit(1)
    elif norm_cmd == "flash" and len(sys.argv) > 4:
        foreground_color = None
        label_color = None
        primary_account_suffix: str | None | object = WALLET_DB_UNCHANGED
        index = 5
        while index < len(sys.argv):
            if index + 1 >= len(sys.argv):
                print(json.dumps({"error": f"Missing value for {sys.argv[index]}"}))
                sys.exit(1)
            if sys.argv[index] == "--foreground-color":
                foreground_color = sys.argv[index + 1]
            elif sys.argv[index] == "--label-color":
                label_color = sys.argv[index + 1]
            elif sys.argv[index] == "--primary-account-suffix":
                primary_account_suffix = sys.argv[index + 1]
            else:
                print(json.dumps({"error": f"Unknown flash option: {sys.argv[index]}"}))
                sys.exit(1)
            index += 2
        if not cmd_flash(
            sys.argv[2],
            sys.argv[3],
            sys.argv[4],
            foreground_color,
            label_color,
            primary_account_suffix,
        ):
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
