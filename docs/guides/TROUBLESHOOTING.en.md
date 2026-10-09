# Troubleshooting card artwork, one stage at a time

[Back to the English guide](README.en.md) · [中文](TROUBLESHOOTING.zh-CN.md) · [Multiple cards and partial failures](MULTI-CARD.en.md)

This page follows the macOS GUI and backend in this repository. **Connecting, detecting a card, completing backend writes, and seeing the artwork on the phone are separate results.** Record each one separately. These instructions add no new hardware compatibility claims.

## 1. The iPhone does not connect

| UI or Log message | Check and next step | Passing this stage means |
| --- | --- | --- |
| `No iPhone found. Please connect via USB.` / `No iPhone connected.` | Use a USB data cable, unlock the phone, and confirm **Trust This Computer**. Reconnect and click the refresh button in the connection area. If several devices are connected, leave only the intended iPhone connected first. | `Connected to …` appears, with the expected device model and iOS version. |
| `Device tools are missing from this build.` | This installation lacks an executable `device_helper`. Download the [author's DMG](https://github.com/Mak5er/AirCard/releases/latest) again and copy the complete app into Applications. For source builds, check the [build instructions](https://github.com/Mak5er/AirCard/blob/main/README.md). | The missing-tools message clears and the target phone is detected. |
| `Device detection failed: …` | Keep the specific error at the end. Check whether only part of the app was copied or moved; reinstall the complete release package and retry. | Device detection completes normally. |

A connection is not proof of write compatibility. The backend probes AirLift separately, but the GUI's `Connected` status only reports device detection.

## 2. Connected, but no cards are detected

1. In **Apple Wallet**, click **Scan Cards** and open **Log**.
2. Look for `Connected to the unified device log stream`. This confirms the log connection, **not card detection**.
3. On the iPhone, double-click the side button, authenticate as prompted, and tap the target card. Try switching to another card and back.
4. Look for a new `Found card: …` entry. Cards already shown in the window can be saved records from earlier sessions, so their presence alone does not prove this scan worked.

| Message or symptom | Next step |
| --- | --- |
| `Could not start card scanning.` / `Syslog monitor failed to start: …` | Read the launch error that follows; check that the app package is complete and the phone remains connected, then retry. |
| `Card scanning ended. Check the log and reconnect the iPhone to retry.` | The log process has exited. Record its exit status; reconnect, unlock, refresh the connection, and start another scan. |
| `Card scanning failed. Check the log and retry.` | Read the reason after `Syslog monitor stopped: …`, then reconnect and scan again. |
| Log stream connected, but no new cards | Actually select cards while scanning. Previously saved identifiers are deduplicated and do not generate another `Found card` entry. The scanner cannot recover values iOS hides as `<private>`. |

To exclude saved records, stop scanning, use **Clear All** to clear the Mac's list, and scan again. This neither deletes cards from the iPhone's Wallet nor restores their artwork; see [what the buttons do](MULTI-CARD.en.md#buttons-that-are-easy-to-confuse).

See the [upstream scanner validation record](../wallet-card-detection.md) for the hardware evidence: its iPhone 15 Pro / iOS 18.6.2 test verified detection, not artwork flashing.

## 3. Flash is unavailable, image preparation fails, or framing looks wrong

| Message or symptom | Next step |
| --- | --- |
| **Flash Skins** is disabled, or `Please assign a skin image to at least one selected card.` | At least one card must be both selected and assigned an image. Check the bottom `ready to flash` count and the device connection. |
| A preview was visible, but the original file is now missing | Save the image in a stable folder on the Mac, confirm Preview can open it, and assign it again. The GUI rereads the file when flashing; an old preview does not prove the file is still available. |
| `Image file not found` / `Failed to prepare card artwork` | Export a readable PNG, preferably **1536 × 969**, assign it again, and retry one card first. The latter error can also come from the backend's PNG-to-PDF conversion. |
| Parts of the image are cut off | Native preparation scales to fill and center-crops to **1536 × 969**. Use the [offline artwork tool](../../tools/card-artwork/README.md) to prepare the composition at that size and keep important details away from the edges. |

`Image file not found` is a backend error; the GUI may show only the final failure instead of that exact text. The GUI's image-preparation fallback does not fully check its returned result, so reaching the write stage is not proof that preparation succeeded. Confirm the source file is valid and reassign it before retrying. Native preparation and the Pillow path preserve proportions and crop; the final `sips` fallback directly resizes to the target dimensions and may stretch the image.

## 4. Flashing fails

Open **Log**, find the last `Flashing card [n/total]: …` entry to identify the card's position in the batch, then read the errors after it.

| Message | Meaning and next step |
| --- | --- |
| `Failed to launch card flasher: …` | The flashing process did not launch. Keep the specific error and check installation integrity before retrying. |
| `Card update failed for …` / `Failed to apply card skins.` | This card's backend exited unsuccessfully, or the process did not start. Check earlier preparation, write, and cache messages; restore the connection, reassign the image, and retry only this card. |
| `One or more cards could not be updated. Check the log and try again.` | The batch did not entirely succeed. Earlier cards may already have changed, and the failed card may also have partial writes. |

The backend first tries to write one card's assets as a batch, then falls back to individual files if that fails. This is a **fallback within one card**, not an undo operation across multiple cards. The multi-card queue stops after the first failed card; follow the [partial-failure procedure](MULTI-CARD.en.md#handling-a-failure-partway-through).

## 5. Cache cleanup fails, or the phone still shows the old image

| Message or symptom | Meaning and next step |
| --- | --- |
| `Could not clear Wallet cache (.cache); card was not reported as updated.` | Cache cleanup failed after asset writes; the backend marks the whole card as failed. The equivalent `.pkcache` message means the same thing. Restore the connection, confirm the target card, and retry the complete flow for that card alone. |
| `Successfully updated …`, but the phone shows the old artwork | This is a backend success report and still needs visual confirmation. Following the app's prompt, force-close Wallet from the app switcher and reopen it. If necessary, try restarting the iPhone and record the result. |
| Still wrong after restarting | Record cache errors, whether the intended card was targeted, and whether other cards changed. Submit separate results for each stage; do not guess at a fix by deleting and re-adding a bank card. |

The backend writes PNG/PDF assets and clears rendered files in `.cache` and `.pkcache`. A 100% progress bar alone is not success: check the final result and the phone's display. If a **Restore Original** point was saved on this Mac before the first skin change, use that card's restore button, then force-close Wallet and inspect the phone. The local snapshot remains available for another restore. A restart alone only refreshes Wallet; it does not restore original artwork. Cards changed before a snapshot was captured cannot be reconstructed by AirCard.

## What to include in a report

Copy the [bilingual report template](compatibility-report-template.md) and follow the [compatibility record](COMPATIBILITY.en.md). Provide the AirCard version or commit, iPhone model, iOS and macOS versions; record **connection / detection / backend write / visible result** separately. Include the first relevant error and the result of a one-card retry. Replace card identifiers and device UDIDs with `<redacted>`; do not post complete device logs, full card numbers, or payment details.

## Source and validation references

- [AirCardApp.swift](../../AirCardApp.swift): `checkDevice`, `startCardScanning`, `prepareCardImage`, `applySkin`, and log handling.
- [aircard_backend.py](../../aircard_backend.py): `cmd_device`, `cmd_prepare_image`, `cmd_flash`; [card_assets.py](../../card_assets.py): PNG/PDF assets and cache filenames.
- [Card backend tests](../../tests/test_card_flash.py): mocked asset writes, PDF conversion, and cache failures; [scanner tests](../../tests/test_card_scanner.py): protocol handling and synthetic card paths. Automated checks do not establish real-device write compatibility.
