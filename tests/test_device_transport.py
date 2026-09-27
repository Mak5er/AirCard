import unittest
from unittest.mock import patch
import apply_card_skin as skin


class TransportTests(unittest.TestCase):
    def test_actual_handshake_is_required(self):
        for result, passes in [({'exitCode': 0, 'ok': True, 'syncAllowed': True}, True),
                               ({'exitCode': 124, 'ok': False, 'error': 'timeout'}, False),
                               ({'exitCode': 0, 'ok': True}, False)]:
            with self.subTest(result=result), patch.object(skin, 'run_json', return_value=result) as run:
                if passes:
                    skin.require_airtraffic_device('device')
                else:
                    with self.assertRaises(ConnectionError):
                        skin.require_airtraffic_device('device')
                self.assertEqual(run.call_args.args[0][1:], ['--probe', 'device'])

    def test_missing_transport_prevents_staging(self):
        with patch.object(skin, 'require_airtraffic_device', side_effect=ConnectionError('No handshake')), patch.object(skin, 'native') as native:
            with self.assertRaises(ConnectionError):
                skin.write_files_batch('device', '/target', [('a', b'b')], progress_callback=lambda _: None)
            native.assert_not_called()
