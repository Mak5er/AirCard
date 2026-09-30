import contextlib
import io
import hashlib
import json
import plistlib
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

import aircard_backend
from card_artwork import CARD_ARTWORK_MANIFEST

CARD_A = "U" * 28
CARD_B = "V" * 28
ASSET_HOST = "pr-pod11-smp-device-asset.apple.com"
URL = f"https://{ASSET_HOST}:443/broker/v1/assets/" + "a" * 32
PNG = (b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR"
       + (1536).to_bytes(4, "big") + (969).to_bytes(4, "big") + b"payload")


def manifest_bytes(url=URL, fmt="json", size=None, sha1=None, payload=PNG):
    """The documented on-device shape: asset name -> url/size/sha1."""
    if fmt == "legacy":
        return plistlib.dumps({"urls": [{"url": url}]})
    body = {"cardBackgroundCombined@2x.png": {
        "url": url,
        "size": len(payload) if size is None else size,
        "sha1": hashlib.sha1(payload).hexdigest() if sha1 is None else sha1,
    }}
    return json.dumps(body).encode()


class FakeResponse:
    def __init__(self, data):
        self.data = data

    def read(self, limit=-1):
        return self.data[:limit] if limit and limit > 0 else self.data

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def manifests_for(card=CARD_A, payload=manifest_bytes()):
    """What read_files_batch returns: {relative leaf: manifest bytes}."""
    if payload is None:
        return {}
    return {f"{card}.pkpass/{CARD_ARTWORK_MANIFEST}": payload}


def run_fetch(card=CARD_A, read_return=manifest_bytes(), http_return=PNG, http_error=None,
              locked=False):
    with tempfile.TemporaryDirectory() as temporary:
        destination = Path(temporary) / "card.png"
        stdout = io.StringIO()
        urlopen = (patch("card_artwork.urllib.request.urlopen", side_effect=http_error)
                   if http_error else
                   patch("card_artwork.urllib.request.urlopen", return_value=FakeResponse(http_return)))
        with (patch("aircard_backend.read_files_batch",
                    return_value=manifests_for(card, read_return)) as read_batch,
              patch("aircard_backend.file_service_available", return_value=not locked),
              urlopen):
            with contextlib.redirect_stdout(stdout):
                ok = aircard_backend.cmd_fetch_card_artwork("udid", card, str(destination))
        payload = None
        for line in reversed(stdout.getvalue().splitlines()):
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            break
        saved = destination.read_bytes() if destination.exists() else None
        return ok, saved, payload, read_batch


class ProbeCardCoversTests(unittest.TestCase):
    def probe(self, results):
        stdout = io.StringIO()
        with patch("aircard_backend.stat_paths", return_value=results):
            with contextlib.redirect_stdout(stdout):
                ok = aircard_backend.cmd_probe_card_artwork("udid", [CARD_A, CARD_B])
        return ok, json.loads(stdout.getvalue().strip().splitlines()[-1])

    def test_lists_only_cards_with_the_manifest(self):
        present = {f"{CARD_A}.pkpass/{CARD_ARTWORK_MANIFEST}":
                   {"present": True, "kind": "S_IFREG", "size": 205}}
        ok, payload = self.probe(present)

        self.assertTrue(ok)
        self.assertEqual(payload["available"], [CARD_A])
        self.assertEqual(payload["checked"], 2)

    def test_ignores_invalid_ids_and_missing_manifests(self):
        stdout = io.StringIO()
        missing = {f"{CARD_B}.pkpass/{CARD_ARTWORK_MANIFEST}": {"present": False}}
        with patch("aircard_backend.stat_paths", return_value=missing) as stat:
            with contextlib.redirect_stdout(stdout):
                aircard_backend.cmd_probe_card_artwork("udid", ["../bad", CARD_B])
        stat.assert_called_once()
        self.assertEqual(stat.call_args.args[2], [f"{CARD_B}.pkpass/{CARD_ARTWORK_MANIFEST}"])
        payload = json.loads(stdout.getvalue().strip().splitlines()[-1])
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["available"], [])

    def test_treats_a_sandbox_denial_as_potentially_available(self):
        denied = {f"{CARD_A}.pkpass/{CARD_ARTWORK_MANIFEST}":
                  {"present": False, "afcStatus": 10, "error": "denied-or-missing"}}
        stdout = io.StringIO()
        with patch("aircard_backend.stat_paths", return_value=denied):
            with contextlib.redirect_stdout(stdout):
                aircard_backend.cmd_probe_card_artwork("udid", [CARD_A])
        payload = json.loads(stdout.getvalue().strip().splitlines()[-1])
        self.assertEqual(payload["available"], [CARD_A])

    def test_reports_a_locked_iphone_when_the_lookup_fails(self):
        stdout = io.StringIO()
        with (patch("aircard_backend.stat_paths", return_value={}),
              patch("aircard_backend.file_service_available", return_value=False)):
            with contextlib.redirect_stdout(stdout):
                ok = aircard_backend.cmd_probe_card_artwork("udid", [CARD_A])

        payload = json.loads(stdout.getvalue().strip().splitlines()[-1])
        self.assertFalse(ok)
        self.assertIn("Unlock", payload["error"])

    def test_reports_a_failed_lookup_instead_of_hiding_buttons(self):
        stdout = io.StringIO()
        with (patch("aircard_backend.stat_paths", return_value={}),
              patch("aircard_backend.file_service_available", return_value=True)):
            with contextlib.redirect_stdout(stdout):
                ok = aircard_backend.cmd_probe_card_artwork("udid", [CARD_A])

        payload = json.loads(stdout.getvalue().strip().splitlines()[-1])
        self.assertFalse(ok)
        self.assertFalse(payload["ok"])
        self.assertNotIn("available", payload)
        self.assertIn("iPhone", payload["error"])


class FetchCardCoverTests(unittest.TestCase):
    def test_downloads_and_saves_the_card_artwork(self):
        ok, saved, payload, read_batch = run_fetch()

        self.assertTrue(ok)
        self.assertEqual(saved, PNG)
        self.assertEqual((payload["width"], payload["height"]), (1536, 969))
        self.assertIn(ASSET_HOST, payload["source"])
        self.assertTrue(payload["verified"])
        self.assertEqual(read_batch.call_args.args[2],
                         [f"{CARD_A}.pkpass/{CARD_ARTWORK_MANIFEST}"])

    def test_requires_the_remote_manifest(self):
        ok, saved, payload, _ = run_fetch(read_return=None)

        self.assertFalse(ok)
        self.assertIsNone(saved)
        self.assertIn("Wallet", payload["error"])

    def test_verifies_the_downloaded_bytes_against_the_manifest(self):
        ok, saved, payload, _ = run_fetch()

        self.assertTrue(ok)
        self.assertEqual(payload["asset"], "cardBackgroundCombined@2x.png")
        self.assertTrue(payload["verified"])
        self.assertEqual(payload["problems"], [])

    def test_flags_a_download_that_does_not_match_the_manifest(self):
        declared = manifest_bytes(sha1="0" * 40, size=1)
        ok, saved, payload, _ = run_fetch(read_return=declared)

        self.assertTrue(ok)
        self.assertEqual(saved, PNG)
        self.assertFalse(payload["verified"])
        self.assertTrue(payload["problems"])

    def test_reads_the_manifest_with_one_batched_round_trip(self):
        ok, saved, payload, read_batch = run_fetch()

        self.assertTrue(ok)
        read_batch.assert_called_once()
        udid, target, leaves = read_batch.call_args.args[:3]
        self.assertEqual(udid, "udid")
        self.assertEqual(target, aircard_backend.CARDS_ROOT)
        self.assertEqual(leaves, [f"{CARD_A}.pkpass/{CARD_ARTWORK_MANIFEST}"])

    def test_reports_a_locked_iphone_when_the_manifest_cannot_be_read(self):
        ok, saved, payload, _ = run_fetch(read_return=None, locked=True)

        self.assertFalse(ok)
        self.assertIsNone(saved)
        self.assertIn("Unlock", payload["error"])

    def test_saves_mismatched_bytes_but_marks_them_unverified(self):
        ok, saved, payload, _ = run_fetch(read_return=manifest_bytes(sha1="0" * 40))
        self.assertTrue(ok)
        self.assertFalse(payload["verified"])
        self.assertTrue(payload["problems"])

    def test_reads_the_legacy_plist_manifest(self):
        ok, saved, payload, _ = run_fetch(read_return=manifest_bytes(fmt="legacy"))

        self.assertTrue(ok)
        self.assertEqual(saved, PNG)
        self.assertFalse(payload["verified"])

    def test_refuses_non_apple_hosts(self):
        ok, saved, payload, _ = run_fetch(
            read_return=manifest_bytes(url="https://example.com/broker/v1/assets/x"))

        self.assertFalse(ok)
        self.assertIsNone(saved)
        self.assertIn("Apple", payload["error"])

    def test_saves_the_original_bytes_without_converting(self):
        pdf = b"%PDF-1.3\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF"
        ok, saved, payload, _ = run_fetch(read_return=manifest_bytes(payload=pdf),
                                          http_return=pdf)

        self.assertTrue(ok)
        # Byte-for-byte what Apple served: nothing re-encodes it on the way out.
        self.assertEqual(saved, pdf)
        self.assertEqual(payload["extension"], ".pdf")
        self.assertTrue(payload["verified"])
        self.assertIsNone(payload["width"])

    def test_rejects_a_non_image_response(self):
        ok, saved, payload, _ = run_fetch(http_return=b"<html>nope</html>")

        self.assertFalse(ok)
        self.assertIsNone(saved)
        self.assertIn("usable image", payload["error"])

    def test_reports_http_failures(self):
        error = urllib.error.HTTPError(URL, 404, "Not Found", {}, None)
        ok, saved, payload, _ = run_fetch(http_error=error)

        self.assertFalse(ok)
        self.assertIsNone(saved)
        self.assertIn("404", payload["error"])

    def test_rejects_an_invalid_card_id(self):
        ok, saved, payload, read_file = run_fetch(card="../bad")

        self.assertFalse(ok)
        self.assertIsNone(saved)
        read_file.assert_not_called()
        self.assertIn("Invalid card ID", payload["error"])


def run_batch(cards=(CARD_A, CARD_B), manifests=None, download=None, available=True,
              directory=None):
    """Runs the batch command with a stubbed device read and returns its summary."""
    if manifests is None:
        manifests = {f"{card}.pkpass/{CARD_ARTWORK_MANIFEST}": manifest_bytes() for card in cards}
    stdout = io.StringIO()

    def fake_download(url, retries=2):
        if download is not None:
            return download(url)
        return PNG

    with tempfile.TemporaryDirectory() as temporary:
        target = Path(directory) if directory else Path(temporary)
        with (
            patch("aircard_backend.read_files_batch", return_value=manifests) as read_batch,
            patch("aircard_backend.file_service_available", return_value=available),
            patch("aircard_backend.download_asset", side_effect=fake_download),
        ):
            with contextlib.redirect_stdout(stdout):
                ok = aircard_backend.cmd_fetch_card_artworks("udid", str(target), list(cards))
        payload = json.loads(stdout.getvalue().strip().splitlines()[-1])
        written = sorted(p.name for p in target.glob("AirCard-*"))
        return ok, payload, read_batch, written


class BatchArtworkDownloadTests(unittest.TestCase):
    def test_reads_every_manifest_in_one_device_call(self):
        ok, payload, read_batch, written = run_batch()

        self.assertTrue(ok)
        self.assertEqual(payload["saved"], 2)
        self.assertEqual(payload["failed"], 0)
        read_batch.assert_called_once()
        leaves = read_batch.call_args.args[2]
        self.assertEqual(leaves, [f"{CARD_A}.pkpass/{CARD_ARTWORK_MANIFEST}",
                                  f"{CARD_B}.pkpass/{CARD_ARTWORK_MANIFEST}"])
        self.assertEqual(len(written), 2)
        self.assertEqual(written, sorted([f"AirCard-{CARD_A[:12]}.png",
                                         f"AirCard-{CARD_B[:12]}.png"]))
        self.assertTrue(all(entry["verified"] for entry in payload["results"]))
        self.assertEqual(payload["results"][0]["width"], 1536)

    def test_writes_each_cover_in_the_format_it_arrived_in(self):
        pdf = b"%PDF-1.3\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF"
        manifests = {f"{CARD_A}.pkpass/{CARD_ARTWORK_MANIFEST}": manifest_bytes(payload=pdf)}
        ok, payload, _, written = run_batch(cards=(CARD_A,), manifests=manifests,
                                            download=lambda url: pdf)

        self.assertTrue(ok)
        self.assertEqual(written, [f"AirCard-{CARD_A[:12]}.pdf"])
        self.assertEqual(payload["results"][0]["extension"], ".pdf")
        self.assertIsNone(payload["results"][0]["width"])

    def test_a_card_without_a_manifest_does_not_stop_the_others(self):
        only_a = {f"{CARD_A}.pkpass/{CARD_ARTWORK_MANIFEST}": manifest_bytes()}
        ok, payload, _, written = run_batch(manifests=only_a)

        self.assertTrue(ok)
        self.assertEqual((payload["saved"], payload["failed"]), (1, 1))
        self.assertEqual(written, [f"AirCard-{CARD_A[:12]}.png"])
        failed = [entry for entry in payload["results"] if not entry["ok"]]
        self.assertEqual(failed[0]["card"], CARD_B)
        self.assertIn("Wallet", failed[0]["error"])

    def test_reports_a_locked_iphone_when_no_manifest_can_be_read(self):
        ok, payload, _, written = run_batch(manifests={}, available=False)

        self.assertFalse(ok)
        self.assertIn("Unlock", payload["error"])
        self.assertEqual(written, [])

    def test_keeps_a_download_that_contradicts_the_manifest(self):
        manifests = {f"{CARD_A}.pkpass/{CARD_ARTWORK_MANIFEST}": manifest_bytes(sha1="0" * 40)}
        ok, payload, _, written = run_batch(cards=(CARD_A,), manifests=manifests)

        self.assertTrue(ok)
        self.assertEqual(payload["saved"], 1)
        self.assertFalse(payload["results"][0]["verified"])
        self.assertTrue(payload["results"][0]["problems"])

    def test_rejects_an_invalid_card_id(self):
        ok, payload, read_batch, _ = run_batch(cards=("short",))

        self.assertFalse(ok)
        self.assertEqual(payload["error"], "Invalid card ID")
        read_batch.assert_not_called()

    def test_requires_an_existing_folder(self):
        with tempfile.TemporaryDirectory() as temporary:
            missing = Path(temporary) / "nope"
            stdout = io.StringIO()
            with patch("aircard_backend.read_files_batch") as read_batch:
                with contextlib.redirect_stdout(stdout):
                    ok = aircard_backend.cmd_fetch_card_artworks("udid", str(missing), [CARD_A])

        self.assertFalse(ok)
        self.assertIn("folder", json.loads(stdout.getvalue().strip())["error"])
        read_batch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
