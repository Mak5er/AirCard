import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(sys.platform == "darwin", "Native diagnostics require macOS")
class NativeDiagnosticTests(unittest.TestCase):
    def test_status_snapshot_and_guarded_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "native-diagnostics"
            subprocess.run(
                ["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                 "-framework", "Foundation", "-framework", "CoreFoundation",
                 "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
                 str(Path(__file__).with_suffix(".m")), "-o", str(binary)],
                check=True, capture_output=True, text=True,
            )
            result = subprocess.run([str(binary), temporary], check=True, capture_output=True, text=True)
            self.assertIn("guarded cleanup checks passed", result.stdout)
