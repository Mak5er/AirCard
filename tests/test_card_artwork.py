"""Unit tests for card_artwork: the remote card-artwork manifest and downloads."""

import hashlib
import json
import plistlib
import unittest
import urllib.error
from unittest.mock import patch

import card_artwork
import card_assets

HOST = "pr-pod11-smp-device-asset.apple.com"
URL = f"https://{HOST}:443/broker/v1/assets/" + "a" * 32
PNG = (b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR"
       + (1536).to_bytes(4, "big") + (969).to_bytes(4, "big") + b"payload")


def manifest(url=URL, fmt="json", size=None, sha1=None):
    """The documented on-device shape: asset name -> url/size/sha1."""
    if fmt == "legacy":
        return plistlib.dumps({"urls": [{"url": url}]})
    payload = {"cardBackgroundCombined@2x.png": {
        "url": url,
        "size": len(PNG) if size is None else size,
        "sha1": hashlib.sha1(PNG).hexdigest() if sha1 is None else sha1,
    }}
    return json.dumps(payload).encode()


class FakeResponse:
    def __init__(self, data):
        self.data = data

    def read(self, limit=-1):
        return self.data[:limit] if limit and limit > 0 else self.data

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class ManifestTests(unittest.TestCase):
    def test_reads_the_documented_shape(self):
        entries = card_artwork.manifest_entries(manifest())

        self.assertEqual(list(entries), ["cardBackgroundCombined@2x.png"])
        self.assertEqual(entries["cardBackgroundCombined@2x.png"]["url"], URL)
        self.assertEqual(entries["cardBackgroundCombined@2x.png"]["size"], len(PNG))
        self.assertEqual(entries["cardBackgroundCombined@2x.png"]["sha1"],
                         hashlib.sha1(PNG).hexdigest())

    def test_reads_a_plain_url_mapping(self):
        entries = card_artwork.manifest_entries(json.dumps({"icon.png": URL}).encode())

        self.assertEqual(entries["icon.png"], {"url": URL, "size": None, "sha1": None})

    def test_reads_the_legacy_plist_shape(self):
        self.assertEqual(card_artwork.manifest_url(manifest(fmt="legacy")), URL)

    def test_falls_back_to_scanning_raw_bytes(self):
        self.assertEqual(card_artwork.manifest_url(b"junk " + URL.encode() + b" tail"), URL)

    def test_returns_nothing_without_a_url(self):
        self.assertIsNone(card_artwork.manifest_url(b"no urls here"))
        self.assertIsNone(card_artwork.manifest_url(b""))
        self.assertEqual(card_artwork.manifest_entries(b""), {})

    def test_orders_the_best_card_face_first(self):
        entries = {
            "icon.png": {"url": URL},
            "cardBackgroundCombined@2x.png": {"url": URL},
            "cardBackgroundCombined@3x.png": {"url": URL},
        }
        self.assertEqual(card_artwork.ordered_assets(entries)[:2], [
            "cardBackgroundCombined@3x.png", "cardBackgroundCombined@2x.png"])

    def test_detects_the_format_of_the_served_bytes(self):
        self.assertEqual(card_artwork.detect_asset_format(PNG), ".png")
        self.assertEqual(card_artwork.detect_asset_format(b"%PDF-1.3"), ".pdf")
        self.assertEqual(card_artwork.detect_asset_format(b"\xff\xd8\xff\xe0"), ".jpg")
        self.assertEqual(card_artwork.detect_asset_format(b"GIF89a"), ".gif")
        # Anything else is not saved: no extension, no silent .png rename.
        self.assertIsNone(card_artwork.detect_asset_format(b"<html>nope</html>"))
        self.assertIsNone(card_artwork.detect_asset_format(b""))

    def test_verifies_size_and_sha1(self):
        self.assertEqual(card_artwork.verify_declared(PNG, len(PNG),
                                                     hashlib.sha1(PNG).hexdigest()), [])
        self.assertTrue(card_artwork.verify_declared(PNG, 1, None))
        self.assertTrue(card_artwork.verify_declared(PNG, None, "0" * 40))
        self.assertTrue(card_artwork.declared_checks(len(PNG), None))
        self.assertFalse(card_artwork.declared_checks(None, None))



class DownloadTests(unittest.TestCase):
    def test_downloads_an_apple_asset(self):
        with patch("card_artwork.urllib.request.urlopen", return_value=FakeResponse(PNG)):
            self.assertEqual(card_artwork.download_asset(URL), PNG)

    def test_refuses_hosts_outside_apple(self):
        with patch("card_artwork.urllib.request.urlopen") as urlopen:
            with self.assertRaises(ValueError):
                card_artwork.download_asset("https://example.com/broker/v1/assets/x")
        urlopen.assert_not_called()

    def test_retries_transient_failures(self):
        failure = urllib.error.URLError("temporary")
        with patch("card_artwork.urllib.request.urlopen",
                   side_effect=[failure, FakeResponse(PNG)]) as urlopen:
            with patch("card_artwork.time.sleep"):
                self.assertEqual(card_artwork.download_asset(URL), PNG)
        self.assertEqual(urlopen.call_count, 2)

    def test_does_not_retry_a_client_error(self):
        error = urllib.error.HTTPError(URL, 404, "Not Found", {}, None)
        with patch("card_artwork.urllib.request.urlopen", side_effect=error) as urlopen:
            with self.assertRaises(urllib.error.HTTPError):
                card_artwork.download_asset(URL)
        self.assertEqual(urlopen.call_count, 1)


if __name__ == "__main__":
    unittest.main()


PNG_BYTES = b"\x89PNG\r\n\x1a\ncard-artwork"
PNG_WITH_SIZE = (b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR"
                 + (1536).to_bytes(4, "big") + (969).to_bytes(4, "big") + b"payload")


class CardImageTests(unittest.TestCase):
    def test_recognises_the_png_signature(self):
        self.assertTrue(card_assets.is_png(PNG))
        self.assertFalse(card_assets.is_png(b"\x00\x01\x02not an image"))
        self.assertFalse(card_assets.is_png(b""))

    def test_png_dimensions_reads_the_header(self):
        self.assertEqual(card_assets.png_dimensions(PNG_WITH_SIZE), (1536, 969))
        self.assertIsNone(card_assets.png_dimensions(b"not a png"))
        self.assertIsNone(card_assets.png_dimensions(b""))


if __name__ == "__main__":
    unittest.main()
