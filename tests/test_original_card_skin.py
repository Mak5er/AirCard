import io
import json
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import aircard_backend
import original_card_skin


CARD_HASH = "A" * 27 + "="
ASSETS = {
    "cardBackgroundCombined@3x.png": b"original-3x",
    "cardBackgroundCombined@2x.png": b"original-2x",
    "cardBackgroundCombined.pdf": b"original-pdf",
}


class OriginalCardSkinTests(unittest.TestCase):
    def test_capture_saves_all_original_assets_once_with_private_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with (
                patch.object(original_card_skin.Path, "home", return_value=root),
                patch.object(original_card_skin, "read_file", side_effect=ASSETS.values()) as read,
            ):
                captured, error = original_card_skin.capture_original_skin("device", CARD_HASH)
                backup = original_card_skin.backup_path("device", CARD_HASH)
                self.assertTrue(captured)
                self.assertIsNone(error)
                self.assertEqual(original_card_skin.load_original_skin("device", CARD_HASH), ASSETS)
                self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
                self.assertEqual(backup.parent.stat().st_mode & 0o777, 0o700)

                with patch.object(original_card_skin, "read_file") as read_again:
                    self.assertEqual(original_card_skin.capture_original_skin("device", CARD_HASH), (True, None))
                    read_again.assert_not_called()
                self.assertEqual(read.call_count, len(ASSETS))

    def test_failed_capture_does_not_create_partial_restore_point(self):
        with tempfile.TemporaryDirectory() as temporary:
            with (
                patch.object(original_card_skin.Path, "home", return_value=Path(temporary)),
                patch.object(
                    original_card_skin,
                    "read_file",
                    side_effect=[ASSETS["cardBackgroundCombined@3x.png"],
                                 ASSETS["cardBackgroundCombined@2x.png"], None],
                ),
            ):
                captured, error = original_card_skin.capture_original_skin("device", CARD_HASH)
                self.assertFalse(captured)
                self.assertIn("cardBackgroundCombined.pdf", error or "")
                self.assertFalse(original_card_skin.backup_path("device", CARD_HASH).exists())

    def test_restore_writes_saved_assets_and_invalidates_wallet_caches(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(original_card_skin.Path, "home", return_value=Path(temporary)):
                backup = original_card_skin.backup_path("device", CARD_HASH)
                backup.parent.mkdir(parents=True)
                with zipfile.ZipFile(backup, "w") as archive:
                    for name, payload in ASSETS.items():
                        archive.writestr(name, payload)
                output = io.StringIO()
                with (
                    patch.object(aircard_backend, "write_files_batch", return_value=True) as write,
                    patch.object(aircard_backend, "remove_files", return_value=True) as remove,
                    redirect_stdout(output),
                ):
                    self.assertTrue(aircard_backend.cmd_restore_original_skin("device", CARD_HASH))

        writes = write.call_args.args
        self.assertEqual(writes[0], "device")
        self.assertEqual(writes[1], f"/var/mobile/Library/Passes/Cards/{CARD_HASH}.pkpass")
        self.assertEqual(dict(writes[2]), ASSETS)
        self.assertEqual(
            [call.args[1:] for call in remove.call_args_list],
            [
                (f"/var/mobile/Library/Passes/Cards/{CARD_HASH}.cache", ["FrontFace", "PlaceHolder", "Preview"]),
                (f"/var/mobile/Library/Passes/Cards/{CARD_HASH}.pkcache", ["FrontFace", "PlaceHolder", "Preview"]),
            ],
        )
        self.assertEqual(json.loads(output.getvalue())["type"], "success")

    def test_restore_refuses_invalid_identifier_without_writing(self):
        output = io.StringIO()
        with (
            patch.object(aircard_backend, "write_files_batch") as write,
            redirect_stdout(output),
        ):
            self.assertFalse(aircard_backend.cmd_restore_original_skin("device", "../../etc/passwd"))
        write.assert_not_called()
        self.assertIn("Invalid card identifier", output.getvalue())

    def test_status_lists_only_valid_cards_with_complete_backups(self):
        output = io.StringIO()
        with patch.object(aircard_backend, "has_original_skin", side_effect=lambda _udid, card: card == CARD_HASH):
            with redirect_stdout(output):
                aircard_backend.cmd_original_skin_status("device", [CARD_HASH, "../../etc/passwd"])
        self.assertEqual(json.loads(output.getvalue())["available_card_ids"], [CARD_HASH])


if __name__ == "__main__":
    unittest.main()
