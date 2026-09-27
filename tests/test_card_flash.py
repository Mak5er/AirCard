import base64
import io
import json
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch

import aircard_backend


PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


class CardFlashTests(unittest.TestCase):
    def test_flash_writes_pdf_and_invalidates_placeholder(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image_path = Path(temporary) / "card.png"
            image_path.write_bytes(PNG_1X1)
            write_file = Mock(return_value=True)

            with (
                patch.object(aircard_backend, "write_file", write_file),
                patch.object(aircard_backend, "write_files_batch", return_value=False),
                patch.object(aircard_backend, "remove_files", return_value=True) as remove,
                redirect_stdout(io.StringIO()),
            ):
                result = aircard_backend.cmd_flash("device", "aaaaaaaaaaaaaaaaaaaaaaaaaaa=", str(image_path))

        self.assertTrue(result)

        writes = [call.args for call in write_file.call_args_list]
        pass_assets = {
            leaf: payload
            for _, target, leaf, payload in writes
            if target.endswith(".pkpass")
        }
        self.assertEqual(
            set(pass_assets),
            {
                "cardBackgroundCombined@3x.png",
                "cardBackgroundCombined@2x.png",
                "cardBackgroundCombined.pdf",
            },
        )
        self.assertTrue(pass_assets["cardBackgroundCombined.pdf"].startswith(b"%PDF-"))

        self.assertEqual(remove.call_count, 2)
        for call, extension in zip(remove.call_args_list, (".cache", ".pkcache")):
            self.assertTrue(call.args[1].endswith(extension))
            self.assertEqual(call.args[2], list(aircard_backend.CACHE_FILES))
            self.assertIn("PlaceHolder", call.args[2])

    def test_flash_reports_failure_when_an_asset_write_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image_path = Path(temporary) / "card.png"
            image_path.write_bytes(PNG_1X1)
            write_file = Mock(
                side_effect=[True, True, False, True, True, True, True, True, True]
            )
            output = io.StringIO()

            with (
                patch.object(aircard_backend, "write_file", write_file),
                patch.object(aircard_backend, "write_files_batch", return_value=False),
                patch.object(aircard_backend, "remove_files", return_value=True) as remove,
                redirect_stdout(output),
            ):
                result = aircard_backend.cmd_flash("device", "aaaaaaaaaaaaaaaaaaaaaaaaaaa=", str(image_path))

        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertFalse(result)
        self.assertEqual(messages[-1]["type"], "error")
        self.assertFalse(any(message["type"] == "success" for message in messages))

    def test_flash_reports_failure_when_pdf_conversion_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            image_path = Path(temporary) / "card.png"
            image_path.write_bytes(PNG_1X1)
            write_file = Mock(return_value=True)
            output = io.StringIO()

            with (
                patch.object(aircard_backend, "write_file", write_file),
                patch.object(aircard_backend, "write_files_batch", return_value=False),
                patch.object(aircard_backend, "remove_files", return_value=True) as remove,
                patch.object(
                    aircard_backend,
                    "build_card_assets",
                    side_effect=subprocess.CalledProcessError(1, ["sips"]),
                ),
                redirect_stdout(output),
            ):
                result = aircard_backend.cmd_flash("device", "aaaaaaaaaaaaaaaaaaaaaaaaaaa=", str(image_path))

        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertFalse(result)
        self.assertEqual(messages[-1]["type"], "error")
        write_file.assert_not_called()


if __name__ == "__main__":
    unittest.main()
