"""Read local Wallet metadata without treating the Mac cache as a phone inventory."""
from __future__ import annotations

import json
import plistlib
import re
from datetime import datetime, timezone
from pathlib import Path

CARD_ID = re.compile(r"[-A-Za-z0-9_+=]{20,64}\Z")


def decode_archive(data: bytes):
    archive = plistlib.loads(data)
    objects = archive["$objects"]
    if not isinstance(objects, list) or len(objects) > 100000:
        raise ValueError("Invalid archive object table")

    def resolve(value, trail=()):
        if len(trail) > 40:
            raise ValueError("Archive nesting limit")
        if isinstance(value, plistlib.UID):
            index = value.data
            if index in trail or not 0 <= index < len(objects):
                raise ValueError("Invalid archive reference")
            return resolve(objects[index], trail + (index,))
        if isinstance(value, dict):
            if "NS.objects" in value:
                values = [resolve(v, trail) for v in value["NS.objects"]]
                if "NS.keys" in value:
                    return dict(zip([resolve(k, trail) for k in value["NS.keys"]], values))
                return values
            return {k: resolve(v, trail) for k, v in value.items() if not k.startswith("$")}
        if isinstance(value, list):
            return [resolve(v, trail) for v in value]
        return None if value == "$null" else value

    return resolve(archive["$top"]["root"])


def read_limited(path: Path) -> bytes:
    with path.open("rb") as stream:
        data = stream.read(16 * 1024 * 1024 + 1)
    if len(data) > 16 * 1024 * 1024:
        raise ValueError("Cache exceeds read limit")
    return data


def card(identifier, name, source, activation_id=None):
    if not isinstance(identifier, str) or not CARD_ID.fullmatch(identifier):
        return None
    result = {"id": identifier, "name": name.strip()[:200] if isinstance(name, str) and name.strip() else "未命名卡片", "source": source}
    if isinstance(activation_id, str) and re.fullmatch(r"[A-Fa-f0-9]{10,64}", activation_id):
        result["activationID"] = activation_id.upper()
    return result


def unique_cards(rows):
    result = {}
    for row in rows:
        if row is not None:
            result.setdefault(row["id"], row)
    return list(result.values())


def payment_card(data):
    application = data.get("primaryPaymentApplication")
    activation_id = application.get("applicationIdentifier") if isinstance(application, dict) else None
    return card(data.get("passID"), data.get("displayName") or data.get("organizationName"), "payment", activation_id)


def build_catalog(root: Path, confirmed_ids: list[str], product: str) -> dict:
    confirmed = set(confirmed_ids)
    result = {"paymentStatus": "unavailable", "payments": [], "memberships": [], "warnings": [], "cacheUpdatedAt": None}
    archive_path = root / "RemoteDevices.archive"
    try:
        devices = decode_archive(read_limited(archive_path))
        if not isinstance(devices, list):
            raise ValueError("Invalid device list")
        candidates = []
        for device in devices:
            if not isinstance(device, dict) or device.get("modelIdentifier") != product:
                continue
            instruments = device.get("remotePaymentInstruments")
            if not isinstance(instruments, list):
                continue
            rows = unique_cards(payment_card(p)
                                for p in instruments if isinstance(p, dict))
            candidates.append(rows)
        matching = [rows for rows in candidates if confirmed.intersection(p["id"] for p in rows)]
        if len(matching) == 1:
            result["paymentStatus"] = "matched"
            result["payments"] = matching[0]
        elif len(matching) > 1:
            result["paymentStatus"] = "ambiguous"
            result["warnings"].append("有多个缓存设备与这些卡片匹配。已暂停显示支付卡片名称和未检测卡片计数。")
        elif len(candidates) == 1:
            result["paymentStatus"] = "matched"
            result["payments"] = candidates[0]
        elif len(candidates) > 1:
            result["paymentStatus"] = "ambiguous"
            result["warnings"].append("存在多台相同型号的缓存设备。请激活一张支付卡以识别正确的钱包缓存。")
        else:
            result["paymentStatus"] = "unmatched"
            result["warnings"].append("请在已连接的 iPhone 上扫描一张支付卡以匹配其缓存。若未匹配，也可能意味着 Mac 缓存不可用或已过期。")
        result["cacheUpdatedAt"] = datetime.fromtimestamp(archive_path.stat().st_mtime, timezone.utc).isoformat()
    except (OSError, ValueError, KeyError, TypeError, IndexError, OverflowError, RecursionError, plistlib.InvalidFileException):
        result["warnings"].append("无法读取支付缓存。扫描功能仍可使用；请重新连接 iPhone 并点击“读取缓存”重试。")

    try:
        entries = list((root / "Cards").iterdir())
    except OSError:
        entries = []
        result["warnings"].append("无法读取凭证与会员卡缓存。请在 iPhone“钱包”应用中打开卡片直接扫描。")
    unreadable = False
    for entry in sorted(entries, key=lambda p: p.name):
        if entry.suffix != ".pkpass" or entry.is_symlink() or not CARD_ID.fullmatch(entry.stem):
            continue
        path = entry / "pass.json"
        if path.is_symlink():
            continue
        try:
            data = json.loads(read_limited(path))
            if not isinstance(data, dict):
                raise ValueError("Invalid pass metadata")
            if not any(key in data for key in ("generic", "storeCard", "boardingPass", "eventTicket", "coupon")):
                continue
            labels = [data.get("organizationName"), data.get("description")]
            name = " · ".join(dict.fromkeys(label.strip() for label in labels if isinstance(label, str) and label.strip()))
            row = card(entry.stem, name, "membership")
            if row:
                result["memberships"].append(row)
        except (OSError, ValueError, TypeError):
            unreadable = True
    if unreadable:
        result["warnings"].append("部分凭证与会员卡元数据无法读取。缓存列表可能不完整。")
    result["memberships"] = unique_cards(result["memberships"])
    return result


def main():
    import sys
    request = json.load(sys.stdin)
    ids = request.get("confirmedIDs", [])
    product = request.get("product", "")
    if not isinstance(ids, list) or not all(isinstance(x, str) for x in ids) or not isinstance(product, str):
        raise ValueError("Invalid catalog request")
    print(json.dumps(build_catalog(Path.home() / "Library/Passes", ids, product), ensure_ascii=False))


if __name__ == "__main__":
    main()
