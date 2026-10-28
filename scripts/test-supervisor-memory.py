#!/usr/bin/env python3
"""Check long-lived supervisor memory using synthetic sealed segments."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time


def footprint(pid):
    output = subprocess.check_output(
        ['/usr/bin/footprint', '-p', str(pid)], text=True, timeout=10,
        env=dict(os.environ, LC_ALL='C'))
    match = re.search(r'Footprint:\s+([\d.]+)\s+(B|KB|MB|GB)', output)
    assert match, 'could not read supervisor physical footprint'
    return float(match[1]) * {'B': 1, 'KB': 1024, 'MB': 1024**2, 'GB': 1024**3}[match[2]]


binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='supervisor-memory-') as directory:
    root = Path(directory)
    (root / 'control.json').write_text(json.dumps({'recording': False, 'summarizing': False}))
    for index in range(1200):
        segment = root / 'segments' / f'synthetic-{index:04d}'
        segment.mkdir(parents=True)
        (segment / 'metadata.json').write_text('{}')
    supervisor = subprocess.Popen(
        [str(binary), 'supervise', '--out', str(root), '--memorize-interval', '0', '--no-model'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        env=dict(os.environ, COMPUTER_HISTORY_NOTIFICATIONS='0'))
    try:
        deadline = time.monotonic() + 8
        while not (root / 'collector.pid').exists():
            assert supervisor.poll() is None, 'supervisor exited during startup'
            assert time.monotonic() < deadline, 'collector did not publish identity'
            time.sleep(.05)
        time.sleep(2)
        before = footprint(supervisor.pid)
        time.sleep(14)
        assert supervisor.poll() is None, 'supervisor exited during memory observation'
        growth = footprint(supervisor.pid) - before
        print(f'Supervisor footprint growth over 14s: {growth / 1024**2:.2f} MiB', flush=True)
        assert growth < 8 * 1024**2, 'directory polling accumulated temporary objects'
        subprocess.run([str(binary), '--stop', '--out', str(root)],
                       check=True, capture_output=True, timeout=10)
        assert supervisor.wait(timeout=8) == 0
        assert not (root / 'collector.pid').exists()
        metadata = list((root / 'segments').glob('*/metadata.json'))
        assert len(metadata) >= 1201, 'stopped collector did not seal its segment'
        assert all((root / 'segments' / f'synthetic-{index:04d}' / 'metadata.json').read_text() == '{}'
                   for index in range(1200)), 'existing sealed segments were modified'
        print('PASS: supervisor polling keeps memory bounded and stops with sealed metadata')
    finally:
        # The session and all its children belong to this test, including failed-startup paths.
        try:
            os.killpg(supervisor.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            supervisor.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(supervisor.pid, signal.SIGKILL)
            supervisor.wait(timeout=5)
