# AirCard 🎴

> **Apple Wallet Card Skinner & Lockscreen Passcode Themer (No Jailbreak Required)**  
> **Supports iOS 18.0 – 27.0.1 & iOS 27.2 beta 1–2** (iOS 27.2 beta 3+ patched)  
> Powered by the `airlift` AirTraffic sync exploit.

<p align="left">
  <a href="https://www.paypal.com/donate/?hosted_button_id=98QRTC2HFRA4Y"><img src="https://img.shields.io/badge/Donate-PayPal-00457C?style=flat-square&logo=paypal" alt="Donate with PayPal" /></a>
</p>

---

## Compatibility

| iOS Version | Status | Notes |
| :--- | :--- | :--- |
| **iOS 18.0 – 27.0.1** | ✅ Supported | Full support for Wallet skins and Lockscreen passcode themes |
| **iOS 27.2 beta 1 – beta 2** | ✅ Supported | Working |
| **iOS 27.2 beta 3+** | ❌ Patched | Apple patched the underlying `airlift` exploit. Flashing will not work. |

> [!IMPORTANT]
> Do not update to **iOS 27.2 beta 3 or newer** if you want to continue using AirCard. The underlying AirTraffic sync exploit was patched by Apple in beta 3.

---

## Features
- 🎨 **Custom Card Skins:** Assign custom artwork, textures, or bank logos to Apple Pay and Wallet cards.
- 🔢 **Lock Screen Passcode Themes (.passthm):** Apply custom keypad button artwork from popular `.passthm` themes directly to iOS 18+ lockscreen.
- 🧩 **Passcode Theme Creator:** Create custom themes from a single wallpaper (Seamless Poster Slicing) or build key-by-key (Individual Keys).
- 🔍 **Interactive Photo Framing:** Pan and zoom artwork directly inside keypad buttons with real-time iPhone preview.
- ✏️ **Edit Existing .passthm Themes:** Open any Cowabunga or Nugget theme package directly in the creator, tweak button artwork, reposition photos, and re-export or flash.
- ⚡ **Per-Card & Bulk Customization:** Set unique artwork for each card or apply one design across all cards with a single click.
- ↩️ **Restore Original Card Artwork:** AirCard saves a local restore point before its first supported skin change and can write that artwork back to the iPhone.
- 📱 **Zero-Hassle Card Detection:** Tap any card in your iPhone's Wallet app to detect its hash in real-time.
- 🚀 **100% Standalone (Universal):** Native support for both **Apple Silicon** and **Intel (x86)** Macs. All required device-communication utilities and image engines are pre-bundled inside the app.
- 📦 **Zero Prerequisites:** No Homebrew, Python packages, or terminal setup required for macOS users.

---

## Guides and sample artwork

Wallet setup, detailed troubleshooting, multi-card workflows, theme creation, compatibility reporting, and local artwork preparation:

- [简体中文使用指南](docs/guides/README.zh-CN.md)
- [English getting-started guide](docs/guides/README.en.md)
- [Card artwork and source notes](assets/skins/README.md)
- [Offline card artwork editor](tools/card-artwork/README.md) — download a single HTML file, frame an image locally, and export a 1536 × 969 PNG

---

## Installation

### macOS 13 or later (Universal DMG)
1. Download **`AirCard.dmg`** from [Releases](https://github.com/mak5er/AirCard/releases).
2. Open `AirCard.dmg` and drag **`AirCard.app`** into your **Applications** folder.
3. AirCard's minimum supported macOS version is **macOS Ventura 13.0**. The app and bundled native helpers include **Apple Silicon (arm64)** and **Intel (x86_64)** binaries.

> [!WARNING]
> Restore points are captured on the first skin change made by a build with this feature. If a card was already modified by an older AirCard build or another tool, its previous original artwork cannot be reconstructed; do not treat the currently installed artwork as the original.

> [!NOTE]
> The macOS 13.0 deployment target was built and checked on an Intel Mac running macOS 13.7.8. This verifies that the app and native helpers can run on that OS; it does not establish that every iPhone connection, scanning, or flashing workflow works on every macOS 13 device. AirCard uses Apple's private `MobileDevice` and `AirTrafficHost` frameworks for device communication.

> [!NOTE]
> **First Launch on macOS (Gatekeeper):**
> If macOS displays an unidentified developer prompt on first launch:
> - **Method 1 (UI):** Right-click (or Control-click) `AirCard.app` in Applications ➔ click **Open** ➔ click **Open**.
> - **Method 2 (Terminal):**
>   ```sh
>   sudo xattr -cr /Applications/AirCard.app
>   ```

> [!TIP]
> **macOS Developer Tools / Python Requirement:**
> AirCard uses macOS native Python 3 (`/usr/bin/python3`). If macOS prompts that Developer Tools are required or if you recently installed/updated Xcode:
> - Install Command Line Tools: `xcode-select --install`
> - Accept Xcode license if applicable: `sudo xcodebuild -license accept`

> [!NOTE]
> **Windows users:** an unofficial Windows port is available at [**AirCard-Windows**](https://github.com/Lumid-Off/AirCard-Windows).

---

## How to Customize Apple Wallet Cards
1. Connect your iPhone to your Mac via USB cable and ensure it is unlocked and trusted.
2. In AirCard, stay on the **Wallet Cards** tab and click **Scan Cards**.
3. On your iPhone:
   - **Double-click the Side (Power) button** to open Apple Pay.
   - Authenticate with **Face ID**.
   - **Tap your card** (or tap it once more) to trigger instant detection!
4. Click on any card mockup or drag & drop an image directly onto the card.
5. Click **Flash Skins**.
6. Force-close the **Wallet** app on your iPhone from the App Switcher (or reboot) to see your new custom card design!

> [!NOTE]
> **Apple Card:**
> The Apple Card (titanium/digital card) uses dynamic vector rendering based on your spending categories instead of static cached card skins. Custom skins apply to standard debit/credit cards, transit cards, and passes.

### Card names and missing-card checks

Scanned cards can now display names from this Mac's Wallet cache. Open **Check
missing cards** to distinguish current-scan matches from membership entries and
payment caches that still need confirmation. Use **Reconnect** for connection
problems and **Read Cache** to reread local metadata.

For payment cards, AirCard uses the NFC activation event for the card you
actually open. Wallet may also request artwork for several cards; IDs observed
in those current iPhone log paths can appear in a batch. Once a live ID matches
one specific remote-device cache, the remaining payment IDs from that same
cache are included so cards omitted by iOS logging still appear. Saved IDs from
an earlier run remain hidden until the current scan matches them again.

Cards and skin file paths are saved by ID separately for each iPhone, in stable
local discovery order. Only IDs matched during the current scan, either live or
through the live-ID-matched device cache, are shown or eligible to flash; saved
records only restore their skin after revalidation.
Cache counts are not the phone's total, and phone Wallet order is not synchronized. See
[card identification and diagnostics](docs/wallet-discovery.md).
### If scanning finds no cards

The scanner uses the iPhone's unified log service, including Info/Debug events.
On iOS 18.6.2, the legacy log service can show Wallet activity while omitting the
resource lookup messages that contain card identifiers.

Open **Log** and check for `Connected to the unified device log stream`, then
double-click the side button, authenticate, and tap or switch cards. If the log
reader stops, reconnect and unlock the iPhone, then start another scan. Values
that iOS replaces with `<private>` cannot be recovered by the scanner.

If your device previously connected but scanning found zero cards, please try
this build and report whether it helps. Include your iPhone model, iOS version,
macOS version, and the AirCard version or commit tested. Avoid posting full
device logs or card identifiers. See [scanner validation](docs/wallet-card-detection.md)
for the verified environment and remaining coverage.

---

## How to Apply Lockscreen Passcode Themes (.passthm)
1. Switch to the **Passcode Themes** tab at the top of AirCard.
2. Drag & drop any `.passthm` file into the app (or click **Choose .passthm File**).
3. AirCard will inspect the theme and display an interactive preview on the numeric keypad (0–9, *, #).
4. Click **Apply Passcode Theme**.
5. Restart your iPhone to reload the lock screen cache and see your custom passcode buttons!

> [!TIP]
> **Universal Language & Bold Text Support:**  
> AirCard automatically expands and flashes custom keypad assets for all system locales (English, Ukrainian, Russian, Spanish, German, French, etc.) and generates both standard and **Bold Text** cache bitmaps (`--white` and `--white-bold`), ensuring your theme works regardless of your iOS language or accessibility display settings!

---

## Community Resources

- [AirCards](https://aircards.org/) — A free, independently maintained
  card artwork catalog and sharing community. Browse, filter, and
  preview designs, download PNG artwork to use with AirCard, or
  publish your own creations for others to discover and use.

These resources are maintained by the community and are not affiliated
with the AirCard project.

---

## Building from Source

```sh
git clone https://github.com/mak5er/AirCard.git
cd AirCard
chmod +x build.sh
./build.sh
```
This builds universal app and helper binaries (`arm64` + `x86_64`) with a macOS 13.0 minimum, bundles dependencies into `build/AirCard.app`, and outputs `build/AirCard.dmg`. The build requires macOS, Xcode or Command Line Tools (including `swiftc`, `clang`, `lipo`, and `codesign`), Python 3 for app operation, and the system's private MobileDevice/AirTrafficHost frameworks. `create-dmg` is optional; without it, the build uses `hdiutil`.

---

## Contributors
- **[@mak5er](https://github.com/mak5er)** (Developer) — [GitHub](https://github.com/mak5er) · [Twitter / X](https://x.com/mak5er)
- **[@Lumid-Off](https://github.com/Lumid-Off)** (Contributor & Developer) — [GitHub](https://github.com/Lumid-Off) · [Twitter / X](https://x.com/LumidOff)
- **[AirLift](https://github.com/0xjohnnydev/airlift)** by **[0xjohnny (@0xjohnnydev)](https://github.com/0xjohnnydev)**: Original AirTraffic/ATAirlock sandbox escape and proof of concept underlying `AirliftFFI`.

## Credits
- Core exploit based on `airlift` (AirTraffic sync escape).

---

## Support

If you find AirCard useful, you can support future development:

- **PayPal**: [Donate via PayPal](https://www.paypal.com/donate/?hosted_button_id=98QRTC2HFRA4Y)
- **TON**: `UQBm9KPhtMw-XVVjirUoa09wzrlyWsbeZhKfefl1Uw-qNZ-r`
- **USDT (TRC20)**: `TDkDMCyjYxgvkWUnQiF5Erk2RyPQMT6G1n`
- **USDT / BNB (BEP20)**: `0x0954dc491c502849d04956ef74634aa5931a08e8`
