#!/usr/bin/env python3
"""Assisted donor-side trading for an already selected card (English, 540x960)."""
from __future__ import annotations
import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageChops, ImageStat

STATES = ('preview', 'set_confirmation', 'last_copy', 'offered', 'waiting',
          'response', 'final_confirmation', 'swipe', 'received')
ACTIONS = {
    'preview': ['tap', '388', '822'],
    'set_confirmation': ['tap', '388', '638'],
    'last_copy': ['tap', '388', '670'],
    'offered': ['tap', '270', '770'],
    'waiting': ['tap', '433', '655'],
    'response': ['tap', '399', '821'],
    'final_confirmation': ['tap', '388', '638'],
    'swipe': ['swipe', '270', '800', '270', '50', '300'],
}
NEXT = {
    'preview': {'set_confirmation'},
    'set_confirmation': {'last_copy', 'offered'},
    'last_copy': {'offered'},
    'offered': {'waiting', 'response'},
    'waiting': {'waiting', 'response'},
    'response': {'final_confirmation'},
    'final_confirmation': {'swipe'},
    'swipe': {'received'},
}

VERIFICATION_REGIONS = {
    'preview': [(220, 165, 150, 50), (110, 230, 322, 450)],
    'response': [(335, 150, 150, 55), (49, 336, 198, 275), (295, 221, 196, 308)],
}


def same_verified_content(reference, current, state, regions=None):
    # Conservative: animation may stop a valid trade, but a changed card or name
    # must never inherit an earlier approval of the same screen type.
    reference, current = reference.convert('RGB'), current.convert('RGB')
    for x, y, width, height in (regions or VERIFICATION_REGIONS)[state]:
        box = (x, y, x+width, y+height)
        difference = ImageChops.difference(reference.crop(box), current.crop(box))
        # A whole-region average can hide a single changed name glyph or
        # collector number. Bound every small tile instead.
        for top in range(0, height, 8):
            for left in range(0, width, 8):
                tile = difference.crop((left, top, min(left+8, width), min(top+8, height)))
                if sum(ImageStat.Stat(tile).mean)/3 > 3:
                    return False
    return True


class TradeError(RuntimeError):
    pass


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


@contextlib.contextmanager
def device_lock(serial, directory=None):
    """OS locks release on crashes; keep the file to avoid an unlink/relock race."""
    root = Path(directory or tempfile.gettempdir()) / 'ptcgpb-trade-locks'
    root.mkdir(parents=True, exist_ok=True)
    path = root / (hashlib.sha256(serial.encode()).hexdigest() + '.lock')
    with path.open('a+b') as stream:
        stream.seek(0)
        if stream.read(1) == b'':
            stream.write(b'0')
            stream.flush()
        stream.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            raise TradeError('Another worker owns this device lock.') from exc
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == 'nt':
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream, fcntl.LOCK_UN)


class Matcher:
    def __init__(self, manifest, states=STATES):
        path = Path(manifest)
        raw = json.loads(path.read_text(encoding='utf-8'))
        self.signatures = {}
        for state in states:
            entries = raw.get(state)
            if not entries:
                raise TradeError('Missing signatures for ' + state)
            loaded = []
            for entry in entries:
                x, y, width, height = entry['box']
                if min(x, y) < 0 or min(width, height) <= 0 or x+width > 540 or y+height > 960:
                    raise TradeError('Invalid signature rectangle')
                image = Image.open(path.parent / entry['file']).convert('RGB')
                if image.size != (width, height):
                    raise TradeError('Signature size does not match rectangle')
                threshold = float(entry.get('max_mae', 8))
                if not 0 <= threshold <= 20:
                    raise TradeError('Signature tolerance must be between 0 and 20')
                loaded.append(((x, y, x+width, y+height), image, threshold))
            self.signatures[state] = loaded

    def classify(self, image):
        if image.size != (540, 960):
            raise TradeError('Expected a 540x960 screenshot')
        image = image.convert('RGB')
        matches = []
        for state, signatures in self.signatures.items():
            if all(sum(ImageStat.Stat(ImageChops.difference(image.crop(box), reference)).mean)/3 <= threshold
                   for box, reference, threshold in signatures):
                matches.append(state)
        if len(matches) > 1:
            raise TradeError('Ambiguous screen signatures: ' + ', '.join(matches))
        return matches[0] if matches else None


class Adb:
    actions = ACTIONS

    def __init__(self, executable, serial, deadline):
        self.command = [executable, '-s', serial]
        self.deadline = deadline

    def run(self, *arguments):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TradeError('Session deadline reached')
        try:
            return subprocess.run(self.command + list(arguments), check=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  timeout=min(15, remaining)).stdout
        except (subprocess.SubprocessError, OSError) as exc:
            raise TradeError('ADB command failed; reconcile device before continuing.') from exc

    def capture(self):
        data = self.run('exec-out', 'screencap', '-p')
        try:
            frame = Image.open(io.BytesIO(data))
            frame.load()
            return frame
        except (OSError, ValueError) as exc:
            raise TradeError('ADB returned an invalid screenshot') from exc

    def act(self, state):
        self.run('shell', 'input', *self.actions[state])


class Worker:
    transitions = NEXT
    verification_regions = VERIFICATION_REGIONS

    def __init__(self, adb, matcher, run_dir, card, recipient, deadline, confirm=input, allow_last_copy=False, inspect=False):
        self.adb, self.matcher = adb, matcher
        self.directory = Path(run_dir)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.journal = self.directory / 'journal.json'
        self.card, self.recipient = card, recipient
        self.deadline, self.confirm = deadline, confirm
        self.allow_last_copy = allow_last_copy
        self.approved = {}
        self.record = {'card': card, 'recipient': recipient, 'status': 'new'}
        if self.journal.exists() and not inspect:
            old = json.loads(self.journal.read_text(encoding='utf-8'))
            raise TradeError('Existing journal: ' + old.get('status', 'unknown') +
                             '. Inspect and reconcile manually; use a new run directory only after reconciliation.')

    def capture(self):
        if time.monotonic() >= self.deadline:
            raise TradeError('Session deadline reached')
        frame = self.adb.capture()
        path = self.directory / (str(time.time_ns()) + '.png')
        frame.save(path)
        return self.matcher.classify(frame), path

    def authorize(self, phase, path):
        expected = self.card + ' | ' + self.recipient
        prompt = ('Inspect ' + str(path) + '\nVerify the exact outgoing card/version and recipient.'
                  if phase == 'preview' else
                  'Inspect ' + str(path) + '\nVerify incoming card, outgoing card and recipient; '
                  'continuing authorizes the final exchange.')
        print(prompt, flush=True)
        # The CLI supplies bounded input; tests may supply a synchronous callback.
        answer = self.confirm('Type exactly "' + expected + '" to continue: ')
        if time.monotonic() >= self.deadline or answer != expected:
            raise TradeError('Confirmation declined or expired')
        current, fresh_path = self.capture()
        if current != phase:
            raise TradeError('Screen changed during operator confirmation')
        with Image.open(path) as reference, Image.open(fresh_path) as fresh:
            if not same_verified_content(reference, fresh, phase, self.verification_regions):
                raise TradeError('Card or recipient image changed during confirmation; reconcile manually')
            self.approved[phase] = fresh.copy()

    def mutate(self, state):
        current, fresh_path = self.capture()
        if current != state:
            raise TradeError('Screen changed before action')
        if state in self.approved:
            with Image.open(fresh_path) as fresh:
                if not same_verified_content(self.approved[state], fresh, state, self.verification_regions):
                    raise TradeError('Approved card or recipient image changed before action')
        self.record.update(status='action_pending', state=state, time=time.time())
        atomic_json(self.journal, self.record)
        self.adb.act(state)
        # Never retry a transactional action. Only settle once its successor is visible.
        end = min(self.deadline, time.monotonic() + 45)
        while time.monotonic() < end:
            time.sleep(1)
            observed, path = self.capture()
            if observed in self.transitions[state]:
                self.record.update(status='observed', state=observed, capture=str(path))
                atomic_json(self.journal, self.record)
                return observed, path
            if observed is not None and observed != state:
                raise TradeError('Unexpected transition from ' + state + ' to ' + observed)
        raise TradeError('No confirmed successor; action remains pending. Reconcile manually.')

    def run(self):
        state, path = self.capture()
        if state != 'preview':
            raise TradeError('Start at the selected outgoing card preview')
        self.authorize('preview', path)
        while state != 'received':
            if state == 'last_copy' and not self.allow_last_copy:
                raise TradeError('Last-copy warning: explicit --allow-last-copy is required')
            if state == 'response':
                self.authorize('response', path)
            if state == 'waiting':
                print('Waiting for the recipient to respond on their phone.', flush=True)
                time.sleep(min(10, max(0, self.deadline-time.monotonic())))
                # Refresh only after confirming this is still the waiting screen.
                state, path = self.capture()
                if state == 'response':
                    continue
                if state != 'waiting':
                    raise TradeError('Waiting screen changed unexpectedly')
            state, path = self.mutate(state)
        self.record.update(status='completed', state=state, capture=str(path), time=time.time())
        atomic_json(self.journal, self.record)
        print('Trade completed. Evidence: ' + str(path), flush=True)


def bounded_input(prompt, deadline):
    """A daemon reader keeps a missing console response from extending the session."""
    import queue
    import threading
    answers = queue.Queue()
    def read():
        try:
            answers.put(input(prompt))
        except EOFError:
            answers.put(None)
    threading.Thread(target=read, daemon=True).start()
    try:
        value = answers.get(timeout=max(0, deadline-time.monotonic()))
    except queue.Empty as exc:
        raise TradeError('Operator confirmation timed out') from exc
    if value is None:
        raise TradeError('No interactive input available')
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--recipient', required=True)
    parser.add_argument('--card', required=True, help='Exact name, set and version')
    parser.add_argument('--run-dir', required=True)
    parser.add_argument('--templates', default=str(Path(__file__).with_name('trade_templates') / 'manifest.json'))
    parser.add_argument('--lock-dir', help='Shared local directory; use the same directory for every worker')
    parser.add_argument('--allow-last-copy', action='store_true', help='Allow the in-game last-copy warning')
    parser.add_argument('--inspect', action='store_true', help='Capture and classify only; never send input')
    args = parser.parse_args(argv)
    deadline = time.monotonic()+20*60
    try:
        matcher = Matcher(args.templates)
        adb = Adb(args.adb, args.serial, deadline)
        with device_lock(args.serial, args.lock_dir):
            worker = Worker(adb, matcher, args.run_dir, args.card, args.recipient,
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
