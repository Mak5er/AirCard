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
import subprocess
import sys
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
    ExtractionRestoreError,
    apply_wallet_db_batch_patch,
    wallet_db_progress,
    apply_wallet_db_patch,
    inspect_wallet_db,
    normalize_primary_account_suffix,
    prepare_wallet_db_batch_patch,
    prepare_wallet_db_patch,
    rollback_wallet_db_patch,
    validate_card_hash,
    remove_files,
    WALLET_DB_UNCHANGED,
    native,
    operation_ok,
    write_file,
    write_files_batch,
    build_archive_multi,
    ROOT,
    DEVICE_HELPER,
)
from card_assets import CACHE_FILES, build_card_assets
from aircard import (
    DeviceDiscoveryError,
    find_device_helper,
    get_connected_device,
    load_saved_cards,
    save_cards,
)


def cmd_device():
    if not find_device_helper():
        print(json.dumps({"connected": False, "error": "device_helper_missing"}))
        return
    try:
        device = get_connected_device(raise_errors=True)
    except DeviceDiscoveryError as error:
        print(json.dumps({"connected": False, "error": "device_discovery_failed", "error_message": str(error)}), flush=True)
        return
    if not device:
        print(json.dumps({"connected": False, "error": "no_device"}))
        return
    # A paired device is connected even when AFC/AirTraffic is not ready yet.
    # The write path performs its own handshake; detection must not wait for it.
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
    print(json.dumps({"ok": False, "error": "格式無效"}))


def cmd_prepare_image(src: str, dst: str):
    path = Path(src).expanduser()
    if not path.is_file():
        print(json.dumps({"ok": False, "error": f"找不到檔案：{src}"}))
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


def cmd_flash(udid: str, card_hash: str, image_path: str,
              foreground_color: str | None = None,
              primary_account_suffix: str | None | object = WALLET_DB_UNCHANGED) -> bool:
    prepared = None
    applied = False
    try:
        validate_card_hash(card_hash)
        artwork = bool(image_path and image_path != "-")
        database = foreground_color is not None or primary_account_suffix is not WALLET_DB_UNCHANGED
        if not artwork and not database:
            raise ValueError("請先設定圖片、文字顏色或顯示末四碼。")
        if artwork and not Path(image_path).is_file():
            raise ValueError("找不到圖片檔案")
        if database:
            prepared = prepare_wallet_db_patch(udid, card_hash, foreground_color, primary_account_suffix)
            apply_wallet_db_patch(udid, prepared)
            applied = True
        if artwork and not cmd_flash_artwork(udid, card_hash, image_path):
            raise RuntimeError("卡片圖片或快取更新失敗")
        result = {"type": "success", "message": "卡片已更新。" + ("請重新啟動 iPhone。" if database else ""),
                  "step": 1, "total": 1}
        if prepared:
            result.update({
                "originalColors": {"foregroundColor": prepared["originalColors"]["foreground_color"]},
                "appliedColors": {"foregroundColor": prepared["appliedColors"]["foreground_color"]},
                "originalPrimaryAccountSuffix": prepared["originalColors"]["primary_account_suffix"],
                "appliedPrimaryAccountSuffix": prepared["appliedColors"]["primary_account_suffix"],
            })
        print(json.dumps(result), flush=True)
        return True
    except (OSError, RuntimeError, ValueError, TypeError, subprocess.SubprocessError) as error:
        detail = str(error)
        if applied:
            try:
                rollback_wallet_db_patch(udid, prepared)
            except Exception as rollback_error:
                detail += f"; {rollback_error}"
        print(json.dumps({"type": "error", "message": detail}), flush=True)
        return False


def cmd_flash_artwork(udid: str, card_hash: str, image_path: str) -> bool:
    img_path = Path(image_path)
    if not img_path.is_file():
        print(json.dumps({"ok": False, "error": "找不到圖片檔案"}))
        return False

    try:
        asset_payloads = build_card_assets(img_path.read_bytes())
    except (OSError, subprocess.SubprocessError):
        print(json.dumps({
            "type": "error",
            "card": card_hash,
            "message": "卡片圖片準備失敗"
        }))
        sys.stdout.flush()
        return False

    pkpass_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}.pkpass"
    
    total_steps = len(asset_payloads) + 3
    step = 0
    all_ok = True

    step += 1
    print(json.dumps({
        "type": "progress",
        "card": card_hash,
        "step": step,
        "total": total_steps,
        "message": f"正在批量寫入 {len(asset_payloads)} 個圖片檔案…"
    }))
    sys.stdout.flush()

    def report(message):
        print(json.dumps({
            "type": "progress", "card": card_hash,
            "step": step,
            "total": total_steps, "message": message,
        }), flush=True)

    def batch_progress(base, label):
        def callback(event):
            nonlocal step
            if event.get("type") == "atc_status":
                report(event["message"])
            else:
                step = max(step, base + event.get("index", 0))
                report(f"{label}: {event.get('leaf', '')}")
        return callback

    try:
        try:
            ok = write_files_batch(
                udid, pkpass_dir, asset_payloads,
                progress_callback=batch_progress(step, "圖片已發送"),
            )
        except (ConnectionError, TimeoutError, subprocess.TimeoutExpired):
            raise
        except (OSError, RuntimeError, subprocess.SubprocessError):
            ok = False

        if not ok:
            report("批量寫入失敗，正在逐個檔案重試…")
            for index, (asset, payload) in enumerate(asset_payloads, 1):
                report(f"正在單獨寫入 {asset}…")
                try:
                    ok_single = write_file(udid, pkpass_dir, asset, payload)
                except (ConnectionError, TimeoutError, subprocess.TimeoutExpired):
                    raise
                except Exception:
                    ok_single = False
                all_ok = all_ok and ok_single
                step = max(step, 1 + index)
        step = 1 + len(asset_payloads)

        for ext in [".cache", ".pkcache"]:
            step += 1
            report(f"正在清理快取（{ext}）…")
            cache_dir = f"/var/mobile/Library/Passes/Cards/{card_hash}{ext}"
            all_ok = remove_files(udid, cache_dir, list(CACHE_FILES)) and all_ok
    except (ConnectionError, TimeoutError, subprocess.TimeoutExpired) as error:
        print(json.dumps({
            "type": "error", "card": card_hash,
            "message": f"裝置操作失敗： {error}",
        }), flush=True)
        return False

    step = total_steps
    if not all_ok:
        print(json.dumps({
            "type": "error",
            "card": card_hash,
            "step": step,
            "total": total_steps,
            "message": f"更新失敗：{card_hash[:12]}…"
        }))
        sys.stdout.flush()
        return False

    print(json.dumps({
        "type": "progress",
        "card": card_hash,
        "step": step,
        "total": total_steps,
        "message": f"更新成功：{card_hash[:12]}…"
    }))
    sys.stdout.flush()
    return True


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
    phase_label = {"prepare": "準備", "apply": "寫入", "rollback": "還原", "transaction": "交易"}.get(phase, phase)
    status_label = {"started": "開始", "completed": "完成", "failed": "失敗"}.get(status, status)
    if error is None:
        message = (
            f"資料庫 [{operation_id}] {phase_label}：{status_label} "
            f"（{elapsed_ms} 毫秒）"
        )
    else:
        message = (
            f"資料庫 [{operation_id}] {phase_label}：{status_label} "
            f"（{elapsed_ms} 毫秒）：{type(root_error).__name__}: {error}"
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


def emit_recovery_guidance(error: Exception) -> None:
    current = error
    while current is not None:
        if isinstance(current, ExtractionRestoreError):
            for message in (
                "處理建議：本次更新未確認成功，請先停止重試，保留完整紀錄及 Media/airlift-recovered-* 復原檔；不要手動刪除或覆寫。",
                "AFC=8／file_not_found 表示本輪未找到指定的復原檔，不能據此判定原位置資料庫或卡片資料已遺失。",
                "確認後端已結束後，若 Wallet 空白，可先重新啟動 iPhone，開啟 Wallet 等約一分鐘，再從多工畫面關閉 Wallet 並重新開啟。此方法不保證解決資料庫還原失敗。",
                "若卡片仍未恢復，請保留現況與紀錄供排查；復原檔可能包含敏感資料，請勿公開上傳。詳見「使用說明與疑難排解.md」。",
            ):
                print(json.dumps({"type": "diagnostic", "message": message}), flush=True)
            return
        current = current.__cause__



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
    def report_progress(step, message):
        payload = {
            "type": "progress", "message": message,
            "elapsedMs": round((time.monotonic() - transaction_started_at) * 1000),
        }
        if step is not None:
            payload.update(step=step, total=14)
        print(json.dumps(payload), flush=True)

    try:
        raw = Path(updates_path).read_bytes()
        if not raw or len(raw) > 1024 * 1024:
            raise ValueError("Wallet 資料庫更新檔為空或過大")
        updates = json.loads(raw)
        if not isinstance(updates, list) or not updates:
            raise ValueError("Wallet 資料庫更新檔必須包含清單")

        emit_db_diagnostic(
            operation_id,
            phase,
            "started",
            phase_started_at,
        )
        report_progress(0, "正在準備 Wallet 資料庫更新…")
        with wallet_db_progress(report_progress):
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
        report_progress(4, "正在比對寫入前的 Wallet 資料庫…")
        with wallet_db_progress(report_progress):
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
            },
            "appliedColors": {
                "foregroundColor": card["appliedColors"]["foreground_color"],
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
            "step": 14,
            "total": 14,
            "message": (
                f"已一次更新 {len(cards)} 張卡片的 Wallet 資料庫。"
                "請重新啟動 iPhone 以套用變更。"
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
        emit_recovery_guidance(error)
        return False



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
        raise FileNotFoundError(f"找不到密碼主題檔案: {passthm_path}")

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
        print(json.dumps({"ok": False, "error": f"找不到檔案：{passthm_path}"}))
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
            print(json.dumps({"ok": False, "error": "壓縮檔中沒有圖片素材"}))
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
        print(json.dumps({"ok": False, "error": "找不到密碼主題檔案"}))
        return False

    try:
        items_to_write = parse_passthm_archive(str(path), telephony_ver, target_lang, target_bold)
        if not items_to_write:
            print(json.dumps({"ok": False, "error": "壓縮檔中沒有圖片素材"}))
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
            "message": f"正在寫入密碼主題“{path.stem}”（{total_steps} 個資源）…"
        }))
        sys.stdout.flush()

        for tdir, dir_files in items_by_dir.items():
            tdir_name = Path(tdir).name
            base_step = processed_files

            def make_progress_handler(base: int):
                def on_atc_progress(p: dict):
                    if p.get("type") == "atc_status":
                        print(json.dumps({"type": "progress", "message": p["message"]}), flush=True)
                        return
                    idx = p.get("index", 0)
                    leaf = p.get("leaf", "")
                    curr = min(base + idx, total_steps)
                    print(json.dumps({
                        "type": "progress",
                        "step": curr,
                        "total": total_steps,
                        "leaf": leaf,
                        "message": p.get("message") or f"正在寫入 {leaf}（{curr}/{total_steps}）…"
                    }))
                    sys.stdout.flush()
                return on_atc_progress

            print(json.dumps({
                "type": "progress",
                "step": base_step,
                "total": total_steps,
                "message": f"正在向 {tdir_name} 寫入 {len(dir_files)} 個資源…"
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
                    "message": f"{tdir_name} 批量寫入失敗，正在逐個檔案寫入…"
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
                        "message": f"[逐個重試] 正在寫入 {leaf}（{curr}/{total_steps}）…"
                    }))
                    sys.stdout.flush()

                    single_ok = write_file(udid, tdir, leaf, payload, retries=3)
                    if not single_ok:
                        failed_leaves.append(leaf)
                    time.sleep(0.08)

                if failed_leaves:
                    print(json.dumps({
                        "type": "error",
                        "message": f"{tdir_name} 中有 {len(failed_leaves)} 個檔案寫入失敗： {', '.join(failed_leaves[:5])}"
                    }))
                    sys.stdout.flush()
                    return False

            processed_files += len(dir_files)

        print(json.dumps({
            "type": "success",
            "step": total_steps,
            "total": total_steps,
            "message": f"密碼主題“{path.stem}”已成功應用！請鎖定 iPhone 查看。"
        }))
        sys.stdout.flush()
        return True

    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        return False


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "未提供指令"}))
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
    elif norm_cmd == "inspect-wallet-db" and len(sys.argv) == 4:
        if not cmd_inspect_wallet_db(sys.argv[2], sys.argv[3]):
            sys.exit(1)
    elif norm_cmd == "flash-wallet-db-batch" and len(sys.argv) == 4:
        if not cmd_flash_wallet_db_batch(sys.argv[2], sys.argv[3]):
            sys.exit(1)
    elif norm_cmd == "flash" and len(sys.argv) > 4:
        foreground_color = None
        primary_account_suffix: str | None | object = WALLET_DB_UNCHANGED
        index = 5
        while index < len(sys.argv):
            if index + 1 >= len(sys.argv):
                print(json.dumps({"error": f"缺少參數值：{sys.argv[index]}"}))
                sys.exit(1)
            if sys.argv[index] == "--foreground-color":
                foreground_color = sys.argv[index + 1]
            elif sys.argv[index] == "--primary-account-suffix":
                primary_account_suffix = sys.argv[index + 1]
            else:
                print(json.dumps({"error": f"未知寫入選項：{sys.argv[index]}"}))
                sys.exit(1)
            index += 2
        if not cmd_flash(
            sys.argv[2],
            sys.argv[3],
            sys.argv[4],
            foreground_color,
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
        print(json.dumps({"error": f"未知指令：{cmd}"}))
        sys.exit(1)


if __name__ == "__main__":
    main()
