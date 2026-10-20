#!/usr/bin/env python3
"""Check release eligibility, archive boundaries, and integration failure propagation."""
import contextlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load('publish-release')
integration = load('test-integration')


class BuildToolsTests(unittest.TestCase):
    def test_only_full_success_for_same_repository_and_commit_can_publish(self):
        run = {'repository': {'full_name': 'example/public'}, 'head_sha': 'a' * 40,
               'path': '.github/workflows/ci.yml', 'conclusion': 'success', 'status': 'completed'}
        jobs = [{'name': name, 'conclusion': 'success'} for name in release.REQUIRED_JOBS]
        release.validate_run(run, jobs, 'example/public', 'a' * 40)
        for key, value in [('head_sha', 'b' * 40), ('path', '.github/workflows/other.yml'),
                           ('conclusion', 'failure'), ('status', 'in_progress'),
                           ('repository', {'full_name': 'example/other'})]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.validate_run(dict(run, **{key: value}), jobs, 'example/public', 'a' * 40)
        with self.assertRaises(ValueError):
            release.validate_run(run, jobs[:1], 'example/public', 'a' * 40)
        with self.assertRaises(ValueError):
            release.validate_run(run, [dict(j, conclusion='skipped') for j in jobs], 'example/public', 'a' * 40)

    def test_archive_rejects_extra_files_and_links_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for extra in ['unexpected', '../escape', 'link']:
                archive = root / 'bad.tar.gz'
                with tarfile.open(archive, 'w:gz') as tar:
                    for name in ['computer-history', 'computer-history-menubar', 'LICENSE', 'README.md']:
                        tar.addfile(tarfile.TarInfo(f'ComputerHistory-v1.2.3-macos-arm64/{name}'))
                    item = tarfile.TarInfo(extra)
                    if extra == 'link':
                        item.type = tarfile.SYMTYPE
                        item.linkname = '/tmp/outside'
                    tar.addfile(item)
                with self.subTest(extra=extra), self.assertRaises(ValueError):
                    release.verify_package(archive, root / 'extracted', '1.2.3')
            self.assertFalse((root / 'extracted').exists())

    def test_integration_checks_overlap_and_do_not_hide_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            for name, other in [('one', 'two'), ('two', 'one')]:
                (root / 'scripts' / f'test-{name}.py').write_text(
                    f"from pathlib import Path\nimport time\nPath('{name}').touch()\n"
                    f"deadline=time.monotonic()+3\nwhile not Path('{other}').exists():\n"
                    " if time.monotonic()>deadline: raise RuntimeError('checks did not overlap')\n time.sleep(.01)\n")
            (root / 'scripts/test-fail.py').write_text("raise SystemExit(7)\n")
            with patch.object(integration, 'ROOT', root), contextlib.redirect_stdout(io.StringIO()):
                self.assertTrue(integration.run_checks(root / 'unused', root / 'logs', ['one', 'two'], jobs=2))
                self.assertFalse(integration.run_checks(root / 'unused', root / 'logs', ['one', 'fail'], jobs=2))
            self.assertTrue((root / 'logs/fail.log').exists())


if __name__ == '__main__':
    unittest.main()
