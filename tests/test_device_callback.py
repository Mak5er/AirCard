import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires macOS')
class DeviceCallbackTests(unittest.TestCase):
    def test_late_notifications_cannot_access_released_target(self):
        harness = pathlib.Path(__file__).with_name('device_callback_harness.m')
        with tempfile.TemporaryDirectory() as folder:
            binary = str(pathlib.Path(folder) / 'callback-test')
            subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-O1', '-framework', 'Foundation', '-framework', 'CoreFoundation', '/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice', str(harness), '-o', binary], check=True, capture_output=True, timeout=60)
            result = subprocess.run([binary], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn('callback teardown checks passed', result.stdout)
