#!/usr/bin/env python3
"""Check release eligibility, archive boundaries, and integration failure propagation."""
import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load('publish-release')
integration = load('test-integration')


class BuildToolsTests(unittest.TestCase):
    def test_explicit_repository_and_existing_release_stop_before_download_or_write(self):
        commit = 'a' * 40
        run = {'repository': {'full_name': 'example/public'}, 'head_sha': commit,
               'path': '.github/workflows/ci.yml', 'conclusion': 'success', 'status': 'completed'}
        jobs = [{'name': name, 'conclusion': 'success'} for name in release.REQUIRED_JOBS]
        with patch('sys.argv', ['publish-release.py', '--repo', 'example/public', '--run-id', '123',
                                '--output', '/unused', '--publish']), \
                patch.object(release, 'gh_json', side_effect=[
                    {'nameWithOwner': 'example/public', 'visibility': 'PUBLIC'}, run, {'jobs': jobs}]) as api, \
                patch.object(release, 'command', return_value=commit), \
                patch.object(release.subprocess, 'run') as process:
            process.return_value.returncode = 0
            with self.assertRaisesRegex(ValueError, 'already has a Release'):
                release.main()
            self.assertEqual(api.call_args_list[0].args,
                             ('repo', 'view', 'example/public', '--json', 'nameWithOwner,visibility'))
            self.assertEqual(api.call_count, 3)
            self.assertEqual(process.call_count, 1)

    def test_candidate_release_is_prerelease_and_never_latest(self):
        version = '1.0.0-rc.1'
        commit = 'a' * 40
        run = {'repository': {'full_name': 'example/public'}, 'head_sha': commit,
               'path': '.github/workflows/ci.yml', 'conclusion': 'success', 'status': 'completed'}
        jobs = [{'name': name, 'conclusion': 'success'} for name in release.REQUIRED_JOBS]
        payload = b'synthetic archive'
        name = f'ComputerHistory-v{version}-macos-arm64.tar.gz'
        published = {'draft': False, 'prerelease': True, 'html_url': 'https://example.invalid/release',
                     'assets': [{'name': name, 'size': len(payload),
                                 'digest': 'sha256:' + hashlib.sha256(payload).hexdigest()}]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'VERSION').write_text(version)
            for file in ['CHANGELOG.md', 'CHANGELOG.zh.md']:
                (root / file).write_text(f'## {version} - 2026-01-01\nCandidate notes.\n')
            calls = []
            def process(args, **kwargs):
                calls.append(args)
                if args[1:3] == ['run', 'download']:
                    (Path(args[args.index('--dir')+1]) / name).write_bytes(payload)
                return SimpleNamespace(returncode=1, stderr='release not found')
            with patch('sys.argv', ['publish-release.py', '--repo', 'example/public', '--run-id', '123',
                                    '--output', str(root / 'output'), '--publish']), \
                    patch.object(release, 'ROOT', root), \
                    patch.object(release, 'gh_json', side_effect=[
                        {'nameWithOwner': 'example/public', 'visibility': 'PUBLIC'}, run, {'jobs': jobs},
                        {'sha': 'b' * 40}, {}, published]), \
                    patch.object(release, 'command', side_effect=lambda *args, **kw: '' if args[1] == 'ls-remote' else commit), \
                    patch.object(release, 'verify_package') as verify, \
                    patch.object(release.subprocess, 'run', side_effect=process), contextlib.redirect_stdout(io.StringIO()):
                release.main()
            create = next(c for c in calls if c[1:3] == ['release', 'create'])
            self.assertIn('--prerelease', create)
            self.assertIn('--latest=false', create)
            self.assertNotIn('--latest', create)
            verify.assert_called_once()

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
                    for name in ['computer-history', 'computer-history-menubar', 'LICENSE', 'README.md', 'manage-install.py']:
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
