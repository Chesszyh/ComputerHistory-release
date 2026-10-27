#!/usr/bin/env python3
"""Build a signed macOS app from already-built executables."""
import argparse
from pathlib import Path
import os
import plistlib
import shutil
import subprocess

PROGRAMS = {'computer-history': 'cli', 'computer-history-menubar': 'menubar', 'computer-history-credentials': 'credentials'}
APP_ID = 'xyz.chesszyh.computer-history.menubar'


def sign(path, identifier):
    identity = os.environ.get('CODESIGN_IDENTITY')
    if identity:
        subprocess.run(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp', '--identifier', identifier, str(path)], check=True)
    elif shutil.which('local-codesign'):
        subprocess.run(['local-codesign', '--identifier', identifier, str(path)], check=True)
    else:
        subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', identifier, str(path)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True)


def bundle(bin_dir, output):
    if output.exists():
        raise ValueError('输出目录已存在，请选择新目录。')
    root = Path(__file__).resolve().parent.parent
    binary = output / 'Contents/MacOS'
    resources = output / 'Contents/Resources'
    binary.mkdir(parents=True)
    resources.mkdir()
    for name, suffix in PROGRAMS.items():
        shutil.copy2(bin_dir / name, binary / name)
        sign(binary / name, 'xyz.chesszyh.computer-history.' + suffix)
    info = {'CFBundleExecutable': 'computer-history-menubar', 'CFBundleIdentifier': APP_ID,
            'CFBundleName': 'ComputerHistory', 'CFBundleDisplayName': 'ComputerHistory',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': (root / 'VERSION').read_text().strip(),
            'CFBundleShortVersionString': (root / 'VERSION').read_text().strip(),
            'LSMinimumSystemVersion': '13.0', 'LSUIElement': True,
            'NSHighResolutionCapable': True}
    (output / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copy2(root / 'LICENSE', resources / 'LICENSE')
    shutil.copy2(root / 'docs/distribution.md', resources / 'README.md')
    shutil.copy2(root / 'scripts/manage-install.py', resources / 'manage-install.py')
    sign(output, APP_ID)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    print(bundle(args.bin_dir, args.output))
