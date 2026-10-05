"""Card artwork parsing, device staging, downloads and cancellation (mock devices)."""

import contextlib
import hashlib
import io
import json
import plistlib
import subprocess
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

import aircard_backend
import apply_card_skin
import card_artwork
import card_assets
from card_artwork import CARD_ARTWORK_MANIFEST



HOST = "pr-pod11-smp-device-asset.apple.com"


URL = f"https://{HOST}:443/broker/v1/assets/" + "a" * 32


PNG = (b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR"
       + (1536).to_bytes(4, "big") + (969).to_bytes(4, "big") + b"payload")


class FakeResponse:
    def __init__(self, data):
        self.data = data

    def read(self, limit=-1):
        return self.data[:limit] if limit and limit > 0 else self.data

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


CARD_A = "U" * 28


CARD_B = "V" * 28


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


UDID = "udid"


PARENT = "/var/mobile/Library/Passes/Cards"


NAMES = [f"{'A' * 28}.pkpass/cardBackgroundCombined.png.urls"]


LEAVES = [f"{'A' * 28}.pkpass/cardBackgroundCombined.png.urls",
          f"{'B' * 28}.pkpass/cardBackgroundCombined.png.urls"]


def _ok(extra=None):
    result = {"exitCode": 0, "targetGatePassed": True, "operation": {"ok": True}}
    if extra:
        result["operation"].update(extra)
    return result


# Manifest parsing and downloaded image validation.


class ManifestTests(unittest.TestCase):
    def test_reads_the_documented_shape(self):
        entries = card_artwork.manifest_entries(manifest_bytes())

        self.assertEqual(list(entries), ["cardBackgroundCombined@2x.png"])
        self.assertEqual(entries["cardBackgroundCombined@2x.png"]["url"], URL)
        self.assertEqual(entries["cardBackgroundCombined@2x.png"]["size"], len(PNG))
        self.assertEqual(entries["cardBackgroundCombined@2x.png"]["sha1"],
                         hashlib.sha1(PNG).hexdigest())

    def test_reads_a_plain_url_mapping(self):
        entries = card_artwork.manifest_entries(json.dumps({"icon.png": URL}).encode())

        self.assertEqual(entries["icon.png"], {"url": URL, "size": None, "sha1": None})

    def test_reads_the_legacy_plist_shape(self):
        self.assertEqual(card_artwork.manifest_url(manifest_bytes(fmt="legacy")), URL)

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


class CardImageTests(unittest.TestCase):
    def test_recognises_the_png_signature(self):
        self.assertTrue(card_assets.is_png(PNG))
        self.assertFalse(card_assets.is_png(b"\x00\x01\x02not an image"))
        self.assertFalse(card_assets.is_png(b""))

    def test_png_dimensions_reads_the_header(self):
        self.assertEqual(card_assets.png_dimensions(PNG), (1536, 969))
        self.assertIsNone(card_assets.png_dimensions(b"not a png"))
        self.assertIsNone(card_assets.png_dimensions(b""))


# Backend availability, single-card and batch commands.


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
    def test_cancel_during_device_read_waits_for_restore_and_skips_download(self):
        events = []
        def read_and_restore(*args, **kwargs):
            events.append("read")
            aircard_backend._request_artwork_cancel(None, None)
            events.append("restored")
            return manifests_for()

        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "card.png"
            destination.write_bytes(b"existing image")
            stdout = io.StringIO()
            with (
                patch.object(aircard_backend, "_artwork_cancel_requested", False),
                patch.object(aircard_backend, "read_files_batch", side_effect=read_and_restore),
                patch.object(aircard_backend, "download_asset") as download,
                contextlib.redirect_stdout(stdout),
            ):
                ok = aircard_backend.cmd_fetch_card_artwork("fake", CARD_A, str(destination))
            self.assertFalse(ok)
            self.assertTrue(json.loads(stdout.getvalue())["cancelled"])
            self.assertEqual(events, ["read", "restored"])
            download.assert_not_called()
            self.assertEqual(destination.read_bytes(), b"existing image")

    def test_invalid_preferred_asset_falls_back_to_valid_image(self):
        manifest = json.dumps({
            "cardBackgroundCombined@3x.png": {"url": URL + "/3x"},
            "cardBackgroundCombined@2x.png": {
                "url": URL, "size": len(PNG), "sha1": hashlib.sha1(PNG).hexdigest()},
        }).encode()
        with patch("aircard_backend.download_asset", side_effect=[b"<html>error</html>", PNG]) as download:
            result = aircard_backend.resolve_card_artwork(manifest)
        self.assertTrue(result["ok"])
        self.assertTrue(result["verified"])
        self.assertEqual(result["asset"], "cardBackgroundCombined@2x.png")
        self.assertEqual(result["data"], PNG)
        self.assertEqual(download.call_count, 2)

    def test_downloads_and_saves_the_card_artwork(self):
        ok, saved, payload, read_batch = run_fetch()

        self.assertTrue(ok)
        self.assertEqual(saved, PNG)
        self.assertEqual((payload["width"], payload["height"]), (1536, 969))
        self.assertIn(HOST, payload["source"])
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


class BatchArtworkDownloadTests(unittest.TestCase):
    def test_cancel_keeps_completed_files_and_skips_remaining_cards(self):
        calls = []
        def download(url, retries=2):
            calls.append(url)
            if len(calls) == 2:
                aircard_backend._request_artwork_cancel(None, None)
            return PNG

        with patch.object(aircard_backend, "_artwork_cancel_requested", False):
            ok, payload, _, written = run_batch(download=download)
        self.assertTrue(ok)
        self.assertTrue(payload["cancelled"])
        self.assertEqual(payload["saved"], 1)
        self.assertEqual(written, [f"AirCard-{CARD_A[:12]}.png"])
        self.assertTrue(payload["results"][1]["cancelled"])

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


# Device lookup and recovery use simulated helpers only.


class StatPathsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.cache = Path(self.temporary.name) / "links.json"
        self.addCleanup(self.temporary.cleanup)
        patcher = patch.object(apply_card_skin, "STAT_LINK_CACHE", self.cache)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_rejects_paths_that_escape_the_directory(self):
        for bad in ("", "/abs", "a/", "a/../b", "../x"):
            with self.assertRaises(ValueError):
                apply_card_skin.stat_paths(UDID, PARENT, [bad])

    def test_reuses_a_kept_link_without_staging_again(self):
        self.cache.write_text(json.dumps({apply_card_skin._stat_link_key(UDID, PARENT): "airlift-link-kept"}))
        reported = {"airlift-link-kept/" + NAMES[0]: {"ok": True, "kind": "S_IFREG", "size": 205}}
        commands = []

        def fake_native(command, udid, *args):
            commands.append(command)
            if command == "afc-stat":
                return _ok({"kind": "S_IFDIR"})
            if command == "afc-stat-many":
                return _ok({"results": reported})
            raise AssertionError(f"unexpected device command: {command}")

        with patch.object(apply_card_skin, "native", side_effect=fake_native):
            results = apply_card_skin.stat_paths(UDID, PARENT, NAMES)

        self.assertEqual(results[NAMES[0]]["present"], True)
        self.assertEqual(results[NAMES[0]]["kind"], "S_IFREG")
        self.assertEqual(results[NAMES[0]]["size"], 205)
        # Only the liveness stat and the batch stat ran: no staging at all.
        self.assertEqual(commands, ["afc-stat", "afc-stat-many"])

    def test_drops_the_dead_link_it_replaces(self):
        stale = "airlift-link-" + "a" * 20
        self.cache.write_text(json.dumps({apply_card_skin._stat_link_key(UDID, PARENT): stale}))
        removed = []
        reported = {"airlift-link-" + "f" + "0" * 19 + "/" + NAMES[0]: {"ok": True, "kind": "S_IFREG", "size": 205}}

        def fake_native(command, udid, *args):
            if command == "afc-stat":
                # The cached link is dead; the freshly staged one resolves.
                fresh = "f" + "0" * 19
                kind = "S_IFDIR" if fresh in args[0] else "S_IFREG"
                return {"exitCode": 0, "targetGatePassed": True,
                        "operation": {"ok": True, "kind": kind}}
            if command == "afc-stat-many":
                return _ok({"results": reported})
            if command in ("snapshot-books", "stage"):
                return _ok()
            if command == "finish-keep-link":
                return _ok()
            raise AssertionError(f"unexpected device command: {command}")

        def fake_remove(udid, target, leaves, retries=1):
            removed.extend(leaves)
            return True

        with (
            patch.object(apply_card_skin, "native", side_effect=fake_native),
            patch.object(apply_card_skin, "run_json", return_value={"exitCode": 0, "ok": True}),
            patch.object(apply_card_skin, "remove_files", side_effect=fake_remove),
            patch("secrets.token_hex", return_value="f" + "0" * 19),
        ):
            apply_card_skin.stat_paths(UDID, PARENT, NAMES)

        self.assertEqual(removed, [stale])

    def test_rebuilds_the_link_when_the_cached_one_is_gone(self):
        key = apply_card_skin._stat_link_key(UDID, PARENT)
        self.cache.write_text(json.dumps({key: "airlift-link-dead"}))
        commands = []
        staged_links = []
        state = {"staged": False}

        def fake_native(command, udid, *args):
            commands.append(command)
            if command == "afc-stat":
                # Dangling cache first, then live once a new link was relocated.
                kind = "S_IFDIR" if state["staged"] else None
                return {"exitCode": 0, "targetGatePassed": True,
                        "operation": {"ok": bool(kind), "kind": kind}}
            if command == "snapshot-books":
                return _ok()
            if command == "stage":
                staged_links.append(args[1])
                state["staged"] = True
                return _ok()
            if command == "afc-stat-many":
                return _ok({"results": {path: {"ok": False, "error": "missing"}
                                        for path in args}})
            if command == "finish-keep-link":
                # The command name carries the semantics: no "keep-link" argument.
                self.assertEqual(len(args), 4)
                return _ok({"linkKept": True})
            raise AssertionError(f"unexpected device command: {command}")

        with (
            patch.object(apply_card_skin, "native", side_effect=fake_native),
            patch.object(apply_card_skin, "run_json", return_value={"exitCode": 0, "ok": True}),
            patch.object(apply_card_skin, "remove_files", return_value=True),
        ):
            results = apply_card_skin.stat_paths(UDID, PARENT, NAMES)

        self.assertIn("snapshot-books", commands)
        self.assertIn("finish-keep-link", commands)
        self.assertEqual(results[NAMES[0]]["present"], False)
        # The freshly relocated link is remembered for the next lookup.
        self.assertEqual(len(staged_links), 1)
        self.assertTrue(staged_links[0].startswith("airlift-link-"))
        self.assertEqual(json.loads(self.cache.read_text())[key], staged_links[0])

    def test_release_removes_the_kept_link(self):
        key = apply_card_skin._stat_link_key(UDID, PARENT)
        self.cache.write_text(json.dumps({key: "airlift-link-kept"}))

        with patch.object(apply_card_skin, "remove_files", return_value=True) as remove:
            apply_card_skin.release_stat_link(UDID, PARENT)

        remove.assert_called_once_with(UDID, "/var/mobile/Media", ["airlift-link-kept"], retries=1)
        self.assertEqual(json.loads(self.cache.read_text()), {})


class ReadFilesBatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.work = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def test_rejects_leaves_that_escape_the_directory(self):
        for bad in ("", "/abs", "a/", "a/../b", "../x"):
            with self.assertRaises(ValueError):
                apply_card_skin.read_files_batch(UDID, PARENT, [bad])

    def test_uncertain_transfer_preserves_staging_without_retry(self):
        for outcome in ({"exitCode": -15, "type": "atc_progress"},
                        subprocess.TimeoutExpired("airtraffic_host", 120)):
            with self.subTest(outcome=outcome):
                arguments = {"side_effect": outcome} if isinstance(outcome, Exception) else {"return_value": outcome}
                with (
                    patch.object(apply_card_skin, "native", return_value=_ok()) as native,
                    patch.object(apply_card_skin, "run_json", **arguments) as transfer,
                    patch.object(apply_card_skin, "_retain_batch_read_recovery") as retain,
                ):
                    result = apply_card_skin.read_files_batch(UDID, PARENT, LEAVES, retries=2)
                self.assertEqual(result, {})
                transfer.assert_called_once()
                retain.assert_called_once()
                self.assertNotIn("finish-write", [call.args[0] for call in native.call_args_list])

    def test_recovery_keeps_books_preimage_and_device_identity(self):
        original = self.work / "original"
        original.mkdir()
        (original / "Books.plist").write_bytes(b"original Books state")
        recovery = self.work / "recovery"
        with patch.object(apply_card_skin.tempfile, "mkdtemp", return_value=str(recovery)):
            apply_card_skin._retain_batch_read_recovery(original, UDID, "airlift-src-test")
        self.assertEqual((recovery / "Books.plist").read_bytes(), b"original Books state")
        self.assertEqual(json.loads((recovery / "recovery.json").read_text()),
                         {"udid": UDID, "source": "airlift-src-test"})

    def test_failed_restore_does_not_report_success_or_delete_originals(self):
        def native(command, udid, *args):
            if command == "afc-read":
                Path(args[1]).write_bytes(b"original manifest")
            return _ok()

        with (
            patch.object(apply_card_skin, "native", side_effect=native) as calls,
            patch.object(apply_card_skin, "run_json", return_value={"exitCode": 0, "ok": True}),
            patch.object(apply_card_skin, "write_files_batch", return_value=False),
            patch.object(apply_card_skin, "_retain_batch_read_recovery") as retain,
        ):
            result = apply_card_skin.read_files_batch(UDID, PARENT, LEAVES)
        self.assertEqual(result, {})
        retain.assert_called_once()
        self.assertNotIn("finish-write", [call.args[0] for call in calls.call_args_list])

    def test_reads_every_leaf_in_one_move_cycle(self):
        payloads = {LEAVES[0]: b'{"one": 1}', LEAVES[1]: b'{"two": 2}'}
        calls = {"native": [], "atc": [], "restored": []}
        counter = {"n": 0}

        def fake_native(command, udid, *args):
            calls["native"].append(command)
            if command in ("snapshot-books", "stage"):
                return _ok()
            if command == "afc-read":
                # args = (device path, local file); hand back the queued payload.
                Path(args[1]).write_bytes(payloads[LEAVES[counter["n"]]])
                counter["n"] += 1
                return _ok()
            if command == "finish-write":
                return _ok()
            raise AssertionError(f"unexpected device command: {command}")

        def fake_atc(argv, timeout=None):
            calls["atc"].append(argv)
            return {"exitCode": 0, "ok": True}

        def fake_restore(udid, target, files, retries=3):
            calls["restored"].append((target, list(files)))
            return True

        with (
            patch.object(apply_card_skin, "native", side_effect=fake_native),
            patch.object(apply_card_skin, "run_json", side_effect=fake_atc),
            patch.object(apply_card_skin, "write_files_batch", side_effect=fake_restore),
        ):
            data = apply_card_skin.read_files_batch(UDID, PARENT, LEAVES)

        self.assertEqual(data, payloads)
        # One staging cycle, one AirTraffic session carrying a pair per leaf.
        self.assertEqual(calls["native"].count("snapshot-books"), 1)
        self.assertEqual(calls["native"].count("stage"), 1)
        self.assertEqual(calls["native"].count("afc-read"), 2)
        self.assertEqual(calls["native"].count("finish-write"), 1)
        self.assertEqual(len(calls["atc"]), 1)
        self.assertEqual(len(calls["atc"][0]) - 2, 2 * (len(LEAVES) + 1))
        # Every manifest is written back by a single batch write.
        self.assertEqual(len(calls["restored"]), 1)
        target, files = calls["restored"][0]
        self.assertEqual(target, PARENT)
        self.assertEqual(sorted(leaf for leaf, _ in files), sorted(LEAVES))

    def test_leaves_unread_files_alone_if_one_read_fails(self):
        calls = {"native": [], "restored": []}
        counter = {"n": 0}

        def fake_native(command, udid, *args):
            calls["native"].append(command)
            if command in ("snapshot-books", "stage"):
                return _ok()
            if command == "afc-read":
                counter["n"] += 1
                if counter["n"] == 1:
                    Path(args[1]).write_bytes(b'{"one": 1}')
                    return _ok()
                return {"exitCode": 0, "targetGatePassed": True,
                        "operation": {"ok": False, "error": "denied-or-missing"}}
            raise AssertionError(f"unexpected device command: {command}")

        def fake_restore(udid, target, files, retries=3):
            calls["restored"].append(list(files))
            return True

        with (
            patch.object(apply_card_skin, "native", side_effect=fake_native),
            patch.object(apply_card_skin, "run_json",
                         return_value={"exitCode": 0, "ok": True}),
            patch.object(apply_card_skin, "write_files_batch", side_effect=fake_restore),
        ):
            data = apply_card_skin.read_files_batch(UDID, PARENT, LEAVES)

        # The readable leaf comes back and is written to the phone again; the
        # failed one stays in the staging tree, which is deliberately kept.
        self.assertEqual(data, {LEAVES[0]: b'{"one": 1}'})
        self.assertEqual(calls["restored"], [[(LEAVES[0], b'{"one": 1}')]])
        self.assertNotIn("finish-write", calls["native"])

    def test_returns_nothing_when_the_device_rejects_the_stage(self):
        with (
            patch.object(apply_card_skin, "native",
                         return_value={"exitCode": 1, "targetGatePassed": False,
                                       "operation": {"ok": False}}),
            patch.object(apply_card_skin, "run_json",
                         return_value={"exitCode": 0, "ok": True}),
        ):
            self.assertEqual(apply_card_skin.read_files_batch(UDID, PARENT, LEAVES), {})


if __name__ == "__main__":
    unittest.main()
