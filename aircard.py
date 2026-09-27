#!/usr/bin/env python3
"""
AirCard — Apple Wallet Card Skinner (via airlift exploit).
Customizes Apple Pay and Wallet card skins without a jailbreak.
"""

from __future__ import annotations

import io
import json
import os
import posixpath
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path

# Ensure bundled and standard bin paths are in PATH
script_dir = Path(__file__).resolve().parent
for bin_path in [
    str(script_dir / "bin"),
    "/Applications/AirCard.app/Contents/Resources/bin",
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin"
]:
    if os.path.isdir(bin_path) and bin_path not in os.environ.get("PATH", ""):
        os.environ["PATH"] = f"{bin_path}:{os.environ.get('PATH', '')}"

from apply_card_skin import (
    native,
    operation_ok,
    write_file,
    ROOT,
    DEVICE_HELPER,
)

TARGET_ASSETS = [
    "cardBackgroundCombined@3x.png",
    "cardBackgroundCombined@2x.png",
]

CACHE_FILES = ["FrontFace", "Preview"]

CARDS_STORE_PATH = Path.home() / ".aircard_cards.json"
LEGACY_STORE_PATH = Path.home() / ".lumicards_cards.json"
PREDEFINED_CARDS = []

CARD_REGEXES = [
    re.compile(r"/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,44})(?:\.pkpass|\.cache|\.pkcache|/|\s|\"|\'|\)|,|$)"),
    re.compile(r"/([-A-Za-z0-9_+=]{20,44})\.(?:pkpass|cache|pkcache)"),
    re.compile(r"(?<![A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{27}=)(?![A-Za-z0-9+/_-])"),
]


def load_saved_cards() -> list[str]:
    """Loads saved card hashes from local storage."""
    for store in [CARDS_STORE_PATH, LEGACY_STORE_PATH]:
        if store.is_file():
            try:
                data = json.loads(store.read_text("utf-8"))
                if isinstance(data, list) and data:
                    return data
            except Exception:
                pass
    return list(PREDEFINED_CARDS)


def save_cards(cards: list[str]):
    """Saves unique card hashes to local storage."""
    try:
        unique = list(dict.fromkeys(cards))
        CARDS_STORE_PATH.write_text(json.dumps(unique, indent=2), encoding="utf-8")
    except Exception:
        pass


def find_device_helper() -> str | None:
    """Finds the bundled device helper, the app's only device-communication tool."""
    root = Path(__file__).resolve().parent
    candidates = [root / "bin" / "device_helper", root / "build" / "device_helper"]
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


class DeviceDiscoveryError(RuntimeError):
    pass


def list_devices(*, raise_errors: bool = False) -> list[dict]:
    """Enumerate paired devices, preserving diagnostics for the GUI."""
    helper = find_device_helper()
    if not helper:
        if raise_errors:
            raise DeviceDiscoveryError("找不到 device_helper，請重新建置 App。")
        return []
    try:
        result = subprocess.run([helper, "list"], capture_output=True, text=True, timeout=15)
        if result.returncode != 0:
            detail = result.stderr.strip()[:400] or f"exit {result.returncode}"
            raise DeviceDiscoveryError(f"裝置發現服務失敗：{detail}")
        for line in reversed(result.stdout.splitlines()):
            try:
                devices = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(devices, list):
                return [d for d in devices if isinstance(d, dict)]
        raise DeviceDiscoveryError("裝置輔助工具未返回有效的裝置清單。")
    except (OSError, subprocess.SubprocessError, DeviceDiscoveryError) as error:
        if raise_errors:
            if isinstance(error, subprocess.TimeoutExpired):
                raise DeviceDiscoveryError("裝置發現超時，請解鎖 iPhone 並確認信任此電腦。") from error
            raise DeviceDiscoveryError(str(error)) from error
        return []


def get_connected_device(*, raise_errors: bool = False) -> dict | None:
    """Picks the connected iPhone out of the enumerated devices."""
    devices = list_devices(raise_errors=True) if raise_errors else list_devices()
    usable = [d for d in devices if d.get("udid") and d.get("product")]
    if not usable:
        if devices and raise_errors:
            raise DeviceDiscoveryError("已發現裝置，但無法建立會話。請解鎖 iPhone，並點選「信任此電腦」。")
        return None
    # Enumeration order is not stable, and iPads can appear alongside the iPhone.
    # A Wi-Fi-paired device can be listed first while the one actually plugged in
    # comes later, so prefer USB-attached devices before anything else.
    usb = [d for d in usable if d.get("usb")]
    pool = usb or usable
    iphones = [d for d in pool if str(d["product"]).startswith("iPhone")]
    device = (iphones or pool)[0]

    return {
        "udid": device["udid"],
        "name": device.get("name") or "iPhone",
        "version": device.get("version") or "Unknown",
        "product": device["product"],
        "language": device.get("language"),
        "locale": device.get("locale") or "",
        "bold_text": bool(device["bold_text"]) if isinstance(device.get("bold_text"), (bool, int)) and device["bold_text"] in (0, 1) else None,
    }


def syslog_command(udid: str) -> list[str] | None:
    """Builds the command that streams the device log, or None if unbundled."""
    helper = find_device_helper()
    if not helper:
        return None
    return [helper, "syslog", udid]


def capture_card_hashes(udid: str, existing_cards: list[str] | None = None) -> list[str]:
    """Listens to syslog and collects card hashes while the user opens Apple Wallet."""
    print("\n" + "=" * 60)
    print("📡 卡片掃描模式")
    print("=" * 60)
    print("偵測卡片的步驟：")
    print("  👉 1) 按兩下側邊（電源）按鈕開啟 Apple Pay。")
    print("  👉 2) 使用 Face ID 驗證。")
    print("  👉 3) 點選卡片即可觸發偵測！")
    print("完成後請按 Enter。")
    print("=" * 60 + "\n")

    cmd = syslog_command(udid)
    if not cmd:
        print("\u274c 缺少 device_helper，無法讀取裝置紀錄。")
        return list(existing_cards or [])
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    found_hashes = set(existing_cards or [])
    initial_count = len(found_hashes)

    try:
        import select

        while True:
            rlist, _, _ = select.select([sys.stdin, process.stdout], [], [], 0.2)
            if sys.stdin in rlist:
                sys.stdin.readline()
                break

            if process.stdout in rlist:
                line = process.stdout.readline()
                if not line:
                    break

                if line.startswith("AirCard scanner: "):
                    print(line.rstrip())
                    continue

                lower = line.lower()
                is_wallet = (
                    "passd" in lower
                    or "passbook" in lower
                    or "passkit" in lower
                    or "stockholm" in lower
                    or "nanopassd" in lower
                    or "wallet" in lower
                    or "/cards/" in lower
                )
                if not is_wallet:
                    continue

                is_ctx = any(
                    w in lower
                    for w in [
                        "card",
                        "pass",
                        "payment",
                        "pkpass",
                        "uniqueid",
                        "identifier",
                        "face",
                        "cache",
                        "stockholm",
                        "/cards/",
                    ]
                )
                if not is_ctx:
                    continue

                for r in CARD_REGEXES:
                    m = r.search(line)
                    if m:
                        h = m.group(1).strip().strip("'\"").rstrip(".").rstrip(",")
                        if len(h) == 36 and "-" in h:
                            continue
                        if h in [
                            "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
                            "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
                            "hwAtAmHKYwsQrJbT5cTNDsaxVME=",
                        ]:
                            continue
                        if h and h not in found_hashes:
                            found_hashes.add(h)
                            print(f"  ✨ 已偵測卡片 [{len(found_hashes)}]: {h}")

    except KeyboardInterrupt:
        pass
    finally:
        process.terminate()
        process.wait()

    res = list(found_hashes)
    save_cards(res)
    return res


def prepare_card_image(input_path: str) -> bytes:
    """Scales image to Apple Wallet standard (1536x969 PNG)."""
    clean_path = input_path.strip().strip("'").strip('"')
    path = Path(clean_path).expanduser()
    if not path.is_file():
        raise FileNotFoundError(f"找不到檔案：{path}")

    try:
        from PIL import Image, ImageOps
        with Image.open(path) as img:
            img = img.convert("RGBA")
            target_size = (1536, 969)
            fitted = ImageOps.fit(img, target_size, method=Image.Resampling.LANCZOS)
            out_io = io.BytesIO()
            fitted.save(out_io, format="PNG")
            return out_io.getvalue()
    except Exception:
        pass

    # Fallback to macOS sips
    temp_out = f"/tmp/aircard_sips_{os.getpid()}.png"
    try:
        subprocess.check_call([
            "/usr/bin/sips",
            "-s", "format", "png",
            "-z", "969", "1536",
            str(path),
            "--out", temp_out
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        data = Path(temp_out).read_bytes()
        Path(temp_out).unlink(missing_ok=True)
        return data
    except Exception as e:
        raise RuntimeError(f"圖片處理失敗：{e}")


def main():
    print("=" * 60)
    print("🎴 AirCard — Apple Wallet Card Skinner (via airlift)")
    print("=" * 60)

    # 1. Device discovery
    print("\n[1/5] 正在搜尋已連線的裝置…")
    device = get_connected_device()
    if not device:
        print("❌ 找不到 iPhone！請以 USB 連接 iPhone 並解鎖螢幕。")
        sys.exit(1)

    print(f"✅ 已找到： {device['name']} ({device['product']}, iOS {device['version']})")
    print(f"   UDID: {device['udid']}")

    # 2. Check airlift compatibility
    probe = native("probe", device["udid"])
    if not operation_ok(probe):
        print("❌ Airlift 預先檢查失敗，請確認裝置已配對並信任此電腦。")
        sys.exit(1)

    # 3. Card discovery / selection
    saved_cards = load_saved_cards()
    print(f"\n[2/5] 已儲存的卡片： {len(saved_cards)}")
    for idx, h in enumerate(saved_cards, 1):
        print(f"  [{idx}] {h}")

    print("\n請選擇操作：")
    print("  1 - 使用現有卡片")
    print("  2 - 掃描卡片（開啟錢包並點選卡片）")
    print("  3 - 手動輸入卡片雜湊值")
    mode = input("請選擇 [1]：").strip()

    hashes = saved_cards
    if mode == "2":
        hashes = capture_card_hashes(device["udid"], saved_cards)
    elif mode == "3":
        manual = input("輸入卡片雜湊值，以逗號或空格分隔：").strip()
        new_items = [x.strip() for x in re.split(r"[\s,;]+", manual) if len(x.strip()) >= 16]
        for item in new_items:
            if item not in hashes:
                hashes.append(item)
        save_cards(hashes)

    if not hashes:
        print("❌ 沒有可寫入的卡片。")
        sys.exit(1)

    print(f"\n[3/5] 準備寫入卡片 ({len(hashes)}):")
    for i, h in enumerate(hashes, 1):
        print(f"  [{i}] {h}")

    print("\n選擇要自訂的卡片：")
    print("  'all' - 套用至所有卡片")
    print("  以逗號分隔的編號（例如 1,3）")
    choice = input("請選擇 [all]：").strip().lower()

    if choice == "" or choice == "all":
        selected_hashes = hashes
    else:
        try:
            indices = [int(x.strip()) for x in choice.split(",") if x.strip()]
            selected_hashes = [hashes[i - 1] for i in indices if 1 <= i <= len(hashes)]
        except Exception:
            print("輸入無效，將套用至所有卡片。")
            selected_hashes = hashes

    if not selected_hashes:
        print("❌ 未選取卡片。")
        sys.exit(1)

    # 4. Prepare image
    print(f"\n[4/5] 正在準備圖片…")
    while True:
        img_input = input("將圖片拖曳到終端機（或輸入路徑）：").strip()
        try:
            png_bytes = prepare_card_image(img_input)
            print(f"✅ 圖片已針對 Apple Wallet 最佳化 ({len(png_bytes)} 位元組)")
            break
        except Exception as e:
            print(f"❌ 錯誤：{e}，請選擇其他圖片。")

    # 5. Flash cards
    print(f"\n[5/5] 正在將外觀寫入所選卡片 ({len(selected_hashes)})...")

    for idx, h in enumerate(selected_hashes, 1):
        print(f"\n--- [{idx}/{len(selected_hashes)}] 卡片：{h} ---")
        pkpass_dir = f"/var/mobile/Library/Passes/Cards/{h}.pkpass"

        for asset in TARGET_ASSETS:
            ok = write_file(device["udid"], pkpass_dir, asset, png_bytes)
            status = "成功" if ok else "失敗"
            print(f"  -> {asset}: {status}")

        for ext in [".cache", ".pkcache"]:
            cache_dir = f"/var/mobile/Library/Passes/Cards/{h}{ext}"
            for leaf in CACHE_FILES:
                write_file(device["udid"], cache_dir, leaf, b"corrupted")
        print("  -> 已清除系統快取（.cache 與 .pkcache）")

    print("\n" + "=" * 60)
    print("🎉 完成！所有選取的卡片皆已更新！")
    print("=" * 60)
    print("1. 在 iPhone 上完全關閉 Apple Wallet。")
    print("2. 若圖片尚未更新，請重新啟動 iPhone。")
    print("=" * 60)


if __name__ == "__main__":
    main()
