"""Run SwiftUI binding regression checks on macOS without launching the app."""
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin", "SwiftUI requires macOS")
class WalletCardBindingTests(unittest.TestCase):
    def test_deleted_rows_remain_safe(self):
        root = Path(__file__).resolve().parents[1]
        sdk = os.environ.get("SWIFT_SDK")
        if not sdk:
            clt_sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk")
            sdk = str(clt_sdk) if clt_sdk.exists() else subprocess.check_output(
                ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
            ).strip()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "AirCardApp.swift"
            # Keep the entire production implementation; only replace its entry
            # point with the regression executable's @main. No app/device startup.
            source.write_text((root / "AirCardApp.swift").read_text().replace("@main\n", ""))
            binary = Path(directory) / "binding-tests"
            flags = ["-D", "LEGACY_INDEX_BINDINGS"] if os.environ.get("AIRCARD_TEST_LEGACY_BINDINGS") else []
            compiled = subprocess.run([
                "swiftc", "-sdk", sdk, "-parse-as-library",
                "-target", platform.machine() + "-apple-macosx13.0", *flags,
                str(source),
                str(root / "Sources/WalletDiscovery.swift"),
                str(root / "Sources/WalletDiagnosticsView.swift"),
                str(root / "tests/WalletCardBindingTests.swift"),
                "-o", str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS:", result.stdout)


if __name__ == "__main__":
    unittest.main()
