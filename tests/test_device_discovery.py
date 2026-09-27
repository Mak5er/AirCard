import io
import json
import subprocess
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

import aircard
import aircard_backend as backend


class DeviceDiscoveryTests(unittest.TestCase):
    def test_numeric_bold_setting_is_normalized_to_json_boolean(self):
        for raw, expected in [(0, False), (1, True), (False, False), (True, True), (None, None), ('unknown', None)]:
            with self.subTest(raw=raw), patch.object(aircard, 'list_devices', return_value=[
                {'udid': 'test', 'product': 'iPhone18,2', 'bold_text': raw}
            ]):
                result = aircard.get_connected_device()
                self.assertIs(json.loads(json.dumps(result))['bold_text'], expected)

    def test_discovery_failure_is_distinct_from_no_phone(self):
        with patch.object(aircard, 'find_device_helper', return_value='/helper'), \
             patch.object(aircard.subprocess, 'run', return_value=subprocess.CompletedProcess([], 2, '[]\n', 'MobileDevice discovery subscription failed')):
            with self.assertRaisesRegex(aircard.DeviceDiscoveryError, 'subscription failed'):
                aircard.list_devices(raise_errors=True)
            self.assertEqual(aircard.list_devices(), [])

    def test_discovery_timeout_has_actionable_error(self):
        with patch.object(aircard, 'find_device_helper', return_value='/helper'), \
             patch.object(aircard.subprocess, 'run', side_effect=subprocess.TimeoutExpired('helper', 15)):
            with self.assertRaisesRegex(aircard.DeviceDiscoveryError, '超時'):
                aircard.list_devices(raise_errors=True)

    def test_untrusted_device_is_not_silently_discarded(self):
        with patch.object(aircard, 'list_devices', return_value=[{'udid': 'test'}]):
            with self.assertRaisesRegex(aircard.DeviceDiscoveryError, '信任'):
                aircard.get_connected_device(raise_errors=True)

    def test_connected_device_does_not_wait_for_afc_probe(self):
        output = io.StringIO()
        with patch.object(backend, 'find_device_helper', return_value='/helper'), \
             patch.object(backend, 'get_connected_device', return_value={'udid': 'test', 'product': 'iPhone18,2', 'bold_text': False}), \
             patch.object(backend, 'native') as native, redirect_stdout(output):
            backend.cmd_device()
        self.assertTrue(json.loads(output.getvalue())['connected'])
        native.assert_not_called()

    def test_backend_returns_discovery_diagnostic_as_valid_json(self):
        output = io.StringIO()
        with patch.object(backend, 'find_device_helper', return_value='/helper'), \
             patch.object(backend, 'get_connected_device', side_effect=aircard.DeviceDiscoveryError('service unavailable')), redirect_stdout(output):
            backend.cmd_device()
        result = json.loads(output.getvalue())
        self.assertFalse(result['connected'])
        self.assertEqual(result['error'], 'device_discovery_failed')
        self.assertEqual(result['error_message'], 'service unavailable')

    def test_empty_enumeration_is_an_ordinary_disconnected_state(self):
        with patch.object(aircard, 'list_devices', return_value=[]):
            self.assertIsNone(aircard.get_connected_device(raise_errors=True))
