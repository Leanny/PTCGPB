#!/usr/bin/env python3
"""Assisted donor-side sharing from a selected card preview (English, 540x960)."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import sys
import time

from trade_worker import (Adb, Matcher, TradeError, Worker, atomic_json,
                          bounded_input, device_lock)

STATES = ('preview', 'confirmation', 'last_copy', 'swipe', 'sent')
ACTIONS = {
    'preview': ['tap', '270', '822'],
    'confirmation': ['tap', '388', '638'],
    'last_copy': ['tap', '388', '670'],
    'swipe': ['swipe', '270', '800', '270', '50', '300'],
}
NEXT = {
    'preview': {'confirmation'},
    'confirmation': {'last_copy', 'swipe'},
    'last_copy': {'swipe'},
    'swipe': {'sent'},
}
VERIFICATION_REGIONS = {'preview': [(220, 118, 150, 50), (110, 185, 322, 450)]}


class ShareAdb(Adb):
    actions = ACTIONS


class ShareWorker(Worker):
    transitions = NEXT
    verification_regions = VERIFICATION_REGIONS

    def run(self):
        state, path = self.capture()
        if state != 'preview':
            raise TradeError('Start at the selected outgoing card preview')
        self.authorize('preview', path)
        while state != 'sent':
            if state == 'last_copy' and not self.allow_last_copy:
                raise TradeError('Last-copy warning: explicit --allow-last-copy is required')
            state, path = self.mutate(state)
        # Only the server's sent toast establishes completion. Missing the brief
        # toast leaves a pending journal; never infer success or repeat the swipe.
        self.record.update(status='completed', state=state, capture=str(path), time=time.time())
        atomic_json(self.journal, self.record)
        print('Card shared. Evidence: ' + str(path), flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--recipient', required=True)
    parser.add_argument('--card', required=True, help='Exact name, set, version and foil treatment')
    parser.add_argument('--run-dir', required=True)
    parser.add_argument('--templates', default=str(Path(__file__).with_name('share_templates') / 'manifest.json'))
    parser.add_argument('--lock-dir', help='Shared local directory; use the same directory for trade and share workers')
    parser.add_argument('--allow-last-copy', action='store_true', help='Allow the in-game last-copy warning')
    parser.add_argument('--inspect', action='store_true', help='Capture and classify only; never send input')
    args = parser.parse_args(argv)
    deadline = time.monotonic()+20*60
    try:
        matcher = Matcher(args.templates, STATES)
        adb = ShareAdb(args.adb, args.serial, deadline)
        with device_lock(args.serial, args.lock_dir):
            worker = ShareWorker(adb, matcher, args.run_dir, args.card, args.recipient,
                                 deadline, lambda prompt: bounded_input(prompt, deadline),
                                 args.allow_last_copy, args.inspect)
            if args.inspect:
                state, path = worker.capture()
                print(json.dumps({'state': state, 'capture': str(path)}))
            else:
                worker.run()
        return 0
    except (TradeError, KeyboardInterrupt, OSError, ValueError, KeyError) as exc:
        print('Stopped: ' + str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
