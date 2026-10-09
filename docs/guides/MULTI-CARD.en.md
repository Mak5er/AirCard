# Multiple cards and partial failures

[Back to the English guide](README.en.md) · [中文](MULTI-CARD.zh-CN.md) · [Troubleshooting by stage](TROUBLESHOOTING.en.md)

These instructions describe the current GUI and backend code, not hardware testing across every iPhone / iOS combination. On a first attempt, complete the flow with one card whose identity you have confirmed before expanding to several cards.

## What the card list remembers

AirCard saves **internal card identifiers**, not payment card numbers or a live inventory of the phone's Wallet. It loads saved records from the Mac at startup, then appends and saves newly detected identifiers during scanning.

| Item | After closing and reopening the app |
| --- | --- |
| Card identifiers and list order | Saved; records from older versions may also be imported. |
| Selection state | Not saved; loaded cards start selected. |
| Assigned images, image paths, and previews | Not saved; assign them again. Keep the source files on the Mac. |
| Association with a specific iPhone | Not grouped by device; the old list is not an inventory of a newly connected phone. |

**Card #1 / #2** are list positions, not bank names, payment card numbers, or reliable Wallet ordering. Do not infer identity from the number alone. During scanning, select one card at a time and watch for new entries; if the mapping is uncertain, resolve it before flashing. Do not copy identifiers from someone else's screenshot into **Add Manually**.

The code saves identifiers in `UserDefaults` and `~/.aircard_cards.json`, and also reads the legacy `~/.lumicards_cards.json`. Original card artwork is separately saved under `~/Library/Application Support/AirCard/OriginalCardSkins` on this Mac, with restrictive local file permissions and separate backups per iPhone/card. Keep this Mac and its AirCard support files if you may want to restore a card later.

An original restore point is captured before the first skin change made by a build with restore support. Cards already changed by an older build or another tool cannot be safely identified or reconstructed; their current files might already contain custom artwork. AirCard warns before flashing, and known previously flashed cards without a restore point are not mislabeled as backed up.

## Assign different images to different cards

1. Check that the connection area identifies the intended iPhone. Stop scanning to keep the list stable for this batch.
2. Click **Deselect All**, then select the target cards individually.
3. Click each card or drop an image onto it to assign separate artwork. **Assigning an image automatically selects that card**, so check the selections again afterward.
4. Check the bottom `ready to flash` count and **Flash Skins (N Cards)**. Only cards that are **selected and have an assigned image path** enter the batch.
5. Confirm the source images still open normally, then click **Flash Skins**. Inspect each card on the iPhone after completion.

For example, if A is selected with an image, B is selected without an image, and C has an image but is unselected, only A is processed. `ready to flash` means those configuration conditions are met; it does not validate the image or confirm successful phone writes.

## Use one image on several cards

Select the target cards and click **Set Skin for All…** to choose an image. “All” means **currently selected cards**. Unselected cards are not assigned the image, and their previous image assignments are not cleared.

For every card, use **Select All** before **Set Skin for All…**. For just two cards, use **Deselect All** and select those two first. Recheck `ready to flash` afterward.

## Buttons that are easy to confuse

| Action | What it actually does |
| --- | --- |
| Uncheck a card / **Deselect All** | Excludes cards from the next batch; assigned images remain in the current session. |
| Top-right × / **Remove skin** | Clears that card's pending image and path on the Mac; does not write original artwork to the phone. |
| **Restore Original** | Enabled when this Mac has a complete saved restore point. Writes the saved card artwork back and clears Wallet's rendered caches; confirm the prompt, then force-close Wallet on the iPhone. |
| Trash icon / **Remove from list** | Removes and saves the Mac's list entry; does not delete the payment card from the phone. |
| **Clear All** on the Apple Wallet tab | Clears and saves the Mac's current card list; does not delete Wallet cards, clear phone caches, or restore artwork. Stop scanning first when refreshing the list, since new log events can still append cards. |
| **Stop Scanning** | Stops the card-detection log process; it is not a stop-flashing or undo button. |

This table applies to **Apple Wallet**, not similarly named controls in the passcode theme creator.

## Handling a failure partway through

Eligible cards are processed in list order. **If a card's flashing process cannot launch or exits unsuccessfully, the batch stops before later cards. Earlier writes are not automatically rolled back.** A failed card may also contain some files that were already written.

For A → B → C, if A succeeds and B fails: A may already have changed, B needs inspection, and C has not been processed. The overall failure message does not mean that nothing changed.

1. In **Log**, find the last `Flashing card [n/total]` before failure, its error, and any preceding `Successfully updated …` entries. Do not rely on the progress percentage alone.
2. Address the connection, image, or cache issue using the [troubleshooting guide](TROUBLESHOOTING.en.md). Keep the original image files.
3. Click **Deselect All**, select only the failed card, confirm its image again, and retry. You do not need to reflash every card already reported as successful.
4. After that card succeeds, select the unprocessed cards and continue. Image assignments remain during the same session; after restarting the app, assign them again.
5. Close and reopen Wallet on the iPhone and inspect every card. If necessary, try restarting the phone and record the result; a restart does not guarantee restoration of old artwork.

The backend first tries a batch write of **one card's asset files**, then retries individual files if needed, followed by cleanup of two Wallet cache types. Restore uses the exact PNG/PDF files saved before the first supported skin change; the snapshot stays on this Mac after restoration. The restore operation is not a transaction and can still fail partway through. Deleting a payment card from Wallet is not a recovery step in this guide.

## Source and validation references

- [AirCardApp.swift](../../AirCardApp.swift): `CardItem`, `loadSavedCards`, `saveCards`, `setCardImage`, `clearAllCards`, `openBulkImagePicker`, `readyToFlashCount`, and `applySkin`.
- [aircard.py](../../aircard.py): `get_connected_device` chooses an available device; [aircard_backend.py](../../aircard_backend.py): `cmd_flash` asset writes, cache cleanup, and exit results.
- [Card backend tests](../../tests/test_card_flash.py) check that mocked write or cache failures do not report success. The multi-card stopping and persistence rules were checked in Swift source; this page does not present them as real-device validation.
