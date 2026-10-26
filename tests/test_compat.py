import json
import unittest
from unittest.mock import patch

import aircard_compat
from aircard_compat import (
    SUPPORTED,
    PATCHED,
    TOO_OLD,
    UNKNOWN,
    classify_ios,
    humanize_error,
    parse_version,
)
from aircard import format_device
import aircard_backend


class ParseVersionTests(unittest.TestCase):
    def test_parses_and_pads(self):
        self.assertEqual(parse_version("18.0"), (18, 0, 0))
        self.assertEqual(parse_version("18.7.10"), (18, 7, 10))
        self.assertEqual(parse_version("27.2"), (27, 2, 0))

    def test_rejects_unknown(self):
        self.assertIsNone(parse_version(""))
        self.assertIsNone(parse_version(None))
        self.assertIsNone(parse_version("Unknown"))


class ClassifyTests(unittest.TestCase):
    def test_supported_range(self):
        for version in ("18.0", "18.7.10", "26.6.2", "27.0.1", "27.1"):
            result = classify_ios(version)
            self.assertEqual(result["status"], SUPPORTED, version)
            self.assertTrue(result["can_flash"], version)

    def test_too_old(self):
        result = classify_ios("17.6.1")
        self.assertEqual(result["status"], TOO_OLD)
        self.assertFalse(result["can_flash"])

    def test_release_after_transition_is_patched(self):
        for version in ("27.2.1", "27.3", "28.0"):
            result = classify_ios(version)
            self.assertEqual(result["status"], PATCHED, version)
            self.assertFalse(result["can_flash"], version)

    def test_transition_version_without_build_is_unknown(self):
        result = classify_ios("27.2")
        self.assertEqual(result["status"], UNKNOWN)
        self.assertIsNone(result["can_flash"])

    def test_transition_version_resolves_by_build(self):
        with patch.object(aircard_compat, "PATCHED_BUILDS", frozenset({"25C5999z"})), \
                patch.object(aircard_compat, "SUPPORTED_BUILDS", frozenset({"25C5111a"})):
            patched = classify_ios("27.2", "25C5999z")
            supported = classify_ios("27.2", "25C5111a")
        self.assertEqual(patched["status"], PATCHED)
        self.assertEqual(supported["status"], SUPPORTED)

    def test_unparseable_version_is_unknown(self):
        result = classify_ios("Unknown")
        self.assertEqual(result["status"], UNKNOWN)
        self.assertIsNone(result["can_flash"])


class HumanizeErrorTests(unittest.TestCase):
    def test_known_codes(self):
        self.assertEqual(humanize_error("device_helper_missing")["code"], "tools_missing")
        self.assertEqual(humanize_error("no_device")["code"], "no_device")
        self.assertEqual(humanize_error("The device is locked")["code"], "locked")
        self.assertEqual(humanize_error("ValidatePairing failed")["code"], "not_trusted")
        self.assertEqual(humanize_error("airlift probe refused")["code"], "patched")

    def test_fallback_keeps_raw_and_context(self):
        result = humanize_error("exit code 42", context="flash")
        self.assertEqual(result["code"], "unknown")
        self.assertEqual(result["title"], "Flashing failed")
        self.assertEqual(result["raw"], "exit code 42")


class BuildVersionPassthroughTests(unittest.TestCase):
    def test_format_device_passes_build(self):
        dev = format_device({
            "udid": "00008020-ABCDEF",
            "product": "iPhone16,1",
            "version": "27.2",
            "buildVersion": "25C5111a",
        })
        self.assertEqual(dev["build_version"], "25C5111a")

    def test_format_device_missing_build_is_empty(self):
        dev = format_device({"udid": "x", "product": "iPhone16,1", "version": "18.0"})
        self.assertEqual(dev["build_version"], "")


class BackendCompatTests(unittest.TestCase):
    @patch("aircard_backend.find_device_helper", return_value="/bin/device_helper")
    @patch("aircard_backend.native", return_value={"exitCode": 0, "operation": {"ok": True}})
    @patch("aircard_backend.get_connected_device")
    def test_cmd_device_attaches_compat(self, mock_device, mock_native, mock_helper):
        mock_device.return_value = {
            "udid": "u1",
            "product": "iPhone16,1",
            "version": "18.6.2",
            "build_version": "22G100",
        }
        import io
        from contextlib import redirect_stdout

        f = io.StringIO()
        with redirect_stdout(f):
            aircard_backend.cmd_device("u1")
        output = json.loads(f.getvalue().strip())
        self.assertIn("compat", output)
        self.assertEqual(output["compat"]["status"], SUPPORTED)
        self.assertTrue(output["compat"]["can_flash"])


if __name__ == "__main__":
    unittest.main()
