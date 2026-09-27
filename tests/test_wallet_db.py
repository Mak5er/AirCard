import io
import json
import sqlite3
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import aircard
import aircard_backend as backend
import apply_card_skin as skin

CARD = 'a' * 27 + '='
CARD2 = 'b' * 27 + '='
GOOD = {'exitCode': 0, 'targetGatePassed': True, 'operation': {'ok': True}}


def database():
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder) / 'test.sqlite'
        with sqlite3.connect(path) as db:
            db.execute('CREATE TABLE pass (unique_id TEXT, foreground_color TEXT, label_color TEXT, primary_account_suffix TEXT)')
            db.executemany('INSERT INTO pass VALUES (?, ?, ?, ?)', [
                (CARD, 'rgba(255, 255, 255, 1.00)', 'preserve-label', '1234'),
                (CARD2, 'rgba(0, 0, 0, 1.00)', 'preserve-label-2', '5678'),
            ])
        return path.read_bytes()


class WalletDatabaseTests(unittest.TestCase):
    def test_batch_changes_only_requested_values_and_preserves_original_bytes(self):
        original = database()
        prepared = skin.patch_wallet_db_batch(original, [
            {'cardHash': CARD, 'foregroundColor': '#123456', 'requestIndex': 0},
            {'cardHash': CARD2, 'primaryAccountSuffix': '0001', 'requestIndex': 1},
        ])
        self.assertEqual(prepared['originalBytes'], original)
        rows = skin.inspect_wallet_db_batch_bytes(prepared['patchedBytes'], [CARD, CARD2])
        self.assertEqual(rows[0]['foregroundColor'], 'rgba(18, 52, 86, 1.00)')
        self.assertEqual(rows[0]['primaryAccountSuffix'], '1234')
        self.assertEqual(rows[1]['foregroundColor'], 'rgba(0, 0, 0, 1.00)')
        self.assertEqual(rows[1]['primaryAccountSuffix'], '0001')
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'test.sqlite'
            path.write_bytes(prepared['patchedBytes'])
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute('SELECT label_color FROM pass').fetchall(), [('preserve-label',), ('preserve-label-2',)])

    def test_invalid_edits_and_duplicate_cards_are_rejected(self):
        original = database()
        for updates in [
            [{'cardHash': CARD, 'primaryAccountSuffix': '１２３４'}],
            [{'cardHash': CARD, 'primaryAccountSuffix': '123'}],
            [{'cardHash': CARD, 'foregroundColor': 'rgb(256,0,0)'}],
            [{'cardHash': CARD, 'label_color': '#000000'}],
            [{'cardHash': CARD, 'foregroundColor': '#000000'}] * 2,
            [{'cardHash': '../invalid', 'foregroundColor': '#000000'}],
        ]:
            with self.subTest(updates=updates), self.assertRaises(ValueError):
                skin.patch_wallet_db_batch(original, updates)

    def test_stale_database_never_writes_or_rolls_back(self):
        prepared = skin.patch_wallet_db(database(), CARD, '#123456')
        prepared['cardHash'] = CARD
        with patch.object(skin, '_extract_wallet_db_main_without_sidecars', return_value=b'changed'), \
             patch.object(skin, '_write_wallet_db_and_verify') as write, \
             patch.object(skin, 'rollback_wallet_db_patch') as rollback:
            with self.assertRaises(skin.WalletDBPrewriteChangedError):
                skin.apply_wallet_db_patch('device', prepared)
            write.assert_not_called()
            rollback.assert_not_called()

    def test_failed_readback_attempts_rollback(self):
        prepared = skin.patch_wallet_db(database(), CARD, '#123456')
        prepared['cardHash'] = CARD
        with patch.object(skin, '_extract_wallet_db_main_without_sidecars', return_value=prepared['originalBytes']), \
             patch.object(skin, '_write_wallet_db_and_verify', return_value=b'bad readback'), \
             patch.object(skin, 'rollback_wallet_db_patch') as rollback:
            with self.assertRaisesRegex(RuntimeError, '還原成功'):
                skin.apply_wallet_db_patch('device', prepared)
            rollback.assert_called_once_with('device', prepared)

    def test_artwork_failure_rolls_back_single_card_database_change(self):
        prepared = skin.patch_wallet_db(database(), CARD, '#123456')
        prepared['cardHash'] = CARD
        with patch.object(backend, 'prepare_wallet_db_patch', return_value=prepared), \
             patch.object(backend, 'apply_wallet_db_patch'), \
             patch.object(backend, 'cmd_flash_artwork', return_value=False), \
             patch.object(backend, 'rollback_wallet_db_patch') as rollback, redirect_stdout(io.StringIO()):
            self.assertFalse(backend.cmd_flash('device', CARD, __file__, '#123456'))
            rollback.assert_called_once()

    def test_batch_backend_prepares_and_applies_once(self):
        prepared = skin.patch_wallet_db_batch(database(), [
            {'cardHash': CARD, 'foregroundColor': '#123456', 'requestIndex': 0},
            {'cardHash': CARD2, 'primaryAccountSuffix': '9999', 'requestIndex': 1},
        ])
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'updates.json'
            path.write_text(json.dumps([{'cardHash': CARD}]))
            output = io.StringIO()
            with patch.object(backend, 'prepare_wallet_db_batch_patch', return_value=prepared) as prepare, \
                 patch.object(backend, 'apply_wallet_db_batch_patch') as apply, redirect_stdout(output):
                self.assertTrue(backend.cmd_flash_wallet_db_batch('device', str(path)))
            prepare.assert_called_once()
            apply.assert_called_once()
            result = json.loads(output.getvalue().splitlines()[-1])
            self.assertEqual([row['requestIndex'] for row in result['cards']], [0, 1])

    def test_usb_device_is_preferred_and_metadata_is_retained(self):
        devices = [{'udid': 'wifi', 'product': 'iPhone15,2'},
                   {'udid': 'usb', 'product': 'iPhone16,2', 'usb': True, 'language': 'zh-TW', 'bold_text': False}]
        with patch.object(aircard, 'list_devices', return_value=devices):
            result = aircard.get_connected_device()
        self.assertEqual(result['udid'], 'usb')
        self.assertEqual(result['language'], 'zh-TW')
        self.assertIs(result['bold_text'], False)


class ExtractionTests(unittest.TestCase):
    def run_extract(self, restore=True, timeout=False):
        calls = []
        def native(command, udid, *args):
            calls.append(command)
            if command == 'extract':
                Path(args[-1]).write_bytes(b'original')
            return GOOD
        def write(*args, **kwargs):
            calls.append('restore-original')
            return restore
        with tempfile.TemporaryDirectory() as folder, \
             patch.object(skin, 'require_airtraffic_device'), \
             patch.object(skin, 'native', side_effect=native), \
             patch.object(skin, 'write_file', side_effect=write), \
             patch.object(skin, 'run_json', side_effect=TimeoutError('stalled') if timeout else None, return_value={'exitCode': 0, 'ok': True}):
            try:
                result = skin.extract_file('device', skin.WALLET_DB_TARGET, skin.WALLET_DB_LEAF, str(Path(folder) / 'out'), raise_errors=True)
            except (skin.ExtractionRestoreError, TimeoutError):
                result = None
        return calls, result

    def test_original_is_restored_before_recovered_copy_is_deleted(self):
        calls, result = self.run_extract()
        self.assertEqual(result, b'original')
        self.assertLess(calls.index('finish-extract'), calls.index('restore-original'))
        self.assertLess(calls.index('restore-original'), calls.index('discard-extracted'))

    def test_failed_restore_never_deletes_recovered_original(self):
        calls, result = self.run_extract(restore=False)
        self.assertIsNone(result)
        self.assertNotIn('discard-extracted', calls)

    def test_timeout_still_recovers_original_without_retrying_move(self):
        calls, result = self.run_extract(timeout=True)
        self.assertIsNone(result)
        self.assertEqual(calls.count('stage'), 1)
        self.assertIn('restore-original', calls)

    def test_cache_timeout_restores_books_without_retry(self):
        with patch.object(skin, 'require_airtraffic_device'), \
             patch.object(skin, 'native', return_value=GOOD) as native, \
             patch.object(skin, 'run_json_streaming', side_effect=TimeoutError('stalled')) as move:
            with self.assertRaises(TimeoutError):
                skin.remove_files('device', '/target', ['FrontFace'])
        move.assert_called_once()
        self.assertEqual(native.call_args_list[-1].args[0], 'finish-write')

    def test_no_transport_prevents_extraction_and_cache_staging(self):
        with patch.object(skin, 'require_airtraffic_device', side_effect=ConnectionError('offline')), \
             patch.object(skin, 'native') as native:
            with self.assertRaises(ConnectionError):
                skin.extract_file('device', skin.WALLET_DB_TARGET, skin.WALLET_DB_LEAF, '/tmp/unused')
            with self.assertRaises(ConnectionError):
                skin.remove_files('device', '/target', ['FrontFace'])
        native.assert_not_called()

class StagingRaceTests(unittest.TestCase):
    def test_stale_books_snapshot_does_not_authorize_cleanup(self):
        denied = {'exitCode': 2, 'targetGatePassed': True,
                  'operation': {'ok': False, 'cleanupAuthorized': False}}
        for operation in ('extract', 'remove'):
            calls = []
            def native(command, *args):
                calls.append(command)
                return denied if command == 'stage' else GOOD
            with tempfile.TemporaryDirectory() as folder, \
                 patch.object(skin, 'require_airtraffic_device'), \
                 patch.object(skin, 'native', side_effect=native):
                if operation == 'extract':
                    with self.assertRaisesRegex(RuntimeError, '擷取暫存失敗'):
                        skin.extract_file('device', skin.WALLET_DB_TARGET, skin.WALLET_DB_LEAF,
                                          str(Path(folder) / 'out'), raise_errors=True)
                else:
                    self.assertFalse(skin.remove_files('device', '/target', ['FrontFace']))
            self.assertEqual(calls, ['snapshot-books', 'stage'])

    def test_failed_cache_removal_is_not_reported_as_success(self):
        output = io.StringIO()
        with patch.object(backend, 'build_card_assets', return_value=[('test.png', b'png')]), \
             patch.object(backend, 'write_files_batch', return_value=True), \
             patch.object(backend, 'remove_files', return_value=False), redirect_stdout(output):
            self.assertFalse(backend.cmd_flash('device', CARD, __file__))
        self.assertFalse(any(json.loads(line)['type'] == 'success' for line in output.getvalue().splitlines()))

class MissingAssetTests(unittest.TestCase):
    def test_missing_target_is_cleaned_without_rewrite(self):
        calls = []
        target_id = skin.posixpath.relpath(skin.WALLET_DB_TARGET + '/passes23.sqlite-wal', skin.AIRLOCK_ROOT)
        def native(command, *args):
            calls.append(command)
            return GOOD
        with tempfile.TemporaryDirectory() as folder, \
             patch.object(skin, 'require_airtraffic_device'), \
             patch.object(skin, 'native', side_effect=native), \
             patch.object(skin, 'run_json', return_value={'exitCode': 5, 'missingCount': 1, 'missingIdentifiers': [target_id]}), \
             patch.object(skin, 'write_file') as write:
            with self.assertRaises(FileNotFoundError):
                skin.extract_file('device', skin.WALLET_DB_TARGET, 'passes23.sqlite-wal',
                                  str(Path(folder) / 'out'), raise_errors=True)
        write.assert_not_called()
        self.assertEqual(calls, ['snapshot-books', 'stage', 'finish-extract', 'discard-extracted'])

    def test_missing_link_is_not_treated_as_absent_database_sidecar(self):
        with tempfile.TemporaryDirectory() as folder, \
             patch.object(skin, 'require_airtraffic_device'), \
             patch.object(skin, 'native', return_value={'exitCode': 0, 'targetGatePassed': True, 'operation': {'ok': True}}) as native, \
             patch.object(skin, 'run_json', return_value={'exitCode': 5, 'missingCount': 1, 'missingIdentifiers': ['missing-link']}):
            # A failed recovered-file read must fail closed, never imply no WAL.
            def operation(command, *args):
                return {'exitCode': 2, 'operation': {'ok': False}} if command == 'extract' else GOOD
            native.side_effect = operation
            with self.assertRaises(skin.ExtractionRestoreError):
                skin.extract_file('device', skin.WALLET_DB_TARGET, 'passes23.sqlite-wal',
                                  str(Path(folder) / 'out'), raise_errors=True)
        self.assertNotIn('discard-extracted', [call.args[0] for call in native.call_args_list])

class HiddenSuffixTests(unittest.TestCase):
    def test_json_null_hides_suffix_without_changing_other_columns(self):
        original = database()
        updates = json.loads(json.dumps([{'cardHash': CARD, 'primaryAccountSuffix': None}]))
        prepared = skin.patch_wallet_db_batch(original, updates)
        rows = skin.inspect_wallet_db_batch_bytes(prepared['patchedBytes'], [CARD, CARD2])
        self.assertIsNone(rows[0]['primaryAccountSuffix'])
        self.assertEqual(rows[0]['foregroundColor'], 'rgba(255, 255, 255, 1.00)')
        self.assertEqual(rows[1]['primaryAccountSuffix'], '5678')
        self.assertEqual(prepared['originalBytes'], original)

    def test_legacy_cli_null_token_remains_supported(self):
        prepared = skin.patch_wallet_db(database(), CARD, primary_account_suffix='NULL')
        self.assertIsNone(skin.inspect_wallet_db_bytes(prepared['patchedBytes'], CARD)['primaryAccountSuffix'])

    def test_omitted_suffix_preserves_value_and_custom_digits_restore_it(self):
        hidden = skin.patch_wallet_db(database(), CARD, primary_account_suffix=None)
        color_only = skin.patch_wallet_db(hidden['patchedBytes'], CARD, '#112233')
        self.assertIsNone(skin.inspect_wallet_db_bytes(color_only['patchedBytes'], CARD)['primaryAccountSuffix'])
        restored = skin.patch_wallet_db(color_only['patchedBytes'], CARD, primary_account_suffix='1234')
        result = skin.inspect_wallet_db_bytes(restored['patchedBytes'], CARD)
        self.assertEqual(result['primaryAccountSuffix'], '1234')
        self.assertEqual(result['foregroundColor'], 'rgba(17, 34, 51, 1.00)')

    def test_empty_or_invalid_custom_suffix_is_not_silently_hidden(self):
        for suffix in ['', ' ', '12', '12345', '１２３４']:
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                skin.normalize_primary_account_suffix(suffix)

    def test_hide_without_artwork_emits_null_and_never_flashes_an_image(self):
        prepared = skin.patch_wallet_db(database(), CARD, primary_account_suffix=None)
        prepared['cardHash'] = CARD
        output = io.StringIO()
        with patch.object(backend, 'prepare_wallet_db_patch', return_value=prepared) as prepare, \
             patch.object(backend, 'apply_wallet_db_patch'), \
             patch.object(backend, 'cmd_flash_artwork') as artwork, redirect_stdout(output):
            self.assertTrue(backend.cmd_flash('device', CARD, '-', primary_account_suffix=None))
        self.assertIsNone(prepare.call_args.args[3])
        artwork.assert_not_called()
        result = json.loads(output.getvalue().splitlines()[-1])
        self.assertEqual(result['type'], 'success')
        self.assertIsNone(result['appliedPrimaryAccountSuffix'])

class OptionalSidecarRegressionTests(unittest.TestCase):
    """Reproduce the advertised-but-absent journal from the device report."""
    missing = {
        'exitCode': 2, 'targetGatePassed': True,
        'operation': {'ok': False, 'reasonCode': 'file_not_found', 'afcStatus': 8, 'reason': '找不到檔案'},
    }
    dispatched = {'exitCode': 0, 'ok': True, 'syncAllowed': True,
                  'readyForSync': True, 'fileCompleteMessages': 2}
    cleaned_absent = {'exitCode': 0, 'targetGatePassed': True,
                      'operation': {'ok': True, 'recoveredAbsent': True, 'recoveredStatStatus': 8}}

    def extract(self, folder, *, leaf='passes23.sqlite-journal', response=None,
                transport=None, cleanup=None, transport_error=None):
        calls = []
        def native(command, udid, *args):
            calls.append(command)
            if command == 'extract':
                return self.missing if response is None else response
            if command == 'finish-extract':
                return self.cleaned_absent if cleanup is None else cleanup
            return GOOD
        output = str(Path(folder) / leaf)
        with patch.object(skin, 'require_airtraffic_device'), \
             patch.object(skin, 'native', side_effect=native), \
             patch.object(skin, 'run_json', return_value=self.dispatched if transport is None else transport,
                          side_effect=transport_error), \
             patch.object(skin, 'write_file') as write:
            try:
                result = skin.extract_file('device', skin.WALLET_DB_TARGET, leaf, output, raise_errors=True)
            except Exception as error:
                result = error
        return result, calls, write

    def test_absent_optional_journal_is_not_a_restore_failure(self):
        for leaf in skin.WALLET_DB_SIDECARS:
            with self.subTest(leaf=leaf), tempfile.TemporaryDirectory() as folder:
                result, calls, write = self.extract(folder, leaf=leaf)
            self.assertIsInstance(result, FileNotFoundError)
            self.assertNotIsInstance(result, skin.ExtractionRestoreError)
            self.assertEqual(calls, ['snapshot-books', 'stage', 'extract', 'finish-extract'])
            write.assert_not_called()

    def test_main_database_not_found_still_stops(self):
        with tempfile.TemporaryDirectory() as folder:
            result, calls, write = self.extract(folder, leaf=skin.WALLET_DB_LEAF)
        self.assertIsInstance(result, skin.ExtractionRestoreError)
        self.assertIn('無法確認原位置檔案狀態', str(result))
        self.assertIn('AFC=8', str(result))
        self.assertNotIn('discard-extracted', calls)
        write.assert_not_called()

    def test_permission_transport_and_untyped_errors_cannot_be_treated_as_absence(self):
        responses = [
            {'exitCode': 2, 'targetGatePassed': True,
             'operation': {'ok': False, 'reasonCode': 'afc_stat_failed', 'afcStatus': 10}},
            {'exitCode': 2, 'targetGatePassed': True,
             'operation': {'ok': False, 'reasonCode': 'afc_stat_failed', 'afcStatus': 12}},
            {'exitCode': 2, 'targetGatePassed': True, 'operation': {'ok': False, 'reason': '找不到檔案'}},
            {'exitCode': 2, 'targetGatePassed': False,
             'operation': {'ok': False, 'reasonCode': 'file_not_found', 'afcStatus': 8}},
        ]
        for response in responses:
            with self.subTest(response=response), tempfile.TemporaryDirectory() as folder:
                result, calls, write = self.extract(folder, response=response)
            self.assertIsInstance(result, skin.ExtractionRestoreError)
            self.assertNotIn('discard-extracted', calls)
            write.assert_not_called()

    def test_failed_incomplete_or_timed_out_dispatch_is_not_optional_absence(self):
        transports = [
            ({'exitCode': 4, 'ok': False}, None),
            ({'exitCode': 0, 'ok': True}, None),
            ({**self.dispatched, 'fileCompleteMessages': 1}, None),
            (None, subprocess.TimeoutExpired('AirTraffic', 120)),
        ]
        for transport, error in transports:
            with self.subTest(transport=transport, error=error), tempfile.TemporaryDirectory() as folder:
                result, calls, write = self.extract(folder, transport=transport, transport_error=error)
            self.assertIsInstance(result, skin.ExtractionRestoreError)
            self.assertNotIn('discard-extracted', calls)

    def test_cleanup_must_confirm_absence_without_hiding_a_late_file(self):
        for cleanup in [GOOD,
                        {'exitCode': 0, 'targetGatePassed': True, 'operation': {'ok': True, 'recoveredAbsent': False, 'recoveredStatStatus': 0}},
                        {'exitCode': 0, 'targetGatePassed': True, 'operation': {'ok': True, 'recoveredAbsent': True, 'recoveredStatStatus': 10}}]:
            with self.subTest(cleanup=cleanup), tempfile.TemporaryDirectory() as folder:
                result, calls, write = self.extract(folder, cleanup=cleanup)
            self.assertIsInstance(result, skin.ExtractionRestoreError)
            self.assertNotIn('discard-extracted', calls)
            write.assert_not_called()

    def test_existing_even_empty_sidecars_block_database_writes(self):
        for contents in [b'', b'journal data']:
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as folder, \
                 patch.object(skin, '_extract_optional_wallet_db_sidecar', return_value=contents):
                with self.assertRaisesRegex(RuntimeError, '已停止寫入'):
                    skin._require_wallet_db_sidecars_absent('device', Path(folder), 'prepare')

    def test_optional_wrapper_only_swallows_actual_file_not_found(self):
        with patch.object(skin, 'extract_file', side_effect=FileNotFoundError('optional journal absent')):
            self.assertIsNone(skin._extract_optional_wallet_db_sidecar('device', 'passes23.sqlite-journal', Path('/unused'), 'prepare'))
        with patch.object(skin, 'extract_file', side_effect=skin.ExtractionRestoreError('recovery unknown')):
            with self.assertRaises(RuntimeError):
                skin._extract_optional_wallet_db_sidecar('device', 'passes23.sqlite-journal', Path('/unused'), 'prepare')


class WalletProgressTests(unittest.TestCase):
    def run_batch(self, fail_write=False):
        original = database()
        updates = [{'cardHash': CARD, 'primaryAccountSuffix': None}]
        prepared = skin.patch_wallet_db_batch(original, updates)
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'updates.json'
            path.write_text(json.dumps(updates))
            with patch.object(skin, 'extract_file', side_effect=[original, original, prepared['patchedBytes']]), \
                 patch.object(skin, '_extract_optional_wallet_db_sidecar', return_value=None), \
                 patch.object(skin, 'write_file', return_value=not fail_write), \
                 patch.object(skin, 'rollback_wallet_db_patch') as rollback, redirect_stdout(output):
                result = backend.cmd_flash_wallet_db_batch('device', str(path))
                self.assertEqual(rollback.called, fail_write)
        self.assertIsNone(skin._wallet_db_progress.get())
        return result, [json.loads(line) for line in output.getvalue().splitlines()]

    def test_progress_tracks_real_stages_and_only_completes_after_verification(self):
        result, events = self.run_batch()
        self.assertTrue(result)
        progress = [event for event in events if event['type'] == 'progress']
        self.assertTrue(all(event['step'] < event['total'] for event in progress))
        self.assertEqual(sorted({event['step'] for event in progress}), list(range(14)))
        self.assertEqual(events[-1]['type'], 'success')
        self.assertEqual(events[-1]['step'], events[-1]['total'])
        self.assertTrue(any('寫入後讀回驗證' in event['message'] for event in progress))

    def test_failure_never_reports_completion_and_restores_observer(self):
        result, events = self.run_batch(fail_write=True)
        self.assertFalse(result)
        self.assertFalse(any(event['type'] == 'success' for event in events))
        self.assertTrue(all(event['step'] < event['total'] for event in events if 'step' in event))

    def test_rollback_status_does_not_advance_progress(self):
        events = []
        with skin.wallet_db_progress(lambda step, message: events.append((step, message))):
            skin._report_wallet_db_progress('rollback-current')
        self.assertEqual(events[0][0], None)
        self.assertIn('還原', events[0][1])
