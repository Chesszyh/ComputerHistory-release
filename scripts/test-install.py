#!/usr/bin/env python3
"""Synthetic install/upgrade/uninstall and rollback checks; never touch the user's installation."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('manage-install.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.source = self.base / 'release'
        self.source.mkdir()
        for name in installer.FILES:
            (self.source / name).write_text('new')
        self.target = self.base / 'Applications' / 'ComputerHistory'
        self.target.parent.mkdir()
        self.root = self.base / 'history'
        self.root.mkdir()
        for name in ['config.json', 'model.json', 'requests.json', 'events.jsonl']:
            (self.root / name).write_text('synthetic preserved')
        self.plist = self.base / 'login.plist'
        self.addCleanup(patch.stopall)
        self.run = patch.object(installer, 'run').start()
        self.launch = patch.object(installer, 'launchctl', return_value=subprocess.CompletedProcess([], 0, b'', b'')).start()
        patch.object(installer, 'running_programs', return_value=[]).start()

    def manage(self, uninstall=False):
        installer.manage(self.source, self.target, self.root, self.plist, uninstall)

    def old_install(self):
        self.target.mkdir()
        for name in installer.FILES:
            (self.target / name).write_text('old')
        self.plist.write_bytes(plistlib.dumps({'Label': installer.LABEL, 'ProgramArguments': ['/old/version/computer-history-menubar']}))

    def test_install_upgrade_uninstall_preserve_data(self):
        self.launch.return_value = subprocess.CompletedProcess([], 1, b'', b'')
        self.manage()
        self.assertEqual((self.target / installer.FILES[0]).read_text(), 'new')
        self.assertFalse(self.plist.exists())
        self.plist.write_bytes(plistlib.dumps({'Label': installer.LABEL, 'ProgramArguments': ['/old/version']}))
        self.launch.return_value = subprocess.CompletedProcess([], 0, b'', b'')
        self.manage()
        self.assertEqual(plistlib.loads(self.plist.read_bytes())['ProgramArguments'], [str(self.target / installer.PROGRAMS[1]), '--out', str(self.root)])
        self.manage(uninstall=True)
        self.assertFalse(self.target.exists())
        self.assertFalse(self.plist.exists())
        self.assertTrue(all(p.read_text() == 'synthetic preserved' for p in self.root.iterdir()))

    def test_copy_preserves_download_quarantine(self):
        source = self.source / installer.FILES[0]
        subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.quarantine', '0081;00000000;Synthetic;', str(source)], check=True)
        self.launch.return_value = subprocess.CompletedProcess([], 1, b'', b'')
        self.manage()
        value = subprocess.check_output(['/usr/bin/xattr', '-p', 'com.apple.quarantine', str(self.target / installer.FILES[0])], text=True)
        self.assertEqual(value.strip().split(';')[0], '0081')

    def test_stop_failure_keeps_old_programs(self):
        self.old_install()
        self.run.side_effect = subprocess.CalledProcessError(1, ['synthetic-stop'])
        with self.assertRaises(subprocess.CalledProcessError):
            self.manage()
        self.assertEqual((self.target / installer.FILES[0]).read_text(), 'old')

    def test_bootstrap_failure_rolls_back_files_and_login(self):
        self.old_install()
        original = self.plist.read_bytes()
        def launch(*args):
            return subprocess.CompletedProcess([], int(args[0] == 'bootstrap'), b'', b'synthetic failure')
        self.launch.side_effect = launch
        with self.assertRaises(RuntimeError):
            self.manage()
        self.assertEqual(self.plist.read_bytes(), original)
        self.assertTrue(all(p.read_text() == 'old' for p in self.target.iterdir()))

    def test_rename_failure_restores_old_directory(self):
        self.old_install()
        rename = Path.rename
        def fail_new(path, target):
            if path.name == 'new':
                raise OSError('synthetic rename failure')
            return rename(path, target)
        with patch.object(Path, 'rename', fail_new), self.assertRaises(OSError):
            self.manage()
        self.assertTrue(all(p.read_text() == 'old' for p in self.target.iterdir()))

    def test_unknown_install_files_abort_before_stop(self):
        self.old_install()
        (self.target / 'personal-note').touch()
        with self.assertRaises(ValueError):
            self.manage()
        self.run.assert_not_called()

    def test_wait_timeout_does_not_replace(self):
        self.old_install()
        with patch.object(installer, 'running_programs', return_value=['synthetic']), \
                patch.object(installer.time, 'monotonic', side_effect=[0, 16]), self.assertRaises(RuntimeError):
            self.manage()
        self.assertEqual((self.target / installer.FILES[0]).read_text(), 'old')


if __name__ == '__main__':
    unittest.main()
