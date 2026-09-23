#!/usr/bin/env python3
"""
AirCard — Apple Wallet Card Skinner (via airlift exploit).
Customizes Apple Pay and Wallet card skins without a jailbreak.
"""

from __future__ import annotations

# 接下来仅汉化供用户阅读的提示，设备标识、路径及 JSON 状态字段保持兼容。
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


def list_devices() -> list[dict]:
    """Enumerates paired devices reachable over USB.

    Wi-Fi-paired devices can appear here too, and an entry whose session could
    not be opened is reported with an empty `product`.
    """
    helper = find_device_helper()
    if not helper:
        return []
    try:
        output = subprocess.check_output(
            [helper, "list"], text=True, stderr=subprocess.DEVNULL, timeout=30
        )
    except (OSError, subprocess.SubprocessError):
        return []

    for line in reversed(output.splitlines()):
        try:
            devices = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(devices, list):
            return [d for d in devices if isinstance(d, dict)]
    return []


def get_connected_device() -> dict | None:
    """Picks the connected iPhone out of the enumerated devices."""
    usable = [d for d in list_devices() if d.get("udid") and d.get("product")]
    if not usable:
        return None
    # Enumeration order is not stable, and iPads can appear alongside the iPhone.
    iphones = [d for d in usable if str(d["product"]).startswith("iPhone")]
    device = (iphones or usable)[0]

    return {
        "udid": device["udid"],
        "name": device.get("name") or "iPhone",
        "version": device.get("version") or "未知",
        "product": device["product"],
        "language": device.get("language") or "en",
        "locale": device.get("locale") or "",
        "bold_text": device.get("bold_text"),
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
    print("📡 卡片扫描模式")
    print("=" * 60)
    print("请按以下步骤检测卡片：")
    print("  👉 1) 连按两下侧边（电源）按钮，打开 Apple Pay。")
    print("  👉 2) 通过面容 ID 验证。")
    print("  👉 3) 轻点卡片，即可触发检测！")
    print("完成后按回车键。")
    print("=" * 60 + "\n")

    cmd = syslog_command(udid)
    if not cmd:
        print("❌ 缺少内置 device_helper，无法读取设备日志。")
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
                            print(f"  ✨ 已检测到卡片 [{len(found_hashes)}]：{h}")

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
        raise FileNotFoundError(f"文件不存在：{path}")

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
        raise RuntimeError(f"图片处理失败：{e}")


def main():
    print("=" * 60)
    print("🎴 AirCard — Apple 钱包卡片皮肤工具（基于 airlift）")
    print("=" * 60)

    # 1. Device discovery
    print("\n[1/5] 正在搜索已连接的设备...")
    device = get_connected_device()
    if not device:
        print("❌ 未找到 iPhone！请通过 USB 连接并解锁屏幕。")
        sys.exit(1)

    print(f"✅ 已找到：{device['name']}（{device['product']}, iOS {device['version']}）")
    print(f"   UDID: {device['udid']}")

    # 2. Check airlift compatibility
    probe = native("probe", device["udid"])
    if not operation_ok(probe):
        print("❌ Airlift 预检查失败，请确保设备已配对并信任此电脑。")
        sys.exit(1)

    # 3. Card discovery / selection
    saved_cards = load_saved_cards()
    print(f"\n[2/5] 已保存卡片：{len(saved_cards)} 张")
    for idx, h in enumerate(saved_cards, 1):
        print(f"  [{idx}] {h}")

    print("\n请选择操作：")
    print("  1 - 使用已有卡片")
    print("  2 - 扫描卡片（打开钱包并轻点卡片）")
    print("  3 - 手动输入卡片哈希值")
    mode = input("请选择 [1]：").strip()

    hashes = saved_cards
    if mode == "2":
        hashes = capture_card_hashes(device["udid"], saved_cards)
    elif mode == "3":
        manual = input("请输入卡片哈希值，用英文逗号或空格分隔：").strip()
        new_items = [x.strip() for x in re.split(r"[\s,;]+", manual) if len(x.strip()) >= 16]
        for item in new_items:
            if item not in hashes:
                hashes.append(item)
        save_cards(hashes)

    if not hashes:
        print("❌ 没有可写入的卡片。")
        sys.exit(1)

    print(f"\n[3/5] 待写入卡片（{len(hashes)} 张）：")
    for i, h in enumerate(hashes, 1):
        print(f"  [{i}] {h}")

    print("\n请选择要自定义的卡片：")
    print("  'all' - 应用到所有卡片")
    print("  输入编号，用英文逗号分隔（例如 1,3）")
    choice = input("请选择 [all]：").strip().lower()

    if choice == "" or choice == "all":
        selected_hashes = hashes
    else:
        try:
            indices = [int(x.strip()) for x in choice.split(",") if x.strip()]
            selected_hashes = [hashes[i - 1] for i in indices if 1 <= i <= len(hashes)]
        except Exception:
            print("输入无效，将应用到所有卡片。")
            selected_hashes = hashes

    if not selected_hashes:
        print("❌ 尚未选择卡片。")
        sys.exit(1)

    # 4. Prepare image
    print(f"\n[4/5] 正在准备图片...")
    while True:
        img_input = input("将图片拖入终端，或输入文件路径：").strip()
        try:
            png_bytes = prepare_card_image(img_input)
            print(f"✅ 图片已优化为 Apple 钱包格式（{len(png_bytes)} 字节）")
            break
        except Exception as e:
            print(f"❌ 错误：{e}。请选择其他图片。")

    # 5. Flash cards
    print(f"\n[5/5] 正在为选中的 {len(selected_hashes)} 张卡片写入皮肤...")

    for idx, h in enumerate(selected_hashes, 1):
        print(f"\n--- [{idx}/{len(selected_hashes)}] 卡片：{h} ---")
        pkpass_dir = f"/var/mobile/Library/Passes/Cards/{h}.pkpass"

        for asset in TARGET_ASSETS:
            ok = write_file(device["udid"], pkpass_dir, asset, png_bytes)
            status = "成功" if ok else "失败"
            print(f"  -> {asset}: {status}")

        for ext in [".cache", ".pkcache"]:
            cache_dir = f"/var/mobile/Library/Passes/Cards/{h}{ext}"
            for leaf in CACHE_FILES:
                write_file(device["udid"], cache_dir, leaf, b"corrupted")
        print("  -> 系统缓存已清除（.cache 和 .pkcache）")

    print("\n" + "=" * 60)
    print("🎉 完成！所有选中的卡片均已更新！")
    print("=" * 60)
    print("1. 在 iPhone 上彻底关闭“钱包”App。")
    print("2. 如果图片没有立即更新，请重启 iPhone。")
    print("=" * 60)


if __name__ == "__main__":
    main()
