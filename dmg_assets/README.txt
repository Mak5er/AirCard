============================================================
              AirCard · Quick Start Guide
============================================================

1. INSTALLATION:
   Drag and drop the "AirCard" icon into the "Applications" folder.
   Minimum macOS: Ventura 13.0. Supports Apple Silicon (arm64) and Intel (x86_64).

2. FIRST LAUNCH (macOS Gatekeeper):
   Since AirCard is built locally, macOS might show a standard security prompt on first launch.
   
   Method 1 (Recommended):
   Right-click (Control-click) on AirCard in Applications -> click "Open" -> click "Open".
   
   Method 2 (via Terminal):
   sudo xattr -cr /Applications/AirCard.app

3. REQUIREMENTS:
   AirCard includes universal app and native helper binaries. Device communication
   uses Apple's MobileDevice and AirTrafficHost frameworks. Python 3 must be
   available on macOS for backend operations; Xcode/Command Line Tools may be
   needed if macOS prompts to install developer tools.

4. HOW TO USE:
   [Apple Wallet Cards]
   - Connect your iPhone via USB cable and tap "Trust this Computer".
   - Open AirCard (the device status badge will turn green).
   - Click "Scan Cards".
   - On your iPhone, double-click the Side button, pass Face ID, and tap your card.
   - Assign a custom skin image (click or drag & drop onto the card).
   - Click "Flash Skins".
   - Force-close the Wallet app on your iPhone to see your new designs.

   [Passcode Themes (.passthm)]
   - Switch to the "Passcode Themes" tab.
   - Drag & drop a .passthm file (or select one via file picker).
   - Preview the keypad artwork on the interactive mockup.
   - Click "Apply Passcode Theme".
   - Restart your iPhone.
   * NOTE: Supports all system languages (RU, UK, EN, etc.) and Bold Text!

============================================================
Developed by @mak5er & @Lumid-Off
============================================================
