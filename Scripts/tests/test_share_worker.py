"""Offline share protocol checks; no real emulator or recipient is contacted."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from PIL import Image

sys.path.insert(0, str(Path(__file__).parents[1]))
import share_worker as s
import trade_worker as t


class Device:
    def __init__(self, last_copy=False):
        self.states = iter(['confirmation'] + (['last_copy'] if last_copy else []) + ['swipe', 'sent'])
        self.state = 'preview'
        self.actions = []
        self.change = False

    def capture(self):
        frame = Image.new('RGB', (540, 960), 'white')
        frame.paste((s.STATES.index(self.state)*40, 0, 0), (0, 0, 10, 10))
        if self.change:
            frame.paste('black', (125, 600, 133, 608))
        return frame

    def act(self, state):
        self.actions.append(state)
        self.state = next(self.states)


class ShareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        manifest = {}
        for i, state in enumerate(s.STATES):
            Image.new('RGB', (10, 10), (i*40, 0, 0)).save(self.root/(state+'.png'))
            manifest[state] = [{'box': [0, 0, 10, 10], 'file': state+'.png', 'max_mae': 0}]
        self.manifest = self.root/'manifest.json'
        self.manifest.write_text(json.dumps(manifest))
        self.matcher = t.Matcher(self.manifest, s.STATES)
        self.device = Device()
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def worker(self, **kwargs):
        return s.ShareWorker(self.device, self.matcher, self.root/'run',
                             'Card set #1 foil', 'Recipient', time.monotonic()+60,
                             confirm=lambda prompt: 'Card set #1 foil | Recipient', **kwargs)

    def test_success_requires_sent_toast_and_records_evidence(self):
        worker = self.worker()
        with patch.object(t.time, 'sleep'):
            worker.run()
        self.assertEqual(['preview', 'confirmation', 'swipe'], self.device.actions)
        record = json.loads(worker.journal.read_text())
        self.assertEqual(('completed', 'sent'), (record['status'], record['state']))
        self.assertTrue(Path(record['capture']).is_file())

    def test_last_copy_requires_opt_in_before_warning_action(self):
        self.device = Device(last_copy=True)
        worker = self.worker()
        with patch.object(t.time, 'sleep'), self.assertRaisesRegex(t.TradeError, '--allow-last-copy'):
            worker.run()
        self.assertEqual(['preview', 'confirmation'], self.device.actions)
        self.assertNotEqual('completed', json.loads(worker.journal.read_text())['status'])

    def test_explicit_last_copy_completes_protocol(self):
        self.device = Device(last_copy=True)
        with patch.object(t.time, 'sleep'):
            self.worker(allow_last_copy=True).run()
        self.assertEqual(list(s.ACTIONS), self.device.actions)

    def test_changed_card_after_confirmation_does_not_click(self):
        worker = self.worker()
        state, path = worker.capture()
        worker.authorize(state, path)
        self.device.change = True
        with self.assertRaisesRegex(t.TradeError, 'image changed'):
            worker.mutate('preview')
        self.assertEqual([], self.device.actions)

    def test_small_recipient_change_fails_tile_guard(self):
        reference = self.device.capture()
        changed = reference.copy()
        changed.paste('black', (230, 125, 238, 133))
        self.assertFalse(t.same_verified_content(reference, changed, 'preview', s.VERIFICATION_REGIONS))

    def test_interrupted_swipe_stays_pending_and_cannot_replay(self):
        worker = self.worker()
        self.device.state = 'swipe'
        def interrupt(state):
            self.device.actions.append(state)
            raise KeyboardInterrupt()
        self.device.act = interrupt
        with self.assertRaises(KeyboardInterrupt):
            worker.mutate('swipe')
        self.assertEqual('action_pending', json.loads(worker.journal.read_text())['status'])
        with self.assertRaisesRegex(t.TradeError, 'reconcile manually'):
            self.worker()
        self.assertEqual(['swipe'], self.device.actions)

    def test_unrecognized_after_swipe_never_completes_or_resends(self):
        worker = self.worker()
        frame = self.root/'unknown.png'
        states = iter([('swipe', frame), (None, frame)])
        worker.capture = lambda: next(states)
        self.device.act = lambda state: self.device.actions.append(state)
        with patch.object(t.time, 'sleep'), patch.object(t.time, 'monotonic', side_effect=[0, 0, 46]):
            with self.assertRaisesRegex(t.TradeError, 'remains pending'):
                worker.mutate('swipe')
        self.assertEqual(['swipe'], self.device.actions)
        self.assertEqual('action_pending', json.loads(worker.journal.read_text())['status'])

    def test_ambiguous_sent_toast_stops(self):
        raw = json.loads(self.manifest.read_text())
        raw['preview'] = raw['sent']
        self.manifest.write_text(json.dumps(raw))
        self.device.state = 'sent'
        matcher = t.Matcher(self.manifest, s.STATES)
        with self.assertRaisesRegex(t.TradeError, 'Ambiguous'):
            matcher.classify(self.device.capture())

    def test_unknown_start_does_not_click(self):
        worker = self.worker()
        self.device.state = 'sent'
        with self.assertRaisesRegex(t.TradeError, 'Start at'):
            worker.run()
        self.assertEqual([], self.device.actions)

    def test_share_and_trade_exclude_each_other(self):
        with t.device_lock('device', self.root):
            with self.assertRaises(t.TradeError):
                with s.device_lock('device', self.root):
                    self.fail('Share must use the same lock as trade')

    def test_share_adb_uses_share_preview_button(self):
        adb = s.ShareAdb('adb', 'device', time.monotonic()+60)
        with patch.object(adb, 'run') as run:
            adb.act('preview')
        run.assert_called_once_with('shell', 'input', 'tap', '270', '822')

    def test_cli_binds_confirmation_to_twenty_minute_deadline(self):
        captured = {}
        class StubWorker:
            def __init__(self, adb, matcher, run_dir, card, recipient, deadline, confirm, *args):
                captured['deadline'] = deadline
                captured['confirm'] = confirm
            def run(self):
                captured['confirm']('approve')
        argv = ['--adb', 'adb', '--serial', 'device', '--recipient', 'Recipient',
                '--card', 'Card', '--run-dir', str(self.root/'cli'), '--templates', str(self.manifest),
                '--lock-dir', str(self.root)]
        with patch.object(s.time, 'monotonic', return_value=100), patch.object(s, 'ShareWorker', StubWorker), patch.object(s, 'bounded_input') as bounded:
            self.assertEqual(0, s.main(argv))
        self.assertEqual(1300, captured['deadline'])
        bounded.assert_called_once_with('approve', 1300)


if __name__ == '__main__':
    unittest.main()
