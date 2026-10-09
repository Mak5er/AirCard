import subprocess
import sys
import platform
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(sys.platform == 'darwin', 'Swift model checks require macOS')
class WalletDiscoveryTests(unittest.TestCase):
    def test_identity_order_persistence_and_scanner(self):
        root = Path(__file__).resolve().parents[1]
        sdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk'
        if not Path(sdk).is_dir():
            sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        with tempfile.TemporaryDirectory() as temp:
            binary = str(Path(temp) / 'wallet-tests')
            subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-module-cache-path', str(Path(temp) / 'modules'),
                            str(root / 'Sources/WalletDiscovery.swift'), str(root / 'tests/test_wallet_discovery.swift'),
                            '-o', binary], capture_output=True, text=True, check=True)
            result = subprocess.run([binary], capture_output=True, text=True, check=True)
            self.assertIn('persistence and path parsing passed', result.stdout)

    def test_view_model_device_isolation_and_migration(self):
        root = Path(__file__).resolve().parents[1]
        sdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk'
        if not Path(sdk).is_dir():
            sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        with tempfile.TemporaryDirectory() as temp:
            binary = str(Path(temp) / 'wallet-model-tests')
            subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-module-cache-path', str(Path(temp) / 'modules'),
                            '-D', 'WALLET_TESTS', '-parse-as-library', '-target', platform.machine() + '-apple-macosx13.0',
                            str(root / 'Sources/WalletDiscovery.swift'), str(root / 'Sources/WalletDiagnosticsView.swift'),
                            str(root / 'AirCardApp.swift'), str(root / 'tests/test_wallet_viewmodel.swift'),
                            '-o', binary], capture_output=True, text=True, check=True)
            result = subprocess.run([binary], capture_output=True, text=True, check=True)
            self.assertIn('clear/relaunch passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
