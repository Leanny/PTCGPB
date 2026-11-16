"""Offline safety checks; these never invoke a real emulator."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
from PIL import Image

spec = importlib.util.spec_from_file_location('trade_worker', Path(__file__).parents[1] / 'trade_worker.py')
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)

class MatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = {}
        for index, state in enumerate(w.STATES):
            filename = state + '.png'
            Image.new('RGB', (10, 10), (index*20, 0, 0)).save(self.root/filename)
            self.manifest[state] = [{'box': [0, 0, 10, 10], 'file': filename, 'max_mae': 0}]

    def matcher(self):
        (self.root/'manifest.json').write_text(json.dumps(self.manifest))
        return w.Matcher(self.root/'manifest.json')

    def test_unknown_is_not_actionable(self):
        self.assertIsNone(self.matcher().classify(Image.new('RGB', (540, 960), 'white')))

    def test_unique_screen(self):
        self.assertEqual('preview', self.matcher().classify(Image.new('RGB', (540, 960), 'black')))

    def test_ambiguity_stops(self):
        self.manifest['received'] = self.manifest['preview']
        with self.assertRaisesRegex(w.TradeError, 'Ambiguous'):
            self.matcher().classify(Image.new('RGB', (540, 960), 'black'))

    def test_same_state_card_swap_invalidates_approval(self):
        original = Image.new('RGB', (540, 960), 'black')
        changed = original.copy()
        changed.paste('white', (110, 230, 432, 680))
        self.assertFalse(w.same_verified_content(original, changed, 'preview'))
        self.assertTrue(w.same_verified_content(original, original.copy(), 'preview'))

    def test_same_state_recipient_swap_invalidates_approval(self):
        original = Image.new('RGB', (540, 960), 'black')
        changed = original.copy()
        changed.paste('white', (335, 150, 485, 205))
        self.assertFalse(w.same_verified_content(original, changed, 'response'))

    def test_small_name_or_version_edit_invalidates_approval(self):
        original = Image.new('RGB', (540, 960), 'white')
        for box in [(311, 181, 321, 202), (128, 645, 136, 653)]:
            changed = original.copy()
            changed.paste('black', box)
            self.assertFalse(w.same_verified_content(original, changed, 'preview'))

    def test_wrong_resolution_stops(self):
        with self.assertRaisesRegex(w.TradeError, '540x960'):
            self.matcher().classify(Image.new('RGB', (1080, 1920)))

class FakeAdb:
    def __init__(self):
        self.actions = []
    def act(self, state):
        self.actions.append(state)
        raise KeyboardInterrupt()

class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.adb = FakeAdb()

    def worker(self, **kwargs):
        return w.Worker(self.adb, None, self.root, 'Example card set #1 star',
                        'Example recipient', time.monotonic()+60, **kwargs)

    def test_interrupt_during_action_leaves_pending_and_blocks_replay(self):
        worker = self.worker()
        worker.capture = lambda: ('preview', self.root/'frame.png')
        with self.assertRaises(KeyboardInterrupt):
            worker.mutate('preview')
        self.assertEqual('action_pending', json.loads(worker.journal.read_text())['status'])
        with self.assertRaisesRegex(w.TradeError, 'reconcile manually'):
            self.worker()
        self.assertEqual(['preview'], self.adb.actions)

    def test_screen_changed_no_action(self):
        worker = self.worker()
        worker.capture = lambda: ('received', self.root/'frame.png')
        with self.assertRaisesRegex(w.TradeError, 'Screen changed'):
            worker.mutate('preview')
        self.assertEqual([], self.adb.actions)

    def test_invalid_transition_does_not_settle_journal(self):
        worker = self.worker()
        states = iter(['preview', 'received'])
        worker.capture = lambda: (next(states), self.root/'frame.png')
        self.adb.act = lambda state: self.adb.actions.append(state)
        with patch.object(w.time, 'sleep'), self.assertRaisesRegex(w.TradeError, 'Unexpected transition'):
            worker.mutate('preview')
        self.assertEqual('action_pending', json.loads(worker.journal.read_text())['status'])
        self.assertEqual(['preview'], self.adb.actions)

    def test_unchanged_screen_never_repeats_submission(self):
        worker = self.worker()
        worker.capture = lambda: ('preview', self.root/'frame.png')
        self.adb.act = lambda state: self.adb.actions.append(state)
        with patch.object(w.time, 'sleep'), patch.object(w.time, 'monotonic', side_effect=[0, 0, 46]):
            with self.assertRaisesRegex(w.TradeError, 'remains pending'):
                worker.mutate('preview')
        self.assertEqual(['preview'], self.adb.actions)
        self.assertEqual('action_pending', json.loads(worker.journal.read_text())['status'])

    def test_initial_wrong_screen_does_not_click(self):
        worker = self.worker()
        worker.capture = lambda: ('waiting', self.root/'frame.png')
        with self.assertRaisesRegex(w.TradeError, 'Start at'):
            worker.run()
        self.assertEqual([], self.adb.actions)

    def test_last_copy_defaults_to_stop(self):
        worker = self.worker()
        worker.capture = lambda: ('preview', self.root/'frame.png')
        worker.authorize = lambda *args: None
        worker.mutate = lambda state: ('last_copy', self.root/'frame.png')
        with self.assertRaisesRegex(w.TradeError, '--allow-last-copy'):
            worker.run()
        self.assertEqual([], self.adb.actions)

    def test_declined_confirmation_does_not_click(self):
        worker = self.worker(confirm=lambda prompt: 'no')
        worker.capture = lambda: ('preview', self.root/'frame.png')
        with self.assertRaisesRegex(w.TradeError, 'declined'):
            worker.run()
        self.assertEqual([], self.adb.actions)

    def test_inspect_accepts_existing_pending_journal(self):
        w.atomic_json(self.root/'journal.json', {'status': 'action_pending'})
        self.worker(inspect=True)
        self.assertEqual({'status': 'action_pending'}, json.loads((self.root/'journal.json').read_text()))

    def test_complete_protocol_and_phone_rendezvous(self):
        worker = self.worker(allow_last_copy=True)
        states = iter(['preview', 'set_confirmation', 'last_copy', 'offered',
                       'waiting', 'response', 'final_confirmation', 'swipe', 'received'])
        current = [next(states)]
        approvals = []
        worker.capture = lambda: (current[0], self.root/'frame.png')
        worker.authorize = lambda state, path: approvals.append(state)
        def act(state):
            self.adb.actions.append(state)
            current[0] = next(states)
        self.adb.act = act
        with patch.object(w.time, 'sleep'):
            worker.run()
        self.assertEqual(['preview', 'response'], approvals)
        self.assertEqual(list(w.ACTIONS), self.adb.actions)
        self.assertEqual('completed', json.loads(worker.journal.read_text())['status'])

    def test_lock_excludes_second_worker_and_releases(self):
        with w.device_lock('fake-device', self.root):
            with self.assertRaises(w.TradeError):
                with w.device_lock('fake-device', self.root):
                    self.fail('Acquired occupied lock')
        with w.device_lock('fake-device', self.root):
            pass

class AdbTests(unittest.TestCase):
    def test_expired_session_never_calls_subprocess(self):
        adb = w.Adb('adb', 'fake', time.monotonic()-1)
        with patch.object(w.subprocess, 'run') as run, self.assertRaises(w.TradeError):
            adb.act('preview')
        run.assert_not_called()

    def test_adb_timeout_is_failure(self):
        adb = w.Adb('adb', 'fake', time.monotonic()+60)
        with patch.object(w.subprocess, 'run', side_effect=subprocess.TimeoutExpired('adb', 1)), self.assertRaises(w.TradeError):
            adb.act('preview')

    def test_invalid_capture_is_failure(self):
        adb = w.Adb('adb', 'fake', time.monotonic()+60)
        with patch.object(adb, 'run', return_value=b'not an image'), self.assertRaises(w.TradeError):
            adb.capture()

if __name__ == '__main__':
    unittest.main()
