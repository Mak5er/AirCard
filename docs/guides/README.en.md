# AirCard User Guide 🎴

**Give your Apple Wallet cards a look you like.**

[中文](README.zh-CN.md) · English · [Download AirCard](https://github.com/Mak5er/AirCard/releases/latest) · [Card artwork](#card-artwork)

A **Chinese and English getting-started guide with sample artwork**, put together by [BryceYuuu](https://github.com/BryceYuuu) to help first-time users install AirCard and customize Wallet cards. AirCard is developed by [Mak5er](https://github.com/Mak5er/AirCard) and its contributors.

## What does AirCard do?

AirCard is a macOS tool that connects to an iPhone over USB to customize Apple Wallet / Apple Pay card artwork. It also supports lock screen passcode themes (`.passthm`) and theme creation. This guide focuses on **changing Wallet card artwork**.

Artwork changes are visual: an image does not create a bank card or change its payment permissions.

## Card artwork

Community sample artwork, prepared as 1536 × 969 PNGs. Open the Aircards.org links below, then click **Download** on the artwork page.

| American Depress | Apple Card — Soft Gradient |
| :---: | :---: |
| <img src="../../assets/skins/cardboard-credit-card.png" alt="Cardboard-style artwork with Official Credit Card and Trust Me lettering" width="400"> | <img src="../../assets/skins/apple-minimal.png" alt="Apple Card artwork with a soft color gradient" width="400"> |
| [American Depress · Aircards.org](https://aircards.org/en/community/a8b36946ea6940ceaa2ef4de0a01973f/) · 1536 × 969 | [Apple Card — Soft Gradient · Aircards.org](https://aircards.org/en/community/bca7203bbcf551aab8abccc5542bb29f/) · 1536 × 969 |

| American Express® Centurion Card | Trump Gold Card |
| :---: | :---: |
| <img src="../../assets/skins/amex-black.png" alt="Black American Express Centurion Card artwork with a centurion portrait" width="400"> | <img src="../../assets/skins/trump-gold-card.png" alt="Gold Trump Gold Card artwork with a Trump portrait, Statue of Liberty, and eagle" width="400"> |
| [American Express® Centurion Card · Aircards.org](https://aircards.org/en/community/9f9c6f6c7824594a89ffb54378892d4f/) · 1536 × 969 | [Trump Gold Card · Aircards.org](https://aircards.org/en/community/ba9c5d821008524e81b09149880107de/) · 1536 × 969 |

**Dimensions:** All four samples are **1536 × 969**, matching AirCard's output size. Check the preview before flashing. See the [artwork notes and community sources](../../assets/skins/README.md) for attribution and image preparation details.

## Before you start

| Item | Details |
| --- | --- |
| Computer | A Mac; upstream provides a universal DMG for Apple Silicon and Intel |
| Phone | An iPhone; upstream advertises iOS 18+ without a jailbreak, but results depend on the device and OS version |
| Connection | A USB data cable; keep the iPhone unlocked and trust the Mac |
| Card | A card already added to Apple Wallet |
| App | Download `AirCard.dmg` from the [original releases page](https://github.com/Mak5er/AirCard/releases/latest); the DMG needs no separate Homebrew or Python installation |

This guide was checked against **AirCard v1.2.6** on **2026-10-04**. The upstream README reports testing on iOS 27; that is not a guarantee for every device. No additional hardware compatibility testing was performed for this guide.

## Change your card artwork in five steps

### 1. Install AirCard

Open the [official download page](https://github.com/Mak5er/AirCard/releases/latest) and download `AirCard.dmg` under **Assets**. Open it, drag `AirCard.app` into **Applications**, and launch the app.

If macOS blocks the first launch, verify that the file came from the original repository above, then follow the [upstream installation instructions](https://github.com/Mak5er/AirCard/blob/main/README.md#installation).

### 2. Connect your iPhone

Connect the iPhone to the Mac with a USB data cable. Unlock it, choose **Trust This Computer** if prompted, and enter the device passcode.

### 3. Scan your existing cards

In AirCard, open **Apple Wallet** and click **Scan Cards**. On the iPhone:

1. Double-click the side button to open Apple Pay.
2. Authenticate as prompted, for example with Face ID.
3. Tap the card you want to customize. If necessary, tap again or switch to another card and back.

Wait for the card to appear in AirCard on the Mac.

### 4. Choose an image

Download any PNG above. Click the target card in AirCard to select an image, or drag the image directly onto it. Check the preview and make sure you selected the intended card. You can assign a different image to each card.

### 5. Apply and refresh

Click **Flash Skins** and wait for completion. Force-close **Wallet** from the iPhone app switcher, then reopen it. If the artwork has not refreshed, try restarting the iPhone.

## Go further

| Task | Guide |
| --- | --- |
| Resolve connection, scanning, flashing, or refresh failures | [Troubleshooting by stage](TROUBLESHOOTING.en.md) |
| Manage multiple cards, change phones, or handle interrupted batches | [Multi-card workflows and failure handling](MULTI-CARD.en.md) |
| Build a passcode theme from a poster or individual key images | [Complete Theme Creator guide](THEME-CREATOR.en.md) |
| Check the verified scope or report a device test | [Compatibility records](COMPATIBILITY.en.md) · [Report template](compatibility-report-template.md) |
| Frame an image and export correctly sized card artwork | [Offline card artwork editor](../../tools/card-artwork/README.md) |

## Frequently asked questions

### No cards found?

Check the data cable, unlock the iPhone, and confirm that it trusts the Mac. While scanning, authenticate on the phone and actually tap or switch cards. If scanning stops, reconnect, unlock, and scan again.

Open **Log** and look for `Connected to the unified device log stream`. The scanner cannot recover values hidden by iOS as `<private>`. The [upstream scanner validation notes](../wallet-card-detection.md) describe the tested scope: the iPhone 15 Pro / iOS 18.6.2 test verified card detection, not artwork flashing.

### Why is my image cropped?

AirCard center-crops to a landscape card shape. Prepare artwork at **1536 × 969**, or the same aspect ratio, and keep important text and graphics near the center. The sample images retain their original dimensions so you can adjust the composition yourself.

### Can I restore the original card artwork with one click?

The current app does not provide a one-click restore workflow. **The × at the top right of a card (Remove skin)** only clears the image selected on the Mac; it does not restore artwork on the iPhone. If restoration is essential to you, check the current upstream documentation before applying a skin.

### Can I use Windows or run this directly on an iPhone?

This guide covers the upstream **macOS DMG with an iPhone connected over USB**. It does not provide a Windows or standalone iPhone installation workflow.

### How do passcode themes work?

Open **Passcode (.passthm)**, import a `.passthm` file, review the preview, and click **Flash Passcode Theme**. Restart the iPhone when it finishes. The PNGs here are card artwork, not `.passthm` theme packages. See the [original upstream README](https://github.com/Mak5er/AirCard/blob/main/README.md) for theme creation and source-build instructions.

## Updates, feedback, and credits

- **Downloads and updates:** [Mak5er/AirCard Releases](https://github.com/Mak5er/AirCard/releases). App installers are published by the original project.
- **Application issues:** check [upstream Issues](https://github.com/Mak5er/AirCard/issues). Include your iPhone model, iOS, macOS, AirCard version, and a short error message. Do not post full device logs or card identifiers.
- **Guide and artwork curation:** [BryceYuuu](https://github.com/BryceYuuu); the standalone guide repository is [AirCard-Guide](https://github.com/BryceYuuu/AirCard-Guide).
- **Original development:** [Mak5er](https://github.com/Mak5er), [Lumid-Off](https://github.com/Lumid-Off), and [0xjohnny](https://github.com/0xjohnnydev), author of the underlying [AirLift](https://github.com/0xjohnnydev/airlift). You can star the [original project](https://github.com/Mak5er/AirCard) or use the [author's support links](https://github.com/Mak5er/AirCard/blob/main/README.md#support) to support development.

Upstream code is covered by the [MIT License](../../LICENSE), with its copyright notice preserved. The added artwork was supplied by [BryceYuuu](https://github.com/BryceYuuu) and is not automatically covered by the code's MIT license; see the [artwork notes](../../assets/skins/README.md). This guide and its sample artwork are not official Apple or bank products.
