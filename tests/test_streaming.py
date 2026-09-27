import io
import json
import subprocess
import sys
import time
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

import apply_card_skin as skin
import aircard_backend as backend


class StreamingTests(unittest.TestCase):
    def setUp(self):
        check = patch.object(skin, 'require_airtraffic_device')
        check.start()
        self.addCleanup(check.stop)

    def run_helper(self, script, timeout=3, callback=None):
        return skin.run_json_streaming([sys.executable, '-u', '-c', script], timeout, callback)

    def test_silent_and_partial_output_have_deadline(self):
        for output in ('', '{"ok":'):
            with self.subTest(output=output):
                start = time.monotonic()
                with self.assertRaises(TimeoutError):
                    self.run_helper(f'import time; print({output!r}, end="", flush=True); time.sleep(10)', .2)
                self.assertLess(time.monotonic() - start, 2)

    def test_stderr_is_drained_and_final_unterminated_json_is_parsed(self):
        result = self.run_helper('import sys; sys.stderr.write("x" * 1000000); print(\'{"ok":true}\', end="")')
        self.assertTrue(result['ok'])
        self.assertEqual(result['exitCode'], 0)

    def test_progress_is_delivered_before_completion(self):
        events = []
        with self.assertRaises(TimeoutError):
            self.run_helper('import time; print(\'{"type":"atc_status","message":"Waiting"}\'); time.sleep(10)', .2, events.append)
        self.assertEqual(events[0]['message'], 'Waiting')

    def test_progress_alone_is_not_a_final_result(self):
        with self.assertRaises(RuntimeError):
            self.run_helper('print(\'{"type":"atc_progress","index":1}\')')

    def test_batch_restores_snapshot_on_timeout_without_retry(self):
        good = {'exitCode': 0, 'targetGatePassed': True, 'operation': {'ok': True}}
        with (
            patch.object(skin, 'native', return_value=good) as native,
            patch.object(skin, 'run_json_streaming', side_effect=TimeoutError('stalled')) as run,
        ):
            with self.assertRaises(TimeoutError):
                skin.write_files_batch('device', '/target', [('test.png', b'image')], progress_callback=lambda _: None)
        self.assertEqual([call.args[0] for call in native.call_args_list], ['snapshot-books', 'stage', 'finish-write'])
        run.assert_called_once()

    def test_single_write_restores_snapshot_on_timeout_without_retry(self):
        good = {'exitCode': 0, 'targetGatePassed': True, 'operation': {'ok': True}}
        with (
            patch.object(skin, 'native', return_value=good) as native,
            patch.object(skin, 'run_json', side_effect=subprocess.TimeoutExpired('helper', 120)),
        ):
            with self.assertRaises(subprocess.TimeoutExpired):
                skin.write_file('device', '/target', 'test.png', b'image')
        self.assertEqual([call.args[0] for call in native.call_args_list], ['snapshot-books', 'stage', 'finish-write'])

    def test_card_timeout_does_not_fall_back_to_more_writes(self):
        output = io.StringIO()
        with (
            patch.object(backend, 'build_card_assets', return_value=[('test.png', b'image')]),
            patch.object(backend, 'write_files_batch', side_effect=TimeoutError('stalled')),
            patch.object(backend, 'write_file') as single,
            redirect_stdout(output),
        ):
            self.assertFalse(backend.cmd_flash('device', 'aaaaaaaaaaaaaaaaaaaaaaaaaaa=', __file__))
        single.assert_not_called()
        self.assertEqual(json.loads(output.getvalue().splitlines()[-1])['type'], 'error')

    def test_card_batch_progress_counts_all_assets(self):
        def batch(udid, target, files, progress_callback):
            progress_callback({'type': 'atc_status', 'message': 'Waiting for SyncAllowed...'})
            for index, (leaf, _) in enumerate(files, 1):
                progress_callback({'type': 'atc_progress', 'index': index, 'leaf': leaf})
            return True

        output = io.StringIO()
        with (
            patch.object(backend, 'build_card_assets', return_value=[('a', b'1'), ('b', b'2'), ('c', b'3')]),
            patch.object(backend, 'write_files_batch', side_effect=batch),
            patch.object(backend, 'remove_files', return_value=True),
            redirect_stdout(output),
        ):
            self.assertTrue(backend.cmd_flash('device', 'aaaaaaaaaaaaaaaaaaaaaaaaaaa=', __file__))
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        steps = [event['step'] for event in events if event['type'] == 'progress']
        self.assertEqual(steps, sorted(steps))
        self.assertEqual(set(steps), set(range(1, 7)))
        self.assertEqual(events[-1]['step'], events[-1]['total'])


if __name__ == '__main__':
    unittest.main()


class HelperCrashDiagnosticsTests(unittest.TestCase):
    def test_crash_includes_operation_exit_code_and_signal_without_udid(self):
        completed = subprocess.CompletedProcess([], -5, '', '')
        with patch.object(skin.subprocess, 'run', return_value=completed):
            with self.assertRaisesRegex(RuntimeError, r'device_helper finish-write.*退出碼 -5.*SIGTRAP.*未提供錯誤輸出') as caught:
                skin.run_json(['/some/device_helper', 'finish-write', 'private-device-id'], 60)
            self.assertNotIn('private-device-id', str(caught.exception))

    def test_crash_after_json_is_not_success(self):
        completed = subprocess.CompletedProcess([], -5, '{"ok": true}', '')
        with patch.object(skin.subprocess, 'run', return_value=completed):
            with self.assertRaisesRegex(RuntimeError, 'SIGTRAP'):
                skin.run_json(['/some/device_helper', 'stage'], 60)
