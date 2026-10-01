"""Device-staging helpers in apply_card_skin (no real device access).

One file per module under test: this covers the read-only lookup used by
card-artwork probing and the batched manifest read used by downloads.
"""

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import apply_card_skin

def _ok(extra=None):
    result = {"exitCode": 0, "targetGatePassed": True, "operation": {"ok": True}}
    if extra:
        result["operation"].update(extra)
    return result

UDID = "udid"
PARENT = "/var/mobile/Library/Passes/Cards"
NAMES = [f"{'A' * 28}.pkpass/cardBackgroundCombined.png.urls"]
LEAVES = [f"{'A' * 28}.pkpass/cardBackgroundCombined.png.urls",
          f"{'B' * 28}.pkpass/cardBackgroundCombined.png.urls"]


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
