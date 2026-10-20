#!/usr/bin/env python3
"""Verify a full public CI run and its package; publish only with --publish."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
REQUIRED_JOBS = {'Core (debug)', 'Core (release)', 'Native panels (all)'}


def command(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def gh_json(*args, payload=None):
    extra = ['--input', '-'] if payload is not None else []
    return json.loads(command('gh', *args, *extra, input=json.dumps(payload) if payload is not None else None))


def validate_run(run, jobs, repository, commit):
    if (run['repository']['full_name'] != repository or run['head_sha'] != commit
            or run['path'] != '.github/workflows/ci.yml' or run['conclusion'] != 'success'
            or run['status'] != 'completed'):
        raise ValueError('Use a successful full CI run for the checked-out commit in this public repository')
    passed = {job['name'] for job in jobs if job['conclusion'] == 'success'}
    if not REQUIRED_JOBS <= passed:
        raise ValueError('CI must pass Debug, Release, and all native panel checks; focused runs cannot publish')


def release_notes(version):
    sections = []
    for name in ['CHANGELOG.zh.md', 'CHANGELOG.md']:
        text = (ROOT / name).read_text()
        match = re.search(r'^## ' + re.escape(version) + r' - [^\n]+\n(.*?)(?=^## |\Z)', text, re.M | re.S)
        if not match:
            raise ValueError(f'{name}: missing release notes for {version}')
        sections.append(match[1].strip())
    return '\n\n---\n\n'.join(sections) + '\n'


def verify_package(archive, output, version):
    name = f'ComputerHistory-v{version}-macos-arm64'
    expected = {f'{name}/{item}' for item in ['computer-history', 'computer-history-menubar', 'LICENSE', 'README.md']}
    with tarfile.open(archive) as tar:
        members = tar.getmembers()
        if {m.name for m in members if m.isfile()} != expected or any(
                m.name not in expected | {name} or not (m.isfile() or m.isdir()) for m in members):
            raise ValueError('Release package must contain only the two programs, LICENSE, and README.md')
        tar.extractall(output, filter='data')
    for executable in ['computer-history', 'computer-history-menubar']:
        path = str(output / name / executable)
        if command('lipo', '-archs', path) != 'arm64':
            raise ValueError(f'{executable}: expected arm64')
        subprocess.run(['codesign', '--verify', '--strict', path], check=True)
        libraries = command('otool', '-L', path).splitlines()[1:]
        if any(not line.strip().startswith(('/System/Library/', '/usr/lib/')) for line in libraries):
            raise ValueError(f'{executable}: non-system dependency in release package')
        minimum = re.search(r'\bminos\s+([\d.]+)', command('otool', '-l', path))
        if not minimum or minimum[1] not in ['13.0', '13.0.0']:
            raise ValueError(f'{executable}: unexpected minimum macOS version')
    subprocess.run([str(output / name / 'computer-history'), '--help'], check=True, stdout=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', required=True, type=int)
    parser.add_argument('--repo', help='Defaults to the repository selected by gh')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    repo_args = ['--repo', args.repo] if args.repo else []
    repo = gh_json('repo', 'view', *repo_args, '--json', 'nameWithOwner,visibility')
    if repo['visibility'] != 'PUBLIC':
        raise ValueError('Run this entry point against the public repository')
    repository = repo['nameWithOwner']
    commit = command('git', 'rev-parse', 'HEAD', cwd=ROOT)
    run = gh_json('api', f'repos/{repository}/actions/runs/{args.run_id}')
    jobs = gh_json('run', 'view', str(args.run_id), '--repo', repository, '--json', 'jobs')['jobs']
    validate_run(run, jobs, repository, commit)
    version = (ROOT / 'VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('VERSION must contain a three-part release version')
    tag = f'v{version}'
    notes = release_notes(version)
    existing = subprocess.run(['gh', 'release', 'view', tag, '--repo', repository],
                              capture_output=True, text=True)
    if existing.returncode == 0:
        raise ValueError(f'{tag} already has a Release; update VERSION and the changelogs first')
    if 'release not found' not in existing.stderr.lower() and '404' not in existing.stderr:
        raise RuntimeError(existing.stderr.strip())
    refs = command('git', 'ls-remote', f'https://github.com/{repository}.git',
                   f'refs/tags/{tag}', f'refs/tags/{tag}^{{}}').splitlines()
    if refs and refs[-1].split()[0] != commit:
        raise ValueError(f'{tag} already points to another commit')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    artifact = output / 'artifact'
    artifact.mkdir(exist_ok=True)
    subprocess.run(['gh', 'run', 'download', str(args.run_id), '--repo', repository,
                    '--name', 'ComputerHistory-macos-arm64', '--dir', str(artifact)], check=True)
    archive = artifact / f'ComputerHistory-v{version}-macos-arm64.tar.gz'
    verify_package(archive, output / 'verified', version)
    notes_path = output / 'release-notes.md'
    notes_path.write_text(notes)
    print(f'Verified {tag}: {commit}, CI {args.run_id}, {archive}', flush=True)
    if not args.publish:
        print('Package verified; use --publish to create the tag and Release')
        return
    if not refs:
        annotation = gh_json('api', '--method', 'POST', f'repos/{repository}/git/tags', payload={
            'tag': tag, 'message': f'ComputerHistory {tag}', 'object': commit, 'type': 'commit'})
        gh_json('api', '--method', 'POST', f'repos/{repository}/git/refs', payload={
            'ref': f'refs/tags/{tag}', 'sha': annotation['sha']})
    subprocess.run(['gh', 'release', 'create', tag, '--repo', repository, '--verify-tag',
                    '--title', tag, '--notes-file', str(notes_path), '--latest', str(archive)], check=True)
    published = gh_json('api', f'repos/{repository}/releases/tags/{tag}')
    assets = published['assets']
    digest = 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()
    if (published['draft'] or published['prerelease'] or len(assets) != 1
            or assets[0]['name'] != archive.name or assets[0]['size'] != archive.stat().st_size
            or assets[0]['digest'] != digest):
        raise RuntimeError('Release was created, but its uploaded asset did not match the verified package; inspect it before retrying')
    print(f'Published and verified: {published["html_url"]}', flush=True)


if __name__ == '__main__':
    main()
