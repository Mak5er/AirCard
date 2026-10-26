SUPPORTED = "supported"
PATCHED = "patched"
TOO_OLD = "too_old"
UNKNOWN = "unknown"

MIN_SUPPORTED_RELEASE = (18, 0, 0)
TRANSITION_RELEASE = (27, 2, 0)
FIRST_PATCHED_RELEASE = (27, 2, 1)

PATCHED_BUILDS = frozenset()
SUPPORTED_BUILDS = frozenset()

_STATUS_META = {
    SUPPORTED: {
        "label": "Supported",
        "can_flash": True,
    },
    PATCHED: {
        "label": "Patched by Apple",
        "can_flash": False,
    },
    TOO_OLD: {
        "label": "Unsupported (too old)",
        "can_flash": False,
    },
    UNKNOWN: {
        "label": "Unverified",
        "can_flash": None,
    },
}


def parse_version(version):
    if not version:
        return None
    text = str(version).strip()
    if not text:
        return None
    head = text.split("-", 1)[0].split(" ", 1)[0]
    parts = head.split(".")
    numbers = []
    for part in parts:
        if not part.isdigit():
            if not numbers:
                return None
            break
        numbers.append(int(part))
    if not numbers:
        return None
    while len(numbers) < 3:
        numbers.append(0)
    return tuple(numbers[:3])


def _message(status, version, build):
    shown = version or "this version"
    if status == SUPPORTED:
        return "iOS {} supports flashing Wallet skins via the airlift sync mechanism.".format(shown)
    if status == PATCHED:
        return (
            "Apple closed the airlift sync mechanism in iOS {}. "
            "Flashing Wallet skins is not possible on this iOS version. "
            "This cannot be fixed in the app; it requires an unpatched iOS version."
        ).format(shown)
    if status == TOO_OLD:
        return "iOS {} is older than the supported range (iOS 18.0 and newer).".format(shown)
    return (
        "iOS {} could not be classified automatically. "
        "iOS 27.2 betas 1-2 can flash, but 27.2 beta 3 and newer are patched; "
        "the beta is not visible from the version number alone. A flash attempt will confirm."
    ).format(shown)


def classify_ios(version, build=None):
    parsed = parse_version(version)
    normalized_build = str(build).strip() if build else ""

    if parsed is None:
        status = UNKNOWN
    elif parsed < MIN_SUPPORTED_RELEASE:
        status = TOO_OLD
    elif parsed >= FIRST_PATCHED_RELEASE:
        status = PATCHED
    elif parsed == TRANSITION_RELEASE:
        if normalized_build and normalized_build in PATCHED_BUILDS:
            status = PATCHED
        elif normalized_build and normalized_build in SUPPORTED_BUILDS:
            status = SUPPORTED
        else:
            status = UNKNOWN
    else:
        status = SUPPORTED

    meta = _STATUS_META[status]
    return {
        "status": status,
        "label": meta["label"],
        "can_flash": meta["can_flash"],
        "message": _message(status, version, normalized_build),
        "version": version or "",
        "build": normalized_build,
    }


_ERROR_RULES = [
    (
        ("device_helper_missing", "command line tools", "xcode-select"),
        "tools_missing",
        "Device tools are missing",
        "AirCard needs Apple's device tools to talk to the iPhone. Open Terminal and run 'xcode-select --install', then reconnect.",
    ),
    (
        ("no_device", "no device found", "no iphone"),
        "no_device",
        "No iPhone found",
        "No iPhone was detected. Connect it with a cable and make sure it is powered on.",
    ),
    (
        ("locked", "passcode", "please unlock", "is locked"),
        "locked",
        "iPhone is locked",
        "Unlock the iPhone and keep the screen on, then try again.",
    ),
    (
        ("trust", "pairing", "not paired", "validatepairing", "pair record"),
        "not_trusted",
        "iPhone is not trusted",
        "Tap 'Trust' on the iPhone when the prompt appears, then reconnect. Unlock it first if needed.",
    ),
    (
        ("patched", "airlift", "airtraffic", "targetgate", "operation not permitted on link"),
        "patched",
        "iOS version is patched",
        "Apple closed the mechanism AirCard uses on this iOS version, so flashing is not possible here.",
    ),
    (
        ("wallet not open", "open wallet", "wallet is closed", "no cards detected"),
        "wallet_closed",
        "Open Wallet on the iPhone",
        "Open the Wallet app on the iPhone and scan the cards, then try again.",
    ),
]


def humanize_error(raw, context=None):
    text = (raw or "").strip()
    low = text.lower()
    for keywords, code, title, message in _ERROR_RULES:
        for key in keywords:
            if key in low:
                return {"code": code, "title": title, "message": message, "raw": text}
    fallback_title = "Something went wrong"
    if context == "flash":
        fallback_title = "Flashing failed"
    elif context == "scan":
        fallback_title = "Scanning failed"
    return {
        "code": "unknown",
        "title": fallback_title,
        "message": text or "An unexpected error occurred. See the log for details.",
        "raw": text,
    }
