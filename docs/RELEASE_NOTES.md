# Release notes

## Unreleased

Setup guidance and artwork-resource improvements.

### Requirements

- **macOS 14 (Sonoma) or later**, on Apple Silicon or Intel. The Swift app,
  helper binaries, and app bundle all target macOS 14. macOS 12 (Monterey)
  and 13 (Ventura) cannot run this build.
- An unlocked iPhone connected with a USB data cable and trusted by the Mac.
- The project advertises iOS 18+; success still depends on the device, iOS
  version, and feature. See the [compatibility records](guides/COMPATIBILITY.en.md).

The clearer macOS requirement addresses [#123](https://github.com/Mak5er/AirCard/issues/123)
and [#51](https://github.com/Mak5er/AirCard/issues/51). It does not add support
for older macOS versions.

### Connection help

The device indicator now opens a connection checklist. When no iPhone is
connected, the Wallet empty state shows the same checklist and a Reconnect
button: try a USB data cable, unlock the phone, trust the Mac, and reconnect.
This addresses confusing setup reports in [#126](https://github.com/Mak5er/AirCard/issues/126)
and [#112](https://github.com/Mak5er/AirCard/issues/112).

### Scanning help

The toolbar now explains opening Wallet directly as an alternative to the
side-button workflow and documents the reported transit-card Service Mode
workaround. The help distinguishes Wallet Service Mode from Developer Mode
and repair mode and notes that availability and results vary. See
[#58](https://github.com/Mak5er/AirCard/issues/58) and
[#25](https://github.com/Mak5er/AirCard/issues/25).

### Clearing selections

Card and theme clear controls now explain that they clear this Mac's selections,
not artwork already applied to the phone. The loaded-theme panel also displays
that distinction. No automatic restore feature was added. See
[#95](https://github.com/Mak5er/AirCard/issues/95),
[#56](https://github.com/Mak5er/AirCard/issues/56), and
[#111](https://github.com/Mak5er/AirCard/issues/111).

### Compatibility before flashing

The Wallet workspace now displays the Apple Card rendering limit, unresolved
Apple Cash reports, unverified Apple Watch and Home Key support, and the lack
of automatic restoration before users flash artwork. The compatibility guide
links the supporting reports: [#148](https://github.com/Mak5er/AirCard/issues/148),
[#118](https://github.com/Mak5er/AirCard/issues/118), and
[#10](https://github.com/Mak5er/AirCard/issues/10).

### Artwork tools

The Wallet toolbar now opens the existing offline artwork editor or the
independent AirCards catalog. The editor is bundled with the app and needs no
network connection; export a PNG and choose it as a skin in AirCard. This makes
the existing resources easier to discover without adding a new image engine.
See [#58](https://github.com/Mak5er/AirCard/issues/58),
[#52](https://github.com/Mak5er/AirCard/issues/52), and
[#68](https://github.com/Mak5er/AirCard/issues/68).
