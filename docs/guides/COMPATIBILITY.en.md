# Compatibility records and reporting

[Back to English guide](README.en.md) · [简体中文](COMPATIBILITY.zh-CN.md) · [Theme Creator](THEME-CREATOR.en.md) · [Copy a report template](compatibility-report-template.md)

Record evidence for each stage instead of assigning one “supported/unsupported” label to a device. A successful connection does not establish that card scanning works; successful scanning does not establish that artwork can be flashed or displayed on the phone. This guide adds no new physical-device testing.

## Documented validation with a defined scope

The following comes from the repository's [Wallet card detection validation record](../wallet-card-detection.md). It is an upstream test record, not a new test by this guide's author.

| Feature / device | iOS | Mac / macOS | AirCard baseline | USB connection | Wallet scanning | Artwork flashing | Artwork displayed on phone |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Wallet cards / iPhone 15 Pro (`iPhone16,1`) | 18.6.2 | MacBook Air M3 (2024) / 26.6.2 | 1.2.3, `02b5ba8` (see below) | Successful | Successful after the scanner change; eight identifiers detected, and the tester confirmed cards appeared | **Not tested** | **Not tested** |

The validation document labels `02b5ba8` as the **Source baseline** and describes results after the scanner change. It does not separately provide the complete commit of the modified build that was tested; do not infer that the unchanged baseline produces the same result. It also records that stopping the helper reset the scanning UI and a subsequent scan connected without losing detected cards.

The original report's macOS 26.2 screenshot is not the final validated environment. Do not mark 26.2 as verified. No card artwork was flashed during that detection test, and passcode themes were not tested.

## Upstream claims and unverified cases

| Item | Evidence available | How to interpret it |
| --- | --- | --- |
| iOS 18.0 – 27.0.1 & 27.2 b1–b2 | Project description in the [upstream README](https://github.com/Mak5er/AirCard/blob/main/README.md) | Verified working range for Wallet skins & passcode themes |
| iOS 27.2 beta 3+ | Patched upstream by Apple | The underlying `airlift` AirTraffic sync exploit is patched. Flashing fails. |
| iPhone 17 / iOS 27 report | The [detection validation record](../wallet-card-detection.md) links to [issue #28](https://github.com/Mak5er/AirCard/issues/28) and explicitly marks that case untested | The record does not verify that combination; another iOS 27 statement does not establish success for this case. |
| Apple Silicon / Intel Macs | The [upstream README](https://github.com/Mak5er/AirCard/blob/main/README.md) states that a universal build is provided | Build architecture coverage does not verify every Mac/macOS combination with a device. |
| iOS 14–17 / Universal passcode targets | [UI and target-selection logic](../../AirCardApp.swift) | Cache-directory options are not compatibility evidence. See [theme target settings](THEME-CREATOR.en.md#before-flashing-language-bold-text-and-target). |

**Not tested** means evidence is missing; it means neither success nor lack of support. Keep features separate. Exporting a theme on the Mac does not count as successfully flashing an iPhone.

## Known limits and open reports

Read these before flashing. Reports describe particular users' results, not a
complete compatibility matrix.

| Card / destination | Current guidance |
| --- | --- |
| Apple Card | Uses dynamic artwork instead of the static skin assets AirCard writes, as explained in the [README](../../README.md#how-to-customize-apple-wallet-cards). |
| Apple Cash | Unresolved; [#148](https://github.com/Mak5er/AirCard/issues/148) reports that artwork could not be changed. Do not assume Apple Card's rendering explanation also applies to Apple Cash. |
| Apple Watch | No confirmed support for syncing these skins to the Watch. [#118](https://github.com/Mak5er/AirCard/issues/118) reports iPhone success without a Watch update. |
| Home Key | No confirmed skin support. [#10](https://github.com/Mak5er/AirCard/issues/10) reports a success message without a visible artwork change. |

The Wallet workspace shows this guidance before the flash action. Completion
of a write still requires checking the result in Wallet. Clearing a skin or
theme selection on the Mac does not restore the phone's original artwork;
there is no automatic rollback flow in this GUI.

## What counts as success at each stage?

| Stage | Observable result needed for “successful” | What this does not establish |
| --- | --- | --- |
| Connection | AirCard identifies the currently unlocked, trusted iPhone as connected | That the target cache is writable |
| Wallet scanning | After **Scan Cards**, authentication, and card selection on the phone, the target card actually appears in AirCard | A scanner connection message alone is not successful card detection. |
| Wallet flashing | **Flash Skins** reports completion for the intended cards; distinguish individual outcomes in a batch | That every card completed or Wallet refreshed |
| Artwork displayed on phone | After reopening Wallet or restarting, the tester observes the expected image on the target card | The Mac preview alone is insufficient. |
| Theme export / re-import | A new `.passthm` saves and can be imported to inspect the digit previews | This is a local file check, not device compatibility. |
| Passcode-theme flashing | **Flash Passcode Theme** reports success | That the lock-screen keypad already looks correct |
| Theme displayed on phone | The tester checks the actual keypad after following the [theme refresh steps](THEME-CREATOR.en.md#apply-and-record-the-result) | If the phone was not inspected, record “not tested.” |

Use **Successful / Failed / Partially successful / Not tested / Not applicable**. Name the stage and short error for failures. For partial success, counts such as “3 target cards, 2 reported complete, third failed” are enough; identifiers are unnecessary. Wallet scanning is not part of the passcode workflow, so mark it “not applicable” there.

## Submit a useful record

1. Copy either language from the [report template](compatibility-report-template.md). Fill in iPhone model, full iOS/macOS versions, and Mac chip. Add OS build numbers if known.
2. Provide the precise AirCard version and tested commit. For a downloaded DMG, include the Release/download source and write “unknown” if the commit is unknown. A documentation commit in the guide repository is not the software build version.
3. Record each stage from connection through display on the phone. Mark skipped stages “not tested,” including stages not attempted after a failure.
4. For batches, separate target-card count, count reported complete, and count visually verified on the phone. For themes, include Target, language, font weight, and whether you used a poster, individual keys, or an imported package.
5. Share only the relevant one or two short error lines. Redact card numbers (including last digits), card identifiers, UDID, device names, and personal usernames in local paths before posting. Full raw logs are unnecessary. Check screenshots for the same information.
6. Report application behavior to [upstream Issues](https://github.com/Mak5er/AirCard/issues); guide corrections can be proposed as a documentation PR in [AirCard-Guide](https://github.com/BryceYuuu/AirCard-Guide). Copying or filling out the template does not automatically submit anything.

New records should link to their evidence and identify whether they are reporter-tested, an upstream record, or a project claim. Automated tests can verify parsing and error handling; they cannot replace scanning, flashing, or refresh checks on the specified phone.

## Source references

- [docs/wallet-card-detection.md](../wallet-card-detection.md): validated environment, detection outcome, and test boundaries.
- [AirCardApp.swift](../../AirCardApp.swift): connection, scanning, flashing states, and passcode target settings.
- [aircard_backend.py](../../aircard_backend.py): artwork and theme operation results.
- [Upstream README](https://github.com/Mak5er/AirCard/blob/main/README.md): project support claims and installation/refresh instructions.
