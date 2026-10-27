#!/usr/bin/env python3
"""Installer state transitions use synthetic bundles and mocked process control."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('manage-install.py'))
i = importlib.util.module_from_spec(spec); spec.loader.exec_module(i)

class AppInstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name); self.source = self.base / 'source.app'
        self.target = self.base / 'apps/ComputerHistory.app'; self.target.parent.mkdir()
        self.root = self.base / 'history'; self.root.mkdir(); (self.root/'model.json').write_text('preserved')
        self.agents = self.base / 'agents'; self.agents.mkdir()
        self.make(self.source, 'new')
        self.run = patch.object(i, 'run').start()
        self.launch = patch.object(i, 'launchctl', return_value=subprocess.CompletedProcess([], 1, b'', b'')).start()
        patch.object(i, 'running_programs', return_value=[]).start()
        self.preserve = patch.object(i, 'preserve_helper').start()
        self.addCleanup(patch.stopall)
    def make(self, bundle, text):
        d=bundle/'Contents/MacOS';d.mkdir(parents=True)
        (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'xyz.chesszyh.computer-history.menubar'}))
        for name in ['computer-history','computer-history-menubar','computer-history-credentials']:(d/name).write_text(text)
    def manage(self, uninstall=False): i.manage_app(self.source,self.target,self.root,self.agents,uninstall)
    def test_install_upgrade_and_uninstall_preserve_history(self):
        self.manage();self.assertEqual(i.app_program(self.target,'computer-history').read_text(),'new')
        self.manage();self.preserve.assert_called()
        self.manage(True);self.assertFalse(self.target.exists());self.assertEqual((self.root/'model.json').read_text(),'preserved')
    def test_both_loaded_services_follow_new_app(self):
        for label in [i.LABEL,'xyz.chesszyh.computerhistory.collector']:
            (self.agents/(label+'.plist')).write_bytes(plistlib.dumps({'Label':label,'ProgramArguments':['/old/tool','--out','synthetic']}))
        self.launch.return_value=subprocess.CompletedProcess([],0,b'',b'')
        self.manage()
        for path in self.agents.iterdir():
            args=plistlib.loads(path.read_bytes())['ProgramArguments'];self.assertIn(str(self.target),args[0]);self.assertEqual(args[1:],['--out','synthetic'])
    def test_rejected_helper_keeps_old_app(self):
        self.make(self.target,'old');self.preserve.side_effect=ValueError('wrong signature')
        with self.assertRaises(ValueError):self.manage()
        self.assertEqual(i.app_program(self.target,'computer-history').read_text(),'old')
        self.assertFalse(any(call.args[0] == 'bootout' for call in self.launch.call_args_list))
    def test_service_failure_restores_app_and_plists(self):
        self.make(self.target,'old')
        path=self.agents/(i.LABEL+'.plist');original=plistlib.dumps({'Label':i.LABEL,'ProgramArguments':['/old/menu']});path.write_bytes(original)
        self.launch.side_effect=lambda *a:subprocess.CompletedProcess([],int(a[0]=='bootstrap'),b'',b'failure')
        with self.assertRaises(RuntimeError):self.manage()
        self.assertEqual(path.read_bytes(),original);self.assertEqual(i.app_program(self.target,'computer-history').read_text(),'old')

if __name__=='__main__':unittest.main()
