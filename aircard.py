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
    invalidate_cache,
    ROOT,
    DEVICE_HELPER,
)
from card_assets import CACHE_FILES

TARGET_ASSETS = [
    "cardBackgroundCombined@3x.png",
    "cardBackgroundCombined@2x.png",
]

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


def format_device(device: dict) -> dict:
    product = device.get("product")
    has_product = bool(product and product != "Unknown")
    default_name = (
        "iPhone"
        if (product and str(product).startswith("iPhone"))
        else ("Apple Device" if has_product else "Locked / Unpaired Device")
    )
    return {
        "udid": device["udid"],
        "name": device.get("name") or default_name,
        "version": device.get("version") or ("Unknown" if has_product else ""),
        "build_version": device.get("buildVersion") or device.get("build_version") or "",
        "product": product or "",
        "language": device.get("language") or "en",
        "locale": device.get("locale") or "",
        "bold_text": device.get("bold_text"),
        "connected": True,
    }


def get_all_connected_devices() -> list[dict]:
    """Returns all enumerated devices formatted for UI/CLI consumption."""
    raw = [d for d in list_devices() if d.get("udid")]
    if not raw:
        return []
    # Separate into fully paired iPhones, other paired devices, and unpaired devices
    iphones = [d for d in raw if d.get("product") and str(d["product"]).startswith("iPhone")]
    other_paired = [d for d in raw if d.get("product") and not str(d["product"]).startswith("iPhone")]
    unpaired = [d for d in raw if not d.get("product")]

    sorted_raw = iphones + other_paired + unpaired
    return [format_device(d) for d in sorted_raw]


def get_connected_device(target_udid: str | None = None) -> dict | None:
    """Picks the connected device (by UDID if given, or the best available device)."""
    devices = get_all_connected_devices()
    if not devices:
        return None
    if target_udid:
        for d in devices:
            if d["udid"] == target_udid:
                return d
    paired = [d for d in devices if d.get("product")]
    return paired[0] if paired else devices[0]


def syslog_command(udid: str) -> list[str] | None:
    """Builds the command that streams the device log, or None if unbundled."""
    helper = find_device_helper()
    if not helper:
        return None
    return [helper, "syslog", udid]


def capture_card_hashes(udid: str, existing_cards: list[str] | None = None) -> list[str]:
    """Listens to syslog and collects card hashes while the user opens Apple Wallet."""
    print("\n" + "=" * 60)
    print("📡 CARD SCANNING MODE")
    print("=" * 60)
    print("To detect your cards:")
    print("  👉 1) Double-click Side (Power) button to open Apple Pay.")
    print("  👉 2) Authenticate with Face ID.")
    print("  👉 3) Tap your card to trigger instant detection!")
    print("Press ENTER when finished.")
    print("=" * 60 + "\n")

    cmd = syslog_command(udid)
    if not cmd:
        print("\u274c Bundled device_helper is missing \u2014 cannot read the device log.")
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
                            print(f"  ✨ Detected card [{len(found_hashes)}]: {h}")

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
        raise FileNotFoundError(f"File not found: {path}")

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
        raise RuntimeError(f"Failed to process image: {e}")


def main():
    print("=" * 60)
    print("🎴 AirCard — Apple Wallet Card Skinner (via airlift)")
    print("=" * 60)

    # 1. Device discovery
    print("\n[1/5] Searching for connected device...")
    devices = get_all_connected_devices()
    if not devices:
        print("❌ iPhone not found! Connect your iPhone via USB and unlock the screen.")
        sys.exit(1)

    target_udid = None
    for i, arg in enumerate(sys.argv[1:]):
        if arg == "--udid" and i + 2 < len(sys.argv):
            target_udid = sys.argv[i + 2]
            break

    device = None
    if target_udid:
        device = get_connected_device(target_udid)
        if not device:
            print(f"❌ Specified device UDID {target_udid} not found among connected devices.")
            sys.exit(1)
    elif len(devices) == 1:
        device = devices[0]
    else:
        print(f"\n📱 Found {len(devices)} connected device(s):")
        for idx, d in enumerate(devices, 1):
            prod_str = f" ({d['product']}, iOS {d['version']})" if d.get("product") else " (Locked/Unpaired)"
            print(f"  [{idx}] {d['name']}{prod_str} — UDID: {d['udid']}")

        while not device:
            choice = input(f"\nSelect device [1-{len(devices)}, default 1]: ").strip()
            if not choice:
                device = devices[0]
                break
            if choice.isdigit() and 1 <= int(choice) <= len(devices):
                device = devices[int(choice) - 1]
                break
            print("Invalid choice, please try again.")

    print(f"\n✅ Selected: {device['name']} ({device.get('product') or 'Device'}, iOS {device.get('version') or '?'})")
    print(f"   UDID: {device['udid']}")

    # 2. Check airlift compatibility
    probe = native("probe", device["udid"])
    if not operation_ok(probe):
        print("❌ Airlift pre-check failed. Ensure the device is paired and trusted.")
        sys.exit(1)

    # 3. Card discovery / selection
    saved_cards = load_saved_cards()
    print(f"\n[2/5] Saved cards: {len(saved_cards)}")
    for idx, h in enumerate(saved_cards, 1):
        print(f"  [{idx}] {h}")

    print("\nChoose an action:")
    print("  1 - Use existing cards")
    print("  2 - Scan cards (open Wallet & tap card)")
    print("  3 - Enter card hash(es) manually")
    mode = input("Your choice [1]: ").strip()

    hashes = saved_cards
    if mode == "2":
        hashes = capture_card_hashes(device["udid"], saved_cards)
    elif mode == "3":
        manual = input("Enter card hashes separated by commas or spaces: ").strip()
        new_items = [x.strip() for x in re.split(r"[\s,;]+", manual) if len(x.strip()) >= 16]
        for item in new_items:
            if item not in hashes:
                hashes.append(item)
        save_cards(hashes)

    if not hashes:
        print("❌ No cards available to flash.")
        sys.exit(1)

    print(f"\n[3/5] Ready to flash cards ({len(hashes)}):")
    for i, h in enumerate(hashes, 1):
        print(f"  [{i}] {h}")

    print("\nSelect cards to customize:")
    print("  'all' - apply to all cards")
    print("  comma-separated numbers (e.g. 1,3)")
    choice = input("Your choice [all]: ").strip().lower()

    if choice == "" or choice == "all":
        selected_hashes = hashes
    else:
        try:
            indices = [int(x.strip()) for x in choice.split(",") if x.strip()]
            selected_hashes = [hashes[i - 1] for i in indices if 1 <= i <= len(hashes)]
        except Exception:
            print("Invalid input. Applying to all cards.")
            selected_hashes = hashes

    if not selected_hashes:
        print("❌ No cards selected.")
        sys.exit(1)

    # 4. Prepare image
    print(f"\n[4/5] Preparing image...")
    while True:
        img_input = input("Drag and drop image file into terminal (or enter path): ").strip()
        try:
            png_bytes = prepare_card_image(img_input)
            print(f"✅ Image optimized for Apple Wallet ({len(png_bytes)} bytes)")
            break
        except Exception as e:
            print(f"❌ Error: {e}. Please specify another image.")

    # 5. Flash cards
    print(f"\n[5/5] Flashing skin to selected cards ({len(selected_hashes)})...")

    for idx, h in enumerate(selected_hashes, 1):
        print(f"\n--- [{idx}/{len(selected_hashes)}] Card: {h} ---")
        pkpass_dir = f"/var/mobile/Library/Passes/Cards/{h}.pkpass"

        for asset in TARGET_ASSETS:
            ok = write_file(device["udid"], pkpass_dir, asset, png_bytes)
            status = "OK" if ok else "FAIL"
            print(f"  -> {asset}: {status}")

        ok_cache = invalidate_cache(device["udid"], h)
        status = "OK" if ok_cache else "PARTIAL"
        print(f"  -> System cache cleared (.cache & .pkcache): {status}")

    print("\n" + "=" * 60)
    print("🎉 DONE! All selected cards successfully updated!")
    print("=" * 60)
    print("1. Force close Apple Wallet on your iPhone.")
    print("2. If the image does not update immediately, restart your iPhone.")
    print("=" * 60)


if __name__ == "__main__":
    main()
