#!/usr/bin/env python3
"""Build one native regression executable and reuse it while its inputs match."""
import fcntl
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def build():
    subprocess.run(['swift', 'build', '--scratch-path', '.build/native-core', '-j', '2', '-c', 'release', '--product', 'computer-history-credentials'], cwd=ROOT, check=True)
    subprocess.run(['swift', 'build', '--scratch-path', '.build/native-core', '-j', '2', '-c', 'release', '--target', 'ComputerHistoryCore'], cwd=ROOT, check=True)
    binary_dir = Path(subprocess.check_output(
        ['swift', 'build', '--scratch-path', '.build/native-core', '-c', 'release', '--show-bin-path'], cwd=ROOT, text=True).strip())
    if (binary_dir / 'ComputerHistoryCore.o').exists():
        modules = binary_dir
        objects = [binary_dir / 'ComputerHistoryCore.o']
    else:
        modules = binary_dir / 'Modules'
        objects = sorted((binary_dir / 'ComputerHistoryCore.build').glob('*.o'))
    sources = [ROOT / 'Sources/computer-history-menubar' / name for name in
               ['StatusModel.swift', 'StatusPanel.swift', 'SettingsPane.swift', 'ReportsPane.swift', 'PermissionSetupPane.swift']]
    sources += [ROOT / 'scripts' / f'test-menubar-{name}.swift' for name in
                ['input', 'panel', 'usage', 'settings', 'catalog', 'reports', 'permissions', 'main']]
    inputs = [Path(__file__).resolve(), modules / 'ComputerHistoryCore.swiftmodule'] + sources + objects
    inputs += sorted(modules.glob('ComputerHistoryCore.swiftmodule/**'))
    digest = hashlib.sha256(subprocess.check_output(['swiftc', '--version']))
    digest.update(str(modules).encode())
    for file in inputs:
        if file.is_file():
            digest.update(str(file).encode())
            digest.update(file.read_bytes())
    fingerprint = digest.hexdigest()
    cache = ROOT / '.build/native-tests'
    cache.mkdir(parents=True, exist_ok=True)
    executable = cache / 'panel-test'
    shutil.copy2(binary_dir / 'computer-history-credentials', cache / 'computer-history-credentials')
    if shutil.which('local-codesign'):
        subprocess.run(['local-codesign', '--identifier', 'xyz.chesszyh.computer-history.credentials', str(cache / 'computer-history-credentials')], check=True)
    stamp = cache / 'inputs.sha256'
    with (cache / 'build.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if executable.is_file() and stamp.is_file() and stamp.read_text() == fingerprint:
            print('Reusing native panel test executable', flush=True)
            return executable
        with tempfile.TemporaryDirectory(dir=cache) as directory:
            target = Path(directory) / 'panel-test'
            subprocess.run(['swiftc', '-parse-as-library', '-I', str(modules),
                            *map(str, sources), *map(str, objects), '-o', str(target)], cwd=ROOT, check=True)
            if shutil.which('local-codesign'):
                subprocess.run(['local-codesign', '--identifier',
                                'xyz.chesszyh.computer-history.panel-test', str(target)], check=True)
            target.replace(executable)
            stamp.write_text(fingerprint)
    return executable


if __name__ == '__main__':
    build()
