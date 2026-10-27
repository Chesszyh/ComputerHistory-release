#!/usr/bin/env python3
"""Exercise real keychain APIs with disposable synthetic items; no authentication UI."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
helper = binary.parent / 'computer-history-credentials'
with tempfile.TemporaryDirectory(prefix='computer-history-credentials-test-') as directory:
    root = Path(directory)
    group = 'synthetic'
    (root / 'model.json').write_text(json.dumps(dict(groups=[dict(id=group, name='Synthetic', baseURL='http://127.0.0.1:1234/v1', model='synthetic', requiresAPIKey=True)], primaryGroupID=group)))
    def request(operation, executable=helper, **extra):
        data = dict(operation=operation, root=str(root), groupID=group, **extra)
        run = subprocess.run([str(executable)], input=json.dumps(data), text=True, capture_output=True, timeout=10)
        result = json.loads(run.stdout)
        return run.returncode, result
    assert request('contains')[1] == {'ok': True, 'exists': False}
    assert request('save', key='synthetic-credential-value')[0] == 0
    try:
        assert request('load')[1]['key'] == 'synthetic-credential-value'
        # A changed business executable still uses exactly the same credential owner.
        new = root / 'upgraded'; new.mkdir()
        for name in [binary.name, helper.name]:
            shutil.copy2(binary.parent / name, new / name)
        assert request('load', executable=new / helper.name)[1]['key'] == 'synthetic-credential-value'
        command = subprocess.run([str(new / binary.name), 'model-key', '--check', '--out', str(root)], capture_output=True, text=True, timeout=10)
        assert command.returncode == 0, command.stderr
        authorized = subprocess.run([str(new / binary.name), 'model-key', '--authorize', '--out', str(root)], capture_output=True, text=True, timeout=10)
        assert authorized.returncode == 0, authorized.stderr
        assert 'synthetic-credential-value' not in authorized.stdout + authorized.stderr
        link = root / 'linked-cli'; link.symlink_to(new / binary.name)
        linked = subprocess.run([str(link), 'model-key', '--check', '--out', str(root)], capture_output=True, text=True, timeout=10)
        assert linked.returncode == 0, linked.stderr
        # A check must never print the value.
        assert 'synthetic-credential-value' not in command.stdout + command.stderr
        wrong = root / 'wrong-helper'; shutil.copy2(helper, wrong)
        subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'invalid.synthetic.credential.reader', str(wrong)], check=True, capture_output=True)
        denied = request('load', executable=wrong)
        assert denied[0] != 0, 'untrusted executable unexpectedly read the item'
        assert '恢复密钥访问' in denied[1]['error']
    finally:
        assert request('remove')[0] == 0
    assert not request('contains')[1]['exists']
print('PASS: silent synthetic keychain read/write, retained owner across upgrade, untrusted reader denied, cleanup')
